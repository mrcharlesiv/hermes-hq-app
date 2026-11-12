// The Artifacts page (docs/spec/1x-pages.md §5.5): files, images and links the bots produced in recent chats. Under
// the title the scope pill and count; a segmented All · Images · Files · Links; images as an edge-to-edge 3-column
// grid (All shows the newest 24, then "Show All N Images"); files and links as 64 pt rows under sticky day headers;
// what the gateway can't find collects under "Unavailable (N)". ⋯ / hold: Pin, Show in Chat, Share…, Copy Path / Link.
// [pins] Pinned artifacts lead the All filter as a shelf of picture cards (`PinnedArtifacts.swift`); the same page with
// `pinnedOnly` is the Pinned page (More, or a tab): the pins alone, as a grid of larger cards. Either can show the pins
// as rows like Today's instead (View As: Cards | List, `ArtifactPins.showsList`); Artifacts then lists the first five.
// [dashboard] Or as Grid: picture tiles, Small, Medium or Large, packed as Home Screen widgets are and dragged into any
// order (`PinGridPacking`); Artifacts then shows the first six.

import SwiftUI
import UIKit

final class ArtifactsViewController: UIViewController, UICollectionViewDelegate, UISearchResultsUpdating, PaneListEmptiness,
                                     UICollectionViewDragDelegate, UICollectionViewDropDelegate, UIGestureRecognizerDelegate {
    private nonisolated enum Section: Hashable { case filter, pages, making, pinned, allPins, images, showAllImages, day(String), more, unavailable, state, count }
    private nonisolated enum Item: Hashable {
        case filter, image(String), showAllImages(Int), row(String), loadMore, unavailableToggle(Int), unavailableRow(String)
        case state, skeleton(Int), count(String), pin(String), pinRow(String), allPins(Int), pages, making(String)
    }

    /// [pins] As rows, Artifacts lists this many pins, then "See All N Pinned".
    private static let pinRowsOnArtifacts = 5
    /// [dashboard] As Grid, Artifacts shows this many tiles, then "See All N Pinned".
    private static let pinTilesOnArtifacts = 4

    let store: ArtifactsStore
    let scope: PagesScope
    private weak var services: PagesServices?
    private let makeChat: (any ChatSessionModel) -> UIViewController
    private let previews: ArtifactPreviews
    /// [pins] The Pinned page: the pins alone (no segments, no pass over the chats).
    let pinnedOnly: Bool
    /// [mac-tools] Owner 2026-11-09 (the Tools sketch): on the Mac, Artifacts and Tiles are a grid over the whole window,
    /// not rows in a list's column beside an empty pane: files and links are cards, as many across as fit, pictures a
    /// grid of thumbnails, and All · Images · Files · Links stand in the top bar. A file opened from it shows beside
    /// the grid (which narrows to one column of cards) and closes with its ✕. Bot Info's one-bot list keeps its rows.
    let isGrid: Bool
    /// [mac-tools] The segments in the bar (the grid as a place's own page, with room for them), not a cell.
    private var barFilter: ArtifactFilterBar?
    private var barFilterHost = false
    private var filterInBar: Bool { barFilterHost && view.bounds.width >= Self.barFilterLeast }
    private static let barFilterLeast: CGFloat = 660
    private var filterWasInBar: Bool?
    /// [mac-tools] The file open beside the grid: its card keeps the mark until another page takes the right pane.
    private var markedId: String?
    private weak var markedPage: UIViewController?
    private static let live = NSHashTable<ArtifactsViewController>.weakObjects()
    /// [pins] One bot's artifacts whatever the shared scope (Bot Info › Artifacts › See All): no scope menu.
    let fixedProfile: String?
    /// [pins] Show in Chat goes here instead of pushing the chat (from a sheet, the chat opens behind it).
    var showInChatOverride: ((ArtifactRecord) -> Void)?
    private let pins: ArtifactPins
    /// What the owner removed: left out of the list and the pins.
    private var hidden: ArtifactHidden { store.hidden }
    private var hiddenObserver: NSObjectProtocol?
    private var pinPictures: PinPictures!
    /// [live-tiles] Tiles whose pages have buttons or ask to refresh, running live (the Tiles page only).
    private var liveTiles: LiveTiles?
    private var pinsShown: [String: ArtifactPin] = [:]
    private var pinsObserver: NSObjectProtocol?
    private var pinsViewObserver: NSObjectProtocol?
    private var tileObserver: NSObjectProtocol?
    private var tileChangedObserver: NSObjectProtocol?
    private var tileWatch: Task<Void, Never>?
    /// [tiles] While a bot makes a tile, its row's step words are read again each second.
    private var makingTimer: Timer?
    /// [dashboard] Edit Tiles (owner 2026-11-02, "more like widgets"): the Grid's tiles wiggle, a corner handle sizes each,
    /// a badge unpins, and Done (in the Pinned header) ends it. A hold lifts a tile to move it, without a menu.
    private var editingTiles = false
    /// On the list only while editing (a row's swipe actions and the scroll are left alone otherwise).
    private var resizePan: UIPanGestureRecognizer?
    /// The tile being sized: its pin, its frame when the drag began, and the size it has now.
    private var resizing: (id: String, start: CGRect, size: PinTileSize)?
    /// [mac] The app's scale the Grid was last laid out at (`gridMetrics`).
    private var drawnScale: CGFloat = 1
    /// [pins] The count the Pinned page's header says ("3 Pinned").
    private var pinnedHeaderCount = -1
    private(set) var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var notices: PageNoticeHost!
    private let scopeItem = ScopeBarItem()
    /// [morepages] Search behind the bar's magnifier (3x-morepages §5).
    private var searchCapsule: PageBarCapsule?
    private var scopeObserver: UUID?
    private var query = ""
    private var filter: ArtifactRecord.Kind? {
        didSet { saveFilter() }
    }
    private var records: [String: ArtifactRecord] = [:]
    private var visibleImages: [ArtifactRecord] = []
    private var fileLimit = 100
    private var unavailableOpen = false
    private var opening: (id: String, task: Task<Void, Never>)?
    private var openingRow: String?
    private var skeletonShown = false
    private var skeletonWork: DispatchWorkItem?

    init(store: ArtifactsStore, scope: PagesScope, services: PagesServices, pinnedOnly: Bool = false, fixedProfile: String? = nil,
         makeChat: @escaping (any ChatSessionModel) -> UIViewController) {
        self.fixedProfile = fixedProfile
        self.store = store
        self.scope = scope
        self.services = services
        self.makeChat = makeChat
        self.pinnedOnly = pinnedOnly
        isGrid = DeviceWord.isMac && fixedProfile == nil
        previews = ArtifactPreviews(client: store.client, account: store.account)
        pins = ArtifactPins.of(accountId: store.account.id)
        super.init(nibName: nil, bundle: nil)
        title = pinnedOnly ? "Tiles" : "Artifacts"   // Owner 2026-11-03: Pinned → Dashboard → Tiles ("Dashboard" too long in the bar); "pin" stays the verb
        filter = UserDefaults.standard.string(forKey: filterKey).flatMap(ArtifactRecord.Kind.init(rawValue:))
        if isGrid { Self.live.add(self) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The bot whose artifacts show ("all" for every bot).
    private var currentScope: String { fixedProfile ?? scope.effective(bots: services?.bots ?? []) }

    /// The bar's trailing items: the scope menu (none for one fixed bot), search, and `extra`.
    private func updateBarItems(extra: [UIBarButtonItem] = []) {
        // [mac-audit G] Owner 2026-11-02 (Mac audit #18, mac2/3): a page with nothing in it shows no controls with
        // nothing to act on. While the list is empty with no search, filter or one bot narrowing it, its Filter (All
        // Bots) and Search leave the bar; the empty state's own button is the one thing to do. They come back with the
        // first row, and stay while a search or filter is what emptied the list (so it can be undone).
        if DeviceWord.isMac, listShowsState, query.pgTrim.isEmpty, filter == nil, currentScope == PagesScope.all,
           searchCapsule?.isSearchShown != true {
            if navigationItem.rightBarButtonItems ?? [] != extra { navigationItem.rightBarButtonItems = extra }
            return
        }
        if fixedProfile != nil {
            navigationItem.rightBarButtonItems = extra + [searchCapsule?.searchItem ?? navigationItem.searchBarPlacementBarButtonItem]
            return
        }
        scopeItem.update(scope: scope, bots: services?.bots ?? [], on: navigationItem, extra: extra, search: searchCapsule?.searchItem)
    }

    nonisolated static func filterKey(_ account: GatewayAccount) -> String { "pages.artifactsFilter.\(account.id)" }
    private var filterKey: String { Self.filterKey(store.account) }
    private func saveFilter() { guard fixedProfile == nil else { return }; UserDefaults.standard.set(filter?.rawValue ?? "all", forKey: filterKey) }

    override func viewDidLoad() {
        super.viewDidLoad()
        // A tab root (slot 3) keeps the list header; pushed from More (or with Kanban in slot 3) the page has the small
        // centred title the other pushed More pages have.
        // [mac] Stress test 2026-10-31: in two panes More opens it as the first page of the right pane's own stack, so
        // "first" alone read as a tab root ("ARTIFACTS" in the Desktop Look, beside Files' plain title). A tab's stack
        // is a `PaneNavigationController`; the right pane's is not.
        // [mac] Mac polish #59 (owner's call 2026-11-07): Tiles is one of the Mac sidebar's Tools, which have the small
        // centred title (Files, Kanban, Terminal…); the big heading stays Artifacts'.
        let paneRoot = navigationController == nil
            || (navigationController?.viewControllers.first === self && navigationController is PaneNavigationController)
        // [mac-tools] The grid's bar is a Tool's: the plain title, then the segments (`installBarFilter`).
        barFilterHost = isGrid && !pinnedOnly && paneRoot
        let tabRoot = !(DeviceWord.isMac && pinnedOnly) && paneRoot && !barFilterHost
        // [mac] Mac polish #59 (follow-up): the Tool keeps its pinned title over a soft edge (`pinTitle` below), as Tasks
        // does, with the plain title: the tiles fade under the bar, not drawn under its words on a clear bar.
        let toolRoot = (DeviceWord.isMac && pinnedOnly && paneRoot) || barFilterHost
        if tabRoot {
            PageChrome.applyListHeader(to: self, title: title ?? "Artifacts")
        } else {
            navigationItem.largeTitleDisplayMode = .never
            scopeItem.compact = !barFilterHost   // UX study #88: "All Bots ⌄" beside search pushed the title off centre
        }
        view.backgroundColor = HQPalette.page
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = HQPalette.page
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.accessibilityIdentifier = pinnedOnly ? "pinned.list" : "artifacts.list"
        // [dashboard] Pins are dragged into the order they show in (a hold still opens the menu; moving lifts the pin).
        collectionView.dragDelegate = self
        collectionView.dropDelegate = self
        // [dashboard] Swipe sideways for the next or previous Dashboard page.
        if pinnedOnly {
            for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
                let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swipePage(_:)))
                swipe.direction = direction
                swipe.delegate = self
                collectionView.addGestureRecognizer(swipe)
                pageSwipes.append(swipe)
            }
        }
        collectionView.dragInteractionEnabled = true
        view.addSubview(collectionView)
        if tabRoot || toolRoot { ListBarAppearance.pinTitle(in: self, softEdgeAround: collectionView) }   // owner 2026-11-01: every tab's top
        if toolRoot { ListBarAppearance.dropLookTitle(navigationItem) }   // `pinTitle` set the tab's label
        PageBackdrop.install(in: self, clearing: [collectionView])   // [backdrop] Theme › App Background
        notices = PageNoticeHost(in: view)
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in self?.pulled() }, for: .valueChanged)
        collectionView.hqInstallRefresh(refresh)
        searchCapsule = PageBarCapsule.search(on: self, page: pinnedOnly ? "pinned" : "artifacts",
                                              placeholder: pinnedOnly ? "Search Tiles" : "Search Artifacts", updater: self)   // [morepages] §5
        configureDataSource()
        if barFilterHost { placeBarFilter() }
        if !pinnedOnly { claimStore() }
        pinPictures = PinPictures(account: store.account, previews: previews)
        pinPictures.onUpdate = { [weak self] id in self?.pinUpdated(id) }
        if pinnedOnly { liveTiles = makeLiveTiles() }
        previews.onUpdate = { [weak self] id in
            if id.hasPrefix("pin:") { self?.pinUpdated(String(id.dropFirst(4))) } else { self?.previewUpdated(id) }
        }
        pinsObserver = NotificationCenter.default.addObserver(forName: ArtifactPins.didChange, object: pins, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setNeedsReload() }
        }
        hiddenObserver = NotificationCenter.default.addObserver(forName: ArtifactHidden.didChange, object: hidden, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setNeedsReload() }
        }
        pinsViewObserver = NotificationCenter.default.addObserver(forName: ArtifactPins.viewChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pinsViewChanged() }
        }
        // [dashboard] A New Tile started or finished: the header says "Making a tile…" meanwhile.
        tileObserver = NotificationCenter.default.addObserver(forName: TileMaker.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pinnedOnly else { return }
                self.pinnedHeaderCount = -1
                self.setNeedsReload()
            }
        }
        // [tiles] A tile's bot finished changing it (Change…): its picture is drawn again.
        tileChangedObserver = NotificationCenter.default.addObserver(forName: TileMaker.tileChanged, object: nil, queue: .main) { [weak self] note in
            let id = note.userInfo?["id"] as? String
            let done = note.userInfo?["done"] as? Bool ?? false
            MainActor.assumeIsolated {
                guard let self, let id else { return }
                if done { self.markChanged(id) }
                self.redrawTile(id)
            }
        }
        scopeObserver = scope.observe { [weak self] _ in self?.scopeChanged() }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (vc: ArtifactsViewController, _) in vc.reload(animated: false) }
        // [mac] UI Scale (⌘+ / ⌘−) or the look changed: the Grid's cells and the pages in them follow the app's scale.
        drawnScale = HQFont.scale
        NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, HQFont.scale != self.drawnScale else { return }
                self.drawnScale = HQFont.scale
                self.collectionView.collectionViewLayout.invalidateLayout()
                self.reload(animated: false)
            }
        }
        store.setScope(currentScope)
        store.prepare()
        reload(animated: false)
    }

    isolated deinit {
        if let scopeObserver { scope.stopObserving(scopeObserver) }
        if let pinsObserver { NotificationCenter.default.removeObserver(pinsObserver) }
        if let pinsViewObserver { NotificationCenter.default.removeObserver(pinsViewObserver) }
        if let tileObserver { NotificationCenter.default.removeObserver(tileObserver) }
        if let tileChangedObserver { NotificationCenter.default.removeObserver(tileChangedObserver) }
        tileWatch?.cancel()
        if let hiddenObserver { NotificationCenter.default.removeObserver(hiddenObserver) }
    }

    /// The store's callbacks go to the page on screen. Verify round 2: a Kanban Tab change can leave a second page on the
    /// same store (tab 3 and one still on More's stack); the one that loaded last took them, and the other stopped
    /// updating and lost its notices.
    private func claimStore() {
        store.onChange = { [weak self] in self?.setNeedsReload() }
        store.onNotice = { [weak self] text, seconds in self?.notices.show(text, seconds: seconds) }
        store.onSessionsRead = { [weak self] sessions, listedAt in
            guard let self else { return }
            self.previews.forget(sessions: sessions, in: self.store.artifacts, keptBefore: listedAt)
            // [pins] A pinned page's chat was read again: the bot may have rewritten it.
            let read = Set(sessions.map(\.id))
            self.pinPictures.redraw(self.pins.pins.filter { read.contains($0.sessionId) }, drawnBefore: listedAt)
        }
        store.onGatewayReady = { [weak self] in self?.gatewayReady() }
    }

    /// The gateway is back: image tiles that failed for the link alone ask again.
    func gatewayReady() {
        guard viewIfLoaded?.window != nil else { return }
        retryTransientPreviews()
    }

    /// [offline] Tiles whose read failed for the link (not a missing or refused file) show loading and ask again; the
    /// four-read limit still applies.
    private func retryTransientPreviews() {
        guard previews.retryTransient(), dataSource != nil else { return }
        let images = collectionView.indexPathsForVisibleItems.compactMap { path -> Item? in
            if case .image? = dataSource.itemIdentifier(for: path) { return dataSource.itemIdentifier(for: path) }
            return nil
        }
        guard !images.isEmpty else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(images)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        searchCapsule?.restoreIfTyped()   // [morepages]
        if !pinnedOnly { claimStore() }
        store.setScope(currentScope)
        if !pinnedOnly { store.pageShown() }
        // [dashboard] Live tiles: a Job rewrites a tile's file on its schedule, so pages drawn over 10 minutes ago
        // are drawn again when the Dashboard opens (fresh ones are left alone).
        if pinnedOnly { pinPictures.redraw(pins.pins, drawnBefore: Date().addingTimeInterval(-600)) }
        watchTiles(true)
        liveTiles?.watch(true)
        reload(animated: false)
        retryTransientPreviews()
        if let selected = collectionView.indexPathsForSelectedItems { selected.forEach { collectionView.deselectItem(at: $0, animated: animated) } }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if pinnedOnly { navigationController?.interactiveContentPopGestureRecognizer?.isEnabled = true }
        if editingTiles { setEditingTiles(false) }
        updateMakingTimer(0)
        watchTiles(false)
        liveTiles?.watch(false)
    }

    /// [tiles] Each second while a tile is being made (and the page shows): the rows' step words again.
    private func updateMakingTimer(_ count: Int) {
        guard count > 0, viewIfLoaded?.window != nil || isMovingToParent || isBeingPresented else {
            makingTimer?.invalidate()
            makingTimer = nil
            return
        }
        guard makingTimer == nil else { return }
        makingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let dataSource = self.dataSource else { return }
                var snapshot = dataSource.snapshot()
                let rows = snapshot.itemIdentifiers.filter { if case .making = $0 { true } else { false } }
                guard !rows.isEmpty else { return }
                snapshot.reconfigureItems(rows)
                dataSource.apply(snapshot, animatingDifferences: false)
            }
        }
    }

    // MARK: Edit Tiles

    /// [dashboard] Into or out of Edit Tiles (Grid only).
    private func setEditingTiles(_ on: Bool) {
        let on = on && ArtifactPins.view == .grid
        guard on != editingTiles, isViewLoaded else { return }
        editingTiles = on
        resizing = nil
        if on {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(resizePanned(_:)))
            pan.delegate = self
            collectionView.addGestureRecognizer(pan)
            collectionView.panGestureRecognizer.require(toFail: pan)
            resizePan = pan
        } else if let pan = resizePan {
            collectionView.removeGestureRecognizer(pan)
            resizePan = nil
        }
        if on { Haptics.play(.soft) } else { PagesHaptics.selection() }
        AppLog.trace("pages", "edit tiles \(on ? "on" : "off")")
        var snapshot = dataSource.snapshot()
        guard snapshot.sectionIdentifiers.contains(.pinned) else { return }
        snapshot.reconfigureItems(snapshot.itemIdentifiers(inSection: .pinned))
        snapshot.reloadSections([.pinned])   // the header's button: View As, or Done
        dataSource.apply(snapshot, animatingDifferences: false)
        HQAnnounce.say(on ? "Editing tiles" : "Done editing tiles")
    }

    /// The pin tile whose corner handle is under `point` (in the collection view), and its frame.
    private func tileHandle(at point: CGPoint) -> (id: String, frame: CGRect)? {
        for cell in collectionView.visibleCells {
            guard let path = collectionView.indexPath(for: cell), case .pin(let id)? = dataSource.itemIdentifier(for: path) else { continue }
            var picture = cell.frame
            if ArtifactPins.showsNames { picture.size.height -= PinTileView.nameHeight }
            let box = PinTileView.handleBox
            let handle = CGRect(x: picture.maxX - box, y: picture.maxY - box, width: box + 8, height: box + 8)
            if handle.contains(point) { return (id, picture) }
        }
        return nil
    }

    /// [dashboard] A page swipe goes along with the list's own scrolling (it only reads a quick sideways flick).
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        pageSwipes.contains { $0 === gesture } && other === collectionView.panGestureRecognizer
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        // [dashboard] Not while editing tiles (a corner dragged sideways sizes a tile) or with one page.
        if let swipe = gesture as? UISwipeGestureRecognizer, pageSwipes.contains(where: { $0 === swipe }) {
            return showsPages && !editingTiles && pins.pages.count > 1
        }
        guard let pan = resizePan, gesture === pan else { return true }
        guard editingTiles, query.pgTrim.isEmpty else { return false }
        return tileHandle(at: pan.location(in: collectionView)) != nil
    }

    /// The corner dragged: the tile takes the size nearest to where the corner is, live, as the grid makes room.
    @objc private func resizePanned(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            guard let hit = tileHandle(at: pan.location(in: collectionView)), let pin = pinsShown[hit.id] else { return }
            resizing = (hit.id, hit.frame, pin.tileSize)
            AppLog.trace("pages", "tile resize began")
        case .changed:
            guard let current = resizing else { return }
            let width = collectionView.bounds.width - 2 * Self.gridInset
            let metrics = Self.gridMetrics(width: width, spacing: Self.gridSpacing, scale: HQFont.scale)
            let rowHeight = metrics.cell + (ArtifactPins.showsNames ? PinTileView.nameHeight : 0)
            let move = pan.translation(in: collectionView)
            let across = Int(((current.start.width + move.x + Self.gridSpacing) / (metrics.cell + Self.gridSpacing)).rounded())
            let down = Int(((current.start.height + move.y + Self.gridSpacing) / (rowHeight + Self.gridSpacing)).rounded())
            let size = PinTileSize.fitting(columns: max(1, min(across, metrics.columns)), rows: max(1, down))
            guard size != current.size else { return }
            resizing?.size = size
            PagesHaptics.selection()
            pins.setSize(size, id: current.id)
            AppLog.trace("pages", "tile resized \(size.rawValue)")
        default:
            resizing = nil
        }
    }
    /// The shared scope changed (here, or on Jobs). Off screen nothing happens until the page shows again
    /// (`viewWillAppear` sets the scope and starts the pass): an index pass never runs off screen (§5.3).
    private func scopeChanged() {
        guard fixedProfile == nil, viewIfLoaded?.window != nil else { return }
        store.setScope(currentScope)
        if !pinnedOnly { store.pageShown() }
        fileLimit = 100
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
        reload(animated: false)
    }

    // MARK: Layout

    private func makeLayout() -> UICollectionViewLayout {
        let cards = UICollectionViewCompositionalLayout { [weak self] index, environment in
            guard let self, let section = self.dataSource?.sectionIdentifier(for: index) else { return nil }
            switch section {
            case .pinned:
                return self.pinnedLayout(environment)
            case .images where self.isGrid:
                return self.gridImagesLayout(environment)
            case .day where self.isGrid:
                return self.gridCardsLayout(environment)
            case .images:
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1 / 3), heightDimension: .fractionalWidth(1 / 3)))
                item.contentInsets = NSDirectionalEdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1)
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                                                 heightDimension: .fractionalWidth(1 / 3)), subitems: [item])
                let s = NSCollectionLayoutSection(group: group)
                if self.filter == nil {
                    // On All the grid is one part of the page: an "Images" header and the 20 pt gutter its header and
                    // rows have (19 + the tile's 1), rounded tiles (UX study #88). The Images filter keeps the
                    // Photos-style edge-to-edge grid.
                    s.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 19, bottom: 4, trailing: 19)
                    let header = NSCollectionLayoutBoundarySupplementaryItem(
                        layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(36)),
                        elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
                    s.boundarySupplementaryItems = [header]
                    s.supplementaryContentInsetsReference = .none   // the header spans the width, as the day headers do
                } else {
                    s.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
                }
                return s
            default:
                var config = UICollectionLayoutListConfiguration(appearance: .plain)
                config.backgroundColor = .clear
                config.separatorConfiguration.color = HQPalette.separator
                config.itemSeparatorHandler = { _, separator in
                    var s = separator
                    s.topSeparatorVisibility = .hidden
                    s.bottomSeparatorInsets = NSDirectionalEdgeInsets(top: 0, leading: 76, bottom: 0, trailing: 20)   // as Bots and Jobs
                    return s
                }
                // [mac-ten] The Unavailable heading has no line under it, as no heading has (see `toggleCell`).
                if DeviceWord.isMac, case .unavailable = section {
                    config.itemSeparatorHandler = { path, separator in
                        var s = separator
                        s.topSeparatorVisibility = .hidden
                        if path.item == 0 { s.bottomSeparatorVisibility = .hidden }
                        s.bottomSeparatorInsets = NSDirectionalEdgeInsets(top: 0, leading: 76, bottom: 0, trailing: 20)
                        return s
                    }
                }
                if case .day = section {
                    config.headerMode = .supplementary
                    // [pins] Swipe a file or link right to pin it (hold for the same in the menu).
                    config.leadingSwipeActionsConfigurationProvider = { [weak self] path in self?.pinSwipe(at: path) }
                    config.trailingSwipeActionsConfigurationProvider = { [weak self] path in self?.removeSwipe(at: path) }
                }
                if case .filter = section { config.showsSeparators = false }
                if case .pages = section { config.showsSeparators = false }
                if case .making = section { config.showsSeparators = false }
                if case .state = section { config.showsSeparators = false }
                if case .showAllImages = section { config.showsSeparators = false }
                if case .allPins = section { config.showsSeparators = false }
                if case .count = section { config.showsSeparators = false }
                config.headerTopPadding = 0
                let s = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
                if case .day = section {
                    // [backdrop-cards] On a picture each day is a card, its date at the card's top (not pinned over others).
                    let cards = BackdropCards.on(self)
                    s.boundarySupplementaryItems.forEach { $0.pinToVisibleBounds = !cards }
                    BackdropCards.card(s, on: cards)
                }
                return s
            }
        }
        BackdropCards.register(in: cards)   // [backdrop-cards]
        return cards
    }

    // MARK: The Mac's grid

    /// [mac-tools] Thumbnails 150 pt or wider, as many across as fit (three at least, as the list's grid).
    private func gridImagesLayout(_ environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let width = environment.container.effectiveContentSize.width - 2 * Self.gridInset
        let columns = max(3, Int((width + Self.gridSpacing) / (150 + Self.gridSpacing)))
        let side = floor((width - CGFloat(columns - 1) * Self.gridSpacing) / CGFloat(columns))
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(side), heightDimension: .absolute(side)))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(side)),
                                                       repeatingSubitem: item, count: columns)
        group.interItemSpacing = .fixed(Self.gridSpacing)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = Self.gridSpacing
        section.contentInsets = NSDirectionalEdgeInsets(top: filter == nil ? 0 : 8, leading: Self.gridInset, bottom: 14, trailing: Self.gridInset)
        if filter == nil { section.boundarySupplementaryItems = [gridHeader()] }
        section.supplementaryContentInsetsReference = .none
        return section
    }

    /// [mac-tools] A day's files and links as cards 300 pt or wider: one column beside an open file, four or so
    /// across the whole window.
    private func gridCardsLayout(_ environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let width = environment.container.effectiveContentSize.width - 2 * Self.gridInset
        let columns = max(1, Int((width + Self.gridSpacing) / (300 + Self.gridSpacing)))
        let card = floor((width - CGFloat(columns - 1) * Self.gridSpacing) / CGFloat(columns))
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(card), heightDimension: .estimated(64)))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(64)),
                                                       subitems: [item])
        group.interItemSpacing = .fixed(Self.gridSpacing)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = Self.gridSpacing
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Self.gridInset, bottom: 14, trailing: Self.gridInset)
        section.boundarySupplementaryItems = [gridHeader()]
        section.supplementaryContentInsetsReference = .none
        return section
    }

    private func gridHeader() -> NSCollectionLayoutBoundarySupplementaryItem {
        NSCollectionLayoutBoundarySupplementaryItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(36)),
                                                    elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
    }

    /// [mac-tools] The bar leads with the page's name and, while there is room, the segments; narrowed beside an open
    /// file the segments are the list's first row again.
    private func placeBarFilter() {
        let inBar = filterInBar
        guard inBar != filterWasInBar else { return }
        let first = filterWasInBar == nil
        filterWasInBar = inBar
        var bar: ArtifactFilterBar?
        if inBar {
            let made = ArtifactFilterBar { [weak self] index in self?.pickSegment(index) }
            made.select([nil, .image, .file, .link].firstIndex(of: filter) ?? 0)
            made.translatesAutoresizingMaskIntoConstraints = false
            made.widthAnchor.constraint(equalToConstant: 320).isActive = true
            bar = made
        }
        barFilter = bar
        navigationItem.leftBarButtonItem = MacToolBar.lead(title: title ?? "Artifacts", popUp: bar)
        navigationItem.titleView = UIView()   // the middle stays empty; `title` still names the page (VoiceOver)
        if !first { reload(animated: false) }
    }

    private func pickSegment(_ index: Int) {
        PagesHaptics.selection()
        filter = [nil, .image, .file, .link][index]
        fileLimit = 100
        collectionView.collectionViewLayout.invalidateLayout()   // the grid's gutter and header follow the filter
        reload(animated: false)
    }

    private static let cardEdge = UIColor { traits in
        Theme.isDesktop || traits.userInterfaceStyle != .dark ? HQPalette.separator.resolvedColor(with: traits) : .clear
    }

    /// [mac-tools] `page` shows beside the grid for `record`: its card is marked and the page gets a ✕ that closes it.
    private func showBeside(_ page: UIViewController, for record: ArtifactRecord) {
        if isGrid, MainTabController.current?.split?.isDouble == true {
            let close = UIBarButtonItem(image: UIImage(systemName: "xmark"), primaryAction: UIAction { _ in
                MainTabController.current?.split?.closeDetail(animated: true)
            })
            close.accessibilityLabel = "Close File"
            close.accessibilityIdentifier = "artifacts.file.close"
            page.navigationItem.leftBarButtonItem = close
            markedId = record.id
            markedPage = page
        }
        navigationController?.pushViewController(page, animated: true)
        restoreMark()
    }

    private func restoreMark() {
        guard isGrid, let collectionView else { return }
        let marked = markedId.flatMap { dataSource.indexPath(for: .row($0)) }
        for path in collectionView.indexPathsForSelectedItems ?? [] where path != marked {
            collectionView.deselectItem(at: path, animated: false)
        }
        if let marked, collectionView.indexPathsForSelectedItems?.contains(marked) != true {
            collectionView.selectItem(at: marked, animated: false, scrollPosition: [])
        }
    }

    /// The right pane shows `root` now: a grid whose file is no longer the one on show drops its mark.
    static func markOnShow(_ root: UIViewController?, keepsSelection: Bool) {
        for page in live.allObjects where page.isViewLoaded && page.markedId != nil {
            if !keepsSelection || page.markedPage == nil || page.markedPage !== root {
                page.markedId = nil
                page.markedPage = nil
                page.restoreMark()
            }
        }
    }

    /// [pins] On Artifacts a shelf that scrolls sideways under a "Pinned" header; on the Pinned page a grid of larger
    /// cards (one column on a phone, as many 320 pt columns as fit on a wider screen).
    private func pinnedLayout(_ environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        if ArtifactPins.view == .list { return pinnedListLayout(environment) }
        if ArtifactPins.view == .grid { return pinnedGridLayout(environment) }
        let width = environment.container.effectiveContentSize.width
        let wide = width >= 600
        let textHeight = ceil(HQFont.preferred(.subheadline).lineHeight + HQFont.preferred(.caption1).lineHeight + 17)
        if pinnedOnly {
            let columns = max(1, Int((width - 32) / 320))
            let picture: CGFloat = wide ? 230 : 210
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1 / CGFloat(columns)),
                                                                heightDimension: .absolute(picture + textHeight)))
            item.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                                             heightDimension: .absolute(picture + textHeight + 12)),
                                                           repeatingSubitem: item, count: columns)
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 16, trailing: 10)
            section.boundarySupplementaryItems = [NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(36)),
                elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)]
            section.supplementaryContentInsetsReference = .none
            return section
        }
        let cardWidth: CGFloat = wide ? 300 : min(260, width * 0.68)
        let picture: CGFloat = wide ? 170 : 140
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .absolute(cardWidth),
                                                                         heightDimension: .absolute(picture + textHeight)),
                                                       subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuousGroupLeadingBoundary
        section.interGroupSpacing = 12
        section.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 20, bottom: 14, trailing: 20)
        let header = NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(36)),
            elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
        section.boundarySupplementaryItems = [header]
        section.supplementaryContentInsetsReference = .none
        return section
    }

    /// [dashboard] Grid: square cells 150 pt or wider (two across a phone, more on a wider screen), each tile spanning its
    /// size's cells (`PinGridPacking`), with room for a name under every row of tiles when names show.
    private func pinnedGridLayout(_ environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let width = environment.container.effectiveContentSize.width
        let inset = Self.gridInset, spacing = Self.gridSpacing
        let layout = Self.gridMetrics(width: width - 2 * inset, spacing: spacing, scale: HQFont.scale)
        let name = ArtifactPins.showsNames ? PinTileView.nameHeight : 0
        let rowHeight = layout.cell + name
        let spans = gridPinIds().map { (pinsShown[$0]?.tileSize ?? .small).span }
        let packing = PinGridPacking.place(spans, columns: layout.columns)
        let frames = packing.cells.map { cell in
            CGRect(x: CGFloat(cell.column) * (layout.cell + spacing), y: CGFloat(cell.row) * (rowHeight + spacing),
                   width: CGFloat(cell.columns) * layout.cell + CGFloat(cell.columns - 1) * spacing,
                   height: CGFloat(cell.rows) * rowHeight + CGFloat(cell.rows - 1) * spacing)
        }
        let height = max(1, CGFloat(packing.rows) * rowHeight + CGFloat(max(0, packing.rows - 1)) * spacing)
        let group = NSCollectionLayoutGroup.custom(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height))) { _ in
            frames.map { NSCollectionLayoutGroupCustomItem(frame: $0) }
        }
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: inset, bottom: 16, trailing: inset)
        section.boundarySupplementaryItems = [NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(36)),
            elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)]
        section.supplementaryContentInsetsReference = .none
        return section
    }

    nonisolated static let gridInset: CGFloat = 20
    nonisolated static let gridSpacing: CGFloat = 12

    /// [dashboard] The shape of a pin's picture where it shows (its page is drawn in that shape): its Grid tile, a card's
    /// picture, a list row's square.
    private func pinPictureShape(_ pin: ArtifactPin) -> PageSnapshots.Shape {
        let width = collectionView.bounds.width > 0 ? collectionView.bounds.width : view.bounds.width
        switch ArtifactPins.view {
        case .grid:
            let metrics = Self.gridMetrics(width: width - 2 * Self.gridInset, spacing: Self.gridSpacing, scale: HQFont.scale)
            let span = pin.tileSize.span
            let across = CGFloat(min(span.columns, metrics.columns)), down = CGFloat(span.rows)
            let rowGap = Self.gridSpacing + (ArtifactPins.showsNames ? PinTileView.nameHeight : 0)
            return .frame(width: across * metrics.cell + (across - 1) * Self.gridSpacing,
                          height: down * metrics.cell + (down - 1) * rowGap, zoom: max(1, HQFont.scale))
        case .cards:
            let wide = width >= 600
            if pinnedOnly {
                let columns = max(1, Int((width - 32) / 320))
                return .tile(width: (width - 20) / CGFloat(columns) - 12, height: wide ? 230 : 210)
            }
            return .tile(width: wide ? 300 : min(260, width * 0.68), height: wide ? 170 : 140)
        case .list:
            return .box(aspect: 1)
        }
    }

    /// [dashboard] How many cells across `width`, and their side: 150 pt or more on a phone, 190 on a wider screen, both
    /// times the app's scale. [mac] Owner 2026-11-10 on a big screen: "our proportions are different", only Large tiles
    /// were easy to see. The Mac draws the app at 77 % and the rest of it grows by UI Scale × 115–130 % (`HQFont.scale`);
    /// the cells and the pages in them (`pinPictureShape`, `LiveTileHost`) didn't.
    nonisolated static func gridMetrics(width: CGFloat, spacing: CGFloat, scale: CGFloat = 1) -> (columns: Int, cell: CGFloat) {
        let least: CGFloat = (width >= 560 ? 190 : 150) * max(1, scale)
        let columns = max(2, Int((width + spacing) / (least + spacing)))
        return (columns, floor((width - CGFloat(columns - 1) * spacing) / CGFloat(columns)))
    }

    /// [dashboard] The pins in the Pinned section, in order (the grid's layout places them).
    private func gridPinIds() -> [String] {
        guard let dataSource, dataSource.snapshot().sectionIdentifiers.contains(.pinned) else { return [] }
        return dataSource.snapshot().itemIdentifiers(inSection: .pinned).compactMap { if case .pin(let id) = $0 { id } else { nil } }
    }

    /// [pins] The pins as rows, as Today's: under a "Pinned" header on Artifacts, alone on the Pinned page.
    private func pinnedListLayout(_ environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.backgroundColor = .clear
        config.separatorConfiguration.color = HQPalette.separator
        config.itemSeparatorHandler = { _, separator in
            var s = separator
            s.topSeparatorVisibility = .hidden
            s.bottomSeparatorInsets = NSDirectionalEdgeInsets(top: 0, leading: 76, bottom: 0, trailing: 20)
            return s
        }
        config.headerMode = .supplementary
        config.headerTopPadding = 0
        config.leadingSwipeActionsConfigurationProvider = { [weak self] path in self?.pinSwipe(at: path) }
        config.trailingSwipeActionsConfigurationProvider = { [weak self] path in self?.removeSwipe(at: path) }
        return NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
    }

    /// [pins] Grid ⇄ Cards ⇄ List (or Grid's names): the pinned section's layout and its items change.
    private func pinsViewChanged() {
        guard isViewLoaded else { return }
        if ArtifactPins.view != .grid { editingTiles = false }
        pinnedHeaderCount = -1
        collectionView.collectionViewLayout.invalidateLayout()
        reload(animated: false)
        // The header's button shows the new choice.
        var snapshot = dataSource.snapshot()
        guard snapshot.sectionIdentifiers.contains(.pinned) else { return }
        snapshot.reloadSections([.pinned])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// [pins] A file or link row swiped right: Pin, or Unpin when it is pinned. A pinned row (List): Unpin.
    private func pinSwipe(at path: IndexPath) -> UISwipeActionsConfiguration? {
        let record: ArtifactRecord
        switch dataSource.itemIdentifier(for: path) {
        case .row(let id)?: guard let found = records[id] else { return nil }; record = found
        case .pinRow(let id)?: guard let pin = pinsShown[id] else { return nil }; record = pin.record
        default: return nil
        }
        let pinned = pins.isPinned(record)
        let action = UIContextualAction(style: .normal, title: pinned ? "Unpin" : "Pin") { [weak self] _, _, done in
            guard let self else { done(false); return }
            PinActions.toggle(record, pins: self.pins, from: self)
            done(true)
        }
        action.image = UIImage(systemName: pinned ? "pin.slash.fill" : "pin.fill")
        action.backgroundColor = pinned ? HQPalette.muted : HQPalette.orange
        let config = UISwipeActionsConfiguration(actions: [action])
        config.performsFirstActionWithFullSwipe = true
        return config
    }

    /// A file or link row (or a pinned row) swiped left: Remove, which asks first ([safer-deletes]).
    private func removeSwipe(at path: IndexPath) -> UISwipeActionsConfiguration? {
        let record: ArtifactRecord, name: String?
        switch dataSource.itemIdentifier(for: path) {
        case .row(let id)?: guard let found = records[id] else { return nil }; record = found; name = nil
        case .pinRow(let id)?: guard let pin = pinsShown[id] else { return nil }; record = pin.record; name = pin.name
        default: return nil
        }
        return PinActions.removeSwipe { [weak self] in
            self?.confirmRemove(record, name: name, source: self?.collectionView.cellForItem(at: path))
        }
    }

    /// [safer-deletes] Remove's question, from the row or tile (`source`), then the removal.
    private func confirmRemove(_ record: ArtifactRecord, name: String? = nil, source: UIView?) {
        PinActions.confirmRemove(record, name: name, hidden: hidden, pins: pins, from: self, source: source)
    }

    private func configureDataSource() {
        // [dashboard] The Dashboard's pages, under its title.
        let pagesCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, _ in
            guard let self else { return }
            let bar = (cell.contentView.subviews.first as? DashboardPagesBar) ?? self.makePagesBar(in: cell)
            self.showPages(bar)
            cell.backgroundConfiguration = .clear()
        }
        // [tiles] A tile being made (owner 2026-11-03: "it says making a tile but idk where to see it doing anything"):
        // what was asked, the bot and the step it's on now; a tap opens the chat.
        let makingCell = UICollectionView.CellRegistration<TileMakingCell, String> { cell, _, id in
            guard let maker = TileMaker.active.first(where: { $0.id == id }) else { return }
            cell.show(what: maker.rowTitle, detail: "\(maker.bot.name) · \(maker.stepWords)", changing: maker.changing != nil)
        }
        let filterCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, _ in
            guard let self else { return }
            let bar = (cell.contentView.subviews.first as? ArtifactFilterBar) ?? self.makeFilterBar(in: cell)
            bar.select([nil, .image, .file, .link].firstIndex(of: self.filter) ?? 0)
            cell.backgroundConfiguration = .clear()
        }
        let imageCell = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            guard let self, let record = self.records[id] else { return }
            self.configureTile(cell, record)
        }
        let showAllCell = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { cell, _, count in
            var content = UIListContentConfiguration.cell().hqScaled()
            content.text = "Show All \(count) Images"
            content.textProperties.color = HQPalette.tint
            cell.contentConfiguration = content
            cell.accessories = [Self.showAllChevron]
            cell.accessibilityIdentifier = "artifacts.show-all-images"
            cell.backgroundConfiguration = .clear()
        }
        let rowCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let self, let record = self.records[id] else { return }
            self.configureRow(cell, record, missing: false)
        }
        let missingCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let self, let record = self.records[id] else { return }
            self.configureRow(cell, record, missing: true)
        }
        let toggleCell = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { [weak self] cell, _, count in
            var content = UIListContentConfiguration.cell().hqScaled()
            content.text = "Unavailable (\(count))"
            content.textProperties.color = HQPalette.label2
            if DeviceWord.isMac {
                // [mac-ten] Owner 2026-11-11 ("weird UI issues"): it folds a group, as Images, Today and Sunday name
                // theirs, but drew as a body-size row with a line under it that started 56 pt in. The headings' type
                // (the Desktop Look's tracked capitals), and no line (`itemSeparatorHandler`).
                content.textProperties.font = MacType.sectionHeader
                if Theme.isDesktop {
                    content.attributedText = NSAttributedString(string: (content.text ?? "").uppercased(), attributes: DesktopLayout.labelAttributes())
                }
            }
            cell.contentConfiguration = content
            cell.accessories = [.outlineDisclosure(options: .init(style: .cell, tintColor: HQPalette.label3))]
            cell.accessibilityIdentifier = "artifacts.unavailable"
            cell.accessibilityValue = (self?.unavailableOpen ?? false) ? "open" : "closed"
            cell.backgroundConfiguration = .clear()
        }
        let moreCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { cell, _, _ in
            cell.contentConfiguration = UIHostingConfiguration { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12) }
            cell.backgroundConfiguration = .clear()
        }
        let stateCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.contentConfiguration = BackdropState.wrap(self.stateConfiguration())   // [backdrop-cards]
            cell.backgroundConfiguration = .clear()
        }
        let countCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { cell, _, text in
            cell.contentConfiguration = UIHostingConfiguration { PageCountView(text: text) }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        let pinCell = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            guard let self, let pin = self.pinsShown[id] else { return }
            self.configurePin(cell, pin)
        }
        let pinRowCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let self, let pin = self.pinsShown[id] else { return }
            self.configurePinRow(cell, pin)
        }
        let allPinsCell = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { cell, _, count in
            var content = UIListContentConfiguration.cell().hqScaled()
            content.text = "See All \(count)"
            content.textProperties.color = HQPalette.tint
            cell.contentConfiguration = content
            cell.accessories = [Self.showAllChevron]
            cell.accessibilityIdentifier = "artifacts.all-pins"
            cell.backgroundConfiguration = .clear()
        }
        let skeletonCell = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { cell, _, _ in
            cell.contentConfiguration = UIHostingConfiguration { PageSkeletonRow(tile: true) }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader) { [weak self] header, _, path in
            guard let self else { return }
            var content = UIListContentConfiguration.header().hqScaled()
            switch self.dataSource.sectionIdentifier(for: path.section) {
            case .day(let day)?: content.text = day
            case .images?: content.text = "Images"
            case .pinned?: content.text = self.pinnedOnly ? self.dashboardHeader() : "Tiles"
            default: return
            }
            content.textProperties.font = HQFont.preferred(.subheadline).pagesWeight(.semibold)
            content.textProperties.color = HQPalette.label2
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 20, bottom: 6, trailing: 20)
            // Mac polish #116: the Desktop Look's tracked capitals, as its other section labels (Kanban's, the forms').
            // The Tiles page's count ("6 Items") is not a heading and keeps its words.
            let count: Bool
            if case .pinned? = self.dataSource.sectionIdentifier(for: path.section) { count = self.pinnedOnly } else { count = false }
            if Theme.isDesktop, !count {
                content.attributedText = NSAttributedString(string: (content.text ?? "").uppercased(), attributes: DesktopLayout.labelAttributes())
            }
            header.contentConfiguration = content.hqMacSectionHeader()   // [mac] Stress test 2026-10-28 #52
            // [pins] Beside "Pinned": View As Cards | List, and Open Pinned.
            if case .pinned? = self.dataSource.sectionIdentifier(for: path.section) {
                // The button's 44 pt box stands over the ⋯ below it: a row's (6 pt in), a Pinned page card's (12 pt
                // in); on the shelf its glyph ends where the cards do (20 pt in).
                let trailing: CGFloat = ArtifactPins.showsList ? 6 : (self.pinnedOnly && ArtifactPins.view == .cards ? 12 : 8)
                header.preservesSuperviewLayoutMargins = false
                header.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 20, bottom: 0, trailing: trailing)
                // [dashboard] On the Dashboard, ＋ (New Tile) before it.
                let tiles = self.pinnedOnly && !self.editingTiles && self.services != nil
                let view: UIView = tiles ? self.newTileAndViewButtons() : self.pinsHeaderButton(openAll: !self.pinnedOnly)
                header.accessories = [.customView(configuration: .init(customView: view, placement: .trailing(),
                                                                       reservedLayoutWidth: .custom(self.editingTiles ? 56 : tiles ? 88 : 44), tintColor: HQPalette.label2,
                                                                       maintainsFixedSize: true))]
            } else {
                header.accessories = []
            }
            var background = UIBackgroundConfiguration.clear()
            background.backgroundColor = HQPalette.page
            header.backgroundConfiguration = background
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { cv, path, item in
            switch item {
            case .filter: return cv.dequeueConfiguredReusableCell(using: filterCell, for: path, item: "filter")
            case .pages: return cv.dequeueConfiguredReusableCell(using: pagesCell, for: path, item: "pages")
            case .making(let id): return cv.dequeueConfiguredReusableCell(using: makingCell, for: path, item: id)
            case .image(let id): return cv.dequeueConfiguredReusableCell(using: imageCell, for: path, item: id)
            case .showAllImages(let n): return cv.dequeueConfiguredReusableCell(using: showAllCell, for: path, item: n)
            case .row(let id): return cv.dequeueConfiguredReusableCell(using: rowCell, for: path, item: id)
            case .loadMore: return cv.dequeueConfiguredReusableCell(using: moreCell, for: path, item: "more")
            case .unavailableToggle(let n): return cv.dequeueConfiguredReusableCell(using: toggleCell, for: path, item: n)
            case .unavailableRow(let id): return cv.dequeueConfiguredReusableCell(using: missingCell, for: path, item: id)
            case .state: return cv.dequeueConfiguredReusableCell(using: stateCell, for: path, item: "state")
            case .skeleton(let n): return cv.dequeueConfiguredReusableCell(using: skeletonCell, for: path, item: n)
            case .count(let text): return cv.dequeueConfiguredReusableCell(using: countCell, for: path, item: text)
            case .pin(let id): return cv.dequeueConfiguredReusableCell(using: pinCell, for: path, item: id)
            case .pinRow(let id): return cv.dequeueConfiguredReusableCell(using: pinRowCell, for: path, item: id)
            case .allPins(let n): return cv.dequeueConfiguredReusableCell(using: allPinsCell, for: path, item: n)
            }
        }
        dataSource.supplementaryViewProvider = { cv, _, path in cv.dequeueConfiguredReusableSupplementary(using: header, for: path) }
    }

    /// Show All and See All end in the tinted chevron; [mac] Mac polish #119: the Mac's quiet one, as its other rows.
    private static var showAllChevron: UICellAccessory {
        DeviceWord.isMac ? .hqDisclosure() : .disclosureIndicator(options: .init(tintColor: HQPalette.tint))
    }

    /// All · Images · Files · Links; segments size to their labels, two by two at accessibility sizes.
    private func makeFilterBar(in cell: UICollectionViewListCell) -> ArtifactFilterBar {
        let bar = ArtifactFilterBar { [weak self] index in self?.pickSegment(index) }
        bar.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 4),
            bar.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -10),
            bar.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
        ])
        return bar
    }

    private func configureTile(_ cell: UICollectionViewCell, _ record: ArtifactRecord) {
        let state = previews.state(record)
        // A kept picture asks too: its chat may have been read again since (it stays up while the fresh one loads).
        if case .failed = state {} else {
            let scale = traitCollection.displayScale
            previews.request(record, pixels: max(cell.bounds.width, view.bounds.width / 3) * scale)
        }
        let image: UIImage?
        var failed = false, hosted = false
        switch state {
        case .image(let picture): image = picture
        case .failed(_, _, let elsewhere): image = nil; failed = true; hosted = elsewhere
        case .loading: image = nil
        }
        let rounded = filter == nil || isGrid
        let pinned = pins.isPinned(record)
        cell.contentConfiguration = UIHostingConfiguration {
            ArtifactTileView(image: image, failed: failed, hosted: hosted, rounded: rounded, pinned: pinned)
        }.margins(.all, 0)
        cell.accessibilityIdentifier = "artifact-tile-\(record.label)"
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = (hosted ? "\(record.label), on another site, \(record.sessionTitle)" : "\(record.label), \(record.sessionTitle)")
            + (pinned ? ", pinned" : "")
        cell.accessibilityTraits = .button
    }

    private func configurePin(_ cell: UICollectionViewCell, _ kept: ArtifactPin) {
        let pin = pins.shown(kept)   // Mac polish #45: its name as every list shows it
        let dark = traitCollection.userInterfaceStyle == .dark
        let grid = ArtifactPins.view == .grid
        let pixels = (pinnedOnly || grid && pin.tileSize != .small ? 640 : 520) * traitCollection.displayScale
        let shape = pinPictureShape(pin)
        let picture = pinPictures.picture(pin, dark: dark, pixels: pixels, shape: shape)
        let busy = picture == nil && (pinPictures.waiting(pin, dark: dark, shape: shape) || openingRow == pin.record.id)
        let bot = PagesNames.botName(pin.profile, bots: services?.bots ?? [])
        let subtitle = store.scope != "all" && !pin.sessionTitle.isEmpty ? pin.sessionTitle   // one bot: its name says nothing
            : pin.sessionTitle.isEmpty ? bot : "\(bot) · \(pin.sessionTitle)"
        let health = TileUpdates.shared.health(pin.id)
        let hover = pinHover(pin.id, cell: cell)
        let failed = pinPictures.failed(pin)   // Mac polish #46
        // [tiles] Its bot working on it (Change…, a button), and the moment after a change is done.
        let working = TileMaker.working(on: pin.id, accountId: store.account.id)?.tileWords
        let ringed = justChanged.contains(pin.id)
        if grid {
            let names = ArtifactPins.showsNames, editing = editingTiles
            let live = editing ? nil : liveTiles?.view(for: pin, dark: dark)   // [live-tiles]
            cell.contentConfiguration = UIHostingConfiguration {
                PinTileView(pin: pin, picture: picture, fills: pin.kind == .image, busy: busy, showsName: names, health: health,
                            editing: editing, live: live, hover: hover, failed: failed,
                            working: editing ? nil : working, ringed: ringed && !editing) { [weak self] in
                    guard let self else { return }
                    PinActions.toggle(pin.record, pins: self.pins, from: self)
                }
            }.margins(.all, 0)
        } else {
            cell.contentConfiguration = UIHostingConfiguration {
                PinCardView(pin: pin, picture: picture, fills: pin.kind == .image, subtitle: subtitle, busy: busy, health: health,
                            hover: hover, failed: failed, working: working, ringed: ringed) { [weak self, weak cell] in
                    self?.pinMenu(kept, anchor: cell) ?? UIMenu(children: [])   // the kept pin: Rename… starts from its own name
                }
            }.margins(.all, 0)
        }
        cell.accessibilityIdentifier = "pin-card-\(pin.label)"
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = "\(pin.isPage ? "Page" : pin.kind == .image ? "Image" : pin.kind == .link ? "Link" : "File"), \(pin.name), \(subtitle)"
            + (grid ? ", \(pin.tileSize.title)" : "") + (TileHealthMark.words(health).map { ", " + $0 } ?? "") + (failed ? ", unavailable" : "")
            + (working.map { ", " + $0 } ?? "")
        cell.accessibilityTraits = .button
        cell.accessibilityCustomActions = liveButtonActions(pin) + pinAccessibilityActions(pin)
        cell.configurationUpdateHandler = { cell, state in
            cell.contentView.alpha = state.isHighlighted ? 0.6 : 1
        }
    }

    /// [mac] Mac polish #110: the tile or card draws its own hover on its shape, not the rows' square fill. Kept by pin,
    /// so a redraw under a resting pointer (a picture landing, a read) keeps it; nil off the Mac.
    private var pinHovers: [String: PinHover] = [:]

    private func pinHover(_ id: String, cell: UICollectionViewCell) -> PinHover? {
        #if targetEnvironment(macCatalyst)
        let hover = pinHovers[id] ?? PinHover()
        pinHovers[id] = hover
        MacHover.ownsHover(cell) { [weak hover] in hover?.set($0) }
        return hover
        #else
        return nil
        #endif
    }

    /// [live-tiles] A live tile's own buttons, by their words: VoiceOver reads the tile as one element, so they are its
    /// actions (pressed in the page, as a tap would).
    private func liveButtonActions(_ pin: ArtifactPin) -> [UIAccessibilityCustomAction] {
        guard ArtifactPins.view == .grid, !editingTiles, let liveTiles, liveTiles.isRunning(pin.id) else { return [] }
        return liveTiles.buttons(pin.id).map { words in
            UIAccessibilityCustomAction(name: words) { [weak liveTiles] _ in
                liveTiles?.press(pin.id, button: words)
                return true
            }
        }
    }

    /// [pins] Unpin; [dashboard] Move Earlier / Move Later (dragging, without a drag).
    private func pinAccessibilityActions(_ pin: ArtifactPin) -> [UIAccessibilityCustomAction] {
        var actions = [UIAccessibilityCustomAction(name: "Unpin") { [weak self] _ in
            guard let self else { return false }
            PinActions.toggle(pin.record, pins: self.pins, from: self)
            return true
        }]
        let shown = visiblePins()
        guard let index = shown.firstIndex(where: { $0.id == pin.id }) else { return actions }
        if index > 0 {
            actions.append(UIAccessibilityCustomAction(name: "Move Earlier") { [weak self] _ in
                self?.pins.move(id: pin.id, to: shown[index - 1].id); return true
            })
        }
        if index < shown.count - 1 {
            actions.append(UIAccessibilityCustomAction(name: "Move Later") { [weak self] _ in
                self?.pins.move(id: pin.id, to: shown[index + 1].id); return true
            })
        }
        return actions
    }

    /// [pins] A pin as a row, as Today's rows (List).
    private func configurePinRow(_ cell: UICollectionViewListCell, _ pin: ArtifactPin) {
        let bot = PagesNames.botName(pin.profile, bots: services?.bots ?? [])
        let subtitle = store.scope != "all" && !pin.sessionTitle.isEmpty ? pin.sessionTitle   // one bot: its name says nothing
            : pin.sessionTitle.isEmpty ? bot : "\(bot) · \(pin.sessionTitle)"
        let busy = openingRow == pin.record.id || TileMaker.working(on: pin.id, accountId: store.account.id) != nil   // [tiles]
        // Mac polish #46: a row draws no picture, so a gone one was never asked for and never known to be gone; a small
        // read (shared with the grid and cards) finds out, and the row then wears the missing mark.
        if pin.kind == .image {
            _ = pinPictures.picture(pin, dark: traitCollection.userInterfaceStyle == .dark, pixels: 120 * traitCollection.displayScale,
                                    shape: pinPictureShape(pin))
        }
        let failed = pinPictures.failed(pin)   // Mac polish #46: a picture that's gone is drawn as missing
        // Mac polish #45: a page's own title, read here too (a row draws no picture, which is where it was read).
        pinPictures.readHead(pin) { [weak self] head in self?.pins.notePage(id: pin.id, head: head) }
        // [tiles] Its name in words; the record (and so the file it opens) unchanged.
        var shown = pin.record
        shown.label = pins.name(pin)
        cell.contentConfiguration = UIHostingConfiguration {
            ArtifactRowView(record: shown, subtitle: subtitle, busy: busy, missing: failed, pinned: true) { [weak self, weak cell] in
                self?.pinMenu(pin, anchor: cell) ?? UIMenu(children: [])
            }
        }.margins(.all, 0)
        cell.accessibilityIdentifier = "pin-row-\(pin.label)"
        cell.accessibilityCustomActions = liveButtonActions(pin) + pinAccessibilityActions(pin)
        cell.configurationUpdateHandler = { cell, state in
            #if targetEnvironment(macCatalyst)
            if DeviceWord.isMac { cell.backgroundConfiguration = MacSelection.listRow(state); return }
            #endif
            var background = UIBackgroundConfiguration.clear()
            background.backgroundColor = state.isHighlighted || state.isSelected ? HQPalette.cellPressed : .clear
            cell.backgroundConfiguration = background
        }
    }

    /// [pins] The small button by the "Pinned" header (Artifacts) and the "3 Pinned" header (the Pinned page).
    private func pinsHeaderButton(openAll: Bool) -> UIButton {
        if editingTiles {
            // [dashboard] Edit Tiles ends here.
            var done = UIButton.Configuration.plain()
            done.attributedTitle = AttributedString("Done", attributes: AttributeContainer([.font: HQFont.preferred(.subheadline).pagesWeight(.semibold)]))
            done.baseForegroundColor = HQPalette.tint
            done.contentInsets = .zero
            let button = UIButton(configuration: done, primaryAction: UIAction { [weak self] _ in self?.setEditingTiles(false) })
            button.frame = CGRect(x: 0, y: 0, width: 56, height: 36)
            button.accessibilityIdentifier = "pins.done"
            return button
        }
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: PinActions.viewSymbol)
        // Grows with the text to 22 pt, the box it stands in (44 × 36) holding it at every size.
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: min(HQFont.preferred(.subheadline).pointSize, 22))
        config.baseForegroundColor = HQPalette.label2
        config.contentInsets = .zero
        let button = UIButton(configuration: config)
        button.frame = CGRect(x: 0, y: 0, width: 44, height: 36)
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            var children = PinActions.viewMenu(openAll: openAll ? { self?.openPinnedPage() } : nil,
                                               editTiles: { self?.setEditingTiles(true) }).children
            // [dashboard] New Page: the way to a second page while there is one (the names show from two).
            if let self, self.showsPages {
                let new = UIAction(title: "New Page…", image: UIImage(systemName: "plus.rectangle.on.rectangle")) { [weak self] _ in self?.askNewPage() }
                new.accessibilityIdentifier = "dashboard.page.new"
                children.append(UIMenu(options: .displayInline, children: [new]))
            }
            done(children)
        }])
        button.accessibilityIdentifier = "pins.view"
        button.accessibilityLabel = "View As"
        return button
    }

    // MARK: Dashboard pages

    /// [dashboard] The page names show on the Dashboard, not on Artifacts' shelf or Bot Info, and not while searching.
    private var showsPages: Bool { pinnedOnly && fixedProfile == nil && query.pgTrim.isEmpty }

    private weak var pagesBar: DashboardPagesBar?
    /// The slot a held tile last opened among the pins: a tick each time the others slide into a new one.
    private var dropSlot: IndexPath?
    private var pageSwipes: [UISwipeGestureRecognizer] = []

    private func makePagesBar(in cell: UICollectionViewListCell) -> DashboardPagesBar {
        let bar = DashboardPagesBar()
        bar.onSelect = { [weak self] id in self?.showPage(id) }
        bar.onAdd = { [weak self] in self?.askNewPage() }
        bar.menuFor = { [weak self] page in self?.pageMenu(page) }
        bar.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 2),
            bar.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
            bar.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -20),
            bar.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
        ])
        pagesBar = bar
        return bar
    }

    private func showPages(_ bar: DashboardPagesBar) {
        var counts: [String: Int] = [:]
        for pin in hidden.visible(pins.pins) { counts[pins.pageId(of: pin), default: 0] += 1 }
        bar.show(pins.pages, current: pins.currentPage, counts: counts)
        pagesBar = bar
    }

    /// [dashboard] Another page shown (a name tapped, or a swipe sideways): the tiles cross-fade.
    func showPage(_ id: String) {
        guard id != pins.currentPage else { return }
        PagesHaptics.selection()
        AppLog.trace("pages", "dashboard page \(id == DashboardPage.mainId ? "main" : "own") shown")
        pins.currentPage = id   // didChange → reload
        if view.window != nil, !HQMotion.reduced {
            UIView.transition(with: collectionView, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction], animations: nil)
        }
    }

    /// [dashboard] iOS 26's swipe-right-anywhere Back would take the Dashboard's swipe to the previous page: off past the
    /// first page (on the first, swiping right goes Back as everywhere).
    private func updateContentPop() {
        guard let navigation = navigationController, navigation.topViewController === self else { return }
        let first = pins.pages.first?.id == pins.currentPage
        navigation.interactiveContentPopGestureRecognizer?.isEnabled = !showsPages || first
    }

    /// [dashboard] Swiped sideways on the Dashboard: the next or previous page, as the Home Screen's.
    @objc private func swipePage(_ swipe: UISwipeGestureRecognizer) {
        guard showsPages, !editingTiles, let index = pins.pages.firstIndex(where: { $0.id == pins.currentPage }) else { return }
        let next = index + (swipe.direction == .left ? 1 : -1)
        guard pins.pages.indices.contains(next) else { return }
        showPage(pins.pages[next].id)
    }

    private func askNewPage() {
        askPageName(title: "New Page", name: "", action: "Add") { [weak self] name in
            guard let self else { return }
            PagesHaptics.success()
            self.pins.addPage(named: name)
            AppLog.trace("pages", "dashboard page added (\(self.pins.pages.count) pages)")
        }
    }

    private func askPageName(title: String, name: String, action: String, done: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = name
            field.placeholder = "Name"
            field.autocapitalizationType = .words
            field.clearButtonMode = .whileEditing
            field.accessibilityIdentifier = "dashboard.page.name"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        let ok = UIAlertAction(title: action, style: .default) { [weak alert] _ in
            let words = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !words.isEmpty { done(words) }
        }
        alert.addAction(ok)
        alert.preferredAction = ok
        present(alert, animated: true)
    }

    /// [dashboard] A page name held: Rename, Move Left/Right, Delete (Main can be renamed, not moved or deleted).
    private func pageMenu(_ page: DashboardPage) -> UIMenu {
        let rename = UIAction(title: "Rename…", image: UIImage(systemName: "pencil")) { [weak self] _ in
            self?.askPageName(title: "Rename Page", name: page.name, action: "Rename") { name in
                PagesHaptics.success()
                self?.pins.renamePage(page.id, to: name)
            }
        }
        rename.accessibilityIdentifier = "dashboard.page.rename"
        var children: [UIMenuElement] = [rename]
        guard page.id != DashboardPage.mainId, let index = pins.pages.firstIndex(of: page) else { return UIMenu(children: children) }
        var moves: [UIMenuElement] = []
        if index > 1 {
            moves.append(UIAction(title: "Move Left", image: UIImage(systemName: "arrow.left")) { [weak self] _ in
                PagesHaptics.selection()
                self?.pins.movePage(page.id, by: -1)
            })
        }
        if index < pins.pages.count - 1 {
            moves.append(UIAction(title: "Move Right", image: UIImage(systemName: "arrow.right")) { [weak self] _ in
                PagesHaptics.selection()
                self?.pins.movePage(page.id, by: 1)
            })
        }
        if !moves.isEmpty { children.append(UIMenu(options: .displayInline, children: moves)) }
        let delete = UIAction(title: "Delete Page", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.confirmDeletePage(page)
        }
        delete.accessibilityIdentifier = "dashboard.page.delete"
        children.append(UIMenu(options: .displayInline, children: [delete]))
        return UIMenu(title: page.name, children: children)
    }

    private func confirmDeletePage(_ page: DashboardPage) {
        let count = pins.pins(onPage: page.id).count
        guard count > 0 else { PagesHaptics.success(); pins.deletePage(page.id); return }
        let main = pins.pages.first?.name ?? "Main"
        let alert = UIAlertController(title: "Delete “\(page.name)”?",
                                      message: "Its \(count == 1 ? "tile moves" : "\(count) tiles move") to \(main). Nothing is unpinned.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete Page", style: .destructive) { [weak self] _ in
            PagesHaptics.success()
            self?.pins.deletePage(page.id)
        })
        present(alert, animated: true)
    }

    /// [dashboard] A tile's Move to Page: the other pages, and New Page… (made, then the tile moved onto it).
    private func movePageMenu(_ pin: ArtifactPin) -> UIMenu? {
        guard showsPages else { return nil }
        let here = pins.pageId(of: pin)
        var children: [UIMenuElement] = pins.pages.filter { $0.id != here }.map { page in
            UIAction(title: page.name, image: UIImage(systemName: "rectangle.on.rectangle")) { [weak self] _ in
                self?.moveTile(pin.id, to: page)
            }
        }
        let new = UIAction(title: "New Page…", image: UIImage(systemName: "plus")) { [weak self] _ in
            self?.askPageName(title: "New Page", name: "", action: "Add") { name in
                guard let self else { return }
                PagesHaptics.success()
                let page = self.pins.addPage(named: name)
                self.pins.setPage(page.id, id: pin.id)
            }
        }
        children.append(UIMenu(options: .displayInline, children: [new]))
        let menu = UIMenu(title: "Move to Page", image: UIImage(systemName: "arrow.right.square"), children: children)
        return menu
    }

    private func moveTile(_ id: String, to page: DashboardPage) {
        PagesHaptics.success()
        pins.setPage(page.id, id: id)
        AppLog.trace("pages", "dashboard tile moved to another page")
        PagesHUD.show("Moved to \(page.name)", symbol: "arrow.right.square", from: self)
    }

    /// [dashboard] The Dashboard header's ＋ (New Tile) and View As, side by side.
    private func newTileAndViewButtons() -> UIView {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "plus")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: min(HQFont.preferred(.subheadline).pointSize, 22),
                                                                                  weight: .semibold)
        config.baseForegroundColor = HQPalette.label2
        config.contentInsets = .zero
        let plus = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.newTile() })
        plus.frame = CGRect(x: 0, y: 0, width: 44, height: 36)
        plus.accessibilityIdentifier = "tile.new"
        plus.accessibilityLabel = "New Tile"
        let view = pinsHeaderButton(openAll: false)
        view.frame.origin.x = 44
        let pair = UIView(frame: CGRect(x: 0, y: 0, width: 88, height: 36))
        pair.addSubview(plus)
        pair.addSubview(view)
        return pair
    }

    /// [dashboard] "3 Items", and "Making a tile…" while a bot makes one.
    private func dashboardHeader() -> String {
        let count = Self.itemCount(pinsShown.count)
        let making = TileMaker.making(accountId: store.account.id)
        let changing = TileMaker.changing(accountId: store.account.id)
        if making == 0 { return count }
        if changing == making { return count + " · " + (making == 1 ? "Changing a tile…" : "Changing \(making) tiles…") }
        if changing == 0 { return count + " · " + (making == 1 ? "Making a tile…" : "Making \(making) tiles…") }
        // [tiles] Both at once (owner 2026-11-10: a change asked while a New Tile was made read "Making a tile…").
        return count + " · Making \(making - changing), changing \(changing)…"
    }

    /// [dashboard] New Tile: the sheet, then the bot makes the tile in a new chat while the Dashboard stays.
    func newTile() {
        guard let services else { return }
        PagesHaptics.selection()
        let bot = fixedProfile ?? (currentScope == PagesScope.all ? nil : currentScope)
        let sheet = NewTileSheet.make(services: services, bot: bot) { [weak self] bot, what in
            guard let self, let services = self.services else { return }
            let chat = services.newChat(for: bot, folder: nil)
            TileMaker.start(bot: bot, what: what, accountId: self.store.account.id, chat: chat, from: self)
        }
        present(sheet, animated: true)
    }

    /// [tiles] Change… (owner 2026-11-03: "change a tile by asking"): what to change, then the tile's bot changes its page
    /// in a new chat (the Tiles page shows it working, a tap opens the chat), and the tile is drawn again when it's done.
    /// `before`: run first, handed the ask (the opened tile closes, then asks).
    func changeTileAction(_ pin: ArtifactPin, before: ((@escaping () -> Void) -> Void)? = nil) -> UIAction {
        // [tiles] Its bot is changing it now: the menu shows that, and opens the chat (a second change would race the first).
        if let maker = TileMaker.working(on: pin.id, accountId: store.account.id), maker.isChange {
            let open = UIAction(title: "Changing…", subtitle: "\(maker.bot.name) is working on it. Open Chat",
                                image: UIImage(systemName: "wand.and.sparkles")) { [weak self, weak maker] _ in
                guard let self, let maker else { return }
                let show: () -> Void = { [weak self, weak maker] in if let maker { self?.openTileChat(maker.chat) } }
                if let before { before(show) } else { show() }
            }
            open.accessibilityIdentifier = "tile.change.working"
            return open
        }
        let action = UIAction(title: "Change…", image: UIImage(systemName: "wand.and.sparkles")) { [weak self] _ in
            let ask: () -> Void = { [weak self] in self?.askTileChange(pin) }
            if let before { before(ask) } else { ask() }
        }
        action.accessibilityIdentifier = "tile.change"
        let bot = (services?.bots ?? []).contains(where: { $0.id == pin.profile })
        if !bot || services?.readOnlyGateway == true { action.attributes = .disabled }
        return action
    }

    /// [tiles] Change Tile (owner 2026-11-10: "greatly improved"): a sheet with the tile as it looks now, its bot and
    /// updates, a field that grows and quick changes (`ChangeTileSheet`), in place of an alert with one cut-off line.
    private func askTileChange(_ pin: ArtifactPin) {
        guard let bot = services?.bots.first(where: { $0.id == pin.profile }), pin.gatewayPath != nil else { return }
        PagesHaptics.selection()
        let context = pinPictures.context(pin)
        let client = services?.gateway
        let sheet = ChangeTileSheet.make(name: pins.name(pin), bot: bot, picture: currentPicture(pin), status: {
            guard let job = await TileUpdates.shared.job(for: pin, accountId: context.accountId, client: client) else { return nil }
            return TileJobs.shortStatus(job)
        }) { [weak self] words in
            self?.changeTile(id: pin.id, what: words)
        }
        present(sheet, animated: true)
    }

    /// [tiles] The tile's bot changes it in a new chat (Change Tile, and its Try Again).
    func changeTile(id: String, what words: String) {
        guard let services, !services.readOnlyGateway, let pin = pins.pins.first(where: { $0.id == id }), let path = pin.gatewayPath,
              let bot = services.bots.first(where: { $0.id == pin.profile }) else { return }
        let chat = services.newChat(for: bot, folder: nil)
        TileMaker.change(pin, path: path, bot: bot, what: words, accountId: store.account.id, chat: chat, from: self)
    }

    /// [tile-versions] Versions (owner 2026-11-11: "v1 … v2 … roll back to prior versions … see what prior versions
    /// looked like"): the tile's versions with their pictures, and Roll Back. The menu says which one shows.
    /// `before`: run first, handed the opening (the opened tile closes, then the sheet opens).
    func versionsAction(_ pin: ArtifactPin, before: ((@escaping () -> Void) -> Void)? = nil) -> UIAction {
        let shown = pins.pins.first { $0.id == pin.id }?.version
        let action = UIAction(title: "Versions", subtitle: shown.map { "Version \($0)" }, image: UIImage(systemName: "square.stack.3d.up")) {
            [weak self] _ in
            let show: () -> Void = { [weak self] in self?.showVersions(pin) }
            if let before { before(show) } else { show() }
        }
        action.accessibilityIdentifier = "tile.versions"
        if pin.gatewayPath == nil { action.attributes = .disabled }
        return action
    }

    private func showVersions(_ kept: ArtifactPin) {
        let pin = pins.pins.first { $0.id == kept.id } ?? kept
        guard pin.gatewayPath != nil else { return }
        PagesHaptics.selection()
        let bots = services?.bots ?? []
        let sheet = TileVersionsSheet.make(pin: pin, name: pins.name(pin),
                                           botName: bots.first { $0.id == pin.profile }?.name,
                                           context: pinPictures.context(pin), writable: services?.readOnlyGateway == false) { [weak self] version in
            self?.rolledBack(pin.id, to: version)
        }
        present(sheet, animated: true)
    }

    /// [tile-versions] A version was put back on the tile: it's drawn again and marked, and when a job keeps the tile up
    /// to date its bot is asked (hidden, as a tile's button) to make that job keep this version.
    private func rolledBack(_ id: String, to version: TileVersion) {
        markChanged(id)
        redrawTile(id)
        guard let services, !services.readOnlyGateway, let pin = pins.pins.first(where: { $0.id == id }), let path = pin.gatewayPath,
              let bot = services.bots.first(where: { $0.id == pin.profile }) else { return }
        let accountId = store.account.id
        Task { [weak self] in
            let (job, _) = await TileUpdates.shared.lookup(pin, accountId: accountId, client: services.gateway)
            guard let self, job != nil, TileMaker.working(on: id, accountId: accountId) == nil else { return }
            let chat: any ChatSessionModel = pin.sessionId.isEmpty
                ? services.newChat(for: bot, folder: nil)
                : services.chat(for: SessionSummary(id: pin.sessionId, profile: pin.profile, title: pin.sessionTitle, preview: nil,
                                                    lastActive: nil, source: nil, unread: false, isRunning: false))
            TileMaker.rolledBack(pin, path: path, bot: bot, version: version.number, accountId: accountId, chat: chat, from: self)
        }
    }

    /// [tiles] The tile's picture as it shows now (the one already drawn for its tile, card or row), for Change Tile.
    private func currentPicture(_ kept: ArtifactPin) -> UIImage? {
        let pin = pins.shown(kept)
        let dark = traitCollection.userInterfaceStyle == .dark
        let grid = ArtifactPins.view == .grid
        let pixels = (pinnedOnly || grid && pin.tileSize != .small ? 640 : 520) * traitCollection.displayScale
        return pinPictures.picture(pin, dark: dark, pixels: pixels, shape: pinPictureShape(pin))
    }

    /// [dashboard] A New Tile's chat, when the bot needs the person (its question, or no page handed over).
    func openTileChat(_ chat: any ChatSessionModel) {
        guard let navigation = navigationController else { return }
        let screen = makeChat(chat)
        screen.hidesBottomBarWhenPushed = true
        navigation.pushViewController(screen, animated: true)
    }

    /// [pins] The Pinned page, pushed (See All N Pinned, Open Pinned).
    private func openPinnedPage() {
        guard let services, let navigation = navigationController else { return }
        PagesHaptics.selection()
        let page = ArtifactsViewController(store: store, scope: scope, services: services, pinnedOnly: true, fixedProfile: fixedProfile,
                                           makeChat: makeChat)
        page.showInChatOverride = showInChatOverride
        page.navigationItem.largeTitleDisplayMode = .never
        navigation.pushViewController(page, animated: true)
    }

    /// [pins] Artifacts, pushed from the empty Pinned page: everything the bots made, each one ready to pin.
    private func openArtifactsPage() {
        guard let services, let navigation = navigationController else { return }
        PagesHaptics.selection()
        let page = ArtifactsViewController(store: store, scope: scope, services: services, fixedProfile: fixedProfile, makeChat: makeChat)
        page.showInChatOverride = showInChatOverride
        page.navigationItem.largeTitleDisplayMode = .never
        navigation.pushViewController(page, animated: true)
    }

    /// [pins] The Dashboard page's header: "1 Item", "3 Items".
    static func itemCount(_ count: Int) -> String { count == 1 ? "1 Item" : "\(count) Items" }

    /// [pins] The empty Pinned page's words: what a pin is for, then the two ways to pin, each line led by the symbol
    /// of where it happens (a chat, Artifacts) in the tint.
    private func pinsHowTo(font: UIFont, colour: UIColor) -> NSAttributedString {
        // [empty-tidy] Owner 2026-11-10 (design pick 9): on the iPhone and iPad the two ways to pin are one quiet line
        // under the sentence (they were two lines, each with its symbol, between the sentence and the buttons). The
        // how-to stays: the first cut's one sentence alone left the page unexplained (owner 2026-11-01).
        if !DeviceWord.isMac {
            let text = NSMutableAttributedString(string: "Pin the pages, pictures and files your bots make, and keep them one \(DeviceWord.tap) away.",
                                                 attributes: [.font: font, .foregroundColor: colour])
            // The sentence alone (design pick 9 as approved): the second way in is the quiet button under New Tile.
            return text
        }
        let text = NSMutableAttributedString(string: "Pin the pages, pictures and files your bots make, and keep them one \(DeviceWord.tap) away.\n",
                                             attributes: [.font: font, .foregroundColor: colour])
        let steps: [(symbol: String, words: String)] = [
            ("bubble.left", "In a chat, \(DeviceWord.hold) one and choose Pin as Tile."),
            ("photo.on.rectangle", DeviceWord.isMac ? "In Artifacts, Control\u{2011}click one and choose Pin as Tile." : "In Artifacts, swipe one to the right."),
        ]
        let symbol = UIImage.SymbolConfiguration(font: font, scale: .small)
        for step in steps {
            text.append(NSAttributedString(string: "\n", attributes: [.font: font.withSize(font.pointSize * 0.5)]))
            if let image = UIImage(systemName: step.symbol, withConfiguration: symbol)?.withTintColor(HQPalette.tint, renderingMode: .alwaysOriginal) {
                text.append(NSAttributedString(attachment: NSTextAttachment(image: image)))
                text.append(NSAttributedString(string: "\u{2002}", attributes: [.font: font]))
            }
            text.append(NSAttributedString(string: step.words + "\n", attributes: [.font: font, .foregroundColor: colour]))
        }
        text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
        return text
    }

    private func configureRow(_ cell: UICollectionViewListCell, _ record: ArtifactRecord, missing: Bool) {
        let subtitle = ArtifactListWords.subtitle(sessionTitle: record.sessionTitle, timestamp: record.timestamp)
        let busy = openingRow == record.id
        let pinned = !missing && pins.isPinned(record)
        let card = isGrid && !missing
        cell.contentConfiguration = UIHostingConfiguration {
            ArtifactRowView(record: record, subtitle: subtitle, busy: busy, missing: missing, pinned: pinned, card: card,
                            edge: ArtifactListWords.parts(sessionTitle: record.sessionTitle, timestamp: record.timestamp)) { [weak self, weak cell] in
                self?.menu(for: record, missing: missing, anchor: cell) ?? UIMenu(children: [])
            }
        }.margins(.all, 0)
        cell.accessibilityIdentifier = "artifact-row-\(record.label)"
        cell.configurationUpdateHandler = { cell, state in
            #if targetEnvironment(macCatalyst)
            if card {
                // [mac-tools] A card of the grid: the open file's wears the list's mark, a press its grey.
                var background = UIBackgroundConfiguration.clear()
                background.cornerRadius = HQShape.radius(10, .card)
                background.backgroundColor = HQPalette.card
                // Where the card is the page's colour (the Desktop Look, the iOS look in light) an outline is its edge.
                background.strokeColor = Self.cardEdge
                background.strokeWidth = 1
                if let mark = MacSelection.fill(selected: state.isSelected, pressed: state.isHighlighted, in: .list) {
                    if state.isSelected { background.strokeColor = HQPalette.tint; background.strokeWidth = 1.5 }
                    background.backgroundColor = state.isSelected ? mark : HQPalette.cellPressed
                }
                cell.backgroundConfiguration = background
                return
            }
            if DeviceWord.isMac { cell.backgroundConfiguration = MacSelection.listRow(state); return }   // [mac] Stress test 2026-10-28 #54
            #endif
            var background = UIBackgroundConfiguration.clear()
            background.backgroundColor = state.isHighlighted || state.isSelected ? HQPalette.cellPressed : .clear
            cell.backgroundConfiguration = background
        }
    }

    // MARK: Reload

    private var reloadPending = false

    private func setNeedsReload() {
        guard isViewLoaded, !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadPending = false
            self.reload(animated: false)
        }
    }

    /// [pins] A pin's picture landed.
    private func pinUpdated(_ id: String) {
        // [tiles] The page was just read: its title and job, as its head says now.
        if let pin = pins.pins.first(where: { $0.id == id }), pin.isPage, let path = pin.gatewayPath,
           let head = PageSnapshots.shared.head(path: path, context: pinPictures.context(pin)) {
            pins.notePage(id: id, head: head)
        }
        guard dataSource != nil else { return }
        var snapshot = dataSource.snapshot()
        let item = Item.pin(id)
        guard snapshot.indexOfItem(item) != nil else { return }
        snapshot.reconfigureItems([item])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func previewUpdated(_ id: String) {
        guard let record = records[id] else { return }
        if case .failed(_, let missing, _) = previews.state(record), missing, record.kind == .image {
            store.markUnavailable(id)
            return
        }
        // An icon-sized picture leaves the grid once it has loaded (`ArtifactThumbs.isTiny`).
        if previews.isTiny(record) { setNeedsReload(); return }
        var snapshot = dataSource.snapshot()
        let item = Item.image(id)
        guard snapshot.indexOfItem(item) != nil else { return }
        snapshot.reconfigureItems([item])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func matches(_ record: ArtifactRecord) -> Bool {
        let words = query.pgTrim.lowercased()
        guard !words.isEmpty else { return true }
        return [record.label, record.value, record.sessionTitle].contains { $0.lowercased().contains(words) }
    }

    /// [pins] The pins this page shows: the scope's bot (or all), matching the search.
    private func visiblePins() -> [ArtifactPin] {
        let words = query.pgTrim.lowercased()
        let page = showsPages ? pins.currentPage : nil
        return hidden.visible(pins.pins).filter { pin in
            (page == nil || pins.pageId(of: pin) == page)
                && (store.scope == "all" || pin.profile == store.scope)
                && (words.isEmpty || [pin.name, pin.label, pin.value, pin.sessionTitle].contains { $0.lowercased().contains(words) })
        }
    }

    /// [pins] The Pinned page: the pins as cards, or what to do to get some.
    private func reloadPinned(animated: Bool) {
        let shown = visiblePins()
        pinsShown = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        // [dashboard] The page names lead once there are two pages (not while searching: a search looks through every page).
        updateContentPop()
        if showsPages, pins.pages.count > 1 {
            snapshot.appendSections([.pages])
            snapshot.appendItems([.pages], toSection: .pages)
            snapshot.reconfigureItems([.pages])
        }
        // [tiles] The tiles being made, above the tiles (on every page: a bot works whatever page is shown).
        let makers = query.isEmpty ? TileMaker.makers(accountId: store.account.id) : []
        if !makers.isEmpty {
            snapshot.appendSections([.making])
            snapshot.appendItems(makers.map { .making($0.id) }, toSection: .making)
            snapshot.reconfigureItems(makers.map { .making($0.id) })
        }
        updateMakingTimer(makers.count)
        if shown.isEmpty {
            snapshot.appendSections([.state])
            snapshot.appendItems([.state], toSection: .state)
            snapshot.reconfigureItems([.state])
        } else {
            snapshot.appendSections([.pinned])
            snapshot.appendItems(shown.map { ArtifactPins.showsList ? .pinRow($0.id) : .pin($0.id) }, toSection: .pinned)
            gridChanged(ArtifactPins.view == .grid ? shown : [])
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
            // The header says how many ("3 Pinned"): drawn again when that changes.
            if shown.count != pinnedHeaderCount, dataSource.snapshot().sectionIdentifiers.contains(.pinned) {
                snapshot.reloadSections([.pinned])
            }
            pinnedHeaderCount = shown.count
        }
        dataSource.apply(snapshot, animatingDifferences: animated && !HQMotion.reduced)
        relayGridIfChanged()
        listShowsState = shown.isEmpty
        if shown.isEmpty != paneListIsEmpty {
            paneListIsEmpty = shown.isEmpty
            NotificationCenter.default.post(name: DetailPlaceholderViewController.listStateChanged, object: self)
        }
        updateBarItems()
        if collectionView.refreshControl?.isRefreshing == true { collectionView.refreshControl?.endRefreshing() }
    }

    func reload(animated: Bool) {
        guard isViewLoaded else { return }
        if pinnedOnly { reloadPinned(animated: animated); return }
        let all = store.artifacts.filter(matches)
        records = Dictionary(store.artifacts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // [pins] A pinned file a newer chat named again: the pin's Show in Chat goes there.
        pins.follow(store.artifacts)
        let pinKeys = Set(pins.pins.map(\.id))
        let flipped = pinKeys.symmetricDifference(lastPinKeys)
        func pinFlipped(_ id: String) -> Bool {
            guard !flipped.isEmpty, let record = records[id] else { return false }
            return flipped.contains(ArtifactPin.key(profile: record.profile, value: record.value))
        }
        let unavailable = all.filter { store.unavailable.contains($0.id) }
        let available = all.filter { !store.unavailable.contains($0.id) }
        let images = available.filter { $0.kind == .image && !previews.isTiny($0) }
        let rows = available.filter { $0.kind != .image && (filter == nil || $0.kind == filter) }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if barFilter == nil {
            snapshot.appendSections([.filter])
            snapshot.appendItems([.filter], toSection: .filter)
        } else {
            barFilter?.select([nil, .image, .file, .link].firstIndex(of: filter) ?? 0)
        }
        // [pins] The shelf leads All (the segments narrow to one kind; pins are every kind).
        let pinned = filter == nil ? visiblePins() : []
        pinsShown = Dictionary(pinned.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if !pinned.isEmpty {
            snapshot.appendSections([.pinned])
            if ArtifactPins.showsList {
                snapshot.appendItems(pinned.prefix(Self.pinRowsOnArtifacts).map { .pinRow($0.id) }, toSection: .pinned)
                if pinned.count > Self.pinRowsOnArtifacts {
                    snapshot.appendSections([.allPins])
                    snapshot.appendItems([.allPins(pinned.count)], toSection: .allPins)
                }
            } else if ArtifactPins.view == .grid {
                // [dashboard] The first six tiles, then all of them on the Pinned page.
                snapshot.appendItems(pinned.prefix(Self.pinTilesOnArtifacts).map { .pin($0.id) }, toSection: .pinned)
                if pinned.count > Self.pinTilesOnArtifacts {
                    snapshot.appendSections([.allPins])
                    snapshot.appendItems([.allPins(pinned.count)], toSection: .allPins)
                }
            } else {
                // Audit 863 (08b-7): Cards, as Grid and List: the first few, then all of them on the Pinned page.
                snapshot.appendItems(pinned.prefix(Self.pinTilesOnArtifacts).map { .pin($0.id) }, toSection: .pinned)
                if pinned.count > Self.pinTilesOnArtifacts {
                    snapshot.appendSections([.allPins])
                    snapshot.appendItems([.allPins(pinned.count)], toSection: .allPins)
                }
            }
        }
        gridChanged(ArtifactPins.view == .grid ? Array(pinned.prefix(Self.pinTilesOnArtifacts)) : [])
        var shownCount = pinned.count
        // Audit 863 (08b-12): the count under the list is of the artifacts it lists (pins aside), of the segment's kind.
        var listedCount = 0
        if filter == nil || filter == .image {
            let grid = filter == nil ? Array(images.prefix(24)) : images
            visibleImages = filter == nil ? images : images
            if !grid.isEmpty {
                snapshot.appendSections([.images])
                snapshot.appendItems(grid.map { .image($0.id) }, toSection: .images)
            }
            if filter == nil && images.count > 24 {
                snapshot.appendSections([.showAllImages])
                snapshot.appendItems([.showAllImages(images.count)], toSection: .showAllImages)
            }
            shownCount += images.count
            listedCount += images.count
        } else {
            visibleImages = []
        }
        if filter != .image {
            let limited = Array(rows.prefix(fileLimit))
            for group in ArtifactListWords.days(limited) {
                snapshot.appendSections([.day(group.day)])
                snapshot.appendItems(group.items.map { .row($0.id) }, toSection: .day(group.day))
            }
            if rows.count > fileLimit {
                snapshot.appendSections([.more])
                snapshot.appendItems([.loadMore], toSection: .more)
            }
            shownCount += rows.count
            listedCount += rows.count
        }
        let missing = unavailable.filter { filter == nil || $0.kind == filter }
        if !missing.isEmpty {
            snapshot.appendSections([.unavailable])
            snapshot.appendItems([.unavailableToggle(missing.count)], toSection: .unavailable)
            if unavailableOpen { snapshot.appendItems(missing.map { .unavailableRow($0.id) }, toSection: .unavailable) }
        }
        let kindTotal = filter.map { kind in store.artifacts.count { $0.kind == kind } } ?? store.artifacts.count
        if rows.count <= fileLimit || filter == .image, let count = countText(shown: listedCount, total: kindTotal), listedCount > 0 {
            snapshot.appendSections([.count])
            snapshot.appendItems([.count(count)], toSection: .count)
        }
        let view = ArtifactIndex.view(loaded: store.loaded, visible: shownCount + missing.count, refreshing: store.refreshing, error: store.loadError)
        if view != .list {
            snapshot.appendSections([.state])
            if view == .loading {
                if skeletonShown { snapshot.appendItems((0..<8).map { .skeleton($0) }, toSection: .state) }
                else { scheduleSkeleton() }
            } else {
                snapshot.appendItems([.state], toSection: .state)
            }
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter {
            if case .state = $0 { return true }
            if case .filter = $0 { return true }
            if case .unavailableToggle = $0 { return true }
            if case .row(let id) = $0 { return id == openingRow || id == lastOpeningRow || pinFlipped(id) }
            if case .image(let id) = $0 { return tilesRounded != (filter == nil || isGrid) || pinFlipped(id) }   // the filter changed the tiles' corners
            if case .pin = $0 { return true }   // [pins] a picture, a name or its chat may have changed
            if case .pinRow = $0 { return true }
            return false
        })
        lastPinKeys = pinKeys
        lastOpeningRow = openingRow
        tilesRounded = filter == nil || isGrid
        dataSource.apply(snapshot, animatingDifferences: animated && !HQMotion.reduced)
        restoreMark()
        relayGridIfChanged()
        // UX study #89: the empty or can't-load state is a cell here; the iPad placeholder beside hears when it comes or goes.
        // Mac polish #115: loading counts too (its placeholder rows are nothing to choose), so the pane stays blank.
        let empty = view != .list
        listShowsState = snapshot.itemIdentifiers.contains { if case .state = $0 { return true } else { return false } }
        if empty != paneListIsEmpty {
            paneListIsEmpty = empty
            NotificationCenter.default.post(name: DetailPlaceholderViewController.listStateChanged, object: self)
        }
        updateBarItems()
        if collectionView.refreshControl?.isRefreshing == true, !store.refreshing { collectionView.refreshControl?.endRefreshing() }
    }

    private var lastOpeningRow: String?
    /// [dashboard] The grid's tiles and sizes at the last layout: a new size or order lays the grid out again.
    private var gridSignature = ""
    private var gridNeedsLayout = false

    private func gridChanged(_ shown: [ArtifactPin]) {
        let signature = shown.map { "\($0.id)|\($0.tileSize.rawValue)" }.joined(separator: "\n")
        guard signature != gridSignature else { return }
        gridSignature = signature
        gridNeedsLayout = true
    }

    /// [dashboard] The tiles move to their new places (a size picked, a pin dragged, unpinned).
    private func relayGridIfChanged() {
        guard gridNeedsLayout else { return }
        gridNeedsLayout = false
        guard view.window != nil, !HQMotion.reduced else { collectionView.collectionViewLayout.invalidateLayout(); return }
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
            self.collectionView.collectionViewLayout.invalidateLayout()
            self.collectionView.layoutIfNeeded()
        }
    }
    /// [pins] The pins at the last reload: a row or tile whose pin changed draws its mark again.
    private var lastPinKeys: Set<String> = []
    /// UX study #89: the list shows its empty or can't-load state (`PaneListEmptiness`).
    private(set) var paneListIsEmpty = false
    /// The empty or can't-load state is what the list shows (not while it reads): the Mac's bar drops Filter and Search
    /// only then, so they don't leave and pop back in on every first open (Mac polish #115).
    private var listShowsState = false
    private var tilesRounded = true

    /// [mac] Mac polish #115: how long a first read runs before its placeholder rows show. At 0.4 s a quick read that
    /// found nothing flashed eight grey rows, then "No Artifacts"; most reads answer well inside 1.5 s. The iPhone and
    /// iPad keep 0.4 s.
    private static var skeletonWait: TimeInterval { DeviceWord.isMac ? 1.5 : 0.4 }

    private func scheduleSkeleton() {
        guard skeletonWork == nil, !skeletonShown else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.skeletonWork = nil
            self.skeletonShown = true
            self.reload(animated: false)
        }
        skeletonWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.skeletonWait, execute: work)
    }

    private func stateConfiguration() -> UIContentConfiguration {
        if pinnedOnly {
            let words = query.pgTrim
            var config = words.isEmpty ? UIContentUnavailableConfiguration.empty().hqScaled() : UIContentUnavailableConfiguration.search().hqScaled()
            if words.isEmpty {
                config.image = UIImage(systemName: "pin")
                // [dashboard] One page empty, others not: say which.
                // Audit 863 (08b-8): with one bot picked, its tiles only; another bot's here says so.
                let kept = hidden.visible(pins.pins)
                let onOtherPages = kept.contains { (store.scope == "all" || $0.profile == store.scope) && pins.pageId(of: $0) != pins.currentPage }
                let otherBots = store.scope != "all" && kept.contains { !showsPages || pins.pageId(of: $0) == pins.currentPage }
                config.text = onOtherPages ? "This Page Is Empty"
                    : otherBots ? "No Tiles for \(PagesNames.botName(store.scope, bots: services?.bots ?? []))" : "No Tiles Yet"
                config.secondaryAttributedText = pinsHowTo(font: config.secondaryTextProperties.font,
                                                           colour: config.secondaryTextProperties.color)
                // Owner 2026-11-01 on the first cut, one sentence: "Idk how to use this page". The way to the things
                // to pin, as well as how.
                // [dashboard] New Tile first (the easy button, owner 2026-11-03), then the way to things already made.
                var button = UIButton.Configuration.hqMacPush(or: .filled(), capsule: true)
                button.title = services == nil ? "Open Artifacts" : "New Tile"
                config.button = button
                config.buttonProperties.primaryAction = UIAction { [weak self] _ in
                    guard let self else { return }
                    if self.services == nil { self.openArtifactsPage() } else { self.newTile() }
                }
                if services != nil {
                    var second = UIButton.Configuration.hqMacPush(or: .plain())   // [mac] Mac polish #107: a push button, not a bare link
                    second.title = "Open Artifacts"
                    if !DeviceWord.isMac {
                        // [empty-tidy] One quiet line under New Tile says the other way and opens it.
                        second.title = "Or pin one from a chat or Artifacts"
                        second.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                            var out = incoming
                            out.font = HQFont.preferred(.footnote)
                            return out
                        }
                    }
                    config.secondaryButton = second
                    config.secondaryButtonProperties.primaryAction = UIAction { [weak self] _ in self?.openArtifactsPage() }
                }
            } else {
                config.text = "No Results"
                config.secondaryText = "No tile matches “\(words)”."
            }
            config.directionalLayoutMargins = stateMargins(for: config)
            return config
        }
        let view = ArtifactIndex.view(loaded: store.loaded, visible: 0, refreshing: store.refreshing, error: store.loadError)
        if view == .error, let reason = store.loadError {
            var config = PageStates.error(title: "Couldn’t Load Artifacts", reason: reason) { [weak self] in self?.store.refresh(explicit: true) }
            config.directionalLayoutMargins = stateMargins(for: config)
            return config
        }
        let words = query.pgTrim
        let current = currentScope
        let bot = current == PagesScope.all ? nil : PagesNames.botName(current, bots: services?.bots ?? [])
        let text = ArtifactListWords.empty(filter: filter, bot: bot, query: words)
        var config = words.isEmpty ? UIContentUnavailableConfiguration.empty().hqScaled() : UIContentUnavailableConfiguration.search().hqScaled()
        if words.isEmpty { config.image = UIImage(systemName: "photo.on.rectangle") }
        config.text = text.title
        config.secondaryText = text.description
        config.directionalLayoutMargins = stateMargins(for: config)
        return config
    }

    /// The state cell's margins. [mac] Stress test 2026-10-28 #9: the state is a cell under the segments, so it stood at
    /// the top while Jobs' and every other list's sat in the middle. On the Mac its top margin brings its content (about
    /// `estimate` tall) to `MacInset.emptyLift` above the middle of the visible list, as the others are.
    /// [mac] Stress test 2026-10-28 round 7: the title, not the whole state, `MacInset.emptyLift` above the middle, so it
    /// is level with the detail placeholder's title beside it (`MacEmptyTitle`); the state's height was a guess.
    private func stateMargins(for config: UIContentUnavailableConfiguration) -> NSDirectionalEdgeInsets {
        var margins = NSDirectionalEdgeInsets(top: 40, leading: 24, bottom: 40, trailing: 24)
        guard DeviceWord.isMac, let collectionView, collectionView.bounds.height > 0 else { return margins }
        // [mac-ten] Owner 2026-11-11 ("weird UI issues"): in a wide window the line under "No Artifacts in Recent
        // Chats" ran 900 pt across the page as one line. It wraps at a readable measure, as the pane's own states do.
        let side = max(24, ((collectionView.bounds.width - MacInset.emptyMeasure) / 2).rounded(.down))
        margins.leading = side
        margins.trailing = side
        let visible = collectionView.bounds.height - collectionView.adjustedContentInset.top - collectionView.adjustedContentInset.bottom
        // The segments' row over it: where the list last laid the state out, else about its height.
        let laid = dataSource?.indexPath(for: .state).flatMap { collectionView.layoutAttributesForItem(at: $0)?.frame.minY }
        let above = laid.map { max(0, $0) } ?? HQFont.scaled(52)
        let parts = MacEmptyTitle.parts(config, width: collectionView.bounds.width - margins.leading - margins.trailing)
        margins.top = max(40, visible / 2 - MacInset.emptyLift - above - parts.above - parts.title / 2)
        // [mac-ui-issues] Owner 2026-11-09: a tall state (Tiles' two how-to lines and two buttons) hung well below
        // the middle with its title held there. One taller than the room under the title is centred whole instead.
        let whole = parts.above + parts.title + parts.below
        margins.top = max(40, min(margins.top, (visible - whole) / 2 - above))
        stateMarginsHeight = collectionView.bounds.height
        return margins
    }
    /// [mac] The list height the state cell was last laid out for: a resize lays it out again.
    private var stateMarginsHeight: CGFloat = 0

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if barFilterHost, dataSource != nil { placeBarFilter() }
        // [mac] Stress test 2026-10-28 #9: the window grew or shrank under an empty state; centre it again.
        guard DeviceWord.isMac, let collectionView, let dataSource,
              abs(collectionView.bounds.height - stateMarginsHeight) > 1 else { return }
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(.state) else { return }
        stateMarginsHeight = collectionView.bounds.height
        snapshot.reconfigureItems([.state])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func countText(shown: Int, total: Int) -> String? {
        guard total > 0 else { return nil }
        let noun = total == 1 ? "item" : "items"
        return query.isEmpty ? "\(total) \(noun)" : "\(shown) of \(total) \(noun)"
    }

    private func pulled() {
        previews.clearFailures()
        pinPictures.redraw(visiblePins())   // [pins] pages the bot rewrote are drawn again
        if pinnedOnly {
            // [live-tiles] Live tiles read their pages again, and the tiles' jobs are read again now (their marks).
            for pin in visiblePins() { liveTiles?.reload(pin.id) }
            if viewIfLoaded?.window != nil { watchTiles(true) }
            reload(animated: false)
            return
        }
        store.refresh(explicit: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.collectionView.refreshControl?.endRefreshing() }
    }

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        searchCapsule?.updateSearchState()   // [morepages]
        guard text != query else { return }
        query = text
        reload(animated: false)
    }

    /// Picks a segment (All when nil).
    func select(filter next: ArtifactRecord.Kind?) {
        filter = next
        fileLimit = 100
        reload(animated: false)
    }

    // MARK: Selection

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        // [live-tiles] A live tile's own page takes its taps: a button runs, a tap on nothing opens it (LiveTiles.open).
        // VoiceOver opens it as any tile.
        if case .pin(let id)? = dataSource.itemIdentifier(for: indexPath), ArtifactPins.view == .grid, !editingTiles,
           !HQAccessibility.voiceOver, liveTiles?.isRunning(id) == true {
            return false
        }
        switch dataSource.itemIdentifier(for: indexPath) {
        case .image?, .row?, .unavailableRow?, .showAllImages?, .unavailableToggle?, .pin?, .pinRow?, .allPins?, .making?: return true
        default: return false
        }
    }

    /// [tiles] The tile-being-made row isn't a keyboard focus stop: after the New Tile sheet (typed into) closes, focus
    /// landed on it and drew it tint-filled.
    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        if case .making? = dataSource.itemIdentifier(for: indexPath) { return false }
        return true
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: !isGrid)
        if isGrid { restoreMark() }
        switch dataSource.itemIdentifier(for: indexPath) {
        case .image(let id)?: if let record = records[id] { openImage(record) }
        case .row(let id)?, .unavailableRow(let id)?: if let record = records[id] { open(record) }
        case .pin(let id)?, .pinRow(let id)?:
            if editingTiles { return }   // [dashboard] a tap doesn't open while the tiles are being arranged
            if let pin = pinsShown[id] { Haptics.play(.soft); open(pin) }   // as a live tile's tap (LiveTiles.open)
        case .allPins?: openPinnedPage()
        case .making(let id)?:
            if let maker = TileMaker.active.first(where: { $0.id == id }) { PagesHaptics.selection(); openTileChat(maker.chat) }
        case .showAllImages?:
            PagesHaptics.selection()
            filter = .image
            reload(animated: false)
            collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
        case .unavailableToggle?:
            PagesHaptics.selection()
            unavailableOpen.toggle()
            reload(animated: true)
        default: break
        }
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // A tile scrolled past gives its queued preview read up: the tiles on screen read first.
        if case .image(let id)? = dataSource.itemIdentifier(for: indexPath) { previews.drop(id) }
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if case .loadMore? = dataSource.itemIdentifier(for: indexPath) {
            fileLimit += 100
            DispatchQueue.main.async { [weak self] in self?.reload(animated: false) }
        }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let path = indexPaths.first else { return nil }
        let cell = collectionView.cellForItem(at: path)   // [mac-audit] what Share…'s popover points at
        if let item = dataSource.itemIdentifier(for: path), case .pin(let id) = item, let pin = pinsShown[id] {
            if editingTiles { return nil }   // [dashboard] a hold lifts the tile to move it
            return UIContextMenuConfiguration(identifier: ("pin:" + id) as NSString, previewProvider: nil) { [weak self, weak cell] _ in
                self?.pinMenu(pin, anchor: cell)
            }
        }
        if case .pinRow(let id)? = dataSource.itemIdentifier(for: path), let pin = pinsShown[id] {
            return UIContextMenuConfiguration(identifier: ("pin:" + id) as NSString, previewProvider: nil) { [weak self, weak cell] _ in
                self?.pinMenu(pin, anchor: cell)
            }
        }
        let record: ArtifactRecord?, missing: Bool
        switch dataSource.itemIdentifier(for: path) {
        case .image(let id)?, .row(let id)?: record = records[id]; missing = false
        case .unavailableRow(let id)?: record = records[id]; missing = true
        default: return nil
        }
        guard let record else { return nil }
        return UIContextMenuConfiguration(identifier: record.id as NSString, previewProvider: nil) { [weak self, weak cell] _ in
            self?.menu(for: record, missing: missing, anchor: cell)
        }
    }

    /// [dashboard] A tile lifts as its picture alone (its name under it stays).
    func collectionView(_ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration,
                        highlightPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
        tilePreview(at: indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration,
                        dismissalPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
        tilePreview(at: indexPath)
    }

    private func tilePreview(at path: IndexPath) -> UITargetedPreview? {
        guard let cell = collectionView.cellForItem(at: path), let parameters = tilePreviewParameters(cell, at: path) else { return nil }
        return UITargetedPreview(view: cell, parameters: parameters)
    }

    /// The tile's picture, cut to its corners, in Grid (nil elsewhere: the whole cell lifts, as before).
    private func tilePreviewParameters(_ cell: UICollectionViewCell, at path: IndexPath) -> UIDragPreviewParameters? {
        guard ArtifactPins.view == .grid, case .pin? = dataSource.itemIdentifier(for: path) else { return nil }
        var picture = cell.bounds
        if ArtifactPins.showsNames { picture.size.height -= PinTileView.nameHeight }
        let parameters = UIDragPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: picture, cornerRadius: HQShape.radius(18, .card))
        parameters.backgroundColor = .clear
        return parameters
    }

    // MARK: Drag to reorder pins

    /// [dashboard] A pin lifts (a tile, a card or a row) to be put in order. [mac-audit] Owner 2026-11-02 (Mac audit J3):
    /// on the Mac a pin, a row or a tile also drags out of the app (to the Finder, Mail, another app) as its file,
    /// downloaded only when the drop asks for it, or as its link.
    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .pin(let id)?, .pinRow(let id)?:
            let out = pinsShown[id].flatMap { dragOutProvider($0.record) }
            let reorders = query.pgTrim.isEmpty   // a search's order isn't the pins' order
            guard reorders || out != nil else { return [] }
            let item = UIDragItem(itemProvider: out ?? NSItemProvider())
            if reorders { item.localObject = id }
            return [item]
        case .row(let id)?, .image(let id)?:
            guard let record = records[id], let out = dragOutProvider(record) else { return [] }
            AppLog.trace("pages", "artifact drag started")
            return [UIDragItem(itemProvider: out)]
        default:
            return []
        }
    }

    /// [mac-audit] What a dragged artifact hands the drop: a gateway file (downloaded as Share… downloads it), a link or
    /// a picture on another site as its URL. Nil on the phone and for an inline (data:) picture.
    private func dragOutProvider(_ record: ArtifactRecord) -> NSItemProvider? {
        guard FileSaver.offered else { return nil }
        if record.kind == .link || ArtifactFiles.isHosted(record) {
            guard let url = URL(string: record.value) else { return nil }
            return NSItemProvider(object: url as NSURL)
        }
        guard ArtifactFiles.isGatewayFile(record), let account = services?.account else { return nil }
        let client = store.client
        return FileSaver.dragProvider(name: record.label.isEmpty ? "file" : record.label) {
            let data = try await ArtifactFiles.download(client, record)
            let url = ArtifactFiles.previewURL(account: account, record: record)
            try await ArtifactFiles.save(data, to: url)
            return url
        }
    }

    func collectionView(_ collectionView: UICollectionView, dragPreviewParametersForItemAt indexPath: IndexPath) -> UIDragPreviewParameters? {
        guard let cell = collectionView.cellForItem(at: indexPath) else { return nil }
        return tilePreviewParameters(cell, at: indexPath)
    }

    /// A pin moved in order stays in the app; [mac-audit] one carrying its file or link may leave it (the Mac).
    func collectionView(_ collectionView: UICollectionView, dragSessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool {
        !session.items.contains { !$0.itemProvider.registeredTypeIdentifiers.isEmpty }
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
                        withDestinationIndexPath destination: IndexPath?) -> UICollectionViewDropProposal {
        // [dashboard] A tile held over another page's name goes onto that page.
        let page = pageUnderDrop(session)
        pagesBar?.highlight(page)
        if page != nil { return UICollectionViewDropProposal(operation: .move, intent: .unspecified) }
        guard session.localDragSession?.items.first?.localObject is String, let destination,
              dataSource.sectionIdentifier(for: destination.section) == .pinned else {
            return UICollectionViewDropProposal(operation: .forbidden)
        }
        if destination != dropSlot {
            if dropSlot != nil { Haptics.play(.selection) }   // the first slot is where the tile came from
            dropSlot = destination
        }
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    /// [dashboard] The other page whose name a dragged tile is over (nil: none, or not a tile).
    private func pageUnderDrop(_ session: UIDropSession) -> String? {
        guard showsPages, session.localDragSession?.items.first?.localObject is String, let bar = pagesBar, bar.window != nil,
              let id = bar.pageId(at: session.location(in: collectionView), in: collectionView), id != pins.currentPage else { return nil }
        return id
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidExit session: UIDropSession) { pagesBar?.highlight(nil); dropSlot = nil }
    func collectionView(_ collectionView: UICollectionView, dropSessionDidEnd session: UIDropSession) { pagesBar?.highlight(nil); dropSlot = nil }

    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        if let pageId = pageUnderDrop(coordinator.session), let id = coordinator.items.first?.dragItem.localObject as? String,
           let page = pins.pages.first(where: { $0.id == pageId }) {
            pagesBar?.highlight(nil)
            moveTile(id, to: page)
            return
        }
        guard coordinator.proposal.operation == .move, let item = coordinator.items.first, let id = item.dragItem.localObject as? String,
              let destination = coordinator.destinationIndexPath,
              let section = dataSource.sectionIdentifier(for: destination.section), section == .pinned else { return }
        let shown = dataSource.snapshot().itemIdentifiers(inSection: .pinned)
        guard !shown.isEmpty else { return }
        let target: String
        switch shown[min(destination.item, shown.count - 1)] {
        case .pin(let other), .pinRow(let other): target = other
        default: return
        }
        if target != id {
            pins.move(id: id, to: target)
            Haptics.play(.soft)
            AppLog.trace("pages", "pin moved")
            reload(animated: true)
        }
        coordinator.drop(item.dragItem, toItemAt: destination)
    }

    // MARK: Actions

    /// A row's or tile's ⋯ and hold: Open, Show in Chat, Share…, (Mac) Save As…, Copy Path / Link, then Pin: the pin
    /// menu's order (Mac audit J3: this one had no Open and put Pin first). `anchor` is what Share…'s popover points at
    /// (the row; it pointed at the page's corner).
    func menu(for record: ArtifactRecord, missing: Bool, anchor: UIView? = nil) -> UIMenu {
        let open = UIAction(title: "Open", image: UIImage(systemName: Self.openSymbol(record))) { [weak self] _ in self?.open(record) }
        let chat = UIAction(title: "Show in Chat", image: UIImage(systemName: "bubble.left")) { [weak self] _ in self?.showInChat(record) }
        var first: [UIMenuElement] = [open, chat]
        if !missing {
            first.append(UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self, weak anchor] _ in
                self?.share(record, from: nil, anchor: anchor)
            })
            if let save = saveAction(record, anchor: anchor) { first.append(save) }
        }
        first.append(copyAction(record.kind == .link, value: record.value))
        var groups = [UIMenu(options: .displayInline, children: first)]
        if !missing {   // [pins]
            groups.append(UIMenu(options: .displayInline, children: [PinActions.action(pinned: pins.isPinned(record)) { [weak self] in
                guard let self else { return }
                PinActions.toggle(record, pins: self.pins, from: self)
            }]))
        }
        // Owner 2026-11-02: junk goes for good (every chat that names it). [safer-deletes] After a question.
        groups.append(UIMenu(options: .displayInline, children: [PinActions.removeAction { [weak self, weak anchor] in
            self?.confirmRemove(record, source: anchor)
        }]))
        // [morepages] The "×3" badge in words for sighted users too.
        return UIMenu(title: record.repeatSpoken ?? "", children: groups)
    }

    /// [mac-audit] Open's glyph: a page's Safari, anything else the open-in arrow (the pin menu's).
    private static func openSymbol(_ record: ArtifactRecord) -> String {
        HTMLPageSheet.opens(name: record.label) || HTMLPageSheet.opens(name: record.value) ? "safari" : "arrow.up.right.square"
    }

    private func copyAction(_ link: Bool, value: String) -> UIAction {
        UIAction(title: link ? "Copy Link" : "Copy Path", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            UIPasteboard.general.string = value
            PagesHaptics.success()
            if let self { PagesHUD.show("Copied", symbol: "doc.on.doc", from: self) }
        }
    }

    /// [mac-audit] Owner 2026-11-02 (Mac audit J1): Save As… for a file on the bot's computer, on the Mac (nil for a link,
    /// a picture on another site, or an inline one).
    private func saveAction(_ record: ArtifactRecord, anchor: UIView?) -> UIAction? {
        guard FileSaver.offered, record.kind != .link, ArtifactFiles.isGatewayFile(record) else { return nil }
        return FileSaver.action { [weak self] in self?.fetchGatewayFile(record, presenter: nil, verb: "Save") { url, host in FileSaver.present(url, from: host) } }
    }

    /// [pins] A pin's ⋯ and hold: Open, Show in Chat, Share…, (Mac) Save As…, Copy Path / Link, then Unpin.
    /// [safer-deletes] Unpin is a plain item (a tile pins again in a tap); Remove, the one that can't be undone, is alone
    /// at the end and asks first (owner 2026-11-03: "destructive actions sit next to everyday ones").
    private func pinMenu(_ pin: ArtifactPin, anchor: UIView? = nil) -> UIMenu {
        let record = pin.record
        let open = UIAction(title: "Open", image: UIImage(systemName: pin.isPage ? "safari" : "arrow.up.right.square")) { [weak self] _ in
            self?.open(pin)
        }
        let chat = UIAction(title: "Show in Chat", image: UIImage(systemName: "bubble.left")) { [weak self] _ in self?.showInChat(record) }
        let share = UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self, weak anchor] _ in
            self?.share(record, from: nil, anchor: anchor)
        }
        let copy = copyAction(pin.kind == .link, value: pin.value)
        let unpin = PinActions.action(pinned: true) { [weak self] in
            guard let self else { return }
            PinActions.toggle(record, pins: self.pins, from: self)
        }
        var first: [UIMenuElement] = [open]
        if !pin.sessionId.isEmpty { first.append(chat) }
        first.append(share)
        if let save = saveAction(record, anchor: anchor) { first.append(save) }
        var groups = [UIMenu(options: .displayInline, children: first + [copy])]
        // [tiles] How often it's updated (a page a job rewrites), and its name.
        var tile: [UIMenuElement] = []
        if pin.isPage { tile.append(tileUpdatesMenu(pin)); tile.append(changeTileAction(pin)); tile.append(versionsAction(pin)) }
        tile.append(TileUpdates.renameAction(pin, pins: pins, from: self))
        groups.append(UIMenu(options: .displayInline, children: tile))
        // [dashboard] Move to Page (on the Dashboard).
        if let move = movePageMenu(pin) { groups.append(UIMenu(options: .displayInline, children: [move])) }
        // [dashboard] In Grid: the sizes as pictures on top, and Edit Tiles.
        if ArtifactPins.view == .grid {
            groups.insert(PinActions.sizeMenu(pin, pins: pins), at: 0)
            groups.append(UIMenu(options: .displayInline, children: [PinActions.editTilesAction { [weak self] in self?.setEditingTiles(true) }]))
        }
        let name = pins.name(pin)   // Mac polish #45: as its tile or row says it
        let remove = PinActions.removeAction { [weak self, weak anchor] in self?.confirmRemove(record, name: name, source: anchor) }
        groups.append(UIMenu(options: .displayInline, children: [unpin]))
        return UIMenu(title: name, children: groups + [UIMenu(options: .displayInline, children: [remove])])
    }

    /// [tiles] A page tile's Updates (read as the menu opens).
    private func tileUpdatesMenu(_ pin: ArtifactPin) -> UIMenuElement {
        TileUpdates.shared.menu(for: pin, accountId: pinPictures.context(pin).accountId, client: services?.gateway, from: self,
                                botName: PagesNames.botName(pin.profile, bots: services?.bots ?? []),
                                botModel: services?.botModelName(pin.profile)) { [weak self] in
            self?.redrawTile(pin.id)
        }
    }

    /// [tiles] While the Tiles page shows: the tiles' jobs read each minute (each 15 s while one runs), their marks kept
    /// current, and a tile whose job has just run drawn again at once (owner 2026-11-03: "redraw the moment the job
    /// finishes").
    private func watchTiles(_ on: Bool) {
        tileWatch?.cancel()
        tileWatch = nil
        guard on, pinnedOnly else { return }
        tileWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let gap = await self?.readTileJobs() else { return }
                try? await Task.sleep(for: gap)
            }
        }
    }

    private func readTileJobs() async -> Duration {
        let pages = pins.pins.filter(\.isPage)
        guard !pages.isEmpty else { return .seconds(60) }
        let (marks, ran) = await TileUpdates.shared.refresh(pages, accountId: store.account.id, client: services?.gateway)
        if !ran.isEmpty { AppLog.trace("pages", "\(ran.count) tile(s) redrawn after their job ran") }
        for id in ran { redrawTile(id) }
        for id in Set(marks).subtracting(ran) { pinUpdated(id) }
        return TileUpdates.shared.anyUpdating ? .seconds(15) : .seconds(60)
    }

    /// [tiles] Tiles whose change has just been done: a tint ring that fades (`TileChangedRing`), so the eye finds the
    /// tile that changed.
    private var justChanged: Set<String> = []

    private func markChanged(_ id: String) {
        justChanged.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.justChanged.remove(id) != nil else { return }
            self.pinUpdated(id)
        }
    }

    /// [tiles] A tile's picture drawn again (its job may have rewritten the page).
    private func redrawTile(_ id: String) {
        guard let pin = pins.pins.first(where: { $0.id == id }) else { return }
        pinPictures.redraw([pin])
        liveTiles?.reload(id)   // [live-tiles]
        pinUpdated(id)
    }

    /// [live-tiles] The Tiles page's live tiles: a tap on nothing pressable opens the tile; a button's prompt goes to the
    /// tile's bot in the chat it was made in (a new chat when there's none), hidden, as `TileMaker.act`.
    private func makeLiveTiles() -> LiveTiles {
        let live = LiveTiles(host: self)
        live.pin = { [weak self] id in self?.pins.pins.first { $0.id == id } }
        live.context = { [weak self] pin in self?.pinPictures.context(pin) ?? MediaContext(accountId: "", profile: pin.profile) }
        live.onChange = { [weak self] id in self?.pinUpdated(id) }
        live.onScreen = { [weak self] in
            guard let self, let collectionView = self.collectionView, let dataSource = self.dataSource else { return [] }
            return Set(collectionView.indexPathsForVisibleItems.compactMap { path -> String? in
                if case .pin(let id)? = dataSource.itemIdentifier(for: path) { return id }
                return nil
            })
        }
        live.open = { [weak self] id in
            guard let self, !self.editingTiles, self.presentedViewController == nil,
                  let pin = self.pins.pins.first(where: { $0.id == id }) else { return }
            Haptics.play(.soft)
            self.open(pin)
        }
        live.send = { [weak self] id, prompt in self?.sendFromTile(id, prompt, from: self) ?? false }
        return live
    }

    /// [live-tiles] A tile's button (on the Tiles page or in the opened tile): its prompt to the tile's bot in the chat it
    /// was made in (a new chat when there's none), hidden, as `TileMaker.act`; `ended` when the bot is done. Refused with
    /// the reason and an error buzz (most pages show nothing for a button that wasn't sent).
    private func sendFromTile(_ id: String, _ prompt: String, from host: UIViewController?, ended: (() -> Void)? = nil) -> Bool {
        guard let services else { return false }
        func refuse(_ words: String) -> Bool {
            PagesHaptics.error()
            if let host { PagesHUD.show(words, symbol: "exclamationmark.triangle", from: host) }
            return false
        }
        guard !services.readOnlyGateway else { return refuse("This gateway is read-only.") }
        guard let pin = pins.pins.first(where: { $0.id == id }), let path = pin.gatewayPath else {
            return refuse("Couldn’t Send to This Tile")
        }
        guard let bot = services.bots.first(where: { $0.id == pin.profile }) else { return refuse("This Tile’s Bot Is Gone") }
        let chat: any ChatSessionModel = pin.sessionId.isEmpty
            ? services.newChat(for: bot, folder: nil)
            : services.chat(for: SessionSummary(id: pin.sessionId, profile: pin.profile, title: pin.sessionTitle, preview: nil,
                                                lastActive: nil, source: nil, unread: false, isRunning: false))
        let maker = TileMaker.act(pin, path: path, bot: bot, prompt: prompt, accountId: store.account.id, chat: chat, from: self)
        maker.ended = ended
        return true
    }

    /// [pins] A pin opens as it is now: a page live (read again, its scripts running), a picture in the viewer,
    /// anything else as Artifacts opens it.
    private func open(_ pin: ArtifactPin) {
        if pin.isPage, let path = pin.gatewayPath {
            AppLog.trace("pages", "pinned page opened")
            let context = pinPictures.context(pin)
            let client = services?.gateway
            // [tiles] Opened as the tile: its name on top, the file under it, and its Updates on a clock button.
            var tile = HTMLPageSheet.Tile(name: pin.name, fileName: pin.label, status: { [weak self] in
                guard self != nil, let job = await TileUpdates.shared.job(for: pin, accountId: context.accountId, client: client) else { return nil }
                return TileJobs.shortStatus(job)
            }, menu: { [weak self] host in
                guard let self else { return UIMenu(children: []) }
                let updates = TileUpdates.shared.menu(for: pin, accountId: context.accountId, client: client, from: host, inline: true,
                                                      botName: PagesNames.botName(pin.profile, bots: self.services?.bots ?? []),
                                                      botModel: self.services?.botModelName(pin.profile)) { [weak self] in
                    self?.redrawTile(pin.id)
                }
                // [tiles] Change… from the opened tile: the tile closes and the Tiles page shows the bot working on it.
                let change = self.changeTileAction(pin) { [weak host] start in
                    guard let host else { start(); return }
                    host.dismiss(animated: true, completion: start)
                }
                // [tile-versions] Versions from the opened tile: it closes, and the sheet opens over the Tiles page.
                let versions = self.versionsAction(pin) { [weak host] start in
                    guard let host else { start(); return }
                    host.dismiss(animated: true, completion: start)
                }
                return UIMenu(children: [updates, UIMenu(options: .displayInline, children: [change, versions])])
            })
            // [live-tiles] Its buttons go to the tile's bot, as on the Tiles page (a page opened from Tiles has no chat).
            tile.botName = PagesNames.botName(pin.profile, bots: services?.bots ?? [])
            tile.send = { [weak self] prompt, host, ended in self?.sendFromTile(pin.id, prompt, from: host, ended: ended) ?? false }
            FilePreviewPresenter.shared.open(path: path, name: pin.label, context: context, from: self, row: nil, tile: tile)
            return
        }
        if pin.kind == .image {
            let viewer = ArtifactImageViewer(records: [pin.record], index: 0, previews: previews, showInChat: { [weak self] record in
                self?.showInChat(record)
            }, share: { [weak self] record, item in
                guard let self, let presented = self.presentedViewController else { return }
                self.share(record, from: item, presenter: presented)
            })
            present(ArtifactImageViewer.wrap(viewer), animated: true)
            return
        }
        open(pin.record)
    }

    func showInChat(_ record: ArtifactRecord) {
        if let showInChatOverride { showInChatOverride(record); return }
        guard let services, let navigation = navigationController else { return }
        let session = SessionSummary(id: record.sessionId, profile: record.profile ?? "default", title: record.sessionTitle, preview: nil,
                                     lastActive: nil, source: nil, unread: false, isRunning: false)
        Haptics.play(.soft)
        let chat = makeChat(services.chat(for: session))
        chat.hidesBottomBarWhenPushed = true
        chat.navigationItem.largeTitleDisplayMode = .never
        ChatViewController.push(chat, on: navigation) {}
    }

    /// `anchor`: the row or tile Share… was chosen on ([mac-audit] Mac audit J3: the popover pointed at the page's
    /// corner); `item` the viewer's bar button.
    private func share(_ record: ArtifactRecord, from item: UIBarButtonItem?, presenter: UIViewController? = nil, anchor: UIView? = nil) {
        let host = presenter ?? self
        if !ArtifactFiles.isGatewayFile(record) {
            let sheet = UIActivityViewController(activityItems: [URL(string: record.value) ?? record.value], applicationActivities: nil)
            point(sheet, item: item, anchor: anchor)
            host.present(sheet, animated: true)
            return
        }
        fetchGatewayFile(record, presenter: presenter, verb: "Share") { [weak self, weak anchor] url, host in
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            self?.point(sheet, item: item, anchor: anchor)
            host.present(sheet, animated: true)
        }
    }

    /// The share popover's arrow: the bar button, else the row (its whole frame), else the page.
    private func point(_ sheet: UIViewController, item: UIBarButtonItem?, anchor: UIView?) {
        guard let popover = sheet.popoverPresentationController else { return }
        if let item { popover.sourceItem = item; return }
        if let anchor, anchor.window != nil {
            popover.sourceView = anchor
            popover.sourceRect = anchor.bounds
        } else {
            popover.sourceView = view
        }
    }

    private func openImage(_ record: ArtifactRecord) {
        let list = visibleImages.isEmpty ? [record] : visibleImages
        let index = list.firstIndex { $0.id == record.id } ?? 0
        let viewer = ArtifactImageViewer(records: list, index: index, previews: previews, showInChat: { [weak self] record in
            self?.showInChat(record)
        }, share: { [weak self] record, item in
            guard let self, let presented = self.presentedViewController else { return }
            self.share(record, from: item, presenter: presented)
        })
        present(ArtifactImageViewer.wrap(viewer), animated: true)
    }

    /// Opens a file or link (§5.6): a spinner on the row, "Downloading <name>…" with Cancel after 0.5 s; a newer tap
    /// supersedes the old.
    func open(_ record: ArtifactRecord) {
        let opening = ArtifactFiles.opening(record)
        if opening == .link {
            if let url = URL(string: record.value) { LinkOpener.openOutside(url) }
            return
        }
        if opening == .image { openImage(record); return }
        guard let account = services?.account else { return }
        let client = store.client
        startOpening(record) { [weak self] in
            let data = try await ArtifactFiles.download(client, record)
            guard !Task.isCancelled, let self else { return }
            self.store.markAvailable(record.id)
            self.finishOpening(record.id)
            let url = ArtifactFiles.previewURL(account: account, record: record)
            if case .text(let markdown, let language) = opening, ArtifactFiles.opensAsText(opening, bytes: data.count) {
                let viewer = ArtifactTextViewController(title: record.label, markdown: markdown, language: language) {
                    // A text that isn't UTF-8 can't be shown here: the viewer offers Open in Quick Look (§5.6).
                    guard let text = String(data: data, encoding: .utf8) else { throw PagesMessageError("This file isn’t plain text.") }
                    return text
                }
                viewer.shareItem = {
                    try await ArtifactFiles.save(data, to: url)
                    return url
                }
                viewer.openInQuickLook = { [weak viewer] in
                    guard let viewer else { return }
                    // The text is already in memory: it's only saved to disk, so no "Downloading…" HUD.
                    QuickLookPresenter.open(from: viewer, busy: nil) {
                        try await ArtifactFiles.save(data, to: url)
                        return url
                    }
                }
                if markdown { ArtifactLinkedNotes.wire(viewer, record: record, client: client, account: account) }   // [morepages]
                self.showBeside(viewer, for: record)
                return
            }
            try await ArtifactFiles.save(data, to: url)
            guard !Task.isCancelled else { return }
            if opening == .html {
                // Quick Look draws the page; Source reads its text (D-P8).
                let source = String(decoding: data.prefix(ArtifactFiles.textLimit), as: UTF8.self)
                let viewer = ArtifactTextViewController(title: record.label, markdown: false, language: "html") { source }
                // Verify round 3: a page without a viewport tag previews at the phone's width (Share keeps the file).
                var preview = url
                if let fitted = ArtifactFiles.previewHTML(data) {
                    let copy = ArtifactFiles.previewCopyURL(for: url)
                    if (try? await ArtifactFiles.save(fitted, to: copy)) != nil { preview = copy }
                }
                viewer.htmlPreview = preview
                viewer.shareItem = { url }
                self.showBeside(viewer, for: record)
                return
            }
            QuickLookPresenter.present(url: url, from: self)
        }
    }

    /// A gateway file is downloaded, then shared as a file (§5.6) or ([mac-audit] Mac audit J1) saved, with the same
    /// row spinner and notice as Open. `deliver` gets the file on disk and the controller to present over.
    /// `verb`: what the failure alert says couldn't be done ("Couldn’t Share …"; audit 863: it said Open).
    private func fetchGatewayFile(_ record: ArtifactRecord, presenter: UIViewController?, verb: String,
                                  deliver: @escaping (URL, UIViewController) -> Void) {
        guard let account = services?.account else { return }
        let client = store.client
        // From the image viewer the notice shows over the viewer (the page is under it).
        startOpening(record, noticeFrom: presenter, verb: verb) { [weak self] in
            let data = try await ArtifactFiles.download(client, record)
            guard !Task.isCancelled, let self else { return }
            self.store.markAvailable(record.id)
            let url = ArtifactFiles.previewURL(account: account, record: record)
            try await ArtifactFiles.save(data, to: url)
            guard !Task.isCancelled else { return }
            self.finishOpening(record.id)
            deliver(url, presenter ?? self)
        }
    }

    /// Runs `work` for `record` with the row spinner and, after 0.5 s, the "Downloading <name>…" notice with Cancel
    /// (cancelled work is never presented). The notice goes as soon as the work ends, fails or is superseded.
    private func startOpening(_ record: ArtifactRecord, noticeFrom: UIViewController? = nil, verb: String = "Open",
                              _ work: @escaping () async throws -> Void) {
        opening?.task.cancel()
        dismissDownloadNotice()
        openingRow = record.id
        reload(animated: false)
        let notice = DispatchWorkItem { [weak self] in
            guard let self, self.openingRow == record.id else { return }
            // UX study #152: the Undo pill's look and hold, with Cancel.
            self.downloadHUD = UndoPill.show(label: "Downloading \(record.label)…", actionTitle: "Cancel", duration: 60,
                                             in: noticeFrom ?? self) { [weak self] in
                self?.opening?.task.cancel()
                self?.finishOpening(record.id)
            }
        }
        downloadNotice = notice
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: notice)
        let task = Task { [weak self] in
            do {
                try await work()
                self?.finishOpening(record.id)
            } catch {
                guard let self else { return }
                if error is CancellationError || Task.isCancelled {
                    // Superseded or cancelled: the newer open owns the spinner and the notice.
                    return
                }
                self.finishOpening(record.id)
                PagesHaptics.error()
                if ArtifactFiles.isMissing(error) { self.store.markUnavailable(record.id) }
                let alert = UIAlertController(title: "Couldn’t \(verb) \(record.label)", message: ArtifactFiles.failureText(error, image: false),
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .cancel))
                (self.presentedViewController ?? self).present(alert, animated: true)
            }
        }
        opening = (record.id, task)
    }

    private var downloadNotice: DispatchWorkItem?
    private var downloadHUD: UndoPill?

    private func dismissDownloadNotice() {
        downloadNotice?.cancel()
        downloadNotice = nil
        downloadHUD?.dismiss(animated: false)
        downloadHUD = nil
    }

    private func finishOpening(_ id: String) {
        guard openingRow == id || opening?.id == id else { return }
        dismissDownloadNotice()
        if openingRow == id { openingRow = nil }
        if opening?.id == id { opening = nil }
        reload(animated: false)
    }
}

/// A grid tile: the thumbnail, the fill-3 colour until it lands, a symbol when it failed (a globe when the image is
/// on another site and wasn't fetched: the viewer offers Open).
struct ArtifactTileView: View {
    var image: UIImage?
    var failed: Bool
    var hosted: Bool = false
    /// On the All filter, a tile among rows: 10 pt continuous corners (UX study #88). The Images filter's grid is square.
    var rounded: Bool = false
    /// [pins] A small pin in the corner.
    var pinned: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle().fill(Color.hqFill3)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: geo.size.width, height: geo.size.height).clipped()
                } else if failed {
                    Image(systemName: hosted ? "globe" : "photo.badge.exclamationmark").font(Font.hq(.title2)).foregroundStyle(Color.hqLabel3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: rounded ? HQShape.radius(10, .card) : 0, style: .continuous))   // Mac polish #118: the look's 4 pt
            .overlay(alignment: .topTrailing) {
                if pinned {
                    Image(systemName: "pin.fill").hqSymbolFont(10, weight: .semibold, cap: 14).foregroundStyle(.white)
                        .frame(width: 20, height: 20).background(Circle().fill(Color.hqOrange)).padding(5)
                        .accessibilityHidden(true)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// A file or link row: a 44 pt type tile, the name (middle-truncated), "<chat> · 6:20 PM", ⋯.
/// [artifact-rows] Owner 2026-11-10 (design pick 10): on the iPhone and iPad's list the time stands at the trailing edge
/// of the name's line, the second line is the chat alone, and the row has no ⋯: touch and hold opens the same menu and
/// the swipes pin and remove, as on Bots, Sessions and Jobs. The Mac (a pointer, no swipes), its grid's cards, the
/// accessibility text sizes and rows without `edge` (a pinned tile's row) keep the row as it was.
struct ArtifactRowView: View {
    var record: ArtifactRecord
    var subtitle: String
    var busy: Bool
    var missing: Bool
    /// [pins] A pin after the count, before ⋯.
    var pinned: Bool = false
    /// [mac-tools] A card of the Mac's grid: its own edges, so less room at the sides.
    var card: Bool = false
    /// [artifact-rows] The chat and the time apart, for the edged row.
    var edge: (chat: String, when: String)? = nil
    var menu: () -> UIMenu
    @Environment(\.dynamicTypeSize) private var typeSize

    private var edged: Bool { edge != nil && !card && !DeviceWord.isMac && !typeSize.isAccessibilitySize }

    static func glyph(_ record: ArtifactRecord) -> String {
        if record.kind == .link { return "link" }
        if record.kind == .image { return "photo" }   // [pins] a pinned picture listed as a row
        switch ArtifactFiles.fileExtension(record.value) {
        case "html", "htm": return "safari"   // [pins] a page opens live, as its card in the chat says
        case "md", "markdown", "mdx", "txt", "text", "log", "json", "jsonl", "yaml", "yml", "toml", "xml", "py", "js", "ts", "swift",
             "sh", "rb", "go", "rs", "java", "kt", "c", "h", "cpp", "css", "sql": return "doc.text"
        case "pdf": return "doc.richtext"
        case "csv", "tsv", "xlsx", "xls", "ods": return "tablecells"
        case "mp3", "wav", "ogg", "opus", "m4a", "flac", "m2a": return "music.note"
        case "mp4", "mov", "avi", "mkv", "webm", "3gp": return "film"
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar": return "doc.zipper"
        default: return "doc"
        }
    }

    var body: some View {
        let large = typeSize.isAccessibilitySize
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: HQShape.radius(10, .card), style: .continuous).fill(Color.hqFill3)   // Mac polish #118
                if busy { ProgressView() }
                // Mac polish #46: a picture that's gone wears the tiles' broken mark (a file that's gone keeps its kind, in grey).
                else { Image(systemName: missing && record.kind == .image ? PinCardView.goneGlyph : Self.glyph(record))
                    .hqSymbolFont(Density.compact ? 16 : 17, cap: 28).foregroundStyle(missing ? Color.hqLabel3 : Color.hqTint) }
            }
            // [ui-sizing 2026-11-09] A 36 pt tile (30 in Compact) × UI Scale, as Tasks' and Jobs' rows: the 44 pt tile and
            // ⋯ made a one-line name's row 64 pt.
            .frame(width: Density.ios(36, 30), height: Density.ios(36, 30))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(record.label.isEmpty ? record.value : record.label)
                        .font(Font.hq(.body))
                        .foregroundStyle(missing ? Color.hqLabel2 : Color.hqLabel)
                        .lineLimit(large ? 3 : (record.repeatBadge == nil || card || edged ? 1 : 2))   // [morepages] the name wraps before the badge squeezes it
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if edged, let when = edge?.when, !when.isEmpty {
                        Text(when).font(Font.hq(.footnote)).monospacedDigit().foregroundStyle(Color.hqLabel2).lineLimit(1).fixedSize()
                    }
                }
                let second = edged ? (edge?.chat ?? "") : subtitle
                if !second.isEmpty {
                    Text(second)
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                        .lineLimit(large ? 3 : 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // [morepages] "×3": this chat named the file or link three times (3x-morepages §2).
            if let badge = record.repeatBadge {
                Text(badge)
                    .font(Font.hq(.footnote).monospacedDigit())
                    .foregroundStyle(Color.hqLabel2)
                    .fixedSize()
                    .accessibilityLabel(record.repeatSpoken ?? badge)
                    .accessibilityIdentifier("artifact-repeats")
            }
            // Mac polish #117: the pin after the count, beside ⋯, so the pins stand in one column whether a row has a
            // count or not.
            if pinned {
                Image(systemName: "pin.fill").hqSymbolFont(12, cap: 18).foregroundStyle(Color.hqOrange)
                    .accessibilityLabel("Pinned").accessibilityIdentifier("artifact-pinned")
            }
            if !edged {
                UIMenuButton(menu: menu, label: "Actions for \(record.label)")
                    .frame(width: 44, height: 44)
                    .padding(.vertical, -6)   // [ui-sizing] its 44 pt touch reaches into the padding, not the row's height
            }
        }
        .padding(.leading, card ? 10 : 20)
        .padding(.trailing, card ? 0 : edged ? 20 : 6)
        .padding(.vertical, large ? 12 : card ? 10 : Density.compact ? 6 : 10)
        .frame(minHeight: large || card ? 64 : Density.ios(56, 46))
        .contentShape(Rectangle())
    }
}

/// The segments, whole at every text size (`MEM/segmented-labels-whole.md`): one row whose segments size to their
/// labels, two rows of two at accessibility sizes. Labels follow Dynamic Type.
final class ArtifactFilterBar: UIView {
    private static let titles = ["All", "Images", "Files", "Links"]
    private let stack = UIStackView()
    private var controls: [UISegmentedControl] = []
    private var selected = 0
    private let changed: (Int) -> Void
    /// The Desktop Look's outlined strip in place of the controls (UISegmentedControl draws iOS 26's pill whatever
    /// it is given, which the look must not show).
    private var strip: UIView?
    private let stripChoice = ArtifactFilterChoice()

    init(changed: @escaping (Int) -> Void) {
        self.changed = changed
        super.init(frame: .zero)
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        build()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (bar: ArtifactFilterBar, previous) in
            // Rebuilt on every size change: the titles' font is read when the segments are made.
            if previous.preferredContentSizeCategory != bar.traitCollection.preferredContentSizeCategory { bar.build() }
        }
        NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.build() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build() {
        controls.forEach { $0.removeFromSuperview() }
        controls = []
        strip?.removeFromSuperview()
        strip = nil
        if Theme.isDesktop {
            stripChoice.index = selected
            let host = UIHostingController(rootView: ArtifactFilterStrip(titles: Self.titles, choice: stripChoice) { [weak self] index in
                guard let self else { return }
                self.selected = index
                self.changed(index)
            })
            host.view.backgroundColor = .clear
            host.sizingOptions = .intrinsicContentSize
            host.view.accessibilityIdentifier = "artifacts.filter"
            stack.addArrangedSubview(host.view)
            strip = host.view
            return
        }
        let rows = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? [[0, 1], [2, 3]] : [[0, 1, 2, 3]]
        controls = rows.enumerated().map { number, indices in
            let control = UISegmentedControl(items: indices.map { Self.titles[$0] })
            // [mac] Stress test 2026-10-28 #68: segments sized by content drew the selected thumb narrower than its
            // segment on the Mac's control. The Mac never runs out of room for four short words: equal segments.
            control.apportionsSegmentWidthsByContent = !DeviceWord.isMac
            // [a11y] Two segments share the row at accessibility sizes, so their text stops growing at AX2: larger
            // than that "Images" no longer fits its half of the row and was cut off (stress round 1, AX5).
            let category = traitCollection.preferredContentSizeCategory
            let capped = UITraitCollection(preferredContentSizeCategory: category > .accessibilityLarge ? .accessibilityLarge : category)
            let font = HQFont.preferred(.subheadline, compatibleWith: capped)
            control.maximumContentSizeCategory = .accessibilityLarge
            // The control keeps its 32 pt height whatever the font: taller text needs a taller control.
            control.heightAnchor.constraint(greaterThanOrEqualToConstant: ceil(font.lineHeight) + 14).isActive = true
            control.setTitleTextAttributes([.font: font], for: .normal)
            control.setTitleTextAttributes([.font: font.pagesWeight(.semibold)], for: .selected)
            control.accessibilityIdentifier = rows.count == 1 ? "artifacts.filter" : "artifacts.filter.\(number + 1)"
            control.addAction(UIAction { [weak self, weak control] _ in
                guard let self, let control, control.selectedSegmentIndex >= 0 else { return }
                let index = indices[control.selectedSegmentIndex]
                self.select(index)
                self.changed(index)
            }, for: .valueChanged)
            stack.addArrangedSubview(control)
            return control
        }
        select(selected)
    }

    func select(_ index: Int) {
        selected = index
        stripChoice.index = index
        let rows = controls.count == 1 ? [[0, 1, 2, 3]] : [[0, 1], [2, 3]]
        for (control, indices) in zip(controls, rows) {
            control.selectedSegmentIndex = indices.firstIndex(of: index) ?? UISegmentedControl.noSegment
        }
    }
}

@Observable final class ArtifactFilterChoice { var index = 0 }

/// [ui-hunt] The Desktop Look's filter: the desktop's outlined strip, whole labels.
private struct ArtifactFilterStrip: View {
    let titles: [String]
    @Bindable var choice: ArtifactFilterChoice
    let changed: (Int) -> Void

    var body: some View {
        DesktopSegmentStrip(options: titles.enumerated().map { ($0.element, $0.offset) },
                            selection: Binding(get: { choice.index }, set: { choice.index = $0; changed($0) }),
                            ticks: false)   // `pickSegment` plays the tick
            .accessibilityElement(children: .contain)
    }
}

#if DEBUG
extension ArtifactsViewController {
    /// [mac-audit] `-HQDebugMacShotsFiles` (MacShots): the menus the first rows and pins open, and what each would hand a
    /// drop out of the app, as (label, menu, provider).
    func debugMenus() -> [(String, UIMenu, NSItemProvider?)] {
        var out: [(String, UIMenu, NSItemProvider?)] = []
        var seen = Set<String>()
        for item in dataSource.snapshot().itemIdentifiers {
            switch item {
            case .row(let id), .image(let id):
                guard let record = records[id], !seen.contains("r\(record.kind)") else { continue }
                seen.insert("r\(record.kind)")
                out.append(("row \(record.kind) \(record.label)", menu(for: record, missing: false), dragOutProvider(record)))
            case .pin(let id), .pinRow(let id):
                guard let pin = pinsShown[id], !seen.contains("pin") else { continue }
                seen.insert("pin")
                out.append(("pin \(pin.label)", pinMenu(pin), dragOutProvider(pin.record)))
            default:
                continue
            }
        }
        return out
    }

    /// [mac-tools] `-HQDebugMacShotsGrids` (MacShots): opens the file or link named `label`, as a click on its card.
    func debugOpen(_ label: String) {
        guard let record = records.values.first(where: { $0.label == label }), let path = dataSource.indexPath(for: .row(record.id)) else {
            print("grids tour: no card \(label)"); return
        }
        collectionView.selectItem(at: path, animated: false, scrollPosition: [])
        collectionView(collectionView, didSelectItemAt: path)
    }

    /// Pins the artifacts named `labels` that aren't pinned yet (the Tiles page then has tiles to show).
    func debugPin(_ labels: [String]) {
        for label in labels {
            guard let record = records.values.first(where: { $0.label == label }), !pins.isPinned(record) else { continue }
            PinActions.toggle(record, pins: pins, from: nil)
        }
    }
}
#endif
