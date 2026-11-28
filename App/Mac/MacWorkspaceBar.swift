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

    // Left controls: Back, Forward, and optional collapsible list toggle (only shown when a list column can fold).
    private let backButton = BarIconButton(symbol: "chevron.left", pointSize: 13, weight: .semibold, label: "Back", tip: "Back (⌘[)")
    private let forwardButton = BarIconButton(symbol: "chevron.right", pointSize: 13, weight: .semibold, label: "Forward", tip: "Forward (⌘])")
    private let listToggleButton = BarIconButton(symbol: "sidebar.leading", pointSize: 14, weight: .regular, label: "Hide List", tip: "Hide List (⇧⌘L)")

    // Center scrollable workspace tab strip
    private let scroll = UIScrollView()
    /// Holds `scroll` and carries the edge fade: a mask on the scroll view itself would move with its content.
    private let scrollHost = UIView()
    private let scrollFade = CAGradientLayer()
    private let strip = UIStackView()
    private var tabViews: [WorkspaceTabButton] = []
    /// The row's tabs as drawn, left to right (the place's own tab first while it shows): what the keys walk.
    private var shownItems: [TabItem] = []

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
        scroll.delegate = self
        scrollHost.backgroundColor = .clear
        scrollHost.addSubview(scroll)
        scrollFade.startPoint = CGPoint(x: 0, y: 0.5)
        scrollFade.endPoint = CGPoint(x: 1, y: 0.5)
        scrollHost.layer.mask = scrollFade

        strip.axis = .horizontal
        strip.alignment = .center
        strip.spacing = 4
        strip.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(strip)

        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            strip.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            strip.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            strip.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])

        for view in [backButton, forwardButton, listToggleButton, scrollHost, addButton] as [UIView] {
            addSubview(view)
        }

        backButton.addAction(UIAction { [weak self] _ in self?.goBack() }, for: .touchUpInside)
        forwardButton.addAction(UIAction { [weak self] _ in self?.goForward() }, for: .touchUpInside)
        listToggleButton.addAction(UIAction { [weak self] _ in self?.listToggleTapped() }, for: .touchUpInside)
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

        var x: CGFloat = 4
        backButton.frame = CGRect(x: x, y: (midY - btnSize / 2).rounded(), width: btnSize, height: btnSize)
        x += btnSize + 2
        forwardButton.frame = CGRect(x: x, y: (midY - btnSize / 2).rounded(), width: btnSize, height: btnSize)
        x += btnSize + 8

        if !listToggleButton.isHidden {
            listToggleButton.frame = CGRect(x: x, y: (midY - btnSize / 2).rounded(), width: btnSize, height: btnSize)
            x += btnSize + 8
        } else {
            listToggleButton.frame = .zero
        }

        let trailingPad: CGFloat = 4
        let addFrame = CGRect(x: bounds.width - trailingPad - btnSize, y: (midY - btnSize / 2).rounded(), width: btnSize, height: btnSize)
        addButton.frame = addFrame

        let scrollWidth = max(0, addFrame.minX - 8 - x)
        scrollHost.frame = CGRect(x: x, y: (midY - 16).rounded(), width: scrollWidth, height: 32)
        scroll.frame = scrollHost.bounds
        scroll.layoutIfNeeded()   // the strip's width (the content size) before the fade reads it
        updateScrollFade()
    }

    /// Tabs that run past an edge fade out there instead of being cut mid-word by the + button.
    private func updateScrollFade() {
        let width = scrollHost.bounds.width
        guard width > 0 else { return }
        let fade = min(28, width / 3) / width
        let hiddenLeft = scroll.contentOffset.x > 0.5
        let hiddenRight = scroll.contentSize.width - scroll.contentOffset.x - width > 0.5
        let clear = UIColor.clear.cgColor, solid = UIColor.black.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollFade.frame = scrollHost.bounds
        scrollFade.colors = [hiddenLeft ? clear : solid, solid, solid, hiddenRight ? clear : solid]
        scrollFade.locations = [0, NSNumber(value: Double(fade)), NSNumber(value: Double(1 - fade)), 1]
        CATransaction.commit()
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
        closingTabId = nil
        tabList = WorkspaceTabList()
        sync()
    }

    func sync() {
        guard split != nil, tabs != nil else { return }
        loadPersistedTabsIfNeeded()
        syncListToggle()
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

    private func syncListToggle() {
        guard let split else { return }
        let show = split.canToggleList
        let changed = listToggleButton.isHidden == show
        listToggleButton.isHidden = !show
        if show {
            let hidden = split.isListCollapsedForUser
            listToggleButton.accessibilityLabel = hidden ? "Show List" : "Hide List"
            listToggleButton.toolTip = hidden ? "Show List (⇧⌘L)" : "Hide List (⇧⌘L)"
            listToggleButton.isSelectedState = hidden
        }
        if changed { setNeedsLayout() }
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

        // Only open chats and sessions appear as tabs on the top bar; the sidebar owns switching sections.
        var displayItems: [TabItem] = []

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

        for item in displayItems {
            let btn = WorkspaceTabButton(item: item)
            btn.onSelect = { [weak self] in self?.activate(item.destination) }
            btn.onClose = item.closable ? { [weak self] in self?.closeTab(id: item.id) } : nil
            btn.contextMenuProvider = item.closable ? { [weak self] in self?.contextMenu(forTabId: item.id) } : nil
            tabViews.append(btn)
            strip.addArrangedSubview(btn)
        }
        setNeedsLayout()
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

    /// Returns the tab id that must be suppressed in `recordCurrentDestinationIfNeeded()` during an async detail-pane
    /// transition after closing tab(s): only set when `activeId` itself was removed (never when closing an inactive tab).
    nonisolated static func closingGuardId(removedIds: Set<String>, activeId: String?) -> String? {
        guard let activeId, removedIds.contains(activeId) else { return nil }
        return activeId
    }

    private func closeTab(id: String) {
        let activeId = currentDestination().flatMap(tabId(for:))
        let result = tabList.close(tabId: id, activeTabId: activeId)
        guard result.removed else { return }
        persistTabs()
        if let guardId = Self.closingGuardId(removedIds: [id], activeId: activeId) {
            closingTabId = guardId
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
        let beforeIds = Set(tabList.tabs.map(\.tabId))
        guard tabList.closeOthers(keeping: id) else { return }
        persistTabs()
        let removedIds = beforeIds.subtracting(tabList.tabs.map(\.tabId))
        if let guardId = Self.closingGuardId(removedIds: removedIds, activeId: activeId) {
            closingTabId = guardId
        }
        if activeId != id, let kept = tabList.tabs.first(where: { $0.tabId == id }) {
            activate(destination(for: kept))
            return
        }
        rebuildTabStrip()
        recolor()
    }

    private func closeTabsToRight(of id: String) {
        let activeId = currentDestination().flatMap(tabId(for:))
        let beforeIds = Set(tabList.tabs.map(\.tabId))
        guard tabList.closeToRight(of: id) else { return }
        persistTabs()
        let removedIds = beforeIds.subtracting(tabList.tabs.map(\.tabId))
        if let guardId = Self.closingGuardId(removedIds: removedIds, activeId: activeId) {
            closingTabId = guardId
            if let anchor = tabList.tabs.first(where: { $0.tabId == id }) {
                activate(destination(for: anchor))
                return
            }
        }
        rebuildTabStrip()
        recolor()
    }

    private func closeAllTabs() {
        let activeId = currentDestination().flatMap(tabId(for:))
        let beforeIds = Set(tabList.tabs.map(\.tabId))
        guard tabList.closeAll() else { return }
        persistTabs()
        if let guardId = Self.closingGuardId(removedIds: beforeIds, activeId: activeId) {
            closingTabId = guardId
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

    private func listToggleTapped() {
        guard let split, split.canToggleList else { return }
        split.toggleList()
        syncListToggle()
    }

    @objc private func handleWindowDrag(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began {
            MacGlassShell.beginWindowDrag(for: window)
        }
    }

    func recolor() {
        backButton.recolor()
        forwardButton.recolor()
        listToggleButton.recolor()
        addButton.recolor()
        tabViews.forEach { $0.recolor() }
    }
}

extension MacWorkspaceBar: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateScrollFade() }
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
