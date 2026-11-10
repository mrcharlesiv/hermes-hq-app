// [update-flow] One Update sheet for Hermes, everywhere it can be updated: Status & Maintenance's Update Hermes row,
// Settings › Gateways' rows, a Nous agent's page and panel, and the "Update Hermes" page after a sign-in. Owner
// 2026-11-05: Command Center › Update Hermes updated the Studio gateway when he meant a Nous agent, then sat silently
// for ~30 min while Hermes waited for bots to finish ("⏳ Waiting up to 1905s for in-flight turns on …"), and the
// version never changed while he watched. "We need a better update process all around."
// Now the sheet names what it updates ("Update Hermes on Studio", where it is, 0.22.5 → 0.23.0, What's New) and asks
// first. Its steps tick off from the update's own log: Check → Wait for Bots (which bots, and the longest wait) →
// Install → Restart → Confirm, and it ends in words that are true: "Updated to 0.23.0" only once /api/status reads the
// new version; otherwise up to date, can't update here (with the command and Copy), still on the old version, couldn't
// confirm, or what went wrong (with Update Output and Copy Details). A Nous agent's update runs in the same sheet: Ask
// Nous → Nous Reinstalls → Hermes Answers → Confirm Version, read from the agent's own Hermes before and after.
// Each run lives in `HermesUpdateCenter`, keyed by gateway (or agent): the sheet may be closed and the app backgrounded;
// the rows say "Updating Studio…" and bring the same sheet back; the end buzzes and, unseen, posts a local alert.
// Hermes has no way to skip the bot wait, so there is no "Update Now" that would pretend to. Pure half:
// HermesKit/Pages/More/HermesUpdateFlow.swift. Modelled on the add-on sheet (App/Notifications/AddOnUpdate.swift).

import SwiftUI
import UIKit
import UserNotifications

/// Every Hermes update this app run knows of, by gateway account id (or "cloud:<agent id>"), and the last update check
/// per gateway (More's row, Settings' rows).
@MainActor @Observable final class HermesUpdateCenter {
    static let shared = HermesUpdateCenter()
    /// The app's model, set at launch (the onboarding screen runs before the tabs exist).
    @ObservationIgnored static weak var app: AppModel?
    fileprivate static var model: AppModel? { MainTabController.current?.services as? AppModel ?? app }

    private(set) var runs: [String: HermesUpdate] = [:]
    /// The newest update check per gateway account id.
    private(set) var checks: [String: HermesUpdateCheck] = [:]
    /// Each saved gateway's Hermes version (`/api/status`), by account id.
    private(set) var versions: [String: String] = [:]
    @ObservationIgnored private var reading: Set<String> = []

    func run(_ key: String) -> HermesUpdate? { runs[key] }

    /// A run under way (or ended and not yet seen) for this key.
    func busy(_ key: String) -> Bool { runs[key]?.busy ?? false }

    func note(_ check: HermesUpdateCheck, for key: String) {
        checks[key] = check
        if let version = check.currentVersion { versions[key] = version }
        PagesTabs.moreRowsChanged()
    }

    func note(version: String?, for key: String) {
        guard let version else { return }
        versions[key] = version
    }

    /// More › Status & Maintenance's row: "Update" when the gateway in use has one, "Updating…" while it runs.
    func moreStatus(_ key: String) -> MoreRowStatus? {
        if let run = runs[key], run.isRunning { return MoreRowStatus(text: "Updating…", isIssue: false, spoken: run.rowTitle) }
        guard checks[key]?.updateAvailable == true else { return nil }
        let to = checks[key]?.sourceVersion.map { " to \($0)" } ?? ""
        return MoreRowStatus(text: "Update", isIssue: false, spoken: "Hermes update available\(to)")
    }

    // MARK: Gateways

    /// Reads a gateway's version and update check once (Settings' rows); a gateway that isn't in use through its own
    /// saved session. Quiet on failure.
    func refresh(_ account: GatewayAccount) {
        guard !reading.contains(account.id), let endpoint = Self.endpoint(for: account) else { return }
        reading.insert(account.id)
        let api = HermesUpdateAPI(endpoint: endpoint)
        Task {
            let version = await api.version()
            note(version: version, for: account.id)
            if version != nil, let check = try? await api.check(force: false) { note(check, for: account.id) }
            endpoint.finish()
            reading.remove(account.id)
        }
    }

    /// The gateway's REST: the live client for the one in use, else a REST-only probe with its saved session.
    static func endpoint(for account: GatewayAccount) -> (any HermesUpdateEndpoint)? {
        guard let app = Self.model else { return nil }
        if app.account?.id == account.id, let client = app.client { return ClientUpdateEndpoint(client: client) }
        guard let stored = app.signIn.store.stored(account), stored.hasSession else { return nil }
        return AccountProbe(stored: stored)
    }

    /// Settings' gateway page as it is titled now: "Gateways" once several are saved.
    static var gatewaysPage: String { (model?.signIn.store.accounts.count ?? 0) > 1 ? "Settings › Gateways" : "Settings › Gateway" }

    /// The live client or a saved session can reach it.
    static func reachable(_ account: GatewayAccount) -> Bool { liveClient(for: account) != nil || storedSession(for: account) != nil }

    /// The live client while this gateway is in use (nil otherwise).
    static func liveClient(for account: GatewayAccount) -> (any GatewayClient)? {
        guard let app = Self.model, app.account?.id == account.id else { return nil }
        return app.client
    }

    /// This gateway's saved session, for a REST-only probe (nil: none on this phone).
    static func storedSession(for account: GatewayAccount) -> StoredAccount? {
        guard let stored = Self.model?.signIn.store.stored(account), stored.hasSession else { return nil }
        return stored
    }

    /// The gateway's name as Settings shows it: the name given on this device, else its computer's.
    static func name(_ account: GatewayAccount) -> String {
        if let app = Self.model,
           let row = app.settingsHub.accounts.first(where: { $0.id == account.id }) { return row.title }
        return UpdateHermesScreen.name(url: account.baseURL, label: account.label)
    }

    /// Update Hermes on a gateway: the sheet opens on "Checking…" and asks before anything changes. A run already under
    /// way for it comes back instead. `afterUpdated`: runs when the sheet closes on "Updated to …" (the "too old" page
    /// checks again, so it enters without a tap on Check Again).
    func update(_ account: GatewayAccount, from presenter: UIViewController?, afterUpdated: (() -> Void)? = nil) {
        if let run = runs[account.id], run.busy {
            if let afterUpdated { run.afterUpdated = afterUpdated }
            run.show(from: presenter)
            return
        }
        guard Self.reachable(account) else {
            FailureAlert.present(title: "Can’t Reach \(Self.name(account))", reason: "Sign in to it again from \(Self.gatewaysPage), then try again.",
                                 from: presenter, whole: true)
            return
        }
        let run = HermesUpdate(key: account.id, kind: .gateway, name: Self.name(account),
                               place: HermesUpdate.place(account), api: HermesUpdateAPI(endpoint: FollowingUpdateEndpoint(account: account)))
        run.afterUpdated = afterUpdated
        runs[account.id] = run
        run.again = { [weak self] presenter in self?.update(account, from: presenter) }
        run.check()
        run.show(from: presenter)
    }

    /// An update that was already running when Status & Maintenance opened (the app was relaunched mid-update): follow
    /// it in the same sheet's state, without asking again.
    func attach(_ account: GatewayAccount) {
        if let run = runs[account.id], run.isRunning { return }
        guard Self.reachable(account) else { return }
        let run = HermesUpdate(key: account.id, kind: .gateway, name: Self.name(account),
                               place: HermesUpdate.place(account), api: HermesUpdateAPI(endpoint: FollowingUpdateEndpoint(account: account)))
        run.from = versions[account.id]
        runs[account.id] = run
        AppLog.note("config", "update flow: re-attached to a running update")
        run.follow()
    }

    // MARK: Nous agents

    /// Update a Nous agent's Hermes. `read`: its own Hermes's version (nil: couldn't be read); `go`: sends
    /// `update_image` and reports Nous's progress back into the run.
    func updateCloud(id: String, name: String, read: @escaping () async -> String?,
                     go: @escaping (HermesUpdate) -> Void, from presenter: UIViewController?) {
        let key = "cloud:" + id
        if let run = runs[key], run.busy { run.show(from: presenter); return }
        let run = HermesUpdate(key: key, kind: .cloud, name: name, place: CloudCopy.agentPlace, api: nil)
        run.cloudRead = read
        run.cloudGo = go
        run.again = { [weak self] presenter in self?.updateCloud(id: id, name: name, read: read, go: go, from: presenter) }
        runs[key] = run
        run.check()
        run.show(from: presenter)
    }

    #if DEBUG
    /// `-HQDebugUpdateShot <state>`: a made-up run in that state.
    func demo(_ state: String, name: String, place: String = "Gateway in use · studio.tail1234.ts.net") -> HermesUpdate? {
        let cloud = state.hasPrefix("cloud-")
        let run = HermesUpdate(key: cloud ? "cloud:demo" : "demo", kind: cloud ? .cloud : .gateway, name: cloud ? "Research Bot" : name,
                               place: cloud ? CloudCopy.agentPlace : place, api: nil)
        guard run.demo(cloud ? String(state.dropFirst(6)) : state) else { return nil }
        runs[run.key] = run
        return run
    }

    func adopt(_ run: HermesUpdate, as key: String) { runs[key] = run }
    #endif
}

/// One update: of a gateway, or of a Nous agent.
@MainActor @Observable final class HermesUpdate {
    enum Kind: Sendable { case gateway, cloud }
    enum Phase: Equatable { case checking, asking, working, ended(HermesUpdateEnd) }

    struct Step: Identifiable, Equatable {
        let id: HermesUpdateStepID
        var title: String
        var state: HermesUpdateStepState = .waiting
        var detail: String?
        var started: Date?
        var finished: Date?
    }

    let key: String
    let kind: Kind
    /// "Studio", "Research Bot".
    let name: String
    /// Where it is, so it can't be mistaken: "Gateway in use · studio.local:9119", "Nous Hermes Cloud agent".
    let place: String
    fileprivate(set) var from: String?
    private(set) var to: String?
    private(set) var commits: [HermesUpdateCommit] = []
    private(set) var phase: Phase = .checking
    private(set) var steps: [Step] = []
    /// What's still owed after it ended (a receipt's follow-up), or why the version is unchanged.
    private(set) var note: String?
    /// The update's own output (Update Output).
    private(set) var action: GatewayActionRun?
    private(set) var progress = HermesUpdateProgress()

    @ObservationIgnored let api: HermesUpdateAPI?
    @ObservationIgnored fileprivate var cloudRead: (() async -> String?)?
    @ObservationIgnored fileprivate var cloudGo: ((HermesUpdate) -> Void)?
    @ObservationIgnored fileprivate var afterUpdated: (() -> Void)?
    @ObservationIgnored private var refusal: HermesUpdateRefusal?
    @ObservationIgnored private weak var sheet: UIViewController?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// Audit 863 (08d-7): the sheet was closed while it checked; the check's end is no news (no buzz, nothing read out).
    @ObservationIgnored private var abandoned = false
    /// Audit 863 (08d-8): a failed check or update asked again (a fresh run, as Update Hermes would start).
    @ObservationIgnored fileprivate var again: ((UIViewController?) -> Void)?
    /// Audit 863 (08d-13): when the update itself began ("so far" counts from here, not from each step).
    private(set) var workStarted: Date?

    init(key: String, kind: Kind, name: String, place: String, api: HermesUpdateAPI?) {
        self.key = key; self.kind = kind; self.name = name; self.place = place; self.api = api
    }

    static func place(_ account: GatewayAccount) -> String {
        let host = GatewayNaming.host(account.baseURL, port: true)
        // The "too old" page after a sign-in comes before the tabs (and the app model's account): the gateway just signed
        // in to is the one in use then.
        let app = HermesUpdateCenter.model
        let current = app?.account?.id == account.id || (MainTabController.current == nil && app?.signIn.store.current?.id == account.id)
        return current ? "Gateway in use · \(host)" : "Saved gateway, not in use · \(host)"
    }

    var isRunning: Bool { phase == .checking || phase == .working }
    /// The check before the question failed: nothing was started on the gateway (its sheet offers Try Again).
    var checkFailed: Bool {
        guard kind == .gateway, action == nil, case .ended(.failed) = phase else { return false }
        return true
    }
    /// Under way, or ended and not closed yet: a tap brings the sheet back instead of starting another.
    var busy: Bool { isRunning || end != nil || sheet?.presentingViewController != nil }
    var end: HermesUpdateEnd? { if case .ended(let end) = phase { end } else { nil } }

    // MARK: Gateway

    /// The check before the question.
    func check() {
        phase = .checking
        if kind == .cloud {
            steps = HermesUpdateStepID.cloud.map { Step(id: $0, title: Self.title($0), detail: Self.plan($0, name: name)) }
            Task {
                from = await cloudRead?()
                phase = .asking
            }
            return
        }
        steps = [Step(id: .check, title: Self.title(.check), state: .active, started: Date())]
        guard let api else { return }
        Task {
            let check: HermesUpdateCheck
            do { check = try await api.check(force: true) } catch {
                api.endpoint.finish()
                end(.failed(reason: Self.unreachable(name, PagesREST.reason(error))))
                return
            }
            HermesUpdateCenter.shared.note(check, for: key)
            from = check.currentVersion
            if from == nil { from = await api.version() }
            to = check.sourceVersion ?? check.rollbackTo
            commits = check.commits
            if check.couldNotCheck {
                api.endpoint.finish()
                end(.failed(reason: check.message ?? "Hermes couldn’t reach its update source. Try again later."))
            } else if !check.updateAvailable {
                api.endpoint.finish()
                end(.upToDate(version: from))
            } else if !check.canApply {
                api.endpoint.finish()
                end(.cantUpdateHere(method: HermesInstallWords.method(check.installMethod) ?? check.message ?? Self.notInPlace, command: check.command))
            } else {
                let started = steps.first?.started
                steps = HermesUpdateStepID.gateway.map { Step(id: $0, title: Self.title($0), detail: Self.plan($0, name: name)) }
                steps[0].state = .done
                steps[0].started = started
                steps[0].finished = Date()
                steps[0].detail = nil
                if let held = check.rollbackTo { note = "This moves \(name) back to release \(held)." }
                phase = .asking
            }
        }
    }

    /// The sheet's Update.
    func confirm() {
        guard phase == .asking else { return }
        AppLog.note("config", "update flow: \(kind == .cloud ? "cloud" : "gateway") update confirmed")
        phase = .working
        workStarted = Date()
        if kind == .cloud {
            step(.ask, .active)
            cloudGo?(self)
            return
        }
        guard let api else { return }
        start { [weak self] in
            do { return try await api.start() } catch let refusal as HermesUpdateRefusal {
                await self?.refused(refusal)
                throw refusal
            }
        }
    }

    /// An update already running on the gateway: its steps from its log.
    fileprivate func follow() {
        steps = HermesUpdateStepID.gateway.map { Step(id: $0, title: Self.title($0)) }
        steps[0].state = .done
        phase = .working
        start { "hermes-update" }
    }

    private func start(_ begin: @escaping @Sendable () async throws -> String) {
        guard let api else { return }
        let run = GatewayActionRun(status: { try await api.status($0) })
        run.patience = .seconds(3 * 3600)   // the bot wait alone can be half an hour; the steps say where it is
        run.onRead = { [weak self] answer in self?.read(answer) }
        run.onFinish = { [weak self] _ in self?.actionEnded() }
        run.onUntracked = { [weak self] in self?.actionEnded() }
        action = run
        progress = HermesUpdateProgress()
        apply()
        run.start(begin)
        ticker?.cancel()
        // The wait's "up to 32 min" counts down between reads.
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self, self.phase == .working else { return }
                self.apply()
            }
        }
    }

    private func refused(_ refusal: HermesUpdateRefusal) { self.refusal = refusal }

    private func read(_ answer: GatewayActionStatus?) {
        if let answer { progress.read(answer) } else { progress.unanswered() }
        apply()
    }

    /// The steps from the progress.
    private func apply() {
        guard phase == .working, kind == .gateway else { return }
        for id in HermesUpdateStepID.gateway where id != .confirm {
            let state = progress.state(id)
            var detail: String?
            switch id {
            case .drain:
                let names = Dictionary((progress.drain?.profiles ?? []).map { ($0, Self.botName($0)) }, uniquingKeysWith: { a, _ in a })
                detail = progress.drainDetail(names: { names[$0] ?? $0 })
            case .install: detail = state == .active ? Self.installing : nil
            case .restart: detail = state == .active ? Self.restarting(name) : nil
            default: break
            }
            step(id, state, detail: detail)
        }
    }

    private func actionEnded() {
        ticker?.cancel()
        guard phase == .working, let api else { return }
        if let refusal {
            api.endpoint.finish()
            end(.cantUpdateHere(method: HermesInstallWords.method(refusal.code) ?? refusal.message, command: refusal.command))
            return
        }
        if case .failed(let reason)? = action?.phase {
            api.endpoint.finish()
            end(.failed(reason: reason))
            return
        }
        // A run that ended in an error stops on the step under way (end() marks it); the rest only on success.
        let stopped = (progress.exitCode ?? 0) != 0 || progress.receipt?.failed == true
        if !stopped {
            for id in [HermesUpdateStepID.check, .drain, .install, .restart] {
                let state = steps.first { $0.id == id }?.state
                if state == .active || state == .waiting { step(id, id == .drain && progress.drain == nil ? .skipped : .done) }
            }
            step(.confirm, .active, detail: Self.reading(name))
        }
        let lines = action?.lines ?? []
        let exit = progress.exitCode ?? { if case .finished(let ok, _)? = action?.phase { return ok ? 0 : 1 } else { return nil } }()
        let before = from
        Task {
            var receipt = progress.receipt
            if receipt == nil { receipt = await api.receipt() }
            // The dashboard restarts last: read until the version moves, for up to a minute and a half.
            var after: String?
            for attempt in 0..<18 {
                if let read = await api.version() {
                    after = read
                    if before.map({ !HermesUpdateEnd.versionsMatch($0, read) }) ?? true { break }
                    if HermesUpdateEnd.stopsReading(attempt: attempt, exitCode: exit) { break }
                }
                try? await Task.sleep(for: .seconds(5))
            }
            api.endpoint.finish()
            let ending = HermesUpdateEnd.gateway(exitCode: exit, receipt: receipt, before: before, after: after, lines: lines)
            let installed = receipt?.postVersion ?? HermesUpdateLog.completed(lines)?.to
            switch ending {
            case .unchanged(let version?):
                if let installed, !HermesUpdateEnd.versionsMatch(installed, version) {
                    note = "Hermes says it installed \(installed), but \(name) still reports \(version). Restarting Hermes may finish it."
                }
            case .updated:
                note = receipt?.owed
            default: break
            }
            if let after { HermesUpdateCenter.shared.note(version: after, for: key) }
            if case .updated = ending, let check = HermesUpdateCenter.shared.checks[key] {
                var done = check
                done.updateAvailable = false
                done.behind = 0
                done.currentVersion = after
                HermesUpdateCenter.shared.note(done, for: key)
            }
            end(ending)
        }
    }

    // MARK: Nous

    /// What Nous says while it works (CloudGatewayModel's settle loop).
    func cloud(_ signal: CloudUpdateSignal) {
        guard phase == .working, kind == .cloud else { return }
        switch signal {
        case .asked:
            step(.ask, .done)
            step(.reinstall, .active, detail: CloudCopy.doing(.updateImage))
        case .settling(let words):
            if steps.first(where: { $0.id == .reinstall })?.state == .active { step(.reinstall, .active, detail: words) }
        case .failed(let reason):
            end(.failed(reason: reason))
        case .ready:
            step(.ask, .done)
            step(.reinstall, .done)
            step(.answer, .active, detail: Self.reading(name))
            let before = from
            Task {
                var after: String?
                for _ in 0..<12 {
                    after = await cloudRead?()
                    if after != nil { break }
                    try? await Task.sleep(for: .seconds(5))
                }
                if after != nil { step(.answer, .done) } else { step(.answer, .skipped) }
                step(.version, .active)
                end(HermesUpdateEnd.cloud(before: before, after: after))
            }
        }
    }

    // MARK: Steps and the end

    private func step(_ id: HermesUpdateStepID, _ state: HermesUpdateStepState, detail: String? = nil) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        let was = steps[index].state
        if was == state, steps[index].detail == detail { return }
        steps[index].state = state
        steps[index].detail = state == .done ? nil : detail
        if state == .active, was != .active { steps[index].started = Date() }
        if state == .active, phase == .working, workStarted == nil { workStarted = Date() }   // a run picked up under way
        if (state == .done || state == .skipped), was != state { steps[index].finished = Date() }
        if state == .done, was != .done { Haptics.play(.light) }
    }

    private func end(_ end: HermesUpdateEnd) {
        ticker?.cancel()
        for index in steps.indices {
            if steps[index].state == .active {
                if case .updated = end { steps[index].state = .done; steps[index].finished = Date() }
                else if case .unchanged = end { steps[index].state = .done; steps[index].finished = Date() }
                else if case .failed = end { steps[index].state = .failed; steps[index].finished = Date() }
                else { steps[index].state = .waiting }
            }
            if steps[index].state == .waiting { steps[index].detail = nil }
        }
        let wasWorking = phase == .working
        phase = .ended(end)
        AppLog.note("config", "update flow ended: \(Self.logWord(end))")
        PagesTabs.moreRowsChanged()
        guard !abandoned else { return }
        switch end {
        case .updated, .upToDate: Haptics.play(.success)
        case .unchanged, .unconfirmed, .cantUpdateHere: Haptics.play(.warning)
        case .failed: Haptics.play(.error)
        }
        if wasWorking { alertIfUnseen() }
        AccessibilityNotification.Announcement(headline).post()
    }

    /// The end, as a local alert, when the sheet isn't what's on screen.
    private func alertIfUnseen() {
        let seen = UIApplication.shared.applicationState == .active && sheet?.view.window != nil
        guard !seen else { return }
        let content = UNMutableNotificationContent()
        content.title = headline
        content.body = line ?? name
        content.sound = .default
        content.threadIdentifier = "hq.hermes-update"
        content.userInfo = [HermesUpdate.alertKey: key]
        Task { try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "hermes-update." + key, content: content, trigger: nil)) }
    }

    /// The local alert's key in `userInfo` (NotificationHub shows it and opens the sheet).
    nonisolated static let alertKey = "hermesUpdate"

    // MARK: The sheet

    func show(from presenter: UIViewController?) {
        if let sheet, sheet.view.window != nil { return }
        guard let host = FailureAlert.topmost(presenter ?? MainTabController.current) else { return }
        let controller = HermesUpdateController(update: self)
        SheetStyle.macTall(controller, from: host)   // [mac] the other sheets' size, not the system's small one
        sheet = controller
        host.present(controller, animated: true)
    }

    func close() { sheet?.dismiss(animated: true) }

    fileprivate func sheetClosed() {
        // An ended run that's been seen is done: the rows go back to the gateway's own state.
        if case .ended = phase, HermesUpdateCenter.shared.run(key) === self { HermesUpdateCenter.shared.forget(key) }
        if case .ended(.updated) = phase, let afterUpdated {
            self.afterUpdated = nil
            afterUpdated()
        }
        // Not Now (or closed while checking): nothing started.
        if phase == .asking || (phase == .checking && action == nil), HermesUpdateCenter.shared.run(key) === self {
            HermesUpdateCenter.shared.forget(key)
            api?.endpoint.finish()
            abandoned = true
        }
    }

    func openOutput() {
        guard let action, let sheet else { return }
        let page = ActionOutput.make(title: "Update Output", run: action, words: ActionWords.update)
        let nav = UINavigationController(rootViewController: page)
        // [mac] Mac polish #123: Done in words on the Mac (`hqClose`), not a ✓ in a circle; the iPhone's system Done as before.
        page.navigationItem.rightBarButtonItem = .hqClose(.done, action: UIAction { [weak nav] _ in nav?.dismiss(animated: true) })
        sheet.present(nav, animated: true)
    }

    var canTryAgain: Bool { again != nil }

    /// A failed check or update, again: the sheet closes and Update Hermes starts over (a fresh check, then the question).
    func tryAgain() {
        guard case .ended(.failed) = phase, let again else { return }
        Haptics.play(.soft)
        let presenter = sheet?.presentingViewController
        if HermesUpdateCenter.shared.run(key) === self { HermesUpdateCenter.shared.forget(key) }
        if let sheet { sheet.dismiss(animated: true) { again(presenter) } } else { again(presenter) }
    }

    func copyDetails() {
        var lines = ["Update Hermes on \(name)", headline]
        if let line { lines.append(line) }
        lines += action?.lines ?? []
        UIPasteboard.general.string = PageStates.scrubbed(lines.joined(separator: "\n"))
        Haptics.play(.success)
        if let sheet { PagesHUD.show("Copied", symbol: "doc.on.doc", from: sheet) }
    }

    func copyCommand() {
        guard case .cantUpdateHere(_, let command?)? = end else { return }
        UIPasteboard.general.string = command
        Haptics.play(.success)
        if let sheet { PagesHUD.show("Copied", symbol: "doc.on.doc", from: sheet) }
    }

    // MARK: Words

    static func title(_ id: HermesUpdateStepID) -> String {
        switch id {
        case .check: "Check"
        case .drain: "Wait for Bots"
        case .install: "Install"
        case .restart: "Restart"
        case .confirm: "Confirm"
        case .ask: "Ask Nous"
        case .reinstall: "Nous Reinstalls"
        case .answer: "Hermes Answers"
        case .version: "Confirm Version"
        }
    }

    /// Before the tap: what each step will do.
    static func plan(_ id: HermesUpdateStepID, name: String) -> String? {
        switch id {
        case .drain: "Bots finish the replies they’re working on first. This can take a while."
        case .restart: "Replies pause for a minute or two."
        case .reinstall: "Nous moves \(name) to its newest Hermes and restarts it."
        default: nil
        }
    }

    static let installing = "Installing the new Hermes"
    static func restarting(_ name: String) -> String { "Waiting for \(name) to come back" }
    static func reading(_ name: String) -> String { "Reading \(name)’s version" }
    static let notInPlace = "Hermes here wasn’t installed in a way it can update itself"
    static func unreachable(_ name: String, _ reason: String) -> String { "Couldn’t check \(name) for updates. \(reason)" }

    /// A profile name → the app's bot name ("finance" → "Finance").
    static func botName(_ profile: String) -> String {
        let bots = (MainTabController.current?.services as? AppModel)?.bots ?? []
        if let bot = bots.first(where: { $0.id == profile }) { return bot.name }
        return PagesNames.botName(profile == "default" ? nil : profile, bots: bots)
    }

    /// Settings' and Status & Maintenance's row while it runs.
    var rowTitle: String { "Updating \(name)…" }

    var rowStatus: String? {
        switch phase {
        case .checking: return "Checking…"
        case .asking: return nil
        case .ended: return headline
        case .working:
            guard let step = steps.first(where: { $0.state == .active }) else { return nil }
            return step.detail.map { "\(step.title): \($0)" } ?? step.title
        }
    }

    var headline: String {
        let what = kind == .cloud ? name : "Hermes on \(name)"
        switch phase {
        case .checking: return "Checking \(name)…"
        case .asking: return "Update \(what)"
        case .working:
            return steps.first(where: { $0.state == .active })?.id == .drain ? "Waiting for Bots…" : "Updating \(what)…"
        case .ended(let end):
            switch end {
            case .updated(let version): return "Updated to \(HermesUpdateEnd.normalized(version))"
            case .upToDate: return "Hermes Is Up to Date"
            case .cantUpdateHere: return "\(name) Can’t Update Itself"
            case .unchanged(let version): return version.map { "Still on \(HermesUpdateEnd.normalized($0))" } ?? "Version Unchanged"
            case .unconfirmed: return "Couldn’t Confirm the Version"
            case .failed: return checkFailed ? "Couldn’t Check for Updates" : "The Update Didn’t Finish"
            }
        }
    }

    /// "0.22.5 → 0.23.0" under the headline.
    var versions: String? {
        switch phase {
        case .ended(.updated(let version)): HermesUpdateWords.versions(from: from, to: version)
        case .ended(.upToDate(let version)): version.map(HermesUpdateEnd.normalized)
        case .ended(.unchanged(let version)): (version ?? from).map(HermesUpdateEnd.normalized)
        case .checking: nil
        default: HermesUpdateWords.versions(from: from, to: to)
        }
    }

    /// A Nous agent that came back on the same Hermes.
    nonisolated static func cloudUnchanged(name: String, version: String?) -> String {
        "Nous restarted \(name) on \(version.map(HermesUpdateEnd.normalized) ?? "the same Hermes"). Nous hasn’t released a newer Hermes yet."
    }

    var line: String? {
        switch phase {
        case .checking: return nil
        case .asking:
            return kind == .cloud ? CloudCopy.updateMessage
                : "Bots finish the replies they’re working on, then Hermes installs the update and restarts. Hermes can’t skip that wait."
        case .working: return Self.keepsGoing
        case .ended(let end):
            switch end {
            case .updated: return note ?? (kind == .cloud ? "\(name) answers on its new Hermes." : "\(name) is back and running the new Hermes.")
            case .upToDate: return "\(name) runs the newest Hermes. Nothing to do."
            case .cantUpdateHere(let method, let command):
                return command == nil ? "\(method), so it’s updated wherever it’s run from, not from here."
                    : "\(method). Run this on \(name) to update it:"
            case .unchanged(let version):
                if kind == .cloud { return Self.cloudUnchanged(name: name, version: version) }
                return note ?? "The update finished, but \(name) still reports the same version."
            case .unconfirmed:
                return kind == .cloud ? "Nous restarted \(name), but HQ couldn’t read its Hermes version, so it can’t say whether it changed."
                    : "The update finished, but \(name) didn’t answer with its version. Check Status & Maintenance in a minute."
            case .failed(let reason): return reason
            }
        }
    }

    static let keepsGoing = "You can close this. The update keeps going, and Settings shows how it’s doing."

    var showsSteps: Bool {
        switch phase {
        case .checking: return false
        case .asking, .working: return steps.count > 1
        case .ended(let end):
            switch end {
            case .upToDate, .cantUpdateHere: return false
            case .failed: return steps.contains { $0.id != .check && $0.state == .done } || action != nil
            default: return steps.count > 1
            }
        }
    }

    var showsWhatsNew: Bool {
        guard !commits.isEmpty else { return false }
        switch phase {
        case .asking, .working, .ended(.updated): return true
        default: return false
        }
    }

    var symbol: (name: String, color: Color)? {
        switch phase {
        case .checking, .working: return nil
        case .asking: return (kind == .cloud ? "cloud" : "arrow.down.circle", .hqTint)
        case .ended(let end):
            switch end {
            case .updated, .upToDate: return ("checkmark.circle.fill", .green)
            case .unchanged, .unconfirmed: return ("questionmark.circle.fill", .orange)
            case .cantUpdateHere: return ("terminal", .orange)
            case .failed: return ("exclamationmark.triangle.fill", .orange)
            }
        }
    }

    static func logWord(_ end: HermesUpdateEnd) -> String {
        switch end {
        case .updated(let version): "updated to \(version)"
        case .upToDate: "up to date"
        case .cantUpdateHere: "can't update here"
        case .unchanged(let version): "unchanged (\(version ?? "?"))"
        case .unconfirmed: "unconfirmed"
        case .failed: "failed"
        }
    }
}

extension HermesUpdateCenter {
    fileprivate func forget(_ key: String) { runs[key] = nil }

    /// A tapped local alert: the run's sheet. A run lives only in memory, so when iOS has closed the app since the alert
    /// was posted, the alert's own words show instead (once the tabs are on screen, ≤ 10 s), never nothing at all.
    func open(_ key: String, title: String, body: String, attempt: Int = 0) {
        if let run = runs[key] { run.show(from: nil); return }
        guard let tabs = MainTabController.current, tabs.view.window != nil, let host = FailureAlert.topmost(tabs) else {
            guard attempt < 20 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.open(key, title: title, body: body, attempt: attempt + 1)
            }
            return
        }
        AppLog.note("config", "update flow: alert tapped after the run was gone")
        let alert = UIAlertController(title: title, message: body, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        alert.view.accessibilityIdentifier = "hermes-update.ended-alert"
        host.present(alert, animated: true)
    }
}

/// [update-flow] A gateway's REST for one whole update: the live client while that gateway is in use, else one REST-only
/// probe with its saved session, chosen again on every read. A switch to another gateway mid-update ends the client the
/// run was following; the run carries on through the probe (it had sat on "Updating…" for good), and back on that
/// gateway it follows the live client again.
actor FollowingUpdateEndpoint: HermesUpdateEndpoint {
    let account: GatewayAccount
    private var probe: AccountProbe?

    init(account: GatewayAccount) { self.account = account }

    func json(_ method: String, _ path: String, query: [URLQueryItem], body: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
        let account = self.account
        if let client = await MainActor.run(body: { HermesUpdateCenter.liveClient(for: account) }) {
            return try await ClientUpdateEndpoint(client: client).json(method, path, query: query, body: body, timeout: timeout)
        }
        return try await probeEndpoint().json(method, path, query: query, body: body, timeout: timeout)
    }

    private func probeEndpoint() async throws -> AccountProbe {
        if let probe { return probe }
        let account = self.account
        guard let stored = await MainActor.run(body: { HermesUpdateCenter.storedSession(for: account) }) else { throw GatewayFailure.signedOut }
        if let probe { return probe }   // another read made one meanwhile
        let made = AccountProbe(stored: stored)
        probe = made
        return made
    }

    nonisolated func finish() { Task { await self.close() } }

    private func close() {
        probe?.finish()
        probe = nil
    }
}

/// What Nous says while an agent updates (CloudGatewayModel → the run).
enum CloudUpdateSignal {
    case asked
    case settling(String)
    case ready
    case failed(String)
}

extension CloudCopy {
    static let agentPlace = "Nous Hermes Cloud agent"
}

// MARK: - The sheet

final class HermesUpdateController: UIHostingController<HQScaledRoot<HermesUpdateView>> {
    private let update: HermesUpdate

    init(update: HermesUpdate) {
        self.update = update
        super.init(rootView: HQScaledRoot(HermesUpdateView(update: update)))
        if let sheet = sheetPresentationController {
            let fit = UISheetPresentationController.Detent.custom(identifier: .init("hermes-update.fit")) { [weak self] context in
                guard let self else { return nil }
                return min(context.maximumDetentValue, self.measuredHeight() ?? 520)
            }
            sheet.detents = [fit, .large()]
            sheet.hqPreferLargeAtAccessibilitySizes()   // [a11y]
            sheet.prefersGrabberVisible = false
            sheet.hqGlassPage()   // glass below full height, its words on cards (as the add-on sheet)
        }
        refitOnChange()
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private weak var list: UIScrollView?
    private var listHeight: NSKeyValueObservation?
    private var fitted: CGFloat = 0

    private func measuredHeight() -> CGFloat? {
        guard let list, list.contentSize.height > 0 else { return nil }
        return ceil(list.contentSize.height + list.adjustedContentInset.top + list.adjustedContentInset.bottom)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard list == nil, let found = Self.firstScrollView(in: view) else { return }
        list = found
        listHeight = found.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refit() }
        }
        refit()
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        for sub in view.subviews {
            if let scroll = sub as? UIScrollView { return scroll }
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }

    /// `shrink`: only when what's shown changed (the phase, the steps). A list taller than the sheet measures its
    /// unseen rows by estimate, so its height swung up and down each time a row drew: refitting to every swing kept
    /// the sheet animating once a second, and taps on Update were lost mid-animation.
    private func refit(shrink: Bool = false) {
        let cap = view.window?.bounds.height ?? .greatestFiniteMagnitude
        guard let sheet = sheetPresentationController, let measured = measuredHeight() else { return }
        let height = min(measured, cap)
        guard abs(height - fitted) > 1, shrink || height > fitted else { return }
        fitted = height
        if view.window == nil { sheet.invalidateDetents() } else { sheet.animateChanges { sheet.invalidateDetents() } }
    }

    private func refitOnChange() {
        withObservationTracking {
            _ = update.phase
            _ = update.steps.count
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refit(shrink: true)
                self.refitOnChange()
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if presentingViewController == nil || isBeingDismissed { update.sheetClosed() }
    }
}

struct HermesUpdateView: View {
    @Bindable var update: HermesUpdate
    @ScaledMetric(relativeTo: .title) private var symbolSize: CGFloat = 36

    var body: some View {
        NavigationStack {
            List {
                Section { header }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                    .hqDesktopBareRow()
                if case .ended(.cantUpdateHere(_, let command?)) = update.phase {
                    Section {
                        Text(command)
                            .font(Font.hqSystem(.callout, design: .monospaced))
                            .foregroundStyle(Color.hqLabel)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("hermes-update.command")
                    }
                    .hqSheetRows()
                    .hqUpdateSheetRowFit()
                }
                if update.showsSteps {
                    Section {
                        ForEach(update.steps) { HermesUpdateStepRow(step: $0) }
                    } footer: {
                        if update.phase == .working, let started = update.workStarted ?? update.steps.first(where: { $0.id != .check })?.started {
                            elapsed(since: started)
                        }
                    }
                    .hqSheetRows()
                    .hqUpdateSheetRowFit()
                }
                if update.showsWhatsNew { whatsNew }
            }
            .hqUpdateSheetFit()   // [sheet-fit]
            .hqGroupedPage()
            // The buttons stay pinned under the list: Update is on screen however long What's New is, and clear of
            // the sheet's bottom edge (a button flush with it in the list didn't take taps).
            // Not safeAreaBar: its soft edge ate the add-on sheet's taps (that sheet moved to an inset on 2026-11-06).
            // Mac polish #122, #124: on the page's colour with a soft fade above, and only when there is a button.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                UpdateSheetButtonBar(shown: hasButtons) {
                    VStack(spacing: 10) { buttons }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 12)
                }
            }
            .navigationTitle(update.kind == .cloud ? "Update Agent" : "Update Hermes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseToolbar(word: closeWord, id: "hermes-update.close") { update.close() } }   // [mac] Mac polish #123
            .animation(HQMotion.swiftUI(.smooth(duration: 0.3)), value: update.phase)
        }
        .hqGlassSheetPage()
        .accessibilityIdentifier("hermes-update")
    }

    /// Hiding the sheet while it works doesn't stop the update.
    private var closeWord: String {
        switch update.phase {
        case .checking, .working: "Hide"
        case .asking: "Not Now"
        case .ended: "Done"
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Group {
                if let symbol = update.symbol {
                    Image(systemName: symbol.name)
                        .font(.system(size: symbolSize))
                        .foregroundStyle(symbol.color)
                        .transition(.hqMotion(.scale.combined(with: .opacity)))
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(height: symbolSize + 4)
            .accessibilityHidden(true)
            Text(update.headline)
                .font(Font.hq(.title2).weight(.bold))
                .foregroundStyle(Color.hqLabel)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("hermes-update.headline")
            // Which machine this is, so a gateway is never taken for a Nous agent (or the other way round).
            Label(update.place, systemImage: update.kind == .cloud ? "cloud" : "server.rack")
                .font(Font.hq(.footnote).weight(.medium))
                .foregroundStyle(Color(uiColor: HQPalette.glassInk2))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("hermes-update.place")
            if let versions = update.versions {
                Text(versions)
                    .font(Font.hq(.headline).monospacedDigit())
                    .foregroundStyle(Color.hqLabel)
                    .accessibilityLabel(versions.replacingOccurrences(of: "→", with: "to"))
                    .accessibilityIdentifier("hermes-update.versions")
            }
            if let line = update.line {
                Text(line)
                    .font(Font.hq(.subheadline))
                    .foregroundStyle(Color(uiColor: HQPalette.glassInk2))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: DeviceWord.isMac ? 440 : nil)   // [mac] a reading width, not the sheet's whole width
                    .accessibilityIdentifier("hermes-update.line")
            }
        }
        .frame(maxWidth: .infinity)
        // [mac] Owner 2026-11-07 ("crammed, like we completely forgot to figure out the padding"): room above and below.
        .padding(.top, DeviceWord.isMac ? 16 : 6)
        .padding(.bottom, DeviceWord.isMac ? 12 : 6)
        .contentTransition(.opacity)
    }

    private var whatsNew: some View {
        let shown = Array(update.commits.prefix(UpdateSheetFit.whatsNewLines))   // [sheet-fit]
        return Section {
            ForEach(shown) { commit in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("•").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel3).accessibilityHidden(true)
                    Text(commit.summary).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            // [sheet-fit] On a phone in the Desktop Look the count is in the heading: a footnote under the card was the
            // one line left under Update at larger text sizes.
            let more = update.commits.count > shown.count
            Text(more && UpdateSheetFit.on ? "What’s New · \(shown.count) of \(update.commits.count)" : "What’s New")
                .font(Font.hq(.footnote).weight(.semibold)).foregroundStyle(Color(uiColor: HQPalette.glassInk2))
        } footer: {
            if update.commits.count > shown.count && !UpdateSheetFit.on {
                Text("And \(update.commits.count - shown.count) more.").font(Font.hq(.footnote)).foregroundStyle(Color(uiColor: HQPalette.glassInk2))
            }
        }
        .hqSheetRows()
        .hqUpdateSheetRowFit()
        .accessibilityIdentifier("hermes-update.whats-new")
    }

    private func elapsed(since started: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text("\(CloudCopy.elapsed(max(0, Int(context.date.timeIntervalSince(started))))) so far")
                .font(Font.hq(.footnote))
                .monospacedDigit()
                .foregroundStyle(Color(uiColor: HQPalette.glassInk2))
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .accessibilityHidden(true)
    }

    /// Whether `buttons` shows any (Mac polish #124): a failure always has Copy Details; a finished run, Update Output
    /// when Hermes printed something.
    private var hasButtons: Bool {
        switch update.phase {
        case .asking, .ended(.cantUpdateHere(_, _?)), .ended(.failed): true
        case .ended(.updated), .ended(.unchanged), .ended(.unconfirmed): update.action?.lines.isEmpty == false
        default: false
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch update.phase {
        case .asking:
            action("Update", id: "hermes-update.go") { update.confirm() }
        case .ended(.cantUpdateHere(_, _?)):
            action("Copy Command", id: "hermes-update.copy-command") { update.copyCommand() }
        case .ended(.failed) where update.checkFailed:
            // Nothing started: the check can simply run again.
            action("Try Again", id: "hermes-update.retry") { update.check() }
            action("Copy Details", id: "hermes-update.copy", prominent: false) { update.copyDetails() }
        case .ended(.failed):
            // Audit 863 (08d-8): Try Again here, not only by closing the sheet and starting over.
            if update.canTryAgain { action("Try Again", id: "hermes-update.retry") { update.tryAgain() } }
            if update.action?.lines.isEmpty == false {
                action("Update Output", id: "hermes-update.output", prominent: false) { update.openOutput() }
            }
            action("Copy Details", id: "hermes-update.copy", prominent: !update.canTryAgain) { update.copyDetails() }
        case .ended(.updated), .ended(.unchanged), .ended(.unconfirmed):
            // What Hermes printed stays reachable after any finished run.
            if update.action?.lines.isEmpty == false {
                action("Update Output", id: "hermes-update.output", prominent: false) { update.openOutput() }
            }
        default:
            EmptyView()
        }
    }

    private func action(_ title: String, id: String, prominent: Bool = true, perform: @escaping () -> Void) -> some View {
        Group {
            Group {
                if prominent {
                    Button(action: perform) { Text(title).frame(maxWidth: GlassSheetKit.designed ? .infinity : nil) }
                        .hqProminentButtonStyle()
                } else {
                    Button(action: perform) { Text(title).frame(maxWidth: GlassSheetKit.designed ? .infinity : nil) }
                        .hqBorderedButtonStyle()
                }
            }
            .controlSize(.large)
            .accessibilityIdentifier(id)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct HermesUpdateStepRow: View {
    var step: HermesUpdate.Step

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            ZStack {
                switch step.state {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green).transition(.hqMotion(.scale.combined(with: .opacity)))
                case .active:
                    ProgressView().controlSize(.small)
                case .skipped:
                    Image(systemName: "minus.circle").foregroundStyle(Color.hqLabel3)
                case .waiting:
                    Image(systemName: "circle").foregroundStyle(Color.hqLabel3)
                case .failed:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.red)
                }
            }
            .font(Font.hq(.title3))
            .frame(width: 24, height: 24)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(Font.hq(.body))
                    .foregroundStyle(step.state == .waiting || step.state == .skipped ? Color.hqLabel2 : Color.hqLabel)
                if let detail = step.state == .skipped ? HermesUpdate.skippedWords(step.id) : step.detail, step.state != .done {
                    Text(detail)
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                        .contentTransition(.opacity)
                        .accessibilityIdentifier("hermes-update.detail.\(step.id.rawValue)")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if step.state == .done, let started = step.started, let finished = step.finished {
                Text(CloudCopy.elapsed(max(0, Int(finished.timeIntervalSince(started)))))
                    .font(Font.hq(.footnote))
                    .monospacedDigit()
                    .foregroundStyle(Color.hqLabel2)
            }
        }
        .padding(.vertical, 3)
        .animation(HQMotion.swiftUI(.smooth(duration: 0.3)), value: step.state)
        .animation(HQMotion.swiftUI(.smooth(duration: 0.3), fades: true), value: step.detail)
        .accessibilityElement(children: .combine)
        .accessibilityValue(step.state == .done ? "Done" : step.state == .active ? "In progress" : step.state == .skipped ? "Not needed"
                            : step.state == .failed ? "Failed" : "Waiting")
        .accessibilityIdentifier("hermes-update.step.\(step.id.rawValue)")
    }
}

extension HermesUpdate {
    /// A skipped step's line.
    static func skippedWords(_ id: HermesUpdateStepID) -> String? {
        switch id {
        case .drain: "No bots were busy"
        case .answer: "Didn’t answer in time"
        default: "Not needed"
        }
    }
}

/// The row a page shows for a gateway's update: "Updating Studio…" with the step under way (tap: the sheet).
struct HermesUpdateRow: View {
    let run: HermesUpdate

    var body: some View {
        Button { run.show(from: nil) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(run.isRunning ? run.rowTitle : run.headline).foregroundStyle(Color.hqTintText)
                    if let status = run.isRunning ? run.rowStatus : run.line {
                        Text(status).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if run.isRunning { ProgressView().controlSize(.small) }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .accessibilityHint("Shows the update")
        .accessibilityIdentifier("hermes-update.row")
    }
}

#if DEBUG
// MARK: - Pictures of each state (`-HQDebugUpdateShot <state>`, App/Debug/DebugHooks.swift)

extension HermesUpdate {
    /// asking, waiting, installing, restarting, updated, unchanged, cant, failed, uptodate; for a Nous agent (`cloud-`
    /// before it): asking, working, updated, unchanged, unconfirmed.
    fileprivate func demo(_ state: String) -> Bool {
        let now = Date()
        func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        from = "0.22.5"
        to = "0.23.0"
        commits = [
            HermesUpdateCommit(sha: "2bd378e", summary: "Gateways drain before an update and say who they’re waiting on"),
            HermesUpdateCommit(sha: "91a0c2f", summary: "Update receipts name the version installed"),
            HermesUpdateCommit(sha: "e8de2c1", summary: "Faster session lists on large profiles"),
            HermesUpdateCommit(sha: "77b10aa", summary: "Browser tools start a minute sooner"),
            HermesUpdateCommit(sha: "3c9d0e4", summary: "Cron jobs keep their model after a restart"),
            HermesUpdateCommit(sha: "0f1e2d3", summary: "Fixes for Telegram threads"),
        ]
        func set(_ id: HermesUpdateStepID, _ state: HermesUpdateStepState, _ detail: String? = nil, from: TimeInterval, to: TimeInterval? = nil) {
            guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
            steps[index].state = state
            steps[index].detail = detail
            steps[index].started = at(from)
            steps[index].finished = to.map(at)
        }
        if kind == .cloud {
            steps = HermesUpdateStepID.cloud.map { Step(id: $0, title: Self.title($0), detail: Self.plan($0, name: name)) }
            commits = []
            to = nil
            switch state {
            case "asking": phase = .asking
            case "working":
                for index in steps.indices { steps[index].detail = nil }
                set(.ask, .done, from: 140, to: 136)
                set(.reinstall, .active, "Installing Hermes…", from: 136)
                phase = .working
            case "updated", "unchanged", "unconfirmed":
                for index in steps.indices { steps[index].detail = nil }
                set(.ask, .done, from: 240, to: 236)
                set(.reinstall, .done, from: 236, to: 70)
                set(.answer, state == "unconfirmed" ? .skipped : .done, from: 70, to: 12)
                set(.version, .done, from: 12, to: 10)
                phase = .ended(state == "updated" ? .updated(to: "0.23.0") : state == "unchanged" ? .unchanged(version: "0.22.5") : .unconfirmed)
            default: return false
            }
            return true
        }
        steps = HermesUpdateStepID.gateway.map { Step(id: $0, title: Self.title($0), detail: Self.plan($0, name: name)) }
        set(.check, .done, from: 2000, to: 1996)
        if state != "asking" { for index in steps.indices.dropFirst() { steps[index].detail = nil } }
        switch state {
        case "asking":
            phase = .asking
        case "waiting":
            set(.drain, .active, "Finishing replies on Finance and Gym · up to 32 min", from: 75)
            phase = .working
        case "installing":
            set(.drain, .done, from: 410, to: 95)
            set(.install, .active, Self.installing, from: 95)
            phase = .working
        case "restarting":
            set(.drain, .skipped, from: 240, to: 240)
            set(.install, .done, from: 240, to: 40)
            set(.restart, .active, Self.restarting(name), from: 40)
            phase = .working
        case "updated", "unchanged":
            set(.drain, .done, from: 600, to: 300)
            set(.install, .done, from: 300, to: 90)
            set(.restart, .done, from: 90, to: 20)
            set(.confirm, .done, from: 20, to: 14)
            phase = .ended(state == "updated" ? .updated(to: "0.23.0") : .unchanged(version: "0.22.5"))
            if state == "unchanged" { note = "Hermes says it installed 0.23.0, but \(name) still reports 0.22.5. Restarting Hermes may finish it." }
        case "cant":
            steps = [steps[0]]
            phase = .ended(.cantUpdateHere(method: HermesInstallWords.method("docker") ?? "", command: "docker compose pull && docker compose up -d"))
        case "uptodate":
            steps = [steps[0]]
            to = nil
            phase = .ended(.upToDate(version: "0.23.0"))
        case "failed":
            set(.drain, .skipped, from: 200, to: 200)
            set(.install, .failed, from: 200, to: 60)
            phase = .ended(.failed(reason: "Update pulled new code, but restoring local changes hit conflicts. Hermes kept the old version running."))
            let lines = ["⚕ Updating Hermes Agent…", "→ Fetching origin…", "→ Restoring local changes…",
                         "✗ Update pulled new code, but restoring local changes hit conflicts."]
            let run = GatewayActionRun(status: { _ in GatewayActionStatus(name: "hermes-update", running: false, exitCode: 1, lines: lines) })
            run.start { "hermes-update" }
            action = run
        default:
            return false
        }
        return true
    }
}
#endif

/// [update-flow] "Update Hermes" under a "too old" message: the one Update sheet for the gateway in use. Draws nothing
/// on a read-only gateway or with none in use.
struct HermesUpdateButton: View {
    var body: some View {
        if let app = MainTabController.current?.services as? AppModel, let account = app.account, !app.readOnlyGateway {
            Button("Update Hermes") { HermesUpdateCenter.shared.update(account, from: nil) }
                .accessibilityIdentifier("hermes-update.open")
        }
    }
}
