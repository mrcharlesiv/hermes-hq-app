// Managed apps for one bot (the desktop's `useHostedConnectors` + `account-operations.ts`): the four reads, the
// person's connection operations followed live, and the writes (connect, stop waiting, disconnect, the access
// switch). Nothing polls: an operation moves on the gateway's `connection.update` broadcasts, is read once when the
// sign-in sheet closes (after `operation.wake`) and once after each reconnect (`gateway.ready`).

import Observation
import UIKit

/// The sign-in page for one app's link. The system sheet by default; DEBUG UI tests swap in a driver.
@MainActor enum ManagedSignInBrowser {
    /// `isPrivate`: none of Safari's saved logins (`NousSheetLogin`), for the Nous sign-in only.
    static var make: (UIWindow?, _ isPrivate: Bool) -> any NousBrowser = { WebAuthBrowser(anchor: $0, isPrivate: $1) }

    /// The link must be https (loopback http only in DEBUG, for the stand-in gateway).
    nonisolated static func accepts(_ link: String) -> URL? {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(), url.host != nil else { return nil }
        if scheme == "https" { return url }
        #if DEBUG
        if scheme == "http", let host = url.host, host == "127.0.0.1" || host == "localhost" { return url }
        #endif
        return nil
    }
}

@MainActor @Observable
final class ManagedAppsModel {
    enum Phase: Equatable {
        case loading, ready, signedOut, unavailable, tooOld
        case failed(String)
    }

    var profile: String { didSet { if profile != oldValue { profileChanged() } } }
    // [perf] Every input of `apps` joins again when it changes, so a read of `apps` or `app(_:)` costs nothing.
    var phase = Phase.loading { didSet { rejoin() } }
    var catalog: [ConnectorCatalogRow] = [] { didSet { rejoin() } }
    var list: [ConnectorListRow] = [] { didSet { rejoin() } }
    var accounts: [ConnectorAccountRow] = [] { didSet { rejoin() } }
    var policy = ConnectorPolicyView.empty { didSet { rejoin() } }
    /// The rules could not be read: switches and tool lists are read-only, with this reason.
    var policyFailure: ConnectorFailure? { didSet { rejoin() } }
    var catalogFailure: ConnectorFailure?
    var operations: [String: ConnectionOperation] = [:]
    var abandoned: Set<String> = [] { didSet { rejoin() } }
    /// Apps with a connect, switch or disconnect on its way.
    var busy: Set<String> = []
    /// The switch's wanted value while its write is on its way.
    var pendingEnabled: [String: Bool] = [:]
    /// A one-line notice on the app's page (a refused write), by slug.
    var notices: [String: String] = [:]
    var readOnly = false
    /// [accounts] This Hermes names accounts (Rename, Add Another Account, Remove per account). False on a Hermes from
    /// before account names, or once it refused a rename as unknown: the page keeps the one-account layout then.
    var accountNames = false
    /// Bumped when a write or an operation settles: the app pages re-read their tool lists.
    var revision = 0

    @ObservationIgnored let api: ManagedConnectorsClient
    @ObservationIgnored weak var presenter: UIViewController?
    @ObservationIgnored private var cache: [String: Snapshot] = [:]
    @ObservationIgnored private var browser: (any NousBrowser)?
    @ObservationIgnored private var browserFor: String?
    @ObservationIgnored private var listening: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadedAt: Date?
    /// [perf] Where each slug sits in `apps`.
    @ObservationIgnored private var appIndex: [String: Int] = [:]
    /// The Connectors tab is the one showing on the Capabilities page (set by its model). With `presenter` in a
    /// window, a reconnect reads the apps again; otherwise the next appearance does.
    @ObservationIgnored var connectorsShowing = false

    private struct Snapshot {
        var phase: Phase
        var catalog: [ConnectorCatalogRow]
        var list: [ConnectorListRow]
        var accounts: [ConnectorAccountRow]
        var policy: ConnectorPolicyView
        var policyFailure: ConnectorFailure?
    }

    /// [nous-sign-in] Whether Hermes is signed in to Nous, and the phone's Sign In to Nous.
    let nous: NousAccountModel

    init(client: any GatewayClient, profile: String) {
        api = ManagedConnectorsClient(client: client)
        nous = NousAccountModel(client: client)
        self.profile = profile
        listen()
        nous.onSignedIn = { [weak self] in self?.load(force: true) }
    }

    // MARK: Derived

    private(set) var apps: [ManagedApp] = []

    private func rejoin() {
        apps = phase == .ready
            ? ManagedJoin.apps(catalog: catalog, list: list, accounts: accounts, policy: policy, rulesReadable: policyFailure == nil,
                               abandoned: abandoned)
            : []
        appIndex = Dictionary(apps.enumerated().map { ($1.slug, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func app(_ slug: String) -> ManagedApp? { appIndex[slug].map { apps[$0] } }

    /// The open (or last) operation for an app (`accountOperationFor`).
    func operation(for slug: String) -> ConnectionOperation? {
        let mine = operations.values.filter { $0.connectors.contains(slug) }.sorted { $0.seq < $1.seq }
        return mine.first { !$0.settled } ?? mine.last
    }

    /// The sign-in for this app is still waiting on the browser (open, and its row not yet failed or expired).
    func waiting(_ slug: String) -> Bool {
        guard let operation = operation(for: slug), !operation.settled, !abandoned.contains(slug) else { return false }
        return operation.target(slug).map { $0.state == .pending || $0.state == .initiated } ?? true
    }

    var rulesWritable: Bool { !readOnly && policyFailure == nil && policy.memberRevision != nil }

    // MARK: Reads

    func load(force: Bool = false) {
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 30, phase == .ready { return }
        loadTask?.cancel()
        loadTask = Task { await reload() }
    }

    func reload() async {
        let profile = self.profile, api = self.api
        if phase != .ready, cache[profile] == nil { phase = .loading }
        let start = ContinuousClock.now
        async let listRead = Self.attempt { try await api.list(profile: profile) }
        async let catalogRead = Self.attempt { try await api.catalog(profile: profile) }
        async let accountsRead = Self.attempt { try await api.namedAccounts(profile: profile) }
        async let policyRead = Self.attempt { try await api.policy(profile: profile) }
        let (listed, cataloged, accounted, ruled) = await (listRead, catalogRead, accountsRead, policyRead)
        guard profile == self.profile, !Task.isCancelled else { return }
        switch listed {
        case .failure(let failure):
            // `hostedPhase`: signed out and unavailable are empty states, not failures; anything else keeps the last list.
            if failure.reason == .needsNousAuth { phase = .signedOut; clear() }
            else if failure.reason == .connectorsUnavailable { phase = .unavailable; clear() }
            else if failure.tooOld { phase = .tooOld; clear() }
            else if phase != .ready { phase = .failed(failure.words(fallback: "Couldn’t reach the managed apps.")) }
            AppLog.note("connect", "managed apps load failed after \(AppLog.ms(since: start)) ms: \(failure.reason?.rawValue ?? "unknown")")
            store(profile)
            return
        case .success(let result):
            guard result.available else { phase = .unavailable; clear(); store(profile); return }
            list = result.connectors
        }
        switch cataloged {
        case .success(let rows): catalog = rows; catalogFailure = nil
        case .failure(let failure): catalogFailure = failure
        }
        if case .success(let read) = accounted { accounts = read.rows; if let named = read.named { accountNames = named } }
        switch ruled {
        case .success(let view): policy = view; policyFailure = nil
        case .failure(let failure): policyFailure = failure
        }
        phase = .ready
        loadedAt = Date()
        store(profile)
        AppLog.trace("connect", "managed apps loaded in \(AppLog.ms(since: start)) ms: \(list.count) connector(s), \(accounts.count) account(s)")
    }

    nonisolated private static func attempt<T: Sendable>(_ work: @Sendable () async throws -> T) async -> Result<T, ConnectorFailure> {
        do { return .success(try await work()) } catch { return .failure(ConnectorFailure(error)) }
    }

    private func clear() {
        catalog = []; list = []; accounts = []; policy = .empty; policyFailure = nil; catalogFailure = nil
    }

    private func store(_ profile: String) {
        cache[profile] = Snapshot(phase: phase, catalog: catalog, list: list, accounts: accounts, policy: policy, policyFailure: policyFailure)
    }

    private func profileChanged() {
        loadTask?.cancel()
        if let kept = cache[profile] {
            phase = kept.phase; catalog = kept.catalog; list = kept.list; accounts = kept.accounts; policy = kept.policy
            policyFailure = kept.policyFailure
        } else {
            phase = .loading; clear()
        }
        abandoned = []; notices = [:]; loadedAt = nil; accountNames = false   // the Capabilities page reads it when the Connectors tab shows
    }

    /// The rules again (a conflict, a retry), without the other reads.
    func reloadPolicy() async {
        let profile = self.profile
        do {
            let view = try await api.policy(profile: profile)
            guard profile == self.profile else { return }
            policy = view; policyFailure = nil
        } catch {
            guard profile == self.profile else { return }
            policyFailure = ConnectorFailure(error)
        }
        store(profile)
    }

    private func reloadAccountsAndList() async {
        let profile = self.profile
        if let result = try? await api.list(profile: profile), profile == self.profile { list = result.connectors }
        if let read = try? await api.namedAccounts(profile: profile), profile == self.profile {
            accounts = read.rows
            if let named = read.named { accountNames = named }
        }
        guard profile == self.profile else { return }
        revision += 1
        store(profile)
    }

    // MARK: Following an operation

    private func listen() {
        let events = api.client.events()
        listening = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event.type {
                case "connection.update": self.applyBroadcast(event.payload)
                case "gateway.ready": await self.resync()
                default: break
                }
            }
        }
    }

    func stopListening() { listening?.cancel(); listening = nil }

    private func applyBroadcast(_ payload: JSONValue) {
        guard payload["owner"]?["type"]?.string == "account", let snapshot = ManagedWire.operation(payload),
              let held = operations[snapshot.opId], let next = held.applying(snapshot, broadcast: true) else { return }
        settle(next)
    }

    private func applyReply(_ snapshot: ConnectionOperation) {
        guard let held = operations[snapshot.opId], let next = held.applying(snapshot, broadcast: false) else { return }
        settle(next)
    }

    private func settle(_ next: ConnectionOperation) {
        let before = operations[next.opId]
        operations[next.opId] = next
        for slug in next.connectors {
            guard let target = next.target(slug) else { continue }
            if target.state != .initiated, target.state != .pending, browserFor == slug { closeBrowser() }
            if target.state == .connected, before?.target(slug)?.state != .connected {
                Haptics.play(.success)
                HQAnnounce.say("\(app(slug)?.name ?? ManagedWire.title(slug)) connected")
            }
        }
        if next.settled, before?.settled != true { Task { await reloadAccountsAndList() } }
    }

    /// After a reconnect: every open operation is read once (a broadcast may have been missed while the link was down).
    /// [perf] Only a page on screen reads the apps again; one left in a stack (another app tab, a page pushed over it)
    /// reads them when it shows again.
    private func resync() async {
        for operation in operations.values where !operation.settled { await sync(operation.opId) }
        guard phase != .loading else { return }
        if onScreen { load(force: true) } else { loadedAt = nil }
    }

    private var onScreen: Bool { connectorsShowing && presenter?.viewIfLoaded?.window != nil }

    private func sync(_ opId: String) async {
        guard let operation = operations[opId] else { return }
        do {
            applyReply(try await api.status(opId, connectors: operation.connectors, profile: profile))
        } catch {
            // The operation can settle and leave the gateway's registry between two reads: it ended.
            if ConnectorFailure(error).reason == .unknownOperation, var ended = operations[opId], !ended.settled {
                ended.settled = true
                operations[opId] = ended
                await reloadAccountsAndList()
            }
        }
    }

    // MARK: Connect

    /// `alias` names the account to add (Add Another Account) or repair; `connectionId` repairs an unnamed one.
    func connect(_ slug: String, reconnect: Bool = false, alias: String? = nil, connectionId: String? = nil) {
        guard !readOnly, !busy.contains(slug) else { return }
        let name = app(slug)?.name ?? ManagedWire.title(slug), profile = self.profile
        busy.insert(slug)
        notices[slug] = nil
        let start = ContinuousClock.now
        Task {
            defer { busy.remove(slug) }
            do {
                let operation = try await api.connect(slug, reconnect: reconnect, alias: alias, connectionId: accountNames ? connectionId : nil,
                                                      profile: profile)
                guard profile == self.profile else { return }
                abandoned.remove(slug)
                // A new operation replaces a settled one for the same app.
                operations = operations.filter { !$0.value.settled || !$0.value.connectors.contains(slug) }
                operations[operation.opId] = operation
                if operation.settled || operation.target(slug)?.state == .connected {
                    AppLog.trace("connect", "managed app \(slug) connect settled immediately in \(AppLog.ms(since: start)) ms")
                    settle(operation)
                    await reloadAccountsAndList()
                    return
                }
                if let link = operation.target(slug)?.connectURL ?? operation.link {
                    AppLog.trace("connect", "managed app \(slug) connect opened a sign-in link in \(AppLog.ms(since: start)) ms")
                    openLink(link, slug: slug, opId: operation.opId)
                }
            } catch {
                let failure = ConnectorFailure(error)
                // `LINK_STILL_VALID`: the link already minted is still good; open it again rather than refuse.
                if failure.reason == .linkStillValid, let held = operation(for: slug), let link = held.link {
                    AppLog.trace("connect", "managed app \(slug) connect reused the still-valid link after \(AppLog.ms(since: start)) ms")
                    openLink(link, slug: slug, opId: held.opId)
                    return
                }
                AppLog.note("connect", "managed app \(slug) connect failed after \(AppLog.ms(since: start)) ms: \(failure.reason?.rawValue ?? "unknown")")
                FailureAlert.present(title: "Couldn’t Connect \(name)", reason: failure.words(fallback: "Couldn’t start authorization for \(name)."),
                                     detail: failure.message, from: presenter, whole: true) {
                    self.connect(slug, reconnect: reconnect, alias: alias, connectionId: connectionId)
                }
            }
        }
    }

    // MARK: Named accounts (`AccountsSection`)

    /// Repairs one account: by its name, else (unnamed) by its id.
    func reconnect(_ account: ConnectorAccountRow) {
        connect(account.connector, reconnect: true, alias: account.alias, connectionId: account.alias == nil ? account.connectionId : nil)
    }

    /// `connectors.accounts.rename`. The row shows the new name at once; a refusal puts the old one back and answers
    /// the words to show (nil when saved).
    func rename(_ account: ConnectorAccountRow, to alias: String) async -> String? {
        guard !readOnly else { return BotWriteError.readOnlyReason }
        let profile = self.profile, before = account.alias
        write(alias: alias, on: account.connectionId)
        let start = ContinuousClock.now
        do {
            let row = try await api.rename(account.connectionId, alias: alias, profile: profile)
            guard profile == self.profile else { return nil }
            write(alias: row?.alias ?? alias, on: account.connectionId)
            Haptics.play(.success)
            store(profile)
            AppLog.trace("connect", "managed account \(account.connector) rename ok in \(AppLog.ms(since: start)) ms")
            return nil
        } catch {
            let failure = ConnectorFailure(error)
            guard profile == self.profile else { return nil }
            write(alias: before, on: account.connectionId)
            AppLog.note("connect", "managed account \(account.connector) rename failed after \(AppLog.ms(since: start)) ms: \(failure.reason?.rawValue ?? "unknown")")
            if failure.tooOld { accountNames = false; return ConnectorFailure.tooOldWords }
            if failure.reason == .connectionNotFound { await reloadAccountsAndList() }
            return AccountWords.refusal(failure)
        }
    }

    private func write(alias: String?, on connectionId: String) {
        guard let index = accounts.firstIndex(where: { $0.connectionId == connectionId }) else { return }
        accounts[index].alias = alias
    }

    /// Remove one account (`onRemove`); the app's other accounts stay connected.
    func remove(_ account: ConnectorAccountRow) {
        guard !readOnly else { return }
        let slug = account.connector, name = app(slug)?.name ?? ManagedWire.title(slug), profile = self.profile
        busy.insert(slug)
        let start = ContinuousClock.now
        Task {
            defer { busy.remove(slug) }
            do {
                try await api.remove(account.connectionId, profile: profile)
                Haptics.play(.success)
                await reloadAccountsAndList()
                AppLog.trace("connect", "managed account \(slug) removed in \(AppLog.ms(since: start)) ms")
            } catch {
                let failure = ConnectorFailure(error)
                if failure.reason == .connectionNotFound { await reloadAccountsAndList(); return }
                AppLog.note("connect", "managed account \(slug) remove failed after \(AppLog.ms(since: start)) ms: \(failure.reason?.rawValue ?? "unknown")")
                FailureAlert.present(title: "Couldn’t Remove the \(account.name) Account", reason: failure.words(fallback: "That change was not saved."),
                                     detail: failure.message, from: presenter, whole: true) { self.remove(account) }
            }
        }
    }

    /// "Open the Link Again".
    func openAgain(_ slug: String) {
        guard let operation = operation(for: slug), !operation.settled, let link = operation.link else { return }
        openLink(link, slug: slug, opId: operation.opId)
    }

    private func openLink(_ link: String, slug: String, opId: String) {
        guard let url = ManagedSignInBrowser.accepts(link) else {
            notices[slug] = "The sign-in link isn’t a secure web address, so it wasn’t opened."
            return
        }
        closeBrowser()
        let sheet = ManagedSignInBrowser.make(presenter?.view.window, false)
        browser = sheet
        browserFor = slug
        let profile = self.profile
        let opened = sheet.open(url) { [weak self] in
            // The person closed the page: read the account now (`hermes://connections/done` on the desktop).
            guard let self else { return }
            if self.browserFor == slug { self.browser = nil; self.browserFor = nil }
            Task {
                try? await self.api.wake(opId, profile: profile)
                await self.sync(opId)
            }
        }
        if !opened {
            browser = nil; browserFor = nil
            notices[slug] = "Couldn’t open the sign-in page. Try Open the Link Again."
        }
    }

    private func closeBrowser() {
        browser?.close()
        browser = nil
        browserFor = nil
    }

    /// "Stop Waiting" (`giveUp` / the card's `stopWaiting`): settle the operation and remove the half-made account.
    func stopWaiting(_ slug: String) {
        guard !readOnly else { return }
        let profile = self.profile
        abandoned.insert(slug)
        closeBrowser()
        AppLog.trace("connect", "managed app \(slug) sign-in: gave up waiting")
        Task {
            if let operation = operation(for: slug), !operation.settled {
                operations[operation.opId] = nil
                try? await api.giveUp(operation.opId, profile: profile)
                for target in operation.targets where target.state != .connected && !target.connectionId.isEmpty {
                    try? await api.remove(target.connectionId, profile: profile)
                }
            } else if let pending = ManagedJoin.account(accounts, slug), pending.status == "pending" {
                try? await api.remove(pending.connectionId, profile: profile)
            }
            await reloadAccountsAndList()
        }
    }

    func clearSettled(_ slug: String) {
        operations = operations.filter { !$0.value.settled || !$0.value.connectors.contains(slug) }
    }

    // MARK: Disconnect

    func disconnect(_ slug: String, done: @escaping () -> Void = {}) {
        guard !readOnly, let account = ManagedJoin.account(accounts, slug) else {
            notices[slug] = "Hermes has no account to disconnect here. Refresh the page and try again."
            return
        }
        let name = app(slug)?.name ?? ManagedWire.title(slug), profile = self.profile
        busy.insert(slug)
        let start = ContinuousClock.now
        Task {
            defer { busy.remove(slug) }
            do {
                try await api.remove(account.connectionId, profile: profile)
                clearSettled(slug)
                Haptics.play(.success)
                await reloadAccountsAndList()
                AppLog.trace("connect", "managed app \(slug) disconnect ok in \(AppLog.ms(since: start)) ms")
                done()
            } catch {
                let failure = ConnectorFailure(error)
                if failure.reason == .connectionNotFound { await reloadAccountsAndList(); done(); return }
                let words = failure.reason == .accountsUnavailable
                    ? "Nous could not remove this sign-in right now. Turn the app off with the switch instead, or try again later."
                    : failure.words(fallback: "That change was not saved.")
                AppLog.note("connect", "managed app \(slug) disconnect failed after \(AppLog.ms(since: start)) ms: \(failure.reason?.rawValue ?? "unknown")")
                FailureAlert.present(title: "Couldn’t Disconnect \(name)", reason: words, detail: failure.message, from: presenter, whole: true)
            }
        }
    }

    // MARK: The access switch

    /// `useConnectorSwitch`: one connector change against the member layer's revision. A conflict re-reads the rules
    /// and tries once more (an on/off is the same wish against any revision).
    func setEnabled(_ slug: String, _ enabled: Bool) {
        guard !readOnly, !busy.contains(slug) else { return }
        let name = app(slug)?.name ?? ManagedWire.title(slug), profile = self.profile
        Haptics.play(.selection)
        busy.insert(slug)
        pendingEnabled[slug] = enabled
        notices[slug] = nil
        let start = ContinuousClock.now
        Task {
            defer { busy.remove(slug); pendingEnabled[slug] = nil }
            do {
                try await writeEnabled(slug, enabled, profile: profile, retry: true)
                await reloadPolicy()
                await reloadAccountsAndList()
                AppLog.trace("connect", "managed app \(slug) set enabled=\(enabled) ok in \(AppLog.ms(since: start)) ms")
            } catch {
                let failure = ConnectorFailure(error)
                guard profile == self.profile else { return }
                AppLog.note("connect", "managed app \(slug) set enabled=\(enabled) failed after \(AppLog.ms(since: start)) ms: \(failure.reason?.rawValue ?? "unknown")")
                FailureAlert.present(title: "Couldn’t Change \(name)", reason: failure.words(fallback: "That change was not saved."),
                                     detail: failure.message, from: presenter, whole: true) { self.setEnabled(slug, enabled) }
            }
        }
    }

    private func writeEnabled(_ slug: String, _ enabled: Bool, profile: String, retry: Bool) async throws {
        if policy.memberRevision == nil { await reloadPolicy() }
        guard let revision = policy.memberRevision else {
            throw policyFailure ?? ConnectorFailure(reason: .policyUnavailable, code: nil, message: "no member revision")
        }
        do {
            try await api.setEnabled(slug, enabled: enabled, revision: revision, profile: profile)
        } catch {
            guard retry, ConnectorFailure(error).reason == .policyConflict else { throw error }
            AppLog.trace("connect", "managed app \(slug) set enabled hit a policy conflict, retrying once with the fresh revision")
            await reloadPolicy()
            try await writeEnabled(slug, enabled, profile: profile, retry: false)
        }
    }
}
