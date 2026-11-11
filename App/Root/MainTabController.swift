// The signed-in root: the system's iOS 26 glass tab bar with Bots and Sessions, each in its own navigation stack, in the
// order Settings › Tabs sets ([taborder]); a tab hidden there stays built, out of the bar ([customtabs]).

import UIKit

final class MainTabController: UITabBarController, UITabBarControllerDelegate {
    /// [capabilities] the ServerIssues watch behind the More tab badge.
    private var issueObserver: NSObjectProtocol?
    private var reminderObserver: NSObjectProtocol?   // [addon-reminder]
    let services: any AppServices
    // [m2/settings] Rebuilt for a gateway switch (`installTabs`): every per-account tab owner is made again for the new
    // account, the tab controller (and a Settings sheet over it) stays.
    private(set) var botsViewController: BotsViewController
    private(set) var sessionsViewController: SessionsViewController
    let makeChat: (any ChatSessionModel) -> UIViewController
    // [m2/pages] Tabs 2–4 (Jobs, Kanban or Artifacts, More): App/Pages/PagesTabs.swift. Made again on a gateway switch.
    private(set) var pages: PagesTabs?
    /// [notifications] The last Back count (UI tests read it from the chat's back button; this is for unit checks).
    private(set) var backCountForTests = 0
    /// [restore] The cold launch's reopen of the last chat has run: from now on the screen on show is remembered
    /// (MainTabController+LaunchChat.swift). What it still waits for, if anything.
    var launchChatSettled = false
    var launchChatWatch: LaunchChatWatch?
    /// [desktoplook] The docked tab bar of the Desktop Look (App/Theme/DesktopTabBar.swift); not in the view tree with
    /// the look off. [mac] On the Mac it stands in for the system bar in the iOS look too, as a glass capsule.
    private(set) lazy var desktopTabBar = DesktopTabBar(host: self)

    /// [customtabs] Every tab built, shown or not: the bar shows the ones Settings › Tabs keeps, in its order.
    private(set) var builtTabs: [UIViewController] = []

    override func setViewControllers(_ viewControllers: [UIViewController]?, animated: Bool) {
        // [taborder] Every set goes in the owner's order (Settings › Tabs), whoever builds the list.
        builtTabs = viewControllers ?? []
        let shown = TabOrder.arranged(builtTabs, tabs: TabOrder.tabs) { $0.tabBarItem.tag }
        lendHiddenLists(shown: shown)
        #if targetEnvironment(macCatalyst)
        // [mac-layout] The sidebar's Tools (More's working pages) aren't in Settings › Tabs: they follow the places,
        // before More.
        let tools = builtTabs.filter { tool in pages?.isTool(tool) == true && !shown.contains { $0 === tool } }
        var placing = shown
        placing.insert(contentsOf: tools, at: placing.firstIndex { $0.tabBarItem.tag == HQTab.more.rawValue } ?? placing.count)
        placed = viewControllers == nil ? [] : placing
        super.setViewControllers(viewControllers == nil ? nil : slots(keeping: [selectedViewController]), animated: animated)
        #else
        super.setViewControllers(viewControllers == nil ? nil : shown, animated: animated)
        #endif
        if isViewLoaded { desktopTabBar.sync() }       // [desktoplook] the tabs changed (Kanban / Artifacts, a switch)
        #if targetEnvironment(macCatalyst)
        if split?.isViewLoaded == true { split?.macSidebar.rebuild() }   // [mac]
        #endif
    }

    /// [badges] The iPhone bar's count badges, over its glass (`fitBadgesInSelection`).
    private var badgeOverlay: TabBadgeOverlay?

    init(services: any AppServices, makeChat: @escaping (any ChatSessionModel) -> UIViewController) {
        self.services = services
        self.makeChat = makeChat
        botsViewController = BotsViewController(services: services, makeChat: makeChat)
        sessionsViewController = SessionsViewController(services: services, makeChat: makeChat)
        super.init(nibName: nil, bundle: nil)
        services.onConnectionChange = { [weak self] in self?.connectionDidChange() }
        #if DEBUG
        // [customtabs] `-HQDebugResetTabs YES`: UI tests start from the default tabs (not the argument's own key, which
        // would hold the tabs for the whole run).
        if UserDefaults.standard.bool(forKey: "HQDebugResetTabs") { UserDefaults.standard.removeObject(forKey: TabOrder.key) }
        #endif
        #if targetEnvironment(macCatalyst)
        // [mac] Mac polish #6: Settings saved as a sidebar place (Add to Sidebar offered it) is dropped: on the Mac it is
        // a window of its own. Before the tabs are made, so nothing listens for the change yet.
        let settingsPlace = TabChoice.page(PagesTabs.settingsRowID)
        if TabOrder.tabs.contains(settingsPlace) { TabOrder.tabs = TabOrder.tabs.filter { $0 != settingsPlace } }
        #endif
        installTabs(fresh: false)
        restoreLaunchChat()          // [restore] the last chat, over the list it was opened from
        // The full bar always (owner, 2026-10-07): shrunk on scroll it read as one odd circle.
        tabBarMinimizeBehavior = .never
        fitBadgesInSelection()
        delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(tabOrderChanged), name: TabOrder.didChange, object: nil)   // [taborder]
        #if targetEnvironment(macCatalyst)
        MacWindow.tabLabels(tabBar)   // [mac]
        #endif
    }

    /// The iPhone bar's count badges sit inside the selected tab's grey pill (owner 2026-10-30 on 492: "the red circle
    /// sits outside the background select shadow thing"): moved 3 pt in and 4 pt down from iOS's place they clear its
    /// curve, one or two digits. And they stay in front while the glass selection slides (owner on 500: "the red
    /// notification goes behind the icon for a second"): iOS fades its own badges under the moving glass and lets the
    /// magnified icon show through, so the app draws them (`TabBadgeOverlay`) over the bar and the bar's own go clear.
    /// The iPad's and Mac's bars are left alone.
    private func fitBadgesInSelection() {
        guard traitCollection.userInterfaceIdiom == .phone else { return }
        let overlay = TabBadgeOverlay(bar: tabBar)
        overlay.onChange = { [weak self] drawn in self?.showBarBadges(!drawn) }
        tabBar.addSubview(overlay)
        badgeOverlay = overlay
    }

    /// The bar's own badges, drawn or clear (the overlay draws them). Their values stay set either way: VoiceOver reads
    /// them there and the Desktop Look bar copies them.
    private func showBarBadges(_ shown: Bool) {
        let appearance = tabBar.standardAppearance.copy()
        for state in [appearance.stackedLayoutAppearance.normal, appearance.stackedLayoutAppearance.selected] {
            state.badgeBackgroundColor = shown ? nil : .clear
            state.badgeTextAttributes = shown ? [:] : [.foregroundColor: UIColor.clear]
            state.badgePositionAdjustment = TabBadgeOverlay.shift
        }
        tabBar.standardAppearance = appearance
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        badgeOverlay?.refresh()
    }

    /// The tabs for the signed-in account. `fresh`: a gateway switch — the list screens are made again (an open chat, a
    /// search, collapsed sections and anything else held for the old account go with them) and the selected tab stays.
    func installTabs(fresh: Bool) {
        let selected = fresh ? selectedIndex : 0
        #if targetEnvironment(macCatalyst)
        let selectedTag = fresh ? selectedViewController?.tabBarItem.tag : nil
        #endif
        // A switch made from More › Settings › Gateway lands back on that page (MEM gateway-switcher: "a switch must land
        // on the page it was made from"); the Settings pages read the new gateway when they show.
        let carried = fresh && (pages?.isMore(selectedViewController) ?? false) ? pages?.carriedMoreStack ?? [] : []
        if fresh {
            launchChatWatch = nil        // [restore] a reopened chat belonged to the old gateway
            botsViewController = BotsViewController(services: services, makeChat: makeChat)
            sessionsViewController = SessionsViewController(services: services, makeChat: makeChat)
        }
        // Set before `viewControllers`: assigning them loads this controller's view. A roster change also refreshes
        // the Sessions rows, which show their owner's name and head (`BotsViewController` holds `onBotsChange`).
        botsViewController.onDataChange = { [weak self] in
            self?.updateBadges()
            #if targetEnvironment(macCatalyst)
            if self?.split?.isViewLoaded == true { self?.split?.macSidebar.botsChanged() }   // [bots-rail] the rail's heads
            #endif
            self?.sessionsViewController.setNeedsReload(animated: false)
        }
        sessionsViewController.onDataChange = { [weak self] in
            self?.updateBadges()
            self?.botsViewController.setNeedsReload(animated: false)   // [chats-under] the chats under the bots
            #if targetEnvironment(macCatalyst)
            // [chats-under] The Mac's are under the sidebar's bot rows.
            if BotChatsPrefs.inUse, self?.split?.isViewLoaded == true { self?.split?.macSidebar.botsChanged() }
            #endif
        }
        #if targetEnvironment(macCatalyst)
        botsViewController.onRoomsChange = { [weak self] in
            if self?.split?.isViewLoaded == true { self?.split?.macSidebar.botsChanged() }   // [bots-rail] its rooms
        }
        // Mac polish #32: a bot's question or tip points at its sidebar row (the list is folded out of sight).
        botsViewController.sidebarRow = { [weak self] id in
            self?.split.flatMap { $0.isViewLoaded ? $0.macSidebar.row(forBot: id) : nil }
        }
        #endif
        let bots = Self.navigation(botsViewController)
        bots.tabBarItem = UITabBarItem(title: "Bots", image: TabIcons.bot, tag: 0)
        bots.tabBarItem.accessibilityIdentifier = "tab-bots"
        let sessions = Self.navigation(sessionsViewController)
        sessions.tabBarItem = UITabBarItem(title: "Sessions", image: TabIcons.barSymbol("bubble.left.and.bubble.right"), tag: 1)
        sessions.tabBarItem.accessibilityIdentifier = "tab-sessions"
        // [m2/pages] Jobs, Kanban/Artifacts and More follow Bots and Sessions; cold launch reopens the last tab. A gateway
        // switch makes them again for the new account (the old PagesTabs cancels its work when released).
        pages = PagesTabs(services: services, makeChat: makeChat, host: self)
        setViewControllers([bots, sessions] + (pages?.tabs ?? []), animated: false)
        if !fresh { pages?.restoreSelection() }
        if fresh {
            pages?.skipRestore()
            pages?.adoptMoreStack(carried)
            #if targetEnvironment(macCatalyst)
            // [mac-sidebar] The place by what it is: the tab controller's five children are not the sidebar's order.
            if let tag = selectedTag, let place = placedTab(tagged: tag) { show(place) } else { selectedIndex = min(selected, (viewControllers?.count ?? 1) - 1) }
            #else
            selectedIndex = min(selected, (viewControllers?.count ?? 1) - 1)
            #endif
            // Both lists listen from the start (as `viewDidLoad` does at launch).
            botsViewController.loadViewIfNeeded()
            sessionsViewController.loadViewIfNeeded()
            updateBadges()
            split?.tabsRebuilt()         // [m9/ipad] the right pane's chat belonged to the old gateway
        }
    }

    // MARK: The Mac's places ([mac-sidebar])

    #if targetEnvironment(macCatalyst)
    /// [mac-sidebar] Every tab the sidebar lists, in its order, More last. The Mac's sidebar holds as many as the owner
    /// adds (owner 2026-10-31), but a UITabBarController with more than five children hands the sixth on to a More stack
    /// of its own (`moreNavigationController`: a page opened there showed "‹ More" over the system's list, measured
    /// with nine rows). So the tab controller holds five of them at a time (`slots`) and the sidebar swaps the one
    /// clicked in; the others keep their stacks, out of the view tree, as a tab not on show is anyway.
    private var placed: [UIViewController] = []
    /// What UIKit shows before it adds its own More.
    static let slotLimit = 5

    /// The children for the tab controller: every place while they fit, else `wanted` first (the one about to show,
    /// the one on show), then the lists (Bots and Sessions, where chats open) and More, then the ones held now; in the
    /// sidebar's order.
    private func slots(keeping wanted: [UIViewController?]) -> [UIViewController] {
        guard placed.count > Self.slotLimit else { return placed }
        var keep: [UIViewController] = []
        func add(_ controller: UIViewController?) {
            guard let controller, keep.count < Self.slotLimit, placed.contains(where: { $0 === controller }),
                  !keep.contains(where: { $0 === controller }) else { return }
            keep.append(controller)
        }
        wanted.forEach(add)
        placed.filter { TabChoice(tag: $0.tabBarItem.tag)?.isList ?? false }.forEach(add)
        placed.filter { $0.tabBarItem.tag == HQTab.more.rawValue }.forEach(add)
        (super.viewControllers ?? []).forEach(add)
        placed.forEach(add)
        return placed.filter { controller in keep.contains { $0 === controller } }
    }

    /// Any tab given for selection is first made one of the tab controller's children (a stack from elsewhere, such as
    /// the right pane's origin going back, can be any place in the sidebar).
    override var selectedViewController: UIViewController? {
        get { super.selectedViewController }
        set {
            if let newValue { slotIndex(for: newValue) }
            super.selectedViewController = newValue
        }
    }
    #endif

    /// Every tab the bar (or the Mac's sidebar) lists, in its order, More last. On the iPhone and iPad the tab
    /// controller's own children.
    var placedTabs: [UIViewController] {
        #if targetEnvironment(macCatalyst)
        placed
        #else
        viewControllers ?? []
        #endif
    }

    /// The place `controller` has among the tab controller's children, for `selectedIndex`. [mac-sidebar] On the Mac a
    /// sidebar place the tab controller doesn't hold now is swapped in first.
    @discardableResult func slotIndex(for controller: UIViewController) -> Int? {
        if let index = viewControllers?.firstIndex(where: { $0 === controller }) { return index }
        #if targetEnvironment(macCatalyst)
        guard placed.contains(where: { $0 === controller }) else { return nil }
        let current = super.selectedViewController
        super.setViewControllers(slots(keeping: [controller, current]), animated: false)
        if let current, super.selectedViewController !== current, let back = viewControllers?.firstIndex(where: { $0 === current }) {
            super.selectedIndex = back
        }
        return viewControllers?.firstIndex(where: { $0 === controller })
        #else
        return nil
        #endif
    }

    /// Shows `controller`, one of `placedTabs` (set even when already shown, as `selectedIndex = n` was).
    func show(_ controller: UIViewController) {
        guard let index = slotIndex(for: controller) else { return }
        selectedIndex = index
    }

    /// A place picked on a bar of the app's own (the Mac's sidebar), as the system bar picks a tab: a second pick of the
    /// one on show goes back to its root.
    func pick(_ target: UIViewController, animated: Bool = true) {
        if selectedViewController === target {
            // [tabretap] At the root already: back to the top of the page.
            if !TabRetap.scrollToTop(target, animated: animated) {
                _ = (target as? UINavigationController)?.popToRootViewController(animated: animated)
            }
            return
        }
        guard delegate?.tabBarController?(self, shouldSelect: target) ?? true, let index = slotIndex(for: target) else { return }
        Haptics.play(.selection)
        selectedIndex = index
        delegate?.tabBarController?(self, didSelect: target)
    }

    /// Settings on show (⌘, and the Mac sidebar's Sidebar Settings…): its own tab when Settings › Tabs gave it one (More
    /// then has no Settings row to open), otherwise More's Settings row.
    func showSettings() {
        if let tab = placedTab(tagged: TabChoice.page("settings").tag) {
            show(tab)
            #if targetEnvironment(macCatalyst)
            split?.followSelectedTab()   // as a click on its sidebar row
            #endif
            _ = (tab as? UINavigationController)?.popToRootViewController(animated: false)
            return
        }
        guard let more = pages?.more, let stack = more.navigationController, let index = slotIndex(for: stack) else { return }
        selectedIndex = index
        stack.popToRootViewController(animated: false)
        more.loadViewIfNeeded()
        more.open(rowId: "settings")
    }

    /// The place tagged `tag` (a tab's `tabBarItem.tag`), if listed.
    func placedTab(tagged tag: Int) -> UIViewController? {
        placedTabs.first { $0.tabBarItem.tag == tag }
    }

    // MARK: Tabs by what they are ([taborder]: Settings › Tabs moves them, so a place says nothing)

    /// The tab's stack, wherever it sits; nil while it isn't in the bar.
    func controller(for tab: HQTab) -> UIViewController? {
        placedTab(tagged: tab.rawValue)
    }

    /// Where `tab` sits among the tab controller's children now (on the Mac swapped in first).
    func index(of tab: HQTab) -> Int? {
        controller(for: tab).flatMap(slotIndex(for:))
    }

    /// Shows `tab`, wherever it sits (set even when already shown, as `selectedIndex = n` was). [customtabs] A hidden
    /// Bots or Sessions shows the other list instead: what was going to open there opens on it.
    func select(_ tab: HQTab) {
        guard let index = index(of: tab) ?? tab.otherList.flatMap(index(of:)) else { return }
        selectedIndex = index
    }

    /// [customtabs] The stack a chat opened for `tab` lands on: the list's own, or while it is hidden the other list's.
    func listStack(_ tab: HQTab) -> UINavigationController? {
        (controller(for: tab) ?? tab.otherList.flatMap(controller(for:))) as? UINavigationController
    }

    /// [customtabs] A hidden Bots or Sessions stack hands what is pushed on it (a notification's chat, Siri, Talk, New
    /// Bot…) to the other list's stack, which shows; a chat left open on it closes as it hides.
    private func lendHiddenLists(shown: [UIViewController]) {
        for tab in [HQTab.bots, .sessions] {
            guard let stack = builtTabs.first(where: { $0.tabBarItem.tag == tab.rawValue }) as? PaneNavigationController else { continue }
            guard !shown.contains(where: { $0 === stack }) else { stack.standIn = nil; continue }
            if stack.standIn == nil, stack.viewControllers.count > 1 { stack.popToRootViewController(animated: false) }
            stack.standIn = tab.otherList.flatMap { other in shown.first { $0.tabBarItem.tag == other.rawValue } } as? UINavigationController
        }
    }

    /// The tab on show.
    var shownTab: HQTab? {
        selectedViewController.flatMap { HQTab(rawValue: $0.tabBarItem.tag) }
    }

    /// Settings › Tabs changed: the stacks again, in the new order and with the page tabs now chosen, the tab on show
    /// kept (a tab hidden while on show leaves its place to More, where its page now is).
    @objc private func tabOrderChanged() {
        guard !builtTabs.isEmpty else { return }
        let shown = selectedViewController
        let before = placedTabs
        let lists = builtTabs.filter { $0.tabBarItem.tag == HQTab.bots.rawValue || $0.tabBarItem.tag == HQTab.sessions.rawValue }
        pages?.tabsChanged()
        setViewControllers(lists + (pages?.tabs ?? []), animated: false)
        if let shown, let index = viewControllers?.firstIndex(of: shown) { selectedIndex = index; return }
        #if targetEnvironment(macCatalyst)
        // [mac] Mac polish (after #29): the Mac sidebar has no More row, so a place removed while on show (Remove from
        // Sidebar) leaves its spot to the place above it, else Bots, not to a More list nobody can reach or see marked.
        let now = placedTabs
        let above = before.prefix { $0 !== shown }.reversed().first { old in
            old.tabBarItem.tag != HQTab.more.rawValue && now.contains { $0 === old }
        }
        if let above { show(above) } else { selectedIndex = index(of: .bots) ?? 0 }
        #else
        selectedIndex = index(of: .more) ?? 0
        #endif
    }

    /// [tabretap] The system bar's second tap of the tab on show: at its root page, the page scrolls to the top (a
    /// pushed page still goes back to the root first, which the system does).
    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        if viewController === selectedViewController { TabRetap.scrollToTop(viewController) }
        return true
    }

    /// The Sessions list refreshes on its on-screen cadence only while its tab shows (spec 03 §7.7).
    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        playTabMotion(viewController.tabBarItem)
        reportShownTab()
    }

    /// [tabmotion] A tab tapped in the system bar (a second tap of the shown tab too): its icon moves (`TabMotion`).
    /// The app's own bars play theirs; their picks come through here with the system bar hidden.
    private func playTabMotion(_ item: UITabBarItem?) {
        guard !isTabBarHidden, DesktopTabBar.wanted == nil, let item, let index = tabBar.items?.firstIndex(of: item) else { return }
        for icon in TabMotion.barIcons(in: tabBar, at: index) { TabMotion.play(in: icon, source: item.image) }
    }

    #if DEBUG
    /// `-HQDebugTabMotion YES`: each tab's motion in turn, one every 1.5 s, in whichever bar shows (screen recordings).
    private func debugTabMotion(step: Int = 0) {
        guard UserDefaults.standard.bool(forKey: "HQDebugTabMotion"), let items = viewControllers?.map(\.tabBarItem) else { return }
        let index = step % max(items.count, 1)
        // `-HQDebugTabMotionSelect YES`: each tab is selected first, as a tap does (the bar's selection moving with it).
        if UserDefaults.standard.bool(forKey: "HQDebugTabMotionSelect") { selectedIndex = index }
        if DesktopTabBar.wanted == nil { playTabMotion(items[index]) } else { desktopTabBar.playMotion(at: index) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.debugTabMotion(step: step + 1) }
    }
    private var debugTabMotionStarted = false
    #endif

    override var selectedIndex: Int { didSet { reportShownTab() } }

    private func reportShownTab() {
        AppLog.note("screen", "tab \(selectedIndex): \(selectedViewController.map { ($0 as? UINavigationController)?.viewControllers.first ?? $0 }.map { String(describing: type(of: $0)) } ?? "none")")
        services.setSessionsListShown(shownTab == .sessions)
        PresenceHooks.askTabShown?(showsAskTab)   // [presence] UX study #135
        pages?.noteSelected(selectedViewController?.tabBarItem.tag)     // [m2/pages] tab restore + a deferred Kanban/Artifacts swap
        noteLaunchScreen()                   // [restore]
        if isViewLoaded, DesktopTabBar.wanted != nil { desktopTabBar.selectionChanged() }   // [desktoplook] [mac]
        if split != nil { paneSelectionChanged() }   // [m9/ipad] the list now on show marks the open chat's row
        #if targetEnvironment(macCatalyst)
        if split?.isViewLoaded == true {   // [mac]
            split?.macSidebar.selectionChanged()
            split?.listFoldMayHaveChanged()   // [bots-rail] Bots folds into the rail; another tab's list comes back
        }
        // [mac] Stress test 2026-10-28 #17: a tab's own list never passed through a push's `didShow`, so only pushed
        // pages lit the row under the pointer. The list on show takes the same hover now (installed once per list).
        if let root = (selectedViewController as? UINavigationController)?.viewControllers.first {
            DispatchQueue.main.async { PointerEffects.install(in: root) }
        }
        #endif
    }

    /// [presence] Sessions or More is on show: nothing there opens the browser plugin's list, so the presence centre
    /// listens for a bot's browser ask itself (UX study #135).
    var showsAskTab: Bool { shownTab == .sessions || pages?.isMore(selectedViewController) == true }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func navigation(_ root: UIViewController) -> UINavigationController {
        let navigation = PaneNavigationController(rootViewController: root)   // [m9/ipad] routes opens to the right pane
        navigation.navigationBar.prefersLargeTitles = true
        navigation.delegate = PushedPageTitles.shared
        return navigation
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.page
        desktopTabBar.sync()                 // [desktoplook] shows only with the look on (or on the Mac); follows Theme.didChange itself
        // Both lists listen from the start, so the tab badges are right before Sessions is first opened.
        botsViewController.loadViewIfNeeded()
        sessionsViewController.loadViewIfNeeded()
        updateBadges()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        updateBadges()
        reportShownTab()
    }

    #if DEBUG
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !debugTabMotionStarted else { return }
        debugTabMotionStarted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.debugTabMotion() }
    }
    #endif

    /// `services.onConnectionChange` lands here. The Bots list's skeleton, offline empty state and "Offline" /
    /// "Reconnecting…" subtitle follow it.
    func connectionDidChange() {
        botsViewController.setNeedsReload(animated: true)
        pages?.connectionChanged()
        #if targetEnvironment(macCatalyst)
        NotificationCenter.default.post(name: MacSidebar.connectionChanged, object: nil)   // [sidebar-tidy] the foot's gateway dot
        #endif
    }

    /// Tab badges count unread bots and unread listed sessions (never messages: `message_count` includes tool rows;
    /// hidden background runs excluded, spec 02 §9.3).
    func updateBadges() {
        var bots = BotList.unreadCount(services.bots)
        var sessions = SessionList.unreadCount(services.sessions)
        #if DEBUG
        // `-HQDebugTabBadges "<bots>,<sessions>"`: fixed counts for screenshots of the badges in the bars.
        if let forced = UserDefaults.standard.string(forKey: "HQDebugTabBadges")?.split(separator: ",").compactMap({ Int($0) }), forced.count == 2 {
            (bots, sessions) = (forced[0], forced[1])
        }
        #endif
        controller(for: .bots)?.tabBarItem.badgeValue = BadgeMath.backTitle(bots)
        controller(for: .sessions)?.tabBarItem.badgeValue = BadgeMath.backTitle(sessions)
        badgeOverlay?.refresh()
        setBackCount(bots + sessions)
        updateIssueBadge()
    }

    /// [capabilities] The More tab's badge is the number of connectors that need the owner (3x §8.4); its accessibility
    /// value says which. The app-icon badge is not touched (it means unread chats).
    func updateIssueBadge() {
        ServerIssues.shared.use(account: services.account?.id ?? "")
        AddOnReminder.shared.use(account: services.account?.id ?? "")
        if reminderObserver == nil {
            reminderObserver = NotificationCenter.default.addObserver(forName: AddOnReminder.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.showIssueCount() }
            }
        }
        if issueObserver == nil {
            // Only re-reads the count: switching the account from here again let two live roots on different
            // accounts hand ServerIssues back and forth, each switch posting the change the other answered, until
            // the stack ran out (UI hunt 2026-10-15, the Talk suite after a run that left several gateways saved).
            issueObserver = NotificationCenter.default.addObserver(forName: ServerIssues.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.showIssueCount() }
            }
        }
        showIssueCount()
    }

    private func showIssueCount() {
        let issues = ServerIssues.shared, reminder = AddOnReminder.shared
        // [addon-reminder] The add-on reminder counts on the tab that holds Settings: Settings' own tab when Settings ›
        // Tabs made it one, otherwise More (beside the connectors that need the owner).
        let settingsTab = placedTab(tagged: TabChoice.page("settings").tag)
        settingsTab?.tabBarItem.badgeValue = reminder.badged ? "1" : nil   // [addon-progress] none for "not out yet"
        settingsTab?.tabBarItem.accessibilityValue = reminder.spoken
        guard let more = placedTabs.first(where: { ($0 as? UINavigationController)?.viewControllers.first is MoreViewController }) else {
            badgeOverlay?.refresh(); return
        }
        #if targetEnvironment(macCatalyst)
        // [mac-ui-issues] The Mac's More list has no Settings row: the sidebar's gear carries the reminder's dot.
        split?.macSidebar.showSettingsDot(reminder.badged, spoken: reminder.spoken)
        let remind = false
        #else
        let remind = reminder.badged && settingsTab == nil
        #endif
        var count = issues.count + (remind ? 1 : 0)
        #if DEBUG
        if UserDefaults.standard.object(forKey: "HQDebugMoreBadge") != nil { count = UserDefaults.standard.integer(forKey: "HQDebugMoreBadge") }
        #endif
        more.tabBarItem.badgeValue = count > 0 ? String(count) : nil
        badgeOverlay?.refresh()
        more.tabBarItem.accessibilityValue = [remind ? reminder.spoken : nil, issues.summary].compactMap { $0 }.joined(separator: ", ").nilIfEmpty
    }

    /// [notifications] Back inside a chat says how many other chats have an unread reply ("‹ 3", Messages' count); with
    /// none it names the list as before.
    func setBackCount(_ count: Int) {
        let title = BadgeMath.backTitle(count)
        if botsViewController.navigationItem.backButtonTitle != title {
            botsViewController.navigationItem.backButtonTitle = title
            DesktopBack.backTitleChanged()                // the fitted Back under it shows the new count
        }
        sessionsViewController.backCount = title         // its Other Apps page names the list instead
        backCountForTests = count
    }
}

/// Tab glyphs that SF Symbols lacks (lucide `bot` and `square-kanban`), drawn as template images sized and weighted
/// like the SF Symbols beside them (owner: the Bots and Kanban icons read bigger and bolder than Sessions, Jobs and
/// More). The 24-unit lucide box is 1.35× a symbol's point size, which puts the outline at a symbol's height.
enum TabIcons {
    /// The Desktop Look bar's symbol point size at 100 % (regular weight, ≈1.4 pt line).
    static let pointSize: CGFloat = 17

    /// For the system tab bar, which draws its symbols ≈1.4× the Desktop Look's (measured on iOS 26/27: a 23 pt tall
    /// calendar, a ≈2.1 pt line); a plain image is not resized, so the glyph is drawn at that size. Solid, like the
    /// symbols beside it there (`barSymbol`); `redrawn` gives the app's own bars the outline.
    static let bot = Glyph(shape: .bot, pointSize: 23.5, line: 0.09, solid: true).made()
    static let kanban = Glyph(shape: .kanban, pointSize: 23.5, line: 0.09, solid: true).made()
    private static let botHead = "M4 10a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2Z"
    /// 16 of the 24 units, where the outline's square is 18: solid at 18 it carried half again the ink of the icons
    /// beside it (measured after 496), the most on the bar.
    private static let kanbanSquare = "M6 4h12a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2Z"

    /// [tabmotion] How a drawn glyph stands: at rest, or part way through its tap motion (`TabMotion`).
    struct Pose {
        /// Bots: the antenna's turn about its foot (radians, clockwise), how open the eyes are (1 open, 0 shut) and how
        /// far they look aside (glyph units, right +).
        var antenna: CGFloat = 0
        var eyes: CGFloat = 1
        var look: CGFloat = 0
        /// Kanban: each column's length, as a share of its own.
        var columns: [CGFloat] = [1, 1, 1]
        static let rest = Pose()
    }

    /// [tabmotion] A drawn glyph's recipe, kept with each image made from it, so its tap motion can draw the same
    /// glyph again in another pose. `solid`: the system bar's filled glyph (eyes and columns cut through it); else the
    /// app's own bars' outline.
    struct Glyph {
        enum Shape { case bot, kanban }
        let shape: Shape
        let pointSize: CGFloat
        let line: CGFloat
        let solid: Bool

        /// The glyph at rest, remembered as this recipe's (`glyph(of:)`).
        func made() -> UIImage {
            let image = image(.rest)
            glyphs.setObject(GlyphBox(self), forKey: image)
            return image
        }

        func image(_ pose: Pose) -> UIImage {
            let (moved, cutouts) = parts(pose)
            switch (shape, solid) {
            case (.bot, true): return TabIcons.glyph(pointSize: pointSize, line: line, body: botHead, paths: moved, cutouts: cutouts)
            case (.kanban, true): return TabIcons.glyph(pointSize: pointSize, line: line, body: kanbanSquare, paths: moved, cutouts: cutouts)
            case (.bot, false):
                return TabIcons.glyph(pointSize: pointSize, line: line, rect: nil, paths: [moved[0], SVGPathData.path(botHead)] + moved.dropFirst() + cutouts)
            case (.kanban, false):
                return TabIcons.glyph(pointSize: pointSize, line: line, rect: CGRect(x: 3, y: 3, width: 18, height: 18), paths: cutouts)
            }
        }

        /// The stroked lines and the lines cut through a solid glyph (drawn as lines in the outline), in the pose.
        private func parts(_ pose: Pose) -> (stroked: [CGPath], cut: [CGPath]) {
            func line(_ x: CGFloat, _ top: CGFloat, _ bottom: CGFloat) -> CGPath {
                let path = CGMutablePath()
                path.move(to: CGPoint(x: x, y: top))
                path.addLine(to: CGPoint(x: x, y: bottom))
                return path
            }
            switch shape {
            case .bot:
                // The antenna turns about its foot on the head; the eyes close towards their middles (a zero-length
                // round-capped line still draws a dot, but a hair of length keeps that certain).
                let turn = CGAffineTransform(translationX: 12, y: 8).rotated(by: pose.antenna).translatedBy(x: -12, y: -8)
                let open = max(pose.eyes, 0.04)
                return ([SVGPathData.path("M12 8V4H8", transform: turn), SVGPathData.path("M2 14h2"), SVGPathData.path("M20 14h2")],
                        [line(15 + pose.look, 14 - open, 14 + open), line(9 + pose.look, 14 - open, 14 + open)])
            case .kanban:
                let lengths: [CGFloat] = [7, 4, 9]
                return ([], [8, 12, 16].enumerated().map { index, x in
                    line(x, 7, 7 + lengths[index] * (pose.columns.indices.contains(index) ? pose.columns[index] : 1))
                })
            }
        }
    }

    private final class GlyphBox { let glyph: Glyph; init(_ glyph: Glyph) { self.glyph = glyph } }
    /// Each drawn glyph image → its recipe.
    private static let glyphs = NSMapTable<UIImage, GlyphBox>(keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)

    /// [tabmotion] The recipe `image` was drawn from, nil for anything else.
    static func glyph(of image: UIImage?) -> Glyph? { image.flatMap { glyphs.object(forKey: $0)?.glyph } }

    /// [tabmotion] Each tab symbol made here (the system bar's filled one, the app's bars' outline) → its name.
    private static let symbolNames = NSMapTable<UIImage, NSString>(keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)

    /// [tabmotion] The SF Symbol `image` is, when it is one of the tab symbols made here.
    static func symbolName(of image: UIImage?) -> String? { image.flatMap { symbolNames.object(forKey: $0) as String? } }

    /// The system tab bar's symbol for a tab: its filled variant, as SwiftUI's tab bar picks by itself (owner
    /// 2026-10-30 on 491, "icons look uneven": Bots, Sessions and Kanban were thin outlines and More three small dots
    /// beside the solid calendar of Jobs and photo of Artifacts). The app's own bars (Desktop Look, the Mac's sidebar)
    /// draw `outline` instead (`redrawn`), as before.
    static func barSymbol(_ name: String, outline: String? = nil) -> UIImage? {
        let filled = solid[name] ?? (name.hasSuffix(".fill") || UIImage(systemName: name + ".fill") == nil ? name : name + ".fill")
        let weight = bold.contains(filled) ? UIImage.SymbolConfiguration(weight: .bold) : nil
        guard let image = UIImage(systemName: filled, withConfiguration: weight) else { return nil }
        symbolNames.setObject(filled as NSString, forKey: image)
        let outlineName = outline ?? PagesTabs.outlineSymbol(name)
        if let plain = UIImage(systemName: outlineName), filled != (outline ?? name) || weight != nil {
            outlines.setObject(plain, forKey: image)
            symbolNames.setObject(outlineName as NSString, forKey: plain)
        }
        return image
    }

    /// Pages a tab can show (Settings › Tabs) whose symbol has no `.fill`: a solid relative, or for a glyph of lines
    /// only, its bold weight. At regular they carried a quarter to a third of the others' ink (measured after 496).
    private static let solid = ["point.3.connected.trianglepath.dotted": "point.3.filled.connected.trianglepath.dotted",
                                "gauge.with.dots.needle.67percent": "gauge.with.needle.fill"]
    private static let bold: Set<String> = ["arrow.triangle.branch", "sparkles", "point.3.filled.connected.trianglepath.dotted",
                                            "plus.forwardslash.minus"]   // Mac polish #65: Changes' +/−, lines only

    /// Each `barSymbol` → the outline the app's own bars draw.
    private static let outlines = NSMapTable<UIImage, UIImage>(keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)

    static func bot(pointSize: CGFloat, line: CGFloat = 0.085) -> UIImage {
        Glyph(shape: .bot, pointSize: pointSize, line: line, solid: false).made()
    }

    static func kanban(pointSize: CGFloat, line: CGFloat = 0.085) -> UIImage {
        Glyph(shape: .kanban, pointSize: pointSize, line: line, solid: false).made()
    }

    /// The Jobs tab while jobs run (owner 2026-10-30: a spinner, not a dot): `calendar.badge.clock` with its clock cut
    /// out and a three-quarter ring turning in its place, once a second for as long as any job runs. The system bar
    /// takes only an image, so this one is 120 frames a turn (as smooth as the screen draws, owner: "A TON smoother"
    /// than 485's 12); the app's own bars turn a real ring over `Spinner.still` (`TabIconView`). Not resized by the
    /// system bar, so drawn at the idle calendar's size there (`jobs`).
    static let jobsRunning = jobsRunning(pointSize: jobsBarSize, weight: .semibold, systemBar: true)

    /// The Jobs tab's calendar in the system bar, a plain image so it can be bigger and bolder than the bar draws
    /// symbols (owner 2026-10-30 on 492: "the Jobs icon still looks smaller than the rest"). Its white grid left it
    /// 30 % less ink than the solid icons beside it; at 25 pt semibold it has the photo's ink and Sessions' height.
    /// The app's own bars draw the plain symbol (`redrawn`).
    static let jobs: UIImage = {
        let canvas = jobsCanvas(pointSize: jobsBarSize, weight: .semibold, systemBar: true)
        let image = UIGraphicsImageRenderer(size: canvas.size).image { _ in
            canvas.base.withTintColor(.black).draw(at: canvas.origin)
        }.withRenderingMode(.alwaysTemplate)
        if let plain = UIImage(systemName: "calendar.badge.clock") {
            outlines.setObject(plain, forKey: image)
            symbolNames.setObject("calendar.badge.clock", forKey: plain)
        }
        return image
    }()
    private static let jobsBarSize: CGFloat = 25

    /// [tabmotion] The symbol `jobs` is drawn from, where it sits in that image, and the image's size.
    static var jobsArt: (symbol: UIImage, origin: CGPoint, size: CGSize) {
        let canvas = jobsCanvas(pointSize: jobsBarSize, weight: .semibold, systemBar: true)
        return (canvas.base, canvas.origin, canvas.size)
    }

    /// `calendar.badge.clock` at a size and weight, and where it sits in a plain image of `size`.
    private static func jobsCanvas(pointSize: CGFloat, weight: UIImage.SymbolWeight, systemBar: Bool) -> (base: UIImage, origin: CGPoint, size: CGSize) {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        let base = UIImage(systemName: "calendar.badge.clock", withConfiguration: config) ?? UIImage()
        // Room above it: a plain image is centred in its box, where the symbol sat on its baseline (≈2 pt lower). In
        // the system bar 2 pt puts its middle level with the icons beside it (at 0.2 × 25 pt it sat 1.5 pt low).
        let pad = (pointSize * (systemBar ? 0.08 : 0.2)).rounded()
        // The system bar centres a symbol by its alignment rect, which leaves out the clock's overhang on the right
        // (3.7 pt at 24 pt); a plain image is centred whole, so it sat 1.8 pt left of the idle icon. The same room on
        // the left puts it back. The app's own bars centre the whole symbol, so they need none.
        let lead = systemBar ? max(0, base.alignmentRectInsets.right - base.alignmentRectInsets.left) : 0
        return (base, CGPoint(x: lead, y: pad), CGSize(width: lead + base.size.width, height: base.size.height + pad))
    }

    /// The still part of the running icon and where its ring turns, in the still image's points.
    struct Spinner {
        let still: UIImage
        let centre: CGPoint
        let radius: CGFloat
        let line: CGFloat

        /// The ring's three-quarter arc, starting at `angle` (radians from the top), around `centre`.
        func arc(at angle: CGFloat, around centre: CGPoint) -> CGPath {
            let start = angle - .pi / 2
            return UIBezierPath(arcCenter: centre, radius: radius - line / 2, startAngle: start, endAngle: start + 1.5 * .pi,
                                clockwise: true).cgPath
        }
    }

    /// Each running icon made (animated or still) → its parts, so a bar can turn the ring itself.
    private static let spinners = NSMapTable<UIImage, SpinnerBox>(keyOptions: [.weakMemory, .objectPointerPersonality],
                                                                  valueOptions: .strongMemory)
    private final class SpinnerBox { let spinner: Spinner; init(_ spinner: Spinner) { self.spinner = spinner } }

    /// The parts of a running icon (`jobsRunning` or a redrawn still), nil for any other image.
    static func spinner(of image: UIImage?) -> Spinner? { image.flatMap { spinners.object(forKey: $0)?.spinner } }

    /// The calendar with its clock cut out, and where the ring goes. `systemBar`: drawn to sit where the system tab bar
    /// puts the idle symbol.
    static func jobsSpinner(pointSize: CGFloat, weight: UIImage.SymbolWeight = .regular, systemBar: Bool = false) -> Spinner {
        let (base, origin, size) = jobsCanvas(pointSize: pointSize, weight: weight, systemBar: systemBar)
        // The clock badge in the symbol's own drawing (measured at 120 pt: centre 77 % across, 68 % down, radius 19 %
        // of the height, cut 23 %).
        let side = base.size.height
        let centre = CGPoint(x: origin.x + base.size.width * 0.773, y: origin.y + side * 0.68)
        let radius = side * 0.19, cut = side * 0.23
        let still = UIGraphicsImageRenderer(size: size).image { context in
            base.withTintColor(.black).draw(at: origin)
            context.cgContext.setBlendMode(.clear)
            context.cgContext.fillEllipse(in: CGRect(x: centre.x - cut, y: centre.y - cut, width: cut * 2, height: cut * 2))
        }.withRenderingMode(.alwaysTemplate)
        let spinner = Spinner(still: still, centre: centre, radius: radius, line: max(1.5, radius * 0.42))
        spinners.setObject(SpinnerBox(spinner), forKey: still)
        return spinner
    }

    /// The running icon as one animated image (120 frames, one turn a second; one still frame with Reduce Motion).
    static func jobsRunning(pointSize: CGFloat, weight: UIImage.SymbolWeight = .regular, systemBar: Bool = false) -> UIImage {
        let spinner = jobsSpinner(pointSize: pointSize, weight: weight, systemBar: systemBar)
        let count = HQMotion.reduced ? 1 : 120
        let frames = (0..<count).map { step in
            UIGraphicsImageRenderer(size: spinner.still.size).image { context in
                spinner.still.draw(at: .zero)
                let ctx = context.cgContext
                ctx.addPath(spinner.arc(at: CGFloat(step) / CGFloat(count) * 2 * .pi, around: spinner.centre))
                ctx.setLineWidth(spinner.line)
                ctx.setLineCap(.round)
                ctx.setStrokeColor(UIColor.black.cgColor)
                ctx.strokePath()
            }.withRenderingMode(.alwaysTemplate)
        }
        // The frames are templates already: `withRenderingMode` on an animated image drops its scale (drawn 3× too big).
        let image = count > 1 ? UIImage.animatedImage(with: frames, duration: 1) ?? frames[0] : frames[0]
        spinners.setObject(SpinnerBox(spinner), forKey: image)
        return image
    }

    /// The same glyph redrawn at `pointSize` for the Desktop Look bar when `image` is one of these, nil for anything
    /// else (an SF Symbol, which takes the bar's symbol configuration instead). The running Jobs icon comes back still:
    /// `TabIconView` turns its ring.
    static func redrawn(_ image: UIImage?, pointSize: CGFloat) -> UIImage? {
        if let image, let outline = outlines.object(forKey: image) { return outline }
        if image === bot { return bot(pointSize: pointSize) }
        if image === kanban { return kanban(pointSize: pointSize) }
        if spinner(of: image) != nil { return jobsSpinner(pointSize: pointSize).still }
        return nil
    }

    private static func glyph(pointSize: CGFloat, line: CGFloat, rect: CGRect?, paths: [CGPath]) -> UIImage {
        let side = (pointSize * 1.35).rounded()
        let unit = side / 24
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let ctx = context.cgContext
            ctx.scaleBy(x: unit, y: unit)
            if let rect { ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil)) }
            for path in paths { ctx.addPath(path) }
            ctx.setLineWidth(pointSize * line / unit)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(UIColor.black.cgColor)
            ctx.strokePath()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    /// The solid glyph: `body` filled and outlined (so it is as big as the outline glyph), `paths` stroked, `cutouts`
    /// cleared through it at the line's width.
    private static func glyph(pointSize: CGFloat, line: CGFloat, body: String, paths: [CGPath], cutouts: [CGPath]) -> UIImage {
        let side = (pointSize * 1.35).rounded()
        let unit = side / 24
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let ctx = context.cgContext
            ctx.scaleBy(x: unit, y: unit)
            ctx.setLineWidth(pointSize * line / unit)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(UIColor.black.cgColor)
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.addPath(SVGPathData.path(body))
            ctx.drawPath(using: .fillStroke)
            for path in paths { ctx.addPath(path) }
            ctx.strokePath()
            ctx.setBlendMode(.clear)
            for path in cutouts { ctx.addPath(path) }
            ctx.strokePath()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }
}

/// A tab icon in one of the app's own bars (Desktop Look, the Mac's glass bar and sidebar). The running Jobs icon
/// (`TabIcons.spinner(of:)`) is its still image with a ring layer turned by Core Animation at the screen's rate (up to
/// 120 Hz), never frames: as long as the icon shows, the ring turns, and it is put back on when the app returns or the
/// view joins a window again (the system drops repeating animations then).
final class TabIconView: UIImageView {
    var icon: UIImage? { didSet { show() } }
    private var spinner: TabIcons.Spinner?
    private var ring: CAShapeLayer?
    private static let turnKey = "turn"

    init() {
        super.init(frame: .zero)
        // The ring's colour resolves against the theme and light/dark.
        registerForTraitChanges(UITraitCollection.systemTraitsAffectingColorAppearance + [ThemeGenerationTrait.self]) { (view: TabIconView, _) in
            view.colourRing()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(turn), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        colourRing()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        colourRing()
        turn()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let ring, let spinner, let still = image else { return }
        // contentMode .center: the still sits centred in the view.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.position = CGPoint(x: (bounds.width - still.size.width) / 2 + spinner.centre.x,
                                y: (bounds.height - still.size.height) / 2 + spinner.centre.y)
        CATransaction.commit()
    }

    private func show() {
        spinner = TabIcons.spinner(of: icon)
        guard let spinner else {
            ring?.removeFromSuperlayer()
            ring = nil
            image = icon?.withRenderingMode(.alwaysTemplate)
            return
        }
        image = spinner.still
        let ring = self.ring ?? CAShapeLayer()
        ring.fillColor = nil
        ring.lineCap = .round
        ring.lineWidth = spinner.line
        ring.path = spinner.arc(at: 0, around: .zero)
        ring.bounds = .zero
        if ring.superlayer == nil { layer.addSublayer(ring) }
        self.ring = ring
        colourRing()
        setNeedsLayout()
        turn()
    }

    private func colourRing() {
        ring?.strokeColor = tintColor.resolvedColor(with: traitCollection).cgColor
    }

    @objc private func turn() {
        guard let ring, window != nil, !HQMotion.reduced, ring.animation(forKey: Self.turnKey) == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = 2 * CGFloat.pi
        turn.duration = 1
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        turn.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        ring.add(turn, forKey: Self.turnKey)
    }
}
