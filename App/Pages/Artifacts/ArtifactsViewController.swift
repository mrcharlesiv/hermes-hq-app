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
    private nonisolated enum Section: Hashable { case filter, making, pinned, allPins, images, showAllImages, day(String), more, unavailable, state, count }
    private nonisolated enum Item: Hashable {
        case filter, image(String), showAllImages(Int), row(String), loadMore, unavailableToggle(Int), unavailableRow(String)
        case state, skeleton(Int), count(String), pin(String), pinRow(String), allPins(Int), making(String)
    }

    /// [pins] As rows, Artifacts lists this many pins, then "See All N Pinned".
    private static let pinRowsOnArtifacts = 5
    /// [dashboard] As Grid, Artifacts shows this many tiles, then "See All N Pinned".
    private static let pinTilesOnArtifacts = 4

    let store: ArtifactsStore
    let scope: PagesScope
    weak var services: PagesServices?
    let makeChat: (any ChatSessionModel) -> UIViewController
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
    /// [Mac AAA 2026-11-16] The bar's one filter, made once (`placeBarFilter`); `barFilter` is it while it is on show.
    private var barFilterView: ArtifactFilterBar?
    private var barFilterWidth: NSLayoutConstraint?
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
    let pins: ArtifactPins
    /// What the owner removed: left out of the list and the pins.
    var hidden: ArtifactHidden { store.hidden }
    private var hiddenObserver: NSObjectProtocol?
    var pinPictures: PinPictures!
    /// [live-tiles] Tiles whose pages have buttons or ask to refresh, running live (the Tiles page only).
    var liveTiles: LiveTiles?
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
    private var themeObserver: NSObjectProtocol?
    private var drawnThemeKey = ""
    private var prewarmTask: Task<Void, Never>?
    /// [pins] The count the Pinned page's header says ("3 Pinned").
    private var pinnedHeaderCount = -1
    /// Owner 2026-11-17 (Mac calls Q13): on the Mac the Tiles page has no row under the bar ("5 Items … + ⊞"): its New
    /// Tile + and its View As switch are bar items, as Jobs' and Tasks' + are, and Edit Tiles' Done takes their place.
    /// [tile-soft] And on the iPhone and iPad once the Grid is the tiles alone (`gridIsBare`): + is in the bar there too.
    private var tilesInBar: Bool { pinnedOnly && (DeviceWord.isMac || gridIsBare) }
    private lazy var newTileItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "plus"), primaryAction: UIAction { [weak self] _ in self?.newTile() })
        item.accessibilityLabel = "New Tile"
        item.accessibilityIdentifier = "tile.new"
        DesktopBars.markThin(item)
        return item
    }()
    private lazy var tilesViewItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: PinActions.viewSymbol), menu: tilesViewMenu(openAll: false))
        item.accessibilityLabel = "View As"
        item.accessibilityIdentifier = "pins.view"
        DesktopBars.markThin(item)
        return item
    }()
    private lazy var tilesDoneItem: UIBarButtonItem = {
        let item = UIBarButtonItem(title: "Done", primaryAction: UIAction { [weak self] _ in self?.setEditingTiles(false) })
        item.style = .prominent
        item.accessibilityIdentifier = "pins.done"
        return item
    }()

    /// The Tiles page's own bar items on the Mac (`tilesInBar`): + and View As, Done while editing, none while the empty
    /// state's New Tile is the one thing to do (they come with the first tile, as Jobs' + does).
    private func tilesBarItems() -> [UIBarButtonItem] {
        guard tilesInBar, services != nil else { return [] }
        if editingTiles { return [tilesDoneItem] }
        if listShowsState, query.pgTrim.isEmpty { return [] }
        // [tile-soft] A phone's bar has room for one more: New Tile. View As is in the filter's menu (`updateBarItems`).
        if !DeviceWord.isMac { return [newTileItem] }
        let symbol = PinActions.viewSymbol
        if tilesViewItem.image != UIImage(systemName: symbol) { tilesViewItem.image = UIImage(systemName: symbol) }
        return [newTileItem, tilesViewItem]
    }
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
    private func updateBarItems(extra given: [UIBarButtonItem] = []) {
        let extra = given
        // [Mac AAA 2026-11-17] Edit Tiles on the Mac: Done alone in the bar, as with no tiles (Home Screen's edit): the
        // filter, the view switch, + and search have nothing to do until it ends.
        if DeviceWord.isMac, tilesInBar, editingTiles {
            if navigationItem.rightBarButtonItems ?? [] != [tilesDoneItem] { navigationItem.rightBarButtonItems = [tilesDoneItem] }
            return
        }
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
        scopeItem.update(scope: scope, bots: services?.bots ?? [], on: navigationItem, extra: extra, search: searchCapsule?.searchItem,
                         // [tile-soft] The bare Grid's View As: under the bots in the filter's menu (a ⋯ of its own with one bot).
                         menuExtra: gridIsBare ? tilesViewElement(openAll: false) : nil,
                         alone: gridIsBare && !editingTiles && !listShowsState ? tilesMoreItem : nil)
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
        view.backgroundColor = HQPalette.panePage
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = HQPalette.panePage
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
        let backdrop = PageBackdrop.install(in: self, clearing: [collectionView])   // [backdrop] Theme › App Background
        // [soft-cards] The days' headings lose their band on a card, and get it back off one.
        backdrop.onCardsChange = { [weak self] in
            guard let self else { return }
            // [soft-cards] The Tiles page's first card one gap under the bar, as on every page (it began at the bar's edge).
            BackdropCards.setTopRoom(self.pinnedOnly && BackdropCards.on(self) ? BackdropCards.gap : 0, of: self.collectionView)
            guard let dataSource = self.dataSource else { return }
            var snapshot = dataSource.snapshot()
            snapshot.reloadSections(snapshot.sectionIdentifiers)
            dataSource.apply(snapshot, animatingDifferences: false)
        }
        // [tiles-chips-same] The page names: a fixed band under the bar, as Tasks' views (they were the list's first row).
        if pinnedOnly { pagesHeader.install(in: self, list: collectionView, backdrop: backdrop) }
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
        // [tiles] Paused, resumed, run now or a new schedule from a tile's menu: its mark follows at once.
        NotificationCenter.default.addObserver(forName: TileUpdates.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pinnedOnly, self.viewIfLoaded?.window != nil else { return }
                self.watchTiles(true)
            }
        }
        scopeObserver = scope.observe { [weak self] _ in self?.scopeChanged() }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self,
                                ThemeGenerationTrait.self, UITraitAccessibilityContrast.self]) { (vc: ArtifactsViewController, previous) in
            let appearanceChanged = previous.userInterfaceStyle != vc.traitCollection.userInterfaceStyle
                || previous[ThemeGenerationTrait.self] != vc.traitCollection[ThemeGenerationTrait.self]
                || previous.accessibilityContrast != vc.traitCollection.accessibilityContrast
            if appearanceChanged {
                vc.liveTiles?.updateTheme(vc.traitCollection)
                PageSnapshots.shared.cancelPrewarm()
                guard vc.viewIfLoaded?.window != nil else { return }
                vc.reload(animated: false)
            } else {
                vc.reload(animated: false)
            }
        }
        // [mac] UI Scale (⌘+ / ⌘−) or the look changed: the Grid's cells and the pages in them follow the app's scale.
        drawnScale = HQFont.scale
        themeObserver = NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.barFilterWidth?.constant = (320 * max(1, HQFont.scale)).rounded()
                if HQFont.scale != self.drawnScale {
                    self.drawnScale = HQFont.scale
                    self.collectionView.collectionViewLayout.invalidateLayout()
                    self.reload(animated: false)
                } else if self.viewIfLoaded?.window != nil,
                          HTMLPageSheet.themeKey(self.traitCollection) != self.drawnThemeKey {
                    self.liveTiles?.updateTheme(self.traitCollection)
                    self.reload(animated: false)
                }
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
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
        prewarmTask?.cancel()
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
        installBarItemTips()   // [Mac UI check 2026-11-13] the bar's icon buttons name themselves under the pointer
        searchCapsule?.restoreIfTyped()   // [morepages]
        if !pinnedOnly { claimStore() }
        store.setScope(currentScope)
        if !pinnedOnly { store.pageShown() }
        // [dashboard] Live tiles: a Job rewrites a tile's file on its schedule, so pages drawn over 10 minutes ago
        // are drawn again when the Dashboard opens (fresh ones are left alone).
        if pinnedOnly { pinPictures.redraw(pins.pins, drawnBefore: Date().addingTimeInterval(-600)) }
        if pinnedOnly { HTMLPageSheet.prewarm(traits: traitCollection) }   // [tiles] a tile opens on a ready web view
        if pinnedOnly, let services { TileMaker.restorePending(accountId: store.account.id, services: services, from: self) }   // [tiles-v2]
        watchTiles(true)
        liveTiles?.watch(true)
        reload(animated: false)
        retryTransientPreviews()
        if let selected = collectionView.indexPathsForSelectedItems { selected.forEach { collectionView.deselectItem(at: $0, animated: animated) } }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        prewarmTask?.cancel()
        prewarmTask = nil
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

    #if DEBUG
    /// [Mac AAA 2026-11-17] Tours: into or out of Edit Tiles, as View As › Edit Tiles and the bar's Done do.
    func debugEditTiles(_ on: Bool) { setEditingTiles(on) }
    #endif

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
        if tilesInBar { updateBarItems(extra: tilesBarItems()) }   // Mac calls Q13: Done in the bar
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
            let size = PinTileSize.fitting(columns: max(1, min(across, metrics.columns)), rows: max(1, down), gridColumns: metrics.columns)
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
        let cards = BackdropCardLayout { [weak self] index, environment in   // [soft-cards] one card behind joined sections
            guard let self, let section = self.dataSource?.sectionIdentifier(for: index) else { return nil }
            switch section {
            case .pinned:
                let pinned = self.pinnedLayout(environment)
                // [soft-cards] The shelf on Artifacts ("Tiles" over a row of pins) stands on a card. The Tiles page is
                // tiles alone, each a card of its own: none there.
                // "See All" under the shelf is the card's foot. The Tiles page's list is rows on a card, as any list.
                let next = self.dataSource?.sectionIdentifier(for: index + 1)
                if !self.pinnedOnly {
                    BackdropCards.card(pinned, on: BackdropCards.on(self), header: true, keepWidth: true, join: next == .allPins ? .below : [])
                } else if !self.tilesStandAlone {
                    // The grid's names stand under its tiles, on the page: a card behind it too (it keeps its own width).
                    // Under the grid's names, as much as over "6 Items" (they bring 6 pt; a list's last row its own).
                    BackdropCards.card(pinned, on: BackdropCards.on(self), header: !self.tilesInBar, keepWidth: ArtifactPins.view == .grid,
                                       extraBottom: ArtifactPins.view == .grid ? 11 : 0)
                }
                return ScrollBarLane.keep(pinned)
            case .images where self.isGrid:
                return ScrollBarLane.keep(self.gridImagesLayout(environment))
            case .day where self.isGrid:
                return ScrollBarLane.keep(self.gridCardsLayout(environment))
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
                    // [soft-cards] On a card the 4 pt under the pictures is the card's own (below), and the next card one
                    // gap on, as every card (it stood 14 pt off).
                    s.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 19, bottom: BackdropCards.on(self) ? 0 : 4, trailing: 19)
                    let header = NSCollectionLayoutBoundarySupplementaryItem(
                        layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(36)),
                        elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
                    s.boundarySupplementaryItems = [header]
                    s.supplementaryContentInsetsReference = .none   // the header spans the width, as the day headers do
                    // [soft-cards] "Images" and its pictures on a card, with Show All Images as its foot.
                    // The pictures bring 4 pt under them, a row's words about 14: as much under them as over "Images" (17 pt).
                    let foot = self.dataSource?.sectionIdentifier(for: index + 1) == .showAllImages
                    BackdropCards.card(s, on: BackdropCards.on(self), header: true, keepWidth: true, join: foot ? .below : [], extraBottom: foot ? 0 : 10)
                } else {
                    s.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
                }
                return ScrollBarLane.keep(s)
            default:
                var config = UICollectionLayoutListConfiguration(appearance: .plain)
                config.backgroundColor = .clear
                config.separatorConfiguration.color = HQPalette.separator
                config.itemSeparatorHandler = { [weak self] path, separator in
                    var s = separator
                    s.topSeparatorVisibility = .hidden
                    s.bottomSeparatorInsets = NSDirectionalEdgeInsets(top: 0, leading: 76, bottom: 0, trailing: 20)   // as Bots and Jobs
                    // [soft-cards] No rule under a card's last row.
                    if let self, BackdropCards.on(self), path.item == self.collectionView.numberOfItems(inSection: path.section) - 1 {
                        s.bottomSeparatorVisibility = .hidden
                    }
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
                    BackdropCards.card(s, on: cards, header: true, extraBottom: 6)   // 17 pt under the last row's words, as over the date
                }
                // [soft-cards] "See All" is the foot of the shelf's card above it, Show All Images of the pictures'. What is
                // listed but can't be opened, and Show More, are cards of their own.
                let above = index > 0 ? self.dataSource?.sectionIdentifier(for: index - 1) : nil
                switch section {
                case .allPins where above == .pinned, .showAllImages where above == .images:
                    // The foot's words stand in a 44 pt row: its own room under them is enough.
                    BackdropCards.card(s, on: BackdropCards.on(self), join: .above, extraBottom: -BackdropCards.pad)
                case .more, .unavailable:
                    BackdropCards.card(s, on: BackdropCards.on(self))
                default: break
                }
                return ScrollBarLane.keep(s)
            }
        }
        BackdropCards.register(in: cards)   // [backdrop-cards]
        cards.placesCards = true            // [soft-cards] the Tiles shelf scrolls sideways
        return cards
    }

    // MARK: The Mac's grid

    /// [mac-tools] Thumbnails 150 pt or wider, as many across as fit (three at least, as the list's grid).
    private func gridImagesLayout(_ environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let width = environment.container.effectiveContentSize.width - 2 * Self.gridInset - ScrollBarLane.listTrailing   // [mac] the scroller's lane
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
        let width = environment.container.effectiveContentSize.width - 2 * Self.gridInset - ScrollBarLane.listTrailing   // [mac] the scroller's lane
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
        // [Mac AAA 2026-11-16] (lists L12) One filter in the bar for the page's life, shown or hidden: a new bar item
        // each time the list came back wide (a file open beside it, then closed) stood on a square, lighter platter of
        // the bar's own, behind the segments, for as long as the page was on show.
        if barFilterView == nil {
            let made = ArtifactFilterBar { [weak self] index in self?.pickSegment(index) }
            made.translatesAutoresizingMaskIntoConstraints = false
            let width = made.widthAnchor.constraint(equalToConstant: (320 * max(1, HQFont.scale)).rounded())
            width.priority = .init(999)   // the stack's own zero width wins while it is hidden
            width.isActive = true
            barFilterWidth = width
            barFilterView = made
            navigationItem.leftBarButtonItem = MacToolBar.lead(title: title ?? "Artifacts", popUp: made)
            navigationItem.titleView = UIView()   // the middle stays empty; `title` still names the page (VoiceOver)
        }
        barFilterView?.select([nil, .image, .file, .link].firstIndex(of: filter) ?? 0)
        barFilterView?.isHidden = !inBar
        barFilter = inBar ? barFilterView : nil
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
            section.contentInsets = NSDirectionalEdgeInsets(top: tilesInBar ? Self.tilesTop : 0, leading: 10, bottom: 16, trailing: 10)
            // Mac calls Q13: no header row on the Mac's Tiles page (its + and View As are in the bar).
            section.boundarySupplementaryItems = tilesInBar ? [] : [NSCollectionLayoutBoundarySupplementaryItem(
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
        let width = environment.container.effectiveContentSize.width - ScrollBarLane.listTrailing   // [mac] the scroller's lane
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
        section.contentInsets = NSDirectionalEdgeInsets(top: tilesInBar ? Self.tilesTop : 2, leading: inset, bottom: 16, trailing: inset)
        // Mac calls Q13: no header row on the Mac's Tiles page (its + and View As are in the bar).
        section.boundarySupplementaryItems = tilesInBar ? [] : [NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(36)),
            elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)]
        section.supplementaryContentInsetsReference = .none
        return section
    }

    nonisolated static let gridInset: CGFloat = 20
    /// Mac calls Q13: the room over the Mac's Tiles under the bar, with no header row there (as Artifacts' first heading
    /// stands under its bar).
    nonisolated static let tilesTop: CGFloat = 8
    nonisolated static let gridSpacing: CGFloat = 12

    /// [dashboard] The shape of a pin's picture where it shows (its page is drawn in that shape): its Grid tile, a card's
    /// picture, a list row's square.
    func pinPictureShape(_ pin: ArtifactPin) -> PageSnapshots.Shape {
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
        config.itemSeparatorHandler = { [weak self] path, separator in
            var s = separator
            s.topSeparatorVisibility = .hidden
            s.bottomSeparatorInsets = NSDirectionalEdgeInsets(top: 0, leading: 76, bottom: 0, trailing: 20)
            // [soft-cards] No rule under a card's last row.
            if let self, BackdropCards.on(self), path.item == self.collectionView.numberOfItems(inSection: path.section) - 1 {
                s.bottomSeparatorVisibility = .hidden
            }
            return s
        }
        config.headerMode = tilesInBar ? .none : .supplementary   // Mac calls Q13
        config.headerTopPadding = 0
        config.leadingSwipeActionsConfigurationProvider = { [weak self] path in self?.pinSwipe(at: path) }
        config.trailingSwipeActionsConfigurationProvider = { [weak self] path in self?.removeSwipe(at: path) }
        let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
        if tilesInBar { section.contentInsets.top = Self.tilesTop }
        return section
    }

    /// [pins] Grid ⇄ Cards ⇄ List (or Grid's names): the pinned section's layout and its items change.
    private func pinsViewChanged() {
        guard isViewLoaded else { return }
        if ArtifactPins.view != .grid { editingTiles = false }
        pinnedHeaderCount = -1
        scopeItem.forgetMenu()   // [tile-soft] View As joins or leaves the filter's menu with the count line
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
        // [tiles] A tile being made (owner 2026-11-03: "it says making a tile but idk where to see it doing anything"):
        // what was asked, the bot and the step it's on now; a tap opens the chat.
        let makingCell = UICollectionView.CellRegistration<TileMakingCell, String> { cell, _, id in
            guard let maker = TileMaker.active.first(where: { $0.id == id }) else { return }
            cell.show(what: maker.rowTitle, detail: "\(maker.bot.name) · \(maker.stepWords)", changing: maker.changing != nil) {
                [weak maker] in
                PagesHaptics.selection()
                maker?.cancel()
            }
        }
        let filterCell = UICollectionView.CellRegistration<SoftCardListCell, String> { [weak self] cell, _, _ in
            guard let self else { return }
            let bar = (cell.contentView.subviews.first as? ArtifactFilterBar) ?? self.makeFilterBar(in: cell)
            bar.select([nil, .image, .file, .link].firstIndex(of: self.filter) ?? 0)
            cell.backgroundConfiguration = .clear()
        }
        let imageCell = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            guard let self, let record = self.records[id] else { return }
            self.configureTile(cell, record)
        }
        let actionRowBackground: (UICollectionViewCell, UICellConfigurationState) -> Void = { cell, state in
            #if targetEnvironment(macCatalyst)
            if DeviceWord.isMac {
                var s = state
                s.isSelected = false
                cell.backgroundConfiguration = MacListFocus.background(cell, s)
                return
            }
            #endif
            if Theme.isDesktop { cell.backgroundConfiguration = DesktopLayout.rowBackground(state); return }
            var background = UIBackgroundConfiguration.clear()
            background.backgroundColor = state.isHighlighted ? HQPalette.cellPressed : .clear
            cell.backgroundConfiguration = background
        }
        let showAllCell = UICollectionView.CellRegistration<SoftCardListCell, Int> { cell, _, count in
            var content = UIListContentConfiguration.cell().hqScaled()
            content.text = "Show All \(count) Images"
            content.textProperties.color = HQPalette.tint
            cell.contentConfiguration = content
            cell.accessories = [Self.showAllChevron]
            cell.accessibilityIdentifier = "artifacts.show-all-images"
            cell.configurationUpdateHandler = actionRowBackground
        }
        let rowCell = UICollectionView.CellRegistration<SoftCardListCell, String> { [weak self] cell, _, id in
            guard let self, let record = self.records[id] else { return }
            self.configureRow(cell, record, missing: false)
        }
        let missingCell = UICollectionView.CellRegistration<SoftCardListCell, String> { [weak self] cell, _, id in
            guard let self, let record = self.records[id] else { return }
            self.configureRow(cell, record, missing: true)
        }
        let toggleCell = UICollectionView.CellRegistration<SoftCardListCell, Int> { [weak self] cell, _, count in
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
                } else {
                    // [Mac AAA 2026-11-16] Drawn as every other folding head is (Sessions' "Recent ⌄", "Projects ⌄"):
                    // the name on the headings' edge, its caret after it, the count after that while folded. It read
                    // "› Unavailable (1)", the arrow first and the name 26 pt in from "Today" and "Friday" over it.
                    content.attributedText = Self.unavailableHead(count: count, open: self?.unavailableOpen ?? false)
                }
            }
            cell.contentConfiguration = content
            if DeviceWord.isMac, !Theme.isDesktop {
                cell.accessories = []
                cell.accessibilityIdentifier = "artifacts.unavailable"
                cell.accessibilityLabel = "Unavailable, \(count)"
                cell.accessibilityTraits = [.button]
                cell.accessibilityValue = (self?.unavailableOpen ?? false) ? "open" : "closed"
                cell.configurationUpdateHandler = actionRowBackground
                return
            }
            // Mac pass round 3: an outline disclosure turns only for a section snapshot's own folding; this group folds
            // by its own flag, so the arrow kept pointing right with the group open. Its own arrow, turned by that flag.
            let arrow = UIImageView(image: UIImage(systemName: "chevron.right",
                                                   withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote).applying(UIImage.SymbolConfiguration(weight: .semibold))))
            arrow.tintColor = HQPalette.label3
            arrow.isAccessibilityElement = false   // the row says open or closed
            arrow.transform = Self.unavailableArrowTurn(open: self?.unavailableOpen ?? false)
            cell.accessories = [.customView(configuration: .init(customView: arrow, placement: .leading(displayed: .always),
                                                                 reservedLayoutWidth: .actual))]
            cell.accessibilityIdentifier = "artifacts.unavailable"
            cell.accessibilityTraits = [.button]
            cell.accessibilityValue = (self?.unavailableOpen ?? false) ? "open" : "closed"
            cell.configurationUpdateHandler = actionRowBackground
        }
        let moreCell = UICollectionView.CellRegistration<SoftCardListCell, String> { cell, _, _ in
            cell.contentConfiguration = UIHostingConfiguration { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12) }
            cell.backgroundConfiguration = .clear()
        }
        let stateCell = UICollectionView.CellRegistration<SoftCardListCell, String> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.contentConfiguration = BackdropState.wrap(self.stateConfiguration())   // [backdrop-cards]
            cell.backgroundConfiguration = .clear()
        }
        let countCell = UICollectionView.CellRegistration<SoftCardListCell, String> { cell, _, text in
            cell.contentConfiguration = UIHostingConfiguration { PageCountView(text: text) }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        let pinCell = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            guard let self, let pin = self.pinsShown[id] else { return }
            self.configurePin(cell, pin)
        }
        let pinRowCell = UICollectionView.CellRegistration<SoftCardListCell, String> { [weak self] cell, _, id in
            guard let self, let pin = self.pinsShown[id] else { return }
            self.configurePinRow(cell, pin)
        }
        let allPinsCell = UICollectionView.CellRegistration<SoftCardListCell, Int> { cell, _, count in
            var content = UIListContentConfiguration.cell().hqScaled()
            content.text = "See All \(count)"
            content.textProperties.color = HQPalette.tint
            cell.contentConfiguration = content
            cell.accessories = [Self.showAllChevron]
            cell.accessibilityIdentifier = "artifacts.all-pins"
            cell.configurationUpdateHandler = actionRowBackground
        }
        let skeletonCell = UICollectionView.CellRegistration<SoftCardListCell, Int> { cell, _, _ in
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
            // [soft-cards] Owner 2026-11-13 ("Recheck everything"): on a card the name stands as far under the card's
            // top as the last row's words stand over its foot (17 pt).
            if BackdropCards.on(self) {
                switch self.dataSource.sectionIdentifier(for: path.section) {
                // A day's name starts where its rows' pictures do (it stood 3 pt left of them).
                case .day?: content.directionalLayoutMargins.top = 14; content.directionalLayoutMargins.leading = 20 + BackdropCards.side
                case .images?: content.directionalLayoutMargins.top = 11
                // "Tiles" over the shelf, "6 Items" over the Tiles page's list and grid (its cards stand alone: the
                // count is a line of its own there).
                // (The shelf's foot, See All, keeps 19 pt under its words: 1 pt more over "Tiles" there.)
                case .pinned? where !self.tilesStandAlone: content.directionalLayoutMargins.top = self.pinnedOnly ? 14 : 15
                default: break
                }
            }
            // Mac polish #116: the Desktop Look's tracked capitals, as its other section labels (Kanban's, the forms').
            // The Tiles page's count ("6 Items") is not a heading and keeps its words.
            let count: Bool
            if case .pinned? = self.dataSource.sectionIdentifier(for: path.section) { count = self.pinnedOnly } else { count = false }
            if let section = self.dataSource.sectionIdentifier(for: path.section), let head = self.countedHead(section) {
                content.attributedText = head
            } else if Theme.isDesktop, !count {
                content.attributedText = NSAttributedString(string: (content.text ?? "").uppercased(), attributes: DesktopLayout.labelAttributes())
            }
            header.contentConfiguration = content.hqMacSectionHeader()   // [mac] Stress test 2026-10-28 #52
            // [pins] Beside "Pinned": View As Cards | List, and Open Pinned.
            if case .pinned? = self.dataSource.sectionIdentifier(for: path.section) {
                // The button's 44 pt box stands over the ⋯ below it: a row's (6 pt in), a Pinned page card's (12 pt
                // in); on the shelf its glyph ends where the cards do (20 pt in).
                let trailing: CGFloat = ArtifactPins.showsList ? 6 : (self.pinnedOnly && ArtifactPins.view == .cards ? 12 : 8)
                header.preservesSuperviewLayoutMargins = false
                // [soft-cards] Over rows on a card the name starts where their pictures do; over tiles, where the tiles do.
                let leading: CGFloat = ArtifactPins.showsList && BackdropCards.on(self) ? 20 + BackdropCards.side : 20
                if leading > 20 { content.directionalLayoutMargins.leading = leading; header.contentConfiguration = content.hqMacSectionHeader() }
                header.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: leading, bottom: 0, trailing: trailing)
                // [dashboard] On the Dashboard, ＋ (New Tile) before it.
                let tiles = self.pinnedOnly && !self.editingTiles && self.services != nil
                var view: UIView = tiles ? self.newTileAndViewButtons() : self.pinsHeaderButton(openAll: !self.pinnedOnly)
                // [soft-cards] On a card the name stands lower in its header (more room over it than under): the
                // buttons stay on its line.
                if BackdropCards.on(self), !self.tilesStandAlone {
                    let box = UIView(frame: view.bounds)
                    view.frame.origin.y = 4
                    box.addSubview(view)
                    view = box
                }
                header.accessories = [.customView(configuration: .init(customView: view, placement: .trailing(),
                                                                       reservedLayoutWidth: .custom(self.editingTiles ? 56 : tiles ? 88 : 44), tintColor: HQPalette.label2,
                                                                       maintainsFixedSize: true))]
            } else {
                header.accessories = []
            }
            var background = UIBackgroundConfiguration.clear()
            // [soft-cards] On a soft card the date is the card's first line: no band of the page colour across it.
            background.backgroundColor = BackdropCards.on(self) ? .clear : HQPalette.page
            // The Tiles page as cards is tiles alone, each its own card: only its count line needs a backing.
            if BackdropCards.on(self), self.tilesStandAlone,
               case .pinned? = self.dataSource.sectionIdentifier(for: path.section) {
                background.customView = SoftCardSurface()
                background.backgroundInsets = NSDirectionalEdgeInsets(top: 2, leading: BackdropCards.side, bottom: 4, trailing: BackdropCards.side)
            }
            header.backgroundConfiguration = background
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { cv, path, item in
            switch item {
            case .filter: return cv.dequeueConfiguredReusableCell(using: filterCell, for: path, item: "filter")
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
        #if targetEnvironment(macCatalyst)
        MacHover.ownsHover(cell) { _ in }   // ArtifactTileView paints its own clipped hover via hqPointerFill
        cell.backgroundConfiguration = .clear()
        #endif
    }

    #if DEBUG
    /// [Mac AAA 2026-11-17] `-HQDebugTileHostile`'s tile for the `index`th pin: white, black, red, a photo, then again.
    private static func debugHostileTile(_ index: Int) -> (picture: UIImage, health: TileJobs.Health, working: Bool)? {
        guard UserDefaults.standard.bool(forKey: "HQDebugTileHostile") else { return nil }
        let size = CGSize(width: 320, height: 320)
        let kind = index % 4
        let picture = UIGraphicsImageRenderer(size: size).image { context in
            let colours: [UIColor] = [.white, .black, UIColor(red: 1, green: 0, blue: 0, alpha: 1)]
            if kind < 3 {
                colours[kind].setFill()
                context.fill(CGRect(origin: .zero, size: size))
            } else {
                // A stand-in photo: a bright sky over dark hills, with a sun.
                let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [UIColor(red: 0.98, green: 0.78, blue: 0.45, alpha: 1).cgColor,
                                              UIColor(red: 0.35, green: 0.62, blue: 0.95, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
                context.cgContext.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: size.height * 0.6), options: [.drawsAfterEndLocation])
                UIColor(red: 1, green: 0.95, blue: 0.8, alpha: 1).setFill()
                UIBezierPath(ovalIn: CGRect(x: 200, y: 40, width: 70, height: 70)).fill()
                UIColor(red: 0.08, green: 0.2, blue: 0.12, alpha: 1).setFill()
                let hills = UIBezierPath()
                hills.move(to: CGPoint(x: 0, y: 200))
                hills.addQuadCurve(to: CGPoint(x: 160, y: 190), controlPoint: CGPoint(x: 80, y: 120))
                hills.addQuadCurve(to: CGPoint(x: 320, y: 170), controlPoint: CGPoint(x: 240, y: 110))
                hills.addLine(to: CGPoint(x: 320, y: 320)); hills.addLine(to: CGPoint(x: 0, y: 320)); hills.close()
                hills.fill()
            }
        }
        let health: [TileJobs.Health] = [.late, .paused, .updating, .failed(nil)]
        return (picture, health[kind], kind == 3)
    }
    #endif

    private func configurePin(_ cell: UICollectionViewCell, _ kept: ArtifactPin) {
        let pin = pins.shown(kept)   // Mac polish #45: its name as every list shows it
        let traits = traitCollection
        let grid = ArtifactPins.view == .grid
        let pixels = (pinnedOnly || grid && pin.tileSize != .small ? 640 : 520) * traitCollection.displayScale
        let shape = pinPictureShape(pin)
        let picture = pinPictures.picture(pin, traits: traits, pixels: pixels, shape: shape)
        let busy = picture == nil && (pinPictures.waiting(pin, traits: traits, shape: shape) || openingRow == pin.record.id)
        let bot = PagesNames.botName(pin.profile, bots: services?.bots ?? [])
        let subtitle = store.scope != "all" && !pin.sessionTitle.isEmpty ? pin.sessionTitle   // one bot: its name says nothing
            : pin.sessionTitle.isEmpty ? bot : "\(bot) · \(pin.sessionTitle)"
        let failed = pinPictures.failed(pin)   // Mac polish #46
        // [tiles] A page whose file is gone wears the failed mark (Mac pass 2026-11-14: a grey chart, no mark).
        let health = failed && pin.isPage ? .failed(TileHealthMark.goneWords) : TileUpdates.shared.health(pin.id)
        let hover = pinHover(pin.id, cell: cell)
        // [tiles] Its bot working on it (Change…, a button), and the moment after a change is done.
        var working = TileMaker.working(on: pin.id, accountId: store.account.id)?.tileWords
        let ringed = justChanged.contains(pin.id)
        #if DEBUG
        // [Mac AAA 2026-11-17] `-HQDebugTileHostile YES`: the tiles drawn white, black, saturated red and a photo, with
        // a mark on each (late, paused, updating, failed) and "changing" on the photo, to see what floats over them.
        var tilePicture = picture, tileHealth = health, fills = pin.kind == .image
        if let index = pins.pins.firstIndex(where: { $0.id == kept.id }), let hostile = Self.debugHostileTile(index) {
            tilePicture = hostile.picture
            fills = true
            tileHealth = hostile.health
            if hostile.working { working = "Otto is changing it…" }
        }
        #else
        let tilePicture = picture, tileHealth = health, fills = pin.kind == .image
        #endif
        if grid {
            let names = ArtifactPins.showsNames, editing = editingTiles
            let live = editing ? nil : liveTiles?.view(for: pin, traits: traits)   // [live-tiles]
            let capped = !editing && (liveTiles?.isCapped(pin) == true)        // [tiles-v2]
            cell.contentConfiguration = UIHostingConfiguration {
                PinTileView(pin: pin, picture: tilePicture, fills: fills, busy: busy, showsName: names, health: tileHealth,
                            editing: editing, live: live, liveCapped: capped, hover: hover, failed: failed,
                            working: editing ? nil : working, ringed: ringed && !editing) { [weak self] in
                    guard let self else { return }
                    PinActions.toggle(pin.record, pins: self.pins, from: self)
                }
            }.margins(.all, 0)
        } else {
            cell.contentConfiguration = UIHostingConfiguration {
                PinCardView(pin: pin, picture: tilePicture, fills: fills, subtitle: subtitle, busy: busy, health: tileHealth,
                            hover: hover, failed: failed, working: working, ringed: ringed) { [weak self, weak cell] in
                    self?.pinMenu(kept, anchor: cell) ?? UIMenu(children: [])   // the kept pin: Rename… starts from its own name
                }
            }.margins(.all, 0)
        }
        cell.accessibilityIdentifier = "pin-card-\(pin.label)"
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = "\(pin.isPage ? "Page" : pin.kind == .image ? "Image" : pin.kind == .link ? "Link" : "File"), \(pin.name), \(subtitle)"
            + (grid ? ", \(pin.tileSize.title)" : "") + (TileHealthMark.words(health).map { ", " + $0 } ?? "") + (failed && !pin.isPage ? ", unavailable" : "")
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
            _ = pinPictures.picture(pin, traits: traitCollection, pixels: 120 * traitCollection.displayScale,
                                    shape: pinPictureShape(pin))
        }
        let failed = pinPictures.failed(pin)   // Mac polish #46: a picture that's gone is drawn as missing
        // Mac polish #45: a page's own title, read here too (a row draws no picture, which is where it was read).
        pinPictures.readHead(pin) { [weak self] head in self?.pins.notePage(id: pin.id, head: head) }
        // [tiles] Its name in words; the record (and so the file it opens) unchanged.
        var shown = pin.record
        shown.label = pins.name(pin)
        // [tiles] Mac pass 2026-11-14: List showed no mark for a failed or paused tile (Grid and Cards did).
        let health = failed && pin.isPage ? .failed(TileHealthMark.goneWords) : TileUpdates.shared.health(pin.id)
        cell.contentConfiguration = UIHostingConfiguration {
            ArtifactRowView(record: shown, subtitle: subtitle, busy: busy, missing: failed, pinned: true, health: health) { [weak self, weak cell] in
                self?.pinMenu(pin, anchor: cell) ?? UIMenu(children: [])
            }
        }.margins(.all, 0)
        cell.accessibilityIdentifier = "pin-row-\(pin.label)"
        cell.accessibilityValue = TileHealthMark.words(health)
        cell.accessibilityCustomActions = liveButtonActions(pin) + pinAccessibilityActions(pin)
        cell.configurationUpdateHandler = { cell, state in
            #if targetEnvironment(macCatalyst)
            if DeviceWord.isMac { cell.backgroundConfiguration = MacListFocus.background(cell, state); return }
            #endif
            if Theme.isDesktop { cell.backgroundConfiguration = DesktopLayout.rowBackground(state); return }
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
        button.menu = tilesViewMenu(openAll: openAll)
        button.accessibilityIdentifier = "pins.view"
        button.accessibilityLabel = "View As"
        return button
    }

    /// View As's menu (the header's button, or the Mac's bar item): the views, Edit Tiles, New Page….
    private func tilesViewMenu(openAll: Bool) -> UIMenu { UIMenu(children: [tilesViewElement(openAll: openAll)]) }

    private func tilesViewElement(openAll: Bool) -> UIDeferredMenuElement {
        UIDeferredMenuElement.uncached { [weak self] done in
            var children = PinActions.viewMenu(openAll: openAll ? { self?.openPinnedPage() } : nil,
                                               editTiles: { self?.setEditingTiles(true) }).children
            // [dashboard] New Page: the way to a second page while there is one (the names show from two).
            if let self, self.showsPages {
                let new = UIAction(title: "New Page…", image: UIImage(systemName: "plus.rectangle.on.rectangle")) { [weak self] _ in self?.askNewPage() }
                new.accessibilityIdentifier = "dashboard.page.new"
                var pageActions: [UIMenuElement] = [new]
                if self.services?.readOnlyGateway == false, self.currentPagePins().contains(where: \.isPage) {
                    let updateAll = UIAction(title: "Update All Now", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                        self?.updateAllCurrentPageTiles()
                    }
                    updateAll.accessibilityIdentifier = "dashboard.page.update-all"
                    let pauseAll = UIAction(title: "Pause All Updates", image: UIImage(systemName: "pause.circle")) { [weak self] _ in
                        self?.setAllCurrentPageTilesPaused(true)
                    }
                    pauseAll.accessibilityIdentifier = "dashboard.page.pause-all"
                    let resumeAll = UIAction(title: "Resume All Updates", image: UIImage(systemName: "play.circle")) { [weak self] _ in
                        self?.setAllCurrentPageTilesPaused(false)
                    }
                    resumeAll.accessibilityIdentifier = "dashboard.page.resume-all"
                    pageActions += [updateAll, pauseAll, resumeAll]
                }
                children.append(UIMenu(options: .displayInline, children: pageActions))
            }
            done(children)
        }
    }

    /// [tile-soft] On the Tiles page each tile is a card of its own on the picture: as Cards, and as the Grid once its
    /// names are off (the default). The Grid with names under its tiles keeps one card behind them, for the names
    /// (as the Mac's Grid does either way: its Tiles page is as it was).
    private var tilesStandAlone: Bool {
        pinnedOnly && (ArtifactPins.view == .cards || ArtifactPins.view == .grid && !ArtifactPins.showsNames && !DeviceWord.isMac)
    }

    /// [tile-soft] Owner 2026-11-17, on the count line over the soft tiles ("6 Items" on a strip of its own, wider than
    /// the tiles and tight against the first): "Padding is very odd here". The Tiles page's Grid with its names off
    /// (the default) is the tiles alone: no count line. What stood on it is in the bar (`tilesInBar`), as on the Mac.
    private var gridIsBare: Bool {
        pinnedOnly && fixedProfile == nil && !DeviceWord.isMac && ArtifactPins.view == .grid && !ArtifactPins.showsNames
    }

    /// With one bot the bar has no filter to hold View As: a ⋯ of its own.
    private lazy var tilesMoreItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: tilesViewMenu(openAll: false))
        item.accessibilityIdentifier = "pins.view"
        item.accessibilityLabel = "View As"
        return item
    }()

    // MARK: Dashboard pages

    /// [dashboard] The page names show on the Dashboard, not on Artifacts' shelf or Bot Info, and not while searching.
    var showsPages: Bool { pinnedOnly && fixedProfile == nil && query.pgTrim.isEmpty }

    /// [tiles-chips-same] The names' band under the bar (installed on the Tiles page only).
    private lazy var pagesHeader: DashboardPagesHeader = {
        let header = DashboardPagesHeader(actions: DashboardPageActions(
            select: { [weak self] id in self?.showPage(id) },
            add: { [weak self] in self?.askNewPage() },
            rename: { [weak self] page in self?.askRenamePage(page) },
            move: { [weak self] page, by in
                PagesHaptics.selection()
                self?.pins.movePage(page.id, by: by)
            },
            delete: { [weak self] page in self?.confirmDeletePage(page) },
            setSymbol: { [weak self] page, symbol in
                PagesHaptics.selection()
                self?.pins.setPageSymbol(page.id, symbol: symbol)
            },
            reorder: { [weak self] sourceId, targetId in
                PagesHaptics.selection()
                self?.pins.reorderPage(sourceId, to: targetId)
            },
            updateAll: { [weak self] in self?.updateAllCurrentPageTiles() },
            pauseAll: { [weak self] pause in self?.setAllCurrentPageTilesPaused(pause) }))
        header.acceptsDrop = { [weak self] session in
            guard let self else { return false }
            return self.showsPages && session.localDragSession?.items.first?.localObject is String
        }
        header.onDrop = { [weak self] session, pageId in
            guard let self, let id = session.localDragSession?.items.first?.localObject as? String,
                  let page = self.pins.pages.first(where: { $0.id == pageId }) else { return }
            self.moveTile(id, to: page)
        }
        return header
    }()
    /// The slot a held tile last opened among the pins: a tick each time the others slide into a new one.
    private var dropSlot: IndexPath?
    private var pageSwipes: [UISwipeGestureRecognizer] = []

    /// The names in the band once there are two pages (none while searching, on the shelf or Bot Info).
    private func showPages() {
        guard pinnedOnly else { return }
        guard showsPages, pins.pages.count > 1 else {
            pagesHeader.update(pages: [], current: pins.currentPage, counts: [:])
            return
        }
        var counts: [String: Int] = [:]
        for pin in hidden.visible(pins.pins) { counts[pins.pageId(of: pin), default: 0] += 1 }
        pagesHeader.update(pages: pins.pages, current: pins.currentPage, counts: counts)
    }

    /// [dashboard] Another page shown (a name tapped, or a swipe sideways): the tiles cross-fade.
    func showPage(_ id: String) {
        guard id != pins.currentPage else { return }
        PagesHaptics.selection()
        AppLog.trace("pages", "dashboard page \(id == DashboardPage.mainId ? "main" : "own") shown")
        pins.currentPage = id   // didChange → reload
        if view.window != nil, !HQMotion.reduced {
            UIView.transition(with: collectionView, duration: HQMotion.fade, options: [.transitionCrossDissolve, .allowUserInteraction], animations: nil)
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

    /// [dashboard] A page's Rename (its hold menu and the ⋯, `DashboardPagesBand`).
    private func askRenamePage(_ page: DashboardPage) {
        askPageName(title: "Rename Page", name: page.name, action: "Rename") { [weak self] name in
            PagesHaptics.success()
            self?.pins.renamePage(page.id, to: name)
        }
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
        let sheet = NewTileSheet.make(services: services, bot: bot, pages: pins.pages, currentPage: pins.currentPage) { [weak self] req in
            guard let self, let services = self.services else { return }
            let chat = services.tileChat(for: req.bot)
            TileMaker.start(bot: req.bot, what: req.what, size: req.size == .small ? nil : req.size,
                            schedule: req.schedule, dashboardPage: req.pageId,
                            accountId: self.store.account.id, chat: chat, from: self)
        }
        present(sheet, animated: true)
    }

    /// [tiles] Change… (owner 2026-11-03: "change a tile by asking"): what to change, then the tile's bot changes its page
    /// in a new chat (the Tiles page shows it working, a tap opens the chat), and the tile is drawn again when it's done.
    /// `before`: run first, handed the ask (nil when presented directly over an opened tile).
    func changeTileAction(_ pin: ArtifactPin, presenter: (() -> UIViewController?)? = nil,
                          before: ((@escaping () -> Void) -> Void)? = nil) -> UIAction {
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
            let ask: () -> Void = { [weak self] in
                guard let self else { return }
                self.askTileChange(pin, from: presenter?() ?? self)
            }
            if let before { before(ask) } else { ask() }
        }
        action.accessibilityIdentifier = "tile.change"
        let bot = (services?.bots ?? []).contains(where: { $0.id == pin.profile })
        if !bot || services?.readOnlyGateway == true { action.attributes = .disabled }
        return action
    }

    /// [tiles] Change Tile (owner 2026-11-10: "greatly improved"): a sheet with the tile as it looks now, its bot and
    /// updates, a field that grows and quick changes (`ChangeTileSheet`), in place of an alert with one cut-off line.
    func askTileChange(_ pin: ArtifactPin, initialWhat: String = "", mode: ChangeTileMode = .change, from host: UIViewController? = nil) {
        guard let bot = services?.bots.first(where: { $0.id == pin.profile }), pin.gatewayPath != nil else { return }
        PagesHaptics.selection()
        let context = pinPictures.context(pin)
        let client = services?.gateway
        let sheet = ChangeTileSheet.make(name: pins.name(pin), bot: bot, picture: currentPicture(pin),
                                         initialWhat: initialWhat, mode: mode, status: {
            guard let job = await TileUpdates.shared.job(for: pin, accountId: context.accountId, client: client) else { return nil }
            return TileJobs.shortStatus(job)
        }) { [weak self] words in
            if mode == .duplicate {
                self?.duplicateTile(id: pin.id, what: words)
            } else {
                self?.changeTile(id: pin.id, what: words)
            }
        }
        (host ?? self).present(sheet, animated: true)
    }

    /// [tiles] The tile's bot changes it in a new chat (Change Tile, and its Try Again).
    func changeTile(id: String, what words: String) {
        guard let services, !services.readOnlyGateway, let pin = pins.pins.first(where: { $0.id == id }), let path = pin.gatewayPath,
              let bot = services.bots.first(where: { $0.id == pin.profile }) else { return }
        let chat = services.tileChat(for: bot)
        TileMaker.change(pin, path: path, bot: bot, what: words, accountId: store.account.id, chat: chat, from: self)
    }

    /// [tile-versions] Versions (owner 2026-11-11: "v1 … v2 … roll back to prior versions … see what prior versions
    /// looked like"): the tile's versions with their pictures, and Roll Back. The menu says which one shows.
    func versionsAction(_ pin: ArtifactPin, presenter: (() -> UIViewController?)? = nil,
                        before: ((@escaping () -> Void) -> Void)? = nil) -> UIAction {
        let shown = pins.pins.first { $0.id == pin.id }?.version
        let action = UIAction(title: "Versions", subtitle: shown.map { "Version \($0)" }, image: UIImage(systemName: "square.stack.3d.up")) {
            [weak self] _ in
            let show: () -> Void = { [weak self] in
                guard let self else { return }
                self.showVersions(pin, from: presenter?() ?? self)
            }
            if let before { before(show) } else { show() }
        }
        action.accessibilityIdentifier = "tile.versions"
        if pin.gatewayPath == nil { action.attributes = .disabled }
        return action
    }

    #if DEBUG
    /// `-HQPagesTileVersions` (PagesDebug): Versions of the first page tile.
    func debugShowVersions(tries: Int = 12) {   // [Mac AAA 2026-11-16] the stand-in's artifacts come late (tools T24)
        guard let pin = pins.pins.first(where: { $0.isPage && $0.gatewayPath != nil }) else {
            // None pinned yet (a tour starts clean): the first page artifact is pinned, then its Versions open.
            if let page = records.values.first(where: { ["html", "htm"].contains(ArtifactFiles.fileExtension($0.value)) }) { debugPin([page.label]) }
            if tries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.debugShowVersions(tries: tries - 1) } }
            return
        }
        showVersions(pin)
    }
    #endif

    func showVersions(_ kept: ArtifactPin, from host: UIViewController? = nil) {
        let pin = pins.pins.first { $0.id == kept.id } ?? kept
        guard pin.gatewayPath != nil else { return }
        PagesHaptics.selection()
        let bots = services?.bots ?? []
        let sheet = TileVersionsSheet.make(pin: pin, name: pins.name(pin),
                                           botName: bots.first { $0.id == pin.profile }?.name,
                                           context: pinPictures.context(pin), writable: services?.readOnlyGateway == false) { [weak self] version in
            self?.rolledBack(pin.id, to: version)
        }
        (host ?? self).present(sheet, animated: true)
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
            let chat = self.tileOwnChat(pin, bot: bot, services: services)
            TileMaker.rolledBack(pin, path: path, bot: bot, version: version.number, accountId: accountId, chat: chat, from: self)
        }
    }

    /// [tiles] The tile's picture as it shows now (the one already drawn for its tile, card or row), for Change Tile.
    func currentPicture(_ kept: ArtifactPin) -> UIImage? {
        let pin = pins.shown(kept)
        let grid = ArtifactPins.view == .grid
        let pixels = (pinnedOnly || grid && pin.tileSize != .small ? 640 : 520) * traitCollection.displayScale
        return pinPictures.picture(pin, traits: traitCollection, pixels: pixels, shape: pinPictureShape(pin))
    }

    /// [tile-chats] The tile's own chat (the one its bot last worked on it in), or a fresh hidden one when it has none.
    func tileOwnChat(_ pin: ArtifactPin, bot: Bot, services: PagesServices) -> any ChatSessionModel {
        Self.tileOwnChat(pin, bot: bot, services: services)
    }

    static func tileOwnChat(_ pin: ArtifactPin, bot: Bot, services: PagesServices) -> any ChatSessionModel {
        guard !pin.sessionId.isEmpty else { return services.tileChat(for: bot) }
        let chat = services.chat(for: SessionSummary(id: pin.sessionId, profile: pin.profile, title: pin.sessionTitle, preview: nil,
                                                     lastActive: nil, source: nil, unread: false, isRunning: false))
        (chat as? LiveChatSession)?.disableThreads()
        return chat
    }

    /// [tile-chats] The tile has a chat to open: the one its bot made or last changed it in, or the one it works in now.
    func tileHasChat(_ pin: ArtifactPin) -> Bool {
        !pin.sessionId.isEmpty || TileMaker.working(on: pin.id, accountId: store.account.id) != nil
    }

    /// [tile-chats] Open Chat (owner 2026-11-21: "an easy way to be able to open the session attached to a Tile"): the
    /// tile's chat, which no list shows. While its bot works on it, the chat it works in (that screen then follows the
    /// turn, and the tile updates when it ends).
    func openChat(ofTile id: String) {
        guard let pin = pins.pins.first(where: { $0.id == id }) else { return }
        if let maker = TileMaker.working(on: pin.id, accountId: store.account.id) {
            AppLog.trace("pages", "tile chat opened while its bot works")
            Haptics.play(.soft)
            openTileChat(maker.chat)
            return
        }
        guard !pin.sessionId.isEmpty else { return }
        AppLog.trace("pages", "tile chat opened")
        showInChat(pin.record)
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
        #if targetEnvironment(macCatalyst)
        // [mac] Mac pass round 3: pushed, a second Pinned page sat in Artifacts' pane. Tiles is a sidebar place.
        if openMacPlace("tab-page-pinned") { return }
        #endif
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
        #if targetEnvironment(macCatalyst)
        // [mac] Mac pass 2026-11-14: pushed, Artifacts landed in the right pane beside Tiles and stayed there after
        // other places were clicked (Tiles came back as a narrow list beside a second Artifacts, not No Tile Open).
        // Artifacts is a place in the sidebar: it opens as its row's click opens it.
        if openMacPlace("tab-page-artifacts") { return }
        #endif
        let page = ArtifactsViewController(store: store, scope: scope, services: services, fixedProfile: fixedProfile, makeChat: makeChat)
        page.showInChatOverride = showInChatOverride
        page.navigationItem.largeTitleDisplayMode = .never
        navigation.pushViewController(page, animated: true)
    }

    #if targetEnvironment(macCatalyst)
    /// [mac] Selects a sidebar place (its tab's identifier) as its row's click does, at its root. False when absent.
    private func openMacPlace(_ identifier: String) -> Bool {
        guard let root = view.window.flatMap({ AppRoot.tabs($0) }) ?? MainTabController.current,
              let tab = root.placedTabs.first(where: { $0.tabBarItem.accessibilityIdentifier == identifier }) else { return false }
        if let split = root.split { split.switchPlace(to: tab) { root.pick(tab) } } else { root.pick(tab) }
        (tab as? UINavigationController)?.popToRootViewController(animated: false)
        return true
    }
    #endif

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
        // [Mac AAA 2026-11-16] (tools T21) The two steps were centred lines of different lengths, so their symbols
        // stood 9 pt apart and their words started on two edges. Now the space after the narrower symbol is widened by the
        // difference (kerning), so the words start on one edge, and the shorter step's last letter by what makes it as wide as the
        // longer one, so both centre as one block with their symbols in one column. Only kerning: a drawn spacer or a
        // re-drawn symbol (tried) shifted the lines off the sentence's centre.
        let images = steps.map { UIImage(systemName: $0.symbol, withConfiguration: symbol)?.withTintColor(HQPalette.tint, renderingMode: .alwaysOriginal) }
        let slot = ceil(images.compactMap { $0?.size.width }.max() ?? 0)
        var lines: [NSMutableAttributedString] = []
        for (step, image) in zip(steps, images) {
            let line = NSMutableAttributedString()
            if let image {
                line.append(NSAttributedString(attachment: NSTextAttachment(image: image)))
                // (On the space after it: kerning on the symbol itself is not drawn.)
                line.append(NSAttributedString(string: "\u{2002}", attributes: [.font: font, .kern: slot - image.size.width]))
            }
            line.append(NSAttributedString(string: step.words, attributes: [.font: font, .foregroundColor: colour]))
            lines.append(line)
        }
        let size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let widths = lines.map { $0.boundingRect(with: size, options: [.usesLineFragmentOrigin], context: nil).width }
        let widest = widths.max() ?? 0
        for (line, width) in zip(lines, widths) {
            if widest - width >= 0.5, line.length > 0 {
                line.addAttribute(.kern, value: widest - width, range: NSRange(location: line.length - 1, length: 1))
            }
            text.append(NSAttributedString(string: "\n", attributes: [.font: font.withSize(font.pointSize * 0.5)]))
            text.append(line)
            text.append(NSAttributedString(string: "\n", attributes: [.font: font]))
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
                    // [Mac UI check 2026-11-13] The open file's card is the list's soft mark on its own edge: the tint
                    // ring it also wore read heavy beside every other selection.
                    background.backgroundColor = state.isSelected ? mark : HQPalette.cellPressed
                }
                cell.backgroundConfiguration = background
                return
            }
            if DeviceWord.isMac { cell.backgroundConfiguration = MacListFocus.background(cell, state); return }   // [mac] Stress test 2026-10-28 #54
            #endif
            if Theme.isDesktop { cell.backgroundConfiguration = DesktopLayout.rowBackground(state); return }
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
        scheduleOppositeModePrewarm()
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
        scheduleOppositeModePrewarm()
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
        showPages()
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
        drawnThemeKey = HTMLPageSheet.themeKey(traitCollection)
        dataSource.apply(snapshot, animatingDifferences: animated && !HQMotion.reduced)
        relayGridIfChanged()
        scheduleOppositeModePrewarm()
        listShowsState = shown.isEmpty
        if shown.isEmpty != paneListIsEmpty {
            paneListIsEmpty = shown.isEmpty
            NotificationCenter.default.post(name: DetailPlaceholderViewController.listStateChanged, object: self)
        }
        updateBarItems(extra: tilesBarItems())
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
        drawnThemeKey = HTMLPageSheet.themeKey(traitCollection)
        dataSource.apply(snapshot, animatingDifferences: animated && !HQMotion.reduced)
        refreshCountedHeads()
        restoreMark()
        relayGridIfChanged()
        scheduleOppositeModePrewarm()
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

    /// Pre-warms locally cached page tiles in the opposite light/dark mode once the current view settles.
    private func scheduleOppositeModePrewarm() {
        prewarmTask?.cancel()
        guard viewIfLoaded?.window != nil, ArtifactPins.view != .list else { return }
        prewarmTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled, self.viewIfLoaded?.window != nil, !PageSnapshots.shared.isBusy else { return }
            let pins = self.pinnedOnly ? self.visiblePins() : Array(self.visiblePins().prefix(Self.pinTilesOnArtifacts))
            self.pinPictures.prewarmOppositeMode(pins, traits: self.traitCollection) { self.pinPictureShape($0) }
        }
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
        UIView.animate(withDuration: HQMotion.move, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
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
                var button = UIButton.Configuration.hqMacPush(or: .hqFilled(), capsule: true)
                // [Mac AAA 2026-11-16] New Tile is the page's one primary action: the Mac's accent push button (as
                // Terminal's Turn On), not a grey twin of Open Artifacts under it.
                if DeviceWord.isMac, services != nil { button = MacPush.configuration(.prominent) }
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
        stateMarginsSize = collectionView.bounds.size
        return margins
    }
    /// [mac] The list size the state cell was last laid out for: a resize lays it out again. The width too (Mac pass
    /// round 3): Tiles empty, a chat opened beside it narrowed the list, and the state kept the wide list's side margins,
    /// which left it no room at all: the column went blank, New Tile with it.
    private var stateMarginsSize: CGSize = .zero

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if pinnedOnly { pagesHeader.layout() }
        if barFilterHost, dataSource != nil { placeBarFilter() }
        // [mac] Stress test 2026-10-28 #9: the window grew or shrank under an empty state; centre it again.
        guard DeviceWord.isMac, let collectionView, let dataSource,
              abs(collectionView.bounds.height - stateMarginsSize.height) > 1
                || abs(collectionView.bounds.width - stateMarginsSize.width) > 1 else { return }
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(.state) else { return }
        stateMarginsSize = collectionView.bounds.size
        snapshot.reconfigureItems([.state])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func countText(shown: Int, total: Int) -> String? {
        // Owner 2026-11-17 (Mac calls Q5): no count line under the list on the Mac ("14 items"); the headings count
        // (`countedHead`). The iPhone and iPad keep theirs.
        guard total > 0, !DeviceWord.isMac else { return nil }
        let noun = total == 1 ? "item" : "items"
        return query.isEmpty ? "\(total) \(noun)" : "\(shown) of \(total) \(noun)"
    }

    /// Owner 2026-11-17 (Mac calls Q5): with the count line under the list gone, the Mac's Images and day headings
    /// say how many they hold, as Jobs' do ("Today 10": the name, then the count in the heads' count ink; the Desktop
    /// Look's "TODAY · 10"). Nil for any other heading, and on the iPhone and iPad.
    private func countedHead(_ section: Section) -> NSAttributedString? {
        guard DeviceWord.isMac, !pinnedOnly else { return nil }
        let name: String, count: Int
        switch section {
        case .images: name = "Images"; count = visibleImages.count
        case .day(let day): name = day; count = dataSource.snapshot().numberOfItems(inSection: section)
        default: return nil
        }
        guard count > 0 else { return nil }
        if Theme.isDesktop {
            return NSAttributedString(string: "\(name) · \(count)".uppercased(), attributes: DesktopLayout.labelAttributes())
        }
        let head = NSMutableAttributedString(string: name, attributes: [.font: MacType.sectionHeader, .foregroundColor: HQPalette.label2])
        head.append(NSAttributedString(string: " \(count)", attributes: [.font: HQFont.preferred(.subheadline),
                                                                         .foregroundColor: HQPalette.headCount()]))
        return head
    }

    /// The headings' counts follow the list: a snapshot never reconfigures its headers.
    private func refreshCountedHeads() {
        guard DeviceWord.isMac, !pinnedOnly else { return }
        for path in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: UICollectionView.elementKindSectionHeader) {
            guard let header = collectionView.supplementaryView(forElementKind: UICollectionView.elementKindSectionHeader, at: path)
                    as? UICollectionViewListCell,
                  let section = dataSource.sectionIdentifier(for: path.section), let head = countedHead(section),
                  var content = header.contentConfiguration as? UIListContentConfiguration,
                  content.attributedText != head else { continue }
            content.attributedText = head
            header.contentConfiguration = content
        }
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
        return opens(dataSource.itemIdentifier(for: indexPath))
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        guard DeviceWord.isMac else { return true }
        return self.collectionView(collectionView, shouldSelectItemAt: indexPath)
    }

    /// Whether an item does something when chosen (a picture, row, tile or link; not the empty state or a count).
    private func opens(_ item: Item?) -> Bool {
        switch item {
        case .image?, .row?, .unavailableRow?, .showAllImages?, .unavailableToggle?, .pin?, .pinRow?, .allPins?, .making?: return true
        default: return false
        }
    }

    /// [tiles] The tile-being-made row isn't a keyboard focus stop: after the New Tile sheet (typed into) closes, focus
    /// landed on it and drew it tint-filled.
    /// [tiles] Mac pass round 6: nor is anything that doesn't open. The empty Tiles page in the light look stood on a
    /// grey block the height of its "No Tiles Yet" state, top to bottom of it: the list's first focus stop was the state
    /// itself, drawn focused.
    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        let item = dataSource.itemIdentifier(for: indexPath)
        if case .making? = item { return false }
        return opens(item)
    }

    /// The Unavailable group's arrow: right when folded, down when open.
    static func unavailableArrowTurn(open: Bool) -> CGAffineTransform {
        open ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
    }

    /// [Mac AAA 2026-11-16] The Mac's Unavailable head, as Sessions' folding captions: "Unavailable ⌄" open,
    /// "Unavailable › 1" folded (the caret in the third grey, the count after it).
    static func unavailableHead(count: Int, open: Bool) -> NSAttributedString {
        let head = NSMutableAttributedString(string: "Unavailable", attributes: [.font: MacType.sectionHeader, .foregroundColor: HQPalette.label2])
        let caretFont = HQFont.preferred(.caption1).pagesWeight(.semibold)
        if let caret = UIImage(systemName: open ? "chevron.down" : "chevron.right",
                               withConfiguration: UIImage.SymbolConfiguration(font: caretFont))?.withTintColor(HQPalette.label3, renderingMode: .alwaysOriginal) {
            let attachment = NSTextAttachment(image: caret)
            // On the words' middle, as the caret sits beside "Recent".
            let lift = (MacType.sectionHeader.capHeight - caret.size.height) / 2
            attachment.bounds = CGRect(x: 0, y: lift.rounded(), width: caret.size.width, height: caret.size.height)
            head.append(NSAttributedString(string: "  "))
            head.append(NSAttributedString(attachment: attachment))
        }
        if !open {
            head.append(NSAttributedString(string: "  \(count)", attributes: [.font: HQFont.preferred(.subheadline), .foregroundColor: HQPalette.headCount(phone: HQPalette.label3)]))
        }
        return head
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
            reload(animated: true)   // the toggle row is drawn again there (its arrow turns)
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
        parameters.visiblePath = UIBezierPath(roundedRect: picture, cornerRadius: PinTileView.radius)
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
        // [dashboard] A tile held over another page's name goes onto that page: the band's drop (`DashboardPagesHeader`).
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

    func collectionView(_ collectionView: UICollectionView, dropSessionDidExit session: UIDropSession) { dropSlot = nil }
    func collectionView(_ collectionView: UICollectionView, dropSessionDidEnd session: UIDropSession) { dropSlot = nil }

    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
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
        if pin.isPage, tileHasChat(pin) {
            // [tile-chats] A tile's chat is in no list: Open Chat, beside Open.
            let tileChat = UIAction(title: "Open Chat", image: UIImage(systemName: "bubble.left.and.bubble.right")) { [weak self] _ in
                self?.openChat(ofTile: pin.id)
            }
            tileChat.accessibilityIdentifier = "tile.open-chat"
            first.append(tileChat)
        } else if !pin.sessionId.isEmpty {
            first.append(chat)
        }
        if let shareImage = shareTileAsImageAction(pin, anchor: anchor) { first.append(shareImage) }
        first.append(share)
        if let save = saveAction(record, anchor: anchor) { first.append(save) }
        var groups = [UIMenu(options: .displayInline, children: first + [copy])]
        // [tiles] How often it's updated (a page a job rewrites), and its name.
        var tile: [UIMenuElement] = []
        if pin.isPage {
            tile.append(tileUpdatesMenu(pin))
            tile.append(changeTileAction(pin))
            tile.append(duplicateTileAction(pin))
            tile.append(versionsAction(pin))
        }
        if let maker = TileMaker.working(on: pin.id, accountId: store.account.id) {
            let stop = UIAction(title: "Stop Updating", image: UIImage(systemName: "stop.circle"), attributes: .destructive) { [weak maker] _ in
                PagesHaptics.selection()
                maker?.cancel()
            }
            stop.accessibilityIdentifier = "tile.stop"
            tile.append(stop)
        }
        tile.append(TileUpdates.renameAction(pin, pins: pins, from: self))
        tile.append(FavoritesPinAction.dashboardTileAction(pin, displayName: pins.name(pin), from: self))
        if let home = addToHomeScreenAction(pin) { tile.append(home) }   // [tile-widgets]
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
        buildTileUpdatesMenu(pin, inline: false, host: self)
    }

    /// [tiles] While the Tiles page shows: the tiles' jobs read each minute (each 15 s while one runs), their marks kept
    /// current, and a tile whose job has just run drawn again at once (owner 2026-11-03: "redraw the moment the job
    /// finishes").
    func watchTiles(_ on: Bool) {
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
        let (marks, ran, modelFailed) = await TileUpdates.shared.refresh(pages, accountId: store.account.id, client: services?.gateway)
        if !ran.isEmpty { AppLog.trace("pages", "\(ran.count) tile(s) redrawn after their job ran") }
        // [tile-models] A tile's model couldn't be put on its job: said once, as a menu's change that failed is.
        if modelFailed != nil, view.window != nil {
            PagesHaptics.error()
            PagesHUD.show("Couldn’t Change a Tile’s Model", symbol: "exclamationmark.triangle", from: self)
        }
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
    func redrawTile(_ id: String) {
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
        live.isWorking = { [weak self] id in
            guard let self else { return false }
            return TileMaker.working(on: id, accountId: self.store.account.id) != nil
        }
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
        Self.sendFromTile(pins.pins.first { $0.id == id }, prompt, services: services, accountId: store.account.id, page: self,
                          from: host, ended: ended)
    }

    /// The same, for a tile shown elsewhere ([favorites-live-tiles] a Dashboard tile on Favorites): `page` is where the
    /// tile shows (`TileMaker`'s page).
    static func sendFromTile(_ pin: ArtifactPin?, _ prompt: String, services: PagesServices?, accountId: String,
                             page: UIViewController?, from host: UIViewController?, ended: (() -> Void)? = nil) -> Bool {
        guard let services else { return false }
        func refuse(_ words: String) -> Bool {
            PagesHaptics.error()
            if let host { PagesHUD.show(words, symbol: "exclamationmark.triangle", from: host) }
            return false
        }
        guard !services.readOnlyGateway else { return refuse("This gateway is read-only.") }
        guard let pin, let path = pin.gatewayPath else {
            return refuse("Couldn’t Send to This Tile")
        }
        guard let bot = services.bots.first(where: { $0.id == pin.profile }) else { return refuse("This Tile’s Bot Is Gone") }
        let chat = tileOwnChat(pin, bot: bot, services: services)
        let maker = TileMaker.act(pin, path: path, bot: bot, prompt: prompt, accountId: accountId, chat: chat, from: page)
        maker.ended = ended
        return true
    }

    /// [tile-widgets] A Tile widget's tap (`WidgetRouter`): the tile whose widget key is `widgetKey` opens as a tap on
    /// it here opens it. False when no pinned tile has that key (unpinned since): the page stays as it is.
    @discardableResult
    func openTile(widgetKey: String) -> Bool {
        guard let pin = pins.pins.first(where: { TileWidgetIndex.key($0.id) == widgetKey }) else { return false }
        if presentedViewController != nil { presentedViewController?.dismiss(animated: false) }
        Haptics.play(.soft)
        open(pin)
        return true
    }

    /// [favorites-live-tiles] A Dashboard tile on Favorites: the tile opens here as a tap on it here opens it (the
    /// Dashboard's own open: its page live, its menu, Change…, Versions and its chat). False when it isn't pinned now.
    @discardableResult
    func openTile(pinId id: String) -> Bool {
        guard let pin = pins.pins.first(where: { $0.id == id }) else { return false }
        if presentedViewController != nil { presentedViewController?.dismiss(animated: false) }
        Haptics.play(.soft)
        open(pin)
        return true
    }

    /// [tile-widgets] Add to Home Screen…, from a tile's hold menu or the opened tile's (iPhone and iPad).
    func addToHomeScreenAction(_ pin: ArtifactPin, from host: (() -> UIViewController?)? = nil) -> UIAction? {
        guard TileWidgetWriter.enabled, pin.isPage, pin.gatewayPath != nil else { return nil }
        let action = UIAction(title: "Add to Home Screen…", image: UIImage(systemName: "apps.iphone.badge.plus")) { [weak self] _ in
            guard let self else { return }
            AddToHomeScreenSheet.present(pin: pin, name: self.pins.name(pin), from: host?() ?? self)
        }
        action.accessibilityIdentifier = "tile.add-to-home-screen"
        return action
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
                let updates = self.buildTileUpdatesMenu(pin, inline: true, host: host)
                // [tiles-v2] Keep context: Change…, Duplicate… and Versions present directly over the opened tile,
                // which shows "Changing…" and reloads in place when done.
                let change = self.changeTileAction(pin, presenter: { [weak host] in host }, before: { [weak self, weak host] start in
                    guard let self, let host else { start(); return }
                    if TileMaker.working(on: pin.id, accountId: self.store.account.id)?.isChange == true {
                        host.dismiss(animated: true, completion: start)
                    } else {
                        start()
                    }
                })
                let duplicate = self.duplicateTileAction(pin, presenter: { [weak host] in host })
                let versions = self.versionsAction(pin, presenter: { [weak host] in host })
                // [tile-widgets] Add to Home Screen… beside its other tile actions, the sheet over the opened tile.
                var actions: [UIMenuElement] = [change, duplicate, versions]
                if let shareImg = self.shareTileAsImageAction(pin, presenter: host) { actions.append(shareImg) }
                if let home = self.addToHomeScreenAction(pin, from: { [weak host] in host }) { actions.append(home) }
                return UIMenu(children: [updates, UIMenu(options: .displayInline, children: actions)])
            })
            // [live-tiles] Its buttons go to the tile's bot, as on the Tiles page (a page opened from Tiles has no chat).
            tile.botName = PagesNames.botName(pin.profile, bots: services?.bots ?? [])
            tile.send = { [weak self] prompt, host, ended in self?.sendFromTile(pin.id, prompt, from: host, ended: ended) ?? false }
            tile.id = pin.id   // [tiles] read again in place when its job runs
            // [tile-chats] Its chat on a button of the bar: the tile closes and the chat opens over Tiles.
            if tileHasChat(pin) {
                tile.openChat = { [weak self] host in
                    host.dismiss(animated: true) { self?.openChat(ofTile: pin.id) }
                }
            }
            // [tiles] The sheet opens in the page's own colour, read off the tile's picture: no black sheet with white bar
            // words before a white page draws (Mac pass 2026-11-14).
            tile.backdrop = pinPictures.shown(pin).flatMap(PinPictures.edgeColor)
            // [tiles] At once, from the copy the Tiles page drew; read again behind it (HTMLPageSheet.openTile).
            HTMLPageSheet.openTile(path: path, name: pin.label, context: context, tile: tile, from: self)
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
            Self.point(sheet, item: item, anchor: anchor, in: host)
            host.present(sheet, animated: true)
            return
        }
        fetchGatewayFile(record, presenter: presenter, verb: "Share") { [weak anchor] url, host in
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            Self.point(sheet, item: item, anchor: anchor, in: host)
            host.present(sheet, animated: true)
        }
    }

    /// The share popover's arrow: the bar button, else the row (its whole frame) when inside `host`'s hierarchy, else `host`'s view.
    func point(_ sheet: UIViewController, item: UIBarButtonItem?, anchor: UIView?, in host: UIViewController? = nil) {
        Self.point(sheet, item: item, anchor: anchor, in: host ?? self)
    }

    static func point(_ sheet: UIViewController, item: UIBarButtonItem?, anchor: UIView?, in host: UIViewController) {
        guard let popover = sheet.popoverPresentationController else { return }
        if let item { popover.sourceItem = item; return }
        if let anchor, anchor.window != nil, anchor.isDescendant(of: host.view) {
            popover.sourceView = anchor
            popover.sourceRect = anchor.bounds
        } else {
            popover.sourceView = host.view
            popover.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
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
            let tileShape = RoundedRectangle(cornerRadius: rounded ? HQShape.radius(10, .card) : 0, style: .continuous)
            ZStack {
                Rectangle().fill(Color.hqFill3)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: geo.size.width, height: geo.size.height).clipped()
                } else if failed {
                    Image(systemName: hosted ? "globe" : "photo.badge.exclamationmark").font(Font.hq(.title2)).foregroundStyle(Color.hqLabel3)
                }
            }
            .clipShape(tileShape)   // Mac polish #118: the look's 4 pt
            .hqPointerFill(tileShape)
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
    /// [tiles] A tile's mark (failed, late, paused, updating), as its Grid tile and card wear it.
    var health: TileJobs.Health = .none
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
                        .font(Font.hq(DeviceWord.isMac ? .callout : .body))   // [type] Mac: every list's row title
                        .foregroundStyle(missing ? Color.hqLabel2 : Color.hqLabel)
                        .lineLimit(large ? 3 : (record.repeatBadge == nil || card || edged ? 1 : 2))   // [morepages] the name wraps before the badge squeezes it
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if edged, let when = edge?.when, !when.isEmpty {
                        Text(when).font(Font.hq(.footnote)).monospacedDigit().foregroundStyle(Color.hqLabel2).lineLimit(1).fixedSize()
                    }
                    if card, let badge = record.repeatBadge { badgeText(badge) }
                }
                let second = edged ? (edge?.chat ?? "") : subtitle
                if card, !large, let chat = edge?.chat, !chat.isEmpty, chat != second {
                    // [Mac UI check 2026-11-13] A card in the Mac's narrow grid: the line under the name has the card's
                    // whole width (the count rides the name's line), and when the chat and its time don't both fit the
                    // time goes first ("Project notes · 10…" said neither).
                    ViewThatFits(in: .horizontal) {
                        secondLine(second, large: large)
                        secondLine(chat, large: large)
                    }
                } else if !second.isEmpty {
                    secondLine(second, large: large)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // [morepages] "×3": this chat named the file or link three times (3x-morepages §2).
            if !card, let badge = record.repeatBadge {
                badgeText(badge)
            }
            // Mac polish #117: the pin after the count, beside ⋯, so the pins stand in one column whether a row has a
            // count or not.
            TileHealthMark(health: health)
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

    private func secondLine(_ words: String, large: Bool) -> some View {
        Text(words)
            .font(Font.hq(.footnote))
            .foregroundStyle(Color.hqLabel2)
            .lineLimit(large ? 3 : 1)
    }

    private func badgeText(_ badge: String) -> some View {
        Text(badge)
            .font(Font.hq(.footnote).monospacedDigit())
            .foregroundStyle(Color.hqLabel2)
            .fixedSize()
            .accessibilityLabel(record.repeatSpoken ?? badge)
            .accessibilityIdentifier("artifact-repeats")
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
    private var stripHost: UIViewController?
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
        stripHost = nil
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
            #if targetEnvironment(macCatalyst)
            MacTitleBarClick.markInteractive(host.view)
            #endif
            stack.addArrangedSubview(host.view)
            strip = host.view
            stripHost = host
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
            control.setTitleTextAttributes([.font: DeviceWord.isMac ? font : font.pagesWeight(.semibold)], for: .selected)   // [type] Mac: the thumb shows the choice
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

    /// [tile-widgets] Every page artifact pinned, oldest first so the newest ends up first (once they have loaded).
    func debugPinPages(tries: Int = 15) {
        let pages = records.values.filter { ["html", "htm"].contains(ArtifactFiles.fileExtension($0.value)) }
        guard !pages.isEmpty else {
            if tries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.debugPinPages(tries: tries - 1) } }
            return
        }
        debugPin(pages.map(\.label).sorted().reversed())
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
