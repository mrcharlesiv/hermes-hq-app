// More › Messaging's state (docs/spec/3x-morepages.md §12): one bot's platforms and the people who may message it,
// shared by the list and a platform's page. Writes are sent at once; a switch is flipped first and rolled back with
// an alert when the gateway refuses. A change the gateway does not serve hot raises the restart notice.
// A key's value passes through `saveKey` to the PUT body and is kept nowhere.

import Observation
import SwiftUI
import UIKit

@MainActor @Observable
final class MessagingModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    enum TestState: Equatable {
        case running
        case done(MessagingTestResult)
    }

    @ObservationIgnored let context: MorePages.Context
    @ObservationIgnored let api: MessagingAPI
    @ObservationIgnored let actions: GatewayActionsAPI
    @ObservationIgnored weak var host: UIViewController?
    /// The page on top (a platform's page), for its alerts.
    @ObservationIgnored weak var front: UIViewController?

    private(set) var phase: Phase = .loading
    /// [mac-audit] Owner 2026-11-02 (#21): this Hermes has no Messaging ("Not Available on This Hermes"). On the Mac
    /// the page then shows the state alone: no Bot picker and no search over a page with nothing to pick or search.
    var isUnavailable: Bool { if case .failed(let reason) = phase { return reason == MoreWire.olderHermes } else { return false } }
    private(set) var platforms: [MessagingPlatform] = []
    private(set) var available: [MessagingCatalogPlatform] = []
    private(set) var pairing = MessagingPairing()
    private(set) var online: Bool
    /// Writes on their way: "platform:<id>", "person:<id>".
    private(set) var busy: Set<String> = []
    private(set) var installingCatalog: Set<String> = []
    private(set) var tests: [String: TestState] = [:]
    private(set) var restartPending: Set<String> = []
    private(set) var restartNeeded = false
    private(set) var restartReasons: [String: String] = [:]
    private(set) var credentialsHints: [String: String] = [:]
    let restart: GatewayActionRun
    var query = ""
    var profile: String {
        didSet {
            guard profile != oldValue else { return }
            MoreBotChoice.save(profile, page: "messaging", context: context)
            platforms = []
            available = []
            pairing = MessagingPairing()
            tests = [:]
            // Audit 863 (08d-2): the last bot's writes still on their way drop their answer: their busy marks go too
            // (the keys, "platform:telegram", are the same on every bot).
            busy = []
            installingCatalog = []
            restartPending = []
            restartNeeded = false
            restartReasons = [:]
            credentialsHints = [:]
            restart.reset()
            phase = .loading
            reload()
        }
    }

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var linkTask: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var firstRead = true

    init(context: MorePages.Context) {
        self.context = context
        api = MessagingAPI(client: context.client)
        actions = GatewayActionsAPI(client: context.client)
        restart = GatewayActionRun(api: actions)
        online = context.isOnline
        profile = MoreBotChoice.read("messaging", context: context)
        restart.onFinish = { [weak self] ok in
            guard let self else { return }
            if ok {
                PagesHaptics.success()
                self.restartPending = []
                self.restartNeeded = false
                self.restartReasons = [:]
            } else {
                PagesHaptics.error()
            }
            self.reload()
        }
    }

    var readOnly: Bool { context.readOnly || MessagingPages.debugReadOnly }
    var canWrite: Bool { !readOnly && online }
    var showsBotPicker: Bool { context.botChoices.count > 1 }
    var botName: String { context.botName(profile) }
    // Item 22: the app with a problem leads, since Status & Maintenance's "1 Issue" sends people here to fix it — error,
    // then needs setup, then connected, then off; alphabetical within each group.
    var shown: [MessagingPlatform] {
        platforms.filter { $0.matches(query) }.sorted { a, b in
            let ra = a.status.tone.sortRank, rb = b.status.tone.sortRank
            if ra != rb { return ra < rb }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
    var shownAvailable: [MessagingCatalogPlatform] {
        available.filter { $0.matches(query) }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    func platform(_ id: String) -> MessagingPlatform? { platforms.first { $0.id == id } }
    func isBusy(_ key: String) -> Bool { busy.contains(key) }
    var showsRestartNotice: Bool { !readOnly && (restartNeeded || restart.phase != .idle) }
    var restartNoticeText: String { restartNoticeText(for: nil) }

    func restartNoticeText(for platformId: String?) -> String {
        let reason: String? = if let platformId {
            restartReasons[platformId] ?? restartReasons.values.first
        } else {
            restartReasons.values.first
        }
        if let reason, !reason.isEmpty {
            return "Restart your gateway to use this change (\(reason))."
        }
        return "Restart your gateway to use this change."
    }

    func credentialsHint(for platformId: String) -> String? { credentialsHints[platformId] }

    private func recordLiveApply(_ platformId: String, _ result: MessagingUpdateResult) {
        if result.needsCredentials {
            restartPending.remove(platformId)
            restartReasons[platformId] = nil
            let detail = result.restartDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
            credentialsHints[platformId] = (detail?.isEmpty == false ? detail : nil) ?? "Add the required credentials below to finish setup."
        } else if result.appliedLive {
            restartPending.remove(platformId)
            restartReasons[platformId] = nil
            credentialsHints[platformId] = nil
        } else {
            restartPending.insert(platformId)
            restartReasons[platformId] = result.restartDetail
            credentialsHints[platformId] = nil
        }
        restartNeeded = !restartPending.isEmpty
    }

    // MARK: Reading

    /// The page came on screen: read (again), and follow the link and `platforms.changed` events.
    func appear() {
        if linkTask == nil {
            let client = context.client
            linkTask = Task { [weak self] in
                var wasReady: Bool?
                for await state in client.connectionStates() {
                    guard let self else { return }
                    let ready = state == .ready
                    self.online = ready
                    if ready, wasReady == false { self.reload() }
                    wasReady = ready
                }
            }
        }
        if eventsTask == nil {
            let client = context.client
            let stream: AsyncStream<GatewayEvent> = (client as? LiveGatewayClient)?.events(matching: ["platforms.changed"]) ?? client.events()
            eventsTask = Task { [weak self] in
                for await event in stream {
                    guard let self else { return }
                    if event.type == "platforms.changed" { self.reload() }
                }
            }
        }
        reload()
    }

    func disappear() {
        linkTask?.cancel()
        linkTask = nil
        eventsTask?.cancel()
        eventsTask = nil
    }

    func reload() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.read() }
    }

    /// Pull to refresh waits for the answer.
    func refresh() async {
        loadTask?.cancel()
        let task = Task { [weak self] in await self?.read() ?? () }
        loadTask = task
        await task.value
    }

    private func read() async {
        generation += 1
        let mine = generation, profile = profile, api = api
        async let people = try? api.pairing(profile: profile)
        do {
            let page = try await api.platformsPage(profile: profile)
            let pairs = await people
            guard mine == generation, !Task.isCancelled else { return }
            if firstRead { firstRead = false; MorePages.noteRead("messaging", error: nil) }
            platforms = page.platforms
            available = page.available
            if profile == "default" { MorePages.noteMessaging(page.platforms, account: context.account) }   // More's row
            if let pairs { pairing = pairs }
            phase = .loaded
        } catch {
            _ = await people
            guard mine == generation, !Task.isCancelled else { return }
            if firstRead, MorePages.noteRead("messaging", error: error) {
                phase = .failed(MoreWire.olderHermes)
                return
            }
            // A page that has shown data keeps showing it.
            if platforms.isEmpty, available.isEmpty { phase = .failed(PagesREST.reason(error)) }
        }
    }

    // MARK: Catalog install (v0.23.5)

    func askInstallCatalog(_ item: MessagingCatalogPlatform) {
        guard canWrite, !installingCatalog.contains(item.name) else { return }
        if item.isBlocked {
            let reason = item.blockedReason.isEmpty ? "Install is blocked by gateway policy." : item.blockedReason
            let detail = item.installCommand.isEmpty ? nil : "Run in a terminal:\n\(item.installCommand)"
            FailureAlert.present(title: "Can’t Install \(item.title) Here", reason: reason, detail: detail, from: front ?? host)
            return
        }
        var lines: [String] = []
        if !item.summary.isEmpty { lines.append(item.summary) }
        if !item.disclosure.isEmpty { lines.append(item.disclosure) }
        lines.append("Hermes will install and enable this plugin for \(botName). This can take a minute.")
        TextPrompt.confirmPlain(title: "Install \(item.title)?",
                                message: lines.joined(separator: "\n\n"),
                                action: "Install", from: front ?? host) { [weak self] in
            self?.runInstallCatalog(item)
        }
    }

    private func runInstallCatalog(_ item: MessagingCatalogPlatform) {
        guard canWrite, !installingCatalog.contains(item.name) else { return }
        installingCatalog.insert(item.name)
        let profile = profile, api = api
        Task {
            defer { installingCatalog.remove(item.name) }
            do {
                let result = try await api.installCatalog(item.name, profile: profile)
                guard profile == self.profile else { return }
                if result.ok {
                    PagesHaptics.success()
                    await refresh()
                    if let host = front ?? host {
                        PagesHUD.show("\(item.title) Installed",
                                      detail: result.warnings.first,
                                      symbol: "checkmark", from: host)
                    }
                    if let firstId = result.platforms.first, let installed = platform(firstId), front == nil {
                        MessagingPages.open(installed, model: self)
                    }
                } else {
                    PagesHaptics.error()
                    let reason = result.error ?? "The gateway refused the install."
                    let cmd = result.installCommand ?? (item.installCommand.isEmpty ? nil : item.installCommand)
                    let detail = cmd.map { "Run in a terminal:\n\($0)" }
                    FailureAlert.present(title: "Couldn’t Install \(item.title)", reason: reason, detail: detail, from: front ?? host)
                }
            } catch {
                guard profile == self.profile else { return }
                PagesHaptics.error()
                FailureAlert.present(title: "Couldn’t Install \(item.title)", reason: PagesREST.reason(error), from: front ?? host)
            }
        }
    }

    // MARK: On / off

    func setEnabled(_ id: String, _ on: Bool) {
        guard canWrite, let index = platforms.firstIndex(where: { $0.id == id }), platforms[index].enabled != on,
              !busy.contains("platform:\(id)") else { return }
        let name = platforms[index].name
        platforms[index].enabled = on
        busy.insert("platform:\(id)")
        PagesHaptics.selection()
        let profile = profile, api = api
        Task {
            do {
                let result = try await api.updateWithLive(id, body: MessagingBodies.enabled(on), profile: profile)
                guard profile == self.profile else { return }
                busy.remove("platform:\(id)")
                recordLiveApply(id, result)
                reload()
            } catch {
                guard profile == self.profile else { return }
                busy.remove("platform:\(id)")
                if let index = platforms.firstIndex(where: { $0.id == id }) { platforms[index].enabled = !on }
                FailureAlert.present(title: on ? "Couldn’t Turn On \(name)" : "Couldn’t Turn Off \(name)",
                                     reason: PagesREST.reason(error), from: front ?? host)
            }
        }
    }

    // MARK: Keys

    /// `PUT {"env":{KEY:value}}`. The value is not kept: the row reads "Set" from the next read.
    func saveKey(_ platform: String, _ key: String, _ value: String) async throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PagesMessageError("Type a value first.") }
        guard online else { throw PagesMessageError(MorePages.offlineFooter) }
        let result = try await api.updateWithLive(platform, body: MessagingBodies.env(key, trimmed), profile: profile)
        AppLog.note("messaging", "key saved")
        recordLiveApply(platform, result)
        await refresh()
    }

    /// `PUT {"clear_env":[KEY]}`.
    func removeKey(_ platform: String, _ key: String) async throws {
        guard online else { throw PagesMessageError(MorePages.offlineFooter) }
        let result = try await api.updateWithLive(platform, body: MessagingBodies.clear(key), profile: profile)
        AppLog.note("messaging", "key removed")
        recordLiveApply(platform, result)
        await refresh()
    }

    // MARK: Test

    func test(_ id: String) {
        guard !readOnly, tests[id] != .running else { return }
        tests[id] = .running
        let profile = profile, api = api
        Task {
            let result: MessagingTestResult
            do { result = try await api.test(id, profile: profile) } catch {
                result = MessagingTestResult(ok: false, message: PagesREST.reason(error))
            }
            guard profile == self.profile else { return }
            tests[id] = .done(result)
            result.ok ? PagesHaptics.success() : PagesHaptics.error()
        }
    }

    // MARK: Who can message this bot

    func approve(_ person: PairingPerson) {
        guard canWrite, let request = person.requestId, !busy.contains("person:\(person.id)") else { return }
        busy.insert("person:\(person.id)")
        let profile = profile, api = api
        Task {
            do {
                try await api.approve(platform: person.platform, requestId: request, profile: profile)
                guard profile == self.profile else { return }
                busy.remove("person:\(person.id)")
                // Moved at once; the next read confirms it.
                pairing.pending.removeAll { $0.id == person.id }
                if !pairing.approved.contains(where: { $0.id == person.id }) {
                    pairing.approved.append(PairingPerson(platform: person.platform, userId: person.userId, userName: person.userName))
                }
                PagesHaptics.success()
                reload()
            } catch {
                guard profile == self.profile else { return }
                busy.remove("person:\(person.id)")
                FailureAlert.present(title: "Couldn’t Approve \(person.name)", reason: PagesREST.reason(error), from: front ?? host)
                reload()
            }
        }
    }

    /// Remove asks first.
    func askRemove(_ person: PairingPerson) {
        guard canWrite else { return }
        TextPrompt.confirm(title: "Remove \(person.name)?",
                           message: "They won’t be able to message this bot until you approve them again.",
                           action: "Remove", from: front ?? host) { [weak self] in self?.remove(person) }
    }

    private func remove(_ person: PairingPerson) {
        guard canWrite, !busy.contains("person:\(person.id)") else { return }
        busy.insert("person:\(person.id)")
        let profile = profile, api = api
        Task {
            do {
                try await api.revoke(platform: person.platform, userId: person.userId, profile: profile)
                guard profile == self.profile else { return }
                busy.remove("person:\(person.id)")
                pairing.approved.removeAll { $0.id == person.id }
                PagesHaptics.success()
                reload()
            } catch {
                guard profile == self.profile else { return }
                busy.remove("person:\(person.id)")
                FailureAlert.present(title: "Couldn’t Remove \(person.name)", reason: PagesREST.reason(error), from: front ?? host)
            }
        }
    }

    // MARK: Restart

    func askRestart() {
        guard canWrite, !restart.isBusy else { return }
        let profile = profile, actions = actions
        GatewayRestart.confirm(from: front ?? host) { [weak self] in
            self?.restart.start { try await actions.restart(profile: profile) }
        }
    }

    // MARK: Telegram

    func telegramSetup() -> TelegramSetup {
        let profile = profile, api = api
        return TelegramSetup(calls: .init(
            start: { try await api.telegramStart(botName: nil, profile: profile) },
            status: { try await api.telegramStatus($0, profile: profile) },
            apply: { try await api.telegramApply($0, allowed: $1, profile: profile) },
            cancel: { try await api.telegramCancel($0, profile: profile) }))
    }

    func telegramApplied(_ applied: TelegramSetupApplied, for flowProfile: String) {
        guard flowProfile == profile else { return }
        if applied.needsRestart && !applied.restartStarted { restartNeeded = true }
        PagesHaptics.success()
        if let host = front ?? host {
            PagesHUD.show(applied.restartStarted ? "Telegram Saved" : "Telegram Connected",
                          detail: applied.restartStarted ? "Your gateway is restarting." : nil, symbol: "checkmark", from: host)
        }
        reload()
        if applied.restartStarted {
            // The gateway restarts on its own: read again once it has had a moment (`V/app/webhooks/index.tsx:178`).
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                self?.reload()
            }
        }
    }
}
