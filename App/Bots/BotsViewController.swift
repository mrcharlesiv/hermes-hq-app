// The Bots tab (spec 02 §6–7, spec 06 §6): pinned tiles, sections, rows, Hidden at the bottom. A collection view
// with a compositional layout and a diffable data source; roster changes apply as animated snapshots and changed
// rows are reconfigured in place, so nothing flashes.

import SwiftUI
import UIKit

/// [botslist] Filter › Show and Activity for this run of the app. A gateway switch rebuilds the tabs
/// (`MainTabController.gatewayDidSwitch`); the filters picked on the list carry over it, as the web list keeps Activity
/// when its Gateway choice changes (`S/ui-bots/roster-filters.ts`, parity §3 L240). Signing out clears them.
@MainActor enum BotsFilterMemory {
    static var activity: BotActivityFilter = .all
    static var kind: BotKindFilter = .all
    static func reset() { activity = .all; kind = .all }
}

final class BotsViewController: UIViewController, UICollectionViewDelegate, UISearchResultsUpdating {
    private let services: any AppServices
    private let makeChat: (any ChatSessionModel) -> UIViewController
    /// Called when the roster changes (`services.onBotsChange`), even while the list is off screen: the tab controller
    /// updates its badges and the Sessions rows (which show their owner's name and head).
    var onDataChange: (() -> Void)?
    #if targetEnvironment(macCatalyst)
    /// [bots-rail] A room changed (its unread mark, a pin, a new room): the Mac's folded rail draws rooms too.
    var onRoomsChange: (() -> Void)?
    #endif

    /// [m9/ipad] The placeholder beside the list drops "Choose an item" while the list is empty; it hears when that flips.
    /// UIKit's `contentUnavailableConfiguration` can't be overridden (it lives in an extension), so writes go through here.
    private var emptyConfiguration: (any UIContentConfiguration)? {
        get { BackdropState.unwrap(contentUnavailableConfiguration) }
        set {
            let flipped = (contentUnavailableConfiguration == nil) != (newValue == nil)
            #if targetEnvironment(macCatalyst)
            // [mac] Mac polish #4: the right pane shows this state itself (the list is folded into the sidebar), so a
            // change from one state to another (Couldn’t Load Bots to No Bots Yet, a new reason) reaches it too.
            let changed = flipped || Self.words(of: BackdropState.unwrap(contentUnavailableConfiguration)) != Self.words(of: newValue)
            #else
            let changed = flipped
            #endif
            contentUnavailableConfiguration = BackdropState.wrap(newValue)   // [backdrop-cards] a soft card on Soft Cards
            guard changed else { return }
            NotificationCenter.default.post(name: DetailPlaceholderViewController.listStateChanged, object: self)
        }
    }

    #if targetEnvironment(macCatalyst)
    /// [mac] What an empty state says: its title, its line and its button's title.
    private static func words(of state: (any UIContentConfiguration)?) -> [String?] {
        guard let state = state as? UIContentUnavailableConfiguration else { return [] }
        return [state.text, state.secondaryText, state.button.title]
    }
    #endif

    nonisolated private enum Section: Hashable, Sendable { case list(BotListSectionID), loading, token, notice }
    nonisolated private enum Item: Hashable, Sendable {
        case tile(String), row(String), header(BotListSectionID), skeleton(Int)
        case notice(String)          // [offline] the slow-load or stale-list card ("slow" / "stale"), spec 3x-offline §4
        case token(String)           // the filter token under the bar (what it names)
        case hint(String)            // settings stream: an empty user section's hint row (section id)
        case room(String), roomTile(String)   // [groups] a group chat's row or pinned tile (room key)
        case chat(String)            // [chats-under] one of a bot's chats under its row (bot id + U+001F + session id)
        case more(String)            // [chats-under] "N more" under a bot's chats (bot id)
    }

    private(set) var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var botsByID: [String: Bot] = [:]
    private var sections: [BotListSection] = []
    /// Collapsed sections, for this session only (Hidden starts collapsed, `HB/hidden-bots.ts`).
    private var collapsed: Set<BotListSectionID> = {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "HQDebugShowHidden") { return [] }   // Show Hidden Bots at launch, for pictures
        #endif
        return [.hidden]
    }()
    private var query = ""
    /// Filter › Activity (`S/ui-bots/filter-token.ts`), for this session.
    private(set) var activity: BotActivityFilter = BotsFilterMemory.activity { didSet { BotsFilterMemory.activity = activity } }
    /// [groups] Filter › Show (All, Bots, Group Chats), the rooms by key, and the Group Chats header's count.
    private(set) var kind: BotKindFilter = BotsFilterMemory.kind { didSet { BotsFilterMemory.kind = kind } }
    /// [bots-groupby] Filter › Group By: Sections, or None (one list by activity).
    private(set) var groupBy: BotGroupBy = BotGroupBy.saved { didSet { BotGroupBy.saved = groupBy } }
    private var roomsByID: [String: GroupRowModel] = [:]
    /// [chats-under] The chats drawn under bots, by item key, and whether each is its bot's last row; "N more" counts.
    private var chatRows: [String: (session: SessionSummary, last: Bool)] = [:]
    private var moreCounts: [String: Int] = [:]
    private var chatsByBot: [String: [SessionSummary]] = [:]
    private var groupBlockCount = 0
    /// Accessibility sizes with pins past the six: the faces shown as rows under the Pinned header (`reload`).
    private var foldedTileCount = 0
    private var groups: (any GroupServices)? { services as? GroupServices }
    /// The trailing capsule: Filter, Search, + (shared with Sessions, whose third button is the pencil).
    private(set) var bar: PageBarCapsule!
    /// [bots-plus] What the + makes, for VoiceOver and the Mac's pointer tip: the bar's + and the Mac rail's + say the same.
    var createLabel: String { services is GroupServices ? "New Bot, Group Chat or Section" : "New Bot or Section" }   // [groups]
    func openSearchFromKeyboard() { bar?.openSearch() }   // [m9/ipad] Command-F
    private let searchController = UISearchController(searchResultsController: nil)
    private var signatures: [Item: Int] = [:]
    /// The rows wearing the working ring, whose hairlines the list hides.
    private var ringedRows: Set<Item> = []
    private var refreshStarted: Date?
    /// Which pull the 8 s fallback belongs to (a second pull must not be ended by the first pull's timer).
    private var refreshGeneration = 0
    private var reloadPending = false
    /// The roster changed while the list was off screen; reloaded when it comes back.
    private(set) var needsReload = false
    /// [perf] A reload is waiting for the navigation transition in flight to end (one per transition).
    private var reloadAfterTransition = false
    // [offline] §4.1: when the skeleton came on show, and whether its 15 s have passed (the slow card).
    private var slowTimer: Timer?
    private var slowShown = false
    /// [offline] §4.2: when Try Again was tapped; its read is out until a newer failure (or a good list) arrives.
    private var noticeRetryAt: Date?
    private var noticeRetrying: Bool {
        guard let tapped = noticeRetryAt, let failure = rosterStates?.rosterFailure else { return false }
        return failure.at < tapped
    }
    private var timeObserver: NSObjectProtocol?
    private var lookObserver: NSObjectProtocol?
    private var styleObserver: NSObjectProtocol?   // [chats-under]
    private var muteObserver: UUID?
    /// Settings stream (1x-settings §5): menus, swipes, sections, drag and drop, the + and Settings buttons.
    private(set) var organizer: BotsOrganizer?
    /// Settings stream (1x-settings §4.6): the gateway switcher on the title.
    private var titleSwitcher: GatewayTitleSwitcher?

    init(services: any AppServices, makeChat: @escaping (any ChatSessionModel) -> UIViewController) {
        self.services = services
        self.makeChat = makeChat
        super.init(nibName: nil, bundle: nil)
        title = "Bots"
        // Inline: the large title sits on the bar row beside its buttons (owner: the separate title row put the list too low).
        navigationItem.largeTitleDisplayMode = .inline
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
        collectionView.accessibilityIdentifier = "bots.list"
        // The bar holds the large title and the trailing capsule: clear, with the soft edge, over this list
        // (`ListBarAppearance`), as every tab's.
        ListBarAppearance.apply(to: navigationItem)
        view.addSubview(collectionView)
        ListBarAppearance.pinTitle(in: self, softEdgeAround: collectionView)
        PageBackdrop.install(in: self, clearing: [collectionView])   // [backdrop] Theme › App Background

        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in self?.pulledToRefresh() }, for: .valueChanged)
        collectionView.hqInstallRefresh(refresh)

        // One capsule top right (`S/ui-bots/roster-bar.tsx`): [Filter] [Search] [+]; the field stays folded away
        // until the magnifier opens it. Settings is in More, as on the web.
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = DeviceWord.isMac ? "Search Bots" : "Search"   // [mac] stress test #66
        searchController.searchBar.searchTextField.accessibilityIdentifier = "bots.search.field"
        let hasOrganizer = services is SettingsServices
        bar = PageBarCapsule(host: self, configuration: .init(
            page: "bots",
            filterMenu: { [weak self] in
                Haptics.play(.selection)
                return self?.filterMenu() ?? []
            },
            search: searchController,
            // [bots-plus] A + for what Bots makes (New Bot, New Group Chat, New Section…), not the pencil: the pencil
            // always means a new chat, as on Sessions (owner 2026-11-03, menu review #3). Same menu, same order; the id
            // stays "bots.compose" (the capsule's third button), which the UI tests use.
            compose: hasOrganizer ? .menu({ [weak self] in self?.organizer?.composeMenu() ?? [] }) : nil,
            composeLabel: createLabel,
            composeSymbol: "plus"))
        bar.install()   // [filters-only] Filter stays on the bar, whatever the list (`updateBar`)
        // [bots-plus] On the Mac a + is hairline strokes: one weight step heavier, as Jobs' + (#58), so it reads as heavy
        // as the Filter and the magnifier beside it. Nothing changes on the iPhone or iPad.
        if let plus = bar.composeItem { DesktopBars.markThin(plus) }

        if let settings = services as? SettingsServices {
            // Settings stream: compose, menus, drag and drop, the gateway switcher.
            let organizer = BotsOrganizer(host: self, services: services, settings: settings)
            self.organizer = organizer
            collectionView.dragDelegate = organizer
            collectionView.dropDelegate = organizer
            #if DEBUG
            // UI tests that only long-press turn drag off (`-HQDebugNoDrag YES`): XCUITest waits on the pending lift.
            collectionView.dragInteractionEnabled = !UserDefaults.standard.bool(forKey: "HQDebugNoDrag")
            #else
            collectionView.dragInteractionEnabled = true
            #endif
            let switcher = GatewayTitleSwitcher(host: self, services: services, settings: settings, baseTitle: "Bots")
            switcher.onDeactivate = { [weak self] in self?.updateSubtitle() }
            titleSwitcher = switcher
        } else {
            let account = UIBarButtonItem(image: UIImage(systemName: "person.crop.circle"),
                                          primaryAction: UIAction { [weak self] _ in self?.showAccount() })
            account.accessibilityLabel = "Account"
            navigationItem.leftBarButtonItem = account
        }

        configureDataSource()
        services.onBotsChange = { [weak self] in
            self?.onDataChange?()
            self?.setNeedsReload()
            self?.openPendingIfReady()      // [botslist] a pick that waited for the roster
        }
        groups?.onGroupsChange = { [weak self] in
            self?.setNeedsReload()   // [groups] a room changed
            #if targetEnvironment(macCatalyst)
            self?.onRoomsChange?()   // [bots-rail] the folded rail's rooms too
            #endif
        }
        // A mute set or ended (here, in Bot Info, or by its time running out): the rows' bells.
        muteObserver = BotMuteCenter.shared.observe { [weak self] in self?.setNeedsReload(animated: false) }
        // Midnight (and clock or zone changes): "11:58 PM" becomes "Yesterday". Only rows whose time string changed
        // are reconfigured. Posted on main; a block observer anyway.
        timeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.significantTimeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setNeedsReload(animated: false) }
        }
        // Desktop Look on or off, or Top Edge Soft or Hard: the first section's top gap follows them (`openingGap`).
        var edge = TopEdgeStyle.current
        // [chats-under] Settings › Appearance › Chats Under Bots changed the line's style: the chats redraw.
        styleObserver = NotificationCenter.default.addObserver(forName: BotChatsStyle.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setNeedsReload(animated: false) }
        }
        lookObserver = NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] note in
            let look = note.userInfo?["look"] as? Bool == true
            MainActor.assumeIsolated {
                let edgeChanged = TopEdgeStyle.current != edge
                edge = TopEdgeStyle.current
                guard look || edgeChanged else { return }
                self?.collectionView.collectionViewLayout.invalidateLayout()
            }
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (vc: BotsViewController, previous) in
            if previous.preferredContentSizeCategory.isAccessibilityCategory
                != vc.traitCollection.preferredContentSizeCategory.isAccessibilityCategory {
                vc.reload(animated: false)
            }
        }
        reload(animated: false)
    }

    isolated deinit {
        slowTimer?.invalidate()        // [offline]
        if let timeObserver { NotificationCenter.default.removeObserver(timeObserver) }
        if let lookObserver { NotificationCenter.default.removeObserver(lookObserver) }
        if let muteObserver { BotMuteCenter.shared.stopObserving(muteObserver) }
    }

    // [presence] The rows' browser lines are read from the plugin's list only while the list is on screen
    // (docs/spec/3x-presence.md §5.2).
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        PresenceHooks.botsListShown?(self, true)
        schedulePeek()
    }

    // MARK: - One-time swipe peek [botslist] (parity §3 L161, docs/spec/3x-botslist.md §6)

    /// The first trailing action of a bot row is Mute (`BotsOrganizer.trailingActions`): its colour and bell show.
    private let swipePeek = SwipePeek(key: SwipePeek.botsKey, markerId: "bots.peek", revealColor: .systemIndigo, symbol: "bell.slash.fill")

    /// Once per install, the first ordinary row (not a tile, not hidden, not a group chat) hints at its swipe actions.
    private func schedulePeek() {
        guard organizer != nil, isViewLoaded else { return }
        swipePeek.schedule(in: self, collectionView: collectionView, ready: { [weak self] in
            guard let self else { return false }
            return self.query.isEmpty && !self.searchController.isActive && !self.collectionView.isEditing
        }, rows: { [weak self] in
            guard let self else { return [] }
            return self.collectionView.indexPathsForVisibleItems.sorted().compactMap { path in
                guard case .row(let id) = self.dataSource.itemIdentifier(for: path), self.botsByID[id]?.hidden == false else { return nil }
                return self.collectionView.cellForItem(at: path) as? UICollectionViewListCell
            }
        })
    }

    /// A finger on the list ends a peek in flight at once.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { swipePeek.cancel() }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        PresenceHooks.botsListShown?(self, false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if needsReload {
            // [perf] A pop back to a list already showing rows reloads once the slide has landed (the changed rows
            // animate in then), not in the pop's first frame. A first showing, a tab switch, an unanimated pop and
            // the skeleton or an empty list reload in place, so a wrong state never slides in.
            let snapshot = dataSource.snapshot()
            if animated, let coordinator = transitionCoordinator, snapshot.numberOfItems > 0,
               !snapshot.sectionIdentifiers.contains(.loading) {
                reloadWhenTransitionEnds(coordinator)
            } else {
                reload(animated: false)
            }
        }
        // As a table view controller does: the row you came back from fades its highlight with the pop.
        guard !paneKeepsSelection, let selected = collectionView.indexPathsForSelectedItems, !selected.isEmpty else { return }
        if let coordinator = transitionCoordinator {
            coordinator.animate(alongsideTransition: { _ in
                selected.forEach { self.collectionView.deselectItem(at: $0, animated: true) }
            }, completion: { context in
                if context.isCancelled { selected.forEach { self.collectionView.selectItem(at: $0, animated: false, scrollPosition: []) } }
            })
        } else {
            selected.forEach { collectionView.deselectItem(at: $0, animated: animated) }
        }
    }

    // MARK: - Layout

    private func makeLayout() -> UICollectionViewLayout {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            guard let self, let section = self.dataSource?.sectionIdentifier(for: index) else { return nil }
            let large = environment.traitCollection.preferredContentSizeCategory.isAccessibilityCategory
            // [backdrop-cards] On Soft Cards the pinned faces and the rows right under them are one card.
            let snapshot = self.dataSource.snapshot()
            // The pinned bots (faces, or rows at accessibility sizes) and the bots' rows after them.
            func isPinned(_ at: Int) -> Bool {
                guard at >= 0, at < snapshot.numberOfSections, case .list(.tiles) = snapshot.sectionIdentifiers[at] else { return false }
                return true
            }
            // The bots in no section, which follow the pinned ones with no title between: the two are one card. A
            // section with a name of its own ("Work") is a card of its own, and the pinned bots then are too.
            func isLoose(_ at: Int) -> Bool {
                guard at >= 0, at < snapshot.numberOfSections, case .list(.unassigned) = snapshot.sectionIdentifiers[at] else { return false }
                return true
            }
            if case .list(.tiles) = section, !large {
                return self.tileSection(environment, count: snapshot.numberOfItems(inSection: section),
                                        first: index == 0, joinBelow: isLoose(index + 1))
            }
            // [mac-audit] Owner 2026-11-02 #9: bots in no section after a section's rows (or its folded header) stand
            // apart, as the rail draws a rule before them; with no header they read as the last section's ("Notes"
            // under "Work"). Spec 02 §7: they keep no header of their own.
            var apart = false
            if DeviceWord.isMac, case .list(.unassigned) = section, index > 0,
               case .list(let above)? = self.dataSource?.sectionIdentifier(for: index - 1) {
                switch above { case .pinned, .user: apart = true; default: break }
            }
            let list = self.listSection(environment, first: index == 0, apart: apart)
            // [backdrop-cards] The bots' and group chats' sections; the filter token and the notices stay as they are.
            if case .list = section {
                var join: BackdropCards.Join = isPinned(index - 1) && isLoose(index) ? .above : []
                if isPinned(index), isLoose(index + 1) { join.insert(.below) }
                BackdropCards.card(list, on: BackdropCards.on(self), join: join)
            }
            return list
        }
        BackdropCards.register(in: layout)   // [backdrop-cards]
        return layout
    }

    /// Three columns, gaps 12 pt down and 4 pt across, 4 pt above and 8 pt below; one or two tiles sit centred.
    /// `first`: the tiles open the list, so they start `openingGap` down, clear of the bar's soft edge (owner 2026-10-19 and
    /// 2026-10-20: the blur sat over the tops of the pinned faces; the edge follows the bar and can't be shortened; at
    /// 24 pt its fade still reached 3 pt into the faces). Desktop Look's bar is solid, with no fade to clear.
    /// The room above the list's first block: 40 pt clears the soft edge's fade; the hard edge stops on a straight line
    /// at the bar, so 16 pt is enough there (owner 2026-11-04: use the room the hard bar freed).
    private static var openingGap: CGFloat { TopEdgeStyle.current == .hard ? 16 : 40 }

    private func tileSection(_ environment: NSCollectionLayoutEnvironment, count: Int, first: Bool, joinBelow: Bool = false) -> NSCollectionLayoutSection {
        let width = environment.container.effectiveContentSize.width
        let side: CGFloat = 8, gap: CGFloat = 4
        let tile = floor((width - 2 * side - 2 * gap) / 3)
        let columns = max(1, min(3, count))
        let groupWidth = CGFloat(columns) * tile + CGFloat(columns - 1) * gap
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(tile), heightDimension: .estimated(124)))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .absolute(groupWidth), heightDimension: .estimated(124)),
            repeatingSubitem: item, count: columns)
        group.interItemSpacing = .fixed(gap)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 12
        let inset = max(0, (width - groupWidth) / 2)
        // [mac] Stress test 2026-10-28 round 7: on the Mac the Desktop Look's tiles started 4 pt under the bar (about 6–9
        // on the screen against the iOS look's ~30); there they open with the iOS look's room in both looks.
        let roomy = !Theme.isDesktop || DeviceWord.isMac
        // [top-bar-gap] The iPhone and iPad's Desktop Look: the look's room under its bar's edge, not 4 pt.
        let top = first ? (roomy ? Self.openingGap : 4 + DesktopRows.underBar) : 4
        section.contentInsets = NSDirectionalEdgeInsets(top: top, leading: inset, bottom: 8, trailing: inset)
        BackdropCards.card(section, on: BackdropCards.on(self), keepWidth: true, join: joinBelow ? .below : [])   // [backdrop-cards] the faces' names too
        return section
    }

    /// `first`: rows open the list (no pinned faces, or the faces drawn as rows at accessibility sizes), so they start
    /// `openingGap` down, clear of the bar's edge, as the tiles do (`tileSection`).
    /// `apart`: [mac] the unassigned rows under a section, set off by a header's room without its words.
    private func listSection(_ environment: NSCollectionLayoutEnvironment, first: Bool, apart: Bool = false) -> NSCollectionLayoutSection {
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.backgroundColor = .clear
        // [botsminimal] No rules between the rows, in either look (owner, 2026-10-27).
        config.showsSeparators = false
        config.leadingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            // [groups] A room: Unread (full swipe) and Pin.
            if let self, let room = self.rowRoom(at: indexPath), let groups = self.groups { return GroupActions.leadingSwipes(for: room, services: groups) }
            guard let self, let bot = self.bot(at: indexPath) else { return nil }
            // Settings stream: Unread (full swipe) and Pin (parity §3, `row-swipes.ts`).
            if let organizer = self.organizer { return organizer.leadingActions(for: bot) }
            var list: [UIContextualAction] = []
            if bot.unread {
                let read = UIContextualAction(style: .normal, title: "Read") { [weak self] _, _, done in
                    self?.services.markRead(bot)
                    done(true)
                }
                read.image = UIImage(systemName: BotExtrasRules.readSymbol(unread: true, filled: true))
                read.backgroundColor = HQPalette.tint
                list.append(read)
            }
            guard !list.isEmpty else { return nil }
            let actions = UISwipeActionsConfiguration(actions: list)
            actions.performsFirstActionWithFullSwipe = bot.unread
            return actions
        }
        // Settings stream: trailing More and Mute (full swipe).
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            // [groups] A room: More and Mute (full swipe).
            if let self, let room = self.rowRoom(at: indexPath), let groups = self.groups {
                return GroupActions.trailingSwipes(for: room, services: groups, list: self)
            }
            guard let self, let bot = self.bot(at: indexPath) else { return nil }
            return self.organizer?.trailingActions(for: bot)
        }
        let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
        if first && (!Theme.isDesktop || DeviceWord.isMac) { section.contentInsets.top = Self.openingGap }   // [mac] Round 7: as the tiles
        else if first { section.contentInsets.top += DesktopRows.underBar }   // [top-bar-gap] as the tiles
        if apart { section.contentInsets.top = 24 }
        return section
    }

    // MARK: - Cells

    private func configureDataSource() {
        let rowRegistration = UICollectionView.CellRegistration<SoftCardListCell, String> { [weak self] cell, _, id in
            guard let self, let bot = self.botsByID[id] else { return }
            var actions = self.actions(for: bot)
            actions.moves = self.pinMoveActions(for: bot)   // [a11y] a pinned bot drawn as a row at accessibility sizes
                + self.rowMoveActions(for: bot)              // [manualorder] Move Up / Move Down within its block
            let muted = BotMuteCenter.shared.isMuted(id)
            cell.contentConfiguration = UIHostingConfiguration {
                BotRowView(bot: bot, time: ListTime.string(bot.lastActive), actions: actions, muted: muted)
            }
            .margins(.all, 0)
            cell.accessibilityIdentifier = "bot-row-\(id)"
            // [botslist] A redraw during the swipe peek keeps the row out (the hosting content is new each time).
            DispatchQueue.main.async { [weak self, weak cell] in if let cell { self?.swipePeek.keep(cell) } }
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
        // [perf] A tile's content is built here (this runs again on a reconfigure, so data changes still rebuild it);
        // a press, a release or the deselect run alongside a pop only flips `press`, which dims the face in place.
        let tileRegistration = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            cell.accessibilityIdentifier = "bot-tile-\(id)"
            guard let self, let bot = self.botsByID[id] else { return }
            let press = TilePress(cell.configurationState, marks: self.paneKeepsSelection)
            let moves = self.pinMoveActions(for: bot)
            cell.contentConfiguration = UIHostingConfiguration {
                PinnedTileView(bot: bot, press: press, muted: BotMuteCenter.shared.isMuted(id), moves: moves)
            }
            .margins(.all, 0)
            cell.configurationUpdateHandler = { [weak self] _, state in press.update(state, marks: self?.paneKeepsSelection ?? false) }
            #if targetEnvironment(macCatalyst)
            MacHover.ownsHover(cell) { press.hover($0) }   // [mac] the face's halo, not the rows' square (owner 2026-10-28)
            cell.backgroundConfiguration = .clear()
            #endif
        }
        // [groups] A room's row and its pinned tile (App/Groups/GroupRowView.swift).
        let roomRegistration = UICollectionView.CellRegistration<SoftCardListCell, String> { [weak self] cell, _, id in
            guard let self, let room = self.roomsByID[id], self.groups != nil else { return }
            cell.contentConfiguration = UIHostingConfiguration {
                GroupRowView(room: room, time: ListTime.string(room.time))
            }
            .margins(.all, 0)
            cell.accessibilityIdentifier = "room-row-\(room.name)"
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
        let roomTileRegistration = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            cell.accessibilityIdentifier = "room-tile-\(self?.roomsByID[id]?.name ?? id)"
            guard let room = self?.roomsByID[id] else { return }
            let press = TilePress(cell.configurationState, marks: self?.paneKeepsSelection ?? false)   // [perf] as the bot tile's
            cell.contentConfiguration = UIHostingConfiguration { GroupTileView(room: room, press: press) }
                .margins(.all, 0)
            cell.configurationUpdateHandler = { [weak self] _, state in press.update(state, marks: self?.paneKeepsSelection ?? false) }
            #if targetEnvironment(macCatalyst)
            MacHover.ownsHover(cell) { press.hover($0) }   // [mac] as the bot tile's
            cell.backgroundConfiguration = .clear()
            #endif
        }
        let headerRegistration = UICollectionView.CellRegistration<SoftCardListCell, BotListSectionID> { [weak self] cell, _, id in
            guard let self, let section = self.sections.first(where: { $0.id == id }) else { return }
            let collapsed = self.collapsed.contains(id)
            if case .user(let sectionId) = id, let organizer = self.organizer {
                // Settings stream: a user section's header; [botsminimal] its menu is a hold on the name
                // (`organizer.sectionContextMenu`), VoiceOver gets the same items as actions. The drop target highlights.
                let highlighted = organizer.dropTarget == id
                let actions = organizer.sectionNodes(sectionId).compactMap { node -> BotSectionHeaderView.Action? in
                    guard case .action(let run) = node.kind, !node.disabled else { return nil }
                    return .init(name: node.title, run: run)
                }
                cell.contentConfiguration = UIHostingConfiguration {
                    BotSectionHeaderView(title: section.title ?? "", count: section.bots.count + section.rooms.count, collapsed: collapsed,
                                         unit: section.rooms.isEmpty ? ("bot", "bots") : ("chat", "chats"), actions: actions)
                        .background(highlighted ? Color.hqTint.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .margins(.all, 0)
                cell.accessibilityIdentifier = "section-header-\(section.title ?? "")"
            } else if id == .unassigned {
                // [bots-groupby] Unassigned, once there are sections: its bots and group chats; a drop target lights up.
                let highlighted = self.organizer?.dropTarget == id
                cell.contentConfiguration = UIHostingConfiguration {
                    BotSectionHeaderView(title: section.title ?? "", count: section.bots.count + section.rooms.count, collapsed: collapsed,
                                         unit: section.rooms.isEmpty ? ("bot", "bots") : ("chat", "chats"))
                        .background(highlighted ? Color.hqTint.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .margins(.all, 0)
                cell.accessibilityIdentifier = "section-header-unassigned"
            } else if id == .groups || id != .hidden && id != .pinned && section.bots.isEmpty && !section.rooms.isEmpty
                        || { if case .groupSection = id { true } else { false } }() {
                // [groups] The Group Chats header (every room of the block) and a room sub-block's; a drop target lights up.
                let count = id == .groups ? self.groupBlockCount : section.rooms.count
                let highlighted = self.organizer?.dropTarget == id
                cell.contentConfiguration = UIHostingConfiguration {
                    BotSectionHeaderView(title: section.title ?? "", count: count, collapsed: collapsed, unit: ("group chat", "group chats"))
                        .background(highlighted ? Color.hqTint.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .margins(.all, 0)
                cell.accessibilityIdentifier = id == .groups ? "section-header-groups" : "section-header-group-\(section.title ?? "")"
            } else {
                // The folded faces count too; under Hidden, its rooms (UX study #254), and under Pinned the pinned rooms
                // past the tiles (audit 05-6). With rooms among them VoiceOver says "chats", not "bots" (audit 05-9).
                let count = section.bots.count + (id == .pinned ? self.foldedTileCount : 0) + section.rooms.count
                cell.contentConfiguration = UIHostingConfiguration {
                    BotSectionHeaderView(title: section.title ?? "", count: count, collapsed: collapsed,
                                         unit: section.rooms.isEmpty ? ("bot", "bots") : ("chat", "chats"))
                }
                .margins(.all, 0)
                if case .hidden = id { cell.accessibilityIdentifier = "section-header-hidden" }      // settings stream (UI tests)
            }
            cell.backgroundConfiguration = .clear()
        }
        let hintRegistration = UICollectionView.CellRegistration<SoftCardListCell, String> { cell, _, id in
            if id.hasPrefix("group:") {   // [groups] an empty room sub-block while a room is dragged
                cell.contentConfiguration = UIHostingConfiguration { GroupSectionHintView() }.margins(.all, 0)
                cell.backgroundConfiguration = .clear()
                return
            }
            if id == Self.pinnedOverflowHint {   // under the Pinned section's rows: why they are not tiles
                cell.contentConfiguration = UIHostingConfiguration {
                    BotSectionHintView(text: BotListLayout.pinnedOverflowHint, identifier: "pinned-hint")
                }.margins(.all, 0)
                cell.backgroundConfiguration = .clear()
                return
            }
            cell.contentConfiguration = UIHostingConfiguration { BotSectionHintView() }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        let tokenRegistration = UICollectionView.CellRegistration<SoftCardListCell, String> { [weak self] cell, _, text in
            cell.contentConfiguration = UIHostingConfiguration {
                PageFilterToken(text: text) { self?.clearFilters() }
            }
            .margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        let skeletonRegistration = UICollectionView.CellRegistration<SoftCardListCell, Int> { cell, _, _ in
            cell.contentConfiguration = UIHostingConfiguration { BotSkeletonRowView() }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        // [offline] §4.1, §4.2: the slow-load and stale-list card.
        let noticeRegistration = UICollectionView.CellRegistration<SoftCardListCell, String> { [weak self] cell, _, kind in
            guard let self else { return }
            let text = self.noticeText(kind), busy = kind == "stale" && self.noticeRetrying
            cell.contentConfiguration = UIHostingConfiguration {
                RosterNoticeCard(text: text, busy: busy) { [weak self] in self?.retryFromNotice(kind) }
            }
            .margins(.all, 0)
            cell.backgroundConfiguration = .clear()
            cell.accessibilityIdentifier = "bots.notice.\(kind)"
        }
        // [chats-under] A bot's chat, and its "N more", pressed as a row is.
        let pressed: (UICollectionViewCell, UICellConfigurationState) -> Void = { cell, state in
            #if targetEnvironment(macCatalyst)
            if DeviceWord.isMac { cell.backgroundConfiguration = MacSelection.listRow(state); return }
            #endif
            if Theme.isDesktop { cell.backgroundConfiguration = DesktopLayout.rowBackground(state); return }
            var background = UIBackgroundConfiguration.clear()
            background.backgroundColor = state.isHighlighted || state.isSelected ? HQPalette.cellPressed : .clear
            cell.backgroundConfiguration = background
        }
        let chatRegistration = UICollectionView.CellRegistration<SoftCardListCell, String> { [weak self] cell, _, key in
            guard let self, let row = self.chatRows[key] else { return }
            let tint = Self.chatOwner(.chat(key)).flatMap { self.botsByID[$0] }?.chatsTint ?? .hqStroke
            cell.contentConfiguration = UIHostingConfiguration { BotChatRowView(session: row.session, last: row.last, tint: tint) }
                .margins(.all, 0)
                .minSize(height: 0)   // the row's own height, so its line meets the next row's
            cell.accessibilityIdentifier = "bot-chat-\(row.session.id)"
            cell.configurationUpdateHandler = pressed
        }
        let moreRegistration = UICollectionView.CellRegistration<SoftCardListCell, String> { [weak self] cell, _, id in
            guard let self, let count = self.moreCounts[id] else { return }
            let name = self.botsByID[id]?.name ?? id
            let tint = self.botsByID[id]?.chatsTint ?? .hqStroke
            cell.contentConfiguration = UIHostingConfiguration { BotChatsMoreView(count: count, botName: name, tint: tint) }
                .margins(.all, 0)
                .minSize(height: 0)
            cell.accessibilityIdentifier = "bot-chats-more-\(id)"
            cell.configurationUpdateHandler = pressed
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .row(let id): collectionView.dequeueConfiguredReusableCell(using: rowRegistration, for: indexPath, item: id)
            case .tile(let id): collectionView.dequeueConfiguredReusableCell(using: tileRegistration, for: indexPath, item: id)
            case .header(let id): collectionView.dequeueConfiguredReusableCell(using: headerRegistration, for: indexPath, item: id)
            case .skeleton(let n): collectionView.dequeueConfiguredReusableCell(using: skeletonRegistration, for: indexPath, item: n)
            case .notice(let kind): collectionView.dequeueConfiguredReusableCell(using: noticeRegistration, for: indexPath, item: kind)
            case .hint(let id): collectionView.dequeueConfiguredReusableCell(using: hintRegistration, for: indexPath, item: id)
            case .token(let text): collectionView.dequeueConfiguredReusableCell(using: tokenRegistration, for: indexPath, item: text)
            case .room(let id): collectionView.dequeueConfiguredReusableCell(using: roomRegistration, for: indexPath, item: id)          // [groups]
            case .roomTile(let id): collectionView.dequeueConfiguredReusableCell(using: roomTileRegistration, for: indexPath, item: id)  // [groups]
            case .chat(let key): collectionView.dequeueConfiguredReusableCell(using: chatRegistration, for: indexPath, item: key)       // [chats-under]
            case .more(let id): collectionView.dequeueConfiguredReusableCell(using: moreRegistration, for: indexPath, item: id)          // [chats-under]
            }
        }
    }

    // MARK: - Data

    /// Asks for a reload on the next turn of the run loop, so a burst of roster changes (stream events flipping
    /// `isWorking`, previews) becomes one reload. Off screen (another tab, or a chat pushed over the list) the reload
    /// waits for `viewWillAppear`, so it never competes with a streaming chat.
    func setNeedsReload(animated: Bool = true) {
        guard isViewLoaded else { return }
        guard view.window != nil else { needsReload = true; return }
        // [perf] Mid-slide (a pop, or a swipe back that can last seconds) the change folds into one reload at its end.
        if let coordinator = transitionCoordinator ?? navigationController?.transitionCoordinator {
            needsReload = true
            reloadWhenTransitionEnds(coordinator)
            return
        }
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadPending = false
            self.reload(animated: animated)
        }
    }

    /// [perf] Reloads when `coordinator`'s transition ends, if the list is still on screen and still needs it. A
    /// cancelled swipe back leaves the flag set for the next `viewWillAppear`; one that leaves the list showing (a
    /// cancelled push away) reloads on the next turn.
    private func reloadWhenTransitionEnds(_ coordinator: any UIViewControllerTransitionCoordinator) {
        guard !reloadAfterTransition else { return }
        reloadAfterTransition = true
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            guard let self else { return }
            self.reloadAfterTransition = false
            guard context.isCancelled else {
                if self.needsReload, self.view.window != nil { self.reload(animated: true) }
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.needsReload, self.view.window != nil else { return }
                self.reload(animated: true)
            }
        }
    }

    /// Rebuilds the snapshot from `services.bots` now. Same ids keep their cells; changed rows are reconfigured in
    /// place. Integration: call this (or `MainTabController.connectionDidChange()`) when `services.connection`
    /// changes — the skeleton, the offline empty state and the "Offline" / "Reconnecting…" subtitle read it, and
    /// `AppServices` has no connection callback yet.
    func reload(animated: Bool) {
        guard isViewLoaded else { return }
        needsReload = false
        var seen = Set<String>()
        let bots = services.bots.filter { seen.insert($0.id).inserted }
        botsByID = Dictionary(uniqueKeysWithValues: bots.map { ($0.id, $0) })
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        // [groups] The account's rooms, as rows.
        let rooms = groups?.groupStore?.rows() ?? []
        roomsByID = Dictionary(rooms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        groupBlockCount = 0
        foldedTileCount = 0
        chatRows = [:]
        moreCounts = [:]
        chatsByBot = Dictionary(grouping: services.sessions, by: \.profile)

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if let token = BotsBar.token(kind: kind, activity: activity) {
            snapshot.appendSections([.token])
            snapshot.appendItems([.token(token)])
        }
        if !query.isEmpty || activity != .all {
            // [groups] Show › narrows a search or an Activity filter to bots or to rooms; rooms follow the bots.
            let results = kind == .groups ? [] : BotsBar.results(bots, query: query, activity: activity, showHidden: !collapsed.contains(.hidden))
            // UX study #254: a hidden room is found only while Hidden is open, as a hidden bot.
            let roomResults = kind == .bots ? [] : GroupList.results(rooms.filter { !$0.hidden || !collapsed.contains(.hidden) }, query: query, activity: activity)
            sections = [BotListSection(id: .results, title: nil, bots: results, rooms: roomResults)]
            snapshot.appendSections([.list(.results)])
            snapshot.appendItems(results.map { .row($0.id) } + roomResults.map { .room($0.id) })
        } else if bots.isEmpty, showsSkeleton, rooms.isEmpty || kind == .bots {
            sections = []
            // [offline] §4.1: after 15 s of skeleton the slow card stands over a shorter skeleton.
            if slowShown { snapshot.appendSections([.notice]); snapshot.appendItems([.notice("slow")]) }
            snapshot.appendSections([.loading])
            snapshot.appendItems((0..<(slowShown ? RosterStateCopy.slowSkeletonRows : RosterStateCopy.skeletonRows)).map { .skeleton($0) })
        } else {
            // [offline] §4.2: the last refresh failed and the last good list is still on show.
            if !bots.isEmpty, rosterStates?.rosterFailure != nil { snapshot.appendSections([.notice]); snapshot.appendItems([.notice("stale")]) }
            else { noticeRetryAt = nil }
            let composed = composeSections(bots: bots, rooms: rooms, kind: kind)
            sections = composed.sections
            groupBlockCount = composed.groupCount
            // [morepages] §6: every bot hidden and Hidden folded: the empty state stands in for the lone "Hidden" header.
            let allHidden = showsAllHidden(bots: bots)
            // At accessibility sizes the faces are rows: with pins past the six, they lead the overflow under the one
            // "Pinned" header (pin order kept) instead of sitting headerless above it. Display only: the sections and
            // the Pinned section's model are unchanged.
            let foldTiles = large && sections.contains { $0.id == .pinned && (!$0.bots.isEmpty || !$0.rooms.isEmpty) }
            let tileBots = foldTiles ? sections.first { $0.id == .tiles }?.bots ?? [] : []
            foldedTileCount = tileBots.count
            for section in sections {
                if allHidden, section.id == .hidden { continue }
                if foldTiles, section.id == .tiles, section.rooms.isEmpty { continue }
                snapshot.appendSections([.list(section.id)])
                switch section.id {
                case .tiles:
                    if !foldTiles { snapshot.appendItems(section.bots.map { large ? .row($0.id) : .tile($0.id) }) }
                    snapshot.appendItems(section.rooms.map { large ? .room($0.id) : .roomTile($0.id) })   // [groups]
                case .results: snapshot.appendItems(section.bots.map { .row($0.id) })
                case .unassigned, .everything:
                    // [bots-groupby] With sections, Unassigned has a header and folds; its rooms are among its bots.
                    if section.title != nil { snapshot.appendItems([.header(section.id)]) }
                    // A block without a header can't be folded: rows folded under Unassigned stay listed once its
                    // header goes with the last section (audit 05-1: they vanished, with nothing left to unfold).
                    if !isFolded(section.id) { snapshot.appendItems(withChats(items(section))) }
                case .pinned where BotListLayout.isPinnedRows(section):
                    // [pinned-rows] Pinned Bots › Rows: the pins head the list as rows like the others (their chats under
                    // them too), no header and no fold; the pinned group chats follow the bots.
                    snapshot.appendItems(withChats(section.bots.map { .row($0.id) }) + section.rooms.map { .room($0.id) })
                case .groups:   // [groups]
                    snapshot.appendItems([.header(.groups)])
                    if !collapsed.contains(.groups) { snapshot.appendItems(section.rooms.map { .room($0.id) }) }
                case .groupSection(let id):   // [groups] a user section's rooms, inside Group Chats
                    guard !collapsed.contains(.groups) else { break }
                    snapshot.appendItems([.header(section.id)])
                    if !collapsed.contains(section.id) {
                        snapshot.appendItems(section.rooms.map { .room($0.id) })
                        if section.rooms.isEmpty { snapshot.appendItems([.hint("group:\(id)")]) }
                    }
                default:
                    snapshot.appendItems([.header(section.id)])
                    let lead = section.id == .pinned ? tileBots : []
                    if !collapsed.contains(section.id) {
                        // [bots-groupby] A user section's group chats are drawn among its bots, and so are Pinned's
                        // (pins past the tiles, audit 05-6).
                        if section.id == .hidden { snapshot.appendItems((lead + section.bots).map { .row($0.id) }) }
                        else { snapshot.appendItems(withChats(lead.map { .row($0.id) } + items(section))) }
                    }
                    if section.id == .hidden, !collapsed.contains(section.id) { snapshot.appendItems(section.rooms.map { .room($0.id) }) }   // UX study #254
                    // Past six pins: a line under the Pinned rows says why they are not tiles (with the faces folded in
                    // at accessibility sizes there are no tiles, so no line).
                    if section.id == .pinned, !foldTiles, !collapsed.contains(section.id) {
                        snapshot.appendItems([.hint(Self.pinnedOverflowHint)])
                    }
                    // Settings stream: an empty user section shows how to fill it.
                    if case .user(let id) = section.id, section.bots.isEmpty, section.rooms.isEmpty, !collapsed.contains(section.id) {
                        snapshot.appendItems([.hint(id)])
                    }
                }
            }
        }
        var next: [Item: Int] = [:]
        for item in snapshot.itemIdentifiers { next[item] = signature(item) }
        let changed = snapshot.itemIdentifiers.filter { item in signatures[item].map { $0 != next[item] } ?? false }
        if !changed.isEmpty { snapshot.reconfigureItems(changed) }
        if query.isEmpty {
            AppLog.trace("bots", "list drawn: \(bots.count) bots, \(rooms.count) rooms, \(sections.count) sections, \(changed.count) reconfigured")
        }
        signatures = next
        let animate = animated && view.window != nil && !HQMotion.reduced
        dataSource.apply(snapshot, animatingDifferences: animate)
        // A row starts or stops working: its neighbours' hairlines are asked again.
        let rings = Set(snapshot.itemIdentifiers.filter { item in
            if case .row(let id) = item, let bot = botsByID[id] { return BotList.showsArc(bot) }
            return false
        })
        if rings != ringedRows {
            ringedRows = rings
            // [perf] The Desktop Look hides every hairline anyway: nothing to ask again (a look change invalidates).
            if !Theme.isDesktop { collectionView.collectionViewLayout.invalidateLayout() }
        }
        remarkOnShow()   // [m9/ipad]
        updateEmptyState(bots: bots)
        updateBar()
        updateSubtitle()
        finishRefreshIfNeeded()
        if !bots.isEmpty, view.window != nil { schedulePeek() }   // [botslist] the rows may arrive after the list showed
        armSlowTimer(skeleton: snapshot.sectionIdentifiers.contains(.loading))
    }

    /// The list's blocks for `bots` and `rooms` under Show › `kind`, unfiltered by search or Activity: the tiles, Pinned,
    /// the user sections, the unassigned rows, Group Chats and its sub-blocks, Hidden. Also the Group Chats header's
    /// count. [bots-rail] The Mac's folded rail draws the same blocks (`railSections`).
    private func composeSections(bots: [Bot], rooms: [GroupRowModel], kind: BotKindFilter) -> (sections: [BotListSection], groupCount: Int) {
        var groupCount = 0
        let pinsAsRows = BotPinnedLook.saved == .rows   // [pinned-rows]
        var sections = organizer?.sections() ?? BotList.compose(bots)       // settings stream: by id, empty sections kept
        if pinsAsRows, let tiles = sections.firstIndex(where: { $0.id == .tiles }) {
            // [pinned-rows] The old composer (no store yet) still makes tiles: they lead the pins' rows.
            let pins = sections[tiles].bots + (sections.first { $0.id == .pinned }?.bots ?? [])
            sections.removeAll { $0.id == .tiles || $0.id == .pinned }
            sections.insert(BotListSection(id: .pinned, title: nil, bots: pins), at: 0)
        }
        // [groups] Pinned rooms are tiles after the bots' tiles; the Group Chats block sits before Hidden.
        // Show › Group Chats keeps the user sections, without their bots, so the rooms are filed in them as under Show ›
        // All (audit 05-7: it fell back to the old Group Chats block); the sections no room is in are dropped below.
        if kind == .groups {
            sections = sections.compactMap { section in
                guard case .user = section.id else { return nil }
                return BotListSection(id: section.id, title: section.title, bots: [])
            }
        }
        var loose: [GroupRowModel] = [], filed: [(id: String, name: String, rooms: [GroupRowModel])] = []
        var pinnedRooms: [GroupRowModel] = []
        if kind != .bots, !rooms.isEmpty {
            let botTiles = sections.first { $0.id == .tiles }?.bots.count ?? 0
            let records = (organizer?.editing?.sectionRecords ?? []).filter { $0.id != RosterRules.pinnedSectionId }.map { (id: $0.id, name: $0.name) }
            let plan = GroupList.plan(rooms, freeTiles: pinsAsRows ? 0 : BotList.maxTiles - botTiles, sections: records,
                                      draggingRoom: organizer?.draggingRoom ?? false)
            groupCount = plan.count
            if !plan.tiles.isEmpty {
                if let index = sections.firstIndex(where: { $0.id == .tiles }) { sections[index].rooms = plan.tiles }
                else { sections.insert(BotListSection(id: .tiles, title: nil, bots: [], rooms: plan.tiles), at: 0) }
            }
            loose = plan.loose
            pinnedRooms = plan.overflow
            filed = plan.filed.map { ($0.id, $0.name, $0.rooms) }
            if pinsAsRows, !pinnedRooms.isEmpty {
                // [pinned-rows] Pinned group chats are rows of the pins' block too, after the bots, whatever Group By says.
                let pinned = Set(pinnedRooms.map(\.id))
                loose.removeAll { pinned.contains($0.id) }
                if let index = sections.firstIndex(where: { $0.id == .pinned }) { sections[index].rooms = pinnedRooms }
                else { sections.insert(BotListSection(id: .pinned, title: nil, bots: [], rooms: pinnedRooms), at: 0) }
                pinnedRooms = []
            }
            // UX study #254: hidden rooms sit under Hidden, after the hidden bots (left out under Show › Group Chats,
            // as Hidden is).
            if kind == .all, !plan.hidden.isEmpty {
                if let index = sections.firstIndex(where: { $0.id == .hidden }) { sections[index].rooms = plan.hidden }
                else { sections.append(BotListSection(id: .hidden, title: "Hidden", bots: [], rooms: plan.hidden)) }
            }
        }
        if groupBy == .none {
            // [bots-groupby] Group By › None: one block, rooms among bots by activity.
            sections = BotListLayout.flat(sections, loose: loose + filed.flatMap(\.rooms))
        } else if kind != .groups || !filed.isEmpty,
                  let withRooms = BotListLayout.file(sections, loose: loose.filter { room in !pinnedRooms.contains { $0.id == room.id } },
                                                     filed: filed.map { ($0.id, $0.rooms) }, pinned: pinnedRooms) {
            // [bots-groupby] With user sections, each room is filed with the bots (its section, or Unassigned); pins past
            // the tiles are in Pinned. Show › Group Chats with no room filed anywhere keeps the one Group Chats block.
            sections = withRooms
        } else if !loose.isEmpty || !filed.isEmpty {
            var blocks = [BotListSection(id: .groups, title: "Group Chats", bots: [], rooms: loose)]
            blocks += filed.map { BotListSection(id: .groupSection($0.id), title: $0.name, bots: [], rooms: $0.rooms) }
            sections.insert(contentsOf: blocks, at: sections.firstIndex { $0.id == .hidden } ?? sections.count)
        }
        // Show › Group Chats: a section with no group chat in it is left out (it shows while a room is dragged, to drop on).
        if kind == .groups, !(organizer?.draggingRoom ?? false) {
            sections.removeAll { if case .user = $0.id { $0.rooms.isEmpty } else { false } }
        }
        return (sections, groupCount)
    }

    /// [bots-groupby] A block's bots and group chats as list items, in drawing order.
    private func items(_ section: BotListSection) -> [Item] {
        section.rows().map { row in
            switch row {
            case .bot(let id): .row(id)
            case .room(let id): .room(id)
            }
        }
    }

    /// [chats-under] `items` with each bot's chats under its row, as Filter › Chats Under Bots (or the bot's own choice)
    /// asks: pinned chats, then its newest, then "N more" for the rest. Hidden bots list none (they have no chip in
    /// Sessions), and a bot with nothing to show gets no "N more" either.
    private func withChats(_ items: [Item]) -> [Item] {
        var out: [Item] = []
        out.reserveCapacity(items.count)
        for item in items {
            out.append(item)
            guard case .row(let id) = item, let bot = botsByID[id], !bot.hidden else { continue }
            let picked = BotChatsUnder.pick(chatsByBot[id] ?? [], bot: id, choice: BotChatsPrefs.choice(for: id))
            guard !picked.shown.isEmpty else { continue }
            for (index, session) in picked.shown.enumerated() {
                let key = id + "\u{1F}" + session.id
                guard chatRows[key] == nil else { continue }
                chatRows[key] = (session, index == picked.shown.count - 1 && picked.more == 0)
                out.append(.chat(key))
            }
            if picked.more > 0 {
                moreCounts[id] = picked.more
                out.append(.more(id))
            }
        }
        return out
    }

    /// [chats-under] The bot a chat row or "N more" belongs to.
    private static func chatOwner(_ item: Item) -> String? {
        switch item {
        case .chat(let key): key.split(separator: "\u{1F}", maxSplits: 1).first.map(String.init)
        case .more(let id): id
        default: nil
        }
    }

    #if targetEnvironment(macCatalyst)
    /// [bots-rail] The blocks the folded rail draws: the list's own, under Show › All and with no search or Activity
    /// filter (the rail has neither), so its heads follow the list's order (manual or recent, pins, sections, rooms).
    func railSections() -> [BotListSection] {
        var seen = Set<String>()
        let bots = services.bots.filter { seen.insert($0.id).inserted }
        return composeSections(bots: bots, rooms: groups?.groupStore?.rows() ?? [], kind: .all).sections
    }

    /// [bots-rail] The gateway switcher the Bots title carries, for the rail (which hides that title).
    var gatewaySwitcher: GatewayTitleSwitcher? { titleSwitcher }

    /// [chats-under] [mac] The chats the open sidebar lists under each of `bots` (ids), as `withChats` picks them for the
    /// list: Filter › Chats Under Bots or the bot's own choice. Bots with nothing to show are left out.
    func railChats(for bots: [String]) -> [String: (shown: [SessionSummary], more: Int)] {
        guard BotChatsPrefs.inUse else { return [:] }
        let byBot = Dictionary(grouping: services.sessions, by: \.profile)
        var out: [String: (shown: [SessionSummary], more: Int)] = [:]
        for id in bots {
            let picked = BotChatsUnder.pick(byBot[id] ?? [], bot: id, choice: BotChatsPrefs.choice(for: id))
            if !picked.shown.isEmpty { out[id] = picked }
        }
        return out
    }

    /// [chats-under] [mac] A chat under a bot in the sidebar: it opens beside the sidebar, as its row in the list opens it.
    func openRailChat(_ session: SessionSummary) {
        push(services.chat(for: session))
    }
    #endif

    // MARK: - Slow, stale and failed states [offline] (docs/spec/3x-offline.md §4)

    private var rosterStates: (any RosterStateServices)? { services as? any RosterStateServices }

    /// §4.1: the skeleton gets 15 s, then the list says the gateway is slow. The old 10 s recheck is gone: the
    /// connection now calls back (`onConnectionChange`), and a failed load ends on "Couldn’t Load Bots" by itself.
    private func armSlowTimer(skeleton: Bool) {
        guard skeleton else {
            slowTimer?.invalidate(); slowTimer = nil
            slowShown = false
            return
        }
        guard slowTimer == nil, !slowShown else { return }
        let timer = Timer(timeInterval: RosterStateCopy.slowAfter, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.slowTimer = nil
                self.slowShown = true
                HQAnnounce.say(RosterStateCopy.slowLoad)
                if self.view.window == nil { self.needsReload = true } else { self.reload(animated: true) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        slowTimer = timer
    }

    private func noticeText(_ kind: String) -> String {
        if kind == "slow" { return RosterStateCopy.slowLoad }
        return RosterStateCopy.stale(waiting: services.connection != .ready, updated: rosterStates?.rosterUpdated)
    }

    /// Try Again on either card, and under "Couldn’t Load Bots": read again; dial now when the gateway is not connected.
    /// A read already out on an open socket is joined, never cancelled and asked again (an abandoned read keeps a
    /// gateway worker busy).
    private func retryFromNotice(_ kind: String) {
        if kind == "slow" {
            slowShown = false          // the card leaves and the 15 s start over
        } else {
            noticeRetryAt = Date()
        }
        if let rosterStates { rosterStates.retryRoster() } else { services.refreshBots() }
        reload(animated: true)
    }

    /// Skeleton rows while the first roster is on its way: connecting, or connected with no answer yet. "No Bots Yet"
    /// waits for the roster to say so.
    private var showsSkeleton: Bool {
        switch services.connection {
        case .connecting, .reconnecting: return true
        case .ready: return !services.botsLoaded
        default: return false
        }
    }

    private func signature(_ item: Item) -> Int {
        var hasher = Hasher()
        switch item {
        case .row(let id), .tile(let id):
            hasher.combine(botsByID[id])
            hasher.combine(ListTime.string(botsByID[id]?.lastActive))
            hasher.combine(BotMuteCenter.shared.isMuted(id))
            hasher.combine(BotMuteCenter.shared.mute(of: id)?.until)   // a timed mute's end is in the VoiceOver label
            hasher.combine(pinnedTileIDs.firstIndex(of: id))   // [a11y] its Move Earlier / Move Later follow its place
            hasher.combine(pinnedTileIDs.count)
            if let bot = botsByID[id] { hasher.combine(organizer?.rowMoves(for: bot).map(\.delta)) }   // [manualorder] its Move Up / Down
        case .room(let id), .roomTile(let id):   // [groups]
            hasher.combine(roomsByID[id])
            hasher.combine(ListTime.string(roomsByID[id]?.time))
        case .header(let id):
            let section = sections.first { $0.id == id }
            hasher.combine(section?.title)
            hasher.combine(section?.bots.count)
            hasher.combine(section?.rooms.count)                                    // [groups]
            if id == .groups { hasher.combine(groupBlockCount) }
            if id == .pinned { hasher.combine(foldedTileCount) }
            hasher.combine(collapsed.contains(id))
            hasher.combine(organizer?.dropTarget == id)                             // settings stream
            if case .user(let sectionId) = id, let moves = organizer?.sectionMenu(sectionId) { hasher.combine(moves.canUp); hasher.combine(moves.canDown) }   // VoiceOver's actions
        case .hint(let id), .token(let id):
            hasher.combine(id)
        case .skeleton(let n):
            hasher.combine(n)
        case .notice(let kind):
            hasher.combine(noticeText(kind))
            hasher.combine(noticeRetrying)
        case .chat(let key):   // [chats-under]
            let row = chatRows[key]
            hasher.combine(BotChatsStyle.saved)
            hasher.combine(row?.session)
            hasher.combine(row?.last)
            hasher.combine(ListTime.string(row?.session.lastActive))
        case .more(let id):
            hasher.combine(moreCounts[id])
            hasher.combine(BotChatsStyle.saved)
            hasher.combine(botsByID[id]?.name)
        }
        return hasher.finalize()
    }

    /// [morepages] §6: every bot is hidden, nothing else is listed and the Hidden section is folded.
    private func showsAllHidden(bots: [Bot]) -> Bool {
        guard kind != .groups, !showsSkeleton || !bots.isEmpty else { return false }
        // Only the group chats listed: a hidden one is folded under Hidden with the bots (audit 05-18).
        let listedRooms = kind == .bots ? 0 : roomsByID.values.filter { !$0.hidden }.count
        return BotList.emptyState(bots: bots.count, hidden: bots.filter(\.hidden).count, rooms: listedRooms,
                                  query: query, filtered: activity != .all, hiddenShown: !collapsed.contains(.hidden)) == .allHidden
    }

    private func updateEmptyState(bots: [Bot]) {
        var config: UIContentUnavailableConfiguration?
        let noResults = sections.first.map { $0.bots.isEmpty && $0.rooms.isEmpty } ?? true   // [groups] rooms count too
        if !query.isEmpty, noResults {
            config = .search()
        } else if kind == .groups, activity == .all, roomsByID.isEmpty {
            // [groups] Show › Group Chats with none (docs/spec/3x-groups.md §7.10).
            var empty = UIContentUnavailableConfiguration.empty().hqScaled()
            // At the largest text sizes the picture goes: the words and the button need the room (it ran under the token).
            empty.image = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? nil : UIImage(systemName: "person.2")
            empty.text = "No Group Chats"
            empty.secondaryText = "A group chat lets 2 to 6 bots talk together."
            if let make = BotMenuHooks.newGroupChat, BotMenuHooks.newGroupChatDisabledReason?() == nil {
                var button = UIButton.Configuration.hqPush()
                button.title = "New Group Chat"
                empty.button = button
                empty.buttonProperties.primaryAction = UIAction { [weak self] _ in if let self { make(self) } }
            }
            config = empty
        } else if activity != .all, noResults {
            var empty = UIContentUnavailableConfiguration.empty().hqScaled()
            empty.image = UIImage(systemName: "line.3.horizontal.decrease.circle")
            empty.text = kind == .groups ? "No Group Chats" : "No Bots"                                                    // [groups]
            empty.secondaryText = kind == .groups ? "No group chat matches \(activity.title)." : "No bot matches \(activity.title)."
            var clear = UIButton.Configuration.hqPush()
            clear.title = "Clear Filters"
            empty.button = clear
            empty.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.clearFilters() }
            config = empty
        } else if showsAllHidden(bots: bots) {
            // [morepages] 3x-morepages §6 (`S/ui-bots/roster-empty.tsx:18-19`).
            var empty = UIContentUnavailableConfiguration.empty().hqScaled()
            empty.image = UIImage(systemName: BotListEmpty.allHiddenSymbol)
            empty.text = BotListEmpty.allHiddenTitle
            empty.secondaryText = BotListEmpty.allHiddenText
            var show = UIButton.Configuration.hqPush()   // [desktoplook3] outlined in the look
            show.title = BotListEmpty.allHiddenButton
            empty.button = show
            empty.buttonProperties.primaryAction = UIAction { [weak self] _ in
                Haptics.play(.selection)
                self?.setSection(.hidden, collapsed: false)
            }
            config = empty
        } else if query.isEmpty, bots.isEmpty, !showsSkeleton, roomsByID.isEmpty || kind == .bots {
            var empty = UIContentUnavailableConfiguration.empty().hqScaled()
            // [offline] §4.3: "Couldn’t Load Bots" with a reason in words and Try Again; a raw code is never shown.
            let failure = rosterStates?.rosterFailure
            var offline = false
            if case .offline = services.connection { offline = true }
            if failure != nil || offline {
                empty.image = UIImage(systemName: "exclamationmark.circle")
                empty.text = RosterStateCopy.cantLoadTitle
                empty.secondaryText = RosterStateCopy.cantLoadReason(connected: services.connection == .ready, busy: failure?.busy ?? false,
                                                                     words: rosterStates?.rosterFailureWords)
                var retry = UIButton.Configuration.hqPush()
                retry.title = RosterStateCopy.tryAgain
                empty.button = retry
                empty.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.retryFromNotice("failed") }
            } else {
                empty.image = UIImage(systemName: "person.2")
                empty.text = "No Bots Yet"
                // A bot can be made right here (the bar's + › New Bot); the button is that same flow.
                if let organizer, organizer.editing != nil {
                    empty.secondaryText = "Make a bot here or in Hermes, and it shows up here."
                    var make = UIButton.Configuration.hqPush()
                    make.title = "New Bot"
                    empty.button = make
                    empty.buttonProperties.primaryAction = UIAction { [weak organizer] _ in organizer?.newBot() }
                } else {
                    empty.secondaryText = "Bots you make in Hermes show up here."
                }
            }
            config = empty
        }
        emptyConfiguration = config
    }

    /// A link problem shows under the title only once it has lasted this long: the line changes the bar's height, and
    /// a blip (a gateway restart now reconnects in about a second) must not bounce the whole list.
    static let subtitleDelay: TimeInterval = 2
    private var subtitleTimer: Timer?

    /// The gateway link's state, under the title ("Offline" / "Reconnecting…", status ranking #1, spec 02 §6.5).
    private func updateSubtitle() {
        // Settings stream: with two or more gateways the switcher's subtitle is always there ("Offline · Studio").
        if let titleSwitcher, titleSwitcher.isActive { subtitleTimer?.invalidate(); subtitleTimer = nil; titleSwitcher.apply(); return }
        // [offline] §5.1, §5.2: one reading for every header and the reconnect notice ("Offline" after 120 s of
        // reconnecting, "Signed Out" once the gateway ended the session).
        let subtitle = OutageClock.shared.words(services.connection)
        guard navigationItem.subtitle != subtitle else { subtitleTimer?.invalidate(); subtitleTimer = nil; return }
        if subtitle != nil && navigationItem.subtitle == nil {
            // Appearing: wait out a blip first.
            guard subtitleTimer == nil else { return }
            let timer = Timer(timeInterval: Self.subtitleDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.subtitleTimer = nil
                    self?.applySubtitle()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            subtitleTimer = timer
            return
        }
        subtitleTimer?.invalidate()
        subtitleTimer = nil
        applySubtitle()
    }

    /// Sets the line for the current state; the bar and the list move together, in one short animation, not a jump.
    private func applySubtitle() {
        if let titleSwitcher, titleSwitcher.isActive { titleSwitcher.apply(); return }      // settings stream
        // [offline] §5.1, §5.2: one reading for every header and the reconnect notice ("Offline" after 120 s of
        // reconnecting, "Signed Out" once the gateway ended the session).
        let subtitle = OutageClock.shared.words(services.connection)
        guard navigationItem.subtitle != subtitle else { return }
        let heightChanges = (subtitle == nil) != (navigationItem.subtitle == nil)
        guard heightChanges, view.window != nil, !HQMotion.reduced, let navigation = navigationController else {
            navigationItem.subtitle = subtitle
            navigationController?.navigationBar.setNeedsLayout()
            navigationController?.view.setNeedsLayout()
            return
        }
        navigation.view.layoutIfNeeded()
        UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {   // motion-ok: Reduce Motion returned in the guard above
            self.navigationItem.subtitle = subtitle
            navigation.navigationBar.setNeedsLayout()
            navigation.view.setNeedsLayout()
            navigation.view.layoutIfNeeded()
        }
    }

    /// [groups] The room of a row or tile, and of a row only (what a swipe or a drag takes).
    private func room(at indexPath: IndexPath) -> GroupRowModel? {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .room(let id), .roomTile(let id): return roomsByID[id]
        default: return nil
        }
    }

    func rowRoom(at indexPath: IndexPath) -> GroupRowModel? {
        if case .room(let id) = dataSource.itemIdentifier(for: indexPath) { return roomsByID[id] }
        return nil
    }

    /// The row at `indexPath` wears the working ring.
    private func ringed(_ indexPath: IndexPath) -> Bool {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return false }
        return ringedRows.contains(item)
    }

    private func bot(at indexPath: IndexPath) -> Bot? {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .row(let id), .tile(let id): return botsByID[id]
        default: return nil
        }
    }

    // MARK: - Actions

    private func actions(for bot: Bot) -> BotRowActions {
        BotRowActions(open: { [weak self] in self?.open(bot.id) },
                      markRead: { [weak self] in self?.markRead(bot.id) })
    }

    /// Opens the bot's chat: the chat model is built from cache synchronously, then pushed — at once when it has rows
    /// to show, else as soon as its first rows land (at most 0.35 s), so the push never slides in blank.
    func open(_ id: String) {
        // [botslist] The pick may come while this list has never been on screen (a launch that lands on Sessions or in a
        // chat; Bot Info › Bot Chat from there): its own rows are then stale or empty, so the bot is looked up in the
        // roster itself, and a pick made before the first roster arrives waits for it (parity §3 L227).
        guard let bot = botsByID[id] ?? services.bots.first(where: { $0.id == id }) else {
            if !services.botsLoaded { pendingOpen = (id, Date().addingTimeInterval(Self.pendingOpenWait)) }
            return
        }
        pendingOpen = nil
        guard let navigation = navigationController, !opening else { return }
        if paneKeepsSelection, onShowKey == id { return }   // [m9/ipad] already on show beside the list: nothing is built
        // [botslist] Asked while another tab shows (and this page was perhaps never built): the chat opens where it can
        // be seen, on the Bots tab (L227).
        if !isViewLoaded || view.window == nil, let tabs = navigation.tabBarController, tabs.selectedViewController !== navigation,
           navigation.splitViewController == nil {
            tabs.selectedViewController = navigation
        }
        Haptics.play(.soft)
        let chat = makeChat(services.chat(for: bot))
        chat.hidesBottomBarWhenPushed = true
        chat.navigationItem.largeTitleDisplayMode = .never
        opening = true
        ChatViewController.push(chat, on: navigation) { [weak self] in
            self?.opening = false
            // [botslist] A pick made from a search ends the search: Back shows the whole list (L174).
            if let self, self.isViewLoaded, self.searchController.isActive || !self.query.isEmpty { self.endSearchForPick() }
        }
        // No read here: the dot clears once this open applied fresh history (spec 02 §6.7, `AppModel.chatOpened`).
    }

    /// A chat push is waiting for its first rows: further taps wait too.
    private var opening = false

    /// [botslist] A pick made before the roster knew the bot: opened when the roster brings it, dropped after 10 s
    /// (the chat cannot open without its bot). The newest pick replaces an older one.
    private var pendingOpen: (id: String, until: Date)?
    static let pendingOpenWait: TimeInterval = 10

    private func openPendingIfReady() {
        guard let pending = pendingOpen else { return }
        guard Date() < pending.until else { pendingOpen = nil; return }
        if services.bots.contains(where: { $0.id == pending.id }) { open(pending.id) }
    }

    /// [botslist] A pick from elsewhere is about to open a chat over this list: a search in progress ends first, so
    /// coming Back shows the whole list (parity §3 L174, `S/ui-bots/list-close.ts`).
    func endSearchForPick() {
        guard isViewLoaded else { return }
        if searchController.isActive { searchController.isActive = false }
        if !query.isEmpty {
            searchController.searchBar.text = ""
            query = ""
            reload(animated: false)
        }
        bar?.updateSearchState()
    }

    // MARK: [m9/ipad] Two panes (App/Root/PaneRouter.swift)

    /// Two panes: the row of the chat on show stays marked while the list shows.
    private var paneKeepsSelection = false
    /// The bot whose chat the right pane shows (kept so the mark comes back after the list reloads).
    private var onShowKey: String?
    /// [groups] The group chat the right pane shows (its room key), marked like a bot's row.
    private var onShowRoom: String?

    /// After the list's rows changed: the mark is put back (a relaunch reopens the chat before the list has rows).
    private func remarkOnShow() {
        if paneKeepsSelection, onShowKey != nil || onShowRoom != nil {
            markOnShow(onShowKey, room: onShowRoom, keepsSelection: true)
        }
    }

    /// Marks the row (and tile) of the bot whose chat the right pane shows, or of the group chat (`room`); nil clears it.
    func markOnShow(_ id: String?, room: String? = nil, keepsSelection: Bool) {
        paneKeepsSelection = keepsSelection
        onShowKey = keepsSelection ? id : nil
        onShowRoom = keepsSelection ? room : nil
        guard isViewLoaded, dataSource != nil else { return }
        let items = (id.map { [Item.row($0), Item.tile($0)] } ?? []) + (room.map { [Item.room($0), Item.roomTile($0)] } ?? [])
        let paths = items.compactMap { dataSource.indexPath(for: $0) }
        for path in collectionView.indexPathsForSelectedItems ?? [] where !paths.contains(path) {
            collectionView.deselectItem(at: path, animated: false)
        }
        paths.forEach { collectionView.selectItem(at: $0, animated: false, scrollPosition: []) }
    }

    /// The bots and group chats as the list shows them now, top to bottom (Next / Previous Chat walk this order). A
    /// group chat's key is `walkKey(room:)`; `walkOpen` opens either.
    var paneOrder: [String] {
        guard isViewLoaded, dataSource != nil else { return [] }
        var seen = Set<String>()
        return dataSource.snapshot().itemIdentifiers.compactMap { item -> String? in
            switch item {
            case .row(let id), .tile(let id): return seen.insert(id).inserted ? id : nil
            case .room(let key), .roomTile(let key):   // [groups]
                let walk = Self.walkKey(room: key)
                return seen.insert(walk).inserted ? walk : nil
            default: return nil
            }
        }
    }

    /// [groups] A group chat in `paneOrder`: its key behind a mark no bot id carries.
    private static let roomWalkMark = "room\u{1F}"
    static func walkKey(room key: String) -> String { roomWalkMark + key }

    /// Next / Previous Chat's pick: a bot's chat, or a group chat (`walkKey(room:)`).
    func walkOpen(_ key: String) {
        if key.hasPrefix(Self.roomWalkMark) { openRoom(String(key.dropFirst(Self.roomWalkMark.count))) } else { open(key) }
    }

    /// A new chat with the bot (row menu › New Chat, Bot Info › New Chat), pushed over the list like its Bot Chat.
    func openNewChat(_ bot: Bot) {
        guard let starter = services as? BotChatStarting else { return }
        push(starter.newChat(for: bot, folder: nil))
    }

    /// Pushes a chat for `model` over the list (Bot Info's recent chats and New Chat).
    func push(_ model: any ChatSessionModel) {
        guard let navigation = navigationController, !opening else { return }
        Haptics.play(.soft)
        let chat = makeChat(model)
        chat.hidesBottomBarWhenPushed = true
        chat.navigationItem.largeTitleDisplayMode = .never
        opening = true
        ChatViewController.push(chat, on: navigation) { [weak self] in self?.opening = false }
    }

    /// The cell showing a bot (its row or tile), for anchoring a sheet or a tip.
    func cellView(for id: String) -> UICollectionViewCell? {
        for item in [Item.row(id), .tile(id), .room(id), .roomTile(id)] {   // [groups] a room's cell by its key
            if let indexPath = dataSource.indexPath(for: item), let cell = collectionView.cellForItem(at: indexPath) { return cell }
        }
        return nil
    }

    #if targetEnvironment(macCatalyst)
    /// [mac] Mac polish #32: a bot's (or group chat's, by its key) row in the Mac's sidebar (`MainTabController` sets
    /// it). The Mac's bots are there, the list folded out of sight, so a question or tip points at that row.
    var sidebarRow: ((String) -> UIView?)?
    #endif

    /// What a bot's (or group chat's, by its key) question or tip points at: its cell, or [mac] its sidebar row while
    /// the list is out of sight (Mac polish #32: Delete Bot…'s question came out near the window's left edge, from a
    /// cell off it).
    func anchorView(for id: String) -> UIView? {
        #if targetEnvironment(macCatalyst)
        if listOutOfSight, let row = sidebarRow?(id) { return row }
        #endif
        return cellView(for: id)
    }

    #if targetEnvironment(macCatalyst)
    /// Out of the window, or under a hidden pane (the Bots list folded into the sidebar).
    private var listOutOfSight: Bool {
        guard let shown = viewIfLoaded, shown.window != nil else { return true }
        var view: UIView? = shown
        while let next = view {
            if next.isHidden { return true }
            view = next.superview
        }
        return false
    }
    #endif

    /// The first mute's one-time tip, on the bell it put on the row (once its row has redrawn). [mac] Beside the bot's
    /// sidebar row while the list is out of sight (Mac polish #32).
    func showMuteTip(for id: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, !UserDefaults.standard.bool(forKey: BotMuteCenter.tipSeenKey), let anchor = self.anchorView(for: id) else { return }
            let tip = MuteTipController()
            guard let popover = tip.popoverPresentationController else { return }
            popover.sourceView = anchor
            let presenter: UIViewController
            if let cell = anchor as? UICollectionViewCell {
                guard self.view.window != nil, self.presentedViewController == nil else { return }
                presenter = self
                // The bell sits on the row's second line, before its pin and unread marks; on a tile, beside the name.
                popover.sourceRect = cell.bounds.height > 100 && cell.bounds.width < 200
                    ? CGRect(x: cell.bounds.midX - 10, y: cell.bounds.maxY - 24, width: 20, height: 20)
                    : CGRect(x: cell.bounds.maxX - 76, y: cell.bounds.midY + 4, width: 24, height: 20)
                popover.permittedArrowDirections = [.up, .down]
            } else {
                // [mac] Beside the sidebar row, from its window (the list may be out of it).
                guard let root = anchor.window?.rootViewController, root.presentedViewController == nil else { return }
                presenter = root
                popover.sourceRect = anchor.bounds
                popover.permittedArrowDirections = [.left, .right]
            }
            BotMuteCenter.shared.markTipSeen()
            presenter.present(tip, animated: true)
        }
    }

    private func markRead(_ id: String) {
        guard let bot = botsByID[id], bot.unread else { return }
        services.markRead(bot)
    }

    /// Whether a block's rows are folded away. A block drawn without a header (the unassigned rows once the last user
    /// section is gone) never is, whatever was folded while it had one: nothing would be left to unfold it.
    private func isFolded(_ id: BotListSectionID) -> Bool {
        collapsed.contains(id) && sections.first { $0.id == id }.map { $0.title != nil } ?? true
    }

    /// Collapses or expands a section (session-only state).
    func setSection(_ section: BotListSectionID, collapsed isCollapsed: Bool) {
        if isCollapsed { collapsed.insert(section) } else { collapsed.remove(section) }
        reload(animated: true)
    }

    /// Fills the search field and filters the list, as typing would.
    func search(_ text: String) {
        bar.openSearch()
        searchController.searchBar.text = text
        updateSearchResults(for: searchController)
    }

    // MARK: - Bar (`S/ui-bots/roster-bar.tsx`)

    /// [filters-only] Filter is always on the bar, as Sessions' is (owner 2026-11-03: it waited for 8 bots, a second
    /// gateway or a hidden bot, so a short list never reached Sort By › Manual). The bar only says whether a filter is
    /// on; [groups] its token names both filters.
    private func updateBar() {
        bar.setFilterActive(BotsBar.filtersActive(kind: kind, activity: activity), token: BotsBar.token(kind: kind, activity: activity))
    }

    /// Activity ›, Sort By ›, then Show Hidden Bots (N) and Clear Filters (`S/ui-bots/roster-filters.ts`).
    /// [filters-only] Filters only (owner 2026-11-03): no Switch Gateway here, the title's switcher holds the gateways
    /// (the same items, with Add Gateway… and Manage Gateways…).
    private func filterMenu() -> [UIMenuElement] {
        let choices = BotActivityFilter.allCases.map { choice in
            UIAction(title: choice.title, state: choice == activity ? .on : .off) { [weak self] _ in self?.setActivity(choice) }
        }
        var items: [UIMenuElement] = [
            UIMenu(title: "Activity", subtitle: activity.title, image: UIImage(systemName: "clock.arrow.circlepath"),
                   options: .singleSelection, children: choices),
        ]
        items += arrangeMenus()
        items.append(chatsUnderMenu())   // [chats-under]
        if groups != nil {   // [groups] Show › (All, Bots, Group Chats) leads the menu
            let kinds = BotKindFilter.allCases.map { choice in
                let action = UIAction(title: choice.title, state: choice == kind ? .on : .off) { [weak self] _ in self?.setKind(choice) }
                action.accessibilityIdentifier = "filter.show.\(choice.rawValue)"
                return action
            }
            items.insert(UIMenu(title: "Show", subtitle: kind.title, image: UIImage(systemName: "person.2"), options: .singleSelection, children: kinds), at: 0)
        }
        var tail: [UIMenuElement] = []
        if let hidden = showHiddenAction() { tail.append(hidden) }
        if activity != .all || kind != .all {   // [groups]
            tail.append(UIAction(title: "Clear Filters", image: UIImage(systemName: "xmark")) { [weak self] _ in self?.clearFilters() })
        }
        if !tail.isEmpty { items.append(UIMenu(options: .displayInline, children: tail)) }
        return items
    }

    /// Filter › Show Hidden Bots (N), nil with nothing hidden. Hidden rooms count too (UX study #254): the item opens the
    /// one Hidden section. Only what the Show filter puts there: rooms under Show › All, bots unless it is Show › Groups.
    /// [mac] The Mac's sidebar offers it on its right click (`changed` redraws it), read from the roster: the list it
    /// fills is never on show there.
    func showHiddenAction(changed: @escaping () -> Void = {}) -> UIAction? {
        var seen = Set<String>()
        let hiddenBots = services.bots.filter { $0.hidden && seen.insert($0.id).inserted }.count
        let hiddenRooms = (groups?.groupStore?.rows() ?? []).filter(\.hidden).count
        let hiddenCount = (kind == .groups ? 0 : hiddenBots) + (kind == .all ? hiddenRooms : 0)
        guard hiddenCount > 0 else { return nil }
        let showing = railShowsHidden
        return UIAction(title: "Show Hidden Bots (\(hiddenCount))", image: UIImage(systemName: "eye"),
                        state: showing ? .on : .off) { [weak self] _ in
            Haptics.play(.selection)
            self?.setSection(.hidden, collapsed: showing)
            changed()
        }
    }

    /// The Hidden section is open (Show Hidden Bots).
    var railShowsHidden: Bool { !collapsed.contains(.hidden) }

    /// The Filter menu's Sort By › and Group By ›. `changed` runs after a pick. [mac] Mac polish #30: the Mac's sidebar
    /// offers them on its right click: its bots follow both, and the Filter button is never on show there.
    func arrangeMenus(changed: @escaping () -> Void = {}) -> [UIMenuElement] {
        var items: [UIMenuElement] = []
        if organizer?.editing != nil {   // [manualorder] Sort By › Recent Activity, Manual
            let sorts = BotSortOrder.allCases.map { choice in
                let action = UIAction(title: choice.title, state: choice == sortOrder ? .on : .off) { [weak self] _ in
                    self?.setSort(choice)
                    changed()
                }
                action.accessibilityIdentifier = "filter.sort.\(choice.rawValue)"
                return action
            }
            items.append(UIMenu(title: "Sort By", subtitle: sortOrder.title, image: UIImage(systemName: "arrow.up.arrow.down"),
                                options: .singleSelection, children: sorts))
        }
        // [bots-groupby] Group By › Sections, None (tester 2026-11-05).
        let groupings = BotGroupBy.allCases.map { choice in
            let action = UIAction(title: choice.title, state: choice == groupBy ? .on : .off) { [weak self] _ in
                self?.setGroupBy(choice)
                changed()
            }
            action.accessibilityIdentifier = "filter.groupby.\(choice.rawValue)"
            return action
        }
        items.append(UIMenu(title: "Group By", subtitle: groupBy.title, image: UIImage(systemName: "square.stack.3d.up"),
                            options: .singleSelection, children: groupings))
        // [pinned-rows] Pinned Bots › Faces, Rows (owner 2026-11-08).
        let looks = BotPinnedLook.allCases.map { choice in
            let action = UIAction(title: choice.title, subtitle: choice.subtitle, state: choice == BotPinnedLook.saved ? .on : .off) { [weak self] _ in
                self?.setPinnedLook(choice)
                changed()
            }
            action.accessibilityIdentifier = "filter.pinned.\(choice.rawValue)"
            return action
        }
        items.append(UIMenu(title: "Pinned Bots", subtitle: BotPinnedLook.saved.title, image: UIImage(systemName: "pin"),
                            options: .singleSelection, children: looks))
        return items
    }

    /// [pinned-rows] Filter › Pinned Bots: the pins drawn again as faces or as rows, kept on this device.
    func setPinnedLook(_ next: BotPinnedLook) {
        guard next != BotPinnedLook.saved else { return }
        Haptics.play(.selection)
        BotPinnedLook.saved = next
        AppLog.note("bots", "pinned bots as \(next.rawValue)")
        reload(animated: true)
    }

    /// [chats-under] Filter › Chats Under Bots: Off, Pinned Only, Pinned + Recent, and how many recent chats. [mac] The
    /// Mac's sidebar offers it on its right click too (the Filter button is never on show there).
    func chatsUnderMenu() -> UIMenu {
        let all = BotChatsPrefs.all
        let nodes = BotChatsChoice.menuNodes(current: all, own: nil, all: all) { [weak self] picked in
            self?.setChatsUnder(picked ?? .standard)
        }
        let menu = UIMenu(title: "Chats Under Bots", image: UIImage(systemName: "bubble.left.and.bubble.right"),
                          children: UIMenuBuilderResult.elements(nodes))
        menu.subtitle = all.summary
        return menu
    }

    func setChatsUnder(_ next: BotChatsChoice) {
        guard next != BotChatsPrefs.all else { return }
        Haptics.play(.selection)
        BotChatsPrefs.all = next
        AppLog.trace("bots", "chats under bots: \(next.stored)")
        reload(animated: true)
    }

    /// [chats-under] A bot's own choice from its hold menu (nil: same as all bots).
    func setChatsUnder(_ next: BotChatsChoice?, for bot: String) {
        guard next != BotChatsPrefs.own(bot) else { return }
        Haptics.play(.selection)
        BotChatsPrefs.setOwn(next, for: bot)
        AppLog.trace("bots", "chats under bot \(AppLog.tag(bot)): \(next?.stored ?? "same as all")")
        reload(animated: true)
    }

    /// [chats-under] "N more": Sessions lists the bot's chats, its chip picked (as Bot Info's All Chats does).
    func openAllChats(of id: String) {
        guard let root = MainTabController.current else { return }
        Haptics.play(.soft)
        root.select(.sessions)
        let list = root.sessionsViewController
        list.navigationController?.popToRootViewController(animated: false)
        list.pickBot(id)
    }

    func setActivity(_ next: BotActivityFilter) {
        guard next != activity else { return }
        Haptics.play(.selection)
        activity = next
        reload(animated: true)
    }

    /// [bots-groupby] Filter › Group By: the list drawn again, sections or one list.
    func setGroupBy(_ next: BotGroupBy) {
        guard next != groupBy else { return }
        Haptics.play(.selection)
        groupBy = next
        AppLog.note("bots", "group by \(next.rawValue)")
        reload(animated: true)
    }

    /// [manualorder] Filter › Sort By, kept on this device for the gateway account (`BotStore.rowsManual`).
    var sortOrder: BotSortOrder { organizer?.editing?.rowsManual == true ? .manual : .recent }

    /// Sort By › Manual keeps every row where it is now; Recent Activity drops the saved order.
    func setSort(_ next: BotSortOrder) {
        guard next != sortOrder, let editing = organizer?.editing else { return }
        Haptics.play(.selection)
        editing.setRowsManual(next == .manual)
        reload(animated: true)
    }

    func clearFilters() {
        if kind != .all {   // [groups]
            kind = .all
            // Only Show was set: `setActivity` has nothing to change, so the tick is played here.
            if activity == .all { Haptics.play(.selection); reload(animated: true) }
        }
        setActivity(.all)
    }

    /// [groups] Filter › Show.
    func setKind(_ next: BotKindFilter) {
        guard next != kind else { return }
        Haptics.play(.selection)
        kind = next
        reload(animated: true)
    }

    /// [groups] Opens a room over the list (its unread mark clears as it shows).
    func openRoom(_ key: String) {
        guard !opening else { return }
        groups?.openRoom(key, from: self)
    }

    private func toggle(_ section: BotListSectionID) {
        Haptics.play(.selection)
        if collapsed.contains(section) { collapsed.remove(section) } else { collapsed.insert(section) }
        reload(animated: true)
    }

    private func pulledToRefresh() {
        refreshStarted = Date()
        refreshGeneration += 1
        let generation = refreshGeneration
        services.refreshBots()
        BotFaces.shared.refreshAll()       // [photoheads] a pull also looks at the bots' pictures again
        // Never spin forever if the roster doesn't answer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.refreshGeneration == generation else { return }
            self.endRefreshing()
        }
    }

    private func finishRefreshIfNeeded() {
        guard let started = refreshStarted else { return }
        let wait = max(0, 0.6 - Date().timeIntervalSince(started))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.endRefreshing() }
    }

    private func endRefreshing() {
        refreshStarted = nil
        if collectionView.refreshControl?.isRefreshing == true { collectionView.refreshControl?.endRefreshing() }
    }

    func showAccount() {
        let account = AccountViewController(services: services)
        present(account, animated: true)
    }

    // MARK: - UICollectionViewDelegate

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        if case .skeleton = dataSource.itemIdentifier(for: indexPath) { return false }
        return true
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .row, .tile, .room, .roomTile, .chat, .more: return true
        // Settings stream fix: a collection view selects only what it may highlight, so a header tap never toggled its
        // section (Hidden stayed shut). Its background is clear: nothing shows.
        case .header: return true
        default: return false
        }
    }

    /// A finger rests on a bot: read its chat now, so the open that may follow paints at once (spec 03 §4.1).
    func collectionView(_ collectionView: UICollectionView, didHighlightItemAt indexPath: IndexPath) {
        swipePeek.cancel()   // [botslist] a tap during the peek opens the chat as usual
        guard let bot = bot(at: indexPath) else { return }
        services.prefetchChat(for: bot)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .row(let id), .tile(let id): open(id)
        case .room(let key), .roomTile(let key): openRoom(key)   // [groups]
        case .chat(let key):   // [chats-under]
            if let session = chatRows[key]?.session { push(services.chat(for: session)) }
        case .more(let id):
            collectionView.deselectItem(at: indexPath, animated: true)
            openAllChats(of: id)
        case .header(let section):
            collectionView.deselectItem(at: indexPath, animated: false)
            toggle(section)
        default:
            collectionView.deselectItem(at: indexPath, animated: false)
        }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        // [groups] A room's menu: Group Info, Pin, Mute, Mark as Unread, Move to Section (with sections), Delete Group Chat.
        if let indexPath = indexPaths.first, let room = room(at: indexPath), let groups {
            let source = collectionView.cellForItem(at: indexPath)
            return UIContextMenuConfiguration(identifier: room.id as NSString, previewProvider: nil) { [weak self, weak source] _ in
                guard let self else { return nil }
                return BotMenuNode.uiMenu(self.roomMenuNodes(room, services: groups, source: { source }), title: room.name).menu
            }
        }
        // [botsminimal] A user section's name: Rename…, Move Up, Move Down, Delete Section.
        if let indexPath = indexPaths.first, case .header(.user(let sectionId)) = dataSource.itemIdentifier(for: indexPath), let organizer {
            return organizer.sectionContextMenu(sectionId)
        }
        guard let indexPath = indexPaths.first, let bot = bot(at: indexPath) else { return nil }
        if let organizer { return organizer.contextMenu(for: bot) }                 // settings stream: the full row menu
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let open = UIAction(title: "Open Chat", image: UIImage(systemName: "bubble.left")) { _ in self?.open(bot.id) }
            let read = UIAction(title: "Mark as Read", image: UIImage(systemName: "checkmark.message"),
                                attributes: bot.unread ? [] : .disabled) { _ in self?.markRead(bot.id) }
            return UIMenu(children: [open, read])
        }
    }

    /// [groups] A room's row menu, held or from its More swipe: Group Info, Pin, Mute, Mark as Unread, Hide, Move to
    /// Section (with sections), Delete Group Chat.
    func roomMenuNodes(_ room: GroupRowModel, services groups: any GroupServices, source: @escaping () -> UIView?) -> [BotMenuNode] {
        var nodes = GroupActions.menuNodes(for: room, services: groups, host: self, source: source)
        // [bots-groupby] Filed among the bots' sections from its menu too, not only by a drag (audit 05-3: the More
        // swipe's menu left it out, though the empty section's hint names it).
        if let move = organizer?.roomMoveNode(for: room) { nodes.insert(move, at: max(0, nodes.count - 1)) }
        return nodes
    }

    /// The lifted row or tile on an opaque card of its own. Left to UIKit, a cell with a clear background gets a
    /// captured backdrop instead (a portal of what is behind the cell); when a tall menu moves the preview up, that
    /// capture shows whatever is behind the new spot, so the pinned tiles and the title drew through the lifted row,
    /// undimmed (owner, build 245).
    func collectionView(_ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration,
                        highlightPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
        liftedPreview(at: indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration,
                        dismissalPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
        liftedPreview(at: indexPath)
    }

    /// [botslist] A tap on the lifted row or tile of the hold menu opens its chat (or its room), and the menu goes
    /// (parity §3 L173, `S/ui-bots/bot-row.tsx:354-362`). The preview stays the row itself: no transcript is opened
    /// just to peek.
    func collectionView(_ collectionView: UICollectionView, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
                        animator: any UIContextMenuInteractionCommitAnimating) {
        guard let key = configuration.identifier as? String else { return }
        animator.preferredCommitStyle = .dismiss
        animator.addCompletion { [weak self] in
            guard let self else { return }
            if self.botsByID[key] != nil, self.dataSource.indexPath(for: .row(key)) != nil || self.dataSource.indexPath(for: .tile(key)) != nil {
                self.open(key)
            } else if self.roomsByID[key] != nil {
                self.openRoom(key)
            }
        }
    }

    /// [botslist] A user section's header cell (the Delete Section question is anchored on its ⋯).
    func headerCell(forSection id: String) -> UICollectionViewCell? {
        dataSource.indexPath(for: .header(.user(id))).flatMap { collectionView.cellForItem(at: $0) }
    }

    private func liftedPreview(at indexPath: IndexPath) -> UITargetedPreview? {
        guard let cell = collectionView.cellForItem(at: indexPath), cell.window != nil else { return nil }
        if Theme.isDesktop {   // [desktoplook2] flat and outlined, no drop shadow
            switch dataSource.itemIdentifier(for: indexPath) {
            case .tile, .roomTile: return UITargetedPreview(view: cell, parameters: DesktopLayout.liftParameters(for: cell.bounds, inset: 0))
            case .row, .room: return UITargetedPreview(view: cell, parameters: DesktopLayout.liftParameters(for: cell.bounds))
            case .header(.user): return UITargetedPreview(view: cell, parameters: DesktopLayout.liftParameters(for: Self.headerLift(cell), inset: 0))
            default: return nil
            }
        }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = HQPalette.lifted
        switch dataSource.itemIdentifier(for: indexPath) {
        case .tile, .roomTile:
            parameters.visiblePath = UIBezierPath(roundedRect: cell.bounds, cornerRadius: 22)
        case .row, .room:
            parameters.visiblePath = UIBezierPath(roundedRect: cell.bounds.insetBy(dx: 16, dy: 0), cornerRadius: 18)
        case .header(.user):   // [botsminimal] the name lifts as a pill, clear of the space above it
            parameters.visiblePath = UIBezierPath(roundedRect: Self.headerLift(cell), cornerRadius: 14)
        default:
            return nil
        }
        return UITargetedPreview(view: cell, parameters: parameters)
    }

    /// [botsminimal] What of a section header lifts for its menu: below the header's top padding
    /// (`BotSectionHeaderView`), a little in from the sides.
    private static func headerLift(_ cell: UICollectionViewCell) -> CGRect {
        let top: CGFloat = Theme.isDesktop ? 10 : 8
        var box = cell.bounds.insetBy(dx: Theme.isDesktop ? 8 : 12, dy: 0)
        box.origin.y += top
        box.size.height -= top
        return box
    }

    // MARK: - Settings stream hooks (1x-settings §4.4, §5.5)

    /// The bot of a list row (not a tile): what a drag lifts.
    func rowBot(at indexPath: IndexPath) -> Bot? {
        if case .row(let id) = dataSource.itemIdentifier(for: indexPath) { return botsByID[id] }
        return nil
    }

    /// The bot of a pinned tile (what a tile drag lifts).
    func tileBot(at indexPath: IndexPath) -> Bot? {
        if case .tile(let id) = dataSource.itemIdentifier(for: indexPath) { return botsByID[id] }
        return nil
    }

    /// The tiles as shown, first first (bot ids).
    var tileIDs: [String] {
        let snapshot = dataSource.snapshot()
        guard snapshot.sectionIdentifiers.contains(.list(.tiles)) else { return [] }
        return snapshot.itemIdentifiers(inSection: .list(.tiles)).compactMap { if case .tile(let id) = $0 { id } else { nil } }
    }

    /// The pinned bots in the tiles' block, first first: tiles, or the rows that stand in for them at accessibility sizes.
    var pinnedTileIDs: [String] { sections.first { $0.id == .tiles }?.bots.map(\.id) ?? [] }

    /// The Pinned section's hint item (not a section id: those are never this).
    static let pinnedOverflowHint = "pins:overflow"

    /// [a11y] Move Earlier / Move Later as named actions on a pinned bot's tile (or its row at accessibility sizes).
    private func pinMoveActions(for bot: Bot) -> [BotAccessibilityAction] {
        guard let organizer else { return [] }
        return organizer.pinMoves(for: bot).map { move in
            BotAccessibilityAction(name: move.title) { [weak organizer] in organizer?.movePin(bot, by: move.delta) }
        }
    }

    /// [manualorder] Move Up / Move Down as named actions on a row (VoiceOver, Switch Control): what a drag does.
    private func rowMoveActions(for bot: Bot) -> [BotAccessibilityAction] {
        guard let organizer else { return [] }
        return organizer.rowMoves(for: bot).map { move in
            BotAccessibilityAction(name: move.title) { [weak organizer] in organizer?.moveRow(bot, by: move.delta) }
        }
    }

    /// [manualorder] The block a bot's row is drawn in, when Sort By › Manual orders that block (Pinned, a section, the
    /// unassigned rows, Hidden); nil for a tile, a search or filter result, or a folded tile at accessibility sizes.
    func rowBlock(of id: String) -> BotListSection? {
        sections.first { BotsOrganizer.isOrderedBlock($0.id) && $0.bots.contains { $0.id == id } }
    }

    /// [manualorder] Where a row dropped at `destination` (an insertion point, the dragged row left out) lands: its
    /// block and its place among that block's rows. Just above a header is the end of the open block before it. nil:
    /// not among a block's rows.
    func rowPlace(at destination: IndexPath, dragging id: String) -> (block: BotListSectionID, index: Int)? {
        let snapshot = dataSource.snapshot()
        let ids = snapshot.sectionIdentifiers
        guard ids.indices.contains(destination.section) else { return nil }
        var index = destination.section
        var items = snapshot.itemIdentifiers(inSection: ids[index]).filter { $0 != .row(id) }
        var at = min(max(0, destination.item), items.count)
        if at == 0, case .header? = items.first, index > 0, case .list(let previous) = ids[index - 1],
           BotsOrganizer.isOrderedBlock(previous), !isFolded(previous) {
            index -= 1
            items = snapshot.itemIdentifiers(inSection: ids[index]).filter { $0 != .row(id) }
            at = items.count
        }
        guard case .list(let block) = ids[index], BotsOrganizer.isOrderedBlock(block),
              let rows = sections.first(where: { $0.id == block })?.bots.map(\.id) else { return nil }
        let members = Set(rows)
        let place = items.prefix(at).filter { if case .row(let row) = $0 { members.contains(row) } else { false } }.count
        return (block, place)
    }

    /// [manualorder] Whether the point is over a section's header (a drop there files the bot, as before: no place).
    func isHeader(at point: CGPoint) -> Bool {
        guard let path = collectionView.indexPathForItem(at: point), case .header? = dataSource.itemIdentifier(for: path) else { return false }
        return true
    }

    /// [manualorder] A block's rows show in the order `ids` now, before the roster's rebuild lands (same order, no
    /// motion then). Other items (the header, a hint, rooms) keep their places.
    func showRows(_ ids: [String], in block: BotListSectionID, animated: Bool) {
        var snapshot = dataSource.snapshot()
        guard snapshot.sectionIdentifiers.contains(.list(block)) else { return }
        let moving = Set(ids)
        let listed = snapshot.itemIdentifiers(inSection: .list(block))
        // [chats-under] A bot's chats move with it.
        let attached = Dictionary(grouping: listed.filter { Self.chatOwner($0) != nil }, by: { Self.chatOwner($0) ?? "" })
        let items = listed.filter { Self.chatOwner($0) == nil }
        let current = items.compactMap { item -> String? in if case .row(let id) = item, moving.contains(id) { id } else { nil } }
        guard current.count == ids.count, Set(current) == moving, current != ids else { return }
        var queue = ids[...]
        let next = items.map { item -> Item in
            if case .row(let id) = item, moving.contains(id), let placed = queue.popFirst() { return .row(placed) }
            return item
        }.flatMap { item -> [Item] in
            if case .row(let id) = item { return [item] + (attached[id] ?? []) }
            return [item]
        }
        snapshot.deleteItems(listed)
        snapshot.appendItems(next, toSection: .list(block))
        if let index = sections.firstIndex(where: { $0.id == block }) { sections[index].bots = BotRowOrder.ordered(sections[index].bots, by: ids) }
        dataSource.apply(snapshot, animatingDifferences: animated && !HQMotion.reduced)
        remarkOnShow()   // [m9/ipad]
    }

    /// [manualorder] A block's rows as shown, top first (bot ids).
    func sectionRows(_ block: BotListSectionID) -> [String] { sections.first { $0.id == block }?.bots.map(\.id) ?? [] }

    /// [manualorder] A row's place in the list now (a drop's landing spot).
    func indexPath(forRow id: String) -> IndexPath? { dataSource.indexPath(for: .row(id)) }

    /// Brings a bot's row (or tile) into view and lights it briefly: Show in Bots, a Duplicate. Its row may land a moment
    /// later (or, with `leaving`, may still stand in that block), so it looks again for up to about 2 s.
    func reveal(_ id: String, leaving: BotListSectionID? = nil, attempts: Int = 12) {
        guard isViewLoaded, dataSource != nil else { return }
        let found = [Item.row(id), .tile(id)].lazy.compactMap { self.dataSource.indexPath(for: $0) }.first
        guard let indexPath = found, leaving == nil || listSectionID(at: indexPath) != leaving else {
            guard attempts > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.reveal(id, leaving: leaving, attempts: attempts - 1) }
            return
        }
        guard view.window != nil, let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }
        let visible = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        let scrolls = !visible.contains(frame)
        if scrolls { collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: !HQMotion.reduced) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (scrolls ? 0.35 : 0)) { [weak self] in
            guard let self, let cell = self.cellView(for: id) else { return }
            cell.isHighlighted = true
            if self.presentedViewController == nil { UIAccessibility.post(notification: .layoutChanged, argument: cell) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak cell] in cell?.isHighlighted = false }
        }
    }

    /// Whether `indexPath` is a slot in the tile grid.
    func isTileSlot(_ indexPath: IndexPath) -> Bool { dataSource.sectionIdentifier(for: indexPath.section) == .list(.tiles) }

    /// A tile drop: the grid shows `ids` in this order now, before the roster's rebuild lands (same order, no motion).
    func showTiles(_ ids: [String]) {
        var snapshot = dataSource.snapshot()
        let current = tileIDs
        guard Set(ids) == Set(current), ids != current else { return }
        // [groups] Room tiles keep their place after the bots' tiles.
        let roomTiles = snapshot.itemIdentifiers(inSection: .list(.tiles)).filter { if case .roomTile = $0 { true } else { false } }
        snapshot.deleteItems(current.map { .tile($0) } + roomTiles)
        snapshot.appendItems(ids.map { .tile($0) } + roomTiles, toSection: .list(.tiles))
        dataSource.apply(snapshot, animatingDifferences: false)
        remarkOnShow()   // [m9/ipad]
    }

    /// The block an index path belongs to (a drop target).
    func listSectionID(at indexPath: IndexPath) -> BotListSectionID? {
        guard let section = dataSource.sectionIdentifier(for: indexPath.section), case .list(let id) = section else { return nil }
        return id
    }

    /// The block under a point (between rows, or below the last one in a block).
    func listSectionID(near point: CGPoint) -> BotListSectionID? {
        if let indexPath = collectionView.indexPathForItem(at: point) { return listSectionID(at: indexPath) }
        let visible = collectionView.indexPathsForVisibleItems.sorted()
        var best: (BotListSectionID, CGFloat)?
        for indexPath in visible {
            guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame, let id = listSectionID(at: indexPath) else { continue }
            let distance = frame.contains(point) ? 0 : min(abs(frame.minY - point.y), abs(frame.maxY - point.y))
            if best == nil || distance < best!.1 { best = (id, distance) }
        }
        return best?.0
    }

    /// The drop target changed: its header redraws highlighted.
    func dropTargetChanged() {
        var snapshot = dataSource.snapshot()
        let headers = snapshot.itemIdentifiers.filter { if case .header = $0 { return true } else { return false } }
        guard !headers.isEmpty else { return }
        for item in headers { signatures[item] = signature(item) }
        snapshot.reconfigureItems(headers)
        dataSource.apply(snapshot, animatingDifferences: false)
        remarkOnShow()   // [m9/ipad]
    }

    // MARK: - Search

    func updateSearchResults(for searchController: UISearchController) {
        bar?.updateSearchState()
        let text = (bar?.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != query else { return }
        query = text
        reload(animated: false)
    }
}
