// [device-access] This phone's side of Device Access (hermes-hq-push 0.9.19 Contacts, 0.9.21 every kind): tells the
// signed-in gateway what it shares, and answers what bots asked. Requests are fetched when the add-on's silent push
// wakes the app (AppDelegate), when the app comes back on screen, and after sign-in; each is checked against this
// phone's own switches (DeviceAccess.check) and then run by its kind's handler (DeviceAccessHandlers). Each one is
// noted in Recent Requests, on this phone only. Logs say what kind of request it was and how it ended, never what was
// asked or found.

import Foundation
import Observation
import UIKit

@MainActor @Observable final class DeviceAccessCenter {
    static let shared = DeviceAccessCenter()

    private(set) var settings = DeviceAccess.Settings.load()
    /// Recent Requests, newest first (the last 50; kept on this phone only).
    private(set) var recent: [DeviceAccess.LogEntry] = []

    /// A handler's time for one request: a silent push's background time is about 30 seconds in all.
    static let answerSeconds: Double = 20
    /// Audit 09-8: every request a wake-up in the background answers fits in this much, all together (iOS gives about
    /// 30 seconds). What doesn't fit is left waiting: the add-on hands it out again on the next fetch.
    static let backgroundSeconds: Double = 26
    static let recentKey = "hq.deviceAccess.recent"

    /// A bot's name as the app shows it, from its profile (set by the signed-in app; else the profile made readable).
    @ObservationIgnored var botNames: ((String) -> String)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var again = false
    /// When a wake-up's background time runs out (nil: the app is on screen, or no wake-up is being answered).
    @ObservationIgnored private var backgroundEnds: ContinuousClock.Instant?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if DEBUG
        // UI tests: `-HQDebugResetDeviceAccess YES` starts with nothing shared, no gateway told and no drafts waiting.
        if defaults.bool(forKey: "HQDebugResetDeviceAccess") {
            defaults.removeObject(forKey: DeviceAccess.Settings.key)
            defaults.removeObject(forKey: "hq.deviceAccess.holders")
            defaults.removeObject(forKey: Self.recentKey)
            defaults.removeObject(forKey: DraftsStore.key)
        }
        #endif
        settings = DeviceAccess.Settings.load(defaults)
        recent = defaults.data(forKey: Self.recentKey).flatMap { try? JSONDecoder().decode([DeviceAccess.LogEntry].self, from: $0) } ?? []
    }

    /// The accounts whose gateway holds this phone's sharing (a PUT went through), so turning everything off or
    /// leaving tells them; one that was never told isn't bothered.
    private var holders: Set<String> {
        get { Set(defaults.stringArray(forKey: "hq.deviceAccess.holders") ?? []) }
        set { defaults.set(Array(newValue.suffix(8)), forKey: "hq.deviceAccess.holders") }
    }

    private var route: String { DeviceAccess.route(PushRegistrar.deviceID) }

    // MARK: Switches

    func setContactField(_ field: DeviceAccess.ContactField, on: Bool) { set(.contacts, field.rawValue, on: on) }

    func set(_ kind: DeviceAccess.Kind, _ key: String, on: Bool) {
        var next = settings
        next.set(kind, key, on: on)
        guard next != settings else { return }
        settings = next
        settings.save(defaults)
        AppLog.note("device", "\(kind.rawValue) \(key) \(on ? "on" : "off")")
        Task { @MainActor in await tellGateway() }
    }

    /// [health-all-types] Several switches of a kind at once (a Health group's Turn On All): saved and told once.
    func set(_ kind: DeviceAccess.Kind, _ keys: Set<String>, on: Bool) {
        var next = settings
        next.set(kind, keys, on: on)
        guard next != settings else { return }
        settings = next
        settings.save(defaults)
        AppLog.note("device", "\(kind.rawValue) \(keys.count) \(on ? "on" : "off")")
        Task { @MainActor in await tellGateway() }
    }

    func clearRecent() {
        recent = []
        defaults.removeObject(forKey: Self.recentKey)
    }

    // MARK: Lifecycle

    /// Signed in (launch restore, a fresh sign-in, a switch): this gateway hears what is shared, then waiting requests run.
    func accountReady() {
        Task { @MainActor in
            await tellGateway()
            if settings.sharesAnything { await fetch() }
        }
    }

    /// Back on screen: anything a bot asked while the wake-up didn't come (notifications off, iOS held it back).
    func appActive() {
        guard settings.sharesAnything, PushRegistrar.shared.call != nil else { return }
        Task { @MainActor in await fetch() }
    }

    /// Before a sign-out or a gateway switch: the gateway being left stops asking this phone.
    func leaving() async {
        guard let call = PushRegistrar.shared.call, let owner = PushRegistrar.shared.owner, holders.contains(owner) else { return }
        let result = await call(route, "DELETE", nil)
        if [200, 204, 404].contains(result.status) { holders.remove(owner) }
        AppLog.note("device", "left gateway (\(result.status))")
    }

    /// PUT what is shared, or DELETE once nothing is (only where a share was ever made).
    @discardableResult
    func tellGateway() async -> Int {
        guard let call = PushRegistrar.shared.call, let owner = PushRegistrar.shared.owner else { return 0 }
        if settings.sharesAnything {
            let body: [String: Any] = ["access": settings.wire, "account": owner, "name": DeviceWord.name,
                                       "platform": DeviceWord.isMac ? "mac" : "ios"]
            let result = await call(route, "PUT", body)
            if result.status == 200 { holders.insert(owner) }
            AppLog.note("device", "shared (\(result.status))")
            return result.status
        }
        guard holders.contains(owner) else { return 0 }
        let result = await call(route, "DELETE", nil)
        if [200, 204, 404].contains(result.status) { holders.remove(owner) }
        AppLog.note("device", "stopped sharing (\(result.status))")
        return result.status
    }

    // MARK: Requests

    /// Whether a request finds the app open: on screen and active. [mac] Mac polish #26: on the Mac a window behind
    /// another app's is still open (its scene is in the foreground, inactive), so Location answers there without While
    /// Locked and a wake-up isn't timed as the background; only a minimized, hidden or closed window counts as away.
    /// A locked Mac, its screens asleep or another user's session counts as away too: the window is on screen for nobody.
    static var appOpen: Bool {
        #if targetEnvironment(macCatalyst)
        !MacTrail.nobodyAtIt && UIApplication.shared.connectedScenes.contains { onScreen($0.activationState) }
        #else
        UIApplication.shared.applicationState == .active
        #endif
    }

    /// [mac] A Mac window in this state is on screen, frontmost or not.
    nonisolated static func onScreen(_ state: UIScene.ActivationState) -> Bool {
        state == .foregroundActive || state == .foregroundInactive
    }

    /// The add-on's silent push: answer what waits, within iOS's short background time. Before the app's sign-in is
    /// back (a launch in the background), the saved sign-in makes the calls.
    func woke() async {
        AppLog.note("device", "woken")
        if !Self.appOpen, backgroundEnds == nil {
            backgroundEnds = .now + .seconds(Self.backgroundSeconds)
        }
        await fetch(fallback: true)
    }

    /// One pass at a time; a call while one runs makes it go round once more (a request may have come meanwhile).
    func fetch(fallback: Bool = false) async {
        if let running {
            again = true
            await running.value
            return
        }
        let task = Task { @MainActor in
            repeat {
                again = false
                await pass(fallback: fallback)
            } while again
        }
        running = task
        await task.value
        running = nil
        backgroundEnds = nil
    }

    /// The time the next request may take: the handler's own, or less when a wake-up's background time is short;
    /// nil when it's too short to start another (back on screen, there's no limit but the handler's).
    private var nextRequestSeconds: Double? {
        guard let backgroundEnds, !Self.appOpen else { return Self.answerSeconds }
        return DeviceAccess.requestSeconds(left: (backgroundEnds - .now) / .seconds(1), each: Self.answerSeconds)
    }

    private func pass(fallback: Bool) async {
        guard let call = await resolvedCall(fallback: fallback) else {
            AppLog.note("device", "no sign-in to answer with")
            return
        }
        let result = await call(route + "/pending", "POST", [:])
        guard result.status == 200 else {
            AppLog.note("device", "pending (\(result.status))")
            return
        }
        let requests = DeviceAccess.requests(result.body)
        // Read again: a launch in the background may come before anything else loaded them.
        settings = DeviceAccess.Settings.load(defaults)
        for request in requests {
            guard let seconds = nextRequestSeconds else {
                AppLog.note("device", "background time short: \(requests.count) asked, the rest wait for the next fetch")
                break
            }
            var answer = await run(request, within: seconds)
            if let file = answer.file {
                // A photo goes up first; the add-on hands the bot its saved copy with the result.
                let body: [String: Any] = ["type": file.type, "name": file.name, "data": file.data.base64EncodedString()]
                let sent = await call(route + "/files/" + request.id, "POST", body)
                if sent.status != 200 { answer = .failed("The photo couldn’t be sent (\(sent.status)).") }
            }
            let sent = await call(route + "/results/" + request.id, "POST", answer.body)
            AppLog.note("device", "\(DeviceAccess.operations[request.op] == nil ? "unknown" : request.op) \(answer.status.rawValue) \(answer.count ?? 0) (\(sent.status))")
            // Audit 09-9: an answer the gateway never got isn't "Answered" in Recent Requests.
            note(request, answer, delivered: sent.status == 200)
        }
    }

    private func run(_ request: DeviceAccess.Request, within seconds: Double) async -> DeviceAccess.Answer {
        switch DeviceAccess.check(request, settings: settings) {
        case .answer(let answer): return answer
        case .run(let kind, let scopes):
            let handler = DeviceAccessHandlers.handler(kind)
            return await Self.within(seconds, late: DeviceAccess.tooLongWords(request.op)) { await handler.answer(request, scopes: scopes) }
        }
    }

    /// The work's answer, or `late` once `seconds` pass (the work is cancelled and its late answer dropped).
    private static func within(_ seconds: Double, late: String,
                               _ work: @escaping @MainActor () async -> DeviceAccess.Answer) async -> DeviceAccess.Answer {
        final class Once {
            private var continuation: CheckedContinuation<DeviceAccess.Answer, Never>?
            nonisolated init(_ continuation: CheckedContinuation<DeviceAccess.Answer, Never>) { self.continuation = continuation }
            var done: Bool { continuation == nil }
            func finish(_ answer: DeviceAccess.Answer) {
                continuation?.resume(returning: answer)
                continuation = nil
            }
        }
        return await withCheckedContinuation { continuation in
            let once = Once(continuation)
            let worker = Task { @MainActor in once.finish(await work()) }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                guard !once.done else { return }
                worker.cancel()
                once.finish(.failed(late))
            }
        }
    }

    /// "" for no bot.
    func botName(_ profile: String) -> String {
        profile.isEmpty ? "" : botNames?(profile) ?? SessionsViewController.readableProfileName(profile)
    }

    private func note(_ request: DeviceAccess.Request, _ answer: DeviceAccess.Answer, delivered: Bool) {
        let entry = DeviceAccess.LogEntry(id: request.id, date: .now, op: request.op, bot: botName(request.bot),
                                          summary: DeviceAccess.describe(request),
                                          status: delivered ? answer.status.rawValue : DeviceAccess.LogEntry.undelivered, count: answer.count)
        recent.removeAll { $0.id == entry.id }
        recent.insert(entry, at: 0)
        if recent.count > 50 { recent.removeLast(recent.count - 50) }
        defaults.set(try? JSONEncoder().encode(recent), forKey: Self.recentKey)
    }

    /// The live sign-in's call; on a wake-up before it exists, one made from the saved sign-in.
    private func resolvedCall(fallback: Bool) async -> PushRegistrar.Call? {
        if let call = PushRegistrar.shared.call { return call }
        guard fallback else { return nil }
        let store = AccountStore()
        guard (try? await store.reloadOffMain()) != nil, let stored = store.storedCurrent else { return nil }
        return { path, method, body in
            let data = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            let answer = await AccountREST.call(stored, method: method, path: path, body: data)
            return (answer.status, answer.data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] })
        }
    }
}
