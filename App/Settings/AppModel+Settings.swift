// The app model's settings-stream side (spec 1x-settings): saved gateways (switch, rename, remove, news), the bot
// editing adapter over `BotStore`, Skills/Connectors over the client, and the gateway's Hermes version. `AppModel`
// holds one `SettingsHub` and calls three hooks from its own lifecycle (activate / foreground / background).

import UIKit

/// Everything the settings stream keeps for the app run.
@MainActor final class SettingsHub: GatewayAccounts {
    weak var model: AppModel?
    let switcher: GatewaySwitcherModel
    private(set) var capabilitiesStore: CapabilitiesStore?
    /// The gateway in use's config record (Settings' gateway pages), one per activation.
    private(set) var configStore: GatewayConfigStore?
    private(set) var version: String?
    private var versionReadAt: Date?
    private var versionFor: String?
    private var listeners: [UUID: @MainActor () -> Void] = [:]
    private(set) var switchingTo: String?
    /// Gateways being removed (their logout can take up to 6 s): their rows say "Removing…" and can't be switched to.
    private(set) var removing: Set<String> = []

    init(signIn: SignInService) {
        switcher = GatewaySwitcherModel(store: signIn.store, directory: AppModel.listsCacheDirectory)
        switcher.onChange = { [weak self] in self?.notify() }
        // AppModel calls `CompletionCue.turnEnded` for every live message.complete (its gateway event watch).
        SettingsHooks.completionCueWired = true
    }

    // MARK: Lifecycle (from AppModel)

    func activated(_ model: AppModel, account: GatewayAccount, client: LiveGatewayClient) {
        self.model = model
        switcher.currentId = { [weak model] in model?.account?.id }
        let store = CapabilitiesStore(client: client)
        store.readOnlyGateway = model.readOnlyGateway
        store.toolRuleVault = KeychainToolRuleVault(account: account.id)   // [capabilities] 3x §5.5-b recovery
        capabilitiesStore = store
        // [capabilities] 3x §8: this account's connector issues, and a sweep of every bot once the link is up.
        ServerIssues.shared.use(account: account.id)
        ServerIssueSweep.shared.start(model: model, store: store)
        ComposioReconciler.shared.start(model: model)   // [capabilities] 3x §10.7: "All Bots" covers bots made later
        let config = GatewayConfigStore(api: GatewaySettingsAPI(client: client), readOnly: model.readOnlyGateway)
        let accountId = account.id
        config.onSaved = { GatewayLaunchPrefs.remember($0, accountId: accountId) }
        configStore = config
        // Read once, after launch has settled, so "Reopen Last Chat on Launch" is known before Settings is ever opened.
        Task {
            try? await Task.sleep(for: .seconds(4))
            // [load-cache] The answer the launch's other readers share (MainTabController's Reopen Last Chat read).
            if let data = try? await client.configData([]), let record = try? JSONValue.parseFast(data) {
                GatewayLaunchPrefs.remember(record, accountId: accountId)
            }
        }
        if versionFor != account.id { version = nil; versionReadAt = nil; versionFor = account.id }
        switcher.start()
        refreshVersion(force: false)
        notify()
    }

    func appActive(_ active: Bool) {
        if active { switcher.appDidBecomeActive() } else { switcher.appDidEnterBackground() }
        ServerIssueSweep.shared.appActive(active)   // [capabilities]
        if active { ComposioReconciler.shared.appActive() }   // [capabilities]
    }

    // MARK: Hermes version (§3.3)

    /// `GET /api/status` → `version` without a leading "v" and anything from the first "+" or "-". Read once per run and
    /// again when Settings opens if older than 60 s and connected.
    func refreshVersion(force: Bool) {
        guard let client = model?.client else { return }
        if let at = versionReadAt {
            guard force, Date().timeIntervalSince(at) >= 60, model?.connection == .ready else { return }
        }
        versionReadAt = Date()
        let account = model?.account?.id
        Task { [weak self] in
            guard let data = try? await client.get("/api/status"), let value = try? JSONValue.parse(data),
                  let raw = RosterText.trimmed(value["version"]), let self, self.model?.account?.id == account else { return }
            let shown = Self.cleanVersion(raw)
            if shown != self.version { self.version = shown; self.notify() }
        }
    }

    nonisolated static func cleanVersion(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let cut = text.firstIndex(where: { $0 == "+" || $0 == "-" }) { text = String(text[..<cut]) }
        return text
    }

    // MARK: GatewayAccounts

    private var signIn: SignInService? { model?.signIn }

    var accounts: [GatewayAccountRow] {
        guard let signIn else { return [] }
        let current = model?.account?.id ?? signIn.currentAccount?.id
        return signIn.store.accounts.map { account in
            let stored = signIn.store.stored(account)
            let label = stored?.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = GatewayNaming.accountName(account)
            let hasSession = switcher.hasUsableSession(account)
            let row = GatewayNaming.row(url: account.baseURL, label: label, accountName: name, hasSession: hasSession)
            let unreachable = account.id != current && hasSession && switcher.unreachable.contains(account.id)
            return GatewayAccountRow(id: account.id, account: account, title: row.title,
                                     subtitle: unreachable ? [row.subtitle, Self.cantReach].filter { !$0.isEmpty }.joined(separator: " · ") : row.subtitle,
                                     label: label?.isEmpty == false ? label : nil,
                                     hostAndPort: GatewayNaming.host(account.baseURL, port: true), accountName: name,
                                     isCurrent: account.id == current, hasSession: hasSession,
                                     news: account.id == current ? 0 : (switcher.counts[account.id] ?? 0), unreachable: unreachable)
        }
    }

    var otherNews: Int { switcher.otherNews }

    /// A gateway whose last news check got no answer (its Gateway page row and the title menu).
    static let cantReach = "Can’t Reach"

    var currentTitle: String {
        accounts.first(where: \.isCurrent)?.title ?? model?.account.map { GatewayNaming.title(url: $0.baseURL, label: nil) } ?? ""
    }

    /// Switches the app to another saved gateway (§4.4). A gateway with no session throws `.needsSignIn`.
    func switchTo(_ id: String) async throws {
        guard switchingTo == nil, let model, let signIn else { return }
        guard id != model.account?.id, !removing.contains(id) else { return }
        guard let account = signIn.store.accounts.first(where: { $0.id == id }) else { throw GatewayFailure.accountMissing }
        guard switcher.hasUsableSession(account) else { throw GatewaySwitchError.needsSignIn(account) }
        let tag = AppLog.tag(id)
        let start = ContinuousClock.now
        switchingTo = id
        notify()
        defer { switchingTo = nil; notify() }
        // Let the "Switching…" line draw before the lists repaint.
        try? await Task.sleep(for: .milliseconds(60))
        do {
            // [offline] §3.4: this phone's saved app data must open for the account, or the switch is not made.
            try await AccountStorage.checkOffMain(account, switching: true)
            // [notifications] Push comes from one gateway: this device leaves the one it is on first (<= 4 s).
            await model.screenLeaving()               // [screen] an open Screen in control hands back before the client ends
            await model.notificationsLeaving(signingOut: false)
            // A switch that can't be made leaves push with the gateway still in use (review: it stayed dead until relaunch).
            let switched: Bool
            do { switched = try signIn.switchTo(account) } catch { model.notificationsResume(); throw error }
            guard switched else { model.notificationsResume(); throw GatewayFailure.accountMissing }
            model.activateSwitched(account)
            switcher.switched(to: id)
            AppLog.note("settings", "gateway switch to \(tag) ok in \(AppLog.ms(since: start)) ms")
            Haptics.play(.selection)
            MainTabController.current?.gatewayDidSwitch()
        } catch {
            AppLog.note("settings", "gateway switch to \(tag) failed after \(AppLog.ms(since: start)) ms: \(type(of: error))")
            throw error
        }
    }

    func rename(_ id: String, _ label: String?) throws {
        guard let signIn, let account = signIn.store.accounts.first(where: { $0.id == id }) else { throw GatewayFailure.accountMissing }
        do {
            guard try signIn.store.rename(account, label: label) else { throw GatewayFailure.accountMissing }
        } catch {
            AppLog.note("settings", "gateway rename \(AppLog.tag(id)) failed: \(type(of: error))")
            throw error
        }
        AppLog.trace("settings", "gateway \(AppLog.tag(id)) renamed, label=\(label != nil)")
        switcher.accountsChanged()
        notify()
    }

    /// Removes a gateway that isn't in use: its own logout (≤ 6 s), Keychain delete, then this phone's copies of its data.
    /// The one in use (or being switched to) is refused, whatever the screen offered.
    func remove(_ id: String) async throws {
        guard let signIn, let account = signIn.store.accounts.first(where: { $0.id == id }) else { throw GatewayFailure.accountMissing }
        guard id != model?.account?.id, id != switchingTo, !removing.contains(id) else { throw GatewayFailure.accountCurrent }
        let tag = AppLog.tag(id)
        let start = ContinuousClock.now
        removing.insert(id)
        notify()
        defer { removing.remove(id); notify() }
        do {
            // [notifications] Its seal key, faces and saved answers go, and an owed DELETE is sent with its own session first
            // (its sign-out below ends that session).
            await model?.notificationsForget(account, stored: signIn.store.stored(account))
            try await signIn.remove(account)
            Self.purge(account)
            switcher.accountsChanged()
            AppLog.note("settings", "gateway \(tag) removed in \(AppLog.ms(since: start)) ms")
        } catch {
            AppLog.note("settings", "gateway \(tag) remove failed after \(AppLog.ms(since: start)) ms: \(type(of: error))")
            throw error
        }
    }

    /// Transcripts and the four list files of an account (`roster|botstate|sessions|sessionstate-<key>.json`), and
    /// (integration) the other streams' per-account copies, as Sign Out deletes them for the account in use.
    static func purge(_ account: GatewayAccount) {
        TranscriptCache.shared.purge(account: account.id)
        AttachmentCenter.signedOut(accountId: account.id)                 // [attachments] drafts, phone copies, media
        MemoPaths.purge(accountId: account.id)                            // VOICE: recordings, drafts, played memos
        ModelPrefs.forget(accountId: account.id)                          // MENUS: favourites, recents, presets
        CommandFavorites.forget(accountId: account.id)                    // starred commands
        ModelCatalogCache.shared.forget(account: account.id)
        CommandsCatalogCache.shared.forget(account: account.id)
        PagesCache.purge(account: account)                                // [m2/pages] Jobs, Kanban, Artifacts
        PagesTabs.forgetDefaults(account)                                 //   and their saved choices
        SoulDraftStore.standard.removeAll(account: account.id)            // [13-12] unsaved SOUL.md text
        KeychainToolRuleVault(account: account.id).removeAll()            // [13-13] half-saved connectors' recovery copies
        PluginListCache.shared.forget(account: account)                   // [load-cache] files went with the pages'
        CapabilitiesWarmCache.shared.forget(account: account.id)          //   (it was never forgotten before)
        QueueStash.shared.purge(accountId: account.id)                    // verify round 3: messages kept queued
        LostSends.shared.purge(accountId: account.id)                     // [sessions-m9] the rows' "Not Delivered:" words
        SideResultStash.shared.purge(accountId: account.id)               // /btw and /bg results kept for the launch
        LogUploader.shared.forget(account: account.id)                   // [13-9] log lines that waited for it
        GatewayLaunchPrefs.forget(accountId: account.id)                  // [m7/settings] Reopen Last Chat on Launch
        let directory = AppModel.listsCacheDirectory
        for kind in [RosterDisk.rosterKind, RosterDisk.botStateKind, RosterDisk.sessionsKind, RosterDisk.sessionStateKind] {
            RosterDiskWriter.shared.remove(RosterDisk.url(directory, kind, account))
        }
        SyncHub.forgetLists(accountId: account.id)                        // [sync] 13-1: with the lists' state just removed
        BotPhotoStore.purge(cacheDirectory: directory, account: account)   // [photoheads] the bots' photos kept for it
        // [13-19] What Sign Out deletes and this didn't: the group rooms and their pins, the chat to reopen on launch,
        // the saved connector issues.
        GroupStore.removeFiles(directory: directory, account: account)
        LaunchChatMemory.shared.forget(account: account.id)
        ServerIssues.shared.signOut(account: account.id)
    }

    func checkSoon() { switcher.checkSoon() }

    @discardableResult func observe(_ change: @escaping @MainActor () -> Void) -> UUID {
        let token = UUID()
        listeners[token] = change
        return token
    }

    func stopObserving(_ token: UUID) { listeners[token] = nil }

    func notify() { for listener in listeners.values { listener() } }

    /// The saved accounts changed outside this hub (a sign-out, Add Gateway…).
    func accountsChanged() {
        switcher.accountsChanged()
        notify()
    }
}

enum GatewaySwitchError: Error, LocalizedError {
    /// The gateway's session ended: sign in again (prefilled) before switching.
    case needsSignIn(GatewayAccount)
    var errorDescription: String? { "Sign in to this gateway again to switch to it." }

    /// Any other switch failure, in the same words wherever it is said (the title menu's alert, the Gateway page's
    /// footer): the app stays on the gateway it was using.
    static func reason(switchingTo name: String) -> String { "Hermes HQ couldn’t switch to \(name). Nothing changed. Try again." }
}

// MARK: - The adapter the screens edit bots through

@MainActor final class StoreBotEditing: BotEditing {
    let store: BotStore
    init(store: BotStore) { self.store = store }

    private func display(_ name: String) -> String { store.bot(named: name)?.name ?? RosterRules.titleCase(name) }

    var sectionRecords: [RosterSectionRecord] { store.sectionRecords }
    var isReadOnly: Bool { store.readOnlyGateway }
    func bot(id: String) -> Bot? { store.bot(named: id) }
    func shownSectionId(of bot: Bot) -> String? { store.shownSectionId(name: bot.id) }
    func botDescription(_ bot: Bot) -> String? { store.rowDescription(bot.id) }
    func metaTitle(_ bot: Bot) -> String? { RosterText.trimmed(store.currentMeta(bot.id)["title"]) }
    func defaultName(_ bot: Bot) -> String {
        store.profile(named: bot.id).map { RosterRules.displayName($0, meta: BotMeta()) } ?? bot.name
    }
    func headState(_ bot: Bot) -> StoredHeadState { store.headState(name: bot.id) }
    func isTaken(profileName: String) -> Bool { store.isTaken(profileName) }

    func setPinned(_ bot: Bot, _ pinned: Bool) async throws { try await store.setPinned(name: bot.id, display: bot.name, pinned) }
    func placeTiles(before: [String], after: [String]) { store.placeTiles(before: before, after: after) }
    var pinOrder: [String] { store.device.pinOrder }                             // [pinned-rows]
    var rowsManual: Bool { store.rowsManual }                                    // [manualorder]
    func setRowsManual(_ manual: Bool) { store.setRowsManual(manual) }
    func placeRows(_ rows: [String]) { store.placeRows(rows) }
    func setHidden(_ bot: Bot, _ hidden: Bool) async throws { try await store.setHidden(name: bot.id, display: bot.name, hidden) }
    func move(_ bot: Bot, toSection id: String?) async throws { try await store.move(name: bot.id, display: bot.name, toSection: id) }

    @discardableResult
    func appendSection(named name: String) -> RosterSectionRecord { store.appendSection(named: name) }

    func renameSection(_ id: String, to name: String) async throws {
        try await store.renameSection(id, to: name) { [weak self] in self?.display($0) ?? $0 }
    }

    func moveSection(_ id: String, by delta: Int) { store.moveSection(id, by: delta) }

    func memberCount(ofSection id: String) -> Int { store.members(ofSection: id).count }

    func beginDeleteSection(_ id: String) throws -> SectionDeletion? { try store.beginDeleteSection(id) }

    func finishDeleteSection(_ deletion: SectionDeletion) async throws {
        try await store.finishDeleteSection(deletion) { [weak self] in self?.display($0) ?? $0 }
    }

    func undoDeleteSection(_ deletion: SectionDeletion) {
        store.undoDeleteSection(deletion) { [weak self] in self?.display($0) ?? $0 }
    }

    func saveEdit(_ bot: Bot, title: String?, description: String?) async throws -> EditOutcome {
        try await store.saveEdit(name: bot.id, title: title, description: description)
    }

    func saveHead(_ bot: Bot, record: JSONValue?, revision: Int) async throws -> Int {
        try await store.saveHead(name: bot.id, record: record, revision: revision)
    }

    func mirrorHead(_ bot: Bot, png dataURL: String?) async { await store.mirrorHead(name: bot.id, png: dataURL) }

    func createBot(name: String, title: String, description: String) async throws -> NewBotResult {
        try await store.createBot(name: name, title: title, description: description)
    }

    func isDefault(_ bot: Bot) -> Bool { store.isDefaultBot(bot.id) }

    func modelInfo(_ bot: Bot) -> (model: String?, provider: String?) {
        let profile = store.profile(named: bot.id)
        // [provider-manager] The owner's name for the model under its own provider (Settings › Providers).
        let label = profile?.model.map { model in profile?.provider.map { ModelNames.displayModelName(model, provider: $0) } ?? store.modelLabel(model) }
        return (label, profile?.provider)
    }

    func defaultModel(_ bot: Bot) -> (model: String?, provider: String?) {
        let profile = store.profile(named: bot.id)
        return (profile?.model, profile?.provider)
    }

    func setDefaultModel(_ bot: Bot, provider: String, model: String, baseURL: String?, confirm: Bool) async throws {
        try await store.setDefaultModel(name: bot.id, display: bot.name, provider: provider, model: model, baseURL: baseURL, confirm: confirm)
    }

    @discardableResult func duplicate(_ bot: Bot) async throws -> String { try await store.duplicateBot(name: bot.id, display: bot.name) }

    func delete(_ bot: Bot) async throws { try await store.deleteBot(name: bot.id, display: bot.name) }

    func recentChats(_ bot: Bot) async -> [SessionSummary] {
        let rows = await store.recentChats(name: bot.id)
        return rows.map { row in
            SessionSummary(id: row.id, profile: row.profile, title: SessionRules.title(row, model: store.modelLabel),
                           preview: SessionRules.preview(row, model: store.modelLabel),
                           lastActive: row.recency > 0 ? Date(timeIntervalSince1970: row.recency) : nil, source: row.source,
                           unread: false, isRunning: false)
        }
    }
}

// MARK: - SettingsServices

extension AppModel: SettingsServices {
    var botEditing: (any BotEditing)? { botStore.map(StoreBotEditing.init) }
    var gateways: any GatewayAccounts { settingsHub }
    var capabilities: (any CapabilitiesService)? { settingsHub.capabilitiesStore }
    var botLayout: RosterLayout? { botStore?.layout }
    var gatewayVersion: String? { settingsHub.version }
    func refreshGatewayVersion(force: Bool) { settingsHub.refreshVersion(force: force) }
    var rosterCount: Int { botStore?.profiles.count ?? 0 }

    func adoptSignedInAccount(_ account: GatewayAccount) {
        // [notifications] The old gateway's alerts go and this phone leaves its push list with that account's own
        // session (its client already ended with the sign-in).
        notificationsLeftForAdded(stored: self.account.flatMap { signIn.store.stored($0) })
        activateSwitched(account)
        settingsHub.switcher.switched(to: account.id)
        settingsHub.accountsChanged()
        MainTabController.current?.gatewayDidSwitch()
    }

    func makeSignInDriver() -> SignInServiceDriver { SignInServiceDriver(service: signIn) }

    func markUnread(_ bot: Bot) { botStore?.markUnread(bot) }

    /// §8.2 step 7: 400 ms after the chat is on screen, the intro goes through the normal send path; without a model
    /// provider the chat says so instead.
    func startIntro(in chat: any ChatSessionModel, result: NewBotResult) {
        Task { @MainActor [weak chat] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let chat else { return }
            if result.needsModel {
                let text = "Bot “\(result.displayName)” created. No model provider is ready for it yet, so it skipped its introduction. "
                    + "Pick a provider and model for it on \(HostWord.phrase)."
                (MainTabController.current?.topChatScreen)?.showLongNotice(text)
            } else {
                chat.send("Hey, tell me about yourself!")
            }
        }
    }

    /// Lifecycle hooks the class body calls (kept here so its edits stay one line each).
    func settingsDidActivate(_ account: GatewayAccount, client: LiveGatewayClient) {
        settingsHub.activated(self, account: account, client: client)
    }
}
