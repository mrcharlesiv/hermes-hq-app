// [tasks] The Tasks page (docs/tasks.md, owner-approved mockup 1-list 2026-11-04): To Do | Ideas at the top
// ([task-ideas] in the place of the quick add, owner 2026-11-05), then Ready for You (green sparkle), Needs You, Overdue, Today, Bots' Tasks, Upcoming, No Date and Done (folded).
// All Bots, search, ⋯ and + in the bar. Tap a circle to tick a task, a row to open it; swipe for Done and Delete.
// Painted from disk in the first frame, then read; read again on appear, on foreground and after a task push.

import SwiftUI
import UIKit

final class TasksViewController: UIViewController, UICollectionViewDelegate, UISearchResultsUpdating,
                                  UICollectionViewDragDelegate, UICollectionViewDropDelegate {
    /// `.user(id)`: one of your sections under Group By › My Sections ("" is No Section).
    private nonisolated enum Section: Hashable { case mode, ideas, group(TodoSection), user(String), newSection, skeleton, count }
    private nonisolated enum Item: Hashable {
        case mode, task(String), showDone, skeleton(Int), count(String), empty(String), newSection
        case ideaStatus, idea(String), ideaNote(TaskIdeasNote)
    }

    /// The page shows somewhere (an add-on without Tasks is asked again on foreground only then).
    static var onScreen = false

    let store: TasksStore
    let scope: PagesScope
    private let context: MorePages.Context
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var rows: [String: TodoRowModel] = [:]
    private var sections: [(TodoSection, [String])] = []
    /// My Sections: each shown section's task ids, in order.
    private var userGroups: [(String, [String])] = []
    /// Your sections folded shut on this device ("" is No Section).
    private var folded: Set<String> = []
    private var selecting = false
    /// Select: the tasks picked, in the order they were tapped.
    private var picked: [String] = []
    private var query = ""
    private var doneOpen = false
    private var ticking: Set<String> = []
    private var notices: PageNoticeHost!
    /// Where a held task would land (section and index): a tick each time it moves to a new place.
    private var dropPlace: String?
    private let scopeItem = ScopeBarItem()
    /// [bot-pills] The bots as Sessions' pills under the bar (iPhone and iPad), in place of "All Bots ⌄", with Me after
    /// All for your own tasks (owner 2026-11-05).
    private lazy var pills = BotPillHeader(identifier: "tasks.chip", me: true) { [weak self] bot in
        self?.scope.set(bot ?? PagesScope.all)
    }
    private var searchCapsule: PageBarCapsule?
    private var scopeObserver: UUID?
    private var minuteTimer: Timer?
    private var refreshStarted: Date?
    private var skeletonShown = false
    private var skeletonWork: DispatchWorkItem?
    private var shownDoneCount = 0
    private var updateAsked = false
    /// [task-ideas] To Do or Ideas: the page always opens on To Do.
    private var mode: TasksMode = .toDo
    private lazy var ideas: TaskIdeasStore = TaskIdeasStore(api: store.api, directory: store.directory)
    private var ideaCards: [String: TaskIdeaCardModel] = [:]
    /// Ideas being added (their buttons wait for the gateway).
    private var addingIdeas: Set<String> = []
    private var shownIdeaCards: [String: TaskIdeaCardModel] = [:]

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

    private func makeSelectMoveItem() -> UIBarButtonItem {
        let menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            MainActor.assumeIsolated { done(self?.selectionMoveChoices() ?? []) }
        }])
        let item = UIBarButtonItem(title: "Move To", image: UIImage(systemName: "folder"), menu: menu)
        item.accessibilityIdentifier = "tasks.select.move"
        DesktopBars.markThin(item)
        return item
    }
    private lazy var selectDoneItem: UIBarButtonItem = {
        let item = UIBarButtonItem(title: "Mark Done", image: UIImage(systemName: "checkmark.circle"),
                                   primaryAction: UIAction { [weak self] _ in self?.markSelectedDone() })
        item.accessibilityIdentifier = "tasks.select.mark-done"
        DesktopBars.markThin(item)
        return item
    }()
    private lazy var selectDeleteItem: UIBarButtonItem = {
        let item = UIBarButtonItem(title: "Delete", image: UIImage(systemName: "trash"),
                                   primaryAction: UIAction { [weak self] _ in self?.deleteSelected() })
        item.tintColor = .systemRed
        item.accessibilityIdentifier = "tasks.select.delete"
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

    init(store: TasksStore, context: MorePages.Context) {
        self.store = store
        self.context = context
        scope = PagesScope(account: context.account, key: TasksHub.scopeKey(context.account))
        super.init(nibName: nil, bundle: nil)
        title = "Tasks"
        Self.live.add(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var bots: [Bot] { context.bots }
    private func botName(_ profile: String?) -> String { PagesNames.botName(profile ?? "default", bots: bots) }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        pills.layout()
        hqPlaceMacEmptyTitle()
        fitWide()
    }

    // MARK: [mac-tools] The table over the window

    /// [mac-tools] Owner 2026-11-09 (the Tools sketch: pickers, filters and search in the top bar; no empty pane until
    /// you open one): on the Mac, with no task open beside it, Tasks has the window. Its rows are a table's (task,
    /// where it stands, the details, who has it), To Do | Ideas sits in the bar's middle and the bot picker is in
    /// words. With a task open beside it the list is the column it was. iPhone and iPad never see this.
    private(set) var isTable = false
    static let tableAt: CGFloat = 760

    private lazy var modeControl: UISegmentedControl = {
        let control = UISegmentedControl(items: ["To Do", "Ideas"])
        control.selectedSegmentIndex = 0
        control.addAction(UIAction { [weak self, weak control] _ in
            self?.setMode(control?.selectedSegmentIndex == 1 ? .ideas : .toDo)
        }, for: .valueChanged)
        control.accessibilityIdentifier = "tasks.mode.bar"
        control.setWidth(120, forSegmentAt: 0)
        control.setWidth(120, forSegmentAt: 1)
        // [mac-ten] Owner 2026-11-11 ("weird UI issues"): as the bar's title view it was stretched to 48 pt, a third
        // taller than Artifacts' filter in the same place on its page (36 pt). The two are one height.
        control.translatesAutoresizingMaskIntoConstraints = false
        let height = control.heightAnchor.constraint(equalToConstant: Self.barControlHeight)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        return control
    }()
    static let barControlHeight: CGFloat = 36

    private var barMiddle: UIView?

    private func fitWide() {
        let wide = DeviceWord.isMac && view.bounds.width >= Self.tableAt
        guard wide != isTable else { return }
        isTable = wide
        scopeItem.compact = !wide
        reload(animated: false)
    }

    /// To Do | Ideas in the bar while the table shows; the list's own first row otherwise.
    private func fitModeBar(shown: Bool) {
        guard DeviceWord.isMac else { return }
        if shown {
            let count = newIdeasCount
            modeControl.setTitle(count > 0 ? "Ideas \(count)" : "Ideas", forSegmentAt: 1)
            modeControl.selectedSegmentIndex = mode == .ideas ? 1 : 0
            if navigationItem.titleView !== modeControl {
                barMiddle = navigationItem.titleView   // the empty middle a place's leading title leaves (MacPlaceTitle)
                navigationItem.titleView = modeControl
            }
        } else if navigationItem.titleView === modeControl {
            navigationItem.titleView = barMiddle
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        settleTitle()
        // [mac] The list pane is narrow: "All Bots" in words beside ⋯, + and the magnifier squeezed "Tasks" to "…".
        if DeviceWord.isMac { scopeItem.compact = true }
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
        folded = Set(UserDefaults.standard.stringArray(forKey: foldedKey) ?? [])
        view.addSubview(collectionView)
        ListBarAppearance.pinTitle(in: self, softEdgeAround: collectionView)
        let backdrop = PageBackdrop.install(in: self, clearing: [collectionView])
        pills.install(in: self, list: collectionView, backdrop: backdrop)
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
        store.onChange = { [weak self] in self?.setNeedsReload() }
        ideas.onChange = { [weak self] in
            guard let self else { return }
            if let page = self.ideas.page { self.store.ideasRead(page.on ? self.ideas.shown.count : 0) }
            self.setNeedsReload()
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
            let root = (sheet as? UINavigationController)?.viewControllers.first ?? sheet
            if let model = TodoSheet.model(of: root) {
                model.show(text)
            } else if let host = root as? NewTodoHost, host.model.saving {
                return   // New Task says why on its own line
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
            title = "Tasks"
            return
        }
        titleSettled = true
        // [mac] Mac polish #59 (owner's call 2026-11-07): on the Mac Tasks is one of the sidebar's Tools, which have the
        // small centred title (Files, Kanban, Terminal…); the big heading is for Sessions, Jobs and Artifacts.
        let tabRoot = !DeviceWord.isMac && navigation.viewControllers.first === self && navigation is PaneNavigationController
        if tabRoot {
            PageChrome.applyListHeader(to: self, title: "Tasks")
        } else {
            pushed = true
            navigationItem.largeTitleDisplayMode = .never
            scopeItem.compact = !isTable
            ListBarAppearance.dropLookTitle(navigationItem)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        settleTitle()
        super.viewWillAppear(animated)
        Self.onScreen = true
        searchCapsule?.restoreIfTyped()
        claimStore()
        store.readOnlyGateway = context.readOnly
        reload(animated: false)
        startMinuteClock()
        Task { await store.refresh() }
        if mode == .ideas { Task { await ideas.refresh() } }
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
        Self.onScreen = false
        minuteTimer?.invalidate()
        minuteTimer = nil
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
            // [backdrop-cards] The tasks' groups and ideas; the picker, the count line and New Section stay as they are.
            let carded: Bool = switch self?.dataSource?.sectionIdentifier(for: index) { case .group?, .user?, .ideas?: true; default: false }
            let onCards = carded && BackdropCards.on(self)
            // The first card stands clear of the bar's buttons, as Bots' first card does (its header sat right under).
            if onCards && index == 0 { layout.contentInsets.top += BackdropCards.gap }
            BackdropCards.card(layout, on: onCards)
            return layout
        }
        BackdropCards.register(in: cards)   // [backdrop-cards]
        return cards
    }

    private static func rowBackground(_ cell: UICollectionViewListCell, _ state: UICellConfigurationState) {
        #if targetEnvironment(macCatalyst)
        if DeviceWord.isMac { cell.backgroundConfiguration = MacSelection.listRow(state); return }
        #endif
        if Theme.isDesktop { cell.backgroundConfiguration = DesktopLayout.rowBackground(state); return }
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = state.isHighlighted || state.isSelected ? HQPalette.cellPressed : .clear
        cell.backgroundConfiguration = background
    }

    private func configureDataSource() {
        let taskCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let self, let row = self.rows[id] else { return }
            cell.contentConfiguration = UIHostingConfiguration {
                TodoRowView(row: row) { [weak self] in self?.toggleDone(id) }
            }.margins(.all, 0)
            cell.accessibilityIdentifier = "task-row-\(row.title)"
            cell.accessibilityTraits = row.picked ? [.button, .selected] : .button
            cell.configurationUpdateHandler = { cell, state in Self.rowBackground(cell as! UICollectionViewListCell, state) }
        }
        let modeCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            let mode = self.mode, count = self.newIdeasCount
            cell.contentConfiguration = UIHostingConfiguration {
                TasksModeSwitch(ideas: count, mode: mode) { [weak self] next in self?.setMode(next) }
            }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        let ideaCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let self, let card = self.ideaCards[id] else { return }
            let enabled = !self.store.readOnlyGateway
            cell.contentConfiguration = UIHostingConfiguration {
                TaskIdeaCard(card: card, enabled: enabled,
                             add: { [weak self] start in self?.addIdea(id, start: start) },
                             dismiss: { [weak self] in self?.dismissIdea(id) })
            }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        let ideaStatusCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            guard let self, let page = self.ideas.page else { return }
            let heads = Dictionary(self.bots.map { ($0.id, $0.head) }, uniquingKeysWith: { first, _ in first })
            let enabled = !self.store.readOnlyGateway
            cell.contentConfiguration = UIHostingConfiguration {
                TaskIdeasStatusRow(botName: self.botName(page.bot), head: heads[page.bot] ?? nil, profile: page.bot, at: page.at,
                                   ranAt: page.ranAt, looking: page.looking, enabled: enabled) { [weak self] in self?.lookForIdeas() }
            }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        let ideaNoteCell = UICollectionView.CellRegistration<UICollectionViewListCell, TaskIdeasNote> { [weak self] cell, _, note in
            let enabled = !(self?.store.readOnlyGateway ?? true)
            cell.contentConfiguration = UIHostingConfiguration {
                TaskIdeasNoteView(note: note, enabled: enabled,
                                  primary: { [weak self] in self?.notePrimary(note) },
                                  secondary: { [weak self] in self?.importReminders() })
            }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        let doneCell = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { cell, _, count in
            cell.contentConfiguration = UIHostingConfiguration { ShowDoneRowView(count: count) }.margins(.all, 0)
            cell.accessibilityIdentifier = "tasks.show-done"
            cell.backgroundConfiguration = .clear()
        }
        let countCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { cell, _, text in
            cell.contentConfiguration = UIHostingConfiguration { PageCountView(text: text) }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        let emptyCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { cell, _, id in
            cell.contentConfiguration = UIHostingConfiguration { TodoEmptySectionRow() }.margins(.all, 0)
            cell.accessibilityIdentifier = "tasks.section-empty.\(id)"
            cell.backgroundConfiguration = .clear()
        }
        let newSectionCell = UICollectionView.CellRegistration<UICollectionViewListCell, Bool> { cell, _, _ in
            cell.contentConfiguration = UIHostingConfiguration { TodoNewSectionRow() }.margins(.all, 0)
            cell.accessibilityIdentifier = "tasks.new-section"
            cell.backgroundConfiguration = .clear()
        }
        let skeletonCell = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { cell, _, _ in
            cell.contentConfiguration = UIHostingConfiguration { PageSkeletonRow() }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader) { [weak self] header, _, path in
            guard let self, let section = self.dataSource.sectionIdentifier(for: path.section) else { return }
            self.configureHeader(header, section)
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { [weak self] cv, path, item in
            switch item {
            case .mode: return cv.dequeueConfiguredReusableCell(using: modeCell, for: path, item: item)
            case .ideaStatus: return cv.dequeueConfiguredReusableCell(using: ideaStatusCell, for: path, item: item)
            case .idea(let id): return cv.dequeueConfiguredReusableCell(using: ideaCell, for: path, item: id)
            case .ideaNote(let note): return cv.dequeueConfiguredReusableCell(using: ideaNoteCell, for: path, item: note)
            case .task(let id): return cv.dequeueConfiguredReusableCell(using: taskCell, for: path, item: id)
            case .showDone:
                let count = self?.sections.first { $0.0 == .done }?.1.count ?? 0
                return cv.dequeueConfiguredReusableCell(using: doneCell, for: path, item: count)
            case .skeleton(let n): return cv.dequeueConfiguredReusableCell(using: skeletonCell, for: path, item: n)
            case .count(let text): return cv.dequeueConfiguredReusableCell(using: countCell, for: path, item: text)
            case .empty(let id): return cv.dequeueConfiguredReusableCell(using: emptyCell, for: path, item: id)
            case .newSection: return cv.dequeueConfiguredReusableCell(using: newSectionCell, for: path, item: true)
            }
        }
        dataSource.supplementaryViewProvider = { cv, _, path in cv.dequeueConfiguredReusableSupplementary(using: header, for: path) }
    }

    private func hasHeader(_ section: Section) -> Bool {
        switch section {
        case .group: return true
        case .user(let id): return !id.isEmpty || !store.sections.isEmpty
        default: return false
        }
    }

    private func configureHeader(_ header: UICollectionViewListCell, _ section: Section) {
        switch section {
        case .group(let group): configureHeader(header, group)
        case .user(let id): configureUserHeader(header, id)
        default: break
        }
    }

    private func configureUserHeader(_ header: UICollectionViewListCell, _ id: String) {
        let ids = userGroups.first { $0.0 == id }?.1 ?? []
        let name = sectionName(id)
        let index = store.sections.firstIndex { $0.id == id }
        let menu = index.map { at in
            TodoUserSectionHeaderView.Menu(
                add: { [weak self] in self?.newTask(section: id) },
                rename: { [weak self] in self?.renameSection(id) },
                moveUp: at > 0 ? { [weak self] in self?.moveSection(id, by: -1) } : nil,
                moveDown: at < store.sections.count - 1 ? { [weak self] in self?.moveSection(id, by: 1) } : nil,
                delete: { [weak self] in self?.deleteSection(id) })
        }
        let isFolded = folded.contains(id) && query.isEmpty
        header.contentConfiguration = UIHostingConfiguration {
            TodoUserSectionHeaderView(name: name, count: ids.count, folded: isFolded,
                                      toggle: { [weak self] in self?.toggleFold(id) }, menu: menu)
        }.margins(.all, 0)
        header.backgroundConfiguration = .clear()
        header.accessibilityIdentifier = "tasks.user-section.\(name)"
    }

    private func sectionName(_ id: String) -> String {
        id.isEmpty ? "No Section" : (store.sections.first { $0.id == id }?.name ?? "Section")
    }

    private func configureHeader(_ header: UICollectionViewListCell, _ section: TodoSection) {
        let count = sections.first { $0.0 == section }?.1.count ?? 0
        let open = doneOpen || !query.isEmpty
        let toggle: (() -> Void)? = section == .done && query.isEmpty ? { [weak self] in self?.toggleDoneSection() } : nil
        header.contentConfiguration = UIHostingConfiguration {
            TodoSectionHeaderView(section: section, count: count, open: open, toggle: toggle)
        }.margins(.all, 0)
        header.backgroundConfiguration = .clear()
        header.accessibilityIdentifier = "tasks.section.\(section.rawValue)"
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
        let current = scope.effective(bots: bots)
        let all = store.tasks
        let visible = TodoSections.filtered(all, scope: current, query: query)
        let heads = Dictionary(bots.map { ($0.id, $0.head) }, uniquingKeysWith: { first, _ in first })
        var nextRows: [String: TodoRowModel] = [:]
        // A task ticked here stays where it was until it moves (a moment later), so the tick shows first.
        let layout = store.settings
        let mine = layout.groupsBySections
        let grouped: [(TodoSection, [TodoTask])]
        if mine {
            let split = TodoSections.byUserSection(visible, sections: store.sections, sort: layout.sort)
            let whole = query.isEmpty && current == PagesScope.all
            // No Section shows when it has tasks (or is all there is); an empty section of yours shows while nothing
            // is filtered out, so there's somewhere to drag a task to.
            userGroups = split.open.filter { id, items in
                id.isEmpty ? (!items.isEmpty || store.sections.isEmpty) : (!items.isEmpty || whole)
            }.map { ($0.0, $0.1.map(\.id)) }
            grouped = split.done.isEmpty ? [] : [(.done, split.done)]
            for task in split.open.flatMap(\.1) {
                nextRows[task.id] = rowModel(task, section: TodoSections.section(task, now: now), now: now, heads: heads)
            }
        } else {
            userGroups = []
            grouped = TodoSections.grouped(visible, now: now, sort: layout.sort)
        }
        sections = grouped.map { ($0.0, $0.1.map(\.id)) }
        for (section, items) in grouped {
            for task in items { nextRows[task.id] = rowModel(task, section: section, now: now, heads: heads) }
        }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        // [task-ideas] To Do | Ideas heads the page whenever the list is in hand, an empty one too.
        let switchShown = store.hasList && !store.needsAddOn
        let ideasShown = switchShown && mode == .ideas
        // Nothing here: no tasks at all, or none with the bot (or of your own) picked in the pills.
        let nothing = visible.isEmpty && query.isEmpty
        let showsList = switchShown && !ideasShown && !nothing
        fitModeBar(shown: switchShown && isTable && !selecting)
        if switchShown, !isTable {   // [mac-tools] the table has the switch in its bar
            snapshot.appendSections([.mode])
            snapshot.appendItems([.mode], toSection: .mode)
        }
        if ideasShown {
            appendIdeas(to: &snapshot, scope: current, heads: heads)
        } else if switchShown && nothing {
            snapshot.appendSections([.ideas])
            let text = Self.nothingText(scope: all.isEmpty ? PagesScope.all : current, botName: botName(current))
            snapshot.appendItems([.ideaNote(.noTasks(text: text, imports: all.isEmpty || current == PagesScope.me))], toSection: .ideas)
        }
        if !store.hasList && store.loading && skeletonShown {
            snapshot.appendSections([.skeleton])
            snapshot.appendItems((0..<8).map { .skeleton($0) }, toSection: .skeleton)
        }
        let open = doneOpen || !query.isEmpty
        if showsList {
            for (id, ids) in userGroups {
                snapshot.appendSections([.user(id)])
                guard !folded.contains(id) || !query.isEmpty else { continue }
                snapshot.appendItems(ids.isEmpty ? [.empty(id)] : ids.map { .task($0) }, toSection: .user(id))
            }
            if mine, query.isEmpty, !selecting {
                snapshot.appendSections([.newSection])
                snapshot.appendItems([.newSection], toSection: .newSection)
            }
            for (section, ids) in sections {
                snapshot.appendSections([.group(section)])
                if section == .done && !open {
                    snapshot.appendItems([.showDone], toSection: .group(section))
                } else {
                    snapshot.appendItems(ids.map { .task($0) }, toSection: .group(section))
                }
            }
            let open = visible.filter { !$0.isDone }.count
            if !visible.isEmpty {
                snapshot.appendSections([.count])
                snapshot.appendItems([.count(open == 1 ? "1 to do" : "\(open) to do")], toSection: .count)
            }
        }
        let previousIdeaCards = shownIdeaCards
        shownIdeaCards = ideaCards
        var changed = snapshot.itemIdentifiers.compactMap { item -> Item? in
            guard case .task(let id) = item, let old = rows[id], old != nextRows[id] else { return nil }
            return item
        }
        let doneCount = sections.first { $0.0 == .done }?.1.count ?? 0
        if doneCount != shownDoneCount, snapshot.itemIdentifiers.contains(.showDone) { changed.append(.showDone) }
        shownDoneCount = doneCount
        rows = nextRows
        // The switch's count and who looks (and when) follow every read.
        changed += snapshot.itemIdentifiers.filter { item in
            switch item {
            case .mode, .ideaStatus: return true
            case .idea(let id): return previousIdeaCards[id] != nil && previousIdeaCards[id] != ideaCards[id]
            default: return false
            }
        }
        if !changed.isEmpty { snapshot.reconfigureItems(changed) }
        dataSource.apply(snapshot, animatingDifferences: animated && !HQMotion.reduced)
        if paneKeepsSelection { markOnShow(onShowTask, keepsSelection: true) }   // [mac] #41
        notePaneListEmpty(!snapshot.itemIdentifiers.contains { $0 == .showDone || taskID(of: $0) != nil })   // [mac] #57
        refreshHeaders()
        addItem.isEnabled = !store.readOnlyGateway && !store.needsAddOn
        pills.update(bots: bots, picked: current)
        if selecting {
            updateSelectionBar()
        } else {
        // [Filter] [Search] [+], as Sessions: Show Done, Import and Settings sit under the bots in Filter's menu.
        // [bot-pills] With the pills under the bar they keep their own ⋯, as with one bot: [⋯] [Search] [+].
        scopeItem.update(scope: scope, bots: bots, on: navigationItem, extra: [addItem], search: searchCapsule?.searchItem,
                         menuExtra: UIDeferredMenuElement.uncached { [weak self] done in
                             MainActor.assumeIsolated { done(self?.menuItems() ?? []) }
                         }, alone: moreItem, pills: pills.shows, me: true)
        }
        updateEmptyState(hasTasks: !all.isEmpty || switchShown && query.isEmpty, visibleCount: ideasShown ? 1 : visible.count)
        scheduleSkeleton()
        if let started = refreshStarted, !store.loading {
            let wait = max(0, 0.5 - Date().timeIntervalSince(started))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.refreshStarted = nil
                self?.collectionView.refreshControl?.endRefreshing()
            }
        }
    }

    private func rowModel(_ task: TodoTask, section: TodoSection, now: Date, heads: [String: JSONValue?]) -> TodoRowModel {
        let helper = task.helper
        return TodoRowModel(
            id: task.id, title: task.title.isEmpty ? "Untitled Task" : task.title,
            line: TodoWords.rowLine(task, section: section, now: now, botName: { [bots] in PagesNames.botName($0 ?? "default", bots: bots) }),
            done: task.isDone, ticking: ticking.contains(task.id),
            leadFace: task.whoKind == .bot ? helper : nil,
            trailFace: task.whoKind == .together ? helper : nil,
            head: helper.flatMap { heads[$0] ?? nil },
            selecting: selecting, picked: picked.contains(task.id),
            wide: isTable, who: TodoWords.whoWords(task, botName: { [bots] in PagesNames.botName($0 ?? "default", bots: bots) }))
    }

    private func refreshHeaders() {
        for path in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: UICollectionView.elementKindSectionHeader) {
            guard let header = collectionView.supplementaryView(forElementKind: UICollectionView.elementKindSectionHeader, at: path)
                    as? UICollectionViewListCell,
                  let section = dataSource.sectionIdentifier(for: path.section) else { continue }
            configureHeader(header, section)
        }
    }

    private func updateEmptyState(hasTasks: Bool, visibleCount: Int) {
        if store.needsAddOn {
            var state = PageStates.empty(symbol: "puzzlepiece.extension", title: "Update the Add-on",
                                         text: "Tasks needs \(AddOnUpdate.pushName) 0.9.32 or later on \(HostWord.phrase).")   // Mac polish #139
            var button = UIButton.Configuration.hqMacPush(or: .filled(), capsule: true)
            button.title = updateAsked ? "Updating…" : "Update Add-on"
            state.button = button
            state.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.updateAddOn() }
            showEmpty(state)
            hqPlaceMacEmptyTitle()
            return
        }
        if visibleCount > 0 || (!store.hasList && store.loading) || (hasTasks && query.isEmpty) {
            showEmpty(nil)
            return
        }
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            showEmpty(PageStates.searchMiss(query.trimmingCharacters(in: .whitespaces)))
        } else if !store.hasList, let reason = store.error {
            showEmpty(PageStates.error(title: "Couldn’t Load Tasks", reason: reason) { [weak self] in
                Task { await self?.store.refresh(force: true) }
            })
        } else if store.hasList {
            let current = scope.effective(bots: bots)
            let text = Self.nothingText(scope: current, botName: botName(current))
            var state = PageStates.empty(symbol: "checklist", title: "No Tasks", text: text)
            var button = UIButton.Configuration.hqMacPush(or: .filled(), capsule: true)
            button.title = "New Task"
            state.button = button
            state.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.newTask() }
            var second = UIButton.Configuration.hqMacPush(or: .plain())
            second.title = "Import from Reminders"
            state.secondaryButton = second
            state.secondaryButtonProperties.primaryAction = UIAction { [weak self] _ in self?.importReminders() }
            showEmpty(state)
        } else {
            showEmpty(nil)
        }
        hqPlaceMacEmptyTitle()
    }

    /// Ideas under Me (your own tasks have no ideas). [mac] Mac polish #138: the Mac has no All pill; its All Bots is in
    /// the bar's menu.
    static func ideasFromBotsText(mac: Bool) -> String {
        mac ? "Ideas come from your bots. Choose All Bots to see them." : "Ideas come from your bots. Tap All to see them."
    }

    /// What the page says with nothing to show: the whole list is empty, or nothing is with the bot picked in the pills
    /// (or of your own, under Me).
    static func nothingText(scope: String, botName: String) -> String {
        if scope == PagesScope.all { return "Add what you need to do. Bots add tasks from your chats too, and get their part ready for you." }
        return scope == PagesScope.me ? "Nothing of your own yet." : "Nothing with \(botName) yet."
    }

    /// [bot-pills] The empty state. Under the pills it is the list's background, as Sessions' is: UIKit's own
    /// (`contentUnavailableConfiguration`) lies over the whole page in front of every subview and took the taps meant
    /// for the pills. Without them (the Mac, one bot) it stays UIKit's, placed by `hqPlaceMacEmptyTitle`.
    private func showEmpty(_ state: (any UIContentConfiguration)?) {
        let state = BackdropState.wrap(state)   // [backdrop-cards] a soft card behind it on Soft Cards
        guard pills.shows else {
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
        if mode == .ideas { Task { await ideas.refresh(force: true) } }
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
        let layout = store.settings
        let groups: [(String, String, String)] = [("smart", "Smart", "sparkles"), ("sections", "My Sections", "rectangle.split.1x2")]
        let sorts: [(String, String, String)] = [
            ("smart", layout.groupsBySections ? "My Order" : "Smart", layout.groupsBySections ? "hand.draw" : "sparkles"),
            ("due", "Due Date", "calendar"), ("added", "Date Added", "clock"),
        ]
        let groupMenu = UIMenu(title: "Group By", subtitle: groups.first { $0.0 == layout.group }?.1, image: UIImage(systemName: "square.stack"),
                               options: .singleSelection, children: groups.map { key, title, symbol in
            UIAction(title: title, image: UIImage(systemName: symbol), state: layout.group == key ? .on : .off) { [weak self] _ in
                self?.setLayout(group: key)
            }
        })
        let sortMenu = UIMenu(title: "Sort By", subtitle: sorts.first { $0.0 == layout.sort }?.1, image: UIImage(systemName: "arrow.up.arrow.down"),
                              options: .singleSelection, children: sorts.map { key, title, symbol in
            UIAction(title: title, image: UIImage(systemName: symbol), state: layout.sort == key ? .on : .off) { [weak self] _ in
                self?.setLayout(sort: key)
            }
        })
        var organize: [UIMenuElement] = [groupMenu, sortMenu]
        if layout.groupsBySections {
            organize.append(UIAction(title: "New Section…", image: UIImage(systemName: "plus.rectangle.on.rectangle")) { [weak self] _ in
                self?.promptNewSection(moving: [])
            })
        }
        organize.append(UIAction(title: "Select Tasks", image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in
            self?.setSelecting(true)
        })
        return [
            UIMenu(options: .displayInline, children: organize),
            UIMenu(options: .displayInline, children: [
                UIAction(title: doneOpen ? "Hide Done" : "Show Done", image: UIImage(systemName: doneOpen ? "eye.slash" : "eye")) { [weak self] _ in
                    self?.toggleDoneSection()
                },
                UIAction(title: "Import from Reminders…", image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
                    self?.importReminders()
                },
            ]),
            UIAction(title: "Tasks Settings…", image: UIImage(systemName: "gearshape")) { [weak self] _ in self?.openSettings() },
        ]
    }

    private func toggleDone(_ id: String) {
        guard let task = store.task(id) else { return }
        if task.isDone {
            PagesHaptics.selection()
            Task { if await !store.setDone(id, false) { PagesHaptics.error() } }
            return
        }
        // The circle fills, the title strikes through; a moment later the task moves to Done.
        PagesHaptics.success()
        ticking.insert(id)
        reload(animated: false)
        HQAnnounce.say("Done: \(task.title)")
        DispatchQueue.main.asyncAfter(deadline: .now() + (HQMotion.reduced ? 0.1 : 0.6)) { [weak self] in
            guard let self else { return }
            Task {
                if await !self.store.setDone(id, true) { PagesHaptics.error() }   // the notice says why
                self.ticking.remove(id)
                self.reload(animated: true)
            }
        }
    }

    func newTask(section: String? = nil) {
        guard !store.readOnlyGateway else { notices.show(JobsStore.readOnlyNotice); return }
        PagesHaptics.selection()
        let current = scope.effective(bots: bots)
        let sheet = NewTodoSheet.make(store: store, bots: bots, preferredBot: current == PagesScope.all || current == PagesScope.me ? nil : current,
                                      section: section) { [weak self] task in
            guard let self, let task else { return }
            self.reload(animated: true)
            // A bot asked to help hears about it now, in the task's own chat on its page, and says what it would take.
            if task.helper != nil {
                self.openTask(task.id, asking: TodoWords.helpQuestion)
            } else {
                self.notices.show("Added “\(task.title)”")
            }
        }
        present(sheet, animated: true)
    }

    /// `asking`: the question goes into the task's own chat at once (New Task with a bot). `atReply`: the page opens at
    /// its chat's newest end (a reply's alert), not the task's top.
    func openTask(_ id: String, asking question: String? = nil, atReply: Bool = false) {
        guard store.task(id) != nil || store.hasList == false else {
            notices.show("That task isn’t on the list anymore.")
            return
        }
        if let presented = presentedViewController { presented.dismiss(animated: false) }
        reveal(id)
        #if targetEnvironment(macCatalyst)
        if (tabBarController as? MainTabController)?.split?.isDouble == true {
            let page = TodoSheet.page(taskID: id, store: store, context: context)
            TodoSheet.model(of: page)?.onMarkedDone = { [weak self] task in self?.offerUndoDone(task) }
            if atReply { (page as? ChatViewController)?.opensAtNewest(); TodoSheet.model(of: page)?.tuck(.alert) }   // the reply first, the task as its bar
            if isTable { MacDash.closes(page) }   // [mac-tools] the table takes the window back
            openDetail(page, animated: question == nil)
            markOnShow(id, keepsSelection: true)   // [mac] #41
            if let question, let task = store.task(id) { TodoSheet.model(of: page)?.openChat(task, question: question) }
            return
        }
        #endif
        let sheet = TodoSheet.make(taskID: id, store: store, context: context)
        TodoSheet.model(of: sheet.viewControllers.first)?.onMarkedDone = { [weak self] task in self?.offerUndoDone(task) }
        if atReply {
            (sheet.viewControllers.first as? ChatViewController)?.opensAtNewest()
            TodoSheet.model(of: sheet.viewControllers.first)?.tuck(.alert)   // the reply first, the task as its bar
        }
        present(sheet, animated: true) { [weak self, weak sheet] in
            guard let self, let question, let task = self.store.task(id) else { return }
            TodoSheet.model(of: sheet?.viewControllers.first)?.openChat(task, question: question)
        }
    }

    /// [tasks] Marked done on its page (owner 2026-11-07, Pinned Task: Done in every state, with Undo): the page goes
    /// and the list says so, with Undo. A repeating task has already rolled on to its next date, so it has none.
    private func offerUndoDone(_ task: TodoTask) {
        guard task.repeatRule == nil || task.whoKind != .me else { return }
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

    // MARK: Ideas ([task-ideas])

    /// The switch's count: the Ideas page's own once read, else the list's.
    private var newIdeasCount: Int {
        if let page = ideas.page { return page.on ? ideas.shown.count : 0 }
        return store.ideasCount ?? 0
    }

    /// Opens Ideas (`-HQPagesTasksIdeas`, PagesDebug).
    func showIdeas() { setMode(.ideas) }

    private func setMode(_ next: TasksMode) {
        guard next != mode else { return }
        mode = next
        if next == .ideas {
            if selecting { setSelecting(false) }
            ideas.prepare()
            Task { await ideas.refresh() }
            // The list was last read whole before the add-on had Ideas (`ideas` absent), and `?since=` has said
            // "unchanged" ever since: read it whole again, or an add-on updated outside the app never shows Ideas.
            if store.ideasCount == nil { Task { await store.refresh(force: true) } }
        }
        reload(animated: false)
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
    }

    /// Ideas' rows: who looks with Look Now, the cards (newest first, the bot chip and search apply), and the line on
    /// where they come from; or the card that turns Ideas on, or asks for the newer add-on.
    private func appendIdeas(to snapshot: inout NSDiffableDataSourceSnapshot<Section, Item>, scope current: String,
                             heads: [String: JSONValue?]) {
        snapshot.appendSections([.ideas])
        ideaCards = [:]
        guard store.ideasCount != nil else {
            snapshot.appendItems([.ideaNote(.update(asked: updateAsked))], toSection: .ideas)
            return
        }
        guard let page = ideas.page else {
            if ideas.loading || ideas.error == nil {
                snapshot.appendItems((0..<3).map { .skeleton($0) }, toSection: .ideas)
            } else {
                snapshot.appendItems([.ideaNote(.failed(ideas.error ?? ""))], toSection: .ideas)
            }
            return
        }
        guard page.on else {
            snapshot.appendItems([.ideaNote(.intro(looker: botName(page.bot)))], toSection: .ideas)
            return
        }
        snapshot.appendItems([.ideaStatus], toSection: .ideas)
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = ideas.shown.filter { idea in
            (current == PagesScope.all || idea.bot == current)
                && (words.isEmpty || "\(idea.title) \(idea.why) \(idea.help)".lowercased().contains(words))
        }
        for idea in shown {
            ideaCards[idea.id] = TaskIdeaCardModel(idea: idea, botName: botName(idea.bot), head: heads[idea.bot] ?? nil,
                                                   busy: addingIdeas.contains(idea.id))
        }
        if shown.isEmpty {
            let text: String
            if !words.isEmpty {
                text = "No ideas match “\(query.trimmingCharacters(in: .whitespaces))”."
            } else if current == PagesScope.me && !ideas.shown.isEmpty {
                text = Self.ideasFromBotsText(mac: DeviceWord.isMac)   // [bot-pills] Me: no bot's ideas
            } else if current != PagesScope.all && !ideas.shown.isEmpty {
                text = "No ideas for \(botName(current)) right now."
            } else if page.looking {
                text = "\(botName(page.bot)) is looking now. New ideas show here in a minute or two."
            } else if page.ranAt == nil {
                text = "\(botName(page.bot)) looks for the first time at \(TaskIdeasStatusRow.time(page.at)). \(DeviceWord.Tap) Look Now to look sooner."
            } else {
                text = "\(botName(page.bot)) looks again at \(TaskIdeasStatusRow.time(page.at))."
            }
            snapshot.appendItems([.ideaNote(.empty(text))], toSection: .ideas)
        } else {
            snapshot.appendItems(shown.map { .idea($0.id) }, toSection: .ideas)
        }
        snapshot.appendItems([.ideaNote(.footer)], toSection: .ideas)
    }

    private func ideaID(at path: IndexPath) -> String? {
        guard case .idea(let id)? = dataSource.itemIdentifier(for: path) else { return nil }
        return id
    }

    private func idea(_ id: String) -> TaskIdea? { ideas.shown.first { $0.id == id } }

    /// The idea goes on To Do (with its bot starting on its part when `start`); "Show" opens the list at it.
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
            let words = start ? "Added. \(self.botName(idea.bot)) is starting on it." : "Added “\(task.title)” to To Do"
            HQAnnounce.say(words)
            self.notices.show(words, seconds: 5, action: ("Show", { [weak self] in
                self?.setMode(.toDo)
                self?.openTask(task.id)
            }))
        }
    }

    /// Gone from Ideas at once, for good; the Undo pill brings it back.
    private func dismissIdea(_ id: String) {
        guard !store.readOnlyGateway else { notices.show(JobsStore.readOnlyNotice); return }
        guard let idea = idea(id) else { return }
        PagesHaptics.selection()
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
        case .intro:
            guard !store.readOnlyGateway else { notices.show(JobsStore.readOnlyNotice); return }
            PagesHaptics.success()
            Task { await ideas.setOn(true, tasks: store) }
        case .update: updateAddOn()
        case .noTasks: newTask()
        case .failed:
            PagesHaptics.selection()
            Task { await ideas.refresh(force: true) }
        case .empty, .footer: break
        }
    }

    private func ideaMenu(_ id: String) -> UIContextMenuConfiguration? {
        guard let idea = idea(id) else { return nil }
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var adds: [UIMenuElement] = [
                UIAction(title: "Add to To Do", image: UIImage(systemName: "plus.circle")) { [weak self] _ in self?.addIdea(id, start: false) },
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

    // MARK: Sections (Group By › My Sections)

    private var foldedKey: String { "tasks.folded.\(context.account.id)" }

    private func setLayout(group: String? = nil, sort: String? = nil) {
        PagesHaptics.selection()
        Task { if await !store.setLayout(group: group, sort: sort) { PagesHaptics.error() } }
    }

    private func toggleFold(_ id: String) {
        guard query.isEmpty else { return }
        PagesHaptics.selection()
        if folded.contains(id) { folded.remove(id) } else { folded.insert(id) }
        UserDefaults.standard.set(Array(folded), forKey: foldedKey)
        reload(animated: true)
    }

    /// Asks for a name, makes the section, then moves `ids` into it (Move To › New Section…).
    private func promptNewSection(moving ids: [String], after: (() -> Void)? = nil) {
        guard !store.readOnlyGateway else { notices.show(JobsStore.readOnlyNotice); return }
        askName(title: "New Section", message: "Group your tasks your way, like Home, Work or Errands.", name: "", action: "Add") { [weak self] name in
            guard let self else { return }
            Task {
                guard let made = await self.store.addSection(named: name) else { PagesHaptics.error(); return }
                PagesHaptics.success()
                if self.store.settings.group != "sections" { await self.store.setLayout(group: "sections") }
                if !ids.isEmpty { await self.store.move(ids, to: made.id) }
                after?()
            }
        }
    }

    private func renameSection(_ id: String) {
        guard let section = store.sections.first(where: { $0.id == id }) else { return }
        askName(title: "Rename Section", message: nil, name: section.name, action: "Save") { [weak self] name in
            guard let self else { return }
            let next = self.store.sections.map { $0.id == id ? TodoUserSection(id: id, name: String(name.prefix(60))) : $0 }
            Task {
                if await self.store.saveSections(next) != nil { PagesHaptics.success() } else { PagesHaptics.error() }
            }
        }
    }

    private func moveSection(_ id: String, by offset: Int) {
        var next = store.sections
        guard let at = next.firstIndex(where: { $0.id == id }), next.indices.contains(at + offset) else { return }
        PagesHaptics.selection()
        next.swapAt(at, at + offset)
        Task { if await store.saveSections(next) == nil { PagesHaptics.error() } }
    }

    private func deleteSection(_ id: String) {
        let name = sectionName(id)
        let inside = store.tasks.filter { $0.section == id }
        let message = TodoWords.deleteSectionMessage(open: inside.filter { !$0.isDone }.count, done: inside.filter(\.isDone).count)
        let alert = UIAlertController(title: "Delete “\(name)”?", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete Section", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.folded.remove(id)
            // The result's cue, as Rename Section's (the confirm button was the press).
            Task {
                if await self.store.saveSections(self.store.sections.filter { $0.id != id }) != nil { PagesHaptics.success() } else { PagesHaptics.error() }
            }
        })
        present(alert, animated: true)
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
            field.placeholder = "Section Name"
            field.autocapitalizationType = .words
            field.returnKeyType = .done
            field.accessibilityIdentifier = "tasks.section-name"
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

    /// Move To's choices for `ids`: No Section, each of yours (a tick on where they all are now), New Section….
    private func moveChoices(for ids: [String], after: (() -> Void)? = nil) -> [UIMenuElement] {
        guard !ids.isEmpty else { return [] }
        let now = Set(ids.map { store.task($0)?.section ?? "" })
        let options = [("", "No Section")] + store.sections.map { ($0.id, $0.name) }
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
        let make = UIAction(title: "New Section…", image: UIImage(systemName: "plus")) { [weak self] _ in
            self?.promptNewSection(moving: ids, after: after)
        }
        return [UIMenu(options: .displayInline, children: places), make]
    }

    // MARK: Select

    private func setSelecting(_ on: Bool) {
        guard on != selecting else { return }
        if on { PagesHaptics.selection() }
        if on { mode = .toDo }   // tasks are picked on To Do
        selecting = on
        picked = []
        reload(animated: true)
    }

    private func selectionMoveChoices() -> [UIMenuElement] {
        moveChoices(for: selectedIDs()) { [weak self] in self?.setSelecting(false) }
    }

    private func selectedIDs() -> [String] { picked.filter { store.task($0) != nil } }

    private func togglePicked(_ id: String) {
        PagesHaptics.selection()
        if let at = picked.firstIndex(of: id) { picked.remove(at: at) } else { picked.append(id) }
        reload(animated: false)
    }

    /// Select's bar: Move To, Mark Done, Delete, then Done (as the page's own three buttons, then Done).
    private func updateSelectionBar() {
        let count = selectedIDs().count
        for item in [selectMoveItem, selectDoneItem, selectDeleteItem] { item.isEnabled = count > 0 && !store.readOnlyGateway }
        let items = [endSelectItem, selectDeleteItem, selectDoneItem, selectMoveItem]
        if navigationItem.rightBarButtonItems ?? [] != items { navigationItem.rightBarButtonItems = items }
    }

    private func markSelectedDone() {
        let ids = selectedIDs()
        guard !ids.isEmpty else { return }
        PagesHaptics.success()
        setSelecting(false)
        Task {
            var allDone = true
            for id in ids where store.task(id)?.isDone == false { if await !store.setDone(id, true) { allDone = false } }
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
                var allGone = true
                for id in ids where !(await self.store.delete(id)) { allGone = false }
                if allGone { PagesHaptics.success() } else { PagesHaptics.error() }
            }
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = selectDeleteItem
        present(sheet, animated: true)
    }

    // MARK: Drag a task to another section (My Sections)

    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession,
                        at indexPath: IndexPath) -> [UIDragItem] {
        guard store.settings.groupsBySections, !selecting, !store.readOnlyGateway, let id = taskID(at: indexPath),
              let task = store.task(id), !task.isDone else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider(object: task.title as NSString))
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

    /// The section a drop at `path` lands in, and the task ids it lands between.
    private func dropTarget(_ path: IndexPath?) -> (section: String, index: Int)? {
        guard let path, let section = dataSource.sectionIdentifier(for: path.section) else { return nil }
        switch section {
        case .user(let id): return (id, path.item)
        case .newSection:
            // Just past the last section: the end of it.
            guard let last = userGroups.last else { return nil }
            return (last.0, last.1.count)
        default: return nil
        }
    }

    func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
        session.localDragSession?.items.first?.localObject is String
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
                        withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
        guard session.localDragSession != nil, let target = dropTarget(destinationIndexPath) else {
            return UICollectionViewDropProposal(operation: .forbidden)
        }
        let place = "\(target.section)#\(target.index)"
        if place != dropPlace {
            if dropPlace != nil { Haptics.play(.selection) }   // the first place is where the task was picked up
            dropPlace = place
        }
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidExit session: UIDropSession) { dropPlace = nil }
    func collectionView(_ collectionView: UICollectionView, dropSessionDidEnd session: UIDropSession) { dropPlace = nil }

    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        guard let drop = coordinator.items.first, let id = drop.dragItem.localObject as? String,
              let target = dropTarget(coordinator.destinationIndexPath) else { return }
        var ids = userGroups.first { $0.0 == target.section }?.1 ?? []
        var index = min(target.index, ids.count)
        if let from = ids.firstIndex(of: id) {
            ids.remove(at: from)
            if from < index { index -= 1 }
        }
        index = min(index, ids.count)
        let above = index > 0 ? store.task(ids[index - 1]) : nil
        let below = index < ids.count ? store.task(ids[index]) : nil
        let section = target.section.isEmpty ? nil : target.section
        let position = TodoSections.position(between: above, and: below)
        if let path = coordinator.destinationIndexPath { coordinator.drop(drop.dragItem, toItemAt: path) }
        Haptics.play(.soft)   // the drop lands; the places crossed on the way ticked
        if store.settings.sort != "smart", store.task(id)?.section == section {
            notices.show("Sorted by \(store.settings.sort == "due" ? "Due Date" : "Date Added"). Choose My Order in Sort By to arrange tasks by hand.", seconds: 4)
        }
        Task { if await !store.move([id], to: section, position: position) { PagesHaptics.error() } }
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
        case .newSection?:
            collectionView.deselectItem(at: indexPath, animated: true)
            promptNewSection(moving: [])
        case .showDone?:
            collectionView.deselectItem(at: indexPath, animated: false)
            toggleDoneSection()
        case .task(let id)?:
            PagesHaptics.selection()
            openTask(id)
            if onShowTask != id { collectionView.deselectItem(at: indexPath, animated: true) }
        default:
            collectionView.deselectItem(at: indexPath, animated: true)
        }
    }

    // MARK: [mac] Two panes (App/Root/PaneRouter.swift)

    /// [mac] Mac polish #57: no task to choose (no tasks, Ideas, the add-on to update, loading, a search with no match):
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
        case .task?, .showDone?, .newSection?: return true
        default: return false
        }
    }

    /// [mac] Mac polish #106: the Mac's row hover (`MacHover`) lights only what a click opens, not To Do | Ideas, an
    /// idea's card, the count or an empty section's hint. Elsewhere rows highlight as before.
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        guard DeviceWord.isMac else { return true }
        return self.collectionView(collectionView, shouldSelectItemAt: indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard !selecting, let path = indexPaths.first else { return nil }
        if let id = ideaID(at: path) { return ideaMenu(id) }
        guard let id = taskID(at: path), let task = store.task(id) else { return nil }
        let stale = isStale(path)
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            let keep = UIAction(title: "Keep", image: UIImage(systemName: "pin")) { [weak self] _ in self?.keep(id) }
            return UIMenu(children: [
                UIMenu(options: .displayInline, children: (stale ? [keep] : []) + [
                    UIAction(title: "Open Task", image: UIImage(systemName: "arrow.up.forward.square")) { [weak self] _ in self?.openTask(id) },
                    UIAction(title: task.isDone ? "Mark Not Done" : "Mark Done",
                             image: UIImage(systemName: task.isDone ? "circle" : "checkmark.circle")) { [weak self] _ in self?.toggleDone(id) },
                    UIMenu(title: "Move To", subtitle: task.section.flatMap { sid in self.store.sections.first { $0.id == sid }?.name },
                           image: UIImage(systemName: "folder"), children: self.moveChoices(for: [id])),
                    UIAction(title: "Select", image: UIImage(systemName: "checkmark.circle.badge.plus")) { [weak self] _ in
                        guard let self else { return }
                        self.setSelecting(true)
                        self.togglePicked(id)
                    },
                ]),
                UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
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
