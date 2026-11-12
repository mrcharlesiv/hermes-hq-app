// The Sessions tab (spec 02 §9, spec 06 §6.4): sessions in the web's date groups, newest first (pinned chats first,
// in their own group), background runs left out unless Filter › Show › Background Runs. Tap → the chat. Row
// actions (swipes, the long-press menu, Archive with Undo, Delete) live in `SessionsOrganizer`; the search
// field filters the loaded rows as you type, then adds the gateway's full-text hits (SessionSearch.swift); Filter ›
// Show › Archived adds the archived chats to the list (marked) so they can be found and unarchived.

import SwiftUI
import UIKit

final class SessionsViewController: UIViewController, UICollectionViewDelegate, UISearchResultsUpdating {
    private let services: any AppServices
    private let makeChat: (any ChatSessionModel) -> UIViewController
    var onDataChange: (() -> Void)?

    private(set) var collectionView: UICollectionView!
    private(set) var dataSource: UICollectionViewDiffableDataSource<String, String>!
    private var sessionsByID: [String: SessionSummary] = [:]
    /// What the Other Apps row last drew (a change reconfigures it).
    private var otherAppsSign = ""
    /// The Other Apps page while it is in the stack (its rows' actions and reloads go through this list).
    private weak var otherAppsPage: OtherAppsViewController?
    /// The roster by profile, rebuilt once per reload: rows draw their owner's name and head from it.
    private var owners: [String: Bot] = [:]
    private(set) var groups: [SessionGroup] = []
    /// [drag-to-project] The project group a dragged chat is held over: its header lights up as the place it would go.
    var dropTargetGroup: String? {
        didSet { if dropTargetGroup != oldValue { refreshVisibleHeaders() } }
    }
    private var signatures: [String: Int] = [:]
    /// The rows wearing the working ring, whose hairlines the list hides.
    private var ringedKeys: Set<String> = []
    private var didRequestFirstLoad = false
    private var refreshStarted: Date?
    /// Try Again under "Couldn’t Load Chats" is waiting on its read: the list says Loading meanwhile.
    private var retryingLoad = false
    /// Which pull the 8 s fallback belongs to (a second pull must not be ended by the first pull's timer).
    private var refreshGeneration = 0
    /// A pull that failed while chats are shown says so for a moment (the Jobs page's line).
    private lazy var notices = PageNoticeHost(in: view)
    private var reloadPending = false
    /// Data changed while the list was off screen; reloaded when it comes back.
    private(set) var needsReload = false
    /// [perf] A reload is waiting for the navigation transition in flight to end (one per transition).
    private var reloadAfterTransition = false
    private var timeObserver: NSObjectProtocol?
    private var lookObserver: NSObjectProtocol?
    /// UX study #248: a bot muted or unmuted redraws its chats' bells.
    private var muteObserver: UUID?
    /// UX study #206: a first read still loading after 15 s says the gateway is slow, with Try Again.
    private let slowClock = SlowLoadClock()
    private var rolloverTimer: Timer?
    /// Settings stream (1x-settings §4.6): the gateway switcher on the title.
    private var titleSwitcher: GatewayTitleSwitcher?
    /// Row actions (nil without a sessions store: the M1 Open Chat menu).
    private(set) var organizer: SessionsOrganizer?
    /// The search field's text (trimmed) and the gateway's hits for it.
    private(set) var query = ""
    private var searchHits: [SessionSearchHit] = []
    private var searchTask: Task<Void, Never>?
    /// The last gateway search had a profile whose request failed (UX study 2026-10-19 #28).
    private var searchFailed = false
    /// Filter › Show › Archived: the archived chats join the list, marked. [sessions-m9] Kept with the account's
    /// other Filter & Sort choices (`SessionStore.view`).
    var showArchived: Bool { store?.view.showArchived ?? false }
    // [sessions-m9] The fixed header (chips, strip), and the Filter menu's end row as it was when the menu opened.
    private let headerModel = SessionsHeaderModel()
    private var headerHost: UIHostingController<SessionsHeaderView>?
    private var pageBackdrop: PageBackdrop?   // [backdrop]
    private var headerHeight: NSLayoutConstraint?
    /// [sessions-m9] Filter › Project's entries as the open menu last drew them.
    fileprivate var menuProjects: [SessionProjectEntry] = []
    private var menuEnd: SessionFilterMenuModel.End?
    /// Which sections draw a header (a change re-reads the layout).
    private var headerFlags: [Bool] = []
    /// [project-cards] Which sections are an open project's card, set in to the card's edges (a change re-reads the layout).
    private var openCardFlags: [Bool] = []
    /// [project-unfold] The group a header tap just opened or closed: the next reload draws the change as a motion.
    private var unfoldGroup: String?
    /// [project-unfold] The moving rows (and the pieces of card under them), each masked at the header's foot.
    private var unfoldMasks: [(view: UIView, mask: UIView, leaving: Bool, item: String?)] = []
    /// [project-unfold] Rows hidden until UIKit is done with them: one a closing group was still sliding away when its
    /// chat came back (the new row took over from it), a piece of card under a closing chat, a row another fold left
    /// (faded out). Their own mask came off with them, and they stood over the header above.
    private var unfoldDying: [(view: UIView, mask: UIView)] = []
    private var unfoldRun = 0
    /// [project-unfold] When the fold's springs began: nil until the change reaches the screen (they start with UIKit's
    /// own, as the change is committed), then read back from one, so a row that comes on screen late joins them mid-way.
    private var unfoldBegan: CFTimeInterval?
    /// [project-unfold] A spring of the fold's (the header's, or a mask's fade), read back for when they all began.
    private var unfoldClock: (layer: CALayer, key: String)?
    /// [project-unfold] Each frame until the spring settles: masks a row that came on screen late, and counts any frame a
    /// row showed above its header (the fold's log line).
    private var unfoldLink: CADisplayLink?
    private var unfoldWatch: (() -> Void)?
    private var unfoldReport: (() -> Void)?
    /// [project-unfold] While a group opens or closes: what changes across the headers on screen moves on the rows'
    /// spring. Which group each header view last drew, so a header given another group's (reused) never animates.
    private var headerMotion: Animation?
    private var headerShows: [ObjectIdentifier: String] = [:]
    /// [project-unfold] How far down each header view's project row last stood (`SessionDateHeaderView.rowShift`).
    private var headerRowTops: [ObjectIdentifier: CGFloat] = [:]
    /// [project-unfold] How far the folder stood below its card's top (`ProjectCardHeader.topPad`).
    private var headerCardPads: [ObjectIdentifier: CGFloat] = [:]
    /// [project-unfold] Until a group's spring settles, other changes wait (a reload mid-motion redrew every header on
    /// screen and kept the main thread from the frames of anything moved by SwiftUI), then come as one reload.
    private var folding = false
    private var reloadAfterFold = false
    private var foldMeter: Int?
    /// Reloads done: a reload asked for before one ran is already in it.
    private var reloads = 0
    /// [sessions-layout] Pinned's rows: one line each (title and time, a small face).
    private var compactKeys: Set<String> = []
    /// [sessions-layout] New for You's rows: one line of preview.
    private var shortKeys: Set<String> = []
    /// [project-cards] Rows inside a project's card (item ids, a chat's second row included), with the project's name.
    private var cardKeys: [String: String] = [:]
    /// [sessions-fresh] Fresh's one-line rows: Group By Recent's Recent and a status chip's run (a second line while
    /// the bot works or waits on you), and Group By Recent's Pinned (`freshPinnedKeys`: never a second line).
    private var freshKeys: Set<String> = []
    private var freshPinnedKeys: Set<String> = []
    private var backgroundObserver: NSObjectProtocol?
    private var headerLaidOut = false
    // [/sessions-m9]
    /// Rows whose Delete is on its way (dimmed, a spinner).
    private var busy: Set<String> = []
    private var barCapsule: PageBarCapsule?
    /// [ipad-polish] The bar's compose button while this list is the page on show: New Chat hangs off it in two panes.
    /// The bar and the compose button's place in it (the trailing-most item): a pop-over given the bar's item itself
    /// grows out of the button and covers the page's title.
    var composeAnchor: (bar: UIView, rect: CGRect)? {
        guard viewIfLoaded?.window != nil, navigationController?.topViewController === self,
              tabBarController?.selectedViewController === navigationController, barCapsule?.composeItem != nil,
              let bar = navigationController?.navigationBar, !bar.isHidden else { return nil }
        return (bar, bar.hqTrailingButtonRect)
    }
    func openSearchFromKeyboard() { barCapsule?.openSearch() }   // [m9/ipad] Command-F, Command-Shift-F
    private let swipePeek = SwipePeek(key: SwipePeek.sessionsKey, markerId: "sessions.peek", revealColor: .systemGray, symbol: "ellipsis.circle.fill")
    static let peekKey = SwipePeek.sessionsKey

    var store: SessionStore? { (services as? SessionsServices)?.sessionStore }
    var searching: Bool { !query.isEmpty }

    init(services: any AppServices, makeChat: @escaping (any ChatSessionModel) -> UIViewController) {
        self.services = services
        self.makeChat = makeChat
        super.init(nibName: nil, bundle: nil)
        title = "Sessions"
        // Inline: the large title sits on the bar row beside its buttons (owner: the separate title row put the list too low).
        navigationItem.largeTitleDisplayMode = .inline
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.page
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = HQPalette.page
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.accessibilityIdentifier = "sessions.list"
        ListBarAppearance.apply(to: navigationItem)        // the same bar as the Bots tab
        if let settings = services as? SettingsServices {   // settings stream: the gateway switcher (1x-settings §4.6)
            titleSwitcher = GatewayTitleSwitcher(host: self, services: services, settings: settings, baseTitle: "Sessions")
        }
        if let sessionsServices = services as? SessionsServices {
            organizer = SessionsOrganizer(host: self, services: services, sessionsServices: sessionsServices)
            // The bar's one trailing capsule: [Filter] [Search] [Compose] (the web's roster bar). The search field
            // stays folded away until the magnifier opens it.
            let search = UISearchController(searchResultsController: nil)
            search.searchResultsUpdater = self
            search.obscuresBackgroundDuringPresentation = false
            search.searchBar.placeholder = SessionsSearchWords.placeholder(botName: nil)
            search.searchBar.searchTextField.accessibilityIdentifier = "sessions.search.field"
            collectionView.keyboardDismissMode = .onDrag
            let capsule = PageBarCapsule(host: self, configuration: .init(
                page: "sessions",
                filterMenu: { [weak self] in self?.filterMenu() ?? [] },
                search: search,
                // [sessions-m9] The New Chat sheet, a picked chip's bot lit (§7.3).
                compose: .action({ [weak self] in self?.organizer?.compose(profile: self?.pickedBot, asksProject: true) }),
                filterLabel: "Filter and Sort"))
            capsule.install()
            barCapsule = capsule
            // [manual-order] Hold a row and drag it to a new place in its group: Sort By becomes Manual. UI tests that
            // only long-press turn drag off (`-HQDebugNoDrag YES`), as on Bots.
            collectionView.dragDelegate = self
            collectionView.dropDelegate = self
            collectionView.dragInteractionEnabled = !UserDefaults.standard.bool(forKey: "HQDebugNoDrag")
        }
        view.addSubview(collectionView)
        ListBarAppearance.pinTitle(in: self, softEdgeAround: collectionView)   // owner 2026-11-01: every tab's top
        pageBackdrop = PageBackdrop.install(in: self, clearing: [collectionView])   // [backdrop] Theme › App Background
        installHeader()          // [sessions-m9]
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in self?.pulledToRefresh() }, for: .valueChanged)
        collectionView.hqInstallRefresh(refresh)
        configureDataSource()
        services.onSessionsChange = { [weak self] in
            self?.onDataChange?()
            self?.setNeedsReload()
        }
        // Midnight (and clock or zone changes): row times and groups move on. Posted on main; a block observer anyway.
        timeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.significantTimeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setNeedsReload(animated: false) }
        }
        // A theme change: the hairlines are asked again (a ring change in the Desktop Look skips that), and the header,
        // which is measured again only when its chips or strip change, is measured in the new look.
        lookObserver = NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isViewLoaded else { return }
                self.collectionView.collectionViewLayout.invalidateLayout()
                self.view.setNeedsLayout()
            }
        }
        // [sessions-layout] The app going away is leaving the page: chats read in New for You go back to their groups.
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseNew() }
        }
        muteObserver = BotMuteCenter.shared.observe { [weak self] in self?.setNeedsReload(animated: false) }   // UX study #248
        slowClock.onSlow = { [weak self] in self?.setNeedsReload(animated: false) }                         // UX study #206
        reload(animated: false)
    }

    isolated deinit {
        if let muteObserver { BotMuteCenter.shared.stopObserving(muteObserver) }
        if let timeObserver { NotificationCenter.default.removeObserver(timeObserver) }
        if let lookObserver { NotificationCenter.default.removeObserver(lookObserver) }
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        rolloverTimer?.invalidate()
        searchTask?.cancel()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if needsReload {
            // [perf] As on Bots: a pop back to rows reloads once the slide has landed; anything else in place.
            if animated, let coordinator = transitionCoordinator, dataSource.snapshot().numberOfItems > 0 {
                reloadWhenTransitionEnds(coordinator)
            } else {
                reload(animated: false)
            }
        }
        if !didRequestFirstLoad {
            didRequestFirstLoad = true
            services.refreshSessions()
            // [sessions-m9] Show › Archived is kept across launches: its chats are read with the first load.
            if showArchived, let store { Task { await store.loadArchived() } }
        }
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

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // [sessions-layout] Another tab (the list itself still on top of its stack): the page was left. A chat pushed
        // over it is not leaving: the chat read there is in New for You on the way back.
        if navigationController?.topViewController === self { releaseNew() }
    }

    /// [sessions-layout] Chats read in New for You since the page was last left go back to their own groups.
    private func releaseNew() {
        if store?.releaseNew() == true { setNeedsReload(animated: false) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        otherAppsOnTop = false           // Back inside a chat pushed from here says the unread count again
        schedulePeek()
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "HQDebugOtherApps"), !debugOpenedOtherApps,
           dataSource.snapshot().itemIdentifiers.contains(Self.otherAppsKey) {
            debugOpenedOtherApps = true
            openOtherApps()
        }
        #endif
    }
    #if DEBUG
    private var debugOpenedOtherApps = false
    /// [project-cards] `-HQDebugSessionsScroll <project folder>`: the list scrolls that project's card to the top once
    /// it is drawn (pictures of a project lower down).
    private var debugScrolled = false
    private func debugScrollToProject() {
        guard !debugScrolled, let key = UserDefaults.standard.string(forKey: "HQDebugSessionsScroll"), !key.isEmpty,
              groups.contains(where: { $0.id == SessionListPipeline.projectPrefix + key }) else { return }
        debugScrolled = true
        // Twice: rows below the screen are measured as they come in, so the first offset can fall short.
        for delay in [1.5, 3.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let index = self.groups.firstIndex(where: { $0.id == SessionListPipeline.projectPrefix + key }) else { return }
            self.collectionView.layoutIfNeeded()
            guard let top = self.collectionView.layoutAttributesForSupplementaryElement(
                ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: index))?.frame.minY else { return }
            let inset = self.collectionView.adjustedContentInset
            let most = max(-inset.top, self.collectionView.contentSize.height + inset.bottom - self.collectionView.bounds.height)
            self.collectionView.setContentOffset(CGPoint(x: 0, y: min(most, top - inset.top - 8)), animated: false)
        } }
    }
    /// [project-unfold] `-HQDebugSessionsToggle <project folder or group id>`: once the list is drawn, that group opens
    /// and closes by itself every 2.5 s (`-HQDebugSessionsToggleEvery` seconds: quick taps), eight times (films of the
    /// fold's motion). `-HQDebugSessionsToggleWait` seconds before the first (default 6).
    private var debugToggling = false
    private func debugToggleLoop() {
        guard !debugToggling, let key = UserDefaults.standard.string(forKey: "HQDebugSessionsToggle"), !key.isEmpty else { return }
        let id = groups.contains { $0.id == key } ? key : SessionListPipeline.projectPrefix + key
        guard groups.contains(where: { $0.id == id }) else { return }
        debugToggling = true
        let wait = Double(UserDefaults.standard.string(forKey: "HQDebugSessionsToggleWait") ?? "") ?? 6
        let every = Double(UserDefaults.standard.string(forKey: "HQDebugSessionsToggleEvery") ?? "") ?? 2.5
        for step in 0..<8 {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait + Double(step) * every) { [weak self] in self?.toggleGroup(id) }
        }
    }
    #endif

    // [sessions-m9]
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutHeader()
    }

    private func makeLayout() -> UICollectionViewLayout {
        let layout = SessionsListLayout { [weak self] section, environment in
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.backgroundColor = .clear
            // Search results are one list without date headers. [sessions-m9] So is a run without a title (Archived,
            // Sort By Tokens or Cost).
            config.headerMode = self?.drawsHeader(section) == true ? .supplementary : .none
            config.leadingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                guard let self, let organizer = self.organizer, let item = self.dataSource.itemIdentifier(for: indexPath),
                      !self.busy.contains(Self.realKey(item)), let session = self.sessionsByID[item] else { return nil }
                return organizer.leadingActions(for: session)
            }
            config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                guard let self, let organizer = self.organizer, let item = self.dataSource.itemIdentifier(for: indexPath),
                      !self.busy.contains(Self.realKey(item)), let session = self.sessionsByID[item] else { return nil }
                return organizer.trailingActions(for: session, key: Self.realKey(item))
            }
            config.headerTopPadding = 0
            config.separatorConfiguration.color = HQPalette.separator
            config.itemSeparatorHandler = { [weak self] indexPath, separator in
                var separator = separator
                separator.topSeparatorVisibility = .hidden
                separator.bottomSeparatorVisibility = .hidden   // [sessionsminimal] no rules in either look, as on Bots
                // A working row's ring stands clear of the hairlines.
                if WorkingArc.ringHidesSeparator(indexPath, ringed: { self?.ringed($0) == true }) {
                    separator.bottomSeparatorVisibility = .hidden
                }
                // The hairline starts at the text (20 + 40 + 12) and stops 20 pt from the trailing edge, as on Bots.
                separator.bottomSeparatorInsets = NSDirectionalEdgeInsets(top: 0, leading: 72, bottom: 0, trailing: 20)
                return separator
            }
            let list = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            // The web's date dividers scroll with the rows; pinned, the clear header sat over the rows beneath it.
            list.boundarySupplementaryItems.forEach { $0.pinToVisibleBounds = false }
            // [project-cards] An open card's rows are as wide as the card, so a swipe moves a chat inside it and its
            // buttons sit inside it. The header (the card's top, "Projects" over the first) keeps the list's width.
            if self?.isOpenCard(section) == true {
                list.contentInsets.leading = ProjectCard.inset
                list.contentInsets.trailing = ProjectCard.inset
                list.supplementaryContentInsetsReference = .none
            } else if self?.isProjectSection(section) != true {
                BackdropCards.card(list, on: BackdropCards.on(self))   // [backdrop-cards] (a project's rows are cards already)
            }
            return list
        }
        layout.register(ProjectCardUnderRow.self, forDecorationViewOfKind: SessionsListLayout.cardUnderRow)
        BackdropCards.register(in: layout)   // [backdrop-cards]
        layout.cardRow = { [weak self] path in
            guard let self, let id = self.dataSource?.itemIdentifier(for: path) else { return false }
            return self.cardKeys[id] != nil
        }
        return layout
    }

    /// [project-cards] An open project's card (its rows are set in to the card's edges).
    private func isOpenCard(_ section: Int) -> Bool {
        !searching && section < groups.count && SessionListPipeline.isProject(groups[section].id) && !groups[section].collapsed
    }

    private func configureDataSource() {
        let rowRegistration = UICollectionView.CellRegistration<SessionListCell, String> { [weak self] cell, _, id in
            guard let self, let session = self.sessionsByID[id] else { return }
            let owner = self.owner(of: session)
            let busy = self.busy.contains(Self.realKey(id))
            let detail = self.rowDetail          // [sessions-m9] Row Detail
            let muted = BotMuteCenter.shared.isMuted(session.profile)   // UX study #248
            let origin = session.origin          // where it came from: the platform's mark before the title
            let compact = self.compactKeys.contains(id)   // [sessions-layout] Pinned: one line
            let short = self.shortKeys.contains(id)       // [sessions-layout] New for You: one line of preview
            let card = self.cardKeys[id]                  // [project-cards] inside a project's card
            // [sessions-fresh] Pinned's and Recent's one line, with or without the face (Show › Bot Faces, which only
            // Group By Recent offers; the cards follow it there too).
            let fresh: SessionRowView.Fresh? = self.freshPinnedKeys.contains(id) ? .pinned : self.freshKeys.contains(id) ? .recent : nil
            let faces = !self.freshLayout || (self.store?.view.botFaces ?? true)
            let row = UIHostingConfiguration {
                SessionRowView(session: session, ownerName: owner.name, ownerHead: owner.head,
                               time: ListTime.string(session.lastActive), busy: busy, detail: detail, muted: muted,
                               origin: origin, compact: compact, shortPreview: short, card: card, fresh: fresh, faces: faces,
                               recentLayout: self.freshLayout)
            }
            .margins(.all, 0)
            // [sessions-layout] A one-line row is as tall as it draws itself (44 pt), not the list's taller least row.
            cell.contentConfiguration = compact || card != nil || fresh != nil ? row.minSize(height: 0) : row
            // [project-cards] A chat's second row (in its project, while New for You has it too) is told apart.
            cell.accessibilityIdentifier = Self.isCopy(id) ? "session-row-also-\(session.id)" : "session-row-\(session.id)"
            cell.clipsToCard = card != nil
            cell.configurationUpdateHandler = { cell, state in
                if card != nil {
                    cell.backgroundConfiguration = ProjectCard.background(
                        .middle, state, edged: false, line: .node(y: ProjectCard.nodeY, clear: SessionRowView.cardLineClear(faces: faces)))
                    return
                }
                #if targetEnvironment(macCatalyst)
                if DeviceWord.isMac { cell.backgroundConfiguration = MacSelection.listRow(state); return }   // [mac] Stress test 2026-10-28 #54
                #endif
                if Theme.isDesktop { cell.backgroundConfiguration = DesktopLayout.rowBackground(state); return }   // [desktoplook2]
                var background = UIBackgroundConfiguration.clear()
                background.backgroundColor = state.isHighlighted || state.isSelected ? HQPalette.cellPressed : .clear
                cell.backgroundConfiguration = background
            }
        }
        let appsRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, _ in
            guard let self, let group = self.groups.first(where: { $0.id == SessionListPipeline.otherAppsId }) else { return }
            let platforms = group.platforms, total = group.total, time = ListTime.string(group.newest), waiting = group.waiting
            cell.contentConfiguration = UIHostingConfiguration {
                OtherAppsRowView(platforms: platforms, total: total, time: time, waiting: waiting)
            }.margins(.all, 0)
            cell.accessibilityIdentifier = "sessions.otherApps"
            cell.configurationUpdateHandler = { cell, state in
                #if targetEnvironment(macCatalyst)
                if DeviceWord.isMac { cell.backgroundConfiguration = MacSelection.listRow(state); return }   // [mac] Stress test 2026-10-28 #54
                #endif
                if Theme.isDesktop { cell.backgroundConfiguration = DesktopLayout.rowBackground(state); return }
                var background = UIBackgroundConfiguration.clear()
                background.backgroundColor = state.isHighlighted || state.isSelected ? HQPalette.cellPressed : .clear
                cell.backgroundConfiguration = background
            }
        }
        let moreRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let self, let group = self.groups.first(where: { $0.id == Self.groupId(moreKey: id) }) else { return }
            let more = group.more
            let inCard = !self.searching && SessionListPipeline.isProject(group.id)    // [project-cards] a node on the line
            if inCard {
                cell.contentConfiguration = UIHostingConfiguration { ProjectShowMoreRow(more: more) }.margins(.all, 0).minSize(height: 0)
            } else {
                cell.contentConfiguration = UIHostingConfiguration { SessionShowMoreRow(more: more) }.margins(.all, 0)
            }
            cell.accessibilityIdentifier = "sessions.showMore"
            cell.configurationUpdateHandler = { cell, state in
                if inCard { cell.backgroundConfiguration = ProjectCard.background(.middle, state); return }
                if Theme.isDesktop { cell.backgroundConfiguration = DesktopLayout.rowBackground(state); return }
                var background = UIBackgroundConfiguration.clear()
                background.backgroundColor = state.isHighlighted ? HQPalette.cellPressed : .clear
                cell.backgroundConfiguration = background
            }
        }
        // [project-cards] The foot of an open project's card: New Chat, which asks which bot.
        let newRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let self, let groupId = Self.groupId(newKey: id), let group = self.groups.first(where: { $0.id == groupId }) else { return }
            let row = self.newChatRow(group)
            cell.contentConfiguration = UIHostingConfiguration { row }.margins(.all, 0).minSize(height: 0)
            cell.accessibilityIdentifier = "sessions.project.newChatRow"
            cell.backgroundConfiguration = .clear()
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<SessionHeaderCell>(
            elementKind: UICollectionView.elementKindSectionHeader) { [weak self] header, _, indexPath in
            self?.configureHeader(header, section: indexPath.section)
        }
        dataSource = UICollectionViewDiffableDataSource<String, String>(collectionView: collectionView) { [weak self] collectionView, indexPath, id in
            let cell: UICollectionViewCell
            if id == Self.otherAppsKey {
                cell = collectionView.dequeueConfiguredReusableCell(using: appsRegistration, for: indexPath, item: id)
            } else if Self.groupId(moreKey: id) != nil {
                cell = collectionView.dequeueConfiguredReusableCell(using: moreRegistration, for: indexPath, item: id)
            } else if Self.groupId(newKey: id) != nil {
                cell = collectionView.dequeueConfiguredReusableCell(using: newRegistration, for: indexPath, item: id)
            } else {
                cell = collectionView.dequeueConfiguredReusableCell(using: rowRegistration, for: indexPath, item: id)
            }
            self?.wholeAgain(cell)
            return cell
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }
    }

    /// [project-unfold] A cell back from the reuse pool that left mid-fold: whole again.
    private func wholeAgain(_ cell: UICollectionViewCell) {
        if let i = unfoldDying.firstIndex(where: { $0.view === cell }) {
            if cell.layer.mask === unfoldDying[i].mask.layer { cell.layer.mask = nil }
            unfoldDying.remove(at: i)
        }
        if let i = unfoldMasks.firstIndex(where: { $0.view === cell }) {
            if cell.layer.mask === unfoldMasks[i].mask.layer { cell.layer.mask = nil }
            unfoldMasks.remove(at: i)
        }
        for key in cell.layer.animationKeys() ?? [] where key.hasPrefix("unfold") { cell.layer.removeAnimation(forKey: key) }
    }

    /// A group's header: its title; a project's (not Home's) + starts a new chat in it and a hold on it renames or deletes it; a titled group on the list
    /// opens and closes with a tap (not while searching, whose one run has no header).
    private func configureHeader(_ header: SessionHeaderCell, section: Int) {
        guard section < groups.count else { return }
        let group = groups[section]
        let title = group.title
        let prefix = SessionListPipeline.projectPrefix
        let key = group.id.hasPrefix(prefix) ? String(group.id.dropFirst(prefix.count)) : nil
        let onNewChat: (() -> Void)? = key.flatMap { key in
            key == SessionProjects.homeKey ? nil : { [weak self] in self?.organizer?.newChat(inProject: key, profile: self?.pickedBot) }
        }
        let onRename: (() -> Void)? = key.flatMap { key in
            key == SessionProjects.homeKey ? nil : { [weak self] in self?.organizer?.renameProject(key: key, title: title) }
        }
        let onDelete: (() -> Void)? = key.flatMap { key in
            key == SessionProjects.homeKey || store?.canDeleteProject(key: key) != true
                ? nil : { [weak self] in self?.organizer?.deleteProject(key: key, title: title) }
        }
        let id = group.id
        let order = store != nil && !searching ? headerOrder(for: group, section: section) : nil
        // [sessions-fresh] Group By Recent's Pinned: See All draws the rest in place. [sessions-collapse] It closes too.
        let freshPinned = !searching && freshLayout && id == "pinned"
        let fold: SessionHeaderFold? = store != nil && !searching && SessionListPipeline.folds(group)
            ? SessionHeaderFold(collapsed: group.collapsed, total: group.total, unread: group.unread,
                                unit: id == SessionListPipeline.projectsId ? "project" : "chat") { [weak self] in self?.toggleGroup(id) }
            : nil
        let dropTarget = id == dropTargetGroup
        // [sessions-layout] A project's header is its summary row. [project-cards] The top of its card: every bot in it,
        // its count (of all bots' under a chip), unread, a bot at work, its newest chat.
        let summary: SessionProjectSummary? = !searching && SessionListPipeline.isProject(id)
            ? SessionProjectSummary(bots: projectBots(group), total: group.total, unread: group.unread,
                                    latestTitle: group.latestTitle, time: ListTime.string(group.newest), collapsed: group.collapsed,
                                    working: group.working, whole: group.whole, home: key == SessionProjects.homeKey,
                                    afterCard: section > 0 && SessionListPipeline.isProject(groups[section - 1].id)
                                        && !groups[section - 1].collapsed)
            : nil
        // [sessions-layout] New for You says how many it holds.
        let badge = !searching && id == SessionListPipeline.newId ? group.total : nil
        // [sessions-layout] "Projects" over the first project, with Edit (Reorder Projects…).
        let firstProject = summary != nil && (section == 0 || !SessionListPipeline.isProject(groups[section - 1].id))
        // [sessions-fresh] Group By Recent's "Projects" says See All (its rows' hold menu keeps Reorder Projects…).
        let onEdit = firstProject && !freshLayout ? order?.onReorder : nil
        // [sessions-collapse] "Projects" closes every project to one closed header (a status or project filter shows
        // them all, as it opens every group).
        let foldsProjects = firstProject && store != nil && !searching && !listFiltered
        let onFoldCaption: (() -> Void)? = foldsProjects ? { [weak self] in self?.toggleGroup(SessionListPipeline.projectsId) } : nil
        let seeAll: SessionSeeAll?
        if freshPinned, group.more > 0 || group.expanded {
            seeAll = SessionSeeAll(total: group.total, expanded: group.expanded, kind: "Pinned") { [weak self] in self?.toggleSeeAll(id) }
        } else if firstProject, !searching, let total = group.projectsTotal {
            seeAll = SessionSeeAll(total: total, expanded: group.projectsAll, kind: "Projects") { [weak self] in
                self?.toggleSeeAll(SessionListPipeline.projectsId)
            }
        } else {
            seeAll = nil
        }
        // [project-unfold] The same group's header again (not a reused view given another): it moves with the rows.
        let motion = headerShows.updateValue(id, forKey: ObjectIdentifier(header)) == id ? headerMotion : nil
        headerRowTops[ObjectIdentifier(header)] = summary.map {
            SessionDateHeaderView.rowShift(collapsed: $0.collapsed, afterCard: $0.afterCard, caption: firstProject)
        }
        headerCardPads[ObjectIdentifier(header)] = summary.map { ProjectCardHeader.topPad(open: !$0.collapsed) }
        let view = SessionDateHeaderView(title: title, onNewChat: onNewChat, onRename: onRename, onDelete: onDelete, fold: fold,
                                         order: order, dropTarget: dropTarget, summary: summary, badge: badge,
                                         caption: firstProject ? SessionListPipeline.projectsTitle : nil, onEditCaption: onEdit,
                                         onFoldCaption: onFoldCaption, seeAll: seeAll,
                                         first: section == 0, motion: motion)
        header.contentConfiguration = UIHostingConfiguration {
            view.with(part: firstProject ? .belowCaption : .whole)
                // [project-unfold] From the top, as the list grows or shrinks it (see unfold).
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        }.margins(.all, 0)
        // [project-unfold] "Projects" apart from the content, which the list moves as the row opens: it stays.
        header.caption = firstProject ? UIHostingConfiguration { view.with(part: .caption) }.margins(.all, 0) : nil
        header.backgroundConfiguration = .clear()
    }

    /// [sessions-collapse] A status or project filter narrows the list: every group shows open (`SessionListPipeline.folded`).
    private var listFiltered: Bool {
        guard let prefs = store?.view else { return false }
        return !prefs.statusFilter.isEmpty || !prefs.projectFilter.isEmpty
    }

    /// The headers on screen say their group's state again (a fold or a count changed under the same section).
    private func refreshVisibleHeaders() {
        let kind = UICollectionView.elementKindSectionHeader
        for path in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
            guard let header = collectionView.supplementaryView(forElementKind: kind, at: path) as? SessionHeaderCell else { continue }
            configureHeader(header, section: path.section)
        }
    }

    /// A header tapped: its group closes to the header (kept across launches for the chip's bot), or opens again.
    func toggleGroup(_ id: String) {
        guard let store else { return }
        // [sessions-collapse] "Projects" open has no group of its own: its caption sits over the first project.
        let collapsed: Bool
        if let group = groups.first(where: { $0.id == id }) {
            collapsed = group.collapsed
        } else if id == SessionListPipeline.projectsId {
            collapsed = false
        } else {
            return
        }
        Haptics.play(.selection)
        unfoldOffscreen = offscreenPlaces(below: id)
        store.setGroupCollapsed(id, !collapsed)
        unfoldGroup = id
        FrameMeter.shared.end(foldMeter)
        foldMeter = FrameMeter.shared.begin(.fold, atMost: 3)
        reload(animated: true)
        if !folding { FrameMeter.shared.end(foldMeter, after: 0.1); foldMeter = nil }   // no motion (Reduce Motion)
    }

    // MARK: [project-unfold] A group opening or closing

    /// Below the screen, the groups under one: where each header and chat stands, read as it's tapped (by the time the
    /// list draws the change, its layout has the group's new state). See `comeFromOffscreen`.
    private var unfoldOffscreen: [String: CGFloat] = [:]

    private func offscreenPlaces(below id: String) -> [String: CGFloat] {
        guard let section = dataSource.snapshot().sectionIdentifiers.firstIndex(where: { $0.hasPrefix(id + "|") }) else { return [:] }
        let screen = collectionView.bounds
        let below = CGRect(x: screen.minX, y: screen.maxY, width: screen.width, height: screen.height * 2)
        var places: [String: CGFloat] = [:]
        for item in collectionView.collectionViewLayout.layoutAttributesForElements(in: below) ?? []
        where item.indexPath.section > section && item.frame.minY >= screen.maxY {
            switch item.representedElementCategory {
            case .cell: places[Self.offscreenKey(header: false, item.indexPath)] = item.frame.minY
            case .supplementaryView where item.representedElementKind == UICollectionView.elementKindSectionHeader:
                places[Self.offscreenKey(header: true, item.indexPath)] = item.frame.minY
            default: break
            }
        }
        return places
    }

    private static func offscreenKey(header: Bool, _ path: IndexPath) -> String {
        "\(header ? "h" : "c").\(path.section).\(path.item)"
    }

    /// [project-unfold] What stood below the screen before a change and comes on in it starts from there. The list
    /// starts it from where it stood once the headers on screen took their new heights (see unfold): closing, 28 pt
    /// short, so the groups coming up bunched against the one below the closing project, and that header's way up and
    /// the closing one's shrinking looked cut short (the review of round 7's films). Moving already, from a tap before,
    /// it goes on from where it stands.
    private func comeFromOffscreen(_ places: [String: CGFloat], below section: Int, since tapped: CFTimeInterval, run: Int) {
        let header = UICollectionView.elementKindSectionHeader
        var views: [(view: UIView, key: String)] = collectionView.indexPathsForVisibleSupplementaryElements(ofKind: header)
            .filter { $0.section > section }
            .compactMap { path in collectionView.supplementaryView(forElementKind: header, at: path).map { ($0, Self.offscreenKey(header: true, path)) } }
        views += collectionView.indexPathsForVisibleItems.filter { $0.section > section }
            .compactMap { path in collectionView.cellForItem(at: path).map { ($0, Self.offscreenKey(header: false, path)) } }
        // A chat's piece of card under it, with it.
        views += collectionView.subviews.compactMap { view in
            guard let path = (view as? ProjectCardUnderRow)?.indexPath, path.section > section else { return nil }
            return (view, Self.offscreenKey(header: false, path))
        }
        for (view, key) in views {
            guard let was = places[key] else { continue }
            let older = (view.layer.animationKeys() ?? []).contains { key in
                view.layer.animation(forKey: key).map { $0.beginTime > 0 && $0.beginTime < tapped } == true
            }
            guard !older else { continue }
            // Where the list starts it: where it stands, less what its moves in this change hold it off that.
            let start = view.frame.minY + Self.edgeMoves(of: view.layer).reduce(0) { sum, move in
                sum + ((move.fromValue as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0)
            }
            guard abs(was - start) > 0.5 else { continue }
            view.layer.add(Self.unfoldSpring(from: was - start), forKey: "unfold-\(run).off")
        }
    }

    /// The rows' spring: no bounce, long enough to see them come out from under the header.
    static let unfoldDuration: TimeInterval = 0.45

    /// A group its header opened or closed (owner, 2026-11-02: "smoothly roll out so that there's not a jarring jump").
    /// Its rows slide out from under the header as one piece (closing, back under it) while the header settles into its
    /// new shape (a project's row becomes the top of its card, 16 pt lower) and the groups below move, all on one spring.
    /// Each moving row is masked at the header's foot, so none shows above it or over the header. Anything else in the
    /// same change (a count, another group) rides the same spring.
    private func unfold(_ group: SessionGroup, to snapshot: NSDiffableDataSourceSnapshot<String, String>) {
        let tapped = CACurrentMediaTime()
        let offscreen = unfoldOffscreen
        unfoldOffscreen = [:]
        // How far faded in each moving row is now, with the header's card: a tap mid-motion turns the fade round from
        // there. And a group closing that opens again: its chats come back as new rows, each taking over from the row
        // still leaving for it, where it stands and as it moves.
        var faded: [ObjectIdentifier: CGFloat] = [:]
        var twins: [String: UIView] = [:]
        for entry in unfoldMasks where entry.view.layer.mask === entry.mask.layer {
            faded[ObjectIdentifier(entry.view)] = entry.mask.layer.presentation().map { CGFloat($0.opacity) }
            if entry.leaving, let item = entry.item { twins[item] = entry.view }
        }
        endUnfold(interrupted: true)
        let old = dataSource.snapshot()
        let sectionId = group.id + "|" + group.title
        let header = UICollectionView.elementKindSectionHeader
        // Read from the screen, not the layout: the layout already has the group's new insets waiting. The headers on
        // screen are drawn from the new groups, by section, before the change: the sections must stay the same.
        guard let layout = collectionView.collectionViewLayout as? SessionsListLayout,
              old.sectionIdentifiers == snapshot.sectionIdentifiers,
              let section = snapshot.indexOfSection(sectionId),
              let lip = collectionView.supplementaryView(forElementKind: header, at: IndexPath(item: 0, section: section))?.frame.maxY
        else {
            endUnfold()
            dataSource.apply(snapshot, animatingDifferences: true)
            refreshVisibleHeaders()
            return
        }
        let opening = !group.collapsed
        var before: [IndexPath: CGRect] = [:]
        var leaving: [UIView] = []
        var items: [ObjectIdentifier: String] = [:]
        if !opening {
            let ids = old.itemIdentifiers(inSection: sectionId)
            for path in collectionView.indexPathsForVisibleItems where path.section == section {
                guard let cell = collectionView.cellForItem(at: path), !isDying(cell) else { continue }
                before[path] = cell.frame
                leaving.append(cell)
                if path.item < ids.count { items[ObjectIdentifier(cell)] = ids[path.item] }
            }
            leaving += collectionView.subviews.filter { ($0 as? ProjectCardUnderRow)?.indexPath?.section == section && !isDying($0) }
        }
        layout.unfold = .init(section: section, oldSection: section, opening: opening,
                              count: snapshot.numberOfItems(inSection: sectionId), lip: lip, before: before)
        unfoldRun += 1
        let run = unfoldRun
        folding = true
        // Until the spring settles (endUnfold): a header drawn again meanwhile keeps it.
        headerMotion = .spring(duration: Self.unfoldDuration, bounce: 0)
        let visibleHeaders = { self.collectionView.indexPathsForVisibleSupplementaryElements(ofKind: header)
            .compactMap { self.collectionView.supplementaryView(forElementKind: header, at: $0) as? SessionHeaderCell } }
        let rowTops = headerRowTops, cardPads = headerCardPads, shows = headerShows
        // Every spring of the change starts as UIKit's do, when the change is committed: begun from the moment of the
        // tap, a mask ran 2-3 frames ahead of a chat UIKit moves (8 pt off the card's foot as a project closed, a piece
        // of card standing over the header as one opened).
        unfoldBegan = nil
        unfoldClock = nil
        UIView.animate(springDuration: Self.unfoldDuration, bounce: 0, options: [.allowUserInteraction]) {   // motion-ok: reload calls unfold only without Reduce Motion
            // The headers take their new shape at once, out of UIKit's animation (UIKit moving what's inside them piece
            // by piece dropped what was narrowing away below the name), from the top of the frame the list moves. A
            // project's row then glides from where it stood to its new place on the rows' spring, Core Animation's
            // alone: SwiftUI moves only what changes across, so a busy main thread can't make the row stall and jump.
            UIView.performWithoutAnimation {
                self.refreshVisibleHeaders()
                visibleHeaders().forEach { $0.layoutIfNeeded() }
            }
            // ...and their new heights in the list before the change, on the spring: sized after it (at the next
            // layout pass, out of the animation), an opening header's 8 pt more came late. The list then had its chats
            // slide from 8 pt below the card's foot to 8 pt short of their places and jump the rest, everything under
            // it jumped down as the slide began, and the masks stood 8 pt off the card: a gap between the folder's row
            // and the chats coming out (owner on 686, frame by frame), a band of page as a project closed.
            self.collectionView.layoutIfNeeded()
            self.dataSource.apply(snapshot, animatingDifferences: true)
            for view in visibleHeaders() {
                // UIKit's moves of the content itself too, every one: it slid a grown header's content from its old
                // middle, half the growth above where it starts, and sizing each header twice, it moved the content of
                // every header on screen there and back (one of the two left, the first project's name rose into
                // "Projects" and the others' 8 pt, at every tap).
                Self.dropUIKitMoves(in: view.contentView.layer)
                view.captionView.map { Self.dropUIKitMoves(in: $0.layer) }
                let key = ObjectIdentifier(view)
                guard shows[key] == self.headerShows[key], let was = rowTops[key], let now = self.headerRowTops[key], was != now
                else { continue }
                // On top of what's left of a tap before, as UIKit's own moves go: from where it stands, as it moves.
                view.contentView.layer.add(Self.unfoldSpring(from: was - now), forKey: "unfold-\(run)")
                if self.unfoldClock == nil { self.unfoldClock = (view.contentView.layer, "unfold-\(run)") }
                // The card's top stays with the row's own top as that moves, not carried with the folder: the folder
                // stands its pad lower in an open card, so closing, the card's top dropped that much (3-4 pt) at the
                // tap and rose from there (the review of round 7's films). Its foot stays with the folder's row.
                if let wasPad = cardPads[key], let nowPad = self.headerCardPads[key], wasPad != nowPad,
                   let card = Self.cardPiece(in: view.contentView) {
                    let pad = wasPad - nowPad
                    card.layer.add(Self.unfoldSpring(from: -pad / 2), forKey: "unfold-\(run)")
                    let taller = Self.unfoldSpring(from: pad)
                    taller.keyPath = "bounds.size.height"
                    card.layer.add(taller, forKey: "unfold-\(run).height")
                }
            }
            guard let shift = layout.unfoldShift(), shift > 0,
                  let foot = self.collectionView.supplementaryView(forElementKind: header, at: IndexPath(item: 0, section: section)) as? SessionHeaderCell
            else { return }
            let after = foot.frame.maxY
            let inSection = {
                (self.collectionView.indexPathsForVisibleItems.filter { $0.section == section }.compactMap(self.collectionView.cellForItem)
                    + self.collectionView.subviews.filter { ($0 as? ProjectCardUnderRow)?.indexPath?.section == section })
                    .filter { !self.isDying($0) }
            }
            let cover = { (view: UIView) in
                let key = ObjectIdentifier(view)
                var from = faded[key]
                var item = items[key]
                if let card = view as? ProjectCardUnderRow {
                    // Closing, a chat's own piece of card goes with it, as it does from a project at rest (UIKit
                    // hides the one under it at once).
                    guard opening else { return self.hideAtOnce(card) }
                    // Opening, it moves with its chat, exactly, and fades from where its chat does: back before
                    // its row had gone, the chat starts at its leaving row's fade and hides its own piece, so a card
                    // starting from nothing let the page show through the chats (a pale band for a few frames).
                    if let path = card.indexPath, let cell = self.collectionView.cellForItem(at: path) {
                        // The chat hides its own piece (and the line in it) till the spring settles: the line here meanwhile.
                        card.line = (cell.backgroundConfiguration?.customView as? ProjectCardSliceView)?.line ?? .none
                        Self.dropMoves(in: card.layer)
                        for (i, move) in Self.edgeMoves(of: cell.layer).enumerated() { card.layer.add(move, forKey: "unfold-\(run).\(i)") }
                        if let item = self.dataSource.itemIdentifier(for: path), let twin = twins[item], twin !== cell {
                            from = faded[ObjectIdentifier(twin)]
                        }
                    }
                } else if opening {
                    item = (view as? UICollectionViewCell).flatMap(self.collectionView.indexPath).flatMap(self.dataSource.itemIdentifier)
                    if let item, let twin = twins[item], twin !== view {
                        // Back before it had gone: from where its row leaving stands, as that one moves, on to its place.
                        Self.dropMoves(in: view.layer)
                        for (i, move) in Self.edgeMoves(of: twin.layer).enumerated() { view.layer.add(move, forKey: "unfold-\(run).\(i)") }
                        view.layer.add(Self.unfoldSpring(from: twin.frame.minY - view.frame.minY, begin: self.unfoldBegan), forKey: "unfold-\(run)")
                        from = faded[ObjectIdentifier(twin)]
                        self.hideAtOnce(twin)
                    } else if !Self.movedNow(view.layer, began: self.unfoldBegan) {
                        // UIKit sets an opening chat (a self-sizing cell) straight at its place: moved here, on the
                        // same spring, from the header's foot.
                        view.layer.add(Self.unfoldSpring(from: -shift, begin: self.unfoldBegan), forKey: "unfold-\(run)")
                    }
                } else if !Self.movedNow(view.layer, began: self.unfoldBegan) {
                    // A closing row UIKit leaves where it was: moved here, on the same spring, up under the header.
                    UIView.performWithoutAnimation { view.frame.origin.y -= shift }
                    view.layer.add(Self.unfoldSpring(from: shift, begin: self.unfoldBegan), forKey: "unfold-\(run)")
                }
                // The mask's top is the header's foot, as the row sees it, every moment: where the foot stands less where
                // the row stands, each moving as it does (UIKit's moves and the fold's, a tap before's still running).
                let mask = UIView()
                let alpha: CGFloat = opening ? 1 : 0
                UIView.performWithoutAnimation {
                    mask.backgroundColor = .black
                    mask.frame = CGRect(x: -400, y: after - view.frame.minY, width: view.bounds.width + 800, height: 20_000)
                    // Out of the block's animation: UIKit faded it too, on top of the spring below.
                    mask.alpha = alpha
                }
                let moves = Self.edgeMoves(of: foot.layer) + Self.edgeMoves(of: foot.contentView.layer, foot: true)
                    + Self.edgeMoves(of: view.layer, sign: -1)
                for (i, move) in moves.enumerated() { mask.layer.add(move, forKey: "unfold-\(i)") }
                // In and out with the header's card (`ProjectCardPiece`), on its spring from the same moment: one card
                // growing and shrinking. Closing, the leaving card's last sliver lingered under the header on the
                // spring's slow end (owner on 679, "not perfect").
                mask.layer.add(Self.unfoldFade(from: (from ?? 1 - alpha) - alpha, begin: self.unfoldBegan), forKey: "fade")
                // A chat in a card draws its piece of card over the one under it (the list's, for its swipes): faded,
                // the two pieces read lighter than the card around them. The one under it, with the card's edges, alone.
                if let cell = view as? SessionListCell {
                    cell.cardPieceHidden = opening && cell.clipsToCard && self.collectionView.indexPath(for: cell).map { path in
                        self.collectionView.subviews.contains { ($0 as? ProjectCardUnderRow)?.indexPath == path && !$0.isHidden }
                    } == true
                    // Closing, the piece under it (with the card's edges) is gone at once: its own draws them, or the
                    // Desktop Look's card lost its sides beside the chats going up (the review of round 7's films).
                    cell.cardPieceEdged = !opening
                }
                view.layer.mask = mask.layer
                self.unfoldMasks.removeAll { $0.view === view }
                self.unfoldMasks.append((view, mask, !opening, item))
                if self.unfoldClock == nil { self.unfoldClock = (mask.layer, "fade") }
            }
            let moving = opening ? inSection() : leaving
            moving.forEach(cover)
            // Rows a tap before left that this one didn't bring back (another group's, or gone off screen): faded away.
            let now = Set(moving.map(ObjectIdentifier.init))
            for entry in self.unfoldMasks where entry.leaving && !now.contains(ObjectIdentifier(entry.view)) {
                self.fadeAway(entry.view, entry.mask)
            }
            self.watchUnfold(section: section, opening: opening, inSection: inSection, cover: cover)
        }
        // A header view given another group in the change (back from the reuse pool, as a closing project brings the
        // groups below it on screen) stands drawn as it ends, moved only with the list: drawn inside the block, what's in
        // it moved on its own (Home's house shaped out of the folder its view drew a moment before, a card's fill
        // sliding and stretching over the rows).
        for view in visibleHeaders() where shows[ObjectIdentifier(view)] != headerShows[ObjectIdentifier(view)] {
            Self.dropAllMoves(in: view.contentView.layer)
            view.captionView.map { Self.dropAllMoves(in: $0.layer) }
        }
        comeFromOffscreen(offscreen, below: section, since: tapped, run: run)
        // Not the animation's completion: UIKit calls that at once, the list's own moves not being the block's.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.unfoldSpring(from: 0).settlingDuration) { [weak self] in
            guard let self, self.unfoldRun == run else { return }
            self.endUnfold()
            self.endFold()
        }
        layout.unfold = nil
    }

    /// The same spring fading a layer in or out: `from` its opacity's way off where it ends.
    static func unfoldFade(from offset: CGFloat, begin: CFTimeInterval? = nil) -> CASpringAnimation {
        let fade = unfoldSpring(from: offset, begin: begin)
        fade.keyPath = "opacity"
        return fade
    }

    /// The same spring as `UIView.animate(springDuration: unfoldDuration, bounce: 0)`'s, moving a layer down by `from`
    /// to where it stands.
    private static func unfoldSpring(from offset: CGFloat, begin: CFTimeInterval? = nil) -> CASpringAnimation {
        let spring = CASpringAnimation(perceptualDuration: unfoldDuration, bounce: 0)   // motion-ok: unfold's alone, see above
        spring.keyPath = "position.y"
        spring.isAdditive = true
        spring.fromValue = offset
        spring.toValue = 0
        spring.duration = spring.settlingDuration
        if let begin {
            spring.beginTime = begin
            spring.fillMode = .backwards
        }
        return spring
    }

    /// [project-unfold] A layer's moves up and down still running (UIKit's and the fold's, each as timed), as moves of a
    /// `position.y` by how far they hold its top (or `foot`) off where it stands, times `sign`.
    private static func edgeMoves(of layer: CALayer, foot: Bool = false, sign: CGFloat = 1) -> [CABasicAnimation] {
        var moves: [(height: Bool, move: CABasicAnimation)] = []
        for key in layer.animationKeys() ?? [] {
            guard let move = layer.animation(forKey: key) as? CABasicAnimation, let path = move.keyPath else { continue }
            let height: Bool
            let value: (Any?) -> CGFloat?
            switch path {
            case "position": height = false; value = { ($0 as? NSValue)?.cgPointValue.y }
            case "position.y": height = false; value = { ($0 as? NSNumber).map { CGFloat($0.doubleValue) } }
            case "bounds": height = true; value = { ($0 as? NSValue)?.cgRectValue.height }
            case "bounds.size": height = true; value = { ($0 as? NSValue)?.cgSizeValue.height }
            case "bounds.size.height": height = true; value = { ($0 as? NSNumber).map { CGFloat($0.doubleValue) } }
            default: continue
            }
            var from = value(move.fromValue) ?? 0, to = value(move.toValue) ?? 0
            if !move.isAdditive {
                // It stands for all before it: from and to as ways off where the layer ends.
                let model = height ? layer.bounds.height : layer.position.y
                from = (value(move.fromValue) ?? model) - model
                to = (value(move.toValue) ?? model) - model
                moves.removeAll { $0.height == height }
            }
            guard from != 0 || to != 0 else { continue }
            // The top moves with the middle, less the height above the anchor; the foot, plus the height below it.
            let k = sign * (height ? (foot ? 1 - layer.anchorPoint.y : -layer.anchorPoint.y) : 1)
            guard let copy = move.copy() as? CABasicAnimation else { continue }
            copy.keyPath = "position.y"
            copy.isAdditive = true
            copy.fromValue = k * from
            copy.toValue = k * to
            copy.byValue = nil
            copy.delegate = nil
            moves.append((height, copy))
        }
        return moves.map(\.move)
    }

    /// [project-unfold] UIKit moved the layer in this change (not only in a change before, still running).
    private static func movedNow(_ layer: CALayer, began: CFTimeInterval?) -> Bool {
        (layer.animationKeys() ?? []).contains { key in
            guard key == "position" || key.hasPrefix("position-"), let move = layer.animation(forKey: key) else { return false }
            return move.beginTime == 0 || began.map { abs(move.beginTime - $0) < 0.004 } == true
        }
    }

    /// [project-unfold] A moving row hidden at once (its twin took its place, or a closing chat's piece of card), until
    /// UIKit is done with it.
    private func hideAtOnce(_ view: UIView) {
        let mask = UIView()
        UIView.performWithoutAnimation {
            mask.backgroundColor = .black
            mask.alpha = 0
        }
        view.layer.mask = mask.layer
        unfoldMasks.removeAll { $0.view === view }
        unfoldDying.append((view, mask))
    }

    /// [project-unfold] A row on its way out keeps its mask, faded to nothing: unmasked it stood over the header until
    /// UIKit took it away.
    private func fadeAway(_ view: UIView, _ mask: UIView) {
        let fade = CABasicAnimation(keyPath: "opacity")   // motion-ok: hides a row mid-fold, see above
        fade.fromValue = mask.layer.presentation()?.opacity ?? mask.layer.opacity
        fade.toValue = 0
        fade.duration = 0.12
        UIView.performWithoutAnimation { mask.alpha = 0 }
        mask.layer.add(fade, forKey: "fade")
        unfoldMasks.removeAll { $0.view === view }
        unfoldDying.append((view, mask))
    }

    /// [project-unfold] Hidden or fading away until UIKit is done with it (its mask still the one it was given).
    private func isDying(_ view: UIView) -> Bool {
        unfoldDying.contains { $0.view === view && view.layer.mask === $0.mask.layer }
    }

    /// [project-unfold] Each frame until the spring settles: a row of the opening group that came on screen after the
    /// change (a cell made on the next layout pass) gets its mask and spring then, mid-way like the rest, and a frame
    /// where a masked row still shows above its header's foot is counted. One log line per fold says how it went.
    private func watchUnfold(section: Int, opening: Bool,
                             inSection: @escaping () -> [UIView], cover: @escaping (UIView) -> Void) {
        let header = UICollectionView.elementKindSectionHeader
        var frames = 0, late = 0, leaks = 0, firstLeak: Int?, worst: CGFloat = 0
        unfoldWatch = { [weak self] in
            guard let self else { return }
            // When the springs began, once the change is on screen (a row that comes late joins them mid-way). Until
            // then (the first tick can come before it), a row that comes starts with them.
            if self.unfoldBegan == nil, let clock = self.unfoldClock,
               let began = clock.layer.animation(forKey: clock.key)?.beginTime, began > 0 {
                self.unfoldBegan = began
            }
            if opening {
                let covered = Set(self.unfoldMasks.map { ObjectIdentifier($0.view) })
                for view in inSection() where !covered.contains(ObjectIdentifier(view)) {
                    late += 1
                    cover(view)
                }
            }
            guard self.unfoldBegan != nil,
                  let foot = self.collectionView.supplementaryView(forElementKind: header, at: IndexPath(item: 0, section: section)) as? SessionHeaderCell
            else { return }
            frames += 1
            // The card's foot: the header's top and its content's foot (the header's own frame runs on, sized twice).
            let card = (foot.layer.presentation() ?? foot.layer).frame.minY + (foot.contentView.layer.presentation() ?? foot.contentView.layer).frame.maxY
            let above = self.unfoldMasks.map { view, mask, _, _ in
                let row = (view.layer.presentation() ?? view.layer).frame
                let top = row.minY + (mask.layer.presentation() ?? mask.layer).frame.minY
                return top < row.maxY ? card - top : 0
            }.max() ?? 0
            worst = max(worst, above)
            if above > 2 { leaks += 1; firstLeak = firstLeak ?? frames }
        }
        let link = CADisplayLink(target: UnfoldTick { [weak self] in self?.unfoldWatch?() }, selector: #selector(UnfoldTick.tick))   // motion-ok: only watches unfold's springs
        link.add(to: .main, forMode: .common)
        unfoldLink = link
        let rows = unfoldMasks.count
        // The line, as the watch stops (endUnfold).
        unfoldReport = { [weak self] in
            let began = self?.unfoldBegan ?? CACurrentMediaTime()
            AppLog.trace("sessions", "fold \(opening ? "open" : "close"): \(rows) rows masked, \(late) late, "
                + "\(leaks) of \(frames) frames showed a row above its header"
                + (firstLeak.map { " (from frame \($0), up to \(Int(worst.rounded())) pt)" } ?? "")
                + String(format: ", %.0f ms", (CACurrentMediaTime() - began) * 1000))
        }
    }

    /// UIKit's moves (an enclosing animation block's, of position and size, each of them) taken off a layer and all
    /// within it.
    private static func dropUIKitMoves(in layer: CALayer) {
        dropMoves(in: layer)
        layer.sublayers?.forEach(dropUIKitMoves)
    }

    /// [project-unfold] A header's piece of card (`ProjectCardPiece`), within its content.
    private static func cardPiece(in view: UIView) -> ProjectCardSliceView? {
        for sub in view.subviews {
            if let card = sub as? ProjectCardSliceView ?? cardPiece(in: sub) { return card }
        }
        return nil
    }

    /// Every animation a layer and all within it has, taken off.
    private static func dropAllMoves(in layer: CALayer) {
        layer.removeAllAnimations()
        layer.sublayers?.forEach(dropAllMoves)
    }

    /// UIKit's moves taken off a layer alone: a second move of a layer already moving is "position-2", and so on.
    private static func dropMoves(in layer: CALayer) {
        for key in layer.animationKeys() ?? [] where key == "position" || key.hasPrefix("position-") || key.hasPrefix("bounds") {
            layer.removeAnimation(forKey: key)
        }
    }

    /// [project-unfold] The spring settled: what waited comes as one reload.
    private func endFold() {
        folding = false
        FrameMeter.shared.end(foldMeter, after: 0.05)
        foldMeter = nil
        guard reloadAfterFold else { return }
        reloadAfterFold = false
        setNeedsReload()
    }

    /// The watch stops (a tap mid-motion leaves the rows moving, for the next fold to take on from where they are);
    /// settled, the moving rows are whole again.
    private func endUnfold(interrupted: Bool = false) {
        unfoldLink?.invalidate()
        unfoldLink = nil
        unfoldWatch = nil
        unfoldReport?()
        unfoldReport = nil
        guard !interrupted else { return }
        // UIKit is done with them by now (their removal ran on an earlier, shorter spring).
        for (view, mask) in unfoldDying where view.layer.mask === mask.layer { view.layer.mask = nil }
        unfoldDying = []
        for (view, mask, _, _) in unfoldMasks {
            if view.layer.mask === mask.layer { view.layer.mask = nil }
            (view as? SessionListCell)?.cardPieceHidden = false
            (view as? SessionListCell)?.cardPieceEdged = false
            (view as? ProjectCardUnderRow)?.line = .none   // the chat's own piece draws it again, in the same frame
        }
        unfoldMasks = []
        unfoldClock = nil
        headerMotion = nil
    }

    /// [sessions-fresh] See All in Pinned's or Projects' header: the rest drawn in place; Show Less, the newest few.
    private func toggleSeeAll(_ id: String) {
        guard let store else { return }
        Haptics.play(.selection)
        let all = id == SessionListPipeline.projectsId
            ? groups.contains { $0.projectsAll }
            : groups.first { $0.id == id }?.expanded == true
        store.setGroupExpanded(id, !all)
        reload(animated: true)
    }

    /// Show More under a project draws all its chats; Show Less goes back to the newest few, keeping the row in view.
    private func toggleShowMore(_ id: String) {
        guard let store, let group = groups.first(where: { $0.id == id }) else { return }
        Haptics.play(.selection)
        let opening = group.more > 0
        store.setGroupExpanded(id, opening)
        reload(animated: true)
        guard !opening, let path = dataSource.indexPath(for: Self.moreKey(id)),
              !collectionView.indexPathsForVisibleItems.contains(path) else { return }
        collectionView.scrollToItem(at: path, at: .centeredVertically, animated: !HQMotion.reduced)
    }

    /// The Show More row's item under a group (never a session key, which is profile + "\u{1F}" + id).
    static func moreKey(_ groupId: String) -> String { "\u{1F}more\u{1F}" + groupId }

    /// [project-cards] The New Chat row at the foot of a project's card.
    static func newKey(_ groupId: String) -> String { "\u{1F}new\u{1F}" + groupId }

    /// The project a New Chat item belongs to; nil for any other item.
    static func groupId(newKey key: String) -> String? {
        let prefix = "\u{1F}new\u{1F}"
        return key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil
    }

    /// [project-cards] A chat's second row: in its project while New for You lists it too (an item id is listed once).
    static func copyKey(_ key: String) -> String { copyPrefix + key }
    private static let copyPrefix = "\u{1F}also\u{1F}"
    static func isCopy(_ item: String) -> Bool { item.hasPrefix(copyPrefix) }
    /// The chat's own key for an item: a second row's chat, or the item itself.
    static func realKey(_ item: String) -> String { isCopy(item) ? String(item.dropFirst(copyPrefix.count)) : item }

    /// [project-cards] The bots a project's chats belong to, newest first, with their names and faces.
    private func projectBots(_ group: SessionGroup) -> [ProjectBot] {
        group.profiles.map { profile in
            ProjectBot(profile: profile, head: owners[profile]?.head, name: owners[profile]?.name ?? Self.readableProfileName(profile))
        }
    }

    /// [project-cards] New Chat at the foot of a project's card: the project's bots (the picked chip's, else the one
    /// with its newest chat, ticked); Other Bots… opens Choose a Bot. Home's chats start in no project.
    private func newChatRow(_ group: SessionGroup) -> ProjectNewChatRow {
        let key = SessionListPipeline.projectKey(group.id) ?? SessionProjects.homeKey
        let home = key == SessionProjects.homeKey
        let bots = projectBots(group)
        let others = Set(services.bots.map(\.id)).subtracting(bots.map(\.profile))
        return ProjectNewChatRow(
            title: group.title, bots: bots, pick: pickedBot ?? bots.first?.profile, otherBots: !others.isEmpty,
            onPick: { [weak self] profile in
                if home { self?.organizer?.compose(profile: profile) } else { self?.organizer?.newChat(inProject: key, profile: profile) }
            },
            onOther: { [weak self] in
                if home { self?.organizer?.compose(profile: nil) } else { self?.organizer?.newChat(inProject: key, profile: nil) }
            })
    }

    /// What a New Chat row draws (a change redraws it).
    private func newChatSign(_ group: SessionGroup) -> Int {
        var hasher = Hasher()
        hasher.combine(projectBots(group).map { [$0.profile, $0.name] })
        hasher.combine(pickedBot)
        hasher.combine(services.bots.count)
        hasher.combine(group.title)
        return hasher.finalize()
    }

    /// The group a Show More item belongs to; nil for any other item.
    static func groupId(moreKey key: String) -> String? {
        let prefix = "\u{1F}more\u{1F}"
        return key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil
    }

    /// The row at `indexPath` wears the working ring.
    private func ringed(_ indexPath: IndexPath) -> Bool {
        guard let key = dataSource.itemIdentifier(for: indexPath) else { return false }
        return ringedKeys.contains(key)
    }

    /// The bot a session belongs to: its display name ("Hermes" for default) and head.
    func ownerName(of session: SessionSummary) -> String { owner(of: session).name }

    func owner(of session: SessionSummary) -> (name: String, head: JSONValue?) {
        if let bot = owners[session.profile] { return (bot.name, bot.head) }
        return (Self.readableProfileName(session.profile), nil)
    }

    /// `default` → "Hermes"; else the profile name in Title Case with `-`/`_` as spaces (spec 02 §6.1).
    /// The Other Apps row's item (never a session key, which is profile + "\u{1F}" + id).
    static let otherAppsKey = "\u{1F}other-apps"

    /// Other Apps: a page with a section per platform; its rows open and act as the list's rows do.
    func openOtherApps() {
        guard let store else { return }
        let page = OtherAppsViewController(list: self, store: store)
        otherAppsWillShow(page)         // before the push, so the slide already shows its Back
        navigationController?.pushViewController(page, animated: true)
    }

    /// The unread count the tab controller gives Back ("3", Messages' count; nil with none), for a chat over the list.
    var backCount: String? {
        didSet { if backCount != oldValue { applyBackTitle() } }
    }

    /// The Other Apps page is the page above the list: its Back names the list (a plain chevron in the Desktop Look, as
    /// the look's other pushed pages draw it), not the count. A chat opened from the page shows the count, as one
    /// opened from the list does.
    private var otherAppsOnTop = false {
        didSet { if otherAppsOnTop != oldValue { applyBackTitle() } }
    }

    func otherAppsWillShow(_ page: OtherAppsViewController) {
        otherAppsPage = page
        otherAppsOnTop = true
        applyBackTitle()
    }

    private func applyBackTitle() {
        let title = otherAppsOnTop ? (Theme.isDesktop ? nil : "Sessions") : backCount
        if navigationItem.backButtonTitle != title { navigationItem.backButtonTitle = title }
        if let page = otherAppsPage, page.navigationItem.backButtonTitle != backCount { page.navigationItem.backButtonTitle = backCount }
        DesktopBack.backTitleChanged()                    // the fitted Back of the page on top shows the new count
    }

    func isBusy(_ key: String) -> Bool { busy.contains(key) }

    static func readableProfileName(_ profile: String) -> String {
        let name = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "default" { return "Hermes" }
        return name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// Asks for a reload on the next turn of the run loop: a burst of changes (stream events, a roster refresh)
    /// becomes one reload. Off screen (another tab, or a chat pushed over the list) the reload waits for
    /// `viewWillAppear`. The tab controller calls this when the roster changes, since rows show their owner's name
    /// and head.
    func setNeedsReload(animated: Bool = true) {
        otherAppsPage?.setNeedsReload()
        guard isViewLoaded else { return }
        guard view.window != nil else { needsReload = true; return }
        // [perf] Mid-slide the change folds into one reload at its end (as on Bots).
        if let coordinator = transitionCoordinator ?? navigationController?.transitionCoordinator {
            needsReload = true
            reloadWhenTransitionEnds(coordinator)
            return
        }
        // [project-unfold] Mid-fold the change waits for the spring to settle (endFold).
        if folding { reloadAfterFold = true; return }
        guard !reloadPending else { return }
        reloadPending = true
        let asked = reloads
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadPending = false
            // [project-unfold] A reload since (a header tap's, whose own store change asked for this one) has it all.
            guard self.reloads == asked else { return }
            self.reload(animated: animated)
        }
    }

    /// [perf] Reloads when `coordinator`'s transition ends, if the list is still on screen and still needs it (as on
    /// Bots: a cancelled swipe back leaves the flag for the next `viewWillAppear`).
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

    /// Rebuilds the list from `services.sessions` and `services.bots` now. Same ids keep their cells; changed rows
    /// are reconfigured in place.
    func reload(animated: Bool) {
        guard isViewLoaded else { return }
        needsReload = false
        var seen = Set<String>()
        let base: [SessionSummary]
        if let store {
            // The store has already applied Filter › Show (background runs, pinned runs kept, outside chats). Archived
            // chats join the rest.
            base = showArchived ? store.liveRows + store.archivedSessions : store.liveRows
            // A chat's menu offers New Chat in its project: the listed bots' projects are read (once a minute at most).
            if !base.isEmpty { store.loadProjects() }
        } else {
            base = SessionList.visible(services.sessions)
        }
        owners = Dictionary(services.bots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        refreshChrome()                         // [sessions-m9] chips, strip, the button
        // [sessions-m9] Projects that arrive while the Filter menu is open appear in it without reopening it.
        if let store {
            let projects = store.projectEntries(order: chipBots.map(\.id), bot: store.botFilter)
            if projects != menuProjects {
                menuProjects = projects
                redrawOpenMenu()
            }
        }
        let sessions: [SessionSummary]
        if searching {
            // [sessions-m9] The chip still applies while a query is typed; the Filter menu's filters do not (§7.4).
            let picked = pickedBot
            let listed = base.filter { (picked == nil || $0.profile == picked) && seen.insert(Self.key($0)).inserted }
            sessions = searchResults(in: listed)
            groups = sessions.isEmpty ? [] : [SessionGroup(id: "results", title: "", sessions: sessions)]
        } else if let store {
            // [sessions-m9] One pipeline: pool, filter, pinned, sort, group (`SessionListPipeline`).
            // [manual-order] Group By Bot's headers name each bot as its rows do.
            let names = Dictionary(Set(base.map(\.profile)).map { ($0, owners[$0]?.name ?? Self.readableProfileName($0)) },
                                   uniquingKeysWith: { first, _ in first })
            // [sessions-layout] New for You keeps what it lifted until the page is left. Two panes keep the list on
            // screen beside the chat, so only the chat on show stays there once read.
            if paneKeepsSelection { store.keepNew.formIntersection(onShowKey.map { [$0] } ?? []) }
            store.holdNew()
            groups = store.listGroups(order: chipBots.map(\.id), botNames: names)
            sessions = groups.flatMap(\.sessions)
        } else {
            sessions = base.filter { seen.insert(Self.key($0)).inserted }
            // Pinned first, in the store's order; then the date groups.
            let pinned = sessions.filter(\.pinned)
            groups = (pinned.isEmpty ? [] : [SessionGroup(id: "pinned", title: "Pinned", sessions: pinned)])
                + SessionGrouping.groups(sessions.filter { !$0.pinned })
        }
        // [sessions-m9] A section gains or loses its header: the layout is read again.
        let flags = groups.map { !searching && !$0.title.isEmpty }
        let openCards = groups.indices.map(isOpenCard)
        if flags != headerFlags || openCards != openCardFlags {
            headerFlags = flags
            openCardFlags = openCards
            collectionView.collectionViewLayout.invalidateLayout()
        }
        sessionsByID = Dictionary(sessions.map { (Self.key($0), $0) }, uniquingKeysWith: { first, _ in first })
        let fresh = !searching && freshLayout
        let pinnedKeys = searching ? [] : Set(groups.first { $0.id == "pinned" }?.sessions.map(Self.key) ?? [])
        compactKeys = fresh ? [] : pinnedKeys
        freshPinnedKeys = fresh ? pinnedKeys : []
        freshKeys = []
        shortKeys = searching ? [] : Set(groups.first { $0.id == SessionListPipeline.newId }?.sessions.map(Self.key) ?? [])
        cardKeys = [:]
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        var listed = Set<String>()
        // [sessions-fresh] Recent keeps its chats' own ids: a project's card draws its copies, so opening one leaves
        // Recent's rows as they are.
        let recentKeys = fresh ? Set(groups.first { $0.id == SessionListPipeline.recentId }?.sessions.map(Self.key) ?? []) : []
        // The title is part of the section's identity: at midnight "Today" becomes "Yesterday" for the same day.
        for group in groups {
            let section = group.id + "|" + group.title
            snapshot.appendSections([section])
            // [project-cards] A project draws its chats in New for You as well: that second row has an id of its own.
            let card = !searching && SessionListPipeline.isProject(group.id)
            let recent = group.id == SessionListPipeline.recentId
            let items = group.sessions.map { session -> String in
                let key = Self.key(session)
                guard recent || !recentKeys.contains(key), listed.insert(key).inserted else {
                    sessionsByID[Self.copyKey(key)] = session
                    return Self.copyKey(key)
                }
                return key
            }
            if card { for item in items { cardKeys[item] = group.title } }
            if !searching && ((fresh && recent) || group.id == SessionListPipeline.chipId) { freshKeys.formUnion(items) }
            snapshot.appendItems(items, toSection: section)
            if group.id == SessionListPipeline.otherAppsId { snapshot.appendItems([Self.otherAppsKey], toSection: section) }
            // [sessions-fresh] Group By Recent's Pinned says See All in its header instead.
            if !group.collapsed, group.more > 0 || group.expanded, !(fresh && group.id == "pinned") {
                snapshot.appendItems([Self.moreKey(group.id)], toSection: section)
            }
            if card, !group.collapsed, organizer != nil { snapshot.appendItems([Self.newKey(group.id)], toSection: section) }
        }
        // The Other Apps row redraws when its platforms, count or time change.
        if let apps = groups.first(where: { $0.id == SessionListPipeline.otherAppsId }) {
            let sign = apps.platforms.joined(separator: ",") + "|\(apps.total)|" + ListTime.string(apps.newest) + "|\(apps.waiting)|\(Theme.isDesktop)"
            if sign != otherAppsSign, snapshot.itemIdentifiers.contains(Self.otherAppsKey) { snapshot.reconfigureItems([Self.otherAppsKey]) }
            otherAppsSign = sign
        }
        var next: [String: Int] = [:]
        for id in snapshot.itemIdentifiers {
            guard let session = sessionsByID[id] else { continue }
            var hasher = Hasher()
            hasher.combine(session)
            hasher.combine(ListTime.string(session.lastActive))
            let owner = owner(of: session)
            hasher.combine(owner.name)
            hasher.combine(owner.head)
            hasher.combine(busy.contains(Self.realKey(id)))
            hasher.combine(cardKeys[id])                                    // [project-cards] in a card, and whose
            hasher.combine(rowDetail)             // [sessions-m9]
            hasher.combine(BotMuteCenter.shared.isMuted(session.profile))   // UX study #248
            hasher.combine(compactKeys.contains(id))                        // [sessions-layout] Pinned's one line
            hasher.combine(shortKeys.contains(id))                          // [sessions-layout] New for You's one line
            hasher.combine(freshKeys.contains(id))                          // [sessions-fresh] Fresh's rows
            hasher.combine(freshPinnedKeys.contains(id))
            hasher.combine(store?.view.botFaces)                            // [sessions-fresh] Show › Bot Faces
            next[id] = hasher.finalize()
        }
        // A Show More row turns into Show Less (or its count moves) under the same item.
        for group in groups where !group.collapsed && (group.more > 0 || group.expanded) {
            next[Self.moreKey(group.id)] = group.more
        }
        // [project-cards] New Chat redraws when the project's bots or the chip change.
        for group in groups where !group.collapsed && SessionListPipeline.isProject(group.id) {
            next[Self.newKey(group.id)] = newChatSign(group)
        }
        let changed = snapshot.itemIdentifiers.filter { id in signatures[id].map { $0 != next[id] } ?? false }
        if !changed.isEmpty { snapshot.reconfigureItems(changed) }
        if !searching {
            AppLog.trace("sessions", "list drawn: \(groups.count) sections, \(sessions.count) rows, \(changed.count) reconfigured")
        }
        signatures = next
        reloads += 1
        let motion = animated && view.window != nil && !HQMotion.reduced
        if motion, let id = unfoldGroup, let group = groups.first(where: { $0.id == id }) {
            unfold(group, to: snapshot)
        } else {
            dataSource.apply(snapshot, animatingDifferences: motion)
            refreshVisibleHeaders()
        }
        unfoldGroup = nil
        // A row starts or stops working: its neighbours' hairlines are asked again.
        let rings = Set(snapshot.itemIdentifiers.filter { id in
            sessionsByID[id].map { SessionRowView.showsArc($0, busy: busy.contains(Self.realKey(id))) } ?? false
        })
        if rings != ringedKeys {
            ringedKeys = rings
            // [perf] The Desktop Look hides every hairline anyway: nothing to ask again (a look change invalidates).
            if !Theme.isDesktop { collectionView.collectionViewLayout.invalidateLayout() }
        }
        if paneKeepsSelection, onShowKey != nil { markOnShow(onShowKey, keepsSelection: true) }   // [m9/ipad]
        #if DEBUG
        debugScrollToProject()
        debugToggleLoop()
        #endif
        // The Other Apps row holds no sessions of its own, but it is a row: nothing empty is drawn behind it. A closed
        // group draws no rows but its header is there: every group closed is not "No Chats Yet" (owner, 2026-10-29).
        let listEmpty = sessions.isEmpty && !groups.contains { $0.id == SessionListPipeline.otherAppsId || $0.collapsed }
        if listEmpty {
            if searching {
                // A spinner while the gateway search runs; the magnifier only once it has answered.
                var empty: UIContentUnavailableConfiguration = searchTask != nil ? .loading() : .search()
                let words = SessionsSearchWords.empty(query: query, searching: searchTask != nil, failed: searchFailed)
                empty.text = words.text
                empty.secondaryText = words.secondary
                showEmptyState(empty)
            } else if loadEmptyState == .loading {
                // Nothing has been read yet (the archived chats, or a first launch with no cache): nothing is known to
                // be missing yet.
                var empty = UIContentUnavailableConfiguration.loading().hqScaled()
                empty.text = SessionsLoadWords.loading
                if slowClock.slow {
                    // UX study #206: the More pages' slow line and Try Again (MoreSkeleton).
                    empty.secondaryText = RosterStateCopy.slowPage
                    var button = UIButton.Configuration.plain()
                    button.title = RosterStateCopy.tryAgain
                    empty.button = button
                    empty.buttonProperties.primaryAction = UIAction { [weak self] _ in
                        self?.slowClock.restart()
                        self?.retryLoad()
                    }
                }
                showEmptyState(empty)
            } else if case .failed(let title, let reason) = loadEmptyState {
                // UX study 2026-10-19 #27: a failed read with nothing on hand says so, with Try Again, never "No Chats Yet".
                showEmptyState(PageStates.error(title: title, reason: reason) { [weak self] in self?.retryLoad() })
            } else if let state = filterStateNow(), SessionFilterWords.filtersActive(state) {
                // [sessions-m9] The filters (or a chip) leave nothing (§6.3). A chip alone names its bot and offers New
                // Chat with it (no filter was set).
                let chipOnly = SessionFilterWords.filterCount(state) == 0 ? state.botFilter : nil
                let botName = chipOnly.map { owners[$0]?.name ?? Self.readableProfileName($0) }
                let compose: (() -> Void)? = organizer == nil ? nil : { [weak self] in
                    self?.organizer?.compose(profile: self?.pickedBot, asksProject: true)
                }
                showEmptyState(UIHostingConfiguration {
                    SessionsNoMatchView(bot: botName, compose: compose) { [weak self] in self?.perform(.clear, nil) }
                })
            } else {
                // UX study 2026-10-19 #30, #31: plain words, and the compose button's own action right here.
                var empty = UIContentUnavailableConfiguration.empty().hqScaled()
                empty.image = UIImage(systemName: "bubble.left.and.bubble.right")
                empty.text = "No Chats Yet"
                // [mac] Mac polish #129: the Mac has a sidebar, not a Bots tab.
                empty.secondaryText = "New chats you start with the compose button appear here. "
                    + (DeviceWord.isMac ? "Each bot’s main chat is in the sidebar under Bots." : "Each bot’s main chat stays on the Bots tab.")
                if organizer != nil {
                    var button = UIButton.Configuration.hqPush()
                    button.title = "New Chat"
                    empty.button = button
                    empty.buttonProperties.primaryAction = UIAction { [weak self] _ in
                        self?.organizer?.compose(profile: self?.pickedBot, asksProject: true)
                    }
                }
                showEmptyState(empty)
            }
        } else {
            showEmptyState(nil)
            schedulePeek()
        }
        slowClock.update(loading: listEmpty && !searching && loadEmptyState == .loading)   // UX study #206
        if let started = refreshStarted {
            let wait = max(0, 0.6 - Date().timeIntervalSince(started))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.endRefreshing() }
        }
        scheduleRollover()
    }

    /// What an empty list shows: Loading or "Couldn’t Load Chats" while nothing is on hand, else its usual words. With
    /// Show › Archived on, the archived read speaks once the main one has nothing to say.
    private var loadEmptyState: SessionsEmptyState {
        guard let store else { return .usual }
        let main = SessionsEmptyState.choose(store.loadState, holdsRows: store.holdsRows, archived: false, retrying: retryingLoad)
        guard showArchived, main == .usual else { return main }
        return .choose(store.archivedLoadState, holdsRows: !store.archivedRows.isEmpty, archived: true, retrying: retryingLoad)
    }

    /// Try Again under "Couldn’t Load Chats": Loading until the read answers, then whatever it brought.
    private func retryLoad() {
        guard let store, !retryingLoad else { return }
        retryingLoad = true
        reload(animated: false)
        let archived = showArchived
        Task { [weak self] in
            await store.refresh()
            if archived { await store.loadArchived() }
            guard let self else { return }
            self.retryingLoad = false
            self.setNeedsReload(animated: false)
        }
    }

    /// The groups change at 4 AM: reload then (a timer that fired late after a suspension still fires on resume).
    private func scheduleRollover() {
        rolloverTimer?.invalidate()
        guard !groups.isEmpty, let next = SessionGrouping.nextRollover(after: Date()) else { return }
        let timer = Timer(fire: next.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.setNeedsReload(animated: false) }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        rolloverTimer = timer
    }

    private func pulledToRefresh() {
        refreshStarted = Date()
        refreshGeneration += 1
        let generation = refreshGeneration
        if showArchived, let store {
            Task { [weak self] in
                let failed = await store.loadArchived()
                self?.endRefreshing()
                // UX study #205: a failed read that kept the archived rows says so, as the main list's pull does.
                guard let self, failed, self.refreshGeneration == generation, self.showArchived else { return }
                self.notices.show("Couldn’t refresh. Showing what was saved.")
            }
        }
        if let store {
            Task { [weak self] in
                await store.refresh()
                // The list stays as saved; without a word the pull looked like it worked.
                guard let self, self.refreshGeneration == generation,
                      case .failed = store.loadState, store.holdsRows else { return }
                self.notices.show("Couldn’t refresh. Showing what was saved.")
            }
        } else {
            services.refreshSessions()
        }
        // Never spin forever if the list doesn't answer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.refreshGeneration == generation else { return }
            self.endRefreshing()
        }
    }

    private func endRefreshing() {
        refreshStarted = nil
        if collectionView.refreshControl?.isRefreshing == true { collectionView.refreshControl?.endRefreshing() }
    }

    // MARK: [m9/ipad] Two panes (App/Root/PaneRouter.swift)

    /// Two panes: the row of the chat on show stays marked while the list shows.
    private var paneKeepsSelection = false
    /// The chat the right pane shows (kept so the mark comes back after the list reloads).
    private var onShowKey: String?

    /// Marks the row of the chat the right pane shows (`key`: profile + stored id); nil clears it.
    func markOnShow(_ key: String?, keepsSelection: Bool) {
        paneKeepsSelection = keepsSelection
        onShowKey = keepsSelection ? key : nil
        guard isViewLoaded, dataSource != nil else { return }
        // [project-cards] The chat's own row, else its second row in its project (New for You closed).
        let path = key.flatMap { dataSource.indexPath(for: $0) ?? dataSource.indexPath(for: Self.copyKey($0)) }
        for selected in collectionView.indexPathsForSelectedItems ?? [] where selected != path {
            collectionView.deselectItem(at: selected, animated: false)
        }
        if let path { collectionView.selectItem(at: path, animated: false, scrollPosition: []) }
    }

    /// The rows as the list shows them now, top to bottom (Next / Previous Chat walk this order).
    var paneOrder: [String] {
        guard isViewLoaded, dataSource != nil else { return [] }
        return dataSource.snapshot().itemIdentifiers.filter { sessionsByID[$0] != nil && !Self.isCopy($0) && !busy.contains($0) }
    }

    /// `key`: the row's item key (`Self.key(_:)`, profile + stored id).
    func open(_ key: String) {
        guard let session = sessionsByID[key], !busy.contains(key) else { return }
        if paneKeepsSelection, onShowKey == key { return }   // [m9/ipad] already on show beside the list
        openChat(session)
    }

    /// Pushes a session's chat (a row, or the chat a branch made).
    /// `fresh`: a chat just started with Compose or Command-N. In the phone layout it always sits directly on the
    /// list, whatever was open when the key was pressed.
    func openChat(_ session: SessionSummary, fresh: Bool = false) {
        openChat(model: services.chat(for: session), fresh: fresh)
    }

    /// Pushes the chat screen for `model` (a listed chat's, or a new chat's that makes its session as it opens).
    func openChat(model: any ChatSessionModel, fresh: Bool = false) {
        guard let navigation = navigationController, !opening else { return }
        Haptics.play(.soft)
        bringListToFront(navigation, always: fresh)
        let chat = makeChat(model)
        chat.hidesBottomBarWhenPushed = true
        chat.navigationItem.largeTitleDisplayMode = .never
        (chat as? ChatViewController)?.focusesOnAppear = fresh
        opening = true
        // A push whose completion never fires must not leave every later open ignored.
        let token = UUID()
        openingToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.openingToken == token { self?.opening = false }
        }
        ChatViewController.push(chat, on: navigation) { [weak self] in
            if self?.openingToken == token { self?.opening = false }
        }
    }

    private var openingToken = UUID()

    /// [m9/ipad] Phone layout: a chat opened while another tab is on screen (Command-N from Bots, Jobs, …) would be
    /// pushed on this hidden stack and never seen. Sessions comes to the front first, at its list, so the chat
    /// arrives where the Compose button would have put it and one Back returns to Sessions. Two panes: the chat goes
    /// to the right pane whatever tab the left shows, so nothing moves.
    ///
    /// `always`: a chat just started (Compose, Command-N) goes over the list even when Sessions is already the tab
    /// on show with a chat open: each Command-N used to stack one more chat, and Back landed on the previous new
    /// chat instead of on Sessions (stress round 2).
    private func bringListToFront(_ navigation: UINavigationController, always: Bool = false) {
        guard let tabs = navigation.tabBarController, always || tabs.selectedViewController !== navigation,
              (tabs as? MainTabController)?.split?.isDouble != true else { return }
        if navigation.viewControllers.count > 1 { navigation.popToRootViewController(animated: false) }
        if tabs.selectedViewController !== navigation { tabs.selectedViewController = navigation }
    }

    /// A chat push is waiting for its first rows: further taps wait too.
    private var opening = false

    /// A row's identity: its profile and stored id. A cloned profile's chat keeps the stored id of the original
    /// (profile twins, fix161 D18/D22), so the id alone would drop the second row.
    static func key(_ session: SessionSummary) -> String { session.profile + "\u{1F}" + session.id }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        if id == Self.otherAppsKey {
            openOtherApps()
            return
        }
        if let group = Self.groupId(moreKey: id) {
            collectionView.deselectItem(at: indexPath, animated: false)
            toggleShowMore(group)
            return
        }
        guard Self.groupId(newKey: id) == nil else { return }    // [project-cards] its own menu answers the tap
        open(Self.realKey(id))
    }

    /// [project-cards] New Chat is not a row to select: its menu takes the tap.
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath).map { Self.groupId(newKey: $0) == nil } ?? true
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath).map { Self.groupId(newKey: $0) == nil } ?? true
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let item = dataSource.itemIdentifier(for: indexPath),
              Self.groupId(moreKey: item) == nil, Self.groupId(newKey: item) == nil else { return nil }
        let id = Self.realKey(item)
        if let organizer, let session = sessionsByID[item] {
            return busy.contains(id) ? nil : organizer.contextMenu(for: session, key: id)
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [UIAction(title: "Open Chat", image: UIImage(systemName: "bubble.left")) { _ in self?.open(id) }])
        }
    }
}

// MARK: - Row actions, search, filter, peek

extension SessionsViewController {
    /// A row's chat, on the list or on the Other Apps page (whose rows the list folds into one).
    func session(forKey key: String) -> SessionSummary? { sessionsByID[key] ?? otherAppsPage?.session(forKey: key) }

    func cell(forKey key: String) -> UIView? {
        if let page = otherAppsPage, page.view.window != nil, let cell = page.cell(forKey: key) { return cell }
        guard let indexPath = dataSource.indexPath(for: key) ?? dataSource.indexPath(for: Self.copyKey(key)) else { return nil }
        return collectionView.cellForItem(at: indexPath)
    }

    /// Delete on its way: the row dims with a spinner (and takes no taps or swipes) until the gateway answers.
    func setBusy(_ key: String, _ on: Bool) {
        if on { busy.insert(key) } else { busy.remove(key) }
        reload(animated: true)
        otherAppsPage?.setNeedsReload()
    }

    // MARK: Search

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        barCapsule?.updateSearchState()
        guard text != query else { return }
        let wasSearching = searching
        query = text
        searchHits = []
        searchFailed = false
        searchTask?.cancel()
        searchTask = nil
        if !text.isEmpty, let store {
            // The gateway's full-text search, once typing pauses; the loaded rows match at once.
            // [sessions-m9] With a chip picked the hits come from that bot only (§7.4).
            let profiles = pickedBot.map { [$0] } ?? Array(Set(services.bots.map(\.id) + store.sessions.map(\.profile)))
            searchTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                let result = await store.searchReporting(text, profiles: profiles)
                guard !Task.isCancelled, let self, self.query == text else { return }
                self.searchHits = result.hits
                self.searchFailed = result.failed
                self.searchTask = nil
                self.reload(animated: false)
            }
        }
        if wasSearching != searching { collectionView.collectionViewLayout.invalidateLayout() }
        reload(animated: false)
    }

    /// [sessions-m9] The chip changed under a typed query: the gateway is asked again, for that bot.
    private func rerunSearch() {
        guard let controller = navigationItem.searchController, searching else { return }
        query = ""
        updateSearchResults(for: controller)
    }

    /// Fills the search field and searches, as typing would (tests, the debug hooks).
    func search(_ text: String) {
        barCapsule?.openSearch()
        guard let controller = navigationItem.searchController else { return }
        controller.isActive = true
        controller.searchBar.text = text
        updateSearchResults(for: controller)
    }

    /// The loaded rows that match (with the gateway's snippet when it found them too), then its other hits.
    private func searchResults(in listed: [SessionSummary]) -> [SessionSummary] {
        let hits = Dictionary(searchHits.map { (SessionStore.writeKey(id: $0.sessionId, profile: $0.profile), $0) },
                              uniquingKeysWith: { first, _ in first })
        let known = Dictionary(((store?.sessions ?? []) + (store?.archivedSessions ?? []) + listed).map { (SessionStore.writeKey(id: $0.id, profile: $0.profile), $0) },
                               uniquingKeysWith: { first, _ in first })
        func withSnippet(_ session: SessionSummary, _ hit: SessionSearchHit?) -> SessionSummary {
            guard let hit else { return session }
            let snippet = SessionSearch.matchSnippet(hit.snippet, query: query)
            let shown = SessionSearch.plain(snippet)
            var copy = session
            if !shown.isEmpty, shown != session.title, shown != session.preview { copy.searchSnippet = snippet }
            return copy
        }
        let local = listed.filter { session in
            let row = store?.storedRow(session)
            return SessionSearch.matches(session, query: query, cwd: row?.cwd, lineageRoot: row?.lineageRootId)
        }.map { withSnippet($0, hits[SessionStore.writeKey(id: $0.id, profile: $0.profile)]) }
        let server = searchHits.map { hit -> SessionSummary in
            if let loaded = known[SessionStore.writeKey(id: hit.sessionId, profile: hit.profile)] { return withSnippet(loaded, hit) }
            let cleaned = SessionSearch.cleanSnippet(hit.snippet.replacingOccurrences(of: ">>>", with: "").replacingOccurrences(of: "<<<", with: ""))
            let name = SessionSearch.resultName(title: hit.title, firstMessage: hit.firstMessage, source: hit.source)
            let when = (hit.lastActive ?? hit.started).map { Date(timeIntervalSince1970: $0) }
            let made = SessionSummary(id: hit.sessionId, profile: hit.profile, title: name ?? (cleaned.isEmpty ? "Untitled Chat" : cleaned),
                                      preview: nil, lastActive: when, source: hit.source, unread: false, isRunning: false)
            return withSnippet(made, hit)
        }
        return SessionSearch.order(local: local, server: server, id: Self.key)
    }

    // MARK: Filter and Sort [sessions-m9] (docs/spec/3x-sessions.md §5, §6, §7)

    /// The chips' bots: Hermes first, then the Bots list's order; hidden bots left out. Fewer than two: no chips.
    var chipBots: [Bot] {
        let bots = services.bots.filter { !$0.hidden }
        return bots.filter { $0.id == "default" } + bots.filter { $0.id != "default" }
    }

    /// The chip's bot (nil: All).
    var pickedBot: String? { store?.botFilter }

    var rowDetail: Set<SessionRowDetail> { store?.view.shownDetail ?? [.preview, .time] }

    /// [sessions-fresh] Group By Recent: Pinned and Projects say See All, Recent's rows are one line.
    var freshLayout: Bool { store.map { SessionListPipeline.isFresh($0.view) } ?? false }

    /// [backdrop-cards] A project's section: its rows are cards of their own.
    func isProjectSection(_ section: Int) -> Bool {
        !searching && section < groups.count && SessionListPipeline.isProject(groups[section].id)
    }

    func drawsHeader(_ section: Int) -> Bool {
        !searching && section < groups.count && !groups[section].title.isEmpty
    }

    /// Everything the menu, the button and the strip read, now.
    private func filterStateNow() -> SessionFilterState? {
        let bots = chipBots
        return store?.filterState(order: bots.map(\.id), botCount: bots.count)
    }

    /// The bot All Bots ✓ picks when it is turned off: the account's own ("Hermes"), else the first.
    private var homeBot: String {
        let bots = chipBots
        return bots.first { $0.id == "default" }?.id ?? bots.first?.id ?? "default"
    }

    /// The three groups of §5.1, read when the menu opens. The end row (Clear Filters or Mark All as Read) is chosen
    /// here and is not swapped while the menu stays open.
    private func filterMenu() -> [UIMenuElement] {
        guard let store, let state = filterStateNow() else { return [] }
        menuEnd = SessionFilterMenuModel.end(state)
        store.loadProjects()
        return filterElements(state)
    }

    private func filterElements(_ state: SessionFilterState) -> [UIMenuElement] {
        SessionFilterMenu.elements(SessionFilterMenuModel.nodes(state, end: menuEnd)) { [weak self] action, item in
            self?.perform(action, item)
        }
    }

    /// A pick in the menu, the strip's tap, a chip, or the empty state's button.
    func perform(_ action: SessionFilterAction, _ item: UIAction?) {
        guard var state = filterStateNow() else { return }
        switch action {
        case .newProject:
            Haptics.play(.selection)
            organizer?.newProjectFromFilter(profile: pickedBot)
            return
        case .reorderGroups:
            Haptics.play(.selection)
            openGroupOrder(bots: state.prefs.groupBy == .bot)
            return
        case .readAll:
            // Ignored if a filter came on after the menu opened (`filter-apply.ts:77-78`): no tap, no buzz.
            guard !SessionFilterWords.filtersActive(state) else { return }
            Haptics.play(.selection)
            markAllRead()
            return
        default:
            Haptics.play(.selection)
        }
        SessionFilterApply.apply(action, to: &state, homeBot: homeBot)
        apply(state)
        // The tapped row's own check, at once (the redraw below says the rest).
        if let item, item.attributes.contains(.keepsMenuPresented) {
            switch action {
            case .detail(let value): item.state = state.prefs.shownDetail.contains(value) ? .on : .off
            case .status(let value): item.state = state.prefs.statusFilter.contains(value) ? .on : .off
            case .project(let key): item.state = state.prefs.projectFilter.contains(key) ? .on : .off
            case .allBots: item.state = state.botFilter == nil ? .on : .off
            case .runs: item.state = state.showBackgroundRuns ? .on : .off
            case .outside: item.state = state.showOutsideChats ? .on : .off
            case .archived: item.state = state.prefs.showArchived ? .on : .off
            case .botFaces: item.state = state.prefs.botFaces ? .on : .off
            case .projectChatsInRecent: item.state = state.prefs.projectChatsInRecent ? .on : .off
            default: break
            }
        }
    }

    /// New choices: kept by the store, the list redrawn, the button, strip and chips following, and the open menu
    /// (if any) re-said in place.
    private func apply(_ state: SessionFilterState, animated: Bool = true) {
        guard let store else { return }
        let bot = store.botFilter
        store.apply(state)
        if searching, bot != store.botFilter { rerunSearch() }
        reload(animated: animated)
        redrawOpenMenu()
    }

    /// The menu on screen (the root, or the submenu the user is in) with its checks, subtitles and end row as they are
    /// now. Nothing while it is closed.
    private func redrawOpenMenu() {
        barCapsule?.updateFilterMenu { [weak self] current in
            guard let self, let state = self.filterStateNow() else { return current }
            let rebuilt = self.filterElements(state)
            if current.identifier == PageBarCapsule.filterMenuIdentifier { return current.replacingChildren(rebuilt) }
            return SessionFilterMenu.find(current.identifier, in: rebuilt) ?? current
        }
    }

    /// A chip: one bot's chats; the lit chip or All: every bot.
    func pickBot(_ profile: String?) {
        guard var state = filterStateNow(), state.botFilter != profile else { return }
        Haptics.play(.selection)
        state.botFilter = profile
        apply(state)
    }

    /// [sessions-fresh] The New or Working chip; nil turns it off. The bot chip stays.
    func pickStatus(_ chip: SessionStatusChip?) {
        guard let store, store.statusChip != chip else { return }
        Haptics.play(.selection)
        crossfade { store.setStatusChip(chip); self.reload(animated: false) }
    }

    /// [sessions-fresh] All: every bot, and no status chip.
    func pickAll() {
        guard let store, store.statusChip != nil || store.botFilter != nil else { return }
        Haptics.play(.selection)
        guard store.statusChip != nil else {
            if var state = filterStateNow() { state.botFilter = nil; apply(state) }
            return
        }
        crossfade {
            store.statusChip = nil
            if var state = self.filterStateNow(), state.botFilter != nil {
                state.botFilter = nil
                self.apply(state, animated: false)
            } else {
                self.reload(animated: false)
            }
        }
    }

    /// [sessions-fresh] A status chip swaps the sections for one flat run (and back): a quick fade, not rows flying
    /// between sections. A picture of the old list fades over the new one (a transition on the list itself was cut short
    /// by the redraw New's full read brings). None with Reduce Motion.
    private func crossfade(_ change: () -> Void) {
        guard view.window != nil, !HQMotion.reduced, let old = collectionView.snapshotView(afterScreenUpdates: false) else {
            change(); return
        }
        old.frame = collectionView.frame
        old.isUserInteractionEnabled = false
        collectionView.superview?.insertSubview(old, aboveSubview: collectionView)
        change()
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {   // motion-ok: a fade
            old.alpha = 0
        } completion: { _ in
            old.removeFromSuperview()
        }
    }

    func setShowArchived(_ on: Bool) {
        guard on != showArchived, var state = filterStateNow() else { return }
        state.prefs.showArchived = on
        apply(state)
    }

    /// The button fills and counts the Filter menu's filters; the strip names them; the chips show the roster and the
    /// pick. A chip whose bot left the roster (or was hidden) is no longer picked.
    private func refreshChrome() {
        guard let store else { return }
        let bots = chipBots
        if let picked = store.botFilter, !bots.contains(where: { $0.id == picked }) { store.setBotFilter(nil) }
        let state = store.filterState(order: bots.map(\.id), botCount: bots.count)
        barCapsule?.setFilterActive(SessionFilterWords.filterCount(state) > 0, token: SessionFilterWords.token(state),
                                    label: SessionFilterWords.buttonLabel(state))
        // [perf] The header is measured again only when what it draws changed, not on every roster tick.
        var headerChanged = false
        // [mac-audit] Owner 2026-11-02 (#20): on the Mac the header draws these as an "All Bots ⌄" pop-up, not a rail.
        let chips = SessionChipBot.chips(from: bots)
        if headerModel.bots != chips { headerModel.bots = chips; headerChanged = true }
        if headerModel.picked != state.botFilter { headerModel.picked = state.botFilter; headerChanged = true }
        // [sessions-fresh] New and Working after All, with their counts under the bot chip.
        let counts = store.chipCounts
        if headerModel.statusChips != counts { headerModel.statusChips = counts; headerChanged = true }
        if headerModel.status != store.statusChip { headerModel.status = store.statusChip; headerChanged = true }
        // UX study 2026-10-19 #36: the field names what it searches: every bot's chats, or the picked chip's bot's.
        let placeholder = SessionsSearchWords.placeholder(botName: state.botFilter.flatMap { id in bots.first { $0.id == id }?.name })
        if let bar = navigationItem.searchController?.searchBar, bar.placeholder != placeholder {
            bar.placeholder = placeholder
            DesktopSearch.fitPlaceholder(bar)   // [mac-audit] its readable ink again
        }
        // The Filter menu's filters do not apply to search hits, so the strip waits for the query to clear (§7.4).
        let strip = searching ? nil : SessionFilterWords.stripText(state)
        if headerModel.strip != strip { headerModel.strip = strip; headerChanged = true }
        if headerChanged { view.setNeedsLayout() }
    }

    /// Mark All as Read (§5.6): both unread sources of every listed chat, and (as the web does) every bot's own chat.
    /// `failed`: Try Again, for just the chats whose write failed.
    private func markAllRead(only failed: [SessionWriteFailure]? = nil) {
        guard let store else { return }
        if failed == nil { (services as? SessionsBotReads)?.markAllBotChatsRead() }
        Task { [weak self] in
            let failures = await store.markAllRead(only: failed)
            guard let self else { return }
            self.reload(animated: true)
            guard !failures.isEmpty else { return }
            FailureAlert.present(title: "Couldn’t Mark All as Read", reason: SessionWriteFailure.alertReason(failures), from: self) { [weak self] in
                self?.markAllRead(only: failures)
            }
        }
    }

    /// [sessions-m9] The empty state ("No Matching Chats", "No Chats Yet", Loading…, "Couldn’t Load Chats", a search
    /// miss) is the list's own background, not the page's `contentUnavailableConfiguration`: UIKit
    /// lays that one over the whole page in a wrapper it keeps in front of every subview, where it took every touch (and VoiceOver's
    /// finger) meant for the chips and the strip (stress round 1). As the list's background it sits behind the fixed
    /// header, centred in the safe area the header leaves, and the list can still be pulled to refresh.
    private func showEmptyState(_ emptyState: (any UIContentConfiguration)?) {
        let emptyState = BackdropState.wrap(emptyState)   // [backdrop-cards] a soft card behind it on Soft Cards
        let wasEmpty = paneListIsEmpty
        // UX study #89: the iPad placeholder beside the list drops "Choose an item" while the list is empty.
        defer { if paneListIsEmpty != wasEmpty { NotificationCenter.default.post(name: DetailPlaceholderViewController.listStateChanged, object: self) } }
        guard let emptyState else {
            if collectionView.backgroundView != nil { collectionView.backgroundView = nil }
            return
        }
        // The same kind of state again keeps its view (a button in it is not swapped out under a finger).
        if var shown = collectionView.backgroundView as? (any UIView & UIContentView), shown.supports(emptyState) {
            shown.configuration = emptyState
        } else {
            collectionView.backgroundView = emptyState.makeContentView()
        }
    }

    // MARK: The fixed header [sessions-m9] (§7.2)

    private func installHeader() {
        guard store != nil else { return }
        headerModel.onPick = { [weak self] profile in self?.pickBot(profile) }
        headerModel.onPickStatus = { [weak self] chip in self?.pickStatus(chip) }
        headerModel.onPickAll = { [weak self] in self?.pickAll() }
        headerModel.onClearStrip = { [weak self] in
            guard let self, var state = self.filterStateNow() else { return }
            Haptics.play(.selection)
            SessionFilterApply.clearStrip(&state)
            self.apply(state)
        }
        let host = UIHostingController(rootView: SessionsHeaderView(model: headerModel))
        host.safeAreaRegions = []                // it sits above the safe area it makes room in
        // Clear over the soft edge in the iOS look; the Desktop Look's band is opaque edge to edge (`layoutHeader`).
        host.view.backgroundColor = Theme.isDesktop ? HQPalette.page : .clear
        pageBackdrop?.clear(host.view)                   // [backdrop] the picture's band is behind it then
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        // [top-edge] The chips are part of the top edge: the hard band (Theme › Themes › Top Edge) stopped at the bar
        // and left rows sharp between it and the chips.
        if let edgeHost = collectionView.superview as? UIScrollView {
            let edge = UIScrollEdgeElementContainerInteraction()
            edge.scrollView = edgeHost
            edge.edge = .top
            host.view.addInteraction(edge)
        }
        let height = host.view.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            height,
        ])
        host.didMove(toParent: self)
        host.view.clipsToBounds = true
        headerHost = host
        headerHeight = height
    }

    /// The list starts under the header: the page's safe area grows by the header's height (re-applied only when it
    /// changes by more than half a point). While the header shows, the hairline is the header's, not the bar's.
    private func layoutHeader() {
        guard let headerHost, let headerHeight, view.bounds.width > 0 else { return }
        let fitted = headerModel.isEmpty ? 0 : headerHost.sizeThatFits(in: CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude)).height
        // To the pixel, not the point: a band a fraction taller than its content left a one-pixel line of the list
        // showing above the chips.
        let scale = max(view.window?.screen.scale ?? traitCollection.displayScale, 1)
        let height = fitted.isFinite ? max(0, (fitted * scale).rounded(.up) / scale) : 0
        // Owner 2026-11-01: in the iOS look the chips sit over the list's soft edge as the title does (the edge reaches
        // under them); the Desktop Look keeps the band opaque under its bar.
        let band = Theme.isDesktop ? HQPalette.page : UIColor.clear
        if headerHost.view.backgroundColor != band { headerHost.view.backgroundColor = band }
        guard abs(additionalSafeAreaInsets.top - height) > 0.5 else { return }
        let animated = view.window != nil && !HQMotion.reduced && headerLaidOut
        headerLaidOut = true
        let change = {
            headerHeight.constant = height
            self.additionalSafeAreaInsets.top = height
        }
        if animated {
            UIView.animate(withDuration: 0.2) {   // motion-ok: `animated` above is false under Reduce Motion
                change()
                self.view.layoutIfNeeded()
            }
        } else {
            change()
        }
        guard Theme.isDesktop else { return }   // the iOS look's bar is clear in every state (`pinTitle(softEdgeAround:)`)
        guard !ListBarAppearance.showsPictureBand(navigationItem) else { return }   // [backdrop] the bar is clear over the picture
        let scrolled = UINavigationBarAppearance()
        scrolled.configureWithOpaqueBackground()
        scrolled.backgroundColor = HQPalette.page
        scrolled.shadowColor = height > 0 || Theme.isDesktop ? .clear : HQPalette.separator   // [desktoplook2] no rule
        navigationItem.standardAppearance = scrolled
        navigationItem.compactAppearance = scrolled
    }

    // MARK: Swipe peek

    /// A moment after the first list with rows shows, its first row slides 60 pt to show there are actions behind it,
    /// and back, once per install (not under Reduce Motion or VoiceOver). The Bots list peeks with the same code
    /// (`App/Kit/SwipePeek.swift`).
    private func schedulePeek() {
        guard organizer != nil else { return }
        swipePeek.schedule(in: self, collectionView: collectionView, ready: { [weak self] in
            guard let self else { return false }
            return !self.searching
        }, rows: { [weak self] in
            guard let self else { return [] }
            return self.collectionView.indexPathsForVisibleItems.sorted().compactMap { self.collectionView.cellForItem(at: $0) as? UICollectionViewListCell }
        })
    }
}

// UX study #89: the empty state is the list's background, not `contentUnavailableConfiguration`.
extension SessionsViewController: PaneListEmptiness {
    var paneListIsEmpty: Bool { isViewLoaded && collectionView?.backgroundView != nil }
}

/// [project-unfold] A display link's target that doesn't keep the list alive (CADisplayLink holds its target).
private final class UnfoldTick: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func tick() { action() }
}
