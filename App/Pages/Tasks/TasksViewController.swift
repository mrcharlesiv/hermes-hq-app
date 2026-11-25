// [tasks-first] The Tasks page (docs/tasks.md; owner 2026-11-12: "pure task management first, agent stuff second",
// mockups hermes-hq-share/2026-11-12-tasks-first). A row of views under the bar (Today, Upcoming, Inbox, your lists,
// Bots), then that view's tasks, ordered by when: one line each, a bot as a small face at the row's end, and a second
// line only when the bot has something for you. A bot's ideas are short rows at Inbox's foot. Filter (the bots), search
// and + in the bar. Tap a circle to tick a task, a row to open it; swipe for Done and Delete.
// Painted from disk in the first frame, then read; read again on appear, on foreground and after a task push.

import SwiftUI
import UIKit

final class TasksViewController: UIViewController, UICollectionViewDelegate, UISearchResultsUpdating,
                                  UICollectionViewDragDelegate, UICollectionViewDropDelegate {
    private nonisolated enum Section: Hashable {
        case filters, offers, keeper, week, group(TodoGroupKind), empty, ideas, skeleton
        /// [goals] The Goals view: a group of goal cards, then "+ New Goal" (or what a goal is, with none).
        case goals(GoalGroupKey), goalsFoot
        /// [goals] Step 2: Today's Goals shelf, over everything else in Today.
        case shelf
        /// Grouped Overview sections (iPhone / compact root): Smart Views 2×2 grid, inline Suggested preview, My Lists, and Agents.
        case overviewSmart, overviewSuggested, overviewLists, overviewAgents
    }
    /// [goals] The Goals view's groups (docs/goals.md "The Goals view").
    /// `found`: a search's Goals group (any status), over its To Do and Done.
    nonisolated enum GoalGroupKey: String, Hashable { case active, someday, achieved, letGo, found }
    private nonisolated enum Item: Hashable {
        case filters, task(String), skeleton(Int), week, viewEmpty(String)
        /// [goals] A goal's card (its id), "+ New Goal", and the view with no goals.
        case goal(String), newGoal, goalsEmpty
        /// [goals] Step 2: the shelf (its heading and cards, one cell).
        case shelf
        /// [task-lists] A bot's offer (its id), the line naming a list's bot, and "4 more in Work" (the list's id).
        case offer(String), keeper(String), more(String)
        /// [goals step 3] A bot's offer for a goal (its id): one at a time at the top of Today, under any list offer.
        case goalOffer(String)
        case ideaHead, idea(String), ideaNote(TaskIdeasNote)
        /// Grouped Overview cells (iPhone / compact root).
        case overviewSmart, overviewSuggested, overviewLists, overviewAgents
    }

    /// The page shows somewhere (an add-on without Tasks is asked again on foreground only then).
    static var onScreen = false

    let store: TasksStore
    let scope: PagesScope
    private let context: MorePages.Context
    /// On iPhone/iPad: nil = Grouped Overview root; non-nil = pushed view (Today, Upcoming, Inbox, Goals, a list, or Bots).
    /// On Mac: always nil (single split view with the collapsible Tasks sidebar beside the list).
    private let pinnedView: TodoView?
    private var isOverviewRoot: Bool { !DeviceWord.isMac && pinnedView == nil }
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var rows: [String: TodoRowModel] = [:]
    /// The view on show (on Mac, or on a pushed iPhone view).
    private var current: TodoView
    /// Cached Grouped Overview / Mac Sidebar models so cells reconfigure only when counts/lists change.
    private var overviewSmart: [TasksSmartTileModel] = []
    private var overviewSuggested: TasksOverviewSuggestedModel?
    private var overviewLists: [TasksOverviewListModel] = []
    private var overviewAgents: TasksOverviewAgentsModel?
    /// Mac internal sidebar state (auto-collapses when narrow or when a task detail pane opens beside Tasks).
    private var sidebarCollapsedByUser = false
    private var showsSidebar = false
    /// The view's groups, each with its task ids in order.
    private var groups: [(TodoGroupKind, [String])] = []
    /// [task-lists] Today's "Next in Work": how many more open tasks each list has than the few shown.
    private var mores: [String: Int] = [:]
    /// The offers' cards on show, and the ones whose answer is on its way.
    private var offerCards: [String: TaskOfferCardModel] = [:]
    private var answering: Set<String> = []
    /// [goals step 3] Today's goal offer card, and the one answered here (kept with its Undo until you leave Today).
    private var goalOfferCards: [String: GoalOfferCardModel] = [:]
    private var goalOfferKept: String?
    /// Upcoming's week strip.
    private var week: [TodoWeekStrip.Day] = []
    /// How many weeks forward/back Upcoming's strip is showing (0 = week starting today).
    private var weekOffset = 0
    /// Month/year title over Upcoming's strip ("November 2026").
    private var weekTitle = ""
    /// Active Priority / Tag filters from the Filter menu (nil = Any).
    private var priorityFilter: Int?
    private var tagFilter: String?
    /// The day picked on it ("2026-11-14"): the list holds that day alone. nil: every coming day.
    private var pickedDay: String?
    private var selecting = false
    /// Select: the tasks picked, in the order they were tapped.
    private var picked: [String] = []
    private var query = ""
    private var doneOpen = false
    private var ticking: Set<String> = []
    /// [task-check-off] Rows whose picture is in the air as dust: their cells stay empty until the list has moved them.
    private var dusted: Set<String> = []
    private var notices: PageNoticeHost!
    /// [notify] How long a task opened from outside has waited for the list to name it (`openTask`, half-seconds).
    private var listWait = 0
    private var openWaitToken = 0
    /// Where a held task would land (section and index): a tick each time it moves to a new place.
    private var dropPlace: String?
    private let scopeItem = ScopeBarItem()
    /// Collapsible Tasks sidebar on Mac (Views, My Lists, Agents); unused on iPhone where Overview pushes views.
    private lazy var sidebar = TasksSidebarHost(actions: listActions) { [weak self] view in self?.show(view) }
    private var listActions: TaskListActions {
        TaskListActions(
            edit: { [weak self] in self?.editList($0) },
            rename: { [weak self] in self?.renameList($0) },
            move: { [weak self] in self?.moveList($0, by: $1) },
            delete: { [weak self] in self?.deleteList($0) },
            newList: { [weak self] in self?.promptNewList(moving: []) }
        )
    }
    #if targetEnvironment(macCatalyst)
    private lazy var macSidebarToggleItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "sidebar.left"), primaryAction: UIAction { [weak self] _ in
            self?.toggleMacSidebar()
        })
        item.accessibilityLabel = "Toggle Tasks Sidebar"
        item.accessibilityIdentifier = "tasks.sidebar.toggle"
        DesktopBars.markThin(item)
        return item
    }()
    private lazy var macViewPickerItem: UIBarButtonItem = makeMacViewPickerItem()

    private func makeMacViewPickerItem() -> UIBarButtonItem {
        let menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            MainActor.assumeIsolated { done(self?.macViewPickerChoices() ?? []) }
        }])
        let item = UIBarButtonItem(title: "Today", image: UIImage(systemName: "sun.max"), menu: menu)
        item.accessibilityLabel = "Switch Tasks View"
        item.accessibilityIdentifier = "tasks.views.picker"
        DesktopBars.markThin(item)
        return item
    }
    #endif
    private var searchCapsule: PageBarCapsule?
    private var scopeObserver: UUID?
    private var minuteTimer: Timer?
    private var refreshStarted: Date?
    private var skeletonShown = false
    private var skeletonWork: DispatchWorkItem?
    private var updateAsked = false
    private var ideas: TaskIdeasStore { TasksHub.ideas(for: store) }
    private var ideaCards: [String: TaskIdeaCardModel] = [:]
    private var shownGoalCards: [String: GoalCardModel] = [:]
    /// [goals] The Goals view's cards on show, its groups (ids in order), and the folded groups opened.
    private var goalCards: [String: GoalCardModel] = [:]
    private var goalGroups: [(GoalGroupKey, [String])] = []
    private var goalFoldsOpen: Set<GoalGroupKey> = []
    /// [goals] Step 2: the shelf's cards on show.
    private var shelfCards: [GoalShelfCard] = []
    private var shownShelfCards: [GoalShelfCard] = []
    /// Ideas being added (their buttons wait for the gateway).
    private var addingIdeas: Set<String> = []
    private var shownIdeaCards: [String: TaskIdeaCardModel] = [:]
    /// The idea whose card is open (a tap on its row).
    private let ideaOpen = TaskIdeaOpen()
    private var openIdea: String? {
        get { ideaOpen.id }
        set { if ideaOpen.id != newValue { ideaOpen.id = newValue } }
    }

    private lazy var addItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "plus"), primaryAction: UIAction { [weak self] _ in self?.newTask() })
        item.accessibilityLabel = "New Task"
        item.accessibilityIdentifier = "tasks.new"
        DesktopBars.markThin(item)
        return item
    }()

    private lazy var moreItem: UIBarButtonItem = makeMoreItem()

    private lazy var endSelectItem: UIBarButtonItem = {
        let item = UIBarButtonItem(title: "Done", primaryAction: UIAction { [weak self] _ in self?.setSelecting(false) })
        item.style = .prominent
        item.accessibilityIdentifier = "tasks.select.done"
        return item
    }()
    private lazy var selectMoveItem: UIBarButtonItem = makeSelectMoveItem()
    private lazy var selectScheduleItem: UIBarButtonItem = makeSelectScheduleItem()
    private lazy var selectPriorityItem: UIBarButtonItem = makeSelectPriorityItem()

    private func makeSelectMoveItem() -> UIBarButtonItem {
        let menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            MainActor.assumeIsolated { done(self?.selectionMoveChoices() ?? []) }
        }])
        let item = UIBarButtonItem(title: "Move To", image: UIImage(systemName: "folder"), menu: menu)
        item.accessibilityIdentifier = "tasks.select.move"
        item.accessibilityLabel = "Move To"
        DesktopBars.markThin(item)
        return item
    }

    private func makeSelectScheduleItem() -> UIBarButtonItem {
        let menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            MainActor.assumeIsolated { done(self?.selectionScheduleChoices() ?? []) }
        }])
        let item = UIBarButtonItem(title: "Schedule", image: UIImage(systemName: "calendar"), menu: menu)
        item.accessibilityIdentifier = "tasks.select.schedule"
        item.accessibilityLabel = "Schedule"
        DesktopBars.markThin(item)
        return item
    }

    private func makeSelectPriorityItem() -> UIBarButtonItem {
        let menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            MainActor.assumeIsolated { done(self?.selectionPriorityChoices() ?? []) }
        }])
        let item = UIBarButtonItem(title: "Priority", image: UIImage(systemName: "flag"), menu: menu)
        item.accessibilityIdentifier = "tasks.select.priority"
        item.accessibilityLabel = "Priority"
        DesktopBars.markThin(item)
        return item
    }
    private lazy var selectDoneItem: UIBarButtonItem = {
        let item = UIBarButtonItem(title: "Mark Done", image: UIImage(systemName: "checkmark.circle"),
                                   primaryAction: UIAction { [weak self] _ in self?.markSelectedDone() })
        item.accessibilityIdentifier = "tasks.select.mark-done"
        item.accessibilityLabel = "Mark Done"
        DesktopBars.markThin(item)
        return item
    }()
    private lazy var selectDeleteItem: UIBarButtonItem = {
        let item = UIBarButtonItem(title: "Delete", image: UIImage(systemName: "trash"),
                                   primaryAction: UIAction { [weak self] _ in self?.deleteSelected() })
        item.tintColor = .systemRed
        item.accessibilityIdentifier = "tasks.select.delete"
        item.accessibilityLabel = "Delete"
        DesktopBars.markThin(item)
        return item
    }()

    private func makeMoreItem() -> UIBarButtonItem {
        let menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            MainActor.assumeIsolated { done(self?.menuItems() ?? []) }
        }])
        let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: menu)
        item.accessibilityLabel = "More"
        item.accessibilityIdentifier = "tasks.more"
        DesktopBars.markThin(item)
        return item
    }

    init(store: TasksStore, context: MorePages.Context, pinnedView: TodoView? = nil) {
        self.store = store
        self.context = context
        self.pinnedView = DeviceWord.isMac ? nil : pinnedView
        self.current = pinnedView ?? .today
        scope = PagesScope(account: context.account, key: TasksHub.scopeKey(context.account))
        super.init(nibName: nil, bundle: nil)
        title = isOverviewRoot ? "Tasks" : (DeviceWord.isMac ? "Tasks" : TasksNavigationLayout.title(for: current, sections: store.sections))
        Self.live.add(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var bots: [Bot] { context.bots }
    private func botName(_ profile: String?) -> String { PagesNames.botName(profile ?? "default", bots: bots) }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutSidebarAndContent()
        hqPlaceMacEmptyTitle()
        fitWide()
    }

    // MARK: [mac-tools] The table and sidebar over the window

    /// [mac-tools] Owner 2026-11-09 (the Tools sketch: pickers, filters and search in the top bar; no empty pane until
    /// you open one): on the Mac, with no task open beside it, Tasks has the window. Its rows are a table's (task,
    /// where it stands, the details, who has it) and the bot picker is in words. With a task open beside it the list
    /// is the column it was. iPhone and iPad never see this.
    private(set) var isTable = false
    /// Kept for callers referencing the original table threshold; actual content check uses `TasksNavigationLayout.tableMinContentWidth`.
    static let tableAt: CGFloat = 940

    private var listContainer: UIView {
        guard let collectionView else { return view }
        return collectionView.superview === view ? collectionView : (collectionView.superview ?? collectionView)
    }

    private func layoutSidebarAndContent() {
        guard DeviceWord.isMac, isViewLoaded, collectionView != nil else { return }
        let next = TasksNavigationLayout.shouldShowMacSidebar(
            isMac: DeviceWord.isMac,
            paneWidth: view.bounds.width,
            userCollapsed: sidebarCollapsedByUser,
            hasList: store.hasList,
            needsAddOn: store.needsAddOn
        )
        let changed = next != showsSidebar
        showsSidebar = next
        let scale = max(view.window?.screen.scale ?? traitCollection.displayScale, 1)
        sidebar.layout(in: view.bounds, visible: next, scale: scale)
        let container = listContainer
        container.autoresizingMask = []
        let target: CGRect
        if next {
            let pixel = 1 / scale
            let x = TasksNavigationLayout.sidebarWidth + pixel
            target = CGRect(x: x, y: 0, width: max(0, view.bounds.width - x), height: view.bounds.height)
        } else {
            target = view.bounds
        }
        if container.frame != target {
            container.frame = target
            if container !== collectionView { collectionView.frame = container.bounds }
        }
        if changed { updateMacLeadingBar() }
    }

    private func fitWide() {
        let wide = TasksNavigationLayout.shouldUseMacTable(isMac: DeviceWord.isMac, contentWidth: listContainer.bounds.width)
        guard wide != isTable else { return }
        isTable = wide
        scopeItem.compact = !wide
        reload(animated: false)
    }

    #if targetEnvironment(macCatalyst)
    private func toggleMacSidebar() {
        PagesHaptics.selection()
        sidebarCollapsedByUser.toggle()
        layoutSidebarAndContent()
        fitWide()
        updateMacLeadingBar()
    }

    private func updateMacLeadingBar() {
        guard DeviceWord.isMac, isViewLoaded else { return }
        guard store.hasList && !store.needsAddOn else {
            navigationItem.leftBarButtonItems = nil
            return
        }
        let wideEnough = view.bounds.width >= TasksNavigationLayout.sidebarMinPaneWidth
        let viewTitle = TasksNavigationLayout.title(for: current, sections: store.sections)
        let symbol = TasksNavigationLayout.symbol(for: current, sections: store.sections)
        macViewPickerItem.title = viewTitle
        macViewPickerItem.image = UIImage(systemName: symbol)
        macSidebarToggleItem.accessibilityLabel = showsSidebar ? "Hide Tasks Sidebar" : "Show Tasks Sidebar"
        var items: [UIBarButtonItem] = []
        if wideEnough { items.append(macSidebarToggleItem) }
        if !showsSidebar { items.append(macViewPickerItem) }
        if navigationItem.leftBarButtonItems ?? [] != items { navigationItem.leftBarButtonItems = items }
    }

    private func macViewPickerChoices() -> [UIMenuElement] {
        var smartItems: [UIMenuElement] = []
        for tile in overviewSmart {
            let count = tile.count.flatMap { $0 > 0 ? "\($0)" : nil }
            smartItems.append(UIAction(title: tile.title, subtitle: count, image: UIImage(systemName: tile.symbol),
                                       state: current == tile.view ? .on : .off) { [weak self] _ in
                self?.show(tile.view)
            })
        }
        var out: [UIMenuElement] = [UIMenu(title: "Views", options: .displayInline, children: smartItems)]
        var listItems: [UIMenuElement] = overviewLists.map { list in
            let count = list.count > 0 ? "\(list.count)" : nil
            return UIAction(title: list.name, subtitle: count, image: UIImage(systemName: list.icon),
                            state: current == .list(list.id) ? .on : .off) { [weak self] _ in
                self?.show(.list(list.id))
            }
        }
        if !store.readOnlyGateway && store.sectionsSupported {
            listItems.append(UIAction(title: "New List…", image: UIImage(systemName: "plus")) { [weak self] _ in
                self?.promptNewList(moving: [])
            })
        }
        if !listItems.isEmpty {
            out.append(UIMenu(title: "My Lists", options: .displayInline, children: listItems))
        }
        if let agents = overviewAgents, !agents.isEmpty {
            var agentItems: [UIMenuElement] = []
            if let suggested = agents.suggested {
                let count = suggested.isOn && suggested.count > 0 ? "\(suggested.count)" : nil
                agentItems.append(UIAction(title: "Suggested", subtitle: count, image: UIImage(systemName: "sparkle"),
                                           state: current == .suggested ? .on : .off) { [weak self] _ in
                    self?.show(.suggested)
                })
            }
            if let botsCount = agents.botsCount {
                let count = botsCount > 0 ? "\(botsCount)" : nil
                agentItems.append(UIAction(title: "Bots’ Tasks", subtitle: count, image: UIImage(systemName: "person.2"),
                                           state: current == .bots ? .on : .off) { [weak self] _ in
                    self?.show(.bots)
                })
            }
            out.append(UIMenu(title: "Agents", options: .displayInline, children: agentItems))
        }
        return out
    }
    #else
    private func updateMacLeadingBar() {}
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        settleTitle()
        // The bots are a filter glyph beside the magnifier and +: "All Bots" in words squeezed "Tasks" to "…". The
        // Mac's table has the room for the words.
        scopeItem.compact = true
        view.backgroundColor = HQPalette.page
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = HQPalette.page
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.accessibilityIdentifier = "tasks.list"
        collectionView.dragDelegate = self
        collectionView.dropDelegate = self
        collectionView.dragInteractionEnabled = true
        view.addSubview(collectionView)
        ListBarAppearance.pinTitle(in: self, softEdgeAround: collectionView)
        let backdrop = PageBackdrop.install(in: self, clearing: [collectionView])
        backdrop.onCardsChange = { [weak self] in   // [soft-cards] titles keep a card's room
            BackdropCards.redraw(self?.dataSource)
            // The first card one gap under the pills, as the cards are from each other (it stood 8.3 pt under them;
            // the pills grow with UI Scale inside their band, so the room follows it).
            if let self { BackdropCards.setTopRoom(BackdropCards.on(self) ? 1.7 + max(0, BackdropCards.grown(17.7)) : 0, of: self.collectionView) }
        }
        if DeviceWord.isMac { sidebar.install(in: self) }
        notices = PageNoticeHost(in: view)
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in self?.pulledToRefresh() }, for: .valueChanged)
        collectionView.hqInstallRefresh(refresh)
        searchCapsule = PageBarCapsule.search(on: self, page: "tasks", placeholder: "Search Tasks", updater: self)
        configureDataSource()
        claimStore()
        scopeObserver = scope.observe { [weak self] _ in self?.reload(animated: false) }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (vc: TasksViewController, _) in vc.reload(animated: false) }
        store.prepare()
        reload(animated: false)
    }

    private func claimStore() {
        store.onChange = {
            for page in TasksViewController.live.allObjects { page.setNeedsReload() }
        }
        ideas.onChange = { [weak store] in
            guard let store else { return }
            let ideas = TasksHub.ideas(for: store)
            if let page = ideas.page { store.ideasRead(page.on ? ideas.shown.count : 0) }
            for page in TasksViewController.live.allObjects { page.setNeedsReload() }
        }
        ideas.onNotice = { [weak self] text in self?.notices.show(text, seconds: 4) }
        store.onNotice = { [weak self] text in
            guard let self else { return }
            guard let sheet = self.presentedViewController else {
                #if targetEnvironment(macCatalyst)
                // [mac] Mac polish #44: in two panes the task is open beside the list, not over it: its page says what
                // went wrong with it. A notice about another task (its row's menu or circle) or the list stays here.
                if let split = (self.tabBarController as? MainTabController)?.split, split.isDouble,
                   let model = TodoSheet.model(of: split.detail.topViewController), model.taskID == self.store.noticeTask {
                    model.show(text)
                    return
                }
                #endif
                self.notices.show(text, seconds: 4)
                return
            }
            // [goals] A task opened from a goal's page stands over that page: the top sheet says it.
            var top = sheet
            while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
            let root = (top as? UINavigationController)?.viewControllers.first ?? top
            if let model = TodoSheet.model(of: root) {
                model.show(text)
            } else if let goal = root as? GoalPageHost {
                goal.model.show(text)
            } else if let host = root as? NewTodoHost, host.model.saving {
                return   // New Task says why on its own line
            } else if let host = root as? NewGoalHost, host.model.saving {
                return   // [goals] so does New Goal
            } else {
                // Over a sheet (Tasks Settings, New Task): the page's own notice would be under it, out of sight.
                PagesHUD.show(text, symbol: "exclamationmark.triangle", from: root, duration: 4)
            }
        }
        store.onRefreshFailed = { [weak self] _ in
            guard let self, self.view.window != nil, self.presentedViewController == nil else { return }
            self.notices.show("Couldn’t refresh. Showing what was saved.")
        }
    }

    isolated deinit {
        minuteTimer?.invalidate()
        if let scopeObserver { scope.stopObserving(scopeObserver) }
    }

    /// Pushed from More (not a tab of its own): the small centred title the other pushed More pages have, and the scope
    /// as a glyph, as Artifacts there (UX study #88). A tab root keeps the list header. Owner 2026-11-04: the title was
    /// "way too small compared to the other pages": the view loaded before the push (no navigation controller yet), so
    /// the page took the tab's header, the Desktop Look's 12 pt "TASKS". So it's decided again once it is on a stack.
    private var titleSettled = false
    private var pushed = false
    private func settleTitle() {
        if pushed { ListBarAppearance.dropLookTitle(navigationItem) }   // `pinTitle` set the tab's label
        guard !titleSettled else { return }
        guard let navigation = navigationController else {
            title = isOverviewRoot || DeviceWord.isMac ? "Tasks" : TasksNavigationLayout.title(for: current, sections: store.sections)
            return
        }
        titleSettled = true
        // [mac] Mac polish #59 (owner's call 2026-11-07): on the Mac Tasks is one of the sidebar's Tools, which have the
        // small centred title (Files, Kanban, Terminal…); the big heading is for Sessions, Jobs and Artifacts.
        let tabRoot = !DeviceWord.isMac && pinnedView == nil && navigation.viewControllers.first === self && navigation is PaneNavigationController
        if tabRoot {
            PageChrome.applyListHeader(to: self, title: "Tasks")
        } else {
            pushed = true
            navigationItem.largeTitleDisplayMode = .never
            ListBarAppearance.dropLookTitle(navigationItem)
            if !isOverviewRoot && !DeviceWord.isMac {
                title = TasksNavigationLayout.title(for: current, sections: store.sections)
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        settleTitle()
        super.viewWillAppear(animated)
        installBarItemTips()   // [Mac UI check 2026-11-13] the bar's icon buttons name themselves under the pointer
        Self.onScreen = true
        searchCapsule?.restoreIfTyped()
        claimStore()
        store.readOnlyGateway = context.readOnly
        reload(animated: false)
        startMinuteClock()
        Task { await store.refresh() }
        if isOverviewRoot || current == .suggested || DeviceWord.isMac { readIdeas() }
        for path in collectionView.indexPathsForSelectedItems ?? [] where dataSource.itemIdentifier(for: path) != onShowTask.map(Item.task) {
            collectionView.deselectItem(at: path, animated: animated)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if selecting { setSelecting(false) }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        minuteTimer?.invalidate()
        minuteTimer = nil
        let anyVisible = Self.live.allObjects.contains { $0 !== self && $0.viewIfLoaded?.window != nil }
        if !anyVisible {
            Self.onScreen = false
            ideas.stopPolling()
        }
    }

    // MARK: Layout

    private func makeLayout() -> UICollectionViewLayout {
        let cards = UICollectionViewCompositionalLayout { [weak self] index, environment in
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.backgroundColor = .clear
            config.showsSeparators = false
            if let section = self?.dataSource?.sectionIdentifier(for: index), self?.hasHeader(section) == true {
                config.headerMode = .supplementary
            }
            config.headerTopPadding = 0
            config.leadingSwipeActionsConfigurationProvider = { [weak self] path in self?.leadingSwipe(path) }
            config.trailingSwipeActionsConfigurationProvider = { [weak self] path in self?.trailingSwipe(path) }
            let layout = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            layout.boundarySupplementaryItems.forEach { $0.pinToVisibleBounds = false }
            // [backdrop-cards] The tasks' groups and the ideas; the week and an empty view's line stay as they are.
            let carded: Bool = switch self?.dataSource?.sectionIdentifier(for: index) { case .group?, .ideas?: true; default: false }
            let onCards = carded && BackdropCards.on(self)
            // A folded group is its heading alone: as much under the name as over it.
            let folded = config.headerMode == .supplementary && (self?.collectionView.numberOfItems(inSection: index) ?? 1) == 0
            BackdropCards.card(layout, on: onCards, header: config.headerMode == .supplementary,
                               extraBottom: folded ? 4 : onCards ? self?.footRoom(index) ?? 0 : 0)
            return ScrollBarLane.keep(layout)
        }
        BackdropCards.register(in: cards)   // [backdrop-cards]
        return cards
    }

    private static func rowBackground(_ cell: UICollectionViewListCell, _ state: UICellConfigurationState) {
        #if targetEnvironment(macCatalyst)
        if DeviceWord.isMac { cell.backgroundConfiguration = MacListFocus.background(cell, state); return }
        #endif
        if Theme.isDesktop { cell.backgroundConfiguration = DesktopLayout.rowBackground(state); return }
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = state.isHighlighted || state.isSelected ? HQPalette.cellPressed : .clear
        cell.backgroundConfiguration = background
    }

    private func configureDataSource() {
        let taskCell = UICollectionView.CellRegistration<TaskListCell, String> { [weak self] cell, _, id in
            guard let self, let row = self.rows[id] else { return }
            cell.onMeasure = { [weak self] height in self?.measured(id, height) }
            cell.contentConfiguration = UIHostingConfiguration {
                TodoRowView(row: row, toggle: { [weak self] in self?.toggleDone(id) },
                            open: { [weak self] in self.map { $0.collectionView.pressRow(at: $0.dataSource.indexPath(for: .task(id))) } })
            }.margins(.all, 0)
            cell.contentView.alpha = self.dusted.contains(id) ? 0 : 1   // [task-check-off]
            cell.accessibilityIdentifier = "task-row-\(row.title)"
            cell.accessibilityTraits = row.picked ? [.button, .selected] : .button
            #if targetEnvironment(macCatalyst)
            // [Mac AAA 2026-11-16] On the Mac a cell with a trait is an element of its own: each task was a button with
            // no name holding the row's own named button, two stops for VoiceOver (read in the running app's
            // accessibility tree). The row inside is the button; the cell keeps only "selected".
            cell.accessibilityTraits = row.picked ? .selected : []
            #endif
            cell.configurationUpdateHandler = { cell, state in Self.rowBackground(cell as! UICollectionViewListCell, state) }
        }
        let ideaRowCell = UICollectionView.CellRegistration<SoftCardListCell, String> { [weak self] cell, _, id in
            guard let self, let card = self.ideaCards[id] else { return }
            let enabled = !self.store.readOnlyGateway
            // One view for both states: it opens and closes by itself (`ideaOpen`), with the cell's height.
            cell.contentConfiguration = UIHostingConfiguration {
                TaskIdeaCell(card: card, open: self.ideaOpen, enabled: enabled,
                             add: { [weak self] start in self?.addIdea(id, start: start) },
                             dismiss: { [weak self] in self?.dismissIdea(id) })
            }.margins(.all, 0)
            // The card is laid out whole from the first frame; the cell shows as much of it as it has grown to.
            cell.clipsToBounds = true
            cell.contentView.clipsToBounds = true
            // Pressed only while the finger is down: a suggestion is never "selected", and the grey fading out over
            // a cell that is growing into its card read as a flash.
            cell.configurationUpdateHandler = { cell, state in
                #if targetEnvironment(macCatalyst)
                if DeviceWord.isMac {
                    var s = state
                    s.isSelected = false
                    (cell as! UICollectionViewListCell).backgroundConfiguration = MacListFocus.background(cell, s)
                    return
                }
                #endif
                if Theme.isDesktop {
                    var s = state
                    s.isSelected = false
                    (cell as! UICollectionViewListCell).backgroundConfiguration = DesktopLayout.rowBackground(s)
                    return
                }
                var background = UIBackgroundConfiguration.clear()
                background.backgroundColor = state.isHighlighted ? HQPalette.cellPressed : .clear
                (cell as! UICollectionViewListCell).backgroundConfiguration = background
            }
        }
        let ideaHeadCell = UICollectionView.CellRegistration<SoftCardListCell, Item> { [weak self] cell, _, _ in
            guard let self, let page = self.ideas.page else { return }
            let enabled = !self.store.readOnlyGateway
            cell.contentConfiguration = UIHostingConfiguration {
                TaskIdeasHead(botName: self.botName(page.bot), count: self.ideaCards.count, at: page.at, ranAt: page.ranAt,
                              looking: page.looking, enabled: enabled,
                              lookNow: { [weak self] in self?.lookForIdeas() }, settings: { [weak self] in self?.openSettings() })
            }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        let ideaNoteCell = UICollectionView.CellRegistration<SoftCardListCell, TaskIdeasNote> { [weak self] cell, _, note in
            let enabled = !(self?.store.readOnlyGateway ?? true)
            cell.contentConfiguration = UIHostingConfiguration {
                TaskIdeasNoteView(note: note, enabled: enabled,
                                  primary: { [weak self] in self?.notePrimary(note) },
                                  secondary: { [weak self] in self?.importReminders() })
            }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        let filtersCell = UICollectionView.CellRegistration<SoftCardListCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.contentConfiguration = UIHostingConfiguration {
                TaskActiveFiltersBar(
                    priority: self.priorityFilter,
                    tag: self.tagFilter,
                    clearPriority: { [weak self] in PagesHaptics.selection(); self?.priorityFilter = nil; self?.reload(animated: true) },
                    clearTag: { [weak self] in PagesHaptics.selection(); self?.tagFilter = nil; self?.reload(animated: true) }
                )
            }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        let weekCell = UICollectionView.CellRegistration<SoftCardListCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.contentConfiguration = UIHostingConfiguration {
                TodoWeekStrip(
                    title: self.weekTitle,
                    showTodayButton: self.weekOffset != 0 || self.pickedDay != nil,
                    days: self.week,
                    pick: { [weak self] key in self?.goToDay(key) },
                    stepWeek: { [weak self] delta in self?.stepWeek(delta) },
                    goToday: { [weak self] in self?.jumpToThisWeek() },
                    onDropTask: { [weak self] taskID, dayKey in self?.rescheduleDroppedTask(taskID, onto: dayKey) ?? false }
                )
            }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        let offerCell = UICollectionView.CellRegistration<SoftCardListCell, String> { [weak self] cell, _, id in
            guard let self, let card = self.offerCards[id] else { return }
            cell.contentConfiguration = UIHostingConfiguration {
                TaskOfferCard(model: card, enabled: !self.store.readOnlyGateway) { [weak self] button in self?.answerOffer(id, button) }
            }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        let goalOfferCell = UICollectionView.CellRegistration<SoftCardListCell, String> { [weak self] cell, _, id in
            guard let self, let card = self.goalOfferCards[id] else { return }
            cell.contentConfiguration = UIHostingConfiguration {
                GoalOfferCard(model: card, enabled: !self.store.readOnlyGateway,
                              tap: { [weak self] button in self?.answerGoalOffer(id, button) },
                              undo: { [weak self] in self?.undoGoalOffer(id) },
                              more: { [weak self] in self?.showGoalOffer(id) })
            }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        let keeperCell = UICollectionView.CellRegistration<SoftCardListCell, String> { cell, _, text in
            cell.contentConfiguration = UIHostingConfiguration { TaskKeeperRow(text: text) }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        let moreCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let self else { return }
            let text = TodoViews.moreLine(self.mores[id] ?? 0, list: self.listName(id) ?? "List")
            cell.contentConfiguration = UIHostingConfiguration { TaskMoreRow(text: text) }.margins(.all, 0)
            cell.configurationUpdateHandler = { cell, state in Self.rowBackground(cell as! UICollectionViewListCell, state) }
        }
        let emptyCell = UICollectionView.CellRegistration<SoftCardListCell, String> { cell, _, text in
            cell.contentConfiguration = UIHostingConfiguration { TodoViewEmptyRow(text: text) }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        // [goals] A goal's card (a tap opens its page: `didSelectItemAt`), "+ New Goal", and the view with no goals.
        let goalCell = UICollectionView.CellRegistration<SoftCardListCell, String> { [weak self] cell, _, id in
            guard let self, let card = self.goalCards[id] else { return }
            cell.contentConfiguration = UIHostingConfiguration {
                GoalCard(model: card) { [weak self] task in self?.toggleDone(task) }
            }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
            #if targetEnvironment(macCatalyst)
            MacHover.ownsHover(cell) { _ in }   // GoalCard paints its own rounded card hover via hqPointerFill
            #endif
            cell.accessibilityIdentifier = "goal-cell-\(card.title)"
        }
        let newGoalCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, _ in
            cell.contentConfiguration = UIHostingConfiguration { GoalNewRow() }.margins(.all, 0)
            cell.configurationUpdateHandler = { cell, state in Self.rowBackground(cell as! UICollectionViewListCell, state) }
        }
        let goalsEmptyCell = UICollectionView.CellRegistration<SoftCardListCell, Item> { [weak self] cell, _, _ in
            let enabled = !(self?.store.readOnlyGateway ?? true)
            cell.contentConfiguration = UIHostingConfiguration {
                GoalsEmptyRow(enabled: enabled) { [weak self] in self?.newGoal() }
            }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        // [goals] Step 2: Today's Goals shelf (its heading and its row of cards, one cell).
        let shelfCell = UICollectionView.CellRegistration<SoftCardListCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.contentConfiguration = UIHostingConfiguration {
                GoalShelfView(cards: self.shelfCards, folded: GoalShelfFold.folded,
                              toggle: { [weak self] in self?.toggleShelf() },
                              open: { [weak self] id in PagesHaptics.selection(); self?.openGoal(id) },
                              all: { [weak self] in PagesHaptics.selection(); self?.show(.goals) },
                              look: GoalTeamLook(bots: self.bots))
            }
            .margins(.all, 0)
            // Folded, the line is shorter than a list row's least height: without this the row kept that height and
            // centred "Goals 3" in it, so the heading dropped 6 pt as the cards folded away.
            .minSize(height: 0)
            cell.backgroundConfiguration = .clear()
            cell.accessibilityIdentifier = "goals.shelf.cell"
        }
        let skeletonCell = UICollectionView.CellRegistration<SoftCardListCell, Int> { cell, _, _ in
            cell.contentConfiguration = UIHostingConfiguration { PageSkeletonRow() }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        let overviewSmartCell = UICollectionView.CellRegistration<SoftCardListCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.contentConfiguration = UIHostingConfiguration {
                TasksSmartGridView(tiles: self.overviewSmart) { [weak self] view in self?.show(view) }
            }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        let overviewSuggestedCell = UICollectionView.CellRegistration<SoftCardListCell, Item> { [weak self] cell, _, _ in
            guard let self, let suggested = self.overviewSuggested else { return }
            let enabled = !self.store.readOnlyGateway
            cell.contentConfiguration = UIHostingConfiguration {
                TasksOverviewSuggestedCard(
                    model: suggested,
                    open: self.ideaOpen,
                    enabled: enabled,
                    onToggle: { [weak self] id in self?.toggleOverviewIdea(id) },
                    onAdd: { [weak self] id, start in self?.addIdea(id, start: start) },
                    onDismiss: { [weak self] id in self?.dismissIdea(id) }
                )
            }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        let overviewListsCell = UICollectionView.CellRegistration<SoftCardListCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            let edits = !self.store.readOnlyGateway && self.store.sectionsSupported
            cell.contentConfiguration = UIHostingConfiguration {
                TasksOverviewListsCard(lists: self.overviewLists, editsLists: edits,
                                       onPick: { [weak self] id in self?.show(.list(id)) },
                                       actions: self.listActions)
            }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        let overviewAgentsCell = UICollectionView.CellRegistration<SoftCardListCell, Item> { [weak self] cell, _, _ in
            guard let self, let agents = self.overviewAgents else { return }
            cell.contentConfiguration = UIHostingConfiguration {
                TasksOverviewAgentsCard(agents: agents) { [weak self] view in self?.show(view) }
            }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader) { [weak self] header, _, path in
            guard let self, let section = self.dataSource.sectionIdentifier(for: path.section) else { return }
            self.configureHeader(header, section)
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { [weak self] cv, path, item in
            switch item {
            case .filters: return cv.dequeueConfiguredReusableCell(using: filtersCell, for: path, item: item)
            case .ideaHead: return cv.dequeueConfiguredReusableCell(using: ideaHeadCell, for: path, item: item)
            case .idea(let id): return cv.dequeueConfiguredReusableCell(using: ideaRowCell, for: path, item: id)
            case .ideaNote(let note): return cv.dequeueConfiguredReusableCell(using: ideaNoteCell, for: path, item: note)
            case .task(let id): return cv.dequeueConfiguredReusableCell(using: taskCell, for: path, item: id)
            case .skeleton(let n): return cv.dequeueConfiguredReusableCell(using: skeletonCell, for: path, item: n)
            case .week: return cv.dequeueConfiguredReusableCell(using: weekCell, for: path, item: item)
            case .viewEmpty(let text): return cv.dequeueConfiguredReusableCell(using: emptyCell, for: path, item: text)
            case .offer(let id): return cv.dequeueConfiguredReusableCell(using: offerCell, for: path, item: id)
            case .goalOffer(let id): return cv.dequeueConfiguredReusableCell(using: goalOfferCell, for: path, item: id)
            case .keeper(let text): return cv.dequeueConfiguredReusableCell(using: keeperCell, for: path, item: text)
            case .more(let id): return cv.dequeueConfiguredReusableCell(using: moreCell, for: path, item: id)
            case .goal(let id): return cv.dequeueConfiguredReusableCell(using: goalCell, for: path, item: id)
            case .newGoal: return cv.dequeueConfiguredReusableCell(using: newGoalCell, for: path, item: item)
            case .goalsEmpty: return cv.dequeueConfiguredReusableCell(using: goalsEmptyCell, for: path, item: item)
            case .shelf: return cv.dequeueConfiguredReusableCell(using: shelfCell, for: path, item: item)
            case .overviewSmart: return cv.dequeueConfiguredReusableCell(using: overviewSmartCell, for: path, item: item)
            case .overviewSuggested: return cv.dequeueConfiguredReusableCell(using: overviewSuggestedCell, for: path, item: item)
            case .overviewLists: return cv.dequeueConfiguredReusableCell(using: overviewListsCell, for: path, item: item)
            case .overviewAgents: return cv.dequeueConfiguredReusableCell(using: overviewAgentsCell, for: path, item: item)
            }
        }
        dataSource.supplementaryViewProvider = { cv, _, path in cv.dequeueConfiguredReusableSupplementary(using: header, for: path) }
    }

    // MARK: [soft-cards] A card's foot under its last task

    /// Owner 2026-11-13 ("Get them all perfect"): a group's name stands 18 pt under its card's top, and its last task
    /// left 21 pt under it when it was one line (its circle, centred in the row) and 15 pt when its words ran to a
    /// second line or a note. The card takes 3 pt off under the one and adds 3 pt under the other, by the row's own
    /// measured height (a one-line row is shorter than any two lines of words can be).
    private var rowHeights: [String: CGFloat] = [:]
    private var footPending = false

    /// A one-line row is its circle's 36 pt and 8 pt over and under: 52 pt at every UI Scale. A second line or a note adds a line of words to that (a note under a one-line name: 56 pt).
    private static func isOneLine(_ height: CGFloat) -> Bool {
        // The circle grows with the iPhone's text size (22 pt at the standard size), and the row with it.
        let circle = UIFontMetrics(forTextStyle: .callout).scaledValue(for: 22)
        return height < 52 + max(0, circle - 22) + 1.5
    }

    private func lastTask(_ section: Int) -> String? {
        let count = collectionView.numberOfItems(inSection: section)
        guard count > 0, case .task(let id)? = dataSource?.itemIdentifier(for: IndexPath(item: count - 1, section: section)) else { return nil }
        return id
    }

    fileprivate func footRoom(_ section: Int) -> CGFloat {
        guard let id = lastTask(section), let height = rowHeights[id] else { return 0 }
        return Self.isOneLine(height) ? -3 : 3
    }

    /// A task's row was measured: when that changes what its card's foot should be, the list lays out again.
    private func measured(_ id: String, _ height: CGFloat) {
        let before = rowHeights[id]
        guard before.map({ abs($0 - height) > 0.5 }) ?? true else { return }
        rowHeights[id] = height
        guard before.map(Self.isOneLine) != Self.isOneLine(height), !footPending, BackdropCards.on(self) else { return }
        footPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.footPending = false
            self.collectionView.collectionViewLayout.invalidateLayout()
        }
    }

    private func hasHeader(_ section: Section) -> Bool {
        if section == .overviewSuggested || section == .overviewLists || section == .overviewAgents { return true }
        if case .goals(let key) = section { return key != .active }   // [goals] Someday, Achieved, Let Go
        guard case .group(let kind) = section else { return false }
        return heading(kind) != nil
    }

    /// A group's heading; none over a list's or Inbox's open tasks, or while searching (one flat list of matches).
    private func heading(_ kind: TodoGroupKind) -> (title: String, detail: String?)? {
        if kind == .open { return searching ? ("To Do", nil) : nil }
        if kind == .done, current == .today, !searching { return ("Done Today", nil) }   // [task-lists] one folded line
        return TodoViews.heading(kind, now: Date(), sections: store.sections, botName: { [bots] in PagesNames.botName($0 ?? "default", bots: bots) })
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private func configureHeader(_ header: UICollectionViewListCell, _ section: Section) {
        if section == .overviewSuggested {
            let count = overviewSuggested?.totalCount ?? 0
            header.contentConfiguration = UIHostingConfiguration {
                TasksOverviewSuggestedHeader(count: count) { [weak self] in self?.show(.suggested) }
            }.margins(.all, 0)
            header.backgroundConfiguration = .clear()
            header.accessibilityIdentifier = "tasks.section.Suggested"
            return
        }
        if section == .overviewLists {
            let edits = !store.readOnlyGateway && store.sectionsSupported && !overviewLists.isEmpty
            header.contentConfiguration = UIHostingConfiguration {
                TasksOverviewSectionHeader(title: "My Lists",
                                           actionTitle: edits ? "New List" : nil,
                                           actionIdentifier: "tasks.view.new-list",
                                           action: edits ? { [weak self] in self?.promptNewList(moving: []) } : nil)
            }.margins(.all, 0)
            header.backgroundConfiguration = .clear()
            header.accessibilityIdentifier = "tasks.section.My Lists"
            return
        }
        if section == .overviewAgents {
            header.contentConfiguration = UIHostingConfiguration {
                TasksOverviewSectionHeader(title: "Agents")
            }.margins(.all, 0)
            header.backgroundConfiguration = .clear()
            header.accessibilityIdentifier = "tasks.section.Agents"
            return
        }
        if case .goals(let key) = section { configureGoalHeader(header, key); return }
        guard case .group(let kind) = section, let words = heading(kind) else { return }
        let count = groups.first { $0.0 == kind }?.1.count ?? 0
        var view = TodoGroupHeaderView(title: words.title, detail: words.detail, count: count)
        view.onCard = BackdropCards.on(self)
        switch kind {
        case .overdue:
            if !store.readOnlyGateway, !selecting {
                view.reschedule = (
                    today: { [weak self] in self?.rescheduleOverdue(to: Date(), hasTime: false) },
                    tomorrow: { [weak self] in self?.rescheduleOverdue(to: Calendar.current.date(byAdding: .day, value: 1, to: Date()), hasTime: false) },
                    nextWeek: { [weak self] in self?.rescheduleOverdue(to: Calendar.current.date(byAdding: .day, value: 7, to: Date()), hasTime: false) },
                    pick: { [weak self] in self?.pickRescheduleOverdue() }
                )
            }
        case .bot(let profile):
            view.face = (profile, bots.first { $0.id == profile }?.head)
        case .stale:
            view.note = TodoWords.staleNote
        case .done:
            if !searching { view.fold = (doneOpen ? "Hide" : "Show", { [weak self] in self?.toggleDoneSection() }) }
        default: break
        }
        header.contentConfiguration = UIHostingConfiguration { view }.margins(.all, 0)
        header.backgroundConfiguration = .clear()
        header.accessibilityIdentifier = "tasks.section.\(words.title)"
    }

    // MARK: Reload

    private var reloadPending = false

    private func setNeedsReload() {
        guard isViewLoaded, !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadPending = false
            self.reload(animated: self.view.window != nil)
        }
    }

    func reload(animated: Bool) {
        guard isViewLoaded else { return }
        let now = Date()
        let scoped = isOverviewRoot && !searching ? PagesScope.all : scope.effective(bots: bots)
        let all = store.tasks
        let activePriority = !isOverviewRoot && store.fieldsSupported ? priorityFilter : nil
        let activeTag = !isOverviewRoot && store.fieldsSupported ? tagFilter : nil
        let visible = TodoSections.filtered(all, scope: scoped, query: query, goals: store.goals, priority: activePriority, tag: activeTag)
        let heads = Dictionary(bots.map { ($0.id, $0.head) }, uniquingKeysWith: { first, _ in first })
        let listShown = store.hasList && !store.needsAddOn
        let showingOverview = isOverviewRoot && !searching
        if !showingOverview { settleView(tasks: all) }
        // Build Grouped Overview / Mac Sidebar models from the currently scoped tasks.
        let navTasks = isOverviewRoot ? all : TodoSections.filtered(all, scope: scoped, query: "", goals: store.goals, priority: activePriority, tag: activeTag)
        let previousSmart = overviewSmart
        let previousSuggested = overviewSuggested
        let previousLists = overviewLists
        let previousAgents = overviewAgents
        buildNavigationModels(navTasks, allTasks: all, now: now)

        // A search looks through every view: what's open, then what's done.
        var made: [TodoGroup]
        if showingOverview {
            made = []
        } else if searching {
            let open = visible.filter { !$0.isDone }, done = visible.filter(\.isDone)
            made = [TodoGroup(kind: .open, tasks: TodoSections.ordered(open, sort: "due")),
                    TodoGroup(kind: .done, tasks: TodoSections.sorted(done, in: .done))].filter { !$0.tasks.isEmpty }
        } else {
            made = TodoViews.groups(visible, view: current, sections: store.sections, bots: bots.map(\.id), now: now,
                                    sort: store.settings.sort, paused: GoalViews.paused(store.goals))
        }
        // Upcoming's week: its dots from every coming day (and today's own tasks), then the picked day alone.
        if !showingOverview && current == .upcoming && !searching {
            week = weekDays(made, visible: visible, now: now)
        } else {
            week = []
            weekTitle = ""
        }
        if pickedDay != nil, !week.contains(where: { $0.key == pickedDay }) { pickedDay = nil }   // another view, or the day has passed
        if !showingOverview, let pickedDay {
            made = TodoViews.dayGroups(visible, day: pickedDay, sections: store.sections, bots: bots.map(\.id), now: now,
                                       sort: store.settings.sort)
        }
        groups = made.map { ($0.kind, $0.tasks.map(\.id)) }
        mores = [:]
        for group in made where group.more > 0 { if case .next(let id) = group.kind { mores[id] = group.more } }
        // [task-lists] The offers that wait, above everything in Today, Inbox, Overview, and in the list they are for.
        let name: (String?) -> String = { [bots] in PagesNames.botName($0 ?? "default", bots: bots) }
        let offersHere: (TodoOffer) -> Bool = { [current] offer in
            if showingOverview { return true }
            switch current {
            case .today, .inbox: return true
            case .list(let id): return offer.section == id || self.store.sections.first { $0.id == id }?.name.caseInsensitiveCompare(offer.list) == .orderedSame
            default: return false
            }
        }
        let waiting = store.listsSupported && !searching && !selecting ? TodoLists.waiting(store.offers).filter(offersHere) : []
        let previousOffers = offerCards
        offerCards = Dictionary(waiting.map { offer in
            (offer.id, TaskOfferCardModel(offer: offer, title: TodoLists.offerTitle(offer, botName: name),
                                          buttons: TodoLists.offerButtons(offer), busy: answering.contains(offer.id),
                                          color: TodoLists.color(store.sections.first { $0.id == offer.section })))
        }, uniquingKeysWith: { first, _ in first })
        // [goals step 3] One goal offer at the top of Today (the oldest first), under the list offers; one answered here
        // stays only while its answer is on the way, then leaves (its Undo moves to a notice; owner 2026-11-23).
        let previousGoalOffers = goalOfferCards
        var goalOffer: TodoOffer?
        if !showingOverview, current == .today, store.goalBotsSupported, !searching, !selecting {
            if let kept = goalOfferKept, let offer = store.offers.first(where: { $0.id == kept }) ?? TodoOfferStates.live(kept).offer,
               !offer.isWaiting || answering.contains(kept) {
                goalOffer = offer
            } else {
                goalOfferKept = nil
                goalOffer = GoalOffers.today(store.offers, goals: store.goals)
            }
        }
        goalOfferCards = goalOffer.map { [$0.id: goalOfferCard($0)] } ?? [:]
        var nextRows: [String: TodoRowModel] = [:]
        // A task ticked here stays where it was until it moves (a moment later), so the tick shows first.
        for group in made {
            // [tasks-calm] No face at a row's end any more (it leads the bot's line), so the times stand in one column.
            for task in group.tasks {
                nextRows[task.id] = rowModel(task, kind: group.kind, now: now, heads: heads)
            }
        }

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if !store.hasList && store.loading && skeletonShown {
            snapshot.appendSections([.skeleton])
            snapshot.appendItems((0..<8).map { .skeleton($0) }, toSection: .skeleton)
        }
        var ideasShown = false
        var goalsFound = false
        if listShown && showingOverview {
            shelfCards = []
            goalCards = [:]
            goalGroups = []
            ideaCards = [:]
            if store.ideasCount != nil, ideas.page?.on == true, !ideas.shown.isEmpty {
                let top = Array(ideas.shown.prefix(TasksNavigationLayout.overviewSuggestedLimit))
                let cards = top.map { idea in
                    TaskIdeaCardModel(idea: idea, botName: botName(idea.bot), head: heads[idea.bot] ?? nil,
                                      busy: addingIdeas.contains(idea.id))
                }
                if let open = openIdea, !cards.contains(where: { $0.idea.id == open }) { openIdea = nil }
                overviewSuggested = TasksOverviewSuggestedModel(cards: cards, totalCount: ideas.shown.count)
            } else {
                overviewSuggested = nil
                openIdea = nil
            }
            if !waiting.isEmpty {
                snapshot.appendSections([.offers])
                snapshot.appendItems(waiting.map { .offer($0.id) }, toSection: .offers)
            }
            snapshot.appendSections([.overviewSmart])
            snapshot.appendItems([.overviewSmart], toSection: .overviewSmart)
            if overviewSuggested != nil {
                snapshot.appendSections([.overviewSuggested])
                snapshot.appendItems([.overviewSuggested], toSection: .overviewSuggested)
            }
            snapshot.appendSections([.overviewLists])
            snapshot.appendItems([.overviewLists], toSection: .overviewLists)
            if let agents = overviewAgents, !agents.isEmpty {
                snapshot.appendSections([.overviewAgents])
                snapshot.appendItems([.overviewAgents], toSection: .overviewAgents)
            }
            if all.isEmpty && store.sections.isEmpty {
                snapshot.appendSections([.empty])
                snapshot.appendItems([.ideaNote(.noTasks(text: Self.nothingText(scope: PagesScope.all, botName: ""), imports: true))], toSection: .empty)
            }
        } else if listShown {
            overviewSuggested = nil
            if (activePriority != nil || activeTag != nil), !searching {
                snapshot.appendSections([.filters])
                snapshot.appendItems([.filters], toSection: .filters)
            }
            if !waiting.isEmpty || goalOffer != nil {
                snapshot.appendSections([.offers])
                snapshot.appendItems(waiting.map { .offer($0.id) } + (goalOffer.map { [.goalOffer($0.id)] } ?? []), toSection: .offers)
            }
            // [goals] Step 2: the Goals shelf (its active goals, your order) leads Today; [goals step 3] a waiting offer (a
            // list's, then one goal's, as the check-in on board 4) stands over it.
            if GoalShelf.shows(view: current, searching: searching, scope: scoped, goalsSupported: store.goalsSupported, goals: store.goals) {
                shelfCards = GoalShelf.cards(store.goals, tasks: all, now: now, bots: store.goalBotsSupported, offers: store.offers,
                                             keptHere: GoalKeptHere.all)
                snapshot.appendSections([.shelf])
                snapshot.appendItems([.shelf], toSection: .shelf)
            } else {
                shelfCards = []
            }
            // A list a bot keeps says so in one quiet line, in words (a face on a row means the bot is on that task).
            if !searching, let id = currentList, let list = store.sections.first(where: { $0.id == id }),
               let line = TodoLists.keeperLine(list, now: now, botName: name) {
                snapshot.appendSections([.keeper])
                snapshot.appendItems([.keeper(line)], toSection: .keeper)
            }
            if !week.isEmpty {
                snapshot.appendSections([.week])
                snapshot.appendItems([.week], toSection: .week)
            }
            // [goals] Step 2: a search's Goals group first (the Goals view's cards, any status), then To Do and Done.
            goalsFound = searching && appendFoundGoals(to: &snapshot, now: now, scope: scoped)
            let open = doneOpen || searching
            for (kind, ids) in groups {
                snapshot.appendSections([.group(kind)])
                if kind != .done || open { snapshot.appendItems(ids.map { .task($0) }, toSection: .group(kind)) }
                if case .next(let id) = kind, mores[id] != nil { snapshot.appendItems([.more(id)], toSection: .group(kind)) }
            }
            // [goals] The Goals view: its cards, not tasks.
            // [goals-addon] Not on an add-on without goals: its Goals view is the update state alone.
            let goalsShown = current == .goals && !searching && store.goalsSupported
            if goalsShown { appendGoals(to: &snapshot, now: now) } else if !goalsFound { goalCards = [:]; goalGroups = [] }
            // No tasks at all: every task view says so, with New Task.
            // [goals-addon] Goals on an add-on without them: the update state alone (updateEmptyState), no task lines.
            let ideasView = current == .suggested && !searching
            let goalsLocked = current == .goals && !searching && !store.goalsSupported
            let nothing = groups.isEmpty && !searching && !goalsShown && !goalsLocked && !ideasView
            if nothing, all.isEmpty {
                snapshot.appendSections([.empty])
                snapshot.appendItems([.ideaNote(.noTasks(text: Self.nothingText(scope: PagesScope.all, botName: ""), imports: true))], toSection: .empty)
            }
            if ideasView, !selecting {
                ideasShown = appendIdeas(to: &snapshot, scope: scoped, heads: heads)
            } else {
                ideaCards = [:]
            }
            // A view with nothing in it says so in one line.
            if (nothing && !all.isEmpty && !ideasShown) || (ideasView && ideas.page != nil && !ideasShown) {
                snapshot.appendSections([.empty])
                snapshot.appendItems([.viewEmpty(emptyText(scope: scoped))], toSection: .empty)
            }
        }
        let previousIdeaCards = shownIdeaCards
        shownIdeaCards = ideaCards
        let previousGoalCards = shownGoalCards
        shownGoalCards = goalCards
        let previousShelf = shownShelfCards
        shownShelfCards = shelfCards
        var changed = snapshot.itemIdentifiers.compactMap { item -> Item? in
            guard case .task(let id) = item, let old = rows[id], old != nextRows[id] else { return nil }
            return item
        }
        rows = nextRows
        // The week's dots, who looks (and when), overview cards, and each idea's card follow every read.
        changed += snapshot.itemIdentifiers.filter { item in
            switch item {
            case .filters, .week, .ideaHead, .more: return true
            case .overviewSmart: return previousSmart != overviewSmart
            case .overviewSuggested: return previousSuggested != overviewSuggested
            case .overviewLists: return previousLists != overviewLists
            case .overviewAgents: return previousAgents != overviewAgents
            case .offer(let id): return previousOffers[id] != nil && previousOffers[id] != offerCards[id]
            case .goalOffer(let id): return previousGoalOffers[id] != nil && previousGoalOffers[id] != goalOfferCards[id]
            case .idea(let id): return previousIdeaCards[id] != nil && previousIdeaCards[id] != ideaCards[id]
            case .goal(let id): return previousGoalCards[id] != nil && previousGoalCards[id] != goalCards[id]
            case .shelf: return !previousShelf.isEmpty && previousShelf != shelfCards
            default: return false
            }
        }
        if !changed.isEmpty { snapshot.reconfigureItems(changed) }
        dataSource.apply(snapshot, animatingDifferences: animated && !HQMotion.reduced)
        if paneKeepsSelection { markOnShow(onShowTask, keepsSelection: true) }   // [mac] #41
        notePaneListEmpty(!snapshot.itemIdentifiers.contains { taskID(of: $0) != nil })   // [mac] #57
        refreshHeaders()
        addItem.isEnabled = !store.readOnlyGateway && !store.needsAddOn
        addItem.accessibilityLabel = !showingOverview && current == .goals ? (store.goalsNeedAddOn ? "Update Add-on" : "New Goal") : "New Task"   // [goals] the bar's + makes a goal there
        if !isOverviewRoot && !DeviceWord.isMac {
            let wanted = TasksNavigationLayout.title(for: current, sections: store.sections)
            if title != wanted { title = wanted }
        }
        if DeviceWord.isMac {
            sidebar.update(smart: overviewSmart, lists: overviewLists, agents: overviewAgents, picked: current,
                           editsLists: !store.readOnlyGateway && store.sectionsSupported)
            layoutSidebarAndContent()
            updateMacLeadingBar()
        }
        if selecting {
            updateSelectionBar()
        } else if isOverviewRoot {
            let items = [addItem, searchCapsule?.searchItem, moreItem].compactMap { $0 }
            if navigationItem.rightBarButtonItems ?? [] != items { navigationItem.rightBarButtonItems = items }
        } else {
            // [Filter] [Search] [+], as Sessions: the bots, then Sort, Select, Import and Settings in Filter's menu. With
            // one bot there is nothing to filter, so they keep a ⋯ of their own.
            scopeItem.update(scope: scope, bots: bots, on: navigationItem, extra: [addItem], search: searchCapsule?.searchItem,
                             menuExtra: UIDeferredMenuElement.uncached { [weak self] done in
                                 MainActor.assumeIsolated { done(self?.menuItems() ?? []) }
                             }, alone: moreItem, me: true)
        }
        // [Mac AAA 2026-11-16] Waiting on an add-on update the page shows that one state and no list: nothing to filter,
        // search, sort, select or import, so the bar's Filter (or ⋯) and Search dim with + and the state's own Update
        // Add-on is the one thing to press. They come back with the list.
        let live = !store.needsAddOn
        scopeItem.isEnabled = live
        moreItem.isEnabled = live
        searchCapsule?.searchItem?.isEnabled = live
        updateEmptyState(matches: showingOverview || !groups.isEmpty || goalsFound)
        scheduleSkeleton()
        if let started = refreshStarted, !store.loading {
            let wait = max(0, 0.5 - Date().timeIntervalSince(started))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.refreshStarted = nil
                self?.collectionView.refreshControl?.endRefreshing()
            }
        }
    }

    // MARK: Views

    /// A list that was deleted, or Bots once no bot has a task of its own: pops back to Overview on iPhone, else Today.
    private func settleView(tasks: [TodoTask]) {
        guard store.hasList else { return }
        var gone = false
        switch current {
        case .list(let id) where !store.sections.contains { $0.id == id }: gone = true
        case .suggested where store.ideasCount == nil: gone = true
        case .bots where !TodoViews.showsBots(tasks): gone = true
        case .goals where !store.goalsSupported && !store.goalsNeedAddOn: gone = true
        default: break
        }
        guard gone else { return }
        if pinnedView != nil, let nav = navigationController, nav.topViewController === self {
            nav.popViewController(animated: true)
            return
        }
        current = .today
    }

    /// Opens a view: pushes onto the navigation stack from the iPhone Grouped Overview, or switches in-place on Mac / pushed view.
    func show(_ view: TodoView) {
        if isOverviewRoot {
            if let top = navigationController?.topViewController as? TasksViewController, top !== self {
                top.show(view)
                return
            }
            let child = TasksViewController(store: store, context: context, pinnedView: view)
            navigationController?.pushViewController(child, animated: self.view.window != nil)
            return
        }
        guard view != current else {
            // The active view again: back to the top (and Upcoming to every day again).
            if pickedDay != nil || weekOffset != 0 { pickedDay = nil; weekOffset = 0; if isViewLoaded { reload(animated: false) } }
            if isViewLoaded { collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: true) }
            return
        }
        current = view
        pickedDay = nil
        weekOffset = 0
        openIdea = nil
        goalOfferKept = nil
        if !DeviceWord.isMac { title = TasksNavigationLayout.title(for: current, sections: store.sections) }
        guard isViewLoaded else { return }
        if view == .suggested { readIdeas() }
        reload(animated: false)
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
    }

    /// Builds the three cleanly separated groups for both the iPhone Grouped Overview and the Mac Sidebar:
    /// Smart Views (Today, Upcoming, Inbox, Goals), My Lists, and Agents (Suggested + Bots' own tasks).
    private func buildNavigationModels(_ scopedTasks: [TodoTask], allTasks: [TodoTask], now: Date) {
        func count(_ view: TodoView) -> Int { TodoViews.openCount(scopedTasks, view: view, sections: store.sections, now: now) }
        var smart: [TasksSmartTileModel] = [
            TasksSmartTileModel(view: .today, title: "Today", symbol: "sun.max", count: count(.today)),
            TasksSmartTileModel(view: .upcoming, title: "Upcoming", symbol: "calendar", count: count(.upcoming)),
            TasksSmartTileModel(view: .inbox, title: "Inbox", symbol: "tray", count: count(.inbox)),
        ]
        if store.goalsSupported {
            smart.append(TasksSmartTileModel(view: .goals, title: "Goals", symbol: "smallcircle.filled.circle", count: GoalViews.activeCount(store.goals)))
        } else if store.goalsNeedAddOn {
            smart.append(TasksSmartTileModel(view: .goals, title: "Goals", symbol: "smallcircle.filled.circle", count: nil))
        }
        overviewSmart = smart

        let total = store.sections.count
        overviewLists = store.sections.enumerated().map { idx, list in
            let sub = list.bot.map { "Kept by \(botName($0))" }
            return TasksOverviewListModel(
                id: list.id,
                name: list.name,
                icon: list.icon ?? TodoListIcons.fallback,
                color: TodoLists.color(list),
                subtitle: sub,
                count: count(.list(list.id)),
                index: idx,
                total: total
            )
        }

        let suggestedRow: TasksOverviewSuggestedRowModel? = store.ideasCount.map { fallbackCount in
            let isOn = ideas.page?.on ?? (fallbackCount > 0 || store.settings.ideas == true)
            let looking = ideas.page?.looking ?? false
            let liveCount = ideas.page.map { $0.on ? ideas.shown.count : 0 } ?? fallbackCount
            return TasksOverviewSuggestedRowModel(count: liveCount, isOn: isOn, looking: looking)
        }
        let botsCount: Int? = TodoViews.showsBots(allTasks) ? count(.bots) : nil
        let agents = TasksOverviewAgentsModel(suggested: suggestedRow, botsCount: botsCount)
        overviewAgents = agents.isEmpty ? nil : agents
    }

    private func listName(_ id: String?) -> String? { id.flatMap { id in store.sections.first { $0.id == id }?.name } }

    /// The list on show, when the view is one.
    private var currentList: String? {
        guard !isOverviewRoot else { return nil }
        if case .list(let id) = current { return id }
        return nil
    }

    private func emptyText(scope scoped: String) -> String {
        if let pickedDay { return TodoViews.dayEmptyText(pickedDay, now: Date()) }
        let text = TodoViews.emptyText(current, listName: listName(currentList))
        guard scoped != PagesScope.all else { return text }
        return scoped == PagesScope.me ? "Nothing of your own here." : "Nothing with \(botName(scoped)) here."
    }

    /// Seven days starting at `today + weekOffset * 7`; a day with tasks carries a dot. A tap on a day shows that day alone.
    private func weekDays(_ made: [TodoGroup], visible: [TodoTask], now: Date) -> [TodoWeekStrip.Day] {
        let calendar = Calendar.current
        var busy = Set(made.compactMap { group -> String? in if case .day(let key) = group.kind { return key } else { return nil } })
        // Today's own tasks aren't "coming up", but its day on the strip still says it has some.
        let todayStart = calendar.startOfDay(for: now)
        let todayKey = TodoViews.dayKey(todayStart, calendar: calendar)
        if !TodoViews.dayGroups(visible, day: todayKey, sections: store.sections, bots: bots.map(\.id), now: now).isEmpty { busy.insert(todayKey) }
        let start = calendar.date(byAdding: .day, value: weekOffset * 7, to: todayStart) ?? todayStart
        let dates = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        weekTitle = TodoViews.weekRangeTitle(dates, calendar: calendar)
        return dates.map { date in
            let key = TodoViews.dayKey(date, calendar: calendar)
            return TodoWeekStrip.Day(key: key, weekday: TodoDates.format(date, template: "EEE", calendar: calendar),
                                     number: "\(calendar.component(.day, from: date))",
                                     today: key == todayKey, busy: busy.contains(key), picked: key == pickedDay)
        }
    }

    private func stepWeek(_ delta: Int) {
        let next = max(0, min(52, weekOffset + delta))
        guard next != weekOffset else { return }
        PagesHaptics.selection()
        weekOffset = next
        pickedDay = nil
        reload(animated: false)
    }

    private func jumpToThisWeek() {
        PagesHaptics.selection()
        weekOffset = 0
        pickedDay = nil
        reload(animated: false)
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: true)
    }

    @discardableResult
    private func rescheduleDroppedTask(_ taskID: String, onto dayKey: String) -> Bool {
        guard !store.readOnlyGateway, let task = store.task(taskID), !task.isDone,
              let day = TodoDates.day(dayKey) else { return false }
        PagesHaptics.success()
        let heading = TodoViews.dayHeading(dayKey, now: Date())
        let label = heading.detail ?? heading.title
        Task {
            if await store.reschedule([taskID], to: day, preserveTime: true) {
                notices.show("Scheduled for \(label)")
            } else {
                PagesHaptics.error()
            }
        }
        return true
    }

    /// A day on the week: the list holds that day alone (every day answers, with tasks or without; the days with
    /// none did nothing, owner 2026-11-12: "The calendar dates aren't clickable"). The picked day again, or the
    /// Upcoming pill, shows every coming day. New Task starts on the picked day.
    private func goToDay(_ key: String) {
        PagesHaptics.selection()
        pickedDay = pickedDay == key ? nil : key
        reload(animated: false)
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
    }

    /// The day a new task is due as it opens: today on Today, the picked day on Upcoming, none elsewhere.
    private var newTaskDay: Date? {
        guard !isOverviewRoot else { return nil }
        if TodoViews.startsToday(current) { return Date() }
        return pickedDay.flatMap { TodoDates.day($0) }
    }

    private func rowModel(_ task: TodoTask, kind: TodoGroupKind, now: Date, heads: [String: JSONValue?]) -> TodoRowModel {
        let helper = task.helper
        let name: (String?) -> String = { [bots] in PagesNames.botName($0 ?? "default", bots: bots) }
        // [task-lists] Its list's icon, where the row isn't under that list's own name.
        var mark = TodoLists.mark(task, in: searching ? .today : current, sections: store.sections)
        if case .next = kind { mark = nil }   // "Next in Work" names the list over the rows
        var model = TodoRowModel.make(task, kind: kind, now: now, botName: name, head: helper.flatMap { heads[$0] ?? nil },
                                      ticking: ticking.contains(task.id), listIcon: mark, listName: mark == nil ? nil : listName(task.section),
                                      wide: isTable)
        // [goals] Step 2: a task in an active or paused goal carries the goal's mark in the icon's place, in every view
        // (inside a list and under "Next in" too, where no icon is drawn).
        if let goal = GoalViews.markGoal(task, goals: store.goals) {
            model.goalMark = true
            model.goalName = goal.title.isEmpty ? "Untitled Goal" : goal.title
            model.listIcon = nil
        }
        model.selecting = selecting
        model.picked = picked.contains(task.id)
        return model
    }

    private func refreshHeaders() {
        for path in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: UICollectionView.elementKindSectionHeader) {
            guard let header = collectionView.supplementaryView(forElementKind: UICollectionView.elementKindSectionHeader, at: path)
                    as? UICollectionViewListCell,
                  let section = dataSource.sectionIdentifier(for: path.section) else { continue }
            configureHeader(header, section)
        }
    }

    /// The page's own states: the add-on to update, a search with no match, a list that couldn't be read. A view with
    /// nothing in it says so in the list itself, under the views.
    private func updateEmptyState(matches: Bool) {
        if store.needsAddOn {
            var state = PageStates.empty(symbol: "puzzlepiece.extension", title: "Update the Add-on",
                                         text: "Tasks needs \(AddOnUpdate.pushName) 0.9.32 or later on \(HostWord.phrase).")   // Mac polish #139
            var button = UIButton.Configuration.hqMacPush(or: .hqFilled(), capsule: true)
            button.title = updateAsked ? "Updating…" : "Update Add-on"
            state.button = button
            state.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.updateAddOn() }
            showEmpty(state)
        } else if current == .goals, !searching, store.goalsNeedAddOn {
            // [goals-addon] Goals is there, and the add-on on the computer is from before it.
            var state = PageStates.empty(symbol: "flag", title: "Goals Need a Newer Add-on",
                                         text: "Update \(AddOnUpdate.pushName) on \(HostWord.phrase) to set goals, milestones and the tasks under them.")
            var button = UIButton.Configuration.hqMacPush(or: .hqFilled(), capsule: true)
            button.title = updateAsked ? "Updating…" : "Update Add-on"
            state.button = button
            state.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.updateAddOn() }
            showEmpty(state)
        } else if searching, !matches, store.hasList {
            showEmpty(PageStates.searchMiss(query.trimmingCharacters(in: .whitespaces)))
        } else if !store.hasList, !store.loading, let reason = store.error {
            showEmpty(PageStates.error(title: "Couldn’t Load Tasks", reason: reason) { [weak self] in
                Task { await self?.store.refresh(force: true) }
            })
        } else {
            showEmpty(nil)
        }
        hqPlaceMacEmptyTitle()
    }

    /// What the page says with no tasks at all (or, in the bar's Filter, none with one bot or of your own).
    static func nothingText(scope: String, botName: String) -> String {
        if scope == PagesScope.all { return "Add what you need to do. Bots add tasks from your chats too, and get their part ready for you." }
        return scope == PagesScope.me ? "Nothing of your own yet." : "Nothing with \(botName) yet."
    }

    /// The empty state. Beside the Mac sidebar it sits in the list's own background so it never covers the sidebar.
    private func showEmpty(_ state: (any UIContentConfiguration)?) {
        let state = BackdropState.wrap(state)   // [backdrop-cards] a soft card behind it on Soft Cards
        guard showsSidebar else {
            if collectionView.backgroundView != nil { collectionView.backgroundView = nil }
            contentUnavailableConfiguration = state
            return
        }
        if contentUnavailableConfiguration != nil { contentUnavailableConfiguration = nil }
        guard let state else {
            if collectionView.backgroundView != nil { collectionView.backgroundView = nil }
            return
        }
        // The same kind of state again keeps its view (a button in it is not swapped out under a finger).
        if let shown = collectionView.backgroundView as? (any UIView & UIContentView), shown.supports(state) {
            shown.configuration = state
        } else {
            collectionView.backgroundView = state.makeContentView()
        }
    }

    private func scheduleSkeleton() {
        guard !store.hasList, store.loading, !skeletonShown, skeletonWork == nil else {
            if store.hasList || !store.loading { skeletonWork?.cancel(); skeletonWork = nil; skeletonShown = false }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.skeletonWork = nil
            guard !self.store.hasList, self.store.loading else { return }
            self.skeletonShown = true
            self.reload(animated: false)
        }
        skeletonWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func toggleDoneSection() {
        doneOpen.toggle()
        PagesHaptics.selection()
        reload(animated: true)
    }

    /// "Due 5:00 PM" turns "Overdue" without a read.
    private func startMinuteClock() {
        minuteTimer?.invalidate()
        let now = Date()
        let next = Calendar.current.nextDate(after: now, matching: DateComponents(second: 0), matchingPolicy: .nextTime) ?? now.addingTimeInterval(60)
        let timer = Timer(fire: next, interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload(animated: false) }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
    }

    private func pulledToRefresh() {
        refreshStarted = Date()
        Task { await store.refresh(force: true) }
        if isOverviewRoot || current == .suggested || DeviceWord.isMac { Task { await ideas.refresh(force: true) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.refreshStarted = nil
            self?.collectionView.refreshControl?.endRefreshing()
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        searchCapsule?.updateSearchState()
        guard text != query else { return }
        query = text
        reload(animated: false)
    }

    // MARK: Actions

    private func menuItems() -> [UIMenuElement] {
        if isOverviewRoot {
            var out: [UIMenuElement] = []
            if !store.readOnlyGateway && store.sectionsSupported {
                out.append(UIMenu(options: .displayInline, children: [
                    UIAction(title: "New List…", image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in
                        self?.promptNewList(moving: [])
                    },
                ]))
            }
            out.append(UIMenu(options: .displayInline, children: [
                UIAction(title: "Completed Logbook…", image: UIImage(systemName: "book.closed")) { [weak self] _ in
                    self?.openLogbook()
                },
                UIAction(title: "Import from Reminders…", image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
                    self?.importReminders()
                },
            ]))
            out.append(UIAction(title: "Tasks Settings…", image: UIImage(systemName: "gearshape")) { [weak self] _ in self?.openSettings() })
            return out
        }
        var filters: [UIMenuElement] = []
        if store.fieldsSupported && current != .suggested && current != .goals {
            let priSubtitle = priorityFilter.map { TodoViews.priorityWord($0) }
            let priChoices: [(Int?, String)] = [(nil, "Any Priority"), (1, "High"), (2, "Medium"), (3, "Low")]
            filters.append(UIMenu(title: "Priority", subtitle: priSubtitle, image: UIImage(systemName: "flag"),
                                  options: .singleSelection, children: priChoices.map { level, title in
                UIAction(title: title, state: priorityFilter == level ? .on : .off) { [weak self] _ in
                    PagesHaptics.selection()
                    self?.priorityFilter = level
                    self?.reload(animated: true)
                }
            }))
            let tags = TodoViews.allTags(in: store.tasks)
            if !tags.isEmpty || tagFilter != nil {
                var tagActions = [UIAction(title: "All Tags", state: tagFilter == nil ? .on : .off) { [weak self] _ in
                    PagesHaptics.selection()
                    self?.tagFilter = nil
                    self?.reload(animated: true)
                }]
                tagActions += tags.map { tag in
                    UIAction(title: "#\(tag)", state: tagFilter?.caseInsensitiveCompare(tag) == .orderedSame ? .on : .off) { [weak self] _ in
                        PagesHaptics.selection()
                        self?.tagFilter = tag
                        self?.reload(animated: true)
                    }
                }
                filters.append(UIMenu(title: "Tag", subtitle: tagFilter.map { "#\($0)" }, image: UIImage(systemName: "tag"),
                                      options: .singleSelection, children: tagActions))
            }
        }
        var organize: [UIMenuElement] = []
        if currentList != nil || current == .today || current == .inbox {
            // A list is in your order until you say otherwise; Today & Inbox also accept Due/Priority/Added.
            let sort = store.settings.sort
            let defaultTitle = currentList != nil ? "My Order" : "Default"
            var sorts: [(String, String, String)] = [("smart", defaultTitle, "hand.draw"), ("due", "Due Date", "calendar"), ("added", "Date Added", "clock")]
            // [tasks-first] By priority, on an add-on that keeps one (0.9.53).
            if store.fieldsSupported || sort == "priority" { sorts.insert(("priority", "Priority", "flag"), at: 2) }
            organize.append(UIMenu(title: "Sort By", subtitle: sorts.first { $0.0 == sort }?.1, image: UIImage(systemName: "arrow.up.arrow.down"),
                                   options: .singleSelection, children: sorts.map { key, title, symbol in
                UIAction(title: title, image: UIImage(systemName: symbol), state: sort == key ? .on : .off) { [weak self] _ in
                    self?.setLayout(sort: key)
                }
            }))
        }
        if current != .suggested && current != .goals {
            organize.append(UIAction(title: "Select Tasks", image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in
                self?.setSelecting(true)
            })
        }
        organize.append(UIAction(title: "Completed Logbook…", image: UIImage(systemName: "book.closed")) { [weak self] _ in
            self?.openLogbook()
        })
        var out: [UIMenuElement] = []
        if !filters.isEmpty { out.append(UIMenu(options: .displayInline, children: filters)) }
        out.append(UIMenu(options: .displayInline, children: organize))
        if let listID = currentList, !store.readOnlyGateway && store.sectionsSupported {
            out.append(UIMenu(options: .displayInline, children: [
                UIAction(title: "Edit List…", image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in
                    self?.editList(listID)
                },
                UIAction(title: "Rename List…", image: UIImage(systemName: "pencil")) { [weak self] _ in
                    self?.renameList(listID)
                },
                UIAction(title: "Delete List…", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    self?.deleteList(listID)
                },
            ]))
        }
        out.append(UIMenu(options: .displayInline, children: [
            UIAction(title: "Import from Reminders…", image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
                self?.importReminders()
            },
        ]))
        out.append(UIAction(title: "Tasks Settings…", image: UIImage(systemName: "gearshape")) { [weak self] _ in self?.openSettings() })
        return out
    }

    private func openLogbook() {
        PagesHaptics.selection()
        present(TaskLogbookSheet.make(store: store, bots: bots) { [weak self] id in
            self?.openTask(id)
        }, animated: true)
    }

    private func rescheduleOverdue(to date: Date?, hasTime: Bool) {
        guard !store.readOnlyGateway, let date else { return }
        let ids = groups.first { $0.0 == .overdue }?.1 ?? []
        guard !ids.isEmpty else { return }
        PagesHaptics.selection()
        let label = TodoWords.day(date, now: Date())
        Task {
            if await store.reschedule(ids, to: date, hasTime: hasTime, preserveTime: !hasTime) {
                PagesHaptics.success()
                notices.show("Rescheduled \(ids.count) \(ids.count == 1 ? "task" : "tasks") to \(label)")
            } else {
                PagesHaptics.error()
            }
        }
    }

    private func pickRescheduleOverdue() {
        let ids = groups.first { $0.0 == .overdue }?.1 ?? []
        guard !ids.isEmpty else { return }
        PagesHaptics.selection()
        let picker = TodoDatePicker.make(date: Date(), hasTime: false, rings: true, title: "Reschedule Overdue") { [weak self] date, hasTime in
            self?.rescheduleOverdue(to: date, hasTime: hasTime)
        }
        present(picker, animated: true)
    }

    private func scheduleTasks(_ ids: [String], to date: Date?, hasTime: Bool = false, preserveTime: Bool = false, after: (() -> Void)? = nil) {
        guard !ids.isEmpty, !store.readOnlyGateway else { return }
        PagesHaptics.selection()
        Task {
            let ok = await store.reschedule(ids, to: date, hasTime: hasTime, preserveTime: preserveTime)
            if ok {
                PagesHaptics.success()
                if let date {
                    let label = TodoWords.day(date, now: Date())
                    notices.show(ids.count == 1 ? "Scheduled for \(label)" : "Scheduled \(ids.count) tasks for \(label)")
                } else {
                    notices.show(ids.count == 1 ? "Cleared due date" : "Cleared due dates")
                }
            } else {
                PagesHaptics.error()
            }
            after?()
        }
    }

    private func pickSchedule(for ids: [String], after: (() -> Void)? = nil) {
        guard !ids.isEmpty else { return }
        let existing = ids.count == 1 ? store.task(ids[0]).flatMap { TodoDates.due($0.due) } : nil
        PagesHaptics.selection()
        let picker = TodoDatePicker.make(date: existing?.date, hasTime: existing?.hasTime ?? false, rings: true) { [weak self] date, hasTime in
            self?.scheduleTasks(ids, to: date, hasTime: hasTime, preserveTime: false, after: after)
        }
        present(picker, animated: true)
    }

    private func scheduleChoices(for ids: [String], after: (() -> Void)? = nil) -> [UIMenuElement] {
        guard !ids.isEmpty else { return [] }
        let now = Date()
        var items: [UIMenuElement] = [
            UIAction(title: "Today", image: UIImage(systemName: "sun.max")) { [weak self] _ in
                self?.scheduleTasks(ids, to: now, preserveTime: true, after: after)
            },
            UIAction(title: "Tomorrow", image: UIImage(systemName: "sunrise")) { [weak self] _ in
                self?.scheduleTasks(ids, to: Calendar.current.date(byAdding: .day, value: 1, to: now), preserveTime: true, after: after)
            },
            UIAction(title: "Next Week", image: UIImage(systemName: "calendar")) { [weak self] _ in
                self?.scheduleTasks(ids, to: Calendar.current.date(byAdding: .day, value: 7, to: now), preserveTime: true, after: after)
            },
            UIAction(title: "Choose Date…", image: UIImage(systemName: "calendar.badge.plus")) { [weak self] _ in
                self?.pickSchedule(for: ids, after: after)
            },
        ]
        if ids.contains(where: { store.task($0)?.due != nil }) {
            items.append(UIAction(title: "No Date", image: UIImage(systemName: "calendar.badge.minus"), attributes: .destructive) { [weak self] _ in
                self?.scheduleTasks(ids, to: nil, after: after)
            })
        }
        return items
    }

    private func priorityChoices(for ids: [String], after: (() -> Void)? = nil) -> [UIMenuElement] {
        guard !ids.isEmpty, store.fieldsSupported else { return [] }
        let current = Set(ids.compactMap { store.task($0)?.priority })
        var items: [UIMenuElement] = [1, 2, 3].map { level in
            UIAction(title: TodoViews.priorityWord(level), image: UIImage(systemName: "flag.fill"), state: current == [level] ? .on : .off) { [weak self] _ in
                guard let self else { return }
                PagesHaptics.selection()
                Task {
                    if await !self.store.setPriority(ids, priority: level) { PagesHaptics.error() }
                    after?()
                }
            }
        }
        if current != [0] {
            items.append(UIAction(title: "No Priority", attributes: .destructive) { [weak self] _ in
                guard let self else { return }
                PagesHaptics.selection()
                Task {
                    if await !self.store.setPriority(ids, priority: 0) { PagesHaptics.error() }
                    after?()
                }
            })
        }
        return items
    }

    private func assignChoices(for task: TodoTask) -> [UIMenuElement] {
        let choices = PagesNames.scopeChoices(bots)
        guard !choices.isEmpty else { return [] }
        let justMe = UIAction(title: "Just Me", image: UIImage(systemName: "person"), state: task.whoKind == .me ? .on : .off) { [weak self] _ in
            self?.assignTask(task.id, who: .me, bot: nil)
        }
        let together = UIMenu(title: "With Me", children: choices.map { bot in
            UIAction(title: bot.name, state: task.whoKind == .together && task.helper == bot.id ? .on : .off) { [weak self] _ in
                self?.assignTask(task.id, who: .together, bot: bot.id)
            }
        })
        let solo = UIMenu(title: "By Itself", children: choices.map { bot in
            UIAction(title: bot.name, state: task.whoKind == .bot && task.helper == bot.id ? .on : .off) { [weak self] _ in
                self?.assignTask(task.id, who: .bot, bot: bot.id)
            }
        })
        return [justMe, together, solo]
    }

    private func assignTask(_ id: String, who: TodoWho, bot: String?) {
        guard !store.readOnlyGateway, let task = store.task(id) else { return }
        let helper = who == .me ? nil : (bot ?? "default")
        guard task.whoKind != who || task.helper != helper else { return }
        PagesHaptics.selection()
        var fields: [String: JSONValue] = ["who": .string(who.rawValue), "bot": helper.map(JSONValue.string) ?? .null]
        if who == .bot || (who == .together && !store.fieldsSupported) { fields["repeat"] = .null }
        if who == .me { fields["prep"] = .bool(false) }
        if let steps = TodoEdits.stepsForJustMe(who, steps: task.steps) { fields["steps"] = TodoWire.steps(steps) }
        let switchedBot = helper != nil && task.helper != helper
        let existingLink = TaskChatLinks.link(task, account: context.account)
        let replacingChat = switchedBot && existingLink != nil && existingLink?.profile != helper
        if replacingChat { fields["chat"] = .object([:]) }
        let asks = switchedBot && (existingLink == nil || replacingChat)
        let words = who == .together ? TodoWords.helpQuestion : TaskNow.startRequest
        Task {
            guard await store.patch(id, fields) else { PagesHaptics.error(); return }
            if replacingChat { TaskChatLinks.clear(task: id, account: context.account) }
            if asks { openTask(id, asking: words) }
        }
    }

    private func duplicateTask(_ id: String) {
        guard !store.readOnlyGateway else { notices.show(JobsStore.readOnlyNotice); return }
        PagesHaptics.selection()
        Task {
            if let copy = await store.duplicate(id) {
                PagesHaptics.success()
                notices.show("Duplicated “\(copy.title)”")
            } else {
                PagesHaptics.error()
            }
        }
    }

    private func showScheduleSheet(for id: String, source: UIView?) {
        guard !store.readOnlyGateway, let task = store.task(id) else { return }
        let sheet = UIAlertController(title: "Schedule “\(task.title)”", message: nil, preferredStyle: .actionSheet)
        let now = Date()
        sheet.addAction(UIAlertAction(title: "Today", style: .default) { [weak self] _ in
            self?.scheduleTasks([id], to: now, preserveTime: true)
        })
        sheet.addAction(UIAlertAction(title: "Tomorrow", style: .default) { [weak self] _ in
            self?.scheduleTasks([id], to: Calendar.current.date(byAdding: .day, value: 1, to: now), preserveTime: true)
        })
        sheet.addAction(UIAlertAction(title: "Next Week", style: .default) { [weak self] _ in
            self?.scheduleTasks([id], to: Calendar.current.date(byAdding: .day, value: 7, to: now), preserveTime: true)
        })
        sheet.addAction(UIAlertAction(title: "Choose Date…", style: .default) { [weak self] _ in
            self?.pickSchedule(for: [id])
        })
        if task.due != nil {
            sheet.addAction(UIAlertAction(title: "No Date", style: .destructive) { [weak self] _ in
                self?.scheduleTasks([id], to: nil)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = source ?? view
            popover.sourceRect = source?.bounds ?? CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        present(sheet, animated: true)
    }

    private func toggleDone(_ id: String) {
        guard let task = store.task(id) else { return }
        if task.isDone {
            PagesHaptics.selection()
            Task { if await !store.setDone(id, false) { PagesHaptics.error() } }
            return
        }
        // Guard against rapid double-taps firing duplicate dust animations and duplicate PATCHes.
        guard !ticking.contains(id) else { return }
        // [task-check-off] The circle fills and the row turns to dust at once; the list closes behind it as the task
        // moves to Done.
        PagesHaptics.success()
        ticking.insert(id)
        reload(animated: false)
        HQAnnounce.say("Done: \(task.title)")
        DispatchQueue.main.asyncAfter(deadline: .now() + (HQMotion.reduced ? 0.1 : TaskCheckOff.tick)) { [weak self] in
            guard let self else { return }
            let blown = self.blowAway(id)
            Task {
                // The save moves the row at once (the store shows it before the gateway answers), so it waits until
                // the dust's front is most of the way across: the list closes behind the dust, not under what stands.
                if blown { try? await Task.sleep(for: .seconds(TaskCheckOff.sweep * 0.8)) }
                let saved = await self.store.setDone(id, true)
                if saved { self.offerUndoDone(task) } else { PagesHaptics.error() }   // the notice says why
                self.ticking.remove(id)
                self.reload(animated: true)
                guard blown else { return }
                // Where the row went (Done on show, its next date, or back where it was when the save was refused)
                // it comes back in once the list has settled.
                try? await Task.sleep(for: .seconds(0.35))
                self.dusted.remove(id)
                if let path = self.dataSource.indexPath(for: .task(id)), let cell = self.collectionView.cellForItem(at: path) {
                    UIView.animate(withDuration: HQMotion.pane) { cell.contentView.alpha = 1 }   // motion-ok: opacity only
                }
            }
        }
    }

    /// The row's picture goes up as dust and its cell is left empty. False when the row isn't on screen, or under
    /// Reduce Motion.
    private func blowAway(_ id: String) -> Bool {
        guard !HQMotion.reduced, view.window != nil, let path = dataSource.indexPath(for: .task(id)),
              let cell = collectionView.cellForItem(at: path),
              TaskDust.play(over: cell.contentView, in: collectionView) else { return false }
        dusted.insert(id)
        cell.contentView.alpha = 0
        return true
    }

    /// A new task starts where you are: in the list on show, due today on Today.
    /// `bot`: [quick-actions] the bot an Add Task tile names, chosen in the sheet (else the page's own scope decides).
    func newTask(bot: String? = nil) {
        guard !store.readOnlyGateway else { notices.show(JobsStore.readOnlyNotice); return }
        if !isOverviewRoot, bot == nil, current == .goals, !searching, store.goalsNeedAddOn { updateAddOn(); return }   // [goals-addon] no goals to make yet
        if !isOverviewRoot, bot == nil, current == .goals, !searching { newGoal(); return }   // [goals] the bar's + makes a goal in the Goals view
        PagesHaptics.selection()
        let scoped = scope.effective(bots: bots)
        let preferred = bot.flatMap { id in bots.contains { $0.id == id } ? id : nil }
            ?? (scoped == PagesScope.all || scoped == PagesScope.me ? nil : scoped)
        let sheet = NewTodoSheet.make(store: store, bots: bots, preferredBot: preferred,
                                      section: currentList, dueDay: newTaskDay) { [weak self] task in
            guard let self, let task else { return }
            self.reload(animated: true)
            // A bot asked to help hears about it now, in the task's own chat on its page, and says what it would take.
            if task.helper != nil {
                self.openTask(task.id, asking: task.whoKind == .bot ? TaskNow.startRequest : TodoWords.helpQuestion)
            } else if self.rows[task.id] != nil {
                self.notices.show("Added “\(task.title)”")
            } else {
                // It landed in another view: say which, with the way there.
                let home = self.home(of: task)
                self.notices.show("Added “\(task.title)” to \(home.name)", seconds: 5, action: ("Show", { [weak self] in
                    self?.show(home.view)
                    self?.reveal(task.id)
                }))
            }
        }
        present(sheet, animated: true)
    }

    /// Where an open task of yours shows first: its list, else by its date, else Inbox.
    private func home(of task: TodoTask) -> (view: TodoView, name: String) {
        if TodoViews.botsOwn(task) { return (.bots, "Bots") }
        if let id = task.section, let name = listName(id) { return (.list(id), name) }
        guard let due = TodoDates.due(task.due) else { return (.inbox, "Inbox") }
        return Calendar.current.startOfDay(for: due.date) > Calendar.current.startOfDay(for: Date()) ? (.upcoming, "Upcoming") : (.today, "Today")
    }

    #if targetEnvironment(macCatalyst)
    /// [Mac AAA 2026-11-17] Owner's call Q3: ↑/↓ open the next or previous task beside the list, as Sessions' arrows
    /// open chats (`KeyCommands.walkList`): the tasks in the order the view shows them. The first ↓ opens the first
    /// task (the system's focus used to start on it unseen, so its ↓ marked the second). Off while Select picks.
    var walkOrder: [String] {
        guard isViewLoaded, dataSource != nil, !selecting else { return [] }
        return dataSource.snapshot().itemIdentifiers.compactMap { if case .task(let id) = $0 { id } else { nil } }
    }

    /// The task open beside the list (nil: none).
    var walkCurrent: String? { paneKeepsSelection ? onShowTask : nil }

    /// Opens `id` beside the list, as a click on its row (its row comes into view: `openTask`'s `reveal`).
    func walkOpen(_ id: String) {
        PagesHaptics.selection()
        openTask(id)
    }
    #endif

    /// `asking`: the question goes into the task's own chat at once (New Task with a bot). `atReply`: the page opens at
    /// its chat's newest end (a reply's alert), not the task's top.
    func openTask(_ id: String, asking question: String? = nil, atReply: Bool = false) {
        openWaitToken += 1
        let token = openWaitToken
        openTask(id, asking: question, atReply: atReply, attempt: 0, token: token)
    }

    private func openTask(_ id: String, asking question: String?, atReply: Bool, attempt: Int, token: Int) {
        guard token == openWaitToken else { return }
        // [notify] Audit 2026-11-19: a task's alert on a launch with no list yet chose the page before the task was
        // read, and stayed the bare page (no chat) once it came. A task not in hand waits for a fresh read (≤ 10 s).
        if store.task(id) == nil, attempt == 0 || ((store.loading || !store.hasList) && attempt < 20) {
            if attempt == 0 { Task { [store] in await store.refresh(force: true) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openTask(id, asking: question, atReply: atReply, attempt: attempt + 1, token: token)
            }
            return
        }
        listWait = 0
        guard store.task(id) != nil || store.hasList == false else {
            notices.show("That task isn’t on the list anymore.")
            return
        }
        if let presented = presentedViewController { presented.dismiss(animated: false) }
        reveal(id)
        #if targetEnvironment(macCatalyst)
        if (tabBarController as? MainTabController)?.split?.isDouble == true {
            let page = TodoSheet.page(taskID: id, store: store, context: context, beside: true)
            TodoSheet.model(of: page)?.onMarkedDone = { [weak self] task in self?.offerUndoDone(task) }
            TodoSheet.model(of: page)?.onAssigned = { [weak self] words in self?.openTask(id, asking: words) }   // [tasks-first]
            if atReply { (page as? ChatViewController)?.opensAtReply(); TodoSheet.model(of: page)?.tuck(.alert) }   // the reply's top, the task as its bar
            if isTable { MacDash.closes(page) }   // [mac-tools] the table takes the window back
            openDetail(page, animated: question == nil)
            markOnShow(id, keepsSelection: true)   // [mac] #41
            if let question, let task = store.task(id) { TodoSheet.model(of: page)?.openChat(task, question: question) }
            return
        }
        #endif
        let sheet = TodoSheet.make(taskID: id, store: store, context: context)
        TodoSheet.model(of: sheet.viewControllers.first)?.onMarkedDone = { [weak self] task in self?.offerUndoDone(task) }
        // [tasks-first] A bot given the task from its who row: the page opens again with that bot's conversation.
        TodoSheet.model(of: sheet.viewControllers.first)?.onAssigned = { [weak self] words in self?.openTask(id, asking: words) }
        if atReply {
            (sheet.viewControllers.first as? ChatViewController)?.opensAtReply()   // [notify] from the reply's top
            TodoSheet.model(of: sheet.viewControllers.first)?.tuck(.alert)   // the reply first, the task as its bar
        }
        present(sheet, animated: true) { [weak self, weak sheet] in
            guard let self, let question, let task = self.store.task(id) else { return }
            TodoSheet.model(of: sheet?.viewControllers.first)?.openChat(task, question: question)
        }
    }

    /// [tasks] Marked done (from its page or the list): offers Undo. A repeating task (`.me` or `.together`) has
    /// already rolled forward to its next date, so it has no Undo.
    private func offerUndoDone(_ task: TodoTask) {
        guard task.repeatRule == nil || task.whoKind == .bot else { return }
        UndoPill.show(label: "Marked Done", wayBack: "“\(task.title)” is back on the list", in: self) { [weak self] in
            guard let self else { return }   // the pill plays Undo's tap
            Task { if await !self.store.setDone(task.id, false) { PagesHaptics.error() } }
        }
    }

    /// A task opened from somewhere else (a chat card, a push) scrolls into view in the list, so its row is beside
    /// the open task on the Mac and where you left it on the iPhone.
    private func reveal(_ id: String) {
        guard isViewLoaded, let path = dataSource.indexPath(for: .task(id)),
              let row = collectionView.layoutAttributesForItem(at: path) else { return }
        let visible = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        guard !visible.contains(row.frame) else { return }
        collectionView.scrollToItem(at: path, at: .centeredVertically, animated: view.window != nil)
    }

    func openSettings() {
        present(TodoSettingsSheet.make(store: store, bots: bots) { [weak self] in
            guard let self else { return }
            Task { await self.ideas.refresh(force: true) }
        }, animated: true)
    }

    func importReminders() {
        guard !store.readOnlyGateway else { notices.show(JobsStore.readOnlyNotice); return }
        PagesHaptics.selection()
        TodoRemindersImport.run(store: store, from: self) { [weak self] text, _ in self?.notices.show(text, seconds: 4) }
    }

    private func updateAddOn() {
        guard !updateAsked, let model = TerminalHooks.model else { return }
        PagesHaptics.selection()
        updateAsked = true
        reload(animated: false)
        Task { [weak self] in
            _ = await PushSetupOffer.shared.check(model: model, fromSettings: true, confirm: false, needsIdeas: true, from: self)
            self?.updateAsked = false
            // Read the whole list whatever the sheet said: "Up to Date" (the add-on was already new) left the list's
            // `?since=` answer "unchanged", and the page kept asking for the update (owner 2026-11-05).
            await self?.store.refresh(force: true)
            self?.reload(animated: false)
        }
    }

    // MARK: Ideas ([task-ideas], dedicated Suggested view + inline Overview preview)

    /// Opens the dedicated Suggested view (`-HQPagesTasksIdeas`, PagesDebug).
    func showIdeas() {
        show(.suggested)
    }

    private func readIdeas() {
        ideas.prepare()
        Task { await ideas.refresh() }
        // The list was last read whole before the add-on had Ideas (`ideas` absent), and `?since=` has said
        // "unchanged" ever since: read it whole again, or an add-on updated outside the app never shows Ideas.
        if store.hasList && store.ideasCount == nil { Task { await store.refresh(force: true) } }
    }

    private func toggleOverviewIdea(_ id: String) {
        PagesHaptics.selection()
        ideaOpen.id = openIdea == id ? nil : id
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(.overviewSuggested) else { return }
        snapshot.reconfigureItems([.overviewSuggested])
        dataSource.apply(snapshot, animatingDifferences: !HQMotion.reduced)
    }

    /// Under Inbox's tasks: "Suggested by <Bot>" and one short row per idea (the bar's Filter and search apply), or
    /// the line that turns Ideas on. Nothing while the add-on has no Ideas or they haven't been read. True when it
    /// added rows.
    private func appendIdeas(to snapshot: inout NSDiffableDataSourceSnapshot<Section, Item>, scope scoped: String,
                             heads: [String: JSONValue?]) -> Bool {
        ideaCards = [:]
        guard store.ideasCount != nil, let page = ideas.page, scoped != PagesScope.me else { return false }
        snapshot.appendSections([.ideas])
        guard page.on else {
            snapshot.appendItems([.ideaNote(.off(looker: botName(page.bot)))], toSection: .ideas)
            return true
        }
        let shown = ideas.shown.filter { scoped == PagesScope.all || $0.bot == scoped }
        for idea in shown {
            ideaCards[idea.id] = TaskIdeaCardModel(idea: idea, botName: botName(idea.bot), head: heads[idea.bot] ?? nil,
                                                   busy: addingIdeas.contains(idea.id))
        }
        if let open = openIdea, ideaCards[open] == nil { openIdea = nil }
        snapshot.appendItems([.ideaHead], toSection: .ideas)
        if shown.isEmpty {
            let text: String
            if page.looking {
                text = "\(botName(page.bot)) is looking now. New ideas show here in a minute or two."
            } else if scoped != PagesScope.all {
                text = "Nothing new for \(botName(scoped))."
            } else {
                text = "Nothing new. \(botName(page.bot)) looks again at \(TaskIdeasHead.time(page.at))."
            }
            snapshot.appendItems([.ideaNote(.quiet(text))], toSection: .ideas)
        } else {
            snapshot.appendItems(shown.map { .idea($0.id) }, toSection: .ideas)
        }
        return true
    }

    /// A tap on an idea's row opens its card in place; a tap on the card folds it again.
    /// A tap on a suggestion: its card opens (and the one that was open closes). Two things move together: the list
    /// animates the cells' heights (and the rows under them), and inside each cell the row fades into the card. The
    /// cell clips, so the card never lies over the next row while it grows. (A cell that resized itself from its
    /// SwiftUI content alone changed height in one frame.)
    private func toggleIdea(_ id: String) {
        PagesHaptics.selection()
        let before = openIdea
        let next = before == id ? nil : id
        ideaOpen.id = next
        var snapshot = dataSource.snapshot()
        let touched = [before, next].compactMap { $0 }.map(Item.idea).filter { snapshot.itemIdentifiers.contains($0) }
        guard !touched.isEmpty else { return }
        snapshot.reconfigureItems(touched)
        dataSource.apply(snapshot, animatingDifferences: !HQMotion.reduced)
    }

    private func ideaID(at path: IndexPath) -> String? {
        guard case .idea(let id)? = dataSource.itemIdentifier(for: path) else { return nil }
        return id
    }

    private func idea(_ id: String) -> TaskIdea? { ideas.shown.first { $0.id == id } }

    /// The idea becomes a task (with its bot starting on its part when `start`); "Show" opens it.
    private func addIdea(_ id: String, start: Bool) {
        guard !store.readOnlyGateway else { notices.show(JobsStore.readOnlyNotice); return }
        guard let idea = idea(id), !addingIdeas.contains(id) else { return }
        PagesHaptics.selection()
        addingIdeas.insert(id)
        reload(animated: false)
        Task { [weak self] in
            guard let self else { return }
            let task = await self.ideas.add(idea, start: start)
            self.addingIdeas.remove(id)
            guard let task else { PagesHaptics.error(); self.reload(animated: false); return }
            PagesHaptics.success()   // once the gateway took it
            await self.store.refresh(force: true)
            let words = start ? "Added. \(self.botName(idea.bot)) is starting on it." : "Added “\(task.title)” to your tasks"
            HQAnnounce.say(words)
            self.notices.show(words, seconds: 5, action: ("Show", { [weak self] in self?.openTask(task.id) }))
        }
    }

    /// Gone from Ideas at once, for good; the Undo pill brings it back.
    private func dismissIdea(_ id: String) {
        guard !store.readOnlyGateway else { notices.show(JobsStore.readOnlyNotice); return }
        guard let idea = idea(id) else { return }
        // A press you feel (owner 2026-11-12: "clicking the X by each suggested task needs Taptic feedback"). It played
        // the selection tick, the faintest cue there is, which a phone can let pass unfelt; a press that takes a row
        // away is a light impact, as the Undo pill's Undo.
        Haptics.play(.light)
        let pill = UndoPill.show(label: "Dismissed", in: self) { [weak self] in
            guard let self else { return }
            Task { if await !self.ideas.restore(idea) { PagesHaptics.error() } }
        }
        Task {
            if await !ideas.dismiss(idea) { pill?.dismiss(animated: true); PagesHaptics.error() }
        }
    }

    private func lookForIdeas() {
        guard !store.readOnlyGateway else { notices.show(JobsStore.readOnlyNotice); return }
        PagesHaptics.selection()
        Task { if await !ideas.lookNow() { PagesHaptics.error() } }
    }

    private func notePrimary(_ note: TaskIdeasNote) {
        switch note {
        case .off:
            guard !store.readOnlyGateway else { notices.show(JobsStore.readOnlyNotice); return }
            PagesHaptics.success()
            Task { await ideas.setOn(true, tasks: store) }
        case .noTasks: newTask()
        case .quiet: break
        }
    }

    private func ideaMenu(_ id: String) -> UIContextMenuConfiguration? {
        guard let idea = idea(id) else { return nil }
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var adds: [UIMenuElement] = [
                UIAction(title: "Add to Tasks", image: UIImage(systemName: "plus.circle")) { [weak self] _ in self?.addIdea(id, start: false) },
            ]
            if idea.botHelps {
                adds.append(UIAction(title: "Add & Let \(self.botName(idea.bot)) Start", image: UIImage(systemName: "play.circle")) { [weak self] _ in
                    self?.addIdea(id, start: true)
                })
            }
            return UIMenu(children: [
                UIMenu(options: .displayInline, children: adds),
                UIAction(title: "Dismiss", image: UIImage(systemName: "xmark.circle"), attributes: .destructive) { [weak self] _ in
                    self?.dismissIdea(id)
                },
            ])
        }
    }

    /// Leading: Add. Trailing: Dismiss (a full swipe does it).
    private func ideaSwipe(_ id: String, leading: Bool) -> UISwipeActionsConfiguration? {
        guard idea(id) != nil, !store.readOnlyGateway else { return nil }
        let action: UIContextualAction
        if leading {
            action = UIContextualAction(style: .normal, title: "Add") { [weak self] _, _, finish in
                self?.addIdea(id, start: false)
                finish(true)
            }
            action.image = UIImage(systemName: "plus")
            action.backgroundColor = .systemGreen
        } else {
            action = UIContextualAction(style: .destructive, title: "Dismiss") { [weak self] _, _, finish in
                self?.dismissIdea(id)
                finish(true)
            }
            action.image = UIImage(systemName: "xmark")
        }
        let config = UISwipeActionsConfiguration(actions: [action])
        config.performsFirstActionWithFullSwipe = true
        return config
    }

    // MARK: Lists (the add-on's sections, hermes-hq-push 0.9.36)

    private func setLayout(sort: String) {
        PagesHaptics.selection()
        Task { if await !store.setLayout(sort: sort) { PagesHaptics.error() } }
    }

    /// Asks for a name, makes the list, moves `ids` into it (Move To › New List…) and shows it.
    private func promptNewList(moving ids: [String], after: (() -> Void)? = nil) {
        guard !store.readOnlyGateway else { notices.show(JobsStore.readOnlyNotice); return }
        askName(title: "New List", message: "Group your tasks your way, like Home, Work or Errands.", name: "", action: "Add") { [weak self] name in
            guard let self else { return }
            Task {
                guard let made = await self.store.addSection(named: name) else { PagesHaptics.error(); return }
                PagesHaptics.success()
                if !ids.isEmpty { await self.store.move(ids, to: made.id) }
                after?()
                self.show(.list(made.id))
            }
        }
    }

    private func renameList(_ id: String) {
        guard let section = store.sections.first(where: { $0.id == id }) else { return }
        askName(title: "Rename List", message: nil, name: section.name, action: "Save") { [weak self] name in
            guard let self else { return }
            let next = self.store.sections.map { list -> TodoUserSection in
                guard list.id == id else { return list }
                var list = list; list.name = String(name.prefix(60)); return list   // its colour, icon and bot stay
            }
            Task {
                if await self.store.saveSections(next) != nil { PagesHaptics.success() } else { PagesHaptics.error() }
            }
        }
    }

    private func moveList(_ id: String, by offset: Int) {
        var next = store.sections
        guard let at = next.firstIndex(where: { $0.id == id }), next.indices.contains(at + offset) else { return }
        PagesHaptics.selection()
        next.swapAt(at, at + offset)
        Task { if await store.saveSections(next) == nil { PagesHaptics.error() } }
    }

    private func deleteList(_ id: String) {
        let name = listName(id) ?? "List"
        let inside = store.tasks.filter { $0.section == id }
        let message = TodoWords.deleteListMessage(open: inside.filter { !$0.isDone }.count, done: inside.filter(\.isDone).count)
        let alert = UIAlertController(title: "Delete “\(name)”?", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete List", style: .destructive) { [weak self] _ in
            guard let self else { return }
            // The result's cue, as Rename List's (the confirm button was the press).
            Task {
                if await self.store.saveSections(self.store.sections.filter { $0.id != id }) != nil { PagesHaptics.success() } else { PagesHaptics.error() }
            }
        })
        present(alert, animated: true)
    }

    // MARK: [task-lists] Edit List, and a bot's offers

    #if DEBUG
    /// `-HQPagesEditList <name>` (PagesDebug): the sheet a hold on the pill opens.
    func debugEditList(_ id: String) { editList(id) }
    #endif

    /// A hold on a list's pill › Edit List…: its name, colour, icon, the bot that keeps it, and Today.
    private func editList(_ id: String) {
        guard let section = store.sections.first(where: { $0.id == id }) else { return }
        guard !store.readOnlyGateway else { notices.show(JobsStore.readOnlyNotice); return }
        present(TaskListEditSheet.make(store: store, section: section, bots: bots) { [weak self] in
            guard let self else { return }
            self.dismiss(animated: true) { self.deleteList(id) }
        }, animated: true)
    }

    /// A tap on an offer's card. What it did shows as a notice, with Undo for what accepting made.
    private func answerOffer(_ id: String, _ button: TodoOfferButton) {
        guard !answering.contains(id), let offer = store.offers.first(where: { $0.id == id }) else { return }
        guard !store.readOnlyGateway else { notices.show(JobsStore.readOnlyNotice); return }
        Haptics.play(.light)
        answering.insert(id)
        reload(animated: false)
        Task {
            let ok = await store.answerOffer(id, button.action, list: button.makesList)
            answering.remove(id)
            guard ok else { PagesHaptics.error(); reload(animated: false); return }
            PagesHaptics.success()
            reload(animated: true)
            // What it did, once: while the card still asks about your own tasks it is the answer on show (a notice
            // would lie over its question), so the notice waits for Move or Leave Them.
            guard button.action != .decline, let after = store.offers.first(where: { $0.id == id }), !after.asksMove,
                  let words = TodoLists.offerDone(after) else { return }
            AppLog.note("tasks", "offer \(button.action.rawValue): \(offer.tasks.count) tasks, \(offer.move.count) to move")
            guard TodoLists.canUndo(after) else { notices.show(words); return }
            notices.show(words, action: (title: "Undo", handler: { [weak self] in self?.undoOffer(id) }))
        }
    }

    // MARK: [goals step 3] Today's goal offer

    private func goalOfferCard(_ offer: TodoOffer) -> GoalOfferCardModel {
        let goal = store.goals.first { $0.id == (offer.goal ?? offer.madeGoal) }
        let name: (String?) -> String = { [bots] in PagesNames.botName($0 ?? "default", bots: bots) }
        return GoalOfferCardModel(offer: offer, goal: goal,
                                  kicker: offer.kind == "checkin" ? GoalOffers.checkinHead(offer, goal: goal, botName: name) : nil,
                                  botName: name(offer.bot), head: PagesNames.head(offer.bot, bots: bots),
                                  busy: answering.contains(offer.id), foot: GoalOffers.foot(offer, past: false), lead: goal?.lead,
                                  names: Dictionary(bots.map { ($0.id, name($0.id)) }, uniquingKeysWith: { a, _ in a }),
                                  heads: Dictionary(bots.compactMap { bot in bot.head.map { (bot.id, $0) } }, uniquingKeysWith: { a, _ in a }))
    }

    /// A tap on the goal offer's card: an answer, or Change (the goal's chat takes the cursor).
    private func answerGoalOffer(_ id: String, _ button: GoalOfferButton) {
        guard !answering.contains(id), let offer = store.offers.first(where: { $0.id == id }) else { return }
        guard let action = button.action else {
            PagesHaptics.selection()
            if let goal = offer.goal { openGoal(goal, chat: true) }
            return
        }
        guard !store.readOnlyGateway else { notices.show(JobsStore.readOnlyNotice); return }
        Haptics.play(.light)
        answering.insert(id)
        goalOfferKept = id
        reload(animated: false)
        Task {
            let ok = await store.answerOffer(id, action, plan: button.plan, inGoal: button.inGoal)
            answering.remove(id)
            if ok { PagesHaptics.success() } else { PagesHaptics.error() }
            // Answered, the card leaves Today (the next waiting offer, if any, takes its place); what it did shows
            // once as a notice, with Undo for what accepting added — as a list offer's answer does.
            goalOfferKept = nil
            reload(animated: true)
            AppLog.note("tasks", "goal offer \(offer.kind) \(action.rawValue): \(ok ? "ok" : "refused")")
            guard ok, action == .accept, let after = store.offers.first(where: { $0.id == id }) ?? TodoOfferStates.live(id).offer,
                  let words = GoalOffers.done(after) else { return }
            if after.kind == "checkin" && after.added.isEmpty { return }   // "Got It": nothing was added, nothing to say
            guard after.state == "accepted" else { notices.show(words); return }
            notices.show(words, action: (title: "Undo", handler: { [weak self] in self?.undoOffer(id) }))
        }
    }

    private func undoGoalOffer(_ id: String) {
        guard !answering.contains(id) else { return }
        Haptics.play(.light)
        answering.insert(id)
        goalOfferKept = id
        reload(animated: false)
        Task {
            let ok = await store.answerOffer(id, .undo)
            answering.remove(id)
            if ok { PagesHaptics.success() } else { PagesHaptics.error() }
            reload(animated: false)
        }
    }

    private func showGoalOffer(_ id: String) {
        guard let card = goalOfferCards[id] else { return }
        PagesHaptics.selection()
        let name: (String?) -> String = { [bots] in PagesNames.botName($0 ?? "default", bots: bots) }
        present(GoalOfferAllSheet.make(card.offer, goal: card.goal, botName: name), animated: true)
    }

    private func undoOffer(_ id: String) {
        Haptics.play(.light)
        Task {
            if await store.answerOffer(id, .undo) { PagesHaptics.success() } else { PagesHaptics.error() }
        }
    }

    private func askName(title: String, message: String?, name: String, action: String, done: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        let save = UIAlertAction(title: action, style: .default) { [weak alert] _ in
            let text = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty { done(text) }
        }
        // A blank name has nothing to add: Add (or Save) waits for a name.
        let blank: (String?) -> Bool = { ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        save.isEnabled = !blank(name)
        alert.addTextField { [weak save] field in
            field.text = name
            field.placeholder = "List Name"
            field.autocapitalizationType = .words
            field.returnKeyType = .done
            field.accessibilityIdentifier = "tasks.list-name"
            field.addAction(UIAction { [weak save, weak field] _ in save?.isEnabled = !blank(field?.text) }, for: .editingChanged)
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(save)
        alert.preferredAction = save
        // Rename: the old name is selected, so typing replaces it.
        present(alert, animated: true) { [weak alert] in
            if let field = alert?.textFields?.first, field.hasText { field.selectAll(nil) }
        }
    }

    /// Move To's choices for `ids`: No List, each of yours (a tick on where they all are now), New List….
    private func moveChoices(for ids: [String], after: (() -> Void)? = nil) -> [UIMenuElement] {
        guard !ids.isEmpty else { return [] }
        let now = Set(ids.map { store.task($0)?.section ?? "" })
        let options = [("", "No List")] + store.sections.map { ($0.id, $0.name) }
        let places = options.map { id, name in
            UIAction(title: name, state: now == [id] ? .on : .off) { [weak self] _ in
                guard let self else { return }
                PagesHaptics.selection()
                Task {
                    if await !self.store.move(ids, to: id.isEmpty ? nil : id) { PagesHaptics.error() }
                    after?()
                }
            }
        }
        let make = UIAction(title: "New List…", image: UIImage(systemName: "plus")) { [weak self] _ in
            self?.promptNewList(moving: ids, after: after)
        }
        return [UIMenu(options: .displayInline, children: places), make]
    }

    // MARK: Select

    private func setSelecting(_ on: Bool) {
        guard on != selecting else { return }
        if on { PagesHaptics.selection() }
        selecting = on
        picked = []
        reload(animated: true)
    }

    private func selectionMoveChoices() -> [UIMenuElement] {
        moveChoices(for: selectedIDs()) { [weak self] in self?.setSelecting(false) }
    }

    private func selectionScheduleChoices() -> [UIMenuElement] {
        scheduleChoices(for: selectedIDs()) { [weak self] in self?.setSelecting(false) }
    }

    private func selectionPriorityChoices() -> [UIMenuElement] {
        priorityChoices(for: selectedIDs()) { [weak self] in self?.setSelecting(false) }
    }

    private func selectedIDs() -> [String] { picked.filter { store.task($0) != nil } }

    private func togglePicked(_ id: String) {
        PagesHaptics.selection()
        if let at = picked.firstIndex(of: id) { picked.remove(at: at) } else { picked.append(id) }
        reload(animated: false)
    }

    /// Select's bar: Schedule, Move To, Mark Done, Delete, then Done (plus Priority when supported).
    private func updateSelectionBar() {
        let count = selectedIDs().count
        let enabled = count > 0 && !store.readOnlyGateway
        for item in [selectScheduleItem, selectMoveItem, selectPriorityItem, selectDoneItem, selectDeleteItem] { item.isEnabled = enabled }
        var items = [endSelectItem, selectDeleteItem, selectDoneItem, selectMoveItem, selectScheduleItem]
        if store.fieldsSupported { items.append(selectPriorityItem) }
        if navigationItem.rightBarButtonItems ?? [] != items { navigationItem.rightBarButtonItems = items }
    }

    private func markSelectedDone() {
        let ids = selectedIDs().filter { store.task($0)?.isDone == false }
        guard !ids.isEmpty else { return }
        PagesHaptics.success()
        setSelecting(false)
        Task {
            let allDone = await withChildTasks(of: Bool.self) { group in
                for id in ids { group.addTask { await self.store.setDone(id, true) } }
                var ok = true
                while let one = await group.next() { ok = ok && one }
                return ok
            }
            if !allDone { PagesHaptics.error() }
        }
    }

    private func deleteSelected() {
        let ids = selectedIDs()
        guard !ids.isEmpty else { return }
        let title = ids.count == 1 ? "Delete 1 Task?" : "Delete \(ids.count) Tasks?"
        let sheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.setSelecting(false)
            // One cue for the lot, once every delete has answered: success, or error if any was refused.
            Task {
                let allGone = await withChildTasks(of: Bool.self) { group in
                    for id in ids { group.addTask { await self.store.delete(id) } }
                    var ok = true
                    while let one = await group.next() { ok = ok && one }
                    return ok
                }
                if allGone { PagesHaptics.success() } else { PagesHaptics.error() }
            }
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = selectDeleteItem
        present(sheet, animated: true)
    }

    // MARK: Drag a task up or down its list, in Today, or onto a day in Upcoming

    /// A list's open tasks can be put in your own order by hand only when Sort By is My Order (`"smart"`).
    private var canArrange: Bool {
        currentList != nil && store.settings.sort == "smart" && !searching && !selecting && !store.readOnlyGateway
    }

    /// Today's open tasks can be dragged to reorder; Upcoming's open tasks can be dragged onto any day pill or day section.
    private var canDragTask: Bool {
        guard !searching, !selecting, !store.readOnlyGateway else { return false }
        return canArrange || current == .today || current == .upcoming
    }

    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession,
                        at indexPath: IndexPath) -> [UIDragItem] {
        if let item = goalDragItem(at: indexPath) { return [item] }   // [goals] active goals, in your order
        guard canDragTask, let id = taskID(at: indexPath), let task = store.task(id), !task.isDone else { return [] }
        // Carry "hq-task:<id>" in NSItemProvider so SwiftUI `.dropDestination(for: String.self)` on Upcoming's week strip receives it.
        let item = UIDragItem(itemProvider: NSItemProvider(object: ("hq-task:" + id) as NSString))
        item.localObject = id
        return [item]
    }

    func collectionView(_ collectionView: UICollectionView, dragPreviewParametersForItemAt indexPath: IndexPath) -> UIDragPreviewParameters? {
        guard let cell = collectionView.cellForItem(at: indexPath) else { return nil }
        let parameters = UIDragPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: cell.bounds, cornerRadius: 12)
        parameters.backgroundColor = HQPalette.page
        return parameters
    }

    /// Where a drop at `path` lands among open tasks (list or Today).
    private func dropIndex(_ path: IndexPath?) -> (kind: TodoGroupKind, index: Int)? {
        guard let path, case .group(let kind)? = dataSource.sectionIdentifier(for: path.section) else { return nil }
        if canArrange, kind == .open { return (.open, path.item) }
        if current == .today, !searching, !selecting, !store.readOnlyGateway, kind == .today { return (.today, path.item) }
        return nil
    }

    /// Day key when dropping a task onto a day section in Upcoming.
    private func upcomingDropDay(_ path: IndexPath?) -> String? {
        guard current == .upcoming, !searching, !selecting, !store.readOnlyGateway,
              let path, case .group(.day(let key))? = dataSource.sectionIdentifier(for: path.section) else { return nil }
        return key
    }

    func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
        let object = session.localDragSession?.items.first?.localObject
        return object is String || object is GoalDrag
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
                        withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
        if session.localDragSession?.items.first?.localObject is GoalDrag { return goalDropProposal(destinationIndexPath) }
        guard session.localDragSession != nil else { return UICollectionViewDropProposal(operation: .forbidden) }
        if let target = dropIndex(destinationIndexPath) {
            let place = "\(target.kind):\(target.index)"
            if place != dropPlace {
                if dropPlace != nil { Haptics.play(.selection) }   // the first place is where the task was picked up
                dropPlace = place
            }
            return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
        }
        if let dayKey = upcomingDropDay(destinationIndexPath) {
            let place = "day:\(dayKey)"
            if place != dropPlace {
                if dropPlace != nil { Haptics.play(.selection) }
                dropPlace = place
            }
            return UICollectionViewDropProposal(operation: .move, intent: .insertIntoDestinationIndexPath)
        }
        return UICollectionViewDropProposal(operation: .forbidden)
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidExit session: UIDropSession) { dropPlace = nil }
    func collectionView(_ collectionView: UICollectionView, dropSessionDidEnd session: UIDropSession) { dropPlace = nil }

    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        if coordinator.items.first?.dragItem.localObject is GoalDrag { dropGoal(coordinator); return }
        guard let drop = coordinator.items.first, let id = drop.dragItem.localObject as? String else { return }
        if let dayKey = upcomingDropDay(coordinator.destinationIndexPath) {
            rescheduleDroppedTask(id, onto: dayKey)
            return
        }
        guard let target = dropIndex(coordinator.destinationIndexPath) else { return }
        var ids = groups.first { $0.0 == target.kind }?.1 ?? []
        var index = min(target.index, ids.count)
        if let from = ids.firstIndex(of: id) {
            ids.remove(at: from)
            if from < index { index -= 1 }
        }
        index = min(index, ids.count)
        let above = index > 0 ? store.task(ids[index - 1]) : nil
        let below = index < ids.count ? store.task(ids[index]) : nil
        let position = TodoSections.position(between: above, and: below)
        if let path = coordinator.destinationIndexPath { coordinator.drop(drop.dragItem, toItemAt: path) }
        Haptics.play(.soft)   // the drop lands; the places crossed on the way ticked
        if let list = currentList {
            if store.settings.sort != "smart" {
                notices.show("Sorted by \(store.settings.sort == "due" ? "Due Date" : (store.settings.sort == "priority" ? "Priority" : "Date Added")). Choose My Order in Sort By to arrange tasks by hand.", seconds: 4)
            }
            Task { if await !store.move([id], to: list, position: position) { PagesHaptics.error() } }
        } else if target.kind == .today {
            var patch: [String: JSONValue] = ["position": .number(position)]
            let wasOverdue = groups.first { $0.0 == .overdue }?.1.contains(id) == true
            if wasOverdue, let task = store.task(id) {
                patch["due"] = .string(TodoViews.rescheduledDue(for: task, onto: Date(), preserveTime: true))
            }
            Task { if await !store.patch(id, patch) { PagesHaptics.error() } }
        }
    }

    // MARK: [goals] The Goals view (docs/goals.md; App/Pages/Goals)

    /// Active goals as cards, then Someday's quieter ones, then Achieved and Let Go folded to their headings, then
    /// "+ New Goal". With no goals at all, what a goal is, with New Goal.
    private func appendGoals(to snapshot: inout NSDiffableDataSourceSnapshot<Section, Item>, now: Date) {
        let made = GoalViews.groups(store.goals)
        let tasks = store.tasks
        let look = GoalTeamLook(bots: bots), kept = GoalKeptHere.all
        goalCards = Dictionary(store.goals.map { ($0.id, GoalCardModel.make($0, tasks: tasks, now: now, ticking: ticking, bots: store.goalBotsSupported, offers: store.offers,
                                                                   look: look, keptHere: kept[$0.id])) },
                               uniquingKeysWith: { first, _ in first })
        let all: [(GoalGroupKey, [Goal])] = [(.active, made.active), (.someday, made.someday), (.achieved, made.achieved), (.letGo, made.letGo)]
        goalGroups = all.filter { !$0.1.isEmpty }.map { key, goals in (key, goals.map(\.id)) }
        guard !made.isEmpty else {
            snapshot.appendSections([.goalsFoot])
            snapshot.appendItems([.goalsEmpty], toSection: .goalsFoot)
            return
        }
        for (key, ids) in goalGroups {
            snapshot.appendSections([.goals(key)])
            let folded = (key == .achieved || key == .letGo) && !goalFoldsOpen.contains(key)
            if !folded { snapshot.appendItems(ids.map { .goal($0) }, toSection: .goals(key)) }
        }
        snapshot.appendSections([.goalsFoot])
        snapshot.appendItems([.newGoal], toSection: .goalsFoot)
    }

    /// [goals] Step 2: a search's "Goals" group, over its To Do and Done: the goals whose name or why holds the words,
    /// any status, as the Goals view draws them. Not with one bot picked (a goal has no bot yet; the shelf hides the
    /// same way). True when it added the group.
    private func appendFoundGoals(to snapshot: inout NSDiffableDataSourceSnapshot<Section, Item>, now: Date, scope scoped: String) -> Bool {
        goalCards = [:]
        goalGroups = []
        guard store.goalsSupported, scoped == PagesScope.all || scoped == PagesScope.me else { return false }
        let found = GoalViews.found(store.goals, query: query)
        guard !found.isEmpty else { return false }
        let tasks = store.tasks
        let look = GoalTeamLook(bots: bots), kept = GoalKeptHere.all
        goalCards = Dictionary(found.map { ($0.id, GoalCardModel.make($0, tasks: tasks, now: now, ticking: ticking, bots: store.goalBotsSupported, offers: store.offers,
                                                                   look: look, keptHere: kept[$0.id])) },
                               uniquingKeysWith: { first, _ in first })
        goalGroups = [(.found, found.map(\.id))]
        snapshot.appendSections([.goals(.found)])
        snapshot.appendItems(found.map { .goal($0.id) }, toSection: .goals(.found))
        return true
    }

    private func configureGoalHeader(_ header: UICollectionViewListCell, _ key: GoalGroupKey) {
        let title = switch key { case .active: "Active"; case .someday: "Someday"; case .achieved: "Achieved"; case .letGo: "Let Go"; case .found: "Goals" }
        let count = goalGroups.first { $0.0 == key }?.1.count ?? 0
        var view = TodoGroupHeaderView(title: title, detail: nil, count: count)
        if key == .achieved || key == .letGo {
            view.fold = (goalFoldsOpen.contains(key) ? "Hide" : "Show", { [weak self] in self?.toggleGoalFold(key) })
            view.foldID = "goals.fold.\(key.rawValue)"
        }
        header.contentConfiguration = UIHostingConfiguration { view }.margins(.all, 0)
        header.backgroundConfiguration = .clear()
        header.accessibilityIdentifier = "tasks.section.\(title)"
    }

    /// [goals] Step 2: a tap on the shelf's "Goals" folds it to its heading, or opens it again (kept on this device).
    private func toggleShelf() {
        PagesHaptics.selection()
        GoalShelfFold.folded.toggle()
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(.shelf) else { return }
        snapshot.reconfigureItems([.shelf])
        dataSource.apply(snapshot, animatingDifferences: !HQMotion.reduced)
        HQAnnounce.say(GoalShelfFold.folded ? "Goals hidden" : "Goals shown")
    }

    private func toggleGoalFold(_ key: GoalGroupKey) {
        PagesHaptics.selection()
        if goalFoldsOpen.contains(key) { goalFoldsOpen.remove(key) } else { goalFoldsOpen.insert(key) }
        reload(animated: true)
    }

    /// New Goal: the quick-add sheet; on Add it closes and the new goal's page opens.
    func newGoal() {
        guard !store.readOnlyGateway else { notices.show(JobsStore.readOnlyNotice); return }
        guard presentedViewController == nil else { return }
        PagesHaptics.selection()
        present(NewGoalSheet.make(store: store, onCreated: { [weak self] goal in
            guard let self, let goal else { return }
            if self.current != .goals { self.show(.goals) }
            self.reload(animated: true)
            self.openGoal(goal.id)
        }, onPlan: { [weak self] goal, typed in
            // [goals step 3] Plan With: the goal's chat opens and its lead is asked for a plan (your words in the bubble).
            guard let self else { return }
            if self.current != .goals { self.show(.goals) }
            self.reload(animated: true)
            self.openGoal(goal.id, chat: true, plan: typed)
        }), animated: true)
    }

    /// A goal's page, as a sheet over the list (as a task's is). [goals step 3] A goal with a lead opens on its chat
    /// with the goal over it (`chat`: the chat first, the goal as its bar). [goals step 5] On the Mac's two panes the
    /// goal takes the centre and, with a lead, its chat the right-hand pane.
    func openGoal(_ id: String, chat: Bool = false, plan: String? = nil) {
        guard store.goal(id) != nil || !store.hasList else { notices.show("That goal isn’t there anymore."); return }
        if let presented = presentedViewController { presented.dismiss(animated: false) }
        let ask: (GoalPageModel?) -> Void = { [weak self] model in
            guard let self, let plan, let model, let chat = model.chat, let goal = self.store.goal(id) else { return }
            // [goals step 6] Never the same ask twice for one goal within a minute (a double tap, Edit Goal then the button).
            guard GoalPlanAsks.mayAsk(id) else { AppLog.note("goals", "plan ask skipped: asked under a minute ago"); return }
            model.sendHidden(GoalBots.planRequest(goal, typed: plan, now: Date()), display: plan, in: chat)
            AppLog.note("goals", "plan asked of the goal's lead")
        }
        #if targetEnvironment(macCatalyst)
        if (tabBarController as? MainTabController)?.split?.isDouble == true {
            let page = GoalPage.page(goalID: id, store: store, context: context, beside: true)
            if isTable { MacDash.closes(page) }
            openDetail(page, animated: true)
            let model = GoalPage.model(of: page)
            if plan != nil { ask(model) } else if chat { model?.chat?.focusComposer() }
            return
        }
        #endif
        let sheet = GoalPage.make(goalID: id, store: store, context: context, chat: chat)
        present(sheet, animated: true) {
            if plan != nil { ask(GoalPage.model(of: sheet.viewControllers.first)) }
        }
    }

    /// [goals] `-HQPagesOpenGoal "<title>"`: the Goals view, then that goal's page.
    func debugOpenGoal(titled title: String) {
        show(.goals)
        guard let goal = store.goals.first(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) else { return }
        openGoal(goal.id)
    }

    /// Hold a card: the goal page's ⋯ rows (Edit Goal…, Pause or Resume, Mark Achieved, Let It Go, Delete Goal…).
    private func goalMenu(_ id: String) -> UIContextMenuConfiguration? {
        guard store.goal(id) != nil, !store.readOnlyGateway else { return nil }
        return UIContextMenuConfiguration(identifier: ("goal:" + id) as NSString, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            let source = self.dataSource.indexPath(for: .goal(id)).flatMap { self.collectionView.cellForItem(at: $0) }
            return UIMenu(children: GoalMenu.items(goalID: id, store: self.store, from: self, source: source))
        }
    }

    /// Active goals go in your order by hand (their `position`).
    private func goalDragItem(at path: IndexPath) -> UIDragItem? {
        guard current == .goals, !searching, !selecting, !store.readOnlyGateway,
              case .goal(let id)? = dataSource.itemIdentifier(for: path),
              dataSource.sectionIdentifier(for: path.section) == .goals(.active), let goal = store.goal(id) else { return nil }
        let item = UIDragItem(itemProvider: NSItemProvider(object: goal.title as NSString))
        item.localObject = GoalDrag(id: id)
        return item
    }

    private func goalDropProposal(_ path: IndexPath?) -> UICollectionViewDropProposal {
        guard let path, dataSource.sectionIdentifier(for: path.section) == .goals(.active) else {
            return UICollectionViewDropProposal(operation: .forbidden)
        }
        let place = "goal:\(path.item)"
        if place != dropPlace {
            if dropPlace != nil { Haptics.play(.selection) }
            dropPlace = place
        }
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    private func dropGoal(_ coordinator: UICollectionViewDropCoordinator) {
        guard let drop = coordinator.items.first, let id = (drop.dragItem.localObject as? GoalDrag)?.id,
              let path = coordinator.destinationIndexPath else { return }
        var ids = goalGroups.first { $0.0 == .active }?.1 ?? []
        var index = min(path.item, ids.count)
        if let from = ids.firstIndex(of: id) {
            ids.remove(at: from)
            if from < index { index -= 1 }
        }
        index = min(index, ids.count)
        let above = index > 0 ? store.goal(ids[index - 1])?.order : nil
        let below = index < ids.count ? store.goal(ids[index])?.order : nil
        let position: Double = switch (above, below) {
        case let (a?, b?): (a + b) / 2
        case let (a?, nil): a + 1
        case let (nil, b?): b - 1
        default: Date().timeIntervalSince1970
        }
        coordinator.drop(drop.dragItem, toItemAt: path)
        Haptics.play(.soft)
        Task { if await !store.patchGoal(id, ["position": .number(position)]) { PagesHaptics.error() } }
    }

    // MARK: Selection, menus, swipes

    private func taskID(at path: IndexPath) -> String? {
        guard case .task(let id)? = dataSource.itemIdentifier(for: path) else { return nil }
        return id
    }

    /// The row sits under "Still Need These?".
    private func isStale(_ path: IndexPath) -> Bool {
        if case .group(.stale)? = dataSource.sectionIdentifier(for: path.section) { return true }
        return false
    }

    /// Keep: it stays on the list and leaves "Still Need These?" for two weeks.
    private func keep(_ id: String) {
        PagesHaptics.success()
        Task { if await !store.keep(id) { PagesHaptics.error() } }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if selecting {
            collectionView.deselectItem(at: indexPath, animated: false)
            if let id = taskID(at: indexPath) { togglePicked(id) }
            return
        }
        switch dataSource.itemIdentifier(for: indexPath) {
        case .idea(let id)?:
            collectionView.deselectItem(at: indexPath, animated: false)
            toggleIdea(id)
        case .task(let id)?:
            PagesHaptics.selection()
            openTask(id)
            if onShowTask != id { collectionView.deselectItem(at: indexPath, animated: true) }
        case .more(let id)?:
            collectionView.deselectItem(at: indexPath, animated: false)
            PagesHaptics.selection()
            show(.list(id))
        case .goal(let id)?:
            collectionView.deselectItem(at: indexPath, animated: true)
            PagesHaptics.selection()
            openGoal(id)
        case .newGoal?:
            collectionView.deselectItem(at: indexPath, animated: true)
            newGoal()
        default:
            collectionView.deselectItem(at: indexPath, animated: true)
        }
    }

    // MARK: [mac] Two panes (App/Root/PaneRouter.swift)

    /// [mac] Mac polish #57: no task to choose (no tasks, the add-on to update, loading, a search with no match):
    /// the right pane beside it stays blank, not "No Task Open – Choose a task" beside the list's own empty state.
    private(set) var paneListIsEmpty = false

    private func notePaneListEmpty(_ empty: Bool) {
        #if targetEnvironment(macCatalyst)
        guard empty != paneListIsEmpty else { return }
        paneListIsEmpty = empty
        NotificationCenter.default.post(name: DetailPlaceholderViewController.listStateChanged, object: self)
        #endif
    }

    private func taskID(of item: Item) -> String? {
        if case .task(let id) = item { return id }
        return nil
    }

    /// [mac] Mac polish #41: the row of the task whose page the right pane shows stays marked while the list shows, as
    /// on Jobs and Kanban (it flashed and went plain, so nothing said which task was open).
    private var paneKeepsSelection = false
    private var onShowTask: String?
    /// The Tasks pages alive now, so the right pane's router can mark the open task's row without a handle on the page.
    private static let live = NSHashTable<TasksViewController>.weakObjects()

    /// `root`: the right pane's first page (`MainTabController.paneSelectionChanged`). Its task's row is marked in every
    /// Tasks list; any other page, or one pane, clears the mark.
    static func markOnShow(root: UIViewController?, keepsSelection: Bool) {
        let id = TodoSheet.model(of: root)?.taskID
        for page in live.allObjects { page.markOnShow(id, keepsSelection: keepsSelection) }
    }

    /// Marks the row of the task the right pane shows; nil clears it. Select's picking marks no row.
    func markOnShow(_ id: String?, keepsSelection: Bool) {
        paneKeepsSelection = keepsSelection
        onShowTask = keepsSelection ? id : nil
        guard isViewLoaded, dataSource != nil else { return }
        let path = selecting ? nil : onShowTask.flatMap { dataSource.indexPath(for: .task($0)) }
        for selected in collectionView.indexPathsForSelectedItems ?? [] where selected != path {
            collectionView.deselectItem(at: selected, animated: false)
        }
        if let path { collectionView.selectItem(at: path, animated: false, scrollPosition: []) }
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        if selecting { return taskID(at: indexPath) != nil }
        switch dataSource.itemIdentifier(for: indexPath) {
        case .task?, .idea?, .more?, .goal?, .newGoal?: return true
        default: return false
        }
    }

    /// [mac] Mac polish #106: the Mac's row hover (`MacHover`) lights only what a click opens, not the week, a
    /// heading's words or an empty view's line. Elsewhere rows highlight as before.
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        guard DeviceWord.isMac else { return true }
        return self.collectionView(collectionView, shouldSelectItemAt: indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard !selecting, let path = indexPaths.first else { return nil }
        if let id = ideaID(at: path) { return ideaMenu(id) }
        if case .goal(let id)? = dataSource.itemIdentifier(for: path) { return goalMenu(id) }   // [goals]
        guard let id = taskID(at: path), let task = store.task(id) else { return nil }
        let stale = isStale(path)
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            let keep = UIAction(title: "Keep", image: UIImage(systemName: "pin")) { [weak self] _ in self?.keep(id) }
            // [goals] Add to Goal, beside Move To (docs/goals.md "A task in a goal").
            let goalRow: [UIMenuElement] = GoalChoices.menu(for: id, store: self.store) { [weak self] goal in self?.openGoal(goal) }.map { [$0] } ?? []
            var triage: [UIMenuElement] = [
                UIMenu(title: "Schedule", subtitle: task.due.flatMap { _ in TodoWords.dueTile(task, now: Date()) },
                       image: UIImage(systemName: "calendar"), children: self.scheduleChoices(for: [id])),
            ]
            if self.store.fieldsSupported {
                triage.append(UIMenu(title: "Priority", subtitle: task.priority > 0 ? TodoViews.priorityWord(task.priority) : nil,
                                     image: UIImage(systemName: "flag"), children: self.priorityChoices(for: [id])))
            }
            let assignItems = self.assignChoices(for: task)
            if !assignItems.isEmpty {
                triage.append(UIMenu(title: "Assign", subtitle: TodoViews.who(task, botName: self.botName),
                                     image: UIImage(systemName: "person.2"), children: assignItems))
            }
            triage.append(UIMenu(title: "Move To", subtitle: self.listName(task.section),
                                 image: UIImage(systemName: "folder"), children: self.moveChoices(for: [id])))
            triage += goalRow
            return UIMenu(children: [
                UIMenu(options: .displayInline, children: (stale ? [keep] : []) + [
                    UIAction(title: "Open Task", image: UIImage(systemName: "arrow.up.forward.square")) { [weak self] _ in self?.openTask(id) },
                    UIAction(title: task.isDone ? "Mark Not Done" : "Mark Done",
                             image: UIImage(systemName: task.isDone ? "circle" : "checkmark.circle")) { [weak self] _ in self?.toggleDone(id) },
                ]),
                UIMenu(options: .displayInline, children: triage),
                UIMenu(options: .displayInline, children: [
                    UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                        self?.duplicateTask(id)
                    },
                    UIAction(title: "Select", image: UIImage(systemName: "checkmark.circle.badge.plus")) { [weak self] _ in
                        guard let self else { return }
                        self.setSelecting(true)
                        self.togglePicked(id)
                    },
                ]),
                UIAction(title: "Delete…", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    guard let self else { return }
                    self.confirmDelete(id, source: self.dataSource.indexPath(for: .task(id)).flatMap { self.collectionView.cellForItem(at: $0) })
                },
            ])
        }
    }

    /// "Delete “…”?" first, as Jobs and Kanban ask (a delete can't be undone: the task goes for you and your bots).
    private func confirmDelete(_ id: String, source: UIView?) {
        guard !store.readOnlyGateway else { notices.show(JobsStore.readOnlyNotice); return }
        guard let task = store.task(id), presentedViewController == nil else { return }
        let title = task.title.isEmpty ? "Untitled Task" : task.title
        let sheet = UIAlertController(title: "Delete “\(title)”?", message: "It goes from the list for you and your bots.",
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Delete Task", style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task {
                if await self.store.delete(id) { PagesHaptics.success() } else { PagesHaptics.error() }
            }
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = source ?? view
            popover.sourceRect = source?.bounds ?? CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        present(sheet, animated: true)
    }

    private func leadingSwipe(_ path: IndexPath) -> UISwipeActionsConfiguration? {
        guard !selecting else { return nil }
        if let id = ideaID(at: path) { return ideaSwipe(id, leading: true) }
        guard let id = taskID(at: path), let task = store.task(id) else { return nil }
        let done = UIContextualAction(style: .normal, title: task.isDone ? "Not Done" : "Done") { [weak self] _, _, finish in
            self?.toggleDone(id)
            finish(true)
        }
        done.image = UIImage(systemName: task.isDone ? "arrow.uturn.backward" : "checkmark")
        done.backgroundColor = task.isDone ? HQPalette.tint : .systemGreen
        let config = UISwipeActionsConfiguration(actions: [done])
        config.performsFirstActionWithFullSwipe = true
        return config
    }

    private func trailingSwipe(_ path: IndexPath) -> UISwipeActionsConfiguration? {
        guard !selecting else { return nil }
        if let id = ideaID(at: path) { return ideaSwipe(id, leading: false) }
        guard let id = taskID(at: path) else { return nil }
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, view, finish in
            guard let self else { finish(false); return }
            // A full swipe asks first; it never deletes by itself.
            self.confirmDelete(id, source: self.collectionView.cellForItem(at: path) ?? view)
            finish(false)
        }
        delete.image = UIImage(systemName: "trash.fill")
        var actions = [delete]
        if let task = store.task(id), !task.isDone {
            let schedule = UIContextualAction(style: .normal, title: "Schedule") { [weak self] _, view, finish in
                guard let self else { finish(false); return }
                self.showScheduleSheet(for: id, source: self.collectionView.cellForItem(at: path) ?? view)
                finish(true)
            }
            schedule.image = UIImage(systemName: "calendar")
            schedule.backgroundColor = HQPalette.tint
            actions.append(schedule)
        }
        if isStale(path) {
            // "Still Need These?": Keep beside Delete (a full swipe still deletes, as on every row).
            let keep = UIContextualAction(style: .normal, title: "Keep") { [weak self] _, _, finish in
                self?.keep(id)
                finish(true)
            }
            keep.image = UIImage(systemName: "pin.fill")
            keep.backgroundColor = HQPalette.tint
            actions.append(keep)
        }
        let config = UISwipeActionsConfiguration(actions: actions)
        config.performsFirstActionWithFullSwipe = true
        return config
    }
}

#if targetEnvironment(macCatalyst)
extension TasksViewController: PaneListEmptiness {}   // [mac] #57
#endif

/// [goals] A goal card on its way to a new place among the active goals.
private final class GoalDrag: NSObject {
    let id: String
    init(id: String) { self.id = id }
}

/// A task's row: tells its page how tall it came out (`TasksViewController.footRoom`).
private final class TaskListCell: SoftCardListCell {
    var onMeasure: ((CGFloat) -> Void)?

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let fitted = super.preferredLayoutAttributesFitting(layoutAttributes)
        onMeasure?(fitted.size.height)
        return fitted
    }
}
