// [quick-actions] The Quick Actions page (docs/spec/3x-morepages.md §25; owner 2026-11-21: "I want everyone to be able
// to build a custom quick action page so every thing they would need is one click away after triggering the shortcut
// to open the quick action"). Tiles in two columns, Small or Wide; one tap runs one (`QuickActionsRouter.run`). Edit
// removes (−), resizes (drag the corner handle), reorders (drag) and adds (＋ Add Action); holding a tile out of Edit offers Small, Wide, Edit… and Remove.
// The list is this device's (`QuickTileStore`, `hqn.quickActions`). Opened as a sheet by every shortcut and link, and
// pushed from More › Quick Actions or shown as a tab.
// [favorites-live-tiles] A tile can be a Dashboard tile itself (FavoriteDashboardTiles.swift): drawn as the Dashboard
// draws it, live when its page is, opened by the Dashboard's own open.

import SwiftUI
import UIKit
import WebKit

final class QuickActionsViewController: UIViewController, UICollectionViewDelegate {
    /// In the page's own sheet (every shortcut's way in), or pushed / a tab.
    let inSheet: Bool
    private var list = QuickTileList()
    private var collectionView: UICollectionView!
    private lazy var moveHold = UILongPressGestureRecognizer(target: self, action: #selector(moveHeld(_:)))
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private lazy var notice = PageNoticeHost(in: view)
    private var seedWait: Task<Void, Never>?
    /// The starter set is waiting for the roster (the empty state waits with it).
    private var seeding = false
    /// The dashed ＋ Add Action tile's id (shown while editing).
    static let addID = "quick-actions.add"
    /// [favorites-live-tiles] The account's pins and their pictures (made on first need, again for another account),
    /// and the Dashboard tiles running live here.
    private var dashboard: FavoriteTiles?
    private var liveTiles: LiveTiles?
    /// A tile is being dragged (a redraw then waits: applying a snapshot mid-move is refused).
    private var moving = false

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

    /// Single column from AX3 (accessibilityExtraLarge), as the Set Up preview (`typeSize >= .accessibility3`).
    private var stacked: Bool { traitCollection.preferredContentSizeCategory >= .accessibilityExtraLarge }
    private var gap: CGFloat { HQFont.scaled(12) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = inSheet ? HQPalette.sheetPage : HQPalette.groupedPage
        view.accessibilityIdentifier = "quick-actions.page"
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        moveHold.minimumPressDuration = 0.35
        moveHold.isEnabled = false
        collectionView.addGestureRecognizer(moveHold)
        collectionView.accessibilityIdentifier = "quick-actions.grid"
        view.addSubview(collectionView)
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
        // A hold-and-drag in Edit (`moveHeld`) is the collection view's interactive movement: it moves the cell and the
        // data source's snapshot together, and the list follows the snapshot.
        dataSource.reorderingHandlers.canReorderItem = { [weak self] id in self?.isEditing == true && id != Self.addID }
        dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
            guard let self else { return }
            let order = transaction.finalSnapshot.itemIdentifiers.filter { $0 != Self.addID }
            PagesHaptics.selection()
            let byID = Dictionary(self.list.tiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            self.list.tiles = order.compactMap { byID[$0] } + self.list.tiles.filter { !order.contains($0.id) }
            // Saved on the next turn: this runs inside the data source's own apply, and the store's change notice
            // reloads (applying a snapshot there again is refused). The reload lays the widths out again in the new order.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                QuickTileStore.save(self.list)
                self.reload()
            }
            HQAnnounce.say("Moved")
        }
        for name in [QuickTileStore.didChange, Theme.didChange, ServerIssues.didChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
        // [favorites-live-tiles] A pin renamed, redrawn, unpinned, removed in Artifacts, or Show Names turned; its
        // updates' mark or its bot working on it: the Dashboard tiles here follow.
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
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _: UITraitCollection) in
            self.reload()
        }
        loadList()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()   // a bot, job or page may have come or gone meanwhile
        liveTiles?.watch(true)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        liveTiles?.watch(false)   // [favorites-live-tiles] as the Dashboard: hidden, every live view goes
        if isEditing, navigationController?.presentedViewController == nil, presentedViewController == nil {
            setEditing(false, animated: false)
        }
    }

    // MARK: The list

    /// The stored list, or the starter set the first time there's a bot to make it for (the roster may still be on
    /// its way: up to 6 s).
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

    /// [favorites-retired] Owner 2026-11-22: Quick Actions replaces the Favorites page. The pages chosen there join
    /// this page once, as page tiles after the rest (after the starter set on a first open); Favorites' list is then
    /// cleared. Waits while the starter set or More's pages aren't there yet (it is tried on every open).
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

    /// Seeds from the roster's first bot once it is known. True: done (seeded, or nothing to seed).
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
        QuickTileStore.save(list)   // its notice reloads the page
        reload()
    }

    func reload() {
        guard isViewLoaded else { return }
        let stored = QuickTileStore.load()
        if stored.seeded || !stored.tiles.isEmpty { list = stored }
        if list.tiles.isEmpty, isEditing { return setEditing(false, animated: false) }   // it reloads
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(list.tiles.map(\.id), toSection: 0)
        if isEditing { snapshot.appendItems([Self.addID], toSection: 0) }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
        collectionView.collectionViewLayout.invalidateLayout()
        navigationItem.rightBarButtonItems = list.tiles.isEmpty ? [] : [editItem]
        setNeedsUpdateContentUnavailableConfiguration()
    }

    override func updateContentUnavailableConfiguration(using state: UIContentUnavailableConfigurationState) {
        guard list.tiles.isEmpty, !seeding else { contentUnavailableConfiguration = nil; return }
        var empty = PageStates.empty(symbol: "star.circle", title: "No Favorites",
                                     text: "Add the actions and pages you use most.")
        if traitCollection.preferredContentSizeCategory.isAccessibilityCategory { empty.image = nil }
        var button = UIButton.Configuration.hqMacPush(or: .hqFilled(), capsule: true)
        button.title = "Add Action"
        empty.button = button
        empty.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.showAdd() }
        contentUnavailableConfiguration = empty
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

    private func setWide(_ id: String, _ wide: Bool) {
        PagesHaptics.selection()
        change { $0.setWide(id, wide) }
    }

    private func setShort(_ id: String, _ short: Bool) {
        PagesHaptics.selection()
        change { $0.setShort(id, short) }
    }

    /// [favorites-live-tiles] Whether the tile is a Dashboard tile (a picture: no Short, no icon).
    private func isPicture(_ tile: QuickTile) -> Bool { tile.known?.isPicture == true }

    /// The corner drag's start: the tile's size and its frame then (thresholds stay put while the tile changes).
    private var resizeStart: (id: String, wide: Bool, short: Bool, size: CGSize)?

    /// 3x-morepages Q14: the size snaps as the finger passes a third of the tile (a quarter, back to Small), with a tick.
    private func resizeDrag(_ id: String, moved: CGPoint, state: UIGestureRecognizer.State, cell: UICollectionViewCell) {
        switch state {
        case .began:
            guard let tile = list.tiles.first(where: { $0.id == id }) else { return }
            resizeStart = (id, tile.wide, tile.short, cell.bounds.size)
        case .changed:
            guard let start = resizeStart, start.id == id, let tile = list.tiles.first(where: { $0.id == id }) else { return }
            let wide = start.wide ? moved.x > -start.size.width * 0.25 : moved.x > start.size.width * 0.3
            // [favorites-live-tiles] A Dashboard tile only goes Small ↔ Wide.
            let short = isPicture(tile) ? tile.short
                : start.short ? moved.y < start.size.height * 0.3 : moved.y < -start.size.height * 0.3
            guard wide != tile.wide || short != tile.short else { return }
            PagesHaptics.selection()
            change { list in
                list.setWide(id, wide)
                list.setShort(id, short)
            }
        default:
            if resizeStart?.id == id {
                resizeStart = nil
                if let tile = list.tiles.first(where: { $0.id == id }) {
                    HQAnnounce.say(isPicture(tile) ? (tile.wide ? "Wide" : "Small") : "\(tile.wide ? "Wide" : "Small"), \(tile.short ? "Short" : "Tall")")
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

    // MARK: Layout

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

    /// Rows of the tiles (and the ＋ tile, always small) as `QuickTileGrid` lays them out.
    private func section(_ environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let ids = dataSource.snapshot().itemIdentifiers
        let count = collectionView.numberOfSections > 0 ? collectionView.numberOfItems(inSection: 0) : ids.count
        var cells = ids.map { id in list.tiles.first { $0.id == id } ?? QuickTile(id: id, kind: .page) }
        while cells.count < count { cells.append(QuickTile(id: UUID().uuidString, kind: .page)) }   // mid-drag
        cells = Array(cells.prefix(count))
        guard !cells.isEmpty else { return Self.emptySection() }
        let half = gap / 2
        let pageWidth = environment.container.effectiveContentSize.width
        let rows = QuickTileGrid.rows(cells, columns: stacked ? 1 : 2).map { row -> NSCollectionLayoutGroup in
            // A row is only as wide as its tiles: a small tile alone before a wide one would otherwise be repeated
            // to fill the row, taking the next tile's place, and every width after it would land one tile off.
            let shares = row.map { index -> CGFloat in stacked || cells[index].wide ? 1 : 0.5 }
            let width = min(1, shares.reduce(0, +))
            // [favorites-live-tiles] A row with a Dashboard tile is about the tile's height (the cells size themselves:
            // the row takes its tallest, and every tile in it fills that, `FavoriteTileSize`).
            let estimate = row.map { index in tileHeight(cells[index], width: pageWidth) ?? 120 }.max() ?? 120
            let items = shares.map { share -> NSCollectionLayoutItem in
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(share / width),
                                                                    heightDimension: .estimated(estimate)))
                item.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: half, bottom: 0, trailing: half)
                return item
            }
            return NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(width),
                                                                         heightDimension: .estimated(estimate)), subitems: items)
        }
        let group = NSCollectionLayoutGroup.vertical(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                                        heightDimension: .estimated(CGFloat(rows.count) * 120)),
                                                     subitems: rows)
        group.interItemSpacing = .fixed(gap)
        let section = NSCollectionLayoutSection(group: group)
        let side = Self.side(pageWidth) - half
        section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: side, bottom: 24, trailing: side)
        return ScrollBarLane.keep(section)
    }

    /// The room either side of the grid, to the tiles' edges.
    private static func side(_ width: CGFloat) -> CGFloat { max(16, width > 700 ? 24 : 16) }

    /// [favorites-live-tiles] A Dashboard tile's picture size on this page (nil: not one).
    private func pictureSize(_ tile: QuickTile, width: CGFloat? = nil) -> CGSize? {
        guard isPicture(tile) else { return nil }
        let width = width ?? (collectionView.bounds.width > 0 ? collectionView.bounds.width : view.bounds.width)
        return FavoriteTileSize.picture(width: width - ScrollBarLane.listTrailing, side: Self.side(width), gap: gap, wide: tile.wide, stacked: stacked)
    }

    /// [favorites-live-tiles] A Dashboard tile's height on this page, its name's line included (nil: not one).
    private func tileHeight(_ tile: QuickTile, width: CGFloat? = nil) -> CGFloat? {
        pictureSize(tile, width: width).map {
            FavoriteTileSize.height(picture: $0, names: ArtifactPins.showsNames, nameHeight: PinTileView.nameHeight)
        }
    }

    /// [favorites-live-tiles] Whether the tile shares its row with a Dashboard tile (an action tile then fills the
    /// row's height: its icon at the top, its words at the foot).
    private func sharesRowWithPicture(_ id: String) -> Bool {
        guard !stacked, let index = list.tiles.firstIndex(where: { $0.id == id }) else { return false }
        let row = QuickTileGrid.rows(list.tiles, columns: 2).first { $0.contains(index) } ?? []
        return row.count > 1 && row.contains { isPicture(list.tiles[$0]) }
    }

    // MARK: Cells

    private func configure(_ cell: QuickTileCell, _ tile: QuickTile) {
        let world = QuickActionsRouter.world()
        let missing = QuickTileRules.missing(tile, world: world)
        let subtitle = tile.subtitle(botName: QuickActionsRouter.botName(tile.bot))
        var name = tile.name
        if isPicture(tile) {
            name = configureDashboardTile(cell, tile, missing: missing != nil)
        } else {
            let fill = sharesRowWithPicture(tile.id)
            cell.contentConfiguration = UIHostingConfiguration {
                QuickTileFace(name: tile.name, subtitle: subtitle, symbol: tile.symbol, color: QuickTileLook.color(tile.tint),
                              stacked: stacked, dimmed: missing != nil, short: tile.short, fills: fill)
            }
            .margins(.all, 0)
            cell.style(inSheet: inSheet, dashed: false, dimmed: missing != nil)
        }
        cell.accessibilityIdentifier = "quick-tile-\(tile.id)"
        cell.isAccessibilityElement = true
        // [favorites-live-tiles] Q18: "<name>, Dashboard tile".
        cell.accessibilityLabel = isPicture(tile) ? "\(name), Dashboard tile" : "\(tile.name), \(subtitle)"
        cell.accessibilityValue = missing == nil ? dashboardHealthWords(tile) : "Unavailable"
        cell.accessibilityTraits = .button
        cell.accessibilityCustomActions = liveButtonActions(tile) + accessibilityActions(tile)
        cell.onRemove = isEditing ? { [weak self] in self?.remove(tile.id) } : nil
        cell.badgeLabel = "Remove \(name)"
        // A single-column page (largest text) draws every tile full width, so its size can't show: no size button.
        cell.onResize = isEditing && !stacked ? { [weak self] in self?.setWide(tile.id, !tile.wide) } : nil
        cell.onResizeDrag = isEditing && !stacked ? { [weak self, weak cell] moved, state in
            guard let self, let cell else { return }
            self.resizeDrag(tile.id, moved: moved, state: state, cell: cell)
        } : nil
        cell.setResize(wide: tile.wide, name: name)
        cell.setWiggling(isEditing)
    }

    // MARK: Dashboard tiles ([favorites-live-tiles])

    /// The account's pins and pictures, made again for another account (with its own live tiles).
    private func dashboardTiles() -> FavoriteTiles? {
        guard let store = FavoriteTiles.store() else { return nil }
        if dashboard?.store !== store {
            liveTiles?.watch(false)
            let made = FavoriteTiles(store: store)
            made.pictures.onUpdate = { [weak self, weak made] id in
                guard let self, let made else { return }
                // Its page's title names it from now on, as on the Dashboard (Mac polish #45).
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

    /// Draws a Dashboard tile's cell: `PinTileView`, as the Dashboard draws it (its picture, live page, health mark and
    /// "Updating…"); a gone pin as its stand-in at 40 %. Answers the name it shows.
    private func configureDashboardTile(_ cell: QuickTileCell, _ tile: QuickTile, missing: Bool) -> String {
        let source = dashboardTiles()
        let kept = missing ? nil : source?.pin(tile.pin)
        let name = tile.shownName(currentPinName: kept.map { source?.pins.name($0) ?? $0.name })
        let size = pictureSize(tile) ?? CGSize(width: 160, height: 160)
        let height = tileHeight(tile) ?? size.height
        let dark = traitCollection.userInterfaceStyle == .dark
        var pin = kept ?? ArtifactPin.standIn(id: tile.pin, name: name)
        pin.title = name   // the Favorites tile's own name (it follows the pin's until typed over)
        var picture: UIImage?, busy = false, failed = missing, health = TileJobs.Health.none
        var working: String?, live: WKWebView?
        if let kept, let source {
            let shape = FavoriteTiles.shape(size)
            picture = source.pictures.picture(kept, dark: dark, pixels: max(size.width, size.height) * traitCollection.displayScale, shape: shape)
            busy = picture == nil && source.pictures.waiting(kept, dark: dark, shape: shape)
            failed = source.pictures.failed(kept)
            health = failed && kept.isPage ? .failed(TileHealthMark.goneWords) : TileUpdates.shared.health(kept.id)
            working = TileMaker.working(on: kept.id, accountId: source.accountId)?.tileWords
            live = isEditing ? nil : liveTiles?.view(for: kept, dark: dark)   // Edit shows pictures, as Edit Tiles
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

    /// The Dashboard tile's mark in words (after its name), as the Dashboard reads it.
    private func dashboardHealthWords(_ tile: QuickTile) -> String? {
        guard isPicture(tile), let pin = dashboard?.pin(tile.pin) else { return nil }
        return TileHealthMark.words(TileUpdates.shared.health(pin.id))
    }

    /// The pins changed (or their marks, names or makers): the Dashboard tiles drawn again.
    private func dashboardChanged() {
        guard isViewLoaded, list.tiles.contains(where: isPicture) else { return }
        reload()
    }

    /// One pin's tiles drawn again (its picture landed, its live view is ready or gone), after this turn.
    private func redraw(pin id: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isViewLoaded, !self.moving else { return }
            let ids = self.list.tiles.filter { self.isPicture($0) && $0.pin == id }.map(\.id)
            var snapshot = self.dataSource.snapshot()
            let shown = ids.filter { snapshot.indexOfItem($0) != nil }
            guard !shown.isEmpty else { return }
            snapshot.reconfigureItems(shown)
            self.dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    /// The page's live tiles, wired as the Dashboard's (`ArtifactsViewController.makeLiveTiles`): a tap on nothing
    /// pressable opens the tile; a button's prompt goes to the tile's bot, hidden, as `TileMaker.act`.
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
            QuickActionsRouter.run(tile, from: self) { [weak self] said in self?.say(said) }
        }
        live.send = { [weak self, weak source] id, prompt in
            guard let self, let source else { return false }
            return ArtifactsViewController.sendFromTile(source.pin(id), prompt, services: MainTabController.current?.pages?.services,
                                                        accountId: source.accountId, page: self, from: self)
        }
        return live
    }

    /// A live tile's own buttons, by their words: VoiceOver reads the tile as one element, so they are its actions.
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
        cell.setWiggling(false)
    }

    /// VoiceOver's actions on a tile: Remove, Move Up / Down, Make Wide / Small (and Edit).
    private func accessibilityActions(_ tile: QuickTile) -> [UIAccessibilityCustomAction] {
        let id = tile.id
        var actions = [
            UIAccessibilityCustomAction(name: "Edit") { [weak self] _ in self?.showSetup(editing: id); return true },
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
        actions.append(UIAccessibilityCustomAction(name: tile.wide ? "Make Small" : "Make Wide") { [weak self] _ in
            self?.setWide(id, !tile.wide)
            return true
        })
        if !isPicture(tile) {
            actions.append(UIAccessibilityCustomAction(name: tile.short ? "Make Tall" : "Make Short") { [weak self] _ in
                self?.setShort(id, !tile.short)
                return true
            })
        }
        return actions
    }

    // MARK: Taps

    /// [favorites-live-tiles] A live Dashboard tile's own page takes its taps: a button runs, a tap on nothing opens it
    /// (`LiveTiles.open`). VoiceOver opens it as any tile.
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
        QuickActionsRouter.run(tile, from: self) { [weak self] said in self?.say(said) }
    }

    /// A background tile's answer: ✓ and what it did, or the reason, on a line under the bar (and said).
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

    /// Holding a tile out of Edit: Small, Wide, Tall, Short, Edit… and Remove.
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        // In Edit a hold picks the tile up to drag (as the Home Screen's jiggle mode); the − badge, a tap (Edit Action)
        // and the VoiceOver actions cover the rest there. The menu would swallow the hold and the drag never starts.
        guard !isEditing, indexPaths.count == 1, let id = dataSource.itemIdentifier(for: indexPaths[0]), id != Self.addID,
              let tile = list.tiles.first(where: { $0.id == id }) else { return nil }
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { [weak self] _ in
            let small = UIAction(title: "Small", image: UIImage(systemName: "square"), state: tile.wide ? .off : .on) { _ in
                self?.setWide(id, false)
            }
            let wide = UIAction(title: "Wide", image: UIImage(systemName: "rectangle"), state: tile.wide ? .on : .off) { _ in
                self?.setWide(id, true)
            }
            let edit = UIAction(title: "Edit…", image: UIImage(systemName: "slider.horizontal.3")) { _ in self?.showSetup(editing: id) }
            let remove = UIAction(title: "Remove", image: UIImage(systemName: "minus.circle"), attributes: .destructive) { _ in
                self?.remove(id)
            }
            let tall = UIAction(title: "Tall", image: UIImage(systemName: "rectangle.portrait"), state: tile.short ? .off : .on) { _ in
                self?.setShort(id, false)
            }
            let short = UIAction(title: "Short", image: UIImage(systemName: "rectangle.compress.vertical"), state: tile.short ? .on : .off) { _ in
                self?.setShort(id, true)
            }
            // [favorites-live-tiles] A Dashboard tile: Open, Small / Wide, Edit…, and Remove from Favorites (it stays on
            // the Dashboard). A picture has no Tall / Short.
            if self?.isPicture(tile) == true {
                let open = UIAction(title: "Open", image: UIImage(systemName: "arrow.up.forward.app")) { _ in
                    guard let self else { return }
                    QuickActionsRouter.run(tile, from: self) { [weak self] said in self?.say(said) }
                }
                remove.title = "Remove from Favorites"
                return UIMenu(children: [UIMenu(options: .displayInline, children: [open]),
                                         UIMenu(options: .displayInline, children: [small, wide]),
                                         UIMenu(options: .displayInline, children: [edit, remove])])
            }
            return UIMenu(children: [UIMenu(options: .displayInline, children: [small, wide]),
                                     UIMenu(options: .displayInline, children: [tall, short]),
                                     UIMenu(options: .displayInline, children: [edit, remove])])
        }
    }

    // MARK: Reordering (hold and drag while editing)

    /// The collection view's interactive movement, driven by a hold in Edit. (Drag and drop was tried first: after a
    /// drop the collection view kept its own mapping of positions, and the Wide widths, laid out by the snapshot's
    /// order, landed on other tiles until the page was rebuilt.)
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

    /// Never past the ＋ tile.
    func collectionView(_ collectionView: UICollectionView, targetIndexPathForMoveOfItemFromOriginalIndexPath originalIndexPath: IndexPath,
                        atCurrentIndexPath currentIndexPath: IndexPath, toProposedIndexPath proposedIndexPath: IndexPath) -> IndexPath {
        IndexPath(item: min(proposedIndexPath.item, max(0, list.tiles.count - 1)), section: proposedIndexPath.section)
    }

    // MARK: Add and Set Up

    func showAdd() {
        // [favorites-live-tiles] The Dashboard's tiles not on Favorites yet, with their pictures (the sheet's own).
        let source = FavoriteTiles.store().map(FavoriteTiles.init)
        let tiles = source.map { QuickActionChoice.dashboardTiles($0.shown, names: $0.names, on: list) } ?? []
        let add = QuickActionAddSheet.make(choices: { [weak self] in self?.pageChoices() ?? [] }, tiles: tiles,
                                           source: source) { [weak self] tile in
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

    /// Every page a tile can open.
    private func pageChoices() -> [MoreSection] {
        MainTabController.current?.pages?.quickActionChoices() ?? []
    }
}

/// One tile: its face (a hosted SwiftUI view), its card, and Edit's − badge and wiggle.
final class QuickTileCell: UICollectionViewCell {
    static let radius: CGFloat = 18
    var onRemove: (() -> Void)? { didSet { badge.isHidden = onRemove == nil } }
    var badgeLabel: String? { didSet { badge.accessibilityLabel = badgeLabel } }
    /// [quick-actions] Owner 2026-11-21: "There isn't a way to change the size of the card." Edit's corner button
    /// flips a tile between Small and Wide (the hold menu out of Edit was the only way, and nothing showed it).
    var onResize: (() -> Void)? { didSet { resize.isHidden = onResize == nil } }
    /// [quick-actions] Owner 2026-11-21: "Can we not just like click and drag from the corner to resize?" The corner
    /// handle drags: its translation (in the cell's superview) and the gesture's state; the page snaps the size.
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
            // Bottom-right: at the top, a left tile's button sat against its neighbour's − badge across the gap.
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

    /// Edit's resize handle: drag it (right Wide, left Small, up Short, down Tall), or tap it for Small ↔ Wide.
    func setResize(wide: Bool, name: String) {
        resize.configuration?.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right",
                                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        resize.accessibilityLabel = wide ? "Make \(name) Small" : "Make \(name) Wide"
    }

    @objc private func resizeDragged(_ pan: UIPanGestureRecognizer) {
        onResizeDrag?(pan.translation(in: superview), pan.state)
    }

    /// The card: the sheet's card in the page's sheet, the page's card when pushed; outlined in the Desktop Look. The
    /// ＋ tile is a dashed outline on nothing.
    /// `bare`: [favorites-live-tiles] a Dashboard tile draws its own soft card (`PinTileView`).
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

    /// Edit's wiggle: only while Reduce Motion (and power saving) leave decoration on.
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
