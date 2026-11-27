// Settings (spec 1x-settings §3.2, `src/settings-ios-list.tsx`): a search field over the whole index, the gateway card,
// Appearance, Notifications, Chat (Tool Calls, Reopen Last Chat on Launch, In-App Tips), Sounds, the gateway's own
// settings (Model … Advanced, Passwords & Logins, Sessions), Providers / Keys / Billing, Bots & Tools, About, and
// Export / Import / Reset. A SwiftUI inset-grouped list on UIKit navigation.

import Observation
import SwiftUI
import UIKit
import UserNotifications

@MainActor @Observable
final class SettingsRootModel {
    /// [mac] Stress test 2026-10-28 #66: Settings is in the right pane beside the More list, whose first row is the
    /// same gateway card: Settings leaves its own out.
    var moreBeside = false
    /// [mac-layout] Settings in its own window: the list's soft top edge shows only once rows scroll under the bar.
    var ownWindow = false
    /// [mac-ui-issues] Owner 2026-11-09 ("The settings page looks exactly like it does on the iPhone … It looks like we
    /// didn't even try"): on the Mac, Settings in the main window is a Mac settings page: its categories in a column at
    /// the left (General, Appearance, Chat…), the picked one's controls beside it, and the whole room right of the
    /// sidebar its own (the More list folds away: its setup pages are rows of Bots & Tools here). Off in a sheet, in a
    /// narrow window and on the iPhone and iPad, where it stays the one list.
    var twoColumn = false
    /// [Mac AAA 2026-11-16] Two columns: the right side's page stack, hosted beside the column (`SettingsPaneHost`).
    var pane: UINavigationController?
    /// ⌘F in the Settings window: raised to put the caret in the column's Search Settings field.
    var focusSearch = 0
    /// The category on show in two columns; nil shows every section (a search result's row being scrolled to).
    var category: SettingsCategory? = {
        #if DEBUG
        // `-HQDebugSettingsCategory <appearance|chat|…>`: the category on show when Settings opens (pictures).
        if let asked = UserDefaults.standard.string(forKey: "HQDebugSettingsCategory").flatMap(SettingsCategory.init(rawValue:)) { return asked }
        #endif
        // [macpass-settings2] The Mac's Settings window opens on the category it was closed on (it always came back
        // on General), as the Mac's own System Settings does.
        if DeviceWord.isMac, let last = UserDefaults.standard.string(forKey: SettingsRootModel.lastCategoryKey)
            .flatMap(SettingsCategory.init(rawValue:)) { return last }
        return .general
    }() {
        didSet {
            guard DeviceWord.isMac, twoColumn, let category else { return }
            UserDefaults.standard.set(category.rawValue, forKey: Self.lastCategoryKey)
        }
    }
    static let lastCategoryKey = "hqn.settings.lastCategory"
    func shows(_ wanted: SettingsCategory) -> Bool { !twoColumn || category == nil || category == wanted }
    /// [mac-ui-issues] Two columns: the column picked a category or typed in its search field. The controller brings the
    /// right side back to the category's own page (a pushed page leaves) and names it.
    @ObservationIgnored var columnChanged: (() -> Void)?
    /// [macpass-settings r2] Two columns: the gateway card's page is the right side's own page (no "‹ Appearance" Back
    /// to the category shown before), and the column marks the card instead of that category.
    var gatewayMarked = false
    @ObservationIgnored var openGateway: (() -> Void)?
    var gatewayName = ""
    var host = ""
    var connection: ConnectionState = .connecting
    var rosterCount = 0
    var version: String?
    var appearance = AppearanceSetting.current
    var completionSound = CompletionCue.isOn
    /// [kanban-tab-one] The Kanban Tab picker is there to find (it lives on Appearance › Tabs).
    var kanbanTabShown = false
    var toolCallsSummary: String?
    /// [tile-models] Tile Model's value ("Each Bot’s Own Model", or the picked model); nil when signed out.
    var tileModelSummary: String?
    /// [plugin-updates] Whether this gateway checks for plugin updates automatically after launch.
    var autoPluginUpdateChecks = true
    /// The search field's text (the list shows results while it isn't empty).
    var query = ""
    var inAppTips = InAppTips.isOn
    var fewerTimestamps = ToolCallSettings.fewerTimestamps
    var fileChanges = ToolCallSettings.fileChanges
    var newChatAsksProject = NewChatProjectChoice.isOn
    var waitForModels = ModelPrefs.waitForModels
    // [settings] On this iPhone: Haptics (docs/spec/3x-settings.md §1) and Intro Splash (§7).
    var haptics = Haptics.isOn
    /// [thinking-drive] How the model panel's thinking bar looks and feels as it climbs.
    var thinkingDrive = ThinkingDrive.chosen
    /// [mac] The Desktop Look draws the thinking bar calmly whatever the drive, and the Mac has no haptics, so there the
    /// Thinking Bar row would change nothing: it isn't shown (Mac polish #37). The iOS look on the Mac keeps it.
    static var thinkingBarShown: Bool { !(DeviceWord.isMac && Theme.shared.state.desktopLook) }
    var thinkingBarShown: Bool { Self.thinkingBarShown }
    /// [mac] Whether a search entry's row is on its page now: Settings' own search, Open Quickly and More's search
    /// all ask, so none of them offers the hidden Thinking Bar (Mac polish #37).
    /// [Mac UI check 2026-11-13] Nor ⌘N Project while ⌘N opens a bot's own chat, where the row isn't drawn.
    static func searchRowShown(_ entry: SettingsSearchEntry) -> Bool {
        (entry.id != "app:thinking-drive" || thinkingBarShown)
            && (entry.id != "app:new-chat-project" || NewChatKeyBot.mode == .session)
    }
    var introSplash = IntroSplash.isOn
    /// [app-icons] The icon the app wears (Appearance › App Icon's value).
    var appIconTitle = AppIcons.wornTitle
    /// §12 File Browser.
    var fileBrowser = FileBrowserPref.isOn
    /// [session-strip] Other Chats at the Top (opt-in; on on the Mac): the bot's other chats as pills under a chat's bar.
    var sessionStrip = SessionStripPref.isOn
    /// Message Reactions (default Off): Tapbacks in a message's menu.
    var messageReactions = MessageReactionsPref.isOn
    /// [send-while-busy] What Send does with typed words while a reply runs.
    var sendWhileBusy = SendWhileBusy.chosen
    /// [links-browser] Open Links In: the browsers on this device, and the one web links open in.
    var linkBrowsers = LinkOpener.browsers()
    var linkChoice = LinkOpener.choice
    var newChatKeyBot = NewChatKeyBot.chosen   // [cmd-n]
    var newChatKeyMode = NewChatKeyBot.mode     // [cmd-n] a tester: New Session or Bot Chat
    var newChatKeyProject = NewChatKeyBot.project ?? ""   // [cmd-n] "" is No Project
    /// §4 Largest Attachment, in MB (1…32).
    var attachmentLimit = AttachmentLimit.megabytes
    var soundName = CompletionSoundVariant.preset(CompletionCue.variant).name
    /// How the last Import / Reset went.
    var fileStatus: String?
    /// A reset is writing (UX study 2026-10-21 #209: the row waits).
    var resetting = false
    /// The Notifications row's value (#119): read from iOS each time the page shows.
    var notificationsSummary: String?
    /// The main bot (the gateway's default profile), whose settings On Your Gateway edits (#186).
    var defaultBotName: String?
    /// A search result on the root itself ("row:…", #108): the list scrolls to it and marks it for a moment.
    var revealed: String?
    @ObservationIgnored private var revealTask: Task<Void, Never>?
    /// Ends the search (set by the controller that owns the search field).
    @ObservationIgnored var endSearch: ((_ then: @escaping () -> Void) -> Void)?
    /// [Mac AAA 2026-11-16] Opens a search result as clicking it does (set by the list): Return in the column's field
    /// opens the first one, as System Settings' search does.
    @ObservationIgnored var openResult: ((SettingsSearchEntry.Target) -> Void)?

    @ObservationIgnored let services: any AppServices
    @ObservationIgnored private var token: UUID?

    init(services: any AppServices) {
        self.services = services
        refresh()
    }

    var settings: (any SettingsServices)? { services as? SettingsServices }

    /// [cmd-n] New Chat (⌘N)'s choices: Hermes, the other bots (hidden ones left out, as Choose a Bot leaves them),
    /// then Ask Every Time. A chosen bot the gateway no longer has stays listed, so the pop-up still shows it.
    var newChatKeyOptions: [String] {
        let bots = services.bots.filter { !$0.hidden || $0.id == "default" }.map(\.id)
        var ids = ["default"] + bots.filter { $0 != "default" }
        if newChatKeyBot != NewChatKeyBot.ask, !ids.contains(newChatKeyBot) { ids.append(newChatKeyBot) }
        return ids + [NewChatKeyBot.ask]
    }

    /// [cmd-n] New Chat Project's choices: No Project, then every bot's projects by name. A chosen project no bot has
    /// any more stays listed, so the pop-up still shows it.
    var newChatKeyProjects: [String] {
        var keys = ((services as? AppModel)?.sessionStore?.projectEntries() ?? []).map(\.key).filter { $0 != SessionProjects.homeKey }
        if !newChatKeyProject.isEmpty, !keys.contains(newChatKeyProject) { keys.append(newChatKeyProject) }
        return [""] + keys
    }

    func newChatKeyProjectTitle(_ key: String) -> String {
        if key.isEmpty { return "No Project" }
        return (services as? AppModel)?.sessionStore?.projectEntries().first { $0.key == key }?.label ?? (key as NSString).lastPathComponent
    }

    func newChatKeyTitle(_ id: String) -> String {
        if id == NewChatKeyBot.ask { return "Ask Every Time" }
        return services.bots.first { $0.id == id }?.name ?? (id == "default" ? "Hermes" : id)
    }
    var gatewaySettings: (any GatewaySettingsServices)? { services as? GatewaySettingsServices }
    var configStore: GatewayConfigStore? { gatewaySettings?.configStore }

    /// "Reopen Last Chat on Launch": the gateway's record once read, this phone's last-known value until then.
    var resumeLastSession: Bool {
        if let config = configStore?.config { return ConfigCopy.resumeLastSession(config) }
        return services.account.map { GatewayLaunchPrefs.resumeLastSession(accountId: $0.id) } ?? true
    }

    func setResumeLastSession(_ on: Bool) {
        guard let store = configStore else { return }
        Haptics.play(.selection)
        if store.config == nil {
            Task {
                await store.load()
                store.set("display.resume_last_session", .bool(on))
            }
        } else {
            store.set("display.resume_last_session", .bool(on))
        }
        if let account = services.account { GatewayLaunchPrefs.remember(.object(["display": ["resume_last_session": .bool(on)]]), accountId: account.id) }
    }

    var searchResults: [SettingsSearchEntry] {
        // A search never leads to a row a page doesn't show (Kanban Tab, on Tabs, only shows once the board is known).
        let canUpdatePlugins = services.account != nil && !((services as? AppModel)?.settingsHub.capabilitiesStore?.readOnlyGateway ?? false)
        let index = SettingsSearch.index(schema: configStore?.schema ?? [:]).filter {
            ($0.target != .root(SettingsSearch.kanbanTabTarget) || kanbanTabShown) && Self.searchRowShown($0)
                // [Mac UI check 2026-11-13] ⌘N Project is drawn only once there is a project to pick.
                && ($0.id != "app:new-chat-project" || newChatKeyProjects.count > 1)
                && (($0.id != "app:plugin-update-checks" && $0.id != "app:check-plugin-updates") || canUpdatePlugins)
        }
        let status = SettingsHooks.commandCenter?() != nil ? [SettingsSearch.statusEntry] : []   // [macpass-settings2]
        return SettingsSearch.results(query, in: index + status + Self.movedFromMoreEntries())
    }

    /// [macpass-settings2] The Mac's Bots & Tools rows that More holds on the iPhone (Bot Profiles, Messaging,
    /// Webhooks, Import Sessions) as results: "webhook" found nothing although the row is on that page.
    private static func movedFromMoreEntries() -> [SettingsSearchEntry] {
        #if targetEnvironment(macCatalyst)
        let words: [String: [String]] = [
            "profiles": ["bots", "personas", "profiles"],
            "messaging": ["telegram", "discord", "slack", "whatsapp", "signal", "email", "sms", "platforms", "gateway"],
            "webhooks": ["webhook", "hooks", "http", "events"],
            "import-sessions": ["import", "history", "claude code", "codex", "chats"],
        ]
        return SettingsRootView.movedFromMore().map {
            SettingsSearchEntry(id: "more:\($0.id)", label: $0.title, context: "Bots & Tools", keywords: words[$0.id] ?? [],
                                target: .root("more:\($0.id)"), isPage: true)
        }
        #else
        return []
        #endif
    }

    /// Scrolls the list to a root row and marks it for a second, as iOS Settings does.
    func reveal(_ row: String) {
        revealTask?.cancel()
        // [macpass-settings2] Two columns: the row's own category is marked in the column and names the page (a
        // search result for ⌘N Bot showed Chat's rows under the title "General" with nothing marked in the column).
        // A row not in the table: every section shows while it is found, as before.
        if twoColumn {
            category = Self.category(ofRow: row)
            columnChanged?()
        }
        revealed = row
        revealTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            if !Task.isCancelled { self?.revealed = nil }
        }
    }

    /// [macpass-settings2] The category whose section draws a root row (`row:<id>`, `SettingsRootView`'s
    /// `shows(_:)` blocks); nil for one this table doesn't know.
    /// [appearance-groups] Whether `row` is on Appearance's own page here (one column), not on this list.
    func opensAppearancePage(for row: String) -> Bool {
        !twoColumn && AppearanceRows.contains(row)
    }

    static func category(ofRow row: String) -> SettingsCategory? {
        if AppearanceRows.contains(row) { return .appearance }
        return switch row {
        case "row:share-menu": .general   // [macpass-settings2]
        case "row:plugin-update-checks", "row:check-plugin-updates": .tools
        case "row:thinking-drive", "row:haptics", "row:completion-sound", "row:sound": .sounds
        case "row:fewer-timestamps", "row:show-file-changes", "row:attachment-limit", "row:new-chat-asks-project", "row:wait-for-models",
             "row:send-while-busy", "row:open-links-in", "row:new-chat-mode", "row:new-chat-key", "row:new-chat-project",
             "row:resume-last-chat", "row:tips", "row:intro-splash", "row:file-browser", "row:session-strip", "row:message-reactions": .chat
        default: nil
        }
    }

    /// The Notifications row's value: what this app's switch, iOS and the gateway's add-on say.
    func refreshNotifications() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let plugin: PushPolicy.PluginState? = PushRegistrar.available ? PushRegistrar.shared.lastPluginState : nil
        notificationsSummary = SettingsWords.notificationsSummary(enabled: NotificationPrefs.load().enabled, denied: status == .denied,
                                                                  undetermined: status == .notDetermined, plugin: plugin)
    }

    func start() {
        guard token == nil, let gateways = settings?.gateways else { return }
        token = gateways.observe { [weak self] in self?.refresh() }
        settings?.refreshGatewayVersion(force: true)
    }

    func stop() {
        if let token { settings?.gateways.stopObserving(token) }
        token = nil
    }

    isolated deinit { stop() }

    func refresh() {
        let rows = settings?.gateways.accounts ?? []
        if let current = rows.first(where: \.isCurrent) {
            gatewayName = current.title
            host = current.hostAndPort
        } else if let account = services.account {
            gatewayName = GatewayNaming.title(url: account.baseURL, label: nil)
            host = GatewayNaming.host(account.baseURL, port: true)
        }
        connection = services.connection
        rosterCount = settings?.rosterCount ?? services.bots.count
        defaultBotName = services.bots.first { $0.id == "default" }?.name
        version = settings?.gatewayVersion
        toolCallsSummary = SettingsHooks.toolCallsSummary?()
        tileModelSummary = services.account.map { TileModels.defaultValue(TileModelSettings(accountId: $0.id).defaultModel) }
        soundName = CompletionSoundVariant.preset(CompletionCue.variant).name
        attachmentLimit = AttachmentLimit.megabytes   // [settings] the page that changes it pops back here
        appIconTitle = AppIcons.wornTitle          // [app-icons]
        kanbanTabShown = TabOrderPage.kanbanChoice(services.account) != nil
        autoPluginUpdateChecks = PluginUpdateReminder.isAutomatic(account: services.account?.id)
    }

    func setAutoPluginUpdateChecks(_ on: Bool) {
        guard let account = services.account?.id else { return }
        autoPluginUpdateChecks = on
        PluginUpdateReminder.setAutomatic(on, account: account)
        if !on { PluginUpdateFlow.shared.cancelLaunchCheck() }
        AppLog.note("settings", "automatic plugin update checks \(on ? "on" : "off")")
    }

    // MARK: The card's status line (§3.3)

    var stateWords: String {
        switch connection {
        case .ready: "Connected"
        case .connecting: "Connecting…"
        case .reconnecting: "Reconnecting…"
        case .offline: "Offline"
        case .signedOut: "Signed Out"
        }
    }

    var dotColor: Color {
        switch connection {
        case .ready: .green
        case .connecting, .reconnecting: .orange
        case .offline: .red
        case .signedOut: .gray
        }
    }

    /// `[state, "9 Bots", "Hermes 0.21.5"]`, each piece kept on one line.
    var statusPieces: [String] { [stateWords] + factPieces }

    /// `["9 Bots", "Hermes 0.21.5"]`: the card's line under the state.
    var factPieces: [String] {
        var pieces: [String] = []
        if rosterCount > 0 { pieces.append("\(rosterCount)\u{00A0}\(rosterCount == 1 ? "Bot" : "Bots")") }
        if let version, !version.isEmpty { pieces.append("Hermes\u{00A0}\(version)") }
        return pieces
    }

    /// The pieces joined with " · ".
    var statusLine: String { statusPieces.joined(separator: " · ") }

    /// The gateway's name with break chances after its dots, colons and slashes, so a long address wraps between
    /// its parts ("127.0.0.1:" / "9951") instead of mid-number.
    var gatewayNameForWrapping: String { Self.wrappable(gatewayName) }

    /// Break chances word by word: a hostname may break after its dots, colons and slashes; a number address
    /// (127.0.0.1) only after its colons and slashes, so it never reads "127.0.0." / "1:10067".
    static func wrappable(_ name: String) -> String {
        name.split(separator: " ", omittingEmptySubsequences: false).map { word in
            let breaks = isNumberAddress(word) ? ":/" : ".:/"
            return String(word.flatMap { breaks.contains($0) ? [$0, "\u{200B}"] : [$0] })
        }.joined(separator: " ")
    }

    /// "127.0.0.1:9951" or "http://10.0.0.2/": the host part is only digits and dots.
    static func isNumberAddress(_ word: Substring) -> Bool {
        var rest = word
        if let scheme = rest.range(of: "://") { rest = rest[scheme.upperBound...] }
        let host = rest.prefix { $0 != ":" && $0 != "/" }
        return host.contains(".") && host.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") }
    }
}

final class SettingsRootController: UIHostingController<HQScaledRoot<SettingsRootView>>, UISearchResultsUpdating {
    let router: SettingsRouter
    let model: SettingsRootModel
    let actions: SettingsFileActions
    var isSheetRoot = false
    private var timer: Timer?
    /// The search field folds behind a magnifier at the top right (owner: a field always under the title floated
    /// over the scrolling list), as on the other list pages.
    private var searchCapsule: PageBarCapsule!
    private var search: UISearchController { searchCapsule.searchController! }

    init(services: any AppServices) {
        let router = SettingsRouter(services: services, navigation: nil)
        let model = SettingsRootModel(services: services)
        let actions = SettingsFileActions(router: router)
        self.router = router
        self.model = model
        self.actions = actions
        super.init(rootView: HQScaledRoot(SettingsRootView(model: model, router: router, actions: actions)))
        actions.onStatus = { [weak model] in model?.fileStatus = $0 }
        actions.onResetting = { [weak model] in model?.resetting = $0 }
        model.endSearch = { [weak self] then in self?.endSearch(then: then) }
        title = "Settings"
        navigationItem.largeTitleDisplayMode = .always
        // The iOS search field over the whole settings index (`IosSettingsList`), unfolded by the magnifier.
        // [mac] Stress test 2026-10-28 #66: beside More's own magnifier the field says what it searches.
        searchCapsule = PageBarCapsule.search(on: self, page: "settings", placeholder: DeviceWord.isMac ? "Search Settings" : "Search",
                                              updater: self)
        search.searchBar.autocapitalizationType = .none
        search.searchBar.searchTextField.accessibilityIdentifier = "settings.search"
        navigationItem.rightBarButtonItems = [searchCapsule.searchItem].compactMap { $0 }
    }

    func updateSearchResults(for searchController: UISearchController) {
        searchCapsule.updateSearchState()
        model.query = searchController.searchBar.text ?? ""
    }

    /// A result opened: the search ends (as the web clears its field) and the page is pushed.
    func endSearch(then: (() -> Void)? = nil) {
        #if targetEnvironment(macCatalyst)
        if model.twoColumn {   // the column's own field: nothing to dismiss
            model.query = ""
            columnChanged()
            then?()
            return
        }
        #endif
        search.searchBar.text = ""
        let wasActive = search.isActive
        search.isActive = false
        model.query = ""
        guard let then else { return }
        // Pushes made while the search field is still letting go are dropped: wait for its dismissal.
        if wasActive, let coordinator = search.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { _ in then() }
        } else if wasActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: then)
        } else {
            then()
        }
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        if router.navigation == nil { router.navigation = navigationController }
        if isSheetRoot {
            // Every sheet's bar matches (ChatSheet.wrap, verify round 1): the ✕ leading, an inline title.
            let close = UIBarButtonItem.hqClose(action: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })
            close.accessibilityIdentifier = "settings.close"
            navigationItem.hqPlaceClose(close)   // [mac] Stress test 2026-10-28 #55: trailing on the Mac
            navigationItem.largeTitleDisplayMode = .never
        }
        // [macpass-settings2] The category column's width follows UI Scale: the pane beside it moves when it changes.
        themeWatch = NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.view.setNeedsLayout() }
        }
    }
    private var themeWatch: NSObjectProtocol?

    #if targetEnvironment(macCatalyst)
    /// [mac] Stress test 2026-10-28 #66: whether the More list (gateway card first) is beside this page, checked as the
    /// panes change (one pane or two, a tab picked) and when the page shows.
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        noteMoreBeside()
    }

    /// The Settings window, just shown: its columns before a page is pushed into them.
    func settleColumns() { noteMoreBeside() }

    private func noteMoreBeside() {
        var beside = false
        // [mac-ui-issues] In the Settings window, or in the main window's right pane with room for the category column
        // and a form beside it.
        let columns = !isSheetRoot && (model.ownWindow ? view.bounds.width >= 640
            : view.bounds.width >= 820 && navigationController === MainTabController.current?.split?.detail)
        if model.twoColumn != columns {
            model.twoColumn = columns
            if columns, model.category == nil { model.category = .general }
            MainTabController.current?.split?.listFoldMayHaveChanged()
        }
        followColumns()
        if !isSheetRoot, !columns, let root = MainTabController.current, let split = root.split, split.isDouble, !split.listFolded,
           navigationController === split.detail, root.pages?.isMore(root.selectedViewController) == true {
            beside = true
        }
        if model.moreBeside != beside { model.moreBeside = beside }
    }

    /// Two columns: the split folds the More list away for this page (`RootSplitController.listFolded`).
    var takesList: Bool { model.twoColumn }

    /// [mac-ui-issues] Owner 2026-11-09 ("too iOS-like … the entire experience doesn't feel right"): in two columns the
    /// right side is a page stack of its own, so opening Notifications or Theme slides a page in beside the categories
    /// instead of replacing the whole pane with a Back button. The pane's own bar (Settings, the magnifier) is hidden:
    /// the column has the search field, and each page on the right has its own title.
    private(set) var paneStack: UINavigationController?
    /// Kept: the gateway card's page stands in for it as the stack's root while the card is marked.
    private var paneRoot: UIViewController?

    private func followColumns() {
        guard isViewLoaded else { return }
        if model.twoColumn {
            if paneStack == nil {
                let page = UIHostingController(rootView: HQScaledRoot(SettingsRootView(model: model, router: router, actions: actions, pane: true)))
                page.navigationItem.largeTitleDisplayMode = .never
                let stack = UINavigationController(rootViewController: page)
                stack.navigationBar.prefersLargeTitles = false
                stack.delegate = PushedPageTitles.shared
                stack.view.backgroundColor = HQPalette.groupedPage
                // [Mac AAA 2026-11-16] Hosted by the SwiftUI page beside the column (`SettingsPaneHost`), not added to
                // this hosting controller's own view: UIKit warned it does not support that ("Adding … as a subview
                // of UIHostingController.view is not supported").
                paneStack = stack
                model.pane = stack
                paneRoot = page
                model.columnChanged = { [weak self] in self?.columnChanged() }
                model.openGateway = { [weak self] in self?.showGateway() }
                router.jump = { [weak self] category in self?.jump(to: category) }
                router.openGateway = { [weak self] in self?.model.query = ""; self?.showGateway() }   // [Mac AAA 2026-11-16]
                namePane()
                MacWindow.pageBar(page)
            }
            router.navigation = paneStack
            placePane()
            if navigationController?.topViewController === self, navigationController?.isNavigationBarHidden == false {
                navigationController?.setNavigationBarHidden(true, animated: false)
            }
        } else if paneStack != nil {
            model.pane = nil
            paneStack = nil
            paneRoot = nil
            model.gatewayMarked = false
            model.columnChanged = nil
            model.openGateway = nil
            router.jump = nil
            router.openGateway = nil
            router.navigation = navigationController
            navigationController?.setNavigationBarHidden(false, animated: false)
        }
    }

    /// [Mac AAA 2026-11-16] The pane is laid out by the SwiftUI page beside the column (`SettingsPaneHost`).
    private func placePane() {}

    private func namePane() {
        let searching = !model.query.trimmingCharacters(in: .whitespaces).isEmpty
        paneRoot?.title = searching ? "Search" : (model.category?.title ?? "Settings")
        // [Mac UI check 2026-11-13] `MacBackTitle` names Back once and keeps it: a later category's pages said
        // "‹ General" (the first category shown) under Hermes or About. Cleared, the next push names it afresh.
        paneRoot?.navigationItem.backButtonTitle = nil
    }

    /// Settings asked for again while it is on show (⌘, the gear): back to the category's own page.
    func backToIndex() { columnChanged() }

    /// [Mac UI check 2026-11-13] A page of `category` opening from elsewhere (`SettingsRouter.jump`): the column marks
    /// it, and a page of another category leaves first, so Back names the category's page, not the page shown before.
    private func jump(to category: SettingsCategory) {
        guard model.category != category || model.gatewayMarked else { return }
        model.query = ""
        model.category = category
        columnChanged()
    }

    private func columnChanged() {
        namePane()
        model.gatewayMarked = false
        guard let stack = paneStack else { return }
        if let paneRoot, stack.viewControllers.first !== paneRoot {
            stack.setViewControllers([paneRoot], animated: false)
        } else if stack.viewControllers.count > 1 {
            stack.popToRootViewController(animated: false)
        }
    }

    /// [macpass-settings r2] The gateway card in two columns: its page is the right side's root (no Back to the
    /// category shown before) and the card carries the column's mark until a category is picked.
    private func showGateway() {
        guard let stack = paneStack else { return }
        model.gatewayMarked = true
        let page = GatewayPageController(services: model.services, router: router)
        stack.setViewControllers([page], animated: false)
        MacWindow.pageBar(page)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        placePane()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Another page over Settings in the pane, or the pane given to something else: its bar comes back.
        if paneStack != nil { navigationController?.setNavigationBarHidden(false, animated: false) }
    }
    #endif

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        #if targetEnvironment(macCatalyst)
        noteMoreBeside()   // [mac] stress test #66
        #endif
        searchCapsule.restoreIfTyped()
        if router.navigation == nil { router.navigation = navigationController }
        model.refresh()
        model.start()
        Task { [model] in await model.refreshNotifications() }
        if let store = model.configStore { Task { await store.load() } }
        // The connection and roster have single owners (the lists); a settled second is plenty for this page.
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.model.refresh() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Scrolls to and marks a root row (`row:<id>`), as a result from this page's own search does. Asked for
    /// before the page is on screen (More's search pushes it first), the mark waits for it to appear.
    func reveal(_ id: String) {
        #if targetEnvironment(macCatalyst)
        if let stack = paneStack, stack.viewControllers.count > 1 { stack.popToRootViewController(animated: false) }
        #endif
        // [appearance-groups] A row of Appearance's own page: the page over this one, scrolled to the row.
        if model.opensAppearancePage(for: id) {
            router.push(AppearancePage.make(model: model, router: router, reveal: id))
            return
        }
        if viewIfLoaded?.window != nil { model.reveal(id) } else { pendingReveal = id }
        #if targetEnvironment(macCatalyst)
        namePane()
        #endif
    }

    private var pendingReveal: String?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let id = pendingReveal {
            pendingReveal = nil
            model.reveal(id)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        timer?.invalidate()
        timer = nil
    }
}

/// [Mac AAA 2026-11-16] The right side of two columns: the pane's page stack as a child of the SwiftUI page, beside
/// the category column (it was added straight to the hosting controller's view, which UIKit does not support).
struct SettingsPaneHost: UIViewControllerRepresentable {
    let stack: UINavigationController
    func makeUIViewController(context: Context) -> UINavigationController { stack }
    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}

/// [mac-layout] The Settings window's list (2026-11-03): at rest its soft top edge blurred the gateway card, the first
/// row, under the bar. SwiftUI shows a list's edge again on each update, so the list itself says when it shows.
struct SoftEdgeOnlyScrolled: ViewModifier {
    let on: Bool
    @State private var atTop = true

    func body(content: Content) -> some View {
        if on {
            content
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top <= 0.5 } action: { _, top in
                    atTop = top
                }
                .scrollEdgeEffectHidden(atTop, for: .top)
        } else {
            content
        }
    }
}

struct SettingsRootView: View {
    @Bindable var model: SettingsRootModel
    let router: SettingsRouter
    let actions: SettingsFileActions
    /// [mac-ui-issues] The right side of two columns (`SettingsRootController.paneStack`'s first page): the list alone.
    var pane = false

    /// [macpass-settings] A section's header, left out in two columns when it only repeats the page's title (the
    /// category's): "Sounds" sat under "Sounds", "Bots & Tools" under "Bots & Tools", while General and About had none.
    /// Search results (every section at once) keep it.
    @ViewBuilder private func categoryHeader(_ title: String) -> some View {
        if !(model.twoColumn && model.category?.title == title) {
            HQSectionLabel { Text(title) }
        }
    }

    var body: some View {
        if pane {
            list
        } else if model.twoColumn {
            // The column stays put; the right side is a page stack of its own laid over the clear room beside it, so a
            // pushed page (Notifications, Theme) slides in there and the categories never leave.
            HStack(spacing: 0) {
                SettingsCategoryColumn(model: model, router: router)
                // [Mac AAA 2026-11-16] The Mac's pane line, as between the sidebar and the chat: the stroke token drew
                // the column's edge darker than the page in dark (it could not be seen at all).
                #if targetEnvironment(macCatalyst)
                Rectangle().fill(Color(uiColor: HQPalette.paneLine)).frame(width: HQShape.pixel(UIScreen.main.scale)).ignoresSafeArea()
                #else
                Rectangle().fill(Color.hqStroke).frame(width: HQShape.pixel(UIScreen.main.scale)).ignoresSafeArea()
                #endif
                if let pane = model.pane {
                    SettingsPaneHost(stack: pane).ignoresSafeArea()
                } else {
                    Color.clear
                }
            }
            .background(Color.hqGroupedPage.ignoresSafeArea())
        } else {
            list
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List {
                Group {
                    if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                        mainSections
                    } else {
                        searchSection
                    }
                }
                .hqMacSettingsRowInsets()
            }
            .hqMacForm(settings: true)       // [mac] Stress test 2026-10-28 #8, #51: the Mac's form width, rows and switches
            .environment(\.hqSourceListRows, true)   // [mac] #51: a source list, no › chevrons
            .hqGroupedPage()   // [desktoplook] the page follows the skin
            .listStyle(.insetGrouped)
            .accessibilityIdentifier("settings.list")
            .modifier(SoftEdgeOnlyScrolled(on: model.ownWindow))
            .hqMacListHeight()   // [Mac AAA 2026-11-16] the search's empty state centred in the pane
            .onAppear { model.openResult = { open($0) } }   // [Mac AAA 2026-11-16] Return in the column's search
            .onChange(of: model.revealed) { _, row in
                guard let row else { return }
                // A beat for the list to come back from the search results before it scrolls.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    HQMotion.withAnimation { proxy.scrollTo(row, anchor: .center) }
                }
            }
        }
    }

    #if targetEnvironment(macCatalyst)
    /// More's setup pages, as this gateway has them (a page its Hermes lacks shows dimmed in More; here it's left out).
    static func movedFromMore() -> [MoreRow] {
        let ids = ["profiles", "messaging", "webhooks", "import-sessions"]
        let rows = MainTabController.current?.pages?.moreSections().flatMap { $0.rows() } ?? []
        return ids.compactMap { id in rows.first { $0.id == id && !$0.dimmed } }
    }
    #endif

    private func open(_ target: SettingsSearchEntry.Target) {
        let open = { [router, actions, model] in
            // UX study 2026-10-21 #108: a row on this list is scrolled to and marked, not left for the person to find.
            // [appearance-groups] A row of Appearance's own page: the page opens scrolled to it, the row marked.
            if case .root(let id) = target, model.opensAppearancePage(for: id) { router.push(AppearancePage.make(model: model, router: router, reveal: id)) }
            else if case .root(let id) = target, id.hasPrefix("row:") { model.reveal(id) }
            // [mac] Stress test 2026-10-28 #51 (review): the search result lands on the root's field, not a page.
            else if DeviceWord.isMac, target == .root("attachment-limit") { model.reveal("row:attachment-limit") }
            // [Mac UI check 2026-11-13] Sound is a pop-up in its row on the Mac, not the iPhone's page (the switch
            // above it when the sound is off and the row isn't drawn).
            else if DeviceWord.isMac, target == .root("sound-picker") { model.reveal(model.completionSound ? "row:sound" : "row:completion-sound") }
            // [macpass-settings2] Two columns: the gateway's page opens as the card does (the card marked, the page the
            // right side's root); a result ("keychain", "sign out") pushed it over the category shown, with Back to it.
            else if target == .root("gateway"), let openGateway = model.openGateway { openGateway() }
            // [macpass-settings2] Status & Maintenance over the Gateway page, opened as the card opens it.
            else if target == .root(SettingsSearch.statusTarget), let openGateway = model.openGateway, let make = SettingsHooks.commandCenter?() {
                openGateway()
                DispatchQueue.main.async {
                    let page = make()
                    page.navigationItem.largeTitleDisplayMode = .never
                    router.push(page)
                }
            } else {
                SettingsNavigator.open(target, router: router, actions: actions)
            }
        }
        if let end = model.endSearch { end(open) } else { open() }
    }

    @ViewBuilder
    private var searchSection: some View {
        let results = model.searchResults
        if results.isEmpty {
            if DeviceWord.isMac {
                // [Mac AAA 2026-11-16] The app's empty state, as Tools' and Voice's no-result pages draw it (and System
                // Settings' search), not one grey line in a card at the top of a blank pane.
                Section {
                    ContentUnavailableView {
                        UnavailableTitle("No Results for “\(model.query.trimmingCharacters(in: .whitespaces))”", systemImage: "magnifyingglass")
                    } description: {
                        Text("Check the spelling or try other words.").hqMacFont(MacType.emptyBodyFont)
                    }
                    .listRowBackground(Color.clear)
                    .hqMacEmptyPlacement()
                    .hqMacListedEmptyState(above: 40)
                    .accessibilityIdentifier("settings.search-empty")
                }
            } else {
            Section {
                Text("No Results for “\(model.query.trimmingCharacters(in: .whitespaces))”")
                    .foregroundStyle(Color.hqLabel2)
                    .accessibilityIdentifier("settings.search-empty")
            }
            }
        } else {
            Section {
                ForEach(results) { result in
                    Button { open(result.target) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.label).foregroundStyle(Color.hqLabel)
                                if !result.context.isEmpty {
                                    Text(result.context).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                                }
                            }
                            Spacer()
                            SettingsChevron()  // [mac] Stress test 2026-10-28 #51: no › on the Mac
                        }
                        .contentShape(Rectangle())
                        .hqMacRowHover()   // [Mac AAA 2026-11-16]
                    }
                    .accessibilityIdentifier("settings.result.\(result.id)")
                }
            }
        }
    }

    /// [addon-reminder] Under the gateway card, as iOS puts Software Update under your account: the add-on update the
    /// person said Not Now to, with a red 1; tapping it offers the same update as the launch alert.
    /// [addon-progress] While an update runs the row says "Updating Add-on…" with a spinner and the step under way, and
    /// a tap brings its sheet back.
    @ViewBuilder
    private var addOnReminder: some View {
        let reminder = AddOnReminder.shared, update = AddOnUpdate.shared
        let busy = update.busy && !update.pluginRun   // [plugin-updates] a plugin update shows on its own row
        if let title = busy ? update.rowLabel : reminder.title, let app = model.services as? AppModel {
            Section {
                Button {
                    // [mac] Its sheet goes over this page's own window, not the main window behind Settings (Mac polish #36).
                    Task { @MainActor in _ = await PushSetupOffer.shared.check(model: app, fromSettings: true, from: router.presenter) }
                } label: {
                    HStack(spacing: 12) {
                        SettingsRowLabel(title: title, systemImage: "puzzlepiece.extension")
                        Spacer(minLength: 16)
                        HStack(spacing: 8) {
                            if busy { ProgressView().controlSize(.small) } else if reminder.badged { CountBadgeView(count: 1) }
                            SettingsChevron()
                        }
                    }
                    .contentShape(Rectangle())
                    .hqMacRowHover()   // [Mac AAA 2026-11-16]
                }
                .hqMacFormRowHeight()
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("settings.addon-update")
            } footer: {
                if let footer = busy ? update.rowStatus : reminder.footer { HQSectionFooter { Text(footer) } }
            }
        }
    }

    /// [plugin-updates] Under the add-on's row, and drawn as it is: the plugins Hermes says have an update, with a red
    /// count; a tap opens the same update sheet for them. While it runs the row says "Updating Plugin…" and the step
    /// under way, and a tap brings the sheet back.
    @ViewBuilder
    private var pluginReminder: some View {
        let reminder = PluginUpdateReminder.shared, update = AddOnUpdate.shared
        let busy = update.busy && update.pluginRun
        if let title = busy ? update.rowLabel : reminder.title, let app = model.services as? AppModel {
            Section {
                Button {
                    PluginUpdateFlow.shared.run(model: app, from: router.presenter)
                } label: {
                    HStack(spacing: 12) {
                        SettingsRowLabel(title: title, systemImage: "puzzlepiece.extension")
                        Spacer(minLength: 16)
                        HStack(spacing: 8) {
                            if busy { ProgressView().controlSize(.small) } else { CountBadgeView(count: reminder.count) }
                            SettingsChevron()
                        }
                    }
                    .contentShape(Rectangle())
                    .hqMacRowHover()   // [Mac AAA 2026-11-16]
                }
                .hqMacFormRowHeight()
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("settings.plugin-update")
            } footer: {
                if let footer = busy ? update.rowStatus : reminder.footer { HQSectionFooter { Text(footer) } }
            }
        }
    }

    @ViewBuilder
    private var mainSections: some View {
        if !model.moreBeside, !model.twoColumn {   // in two columns the gateway heads the category column
            Section {
                Button { router.push(GatewayPageController(services: model.services, router: router)) } label: {
                    GatewayCardView(model: model, padV: 2)
                }
                .accessibilityIdentifier("settings.gateway-card")
            }
        }

        if model.shows(.general) { addOnReminder; pluginReminder }

        // [appearance-groups] Owner 2026-11-18: Appearance's rows in groups by what they change (`AppearanceSections`).
        // The Mac's category pane draws the groups; on the iPhone and iPad they are a page of their own behind the
        // Appearance row below.
        if model.shows(.appearance), model.twoColumn {
            AppearanceSections(model: model, router: router, revealed: model.revealed)
        }

        if model.shows(.general) {
        Section {
            if !model.twoColumn {
                let _ = Theme.touch()
                NavRow(title: AppearancePage.title, systemImage: "paintbrush", value: Theme.shared.state.skin.label) {
                    router.push(AppearancePage.make(model: model, router: router))
                }
                .accessibilityIdentifier("settings.appearance-row")
            }
            // UX study 2026-10-21 #119: its state, as the rows beside it show theirs.
            NavRow(title: "Notifications", systemImage: "bell.badge", value: model.notificationsSummary) {
                router.push(NotificationsSettingsController(app: model.services as? AppModel))
            }
            .accessibilityIdentifier("settings.notifications")
            // [device-access] What the bots may use from this phone.
            NavRow(title: "Device Access", systemImage: "hand.raised", value: DeviceAccessCenter.shared.settings.rowSummary) {
                router.push(DeviceAccessSettingsController())
            }
            .accessibilityIdentifier("settings.device-access")
        }

        if let tasks = TasksSwitchRow() {
            Section {
                tasks.revealed(model.revealed)
            } footer: { HQSectionFooter { Text(TasksSwitchRow.footer) } }
        }
        }

        if model.shows(.chat) {
        // [Mac AAA 2026-11-17] Q18, owner: on the Mac each row's explanation is under its own title (`ChatRowNotes`),
        // and the paragraph under the card goes. The iPhone keeps its paragraph.
        let notes = DeviceWord.isMac
        Section {
            if let screen = SettingsHooks.toolCallsScreen {
                NavRow(title: SettingsHooks.toolCallsTitle, systemImage: "wrench.and.screwdriver", value: model.toolCallsSummary) { router.push(screen()) }
            }
            // The switch itself ticks (a system control): no cue of ours on top.
            Toggle(isOn: Binding(get: { model.fewerTimestamps }, set: { on in
                model.fewerTimestamps = on
                ToolCallSettings.fewerTimestamps = on
            })) {
                SettingsRowLabel(title: "Fewer Timestamps", systemImage: "clock", subtitle: notes ? ChatRowNotes.fewerTimestamps : nil)
            }
            .accessibilityIdentifier("settings.fewer-timestamps")
            .revealRow("row:fewer-timestamps", model.revealed)
            // [files] Owner 2026-11-20 (tester Mordred): Off / Folded / Open, Folded by default — the card as one line,
            // like a reply's work line, that opens on it.
            let fileChanges = Binding(get: { model.fileChanges }, set: { (value: FileChangesLook) in
                Haptics.play(.selection)
                model.fileChanges = value
                ToolCallSettings.fileChanges = value
                AppLog.note("settings", "File Changes set to \(value.rawValue)")
            })
            if DeviceWord.isMac {
                HStack(alignment: .firstTextBaseline, spacing: 12) {   // [Mac AAA 2026-11-17] on the title's line, as the switches
                    SettingsRowLabel(title: "File Changes", systemImage: "doc.badge.ellipsis", subtitle: ChatRowNotes.showFileChanges)
                    Spacer(minLength: 16)
                    MacPopUp(label: "File Changes", selection: fileChanges, options: FileChangesLook.allCases) { $0.title }
                        .accessibilityIdentifier("settings.show-file-changes")
                        .hqMacSettingsControl()
                }
                .revealRow("row:show-file-changes", model.revealed)
            } else {
                SettingsMenuRowFace(label: SettingsRowLabel(title: "File Changes", systemImage: "doc.badge.ellipsis"),
                                    value: model.fileChanges.title)
                .overlay {
                    Menu {
                        Picker("File Changes", selection: fileChanges) {
                            ForEach(FileChangesLook.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .accessibilityLabel("File Changes")
                    .accessibilityValue(model.fileChanges.title)
                    .accessibilityIdentifier("settings.show-file-changes")
                }
                .revealRow("row:show-file-changes", model.revealed)
            }
            Toggle(isOn: Binding(get: { model.newChatAsksProject }, set: { on in
                model.newChatAsksProject = on
                NewChatProjectChoice.isOn = on
            })) {
                SettingsRowLabel(title: "New Chat Asks for a Project", systemImage: "folder", subtitle: notes ? ChatRowNotes.newChatAsksProject : nil)
            }
            .accessibilityIdentifier("settings.new-chat-asks-project")
            .revealRow("row:new-chat-asks-project", model.revealed)
            // [ghost-stars] A provider removed in Hermes itself leaves its stars in a new chat until its models load.
            Toggle(isOn: Binding(get: { model.waitForModels }, set: { on in
                model.waitForModels = on
                ModelPrefs.waitForModels = on
            })) {
                SettingsRowLabel(title: "Favorites Wait for Models", systemImage: "star.slash")
            }
            .accessibilityIdentifier("settings.wait-for-models")
            .revealRow("row:wait-for-models", model.revealed)
            // [settings] §4
            if DeviceWord.isMac {
                // [mac] Stress test 2026-10-28 #81, round 2: with a gateway it lives in Chat Behavior › Attachments,
                // beside Image Attachments (MacAttachmentLimitRow); here only while there is no Chat Behavior.
                if model.configStore == nil {
                // [mac] Stress test 2026-10-28 #51: typed in place with its unit, not a page with iOS's "− | +".
                HStack(spacing: 12) {
                    SettingsRowLabel(title: "Largest Attachment", systemImage: "paperclip")
                    Spacer(minLength: 16)
                    MacIntField(value: Binding(get: { model.attachmentLimit }, set: { value in
                        AttachmentLimit.megabytes = value
                        model.attachmentLimit = value
                    }), range: AttachmentLimit.range, unit: "MB", label: "Largest Attachment")
                }
                .help(AttachmentLimit.footer())
                .accessibilityIdentifier("settings.attachment-limit")
                .revealRow("row:attachment-limit", model.revealed)
                }
            } else {
            NavRow(title: "Largest Attachment", systemImage: "paperclip", value: "\(model.attachmentLimit) MB") {
                router.push("Largest Attachment", AttachmentLimitPage { model.attachmentLimit = $0 })
            }
            .accessibilityIdentifier("settings.attachment-limit")
            }
            // [send-while-busy] Tester 2026-11-08: Queue, not Steer, as what Send does while a reply runs.
            let sendWhileBusy = Binding(get: { model.sendWhileBusy }, set: { (value: SendWhileBusy) in
                Haptics.play(.selection)
                model.sendWhileBusy = value
                SendWhileBusy.chosen = value
            })
            if DeviceWord.isMac {
                HStack(alignment: .firstTextBaseline, spacing: 12) {   // [Mac AAA 2026-11-17] on the title's line, as the switches
                    SettingsRowLabel(title: SettingsSearch.sendWhileBusyLabel, systemImage: "text.line.last.and.arrowtriangle.forward",
                                     subtitle: ChatRowNotes.sendWhileBusy(mac: true))
                    Spacer(minLength: 16)
                    MacPopUp(label: SettingsSearch.sendWhileBusyLabel, selection: sendWhileBusy, options: SendWhileBusy.allCases) { $0.title }
                        .accessibilityIdentifier("settings.send-while-busy")
                        .hqMacSettingsControl()
                }
                .revealRow("row:send-while-busy", model.revealed)
            } else {
                SettingsMenuRowFace(label: SettingsRowLabel(title: SettingsSearch.sendWhileBusyLabel, systemImage: "text.line.last.and.arrowtriangle.forward"),
                                    value: model.sendWhileBusy.title)
                .overlay {
                    Menu {
                        Picker(SettingsSearch.sendWhileBusyLabel, selection: sendWhileBusy) {
                            ForEach(SendWhileBusy.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .accessibilityLabel(SettingsSearch.sendWhileBusyLabel)
                    .accessibilityValue(model.sendWhileBusy.title)
                    .accessibilityIdentifier("settings.send-while-busy")
                }
                .revealRow("row:send-while-busy", model.revealed)
            }
            // [links-browser] Owner 2026-11-12: web links in a browser of your choice. A file a bot made (a page, a
            // tile) opens in the app whatever is chosen here (`LinkRoute`).
            let linkChoice = Binding(get: { model.linkChoice }, set: { (value: LinkBrowserChoice) in
                Haptics.play(.selection)
                model.linkChoice = value
                LinkBrowserChoice.stored = value
                AppLog.note("settings", "Open Links In set to \(value.saved)")
            })
            let linkChoices = LinkOpener.choices(installed: model.linkBrowsers)
            if DeviceWord.isMac {
                HStack(alignment: .firstTextBaseline, spacing: 12) {   // [Mac AAA 2026-11-17] on the title's line, as the switches
                    SettingsRowLabel(title: SettingsSearch.openLinksInLabel, systemImage: "safari", subtitle: ChatRowNotes.openLinksIn)
                    Spacer(minLength: 16)
                    MacPopUp(label: SettingsSearch.openLinksInLabel, selection: linkChoice, options: linkChoices) {
                        $0.title(installed: model.linkBrowsers)
                    }
                    .accessibilityIdentifier("settings.open-links-in")
                    .hqMacSettingsControl()
                }
                .help("Web links open in this browser. Pages and files your bots make always open in the app.")
                .revealRow("row:open-links-in", model.revealed)
            } else {
                SettingsMenuRowFace(label: SettingsRowLabel(title: SettingsSearch.openLinksInLabel, systemImage: "safari"),
                                    value: model.linkChoice.title(installed: model.linkBrowsers))
                .overlay {
                    Menu {
                        Picker(SettingsSearch.openLinksInLabel, selection: linkChoice) {
                            ForEach(linkChoices, id: \.self) { Text($0.title(installed: model.linkBrowsers)).tag($0) }
                        }
                    } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .accessibilityLabel(SettingsSearch.openLinksInLabel)
                    .accessibilityValue(model.linkChoice.title(installed: model.linkBrowsers))
                    .accessibilityIdentifier("settings.open-links-in")
                }
                .revealRow("row:open-links-in", model.revealed)
            }
            if DeviceWord.isMac {
                // [cmd-n] A tester 2026-11-02: ⌘N opens the bot's own chat instead of a new one, when asked.
                HStack(alignment: .firstTextBaseline, spacing: 12) {   // [Mac AAA 2026-11-17] on the title's line, as the switches
                    SettingsRowLabel(title: "⌘N Opens", systemImage: "command",
                                     subtitle: ChatRowNotes.newChatMode(botChat: model.newChatKeyMode == .botChat))
                    Spacer(minLength: 16)
                    MacPopUp(label: "⌘N Opens", selection: Binding(get: { model.newChatKeyMode }, set: { mode in
                        NewChatKeyBot.mode = mode
                        model.newChatKeyMode = mode
                    }), options: NewChatKeyBot.Mode.allCases) { $0.title }
                        .accessibilityIdentifier("settings.new-chat-mode")
                        .hqMacSettingsControl()
                }
                .revealRow("row:new-chat-mode", model.revealed)
                // [cmd-n] Tester 2026-11-02: the bot ⌘N starts a chat with, no chooser (⇧⌘N keeps it).
                HStack(spacing: 12) {
                    SettingsRowLabel(title: "⌘N Bot", systemImage: "square.and.pencil")
                    Spacer(minLength: 16)
                    MacPopUp(label: "⌘N Bot", selection: Binding(get: { model.newChatKeyBot }, set: { id in
                        NewChatKeyBot.chosen = id
                        model.newChatKeyBot = id
                    }), options: model.newChatKeyOptions, title: model.newChatKeyTitle)
                        .accessibilityIdentifier("settings.new-chat-key")
                        .hqMacSettingsControl()
                }
                .revealRow("row:new-chat-key", model.revealed)
                // [cmd-n] Owner 2026-11-02: "have the session default to a certain project". Shown once there is a
                // project to pick (or one is picked).
                // A bot's own chat has no project: the row goes while ⌘N opens it.
                if model.newChatKeyMode == .session, model.newChatKeyProjects.count > 1 {
                    HStack(spacing: 12) {
                        SettingsRowLabel(title: "⌘N Project", systemImage: "folder.badge.plus")
                        Spacer(minLength: 16)
                        MacPopUp(label: "⌘N Project", selection: Binding(get: { model.newChatKeyProject }, set: { key in
                            NewChatKeyBot.project = key.isEmpty ? nil : key
                            model.newChatKeyProject = key
                        }), options: model.newChatKeyProjects, title: model.newChatKeyProjectTitle)
                            .accessibilityIdentifier("settings.new-chat-project")
                            .hqMacSettingsControl()
                    }
                    .revealRow("row:new-chat-project", model.revealed)
                }
            }
            if model.configStore != nil {
                Toggle(isOn: Binding(get: { model.resumeLastSession }, set: { model.setResumeLastSession($0) })) {
                    SettingsRowLabel(title: "Reopen Last Chat on Launch", systemImage: "arrow.counterclockwise", subtitle: notes ? ChatRowNotes.resumeLastChat : nil)
                }
                .accessibilityIdentifier("settings.resume-last-chat")
                .revealRow("row:resume-last-chat", model.revealed)
            }
            Toggle(isOn: Binding(get: { model.inAppTips }, set: { on in
                Haptics.play(.selection)
                model.inAppTips = on
                InAppTips.isOn = on
            })) {
                SettingsRowLabel(title: "In-App Tips", systemImage: "lightbulb")
            }
            .accessibilityIdentifier("settings.tips")
            .revealRow("row:tips", model.revealed)
            // [settings] §7. The switch itself ticks (a system control): no cue of ours on top (DECISION 2.1).
            Toggle(isOn: Binding(get: { model.introSplash }, set: { on in
                model.introSplash = on
                IntroSplash.isOn = on
            })) {
                SettingsRowLabel(title: SettingsSearch.introSplashLabel, systemImage: "hand.wave")   // UX study #69: was "Intro Splash"
            }
            .accessibilityIdentifier("settings.intro-splash")
            .revealRow("row:intro-splash", model.revealed)
            // [settings] §12
            Toggle(isOn: Binding(get: { model.fileBrowser }, set: { on in
                model.fileBrowser = on
                FileBrowserPref.isOn = on
            })) {
                SettingsRowLabel(title: SettingsSearch.fileBrowserLabel, systemImage: "folder")   // UX study #69: was "File Browser"
            }
            .accessibilityIdentifier("settings.file-browser")
            .revealRow("row:file-browser", model.revealed)
            // [session-strip] [bot-chat-sessions] On the Mac too.
            Toggle(isOn: Binding(get: { model.sessionStrip }, set: { on in
                model.sessionStrip = on
                SessionStripPref.isOn = on
            })) {
                SettingsRowLabel(title: "Other Chats at the Top", systemImage: "capsule")
            }
            .accessibilityIdentifier("settings.session-strip")
            .revealRow("row:session-strip", model.revealed)
            Toggle(isOn: Binding(get: { model.messageReactions }, set: { on in
                model.messageReactions = on
                MessageReactionsPref.isOn = on
            })) {
                SettingsRowLabel(title: "Message Reactions", systemImage: "face.smiling", subtitle: notes ? ChatRowNotes.messageReactions : nil)
            }
            .accessibilityIdentifier("settings.message-reactions")
            .revealRow("row:message-reactions", model.revealed)
        } header: { categoryHeader("Chat") }
        }

        // [settings] §1, §18: "Sounds & Haptics". The Haptics row does not depend on the completion cue being wired.
        if model.shows(.sounds) {
        Section {
            // Owner 2026-11-01: every row of the card has its symbol (these three had none on the iPhone).
            if SettingsHooks.completionCueWired {
                Toggle(isOn: $model.completionSound) { SettingsRowLabel(title: "Completion Sound", systemImage: "speaker.wave.2") }
                    .accessibilityIdentifier("settings.completion-sound")
                    .onChange(of: model.completionSound) { _, value in
                        Haptics.play(.selection)
                        CompletionCue.isOn = value
                    }
                    .revealRow("row:completion-sound", model.revealed)
                if model.completionSound {
                    if DeviceWord.isMac {
                        // [mac] Owner 2026-11-09 (Settings "too iOS-like"): one choice is a pop-up in its row, not a
                        // page of its own. Choosing a sound plays it; the play button hears the chosen one again.
                        HStack(spacing: 12) {
                            SettingsRowLabel(title: "Sound", systemImage: "music.note")
                            Spacer(minLength: 16)
                            Button { CompletionCue.preview(CompletionCue.variant) } label: {
                                Image(systemName: "play.circle")
                                    .font(MacIcon.rowFont)
                                    .foregroundStyle(Color.hqLabel2)
                                    .frame(width: MacIcon.rowColumn, height: MacIcon.rowColumn)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .help("Play \(model.soundName)")
                            .accessibilityLabel("Play \(model.soundName)")
                            MacPopUp(label: "Sound", selection: Binding(get: { CompletionSoundVariant.preset(CompletionCue.variant).id }, set: { id in
                                CompletionCue.variant = id
                                model.soundName = CompletionSoundVariant.preset(id).name
                                CompletionCue.preview(id)
                            }), options: CompletionSoundVariant.presets.map(\.id)) { CompletionSoundVariant.preset($0).name }
                                .accessibilityIdentifier("settings.sound")
                                .hqMacSettingsControl()
                        }
                        .revealRow("row:sound", model.revealed)   // [Mac UI check 2026-11-13] Settings search lands here
                    } else {
                    NavRow(title: "Sound", systemImage: "music.note", value: model.soundName) { router.push("Sound", CompletionSoundPicker()) }
                        .accessibilityIdentifier("settings.sound")
                    }
                }
            }
            if SettingsSearch.hasHaptics {   // [mac] not on the Mac (SettingsSearch.hasHaptics)
                Toggle(isOn: Binding(get: { model.haptics }, set: { on in
                    model.haptics = on
                    Haptics.isOn = on
                })) {
                    SettingsRowLabel(title: "Haptics", systemImage: "hand.tap")
                }
                .accessibilityIdentifier("settings.haptics")
                .revealRow("row:haptics", model.revealed)
            }
            // [thinking-drive] Owner 2026-11-01: the thinking bar "going into hyperspace", felt and seen.
            let drive = Binding(get: { model.thinkingDrive }, set: { (value: ThinkingDrive) in
                Haptics.play(.selection)
                model.thinkingDrive = value
                ThinkingDrive.chosen = value
            })
            // [macpass-settings2] On the Mac it is in Appearance (`macThinkingBarRow`): nothing there is heard or felt.
            if !DeviceWord.isMac {
                SettingsMenuRowFace(label: SettingsRowLabel(title: "Thinking Bar", systemImage: "gauge.with.dots.needle.67percent"), value: model.thinkingDrive.title)
                .overlay {
                    Menu {
                        Picker("Thinking Bar", selection: drive) {
                            ForEach(ThinkingDrive.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .accessibilityLabel("Thinking Bar")
                    .accessibilityValue(model.thinkingDrive.title)
                    .accessibilityIdentifier("settings.thinking-drive")
                }
                .revealRow("row:thinking-drive", model.revealed)
            }
        } header: { categoryHeader(!SettingsSearch.hasHaptics ? "Sounds" : SettingsHooks.completionCueWired ? "Sounds & Haptics" : "Haptics") }
        }

        if model.shows(.gateway) {
        if model.configStore != nil {
            Section {
                ForEach(ConfigCatalog.sections) { section in
                    NavRow(title: section.title, systemImage: section.symbol) { ConfigScreens.open(section: section, router: router) }
                        .accessibilityIdentifier("settings.config.\(section.id)")
                    if section.id == "browser" {
                        // UX study #67: Safety keeps the shield; Keys already has "key".
                        NavRow(title: "Passwords", systemImage: "person.badge.key") { SettingsNavigator.openRoot("vault", router: router) }
                            .accessibilityIdentifier("settings.vault")
                    }
                }
                // UX study #68: not "Sessions", the tab's name: the page sets new chats' folder and archives old ones.
                NavRow(title: SettingsSearch.sessionsPageTitle, systemImage: "folder.badge.gearshape") {
                    SettingsNavigator.openRoot("sessions", router: router)
                }
                    .accessibilityIdentifier("settings.sessions")
            } header: { HQSectionLabel {
                Text("On Your Gateway")   // UX study #72: was "Hermes", which said nothing about where these are kept
            } }

            Section {
                NavRow(title: "Phone Calls (Beta)", systemImage: "phone") { SettingsNavigator.openRoot("phone-calls", router: router) }
                    .accessibilityIdentifier("settings.phone-calls")
                NavRow(title: "Providers", systemImage: "bolt") { SettingsNavigator.openRoot("providers", router: router) }
                    .accessibilityIdentifier("settings.providers")
                NavRow(title: "Keys", systemImage: "key") { SettingsNavigator.openRoot("keys", router: router) }
                    .accessibilityIdentifier("settings.keys")
                NavRow(title: "Billing", systemImage: "creditcard") { SettingsNavigator.openRoot("billing", router: router) }
                    .accessibilityIdentifier("settings.billing")
                // The owner 2026-11-14: Browser Use Cloud was per bot only; its key and "Use for All Bots" live here.
                NavRow(title: "Browser Use Cloud", systemImage: "cloud") { SettingsNavigator.openRoot("browser-use-cloud", router: router) }
                    .accessibilityIdentifier("settings.browser-use-cloud")
            } header: { HQSectionLabel {
                Text("Accounts & Keys")
            } }
        }

        // [talk] Without the gateway's settings Voice still opens: its switches belong to this iPhone (3x-talk §9.1).
        if model.configStore == nil {
            Section {
                NavRow(title: "Voice", systemImage: "mic") { VoiceSettingsScreens.openSection(router: router) }
                    .accessibilityIdentifier("settings.config.voice")
            }
        }
        }

        if model.shows(.tools) {
        Section {
            // [cap-pages] Owner 2026-11-03 (one home per page): Capabilities by its own name, the page More lists, not
            // Skills, Connectors and Plugins rows that each opened it under the title "Capabilities".
            let issue = CapabilitiesIssues.moreStatus()
            NavRow(title: "Capabilities", systemImage: "square.grid.2x2", value: issue?.text, valueIsIssue: issue != nil) {
                router.push(CapabilitiesHubController(services: model.services, settingsPage: true))
            }
            .accessibilityValue(issue?.spoken ?? "")
            .accessibilityIdentifier("settings.capabilities")
            // [tile-models] Owner 2026-11-18: the model the tiles' jobs run, and their fallback (each tile can have its own).
            if let summary = model.tileModelSummary {
                NavRow(title: "Tile Model", systemImage: "rectangle.3.group", value: summary) {
                    SettingsNavigator.openRoot("tile-model", router: router)
                }
                .accessibilityIdentifier("settings.tile-model")
            }
            #if targetEnvironment(macCatalyst)
            // [mac-layout] Owner 2026-11-03 (the layout study): More dissolves on the Mac. Its setup pages (the bots'
            // profiles, messaging apps, webhooks, imports) are here in the Settings window; its working pages are the
            // sidebar's Tools. (Capabilities is the row above.)
            if model.ownWindow || model.twoColumn {
                ForEach(Self.movedFromMore(), id: \.id) { row in
                    NavRow(title: row.title, systemImage: row.symbol.map(PagesTabs.outlineSymbol)) {
                        if let page = row.make() { router.push(page) }
                    }
                    .accessibilityIdentifier("settings.more.\(row.id)")
                }
            }
            #endif
            // [kanban-tab-one] Owner 2026-11-03 (one home per page): no Kanban Tab row here. Its one picker is on
            // Appearance › Tabs, with the other tab choices.
        } header: { categoryHeader("Bots & Tools") }

        if let app = model.services as? AppModel, model.services.account != nil,
           !(app.settingsHub.capabilitiesStore?.readOnlyGateway ?? false) {
            let update = AddOnUpdate.shared
            let busy = update.busy && update.pluginRun
            Section {
                Toggle(isOn: Binding(get: { model.autoPluginUpdateChecks }, set: { model.setAutoPluginUpdateChecks($0) })) {
                    SettingsRowLabel(title: "Check Automatically", systemImage: "arrow.triangle.2.circlepath")
                }
                .accessibilityIdentifier("settings.plugin-update-checks")
                .revealRow("row:plugin-update-checks", model.revealed)
                Button {
                    PluginUpdateFlow.shared.run(model: app, from: router.presenter)
                } label: {
                    HStack(spacing: 12) {
                        SettingsRowLabel(title: busy ? update.rowLabel : SettingsSearch.checkPluginUpdatesLabel,
                                         systemImage: "arrow.down.circle")
                        Spacer(minLength: 16)
                        if busy { ProgressView().controlSize(.small) } else { SettingsChevron() }
                    }
                    .contentShape(Rectangle())
                    .hqMacRowHover()
                }
                .hqMacFormRowHeight()
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("settings.check-plugin-updates")
                .revealRow("row:check-plugin-updates", model.revealed)
            } header: { HQSectionLabel {
                Text("Plugin Updates")
            } } footer: { HQSectionFooter {
                Text(PluginUpdateReminder.autoCheckFooter)
            } }
        }
        }

        #if targetEnvironment(macCatalyst)
        // [mac] Stress test 2026-10-28 #40: macOS keeps a new app's Share extension off until it is switched on, and
        // nothing said so. The row opens the System Settings page that does it.
        if model.shows(.general) {
        Section {
            // [macpass-settings2] The row leaves the app for System Settings, so it is a push button that says so, not a
            // page row (a click that seemed to open a page here brought System Settings forward instead).
            HStack(spacing: 12) {
                SettingsRowLabel(title: "Share Menu", systemImage: "square.and.arrow.up")
                Spacer(minLength: 16)
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.share-services") {
                        UIApplication.shared.open(url)
                    }
                }
                .hqMacPushButton()
                .fixedSize()
                .accessibilityIdentifier("settings.share-menu")
            }
            .hqMacFormRowHeight()
            .revealRow("row:share-menu", model.revealed)
        } footer: { HQSectionFooter {
            Text("To send files, links and text to a bot from other apps' Share menus, switch on Hermes HQ in System Settings › General › Login Items & Extensions › Sharing.")
        } }
        }
        #endif

        if model.shows(.about) {
        Section {
            NavRow(title: "About", systemImage: "info.circle") {
                router.push(AboutController(services: model.services, router: router))
            }
            .accessibilityIdentifier("settings.about")
        }

        if model.configStore != nil {
            Section {
                if DeviceWord.isMac {
                    // [mac] Stress test 2026-10-28 #51: push buttons at the row's trailing edge, not rows in link blue.
                    // [macpass-settings] Four buttons don't fit one line of the Settings window's page: they squeezed
                    // into two-line labels. One line when they fit, else two lines of two, each label on one line.
                    let fileButtons = HStack(spacing: 10) {
                        Button("Export Settings…") { actions.export() }
                            .accessibilityIdentifier("settings.export")
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { actions.exportAnchor = $0 }   // [Mac UI check 2026-11-13]
                        Button("Import Settings…") { actions.pickImport() }
                            .accessibilityIdentifier("settings.import")
                    }
                    let resetButtons = HStack(spacing: 10) {
                        Button("Clear Model Favorites…") { actions.confirmClearModels() }
                            .accessibilityIdentifier("settings.clear-models")
                        Button("Reset to Defaults…", role: .destructive) { actions.confirmReset() }
                            .disabled(model.resetting)
                            .accessibilityIdentifier("settings.reset")
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { fileButtons; resetButtons }.fixedSize()
                        VStack(alignment: .leading, spacing: 8) { fileButtons; resetButtons }.fixedSize()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hqMacBordered()   // [mac] Stress test 2026-10-28 #55 (round 6): the Mac push button; Reset keeps red words (its role)
                } else {
                Button("Export Settings…") { actions.export() }
                    .accessibilityIdentifier("settings.export")
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { actions.exportAnchor = $0 }   // [Mac UI check 2026-11-13]
                Button("Import Settings…") { actions.pickImport() }
                    .accessibilityIdentifier("settings.import")
                // [stale-stars] Tester 2026-11-09: above Reset, where he looked for it.
                Button("Clear Favorite & Recent Models…") { actions.confirmClearModels() }
                    .accessibilityIdentifier("settings.clear-models")
                Button("Reset to Defaults…", role: .destructive) { actions.confirmReset() }
                    .disabled(model.resetting)   // UX study 2026-10-21 #209: "Resetting…" shows below while it writes
                    .accessibilityIdentifier("settings.reset")
                }
            } footer: { HQSectionFooter {
                VStack(alignment: .leading, spacing: 6) {
                    if let status = model.fileStatus {
                        Text(status).foregroundStyle(Color.hqLabel).accessibilityIdentifier("settings.file-status")
                    }
                    Text("Exported files leave out keys, tokens and passwords.")
                }
            } }
        }
        }
    }
}

/// [mac-ui-issues] Settings' categories on the Mac (`SettingsRootModel.twoColumn`).
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, appearance, chat, sounds, gateway, tools, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .chat: "Chat"
        case .sounds: SettingsSearch.hasHaptics ? "Sounds & Haptics" : "Sounds"
        case .gateway: "Hermes"
        case .tools: "Bots & Tools"
        case .about: "About"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .chat: "bubble.left.and.bubble.right"
        case .sounds: "speaker.wave.2"
        case .gateway: "server.rack"
        case .tools: "wrench.and.screwdriver"
        case .about: "info.circle"
        }
    }
}

/// The category column: the gateway (its page), then the categories; the one on show carries the window's own mark.
/// [mac-ten] Owner 2026-11-11 ("weird UI issues"): it was filled in the full tint with white words, as System
/// Settings' sidebar marks its own: the one saturated row in the app, a few points from the sidebar's soft mark, and
/// it stayed blue when Chat Bubbles › Colour (a page of this very list) gave the Mac's chosen row another colour.
/// It is the sidebar's mark now (`MacSelection.accent`): the same fill, the symbol in the tint; on the Mac the name
/// keeps its regular weight (owner decision, as the sidebar's rows).
struct SettingsCategoryColumn: View {
    @Bindable var model: SettingsRootModel
    let router: SettingsRouter
    /// [macpass-settings2] Grows with UI Scale, as `MacForm.labelWidth` does: at a fixed 270 the field's "Search
    /// Settings" was cut to "Search Setti" at 130 %, and the category names came close to the edge.
    static var width: CGFloat {
        (270 * CGFloat(ThemeTable.current.state.uiScalePercent) / 100).rounded()
    }
    /// The chosen category's fill and corners: the sidebar's on the Mac (the only place the column is drawn).
    private static var mark: Color {
        #if targetEnvironment(macCatalyst)
        Color(uiColor: MacSelection.accent)
        #else
        Color.hqTint.opacity(0.3)
        #endif
    }
    private static var markRadius: CGFloat {
        #if targetEnvironment(macCatalyst)
        MacSelection.radius
        #else
        9
        #endif
    }
    @FocusState private var searching: Bool

    var body: some View {
        let _ = Theme.touch()   // drawn again when UI Scale changes
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                    // [macpass-settings] Only a real change: the field writes its words back when it loses focus (a sheet opening
                    // over the window), and each write popped the pane to its root, so Add Gateway… closed the Gateway page.
                    // [macpass-settings] One line of body text sets the field's height, the field laid over it: an
                    // editing field is a point taller than a resting one, and the whole column jumped as you typed.
                    Text(verbatim: " ").font(Font.hq(.body)).frame(maxWidth: .infinity).hidden().accessibilityHidden(true)
                        .overlay {
                            TextField("Search Settings", text: Binding(get: { model.query }, set: { guard $0 != model.query else { return }; model.query = $0; model.columnChanged?() }))
                                .textFieldStyle(.plain)
                                .font(Font.hq(.body))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .accessibilityIdentifier("settings.search")
                                .focused($searching)
                                .onChange(of: model.focusSearch) { _, _ in searching = true }
                                // [Mac AAA 2026-11-16] Return opens the first result and Escape empties the field, as
                                // in System Settings' search; they did nothing.
                                .onSubmit {
                                    guard let first = model.searchResults.first else { return }
                                    searching = false
                                    model.openResult?(first.target)
                                }
                                .onKeyPress(.escape) {
                                    guard !model.query.isEmpty else { return .ignored }
                                    model.query = ""
                                    model.columnChanged?()
                                    return .handled
                                }
                        }
                    // Always laid out, shown only with words in the field (it is laid out the same either way).
                    Button { model.query = ""; model.columnChanged?() } label: {
                        Image(systemName: "xmark.circle.fill").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear Search")
                    .opacity(model.query.isEmpty ? 0 : 1)
                    .disabled(model.query.isEmpty)
                    .accessibilityHidden(model.query.isEmpty)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.hqFill3, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.bottom, 10)
                Button {
                    model.query = ""
                    if let open = model.openGateway {
                        open()
                    } else {
                        model.columnChanged?()
                        router.push(GatewayPageController(services: model.services, router: router))
                    }
                } label: {
                    HStack(spacing: 10) {
                        // [macpass-settings2] The column's pictures follow UI Scale as its words do (they stayed 20 and
                        // 16 pt beside text that grew and shrank).
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: HQFont.scaled(20)))   // a11y-font-ok: the Mac Settings window's column picture; the Mac has no Dynamic Type
                            .foregroundStyle(Color.hqTintText)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.gatewayName.isEmpty ? "Gateway" : model.gatewayName)
                                .font(Font.hq(.headline))
                                .foregroundStyle(Color.hqLabel)
                                .lineLimit(2)
                            Text(model.host)
                                .font(Font.hq(.footnote))
                                .foregroundStyle(Color.hqLabel2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(model.gatewayMarked ? Self.mark : Color.clear, in: RoundedRectangle(cornerRadius: Self.markRadius, style: .continuous))
                    .hqPointerFill(Self.markRadius, on: !model.gatewayMarked)   // [mac] Feel list B: the column's rows light under the pointer
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.gateway-card")
                .padding(.bottom, 10)
                ForEach(SettingsCategory.allCases) { category in
                    let on = model.category == category && model.query.isEmpty && !model.gatewayMarked
                    Button { model.query = ""; model.category = category; model.columnChanged?() } label: {
                        HStack(spacing: 10) {
                            // [type-body] On the Mac the glyph at its words' size (MacIcon.rowSize, the body), as Mail's and
                            // Finder's sidebars draw theirs: 16 × UI Scale stood a size bigger than 13 pt words.
                            Image(systemName: category.symbol)
                                .font(.system(size: DeviceWord.isMac ? MacIcon.rowSize : HQFont.scaled(16)))   // a11y-font-ok: as above
                                .foregroundStyle(Color.hqTintText)
                                .frame(width: 30)
                            Text(category.title)
                                .font(Font.hq(.body).weight(on && !DeviceWord.isMac ? .semibold : .regular))
                                .foregroundStyle(Color.hqLabel)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(on ? Self.mark : Color.clear, in: RoundedRectangle(cornerRadius: Self.markRadius, style: .continuous))
                        .hqPointerFill(Self.markRadius, on: !on)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? [.isSelected] : [])
                    .accessibilityIdentifier("settings.category.\(category.rawValue)")
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 12 + ScrollBarLane.listTrailing)
            // [Mac AAA 2026-11-16] The search field on the sidebar's search line (its middle 79 pt down in both
            // windows): beside the sidebar it stood 6 pt higher than the sidebar's own field. [Mac AAA rest 2026-11-17]
            // Mac only: the iPad's two-column Settings keeps its 14 pt (no sidebar field beside it to line up with).
            .padding(.top, DeviceWord.isMac ? 20 : 14)
            .padding(.bottom, 14)
        }
        .frame(width: Self.width)
    }
}

/// The gateway card (`S/ui-nav/more-account.tsx:18-63`): app mark 48 pt, name (Title 3 semibold, wraps), status line
/// with its dot, chevron. Min 64 pt (76 in the Desktop Look), 14 pt gap. [compact] iOS look: its own padding is 10 pt where nothing pads it (More's
/// cell); in a List row, which already pads its rows, 2 pt (owner 2026-10-17: the card was too tall).
struct GatewayCardView: View {
    let model: SettingsRootModel
    var padV: CGFloat = 10
    @Environment(\.dynamicTypeSize) private var typeSize
    /// [a11y] The status line's capital height (10.5 pt at the default size): the dot stays level with the middle
    /// of the first line as the text grows, instead of sitting at its foot.
    @ScaledMetric(relativeTo: .subheadline) private var statusCap: CGFloat = 10.5
    /// The status dot grows with the text (8 pt at the default size, at most 14), so it isn't a speck at AX sizes.
    @ScaledMetric(relativeTo: .subheadline) private var dotSize: CGFloat = 8

    // [mac] Stress test 2026-10-28 round 6: the dot no longer hangs in the gap before the text column (#68 did); it
    // leads the status line inside the column, its left edge under the name's, on every device.
    /// [mac] The name is an address (one word, no spaces) and the text isn't at an accessibility size.
    private var oneLineAddress: Bool {
        DeviceWord.isMac && !typeSize.isAccessibilitySize && !model.gatewayName.contains(" ")
    }

    /// [mac-audit] Owner 2026-11-02 (#22): on the Mac a gateway with a name (its computer's, or one given here) has its
    /// address under the name, as Settings › Gateway's rows do. The iPhone's card keeps its two lines.
    private var showsAddress: Bool {
        DeviceWord.isMac && !model.host.isEmpty && model.host != model.gatewayName
    }

    var body: some View {
        HStack(spacing: 14) {
            // At accessibility sizes the icon goes above the text (as in iOS Settings), so the name keeps the width.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    icon
                    details
                }
                .layoutPriority(1)   // [mac] Stress test 2026-10-28 round 6: see below
            } else {
                icon
                details
                    // [mac] Stress test 2026-10-28 round 6: the cause of More's three status lines. An HStack shares
                    // what is left between its flexible children, so the text column got about half (the Spacer took
                    // the rest) and DotSeparatedText's two-line layouts didn't fit it. The text goes first now.
                    .layoutPriority(1)
            }
            Spacer(minLength: 8)
            if !DeviceWord.isMac {   // [mac] Stress test 2026-10-28 #51: More and Settings are source lists on the Mac
                Image(systemName: "chevron.right")
                    .font(Font.hq(.footnote).weight(.semibold))
                    .foregroundStyle(Color.hqLabel3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { rowWidth = $0 })   // [gateway-card]
        .padding(.vertical, Theme.isDesktop ? 12 : padV)
        .frame(minHeight: Theme.isDesktop ? 76 : 64)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        // UX study #64: an unnamed gateway's name is its address, so the address is said once; where it goes is a hint.
        .accessibilityLabel(SettingsWords.gatewayCardLabel(name: model.gatewayName, status: model.statusLine, host: model.host))
        .accessibilityHint(SettingsWords.gatewayCardHint)
        .accessibilityAddTraits(.isButton)
    }

    private var icon: some View {
        WornAppIcon(side: 48)
    }

    /// [gateway-card] The row's width, for choosing the status line's form.
    @State private var rowWidth: CGFloat = 0

    private static func width(_ text: String, _ font: UIFont, medium: Bool = false) -> CGFloat {
        let face = medium ? HQFont.system(ofSize: font.pointSize, weight: .medium) : font
        return ceil((text as NSString).size(withAttributes: [.font: face]).width) + 2
    }

    /// How far the dot's middle sits above the status line's baseline.
    /// [mac] Stress test 2026-10-28 round 7: on the Mac the line's font is scaled by the look's base and UI Scale (about
    /// 19.5 pt at 100 % against iOS's 15) but `statusCap` isn't, so the dot sat about 2 pt low. There its middle is the
    /// middle of the font's own x-height, as "Connected" is drawn.
    private var dotLift: CGFloat {
        if DeviceWord.isMac { return (HQFont.preferred(.subheadline).xHeight / 2).rounded(.toNearestOrAwayFromZero) }
        return statusCap / 2 - 2.25
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            if oneLineAddress {
                // [mac] Stress test 2026-10-28 (leftover): in a 320 pt list "127.0.0.1:9871" broke after its colon;
                // an address (one word) keeps one line and gives up its middle.
                Text(model.gatewayName)
                    .font(Font.hq(.title3).weight(.semibold))
                    .foregroundStyle(Color.hqLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(model.gatewayNameForWrapping)
                    .font(Font.hq(.title3).weight(.semibold))
                    .foregroundStyle(Color.hqLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsAddress {
                Text(model.host)
                    .font(Font.hq(.subheadline))
                    .foregroundStyle(Color.hqLabel2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // The dot's middle sits at the middle of the capitals (3 pt above the baseline at the default size).
            let dot = min(dotSize, 14)
            let state = HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(model.dotColor).frame(width: dot, height: dot)
                    .alignmentGuide(.firstTextBaseline) { $0.height / 2 + dotLift }
                // Owner 2026-11-04: "Connected · 1 Bot · Hermes 0.22.6" broke wherever the width ran out, its tail
                // indented under "Connected", and read as an accident. The state has its own line; the facts sit
                // under it, smaller and quieter, from the column's left edge.
                Text(model.stateWords)
                    .font(Font.hq(.subheadline).weight(.medium))
                    .foregroundStyle(Color.hqLabel2)
            }
            // [gateway-card] Owner 2026-11-10 (design pick 19): when the state and the facts fit one line they share
            // it ("● Connected · 8 Bots · Hermes 0.21.5"), so the card is two lines. When they don't, the 2026-11-04
            // form stands: the state on its own line and the facts under it, never a broken line.
            if model.factPieces.isEmpty {
                state
            } else {
                // Chosen by measuring (a `ViewThatFits` here always took the two-line form: the row's first layout pass
                // offers the column no width): the line at its own sizes, else a size down, else two lines.
                let facts = " · " + model.factPieces.joined(separator: " · ")
                let room = rowWidth - 48 - 14 - (DeviceWord.isMac ? 8 : 34)
                let full = dot + 6 + Self.width(model.stateWords, HQFont.preferred(.subheadline), medium: true) + Self.width(facts, HQFont.preferred(.footnote))
                let small = 7 + 5 + Self.width(model.stateWords + facts, HQFont.preferred(.caption1), medium: true)
                if rowWidth > 0, !typeSize.isAccessibilitySize, full <= room {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        // [Mac AAA rest 2026-11-17] The state is never broken inside its word: in the iPhone's Desktop
                        // Look the measure above came out a few points short and "Connected" broke as "Connecte / d".
                        // If the line is that little too long the facts give up a little size instead (where it fits,
                        // as chosen, both draw exactly as before).
                        state.fixedSize()
                        Text(facts)
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color(uiColor: HQPalette.cardNote))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                } else if rowWidth > 0, !typeSize.isAccessibilitySize, small <= room {
                    // A narrower phone (the mini): the whole line a size down before it is given up for two lines.
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Circle().fill(model.dotColor).frame(width: 7, height: 7)
                            .alignmentGuide(.firstTextBaseline) { $0.height / 2 + dotLift - 0.5 }
                        Text("\(Text(model.stateWords).fontWeight(.medium).foregroundStyle(Color.hqLabel2))\(Text(facts).foregroundStyle(Color(uiColor: HQPalette.cardNote)))")
                            .font(Font.hq(.caption))
                            .lineLimit(1)
                            .fixedSize()
                    }
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        state
                        // Mac polish #68: label 2 in the iOS look (label 3 read about 2.1:1 on the card); the Desktop Look's 3.
                        DotSeparatedText(pieces: model.factPieces)
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color(uiColor: HQPalette.cardNote))
                    }
                }
            }
        }
    }
}

/// A row that pushes a page: title (with an optional symbol), an optional value, a chevron. Wrapping text gets
/// iOS's own row padding (owner 2026-10-16: no extra 4 pt, so rows match the Settings app's).
/// Item 16: the name wins over the value. At the largest standard size and up, a name and value that don't both fit
/// stacked the name onto two lines ("Tool / Calls") so the value could stay on one line; the value now moves under
/// the name instead, as iOS Settings does. (`SettingsMenuRowFace` already does this for its own menu rows.)
struct NavRow: View {
    var title: String
    var systemImage: String? = nil
    var value: String? = nil
    /// [cap-pages] The value is a problem (Capabilities' "1 Issue"): red, as More draws it.
    var valueIsIssue = false
    var action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            let stacked = typeSize >= .xxxLarge && value != nil
            let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
                if let systemImage {
                    SettingsRowLabel(title: title, systemImage: systemImage)
                } else {
                    Text(title).foregroundStyle(Color.hqLabel)
                }
                if !stacked { Spacer(minLength: 16) }
                HStack(spacing: 4) {
                    if let value { Text(value).foregroundStyle(valueIsIssue ? Color.hqRed : Color.hqLabel2).multilineTextAlignment(.trailing) }
                    // [mac] Stress test 2026-10-28 #51: no chevron on the Mac, on the root's source list and every page alike.
                    SettingsChevron()
                }
            }
            .contentShape(Rectangle())
            .hqMacRowHover()   // [Mac AAA 2026-11-16] a row that opens a page answers the pointer
        }
        .hqMacFormRowHeight()   // [mac] Stress test 2026-10-28 round 8: the form's one row height (53 on About, 58 with a symbol)
        .accessibilityAddTraits(.isButton)
    }
}

/// A menu row as the Kanban Tab and Light or Dark rows draw it under their Menu: the title, and at the trailing edge
/// the value with the up-down chevron. At accessibility sizes the value goes under the title, as a LabeledContent's
/// does, instead of both being squeezed into one line and broken mid-word. [kanban-tab-one] Any label: Tabs draws the
/// Kanban Tab row's with that page's own glyph.
struct SettingsMenuRowFace<RowLabel: View>: View {
    var label: RowLabel
    var value: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            label
            if !stacked { Spacer(minLength: 16) }
            HStack(spacing: 4) {
                Text(value)
                Image(systemName: "chevron.up.chevron.down").font(Font.hq(.footnote).weight(.semibold))
            }
            .foregroundStyle(Color.hqLabel2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }
}

/// A row's title with its symbol in a fixed-width column (UX study #66: glyphs of different widths started their titles
/// at different places from card to card). NavRow and the menu rows share it. A switch or picker has no symbol
/// (#66) but keeps the column empty in a card whose other rows have one, so the card's titles start together (#60).
/// [desktoplook] The look draws More's glyph: 15 pt, secondary grey, a 20 pt column (UX study 2026-10-21 #198).
/// Item 8: in the iOS look every symbol sits in a coloured rounded tile, as More draws its own rows, instead of a
/// bare outline glyph. Owner 2026-11-01 ("some kinda suck"): the tile's colour and filled glyph come from `tiles`, picked
/// for what the row is (red Notifications, pink sounds, as iOS Settings), not hashed from the symbol's name.
struct SettingsRowLabel: View {
    var title: String
    var systemImage: String? = nil
    /// [mac] Stress test 2026-10-28 #24, #93: the symbol a switch or picker row has on the Mac, where every row of the
    /// Settings list has one (some had, some hadn't, and the two kinds were different heights).
    var macSymbol: String? = nil
    /// No symbol: whether the empty column is kept (a card with symbols) or the title starts at the edge.
    var keepsColumn = true
    /// [Mac AAA 2026-11-17] Q18: a line under the title, in the style of Notifications' rows (footnote, the second
    /// label colour, 2 pt under the title, wrapping). Settings › Chat on the Mac.
    var subtitle: String? = nil
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 29
    @ScaledMetric(relativeTo: .body) private var desktopIconWidth: CGFloat = 20
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var scheme


    @ViewBuilder private var titleText: some View {
        if let subtitle {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Color.hqLabel)
                Text(subtitle).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(title).foregroundStyle(Color.hqLabel)
        }
    }

    var body: some View {
        let desktop = Theme.isDesktop
        let symbol = systemImage ?? (DeviceWord.isMac ? macSymbol : nil)
        let systemImage = symbol.map { Self.outline($0, dark: scheme == .dark) }
        // At accessibility sizes the rows stack and the empty column only pushes the title's first line in.
        if systemImage == nil && (!keepsColumn || typeSize.isAccessibilitySize) {
            titleText
        } else {
            Label {
                titleText
            } icon: {
                // [mac] Stress test 2026-10-28 #58: one glyph size and weight in one column width on every Settings row
                // (`MacIcon`), following UI Scale as the titles do (a ScaledMetric doesn't on the Mac).
                // [ui-sizing 2026-11-09] × UI Scale on the iPhone too: the glyph followed it and the tile didn't, so at 150 %
                // a 22 pt glyph filled a 29 pt tile.
                let width = DeviceWord.isMac ? MacIcon.rowColumn : HQFont.scaled(desktop ? desktopIconWidth : iconWidth)
                if let systemImage {
                    if DeviceWord.isMac {
                        // #93: one box for every glyph, so a row's height doesn't follow its symbol's.
                        // [Mac AAA 2026-11-16] The Label placed its title by the glyph's own metrics, which differ
                        // from glyph to glyph (mic, person.badge.key, app.badge), so titles stood 15 to 19 pt under
                        // their row's top. The glyph is drawn over a plain box of the column's size, which alone sets
                        // the title's place: the box's middle is the title's capital middle on every row.
                        let capHalf = HQFont.preferred(.body).capHeight / 2
                        Color.clear.frame(width: width, height: width)
                            .overlay {
                                Image(systemName: systemImage).font(Self.fittedFont(systemImage, column: width))
                                    .foregroundStyle(desktop ? Color.hqLabel2 : Color.hqLabel)
                            }
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + capHalf }
                            .alignmentGuide(.lastTextBaseline) { $0[VerticalAlignment.center] + capHalf }
                    } else if desktop {
                        Image(systemName: systemImage).font(Font.hqSystem(size: 15)).foregroundStyle(Color.hqLabel2).frame(width: width)
                    } else if let ink = Theme.inkIcons {
                        // [paper-icons] The theme's ink, on its own tile or alone, in the tile's column.
                        let tile = Self.tile(for: symbol ?? systemImage)
                        if ink == .plain {
                            Image(systemName: systemImage).font(Self.tileFont(systemImage, tile: width * 1.2).weight(.regular))
                                .foregroundStyle(Color.hqLabel).frame(width: width, height: width)
                        } else {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color(uiColor: HQPalette.iconTile))
                                .frame(width: width, height: width)
                                .overlay {
                                    Image(systemName: tile.glyph).font(Self.tileFont(tile.glyph, tile: width)).foregroundStyle(Color.hqLabel)
                                }
                        }
                    } else {
                        let tile = Self.tile(for: symbol ?? systemImage)
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color(UIColor(hex: tile.colour)))
                            .frame(width: width, height: width)
                            .overlay {
                                Image(systemName: tile.glyph).font(Self.tileFont(tile.glyph, tile: width)).foregroundStyle(.white)
                            }
                    }
                } else {
                    Color.clear.frame(width: width, height: 1).accessibilityHidden(true)
                }
            }
        }
    }
}

extension SettingsRowLabel {
    /// iOS-look tile colours (the `MorePages` palette plus iOS Settings' pink and grey).
    private enum Tile {
        static let red: UInt32 = 0xFF3B30, pink: UInt32 = 0xFF2D55, rose: UInt32 = 0xE5446D, orange: UInt32 = 0xFF9500
        static let amber: UInt32 = 0xFF9F0A, green: UInt32 = 0x30B94D, teal: UInt32 = 0x00A2B8, sky: UInt32 = 0x32ADE6
        static let blue: UInt32 = 0x0A84FF, indigo: UInt32 = 0x5E5CE6, purple: UInt32 = 0x8E5CD9, grey: UInt32 = 0x8E8E93
        static let graphite: UInt32 = 0x636366, brown: UInt32 = 0xA2845E
    }

    /// The tile for each row symbol: the white glyph drawn on it (filled, as iOS Settings draws its own) and its colour.
    /// Rows next to each other get different colours; a symbol shared by two pages keeps one tile.
    static let tiles: [String: (glyph: String, colour: UInt32)] = [
        // Appearance
        "circle.lefthalf.filled": ("circle.lefthalf.filled", Tile.blue),
        "paintpalette": ("paintpalette.fill", Tile.purple),
        "paintbrush": ("paintbrush.fill", Tile.purple),
        "desktopcomputer": ("desktopcomputer", Tile.indigo),
        "circle.righthalf.filled": ("circle.righthalf.filled", Tile.indigo),
        "textformat.size": ("textformat.size", Tile.blue),
        "bubble.left.and.bubble.right": ("bubble.left.and.bubble.right.fill", Tile.green),   // [theme-pages] Chat Bubbles
        "rectangle.compress.vertical": ("rectangle.compress.vertical", Tile.teal),
        "circle.dashed": ("circle.dashed", Tile.orange),
        "rectangle.topthird.inset.filled": ("rectangle.topthird.inset.filled", Tile.purple),
        "dock.rectangle": ("dock.rectangle", Tile.teal),
        "sidebar.left": ("sidebar.left", Tile.teal),   // [mac] Mac polish: Sidebar, the Mac's Tabs
        "app.badge": ("app.badge.fill", Tile.indigo),
        // Notifications, Device Access and its pages
        "bell.badge": ("bell.badge.fill", Tile.red),
        "hand.raised": ("hand.raised.fill", Tile.blue),
        "clock.arrow.circlepath": ("clock.arrow.circlepath", Tile.graphite),
        "person.crop.circle": ("person.crop.circle.fill", Tile.graphite),
        "location": ("location.fill", Tile.blue),
        "checklist": ("checklist", Tile.orange),
        "calendar": ("calendar", Tile.red),
        "alarm": ("alarm.fill", Tile.amber),
        "photo.on.rectangle": ("photo.fill.on.rectangle.fill", Tile.sky),
        "heart": ("heart.fill", Tile.pink),
        "figure.walk.motion": ("figure.walk.motion", Tile.green),
        "music.note": ("music.note", Tile.red),
        "square.and.pencil": ("square.and.pencil", Tile.blue),
        "phone": ("phone.fill", Tile.green),
        "envelope": ("envelope.fill", Tile.blue),
        "gift": ("gift.fill", Tile.rose),
        "mappin.and.ellipse": ("mappin.and.ellipse", Tile.red),
        "building.2": ("building.2.fill", Tile.brown),
        "house": ("house.fill", Tile.orange),
        "scope": ("scope", Tile.blue),
        "lock": ("lock.fill", Tile.graphite),
        "eye": ("eye.fill", Tile.sky),
        "calendar.badge.plus": ("calendar.badge.plus", Tile.red),
        "magnifyingglass": ("magnifyingglass", Tile.grey),
        "paperplane": ("paperplane.fill", Tile.blue),
        "figure.walk": ("figure.walk", Tile.orange),
        "bed.double": ("bed.double.fill", Tile.indigo),
        "figure.run": ("figure.run", Tile.green),
        "waveform.path.ecg": ("waveform.path.ecg", Tile.pink),
        "music.note.list": ("music.note.list", Tile.red),
        "playpause": ("playpause.fill", Tile.graphite),
        "message": ("message.fill", Tile.green),
        // [health-all-types] Device Access › Health's groups, in the Health app's colours
        "flame": ("flame.fill", Tile.orange),
        "figure": ("figure", Tile.purple),
        "drop": ("drop.fill", Tile.rose),
        "ear": ("ear.fill", Tile.blue),
        "brain.head.profile": ("brain.head.profile.fill", Tile.teal),
        "figure.stairs": ("figure.stairs", Tile.amber),
        "carrot": ("carrot.fill", Tile.green),
        "lungs": ("lungs.fill", Tile.sky),
        "list.bullet.clipboard": ("list.bullet.clipboard.fill", Tile.indigo),
        "waveform.path.ecg.rectangle": ("waveform.path.ecg.rectangle.fill", Tile.red),
        "plus.square": ("plus.square.fill", Tile.blue),
        // Chat
        "wrench.and.screwdriver": ("wrench.and.screwdriver.fill", Tile.grey),
        "clock": ("clock.fill", Tile.indigo),
        "paperclip": ("paperclip", Tile.blue),
        "arrow.counterclockwise": ("arrow.counterclockwise", Tile.purple),
        "lightbulb": ("lightbulb.fill", Tile.amber),
        "hand.wave": ("hand.wave.fill", Tile.green),
        "folder": ("folder.fill", Tile.blue),
        "face.smiling": ("face.smiling.inverse", Tile.pink),
        // Sounds & Haptics
        "speaker.wave.2": ("speaker.wave.2.fill", Tile.pink),
        "hand.tap": ("hand.tap.fill", Tile.rose),
        "gauge.with.dots.needle.67percent": ("gauge.with.dots.needle.67percent", Tile.indigo),
        // On Your Gateway, its section pages and Voice
        "cube": ("cube.fill", Tile.purple),
        "viewfinder": ("viewfinder", Tile.blue),   // [context-window] how much of the chat the model sees
        "arrow.turn.down.right": ("arrow.turn.down.right", Tile.orange),
        "cpu": ("cpu.fill", Tile.teal),
        "rectangle.3.group": ("rectangle.3.group.fill", Tile.indigo),
        "bubble.left.and.text.bubble.right": ("bubble.left.and.text.bubble.right.fill", Tile.green),
        "bubble.left": ("bubble.left.fill", Tile.green),
        "photo": ("photo.fill", Tile.sky),
        "terminal": ("terminal.fill", Tile.graphite),
        "doc.text": ("doc.text.fill", Tile.blue),
        "lock.shield": ("lock.shield.fill", Tile.indigo),
        "checkmark.shield": ("checkmark.shield.fill", Tile.green),
        "archivebox": ("archivebox.fill", Tile.brown),
        "globe": ("globe", Tile.sky),
        "network": ("network", Tile.blue),
        "brain": ("brain.fill", Tile.rose),
        "mic": ("mic.fill", Tile.orange),
        "waveform": ("waveform", Tile.pink),
        "gearshape.2": ("gearshape.2.fill", Tile.grey),
        "timer": ("timer", Tile.orange),
        "wrench": ("wrench.fill", Tile.grey),
        "doc.plaintext": ("doc.plaintext.fill", Tile.graphite),
        "person.crop.rectangle.stack": ("person.crop.rectangle.stack.fill", Tile.purple),
        "person.badge.key": ("person.badge.key.fill", Tile.teal),
        "folder.badge.gearshape": ("folder.fill.badge.gearshape", Tile.blue),
        // Accounts & Keys, Bots & Tools, the rest
        "bolt": ("bolt.fill", Tile.orange),
        "key": ("key.fill", Tile.graphite),
        "creditcard": ("creditcard.fill", Tile.green),
        "cloud": ("cloud.fill", Tile.sky),
        "sparkles": ("sparkles", Tile.purple),
        "point.3.connected.trianglepath.dotted": ("point.3.filled.connected.trianglepath.dotted", Tile.teal),
        "powerplug": ("powerplug.fill", Tile.teal),   // Capabilities › Connectors (Mac polish #90)
        "rectangle.split.3x1": ("rectangle.split.3x1.fill", Tile.amber),   // More's Kanban tile
        "square.and.arrow.up": ("square.and.arrow.up.fill", Tile.blue),
        "info.circle": ("info.circle.fill", Tile.grey),
        "puzzlepiece.extension": ("puzzlepiece.extension.fill", Tile.green),
        "arrow.triangle.2.circlepath": ("arrow.triangle.2.circlepath", Tile.teal),
        "arrow.down.circle": ("arrow.down.circle.fill", Tile.blue),
        "square.grid.2x2": ("square.grid.2x2.fill", Tile.blue),   // [cap-pages] More's Capabilities tile
        "hammer": ("hammer.fill", Tile.orange),   // [cap-pages] Capabilities › Tools
    ]

    /// The tile glyph's font: 15 pt semibold, made just small enough for a wide glyph (Connectors' dots) to
    /// keep 5 pt of the tile clear each side.
    /// [ui-sizing] `tile`: the tile's side as drawn; the glyph is 15 / 29 of it, so the two grow together (text size and
    /// UI Scale alike).
    static func tileFont(_ glyph: String, tile: CGFloat = 29) -> Font {
        let room: CGFloat = 29 - 10   // at the tile's base size; glyph and tile scale together
        let ratio = tile / 29
        guard let width = UIImage(systemName: glyph, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))?.size.width,
              width > room else { return Font.system(size: (15 * ratio * 2).rounded() / 2, weight: .semibold) }
        return Font.system(size: (15 * room / width * ratio * 10).rounded(.down) / 10, weight: .semibold)
    }

    /// A row symbol's tile; one not in `tiles` gets its filled glyph when there is one, on grey.
    static func tile(for symbol: String) -> (glyph: String, colour: UInt32) {
        if let tile = tiles[symbol] { return tile }
        let filled = symbol + ".fill"
        return (UIImage(systemName: filled) != nil ? filled : symbol, Tile.grey)
    }

    /// [mac] Stress test 2026-10-28 round 6: "face.smiling" draws as a filled disc in a dark window (the system swaps
    /// in its lit face; its ".inverse" is the outline there), so Message Reactions had the one filled glyph among the
    /// outlines in the Desktop Look dark. Every other symbol is its own name.
    static func outline(_ name: String, dark: Bool) -> String {
        dark && name == "face.smiling" ? "face.smiling.inverse" : name
    }

    /// [mac] Stress test 2026-10-28 round 6: the row glyph's font, made just small enough for a wide symbol to fit the
    /// icon column (Mixture of Agents' "rectangle.3.group" was about 4 pt wider and stuck out left of the column on the
    /// Model hub). Every other glyph keeps the row's size.
    /// [macpass-settings r3] Fitting only to the column left the wide, busy glyphs (Memory's brain, Advanced's two
    /// gears, Archiving's folder with a gear, Billing's card) about a quarter larger than the others on Hermes' list,
    /// so they read heavier. Every glyph now fits one box, at most 1.3 × the text size wide and 1.4 × tall (measured
    /// on that list: brain, gears and folder-gear 24–25 pt wide against 19–22 pt for the rest).
    static func fittedFont(_ name: String, column: CGFloat) -> Font {
        let size = MacIcon.rowSize
        guard let glyph = UIImage(systemName: name, withConfiguration: MacIcon.row)?.size, glyph.width > 0, glyph.height > 0 else {
            return MacIcon.rowFont
        }
        let scale = min(1, min(column, size * 1.3) / glyph.width, size * 1.4 / glyph.height)
        guard scale < 1 else { return MacIcon.rowFont }
        return Font.system(size: (size * scale * 10).rounded(.down) / 10, weight: .regular)
    }
}

/// A root row a search result can lead to (UX study 2026-10-21 #108): its id for the list to scroll to, and a tint
/// that fades in and out while it is the one revealed. [kanban-tab-one] Tabs marks its Kanban Tab row the same way.
struct RevealMark: ViewModifier {
    var on: Bool

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.hqTint.opacity(on ? 0.18 : 0))
                .padding(.horizontal, -10)
                .padding(.vertical, -6)
                .animation(HQMotion.swiftUI(.easeInOut(duration: HQMotion.move)), value: on)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    func revealRow(_ id: String, _ revealed: String?) -> some View {
        modifier(RevealMark(on: revealed == id)).id(id)
    }
}
