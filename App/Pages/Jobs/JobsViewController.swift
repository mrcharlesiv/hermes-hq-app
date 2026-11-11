// The Jobs tab (docs/spec/1x-pages.md §3.4): the scope's jobs in the web's sections (Needs Attention, Running,
// Scheduled, Paused, Completed folded), painted from the disk cache in the first frame, then refreshed. Rows: title +
// schedule words + next run, ⋯ and a hold menu (Run Now, Pause/Resume, Delete Job), swipes (Pause/Resume and Run
// leading, Delete trailing). Search behind the bar's magnifier; the scope pill under the title.

import SwiftUI
import UIKit

final class JobsViewController: UIViewController, UICollectionViewDelegate, UISearchResultsUpdating {
    // [jobs] `.empty` (the "No Jobs" words when blueprints follow them) and `.blueprints` (docs/spec/3x-jobs.md §6.6).
    private nonisolated enum Section: Hashable { case group(JobWords.Section), skeleton, count, empty, blueprints }
    private nonisolated enum Item: Hashable { case job(String), showCompleted, skeleton(Int), slow, count(String), emptyNote(String), blueprint(String) }

    let store: JobsStore
    let scope: PagesScope
    private weak var services: PagesServices?
    private let makeChat: (any ChatSessionModel) -> UIViewController
    let actions: JobActions

    /// [m9/ipad] The placeholder beside the list drops "Choose an item" while the list is empty; it hears when that flips.
    /// UIKit's `contentUnavailableConfiguration` can't be overridden (it lives in an extension), so writes go through here.
    private var emptyConfiguration: (any UIContentConfiguration)? {
        get { contentUnavailableConfiguration }
        set {
            let flipped = (contentUnavailableConfiguration == nil) != (newValue == nil)
            contentUnavailableConfiguration = newValue
            // [mac] Stress test 2026-10-28 round 8: placed as it's set. A state set after the last layout (each reload
            // writes a fresh one) kept the system's centring until something laid the page out again, so its title
            // stood 17 to 22 pt above the detail placeholder's.
            hqPlaceMacEmptyTitle()
            guard flipped else { return }
            NotificationCenter.default.post(name: DetailPlaceholderViewController.listStateChanged, object: self)
        }
    }

    private(set) var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var rows: [String: JobRowModel] = [:]
    private var sections: [(JobWords.Section, [String])] = []
    private var query = ""
    private var completedOpen = false
    private var skeletonShown = false
    private var skeletonWork: DispatchWorkItem?
    /// UX study #206: the skeleton still up after 15 s says the gateway is slow, with Try Again.
    private let slowClock = SlowLoadClock()
    private var minuteTimer: Timer?
    private var notices: PageNoticeHost!
    private let scopeItem = ScopeBarItem()
    /// [morepages] Search behind the bar's magnifier (3x-morepages §5).
    private var searchCapsule: PageBarCapsule?
    private var scopeObserver: UUID?
    private var observing = false
    private var refreshStarted: Date?
    // [jobs] New Job (docs/spec/3x-jobs.md §4.5) and the blueprints the list offers.
    private lazy var addItem: UIBarButtonItem = {
        // A symbol image, not `systemItem: .add`: the Desktop Look's quiet grey glyph needs an image to work on (#124).
        let item = UIBarButtonItem(image: UIImage(systemName: "plus"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            self.actions.newJob(from: self)
        })
        item.accessibilityLabel = "New Job"
        item.accessibilityIdentifier = "jobs.new"
        DesktopBars.markThin(item)   // [mac] Stress test 2026-10-28 #58: as heavy as the magnifier beside it
        return item
    }()
    private var blueprintRows: [String: Blueprint] = [:]
    /// The count the folded "Show N Completed" row last drew (it keeps its identity, so a new count must reconfigure it).
    private var shownCompletedCount = 0

    init(store: JobsStore, scope: PagesScope, services: PagesServices?, makeChat: @escaping (any ChatSessionModel) -> UIViewController) {
        self.store = store
        self.scope = scope
        self.services = services
        self.makeChat = makeChat
        actions = JobActions(store: store)
        actions.services = services
        super.init(nibName: nil, bundle: nil)
        PageChrome.applyListHeader(to: self, title: "Jobs")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        hqPlaceMacEmptyTitle()   // [mac] Stress test 2026-10-28 round 7: the title level with the detail placeholder's
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.page
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = HQPalette.page
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.accessibilityIdentifier = "jobs.list"
        view.addSubview(collectionView)
        ListBarAppearance.pinTitle(in: self, softEdgeAround: collectionView)   // owner 2026-11-01: every tab's top
        PageBackdrop.install(in: self, clearing: [collectionView])   // [backdrop] Theme › App Background
        notices = PageNoticeHost(in: view)
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in self?.pulledToRefresh() }, for: .valueChanged)
        collectionView.hqInstallRefresh(refresh)
        searchCapsule = PageBarCapsule.search(on: self, page: "jobs", placeholder: "Search Jobs", updater: self)   // [morepages] §5
        configureDataSource()
        claimStore()
        slowClock.onSlow = { [weak self] in self?.setNeedsReload() }   // UX study #206
        actions.onDeleted = { [weak self] job in
            guard let self, let navigation = self.navigationController else { return }
            // [m9/ipad] In two panes the job's page is on the right, not on this stack.
            let detail = (navigation.topViewController as? JobDetailViewController)
                ?? (MainTabController.current?.split?.detail.viewControllers.first as? JobDetailViewController)
            guard let detail, detail.jobKey == job.key else { return }
            if let root = MainTabController.current { root.leave(detail, animated: true) } else { navigation.popViewController(animated: true) }
        }
        actions.currentScope = { [weak self] in
            guard let self else { return PagesScope.all }
            return self.scope.effective(bots: self.services?.bots ?? [])
        }
        actions.onCreated = { [weak self] key in self?.showCreated(key) }
        scopeObserver = scope.observe { [weak self] next in self?.scopeChanged(next) }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (vc: JobsViewController, _) in vc.reload(animated: false) }
        reload(animated: false)
    }

    /// The store's callbacks go to the Jobs page on screen ([customtabs] with the Jobs tab hidden, More opens a Jobs
    /// page of its own on the same store; as Kanban's `claimStore`).
    private func claimStore() {
        store.onChange = { [weak self] in self?.setNeedsReload() }
        store.onRefreshFailed = { [weak self] _ in self?.notices.show("Couldn’t refresh. Showing what was saved.") }
    }

    isolated deinit {
        minuteTimer?.invalidate()
        if let scopeObserver { scope.stopObserving(scopeObserver) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        searchCapsule?.restoreIfTyped()   // [morepages]
        claimStore()
        if !observing { observing = true; store.noteAppear() }
        store.setScope(scope.effective(bots: services?.bots ?? []))
        reload(animated: false)
        startMinuteClock()
        deselectOnReturn(animated)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if observing { observing = false; store.noteDisappear() }
        minuteTimer?.invalidate()
        minuteTimer = nil
    }

    private func deselectOnReturn(_ animated: Bool) {
        guard !paneKeepsSelection, let selected = collectionView.indexPathsForSelectedItems, !selected.isEmpty else { return }
        if let coordinator = transitionCoordinator {
            coordinator.animate(alongsideTransition: { _ in selected.forEach { self.collectionView.deselectItem(at: $0, animated: true) } })
        } else {
            selected.forEach { collectionView.deselectItem(at: $0, animated: animated) }
        }
    }

    // MARK: Scope

    /// Off screen (Artifacts changed the shared scope) nothing is read until Jobs shows again (`viewWillAppear`).
    private func scopeChanged(_ next: String) {
        guard viewIfLoaded?.window != nil else { return }
        store.setScope(scope.effective(bots: services?.bots ?? []))
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
        reload(animated: false)
    }

    private func countText(shown: Int, total: Int) -> String? {
        guard store.hasList, total > 0 else { return nil }
        let noun = total == 1 ? "job" : "jobs"
        return query.isEmpty ? "\(total) \(noun)" : "\(shown) of \(total) \(noun)"
    }

    // MARK: Layout

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.backgroundColor = .clear
            // item 15: Bots and Sessions dropped the line between rows (owner, 2026-10-27); Jobs matches, in both looks.
            config.showsSeparators = false
            let section = self?.dataSource?.sectionIdentifier(for: index)
            if case .group = section { config.headerMode = .supplementary }
            if section == .blueprints { config.headerMode = .supplementary }
            config.headerTopPadding = 0
            config.leadingSwipeActionsConfigurationProvider = { [weak self] path in self?.leadingSwipe(path) }
            config.trailingSwipeActionsConfigurationProvider = { [weak self] path in self?.trailingSwipe(path) }
            let layout = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            layout.boundarySupplementaryItems.forEach { $0.pinToVisibleBounds = false }
            return layout
        }
    }

    private func configureDataSource() {
        let jobCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, key in
            guard let self, let row = self.rows[key] else { return }
            cell.contentConfiguration = UIHostingConfiguration { JobRowView(row: row) }
            .margins(.all, 0)
            cell.accessibilityIdentifier = "job-row-\(key)"
            cell.configurationUpdateHandler = { cell, state in
                #if targetEnvironment(macCatalyst)
                if DeviceWord.isMac { cell.backgroundConfiguration = MacSelection.listRow(state); return }   // [mac] Stress test 2026-10-28 #54
                #endif
                if Theme.isDesktop { cell.backgroundConfiguration = DesktopLayout.rowBackground(state); return }   // [desktoplook2]
                var background = UIBackgroundConfiguration.clear()
                background.backgroundColor = state.isHighlighted || state.isSelected ? HQPalette.cellPressed : .clear
                cell.backgroundConfiguration = background
            }
        }
        let completedCell = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { cell, _, count in
            cell.contentConfiguration = UIHostingConfiguration { ShowCompletedRowView(count: count) }.margins(.all, 0)
            cell.accessibilityIdentifier = "jobs.show-completed"
            cell.backgroundConfiguration = .clear()
        }
        let countCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { cell, _, text in
            cell.contentConfiguration = UIHostingConfiguration { PageCountView(text: text) }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        let skeletonCell = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { cell, _, _ in
            cell.contentConfiguration = UIHostingConfiguration { PageSkeletonRow() }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        let slowCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            cell.contentConfiguration = UIHostingConfiguration {
                PageSlowNote(retry: { [weak self] in
                    guard let self else { return }
                    self.slowClock.restart()
                    self.reload(animated: false)
                    Task { await self.store.refresh() }
                }, identifier: "jobs.slow")
            }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        let emptyCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { cell, _, text in
            cell.contentConfiguration = UIHostingConfiguration { JobsEmptyNoteView(text: text) }.margins(.all, 0)
            cell.accessibilityIdentifier = "jobs.empty"
            cell.backgroundConfiguration = .clear()
        }
        let blueprintCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, key in
            guard let self, let blueprint = self.blueprintRows[key] else { return }
            cell.contentConfiguration = UIHostingConfiguration { BlueprintRowView(blueprint: blueprint) }.margins(.all, 0)
            cell.accessibilityIdentifier = "blueprint-row-\(key)"
            cell.configurationUpdateHandler = { cell, state in
                #if targetEnvironment(macCatalyst)
                if DeviceWord.isMac { cell.backgroundConfiguration = MacSelection.listRow(state); return }   // [mac] Stress test 2026-10-28 #54
                #endif
                var background = UIBackgroundConfiguration.clear()
                background.backgroundColor = state.isHighlighted || state.isSelected ? HQPalette.cellPressed : .clear
                cell.backgroundConfiguration = background
            }
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader) { [weak self] header, _, path in
            guard let self else { return }
            switch self.dataSource.sectionIdentifier(for: path.section) {
            case .group(let section)?: self.configureHeader(header, section)
            case .blueprints?: self.configureBlueprintsHeader(header)
            default: break
            }
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { [weak self] cv, path, item in
            switch item {
            case .job(let key): return cv.dequeueConfiguredReusableCell(using: jobCell, for: path, item: key)
            case .showCompleted:
                let count = self?.sections.first { $0.0 == .completed }?.1.count ?? 0
                return cv.dequeueConfiguredReusableCell(using: completedCell, for: path, item: count)
            case .skeleton(let n): return cv.dequeueConfiguredReusableCell(using: skeletonCell, for: path, item: n)
            case .slow: return cv.dequeueConfiguredReusableCell(using: slowCell, for: path, item: item)
            case .count(let text): return cv.dequeueConfiguredReusableCell(using: countCell, for: path, item: text)
            case .emptyNote(let text): return cv.dequeueConfiguredReusableCell(using: emptyCell, for: path, item: text)
            case .blueprint(let key): return cv.dequeueConfiguredReusableCell(using: blueprintCell, for: path, item: key)
            }
        }
        dataSource.supplementaryViewProvider = { cv, _, path in cv.dequeueConfiguredReusableSupplementary(using: header, for: path) }
    }

    private func cell(for key: String) -> UIView? {
        guard let path = dataSource.indexPath(for: .job(key)) else { return nil }
        return collectionView.cellForItem(at: path)
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
        let words = query.pgTrim.lowercased()
        let all = store.jobs
        let visible = words.isEmpty ? all : all.filter { job in
            let fields = [JobWords.jobTitle(job), store.title(job), job.prompt ?? "", job.scheduleDisplay ?? "",
                          job.schedule?.expr ?? "", job.deliver ?? ""]
            return fields.contains { $0.lowercased().contains(words) }
        }
        var grouped: [JobWords.Section: [String]] = [:]
        var nextRows: [String: JobRowModel] = [:]
        let bots = Dictionary((services?.bots ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for job in visible {
            let section = JobWords.section(job, now: now)
            grouped[section, default: []].append(job.key)
            let failed = JobWords.lastRunFailed(job)
            // Running: a Run Now still out, the gateway has a run out (one the scheduler started included), or a bot is
            // still working on what the last run handed it.
            let running = store.showsRunning(job) || JobWords.isRunning(job)
            nextRows[job.key] = JobRowModel(key: job.key, title: store.title(job),
                                            subtitle: JobWords.rowSchedule(job, now: now, running: running),
                                            failed: failed, running: running, paused: section == .paused,
                                            overdue: JobWords.nextRunOverdue(job, now: now) != nil,
                                            edge: JobWords.rowEdge(job, now: now, running: running),
                                            owner: job.owner, head: bots[job.owner]?.head)
        }
        sections = JobWords.Section.allCases.compactMap { section in grouped[section].map { (section, $0) } }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if !store.hasList && store.loading && skeletonShown {
            snapshot.appendSections([.skeleton])
            // UX study #206: after 15 s the slow line stands over a shorter skeleton (MoreSkeleton's).
            if slowClock.slow { snapshot.appendItems([.slow], toSection: .skeleton) }
            snapshot.appendItems((0..<(slowClock.slow ? RosterStateCopy.slowSkeletonRows : 8)).map { .skeleton($0) }, toSection: .skeleton)
        }
        slowClock.update(loading: !store.hasList && store.loading && skeletonShown)
        let open = completedOpen || !words.isEmpty
        for (section, keys) in sections {
            snapshot.appendSections([.group(section)])
            if section == .completed && !open {
                snapshot.appendItems([.showCompleted], toSection: .group(section))
            } else {
                snapshot.appendItems(keys.map { .job($0) }, toSection: .group(section))
            }
        }
        if let count = countText(shown: visible.count, total: all.count), !visible.isEmpty {
            snapshot.appendSections([.count])
            snapshot.appendItems([.count(count)], toSection: .count)
        }
        // [jobs] Blueprints follow the jobs (and the search); with no jobs the "No Jobs" words sit above them.
        let blueprints = store.hasList ? store.blueprints.filter { JobBlueprints.matches($0, words) } : []
        if !blueprints.isEmpty {
            if visible.isEmpty && words.isEmpty {
                snapshot.appendSections([.empty])
                snapshot.appendItems([.emptyNote(emptyText(blueprints: true))], toSection: .empty)
            }
            snapshot.appendSections([.blueprints])
            snapshot.appendItems(blueprints.map { .blueprint($0.key) }, toSection: .blueprints)
        }
        let nextBlueprints = Dictionary(blueprints.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = snapshot.itemIdentifiers.compactMap { item -> Item? in
            guard case .job(let key) = item, let old = rows[key], old != nextRows[key] else { return nil }
            return item
        }
        changed += blueprints.compactMap { blueprint -> Item? in
            guard let old = blueprintRows[blueprint.key], old != blueprint else { return nil }
            return .blueprint(blueprint.key)
        }
        let completedCount = sections.first { $0.0 == .completed }?.1.count ?? 0
        if completedCount != shownCompletedCount, snapshot.itemIdentifiers.contains(.showCompleted) { changed.append(.showCompleted) }
        shownCompletedCount = completedCount
        blueprintRows = nextBlueprints
        rows = nextRows
        if !changed.isEmpty { snapshot.reconfigureItems(changed) }
        dataSource.apply(snapshot, animatingDifferences: animated && !HQMotion.reduced)
        remarkOnShow()   // [m9/ipad]
        refreshHeaders()
        addItem.isEnabled = !store.readOnlyGateway
        scopeItem.update(scope: scope, bots: services?.bots ?? [], on: navigationItem, extra: [addItem], search: searchCapsule?.searchItem)
        updateEmptyState(visibleCount: visible.count + blueprints.count)
        // [mac-audit G] Owner 2026-11-02 (Mac audit #18): no jobs at all and nothing narrowing the list (no search, All
        // Bots): All Bots and Search have nothing to act on and leave the bar; + stays beside the state's New Job….
        if DeviceWord.isMac, emptyConfiguration != nil, query.pgTrim.isEmpty, scope.effective(bots: services?.bots ?? []) == PagesScope.all,
           searchCapsule?.isSearchShown != true, navigationItem.rightBarButtonItems ?? [] != [addItem] {
            navigationItem.rightBarButtonItems = [addItem]
        }
        scheduleSkeleton()
        if let started = refreshStarted, !store.loading {
            let wait = max(0, 0.5 - Date().timeIntervalSince(started))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.refreshStarted = nil
                self?.collectionView.refreshControl?.endRefreshing()
            }
        }
    }

    /// Section headers carry counts (and Completed's Hide): a snapshot never reconfigures them, so they are set again.
    private func refreshHeaders() {
        for path in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: UICollectionView.elementKindSectionHeader) {
            guard let header = collectionView.supplementaryView(forElementKind: UICollectionView.elementKindSectionHeader, at: path)
                    as? UICollectionViewListCell,
                  let identifier = dataSource.sectionIdentifier(for: path.section) else { continue }
            if case .group(let section) = identifier { configureHeader(header, section) }
            if identifier == .blueprints { configureBlueprintsHeader(header) }
        }
    }

    private func configureBlueprintsHeader(_ header: UICollectionViewListCell) {
        header.contentConfiguration = UIHostingConfiguration {
            JobsPlainHeaderView(title: "Blueprints", count: blueprintRows.count)
        }.margins(.all, 0)
        header.backgroundConfiguration = .clear()
        header.accessibilityIdentifier = "jobs.section.Blueprints"
    }

    /// "Jobs run a prompt[ for {Bot}] on a schedule. \(DeviceWord.Tap) + to make one[, or start from a blueprint below]."
    private func emptyText(blueprints: Bool) -> String {
        let current = scope.effective(bots: services?.bots ?? [])
        let bot = current == PagesScope.all ? "" : " for \(PagesNames.botName(current, bots: services?.bots ?? []))"
        // [mac] Stress test 2026-10-28 round 8: the Mac's state has its New Job… button, so the words don't send you to +
        // (they wrapped to leave "make one." alone on a second line in both looks).
        if DeviceWord.isMac, !blueprints { return "Jobs run a prompt\(bot) on a schedule." }
        // Audit 863 (08c-10): + is off while changes are: the words don't send you to it.
        if store.readOnlyGateway { return "Jobs run a prompt\(bot) on a schedule. \(JobsStore.readOnlyNotice)" }
        return "Jobs run a prompt\(bot) on a schedule. \(DeviceWord.Tap) + to make one\(blueprints ? ", or start from a blueprint below" : "")."
    }

    /// A job was made: its row is scrolled into view (when the page's bot shows it).
    private func showCreated(_ key: String?) {
        guard isViewLoaded, let key else { return }
        if navigationItem.searchController?.isActive == true { navigationItem.searchController?.isActive = false }
        reload(animated: false)
        guard let path = dataSource.indexPath(for: .job(key)) else { return }
        collectionView.scrollToItem(at: path, at: .centeredVertically, animated: !HQMotion.reduced)
    }

    fileprivate func configureHeader(_ header: UICollectionViewListCell, _ section: JobWords.Section) {
        let count = sections.first { $0.0 == section }?.1.count ?? 0
        let open = completedOpen || !query.isEmpty
        let toggle: (() -> Void)? = section == .completed && query.isEmpty ? { [weak self] in self?.toggleCompleted() } : nil
        header.contentConfiguration = UIHostingConfiguration {
            JobSectionHeaderView(section: section, count: count, open: open, toggle: toggle)
        }.margins(.all, 0)
        header.backgroundConfiguration = .clear()
        header.accessibilityIdentifier = "jobs.section.\(section.rawValue)"
    }

    /// Nothing for 400 ms, then skeleton rows (§2.4).
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

    private func updateEmptyState(visibleCount: Int) {
        if visibleCount > 0 || (!store.hasList && store.loading) {
            emptyConfiguration = nil
            return
        }
        if !query.pgTrim.isEmpty {
            emptyConfiguration = PageStates.searchMiss(query.pgTrim)
        } else if !store.hasList, let reason = store.loadError {
            emptyConfiguration = PageStates.error(title: "Couldn’t Load Jobs", reason: reason) { [weak self] in
                Task { await self?.store.refresh() }
            }
        } else if store.hasList {
            var empty = PageStates.empty(symbol: "clock.arrow.circlepath", title: "No Jobs", text: emptyText(blueprints: false))
            // [mac] Stress test 2026-10-28 round 7: the words say + makes one but the state offered nothing to click,
            // where Kanban, Prompts and Commands each have their button. On the Mac it has a New Job… push button that
            // does what + does.
            if DeviceWord.isMac {
                var button = UIButton.Configuration.hqMacPush(or: .plain())
                button.title = "New Job…"
                empty.button = button
                empty.buttonProperties.primaryAction = UIAction { [weak self] _ in
                    guard let self else { return }
                    self.actions.newJob(from: self)
                }
            }
            emptyConfiguration = empty
        } else {
            emptyConfiguration = nil
        }
    }

    private func toggleCompleted() {
        completedOpen.toggle()
        PagesHaptics.selection()
        reload(animated: true)
    }

    /// One shared timer at the top of each minute: "in 12 min" → "in 11 min" without a read.
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
        Task { await store.refresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.refreshStarted = nil
            self?.collectionView.refreshControl?.endRefreshing()
        }
    }

    // MARK: Search

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        searchCapsule?.updateSearchState()   // [morepages]
        guard text != query else { return }
        query = text
        reload(animated: false)
    }

    // MARK: Selection, menus, swipes

    private func job(at path: IndexPath) -> CronJob? {
        guard case .job(let key)? = dataSource.itemIdentifier(for: path) else { return nil }
        return store.job(key: key)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .showCompleted?:
            collectionView.deselectItem(at: indexPath, animated: false)
            toggleCompleted()
        case .job(let key)?:
            openDetail(key)
        case .blueprint(let key)?:
            collectionView.deselectItem(at: indexPath, animated: true)
            if let blueprint = blueprintRows[key] { actions.newJob(from: self, blueprint: blueprint) }
        default:
            collectionView.deselectItem(at: indexPath, animated: true)
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .skeleton?, .slow?, .count?, .emptyNote?: return false
        default: return true
        }
    }

    // MARK: [m9/ipad] Two panes (App/Root/PaneRouter.swift)

    /// Two panes: the row of the job on show stays marked while the list shows, as on Bots and Sessions.
    private var paneKeepsSelection = false
    /// The job whose page the right pane shows (kept so the mark comes back after the list reloads).
    private var onShowKey: String?

    private func remarkOnShow() {
        if paneKeepsSelection { markOnShow(onShowKey, keepsSelection: true) }
    }

    /// Marks the row of the job whose page the right pane shows; nil clears it.
    func markOnShow(_ key: String?, keepsSelection: Bool) {
        paneKeepsSelection = keepsSelection
        onShowKey = keepsSelection ? key : nil
        guard isViewLoaded, dataSource != nil else { return }
        let path = key.flatMap { dataSource.indexPath(for: .job($0)) }
        for selected in collectionView.indexPathsForSelectedItems ?? [] where selected != path {
            collectionView.deselectItem(at: selected, animated: false)
        }
        if let path { collectionView.selectItem(at: path, animated: false, scrollPosition: []) }
    }

    func openDetail(_ key: String) {
        guard let services, store.job(key: key) != nil else { return }
        let detail = JobDetailViewController(jobKey: key, store: store, actions: actions, services: services, makeChat: makeChat)
        navigationController?.pushViewController(detail, animated: true)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let path = indexPaths.first, let job = job(at: path) else { return nil }
        let key = job.key
        return UIContextMenuConfiguration(identifier: key as NSString, previewProvider: nil) { [weak self] _ in
            guard let self, let job = self.store.job(key: key) else { return nil }
            return self.actions.menu(job, from: self) { [weak self] in self?.cell(for: key) }
        }
    }

    private func leadingSwipe(_ path: IndexPath) -> UISwipeActionsConfiguration? {
        guard let job = job(at: path) else { return nil }
        let paused = JobActions.isPaused(job)
        let toggle = UIContextualAction(style: .normal, title: paused ? "Resume" : "Pause") { [weak self] _, _, done in
            guard let self else { done(false); return }
            self.actions.togglePause(job, from: self)
            done(true)
        }
        toggle.image = UIImage(systemName: paused ? "play.fill" : "pause.fill")
        toggle.backgroundColor = .systemOrange
        let run = UIContextualAction(style: .normal, title: "Run") { [weak self] _, _, done in
            guard let self else { done(false); return }
            self.actions.runNow(job, from: self)
            done(true)
        }
        run.image = UIImage(systemName: "bolt.fill")
        run.backgroundColor = HQPalette.tint
        let config = UISwipeActionsConfiguration(actions: store.isBusy(job) ? [] : [toggle, run])
        config.performsFirstActionWithFullSwipe = true
        return config
    }

    private func trailingSwipe(_ path: IndexPath) -> UISwipeActionsConfiguration? {
        guard let job = job(at: path) else { return nil }
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, view, done in
            guard let self else { done(false); return }
            // A full swipe opens the confirmation; it never deletes by itself.
            self.actions.delete(job, from: self, source: self.cell(for: job.key) ?? view)
            done(false)
        }
        delete.image = UIImage(systemName: "trash.fill")
        let config = UISwipeActionsConfiguration(actions: [delete])
        config.performsFirstActionWithFullSwipe = true
        return config
    }
}
