// Remote notifications through the gateway's hermes-hq-push plugin (port of the web app's HermesPush, build 240). The
// plugin is optional: without it (404 on both names) local alerts keep working. One registration at a time, for the
// signed-in account only (push comes from one gateway: a switch removes this device from the gateway left). State keeps
// the web app's UserDefaults keys, so an update from it carries over. Never logs tokens, keys or alert text: AppLog gets
// content-free breadcrumbs only.

import UIKit
import UserNotifications

@MainActor final class PushRegistrar {
    static let shared = PushRegistrar()

    typealias Call = @MainActor (_ path: String, _ method: String, _ body: [String: Any]?) async -> (status: Int, body: [String: Any]?)

    /// Authenticated gateway call for the signed-in account; nil while nobody is signed in. 0 = no answer.
    var call: Call?
    /// The signed-in account (PushPolicy.owner), set after each sign-in and cleared on sign-out.
    private(set) var owner: String?
    /// Asked by Settings (`pluginState`) and the setup offer; the latest answer.
    private(set) var lastPluginState: PushPolicy.PluginState = .unknown
    /// [live-steps] The signed-in gateway's add-on pushes a reply's steps to its Lock Screen card (0.9.22's `liveSteps`).
    private(set) var liveStepsOffered = false
    /// [task-ideas] The last status read said the add-on serves Ideas (0.9.39+).
    private(set) var taskIdeasServed = false
    var onStateChange: (() -> Void)?
    /// Posted after each registration attempt: an open Notifications page reads the plugin and "On" again (the setup
    /// can finish in the background, after the bot installed the add-on, while the page shows "Add-on Needed").
    nonisolated static let didRegister = Notification.Name("HQPushDidRegister")

    private let defaults: UserDefaults
    private var epoch = UUID()
    private var ledger: PushLedger
    private var answers: PushAnswers
    private var routes: [String: String]
    private var legacyStatus = false
    private var absentUntil = Date.distantPast
    private var token: String?
    private var tokenWaiters: [CheckedContinuation<String?, Never>] = []
    private var syncing = false, syncAgain = false, removing = false, putting = false
    /// A registration asked for while a removal ran (a switch whose DELETE outlived its 4 s): it runs once that ends.
    private var registerAfterRemoval = false
    private var putWaiters: [CheckedContinuation<Void, Never>] = []
    private var flushing = false, flushAgain = false
    /// A registration that couldn't reach the gateway while it may hold this device: retried when the app is next opened.
    private(set) var retry = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ledger = PushLedger.decode(defaults.data(forKey: "hermes.push.ledger"), legacy: defaults.bool(forKey: "hermes.push.registered"))
        answers = PushAnswers.decode(defaults.data(forKey: "hermes.push.answers"))
        routes = defaults.dictionary(forKey: "hermes.push.routes") as? [String: String] ?? [:]
    }

    // MARK: Identity

    /// Push can reach this build at all: the original App Store identity (the relay and the plugin take only its topic).
    /// DEBUG: `-HQDebugPushAnyTopic YES` lets a fixture plugin register the native identity too.
    static var available: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "HQDebugPushAnyTopic") { return true }
        #endif
        return AppIdentity.current.canPush
    }

    func setOwner(_ owner: String?) {
        guard owner != self.owner else { return }
        self.owner = owner
        epoch = UUID(); absentUntil = .distantPast; legacyStatus = false; lastPluginState = .unknown
        if let owner { ledger.adopt(owner); ledger.switchTo(owner); save() }
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(ledger), forKey: "hermes.push.ledger")
        defaults.set(try? JSONEncoder().encode(answers), forKey: "hermes.push.answers")
        defaults.removeObject(forKey: "hermes.push.registered")
    }

    /// Registered with this account's gateway for at least one kind: local copies of those kinds would duplicate pushes.
    var active: Bool { owner != nil && ledger.owner == owner && !ledger.kinds.isEmpty }
    func delivers(_ kind: String) -> Bool { active && PushPolicy.delivers(kind, kinds: ledger.kinds) }
    /// The account an alert's answer may go to (nil: none here).
    func sender(_ tag: String?) -> String? { ledger.sender(tag) }

    private func remember(_ route: String, for account: String) {
        guard routes[account] != route else { return }
        routes[account] = route
        if routes.count > 32 { routes = [account: route] }
        defaults.set(routes, forKey: "hermes.push.routes")
    }

    private func probe(_ call: Call, account: String) async -> (status: Int, body: [String: Any]?) {
        var result = await call(PushPolicy.route + "/status", "GET", nil)
        var legacy = false
        if result.status == 404 {
            let old = await call(PushPolicy.legacyRoute + "/status", "GET", nil)
            if old.status != 404 { result = old; legacy = old.status == 200 }
        }
        if result.status == 200 { remember(legacy ? PushPolicy.legacyRoute : PushPolicy.route, for: account) }
        legacyStatus = legacy
        // [drafts] An add-on with draft_message gives it to bots only once an app that draws the card says so.
        if result.status == 200, !legacy, DraftCards.cardsUntold(result.body) {
            let told = await call(PushPolicy.route + DraftCards.cardsPath, "PUT", nil)
            AppLog.note("drafts", "told the add-on this app draws draft cards (\(told.status))")
        }
        return result
    }

    private func send(_ call: Call, account: String, _ path: String, _ method: String, _ body: [String: Any]?) async -> (status: Int, body: [String: Any]?) {
        var result: (status: Int, body: [String: Any]?) = (0, nil)
        for route in PushPolicy.routes(preferring: routes[account]) {
            result = await call(route + path, method, body)
            if result.status != 404 {
                if result.status != 0 { remember(route, for: account) }
                return result
            }
        }
        return result
    }

    static var deviceID: String { UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device" }
    private var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    // MARK: APNs token

    func received(token data: Data) {
        token = data.map { String(format: "%02x", $0) }.joined()
        AppLog.note("push", "apns token")
        finishTokenWait()
    }

    func failed() {
        AppLog.note("push", "apns registration failed")
        finishTokenWait()
    }

    private func finishTokenWait() {
        let waiters = tokenWaiters
        tokenWaiters.removeAll()
        waiters.forEach { $0.resume(returning: token) }
    }

    private func deviceToken() async -> String? {
        if let token { return token }
        #if DEBUG && targetEnvironment(simulator)
        // A simulator build without the push entitlement gets no APNs token; fixtures never send to Apple.
        if let fixture = ProcessInfo.processInfo.environment["HQN_APNS_TOKEN"], !fixture.isEmpty { return fixture }
        #endif
        UIApplication.shared.registerForRemoteNotifications()
        return await withCheckedContinuation { continuation in
            tokenWaiters.append(continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self, !self.tokenWaiters.isEmpty else { return }
                self.finishTokenWait()
            }
        }
    }

    // MARK: Register / unregister

    /// After sign-in, and whenever permission or preferences change. Saved answers go first.
    func sync() {
        Task { @MainActor in
            await flush()
            guard !syncing else { syncAgain = true; return }
            syncing = true
            repeat { syncAgain = false; await register() } while syncAgain
            syncing = false
        }
    }

    /// Sign-out (after `unregister`): the ledger keeps what is still owed.
    /// Audit 14-1: the account is gone from this phone, so its seal key and faces go too (as `forget`): an alert its
    /// gateway still pushes, because the removal didn't get through, shows only "New notification", with no words and
    /// no Approve, instead of a signed-out phone reading its alerts.
    func clear() {
        if let owner {
            PushSealKeys.remove(owner)
            PushFaces.remove(account: owner)
        }
        owner = nil; epoch = UUID(); answers = PushAnswers(); ledger.clear(); save(); retry = !ledger.owed.isEmpty
        lastPluginState = .unknown
    }

    /// What iOS allows (tests supply their own).
    var isAuthorized: @MainActor () async -> Bool = {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }
    /// Filter › Show › Outside Chats for the signed-in account: with Settings › Notifications › Outside Chats (on unless
    /// turned off) the plugin (0.9+) alerts replies and approvals from chats in Telegram, Discord and the other apps too.
    /// An older plugin drops the kind.
    var outsideChats: @MainActor () -> Bool = { false }
    /// Tests: push available whatever the build's identity.
    var availableOverride: Bool?
    private var canPush: Bool { availableOverride ?? Self.available }

    /// One registration pass (`sync` runs it after saved answers; tests call it directly).
    func register() async {
        guard !removing else { registerAfterRemoval = true; return }
        guard canPush, let call, let owner else { return }
        let admitted = epoch
        let authorized = await isAuthorized()
        guard epoch == admitted else { return }
        guard authorized, NotificationPrefs.load(defaults).enabled else { return await unregister() }
        guard Date() >= absentUntil else { retry = ledger.needsRemoval(owner); return }
        let status = await probe(call, account: owner)
        guard epoch == admitted else { return }
        lastPluginState = PushPolicy.pluginState(status: status.status, body: status.body, legacy: legacyStatus)
        liveStepsOffered = status.status == 200 && PushPolicy.liveSteps(status.body)
        onStateChange?()
        guard status.status == 200 else {
            absentUntil = Date().addingTimeInterval(600); ledger.unavailable(); save(); retry = ledger.needsRemoval(owner)
            AppLog.note("push", "plugin absent (\(status.status))")
            return
        }
        ledger.advertised(PushPolicy.kinds(status.body)); save()
        guard let token = await deviceToken() else { retry = ledger.needsRemoval(owner); return }
        guard epoch == admitted else { return }
        let prefs = NotificationPrefs.load(defaults)
        let kinds = PushPolicy.enabledKinds(status.body, preferences: prefs.kinds)
        var asked = Dictionary(uniqueKeysWithValues: ["turnDone", "approval"].map { ($0, kinds.contains($0)) })
        asked["outside"] = outsideChats() && prefs.kinds["outside"] != false
        if PushPolicy.kinds(status.body).contains("input") { asked["input"] = kinds.contains("input") }   // [prompt-alerts]
        var body: [String: Any] = ["token": token, "environment": environment, "topic": Bundle.main.bundleIdentifier ?? "",
                                   "account": owner, "profile": "*", "kinds": asked,
                                   "previews": prefs.previews]
        if PushPolicy.seals(status.body), let key = PushSealKeys.key(for: owner) { body["seal"] = key.base64EncodedString() }
        ledger.attempt(owner); save()
        putting = true
        let result = await send(call, account: owner, "/devices/" + Self.deviceID, "PUT", body)
        putting = false
        let waiters = putWaiters; putWaiters.removeAll(); waiters.forEach { $0.resume() }
        guard epoch == admitted else { return }
        if result.status == 200 { ledger.registered(owner, kinds: kinds); save() }
        retry = result.status != 200
        AppLog.note("push", result.status == 200 ? "registered" : "registration failed (\(result.status))")
        onStateChange?()
        NotificationCenter.default.post(name: Self.didRegister, object: nil)
    }

    /// Is the signed-in gateway's plugin one this build can use? Asked whatever the settings are (the setup offer and
    /// Settings ask before alerts are on). "ready" registers at once: a plugin a bot just installed is used without a relaunch.
    func pluginState() async -> (state: PushPolicy.PluginState, themes: Bool, restartGuard: Bool) {
        guard let call, let owner else { return (.unknown, false, false) }
        let status = await probe(call, account: owner)
        guard owner == self.owner else { return (.unknown, false, false) }
        let state = PushPolicy.pluginState(status: status.status, body: status.body, legacy: legacyStatus)
        lastPluginState = state
        liveStepsOffered = status.status == 200 && PushPolicy.liveSteps(status.body)
        taskIdeasServed = status.status == 200 && PushPolicy.taskIdeas(status.body)
        if state != .unknown { absentUntil = .distantPast }
        if state == .ready, !active { sync() }
        onStateChange?()
        return (state, PushPolicy.desktopThemes(status.body), PushPolicy.restartGuard(status.body))
    }

    /// Sign-out, a gateway switch or notifications turned off: stop this gateway pushing to the device.
    func unregister() async {
        epoch = UUID(); absentUntil = .distantPast
        guard let owner, ledger.needsRemoval(owner) else { retry = false; return }
        let admitted = epoch
        // This gateway's call, taken now: a switch made while an older PUT finishes sets the next gateway's.
        let call = self.call
        removing = true
        defer { removing = false }
        ledger.removal(owner, status: 0); save(); retry = true
        // An older PUT must finish before DELETE, or it could register this device again.
        if putting { await withCheckedContinuation { putWaiters.append($0) } }
        guard let call else { registerAfterRemovalIfAsked(); return }
        let result = await send(call, account: owner, "/devices/" + Self.deviceID, "DELETE", nil)
        // Audit 14-1: the answer is kept even when it came after the sign-out or switch that asked for it (their 4 s
        // budget ends first on a slow connection): a removal that went through is no longer owed. No registration ran
        // meanwhile (`removing` holds it), so nothing newer is undone.
        ledger.removal(owner, status: result.status); save()
        AppLog.note("push", "unregistered (\(result.status))")
        guard epoch == admitted else { registerAfterRemovalIfAsked(); return }
        retry = ledger.needsRemoval(owner)
        onStateChange?()
        registerAfterRemovalIfAsked()
    }

    private func registerAfterRemovalIfAsked() {
        guard registerAfterRemoval else { return }
        registerAfterRemoval = false
        Task { @MainActor in
            // After `removing` is false (this runs once the removal's `defer` has).
            self.sync()
        }
    }

    /// Accounts that still owe a removal, other than the one in use.
    var owedRemovals: [String] { ledger.owed.filter { $0 != owner } }
    func owesRemoval(_ account: String) -> Bool { ledger.needsRemoval(account) }

    /// A saved account removed from this phone (not the one in use): its answers, seal key and faces go; an owed removal
    /// is settled through `call`, a request made with that account's own session.
    func forget(_ account: String, call: Call?) async {
        answers.drop(owner: account); save()
        PushSealKeys.remove(account)
        PushFaces.remove(account: account)
        guard let call else { return }
        await removeDevice(from: account, call: call)
    }

    /// A gateway this phone left without its client (Add Gateway signed in elsewhere first): its owed removal is sent
    /// now through `call`, a request with that account's own session. Returns the DELETE's status (0: none needed or no
    /// answer: still owed, retried when that account is signed in again).
    @discardableResult
    func removeDevice(from account: String, call: Call) async -> Int {
        guard account != owner, ledger.needsRemoval(account) else { return 0 }
        let result = await send(call, account: account, "/devices/" + Self.deviceID, "DELETE", nil)
        ledger.removal(account, status: result.status); save()
        AppLog.note("push", "left a gateway (\(result.status))")
        return result.status
    }

    // MARK: Approve / Deny from an alert

    func withdraw(_ request: String) { answers.settle(request); save() }

    func flush() async {
        guard !flushing else { flushAgain = true; return }
        flushing = true; flushAgain = false
        defer {
            flushing = false
            if flushAgain { Task { @MainActor in await self.flush() } }
        }
        for answer in answers.pending {
            guard answers.pending.contains(answer) else { continue }
            let decision = answers.decision(answer, owner: owner, ready: call != nil, now: Date())
            if decision == .waiting { continue }
            if decision == .expired || decision == .stale {
                save()
                await failure(answer.request, session: answer.session, outcome: decision, about: About(answer)); continue
            }
            guard let call else { continue }
            let result = await send(call, account: answer.owner, "/approvals/" + answer.request, "POST",
                                    ["session_key": answer.sessionKey, "choice": answer.choice, "token": answer.token])
            guard answers.pending.contains(answer) else { continue }
            let resolved = (result.body?["resolved"] as? NSNumber)?.intValue
            let outcome = answers.result(answer, status: result.status, resolved: resolved)
            save()
            AppLog.note("push", "approval answer \(outcome.rawValue)")
            if outcome == .answered {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notice(answer.request)])
                // UX study #258: answered from the banner while the app is in front, the brief HUD a local alert's answer
                // gets says it went. In the background nothing more: the alert going away is the system's confirmation.
                if UIApplication.shared.applicationState == .active, let window = MainTabController.current?.view.window {
                    MenusHUD.show(LocalApprovalWords.sent(approve: answer.choice != "deny"), in: window)
                }
            } else if outcome == .failed {
                await failure(answer.request, session: answer.session, outcome: outcome, resolved: result.status == 200 && resolved == 0,
                              about: About(answer))
            }
        }
    }

    /// One alert per request about its answer: a later outcome replaces "not sent yet", a sent answer removes it.
    static func notice(_ request: String) -> String { "answer-failed-" + request }

    /// `command`: what the alert showed, quoted so the person knows which request this is (UX study #260); "" for none.
    nonisolated static func failureWords(_ outcome: PushAnswers.Outcome, resolved: Bool, command: String = "",
                             app: String = AppIdentity.current.displayName) -> String {
        let quoted = command.isEmpty ? nil : "“\(command)”"
        switch outcome {
        case .waiting: return quoted.map { "Your answer to \($0) hasn’t been sent yet. Open \(app) to send it." }
            ?? "Your answer hasn’t been sent yet. Open \(app) to send it."
        case .expired: return quoted.map { "Couldn’t answer \($0) in time. Open \(app) to review it." }
            ?? "Couldn’t answer that request in time. Open \(app) to review it."
        case .stale: return Self.otherGatewayWords
        default:
            if resolved {
                return quoted.map { "The request to run \($0) was already answered or had expired. Open \(app) to review it." }
                    ?? "That request was already answered or had expired. Open \(app) to review it."
            }
            return quoted.map { "Your answer to \($0) wasn’t sent. Open \(app) to review it." }
                ?? "Couldn’t answer that request. Open \(app) to review it."
        }
    }

    /// An answer to an alert from a gateway this phone has switched away from (UX study #262): it belongs there. Two or
    /// more gateways are saved then, so the page is "Gateways".
    nonisolated static let otherGatewayWords = "That alert came from a gateway you’ve switched away from, so it can’t be answered here. Switch back to it in Settings › Gateways."
    /// A tapped alert from a gateway no saved gateway here matches (removed since): its chat can't open.
    nonisolated static let otherGatewayChatWords = "That alert came from a gateway you’re no longer using, so its chat can’t open here."

    /// Who and what a follow-up alert names (UX study #260): the bot, the command its alert showed, the bot's profile
    /// (the tap opens that bot's chat, and the alert groups under its thread).
    struct About: Sendable {
        var who = "", command = "", profile = ""
        init(who: String = "", command: String = "", profile: String = "") { self.who = who; self.command = command; self.profile = profile }
        init(_ answer: PushAnswers.Answer) { self.init(who: answer.who ?? "", command: answer.command ?? "", profile: answer.profile ?? "") }
    }

    private func failure(_ request: String, session: String, outcome: PushAnswers.Outcome = .failed, resolved: Bool = false,
                         about: About = About()) async {
        await notify(request, session: session, about: about,
                     body: Self.failureWords(outcome, resolved: resolved, command: about.command))
    }

    /// An Approve on an alert that showed no command is never sent; this says so instead.
    func unseenApproval(_ request: String, session: String, about: About = About()) async {
        await notify(request, session: session, about: about,
                     body: "Not approved: that alert couldn’t show the command. Open \(AppIdentity.current.displayName) to review it.")
    }

    /// The follow-up alert: titled with the bot when known (else the app), in the chat's thread.
    private func notify(_ request: String, session: String, about: About, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = about.who.isEmpty ? AppIdentity.current.displayName : about.who
        content.body = body
        var info: [String: Any] = ["session": session]
        if !about.profile.isEmpty { info["profile"] = about.profile }
        content.userInfo = info
        if NotificationRules.valid(session) { content.threadIdentifier = session }
        let id = PushPolicy.validRequest(request) ? Self.notice(request) : UUID().uuidString
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// An Approve/Deny tapped on a pushed alert. The token binds the answer to that one request; it goes only to the
    /// account whose registration the alert came from. Returns within about 20 s (a background launch is short).
    func answer(_ remote: [String: Any], choice: String, about: About = About()) async {
        let request = remote["request"] as? String ?? "", session = remote["session"] as? String ?? ""
        guard let key = remote["sessionKey"] as? String, let token = remote["token"] as? String, PushPolicy.validRequest(request) else {
            await failure(request, session: session, about: about); return
        }
        guard let owner = ledger.sender(remote["account"] as? String) else {
            // "Another gateway" only when the alert's tag names one other than this phone's: signed out, or an older
            // plugin's untagged alert while the registration is unsettled, gets the plain words.
            let tag = remote["account"] as? String, holder = ledger.owner ?? ledger.candidate
            let other = tag != nil && holder != nil && tag != holder
            AppLog.note("push", "approval answer not sent: \(other ? "other gateway" : "no sender")")
            await failure(request, session: session, outcome: other ? .stale : .failed, about: about); return
        }
        let outcome = answers.enqueue(.init(request: request, sessionKey: key, token: token, session: session, choice: choice,
                                            owner: owner, tappedAt: Date(), who: about.who, command: about.command,
                                            profile: about.profile))
        AppLog.trace("push", "approval answer enqueue: \(outcome.rawValue)")
        if outcome == .queued { save() }
        if call != nil {
            Task { @MainActor in await self.flush() }
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            while answers.pending.contains(where: { $0.request == request }), ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        if answers.pending.contains(where: { $0.request == request }), UIApplication.shared.applicationState != .active {
            await failure(request, session: session, outcome: .waiting, about: about)
        }
    }

    #if DEBUG
    var debugState: [String: String] {
        ["owner": owner == nil ? "none" : "set", "active": active ? "yes" : "no", "plugin": lastPluginState.rawValue,
         "pending": String(answers.pending.count)]
    }
    #endif
}

// MARK: - [live-steps] A reply's Lock Screen card, kept live by the add-on

extension PushRegistrar: LiveStepsRelay {
    /// The add-on gets the card's push token (and a new one when iOS changes it). Only when this device is registered
    /// with the signed-in gateway and its add-on says it can (`liveSteps`); the add-on refuses a device it doesn't know.
    /// Never logs the token or the steps.
    func handOverSteps(_ start: LiveStepsHandOver) async {
        guard canPush, let call, let owner, liveStepsOffered, NotificationPrefs.load(defaults).enabled else { return }
        let trail: [String: Any] = ["step": start.trail.step ?? NSNull(), "recent": start.trail.recent, "steps": start.trail.steps]
        let body: [String: Any] = ["token": start.token, "profile": start.profile, "session": start.session ?? "",
                                   "startedAt": start.startedAt.timeIntervalSinceReferenceDate, "trail": trail]
        let result = await send(call, account: owner, "/live/" + Self.deviceID + "/" + start.activity, "PUT", body)
        AppLog.note("live", "steps handed to the add-on (\(result.status))")
    }

    /// The card ended here: the add-on stops pushing to it (it also drops it when the turn ends, or after 8 h).
    func withdrawSteps(_ activity: String) async {
        guard canPush, let call, let owner, liveStepsOffered else { return }
        let result = await send(call, account: owner, "/live/" + Self.deviceID + "/" + activity, "DELETE", nil)
        AppLog.note("live", "steps withdrawn (\(result.status))")
    }
}
