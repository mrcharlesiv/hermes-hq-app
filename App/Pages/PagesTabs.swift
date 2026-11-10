// Tabs 2–4 (docs/spec/1x-pages.md §1): Jobs, then Kanban or Artifacts, then More. Owns the pages' stores, the Kanban
// rule (§4.2: Kanban takes tab 3 while the gateway's Kanban API answers and a board holds a task; Artifacts then lives
// in More › Workspace), the More root, cold-launch tab restore (0–4, per account), the gateway events the pages use
// (`cron.changed`, `gateway.ready`) and the app's foreground/background for them. [taborder] "Tab n" is the tab's tag
// (`HQTab`): Settings › Tabs can put it anywhere in the bar. [customtabs] It can also hide Jobs or Kanban/Artifacts
// (their page is then a More row) and make a More page a tab of its own (the row then leaves More).

import UIKit

/// A More row another stream adds (Settings, Capabilities, Files…): `make` builds the page pushed on More's stack.
struct MoreRow {
    var id: String
    var title: String
    var symbol: String?
    var image: UIImage?
    var tile: UIColor
    var make: () -> UIViewController?
    /// A row drawn by its owner instead of tile + title + chevron (the gateway card, `S/ui-nav/more-account.tsx`).
    var card: (() -> UIContentConfiguration)? = nil
    /// [capabilities] A trailing value before the chevron (3x §8.3: "1 Issue" in red on Capabilities).
    var status: (@MainActor () -> MoreRowStatus?)? = nil
    /// [addon-reminder] A red count before the chevron, as iOS Settings marks Software Update (nil or 0: none), and
    /// what VoiceOver says after the title.
    var badge: (@MainActor () -> (count: Int, spoken: String)?)? = nil
    /// [mac-audit] A page this gateway's Hermes doesn't have (the Mac lists it greyed, `MorePages.row`).
    var dimmed = false
}

/// [capabilities] What a More row says at its trailing edge; `spoken` follows the title for VoiceOver.
struct MoreRowStatus {
    var text: String
    var isIssue: Bool
    var spoken: String
}

/// A More group, in `PagesTabs.sectionOrder` order.
struct MoreSection {
    var id: String
    var header: String?
    var rows: () -> [MoreRow]
}

@MainActor
final class PagesTabs {
    // MARK: More registry (other streams add rows without editing this file)

    /// `S/ui-nav/more-model.ts:12-17`: Settings alone, then Bots, Workspace, Insights, Integrations.
    /// [plugin-pages-more] Plugin Pages after Insights: places you go to, before Integrations' setup pages.
    static let sectionOrder = ["account", "settings", "bots", "workspace", "insights", "plugins", "integrations"]
    private static var registered: [String: MoreSection] = [:]
    private static var registryObservers: [UUID: () -> Void] = [:]

    /// Adds (or replaces, by id) a More section. Rows show only while their section returns them.
    static func registerMoreSection(_ section: MoreSection) {
        registered[section.id] = section
        for observer in registryObservers.values { observer() }
    }

    // [morepages] Rows appended to a section by its id (docs/spec/3x-morepages.md §19): several streams fill one
    // section without replacing each other's rows. `order` places a group among the section's rows: the rows a stream
    // registered with `registerMoreSection` (and Workspace's own Kanban / Artifacts row) count as 100.
    struct MoreRowGroup {
        var section: String
        var header: String?
        var order: Int
        var rows: () -> [MoreRow]
    }
    private static var appended: [String: MoreRowGroup] = [:]

    static func appendMoreRows(key: String, section: String, header: String?, order: Int, rows: @escaping () -> [MoreRow]) {
        appended[key] = MoreRowGroup(section: section, header: header, order: order, rows: rows)
        moreRowsChanged()
    }

    /// A row came or went (a page found its route missing on this gateway): More and the tab bar are read again.
    static func moreRowsChanged() {
        for observer in registryObservers.values { observer() }
    }

    /// `sections` with every appended group merged in, each section's rows in `order`.
    private static func merged(_ sections: [String: MoreSection]) -> [String: MoreSection] {
        var out = sections
        for id in Set(appended.values.map(\.section)) {
            let groups = appended.sorted { $0.key < $1.key }.map(\.value).filter { $0.section == id }
            let base = sections[id]
            let before = groups.filter { $0.order < 100 }.sorted { $0.order < $1.order }
            let after = groups.filter { $0.order >= 100 }.sorted { $0.order < $1.order }
            out[id] = MoreSection(id: id, header: base?.header ?? groups.compactMap(\.header).first) {
                before.flatMap { $0.rows() } + (base?.rows() ?? []) + after.flatMap { $0.rows() }
            }
        }
        return out
    }
    // [/morepages]

    static func unregisterMoreSection(_ id: String) {
        registered[id] = nil
        for observer in registryObservers.values { observer() }
    }

    // MARK: State

    private weak var host: UITabBarController?
    private(set) weak var services: PagesServices?
    let makeChat: (any ChatSessionModel) -> UIViewController
    let account: GatewayAccount?
    let scope: PagesScope?
    let jobsStore: JobsStore?
    private let client: (any GatewayClient)?
    private let directory: URL?
    private var madeKanban: KanbanStore?
    private var madeArtifacts: ArtifactsStore?
    /// Kanban's store, made on first use (its page or More row), not at launch (P-NAV-6).
    var kanbanStore: KanbanStore? {
        if let madeKanban { return madeKanban }
        guard let account, let client, let services else { return nil }
        let store = KanbanStore(api: KanbanAPI(client: client), account: account, directory: directory)
        store.readOnlyGateway = services.readOnlyGateway || Self.debugReadOnly
        madeKanban = store
        return store
    }
    /// Artifacts' store, made on first use; its index is read when its page draws (P-NAV-6).
    var artifactsStore: ArtifactsStore? {
        if let madeArtifacts { return madeArtifacts }
        guard let account, let client, let services, let scope else { return nil }
        let store = ArtifactsStore(client: client, account: account, directory: directory, scope: scope.effective(bots: services.bots))
        store.profilesProvider = { [weak services] in services?.bots.map(\.id) ?? [] }
        store.displayName = { [weak services] name in PagesNames.botName(name, bots: services?.bots ?? []) }
        madeArtifacts = store
        return store
    }

    /// `-HQPagesReadOnly YES` (DEBUG): every page write refused (the read-only gateway switch, P-JOB-11).
    private static var debugReadOnly: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "HQPagesReadOnly")
        #else
        return false
        #endif
    }
    private(set) var availability: KanbanAvailability = .absent
    private var pendingAvailability: KanbanAvailability?
    private var lastProbe: Date?
    private var eventsTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var registryObserver: UUID?
    /// The tab saved by the last run, read before this run's first selection can overwrite it.
    private var savedTab: Int?

    private var jobsNav: UINavigationController?
    private static let jobsIcon = TabIcons.jobs
    /// The Jobs list (its row marks the job on show in the right pane).
    var jobs: JobsViewController? { jobsNav?.viewControllers.first as? JobsViewController }
    private var tab3Nav: UINavigationController?
    /// The Kanban tab's board (its row marks the task on show in the right pane, on the Mac).
    var kanban: KanbanViewController? { tab3Nav?.viewControllers.first as? KanbanViewController }
    private var tab3Kind: KanbanAvailability?
    /// The gateway switcher under each page tab's title (with two or more saved gateways), as Bots and Sessions have:
    /// one header for every tab (verify round 1: Bots/Sessions alone had the subtitle, which shrinks the inline large
    /// title, so the header changed size between tabs).
    private var titleSwitchers: [ObjectIdentifier: GatewayTitleSwitcher] = [:]
    /// With one gateway: the link's "Offline" / "Reconnecting…" under each page tab's title, as on Bots and Sessions.
    private var linkSubtitles: [ObjectIdentifier: LinkSubtitle] = [:]
    private let appServices: any AppServices
    private var moreNav: UINavigationController?
    private(set) var more: MoreViewController?

    /// The tabs after Bots and Sessions (none without a signed-in gateway: previews and tests). Jobs is here even while
    /// hidden; MainTabController leaves out what Settings › Tabs hides.
    private(set) var tabs: [UIViewController] = []
    /// [customtabs] The More pages made tabs, by row id (kept while chosen, so a rebuild keeps the page as it was).
    private var pageNavs: [String: UINavigationController] = [:]
    /// The tabs were built once (the More rows they read exist only after `MorePages.attach`).
    private var built = false

    nonisolated static func availabilityKey(_ account: GatewayAccount) -> String { "pages.kanbanTab.\(account.id)" }
    nonisolated static func overrideKey(_ account: GatewayAccount) -> String { "pages.kanbanTab.override.\(account.id)" }
    nonisolated static func tabKey(_ account: GatewayAccount) -> String { "pages.tab.\(account.id)" }

    init(services: any AppServices, makeChat: @escaping (any ChatSessionModel) -> UIViewController, host: UITabBarController) {
        // Launch timing (`-HQLaunchTime`, P-NAV-6): what building the page tabs costs inside MainTabController.init.
        let started = ProcessInfo.processInfo.arguments.contains("-HQLaunchTime") ? Date() : nil
        defer {
            if let started { print(String(format: "[Launch] pagesTabs.init %.1f ms", Date().timeIntervalSince(started) * 1000)) }
        }
        self.host = host
        self.makeChat = makeChat
        appServices = services
        let pages = services as? PagesServices
        self.services = pages
        guard let pages, let account = pages.account, let client = pages.gateway else {
            account = nil; scope = nil; jobsStore = nil; self.client = nil; directory = nil
            return
        }
        self.account = account
        self.client = client
        savedTab = UserDefaults.standard.object(forKey: Self.tabKey(account)) as? Int
        let directory = PagesCache.directory(for: account)
        self.directory = directory
        let scope = PagesScope(account: account)
        self.scope = scope
        defer { BotArtifactsHook.attach(self) }   // [pins] Bot Info › Artifacts
        #if DEBUG
        // [kanban-tab-one] `-HQDebugForgetKanbanTip YES`: UI tests see the Kanban tip again, as a person who never chose
        // Kanban Tab (no override) and never saw it would.
        if UserDefaults.standard.bool(forKey: "HQDebugForgetKanbanTip") {
            for key in [Self.overrideKey(account), Self.kanbanTabTipKey(account)] { UserDefaults.standard.removeObject(forKey: key) }
        }
        #endif
        let current = scope.effective(bots: pages.bots)
        let jobs = JobsStore(client: client, account: account, directory: directory, scope: current)
        jobs.readOnlyGateway = pages.readOnlyGateway || Self.debugReadOnly
        jobsStore = jobs
        JobsStore.current = jobs   // [tiles] a tile's Updates
        availability = Self.decision(account)

        let jobsList = JobsViewController(store: jobs, scope: scope, services: pages, makeChat: makeChat)
        let jobsNav = PageChrome.navigation(jobsList)
        jobsNav.tabBarItem = UITabBarItem(title: "Jobs", image: Self.jobsIcon, tag: 2)
        jobsNav.tabBarItem.accessibilityIdentifier = "tab-jobs"
        self.jobsNav = jobsNav
        watchWorking()
        let more = MoreViewController(sections: { [weak self] in self?.visibleMoreSections() ?? [] })
        self.more = more
        let moreNav = PageChrome.navigation(more)
        moreNav.tabBarItem = UITabBarItem(title: "More", image: TabIcons.barSymbol("ellipsis.circle", outline: "ellipsis"), tag: 4)
        moreNav.tabBarItem.accessibilityIdentifier = "tab-more"
        self.moreNav = moreNav
        attachTitleSwitcher(jobsList, title: "Jobs")
        attachTitleSwitcher(more, title: "More")

        pages.onSignOutPages = { [weak self] in self?.signedOut() }
        registryObserver = UUID()
        if let id = registryObserver { Self.registryObservers[id] = { [weak self] in self?.moreChanged() } }
        watchEvents(client)
        watchLifecycle()
        MorePages.attach(self, services: services, client: client, account: account, makeChat: makeChat)   // [morepages]
        // [customtabs] After the More pages know this account: a More page chosen as a tab is built from its row.
        tabs = buildTabs()
        built = true
        Task { [weak self] in await self?.probe() }
    }

    /// The Jobs tab while jobs run (owner 2026-10-30: "some indicator on the Jobs page icon … that jobs are currently
    /// running"; a spinner, not a dot): the icon's clock turns (`TabIcons.jobsRunning`). Its accessibility value says
    /// how many.
    private func watchWorking() {
        guard let jobsStore, let item = jobsNav?.tabBarItem else { return }
        var count = withObservationTracking { jobsStore.workingCount } onChange: { [weak self] in
            Task { @MainActor in self?.watchWorking() }
        }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "HQDebugJobsRunning") { count = max(count, 1) }   // screenshots of the spinner
        #endif
        item.accessibilityValue = count > 0 ? "\(count) running" : nil
        let image = count > 0 ? TabIcons.jobsRunning : Self.jobsIcon
        guard item.image !== image else { return }
        AppLog.trace("pages", "jobs tab spinner \(count > 0 ? "on" : "off") (\(count) working)")
        item.image = image
    }

    isolated deinit {
        eventsTask?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let registryObserver { Self.registryObservers[registryObserver] = nil }
    }

    // MARK: Kanban rule (§4.2)

    static func decision(_ account: GatewayAccount) -> KanbanAvailability {
        let defaults = UserDefaults.standard
        let probed = defaults.string(forKey: availabilityKey(account)).flatMap(KanbanAvailability.init(rawValue:))
        switch defaults.string(forKey: overrideKey(account)) {
        // Verify round 3: a gateway whose Kanban API is gone can't fill the tab, whatever the override says (it showed
        // "Couldn't Load the Board" with no row left in Settings to turn it off). The override holds again once the
        // API answers.
        case "on": return probed == .absent ? .absent : .on
        case "off": return .absent
        default: return probed ?? .absent
        }
    }

    /// `GET /api/plugins/kanban/boards` (10 s): after sign-in/activation, and on foreground when the last probe is over
    /// 10 minutes old. A transport failure keeps the last decision.
    func probe() async {
        guard let account, let client = services?.gateway else { return }
        lastProbe = Date()
        guard let found = await KanbanAvailability.probe(client) else { return }
        let known = UserDefaults.standard.string(forKey: Self.availabilityKey(account)) != nil
        UserDefaults.standard.set(found.rawValue, forKey: Self.availabilityKey(account))
        let decided = Self.decision(account)
        guard decided != availability else { pendingAvailability = nil; return }
        AppLog.trace("pages", "tab 3 availability \(availability.rawValue) -> \(decided.rawValue) (probed \(found.rawValue))")
        // UX study #194: a tab 3 the user already knew as Artifacts turns into Kanban on its own (Automatic).
        if known, decided == .on, tab3Kind != nil, tab3Kind != .on, UserDefaults.standard.string(forKey: Self.overrideKey(account)) == nil {
            explainKanbanTab = true
        }
        // Never swap the tab under the user's finger: wait until they leave tab 3.
        if tab3OnShow {
            pendingAvailability = decided
            AppLog.trace("pages", "tab 3 swap deferred: tab 3 is on screen")
        } else {
            apply(decided)
        }
    }

    /// Kanban or Artifacts is the tab on show, wherever it sits ([taborder]).
    private var tab3OnShow: Bool { host?.selectedViewController?.tabBarItem.tag == HQTab.workspace.rawValue }

    /// Every tab the host holds, the hidden ones too ([customtabs]).
    private var hostTabs: [UIViewController]? { (host as? MainTabController)?.builtTabs ?? host?.viewControllers }

    /// Bots' and Sessions' stacks among `controllers`, which the host keeps when these tabs are built again.
    private static func listTabs(_ controllers: [UIViewController]) -> [UIViewController] {
        controllers.filter { $0.tabBarItem.tag == HQTab.bots.rawValue || $0.tabBarItem.tag == HQTab.sessions.rawValue }
    }

    /// Shows the tab tagged `tag` again after the bar was set, if it is still there.
    private static func reselect(_ tag: Int?, in host: UITabBarController) {
        guard let tag else { return }
        // [mac-sidebar] Any sidebar place, the ones the Mac's tab controller doesn't hold now too.
        if let host = host as? MainTabController {
            if let tab = host.placedTab(tagged: tag) { host.show(tab) }
            return
        }
        guard let index = host.viewControllers?.firstIndex(where: { $0.tabBarItem.tag == tag }) else { return }
        host.selectedIndex = index
    }

    /// The next swap to Kanban says where Artifacts went (UX study #194).
    private var explainKanbanTab = false

    nonisolated static func kanbanTabTipKey(_ account: GatewayAccount) -> String { "pages.kanbanTab.tip.\(account.id)" }

    private func apply(_ next: KanbanAvailability) {
        availability = next
        pendingAvailability = nil
        let explain = explainKanbanTab && next == .on
        explainKanbanTab = false
        guard let host, let current = hostTabs, current.count >= 2 else { return }
        let selected = host.selectedViewController?.tabBarItem.tag
        tabs = buildTabs()
        host.setViewControllers(Self.listTabs(current) + tabs, animated: false)
        Self.reselect(selected, in: host)
        more?.reload()
        dropStaleMorePages()
        if explain { explainKanbanTabOnce(in: host) }
    }

    /// Once per account, with In-App Tips on: Kanban took the tab, Artifacts is in More, and where to change it. A
    /// plain notice in the Undo pill's place (it holds while touched or VoiceOver-focused). [kanban-tab-one] It names
    /// the real path, Settings › Appearance › Tabs (on the Mac too), where the Kanban Tab picker's footer says the same.
    private func explainKanbanTabOnce(in host: UITabBarController) {
        guard let account, InAppTips.isOn, !UserDefaults.standard.bool(forKey: Self.kanbanTabTipKey(account)) else { return }
        UserDefaults.standard.set(true, forKey: Self.kanbanTabTipKey(account))
        let tip = SettingsWords.kanbanTookTab()
        UndoPill.show(label: tip.label, detail: tip.detail, duration: 8, in: host, showsUndo: false) {}
    }

    /// A page More opened whose row More no longer lists (its kind moved to tab 3) leaves More's stack: one page per
    /// store (verify round 2: the copy left on More stopped updating and lost its notices).
    private func dropStaleMorePages() {
        // Never from under the reader: on More itself the page stays (it takes the store back whenever it shows).
        guard let moreNav, moreNav.viewControllers.count > 1, host?.selectedViewController !== moreNav else { return }
        let rows = Set(moreSections().flatMap { $0.rows() }.map(\.id))
        guard let index = moreNav.viewControllers.firstIndex(where: { page in
            (page is KanbanViewController && !rows.contains("kanban"))
                || ((page as? ArtifactsViewController)?.pinnedOnly == false && !rows.contains("artifacts"))
                || (page is JobsViewController && !rows.contains("jobs"))   // [customtabs] the Jobs tab is back
        }), index > 0 else { return }
        moreNav.setViewControllers(Array(moreNav.viewControllers.prefix(index)), animated: false)
    }

    private func buildTabs() -> [UIViewController] {
        guard let jobsNav else { return [] }
        var out: [UIViewController] = [jobsNav]
        let kind: KanbanAvailability = availability == .on ? .on : .absent
        if !TabOrder.tabs.contains(.main(.workspace)) {
            // [customtabs] Hidden: its page is a More row (one page per store), made again if the tab comes back.
            tab3Nav = nil
            tab3Kind = nil
        } else if tab3Nav == nil || tab3Kind != kind {
            let root: UIViewController = kind == .on ? makeKanban() : makeArtifacts()
            attachTitleSwitcher(root, title: kind == .on ? "Kanban" : "Artifacts")
            let nav = PageChrome.navigation(root)
            nav.tabBarItem = kind == .on
                ? UITabBarItem(title: "Kanban", image: TabIcons.kanban, tag: 3)
                : UITabBarItem(title: "Artifacts", image: TabIcons.barSymbol("photo.on.rectangle"), tag: 3)
            nav.tabBarItem.accessibilityIdentifier = kind == .on ? "tab-kanban" : "tab-artifacts"
            tab3Nav = nav
            tab3Kind = kind
        }
        if let tab3Nav { out.append(tab3Nav) }
        out += pageTabs()
        if let moreNav, !visibleMoreSections().flatMap({ $0.rows() }).isEmpty { out.append(moreNav) }
        return out
    }

    #if targetEnvironment(macCatalyst)
    /// [mac] Settings' More row: on the Mac a window of its own, never a sidebar place (Mac polish #6: chosen as one, it
    /// added no row and opened the window each time the places were made again).
    static let settingsRowID = "settings"
    /// [mac-layout] More's sections whose pages are the Mac sidebar's Tools.
    static let toolSections: Set<String> = ["workspace", "insights"]
    /// Mac polish #33 (owner's call 2026-11-07): Marketplace is a Tool too, after those, and under it each page your
    /// bots' plugins add (More › Plugin Pages on the iPhone), only while some bot has one. ⌘K finds them as before.
    static let toolPages = ["marketplace"]
    /// The page tabs that are Tools (not places from Settings › Tabs), in More's order.
    private(set) var toolIDs: [String] = []
    func isTool(_ controller: UIViewController) -> Bool {
        toolIDs.contains { Self.placeTag($0) == controller.tabBarItem.tag }
    }
    /// A plugin page's place is no `TabChoice` (Settings › Tabs never lists it): a tag of its own, past theirs, the same
    /// for the app's run.
    private static var pluginTags: [String: Int] = [:]
    static let firstPluginTag = 1000
    #endif

    /// The tag of page `id`'s place: its `TabChoice`'s, or [mac] a plugin page's own.
    static func placeTag(_ id: String) -> Int {
        #if targetEnvironment(macCatalyst)
        if !TabChoice.pageIDs.contains(id) {
            if let tag = pluginTags[id] { return tag }
            let tag = firstPluginTag + pluginTags.count
            pluginTags[id] = tag
            return tag
        }
        #endif
        return TabChoice.page(id).tag
    }

    /// [customtabs] The More row id of the page tab 3 shows now (Kanban or Artifacts): Settings › Tabs offers it as
    /// that tab, not as a page of its own.
    var workspaceRowID: String { availability == .on ? "kanban" : "artifacts" }

    /// [customtabs] The More pages Settings › Tabs made tabs, in its order, while More has their row (a page this
    /// gateway lacks has none, and comes back as a tab when it does).
    private func pageTabs() -> [UIViewController] {
        var chosen = TabOrder.tabs.compactMap { tab -> String? in
            if case .page(let id) = tab, id != workspaceRowID { return id }
            return nil
        }
        #if targetEnvironment(macCatalyst)
        chosen.removeAll { $0 == Self.settingsRowID }   // Mac polish #6 (a choice saved before the fix)
        #endif
        var rows: [String: MoreRow] = [:]
        let sections = moreSections()
        for row in sections.flatMap({ $0.rows() }) where rows[row.id] == nil { rows[row.id] = row }
        #if targetEnvironment(macCatalyst)
        // [mac-layout] Owner 2026-11-03 (the layout study, "I'd like to see it all built"): More dissolves on the Mac.
        // The pages you work in (Workspace, Insights) are the sidebar's Tools, each a place as one added from More is.
        // Then Marketplace and the plugin pages (Mac polish #33).
        var tools: [String] = sections.filter { Self.toolSections.contains($0.id) }.flatMap { $0.rows() }
            .filter { $0.card == nil && TabChoice.pageIDs.contains($0.id) && !chosen.contains($0.id) }.map(\.id)
        tools += Self.toolPages.filter { rows[$0] != nil && !chosen.contains($0) }
        tools += sections.filter { $0.id == PluginPagesMore.section }.flatMap { $0.rows() }.map(\.id)
        toolIDs = tools
        chosen += tools
        #endif
        pageNavs = pageNavs.filter { chosen.contains($0.key) && rows[$0.key] != nil }
        return chosen.compactMap { id in
            if let nav = pageNavs[id] { return nav }
            guard let row = rows[id], row.card == nil, let page = row.make() else { return nil }
            #if targetEnvironment(macCatalyst)
            MacPlaceTitle.mark(page)   // [mac-ui-issues] its title leads the bar, as Sessions' and Jobs' do
            #endif
            let nav = PageChrome.navigation(page)
            nav.tabBarItem = UITabBarItem(title: row.title, image: Self.tabImage(row), tag: Self.placeTag(id))
            nav.tabBarItem.accessibilityIdentifier = "tab-page-\(id)"
            pageNavs[id] = nav
            return nav
        }
    }

    /// A More row's glyph at the bar's size: the outline symbol where there is one (the bar marks the shown tab).
    static func tabImage(_ row: MoreRow) -> UIImage? {
        if row.id == "kanban" { return TabIcons.kanban }
        guard let symbol = row.symbol else { return row.image }
        return TabIcons.barSymbol(outlineSymbol(symbol))
    }

    /// `symbol` without its fill, where SF Symbols has the outline (More's tiles use filled glyphs, tabs outlines).
    static func outlineSymbol(_ symbol: String) -> String {
        let outline = symbol.replacingOccurrences(of: ".fill", with: "")
        return outline != symbol && UIImage(systemName: outline) != nil ? outline : symbol
    }

    /// Settings › Tabs changed (MainTabController sets the bar from `tabs` next).
    func tabsChanged() {
        tabs = buildTabs()
        more?.reload()
        dropStaleMorePages()
    }

    /// `fromMore`: More's row made it, so on the Mac it is a More page (Title Case title, grouped grey), even as the
    /// right pane's first page ([mac] Stress test 2026-10-28 #23).
    func makeKanban(fromMore: Bool = false) -> UIViewController {
        guard let kanbanStore, let services else { return UIViewController() }
        let page = KanbanViewController(store: kanbanStore, services: services, makeChat: makeChat)
        page.openedFromMore = fromMore
        return page
    }

    /// [customtabs] Jobs as a More page (its tab hidden): its own list on the shared store.
    func makeJobs() -> UIViewController? {
        guard let jobsStore, let scope, let services else { return nil }
        let page = JobsViewController(store: jobsStore, scope: scope, services: services, makeChat: makeChat)
        page.navigationItem.largeTitleDisplayMode = .never
        return page
    }

    func makeArtifacts() -> UIViewController {
        guard let artifactsStore, let scope, let services else { return UIViewController() }
        return ArtifactsViewController(store: artifactsStore, scope: scope, services: services, makeChat: makeChat)
    }

    /// [pins] The Pinned page: the pinned artifacts alone, as cards (a More row, or a tab from Settings › Tabs).
    func makePinned() -> UIViewController {
        guard let artifactsStore, let scope, let services else { return UIViewController() }
        return ArtifactsViewController(store: artifactsStore, scope: scope, services: services, pinnedOnly: true, makeChat: makeChat)
    }

    // MARK: More

    /// Every More row, the ones that are tabs now too (More search, Settings › Tabs).
    func moreSections() -> [MoreSection] {
        var sections = Self.registered
        var workspace: [MoreRow] = []
        let shown = TabOrder.tabs
        // [customtabs] A hidden Jobs tab, and a hidden Kanban or Artifacts tab, are pages in More.
        if !shown.contains(.main(.jobs)), jobsStore != nil {
            workspace.append(MoreRow(id: "jobs", title: "Jobs", symbol: "calendar.badge.clock", image: nil,
                                     tile: UIColor(red: 1, green: 0x45 / 255, blue: 0x3A / 255, alpha: 1)) { [weak self] in self?.makeJobs() })
        }
        let workspaceHidden = !shown.contains(.main(.workspace))
        if availability == .unused || (workspaceHidden && availability == .on) {
            workspace.append(MoreRow(id: "kanban", title: "Kanban", symbol: nil, image: PagesTabIcons.kanban,
                                     tile: UIColor(red: 1, green: 0x9F / 255, blue: 0x0A / 255, alpha: 1)) { [weak self] in self?.makeKanban(fromMore: true) })
        }
        if availability == .on || workspaceHidden {
            workspace.append(MoreRow(id: "artifacts", title: "Artifacts", symbol: "photo.on.rectangle", image: nil,
                                     tile: UIColor(red: 1, green: 0x37 / 255, blue: 0x5F / 255, alpha: 1)) { [weak self] in self?.makeArtifacts() })
        }
        // [pins] Tester, 2026-10-31: "a dedicated widgets tab". Always a page in More; a tab when chosen.
        if artifactsStore != nil {
            workspace.append(MoreRow(id: "pinned", title: "Tiles", symbol: "rectangle.3.group.fill", image: nil,
                                     tile: UIColor(red: 1, green: 0x8A / 255, blue: 0, alpha: 1)) { [weak self] in self?.makePinned() })
        }
        if !workspace.isEmpty {
            let extra = sections["workspace"]
            sections["workspace"] = MoreSection(id: "workspace", header: "Workspace") { (extra?.rows() ?? []) + workspace }
        }
        return Self.merged(sections).values.sorted { a, b in   // [morepages] appended rows
            (Self.sectionOrder.firstIndex(of: a.id) ?? 99, a.id) < (Self.sectionOrder.firstIndex(of: b.id) ?? 99, b.id)
        }
    }

    /// [customtabs] More's list: every row but those that are tabs of their own now.
    private func visibleMoreSections() -> [MoreSection] {
        let asTabs = Set(pageNavs.keys)
        guard !asTabs.isEmpty else { return moreSections() }
        return moreSections().map { section in
            MoreSection(id: section.id, header: section.header) { section.rows().filter { !asTabs.contains($0.id) } }
        }
    }

    private func moreChanged() {
        guard built, let host, let current = hostTabs, current.count >= 2 else { more?.reload(); return }
        let next = buildTabs()
        more?.reload()   // after: a page that just became (or stopped being) a tab leaves (or joins) the list
        guard !next.elementsEqual(tabs, by: ===) else { return }
        let selected = host.selectedViewController?.tabBarItem.tag
        tabs = next
        host.setViewControllers(Self.listTabs(current) + tabs, animated: false)
        Self.reselect(selected, in: host)
    }

    // MARK: Selection (§1.3)

    /// Every tab change (MainTabController's `reportShownTab`): remember it for the next cold launch, and apply a
    /// Kanban decision that waited for the user to leave tab 3. [taborder] Saved as the tab's tag, which is the place
    /// older builds saved (the same number for every tab in the default order); a page tab's is 100 or more.
    func noteSelected(_ tag: Int?) {
        guard let account, let tag, savedTab == nil else { return }
        UserDefaults.standard.set(tag, forKey: Self.tabKey(account))
        if tag != HQTab.workspace.rawValue, let pending = pendingAvailability { apply(pending) }
    }

    private func attachTitleSwitcher(_ root: UIViewController, title: String) {
        guard let settings = appServices as? SettingsServices else { return }
        titleSwitchers = titleSwitchers.filter { $0.value.host != nil }
        linkSubtitles = linkSubtitles.filter { $0.value.host != nil }
        let switcher = GatewayTitleSwitcher(host: root, services: appServices, settings: settings, baseTitle: title)
        let link = LinkSubtitle(host: root, services: appServices)
        link.isSuppressed = { [weak switcher] in switcher?.isActive ?? false }
        switcher.onDeactivate = { [weak link] in link?.update() }
        titleSwitchers[ObjectIdentifier(root)] = switcher
        linkSubtitles[ObjectIdentifier(root)] = link
        link.update()
    }

    /// The link changed (Offline / Reconnecting… lead the switcher's subtitle, or stand alone with one gateway).
    func connectionChanged() {
        for switcher in titleSwitchers.values where switcher.isActive { switcher.apply() }
        for link in linkSubtitles.values { link.update() }
        // Verify round 3: More's gateway card says what the title says ("● Reconnecting…"), not what it said when More
        // last appeared (its card is built from the connection each time the row is configured).
        if more?.viewIfLoaded?.window != nil { more?.reload() }
    }

    /// The pages pushed on More over its root, when they are the Settings pages (account-independent: they read the
    /// current gateway when they show). A gateway switch made from More › Settings › Gateway carries them over to the
    /// new More stack, so the switch lands on the page it was made from (MEM gateway-switcher, build 111).
    var carriedMoreStack: [UIViewController] {
        guard let moreNav, moreNav.viewControllers.count > 1 else { return [] }
        let pushed = Array(moreNav.viewControllers.dropFirst())
        return pushed.first is SettingsRootController || pushed.first is GatewayPageController ? pushed : []
    }

    /// Puts `pages` (from the previous account's More) on top of this More's root.
    func adoptMoreStack(_ pages: [UIViewController]) {
        guard let moreNav, let root = moreNav.viewControllers.first, !pages.isEmpty else { return }
        moreNav.setViewControllers([root] + pages, animated: false)
        for page in pages {
            (page as? SettingsRootController)?.router.navigation = moreNav
            (page as? GatewayPageController)?.model.router.navigation = moreNav
        }
    }

    /// Whether `controller` is this account's More stack (its tab).
    func isMore(_ controller: UIViewController?) -> Bool { controller != nil && controller === moreNav }

    /// A gateway switch built these tabs: the selected tab stays where it was (MainTabController keeps it), so the tab
    /// saved for this account is not restored, and every later tab change is remembered again (verify round 1: the
    /// unread `savedTab` made `noteSelected` ignore every change after a switch, and held back a Kanban swap for good).
    func skipRestore() {
        savedTab = nil
    }

    /// Cold launch opens the tab last left (by its tag, wherever Settings › Tabs put it); tab 3 opens as it now is.
    func restoreSelection() {
        #if DEBUG
        if let host { PagesDebug.apply(self, host: host) }
        #endif
        guard let host, let saved = savedTab else { return }
        savedTab = nil
        Self.reselect(saved, in: host)
    }

    // MARK: Events and lifecycle

    private func watchEvents(_ client: any GatewayClient) {
        let events = client.events()
        eventsTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event.type {
                case "cron.changed":
                    self.jobsStore?.cronChanged()
                case "gateway.ready":
                    let changeEvents = event.payload["change_events"]?.bool ?? false
                    self.jobsStore?.gatewayReady(changeEvents: changeEvents)
                    self.madeKanban?.gatewayReady()
                    self.madeArtifacts?.onGatewayReady?()
                    MorePages.gatewayReady()   // [morepages] rows a gateway lacked are probed again
                    if self.lastProbe.map({ Date().timeIntervalSince($0) > 600 }) ?? true { await self.probe() }
                default:
                    break
                }
            }
        }
        // Connected before these tabs were made: that ready is the Jobs list's first read too (the tab's spinner
        // needs it with Jobs off screen).
        if let ready = client.latestReady { jobsStore?.gatewayReady(changeEvents: ready["change_events"]?.bool ?? false) }
    }

    /// Integration (Settings › Appearance › Tabs › Kanban Tab): the gateway's own Kanban answer before the override — "on", "unused" or
    /// "absent"; nil while it was never probed. The row shows unless it is "absent", so Off can be turned back.
    static func probedKanbanAvailability(_ account: GatewayAccount) -> String? {
        UserDefaults.standard.string(forKey: availabilityKey(account))
    }

    /// The override changed (Settings › Appearance › Tabs › Kanban Tab): decide again from what is known, without a probe.
    private func overrideChanged() {
        guard let account else { return }
        let decided = Self.decision(account)
        guard decided != availability else { pendingAvailability = nil; return }
        if tab3OnShow { pendingAvailability = decided } else { apply(decided) }
    }

    private func watchLifecycle() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: KanbanTabOverride.didChange, object: nil, queue: .main) { [weak self] note in
            let accountId = note.object as? String
            MainActor.assumeIsolated {
                guard let self, accountId == self.account?.id else { return }
                self.overrideChanged()
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.jobsStore?.appDidBecomeActive()
                self.madeKanban?.appDidBecomeActive()
                if self.lastProbe.map({ Date().timeIntervalSince($0) > 600 }) ?? true { Task { await self.probe() } }
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.jobsStore?.appDidEnterBackground()
                self.madeKanban?.appDidEnterBackground()
                self.madeArtifacts?.index.save()
                let task = BackgroundTime.begin("Hermes HQ pages cache")   // [diagnostics] §14: always ends
                DispatchQueue.global(qos: .utility).async {
                    PagesCache.flush()
                    DispatchQueue.main.async { task.end() }
                }
            }
        })
    }

    private func signedOut() {
        eventsTask?.cancel()
        jobsStore?.reset()
        madeKanban?.reset()
        madeArtifacts?.reset()
        TasksHub.signedOut()   // [tasks]
        if let account { Self.forgetDefaults(account) }
    }

    /// Sign-out: this account's page choices go with its caches (tab, scope, board, Kanban decision, Artifacts filter).
    /// The Kanban override (`pages.kanbanTab.override.<id>`) is a setting and stays.
    nonisolated static func forgetDefaults(_ account: GatewayAccount) {
        let defaults = UserDefaults.standard
        for key in [tabKey(account), availabilityKey(account), KanbanStore.slugKey(account), PagesScope.defaultsKey(account),
                    ArtifactsViewController.filterKey(account), MoreAvailability.key(account),   // [morepages]
                    TasksHub.scopeKey(account)] {   // [tasks]
            defaults.removeObject(forKey: key)
        }
    }
}

/// lucide `square-kanban` at the larger size the More list and the Kanban empty state use (the tab uses `TabIcons.kanban`).
enum PagesTabIcons {
    static let kanban: UIImage = {
        let size = CGSize(width: 28, height: 28)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let ctx = context.cgContext
            ctx.scaleBy(x: size.width / 24, y: size.height / 24)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 3, y: 3, width: 18, height: 18), cornerWidth: 2, cornerHeight: 2, transform: nil))
            for d in ["M8 7v7", "M12 7v4", "M16 7v9"] { ctx.addPath(SVGPathData.path(d)) }
            ctx.setLineWidth(1.9)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(UIColor.black.cgColor)
            ctx.strokePath()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }()
}
