// Connect Apps (docs/spec/3x-capabilities.md §10): the model behind the sheet. Setup and connecting never write to the
// gateway; only the Bots page does (turning a bot on gives it the `composio` server and the key in its env).

import Observation
import UIKit

enum ConnectAppsFeature {
    /// DECISION 10.1-a: a compile-time constant; a DEBUG launch argument `-composioConnect NO` hides the row for tests.
    static var isOn: Bool {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "composioConnect") == "NO" { return false }
        #endif
        return true
    }
}

@MainActor @Observable
final class ComposioModel {
    enum Phase: Equatable { case loading, setup, ready, failed(String) }
    struct Notice: Equatable { var title: String; var message: String; var isError: Bool }
    enum BotState: Equatable { case on, off, failed(on: Bool, reason: String) }

    let services: any AppServices
    @ObservationIgnored let keys: ComposioKeychain
    @ObservationIgnored let client: ComposioClient
    @ObservationIgnored weak var presenter: UIViewController?

    var phase = Phase.loading
    var session: ComposioSession?
    var record: ComposioRecord?
    var setupNotice: Notice?
    var settingUp = false
    var gatewayKeyProfile: String?

    // Home
    var connected: [ComposioToolkit]?
    var connectedError: String?
    var popular: [ComposioToolkit]?
    var query = "" { didSet { if query != oldValue { searchChanged() } } }
    var results: [ComposioToolkit]? { get { shown(allResults) } set { allResults = newValue } }
    private var allResults: [ComposioToolkit]?
    var searchError: String?
    /// §10.13: apps Composio gives no sign-in for (OAuth only, none managed), and the apps the owner made their own
    /// auth config for. Both empty until read; a failed read leaves every app showing.
    var needsOwnApp: Set<String> = []
    var ownAuthConfigs: Set<String> = []
    @ObservationIgnored private var signInRulesRead: Date?
    @ObservationIgnored private var searchGeneration = 0

    // An app's page (§10.11, §10.12)
    /// Every account of an app by slug, oldest first; an app is missing until read.
    var appAccounts: [String: [ComposioAccount]] = [:]
    /// Who each account is signed in as, by account id; kept on this device (`connectapps.identities.<account>`) so a
    /// page opens with the addresses it showed last time.
    var identities: [String: ComposioIdentity] = [:]
    /// Accounts asked about since launch (or since the page last asked): not asked again until the list reloads them.
    @ObservationIgnored private var identityAsked: Set<String> = []
    @ObservationIgnored private var identitiesRead = false

    // Bots
    var botStates: [String: BotState]?
    var botBusy: Set<String> = []
    var applyingAll = false
    var botsNotice: Notice?

    init(services: any AppServices, keys: ComposioKeychain = ComposioKeychain(), client: ComposioClient? = nil) {
        self.services = services
        self.keys = keys
        self.client = client ?? ComposioClient(keys: keys)
    }

    var store: CapabilitiesStore? { (services as? SettingsServices)?.capabilities as? CapabilitiesStore }
    var gateway: ComposioGateway? { store.map(ComposioGateway.init) }
    var readOnly: Bool { store?.readOnlyGateway ?? true }
    var accountId: String { services.account?.id ?? "" }
    var bots: [Bot] {
        services.bots.filter { !$0.hidden }.sorted { a, b in
            a.id == "default" ? true : b.id == "default" ? false : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
    var allBots: Bool { record?.allBots ?? false }
    var onBots: [Bot] { bots.filter { botStates?[$0.id] == .on } }

    // MARK: Session cache (no key in it)

    private var cacheKey: String { "connectapps.session.\(accountId)" }
    private var cached: (user: String, session: String)? {
        guard let map = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String], let user = map["userId"], let session = map["sessionId"] else { return nil }
        return (user, session)
    }
    private func cache(_ session: ComposioSession, user: String) {
        UserDefaults.standard.set(["userId": user, "sessionId": session.id], forKey: cacheKey)
    }

    // MARK: Opening

    func start() async {
        phase = .loading
        let startedAt = ContinuousClock.now
        guard keys.status().saved else {
            phase = .setup
            await findGatewayKey()
            AppLog.trace("connect", "composio start: no key saved, found gateway key profile=\(gatewayKeyProfile != nil)")
            return
        }
        do throws(ComposioError) {
            // [perf] With a session kept from last time, Composio is asked for it while the gateway's record is read.
            // Its answer counts only when the record names that same session and user (the record wins).
            let cached = self.cached, client = self.client
            let early = cached.map { cached in
                Task { () -> Result<ComposioSession, ComposioError> in
                    do throws(ComposioError) { return .success(try await client.readSession(cached.session)) } catch { return .failure(error) }
                }
            }
            defer { early?.cancel() }
            let record = try? await gateway?.record()
            self.record = record
            let user = record?.userId ?? cached?.user ?? ComposioRecord.newUserID()
            let known = record?.sessionId.isEmpty == false ? record?.sessionId : cached?.session
            if let early, let cached, known == cached.session, user == cached.user {
                switch await early.value {
                case .success(let made): session = made
                case .failure(let error) where error.kind == .notFound: session = try await created(user: user)
                case .failure(let error): throw error
                }
            } else {
                session = try await sessionFor(user: user, known: known)
            }
            if let session { cache(session, user: user) }
            phase = .ready
            async let home: Void = loadHome()
            async let states: Void = loadBots()
            _ = await (home, states)
            AppLog.trace("connect", "composio start ok in \(AppLog.ms(since: startedAt)) ms")
        } catch let error {
            if error.kind == .badKey || error.kind == .noKey { phase = .setup; setupNotice = Notice(title: "Key Not Accepted", message: error.message, isError: true) }
            else if error.kind == .network { phase = .failed("\(error.message). Check your connection, then try again.") }
            else { phase = .failed(error.message) }
            AppLog.note("connect", "composio start failed after \(AppLog.ms(since: startedAt)) ms: \(error.kind)")
        }
    }

    /// The record's session if Composio still has it, else a new one for the same user (never a new user id while a record exists).
    private func sessionFor(user: String, known: String?) async throws(ComposioError) -> ComposioSession {
        if let known, !known.isEmpty {
            do { return try await client.readSession(known) }
            catch let error where error.kind == .notFound {}
        }
        return try await created(user: user)
    }

    /// A new session (multi-account, §10.11), remembered as such when Composio's answer doesn't say.
    private func created(user: String) async throws(ComposioError) -> ComposioSession {
        let made = try await client.createSession(userID: user)
        noteMultiAccount(made)
        return made
    }

    /// Whether a bot on this gateway already holds a key (shows "Use the Key on Your Gateway").
    private func findGatewayKey() async {
        guard let gateway else { return }
        for bot in bots.prefix(12) {
            if let server = try? await gateway.server(bot.id), server.url != nil || server.transport == "http" { gatewayKeyProfile = bot.id; return }
        }
    }

    // MARK: Setup (§10.4): never writes to the gateway

    func setUp(typed: String?) {
        guard !settingUp else { return }
        Task { await runSetUp(typed: typed) }
    }

    /// The work of `setUp`, awaitable (tests). A key Composio refuses is never saved, and never costs the key already
    /// saved: only Remove Composio, or the saved key itself being refused on a read, clears the Keychain.
    func runSetUp(typed: String?) async {
        guard !settingUp else { return }
        settingUp = true
        setupNotice = nil
        let start = ContinuousClock.now
        let fromGateway = typed == nil
        do {
            defer { settingUp = false }
            var key = typed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if typed == nil {
                do {
                    guard let profile = gatewayKeyProfile, let revealed = try await gateway?.revealKey(profile), !revealed.isEmpty else {
                        fail("Couldn’t Set Up Composio", "No bot on your gateway holds a Composio key now. Paste yours instead."); return
                    }
                    key = revealed
                } catch let error as HTTPError where error.status == 429 {
                    fail("Couldn’t Set Up Composio", "Your gateway is busy. Wait half a minute, then try again."); return
                } catch {
                    fail("Couldn’t Set Up Composio", CapabilitiesStore.detail(error)); return
                }
            }
            guard ComposioKeychain.plausible(key) else { fail("Key Not Accepted", "That doesn’t look like a Composio key."); return }
            do {
                let record = (try? await gateway?.record()) ?? nil
                self.record = record
                let user = record?.userId ?? cached?.user ?? ComposioRecord.newUserID()
                let known = record?.sessionId ?? cached?.session
                let made = try await client.check(key: key, userID: user, session: known)
                if made.id != known { noteMultiAccount(made) }   // made just now, so multi-account
                try keys.save(key)
                ComposioReconciler.shared.keySaved()
                key = ""
                session = made
                cache(made, user: user)
                Haptics.play(.success)
                phase = .ready
                async let home: Void = loadHome()
                async let states: Void = loadBots()
                _ = await (home, states)
                AppLog.trace("connect", "composio setup ok in \(AppLog.ms(since: start)) ms, fromGateway=\(fromGateway)")
            } catch let error as ComposioError {
                fail(error.kind == .badKey ? "Key Not Accepted" : "Couldn’t Set Up Composio", error.message)
                AppLog.note("connect", "composio setup failed after \(AppLog.ms(since: start)) ms: \(error.kind)")
            } catch {
                fail("Couldn’t Set Up Composio", "This \(DeviceWord.name) couldn’t save the key.")
                AppLog.note("connect", "composio setup failed after \(AppLog.ms(since: start)) ms: \(type(of: error))")
            }
        }
    }

    private func fail(_ title: String, _ message: String) {
        Haptics.play(.error)
        setupNotice = Notice(title: title, message: message, isError: true)
        HQAnnounce.say("\(title). \(message)")
    }

    // MARK: Home (§10.5)

    /// The apps the lists can show (§10.13).
    func shown(_ items: [ComposioToolkit]?) -> [ComposioToolkit]? {
        items?.filter { !ComposioSignIn.hidden($0, needsOwnApp: needsOwnApp, configured: ownAuthConfigs) }
    }

    /// Reads which apps need the owner's own OAuth app (the catalog, kept on this device for a day) and which they set
    /// one up for (each load). Runs beside the home's own reads; any failure shows every app, as before.
    func loadSignInRules() async {
        if let read = signInRulesRead, Date().timeIntervalSince(read) < 600 { return }
        let start = ContinuousClock.now, client = self.client
        signInRulesRead = Date()
        async let configs: Set<String>? = { do throws(ComposioError) { return try await client.appsWithOwnAuthConfig() } catch { return nil } }()
        var catalog: Set<String>?
        if let saved = UserDefaults.standard.dictionary(forKey: Self.catalogKey), let at = saved["at"] as? Date,
           Date().timeIntervalSince(at) < 86_400, let slugs = saved["slugs"] as? [String] {
            catalog = Set(slugs)
        } else {
            do throws(ComposioError) {
                let fresh = try await client.appsNeedingOwnSignIn()
                UserDefaults.standard.set(["at": Date(), "slugs": fresh.sorted()], forKey: Self.catalogKey)
                catalog = fresh
            } catch {
                AppLog.note("connect", "composio catalog read failed: \(error.kind); every app shows")
            }
        }
        let own = await configs
        if own == nil { AppLog.note("connect", "composio auth configs read failed; every app shows") }
        if let catalog, let own {
            needsOwnApp = catalog
            ownAuthConfigs = own
        } else {
            signInRulesRead = nil   // asked again on the next load
        }
        AppLog.trace("connect", "composio sign-in rules: \(needsOwnApp.count) apps need an own app, \(ownAuthConfigs.count) set up, in \(AppLog.ms(since: start)) ms")
    }

    static let catalogKey = "connectapps.needs-own-app"

    func loadHome() async {
        guard let session else { return }
        Task { await loadSignInRules() }
        connectedError = nil
        let start = ContinuousClock.now
        do {
            // Every page of connected apps (limit 50, up to 10 pages).
            var all: [ComposioToolkit] = [], cursor = ""
            for _ in 0..<10 {
                let page = try await client.toolkits(session: session.id, cursor: cursor, limit: 50, connectedOnly: true)
                all += page.items.filter { $0.connected && !all.map(\.slug).contains($0.slug) }
                cursor = page.next
                if cursor.isEmpty { break }
            }
            connected = all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            AppLog.trace("connect", "composio connected apps loaded in \(AppLog.ms(since: start)) ms: \(all.count)")
        } catch {
            connectedError = error.message
            if connected == nil { connected = [] }
            AppLog.note("connect", "composio connected apps load failed after \(AppLog.ms(since: start)) ms: \(error.kind)")
        }
        if let page = try? await client.toolkits(session: session.id, slugs: ComposioCatalog.popular, limit: 30) {
            let order = Dictionary(uniqueKeysWithValues: ComposioCatalog.popular.enumerated().map { ($1, $0) })
            popular = page.items.sorted { (order[$0.slug] ?? 99) < (order[$1.slug] ?? 99) }
        } else if popular == nil {
            popular = []
        }
    }

    var popularShown: [ComposioToolkit] {
        let taken = Set((connected ?? []).map(\.slug))
        return Array((shown(popular) ?? []).filter { !taken.contains($0.slug) }.prefix(ComposioCatalog.popularShown))
    }

    private func searchChanged() {
        searchGeneration += 1
        let generation = searchGeneration
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchError = nil
        guard !q.isEmpty, let session else { results = nil; return }
        results = nil
        let sessionId = session.id
        Task { await runSearch(q, session: sessionId, generation: generation) }
    }

    /// The search itself, 300 ms after the last keystroke. A method of its own rather than the task's closure: the
    /// Release optimizer of Swift 6.4 crashed on the closure (CopyPropagation, an ownership check), which stopped
    /// every archive.
    private func runSearch(_ q: String, session: String, generation: Int) async {
        try? await Task.sleep(for: .milliseconds(300))
        guard generation == searchGeneration else { return }
        let found: Result<[ComposioToolkit], Error>
        do { found = .success(try await client.toolkits(session: session, search: q, limit: 30).items) }
        catch { found = .failure(error) }
        guard generation == searchGeneration else { return }   // an answer for an older query is dropped
        switch found {
        case .success(let items): results = items
        case .failure(let error):
            searchError = (error as? ComposioError)?.message ?? ComposioError.problem.message
            results = []
        }
    }

    func toolkit(_ slug: String) -> ComposioToolkit? {
        (connected ?? []).first { $0.slug == slug } ?? (popular ?? []).first { $0.slug == slug } ?? (results ?? []).first { $0.slug == slug }
    }

    // MARK: Bots (§10.7)

    func loadBots() async {
        guard let gateway else { botStates = [:]; return }
        if let fresh = try? await gateway.record() { record = fresh }
        var states: [String: BotState] = botStates ?? [:]
        let ids = bots.map(\.id)
        var index = 0
        while index < ids.count {
            let slice = Array(ids[index..<min(index + 3, ids.count)])
            index += 3
            let answers: [(String, Bool?)] = await Together.run(slice) { id in
                do { return try await gateway.server(id) != nil } catch { return nil }
            }
            for (id, on) in answers {
                guard let on else { continue }
                if case .failed = states[id], !on { continue }
                states[id] = on ? .on : .off
            }
        }
        botStates = states
    }

    func setBot(_ bot: Bot, on: Bool) {
        guard !botBusy.contains(bot.id), !readOnly else { return }
        Haptics.play(.selection)
        botBusy.insert(bot.id)
        Task {
            defer { botBusy.remove(bot.id) }
            await apply(bot.id, on: on)
        }
    }

    /// One bot, independent of the others: a failure shows on its row only.
    private func apply(_ profile: String, on: Bool) async {
        guard let gateway, let session else { return }
        let start = ContinuousClock.now
        let tag = AppLog.tag(profile)
        do {
            if on {
                guard let key = keys.read() else { throw ComposioError.noKey }
                try await gateway.turnOn(profile, key: key, mcpURL: session.mcpURL)
                if record == nil {
                    let fresh = ComposioRecord(userId: session.userID.isEmpty ? (cached?.user ?? ComposioRecord.newUserID()) : session.userID,
                                               sessionId: session.id, allBots: false)
                    try await gateway.write(fresh)
                    record = fresh
                }
            } else {
                try await gateway.turnOff(profile)
                ComposioVerified.settle(profile, account: accountId)   // the owner's own choice: the reconciler leaves this bot alone
            }
            botStates?[profile] = on ? .on : .off
            AppLog.trace("connect", "composio bot \(tag) set on=\(on) ok in \(AppLog.ms(since: start)) ms")
        } catch {
            Haptics.play(.error)
            let reason = (error as? ComposioError)?.message ?? (error as? BotWriteError)?.reason ?? McpEntryMask.phone.text(CapabilitiesStore.detail(error))
            botStates?[profile] = .failed(on: on, reason: reason)
            AppLog.note("connect", "composio bot \(tag) set on=\(on) failed after \(AppLog.ms(since: start)) ms: \(reason)")
        }
    }

    func setAllBots(_ on: Bool) {
        guard let gateway, let session, !applyingAll, !readOnly else { return }
        applyingAll = true
        ComposioBotsGate.applying = true
        botsNotice = nil
        let start = ContinuousClock.now
        Task {
            defer { applyingAll = false; ComposioBotsGate.applying = false }
            var next = record ?? ComposioRecord(userId: session.userID.isEmpty ? (cached?.user ?? ComposioRecord.newUserID()) : session.userID,
                                                sessionId: session.id, allBots: false)
            next.allBots = on
            next.sessionId = session.id
            do { try await gateway.write(next) }
            catch {
                Haptics.play(.error)
                botsNotice = Notice(title: "Couldn’t Change All Bots", message: (error as? BotWriteError)?.reason ?? CapabilitiesStore.detail(error), isError: true)
                AppLog.note("connect", "composio set all bots on=\(on) failed after \(AppLog.ms(since: start)) ms")
                return
            }
            record = next
            guard on else { Haptics.play(.success); AppLog.trace("connect", "composio set all bots off ok in \(AppLog.ms(since: start)) ms"); return }
            let pending = bots.map(\.id).filter { botStates?[$0] != .on }
            var index = 0
            while index < pending.count {   // three at a time
                let slice = Array(pending[index..<min(index + 3, pending.count)])
                index += 3
                botBusy.formUnion(slice)
                _ = await Together.run(slice) { id in await self.apply(id, on: true) }
                botBusy.subtract(slice)
            }
            let failed = pending.filter { if case .failed = botStates?[$0] { return true } else { return false } }.count
            if failed > 0 {
                Haptics.play(.warning)
                botsNotice = Notice(title: failed == 1 ? "1 Bot Not Updated Yet" : "\(failed) Bots Not Updated Yet",
                                    message: "Hermes HQ tries them again the next time it opens. Each one says why below.", isError: false)
            } else {
                Haptics.play(.success)
            }
            AppLog.trace("connect", "composio set all bots on in \(AppLog.ms(since: start)) ms, \(pending.count) bot(s), \(failed) failed")
        }
    }

    // MARK: Remove (§10.9)

    /// nil = all good; else the reason the gateway part failed (the phone side is cleared either way).
    func remove() async -> String? {
        var reason: String?
        let start = ContinuousClock.now
        if let gateway, !readOnly {
            if botStates == nil { await loadBots() }
            let on = bots.map(\.id).filter { botStates?[$0] != .off }
            var index = 0
            while index < on.count {
                let slice = Array(on[index..<min(index + 3, on.count)])
                index += 3
                let failures: [(String, String?)] = await Together.run(slice) { id in
                    do { try await gateway.turnOff(id); return nil } catch { return McpEntryMask.phone.text(CapabilitiesStore.detail(error)) }
                }
                for (_, failure) in failures { if let failure { reason = failure } }
            }
            do { try await gateway.write(nil) } catch { reason = reason ?? ((error as? BotWriteError)?.reason ?? CapabilitiesStore.detail(error)) }
        } else {
            reason = "this gateway is read-only"
        }
        keys.clear()
        UserDefaults.standard.removeObject(forKey: cacheKey)
        UserDefaults.standard.removeObject(forKey: ComposioVerified.key(accountId))
        UserDefaults.standard.removeObject(forKey: multiKey)
        UserDefaults.standard.removeObject(forKey: identityKey)
        identities = [:]
        UserDefaults.standard.removeObject(forKey: movingKey)
        ComposioReconciler.shared.stop()
        session = nil; record = nil; connected = nil; popular = nil; botStates = nil; results = nil
        phase = .setup
        if let reason {
            Haptics.play(.warning)
            setupNotice = Notice(title: "Removed From This \(DeviceWord.name) Only",
                                 message: "Hermes HQ couldn’t update every bot (\(reason)). If Capabilities › Connectors still lists “composio” on a bot, remove it there.",
                                 isError: false)
            AppLog.note("connect", "composio remove partial after \(AppLog.ms(since: start)) ms: \(reason)")
        } else {
            Haptics.play(.success)
            setupNotice = nil
            AppLog.trace("connect", "composio remove ok in \(AppLog.ms(since: start)) ms")
        }
        return reason
    }

    // MARK: Accounts: a second account of an app (§10.11)

    private var multiKey: String { "connectapps.multi.\(accountId)" }
    private var movingKey: String { "connectapps.moving.\(accountId)" }
    /// Sessions this app made multi-account whose answer didn't say so itself (ids only).
    var knownMultiAccount: Set<String> { Set(UserDefaults.standard.stringArray(forKey: multiKey) ?? []) }

    private func noteMultiAccount(_ made: ComposioSession) {
        guard made.multiAccount != false, !knownMultiAccount.contains(made.id) else { return }
        UserDefaults.standard.set(Array((knownMultiAccount.union([made.id])).sorted().suffix(8)), forKey: multiKey)
    }

    var userID: String { record?.userId ?? (session?.userID.isEmpty == false ? session?.userID : cached?.user) ?? "" }

    /// An app's accounts for this user, oldest first.
    func accounts(_ slug: String) async throws(ComposioError) -> [ComposioAccount] {
        guard !userID.isEmpty else { throw ComposioError.problem }
        return try await client.accounts(user: userID, toolkit: slug)
    }

    private var identityKey: String { "connectapps.identities.\(accountId)" }

    /// The saved identities, read once.
    func readIdentities() {
        guard !identitiesRead else { return }
        identitiesRead = true
        guard let data = UserDefaults.standard.data(forKey: identityKey),
              let saved = try? JSONDecoder().decode([String: ComposioIdentity].self, from: data) else { return }
        identities.merge(saved) { now, _ in now }
    }

    private func saveIdentities() {
        guard let data = try? JSONEncoder().encode(identities) else { return }
        UserDefaults.standard.set(data, forKey: identityKey)
    }

    /// An app's fresh account list (nil: unknown); what was saved about accounts that are gone is dropped.
    func setAccounts(_ slug: String, _ list: [ComposioAccount]?) {
        readIdentities()
        if let list {
            let ids = Set(list.map(\.id))
            let gone = (appAccounts[slug] ?? []).map(\.id).filter { !ids.contains($0) && identities[$0] != nil }
            for id in gone { identities[id] = nil }
            if !gone.isEmpty { saveIdentities() }
        }
        appAccounts[slug] = list
    }

    /// Asks the app who each signed-in account is (§10.12), all at once; a failure leaves what was known. Accounts
    /// that need a new sign-in are not asked (Composio refuses them). Run once per account per launch unless `again`.
    func loadIdentities(_ slug: String, accounts: [ComposioAccount], again: Bool = false) async {
        readIdentities()
        guard ComposioWhoAmI.entry(slug) != nil, !userID.isEmpty else { return }
        let ask = accounts.filter { $0.isActive && (again || !identityAsked.contains($0.id)) }
        guard !ask.isEmpty else { return }
        identityAsked.formUnion(ask.map(\.id))
        let start = ContinuousClock.now, client = self.client, user = userID
        let answers = await Together.run(ask.map(\.id)) { id -> Result<ComposioIdentity?, ComposioError> in
            do throws(ComposioError) { return .success(try await client.identity(account: id, toolkit: slug, user: user)) }
            catch { return .failure(error) }
        }
        var found = 0, failed = 0
        for (id, answer) in answers {
            switch answer {
            case .success(let identity?): identities[id] = identity; found += 1
            case .success(nil): break
            case .failure(let error):
                failed += 1
                identityAsked.remove(id)
                AppLog.note("connect", "composio \(slug) account \(AppLog.tag(id)) who-am-I failed: \(error.kind)")
            }
        }
        if found > 0 { saveIdentities() }
        AppLog.trace("connect", "composio \(slug) who-am-I: \(found) of \(ask.count) named, \(failed) failed, in \(AppLog.ms(since: start)) ms")
    }

    /// The bots to move to the new session: those with a `composio` server whose URL names another session (or none).
    nonisolated static func botsToMove(_ servers: [(profile: String, url: String?)], to session: String) -> [String] {
        servers.filter { ComposioSession.id(fromMcpURL: $0.url ?? "") != session }.map(\.profile)
    }

    /// The session, made multi-account first when it isn't. A session's multi-account setting is fixed when it's made,
    /// so an older one is replaced by a new one for the same user: every bot with Composio moves to the new MCP URL,
    /// then the gateway record names it. Connected accounts belong to the user, so they all carry over. Safe to stop and
    /// run again: the new session is kept aside until the record names it, and a bot already on it is left alone.
    func multiAccountSession() async throws -> ComposioSession {
        guard let current = session else { throw ComposioError.problem }
        if ComposioSession.isMultiAccount(current, known: knownMultiAccount) { return current }
        let start = ContinuousClock.now
        ComposioBotsGate.applying = true   // the reconciler waits
        defer { ComposioBotsGate.applying = false }
        let gateway = self.gateway
        let record = try await gateway?.record()
        if let record { self.record = record }
        let user = record?.userId ?? (current.userID.isEmpty ? cached?.user ?? "" : current.userID)
        guard !user.isEmpty else { throw ComposioError.problem }
        if record != nil, readOnly {
            throw ComposioError(kind: .rejected, message: "This gateway is read-only. Add another account from a gateway you can change.")
        }
        AppLog.trace("connect", "composio multi-account move started, record=\(record != nil)")
        // A session an earlier try made and didn't finish moving to.
        var next: ComposioSession?
        if let kept = UserDefaults.standard.dictionary(forKey: movingKey) as? [String: String], kept["userId"] == user, let id = kept["sessionId"],
           let found = try? await client.readSession(id), ComposioSession.isMultiAccount(found, known: knownMultiAccount) {
            next = found
            AppLog.trace("connect", "composio multi-account move resumes its kept session")
        }
        if next == nil {
            let made = try await created(user: user)
            guard ComposioSession.isMultiAccount(made, known: knownMultiAccount) else {
                throw ComposioError(kind: .rejected, message: "Composio didn’t allow more than one account per app.")
            }
            UserDefaults.standard.set(["userId": user, "sessionId": made.id], forKey: movingKey)
            next = made
        }
        guard let next else { throw ComposioError.problem }
        var moved = 0
        if let gateway {
            // Every bot, hidden ones too: one left on the old session would keep using only the newest account.
            let ids = services.bots.map(\.id)
            var servers: [(profile: String, url: String?)] = []
            var index = 0
            while index < ids.count {
                let slice = Array(ids[index..<min(index + 3, ids.count)])
                index += 3
                let answers: [(String, Result<McpServer?, Error>)] = await Together.run(slice) { id in
                    do { return .success(try await gateway.server(id)) } catch { return .failure(error) }
                }
                for (id, answer) in answers {
                    switch answer {
                    case .success(let server): if let server { servers.append((id, server.url)) }
                    case .failure(let error): throw error   // unknown = not safe to name the new session yet
                    }
                }
            }
            let pending = Self.botsToMove(servers, to: next.id)
            if !pending.isEmpty {
                guard let key = keys.read() else { throw ComposioError.noKey }
                var failed: [String] = []
                index = 0
                while index < pending.count {
                    let slice = Array(pending[index..<min(index + 3, pending.count)])
                    index += 3
                    let answers: [(String, String?)] = await Together.run(slice) { id in
                        do { try await gateway.turnOn(id, key: key, mcpURL: next.mcpURL); return nil }
                        catch { return (error as? BotWriteError)?.reason ?? McpEntryMask.phone.text(CapabilitiesStore.detail(error)) }
                    }
                    for (id, failure) in answers { if let failure { failed.append(failure); AppLog.note("connect", "composio multi-account move: bot \(AppLog.tag(id)) failed: \(failure)") } }
                }
                moved = pending.count - failed.count
                if let reason = failed.first {
                    throw ComposioError(kind: .rejected, message: failed.count == 1 ? "1 bot couldn’t be updated (\(reason)). Try again."
                                        : "\(failed.count) bots couldn’t be updated (\(reason)). Try again.")
                }
            }
            if record != nil || !servers.isEmpty {
                var fresh = record ?? ComposioRecord(userId: user, sessionId: next.id, allBots: false)
                fresh.sessionId = next.id
                try await gateway.write(fresh)
                self.record = fresh
            }
        }
        session = next
        cache(next, user: user)
        UserDefaults.standard.removeObject(forKey: movingKey)
        AppLog.trace("connect", "composio multi-account move ok in \(AppLog.ms(since: start)) ms: \(moved) bot(s) moved")
        return next
    }

    // MARK: Words

    var botsRow: (title: String, subtitle: String, choose: Bool) {
        guard botStates != nil else { return ("Checking bots…", "", false) }
        let total = bots.count, on = onBots
        if allBots { return ("Used by all bots", "\(total == 1 ? "1 bot" : "\(total) bots"), including new ones", false) }
        if on.isEmpty { return ("No bots use your apps yet", "Choose Bots", true) }
        return ("Used by \(ComposioCatalog.nameList(on.map(\.name)))", "\(on.count) of \(total == 1 ? "1 bot" : "\(total) bots")", false)
    }
}

// MARK: - Connecting (§10.8, port of ref:src/composio/connect.ts)

@MainActor @Observable
final class ComposioConnect {
    enum Phase: Equatable { case idle, preparing, link, signIn, checking }
    /// `needsOwnApp`: Composio provides no sign-in for the app and the owner set none up (§10.13).
    enum Outcome: Equatable { case connected, failed(String), unfinished, needsOwnApp }

    static let callbackWait: TimeInterval = 20
    static let cancelWait: TimeInterval = 4
    /// One connect at a time.
    static private(set) var running = false
    /// Tests drive the consent page with URLSession instead of the system sheet: (link, scheme) → the callback URL.
    static var driver: ((URL, String) async -> URL?)?

    var phase = Phase.idle
    var outcome: Outcome? {
        // Every way a connect can fail ends here: the error tap with the red line (success plays its own above).
        didSet { if case .failed = outcome, outcome != oldValue { Haptics.play(.error) } }
    }
    @ObservationIgnored private var authSession: NSObject?
    @ObservationIgnored private var provider: WebAuthAnchorProvider?
    @ObservationIgnored private var cancelled = false

    static var callback: String { "\(AppIdentity.current.urlScheme)://composio/callback" }

    var label: String? {
        switch phase {
        case .idle: nil
        case .preparing: "Getting ready…"
        case .link: "Opening…"
        case .signIn: "Signing in…"
        case .checking: "Checking…"
        }
    }

    /// Popping the page ends the auth session; the flow ends as unfinished without an alert.
    func cancel() {
        cancelled = true
        if let authSession { WebAuthRuntime.cancel(authSession) }
        authSession = nil
    }

    /// With an `alias`, this signs in to another account of the app under that name; `prepare` runs first and gives
    /// the session to use (the multi-account one, §10.11).
    func run(client: ComposioClient, session: String, slug: String, alias: String? = nil, window: UIWindow?,
             prepare: (@MainActor () async throws -> String)? = nil) async {
        guard !Self.running else { return }
        Self.running = true
        cancelled = false
        outcome = nil
        let start = ContinuousClock.now
        defer {
            Self.running = false; phase = .idle; authSession = nil
            AppLog.trace("connect", "composio connect \(slug) ended \(String(describing: outcome)) in \(AppLog.ms(since: start)) ms, named=\(alias != nil)")
        }
        var session = session
        if let prepare {
            phase = .preparing
            do { session = try await prepare() }
            catch {
                outcome = .failed((error as? ComposioError)?.message ?? (error as? BotWriteError)?.reason ?? McpEntryMask.phone.text(CapabilitiesStore.detail(error)))
                return
            }
            if cancelled { outcome = .unfinished; return }
        }
        phase = .link
        let link: ConnectLink
        do {
            do { link = try await client.link(session: session, toolkit: slug, alias: alias, callback: Self.callback) }
            catch let error where error.kind == .rejected && error.message.lowercased().contains("callback") {
                link = try await client.link(session: session, toolkit: slug, alias: alias, callback: nil)
            }
        } catch {
            outcome = ComposioSignIn.isOwnAppRefusal(error) ? .needsOwnApp : .failed(error.message)
            return
        }
        // Single-use: validated, then opened exactly once. Never prefetched or previewed.
        guard let url = ComposioClient.connectLink(link.redirectURL) else { outcome = .failed(ComposioError.problem.message); return }
        phase = .signIn
        let returned = await open(url, window: window)
        if cancelled { outcome = .unfinished; return }
        phase = .checking
        let items = returned.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        let status = items.first { $0.name == "status" }?.value?.lowercased() ?? ""
        let id = items.first { $0.name == "connected_account_id" }?.value.flatMap { $0.isEmpty ? nil : $0 } ?? link.accountID
        guard !id.isEmpty else { outcome = .failed("Composio lost this sign-in. Try again."); return }
        let declined = status == "failed" || status == "error"
        let deadline = Date().addingTimeInterval(returned != nil ? Self.callbackWait : Self.cancelWait)
        while true {
            do {
                let account = try await client.account(id)
                if account.isActive { Haptics.play(.success); outcome = .connected; return }
                if declined { outcome = .failed(account.reason.isEmpty ? "The sign-in was declined." : account.reason); return }
                if account.status == "FAILED" || account.status == "EXPIRED" {
                    outcome = .failed(account.reason.isEmpty ? "The sign-in didn’t finish. Try again." : account.reason); return
                }
            } catch let error where error.kind == .notFound {
                outcome = .failed(declined ? "The sign-in was declined." : "Composio lost this sign-in. Try again."); return
            } catch {}   // a failed read is tried again on the next tick
            if cancelled { outcome = .unfinished; return }
            if Date() >= deadline {
                outcome = returned != nil ? .failed("Composio is still finishing this sign-in. Check again in a moment.") : .unfinished
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// The system sign-in sheet (never a web view): returns the callback URL, or nil when the person closed it.
    private func open(_ url: URL, window: UIWindow?) async -> URL? {
        if let driver = Self.driver { return await driver(url, AppIdentity.current.urlScheme) }
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            let once = Once(continuation)
            let handler: @convention(block) @Sendable (NSURL?, NSError?) -> Void = { url, _ in
                let value = url as URL?
                Task { @MainActor in once.resume(value) }
            }
            guard let session = WebAuthRuntime.makeSession(url: url, customScheme: AppIdentity.current.urlScheme, handler: handler) else {
                once.resume(nil); return
            }
            let provider = WebAuthAnchorProvider(anchor: window)
            self.provider = provider
            session.setValue(provider, forKey: "presentationContextProvider")
            session.setValue(false, forKey: "prefersEphemeralWebBrowserSession")
            authSession = session
            if !WebAuthRuntime.start(session) { once.resume(nil) }
        }
    }

    @MainActor private final class Once {
        private var continuation: CheckedContinuation<URL?, Never>?
        init(_ continuation: CheckedContinuation<URL?, Never>) { self.continuation = continuation }
        func resume(_ value: URL?) { continuation?.resume(returning: value); continuation = nil }
    }
}

// MARK: - Reconciler (§10.7)

/// While "All Bots" is on, a bot that has no `composio` server yet gets one. It never removes anything by itself, runs
/// only with a key in this iPhone's Keychain, a live link and a gateway that can be changed (DECISION 10.7-a).
@MainActor final class ComposioReconciler {
    static let shared = ComposioReconciler()
    private weak var model: AppModel?
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var rosterCount = -1
    private var changedAt: Date?
    private var tries = 0
    private var retryAt: Date?
    private var account = ""
    /// Whether this device's Keychain holds the key: read at start and on each return to the app, and set when Connect
    /// Apps saves one. Not read on every tick: with no key, that was a Keychain read every 2 s for as long as the app ran.
    private var hasKey = false

    func start(model: AppModel) {
        stop()
        guard ConnectAppsFeature.isOn else { return }
        self.model = model
        account = model.account?.id ?? ""
        hasKey = ComposioKeychain().status().saved
        tries = 0; retryAt = nil; rosterCount = -1; changedAt = Date()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() { timer?.invalidate(); timer = nil; task?.cancel(); task = nil }

    func appActive() {
        if timer != nil { hasKey = ComposioKeychain().status().saved }
        if retryAt != nil { retryAt = Date() }
    }

    func keySaved() { hasKey = true }


    private func tick() {
        guard let model, task == nil, model.connection == .ready, !model.readOnlyGateway, UIApplication.shared.applicationState == .active,
              !ComposioBotsGate.applying else { return }
        let count = model.bots.count
        if count != rosterCount { rosterCount = count; changedAt = Date() }
        // A bot that left the roster is forgotten, so one made again under the same id is checked afresh. Only with a
        // loaded, non-empty roster: a list still loading must not forget anybody.
        let verified = ComposioVerified.pruned(ComposioVerified.read(account), roster: model.bots.map(\.id))
        if !model.bots.isEmpty { ComposioVerified.write(verified, account: account) }
        let missing = model.bots.map(\.id).filter { !verified.contains($0) }
        guard !missing.isEmpty else { return }
        if let changedAt, Date().timeIntervalSince(changedAt) < 2 { return }           // 2 s debounce
        if let retryAt, Date() < retryAt { return }
        guard tries < 6, hasKey else { return }
        guard let store = model.settingsHub.capabilitiesStore else { return }
        let account = account
        let start = ContinuousClock.now
        AppLog.trace("connect", "composio reconciler started for \(missing.count) bot(s) missing the server, try \(tries + 1)")
        task = Task { [weak self] in
            defer { self?.task = nil }
            let keys = ComposioKeychain()
            let gateway = ComposioGateway(store: store)
            guard let record = try? await gateway.record(), record.allBots, !record.sessionId.isEmpty else {
                self?.changedAt = nil; self?.retryAt = Date().addingTimeInterval(60)
                AppLog.trace("connect", "composio reconciler stopped: all-bots record is gone")
                return
            }
            guard let session = try? await ComposioClient(keys: keys).readSession(record.sessionId), let secret = keys.read() else {
                self?.backOff()
                AppLog.note("connect", "composio reconciler couldn't read its session or key, backing off")
                return
            }
            var done = verified, failed = false
            var index = 0
            while index < missing.count, !Task.isCancelled {
                let slice = Array(missing[index..<min(index + 2, missing.count)])   // two at a time
                index += 2
                for profile in slice {
                    do {
                        if try await gateway.server(profile) == nil { try await gateway.turnOn(profile, key: secret, mcpURL: session.mcpURL) }
                        done.insert(profile)
                    } catch { failed = true }
                }
            }
            // Merge, not overwrite: the Bots page may have settled a bot while this pass ran.
            ComposioVerified.write(ComposioVerified.read(account).union(done), account: account)
            if failed { self?.backOff() } else { self?.tries = 0; self?.retryAt = nil }
            AppLog.trace("connect", "composio reconciler finished in \(AppLog.ms(since: start)) ms: \(done.count) of \(missing.count) done, failed=\(failed)")
        }
    }

    private func backOff() {
        tries += 1
        retryAt = Date().addingTimeInterval(30 * pow(2, Double(tries - 1)))
        if tries >= 6 { AppLog.note("connect", "composio reconciler gave up after 6 tries") }
    }
}

/// The bots the "All Bots" pass need not look at again, per account (ids only, in UserDefaults).
@MainActor enum ComposioVerified {
    static func key(_ account: String) -> String { "connectapps.verified.\(account)" }
    static func read(_ account: String) -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: key(account)) ?? []) }
    static func write(_ ids: Set<String>, account: String) {
        guard ids != read(account) else { return }
        UserDefaults.standard.set(ids.sorted(), forKey: key(account))
    }
    static func settle(_ profile: String, account: String) { write(read(account).union([profile]), account: account) }
    /// Ids no longer in the roster are dropped; an empty roster (still loading) drops nothing.
    nonisolated static func pruned(_ verified: Set<String>, roster: [String]) -> Set<String> {
        roster.isEmpty ? verified : verified.intersection(roster)
    }
}

/// The Bots page is applying: the reconciler waits.
@MainActor enum ComposioBotsGate { static var applying = false }

/// A few main-actor jobs at once (the gateway calls suspend, so they overlap), answers in the order asked.
@MainActor enum Together {
    static func run<T: Sendable>(_ ids: [String], _ work: @escaping @MainActor (String) async -> T) async -> [(String, T)] {
        let tasks = ids.map { id in (id, Task { @MainActor in await work(id) }) }
        var out: [(String, T)] = []
        for (id, task) in tasks { out.append((id, await task.value)) }
        return out
    }
}
