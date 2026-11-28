#if targetEnvironment(macCatalyst)
import UIKit

/// Unified top navigation and workspace tab bar sitting across the translucent glass window shell
/// directly above the floating rounded content canvas card, aligned horizontally with the traffic lights.
@MainActor
final class MacWorkspaceBar: UIView {
    static let height: CGFloat = MacGlassShell.topBarHeight

    enum Destination: Hashable {
        case place(tag: Int)
        case bot(id: String)
        case session(profile: String, id: String)
    }

    struct TabItem: Equatable {
        var id: String
        var title: String
        var iconName: String?
        var customIcon: UIImage?
        var destination: Destination
        var isWorking: Bool = false
        var isUnread: Bool = false
        var closable: Bool = true
        var isActive: Bool = false
    }

    private weak var split: RootSplitController?
    private weak var tabs: MainTabController?

    // Left controls: Back, Forward, Quick Action, Active Section pill
    private let backButton = BarIconButton(symbol: "chevron.left", pointSize: 13, weight: .semibold, label: "Back", tip: "Back (⌘[)")
    private let forwardButton = BarIconButton(symbol: "chevron.right", pointSize: 13, weight: .semibold, label: "Forward", tip: "Forward (⌘])")
    private let listToggleButton = BarIconButton(symbol: "clock", pointSize: 14, weight: .regular, label: "Quick Switcher", tip: "Search or jump to… (⌘K)")
    private let placePill = ActivePlacePill()

    // Center scrollable workspace tab strip
    private let scroll = UIScrollView()
    private let strip = UIStackView()
    private var tabViews: [WorkspaceTabButton] = []
    /// The row's tabs as drawn, left to right (the place's own tab first while it shows): what the keys walk.
    private var shownItems: [TabItem] = []
    private var dividers: [UIView] = []

    // Trailing + button
    private let addButton = BarIconButton(symbol: "plus", pointSize: 14.5, weight: .medium, label: "New Chat", tip: "New Chat (⌘N)")

    // History state
    private var history: [Destination] = []
    private var historyIndex: Int = -1
    private var navigatingHistory = false

    // Persistent workspace tabs (browser-style: stay until explicitly closed, appended on the right, saved per gateway)
    private var tabList = WorkspaceTabList()
    private var loadedGatewayId: String?
    private var seededForDemo = false
    /// Prevents a tab currently being closed from getting re-recorded while the detail pane transitions.
    private var closingTabId: String?

    private var themeToken: NSObjectProtocol?
    private var attachToken: NSObjectProtocol?
    private var centerYOffset: CGFloat = 0
    private var didAlignTrafficLights = false

    init(split: RootSplitController, tabs: MainTabController) {
        self.split = split
        self.tabs = tabs
        super.init(frame: .zero)
        accessibilityIdentifier = "mac-workspace-bar"
        backgroundColor = .clear
        isOpaque = false

        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        scroll.alwaysBounceVertical = false
        scroll.backgroundColor = .clear
        scroll.delaysContentTouches = false

        strip.axis = .horizontal
        strip.alignment = .center
        strip.spacing = 2
        strip.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(strip)

        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            strip.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            strip.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            strip.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])

        for view in [backButton, forwardButton, listToggleButton, placePill, scroll, addButton] as [UIView] {
            addSubview(view)
        }

        backButton.addAction(UIAction { [weak self] _ in self?.goBack() }, for: .touchUpInside)
        forwardButton.addAction(UIAction { [weak self] _ in self?.goForward() }, for: .touchUpInside)
        listToggleButton.addAction(UIAction { [weak self] _ in self?.quickActionTapped() }, for: .touchUpInside)
        placePill.addAction(UIAction { [weak self] _ in self?.placePillTapped() }, for: .touchUpInside)
        addButton.addAction(UIAction { _ in
            UIApplication.shared.sendAction(KeyCommands.newChat, to: UIApplication.shared.delegate, from: nil, for: nil)
        }, for: .touchUpInside)

        // Window drag on empty background space of the bar.
        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleWindowDrag(_:)))
        drag.delegate = self
        drag.minimumNumberOfTouches = 1
        addGestureRecognizer(drag)

        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (bar: MacWorkspaceBar, _) in
            bar.recolor()
        }
        themeToken = NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recolor() }
        }
        attachToken = NotificationCenter.default.addObserver(forName: MacGlassShell.didAttachWindow, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.didAlignTrafficLights = false
                self?.alignToTrafficLights()
            }
        }

        updateHistoryButtons()
        recolor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        if let themeToken { NotificationCenter.default.removeObserver(themeToken) }
        if let attachToken { NotificationCenter.default.removeObserver(attachToken) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        alignToTrafficLights()
        sync()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !didAlignTrafficLights, window != nil, bounds.height > 0 { alignToTrafficLights() }
        let h = bounds.height
        let midY = max(13, min(h - 13, h / 2 + centerYOffset))
        let btnSize: CGFloat = 28
        let pillW: CGFloat = 34
        let pillH: CGFloat = 28

        var x: CGFloat = 4
        backButton.frame = CGRect(x: x, y: (midY - btnSize / 2).rounded(), width: btnSize, height: btnSize)
        x += btnSize + 2
        forwardButton.frame = CGRect(x: x, y: (midY - btnSize / 2).rounded(), width: btnSize, height: btnSize)
        x += btnSize + 12

        listToggleButton.frame = CGRect(x: x, y: (midY - btnSize / 2).rounded(), width: btnSize, height: btnSize)
        x += btnSize + 4
        placePill.frame = CGRect(x: x, y: (midY - pillH / 2).rounded(), width: pillW, height: pillH)
        x += pillW + 10

        let trailingPad: CGFloat = 4
        let addFrame = CGRect(x: bounds.width - trailingPad - btnSize, y: (midY - btnSize / 2).rounded(), width: btnSize, height: btnSize)
        addButton.frame = addFrame

        let scrollWidth = max(0, addFrame.minX - 8 - x)
        scroll.frame = CGRect(x: x, y: (midY - 16).rounded(), width: scrollWidth, height: 32)
    }

    private func alignToTrafficLights() {
        guard let window, bounds.height > 0 else { return }
        guard MacGlassShell.nsWindow(for: window) != nil else { return }
        didAlignTrafficLights = true
        let metrics = MacGlassShell.trafficLightsMetrics(in: window)
        let localMid = convert(CGPoint(x: 0, y: metrics.midY), from: window).y
        let target = localMid - bounds.height / 2
        if abs(target) < 12, abs(target - centerYOffset) > 0.25 {
            centerYOffset = target
            setNeedsLayout()
        }
    }

    // MARK: - Syncing State

    private var isDemoMode: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-HQDemoLists")
        #else
        false
        #endif
    }

    private var currentGatewayId: String? { tabs?.services.account?.id }

    /// Called when the user switches gateways (`RootSplitController.tabsRebuilt()`).
    func reloadForGateway() {
        history.removeAll()
        historyIndex = -1
        loadedGatewayId = nil
        seededForDemo = false
        tabList = WorkspaceTabList()
        sync()
    }

    func sync() {
        guard split != nil, tabs != nil else { return }
        loadPersistedTabsIfNeeded()
        syncQuickAction()
        syncActivePlacePill()
        seedDemoTabsIfNeeded()
        recordCurrentDestinationIfNeeded()
        rebuildTabStrip()
        scrollActiveTabIntoView()
        updateHistoryButtons()
        recolor()
    }

    private func loadPersistedTabsIfNeeded() {
        let key = WorkspaceTabList.storageKey(for: currentGatewayId)
        guard loadedGatewayId != key else { return }
        loadedGatewayId = key
        if isDemoMode {
            tabList = WorkspaceTabList()
        } else {
            tabList = WorkspaceTabList.load(gatewayId: currentGatewayId)
        }
    }

    private func persistTabs() {
        guard !isDemoMode else { return }
        tabList.save(gatewayId: currentGatewayId)
    }

    private func syncQuickAction() {
        guard let split else { return }
        if split.canToggleList {
            listToggleButton.setSymbol("sidebar.leading", pointSize: 14, weight: .regular)
            let hidden = split.isListCollapsedForUser
            listToggleButton.accessibilityLabel = hidden ? "Show List" : "Hide List"
            listToggleButton.toolTip = hidden ? "Show List (⇧⌘L)" : "Hide List (⇧⌘L)"
            listToggleButton.isSelectedState = hidden
        } else {
            listToggleButton.setSymbol("clock", pointSize: 14, weight: .regular)
            listToggleButton.accessibilityLabel = "Search or jump to…"
            listToggleButton.toolTip = "Search or jump to… (⌘K)"
            listToggleButton.isSelectedState = false
        }
    }

    private func syncActivePlacePill() {
        guard let tabs else { return }
        let selected = tabs.selectedViewController
        let item = selected?.tabBarItem
        let drawn = MacSidebar.rowIcon(item?.image, folded: false)
        placePill.configure(image: drawn.image, title: item?.title ?? "Hermes HQ")
    }

    /// Demo-only tab seeding (`-HQDemoLists`) so demo/screenshot builds show populated tabs immediately.
    /// Live runs never auto-seed: only sessions & bots explicitly opened by the user appear on the bar.
    private func seedDemoTabsIfNeeded() {
        guard isDemoMode, !seededForDemo, let tabs else { return }
        let sessions = tabs.services.sessions.filter {
            !$0.archived && $0.source != "cron" && $0.source != "tool" && SessionList.isVisible($0)
        }
        guard !sessions.isEmpty else { return }
        seededForDemo = true
        let sorted = sessions.sorted { a, b in
            let ar = a.isRunning ? 0 : (a.unread ? 1 : 2)
            let br = b.isRunning ? 0 : (b.unread ? 1 : 2)
            if ar != br { return ar < br }
            return (a.lastActive ?? .distantPast) > (b.lastActive ?? .distantPast)
        }
        for session in sorted.prefix(4) {
            tabList.open(WorkspaceTabRecord(kind: .session, profile: session.profile, id: session.id, title: SessionRowView.title(session)))
        }
    }

    private func destination(for record: WorkspaceTabRecord) -> Destination {
        switch record.kind {
        case .session: .session(profile: record.profile, id: record.id)
        case .bot: .bot(id: record.id)
        }
    }

    private func tabId(for dest: Destination) -> String? {
        switch dest {
        case .session(let profile, let id): "session:\(profile):\(id)"
        case .bot(let id): "bot:\(id)"
        case .place: nil
        }
    }

    private func currentDestination() -> Destination? {
        guard let split, let tabs else { return nil }
        if !split.detailIsEmpty, let first = split.detail.viewControllers.first {
            if let chat = first as? ChatViewController {
                if let live = chat.session as? LiveChatSession {
                    if live.menus.isBotChat { return .bot(id: live.profile) }
                    if let sid = live.storedSessionId ?? live.resolvedStoredId, !sid.isEmpty {
                        return .session(profile: live.profile, id: sid)
                    }
                    return .bot(id: live.profile)
                }
                let title = chat.session.title
                if let s = tabs.services.sessions.first(where: { SessionRowView.title($0) == title || $0.title == title }) {
                    return .session(profile: s.profile, id: s.id)
                }
                if let b = tabs.services.bots.first(where: { $0.name == title }) {
                    return .bot(id: b.id)
                }
            }
            if let title = first.title, !title.isEmpty {
                if let s = tabs.services.sessions.first(where: { SessionRowView.title($0) == title || $0.title == title }) {
                    return .session(profile: s.profile, id: s.id)
                }
                if let b = tabs.services.bots.first(where: { $0.name == title }) {
                    return .bot(id: b.id)
                }
            }
        }
        if let tag = tabs.selectedViewController?.tabBarItem.tag {
            return .place(tag: tag)
        }
        return nil
    }

    private func recordCurrentDestinationIfNeeded() {
        guard let dest = currentDestination(), let tabs else { return }
        var changed = false

        // Ensure an opened bot/session stays in the strip (appended on the right, no eviction cap).
        let currentTabId = tabId(for: dest)
        if currentTabId != closingTabId {
            closingTabId = nil
            switch dest {
            case .session(let profile, let id):
                let summary = tabs.services.sessions.first { $0.id == id }
                let chatTitle = (split?.detail.viewControllers.first as? ChatViewController)?.navigationItem.title
                let title = summary.map(SessionRowView.title) ?? chatTitle ?? "Chat"
                let record = WorkspaceTabRecord(kind: .session, profile: profile, id: id, title: title)
                if tabList.open(record) { changed = true }
            case .bot(let id):
                if let bot = tabs.services.bots.first(where: { $0.id == id }) {
                    let record = WorkspaceTabRecord(kind: .bot, profile: id, id: id, title: bot.name)
                    if tabList.open(record) { changed = true }
                }
            case .place:
                break
            }
        }

        // Refresh titles for already-open tabs when live session/bot names arrive or are renamed.
        for record in tabList.tabs {
            switch record.kind {
            case .session:
                if let s = tabs.services.sessions.first(where: { $0.id == record.id }) {
                    if tabList.updateTitle(tabId: record.tabId, title: SessionRowView.title(s)) { changed = true }
                }
            case .bot:
                if let b = tabs.services.bots.first(where: { $0.id == record.id }) {
                    if tabList.updateTitle(tabId: record.tabId, title: b.name) { changed = true }
                }
            }
        }

        if changed { persistTabs() }

        guard !navigatingHistory else { return }
        if historyIndex >= 0, historyIndex < history.count, history[historyIndex] == dest { return }
        if historyIndex + 1 < history.count {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(dest)
        if history.count > 40 { history.removeFirst() }
        historyIndex = history.count - 1
    }

    private func rebuildTabStrip() {
        guard let tabs else { return }
        let current = currentDestination()

        // First tab is always the active place home (e.g. "Sessions", "Bots", "Tasks", "Jobs").
        let selectedVC = tabs.selectedViewController
        let placeTag = selectedVC?.tabBarItem.tag ?? HQTab.sessions.rawValue
        let placeTitle = selectedVC?.tabBarItem.title ?? "Sessions"
        let placeIcon = MacSidebar.rowIcon(selectedVC?.tabBarItem.image, folded: false).image
        let placeActive: Bool = {
            if case .place(let t) = current, t == placeTag { return true }
            return current == nil
        }()

        let showPlaceTab = !(placeTag == HQTab.bots.rawValue && MacSidebar.botsInSidebar && !placeActive)
        var displayItems: [TabItem] = []
        if showPlaceTab {
            displayItems.append(TabItem(
                id: "place:\(placeTag)",
                title: placeTitle,
                iconName: nil,
                customIcon: placeIcon,
                destination: .place(tag: placeTag),
                isWorking: false,
                isUnread: false,
                closable: false,
                isActive: placeActive
            ))
        }

        for record in tabList.tabs {
            let dest = destination(for: record)
            var title = record.title
            var working = false
            var unread = false
            var iconName: String? = "bubble.left"
            var customIcon: UIImage?
            switch record.kind {
            case .session:
                if let s = tabs.services.sessions.first(where: { $0.id == record.id }) {
                    title = SessionRowView.title(s)
                    working = s.isRunning || s.status == .working
                    unread = s.unread
                }
                iconName = working ? nil : "bubble.left"
            case .bot:
                if let b = tabs.services.bots.first(where: { $0.id == record.id }) {
                    title = b.name
                    working = b.isWorking
                    unread = b.unread
                }
                iconName = nil
                customIcon = TabIcons.bot(pointSize: 13.5, line: 0.08)
            }
            displayItems.append(TabItem(
                id: record.tabId,
                title: title,
                iconName: iconName,
                customIcon: customIcon,
                destination: dest,
                isWorking: working,
                isUnread: unread,
                closable: true,
                isActive: current == dest
            ))
        }

        shownItems = displayItems

        // Rebuild arranged subviews cleanly.
        strip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tabViews.removeAll()
        dividers.removeAll()

        for (idx, item) in displayItems.enumerated() {
            if idx > 0 {
                let prevActive = displayItems[idx - 1].isActive
                let div = UIView()
                div.translatesAutoresizingMaskIntoConstraints = false
                div.widthAnchor.constraint(equalToConstant: HQShape.pixel(traitCollection.displayScale)).isActive = true
                div.heightAnchor.constraint(equalToConstant: 14).isActive = true
                div.alpha = (prevActive || item.isActive) ? 0 : 1
                dividers.append(div)
                strip.addArrangedSubview(div)
            }
            let btn = WorkspaceTabButton(item: item)
            btn.onSelect = { [weak self] in self?.activate(item.destination) }
            btn.onClose = item.closable ? { [weak self] in self?.closeTab(id: item.id) } : nil
            btn.contextMenuProvider = item.closable ? { [weak self] in self?.contextMenu(forTabId: item.id) } : nil
            tabViews.append(btn)
            strip.addArrangedSubview(btn)
        }
    }

    private func scrollActiveTabIntoView() {
        guard let active = tabViews.first(where: { $0.item.isActive }) else { return }
        DispatchQueue.main.async { [weak self, weak active] in
            guard let self, let active, active.superview != nil else { return }
            self.scroll.layoutIfNeeded()
            let rect = active.convert(active.bounds, to: self.scroll).insetBy(dx: -12, dy: 0)
            self.scroll.scrollRectToVisible(rect, animated: !HQMotion.reduced)
        }
    }

    private func contextMenu(forTabId id: String) -> UIMenu? {
        guard let idx = tabList.tabs.firstIndex(where: { $0.tabId == id }) else { return nil }
        let hasOthers = tabList.tabs.count > 1
        let hasRight = idx + 1 < tabList.tabs.count
        var items: [UIMenuElement] = [
            UIAction(title: "Close Tab", image: UIImage(systemName: "xmark")) { [weak self] _ in
                self?.closeTab(id: id)
            }
        ]
        var groupActions: [UIAction] = []
        if hasOthers {
            groupActions.append(UIAction(title: "Close Other Tabs") { [weak self] _ in
                self?.closeOtherTabs(keeping: id)
            })
        }
        if hasRight {
            groupActions.append(UIAction(title: "Close Tabs to the Right") { [weak self] _ in
                self?.closeTabsToRight(of: id)
            })
        }
        if !groupActions.isEmpty {
            items.append(UIMenu(options: .displayInline, children: groupActions))
        }
        if hasOthers {
            items.append(UIMenu(options: .displayInline, children: [
                UIAction(title: "Close All Tabs", attributes: .destructive) { [weak self] _ in
                    self?.closeAllTabs()
                }
            ]))
        }
        return UIMenu(children: items)
    }

    private func activate(_ destination: Destination) {
        guard let split, let tabs else { return }
        switch destination {
        case .place(let tag):
            if let controller = tabs.placedTab(tagged: tag) {
                split.switchPlace(to: controller) { tabs.pick(controller) }
                if !split.detailIsEmpty { split.closeDetail(animated: true) }
            }
        case .bot(let id):
            tabs.botsViewController.open(id)
        case .session(let profile, let id):
            let session = tabs.services.sessions.first(where: { $0.id == id }) ?? {
                let savedTitle = tabList.tabs.first(where: { $0.tabId == "session:\(profile):\(id)" })?.title ?? "Chat"
                return SessionSummary(id: id, profile: profile, title: savedTitle, preview: nil, lastActive: nil,
                                      source: "desktop", unread: false, isRunning: false)
            }()
            if let sessionsTab = tabs.controller(for: .sessions), tabs.selectedViewController !== sessionsTab {
                split.switchPlace(to: sessionsTab) { tabs.pick(sessionsTab) }
            }
            tabs.sessionsViewController.openChat(session)
        }
        sync()
    }

    /// [mac-session-tabs] Owner 2026-11-27 ("is this tabbing between the tabs at the very top or the chats in the bot
    /// chat header? … that doesn't make any sense"): Window › Show Next Tab and Show Previous Tab (⇧⌘] ⇧⌘[, and ⌃Tab
    /// ⌃⇧Tab as in Safari) walk this row, the window's tabs, not the bot's chats under a chat's bar. On while there is
    /// another tab to go to.
    var canCycleTabs: Bool { cycleTarget(step: 1) != nil }

    private func cycleTarget(step: Int) -> TabItem? {
        WorkspaceTabList.cycledIndex(count: shownItems.count, active: shownItems.firstIndex(where: \.isActive), step: step)
            .map { shownItems[$0] }
    }

    /// The next (`step` 1) or previous (-1) tab of the row, wrapping round at either end. False when it has no other.
    @discardableResult
    func cycleTabs(step: Int) -> Bool {
        guard let target = cycleTarget(step: step) else { return false }
        activate(target.destination)
        return true
    }

    /// Closes the currently active workspace tab (wired to ⌘W). Returns true if a workspace tab was closed.
    @discardableResult
    func closeActiveTab() -> Bool {
        guard let dest = currentDestination(), let id = tabId(for: dest),
              tabList.tabs.contains(where: { $0.tabId == id }) else {
            return false
        }
        closeTab(id: id)
        return true
    }

    private func closeTab(id: String) {
        let activeId = currentDestination().flatMap(tabId(for:))
        let result = tabList.close(tabId: id, activeTabId: activeId)
        guard result.removed else { return }
        persistTabs()
        closingTabId = id
        if activeId == id {
            if let next = result.nextActive {
                activate(destination(for: next))
                return
            }
            split?.closeDetail(animated: true)
        }
        rebuildTabStrip()
        recolor()
    }

    private func closeOtherTabs(keeping id: String) {
        let activeId = currentDestination().flatMap(tabId(for:))
        guard tabList.closeOthers(keeping: id) else { return }
        persistTabs()
        if activeId != id, let kept = tabList.tabs.first(where: { $0.tabId == id }) {
            activate(destination(for: kept))
            return
        }
        rebuildTabStrip()
        recolor()
    }

    private func closeTabsToRight(of id: String) {
        let activeId = currentDestination().flatMap(tabId(for:))
        guard tabList.closeToRight(of: id) else { return }
        persistTabs()
        if let activeId, !tabList.tabs.contains(where: { $0.tabId == activeId }),
           let anchor = tabList.tabs.first(where: { $0.tabId == id }) {
            activate(destination(for: anchor))
            return
        }
        rebuildTabStrip()
        recolor()
    }

    private func closeAllTabs() {
        let hadActive = currentDestination().flatMap(tabId(for:)).map { id in
            tabList.tabs.contains { $0.tabId == id }
        } ?? false
        guard tabList.closeAll() else { return }
        persistTabs()
        if hadActive {
            split?.closeDetail(animated: true)
        }
        rebuildTabStrip()
        recolor()
    }

    // MARK: - Actions

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex >= 0 && historyIndex + 1 < history.count }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        navigatingHistory = true
        activate(history[historyIndex])
        navigatingHistory = false
        updateHistoryButtons()
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        navigatingHistory = true
        activate(history[historyIndex])
        navigatingHistory = false
        updateHistoryButtons()
    }

    private func updateHistoryButtons() {
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        backButton.alpha = canGoBack ? 1 : 0.34
        forwardButton.alpha = canGoForward ? 1 : 0.34
    }

    private func quickActionTapped() {
        guard let split else { return }
        if split.canToggleList {
            split.toggleList()
            syncQuickAction()
        } else {
            UIApplication.shared.sendAction(KeyCommands.openQuickly, to: UIApplication.shared.delegate, from: nil, for: nil)
        }
    }

    private func placePillTapped() {
        guard let split else { return }
        if split.canToggleList {
            split.toggleList()
            syncQuickAction()
        } else if !split.detailIsEmpty {
            split.closeDetail(animated: true)
        }
    }

    @objc private func handleWindowDrag(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began {
            MacGlassShell.beginWindowDrag(for: window)
        }
    }

    func recolor() {
        let dark = traitCollection.userInterfaceStyle == .dark
        let divColor = dark ? UIColor(white: 1, alpha: 0.14) : UIColor(white: 0, alpha: 0.11)
        for d in dividers { d.backgroundColor = divColor }
        backButton.recolor()
        forwardButton.recolor()
        listToggleButton.recolor()
        placePill.recolor()
        addButton.recolor()
        tabViews.forEach { $0.recolor() }
    }
}

extension MacWorkspaceBar: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var v = touch.view
        while let current = v, current !== self {
            if current is UIControl { return false }
            v = current.superview
        }
        return true
    }
}

// MARK: - Sub-controls

@MainActor
private final class BarIconButton: UIControl {
    private let iconView = UIImageView()
    private let pill = UIView()
    private var hovered = false
    private var symbolName: String
    private var pointSize: CGFloat
    private var weight: UIImage.SymbolWeight
    var isSelectedState = false { didSet { if isSelectedState != oldValue { recolor() } } }

    init(symbol: String, pointSize: CGFloat, weight: UIImage.SymbolWeight, label: String, tip: String) {
        self.symbolName = symbol
        self.pointSize = pointSize
        self.weight = weight
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = label
        toolTip = tip
        MacTitleBarClick.markInteractive(self)
        MacHover.drawsOwnHover(self)

        pill.isUserInteractionEnabled = false
        pill.layer.cornerRadius = 8
        pill.layer.cornerCurve = .continuous
        addSubview(pill)

        iconView.isUserInteractionEnabled = false
        iconView.contentMode = .center
        addSubview(iconView)

        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
        applySymbol()
        recolor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setSymbol(_ name: String, pointSize: CGFloat, weight: UIImage.SymbolWeight) {
        guard name != symbolName || pointSize != self.pointSize || weight != self.weight else { return }
        symbolName = name
        self.pointSize = pointSize
        self.weight = weight
        applySymbol()
    }

    private func applySymbol() {
        iconView.image = UIImage(systemName: symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        pill.frame = bounds
        iconView.frame = bounds
    }

    override var isHighlighted: Bool { didSet { recolor() } }

    @objc private func hover(_ g: UIHoverGestureRecognizer) {
        hovered = g.state == .began || g.state == .changed
        recolor()
    }

    func recolor() {
        let dark = traitCollection.userInterfaceStyle == .dark
        iconView.tintColor = (hovered || isSelectedState) ? HQPalette.label : HQPalette.label.withAlphaComponent(dark ? 0.68 : 0.58)
        if isHighlighted {
            pill.backgroundColor = dark ? UIColor(white: 1, alpha: 0.14) : UIColor(white: 0, alpha: 0.09)
        } else if isSelectedState {
            pill.backgroundColor = dark ? UIColor(white: 1, alpha: 0.11) : UIColor(white: 1, alpha: 0.65)
        } else if hovered {
            pill.backgroundColor = dark ? UIColor(white: 1, alpha: 0.08) : UIColor(white: 0, alpha: 0.055)
        } else {
            pill.backgroundColor = .clear
        }
    }
}

@MainActor
private final class ActivePlacePill: UIControl {
    private let bg = UIView()
    private let iconView = TabIconView()
    private var hovered = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        MacTitleBarClick.markInteractive(self)
        MacHover.drawsOwnHover(self)

        bg.isUserInteractionEnabled = false
        bg.layer.cornerRadius = 9
        bg.layer.cornerCurve = .continuous
        bg.layer.shadowColor = UIColor.black.cgColor
        bg.layer.shadowOffset = CGSize(width: 0, height: 1)
        bg.layer.shadowRadius = 2.5
        addSubview(bg)

        iconView.isUserInteractionEnabled = false
        iconView.contentMode = .center
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13.5, weight: .medium)
        addSubview(iconView)

        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
        recolor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(image: UIImage?, title: String) {
        iconView.icon = image
        accessibilityLabel = title
        toolTip = title
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        bg.frame = bounds
        bg.layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 9).cgPath
        iconView.frame = bounds
    }

    override var isHighlighted: Bool { didSet { recolor() } }

    @objc private func hover(_ g: UIHoverGestureRecognizer) {
        hovered = g.state == .began || g.state == .changed
        recolor()
    }

    func recolor() {
        let dark = traitCollection.userInterfaceStyle == .dark
        bg.backgroundColor = dark
            ? UIColor(white: 1, alpha: isHighlighted ? 0.20 : hovered ? 0.16 : 0.13)
            : UIColor(white: 1, alpha: isHighlighted ? 0.96 : hovered ? 0.90 : 0.78)
        bg.layer.borderWidth = HQShape.pixel(traitCollection.displayScale)
        bg.layer.borderColor = (dark ? UIColor(white: 1, alpha: 0.14) : UIColor(white: 0, alpha: 0.08)).cgColor
        bg.layer.shadowOpacity = dark ? 0.22 : 0.07
        iconView.tintColor = HQPalette.label
    }
}

@MainActor
private final class WorkspaceTabButton: UIControl {
    let item: MacWorkspaceBar.TabItem
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var contextMenuProvider: (() -> UIMenu?)?

    private let bg = UIView()
    private let stack = UIStackView()
    private let dot = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let iconView = TabIconView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private var hovered = false

    init(item: MacWorkspaceBar.TabItem) {
        self.item = item
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = item.isActive ? [.button, .selected] : .button
        accessibilityLabel = item.title
        toolTip = item.title
        MacTitleBarClick.markInteractive(self)
        MacHover.drawsOwnHover(self)

        bg.isUserInteractionEnabled = false
        bg.layer.cornerRadius = 9
        bg.layer.cornerCurve = .continuous
        bg.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bg)

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 5
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer.cornerRadius = 2.75
        dot.widthAnchor.constraint(equalToConstant: 5.5).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 5.5).isActive = true

        spinner.transform = CGAffineTransform(scaleX: 0.56, y: 0.56)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.widthAnchor.constraint(equalToConstant: 14).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 14).isActive = true

        iconView.contentMode = .center
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12.5, weight: .regular)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 15).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 15).isActive = true

        titleLabel.text = item.title
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let showDot = item.isWorking || (item.isUnread && !item.isActive)
        if showDot {
            stack.addArrangedSubview(dot)
        }
        if item.isWorking {
            spinner.startAnimating()
            stack.addArrangedSubview(spinner)
        } else if let custom = item.customIcon {
            iconView.icon = custom
            stack.addArrangedSubview(iconView)
        } else if let name = item.iconName, let img = UIImage(systemName: name) {
            iconView.icon = img
            stack.addArrangedSubview(iconView)
        }
        stack.addArrangedSubview(titleLabel)

        var closeConfig = UIButton.Configuration.plain()
        closeConfig.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        closeConfig.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        closeButton.configuration = closeConfig
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.alpha = 0
        closeButton.isHidden = !item.closable
        closeButton.accessibilityLabel = "Close \(item.title)"
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        MacTitleBarClick.markInteractive(closeButton)
        addSubview(closeButton)

        let trailingPad: CGFloat = item.closable ? 22 : 12
        let maxW: CGFloat = item.closable ? 204 : 148
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            widthAnchor.constraint(lessThanOrEqualToConstant: maxW),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 82),
            bg.topAnchor.constraint(equalTo: topAnchor),
            bg.bottomAnchor.constraint(equalTo: bottomAnchor),
            bg.leadingAnchor.constraint(equalTo: leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailingPad),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
        ])

        addAction(UIAction { [weak self] _ in self?.onSelect?() }, for: .touchUpInside)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
        isContextMenuInteractionEnabled = item.closable
        recolor()
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                         configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let provider = contextMenuProvider else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in provider() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isHighlighted: Bool { didSet { recolor() } }

    @objc private func hover(_ g: UIHoverGestureRecognizer) {
        hovered = g.state == .began || g.state == .changed
        recolor()
    }

    func recolor() {
        let dark = traitCollection.userInterfaceStyle == .dark
        let active = item.isActive
        titleLabel.font = MacSidebar.font(15, weight: active ? .medium : .regular)
        titleLabel.textColor = active ? HQPalette.label : HQPalette.label.withAlphaComponent(dark ? 0.68 : 0.62)
        iconView.tintColor = active ? HQPalette.label : HQPalette.label.withAlphaComponent(dark ? 0.60 : 0.52)
        spinner.color = active ? HQPalette.tint : HQPalette.label2
        dot.backgroundColor = item.isWorking ? HQPalette.tint : (item.isUnread ? HQPalette.tint : .clear)
        closeButton.tintColor = HQPalette.label2
        closeButton.alpha = (item.closable && hovered) ? 0.85 : 0

        if active {
            bg.backgroundColor = dark ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 1, alpha: 0.78)
            bg.layer.borderWidth = HQShape.pixel(traitCollection.displayScale)
            bg.layer.borderColor = (dark ? UIColor(white: 1, alpha: 0.11) : UIColor(white: 0, alpha: 0.05)).cgColor
        } else if isHighlighted {
            bg.backgroundColor = dark ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 0, alpha: 0.07)
            bg.layer.borderWidth = 0
        } else if hovered {
            bg.backgroundColor = dark ? UIColor(white: 1, alpha: 0.07) : UIColor(white: 0, alpha: 0.045)
            bg.layer.borderWidth = 0
        } else {
            bg.backgroundColor = .clear
            bg.layer.borderWidth = 0
        }
    }
}
#endif
