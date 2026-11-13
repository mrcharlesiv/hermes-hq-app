// The Kanban tab (docs/spec/1x-pages.md §4.3): the board's name (a menu of boards), the status chips (Blocked first),
// and the chosen status's tasks as an inset group. Tap → the task sheet; hold → Move To / Assign To / Archive / Delete;
// swipes: the quick move leading, More / Archive / Delete trailing. Writes are optimistic (the store puts back only a
// failed task). Styled in its first frame, light and dark (`MEM/kanban-css-preload.md`).

import SwiftUI
import UIKit

final class KanbanViewController: UIViewController, UICollectionViewDelegate, UISearchResultsUpdating {
    /// [morepages] Search behind the bar's magnifier (3x-morepages §5).
    private var searchCapsule: PageBarCapsule?
    private nonisolated enum Section: Hashable { case top, chips, group(String), state }
    private nonisolated enum Item: Hashable { case board, chip(String), task(String), empty(String), status }

    let store: KanbanStore
    private weak var services: PagesServices?
    private let makeChat: (any ChatSessionModel) -> UIViewController
    private(set) var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var notices: PageNoticeHost!
    private var query = ""
    private var tasks: [String: KanbanTask] = [:]
    private var rowModels: [String: KanbanRowModel] = [:]
    private var chipCounts: [String: Int] = [:]
    private var chosen = "blocked"
    /// The shown groups: `key` is the section's identity (stable while its count changes, so a move or a poll never
    /// deletes and re-inserts the section), `heading` what its header says.
    private var groups: [(key: String, heading: String, ids: [String])] = []
    private var observing = false
    private var lastChosen: String?
    private var lastBoard: String?
    private var retrying = false
    /// What the board button and each chip last drew: a cell is reconfigured only when that changes (a menu that
    /// is open must not be replaced under the finger).
    private var boardSignature = ""
    private var chipSignatures: [String: String] = [:]
    private var shownChip: String?
    /// A chip still to bring into view once its row has been laid out (the first layout comes after the first apply).
    private var chipToReveal: String?
    private var chipRevealTries = 0
    /// item 20: the chip row's trailing edge read as clipped, not more to scroll to; a short fade shows there's more.
    private let chipFade = HorizontalEdgeFade()

    /// [mac-tools] Owner 2026-11-09 ("Yes go ahead with what you sketched"): on the Mac, Kanban is a board of columns
    /// across the window (`KanbanBoardView`), its board picker in the bar beside the title. The chips and the one list
    /// below stay the iPhone's and the iPad's. The collection view is still here on the Mac: it shows Loading, Couldn't
    /// Load and No Tasks Yet while there is no board to draw.
    static var boardMode: Bool { DeviceWord.isMac }
    private var boardView: KanbanBoardView?
    private var barBoardButton: UIButton?
    /// The page is the board (the window gives it the whole width, and most of it beside an open task).
    var isBoard: Bool { boardView != nil }
    private static let live = NSHashTable<KanbanViewController>.weakObjects()

    /// Every Kanban page marks the card of the task the right pane shows (the tab's and one opened from Tools).
    static func markOnShow(_ id: String?, keepsSelection: Bool) {
        for page in live.allObjects { page.markOnShow(id, keepsSelection: keepsSelection) }
    }

    init(store: KanbanStore, services: PagesServices, makeChat: @escaping (any ChatSessionModel) -> UIViewController) {
        self.store = store
        self.services = services
        self.makeChat = makeChat
        super.init(nibName: nil, bundle: nil)
        if DeviceWord.isMac { title = "Kanban" } else { PageChrome.applyListHeader(to: self, title: "Kanban") }
    }

    /// [mac] Stress test 2026-10-28 #23, #56: pushed from More, Kanban is a More page: the small Title Case title the
    /// other pushed pages have (not the tab's "KANBAN" label) on their grey. As a tab root it keeps the list header and
    /// the page colour, as Bots, Sessions and Jobs. Decided once the page is in its stack, as Artifacts does.
    private var pushedOnMac: Bool {
        guard DeviceWord.isMac else { return false }
        // [mac] Stress test 2026-10-28 #23 (round 2): More's rows open in the right pane as that pane's first page, so
        // "first in its stack" missed them and the page kept "KANBAN" on white. More says so when it makes the page.
        if openedFromMore { return true }
        guard let navigationController else { return false }
        return navigationController.viewControllers.first !== self
    }

    /// Set by More's Kanban row (`PagesTabs.makeKanban(fromMore:)`) before the page loads.
    var openedFromMore = false

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        Self.live.add(self)
        let board = Self.boardMode
        if board {
            installBoardBar()   // [mac-tools]
        } else if DeviceWord.isMac && !pushedOnMac {
            PageChrome.applyListHeader(to: self, title: "Kanban")   // [mac] #23
        }
        if pushedOnMac && !board { navigationItem.largeTitleDisplayMode = .never }
        // The app's page colour, as Bots, Sessions, Jobs and the chat (verify round 1: Kanban alone was grouped grey).
        // [mac] Stress test 2026-10-28 #23: pushed from More, the grouped grey of the other More pages.
        // [mac-tools] The board is the page colour wherever it was opened from: its columns are the grey on it.
        let background = pushedOnMac && !board ? HQPalette.groupedPage : HQPalette.page
        view.backgroundColor = background
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = background
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.accessibilityIdentifier = "kanban.list"
        view.addSubview(collectionView)
        if !pushedOnMac || board { ListBarAppearance.pinTitle(in: self, softEdgeAround: collectionView) }   // owner 2026-11-01: every tab's top
        // [backdrop-cards] Owner 2026-11-12: the board too ("Yes I think so"), as Jobs and the other pages.
        PageBackdrop.install(in: self, clearing: [collectionView])
        if board { installBoard() }
        notices = PageNoticeHost(in: view)
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in self?.pulled() }, for: .valueChanged)
        collectionView.hqInstallRefresh(refresh)
        let capsule = PageBarCapsule.search(on: self, page: "kanban", placeholder: "Search Tasks", updater: self)   // [morepages] §5
        searchCapsule = capsule
        let about = UIBarButtonItem(image: UIImage(systemName: "info.circle"), primaryAction: UIAction { [weak self] _ in self?.showAbout() })
        about.accessibilityLabel = "How Kanban Works"
        let add = UIBarButtonItem(image: UIImage(systemName: "plus"), primaryAction: UIAction { [weak self] _ in self?.newTask() })
        add.accessibilityLabel = "New Task"
        add.accessibilityIdentifier = "kanban.new"
        // Trailing edge inward: New Task · Search · How Kanban Works.
        navigationItem.rightBarButtonItems = [add, capsule.searchItem, about].compactMap { $0 }
        configureDataSource()
        // [a11y] The chips' pill height follows the text size: on a live change the chips are drawn again at the
        // new height and the row's layout re-read.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: KanbanViewController, _) in
            controller.chipSignatures = [:]
            var snapshot = controller.dataSource.snapshot()
            let chips = snapshot.itemIdentifiers.filter { if case .chip = $0 { return true } else { return false } }
            guard !chips.isEmpty else { return }
            snapshot.reconfigureItems(chips)
            controller.dataSource.apply(snapshot, animatingDifferences: false)
            controller.collectionView.collectionViewLayout.invalidateLayout()
        }
        claimStore()
        store.prepare()
        reload(animated: false)
    }

    /// The store's callbacks go to the page on screen (verify round 2: a second Kanban page on the same store — tab 3
    /// and one still on More's stack — left the other snapping cards back with no notice).
    private func claimStore() {
        store.onChange = { [weak self] in self?.setNeedsReload() }
        store.onWriteFailed = { [weak self] reason in
            PagesHaptics.error()
            self?.notices.show(reason, seconds: 4)
        }
        store.onNotice = { [weak self] text in
            // [#134] the read-only refusal is the Jobs page's lock HUD; a locked status keeps its line of text.
            if text == JobsStore.readOnlyNotice { KanbanFeedback.readOnly(from: self) } else { self?.notices.show(text) }
        }
        store.onWriteSucceeded = { PagesHaptics.success() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        searchCapsule?.restoreIfTyped()   // [morepages]
        claimStore()
        if !observing { observing = true; store.setVisible(true) }
        reload(animated: false)
        // [desktoplook2] the task groups are outlined boxes in the look (not the chips or the board button)
        DesktopListOutliner.attach(to: collectionView)?.boxes = { [weak self] index in
            if case .group? = self?.dataSource?.sectionIdentifier(for: index) { return true }
            return false
        }
        for path in collectionView.indexPathsForSelectedItems ?? [] where dataSource.itemIdentifier(for: path) != onShowTask.map(Item.task) {
            collectionView.deselectItem(at: path, animated: animated)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if chipToReveal != nil { revealChosenChip(animated: false) }
        if let row = chipRowScrollView() { chipFade.attach(to: row) }   // item 20
        // [mac] Stress test 2026-10-28 #9: the window grew or shrank under an empty status; centre it again.
        if DeviceWord.isMac, let collectionView, let dataSource, abs(collectionView.bounds.height - emptyTopHeight) > 1 {
            var snapshot = dataSource.snapshot()
            let empties = snapshot.itemIdentifiers.filter { if case .empty = $0 { return true } else { return false } }
            if !empties.isEmpty {
                emptyTopHeight = collectionView.bounds.height
                snapshot.reconfigureItems(empties)
                dataSource.apply(snapshot, animatingDifferences: false)
            }
        }
    }

    /// [mac] Stress test 2026-10-28 #9: an empty status stood at the top under the chips while every other page's
    /// state sits `MacInset.emptyLift` above the middle. On the Mac its top padding brings it there (as Artifacts does).
    private func emptyTop(estimate: CGFloat) -> CGFloat {
        guard DeviceWord.isMac, let collectionView, collectionView.bounds.height > 0 else { return 40 }
        let visible = collectionView.bounds.height - collectionView.adjustedContentInset.top - collectionView.adjustedContentInset.bottom
        // The board button and the chips over it: where the chips' section ends.
        var above = isBoard ? 0 : HQFont.scaled(100)   // [mac-tools] nothing stands over the state on the board
        // [mac] Stress test 2026-10-28 round 6: with no chips on the board (the Mac shows none under the Board button
        // there), the 100 pt guess was about twice the Board row, so the state stood about 42 % down the page instead
        // of `MacInset.emptyLift` above the middle. The Board row's own end is used when there are no chips.
        let snapshot = dataSource?.snapshot()
        for section in [Section.chips, .top] {
            guard let index = snapshot?.indexOfSection(section), index < collectionView.numberOfSections,
                  collectionView.numberOfItems(inSection: index) > 0,
                  let last = collectionView.collectionViewLayout.layoutAttributesForItem(
                      at: IndexPath(item: collectionView.numberOfItems(inSection: index) - 1, section: index)) else { continue }
            above = last.frame.maxY + 14
            break
        }
        emptyTopHeight = collectionView.bounds.height
        return max(40, (visible - estimate) / 2 - MacInset.emptyLift - above)
    }
    private var emptyTopHeight: CGFloat = 0

    /// [mac] Stress test 2026-10-28 round 6: `KanbanEmptyView`'s height from its own parts (symbol, title, line, New
    /// Task…), in place of a fixed 190 / 140 that was about 40 pt more than the state and lifted it further.
    private static func emptyEstimate(button: Bool) -> CGFloat {
        guard DeviceWord.isMac else { return button ? 190 : 140 }
        let line = MacType.emptyBody.lineHeight
        let parts = HQFont.scaled(34) + 4 + 8 + MacType.emptyTitle.lineHeight + 8 + line
        return (parts + (button ? 8 + 8 + line + 14 : 0)).rounded()
    }

    /// The chip row's own horizontal scroller (an orthogonal section's cells sit in one, nested under the main
    /// collection view); nil before the chips' first layout, and on the Mac, where the row wraps instead of scrolling.
    private func chipRowScrollView() -> UIScrollView? {
        guard !Self.chipsWrap, let path = dataSource.snapshot().itemIdentifiers(inSection: .chips).first.flatMap(dataSource.indexPath(for:)),
              let cell = collectionView.cellForItem(at: path), let row = cell.superview as? UIScrollView, row !== collectionView else { return nil }
        return row
    }

    /// Centres the chosen chip in the chip row. `scrollToItem` on an orthogonal section lands short while the chips'
    /// widths are estimates, and a chip off screen has no cell, so this sets the row's own scroller (a chip cell's
    /// superview): first from the layout's estimate, then again from the real cell once it is on screen.
    private func revealChosenChip(animated: Bool) {
        // [mac] Wrapped chips are all in view: nothing to scroll.
        if Self.chipsWrap { chipToReveal = nil; return }
        guard let status = chipToReveal, let path = dataSource.indexPath(for: .chip(status)) else { return }
        collectionView.layoutIfNeeded()
        let shown = collectionView.indexPathsForVisibleItems.filter { $0.section == path.section }.sorted()
        guard let anchorPath = shown.first, let anchor = collectionView.cellForItem(at: anchorPath),
              let row = anchor.superview as? UIScrollView, row !== collectionView, row.bounds.width > 0,
              let anchorLayout = collectionView.layoutAttributesForItem(at: anchorPath) else { return }
        let cell = collectionView.cellForItem(at: path)
        let frame: CGRect
        if let cell {
            frame = cell.frame
        } else if let layout = collectionView.layoutAttributesForItem(at: path) {
            frame = layout.frame.offsetBy(dx: anchor.frame.minX - anchorLayout.frame.minX, dy: 0)
        } else {
            return
        }
        if cell != nil || chipRevealTries >= 3 { chipToReveal = nil } else { chipRevealTries += 1 }
        let inset = row.adjustedContentInset
        let lowest = -inset.left
        let highest = max(lowest, row.contentSize.width + inset.right - row.bounds.width)
        if frame.minX < row.contentOffset.x + 16 || frame.maxX > row.contentOffset.x + row.bounds.width - 16 {
            let x = min(max(frame.midX - row.bounds.width / 2, lowest), highest)
            row.setContentOffset(CGPoint(x: x, y: row.contentOffset.y), animated: animated && cell != nil)
        }
        if chipToReveal != nil { DispatchQueue.main.async { [weak self] in self?.revealChosenChip(animated: false) } }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if observing, presentedViewController == nil { observing = false; store.setVisible(false) }
    }

    // MARK: Layout

    /// [mac] The status chips wrap instead of scrolling sideways (a mouse wheel scrolls the page, not the row).
    static let chipsWrap = DeviceWord.isMac

    private func makeLayout() -> UICollectionViewLayout {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            guard let self, let section = self.dataSource?.sectionIdentifier(for: index) else { return nil }
            switch section {
            case .top, .state:
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(44)))
                let group = NSCollectionLayoutGroup.vertical(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(44)), subitems: [item])
                let s = NSCollectionLayoutSection(group: group)
                // [mac] Stress test 2026-10-28 #53: the board button 16 pt under the bar on the Mac (it touched the bar).
                s.contentInsets = NSDirectionalEdgeInsets(top: section == .top ? MacInset.top(otherwise: 0) : 8, leading: 0, bottom: 0, trailing: 0)
                // [backdrop-cards] The board's button and its status chips are one card on Soft Cards.
                if section == .top { BackdropCards.card(s, on: BackdropCards.on(self), join: self.dataSource?.sectionIdentifier(for: index + 1) == .chips ? .below : []) }
                return s
            case .chips:
                let chipHeight = KanbanChipView.height(for: environment.traitCollection)   // [a11y] grows with the text
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .estimated(90), heightDimension: .absolute(chipHeight)))
                if Self.chipsWrap {
                    // [mac] Mac stress #46: a sideways row only scrolls with Shift and the wheel, so on the Mac the chips
                    // wrap onto as many lines as the column needs (the window is wide; it is one line at most sizes).
                    let line = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(chipHeight)), subitems: [item])
                    line.interItemSpacing = .fixed(8)
                    let s = NSCollectionLayoutSection(group: line)
                    s.interGroupSpacing = 8
                    s.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 20, bottom: 14, trailing: 20)
                    BackdropCards.card(s, on: BackdropCards.on(self), keepWidth: true, join: .above)   // [backdrop-cards]
                    return s
                }
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .estimated(90), heightDimension: .absolute(chipHeight)), subitems: [item])
                let s = NSCollectionLayoutSection(group: group)
                s.orthogonalScrollingBehavior = .continuous
                s.interGroupSpacing = 8
                s.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 20, bottom: 14, trailing: 20)
                BackdropCards.card(s, on: BackdropCards.on(self), keepWidth: true, join: .above)   // [backdrop-cards]
                return s
            case .group:
                var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
                config.headerMode = .supplementary
                config.backgroundColor = .clear
                config.separatorConfiguration.color = HQPalette.separator
                if Theme.isDesktop { config.showsSeparators = false }   // [desktoplook2] the outliner draws the box
                config.itemSeparatorHandler = { _, separator in
                    var s = separator
                    s.bottomSeparatorInsets = NSDirectionalEdgeInsets(top: 0, leading: 62, bottom: 0, trailing: 0)
                    return s
                }
                config.leadingSwipeActionsConfigurationProvider = { [weak self] path in self?.leadingSwipe(path) }
                config.trailingSwipeActionsConfigurationProvider = { [weak self] path in self?.trailingSwipe(path) }
                // [soft-cards] On a card the group's line stands as far under the card's top as the last task over its foot.
                if BackdropCards.on(self) { config.headerTopPadding = 4 }
                let s = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
                s.contentInsets.leading = 20
                s.contentInsets.trailing = 20
                // [backdrop-cards] On Soft Cards the group's line and its rows are one soft card, in place of the
                // board's own card, as far in as every page's (`BackdropCards.side`).
                if BackdropCards.on(self) {
                    s.contentInsets.leading = 0
                    s.contentInsets.trailing = 0
                    BackdropCards.card(s, on: true, header: true)
                    return s
                }
                // UX study #175: in light the card is the page's white with a hairline edge, not a grey fill; the
                // decoration draws it behind the rows (dark keeps the grey card). Reverse: drop this and the clear rows.
                if !Theme.isDesktop {
                    let card = NSCollectionLayoutDecorationItem.background(elementKind: KanbanCardBackground.kind)
                    card.contentInsets = s.contentInsets
                    s.decorationItems = [card]
                }
                return s
            }
        }
        layout.register(KanbanCardBackground.self, forDecorationViewOfKind: KanbanCardBackground.kind)
        BackdropCards.register(in: layout)   // [backdrop-cards]
        return layout
    }

    private func configureDataSource() {
        let boardCell = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, _ in
            guard let self else { return }
            let button = (cell.contentView.subviews.first as? UIButton) ?? Self.makeBoardButton(in: cell)
            self.configureBoardButton(button)
        }
        let chipCell = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, status in
            guard let self else { return }
            let count = self.chipCounts[status] ?? 0, selected = status == self.chosen
            let height = KanbanChipView.height(for: self.traitCollection)
            cell.contentConfiguration = UIHostingConfiguration { KanbanChipView(status: status, count: count, selected: selected, height: height) }
                .margins(.all, 0)
            cell.accessibilityIdentifier = "kanban.chip.\(status)"
        }
        let taskCell = UICollectionView.CellRegistration<SoftCardListCell, String> { [weak self] cell, _, id in
            guard let self, let row = self.rowModels[id] else { return }
            cell.contentConfiguration = UIHostingConfiguration { KanbanRowView(row: row) }.margins(.all, 0)
            cell.accessibilityIdentifier = "kanban-task-\(id)"
            // Verify round 3: the group's card shows on the page colour (the default white card had no edge in light).
            cell.configurationUpdateHandler = { cell, state in
                #if targetEnvironment(macCatalyst)
                if DeviceWord.isMac { cell.backgroundConfiguration = MacSelection.listRow(state); return }   // [mac] Stress test 2026-10-28 #54
                #endif
                if Theme.isDesktop { cell.backgroundConfiguration = DesktopLayout.rowBackground(state); return }   // [desktoplook2]
                var background = UIBackgroundConfiguration.listCell().updated(for: state)
                background.backgroundColor = state.isHighlighted || state.isSelected ? HQPalette.cellPressed : .clear   // #175
                cell.backgroundConfiguration = background
            }
        }
        let emptyCell = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, status in
            guard let self else { return }
            let words = self.query.pgTrim
            let canAdd = !KanbanModel.isLocked(status) && status != "done"
            let top = self.emptyTop(estimate: Self.emptyEstimate(button: canAdd && words.isEmpty))   // [mac] Stress test 2026-10-28 #9
            cell.contentConfiguration = UIHostingConfiguration {
                KanbanEmptyView(status: status, query: words, newTask: canAdd ? { [weak self] in self?.newTask() } : nil, top: top)
            }.margins(.all, 0)
        }
        let statusCell = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, _ in
            guard let self else { return }
            let error = self.store.board == nil ? self.store.boardError : nil
            cell.contentConfiguration = UIHostingConfiguration {
                KanbanStatusView(loading: self.store.loadingBoard, error: error, retrying: self.retrying) { [weak self] in self?.retry() }
            }.margins(.all, 0)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader) { [weak self] header, _, path in
            guard let self, case .group(let key)? = self.dataSource.sectionIdentifier(for: path.section) else { return }
            header.contentConfiguration = self.headerContent(key)
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { cv, path, item in
            switch item {
            case .board: return cv.dequeueConfiguredReusableCell(using: boardCell, for: path, item: "board")
            case .chip(let s): return cv.dequeueConfiguredReusableCell(using: chipCell, for: path, item: s)
            case .task(let id): return cv.dequeueConfiguredReusableCell(using: taskCell, for: path, item: id)
            case .empty(let s): return cv.dequeueConfiguredReusableCell(using: emptyCell, for: path, item: s)
            case .status: return cv.dequeueConfiguredReusableCell(using: statusCell, for: path, item: "status")
            }
        }
        dataSource.supplementaryViewProvider = { cv, _, path in cv.dequeueConfiguredReusableSupplementary(using: header, for: path) }
    }

    private func headerContent(_ key: String) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.header().hqScaled()
        content.text = groups.first { $0.key == key }?.heading ?? ""
        content.textProperties.transform = .none
        content.textProperties.font = HQFont.preferred(.footnote)
        content.textProperties.color = HQPalette.label2
        content.directionalLayoutMargins.leading = 16
        if Theme.isDesktop {   // [desktoplook2] the desktop's label
            // On the 20 pt gutter with the title, the chips and the task box (it sat 16 pt further in).
            content.directionalLayoutMargins.leading = 0
            // A zero margin alone still took the header cell's own 16 pt (the content keeps the larger of the two).
            content.axesPreservingSuperviewLayoutMargins = []
            content.attributedText = NSAttributedString(string: content.text?.uppercased() ?? "", attributes: DesktopLayout.labelAttributes())
        }
        return content.hqMacSectionHeader()   // [mac] Stress test 2026-10-28 #52
    }

    /// A snapshot never reconfigures headers: the count in a status's heading is set again on the ones showing.
    private func refreshHeaders() {
        for path in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: UICollectionView.elementKindSectionHeader) {
            guard let header = collectionView.supplementaryView(forElementKind: UICollectionView.elementKindSectionHeader, at: path)
                    as? UICollectionViewListCell,
                  case .group(let key)? = dataSource.sectionIdentifier(for: path.section) else { continue }
            header.contentConfiguration = headerContent(key)
        }
    }

    // MARK: The Mac's board ([mac-tools])

    /// The bar: "Kanban" leading it, as every place's title does, and the board's pop-up button beside it.
    private func installBoardBar() {
        title = "Kanban"
        navigationItem.largeTitleDisplayMode = .never
        ListBarAppearance.apply(to: navigationItem)
        let label = UILabel()
        label.font = MacType.pageTitle
        label.textColor = HQPalette.label
        label.adjustsFontForContentSizeCategory = true
        label.text = "Kanban"
        label.accessibilityTraits = .header
        label.setContentHuggingPriority(.required, for: .horizontal)
        var config = UIButton.Configuration.plain()
        config.imagePlacement = .trailing
        config.imagePadding = 6
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 9, bottom: 4, trailing: 7)
        config.cornerStyle = .fixed
        config.background.cornerRadius = MacField.radius
        config.background.strokeWidth = 1
        config.background.strokeColor = MacPush.stroke
        config.background.backgroundColor = MacPush.fill
        config.titleLineBreakMode = .byTruncatingMiddle
        let button = UIButton(configuration: config)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityIdentifier = "kanban.board"
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.heightAnchor.constraint(equalToConstant: MacForm.controlHeight).isActive = true
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
        barBoardButton = button
        let stack = UIStackView(arrangedSubviews: [label, button])
        stack.spacing = 12
        stack.alignment = .center
        // As far in as a tab's own title (`MacPlaceTitle`): the bar starts its items 10 pt nearer the edge.
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 0)
        let lead = UIBarButtonItem(customView: stack)
        lead.hidesSharedBackground = true   // words and a pop-up on the bar, not a glass button
        navigationItem.leftBarButtonItem = lead
        navigationItem.titleView = UIView()   // the middle stays empty; `title` still names the page (VoiceOver, Back)
    }

    private func installBoard() {
        let board = KanbanBoardView()
        board.translatesAutoresizingMaskIntoConstraints = false
        board.isHidden = true
        view.addSubview(board)
        NSLayoutConstraint.activate([
            board.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            board.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            board.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            board.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        board.row = { [weak self] id in self?.rowModels[id] }
        board.statusOf = { [weak self] id in self?.tasks[id]?.status }
        board.onOpen = { [weak self] id in self?.openTask(id) }
        board.onMove = { [weak self] id, status in
            guard let self, let task = self.tasks[id] else { return }
            if self.store.readOnlyGateway { KanbanFeedback.readOnly(from: self); return }
            Task { await self.store.move(task, to: status) }
        }
        board.menu = { [weak self] id, source in
            guard let self, let task = self.tasks[id] else { return nil }
            return self.menu(for: task, source: source)
        }
        boardView = board
    }

    /// The board's reload: every status a column, every task a card. With no board to draw (loading, can't load, no
    /// task at all, a search with no match) the collection view under it shows the state instead.
    private func reloadBoard(_ boardView: KanbanBoardView, shown: KanbanBoard?, order: [String], animated: Bool) {
        let botName: (String?) -> String = { [weak self] name in PagesNames.botName(name, bots: self?.services?.bots ?? []) }
        var nextTasks: [String: KanbanTask] = [:], nextRows: [String: KanbanRowModel] = [:]
        var columns: [KanbanBoardColumn] = []
        let now = Date()
        for status in order {
            let list = shown?.columns.first { $0.name == status }?.tasks ?? []
            for task in list {
                nextTasks[task.id] = task
                let who = task.assignee ?? (task.status == "ready" && !store.fallback.isEmpty ? store.fallback : nil)
                nextRows[task.id] = KanbanRowModel(id: task.id, title: task.title, assignee: who,
                                                   head: who.flatMap { PagesNames.head($0, bots: services?.bots ?? []) },
                                                   bits: KanbanRowModel.bits(task, fallback: store.fallback, botName: botName, now: now))
            }
            columns.append(KanbanBoardColumn(status: status, ids: list.map(\.id)))
        }
        let changed = Set(nextRows.keys.filter { rowModels[$0] != nil && rowModels[$0] != nextRows[$0] })
        tasks = nextTasks
        rowModels = nextRows
        groups = []
        let noCards = nextTasks.isEmpty
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if shown == nil {
            snapshot.appendSections([.state])
            snapshot.appendItems([.status], toSection: .state)
        } else if noCards {
            snapshot.appendSections([.state])
            snapshot.appendItems([.empty(KanbanEmptyView.wholeBoard)], toSection: .state)
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
        let showsBoard = shown != nil && !noCards
        boardView.isHidden = !showsBoard
        boardView.apply(showsBoard ? columns : [], changed: changed, animated: animated)
        boardView.selected = onShowTask
        let signature = "\(store.boardTitle)|\(store.boardKey)|\(store.boards?.boards.map { "\($0.slug):\($0.total ?? -1)" } ?? [])"
        if signature != boardSignature, let barBoardButton {
            boardSignature = signature
            configureBoardButton(barBoardButton, inBar: true)
        }
        lastBoard = store.boardKey
        notePaneListEmpty(!showsBoard)
        if collectionView.refreshControl?.isRefreshing == true, !store.loadingBoard { collectionView.refreshControl?.endRefreshing() }
        searchShownWhileEmpty(shown.map { query.pgTrim.isEmpty && $0.columns.allSatisfy { $0.tasks.isEmpty } } ?? false)
    }

    // MARK: Board button

    private static func makeBoardButton(in cell: UICollectionViewCell) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.imagePlacement = .trailing
        config.imagePadding = 6
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        if DeviceWord.isMac {
            // [mac] Stress test 2026-10-28 #91: the 20 pt bold "Default Board ⌄" read as a second page title. On the Mac
            // it is drawn as a pop-up button: an outlined box, body-size text, the up-down chevron.
            // [mac] Mac polish #109: the face every Mac pop-up has (`MacPopUpFace`: the field box's fill, edge, corner and
            // height); it was a 44 pt outline with no fill. The click area stays the button's 44 pt.
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 9, bottom: 4, trailing: 7)
            config.cornerStyle = .fixed   // the background's own radius (a dynamic style sets its own)
            config.background.cornerRadius = MacField.radius
            config.background.strokeWidth = 1
            config.background.strokeColor = MacPush.stroke
            config.background.backgroundColor = MacPush.fill
            let inset = max(0, ((44 - MacForm.controlHeight) / 2).rounded(.down))
            config.background.backgroundInsets = NSDirectionalEdgeInsets(top: inset, leading: 0, bottom: inset, trailing: 0)
        }
        // The name wraps (it was cut to "Release 2…" at accessibility sizes, and it is all that says which board is open).
        config.titleLineBreakMode = .byWordWrapping
        let button = UIButton(configuration: config)
        button.titleLabel?.numberOfLines = 0
        button.showsMenuAsPrimaryAction = true
        button.contentHorizontalAlignment = .leading
        button.accessibilityIdentifier = "kanban.board"
        button.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 20),
            button.trailingAnchor.constraint(lessThanOrEqualTo: cell.contentView.trailingAnchor, constant: -20),
            button.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        return button
    }

    private func configureBoardButton(_ button: UIButton, inBar: Bool = false) {
        let title = store.boardTitle
        if inBar {
            // [mac-tools] In the bar beside "Kanban": the board's name alone on the pop-up's face.
            button.configuration?.attributedTitle = AttributedString(title, attributes: AttributeContainer([
                .font: HQFont.preferred(.subheadline), .foregroundColor: HQPalette.label]))
            button.configuration?.image = UIImage(systemName: "chevron.up.chevron.down",
                                                  withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption2).applying(UIImage.SymbolConfiguration(weight: .semibold)))
            button.tintColor = HQPalette.label2
        } else if DeviceWord.isMac {
            // [mac] Stress test 2026-10-28 #91: a pop-up button ("Board: Default Board ⇕"), not a heading.
            var words = AttributedString("Board: ", attributes: AttributeContainer([.font: HQFont.preferred(.body), .foregroundColor: HQPalette.label2]))
            words += AttributedString(title, attributes: AttributeContainer([.font: HQFont.preferred(.body), .foregroundColor: HQPalette.label]))
            button.configuration?.attributedTitle = words
            button.configuration?.image = UIImage(systemName: "chevron.up.chevron.down",
                                                  withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote).applying(UIImage.SymbolConfiguration(weight: .semibold)))
            button.tintColor = HQPalette.label2
        } else {
        button.configuration?.attributedTitle = AttributedString(title, attributes: AttributeContainer([
            .font: HQFont.preferred(.title3).pagesWeight(.semibold), .foregroundColor: HQPalette.label]))
        // The chevron grows with the title (a text style, 15 pt at the default size): a fixed 15 pt one looked lost
        // beside a huge board name at accessibility sizes, and it is the only hint the title is a menu.
        // [desktoplook] the look's quiet picker chevron (regular, caption, secondary colour), as All Bots on Jobs.
        let desktop = Theme.isDesktop
        let chevron = desktop
            ? UIImage.SymbolConfiguration(textStyle: .caption1).applying(UIImage.SymbolConfiguration(weight: .regular))
            : UIImage.SymbolConfiguration(textStyle: .subheadline).applying(UIImage.SymbolConfiguration(weight: .bold))
        button.configuration?.image = UIImage(systemName: "chevron.down", withConfiguration: chevron)
        button.tintColor = desktop ? HQPalette.label2 : HQPalette.tint
        }
        button.isEnabled = store.boards != nil
        button.accessibilityLabel = "Board: \(title). Switch board"
        let boards = store.boards?.boards ?? []
        if boards.count > 8 {
            button.showsMenuAsPrimaryAction = false
            button.menu = nil
            button.removeTarget(nil, action: nil, for: .primaryActionTriggered)
            button.addAction(UIAction { [weak self] _ in self?.showBoardList() }, for: .primaryActionTriggered)
        } else {
            button.showsMenuAsPrimaryAction = true
            let current = store.boardKey
            let items = boards.map { meta in
                let action = UIAction(title: KanbanModel.boardTitle(slug: meta.slug, name: meta.name), state: meta.slug == current ? .on : .off) { [weak self] _ in
                    self?.pickBoard(meta.slug)
                }
                if let total = meta.total { action.subtitle = "\(total) \(total == 1 ? "task" : "tasks")" }
                return action
            }
            button.menu = UIMenu(title: "Boards", options: .singleSelection, children: items)
        }
    }

    private func pickBoard(_ slug: String) {
        guard slug != store.boardKey else { return }
        PagesHaptics.selection()
        searchCapsule?.clearSearch()   // [morepages]
        query = ""
        store.select(board: slug)
    }

    private func showBoardList() {
        let boards = store.boards?.boards ?? []
        let list = KanbanBoardListController(boards: boards, current: store.boardKey) { [weak self] slug in
            self?.pickBoard(slug)
            self?.navigationController?.popViewController(animated: true)
        }
        navigationController?.pushViewController(list, animated: true)
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
        let names = store.board?.columns.map(\.name) ?? KanbanModel.statusOrder
        let order = KanbanModel.chipOrder(names)
        let shown = store.board.map { KanbanModel.filter($0, query) }
        if let boardView { reloadBoard(boardView, shown: shown, order: order, animated: animated); return }   // [mac-tools]
        let counts = shown.map(KanbanModel.statusCounts) ?? [:]
        chipCounts = counts
        // A search that empties the picked chip drops the pick.
        if !query.pgTrim.isEmpty, let picked = store.pickedChip, (counts[picked] ?? 0) == 0 { store.picked(nil) }
        let picked = store.pickedChip
        chosen = picked.flatMap { order.contains($0) ? $0 : nil } ?? KanbanModel.defaultStatus(order, counts)
        let list = shown?.columns.first { $0.name == chosen }?.tasks ?? []
        let botName: (String?) -> String = { [weak self] name in PagesNames.botName(name, bots: self?.services?.bots ?? []) }
        var nextTasks: [String: KanbanTask] = [:], nextRows: [String: KanbanRowModel] = [:]
        let now = Date()
        for task in list {
            nextTasks[task.id] = task
            let who = task.assignee ?? (task.status == "ready" && !store.fallback.isEmpty ? store.fallback : nil)
            nextRows[task.id] = KanbanRowModel(id: task.id, title: task.title, assignee: who,
                                               head: who.flatMap { PagesNames.head($0, bots: services?.bots ?? []) },
                                               bits: KanbanRowModel.bits(task, fallback: store.fallback, botName: botName, now: now))
        }
        if chosen == "done" {
            groups = KanbanModel.groupBy(list) { KanbanModel.doneGroup($0.completedAt ?? $0.createdAt, now: now) }
                .map { ("done:" + $0.heading, $0.heading, $0.items.map(\.id)) }
        } else {
            groups = list.isEmpty ? [] : [("status:" + chosen, KanbanModel.groupHeading(count: list.count, status: chosen), list.map(\.id))]
        }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.top, .chips])
        snapshot.appendItems([.board], toSection: .top)
        snapshot.appendItems(order.map { .chip($0) }, toSection: .chips)
        if shown == nil {
            snapshot.appendSections([.state])
            snapshot.appendItems([.status], toSection: .state)
        } else if list.isEmpty {
            // [mac] Stress test 2026-10-31 (#91 again): a board with no tasks at all says so, not "Nothing in Triage"
            // (the Mac shows no chips then, so the status named nothing on screen).
            let boardEmpty = query.pgTrim.isEmpty && shown?.columns.allSatisfy { $0.tasks.isEmpty } == true
            snapshot.appendSections([.state])
            snapshot.appendItems([.empty(boardEmpty ? KanbanEmptyView.wholeBoard : chosen)], toSection: .state)
        } else {
            for group in groups {
                snapshot.appendSections([.group(group.key)])
                snapshot.appendItems(group.ids.map { .task($0) }, toSection: .group(group.key))
            }
        }
        let board = "\(store.boardTitle)|\(store.boardKey)|\(store.boards?.boards.map { "\($0.slug):\($0.total ?? -1)" } ?? [])"
        var nextChips: [String: String] = [:]
        for status in order { nextChips[status] = "\(counts[status] ?? 0)|\(status == chosen)" }
        let changed = snapshot.itemIdentifiers.filter { item in
            switch item {
            case .task(let id): return rowModels[id] != nil && rowModels[id] != nextRows[id]
            case .chip(let status): return chipSignatures[status] != nextChips[status]
            case .board: return board != boardSignature
            case .status, .empty: return true
            }
        }
        boardSignature = board
        chipSignatures = nextChips
        tasks = nextTasks
        rowModels = nextRows
        snapshot.reconfigureItems(changed)
        let scrollToTop = (lastChosen != nil && lastChosen != chosen) || (lastBoard != nil && lastBoard != store.boardKey)
        lastChosen = chosen
        lastBoard = store.boardKey
        dataSource.apply(snapshot, animatingDifferences: animated && !scrollToTop && !HQMotion.reduced)
        notePaneListEmpty(groups.isEmpty || shown == nil)   // [mac] #57
        refreshHeaders()
        if scrollToTop { collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false) }
        if chosen != shownChip {
            // The chosen chip stays in view (a board or a launch that opens on Done).
            shownChip = chosen
            chipToReveal = chosen
            chipRevealTries = 0
            revealChosenChip(animated: animated)
        }
        if collectionView.refreshControl?.isRefreshing == true, !store.loadingBoard { collectionView.refreshControl?.endRefreshing() }
        if paneKeepsSelection { markOnShow(onShowTask, keepsSelection: true) }
        searchShownWhileEmpty(shown.map { query.pgTrim.isEmpty && $0.columns.allSatisfy { $0.tasks.isEmpty } } ?? false)
    }

    /// [mac-audit G] Owner 2026-11-02 (Mac audit #18, mac2/4): a board with no tasks at all has nothing to search, so
    /// Search leaves the bar (New Task and How Kanban Works stay) and comes back with the first task. A search that
    /// emptied the board keeps it, so the search can be undone. Mac only; the bar items' order is otherwise unchanged.
    private func searchShownWhileEmpty(_ boardEmpty: Bool) {
        guard DeviceWord.isMac, let search = searchCapsule?.searchItem, searchCapsule?.isSearchShown != true else { return }
        var items = navigationItem.rightBarButtonItems ?? []
        let at = items.firstIndex { $0 === search }
        if boardEmpty, let at {
            items.remove(at: at)
        } else if !boardEmpty, at == nil {
            // Back in its place: the edge-most item (`DesktopBars.searchToEdge` keeps it there).
            items.insert(search, at: 0)
        } else {
            return
        }
        navigationItem.rightBarButtonItems = items
    }

    /// [mac] Mac polish #57: no task on show (an empty board or status, a search with no match, loading or can't load):
    /// the right pane beside it stays blank, not "No Task Selected – Choose a task" beside the board's own "No Tasks Yet".
    private(set) var paneListIsEmpty = false

    private func notePaneListEmpty(_ empty: Bool) {
        #if targetEnvironment(macCatalyst)
        guard empty != paneListIsEmpty else { return }
        paneListIsEmpty = empty
        NotificationCenter.default.post(name: DetailPlaceholderViewController.listStateChanged, object: self)
        #endif
    }

    /// [mac] Two panes: the row of the task whose page the right pane shows stays marked, as on Jobs.
    private var paneKeepsSelection = false
    private var onShowTask: String?

    /// Marks the row of the task the right pane shows; nil clears it.
    func markOnShow(_ id: String?, keepsSelection: Bool) {
        paneKeepsSelection = keepsSelection
        onShowTask = keepsSelection ? id : nil
        boardView?.selected = onShowTask   // [mac-tools]
        guard isViewLoaded, dataSource != nil else { return }
        let path = onShowTask.flatMap { dataSource.indexPath(for: .task($0)) }
        for selected in collectionView.indexPathsForSelectedItems ?? [] where selected != path {
            collectionView.deselectItem(at: selected, animated: false)
        }
        if let path { collectionView.selectItem(at: path, animated: false, scrollPosition: []) }
    }

    private func pulled() {
        Task { [weak self] in
            guard let store = self?.store, await store.pullToRefresh() != nil else { return }
            // The board stays as saved; without a word the pull looked like it worked.
            self?.notices.show("Couldn’t refresh. Showing what was saved.")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.collectionView.refreshControl?.endRefreshing() }
    }

    private func retry() {
        retrying = true
        reload(animated: false)
        Task {
            await store.readBoard()
            retrying = false
            reload(animated: false)
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        searchCapsule?.updateSearchState()   // [morepages]
        guard text != query else { return }
        query = text
        reload(animated: false)
    }

    // MARK: Selection

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .chip?, .task?: return true
        default: return false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .chip(let status)?:
            collectionView.deselectItem(at: indexPath, animated: false)
            if status != chosen { PagesHaptics.selection() }
            store.picked(status)
            reload(animated: false)
        case .task(let id)?:
            openTask(id)
            if onShowTask != id { collectionView.deselectItem(at: indexPath, animated: true) }
        default:
            break
        }
    }

    func openTask(_ id: String) {
        guard let services else { return }
        // [mac] In two panes the task opens in the right pane beside the board, as a job's page does beside Jobs (owner
        // 2026-10-23: "Kanban using the right side"). [ipad-polish] The iPad too: its centred sheet (3x-ipad D6) left
        // the right pane saying "Choose an item from the list" for good, since choosing one never filled it.
        if (tabBarController as? MainTabController)?.split?.isDouble == true {
            openDetail(KanbanTaskSheet.page(taskId: id, store: store, services: services, board: self))
            return
        }
        let sheet = KanbanTaskSheet.make(taskId: id, store: store, services: services)
        present(sheet, animated: true)
    }

    func newTask() {
        guard let services else { return }
        if store.readOnlyGateway { KanbanFeedback.readOnly(from: self); return }
        let sheet = NewTaskSheet.make(store: store, services: services, startIn: chosen == "ready" ? "ready" : "triage") { [weak self] warning in
            if let warning { self?.notices.show(warning, seconds: 5) }
            self?.reload(animated: true)
        }
        present(sheet, animated: true)
    }

    private func showAbout() {
        // The shared sheet frame (verify round 1: this one had its ✕ trailing, a grabber and no opaque page).
        let about = UIHostingController(rootView: HQScaledRoot(KanbanAboutView()))
        // Large only: at medium height the statuses were cut off after Todo and the gestures line was out of sight.
        present(ChatSheet.wrap(about, title: "How Kanban Works", detents: [.large()]), animated: true)
    }

    // MARK: Hold menu and swipes

    private func task(at path: IndexPath) -> KanbanTask? {
        guard case .task(let id)? = dataSource.itemIdentifier(for: path) else { return nil }
        return tasks[id]
    }

    func menu(for task: KanbanTask, source: UIView?) -> UIMenu {
        var children: [UIMenuElement] = []
        // [mac-audit] Owner 2026-11-02 (#26): a card's right-click menu starts with what a click does, as a job's does
        // (Open Job, Edit Job…); it had only moves and Delete.
        if DeviceWord.isMac {
            children.append(UIMenu(options: .displayInline, children: [
                UIAction(title: "Open Task", image: UIImage(systemName: "arrow.up.forward.square")) { [weak self] _ in self?.openTask(task.id) }
            ]))
        }
        if let quick = KanbanModel.quickMove(task.status), !KanbanModel.isLocked(quick.to) {
            let symbol = quick.label == "Unblock" ? "play" : quick.label == "Reopen" ? "arrow.clockwise" : "arrow.right.circle"
            children.append(UIAction(title: quick.label, image: UIImage(systemName: symbol)) { [weak self] _ in
                Task { await self?.store.move(task, to: quick.to) }
            })
        }
        let targets = (store.board?.columns.map(\.name) ?? []).filter { $0 != task.status && $0 != "archived" && !KanbanModel.isLocked($0) }
        children.append(UIMenu(title: "Move To", image: UIImage(systemName: "tray"), children: targets.map { name in
            UIAction(title: KanbanModel.label(name)) { [weak self] _ in Task { await self?.store.move(task, to: name) } }
        }))
        let people = store.profiles.map(\.name)
        let bots = services?.bots ?? []
        // Last, as New Task lists No One Yet: unassigned (the board's default bot, if any, then runs it).
        let nobody = UIAction(title: KanbanModel.nobodyWords(defaultBot: store.fallback.isEmpty ? "" : PagesNames.botName(store.fallback, bots: bots)),
                              state: task.assignee == nil ? .on : .off) { [weak self] _ in
            Task { await self?.store.assign(task, to: "") }
        }
        let picks: [UIMenuElement] = people.map { name in
            UIAction(title: PagesNames.botName(name, bots: bots), state: name == task.assignee ? .on : .off) { [weak self] _ in
                Task { await self?.store.assign(task, to: name) }
            }
        }
        children.append(UIMenu(title: "Assign To", image: UIImage(systemName: "person.crop.circle"),
                               children: picks + [UIMenu(options: .displayInline, children: [nobody])]))
        var manage: [UIMenuElement] = []
        if task.status == "done" {
            manage.append(UIAction(title: "Archive", image: UIImage(systemName: "archivebox")) { [weak self] _ in self?.archive(task) })
        }
        // [mac-audit] Owner 2026-11-02 (#26): "…", since Delete asks first.
        manage.append(UIAction(title: "Delete Task…", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.confirmDelete(task, source: source)
        })
        children.append(UIMenu(options: .displayInline, children: manage))
        return UIMenu(children: children)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let path = indexPaths.first, let task = task(at: path) else { return nil }
        let cell = collectionView.cellForItem(at: path)
        return UIContextMenuConfiguration(identifier: task.id as NSString, previewProvider: nil) { [weak self] _ in
            self?.menu(for: task, source: cell)
        }
    }

    private func archive(_ task: KanbanTask) {
        let from = task.status
        Task {
            guard let board = await store.archive(task) else { return }
            KanbanFeedback.archived(task, from: from, board: board, store: store, on: self)
        }
    }

    private func confirmDelete(_ task: KanbanTask, source: UIView?) {
        if store.readOnlyGateway { KanbanFeedback.readOnly(from: self); return }
        let sheet = UIAlertController(title: "Delete This Task?",
                                      message: "“\(task.title)” is deleted for every bot and device. This can’t be undone.",
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Delete Task", style: .destructive) { [weak self] _ in self?.delete(task) })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = source ?? view
        present(sheet, animated: true)
    }

    /// A failed delete is an alert with Try Again (the card comes back), not a line that fades (UX study #134).
    private func delete(_ task: KanbanTask) {
        Task { [store] in
            _ = await store.delete(task) { [weak self] reason in
                KanbanFeedback.failed("delete", reason: reason, from: self) { self?.delete(task) }
            }
        }
    }

    private func leadingSwipe(_ path: IndexPath) -> UISwipeActionsConfiguration? {
        guard let task = task(at: path), let quick = KanbanModel.quickMove(task.status), !KanbanModel.isLocked(quick.to) else { return nil }
        let action = UIContextualAction(style: .normal, title: quick.label) { [weak self] _, _, done in
            Task { await self?.store.move(task, to: quick.to) }
            done(true)
        }
        action.backgroundColor = quick.label == "Unblock" ? .systemGreen : ChatPalette.tint
        action.image = UIImage(systemName: quick.label == "Unblock" ? "play.fill" : quick.label == "Reopen" ? "arrow.uturn.backward" : "arrow.right.circle.fill")
        let config = UISwipeActionsConfiguration(actions: [action])
        config.performsFirstActionWithFullSwipe = true
        return config
    }

    private func trailingSwipe(_ path: IndexPath) -> UISwipeActionsConfiguration? {
        guard let task = task(at: path) else { return nil }
        let cell = collectionView.cellForItem(at: path)
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            self?.confirmDelete(task, source: cell)
            done(false)
        }
        delete.image = UIImage(systemName: "trash.fill")
        var actions = [delete]
        if task.status == "done" {
            let archive = UIContextualAction(style: .normal, title: "Archive") { [weak self] _, _, done in
                self?.archive(task)
                done(true)
            }
            archive.backgroundColor = .systemIndigo
            archive.image = UIImage(systemName: "archivebox.fill")
            actions.append(archive)
        }
        let more = UIContextualAction(style: .normal, title: "More") { [weak self] _, _, done in
            done(true)
            RowMoreMenu.afterSwipe { [weak self] in
                guard let self else { return }
                if RowMoreMenu.open(self.menu(for: task, source: cell), from: cell) { return }
                self.presentMenuSheet(for: task, source: cell)
            }
        }
        more.backgroundColor = .systemGray
        more.image = UIImage(systemName: "ellipsis.circle.fill")
        actions.append(more)
        let config = UISwipeActionsConfiguration(actions: actions)
        config.performsFirstActionWithFullSwipe = false
        return config
    }

    /// The hold menu from a swipe's More for a card not on screen: an action sheet with the same choices.
    private func presentMenuSheet(for task: KanbanTask, source: UIView?) {
        let sheet = UIAlertController(title: task.title, message: nil, preferredStyle: .actionSheet)
        if let quick = KanbanModel.quickMove(task.status), !KanbanModel.isLocked(quick.to) {
            sheet.addAction(UIAlertAction(title: quick.label, style: .default) { [weak self] _ in Task { await self?.store.move(task, to: quick.to) } })
        }
        sheet.addAction(UIAlertAction(title: "Move To…", style: .default) { [weak self] _ in self?.presentMoveSheet(task, source: source) })
        sheet.addAction(UIAlertAction(title: "Assign To…", style: .default) { [weak self] _ in self?.presentAssignSheet(task, source: source) })
        if task.status == "done" { sheet.addAction(UIAlertAction(title: "Archive", style: .default) { [weak self] _ in self?.archive(task) }) }
        sheet.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in self?.confirmDelete(task, source: source) })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = source ?? view
        present(sheet, animated: true)
    }

    private func presentMoveSheet(_ task: KanbanTask, source: UIView?) {
        let sheet = UIAlertController(title: "Move To", message: nil, preferredStyle: .actionSheet)
        for name in (store.board?.columns.map(\.name) ?? []) where name != task.status && name != "archived" && !KanbanModel.isLocked(name) {
            sheet.addAction(UIAlertAction(title: KanbanModel.label(name), style: .default) { [weak self] _ in Task { await self?.store.move(task, to: name) } })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = source ?? view
        present(sheet, animated: true)
    }

    private func presentAssignSheet(_ task: KanbanTask, source: UIView?) {
        let sheet = UIAlertController(title: "Assign To", message: nil, preferredStyle: .actionSheet)
        for profile in store.profiles {
            let name = PagesNames.botName(profile.name, bots: services?.bots ?? [])
            // The current bot is named and greyed out (a typed "✓" read as "check mark" and looked unfinished).
            let current = profile.name == task.assignee
            let action = UIAlertAction(title: current ? "\(name) (Current)" : name, style: .default) { [weak self] _ in
                Task { await self?.store.assign(task, to: profile.name) }
            }
            action.isEnabled = !current
            sheet.addAction(action)
        }
        let nobody = KanbanModel.nobodyWords(defaultBot: store.fallback.isEmpty ? "" : PagesNames.botName(store.fallback, bots: services?.bots ?? []))
        let none = task.assignee == nil
        let unassign = UIAlertAction(title: none ? "\(nobody) (Current)" : nobody, style: .default) { [weak self] _ in
            Task { await self?.store.assign(task, to: "") }
        }
        unassign.isEnabled = !none
        sheet.addAction(unassign)
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = source ?? view
        present(sheet, animated: true)
    }
}

/// More than eight boards: a pushed, searchable list (search over 12).
final class KanbanBoardListController: UITableViewController, UISearchResultsUpdating {
    private let boards: [KanbanBoardMeta]
    private let current: String
    private let pick: (String) -> Void
    private var shown: [KanbanBoardMeta]

    init(boards: [KanbanBoardMeta], current: String, pick: @escaping (String) -> Void) {
        self.boards = boards
        self.current = current
        self.pick = pick
        shown = boards
        super.init(style: .insetGrouped)
        title = "Boards"
        navigationItem.largeTitleDisplayMode = .never
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = HQPalette.groupedPage   // solid-ok: a page in the Kanban tab, not a sheet; it follows the skin
        PageBackdrop.install(behind: tableView)   // [backdrop] Theme › App Background
        if boards.count > 12 {
            let search = UISearchController(searchResultsController: nil)
            search.searchResultsUpdater = self
            search.obscuresBackgroundDuringPresentation = false
            navigationItem.searchController = search
            PageSearchField.hidesOnScroll(navigationItem)
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        let words = (searchController.searchBar.text ?? "").pgTrim.lowercased()
        shown = words.isEmpty ? boards : boards.filter { KanbanModel.boardTitle(slug: $0.slug, name: $0.name).lowercased().contains(words) }
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { shown.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let meta = shown[indexPath.row]
        var content = cell.defaultContentConfiguration().hqScaled()
        content.text = KanbanModel.boardTitle(slug: meta.slug, name: meta.name)
        content.secondaryText = meta.total.map { "\($0) \($0 == 1 ? "task" : "tasks")" }
        cell.contentConfiguration = content
        cell.accessoryType = meta.slug == current ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        pick(shown[indexPath.row].slug)
    }
}

/// "How Kanban Works" (§4.3): who runs tasks, each status with its dot and help, and the gestures.
struct KanbanAboutView: View {
    var body: some View {
        List {
            Section {
                Text("You don’t run the tasks; your bots do. Put a task in Ready with someone assigned and that bot picks it up within a minute.")
                    .padding(.vertical, 4)
            }
            Section {
                ForEach(KanbanModel.statusOrder, id: \.self) { status in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(KanbanTone.color(status)).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(KanbanModel.label(status)).font(Font.hq(.body).weight(.semibold))
                            Text(KanbanModel.statusHelp[status] ?? "").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            Section {
                Text(DeviceWord.isMac ? "Control\u{2011}click a task for Move To, Assign To and Delete."
                     : "Hold a task for Move To, Assign To and Delete, or swipe it.").foregroundStyle(Color.hqLabel2)
            }
            // UX study #121: where the tab's switch lives (Settings › Appearance › Tabs, or Capabilities › Plugins).
            // [kanban-tab-one] It named Settings › Bots & Tools, which no longer has the row (owner 2026-11-03: one home per page).
            Section {
                Text(SettingsWords.kanbanAboutTab())
                    .foregroundStyle(Color.hqLabel2)
                    .accessibilityIdentifier("kanban.about.tab-setting")
            }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
    }
}

/// UX study #175: the task group's card. Light: the page's white with a hairline edge (the grey fill read as a disabled
/// block on the white page). Dark: the grey card as before, no edge. The rows above it are clear.
final class KanbanCardBackground: UICollectionReusableView {
    static let kind = "kanban.card"
    /// The card itself: a section background spans the section's header too, so it starts under the header's line.
    private let card = UIView()
    private var section = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        card.layer.cornerCurve = .continuous
        addSubview(card)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: KanbanCardBackground, _) in view.paint() }
        paint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        section = layoutAttributes.indexPath.section
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let header = (superview as? UICollectionView)?.collectionViewLayout
            .layoutAttributesForSupplementaryView(ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: section))
        let top = header.map { min(max(0, $0.frame.maxY - frame.minY), bounds.height) } ?? 0
        card.frame = bounds.inset(by: UIEdgeInsets(top: top, left: 0, bottom: 0, right: 0))
        // The inset-grouped list's own corner (26 on iOS 26 at the default width), so a pressed first or last row lines up.
        card.layer.cornerRadius = min(26, card.bounds.height / 2)
    }

    private func paint() {
        let dark = traitCollection.userInterfaceStyle == .dark
        card.backgroundColor = dark ? HQPalette.groupedCard : HQPalette.page
        card.layer.borderWidth = dark ? 0 : HQShape.hairline / max(traitCollection.displayScale, 1)
        card.layer.borderColor = dark ? nil : HQPalette.separator.resolvedColor(with: traitCollection).cgColor
    }
}

/// item 20: a short fade on an edge of a horizontally scrolling row while more content lies past it — a trailing
/// chip cut off flat at the screen edge read as clipping, not more to scroll to. Masks the scroll view itself (its
/// own `layer.mask`), recomputed on every scroll and on every call to `attach` (a UIView's `bounds` is not reliably
/// KVO-observable under Auto Layout, so the owning controller's `viewDidLayoutSubviews` drives the layout side, the
/// same technique as `ComposerTextView`'s vertical edge fade drives from its own `layoutSubviews`).
final class HorizontalEdgeFade: NSObject {
    private weak var scrollView: UIScrollView?
    private let mask = CAGradientLayer()
    private var offsetObserver: NSKeyValueObservation?
    var width: CGFloat = 20

    /// Call on every layout pass of the owning controller (it recomputes the mask's frame for the current bounds)
    /// and whenever the row's own scroll view might have changed.
    func attach(to scrollView: UIScrollView) {
        if self.scrollView !== scrollView {
            detach()
            self.scrollView = scrollView
            scrollView.layer.mask = mask
            offsetObserver = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }
        update()
    }

    func detach() {
        if scrollView?.layer.mask === mask { scrollView?.layer.mask = nil }
        offsetObserver = nil
        scrollView = nil
    }

    private func update() {
        guard let scrollView, scrollView.bounds.width > 0 else { return }
        let w = scrollView.bounds.width
        let inset = scrollView.adjustedContentInset
        let leading = scrollView.contentOffset.x > -inset.left + 0.5
        let trailing = scrollView.contentOffset.x < scrollView.contentSize.width + inset.right - w - 0.5
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // The mask's frame is read in the layer's own coordinate space, which for a scrolled view starts at
        // `bounds.origin` (not (0, 0)): using the scroll view's own `bounds` keeps the mask over the visible
        // viewport as it scrolls (a hardcoded zero origin hid the whole row once contentInset shifted `bounds`).
        mask.frame = scrollView.bounds
        let band = min(0.3, width / w)
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.colors = [(leading ? UIColor.clear : UIColor.black).cgColor, UIColor.black.cgColor, UIColor.black.cgColor,
                       (trailing ? UIColor.clear : UIColor.black).cgColor]
        mask.locations = [0, NSNumber(value: leading ? band : 0), NSNumber(value: 1 - (trailing ? band : 0)), 1]
        CATransaction.commit()
    }
}

#if targetEnvironment(macCatalyst)
extension KanbanViewController: PaneListEmptiness {}   // [mac] #57
#endif
