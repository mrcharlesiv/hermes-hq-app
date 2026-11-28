// [quick-actions] The Favorites page (docs/spec/3x-morepages.md §25): personal command center with live native cards
// (Tasks, Goals, Needs You, Bots, Group Chats, Specific Chats, Jobs, Kanban, Gateway Status, Usage), live Dashboard
// tiles, deeper shortcuts, Routines, Quick Ask, collapsible Section Headers, multi-page spaces, responsive 2D Bento
// grid across iPhone/iPad/Mac, presets, search, keyboard triggers (⌘1–⌘9), and cross-device sync.

import SwiftUI
import UIKit
import WebKit

final class QuickActionsViewController: UIViewController, UICollectionViewDelegate, UISearchResultsUpdating {
    let inSheet: Bool
    private var list = QuickTileList()
    private var currentPageId: String = QuickTileStore.currentPage()
    private var query = ""
    private var searching = false
    private var collectionView: UICollectionView!
    private lazy var moveHold = UILongPressGestureRecognizer(target: self, action: #selector(moveHeld(_:)))
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private lazy var notice = PageNoticeHost(in: view)
    private var seedWait: Task<Void, Never>?
    private var seeding = false
    static let addID = "quick-actions.add"

    // Live Dashboard tiles & native live cards data hub
    private var dashboard: FavoriteTiles?
    private var liveTiles: LiveTiles?
    private let liveModel = FavoritesLiveModel()

    // Pages pill band (visible whenever multiple pages exist)
    private let pagesModel = FavoritePagesModel()
    private var pagesHost: UIHostingController<HQScaledRoot<FavoritePagesBand>>?
    private var pagesHeight: NSLayoutConstraint?

    // Optional search controller
    private lazy var searchController: UISearchController = {
        let controller = UISearchController(searchResultsController: nil)
        controller.obscuresBackgroundDuringPresentation = false
        controller.hidesNavigationBarDuringPresentation = false
        controller.searchResultsUpdater = self
        controller.searchBar.placeholder = "Search Favorites"
        return controller
    }()

    /// Cached layout placements for the current snapshot so cell rendering & picture shapes match exact frames.
    private var lastLayout: QuickTileLayout.Result?
    private var moving = false
    private var drawnThemeKey = ""
    private var drawnScale: CGFloat = HQFont.scale
    private var prewarmTask: Task<Void, Never>?

    isolated deinit {
        prewarmTask?.cancel()
    }

    init(inSheet: Bool) {
        self.inSheet = inSheet
        super.init(nibName: nil, bundle: nil)
        title = IntentsText.quickActions
        navigationItem.largeTitleDisplayMode = .never
        if !inSheet { PageChrome.applyListHeader(to: self, title: IntentsText.quickActions) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private lazy var editItem: UIBarButtonItem = {
        let item = UIBarButtonItem(title: "Edit", primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            self.setEditing(!self.isEditing, animated: true)
        })
        item.accessibilityIdentifier = "quick-actions.edit"
        return item
    }()

    private lazy var addBarItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "plus"), primaryAction: UIAction { [weak self] _ in
            self?.showAdd()
        })
        item.accessibilityLabel = "Add to Favorites"
        item.accessibilityIdentifier = "quick-actions.add"
        return item
    }()

    private lazy var moreBarItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: makePageMenu())
        item.accessibilityLabel = "Favorites Options"
        item.accessibilityIdentifier = "quick-actions.more"
        return item
    }()

    /// Single column from AX3 (accessibilityExtraLarge), as the Set Up preview (`typeSize >= .accessibility3`).
    private var stacked: Bool { traitCollection.preferredContentSizeCategory >= .accessibilityExtraLarge }
    private var gap: CGFloat { HQFont.scaled(12) }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = [
            UIKeyCommand(title: "Add to Favorites", action: #selector(keyAdd), input: "n", modifierFlags: .command),
            UIKeyCommand(title: "Refresh Favorites", action: #selector(keyRefresh), input: "r", modifierFlags: .command),
            UIKeyCommand(title: "Search Favorites", action: #selector(keySearch), input: "f", modifierFlags: .command),
        ]
        // ⌘1–⌘9 trigger the first 9 non-section tiles on the current page.
        let actionable = displayedTiles().filter { $0.known != .section }
        for idx in 0..<min(9, actionable.count) {
            let cmd = UIKeyCommand(title: actionable[idx].name, action: #selector(keyRunSlot(_:)),
                                   input: "\(idx + 1)", modifierFlags: .command, propertyList: idx)
            commands.append(cmd)
        }
        return (super.keyCommands ?? []) + commands
    }

    @objc private func keyAdd() { showAdd() }
    @objc private func keyRefresh() { Task { await liveModel.refreshAll(); reload() } }
    @objc private func keySearch() { toggleSearch(true) }
    @objc private func keyRunSlot(_ command: UIKeyCommand) {
        guard !isEditing, let index = command.propertyList as? Int else { return }
        let actionable = displayedTiles().filter { $0.known != .section }
        guard actionable.indices.contains(index) else { return }
        Haptics.play(.selection)
        QuickActionsRouter.run(actionable[index], from: self, live: liveModel) { [weak self] said in self?.say(said) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = inSheet ? HQPalette.sheetPage : HQPalette.groupedPage
        view.accessibilityIdentifier = "quick-actions.page"
        definesPresentationContext = true

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        moveHold.minimumPressDuration = 0.35
        moveHold.isEnabled = false
        collectionView.addGestureRecognizer(moveHold)
        collectionView.accessibilityIdentifier = "quick-actions.grid"

        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            Task { @MainActor in
                await self?.liveModel.refreshAll()
                self?.reload()
                refresh?.endRefreshing()
            }
        }, for: .valueChanged)
        collectionView.refreshControl = refresh

        view.addSubview(collectionView)
        installPagesBar()

        if !inSheet {
            ListBarAppearance.pinTitle(in: self, grouped: true, softEdgeAround: collectionView)
            PageBackdrop.install(in: self, clearing: [collectionView])
        }

        let tileCell = UICollectionView.CellRegistration<QuickTileCell, String> { [weak self] cell, _, id in
            guard let self, let tile = self.list.tiles.first(where: { $0.id == id }) else { return }
            self.configure(cell, tile)
        }
        let addCell = UICollectionView.CellRegistration<QuickTileCell, String> { [weak self] cell, _, _ in
            self?.configureAdd(cell)
        }
        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { cv, path, id in
            id == Self.addID ? cv.dequeueConfiguredReusableCell(using: addCell, for: path, item: id)
                : cv.dequeueConfiguredReusableCell(using: tileCell, for: path, item: id)
        }
        dataSource.reorderingHandlers.canReorderItem = { [weak self] id in self?.isEditing == true && id != Self.addID }
        dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
            guard let self else { return }
            let order = transaction.finalSnapshot.itemIdentifiers.filter { $0 != Self.addID }
            PagesHaptics.selection()
            self.list.reorder(order, on: self.currentPageId)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                QuickTileStore.save(self.list)
                self.reload()
            }
            HQAnnounce.say("Moved")
        }

        liveModel.onChange = { [weak self] in
            guard let self, self.isViewLoaded, !self.moving else { return }
            self.reconfigureLiveCells()
        }

        for name in [QuickTileStore.didChange, ServerIssues.didChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
        NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.viewIfLoaded?.window != nil { self.liveTiles?.updateTheme(self.traitCollection) }
                if HTMLPageSheet.themeKey(self.traitCollection) != self.drawnThemeKey || HQFont.scale != self.drawnScale {
                    self.reload()
                }
            }
        }
        for name in [ArtifactPins.didChange, ArtifactHidden.didChange, ArtifactPins.viewChanged, TileUpdates.changed, TileMaker.changed] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dashboardChanged() }
            }
        }
        NotificationCenter.default.addObserver(forName: TileMaker.tileChanged, object: nil, queue: .main) { [weak self] note in
            let id = note.userInfo?["id"] as? String
            MainActor.assumeIsolated {
                guard let self, let id, let pin = self.dashboard?.pin(id) else { return }
                self.dashboard?.pictures.redraw([pin])
                self.liveTiles?.reload(id)
                self.redraw(pin: id)
            }
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self,
                                ThemeGenerationTrait.self, UITraitAccessibilityContrast.self]) { (self: Self, previous) in
            let appearanceChanged = previous.userInterfaceStyle != self.traitCollection.userInterfaceStyle
                || previous[ThemeGenerationTrait.self] != self.traitCollection[ThemeGenerationTrait.self]
                || previous.accessibilityContrast != self.traitCollection.accessibilityContrast
            if appearanceChanged {
                self.liveTiles?.updateTheme(self.traitCollection)
                PageSnapshots.shared.cancelPrewarm()
                guard self.viewIfLoaded?.window != nil else { return }
                self.reload()
            } else {
                self.reload()
            }
        }
        loadList()
    }

    private func installPagesBar() {
        let actions = FavoritePageActions(
            select: { [weak self] id in self?.selectPage(id) },
            add: { [weak self] in self?.promptNewPage() },
            rename: { [weak self] page in self?.promptRenamePage(page) },
            setSymbol: { [weak self] page, symbol in
                self?.change { $0.setPageSymbol(page.id, symbol: symbol) }
            },
            move: { [weak self] page, delta in
                guard let self else { return }
                let all = self.list.allPages
                guard let idx = all.firstIndex(where: { $0.id == page.id }) else { return }
                let nextIdx = idx + delta
                guard nextIdx >= 1, nextIdx < all.count else { return }
                let targetId = all[nextIdx].id
                self.change { $0.reorderPage(page.id, before: targetId) }
            },
            reorder: { [weak self] src, dst in
                PagesHaptics.selection()
                self?.change { $0.reorderPage(src, before: dst) }
            },
            delete: { [weak self] page in self?.confirmDeletePage(page) }
        )
        let host = UIHostingController(rootView: HQScaledRoot(FavoritePagesBand(model: pagesModel, actions: actions)))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let heightConstraint = host.view.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            heightConstraint,
            collectionView.topAnchor.constraint(equalTo: host.view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        pagesHost = host
        pagesHeight = heightConstraint
    }

    private func syncPagesBar() {
        let all = list.allPages
        if !all.contains(where: { $0.id == currentPageId }) {
            currentPageId = FavoritePage.mainId
            QuickTileStore.setCurrentPage(currentPageId)
        }
        pagesModel.pages = all
        pagesModel.current = currentPageId
        var counts: [String: Int] = [:]
        for page in all {
            counts[page.id] = list.tiles(on: page.id).count { $0.known != .section }
        }
        pagesModel.counts = counts
        let show = all.count > 1
        pagesHost?.view.isHidden = !show
        if show {
            let fitted = pagesHost?.sizeThatFits(in: CGSize(width: max(320, view.bounds.width), height: .greatestFiniteMagnitude)).height ?? 48
            pagesHeight?.constant = max(44, fitted)
        } else {
            pagesHeight?.constant = 0
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if list.hasMultiplePages { syncPagesBar() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
        liveTiles?.watch(true)
        liveModel.setVisible(true, tiles: displayedTiles())
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        prewarmTask?.cancel()
        prewarmTask = nil
        liveTiles?.watch(false)
        liveModel.setVisible(false, tiles: [])
        if isEditing, navigationController?.presentedViewController == nil, presentedViewController == nil {
            setEditing(false, animated: false)
        }
    }

    // MARK: The list & filtering

    private func loadList() {
        list = QuickTileStore.load()
        guard list.tiles.isEmpty, !list.seeded else { absorbFavorites(); return reload() }
        seeding = true
        reload()
        seedWait = Task { [weak self] in
            for _ in 0..<30 {
                guard let self else { return }
                if self.seedIfReady() { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            self?.seeding = false
            self?.absorbFavorites()
            self?.reload()
        }
    }

    private func absorbFavorites() {
        var next = QuickTileStore.load()
        let ids = FavoritePages.ids()
        let rows = pageChoices().flatMap { $0.rows() }
        guard next.seeded, !rows.isEmpty else { return }
        defer { FavoritePages.clear() }
        guard !ids.isEmpty || next.tiles.contains(where: { $0.page == FavoritePages.rowID }) else { return }
        var pages: [String: (title: String, symbol: String)] = [:]
        for row in rows where pages[row.id] == nil {
            pages[row.id] = (row.title, QuickTileLook.symbol(row.symbol ?? QuickTileKind.page.defaultLook.symbol))
        }
        guard next.absorbFavorites(ids, pages: pages) else { return }
        list = next
        QuickTileStore.save(list)
        AppLog.note("quick-actions", "took in \(ids.count) Favorites page(s)")
    }

    private func seedIfReady() -> Bool {
        let stored = QuickTileStore.load()
        guard stored.tiles.isEmpty, !stored.seeded else { list = stored; return true }
        guard let root = MainTabController.current, let bot = root.services.bots.first else { return false }
        let shown = QuickTileStore.listToShow(stored, firstBot: (profile: bot.id, name: bot.name))
        if shown.seeded {
            QuickTileStore.save(shown.list)
            AppLog.note("quick-actions", "seeded the starter set")
        }
        list = shown.list
        return true
    }

    private func change(_ edit: (inout QuickTileList) -> Void) {
        edit(&list)
        QuickTileStore.save(list)
        reload()
    }

    /// Tiles currently shown on screen, accounting for current page, collapsed sections, search query, and gateway filter.
    private func displayedTiles() -> [QuickTile] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var tiles: [QuickTile]
        if !trimmed.isEmpty {
            // Search across all pages and collapsed sections.
            tiles = list.tiles.filter { tile in
                guard tile.known != .section else { return false }
                let sub = tile.subtitle(botName: QuickActionsRouter.botName(tile.bot))
                return tile.name.localizedCaseInsensitiveContains(trimmed)
                    || sub.localizedCaseInsensitiveContains(trimmed)
                    || tile.kind.localizedCaseInsensitiveContains(trimmed)
            }
        } else {
            tiles = list.visibleTiles(on: currentPageId, includeCollapsed: isEditing)
        }
        if QuickTileStore.hidesOtherGateways() && !isEditing {
            let world = QuickActionsRouter.world()
            tiles = tiles.filter { !QuickTileRules.isOtherGateway($0, world: world) }
        }
        return tiles
    }

    func reload() {
        guard isViewLoaded else { return }
        let stored = QuickTileStore.load()
        if stored.seeded || !stored.tiles.isEmpty { list = stored }
        syncPagesBar()
        let shown = displayedTiles()
        if list.tiles.isEmpty, isEditing { return setEditing(false, animated: false) }

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(shown.map(\.id), toSection: 0)
        if isEditing && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            snapshot.appendItems([Self.addID], toSection: 0)
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        drawnThemeKey = HTMLPageSheet.themeKey(traitCollection)
        drawnScale = HQFont.scale
        dataSource.apply(snapshot, animatingDifferences: false)
        collectionView.collectionViewLayout.invalidateLayout()
        updateBarItems()
        setNeedsUpdateContentUnavailableConfiguration()
        liveModel.updateTiles(shown)
        scheduleOppositeModePrewarm()
    }

    private func updateBarItems() {
        moreBarItem.menu = makePageMenu()
        if list.tiles.isEmpty {
            navigationItem.rightBarButtonItems = [moreBarItem, addBarItem]
        } else if isEditing {
            navigationItem.rightBarButtonItems = [editItem, addBarItem]
        } else {
            navigationItem.rightBarButtonItems = [editItem, moreBarItem, addBarItem]
        }
    }

    /// Reconfigures only tiles whose visual state depends on `liveModel` (live cards, badgeable page tiles, avatars, running tiles).
    private func reconfigureLiveCells() {
        guard isViewLoaded, !moving else { return }
        var snapshot = dataSource.snapshot()
        let liveIDs = snapshot.itemIdentifiers.filter { id in
            guard let tile = list.tiles.first(where: { $0.id == id }) else { return false }
            if tile.known?.isLiveCard == true { return true }
            if tile.known == .page { return true }
            if tile.showAvatar == true { return true }
            if liveModel.runningTiles.contains(id) || liveModel.feedbackByTile[id] != nil { return true }
            return false
        }
        guard !liveIDs.isEmpty else { return }
        snapshot.reconfigureItems(liveIDs)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    override func updateContentUnavailableConfiguration(using state: UIContentUnavailableConfigurationState) {
        let shown = displayedTiles()
        guard shown.isEmpty, !seeding, !isEditing else { contentUnavailableConfiguration = nil; return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            contentUnavailableConfiguration = PageStates.searchMiss(trimmed)
            return
        }
        let pageTitle = list.allPages.first(where: { $0.id == currentPageId })?.name ?? "Favorites"
        let titleText = list.hasMultiplePages ? "Nothing on \(pageTitle)" : "No Favorites"
        var empty = PageStates.empty(symbol: "star.circle", title: titleText,
                                     text: "Add actions, live widgets, Dashboard tiles, and pages.")
        if traitCollection.preferredContentSizeCategory.isAccessibilityCategory { empty.image = nil }
        var button = UIButton.Configuration.hqMacPush(or: .hqFilled(), capsule: true)
        button.title = "Add Action"
        empty.button = button
        empty.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.showAdd() }
        contentUnavailableConfiguration = empty
    }

    // MARK: Page Options Menu, Pages, Search & Presets

    private func makePageMenu() -> UIMenu {
        let searchAction = UIAction(title: searching ? "Hide Search" : "Search Favorites",
                                    image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
            guard let self else { return }
            self.toggleSearch(!self.searching)
        }
        let addSection = UIAction(title: "Add Section Header", image: UIImage(systemName: "line.3.horizontal")) { [weak self] _ in
            self?.promptNewSection()
        }
        let newPage = UIAction(title: "New Page…", image: UIImage(systemName: "rectangle.stack.badge.plus")) { [weak self] _ in
            self?.promptNewPage()
        }
        let presets = UIAction(title: "Starter Presets…", image: UIImage(systemName: "sparkles.rectangle.stack")) { [weak self] _ in
            self?.showPresets()
        }
        let hidesOther = QuickTileStore.hidesOtherGateways()
        let gwFilter = UIAction(title: "This Gateway Only",
                                image: UIImage(systemName: hidesOther ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"),
                                state: hidesOther ? .on : .off) { _ in
            PagesHaptics.selection()
            QuickTileStore.setHidesOtherGateways(!hidesOther)
        }
        let refresh = UIAction(title: "Refresh Live Cards", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
            Task { await self?.liveModel.refreshAll(); self?.reload() }
        }
        return UIMenu(children: [
            UIMenu(options: .displayInline, children: [addSection, newPage, presets]),
            UIMenu(options: .displayInline, children: [searchAction, gwFilter, refresh]),
        ])
    }

    private func toggleSearch(_ on: Bool) {
        searching = on
        if on {
            navigationItem.searchController = searchController
            navigationItem.hidesSearchBarWhenScrolling = false
            searchController.isActive = true
            DispatchQueue.main.async { self.searchController.searchBar.becomeFirstResponder() }
        } else {
            query = ""
            searchController.searchBar.text = ""
            searchController.isActive = false
            navigationItem.searchController = nil
            reload()
        }
        updateBarItems()
    }

    func updateSearchResults(for searchController: UISearchController) {
        let next = searchController.searchBar.text ?? ""
        if next != query {
            query = next
            reload()
        }
    }

    private func selectPage(_ id: String) {
        guard id != currentPageId else { return }
        PagesHaptics.selection()
        currentPageId = id
        QuickTileStore.setCurrentPage(id)
        reload()
    }

    private func promptNewPage() {
        let alert = UIAlertController(title: "New Favorites Page", message: "Group actions and widgets into a separate space.", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Work, Daily, Ops…"
            field.autocapitalizationType = .words
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            guard let self, let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            PagesHaptics.success()
            var createdId = FavoritePage.mainId
            self.change { createdId = $0.addPage(name: name).id }
            self.selectPage(createdId)
        })
        present(alert, animated: true)
    }

    private func promptRenamePage(_ page: FavoritePage) {
        let alert = UIAlertController(title: "Rename Page", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = page.name
            field.autocapitalizationType = .words
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            guard let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            self?.change { $0.renamePage(page.id, name: name) }
        })
        present(alert, animated: true)
    }

    private func confirmDeletePage(_ page: FavoritePage) {
        let count = list.tiles(on: page.id).count
        let msg = count == 0 ? "This page has no tiles." : "Its \(count) \(count == 1 ? "tile" : "tiles") will move back to Home."
        let alert = UIAlertController(title: "Delete “\(page.name)”?", message: msg, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete Page", style: .destructive) { [weak self] _ in
            guard let self else { return }
            if self.currentPageId == page.id {
                self.currentPageId = FavoritePage.mainId
                QuickTileStore.setCurrentPage(FavoritePage.mainId)
            }
            self.change { $0.deletePage(page.id, deleteTiles: false) }
        })
        present(alert, animated: true)
    }

    private func promptNewSection() {
        let alert = UIAlertController(title: "New Section Header", message: "Drag tiles under a section to organize them.", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Today, My Bots, Metrics…"
            field.autocapitalizationType = .words
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self] _ in
            guard let self, let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            var tile = QuickTile(kind: .section, name: name)
            if self.currentPageId != FavoritePage.mainId { tile.pageId = self.currentPageId }
            PagesHaptics.success()
            self.change { $0.add(tile) }
        })
        present(alert, animated: true)
    }

    private func showPresets() {
        let sheet = FavoritePresetsSheet.make(pageId: currentPageId) { [weak self] tiles, replace in
            guard let self else { return }
            PagesHaptics.success()
            self.change { list in
                if replace {
                    list.tiles.removeAll { $0.resolvedPageId == self.currentPageId }
                }
                for tile in tiles { list.add(tile) }
            }
            self.say(.done("Added preset"))
        }
        present(sheet, animated: true)
    }

    func toggleSection(_ id: String) {
        PagesHaptics.selection()
        change { $0.toggleSection(id) }
    }

    func presentQuickAsk(bot: String, botName: String, defaultOpen: Bool) {
        let sheet = FavoriteQuickAskSheet.make(bot: bot, botName: botName, defaultOpen: defaultOpen) { [weak self] words, openChat in
            guard let self else { return }
            if openChat {
                Task {
                    if self.inSheet { self.dismiss(animated: true) }
                    await NewChatRouter.send(words, inBotChatOf: bot)
                }
            } else {
                Task {
                    let sent = await Result.of { try await AskBotIntent.send(profile: bot, name: botName, message: words, wait: false) }
                    switch sent {
                    case .success(let answer): self.say(.done("Sent to \(answer.target.name)"))
                    case .failure(let error): self.say(.failed(QuickActionsRouter.words(error)))
                    }
                }
            }
        }
        present(sheet, animated: true)
    }

    // MARK: Editing

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        editItem.title = editing ? "Done" : "Edit"
        editItem.style = editing ? .done : .plain
        moveHold.isEnabled = editing
        reload()
        for cell in collectionView.visibleCells { (cell as? QuickTileCell)?.setWiggling(editing) }
        HQAnnounce.say(editing ? "Editing Favorites" : nil)
    }

    private func remove(_ id: String) {
        PagesHaptics.selection()
        let name = list.tiles.first { $0.id == id }?.name
        change { $0.remove(id) }
        HQAnnounce.say(name.map { "Removed \($0)" })
    }

    private func duplicate(_ id: String) {
        PagesHaptics.selection()
        change { _ = $0.duplicate(id) }
        HQAnnounce.say("Duplicated")
    }

    private func setWide(_ id: String, _ wide: Bool) {
        PagesHaptics.selection()
        change { $0.setWide(id, wide) }
    }

    private func setShort(_ id: String, _ short: Bool) {
        PagesHaptics.selection()
        change { $0.setShort(id, short) }
    }

    private func setSize(_ id: String, _ size: QuickTileSize) {
        PagesHaptics.selection()
        change { $0.setSize(id, size) }
    }

    private func isPicture(_ tile: QuickTile) -> Bool { tile.known?.isPicture == true }
    private func isWidget(_ tile: QuickTile) -> Bool { tile.known?.isWidget == true }

    private var resizeStart: (id: String, wide: Bool, short: Bool, size: QuickTileSize, bounds: CGSize)?

    /// Corner drag: right → Wide, left → Small (action tiles: up → Short, down → Tall; widgets: down → Vertical/Large, up → 1-row).
    private func resizeDrag(_ id: String, moved: CGPoint, state: UIGestureRecognizer.State, cell: UICollectionViewCell) {
        switch state {
        case .began:
            guard let tile = list.tiles.first(where: { $0.id == id }) else { return }
            resizeStart = (id, tile.wide, tile.short, tile.effectiveSize, cell.bounds.size)
        case .changed:
            guard let start = resizeStart, start.id == id, let tile = list.tiles.first(where: { $0.id == id }) else { return }
            let wide = start.wide ? moved.x > -start.bounds.width * 0.25 : moved.x > start.bounds.width * 0.3
            if isWidget(tile) {
                let wantTwoRows = start.size.rowSpan == 2 ? moved.y > -start.bounds.height * 0.25 : moved.y > start.bounds.height * 0.35
                let nextSize: QuickTileSize = wantTwoRows ? (wide ? .large : .tallCard) : (wide ? .wide : .small)
                guard nextSize != tile.effectiveSize else { return }
                PagesHaptics.selection()
                change { $0.setSize(id, nextSize) }
            } else {
                let short = start.short ? moved.y < start.bounds.height * 0.3 : moved.y < -start.bounds.height * 0.3
                guard wide != tile.wide || short != tile.short else { return }
                PagesHaptics.selection()
                change { list in
                    list.setWide(id, wide)
                    list.setShort(id, short)
                }
            }
        default:
            if resizeStart?.id == id {
                resizeStart = nil
                if let tile = list.tiles.first(where: { $0.id == id }) {
                    HQAnnounce.say(isWidget(tile) ? tile.effectiveSize.title : "\(tile.wide ? "Wide" : "Small"), \(tile.short ? "Short" : "Tall")")
                }
            }
        }
    }

    private func step(_ id: String, by delta: Int) -> Bool {
        var moved = false
        change { moved = $0.step(id, by: delta) }
        if moved { PagesHaptics.selection() }
        return moved
    }

    // MARK: Layout (Responsive 2D Bento Grid)

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] _, environment in
            self?.section(environment) ?? Self.emptySection()
        }
    }

    private static func emptySection() -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(1)))
        return NSCollectionLayoutSection(group: .vertical(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                                           heightDimension: .absolute(1)), subitems: [item]))
    }

    private func layoutMetrics(for pageWidth: CGFloat) -> QuickTileLayout.Metrics {
        let side = Self.side(pageWidth)
        let usable = max(0, pageWidth - 2 * side - ScrollBarLane.listTrailing)
        let headH = HQFont.preferred(.headline).lineHeight
        let subH = HQFont.preferred(.subheadline).lineHeight
        let capH = HQFont.preferred(.caption1).lineHeight
        let footH = HQFont.preferred(.footnote).lineHeight
        let actionTall = ceil(HQFont.scaled(34) + headH * 2 + subH + 38)
        let actionShort = ceil(max(HQFont.scaled(28), headH + subH + 2) + 18)
        let mini = ceil(HQFont.scaled(32) + capH + 24)
        let sectionH = ceil(footH + 16)
        let dashName = ArtifactPins.showsNames ? PinTileView.nameHeight : 0
        return QuickTileLayout.Metrics(
            width: usable,
            gap: gap,
            stacked: stacked,
            scale: HQFont.scale,
            actionTallHeight: actionTall,
            actionShortHeight: actionShort,
            miniHeight: mini,
            sectionHeight: sectionH,
            dashboardNameHeight: dashName
        )
    }

    private func section(_ environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let ids = dataSource.snapshot().itemIdentifiers
        let count = collectionView.numberOfSections > 0 ? collectionView.numberOfItems(inSection: 0) : ids.count
        var cells = ids.map { id -> QuickTile in
            if id == Self.addID { return QuickTile(id: id, kind: .page) }
            return list.tiles.first { $0.id == id } ?? QuickTile(id: id, kind: .page)
        }
        while cells.count < count { cells.append(QuickTile(id: UUID().uuidString, kind: .page)) }
        cells = Array(cells.prefix(count))
        guard !cells.isEmpty else { return Self.emptySection() }

        let pageWidth = environment.container.effectiveContentSize.width
        let side = Self.side(pageWidth)
        let metrics = layoutMetrics(for: pageWidth)

        // Accessibility single-column mode uses intrinsic self-sizing rows so AX5 text never clips.
        if stacked {
            let rows = cells.map { tile -> NSCollectionLayoutGroup in
                let estimate = QuickTileLayout.naturalHeight(for: tile, metrics: metrics)
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(estimate)))
                return NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(estimate)), subitems: [item])
            }
            let group = NSCollectionLayoutGroup.vertical(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                                            heightDimension: .estimated(CGFloat(rows.count) * 120)),
                                                         subitems: rows)
            group.interItemSpacing = .fixed(gap)
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: side, bottom: 24, trailing: side)
            lastLayout = nil
            return ScrollBarLane.keep(section)
        }

        let result = QuickTileLayout.compute(cells, metrics: metrics, hasAddTile: false)
        lastLayout = result
        let totalHeight = max(1, result.totalHeight)
        let frames = result.placements.map(\.frame)
        let group = NSCollectionLayoutGroup.custom(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(totalHeight))
        ) { _ in
            frames.map { NSCollectionLayoutGroupCustomItem(frame: $0) }
        }
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: side, bottom: 24, trailing: side)
        return ScrollBarLane.keep(section)
    }

    private static func side(_ width: CGFloat) -> CGFloat { max(16, width > 700 ? 24 : 16) }

    private func pictureSize(_ tile: QuickTile, width: CGFloat? = nil) -> CGSize? {
        guard isPicture(tile) else { return nil }
        let width = width ?? (collectionView.bounds.width > 0 ? collectionView.bounds.width : view.bounds.width)
        return FavoriteTileSize.picture(width: width - ScrollBarLane.listTrailing, side: Self.side(width), gap: gap,
                                        size: tile.effectiveSize, stacked: stacked, scale: HQFont.scale)
    }

    private func tileHeight(_ tile: QuickTile, width: CGFloat? = nil) -> CGFloat? {
        pictureSize(tile, width: width).map {
            FavoriteTileSize.height(picture: $0, names: ArtifactPins.showsNames, nameHeight: PinTileView.nameHeight)
        }
    }

    private func fillsRow(_ id: String) -> Bool {
        guard !stacked, let layout = lastLayout, let index = dataSource.snapshot().itemIdentifiers.firstIndex(of: id),
              layout.placements.indices.contains(index) else { return false }
        return layout.placements[index].fillsRow
    }

    // MARK: Cells

    private func configure(_ cell: QuickTileCell, _ tile: QuickTile) {
        let world = QuickActionsRouter.world()
        let missing = QuickTileRules.missing(tile, world: world)
        let subtitle = tile.subtitle(botName: QuickActionsRouter.botName(tile.bot))
        var name = tile.name
        let kind = tile.known

        if kind == .section {
            let collapsed = tile.collapsed == true
            let itemCount = list.sectionItemCount(tile.id, on: currentPageId)
            cell.contentConfiguration = UIHostingConfiguration {
                FavoriteSectionHeaderView(title: tile.name, collapsed: collapsed, itemCount: itemCount, editing: isEditing)
            }
            .margins(.all, 0)
            cell.style(inSheet: inSheet, dashed: false, dimmed: false, bare: true)
            cell.accessibilityIdentifier = "quick-tile-\(tile.id)"
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = "\(tile.name), section"
            cell.accessibilityValue = collapsed ? "Collapsed, \(itemCount) items" : "Expanded"
            cell.accessibilityTraits = .header
            cell.accessibilityCustomActions = accessibilityActions(tile)
            cell.onRemove = isEditing ? { [weak self] in self?.remove(tile.id) } : nil
            cell.badgeLabel = "Remove \(tile.name)"
            cell.onResize = nil
            cell.onResizeDrag = nil
            cell.setWiggling(false)
            return
        }

        if isPicture(tile) {
            name = configureDashboardTile(cell, tile, missing: missing != nil)
        } else if let kind, kind.isLiveCard {
            configureLiveCard(cell, tile, kind: kind, missing: missing != nil)
        } else if tile.effectiveSize == .mini && !stacked {
            let botAvatar: (profile: String, head: JSONValue?)? = (tile.showAvatar == true && tile.bot != nil)
                ? (tile.bot!, liveModel.bot(tile.bot)?.head) : nil
            let badge = tile.known == .page ? liveModel.pageBadge(for: tile.page) : nil
            let running = liveModel.runningTiles.contains(tile.id)
            let feedback = liveModel.feedbackByTile[tile.id]
            cell.contentConfiguration = UIHostingConfiguration {
                QuickTileMiniFace(name: tile.name, symbol: tile.symbol, color: QuickTileLook.color(tile.tint),
                                  dimmed: missing != nil, botAvatar: botAvatar, badge: badge, running: running, feedback: feedback)
            }
            .margins(.all, 0)
            cell.style(inSheet: inSheet, dashed: false, dimmed: missing != nil)
        } else {
            let fill = fillsRow(tile.id)
            let botAvatar: (profile: String, head: JSONValue?)? = (tile.showAvatar == true && tile.bot != nil)
                ? (tile.bot!, liveModel.bot(tile.bot)?.head) : nil
            let badge = tile.known == .page ? liveModel.pageBadge(for: tile.page) : nil
            let running = liveModel.runningTiles.contains(tile.id)
            let feedback = liveModel.feedbackByTile[tile.id]
            cell.contentConfiguration = UIHostingConfiguration {
                QuickTileFace(name: tile.name, subtitle: subtitle, symbol: tile.symbol, color: QuickTileLook.color(tile.tint),
                              stacked: stacked, dimmed: missing != nil, short: tile.short, fills: fill,
                              botAvatar: botAvatar, badge: badge, running: running, feedback: feedback)
            }
            .margins(.all, 0)
            cell.style(inSheet: inSheet, dashed: false, dimmed: missing != nil)
        }

        cell.accessibilityIdentifier = "quick-tile-\(tile.id)"
        cell.isAccessibilityElement = !(kind?.isLiveCard == true && !isEditing && (kind == .tasks || kind == .goal || kind == .needsYou || kind == .botCard || kind == .jobCard))
        cell.accessibilityLabel = isPicture(tile) ? "\(name), Dashboard tile" : "\(tile.name), \(subtitle)"
        cell.accessibilityValue = missing == nil ? dashboardHealthWords(tile) : "Unavailable"
        cell.accessibilityTraits = .button
        cell.accessibilityCustomActions = liveButtonActions(tile) + accessibilityActions(tile)
        cell.onRemove = isEditing ? { [weak self] in self?.remove(tile.id) } : nil
        cell.badgeLabel = "Remove \(name)"
        cell.onResize = isEditing && !stacked ? { [weak self] in self?.cycleResize(tile.id) } : nil
        cell.onResizeDrag = isEditing && !stacked ? { [weak self, weak cell] moved, state in
            guard let self, let cell else { return }
            self.resizeDrag(tile.id, moved: moved, state: state, cell: cell)
        } : nil
        cell.setResize(wide: tile.wide, name: name)
        cell.setWiggling(isEditing)
    }

    private func cycleResize(_ id: String) {
        guard let tile = list.tiles.first(where: { $0.id == id }) else { return }
        if isWidget(tile) {
            let next: QuickTileSize = switch tile.effectiveSize {
            case .small: .wide
            case .wide: .large
            case .large: .small
            default: .small
            }
            setSize(id, next)
        } else {
            setWide(id, !tile.wide)
        }
    }

    private func configureLiveCard(_ cell: QuickTileCell, _ tile: QuickTile, kind: QuickTileKind, missing: Bool) {
        let size = tile.effectiveSize
        let model = liveModel
        cell.contentConfiguration = UIHostingConfiguration {
            switch kind {
            case .tasks:
                FavoriteTasksCard(tile: tile, model: model, size: size, dimmed: missing,
                                  onOpenTask: { [weak self] taskId in self?.openTaskFromCard(taskId) },
                                  onAddTask: { [weak self] in self?.openNewTaskFromCard() })
            case .goal:
                FavoriteGoalCard(tile: tile, model: model, size: size, dimmed: missing)
            case .needsYou:
                FavoriteNeedsYouCard(tile: tile, model: model, size: size) { [weak self] item in
                    guard let self, !self.isEditing else { return }
                    QuickActionsRouter.runAttention(item, from: self) { [weak self] said in self?.say(said) }
                }
            case .botCard:
                FavoriteBotCard(tile: tile, model: model, size: size, dimmed: missing,
                                onMemo: { [weak self] in self?.runBotQuick(tile.bot, kind: .memo) },
                                onTalk: { [weak self] in self?.runBotQuick(tile.bot, kind: .talk) },
                                onNewChat: { [weak self] in self?.runBotQuick(tile.bot, kind: .newChat) })
            case .groupChat:
                FavoriteGroupChatCard(tile: tile, model: model, size: size, dimmed: missing)
            case .chatSession:
                FavoriteChatSessionCard(tile: tile, model: model, size: size, dimmed: missing)
            case .jobCard:
                FavoriteJobCard(tile: tile, model: model, size: size, dimmed: missing) { [weak self] key, name in
                    guard let self, !self.isEditing else { return }
                    QuickActionsRouter.runJobDirectly(key: key, name: name, tileId: tile.id, live: self.liveModel) { [weak self] said in
                        self?.say(said)
                    }
                }
            case .kanban:
                FavoriteKanbanCard(tile: tile, model: model, size: size, dimmed: missing)
            case .gatewayStatus:
                FavoriteGatewayStatusCard(tile: tile, model: model, size: size)
            case .usage:
                FavoriteUsageCard(tile: tile, model: model, size: size)
            default:
                EmptyView()
            }
        }
        .margins(.all, 0)
        cell.style(inSheet: inSheet, dashed: false, dimmed: missing)
    }

    private func openTaskFromCard(_ taskId: String) {
        guard !isEditing else { return }
        if inSheet { dismiss(animated: true) { _ = TasksHub.open(taskID: taskId) } }
        else { _ = TasksHub.open(taskID: taskId) }
    }

    private func openNewTaskFromCard() {
        guard !isEditing else { return }
        if inSheet { dismiss(animated: true) { TasksHub.newTask(bot: nil) } }
        else { TasksHub.newTask(bot: nil) }
    }

    private func runBotQuick(_ profile: String?, kind: QuickTileKind) {
        guard !isEditing, let profile, !profile.isEmpty else { return }
        var temp = QuickTile(kind: kind)
        temp.bot = profile
        temp.botName = QuickActionsRouter.botName(profile)
        if kind == .newChat { temp.flag = true }
        QuickActionsRouter.run(temp, from: self, live: liveModel) { [weak self] said in self?.say(said) }
    }

    // MARK: Dashboard tiles ([favorites-live-tiles])

    private func dashboardTiles() -> FavoriteTiles? {
        guard let store = FavoriteTiles.store() else { return nil }
        if dashboard?.store !== store {
            liveTiles?.watch(false)
            let made = FavoriteTiles(store: store)
            made.pictures.onUpdate = { [weak self, weak made] id in
                guard let self, let made else { return }
                if let pin = made.pin(id), pin.isPage, let path = pin.gatewayPath,
                   let head = PageSnapshots.shared.head(path: path, context: made.pictures.context(pin)) {
                    made.pins.notePage(id: id, head: head)
                }
                self.redraw(pin: id)
            }
            made.previews.onUpdate = { [weak self] id in
                if id.hasPrefix("pin:") { self?.redraw(pin: String(id.dropFirst(4))) }
            }
            dashboard = made
            liveTiles = makeLiveTiles(made)
            if viewIfLoaded?.window != nil { liveTiles?.watch(true) }
        }
        return dashboard
    }

    private func configureDashboardTile(_ cell: QuickTileCell, _ tile: QuickTile, missing: Bool) -> String {
        let source = dashboardTiles()
        let kept = missing ? nil : source?.pin(tile.pin)
        let name = tile.shownName(currentPinName: kept.map { source?.pins.name($0) ?? $0.name })
        let size = pictureSize(tile) ?? CGSize(width: 160, height: 160)
        let height = tileHeight(tile) ?? size.height
        let traits = traitCollection
        var pin = kept ?? ArtifactPin.standIn(id: tile.pin, name: name)
        pin.title = name
        var picture: UIImage?, busy = false, failed = missing, health = TileJobs.Health.none
        var working: String?, live: WKWebView?
        if let kept, let source {
            let shape = FavoriteTiles.shape(size)
            picture = source.pictures.picture(kept, traits: traits, pixels: max(size.width, size.height) * traitCollection.displayScale, shape: shape)
            busy = picture == nil && source.pictures.waiting(kept, traits: traits, shape: shape)
            failed = source.pictures.failed(kept)
            health = failed && kept.isPage ? .failed(TileHealthMark.goneWords) : TileUpdates.shared.health(kept.id)
            working = TileMaker.working(on: kept.id, accountId: source.accountId)?.tileWords
            live = isEditing ? nil : liveTiles?.view(for: kept, traits: traits)
        }
        let shown = pin
        cell.contentConfiguration = UIHostingConfiguration {
            FavoriteTileFace(pin: shown, picture: picture, busy: busy, health: isEditing ? .none : health, live: live,
                             failed: failed, working: isEditing ? nil : working, height: height, dimmed: missing)
        }
        .margins(.all, 0)
        cell.style(inSheet: inSheet, dashed: false, dimmed: false, bare: true)
        return name
    }

    private func dashboardHealthWords(_ tile: QuickTile) -> String? {
        guard isPicture(tile), let pin = dashboard?.pin(tile.pin) else { return nil }
        return TileHealthMark.words(TileUpdates.shared.health(pin.id))
    }

    private func dashboardChanged() {
        guard isViewLoaded, list.tiles.contains(where: isPicture) else { return }
        reload()
    }

    private func redraw(pin id: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isViewLoaded, !self.moving else { return }
            let ids = self.list.tiles.filter { self.isPicture($0) && $0.pin == id }.map(\.id)
            var snapshot = self.dataSource.snapshot()
            let shown = ids.filter { snapshot.indexOfItem($0) != nil }
            guard !shown.isEmpty else { return }
            snapshot.reconfigureItems(shown)
            self.dataSource.apply(snapshot, animatingDifferences: false)
            self.scheduleOppositeModePrewarm()
        }
    }

    private func scheduleOppositeModePrewarm() {
        prewarmTask?.cancel()
        guard viewIfLoaded?.window != nil, list.tiles.contains(where: isPicture) else { return }
        prewarmTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled, self.viewIfLoaded?.window != nil, !PageSnapshots.shared.isBusy,
                  let source = self.dashboardTiles() else { return }
            var shapes: [String: PageSnapshots.Shape] = [:]
            var pins: [ArtifactPin] = []
            for tile in self.list.tiles where self.isPicture(tile) {
                guard let pin = source.pin(tile.pin), shapes[pin.id] == nil else { continue }
                let size = self.pictureSize(tile) ?? CGSize(width: 160, height: 160)
                shapes[pin.id] = FavoriteTiles.shape(size)
                pins.append(pin)
            }
            guard !pins.isEmpty else { return }
            source.pictures.prewarmOppositeMode(pins, traits: self.traitCollection) {
                shapes[$0.id] ?? .box(aspect: 1)
            }
        }
    }

    private func makeLiveTiles(_ source: FavoriteTiles) -> LiveTiles {
        let live = LiveTiles(host: self)
        live.pin = { [weak source] id in source?.pin(id) }
        live.context = { [weak source] pin in source?.pictures.context(pin) ?? MediaContext(accountId: "", profile: pin.profile) }
        live.onChange = { [weak self] id in self?.redraw(pin: id) }
        live.onScreen = { [weak self] in
            guard let self, let collectionView = self.collectionView else { return [] }
            return Set(collectionView.indexPathsForVisibleItems.compactMap { path -> String? in
                guard let id = self.dataSource.itemIdentifier(for: path) else { return nil }
                return self.list.tiles.first { $0.id == id && self.isPicture($0) }?.pin
            })
        }
        live.open = { [weak self] id in
            guard let self, !self.isEditing, self.presentedViewController == nil,
                  let tile = self.list.tiles.first(where: { self.isPicture($0) && $0.pin == id }) else { return }
            Haptics.play(.soft)
            QuickActionsRouter.run(tile, from: self, live: self.liveModel) { [weak self] said in self?.say(said) }
        }
        live.send = { [weak self, weak source] id, prompt in
            guard let self, let source else { return false }
            return ArtifactsViewController.sendFromTile(source.pin(id), prompt, services: MainTabController.current?.pages?.services,
                                                        accountId: source.accountId, page: self, from: self)
        }
        return live
    }

    private func liveButtonActions(_ tile: QuickTile) -> [UIAccessibilityCustomAction] {
        guard isPicture(tile), !isEditing, let id = tile.pin, let liveTiles, liveTiles.isRunning(id) else { return [] }
        return liveTiles.buttons(id).map { words in
            UIAccessibilityCustomAction(name: words) { [weak liveTiles] _ in
                liveTiles?.press(id, button: words)
                return true
            }
        }
    }

    private func configureAdd(_ cell: QuickTileCell) {
        cell.contentConfiguration = UIHostingConfiguration {
            VStack(spacing: 6) {
                Image(systemName: "plus").font(Font.hq(.title3).weight(.semibold)).foregroundStyle(Color.hqTint)
                Text("Add Action").font(Font.hq(.headline)).foregroundStyle(Color.hqTintText)
            }
            .frame(maxWidth: .infinity, minHeight: HQFont.scaled(104))
        }
        .margins(.all, 0)
        cell.style(inSheet: inSheet, dashed: true, dimmed: false)
        cell.accessibilityIdentifier = "quick-actions.add-tile"
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = "Add Action"
        cell.accessibilityValue = nil
        cell.accessibilityTraits = .button
        cell.accessibilityCustomActions = nil
        cell.onRemove = nil
        cell.onResize = nil
        cell.onResizeDrag = nil
        cell.setWiggling(false)
    }

    private func accessibilityActions(_ tile: QuickTile) -> [UIAccessibilityCustomAction] {
        let id = tile.id
        var actions = [
            UIAccessibilityCustomAction(name: "Edit") { [weak self] _ in self?.showSetup(editing: id); return true },
            UIAccessibilityCustomAction(name: "Duplicate") { [weak self] _ in self?.duplicate(id); return true },
            UIAccessibilityCustomAction(name: "Remove") { [weak self] _ in self?.remove(id); return true },
        ]
        let index = list.tiles.firstIndex { $0.id == id } ?? 0
        if index > 0 {
            actions.append(UIAccessibilityCustomAction(name: "Move Up") { [weak self] _ in
                guard self?.step(id, by: -1) == true else { return false }
                HQAnnounce.say("Moved up")
                return true
            })
        }
        if index < list.tiles.count - 1 {
            actions.append(UIAccessibilityCustomAction(name: "Move Down") { [weak self] _ in
                guard self?.step(id, by: 1) == true else { return false }
                HQAnnounce.say("Moved down")
                return true
            })
        }
        if tile.known != .section {
            actions.append(UIAccessibilityCustomAction(name: tile.wide ? "Make Small" : "Make Wide") { [weak self] _ in
                self?.setWide(id, !tile.wide)
                return true
            })
            if tile.known?.supportsShort == true {
                actions.append(UIAccessibilityCustomAction(name: tile.short ? "Make Tall" : "Make Short") { [weak self] _ in
                    self?.setShort(id, !tile.short)
                    return true
                })
            }
        }
        return actions
    }

    // MARK: Taps

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard !isEditing, !HQAccessibility.voiceOver, let id = dataSource.itemIdentifier(for: indexPath),
              let tile = list.tiles.first(where: { $0.id == id }), isPicture(tile), let pin = tile.pin else { return true }
        return liveTiles?.isRunning(pin) != true
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        if id == Self.addID { return showAdd() }
        guard let tile = list.tiles.first(where: { $0.id == id }) else { return }
        if isEditing { return showSetup(editing: id) }
        Haptics.play(.selection)
        QuickActionsRouter.run(tile, from: self, live: liveModel) { [weak self] said in self?.say(said) }
    }

    func say(_ said: QuickActionsRouter.Said) {
        switch said {
        case .done(let words):
            PagesHaptics.success()
            notice.show("✓ " + words)
            HQAnnounce.say(words)
        case .failed(let words):
            Haptics.play(.error)
            notice.show(words, seconds: 4)
            HQAnnounce.say(words, priority: .high)
        }
    }

    // MARK: Context menu (out of Edit)

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard !isEditing, indexPaths.count == 1, let id = dataSource.itemIdentifier(for: indexPaths[0]), id != Self.addID,
              let tile = list.tiles.first(where: { $0.id == id }) else { return nil }
        let wideScreen = (lastLayout?.columns ?? 2) >= 3
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            let edit = UIAction(title: "Edit…", image: UIImage(systemName: "slider.horizontal.3")) { _ in self.showSetup(editing: id) }
            let dup = UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { _ in self.duplicate(id) }
            let remove = UIAction(title: self.isPicture(tile) ? "Remove from Favorites" : "Remove",
                                  image: UIImage(systemName: "minus.circle"), attributes: .destructive) { _ in self.remove(id) }

            if tile.known == .section {
                let collapsed = tile.collapsed == true
                let toggle = UIAction(title: collapsed ? "Expand Section" : "Collapse Section",
                                      image: UIImage(systemName: collapsed ? "chevron.down" : "chevron.up")) { _ in self.toggleSection(id) }
                return UIMenu(children: [toggle, UIMenu(options: .displayInline, children: [edit, remove])])
            }

            var moveMenu: [UIMenuElement] = []
            if self.list.hasMultiplePages {
                let pageActions = self.list.allPages.map { page in
                    UIAction(title: page.name, image: page.symbol.flatMap { UIImage(systemName: QuickTileLook.symbol($0)) },
                             state: tile.resolvedPageId == page.id ? .on : .off) { _ in
                        self.change { $0.moveTile(id, toPage: page.id) }
                    }
                }
                moveMenu = [UIMenu(title: "Move to Page", image: UIImage(systemName: "rectangle.stack"), children: pageActions)]
            }

            // Dashboard tiles & live widgets: Open, Size (Small / Wide / Vertical / Large … — never Tall/Short!), Edit…, Duplicate, Move, Remove
            if self.isWidget(tile) {
                let open = UIAction(title: "Open", image: UIImage(systemName: "arrow.up.forward.app")) { [weak self] _ in
                    guard let self else { return }
                    QuickActionsRouter.run(tile, from: self, live: self.liveModel) { [weak self] said in self?.say(said) }
                }
                let current = tile.effectiveSize
                let sizes = QuickTileSize.choices(for: tile.known ?? .dashboardTile, wideScreen: wideScreen).map { option in
                    UIAction(title: option.title, image: UIImage(systemName: option.symbol), state: current == option ? .on : .off) { _ in
                        if option == .small { self.setWide(id, false) }
                        else if option == .wide { self.setWide(id, true) }
                        else { self.setSize(id, option) }
                    }
                }
                return UIMenu(children: [
                    UIMenu(options: .displayInline, children: [open]),
                    UIMenu(options: .displayInline, children: sizes),
                    UIMenu(options: .displayInline, children: [edit, dup] + moveMenu + [remove]),
                ])
            }

            // Action & page tiles: Mini / Small / Wide (+ Banner on wide screens), Tall / Short, Edit…, Duplicate, Move, Remove
            let current = tile.effectiveSize
            var widthItems: [UIAction] = [
                UIAction(title: "Mini", image: UIImage(systemName: "square.grid.2x2"), state: current == .mini ? .on : .off) { _ in
                    self.setSize(id, .mini)
                },
                UIAction(title: "Small", image: UIImage(systemName: "square"), state: current == .small ? .on : .off) { _ in
                    self.setWide(id, false)
                },
                UIAction(title: "Wide", image: UIImage(systemName: "rectangle"), state: current == .wide ? .on : .off) { _ in
                    self.setWide(id, true)
                },
            ]
            if wideScreen {
                widthItems.append(UIAction(title: "Banner", image: UIImage(systemName: "rectangle.split.1x2"), state: current == .banner ? .on : .off) { _ in
                    self.setSize(id, .banner)
                })
            }
            let tall = UIAction(title: "Tall", image: UIImage(systemName: "rectangle.portrait"), state: tile.short ? .off : .on) { _ in
                self.setShort(id, false)
            }
            let short = UIAction(title: "Short", image: UIImage(systemName: "rectangle.compress.vertical"), state: tile.short ? .on : .off) { _ in
                self.setShort(id, true)
            }
            return UIMenu(children: [
                UIMenu(options: .displayInline, children: widthItems),
                UIMenu(options: .displayInline, children: [tall, short]),
                UIMenu(options: .displayInline, children: [edit, dup] + moveMenu + [remove]),
            ])
        }
    }

    // MARK: Reordering (hold and drag while editing)

    @objc private func moveHeld(_ hold: UILongPressGestureRecognizer) {
        let point = hold.location(in: collectionView)
        switch hold.state {
        case .began:
            guard let path = collectionView.indexPathForItem(at: point), dataSource.itemIdentifier(for: path) != Self.addID,
                  collectionView.beginInteractiveMovementForItem(at: path) else { return }
            moving = true
            PagesHaptics.selection()
        case .changed:
            collectionView.updateInteractiveMovementTargetPosition(point)
        case .ended:
            moving = false
            collectionView.endInteractiveMovement()
        default:
            moving = false
            collectionView.cancelInteractiveMovement()
        }
    }

    func collectionView(_ collectionView: UICollectionView, targetIndexPathForMoveOfItemFromOriginalIndexPath originalIndexPath: IndexPath,
                        atCurrentIndexPath currentIndexPath: IndexPath, toProposedIndexPath proposedIndexPath: IndexPath) -> IndexPath {
        let count = dataSource.snapshot().itemIdentifiers.filter { $0 != Self.addID }.count
        return IndexPath(item: min(proposedIndexPath.item, max(0, count - 1)), section: proposedIndexPath.section)
    }

    // MARK: Add and Set Up

    func showAdd() {
        let source = FavoriteTiles.store().map(FavoriteTiles.init)
        let tiles = source.map { QuickActionChoice.dashboardTiles($0.shown, names: $0.names, on: list) } ?? []
        let targetPageId = currentPageId
        let add = QuickActionAddSheet.make(choices: { [weak self] in self?.pageChoices() ?? [] }, tiles: tiles,
                                           source: source) { [weak self] tile in
            var tile = tile
            if targetPageId != FavoritePage.mainId { tile.pageId = targetPageId }
            self?.change { $0.add(tile) }
            HQAnnounce.say("Added \(tile.name)")
        }
        present(add, animated: true)
    }

    func showSetup(editing id: String) {
        guard let tile = list.tiles.first(where: { $0.id == id }) else { return }
        let pictures = isPicture(tile) ? FavoriteTiles.store().map { FavoriteTilePictures(FavoriteTiles(store: $0)) } : nil
        let setup = QuickActionSetup.sheet(editing: tile, pictures: pictures) { [weak self] saved in
            self?.change { $0.replace(saved) }
        }
        present(setup, animated: true)
    }

    private func pageChoices() -> [MoreSection] {
        MainTabController.current?.pages?.quickActionChoices() ?? []
    }
}

/// One tile: its face (a hosted SwiftUI view), its card, and Edit's − badge, resize handle and wiggle.
final class QuickTileCell: UICollectionViewCell {
    static let radius: CGFloat = 18
    var onRemove: (() -> Void)? { didSet { badge.isHidden = onRemove == nil } }
    var badgeLabel: String? { didSet { badge.accessibilityLabel = badgeLabel } }
    var onResize: (() -> Void)? { didSet { resize.isHidden = onResize == nil } }
    var onResizeDrag: ((CGPoint, UIGestureRecognizer.State) -> Void)?
    private let badge = UIButton(type: .system)
    private let resize = UIButton(type: .system)
    private let dash = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "minus.circle.fill",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold))
        config.contentInsets = .zero
        badge.configuration = config
        badge.tintColor = HQPalette.red
        badge.backgroundColor = .white
        badge.layer.cornerRadius = 12
        badge.isHidden = true
        badge.accessibilityIdentifier = "quick-tile.remove"
        badge.addAction(UIAction { [weak self] _ in self?.onRemove?() }, for: .primaryActionTriggered)
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            badge.centerYAnchor.constraint(equalTo: topAnchor, constant: 6),
            badge.widthAnchor.constraint(equalToConstant: 24),
            badge.heightAnchor.constraint(equalToConstant: 24),
        ])
        var sizeConfig = UIButton.Configuration.filled()
        sizeConfig.cornerStyle = .capsule
        sizeConfig.baseBackgroundColor = HQPalette.tint
        sizeConfig.baseForegroundColor = HQPalette.onTint
        sizeConfig.contentInsets = .zero
        resize.configuration = sizeConfig
        resize.isHidden = true
        resize.accessibilityIdentifier = "quick-tile.resize"
        resize.addAction(UIAction { [weak self] _ in self?.onResize?() }, for: .primaryActionTriggered)
        resize.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(resizeDragged(_:))))
        resize.translatesAutoresizingMaskIntoConstraints = false
        addSubview(resize)
        NSLayoutConstraint.activate([
            resize.centerXAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            resize.centerYAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            resize.widthAnchor.constraint(equalToConstant: 24),
            resize.heightAnchor.constraint(equalToConstant: 24),
        ])
        dash.fillColor = UIColor.clear.cgColor
        dash.lineWidth = 1.5
        dash.lineDashPattern = [6, 4]
        layer.addSublayer(dash)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setResize(wide: Bool, name: String) {
        resize.configuration?.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right",
                                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        resize.accessibilityLabel = wide ? "Make \(name) Small" : "Make \(name) Wide"
    }

    @objc private func resizeDragged(_ pan: UIPanGestureRecognizer) {
        onResizeDrag?(pan.translation(in: superview), pan.state)
    }

    func style(inSheet: Bool, dashed: Bool, dimmed: Bool, bare: Bool = false) {
        var background = UIBackgroundConfiguration.clear()
        background.cornerRadius = Self.radius
        if !dashed, !bare {
            let card = inSheet ? HQPalette.sheetCard : HQPalette.card
            background.backgroundColor = dimmed ? card.withAlphaComponent(0.5) : card
            if Theme.isDesktop {
                background.strokeColor = HQPalette.cardEdge
                background.strokeWidth = 1
            }
        }
        backgroundConfiguration = background
        dash.isHidden = !dashed
        dash.strokeColor = HQPalette.tint.resolvedColor(with: traitCollection).cgColor
        bringSubviewToFront(badge)
        bringSubviewToFront(resize)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dash.frame = bounds
        dash.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerRadius: Self.radius).cgPath
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        dash.strokeColor = HQPalette.tint.resolvedColor(with: traitCollection).cgColor
    }

    func setWiggling(_ on: Bool) {
        layer.removeAnimation(forKey: "wiggle")
        guard on, !HQMotion.decorativeStill else { return }
        let wiggle = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        let angle = 1.2 * Double.pi / 180
        wiggle.values = [-angle, angle, -angle]
        wiggle.duration = 0.28 + Double.random(in: 0...0.06)
        wiggle.repeatCount = .infinity
        wiggle.isAdditive = true
        wiggle.timeOffset = Double.random(in: 0...0.2)
        layer.add(wiggle, forKey: "wiggle")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onRemove = nil
        onResize = nil
        onResizeDrag = nil
        layer.removeAnimation(forKey: "wiggle")
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if !badge.isHidden, badge.frame.insetBy(dx: -8, dy: -8).contains(point) { return true }
        if !resize.isHidden, resize.frame.insetBy(dx: -8, dy: -8).contains(point) { return true }
        return super.point(inside: point, with: event)
    }
}
