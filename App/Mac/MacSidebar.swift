// [mac] The Mac's tabs as a sidebar down the window's leading edge, the way Mail, Music and System Settings list
// their places (owner 2026-10-25: the bottom capsule was "a crowded row of overlapping touch-style pills"; after build
// 195 they turned down a bar floating over the list, so nothing here covers content). One row per tab of the tab
// controller: its symbol, its name and its count, the selected one marked, a faint fill under the pointer. ⌘1…⌘9 pick
// the same tabs (View menu). The iPhone and iPad keep the system tab bar.
// [mac-sidebar] Owner 2026-10-31: "you should be able to add more options to the sidebar". It holds every main tab and
// every More page the person adds, no cap of four (`TabOrder.sidebarLimit`), and scrolls when they outgrow the window.
// Edited where it is, the Mac way (`SidebarEditing`): a right click on a row moves it up or down or removes it, a
// right click anywhere (or the + at its foot) adds a page, a row drags to a new place, and More's rows add themselves.
// Owner 2026-10-28: "make the left bar collapsable". It folds to its icons (each names itself under the pointer) with
// the button at its foot or View › Hide Sidebar (⌃⌘S, as in Mail), and stays folded across launches. Not hidden
// outright: the window's close, minimise and zoom buttons sit over its top corner and would land on the list's title.

import UIKit

#if targetEnvironment(macCatalyst)
final class MacSidebar: UIView {
    /// In the iPad points the Mac draws at 77 %: 228 at 100 % is about 176 pt on the screen, Mail's sidebar. It grows
    /// with UI Scale (the Mac's text size), less than the text does: the names are short.
    static var width: CGFloat { isCollapsed ? (railDragWidth ?? railWidth) : openWidth }
    /// [sidebar-width] Owner 2026-11-09: "some way to expand that left side menu … give it more room to breathe" (a
    /// chat under a bot showed two words). The open sidebar's edge drags between `narrowestOpen` and `widestOpen`; the
    /// width is kept across launches (in points at 100 %, so UI Scale still grows it), and a window too narrow for it
    /// squeezes it back toward `narrowestOpen` before anything folds.
    static var openWidth: CGFloat {
        let wanted = openDragWidth ?? (savedOpenWidth * chrome).rounded()
        let room = windowWidth > 0 ? windowWidth - PaneLayout.minWidth : .greatestFiniteMagnitude
        return max(narrowestOpen, min(wanted, widestOpen, room))
    }
    static var narrowestOpen: CGFloat { (160 + 88 * chrome).rounded() }   // [mac-layout] room for a bot's name and its step
    static var widestOpen: CGFloat { (520 * chrome).rounded() }
    static let openWidthKey = "HQMacSidebarOpenWidth"
    /// At 100 %: 300 is about 231 pt on the screen (Mail's and Finder's sidebars open near there).
    static let defaultOpenWidth: CGFloat = 300
    static var savedOpenWidth: CGFloat {
        get { let saved = UserDefaults.standard.double(forKey: openWidthKey); return saved > 0 ? CGFloat(saved) : defaultOpenWidth }
        set { UserDefaults.standard.set(Double(newValue), forKey: openWidthKey) }
    }
    /// The open sidebar's width while its edge is dragged (nil otherwise).
    private(set) static var openDragWidth: CGFloat?
    /// The window's width at the last layout pass (0 before the first).
    private static var windowWidth: CGFloat = 0
    /// [mac] Stress test 2026-10-28 #64: the sidebar's own scale, the UI Scale percent alone. Through `HQFont.scale` it
    /// took each look's Mac base too (× 1.3 / × 1.15), so it was 248 pt wide in one look and 238 in the other, with
    /// 59 pt rows and ~20 pt names where a Mac sidebar has 28–32 pt rows and 13 pt names. Now both looks match.
    static var chrome: CGFloat { CGFloat(ThemeTable.current.state.uiScalePercent) / 100 }
    /// The sidebar's sizes in its own scale (`HQFont.system` multiplies by the look's scale, divided back out here),
    /// never under the Mac's smallest text (Mac polish #54: at 90 % the group headings, a bot's step, the gateway's
    /// name and the ⌘K hint came out at 9 to 9.4 pt on the screen). `legible` false: a mark drawn as text (a news dot).
    static func font(_ size: CGFloat, weight: UIFont.Weight = .regular, legible: Bool = true) -> UIFont {
        let points = legible ? HQFont.legible(size * chrome) : size * chrome
        return HQFont.system(ofSize: points / max(HQFont.scale, 0.01), weight: weight)
    }
    /// How far a name in `font` may shrink to fit (`minimumScaleFactor`): `least`, but never under the Mac's smallest
    /// text (Mac polish #54: the named rail's longer names came to about 9.5 pt on the screen).
    static func shrink(_ font: UIFont, least: CGFloat) -> CGFloat {
        SidebarRules.shrink(pointSize: font.pointSize, least: least, smallest: HQFont.macSmallest)
    }
    /// Folded, the icons alone: never narrower than the window's three buttons over its top corner (about 70 pt on the
    /// screen, 92 here).
    /// [bots-rail] Room for a bot's head (`MacBotsRail.face`) and its selection box inside the glass panel too.
    static var railWidth: CGFloat { railNamed ? namedRailWidth : compactRailWidth }
    /// [rail-names] Owner 2026-11-02: "some more room on the side ... to fit in the name of each bot underneath", the
    /// rail's edge dragged with the pointer: pushed in, the faces alone (`compactRailWidth`); pulled out a little, it
    /// locks at a width with each name under its face and the places at its foot two across with their names
    /// (`namedRailWidth`). No third width: the sidebar's button still opens the whole sidebar and list.
    static var compactRailWidth: CGFloat { max(92, (2 * contentInset + 56 * chrome).rounded()) }
    static var namedRailWidth: CGFloat { max(136, (2 * contentInset + 116 * chrome).rounded()) }
    static let railNamedKey = "HQMacRailNamed"
    static var railNamed: Bool {
        get { UserDefaults.standard.bool(forKey: railNamedKey) }
        set { UserDefaults.standard.set(newValue, forKey: railNamedKey) }
    }
    /// [rail-names] The rail's width while its edge is dragged (nil otherwise): it follows the pointer, then settles.
    private(set) static var railDragWidth: CGFloat?
    static let collapsedKey = "HQMacSidebarCollapsed"
    /// Folded by the person (kept across launches), or by a narrow window (below).
    static var isCollapsed: Bool { savedCollapsed || (narrowWindow && !openedWhileNarrow) }
    private static var savedCollapsed: Bool { UserDefaults.standard.bool(forKey: collapsedKey) }
    /// [mac] Stress test 2026-10-28 #13: a window too narrow for the open sidebar and two panes folds it to its icons by
    /// itself, as Mail and Finder do, and opens it again once wider; nothing is saved. The button or ⌃⌘S still opens it
    /// meanwhile (`openedWhileNarrow`, until the window is wide again).
    private(set) static var narrowWindow = false
    private static var openedWhileNarrow = false

    /// The window's width changed (RootSplitController's layout pass); true when that folds or opens the sidebar.
    static func windowWidthChanged(_ width: CGFloat) -> Bool {
        let was = isCollapsed
        windowWidth = width
        let narrow = width > 0 && width < narrowestOpen + PaneLayout.minWidth
        if narrow != narrowWindow {
            narrowWindow = narrow
            if !narrow { openedWhileNarrow = false }
        }
        return was != isCollapsed
    }
    /// 36 pt rows at 100 % (28 on the screen, Finder's and Notes'), names 17 pt (13 on the screen). [mac] Stress test #64.
    /// [sidebar-tidy] Owner 2026-11-10 liked the tidied sidebar (shorter rows): 40 → 36, and Theme › Density › Compact
    /// reaches the places and Tools too (32, the bots' compact rows): it had stopped at the bots, so in Compact the
    /// bots' rows were 32 and every row under them 40.
    /// [sidebar-feel] 37, not 36: with the 2 pt between rows a row takes 39 pt, a whole 30 px on the screen (the Mac
    /// draws this app at 77 %). At 38 pt the rows fell 29.26 px apart, so each row's icon and name landed on a
    /// different part of a pixel: names 12 px tall in one row and 13 in the next, gaps of 29, 30 and 30.5.
    static var openRowHeight: CGFloat { ((Density.compact ? 32 : tidy ? 37 : 40) * chrome).rounded() }
    /// [sidebar-size] Owner 2026-11-10 ("just get it all sized properly"): one of the sidebar's sizes, `was` before
    /// and `now`. The pages beside it and the Settings window's own sidebar draw their text at 15 pt on the screen;
    /// here the places' names were 13, the group headings 10.4 and Search 12. Now the places' and New Bot's names are
    /// 15 (as the bots'), the headings 11 (macOS's own sidebar headings), Search 13, and no word is under 11.
    static func sized(_ was: CGFloat, _ now: CGFloat) -> CGFloat { tidy ? now : was }
    /// The places' names: 19.5 here is 15 pt on the screen (Compact a step under, as the bots').
    static var placeSize: CGFloat { sized(17, Density.compact ? 18 : 19.5) }
    /// For before-and-after pictures: `-HQDebugSidebarTidy NO` draws the rows as they were (Debug builds only).
    static var tidy: Bool {
        #if DEBUG
        if UserDefaults.standard.object(forKey: "HQDebugSidebarTidy") != nil { return UserDefaults.standard.bool(forKey: "HQDebugSidebarTidy") }
        #endif
        return true
    }
    static var rowHeight: CGFloat { isCollapsed ? (48 * chrome).rounded() : openRowHeight }
    /// [rail-names] A place at the named rail's foot: its icon with its name under it.
    static var namedRowHeight: CGFloat { (62 * chrome).rounded() }
    /// The tab icons: 16 pt beside their names (Mail's). [mac] Owner 2026-10-29 on 452: "when the sidebar is minimized,
    /// the icons are too small": folded, the icon is all the row has, so it is drawn at the size of the bars' own
    /// buttons (22 pt) in a taller row.
    static func iconSize(folded: Bool) -> CGFloat { (folded ? 22 : sized(16, 18)) * chrome }   // [sidebar-size] beside 15 pt names
    /// [mac] Mac polish #53: the open sidebar's icon column and where its names start after it, which the bots' rows
    /// share (`MacRailHead`): the bots' names started about 4 pt further in than the places' below them.
    static let iconLeading: CGFloat = 10
    static var iconColumn: CGFloat { (iconSize(folded: false) * 1.5).rounded() }
    static var labelLeading: CGFloat { iconLeading + iconColumn + 10 }
    /// [sidebar-feel] Owner 2026-11-13: the sidebar "feels off … I can't put my finger on it". Measured on the screen,
    /// its left edges nearly lined up and didn't: faces at 13 px, group headings at 15, the places' icons at 16 to 19,
    /// New Bot's + at 20; names at 47 (bots) and 44 (places, New Bot). Now there are four lines and everything sits on
    /// one: the rows' own edge (Search, a row's mark), `contentLeading` (the faces' left edge: headings, the foot's
    /// line, an empty section's hint), the icon column's centre (faces, icons, New Bot's +) and the name column
    /// (`MacBotsRail.nameLeading`). At the trailing end, chevrons, counts and "Working…" end `edgeInset` in.
    static var contentLeading: CGFloat { iconLeading + iconColumn / 2 - MacBotsRail.rowFace / 2 }
    static let edgeInset: CGFloat = 10
    /// The nearest half point, the finest step UIKit lays out on here.
    static func half(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }
    /// The faint fill under the pointer, on every row of the sidebar.
    static let rowHover = UIColor { traits in UIColor.label.resolvedColor(with: traits).withAlphaComponent(0.05) }
    /// [sidebar-feel] How long the sidebar's own moves take: a group's rows closing up, Tools folding, the list
    /// scrolling to the open row. They all snapped.
    static let glide: TimeInterval = 0.22
    static var headingHeight: CGFloat { (30 * chrome).rounded() }
    /// 5 px on the screen (the Mac draws this app at 77 %): rows whose tops are a whole number of these apart are
    /// drawn exactly alike. A place row and its gap take six (39 pt, 30 px), a bot row seven (45.5 pt, 35 px).
    static let gridStep: CGFloat = 6.5
    /// [sidebar-feel] The gap over a group's heading: the least that puts the heading and the gap under it on whole
    /// steps (2.5 pt), so the rows after a heading are drawn as the rows before it. It was 2 over a group of bots
    /// and 10 over Tools, so from a group's last row to the next heading measured 31, 32 or 35 px down the one
    /// sidebar; now every heading sits the same way, and the room Tools gives up pays for the place rows' extra
    /// point each (`openRowHeight`): the sidebar is no taller than it was.
    /// [sidebar-intent] And one step more (5 px): a heading sat as far from the group above it as two rows sit from
    /// each other, so "Tools" read as one more row of the places, not as the name of what follows.
    static var aboveHeading: CGFloat { ((headingHeight + 2) / gridStep).rounded(.up) * gridStep - headingHeight + sectionBreak }
    /// [sidebar-intent] Owner 2026-11-13: "make it all feel more intentional". What a break between two parts of the
    /// sidebar adds over the gap between two rows, the same everywhere: over a group's heading, and over the bar at
    /// the foot (the gateway's name sat a row's pitch under the last Tool, as if it were one).
    static let sectionBreak: CGFloat = gridStep

    /// [icon-study] Owner 2026-11-03: "between the sessions icon, the jobs icon, and the Kanban, they don't feel like they're
    /// sized properly". Measured drawn alone (`-HQDebugIconInk`), folded at 22 pt: Sessions' two bubbles filled 31 × 25 of
    /// the 33 pt box (the most of any place), the drawn Kanban 25.6 × 25.6 at a 1.9 pt line (SF Symbols' regular line is
    /// about 1.5 there) and Bots the same line. So Sessions is drawn at 88 %, Kanban and Tiles (31 pt wide) at 90 %, and both drawn glyphs at
    /// SF's line, which puts every place's ink box within about 6 % of Jobs' and Artifacts' (`docs/mac.md`).
    static func rowIcon(_ image: UIImage?, folded: Bool) -> (image: UIImage?, pointSize: CGFloat) {
        let size = iconSize(folded: folded)
        if image === TabIcons.kanban { return (TabIcons.kanban(pointSize: size * 0.9, line: 0.07), size) }
        if image === TabIcons.bot { return (TabIcons.bot(pointSize: size, line: 0.07), size) }
        let drawn = TabIcons.redrawn(image, pointSize: size) ?? image
        let scale = TabIcons.symbolName(of: drawn).flatMap { opticalScale[$0] } ?? 1
        return (drawn, size * scale)
    }
    private static let opticalScale: [String: CGFloat] = ["bubble.left.and.bubble.right": 0.88, "rectangle.3.group": 0.9]
    static let inset: CGFloat = 10
    /// Clear of the window's close, minimise and zoom buttons, which sit over the top-left corner.
    static let topRoom: CGFloat = 60
    /// [rail-top] Search and New Chat start `topRoom` down from the sidebar's own top, not its safe area: the Mac's safe
    /// area starts 41 pt down (the window's title strip), which left an empty dark band above the top head (owner
    /// 2026-11-03: "there is black bar that prevents it"). [Mac UI check 2026-11-13] They no longer scroll: the rows'
    /// list starts under them (`toolsTop`).

    private weak var tabs: MainTabController?
    /// [mac-sidebar] The rows scroll once there are more than the window's height holds.
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var rows: [Row] = []
    /// [bots-rail] The bots' heads fill the scrolling part (`stack`); the places and Tools sit at the foot (owner 2026-11-04).
    private let foot = UIStackView()
    /// Mac polish #5: the foot in a list of its own, whole while the window has room for it and the bots' least
    /// (`botsMinHeight`), scrolling in a short window: there the bots and Search shrank to nothing and the foot's last
    /// rows were drawn over each other.
    private let footScroll = UIScrollView()
    private var botsRoom: NSLayoutConstraint!
    /// The foot's line, fixed between the two lists: the foot's rows scroll under it, not the line with them (a
    /// sliver of Sessions showed under New Bot with no line once the foot had scrolled).
    private let footEdge = UIView()
    private var footEdgeHeight: NSLayoutConstraint!
    private var footBottom: NSLayoutConstraint!
    private var heads: [String: MacRailHead] = [:]
    /// [chats-under] The chats under the bot rows (and their "N more"), by bot id + U+001F + session id (or "more").
    private var chatRows: [String: MacSidebarChat] = [:]
    private var chatsToken: [NSObjectProtocol] = []
    private var railAdd: MacRailAdd?
    /// [mac-layout] The bots, under the places in both widths (owner 2026-11-03 "I like the bots in the sidebar"): heads
    /// on the rail, rows with names and group headings open. Its own stack, so a roster change redraws only it.
    private let botsStack = UIStackView()
    private var botsSignature = ""
    /// [sidebar-feel] The groups' headings by their fold key, kept between roster changes as the heads are: a click
    /// turns the heading's own chevron, and the rows under it glide from where they were.
    private var headings: [String: MacSidebarHeading] = [:]
    private weak var toolsHeading: MacSidebarHeading?
    /// When the sidebar came on show: its lists glide to a row only once it has been up a moment (`glidesScroll`).
    private var shownAt: CFTimeInterval = .greatestFiniteMagnitude
    private var tools: MacSidebarTools?
    /// The head whose chat is on show beside the rail, by `MacBotsRail.Item.key` (`MainTabController.paneSelectionChanged`).
    private var openHead: String?
    /// [rail-more] The gateway switcher at the rail's top (more than one gateway), and its watch on the gateways.
    private var railGateway: MacRailGateway?
    private var gatewayWatch: (token: UUID, gateways: any GatewayAccounts)?
    /// Where Search and New Chat sit: `topRoom` down, or under the rail's gateway switcher (`placeRailGateway`).
    private var toolsTop: NSLayoutConstraint?
    private var badgeWatch: [NSKeyValueObservation] = []
    /// [sidebar-light] The watch on the panes beside the strip (`neighbourMayChange`).
    private var neighbourToken: NSObjectProtocol?
    private var sceneTokens: [NSObjectProtocol] = []
    private var neighbourPending = false
    /// Tries left to read the page beside the strip before the window has drawn (`followNeighbour`).
    private var neighbourRetries = 0
    private var themeToken: NSObjectProtocol?
    private let edge = UIView()
    /// [glass-mac] Owner 2026-10-30 "more Liquid Glass": in the iOS look the sidebar is a glass panel floating inside its
    /// strip, a hair off the window's edges, as macOS 26's sidebars float (Mail, Finder). The rows sit on it; nothing
    /// covers the list. The Desktop Look keeps its solid raised panel (`ChatPalette.sidebar`) and no glass.
    private let glass = UIVisualEffectView()
    /// [sidebar-light] The tint the glass was made with (resolved), so a theme or appearance change makes it again.
    private var glassTint: UIColor?
    private var stackLeading: NSLayoutConstraint!
    private var stackTrailing: NSLayoutConstraint!
    private var toggleBottom: NSLayoutConstraint!
    /// The glass panel's gap from the window's edges and its corners (about 8 and 17 pt on the screen at 77 %).
    static let glassInset: CGFloat = 10
    /// The glass panel's top: under the window's close, minimise and zoom buttons (about 12 to 30 pt down, so 10 below them
    /// as at the sides), not round them. Owner 2026-11-03: the buttons "sit almost inside that little bubble".
    static let glassTop: CGFloat = 40
    static let glassRadius: CGFloat = 22
    /// [sidebar-solid] Owner 2026-11-09: the strip round the floating glass panel took the colour of the page beside it,
    /// so it was often a different colour from everything else ("let's just do it where it's a solid color for that
    /// entire section … keep it simple"). The whole strip is now one solid colour in the iOS look too (the glass panel's
    /// tint made solid, `panelColor`), with the Desktop Look's hairline at its edge. True brings the floating panel back.
    static let floats = false
    /// The strip is one solid panel: the Desktop Look, or the iOS look while the panel doesn't float.
    static var solid: Bool { Theme.isDesktop || !floats }
    /// The rows' and the toggle's gap from the strip's edges: inside the glass panel while it floats.
    static var contentInset: CGFloat { solid ? inset : inset + glassInset }
    private let toggle = UIButton(type: .system)
    /// [mac-sidebar] The foot's +: Add to Sidebar ▸ and Sidebar Settings…, the menu a right click on the sidebar gives.
    private let addButton = UIButton(type: .system)
    private var addTrailing: NSLayoutConstraint!
    private var addSize: [NSLayoutConstraint] = []
    /// The foot's gear: Settings in its window (⌘,). Owner 2026-11-07: "I don't see where I can access More or Settings":
    /// with More dissolved on the Mac (its setup pages are in the Settings window), only the menu bar opened it. Beside
    /// the + open; above the toggle folded.
    private let settingsButton = UIButton(type: .system)
    /// [sidebar-tidy] Owner 2026-11-10 (the tidied mockup): the foot says where the app is connected, a state dot and
    /// the gateway's name between the sidebar button and the gear (open only; the rail has no room for words).
    private let gatewayDot = UIView()
    private let gatewayName = UILabel()
    private let gatewayTip = UIToolTipInteraction()
    private var gatewayLeading: NSLayoutConstraint!
    static let connectionChanged = Notification.Name("HQMacSidebarConnectionChanged")
    private var connectionToken: NSObjectProtocol?
    private var settingsSize: [NSLayoutConstraint] = []
    private var settingsBesideAdd: [NSLayoutConstraint] = []
    private var settingsAboveToggle: [NSLayoutConstraint] = []
    private var footAboveToggle: NSLayoutConstraint!
    private var footAboveSettings: NSLayoutConstraint!
    /// [mac-sidebar] Where a dragged row would land.
    private let dropLine = UIView()
    private var toggleLeading: NSLayoutConstraint!
    private var toggleCentre: NSLayoutConstraint!
    /// The trailing edge line's width: one pixel of the display the window is on now.
    private var edgeWidth: NSLayoutConstraint!
    private var toggleSize: [NSLayoutConstraint] = []
    /// [rail-names] The folded rail's edge: dragged, it widens to show the names or narrows to the faces alone.
    private let railGrip = UIView()
    private var railDragStart: CGFloat = 0
    /// Owner 2026-11-04 (the folded sidebar): the rows ran into the sidebar button, the last bot cut off on its edge. A
    /// gap above the button, and while more rows lie below, the list fades out into it instead of stopping on a hard line.
    private let fade = CAGradientLayer()
    private let footFade = CAGradientLayer()   // Mac polish #5: the foot's list, when it scrolls
    private static let fadeHeight = SidebarRules.fadeHeight
    private var scrollWatch: [NSKeyValueObservation] = []

    init(tabs: MainTabController) {
        self.tabs = tabs
        super.init(frame: .zero)
        accessibilityIdentifier = "mac-sidebar"
        accessibilityTraits = .tabBar
        accessibilityContainerType = .semanticGroup
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        // Owner 2026-11-03: the scroll bar ran through the open bot's selection box ("We cannot have UI elements
        // overlap like that"). The rows still scroll with the wheel or trackpad, and the open one scrolls into view.
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.contentInsetAdjustmentBehavior = .never
        // [rail-top] No scroll edge effect: on the Mac's dark glass its fade read as a black band over the top row.
        scroll.topEdgeEffect.isHidden = true
        scroll.bottomEdgeEffect.isHidden = true
        scroll.delaysContentTouches = false   // a click marks its row at once, as before the rows could scroll
        scroll.backgroundColor = .clear
        scroll.accessibilityIdentifier = "mac-sidebar.rows"
        scroll.addSubview(stack)
        scroll.contentInset.bottom = 6
        scrollWatch = [scroll, footScroll].flatMap { list in [
            list.observe(\.contentOffset, options: []) { [weak self] _, _ in MainActor.assumeIsolated { self?.placeFade() } },
            list.observe(\.contentSize, options: []) { [weak self] _, _ in MainActor.assumeIsolated { self?.placeFade() } },
        ] }
        botsStack.axis = .vertical
        botsStack.spacing = 2
        botsStack.accessibilityIdentifier = "mac-sidebar.bots"
        foot.axis = .vertical
        foot.spacing = 2
        foot.translatesAutoresizingMaskIntoConstraints = false
        foot.accessibilityIdentifier = "mac-sidebar.foot"
        footScroll.translatesAutoresizingMaskIntoConstraints = false
        footScroll.showsVerticalScrollIndicator = false   // as the bots' list: no bar through the rows' marks
        footScroll.showsHorizontalScrollIndicator = false
        footScroll.alwaysBounceVertical = false
        footScroll.contentInsetAdjustmentBehavior = .never
        footScroll.topEdgeEffect.isHidden = true
        footScroll.bottomEdgeEffect.isHidden = true
        footScroll.delaysContentTouches = false
        footScroll.backgroundColor = .clear
        footScroll.accessibilityIdentifier = "mac-sidebar.foot-rows"
        footScroll.addSubview(foot)
        dropLine.isHidden = true
        dropLine.isUserInteractionEnabled = false
        scroll.addSubview(dropLine)
        glass.isUserInteractionEnabled = false
        glass.cornerConfiguration = .corners(radius: .fixed(Self.glassRadius))
        DesktopLayout.keepOwnLook(glass)   // the look's solid panel is this view's own colour, not ThemeChrome's editor box
        addSubview(glass)
        addSubview(scroll)
        addSubview(footScroll)
        footEdge.translatesAutoresizingMaskIntoConstraints = false
        footEdge.isUserInteractionEnabled = false
        footEdge.clipsToBounds = true
        addSubview(footEdge)
        edge.isUserInteractionEnabled = false
        edge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(edge)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.isPointerInteractionEnabled = true
        // [sidebar-feel] The foot's three buttons showed nothing under the pointer: their own pointer interaction
        // (which draws nothing on the Mac) kept the app's hover off them (`PointerEffects.button`).
        MacHover.button(toggle)
        toggle.accessibilityIdentifier = "mac-sidebar.toggle"
        toggle.addAction(UIAction { [weak self] _ in self?.toggleCollapsed() }, for: .touchUpInside)
        addSubview(toggle)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.isPointerInteractionEnabled = true
        MacHover.button(addButton)
        addButton.accessibilityIdentifier = "mac-sidebar.add"
        addButton.accessibilityLabel = "Add to Sidebar"
        addButton.toolTip = "Add to Sidebar"
        addButton.showsMenuAsPrimaryAction = true
        addButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { done in done(SidebarEditing.spaceMenu().children) }])
        addSubview(addButton)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.isPointerInteractionEnabled = true
        MacHover.button(settingsButton)
        settingsButton.accessibilityIdentifier = "mac-sidebar.settings"
        settingsButton.accessibilityLabel = "Settings"
        settingsButton.toolTip = "Settings (⌘,)"
        settingsButton.addAction(UIAction { _ in MacSettingsWindow.open() }, for: .touchUpInside)
        addSubview(settingsButton)
        gatewayDot.translatesAutoresizingMaskIntoConstraints = false
        gatewayDot.isUserInteractionEnabled = false
        gatewayDot.layer.cornerRadius = 3.5
        gatewayName.translatesAutoresizingMaskIntoConstraints = false
        gatewayName.lineBreakMode = .byTruncatingMiddle
        gatewayName.accessibilityIdentifier = "mac-sidebar.gateway"
        gatewayName.isUserInteractionEnabled = true   // its tooltip
        gatewayName.addInteraction(gatewayTip)
        addSubview(gatewayDot)
        addSubview(gatewayName)
        // [sidebar-feel] The gateway's name in the name column, under the bots' and places' names (it started 2 pt
        // right of them), its dot before it. Short of required: folded, the name is hidden and has no room.
        gatewayLeading = gatewayName.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.contentInset + MacBotsRail.nameLeading)
        gatewayLeading.priority = .required - 1
        NSLayoutConstraint.activate([
            gatewayDot.widthAnchor.constraint(equalToConstant: 7), gatewayDot.heightAnchor.constraint(equalToConstant: 7),
            gatewayDot.trailingAnchor.constraint(equalTo: gatewayName.leadingAnchor, constant: -6),
            gatewayDot.centerYAnchor.constraint(equalTo: toggle.centerYAnchor),
            gatewayLeading,
            gatewayName.centerYAnchor.constraint(equalTo: toggle.centerYAnchor),
            gatewayName.trailingAnchor.constraint(lessThanOrEqualTo: settingsButton.leadingAnchor, constant: -6),
        ])
        connectionToken = NotificationCenter.default.addObserver(forName: Self.connectionChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showGateway() }
        }
        railGrip.accessibilityIdentifier = "mac-sidebar.rail-edge"
        railGrip.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(railDragged(_:))))
        railGrip.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(railHovered(_:))))
        let reset = UITapGestureRecognizer(target: self, action: #selector(openWidthReset))
        reset.numberOfTapsRequired = 2
        railGrip.addGestureRecognizer(reset)
        addSubview(railGrip)
        toggleLeading = toggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.contentInset)
        addTrailing = addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.contentInset)
        stackLeading = scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.contentInset)
        stackTrailing = scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.contentInset)
        toggleBottom = toggle.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -Self.contentInset)
        toggleCentre = toggle.centerXAnchor.constraint(equalTo: centerXAnchor)
        // [mac-audit #12] Owner 2026-11-02: one pixel of the window's own display (traitCollection), not the main
        // screen's: a Mac window on a 1x external display next to a 2x built-in one drew a blurred two-pixel line.
        edgeWidth = edge.widthAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale))
        footBottom = footScroll.bottomAnchor.constraint(equalTo: toggle.topAnchor, constant: -6)
        // The gear: beside the + open, centred above the toggle folded (the foot's rows then end above the gear).
        settingsBesideAdd = [settingsButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -2),
                             settingsButton.centerYAnchor.constraint(equalTo: toggle.centerYAnchor)]
        settingsAboveToggle = [settingsButton.centerXAnchor.constraint(equalTo: toggle.centerXAnchor),
                               settingsButton.bottomAnchor.constraint(equalTo: toggle.topAnchor, constant: -2)]
        footAboveSettings = footScroll.bottomAnchor.constraint(equalTo: settingsButton.topAnchor, constant: -6)
        // Mac polish #5: the foot is drawn whole when it fits (its own height, short of required), and the bots keep
        // their least (all but required, so a window shorter than every minimum breaks nothing).
        let footWhole = footScroll.heightAnchor.constraint(equalTo: foot.heightAnchor)
        footWhole.priority = .defaultHigh
        botsRoom = scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
        botsRoom.priority = .required - 1
        footEdgeHeight = footEdge.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            footBottom, footEdgeHeight,
            toggleBottom, stackLeading, stackTrailing, addTrailing,
            addButton.centerYAnchor.constraint(equalTo: toggle.centerYAnchor),
            scroll.bottomAnchor.constraint(equalTo: footEdge.topAnchor),
            footEdge.bottomAnchor.constraint(equalTo: footScroll.topAnchor),
            footEdge.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            footEdge.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            footScroll.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            footScroll.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            footScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
            footWhole, botsRoom,
            foot.topAnchor.constraint(equalTo: footScroll.contentLayoutGuide.topAnchor),
            foot.bottomAnchor.constraint(equalTo: footScroll.contentLayoutGuide.bottomAnchor),
            foot.leadingAnchor.constraint(equalTo: footScroll.contentLayoutGuide.leadingAnchor),
            foot.trailingAnchor.constraint(equalTo: footScroll.contentLayoutGuide.trailingAnchor),
            foot.widthAnchor.constraint(equalTo: footScroll.frameLayoutGuide.widthAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            edge.topAnchor.constraint(equalTo: topAnchor), edge.bottomAnchor.constraint(equalTo: bottomAnchor),
            edge.trailingAnchor.constraint(equalTo: trailingAnchor), edgeWidth,
        ])
        // [mac-sidebar] A right click: a row's own menu over a row, Add to Sidebar ▸ anywhere else; a row drags to a new
        // place (`SidebarEditing`).
        addInteraction(UIContextMenuInteraction(delegate: self))
        scroll.addInteraction(UIDropInteraction(delegate: self))
        foot.addInteraction(UIDropInteraction(delegate: self))   // the places' rows sit there beside the bots
        themeToken = NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recolor() }
        }
        neighbourToken = NotificationCenter.default.addObserver(forName: Self.neighbourMayChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.followNeighbourSoon() }
        }
        // [chats-under] Chats Under Bots or its line style changed (the right click, a bot's menu, Settings).
        chatsToken = [BotChatsPrefs.changed, BotChatsStyle.changed].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.botsChanged() }
            }
        }
        // Owner 2026-11-03 (Mac 720): "The bar had black behind it and now doesn't after I moved the window": the first
        // read ran before the window had drawn. Read again whenever the window comes forward or becomes key.
        for name in [UIScene.didActivateNotification, UIWindow.didBecomeKeyNotification, UIWindow.didBecomeVisibleNotification] {
            sceneTokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.neighbourRetries = 8
                    self?.followNeighbourSoon()
                }
            })
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self, UITraitPreferredContentSizeCategory.self]) {
            (bar: MacSidebar, _) in bar.rebuild()
        }
        registerForTraitChanges([UITraitDisplayScale.self]) { (bar: MacSidebar, _) in
            bar.edgeWidth.constant = 1 / max(1, bar.traitCollection.displayScale)
        }
        // [sidebar-intent] The window went behind another (or another app came in front), or came back: its accent
        // mark goes grey and comes back (`MacSelection.windowActive`).
        registerForTraitChanges([UITraitActiveAppearance.self]) { (bar: MacSidebar, _) in bar.windowActiveChanged() }
        rebuild()
    }

    private func windowActiveChanged() {
        guard window != nil else { return }
        MacSelection.windowActive(traitCollection.activeAppearance != .inactive)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        shownAt = window == nil ? .greatestFiniteMagnitude : CACurrentMediaTime()
        if window != nil { followNeighbourSoon() }
        windowActiveChanged()
        #if DEBUG
        // `-HQDebugSlowMotion 0.1`: the window's animations at a tenth of their speed, to photograph one part-way.
        let slow = UserDefaults.standard.double(forKey: "HQDebugSlowMotion")
        if slow > 0, let window { window.layer.speed = Float(slow) }
        #endif
    }

    /// Lays the sidebar out now, in two passes. The sidebar's own pass reads the bots' rows' height to give their list
    /// its least height (`layoutSubviews`), and it runs before the lists lay their rows out: the first pass places the
    /// rows, the second reads their new height and moves the lists. One pass left the lists to a later one, outside
    /// the animation, so the places jumped while the bots' rows glided.
    private func settleLayout() {
        for _ in 0..<2 {
            setNeedsLayout()
            layoutIfNeeded()
        }
        layoutIfNeeded()
    }

    isolated deinit {
        if let themeToken { NotificationCenter.default.removeObserver(themeToken) }
        if let connectionToken { NotificationCenter.default.removeObserver(connectionToken) }
        if let neighbourToken { NotificationCenter.default.removeObserver(neighbourToken) }
        chatsToken.forEach { NotificationCenter.default.removeObserver($0) }
        sceneTokens.forEach { NotificationCenter.default.removeObserver($0) }
        if let gatewayWatch { gatewayWatch.gateways.stopObserving(gatewayWatch.token) }
    }

    /// The tabs changed (Kanban or Artifacts, a gateway switch): the rows are made again.
    func rebuild() {
        guard let tabs else { return }
        badgeWatch = []
        rows.forEach { $0.removeFromSuperview() }
        foot.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let folded = Self.isCollapsed
        let named = folded && Self.railNamed   // [rail-names] each place with its name under it
        clearHeads()   // made again below: UI Scale, a theme or the fold may have changed their sizes
        // [mac-layout] Owner 2026-11-03 (the layout study): Search and New Chat first, then the places, then the bots, in
        // both widths: nothing that matters at the bottom corner (Apple: "avoid putting critical information or actions
        // at the bottom of a sidebar").
        // [Mac UI check 2026-11-13] Search and New Chat stay put over the bots' list, not as its first row: revealing a
        // low bot or group chat scrolled them half off the top (Mac polish #27 only kept the foot's offset off this list).
        self.tools?.removeFromSuperview()
        let tools = MacSidebarTools(folded: folded, named: named)
        tools.translatesAutoresizingMaskIntoConstraints = false
        self.tools = tools
        addSubview(tools)
        NSLayoutConstraint.activate([
            tools.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            tools.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: tools.bottomAnchor, constant: stack.spacing),
        ])
        var placeRows: [Row] = []
        var toolRows: [Row] = []
        let places = tabs.placedTabs   // [mac-sidebar] every place, the ones the tab controller doesn't hold now too
        rows = places.enumerated().map { index, controller in
            let item = controller.tabBarItem ?? UITabBarItem()
            // View's ⌘1…⌘9 items (KeyCommands.viewItems): the first eight places, and the ninth or, past nine, the last,
            // with More skipped (it has no row here; Mac polish #18, `TabShortcut`).
            let row = Row(item: item, shortcut: KeyCommands.shortcut(forTab: index, among: places.map { $0.tabBarItem.tag }), folded: Self.isCollapsed, named: named)
            row.controller = controller
            row.isTool = tabs.pages?.isTool(controller) ?? false   // [sidebar-tidy] quieter than the bots and places
            row.addAction(UIAction { [weak self, weak row, weak controller] _ in
                guard let self, let tabs = self.tabs, let controller else { return }
                // [mac] stress test #62: the right pane follows the tab; a chat left over its list goes straight there
                // (`switchPlace`, tester 2026-11-14: one laid out in the hidden list column froze the app)
                if let split = tabs.split { split.switchPlace(to: controller) { tabs.pick(controller) } } else { tabs.pick(controller) }
                MacSelection.focus(on: .sidebar)   // [mac] Stress test 2026-10-28 #54
                self.selectionChanged()
                row?.playMotion()             // [tabmotion] after the select, in the colour it turns
            }, for: .touchUpInside)
            // [mac-sidebar] Its own Control-click menu, and a row with a place in Settings › Tabs (not More) drags to a
            // new one.
            row.addInteraction(UIContextMenuInteraction(delegate: self))
            let isTool = tabs.pages?.isTool(controller) ?? false
            if TabChoice(tag: item.tag) != nil, !folded, !isTool {
                let drag = UIDragInteraction(delegate: self)
                drag.isEnabled = true
                row.addInteraction(drag)
            }
            // [bots-rail] [mac-layout] Bots is the bots themselves, open or folded: its row is left out.
            // [mac-layout] More dissolved: its pages are Tools and the Settings window's; it stays a place out of
            // sight (⌘K's results open from its stack), with no row.
            if isTool { toolRows.append(row) } else if item.tag != HQTab.bots.rawValue, item.tag != HQTab.more.rawValue { placeRows.append(row) }
            let height = row.heightAnchor.constraint(equalToConstant: named ? Self.namedRowHeight : Self.rowHeight)
            height.priority = .required - 1   // [sidebar-feel] a hidden Tools row has no height in its stack (`foldTools`)
            height.isActive = true
            badgeWatch.append(item.observe(\.badgeValue, options: [.new]) { [weak row] item, _ in
                MainActor.assumeIsolated { row?.badge = item.badgeValue }
            })
            // The Jobs tab's icon turns while jobs run (`TabIcons.jobsRunning`).
            badgeWatch.append(item.observe(\.image, options: [.new]) { [weak row] _, _ in
                MainActor.assumeIsolated { row?.imageChanged() }
            })
            return row
        }
        // [rail-names] One place to a line, its name under it, as the bots' heads below: two across crowded the names
        // ("Sessions" ran into "Jobs") and left an odd one at half width (owner 2026-11-04, the folded sidebar).
        // Owner 2026-11-04: "I want the nav options in the left sidebar to be at the bottom with the bots on top." The bots
        // scroll under Search and New; the places and Tools stay at the foot, above the sidebar button, in both widths.
        // Without the bots in the sidebar the places stay at the top, under Search and New.
        // [sidebar-tidy] 2026-11-10: tried with the places following the bots in the one list (no empty panel under New
        // Bot). Owner: "Won't that kind of feel chaotic?" It did: the places moved with every bot added, group folded
        // or chat listed, and scrolled out of sight under a long roster. They stay pinned at the foot.
        let nav = showsBots ? foot : stack
        footEdge.subviews.forEach { $0.removeFromSuperview() }
        footEdgeHeight.constant = 0
        if showsBots {
            let gap = UIView()
            gap.heightAnchor.constraint(equalToConstant: folded ? 4 : 6).isActive = true
            stack.addArrangedSubview(gap)
            stack.addArrangedSubview(botsStack)
            // A faint line, so the fixed foot reads apart from the list that scrolls above it. [Mac UI check
            // 2026-11-13] Fixed between the lists (`footEdge`), so the foot's rows scroll under it.
            let line = MacRailLine(wide: !folded)
            line.translatesAutoresizingMaskIntoConstraints = false
            footEdge.addSubview(line)
            NSLayoutConstraint.activate([
                line.topAnchor.constraint(equalTo: footEdge.topAnchor),
                line.leadingAnchor.constraint(equalTo: footEdge.leadingAnchor),
                line.trailingAnchor.constraint(equalTo: footEdge.trailingAnchor),
            ])
            // MacRailLine's own height and the gap it had in the foot. [sidebar-feel] Open, the line had 10 pt over
            // it and 6 under (8 px and 4.5 on the screen): 5 and 5 now.
            footEdgeHeight.constant = folded ? 9 + foot.spacing : 10
        }
        scroll.contentInset.bottom = showsBots && !folded ? 1 : 6
        placeRows.forEach { nav.addArrangedSubview($0) }
        addTools(toolRows, folded: folded, into: nav)
        if showsBots { botsChanged() }
        placeRailGateway()
        showGateway()
        // A gap above the button, rows at the foot or not. [sidebar-intent] Open, a section's break more: the bar is
        // not one of the rows above it.
        footBottom.constant = -6 - (folded ? 0 : Self.sectionBreak)
        botsRoom.constant = showsBots ? Self.botsMinHeight : 0   // Mac polish #5
        placeToggle()
        recolor()
        superview?.setNeedsLayout()   // the width follows UI Scale (RootSplitController places it)
    }

    /// [mac-layout] Owner 2026-11-03 (the layout study): More's working pages (Workspace, Insights) as the sidebar's Tools.
    /// Open: under a "Tools" heading that folds, as the bots' groups do. Folded: one button whose menu lists them.
    private weak var foldedTools: Row?

    private func addTools(_ toolRows: [Row], folded: Bool, into stack: UIStackView) {
        foldedTools = nil
        guard !toolRows.isEmpty else { return }
        if folded {
            // A row of its own (marked while a tool is on show), with a menu button over it that lists the tools.
            let item = UITabBarItem(title: "Tools", image: UIImage(systemName: "wrench.and.screwdriver"), tag: -1)
            // Named as the places above it are, in the rail that shows names.
            let named = Self.railNamed
            let row = Row(item: item, shortcut: nil, folded: true, named: named)
            row.heightAnchor.constraint(equalToConstant: named ? Self.namedRowHeight : Self.rowHeight).isActive = true
            let button = UIButton(type: .custom)
            button.accessibilityIdentifier = "mac-sidebar.tools-menu"
            button.accessibilityLabel = "Tools"
            button.toolTip = "Tools"
            button.showsMenuAsPrimaryAction = true
            button.menu = UIMenu(title: "Tools", children: toolRows.map { tool in
                UIAction(title: tool.item.title ?? "", image: tool.item.image) { [weak tool] _ in tool?.sendActions(for: .touchUpInside) }
            })
            button.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: row.topAnchor), button.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                button.leadingAnchor.constraint(equalTo: row.leadingAnchor), button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            ])
            // The rows stay made (selection marks, ⌘ shortcuts) but off screen; the menu clicks them.
            toolRows.forEach { $0.isHidden = true; stack.addArrangedSubview($0) }
            stack.addArrangedSubview(row)
            foldedTools = row
            return
        }
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(Self.aboveHeading, after: last) }   // as over the bots' headings
        let heading = MacSidebarHeading(title: "Tools", key: "tools") { [weak self] in self?.foldTools() }
        toolsHeading = heading
        stack.addArrangedSubview(heading)
        toolRows.forEach { $0.isHidden = heading.isFolded; stack.addArrangedSubview($0) }
    }

    /// [sidebar-feel] Tools' heading clicked: the places' list slides down over its rows like a drawer closing (or up
    /// off them), and the bots' list takes or gives the room in the same glide. The whole sidebar used to be made
    /// again, so every row snapped. The rows keep their height on the way: closing them up row by row ran their names
    /// into each other.
    private func foldTools() {
        guard let heading = toolsHeading else { return rebuild() }
        let hide = heading.isFolded
        let tools = rows.filter { $0.isTool && $0.superview != nil }
        heading.showFold(animated: true)
        let glides = window != nil && !HQMotion.reduced
        let boxes = glides ? glideBoxes.map(\.frame) : []
        var leaving: [UIView] = []
        if glides, hide {
            // A picture of each row stays where the row was until the list has slid over it.
            for row in tools where !row.isHidden {
                guard let ghost = row.snapshotView(afterScreenUpdates: false) else { continue }
                ghost.frame = row.frame
                ghost.isUserInteractionEnabled = false
                leaving.append(ghost)
            }
        }
        for row in tools where row.isHidden != hide { row.isHidden = hide }
        if glides {
            glideRows([], from: [:], leaving: leaving, boxes: boxes, in: tools.first?.superview, fades: false)
        } else {
            UIView.performWithoutAnimation { settleLayout() }
        }
        selectionChanged()   // the open Tool, if one of them, scrolls into view
    }

    /// [mac-layout] The bots are in the sidebar while Bots is one of the places (Settings › Tabs keeps Bots or Sessions).
    private var showsBots: Bool { tabs?.controller(for: .bots) != nil }

    // MARK: The bots' heads ([bots-rail])

    /// The roster changed (or the sidebar folded, or a room changed): the heads follow the Bots list's blocks and order
    /// (`BotsViewController.railSections`). A head that stays keeps its view (only a changed row is drawn again); the
    /// stack is laid out again only when the order or groups changed.
    func botsChanged() {
        guard let tabs, showsBots else { return }
        let open = !Self.isCollapsed
        let bots = tabs.botsViewController
        // [mac] Show Hidden Bots (the right click): a Hidden group last, open sidebar or rail.
        let groups = MacBotsRail.titledGroups(bots.railSections(), showHidden: bots.railShowsHidden)
            .filter { open || !$0.items.isEmpty }   // the rail draws no empty section (no heading to carry it)
        // [chats-under] Open, each bot's chats under its row, as Filter › Chats Under Bots lists them in the Bots list
        // (the rail's heads have no room for them).
        let chats = open ? bots.railChats(for: groups.flatMap { $0.items.compactMap { $0.item.bot?.id } }) : [:]
        let style = BotChatsStyle.saved
        var nextChats: [String: MacSidebarChat] = [:]
        var nextHeadings: [String: MacSidebarHeading] = [:]
        var next: [String: MacRailHead] = [:]
        var arranged: [UIView] = []
        var signature: [String] = []
        for (index, group) in groups.enumerated() {
            if open, group.title.isEmpty {
                // Mac polish #130: Group By › None's one block (bots and group chats together) has no heading; under
                // the pins it is set apart by the rail's faint line.
                if index > 0 { arranged.append(MacRailLine(wide: true)); signature.append("|") }
            } else if open {
                // [mac-layout] Open: each group under its heading (Pinned, a section, Bots), which folds it away.
                let key = MacSidebarHeading.key(for: group.block)
                let heading: MacSidebarHeading
                if let kept = headings[key], kept.title == group.title, nextHeadings[key] == nil {
                    heading = kept
                    heading.showFold(animated: true)
                } else {
                    heading = MacSidebarHeading(title: group.title, key: key) { [weak self] in
                        self?.botsSignature = ""; self?.botsChanged()
                    }
                    if case .user(let id) = group.block {
                        // [mac] A section's heading has the list's section menu on its right click (Rename…, Move, Delete).
                        heading.sectionId = id
                        heading.addInteraction(UIContextMenuInteraction(delegate: self))
                    }
                }
                if nextHeadings[key] == nil { nextHeadings[key] = heading }
                arranged.append(heading)
                signature.append("#\(heading.key)\(group.title)\(heading.isFolded ? "-" : "+")")
                if heading.isFolded { continue }
                if group.items.isEmpty, case .user(let id) = group.block {
                    // [mac] An empty section stays, with the list's hint, and takes a dragged bot (`railLanding`).
                    arranged.append(MacSidebarEmptyHint(sectionId: id))
                    signature.append("_" + id)
                }
            } else if index > 0 {
                arranged.append(MacRailLine())
                signature.append("|")
            }
            for (block, item) in group.items {
                let head = heads[item.key] ?? makeHead(item)
                head.update(item)
                head.block = block
                next[item.key] = head
                arranged.append(head)
                signature.append(item.key)
                guard let bot = item.bot, let picked = chats[bot.id] else { continue }
                var looks: [(key: String, look: MacSidebarChat.Look)] = picked.shown.enumerated().map { index, session in
                    (bot.id + "\u{1F}" + session.id,
                     MacSidebarChat.Look(kind: .chat(session), botName: bot.name, tint: bot.chatsTint,
                                         last: index == picked.shown.count - 1 && picked.more == 0, style: style))
                }
                if picked.more > 0 {
                    looks.append((bot.id + "\u{1F}more", MacSidebarChat.Look(kind: .more(picked.more), botName: bot.name,
                                                                              tint: bot.chatsTint, last: true, style: style)))
                }
                for (key, look) in looks {
                    let row = chatRows[key] ?? makeChatRow(bot: bot.id, look: look)
                    row.update(look)
                    nextChats[key] = row
                    arranged.append(row)
                    signature.append("c" + key)
                }
            }
        }
        if railAdd == nil, let organizer = bots.organizer {
            railAdd = MacRailAdd(titled: open, label: tabs.botsViewController.createLabel) { [weak organizer] in organizer?.composeMenu() ?? [] }
        }
        if let railAdd { arranged.append(railAdd); signature.append("+") }
        let joined = signature.joined(separator: " ")
        if joined != botsSignature {
            botsSignature = joined
            // [sidebar-feel] A group folded or opened, a chat listed under its bot, a bot added or moved: the rows that
            // stay glide to their new places, new ones fade in and the ones that go fade out. They all jumped.
            let was = botsStack.arrangedSubviews
            let glides = window != nil && !was.isEmpty && !HQMotion.reduced
            var from: [ObjectIdentifier: CGFloat] = [:]
            var leaving: [UIView] = []
            let boxes = glides ? glideBoxes.map(\.frame) : []
            if glides {
                let staying = Set(arranged.map { ObjectIdentifier($0) })
                for view in was where !view.isHidden {
                    let top = (view.layer.presentation() ?? view.layer).frame.minY
                    if staying.contains(ObjectIdentifier(view)) {
                        from[ObjectIdentifier(view)] = top
                    } else if let ghost = view.snapshotView(afterScreenUpdates: false) {
                        ghost.frame = CGRect(x: view.frame.minX, y: top, width: view.bounds.width, height: view.bounds.height)
                        ghost.isUserInteractionEnabled = false
                        leaving.append(ghost)
                    }
                }
            }
            was.forEach { $0.removeFromSuperview() }
            arranged.forEach { botsStack.addArrangedSubview($0) }
            // [chats-under] No gap above a chat row: the line down a bot's chats is drawn a row at a time, and the
            // stack's 2 pt between rows broke it at every chat (owner 2026-11-09: "it's not a continuous line").
            for (view, below) in zip(arranged, arranged.dropFirst()) {
                botsStack.setCustomSpacing(below is MacSidebarChat ? 0 : below is MacSidebarHeading ? Self.aboveHeading : botsStack.spacing,
                                           after: view)
            }
            if glides { glideRows(arranged, from: from, leaving: leaving, boxes: boxes) }
        }
        headings = nextHeadings
        for (key, head) in heads where next[key] == nil { head.removeFromSuperview() }
        heads = next
        for (key, row) in chatRows where nextChats[key] == nil { row.removeFromSuperview() }
        chatRows = nextChats
        markHeads()
        setNeedsLayout()   // `placeFade` measures the rows again (a heading left last)
    }

    /// [sidebar-feel] The bots' rows after a change: each row that stayed starts where it was drawn (`from`, its old
    /// top in the bots' stack) and glides to its new place; a new row fades in once there is room for it; a picture of
    /// each row that went (`leaving`) fades out where it was. The bots' list, the line under it and the places' list
    /// (`boxes`, their frames before the change) take or give the room in the same glide: the places jumped while the
    /// bots' rows were still on their way.
    private func glideRows(_ arranged: [UIView], from: [ObjectIdentifier: CGFloat], leaving: [UIView], boxes: [CGRect],
                           in list: UIView? = nil, fades: Bool = true) {
        UIView.performWithoutAnimation { settleLayout() }
        var moved: [UIView] = []
        var fresh: [(view: UIView, alpha: CGFloat)] = []
        for view in arranged where !view.isHidden {
            if let top = from[ObjectIdentifier(view)] {
                let offset = top - view.frame.minY
                guard abs(offset) > 0.5 else { continue }
                view.transform = CGAffineTransform(translationX: 0, y: offset)
                moved.append(view)
            } else if fades {
                fresh.append((view, view.alpha))
                view.alpha = 0
            }
        }
        leaving.forEach { (list ?? botsStack).insertSubview($0, at: 0) }
        let resized = zip(glideBoxes, boxes).map { (box: $0, start: $1, end: $0.frame) }.filter { $0.start != $0.end }
        guard !moved.isEmpty || !fresh.isEmpty || !leaving.isEmpty || !resized.isEmpty else { return }
        resized.forEach { Self.shrinkFade(of: $0.box, from: $0.start) }
        UIView.performWithoutAnimation { resized.forEach { $0.box.frame = $0.start } }
        let options: UIView.AnimationOptions = [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
        HQMotion.animate(Self.glide, options: options, changes: {
            moved.forEach { $0.transform = .identity }
            resized.forEach { $0.box.frame = $0.end }   // where the layout has them: the next pass changes nothing
        }, completion: { _ in
            if !fades { leaving.forEach { $0.removeFromSuperview() } }   // Tools' rows: the list has slid over them
        })
        guard fades else { return }
        HQMotion.animate(Self.glide * 0.35, options: options, changes: { leaving.forEach { $0.alpha = 0 } },
                         completion: { _ in leaving.forEach { $0.removeFromSuperview() } })
        // Key frames, not a delay: the new rows wait for the rows below to be most of the way out of their place.
        UIView.animateKeyframes(withDuration: Self.glide, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {   // motion-ok: opacity only
            UIView.addKeyframe(withRelativeStartTime: 0.45, relativeDuration: 0.55) { fresh.forEach { $0.view.alpha = $0.alpha } }
        }
    }

    /// A list that gives up room in a glide (`box`, laid out at its new size, `start` its frame before): its foot fade
    /// is already the size the list ends at, which cut the rows under it off at once and left a gap that closed as the
    /// list slid. The fade starts at the list's old foot and shrinks with it.
    private static func shrinkFade(of box: UIView, from start: CGRect) {
        let extra = start.height - box.frame.height
        guard let mask = box.layer.mask, extra > 0.5 else { return }
        let height = CABasicAnimation(keyPath: "bounds.size.height")   // motion-ok: `glideRows` runs with Reduce Motion off only
        height.fromValue = mask.bounds.height + extra
        height.toValue = mask.bounds.height
        let place = CABasicAnimation(keyPath: "position.y")   // motion-ok: as the line above
        place.fromValue = mask.position.y + extra * mask.anchorPoint.y
        place.toValue = mask.position.y
        for animation in [height, place] {
            animation.duration = glide
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            mask.add(animation, forKey: animation.keyPath)
        }
    }

    /// The three boxes that share the sidebar's height: the bots' list, the line under it, the places and Tools.
    private var glideBoxes: [UIView] { [scroll, footEdge, footScroll] }

    private func makeHead(_ item: MacBotsRail.Item) -> MacRailHead {
        let head = MacRailHead(item: item, named: Self.railNamed, inRow: !Self.isCollapsed)
        head.addAction(UIAction { [weak self, weak head] _ in
            guard let self, let head else { return }
            switch head.item {
            case .bot(let bot): self.openBotChat(bot.id)
            case .room(let room): self.openRoom(room.id)
            }
        }, for: .touchUpInside)
        head.addInteraction(UIContextMenuInteraction(delegate: self))
        // [rail-more] A bot's head drags to a new place (`railDrop`). Mac polish #31: a group chat's into a section
        // (`roomDrop`); among its group it stays where the list puts it.
        let drag = UIDragInteraction(delegate: self)
        drag.isEnabled = true
        head.addInteraction(drag)
        return head
    }

    /// [chats-under] A chat under a bot: it opens beside the sidebar; "N more" opens Sessions with the bot picked.
    private func makeChatRow(bot: String, look: MacSidebarChat.Look) -> MacSidebarChat {
        let row = MacSidebarChat(bot: bot, look: look)
        row.addAction(UIAction { [weak self, weak row] _ in
            guard let self, let row, let tabs = self.tabs else { return }
            if let session = row.session {
                self.showBots(marking: row.bot + "\u{1F}" + session.id)
                tabs.botsViewController.openRailChat(session)
            } else {
                tabs.botsViewController.openAllChats(of: row.bot)
            }
        }, for: .touchUpInside)
        // [Mac UI check 2026-11-13] Its own right click: the chat's menu as Sessions has it (`contextMenuInteraction`).
        row.addInteraction(UIContextMenuInteraction(delegate: self))
        return row
    }

    private func clearHeads() {
        botsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        botsSignature = ""
        heads = [:]
        chatRows = [:]
        headings = [:]
        railAdd = nil
    }

    /// Mac polish #32: the row of a bot (by its id) or a group chat (by its key), for a question or tip to point at.
    func row(forBot id: String) -> UIView? {
        (heads[id] ?? heads[MacBotsRail.Item.roomKey(id)]).flatMap { $0.window == nil ? nil : $0 }
    }

    /// [mac-layout] The heads on show, top to bottom (a folded group's are left out).
    private var shownHeads: [MacRailHead] { botsStack.arrangedSubviews.compactMap { $0 as? MacRailHead } }
    /// A head's frame in the rows' stack, where drops and drop lines are measured.
    private func frameOf(_ view: UIView) -> CGRect { view.convert(view.bounds, to: stack) }

    /// A head's click: Bots becomes the tab on show (its list stays folded) and the bot's chat opens beside the rail,
    /// exactly as its row in the list opens it.
    private func openBotChat(_ id: String) {
        guard let tabs else { return }
        showBots(marking: id)
        tabs.botsViewController.open(id)
    }

    /// [rail-more] A group chat's head: its room opens beside the rail, as its row in the list opens it.
    private func openRoom(_ key: String) {
        guard let tabs else { return }
        showBots(marking: MacBotsRail.Item.roomKey(key))
        tabs.botsViewController.openRoom(key)
    }

    private func showBots(marking key: String) {
        guard let tabs, let bots = tabs.controller(for: .bots) else { return }
        if tabs.selectedViewController !== bots {
            if let split = tabs.split { split.switchPlace(to: bots) { tabs.pick(bots) } } else { tabs.pick(bots) }
        }
        MacSelection.focus(on: .sidebar)
        openHead = key
        markHeads()
    }

    /// The bot (or group chat, by room key) whose own chat is on show beside the list (nil: none, or another screen).
    /// [chats-under] `chat`: a bot's other chat on show (bot id + U+001F + session id), marked under its bot if listed there.
    func markOpen(bot: String?, room: String? = nil, chat: String? = nil) {
        openHead = bot ?? room.map(MacBotsRail.Item.roomKey) ?? chat
        markHeads()
    }

    private func markHeads() {
        let onBots = tabs?.shownTab == .bots
        for (key, head) in heads { head.isMarked = onBots && key == openHead }
        for (key, row) in chatRows { row.isMarked = onBots && key == openHead }
        let marked: UIView? = heads.values.first(where: \.isMarked) ?? chatRows.values.first(where: \.isMarked)
        if let marked, marked.superview != nil { reveal(marked) }
    }

    /// Scrolls the list that holds `view` (the bots' or the foot's) so it shows clear of the list's fading edges.
    /// Mac polish #27: a place in the foot was measured in the foot and scrolled the bots' list by its offset there,
    /// pushing Search half off the top.
    /// [Mac UI check 2026-11-13] It stops on whole rows: the row past `view` shows whole (faded, as more to scroll to),
    /// not cut in half on the list's edge ("+ New Bot" struck through by the foot's line, a sliver of Jobs under it).
    private func reveal(_ view: UIView) {
        let lists: [UIScrollView] = [scroll, footScroll]
        guard !view.isHidden, let list = lists.first(where: { view.isDescendant(of: $0) }),
              list.contentSize.height > list.bounds.height + 1 else { return }
        list.layoutIfNeeded()
        let frame = view.convert(view.bounds, to: list)
        let top = list.contentOffset.y, height = list.bounds.height
        let least = -list.contentInset.top
        let most = max(least, list.contentSize.height + list.contentInset.bottom - height)
        let rows = rowFrames(in: list)
        var target: CGFloat
        if frame.minY - Self.fadeHeight < top {
            // Above: the row before it shows whole at the top (the list's own top when that is the first row).
            let before = rows.last { $0.maxY <= frame.minY + 0.5 }
            target = before.map { before in before.minY <= rows.first!.minY + 0.5 ? least : before.minY } ?? least
        } else if frame.maxY + Self.fadeHeight > top + height {
            // Below: the row after it ends on the list's foot (the list's own end when that is the last row).
            let after = rows.first { $0.minY >= frame.maxY - 0.5 }
            target = after.map { after in after.maxY >= rows.last!.maxY - 0.5 ? most : after.maxY - height } ?? most
        } else {
            return
        }
        target = min(max(target, least), most)
        if abs(target - top) > 0.5 { glide(list, to: target) }
    }

    /// [sidebar-feel] A list moved to show a row (a place picked with ⌘9, a chat opened from a link): it glides there.
    /// It jumped, so the rows changed under the eye with nothing to say which way. At launch (the first moments on
    /// show) and under Reduce Motion it is simply there.
    private func glide(_ list: UIScrollView, to y: CGFloat) {
        let place = { list.contentOffset = CGPoint(x: 0, y: y) }
        guard window != nil, CACurrentMediaTime() - shownAt > 2 else { return place() }
        HQMotion.animate(Self.glide, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction], changes: place)
    }

    /// The rows on show in `list` (its content's points, top to bottom): a bot's or group's rows, the places and Tools;
    /// not the thin gaps between them.
    private func rowFrames(in list: UIScrollView) -> [CGRect] {
        let container: UIStackView = list === footScroll ? foot : stack
        let views = container.arrangedSubviews.flatMap { $0 === botsStack ? botsStack.arrangedSubviews : [$0] }
        return views.filter { !$0.isHidden && $0.bounds.height >= 12 }.map { $0.convert($0.bounds, to: list) }
    }

    /// [Mac UI check 2026-11-13] The foot back at its top (Sessions and Jobs in view) once what is on show isn't one
    /// of its lower rows: a low Tool picked once left the places scrolled away under New Bot from then on.
    private func footBackToTop() {
        guard footScroll.contentOffset.y > -footScroll.contentInset.top + 0.5 else { return }
        glide(footScroll, to: -footScroll.contentInset.top)
    }

    /// Mac polish #5: the least the bots' list keeps in a short window (Search and New Chat, a heading and two bots;
    /// on the rail the two buttons and two heads), the places and Tools scrolling below it.
    static var botsMinHeight: CGFloat { ((isCollapsed ? 220 : 180) * chrome).rounded() }

    // MARK: The gateway switcher ([rail-more])

    /// More than one gateway and the rail folded: the Bots title's switcher at the rail's top (the title is hidden while
    /// the list is folded into the rail). Otherwise the heads start under the window's buttons as before.
    private func placeRailGateway() {
        watchGateways()
        let wanted = railGatewayWanted
        let namedSwitcher = !Self.isCollapsed || Self.railNamed
        if !wanted || railGateway.map({ $0.isNamed != namedSwitcher }) == true {
            railGateway?.removeFromSuperview()
            railGateway = nil
        }
        if wanted, railGateway == nil {
            let button = MacRailGateway(named: namedSwitcher) { [weak self] in
                self?.tabs?.botsViewController.gatewaySwitcher?.menu([])
            }
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: topAnchor, constant: Self.topRoom - 8),
                button.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            ])
            railGateway = button
        }
        // [rail-top] Search and New Chat (and the rows under them) start right under the switcher; else at `topRoom`.
        toolsTop?.isActive = false
        if let tools {
            toolsTop = railGateway.map { tools.topAnchor.constraint(equalTo: $0.bottomAnchor, constant: 4) }
                ?? tools.topAnchor.constraint(equalTo: topAnchor, constant: Self.topRoom)
            toolsTop?.isActive = true
        }
        gatewaysChanged()
    }

    /// The gateways' own listener (as the titles have): a switch starting or landing, news, a gateway added or removed.
    private func watchGateways() {
        guard gatewayWatch == nil, let gateways = tabs?.botsViewController.gatewaySwitcher?.gateways else { return }
        let token = gateways.observe { [weak self] in
            guard let self else { return }
            // The switcher turns on or off with a second gateway: the rail's top follows (after the title's own refresh).
            DispatchQueue.main.async { if (self.railGateway != nil) != self.railGatewayWanted { self.placeRailGateway() } else { self.gatewaysChanged() } }
        }
        gatewayWatch = (token, gateways)
    }

    private var railGatewayWanted: Bool {
        // [mac-layout] Open too: the Bots list (and its title's switcher) no longer shows beside the sidebar.
        showsBots && (tabs?.botsViewController.gatewaySwitcher?.isActive ?? false)
    }

    /// [sidebar-tidy] The foot's gateway line: the current gateway's name and a dot for the connection (green
    /// connected, orange while it connects, red offline or signed out).
    private func showGateway() {
        let shown = Self.tidy && !Self.isCollapsed
        gatewayDot.isHidden = !shown
        gatewayName.isHidden = !shown
        guard shown, let tabs else { return }
        let rows = tabs.botsViewController.gatewaySwitcher?.gateways.accounts ?? []
        let title = rows.first(where: \.isCurrent)?.title ?? tabs.services.account?.baseURL.host() ?? ""
        let state = tabs.services.connection
        gatewayLeading.constant = Self.contentInset + MacBotsRail.nameLeading   // UI Scale moves the column
        gatewayName.text = title
        gatewayName.font = Self.font(14)
        gatewayName.textColor = HQPalette.label.withAlphaComponent(0.74)
        switch state {
        case .ready: gatewayDot.backgroundColor = .systemGreen
        case .connecting, .reconnecting: gatewayDot.backgroundColor = .systemOrange
        case .offline, .signedOut: gatewayDot.backgroundColor = .systemRed
        }
        gatewayTip.defaultToolTip = "\(AccountView.status(state)): \(title)"
        gatewayName.accessibilityLabel = "Gateway \(title), \(AccountView.status(state))"
    }

    private func gatewaysChanged() {
        showGateway()
        guard let railGateway, let gateways = gatewayWatch?.gateways else { return }
        let rows = gateways.accounts
        let switching = gateways.switchingTo.flatMap { id in rows.first { $0.id == id }?.title }
        let title = switching.map { "Switching to \($0)…" } ?? rows.first(where: \.isCurrent)?.title ?? ""
        railGateway.show(title: title, news: gateways.otherNews > 0 && switching == nil, busy: switching != nil)
    }


    /// [mac-sidebar] The row under `point` (in this view), with its place in Settings › Tabs (nil for More).
    func row(at point: CGPoint) -> (index: Int, choice: TabChoice?)? {
        for (index, row) in rows.enumerated() where row.bounds.contains(row.convert(point, from: self)) && Self.unclipped(row, at: point, in: self) {
            return (index, row.controller.flatMap { TabChoice(tag: $0.tabBarItem.tag) })
        }
        return nil
    }

    /// The point is on `row` as drawn: inside every clipping view between it and the sidebar. In a short window the places
    /// scroll, and a row scrolled out of sight still lay under blank space above them, so a right click there opened its menu.
    private static func unclipped(_ row: UIView, at point: CGPoint, in sidebar: UIView) -> Bool {
        var view = row.superview
        while let next = view, next !== sidebar {
            if next.clipsToBounds, !next.bounds.contains(next.convert(point, from: sidebar)) { return false }
            view = next.superview
        }
        return true
    }

    #if DEBUG
    /// [mac-sidebar] MacShots: what a right click on row `index` (nil: the empty space) would offer, and a click.
    func debugMenu(forRow index: Int?) -> UIMenu {
        guard let index, rows.indices.contains(index) else { return SidebarEditing.spaceMenu() }
        return SidebarEditing.rowMenu(for: rows[index].controller.flatMap { TabChoice(tag: $0.tabBarItem.tag) })
    }
    func debugClick(_ index: Int) { if rows.indices.contains(index) { rows[index].sendActions(for: .touchUpInside) } }
    var debugScroll: UIScrollView { scroll }
    /// [sidebar-light] The glass's effect and tint, and the page and ink it is mixed from.
    var debugGlass: String {
        "glass \(glass.effect.map { String(describing: type(of: $0)) } ?? "none") hidden \(glass.isHidden) tint \(glassTint.map { "\($0)" } ?? "-") page \(HQPalette.page.resolvedColor(with: traitCollection)) ink \(HQPalette.label.resolvedColor(with: traitCollection)) style \(traitCollection.userInterfaceStyle.rawValue) desktop \(Theme.isDesktop)"
    }
    /// [icon-study] Each row's name and its icon's view (`MacShots` measures the drawn ink).
    var debugIcons: [(String, UIView)] { rows.map { ($0.title ?? "?", $0.debugIcon) } }
    /// [bots-rail] The heads in order, the marked one in brackets.
    var debugHeads: String {
        botsStack.arrangedSubviews.map { view in
            if let head = view as? MacRailHead { return head.isMarked ? "[\(head.item.key)]" : head.item.key }
            return view is MacRailLine ? "|" : view is MacRailAdd ? "+" : ""
        }.joined(separator: " ")
    }
    func debugClickHead(_ index: Int) {
        let shown = shownHeads
        if shown.indices.contains(index) { shown[index].sendActions(for: .touchUpInside) }
    }
    func debugHeadMenu(_ index: Int) -> UIMenu? {
        let shown = shownHeads
        guard shown.indices.contains(index), let organizer = tabs?.botsViewController.organizer, let bot = shown[index].bot else { return nil }
        return BotMenuNode.uiMenu(organizer.menuNodes(for: bot), title: bot.name).menu
    }
    func debugDropLine(_ gap: Int?) { if let gap { showDropLine(at: gap) } else { dropLine.isHidden = true } }
    /// [rail-more] A drag of head `from` held over head `over`'s top (or bottom) half: the drop line it shows, and (with
    /// `drop`) the drop itself. The heads' indices count bots and group chats alike.
    func debugRailDrag(from: Int, over: Int, below: Bool, drop: Bool) -> String {
        let shown = shownHeads
        guard shown.indices.contains(from), shown.indices.contains(over), let bot = shown[from].bot else { return "no such heads" }
        let target = frameOf(shown[over])
        let y = below ? target.maxY - 3 : target.minY + 3
        guard let landing = railLanding(bot, at: y) else { dropLine.isHidden = true; return "\(bot.id): no drop there" }
        showRailDropLine(landing)
        if drop { railDrop(bot, landing); dropLine.isHidden = true }
        return "\(bot.id) → \(landing.block) at \(landing.index) of \(landing.rows)"
    }
    /// [rail-more] The gateway switcher at the rail's top, and the items its menu offers.
    var debugRailGateway: String {
        guard let railGateway else { return "no switcher" }
        let items = tabs?.botsViewController.gatewaySwitcher?.menu([]).children.flatMap { ($0 as? UIMenu)?.children ?? [$0] } ?? []
        return "switcher \(railGateway.accessibilityLabel ?? "") frame \(railGateway.frame.integral): "
            + items.compactMap { ($0 as? UIAction).map { $0.title + ($0.state == .on ? " ✓" : "") } }.joined(separator: ", ")
    }
    #endif

    /// [rail-names] The rail's edge follows the pointer between a little narrower than the faces alone and a little
    /// wider than the names; past halfway the names come (or go) at once, and let go it settles on the nearer width.
    @objc private func railDragged(_ pan: UIPanGestureRecognizer) {
        // Open, every state of the drag is the open sidebar's (Mac 915 sent all but the first to the rail's code
        // below, which rebuilt the sidebar on each move: the drag all but froze, owner 2026-11-09).
        guard Self.isCollapsed else { return openDragged(pan) }
        let compact = Self.compactRailWidth, named = Self.namedRailWidth
        switch pan.state {
        case .began:
            railDragStart = Self.railWidth
        case .changed:
            let moved = pan.translation(in: self).x * (effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1)
            let width = min(max(railDragStart + moved, compact - 12), named + 16)
            Self.railDragWidth = width
            MacWindow.cursor("resizeLeftRightCursor")
            let wantNamed = width > (compact + named) / 2
            if wantNamed != Self.railNamed {
                Self.railNamed = wantNamed
                AppLog.note("mac", wantNamed ? "rail widened: bot names on" : "rail narrowed: faces alone")
                rebuild()
            }
            superview?.setNeedsLayout()
            superview?.layoutIfNeeded()
        default:
            Self.railDragWidth = nil
            window?.windowScene?.sizeRestrictions?.minimumSize = MacWindow.minimumSize
            guard let host = superview else { return }
            host.setNeedsLayout()
            HQMotion.animate(0.18, options: [.curveEaseOut, .beginFromCurrentState], changes: { host.layoutIfNeeded() })
        }
    }

    /// [sidebar-width] The open sidebar's edge follows the pointer between its narrowest and widest; let go, the width
    /// is kept. A double click puts the usual width back.
    private func openDragged(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            railDragStart = Self.openWidth
        case .changed:
            let moved = pan.translation(in: self).x * (effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1)
            Self.openDragWidth = min(max(railDragStart + moved, Self.narrowestOpen), Self.widestOpen)
            MacWindow.cursor("resizeLeftRightCursor")
            superview?.setNeedsLayout()
            superview?.layoutIfNeeded()
        default:
            if pan.state == .ended, let width = Self.openDragWidth {
                _ = width; Self.savedOpenWidth = Self.openWidth / max(Self.chrome, 0.01)   // as the window let it be
                AppLog.note("mac", "sidebar width \(Int(Self.openWidth))")
            }
            Self.openDragWidth = nil
            superview?.setNeedsLayout()
        }
    }

    @objc private func openWidthReset() {
        guard !Self.isCollapsed else { return }
        Self.savedOpenWidth = Self.defaultOpenWidth
        guard let host = superview else { return }
        host.setNeedsLayout()
        HQMotion.animate(0.18, options: [.curveEaseOut, .beginFromCurrentState], changes: { host.layoutIfNeeded() })
    }

    #if DEBUG
    /// MacShots: the open sidebar at `width` (in points at 100 %), as a drag would leave it; nil puts the usual one back.
    func debugOpenWidth(_ width: CGFloat?) {
        Self.savedOpenWidth = width ?? Self.defaultOpenWidth
        superview?.setNeedsLayout()
        superview?.layoutIfNeeded()
    }
    #endif

    /// The Mac's left-right arrows over the rail's edge, so it reads as something to drag.
    @objc private func railHovered(_ hover: UIHoverGestureRecognizer) {
        let over = hover.state == .began || hover.state == .changed
        MacWindow.cursor(over || Self.railDragWidth != nil || Self.openDragWidth != nil ? "resizeLeftRightCursor" : "arrowCursor")
    }

    #if DEBUG
    /// MacShots: the rail held at `width` as a drag would, or let go (nil) to settle.
    func debugDragRail(to width: CGFloat?) {
        if let width {
            Self.railDragWidth = width
            let wantNamed = width > (Self.compactRailWidth + Self.namedRailWidth) / 2
            if wantNamed != Self.railNamed { Self.railNamed = wantNamed; rebuild() }
        } else {
            Self.railDragWidth = nil
        }
        superview?.setNeedsLayout()
        superview?.layoutIfNeeded()
    }
    #endif

    /// Folds the sidebar to its icons or opens it out again; the panes slide over to fill the room.
    func toggleCollapsed() {
        if Self.isCollapsed {
            UserDefaults.standard.set(false, forKey: Self.collapsedKey)
            if Self.narrowWindow { Self.openedWhileNarrow = true }
        } else if Self.narrowWindow {
            Self.openedWhileNarrow = false   // folded for this narrow spell only: it opens again with a wider window
        } else {
            UserDefaults.standard.set(true, forKey: Self.collapsedKey)
        }
        AppLog.note("mac", Self.isCollapsed ? "sidebar folded" : "sidebar opened")
        // [sidebar-feel] The rows turned into icons (or back) at once and then the strip glided. Now a picture of the
        // sidebar as it was fades out over the new rows while the strip glides: one move.
        let ghost = window != nil && !HQMotion.reduced ? snapshotView(afterScreenUpdates: false) : nil
        rebuild()
        window?.windowScene?.sizeRestrictions?.minimumSize = MacWindow.minimumSize
        guard let host = superview else { return }
        if let ghost {
            let clip = UIView(frame: bounds)   // cut to the strip as it narrows
            clip.clipsToBounds = true
            clip.isUserInteractionEnabled = false
            clip.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            ghost.frame = clip.bounds
            ghost.autoresizingMask = effectiveUserInterfaceLayoutDirection == .rightToLeft ? .flexibleLeftMargin : .flexibleRightMargin
            clip.addSubview(ghost)
            addSubview(clip)
            UIView.performWithoutAnimation { settleLayout() }   // the new rows start in place, not from nowhere
            HQMotion.animate(0.15, options: [.curveEaseOut], changes: { ghost.alpha = 0 }, completion: { _ in clip.removeFromSuperview() })
        }
        HQMotion.animate(0.22, options: [.curveEaseInOut, .beginFromCurrentState], changes: { host.layoutIfNeeded() })
    }

    /// [mac] Stress test #13: the window's width folded or opened the sidebar; the rows follow and the window may shrink
    /// to the rail's minimum.
    func widthStateChanged() {
        AppLog.note("mac", Self.isCollapsed ? "sidebar folded for a narrow window" : "sidebar opened for a wider window")
        rebuild()
        window?.windowScene?.sizeRestrictions?.minimumSize = MacWindow.minimumSize
    }

    private func placeToggle() {
        let folded = Self.isCollapsed
        let size = ((folded ? 38 : 32) * Self.chrome).rounded()
        toggle.setImage(UIImage(systemName: "sidebar.left"), for: .normal)
        toggle.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: (folded ? 19 : 15) * Self.chrome, weight: .regular), forImageIn: .normal)
        toggle.accessibilityLabel = folded ? "Show Sidebar" : "Hide Sidebar"
        toggle.toolTip = "\(folded ? "Show Sidebar" : "Hide Sidebar") (⌃⌘S)"
        NSLayoutConstraint.deactivate(toggleSize + [toggleLeading, toggleCentre])
        toggleSize = [toggle.widthAnchor.constraint(equalToConstant: size), toggle.heightAnchor.constraint(equalToConstant: size)]
        NSLayoutConstraint.activate(toggleSize + [folded ? toggleCentre : toggleLeading])
        // [mac-sidebar] The + across the foot from the toggle, at its size; folded, the rail keeps the toggle alone (a
        // right click on it still offers Add to Sidebar ▸).
        addButton.setImage(UIImage(systemName: "plus"), for: .normal)
        addButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 15 * Self.chrome, weight: .regular), forImageIn: .normal)
        addButton.isHidden = folded
        NSLayoutConstraint.deactivate(addSize)
        addSize = [addButton.widthAnchor.constraint(equalToConstant: size), addButton.heightAnchor.constraint(equalToConstant: size)]
        NSLayoutConstraint.activate(addSize)
        // The gear at the toggle's size and weight: beside the + open, above the toggle on the folded rail.
        settingsButton.setImage(UIImage(systemName: "gearshape"), for: .normal)
        settingsButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: (folded ? 19 : 15) * Self.chrome, weight: .regular), forImageIn: .normal)
        NSLayoutConstraint.deactivate(settingsSize + settingsBesideAdd + settingsAboveToggle + [footBottom, footAboveSettings])
        settingsSize = [settingsButton.widthAnchor.constraint(equalToConstant: size), settingsButton.heightAnchor.constraint(equalToConstant: size)]
        NSLayoutConstraint.activate(settingsSize + (folded ? settingsAboveToggle + [footAboveSettings] : settingsBesideAdd + [footBottom]))
    }

    /// [mac-ui-issues] The add-on reminder's red dot on the gear (it was the count on More's Settings row, which the
    /// Mac no longer lists). VoiceOver and the tooltip say what it is for.
    func showSettingsDot(_ shown: Bool, spoken: String?) {
        if shown, settingsDot.superview == nil {
            settingsDot.backgroundColor = .systemRed
            settingsDot.layer.cornerRadius = 4
            settingsDot.isUserInteractionEnabled = false
            settingsDot.translatesAutoresizingMaskIntoConstraints = false
            settingsButton.addSubview(settingsDot)
            NSLayoutConstraint.activate([
                settingsDot.widthAnchor.constraint(equalToConstant: 8), settingsDot.heightAnchor.constraint(equalToConstant: 8),
                settingsDot.centerXAnchor.constraint(equalTo: settingsButton.centerXAnchor, constant: 9),
                settingsDot.centerYAnchor.constraint(equalTo: settingsButton.centerYAnchor, constant: -8),
            ])
        }
        settingsDot.isHidden = !shown
        settingsButton.accessibilityValue = shown ? spoken : nil
        settingsButton.toolTip = shown ? (spoken.map { "Settings (⌘,): \($0)" } ?? "Settings (⌘,)") : "Settings (⌘,)"
    }
    private let settingsDot = UIView()

    /// The selected tab changed (a click here, ⌘1…⌘5, a link that opened a chat).
    func selectionChanged() {
        guard let tabs else { return }
        let shown = tabs.selectedViewController
        for row in rows { row.isMarked = row.controller != nil && row.controller === shown }
        foldedTools?.isMarked = shown.map { tabs.pages?.isTool($0) ?? false } ?? false   // [mac-layout]
        markHeads()   // [bots-rail] a head is marked only while Bots is on show
        // [mac-sidebar] A place picked by ⌘9 or a link, below the fold of a long list, scrolls into view (in its own list:
        // Mac polish #27). A Tool on the folded rail is its Tools button.
        let marked = rows.first(where: { $0.isMarked && !$0.isHidden }) ?? foldedTools.flatMap({ $0.isMarked ? $0 : nil })
        if let marked, marked.isDescendant(of: footScroll) { reveal(marked) } else {
            footBackToTop()   // [Mac UI check 2026-11-13] V27
            if let marked { reveal(marked) }
        }
    }

    /// [mac] Stress test 2026-10-28 #54: the open tab's mark is the accent while the sidebar has the focus.
    func focusChanged() {
        rows.forEach { $0.recolor() }
        heads.values.forEach { $0.recolor() }   // [bots-rail]
        chatRows.values.forEach { $0.recolor() }   // [chats-under]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let panel = CGRect(x: Self.glassInset, y: Self.glassTop, width: max(0, bounds.width - 2 * Self.glassInset),
                           height: max(0, bounds.height - Self.glassInset - Self.glassTop))
        if glass.frame != panel { glass.frame = panel }
        // [rail-names] The rail's outer edge, a little either side of the panel's edge in the iOS look.
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let gripWidth: CGFloat = Self.solid ? 8 : Self.glassInset + 6
        railGrip.frame = CGRect(x: rightToLeft ? 0 : bounds.maxX - gripWidth, y: 0, width: gripWidth, height: bounds.height)
        railGrip.isHidden = false   // [sidebar-width] open, the same edge drags the sidebar's width
        bringSubviewToFront(railGrip)
        // [sidebar-width] Owner 2026-11-09 ("more room to breathe"): with Tools open the foot took its whole height and
        // left the bots their least, one bot and its chats in a tall window. The bots now keep what they need up to
        // half the sidebar; the places and Tools scroll in what is left.
        if showsBots {
            let content = stack.bounds.height + scroll.contentInset.top + scroll.contentInset.bottom
            // [Mac UI check 2026-11-13] The least and the half were measured with Search and New Chat inside the list,
            // which started just under the panel's top (or the gateway switcher). Now that they sit above it, the
            // list takes that much less, so the foot keeps the room it had (the folded rail in a short window lost
            // its Tools button to the bots' list, and "+" showed where it hadn't).
            let startedAt = railGateway.map { $0.frame.maxY + 4 } ?? Self.glassTop + 8
            let lead = max(0, (tools?.frame.maxY ?? startedAt) + stack.spacing - startedAt)
            let room = max(Self.botsMinHeight - lead, min(content, (bounds.height * 0.5).rounded() - lead))
            if abs(botsRoom.constant - room) > 0.5 { botsRoom.constant = room }
        }
        placeFade()
    }

    /// Each list's foot fades while rows lie below it, and its top while rows lie above it (Mac polish #51: a row
    /// scrolled under the top was cut through on a hard line); scrolled to that end (or all in view) it is drawn whole.
    private func placeFade() {
        // Owner 2026-11-09 on Mac 915: the Tools list "can scroll left to right a little - not just up and down".
        // The sidebar's lists only ever move up and down: a sideways nudge from the trackpad is put straight back.
        for list in [scroll, footScroll] where list.contentOffset.x != 0 { list.contentOffset.x = 0 }
        Self.fadeEdges(of: scroll, with: fade, heading: loneHeading())
        Self.fadeEdges(of: footScroll, with: footFade)
    }

    /// After Mac polish #33 (Marketplace made the Tools one row longer): in a standard window the bots' list stopped on
    /// a group's heading (Unassigned) with its one bot a ghost under the fade, or out of sight, so the group read as
    /// empty. The foot fade starts above such a heading instead, so the list ends on the bot above it and the heading
    /// fades out as more to scroll to (`SidebarRules.headingFade`). The places and Tools stay whole.
    private func loneHeading() -> (start: CGFloat, end: CGFloat)? {
        guard showsBots, !Self.isCollapsed else { return nil }
        let rows = botsStack.arrangedSubviews.filter { !$0.isHidden }.map { view in
            let frame = view.convert(view.bounds, to: stack)
            return SidebarRules.ListRow(top: frame.minY, bottom: frame.maxY, heading: view is MacSidebarHeading)
        }
        return SidebarRules.headingFade(rows: rows, top: scroll.contentOffset.y, height: scroll.bounds.height,
                                        below: scroll.contentSize.height - (scroll.contentOffset.y + scroll.bounds.height))
    }

    private static func fadeEdges(of list: UIScrollView, with mask: CAGradientLayer, heading: (start: CGFloat, end: CGFloat)? = nil) {
        let height = list.bounds.height
        guard height > 0 else { return }
        let fades = SidebarRules.fadeStops(above: list.contentOffset.y + list.contentInset.top,
                                           below: list.contentSize.height + list.contentInset.bottom - (list.contentOffset.y + height),
                                           height: height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let fades {
            mask.frame = list.bounds   // the scroll view's bounds move as it scrolls; the mask moves with them
            // A lone heading at the foot: clear from its foot down, faded across it (`loneHeading`).
            let bottom = heading.map { max(fades.top, $0.start / height) } ?? fades.bottom
            let gone = heading.map { min(1, max(bottom, $0.end / height)) } ?? 1
            mask.colors = [fades.top > 0 ? UIColor.clear.cgColor : UIColor.black.cgColor, UIColor.black.cgColor,
                           UIColor.black.cgColor, fades.bottom < 1 ? UIColor.clear.cgColor : UIColor.black.cgColor,
                           fades.bottom < 1 ? UIColor.clear.cgColor : UIColor.black.cgColor]
            mask.locations = [0, NSNumber(value: Double(fades.top)), NSNumber(value: Double(bottom)), NSNumber(value: Double(gone)), 1]
            if list.layer.mask !== mask { list.layer.mask = mask }
        } else if list.layer.mask != nil {
            list.layer.mask = nil
        }
        CATransaction.commit()
    }

    private func recolor() {
        let desktop = Self.solid   // [sidebar-solid] the iOS look's strip is solid too: no glass, no page round it
        if desktop { backgroundColor = Self.background } else { followNeighbour() }
        // [glass-mac] The glass in the iOS look only.
        // [sidebar-light] Owner 2026-11-03: in light mode "it's all white behind it… you can't really tell that there's this
        // like floating sidebar": clear glass over a white page drew white (and black over iOS dark's black). It carries
        // the theme's page colour a step towards its ink now (`glassTintColor`), with a hairline edge (`cardEdge`), so it
        // reads as a panel on any page and in every theme.
        if desktop {
            if glass.effect != nil { glass.effect = nil }
        } else {
            let tint = Self.glassTintColor
            if !(glass.effect is UIGlassEffect) || glassTint != tint.resolvedColor(with: traitCollection) {
                let effect = UIGlassEffect(style: .regular)
                effect.tintColor = tint
                glass.effect = effect
                glassTint = tint.resolvedColor(with: traitCollection)
            }
        }
        // The glass's own sheen lifts whatever is under it towards white in light mode (measured: 255 on a 243 page in
        // iOS System, 245 on 242 in Nous), so the tint is laid over it as well, not only given to the effect.
        glass.contentView.backgroundColor = desktop ? nil : Self.glassTintColor
        glass.layer.cornerRadius = Self.glassRadius
        glass.layer.cornerCurve = .continuous
        // Owner 2026-11-04 ("the corners look like something is wrong"): the tint above filled the panel's square, so
        // each corner showed a square behind the rounded edge. It keeps to the panel's curve now.
        glass.contentView.layer.cornerRadius = Self.glassRadius
        glass.contentView.layer.cornerCurve = .continuous
        glass.contentView.layer.masksToBounds = true
        glass.layer.borderWidth = desktop ? 0 : 1 / max(1, traitCollection.displayScale)
        glass.layer.borderColor = HQPalette.cardEdge.resolvedColor(with: traitCollection).cgColor
        glass.isHidden = desktop
        edge.isHidden = !desktop
        let inset = Self.contentInset
        if stackLeading.constant != inset {
            stackLeading.constant = inset
            stackTrailing.constant = -inset
            toggleLeading.constant = inset
            addTrailing.constant = -inset
            toggleBottom.constant = -inset
        }
        edge.backgroundColor = HQPalette.paneLine   // stress test #26: neutral, as the divider between the panes
        toggle.tintColor = HQPalette.label   // [mac] stress test #65: label 2 on the iOS look's grey was about 2:1
        addButton.tintColor = HQPalette.label
        settingsButton.tintColor = HQPalette.label
        dropLine.backgroundColor = tintColor
        selectionChanged()
        rows.forEach { $0.recolor() }
        heads.values.forEach { $0.recolor() }   // [bots-rail]
        chatRows.values.forEach { $0.recolor() }   // [chats-under]
        railAdd?.recolor()
        (stack.arrangedSubviews + botsStack.arrangedSubviews + foot.arrangedSubviews + footEdge.subviews).compactMap { $0 as? MacRailLine }.forEach { $0.recolor() }
        botsStack.arrangedSubviews.compactMap { $0 as? MacSidebarHeading }.forEach { $0.recolor() }
        botsStack.arrangedSubviews.compactMap { $0 as? MacSidebarEmptyHint }.forEach { $0.recolor() }
        tools?.recolor()
    }

    /// [sidebar-light] A pane beside the strip laid out (a page pushed or popped, the list folded or opened).
    static let neighbourMayChange = Notification.Name("hq.macSidebar.neighbourMayChange")

    /// Once per turn of the run loop however many panes laid out.
    private func followNeighbourSoon() {
        neighbourRetries = max(neighbourRetries, 8)
        guard !neighbourPending else { return }
        neighbourPending = true
        DispatchQueue.main.async { [weak self] in
            self?.neighbourPending = false
            self?.followNeighbour()
        }
    }

    /// [sidebar-light] Owner 2026-11-03: behind the panel "it's all white… it's not the background color of the rest of
    /// the app". In the iOS look the strip round the glass panel showed the window's plain page whatever was beside it,
    /// so beside a grouped page (Settings, Bot Info: grey) it was a white band. It takes the colour drawn just past its
    /// edge now, read from the window itself (one point at the page's top, after a pane laid out): a view's own colour there can sit
    /// under another (Nous dark's Settings read 30 where the page drew 13).
    private func followNeighbour() {
        guard !Self.solid else { return }
        guard let window, !bounds.isEmpty else { fallBackToPage(); return }
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        // 16 pt past the edge and 20 down, over the glass panel's top: clear of its shadow, which reaches past the strip
        // (it read 237 beside a 254 list), and above any row, bubble or card in the page.
        let point = convert(CGPoint(x: rightToLeft ? bounds.minX - 16 : bounds.maxX + 16, y: 20), to: window)
        guard window.bounds.contains(point) else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        var pixel = [UInt8](repeating: 0, count: 4)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { _ in
            _ = window.drawHierarchy(in: CGRect(origin: CGPoint(x: -point.x, y: -point.y), size: window.bounds.size), afterScreenUpdates: false)
        }
        guard let cg = image.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let read = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        read.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        // A window that hasn't drawn yet (just opened, or behind another) reads as pure black: keep the page's own colour
        // and try again shortly, unless the page really is black (iOS dark). Mac polish #56: in light mode anything near
        // black too (mid-draw, the folded rail got a near-black frame).
        if SidebarRules.undrawn(red: pixel[0], green: pixel[1], blue: pixel[2], light: traitCollection.userInterfaceStyle != .dark,
                                pageIsBlack: Self.pageIsBlack(traitCollection), picture: Backdrop.app.shows) {
            fallBackToPage()
            if neighbourRetries > 0 {
                neighbourRetries -= 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.followNeighbour() }
            }
            return
        }
        let next = UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
        if backgroundColor != next { backgroundColor = next }
    }

    /// Until the page beside it can be read, the strip is the theme's page colour (never black or clear).
    private func fallBackToPage() {
        let page = HQPalette.page.resolvedColor(with: traitCollection)
        if backgroundColor == nil || backgroundColor == .clear || isBlack(backgroundColor) { backgroundColor = page }
    }

    private func isBlack(_ color: UIColor?) -> Bool {
        guard let color else { return false }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let byte = { (value: CGFloat) in UInt8(max(0, min(255, (value * 255).rounded()))) }
        return SidebarRules.undrawn(red: byte(r), green: byte(g), blue: byte(b), light: traitCollection.userInterfaceStyle != .dark,
                                    pageIsBlack: Self.pageIsBlack(traitCollection))
    }

    private static func pageIsBlack(_ traits: UITraitCollection) -> Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        HQPalette.page.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return r < 0.02 && g < 0.02 && b < 0.02
    }

    /// [sidebar-light] The glass panel's tint: the page's colour 5 % of the way to its ink in light, 9 % in dark (where a
    /// step reads smaller), nearly opaque, so the panel is the page's own hue, a shade apart from it.
    static let glassTintColor = UIColor { @Sendable traits in
        let dark = traits.userInterfaceStyle == .dark
        var page = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0)), ink = page
        HQPalette.page.resolvedColor(with: traits).getRed(&page.r, green: &page.g, blue: &page.b, alpha: &page.a)
        HQPalette.label.resolvedColor(with: traits).getRed(&ink.r, green: &ink.g, blue: &ink.b, alpha: &ink.a)
        let t: CGFloat = dark ? 0.14 : 0.10
        return UIColor(red: page.r + (ink.r - page.r) * t, green: page.g + (ink.g - page.g) * t,
                       blue: page.b + (ink.b - page.b) * t, alpha: 0.85)
    }

    /// The strip's colour: the solid panel (`panelColor`); while the glass panel floats, the page beside it shows round it.
    static var background: UIColor { solid ? panelColor : .clear }

    /// What the rows sit on: the Desktop Look's raised panel, or the glass panel's tint made solid (Mac polish #55: what
    /// a face's badges are ringed in here).
    static var panelColor: UIColor {
        Theme.isDesktop ? ChatPalette.sidebar : UIColor { glassTintColor.resolvedColor(with: $0).withAlphaComponent(1) }
    }
}

// MARK: Editing in place ([mac-sidebar])

extension MacSidebar: UIContextMenuInteractionDelegate, UIDragInteractionDelegate, UIDropInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        // [bots-rail] A head's menu is its row's in the Bots list. [rail-more] A group chat's too (Group Info, Pin…).
        if let heading = interaction.view as? MacSidebarHeading, let id = heading.sectionId {
            return tabs?.botsViewController.organizer?.sectionContextMenu(id)
        }
        // [Mac UI check 2026-11-13] A chat under its bot: that chat's own actions (Pin, Rename…, Move to Project,
        // Archive, Delete…), the same menu its row in Sessions has. "N more" keeps the sidebar's menu.
        if let chat = interaction.view as? MacSidebarChat, let session = chat.session {
            guard let organizer = tabs?.sessionsViewController.organizer else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak organizer, weak chat] _ in
                guard let organizer, let chat else { return nil }
                return organizer.uiMenu(for: session, anchor: chat)
            }
        }
        if let head = interaction.view as? MacRailHead {
            switch head.item {
            case .bot(let bot): return tabs?.botsViewController.organizer?.contextMenu(for: bot)
            case .room(let room):
                guard let host = tabs?.botsViewController, let groups = tabs?.services as? GroupServices else { return nil }
                return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak host, weak head] _ in
                    guard let host else { return nil }
                    // Mac polish #31: the list's own room menu, with its Move to Section.
                    return BotMenuNode.uiMenu(host.roomMenuNodes(room, services: groups, source: { head }), title: room.name).menu
                }
            }
        }
        let hit = row(at: interaction.view.map { $0.convert(location, to: self) } ?? location)
        // [mac-layout] A tool's menu: make it one of the places (it leaves Tools for Settings › Tabs' list).
        if let hit, let controller = rows[hit.index].controller, tabs?.pages?.isTool(controller) == true, let choice = hit.choice {
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                UIMenu(children: [UIAction(title: "Move to Places", image: UIImage(systemName: "arrow.up.to.line")) { _ in
                    SidebarEditing.add(choice)
                }])
            }
        }
        // [rail-more] Folded, a right click on the rail's empty space offers the gateways too (with more than one).
        let gateways = Self.isCollapsed && hit == nil ? tabs?.botsViewController.gatewaySwitcher.flatMap { $0.isActive ? $0 : nil } : nil
        // Mac polish #30: and the bots' Sort By and Group By, which the sidebar's bots follow (the Bots list's Filter
        // button, where they live, is never on show on the Mac).
        let bots = hit == nil && showsBots ? tabs?.botsViewController : nil
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self, weak bots] _ in
            if let hit { return SidebarEditing.rowMenu(for: hit.choice) }
            var lead: [UIMenuElement] = []
            if let gateways { lead.append(UIMenu(title: "Gateways", image: UIImage(systemName: "network"), children: gateways.menu([]).children)) }
            if let bots, case let arrange = bots.arrangeMenus(changed: { self?.botsChanged() }), !arrange.isEmpty {
                // [chats-under] And Chats Under Bots, from the same Filter menu.
                lead.append(UIMenu(options: .displayInline, children: arrange + [bots.chatsUnderMenu()]))
            }
            // [mac] Filter › Show Hidden Bots: the hidden bots under a Hidden heading.
            if let bots, let hidden = bots.showHiddenAction(changed: { self?.botsChanged() }) {
                lead.append(UIMenu(options: .displayInline, children: [hidden]))
            }
            return UIMenu(children: lead + SidebarEditing.spaceMenu().children)
        }
    }

    // A row's drag carries its place (`TabChoice`); only within this app, only onto this sidebar.
    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        // [rail-more] A bot's head: moved among the heads (`railDrop`), as its row is in the list. Mac polish #31: a group
        // chat's: filed into a section (`roomDrop`), as its row is.
        if let head = interaction.view as? MacRailHead {
            guard tabs?.botsViewController.organizer?.editing != nil else { return [] }
            let item = UIDragItem(itemProvider: NSItemProvider())
            item.localObject = MacBotsRail.DragBox(key: head.item.key)
            return [item]
        }
        guard let row = interaction.view as? Row, let tag = row.controller?.tabBarItem.tag, let choice = TabChoice(tag: tag) else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = SidebarEditing.DragBox(choice: choice)
        return [item]
    }

    func dragInteraction(_ interaction: UIDragInteraction, sessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool { true }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        let box = session.localDragSession?.items.first?.localObject
        return box is SidebarEditing.DragBox || box is MacBotsRail.DragBox
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        if let bot = railDragBot(session) {   // [rail-more]
            guard interaction.view !== foot, let landing = railLanding(bot, at: session.location(in: stack).y) else {
                dropLine.isHidden = true
                return UIDropProposal(operation: .forbidden)
            }
            showRailDropLine(landing)
            return UIDropProposal(operation: .move)
        }
        if let room = railDragRoom(session) {   // Mac polish #31
            guard interaction.view !== foot, let landing = roomLanding(room, at: session.location(in: stack).y) else {
                dropLine.isHidden = true
                return UIDropProposal(operation: .forbidden)
            }
            showRoomDropLine(landing.block)
            return UIDropProposal(operation: .move)
        }
        guard let gap = dropGap(session) else { dropLine.isHidden = true; return UIDropProposal(operation: .cancel) }
        showDropLine(at: gap)
        return UIDropProposal(operation: .move)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) { dropLine.isHidden = true }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) { dropLine.isHidden = true }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        dropLine.isHidden = true
        if let bot = railDragBot(session) {   // [rail-more]
            if interaction.view !== foot, let landing = railLanding(bot, at: session.location(in: stack).y) { railDrop(bot, landing) }
            return
        }
        if let room = railDragRoom(session) {   // Mac polish #31
            if interaction.view !== foot, let landing = roomLanding(room, at: session.location(in: stack).y) { roomDrop(room, landing) }
            return
        }
        guard let box = session.localDragSession?.items.first?.localObject as? SidebarEditing.DragBox, let gap = dropGap(session) else { return }
        let placed = dropRows.compactMap { $0.controller.flatMap { TabChoice(tag: $0.tabBarItem.tag) } }
        SidebarEditing.move(box.choice, before: gap < placed.count ? placed[gap] : nil)
    }

    /// The place rows a dragged place can land between: the ones on show that Settings › Tabs orders. Bots' row is
    /// built but never shown here and the Tools keep their own order, so neither counts (with Bots first in the list,
    /// its missing superview cancelled every drop).
    private var dropRows: [Row] {
        let order = TabOrder.tabs
        return rows.filter { row in
            guard row.superview != nil, !row.isTool, let choice = row.controller.flatMap({ TabChoice(tag: $0.tabBarItem.tag) }) else { return false }
            return order.contains(choice)
        }
    }

    /// The gap between Settings › Tabs places (More stays last) nearest the pointer: 0 above the first, n below the last.
    private func dropGap(_ session: UIDropSession) -> Int? {
        let placed = dropRows
        guard !placed.isEmpty else { return nil }
        guard let host = placed[0].superview else { return nil }
        let y = session.location(in: host).y   // the foot's stack, or the scrolling one
        return placed.firstIndex { y < $0.frame.midY } ?? placed.count
    }

    private func showDropLine(at gap: Int) {
        let placed = dropRows
        guard !placed.isEmpty else { return }
        guard let host = placed[0].superview as? UIStackView else { return }
        let y = gap < placed.count ? placed[gap].frame.minY - host.spacing / 2 : placed[placed.count - 1].frame.maxY + host.spacing / 2
        // The places sit in the fixed foot while the bots are in the sidebar: the line is drawn over the strip there,
        // not in the scrolling list (whose clip would hide it).
        let canvas: UIView = host === foot ? self : scroll
        if dropLine.superview !== canvas { canvas.addSubview(dropLine) }
        dropLine.frame = host.convert(CGRect(x: 6, y: y - 1, width: host.bounds.width - 12, height: 2), to: canvas)
        dropLine.layer.cornerRadius = 1
        dropLine.backgroundColor = tintColor
        dropLine.isHidden = false
        canvas.bringSubviewToFront(dropLine)
    }

    // MARK: Moving a head ([rail-more])

    /// The bot a head's drag carries, as the roster has it now.
    private func railDragBot(_ session: UIDropSession) -> Bot? {
        guard let box = session.localDragSession?.items.first?.localObject as? MacBotsRail.DragBox else { return nil }
        return heads[box.key]?.bot
    }

    /// The group chat a head's drag carries (Mac polish #31).
    private func railDragRoom(_ session: UIDropSession) -> GroupRowModel? {
        guard let box = session.localDragSession?.items.first?.localObject as? MacBotsRail.DragBox else { return nil }
        return heads[box.key]?.item.room
    }

    /// Mac polish #31: where a dragged group chat would be filed: the group of heads under the pointer, by the list's
    /// rule for a room's drop (`GroupList.drop`): a section files it there, the bots' own group or Group Chats takes it
    /// out of its section. nil: no drop there (the pins), or it is filed there already. Its place in the group is the
    /// list's (by activity), so the line goes under the group.
    func roomLanding(_ room: GroupRowModel, at y: CGFloat) -> (block: BotListSectionID, section: String?)? {
        let shown = shownHeads
        guard let under = shown.first(where: { y < frameOf($0).maxY }) ?? shown.last,
              case .section(let section)? = GroupList.drop(room: true, over: under.block), section != room.sectionId else { return nil }
        return (under.block, section)
    }

    func roomDrop(_ room: GroupRowModel, _ landing: (block: BotListSectionID, section: String?)) {
        guard let store = (tabs?.services as? GroupServices)?.groupStore else { return }
        Haptics.play(.light)
        store.setSection(room.id, landing.section)   // on this device, as the list's drop
        AppLog.note("mac", "rail: group chat moved to \(landing.block)")
        HQAnnounce.say("\(room.name), moved")
    }

    /// The drop line under the last head of `block`, where a dragged group chat would go.
    private func showRoomDropLine(_ block: BotListSectionID) {
        guard let last = shownHeads.last(where: { $0.block == block }) else { dropLine.isHidden = true; return }
        drawRailDropLine(at: frameOf(last).maxY + stack.spacing / 2)
    }

    /// Where a dragged head would land, `y` down the heads' stack: before the head whose middle is below it, in that
    /// head's list block, or after the last head of the block above when the pointer is in the gap between groups.
    /// `rows`: that block's bots in their new order (`block` .tiles: the tiles'). nil: no drop there, by the list's own
    /// rules (`BotsOrganizer.rowLanding`): group chats, a pin filed into a section, a hidden bot, a read-only gateway.
    struct RailLanding: Equatable {
        var block: BotListSectionID
        var index: Int
        var rows: [String]
        /// The head the line sits above (nil: below the block's last head).
        var before: String?
        var after: String?
    }

    func railLanding(_ bot: Bot, at y: CGFloat) -> RailLanding? {
        guard let organizer = tabs?.botsViewController.organizer, let editing = organizer.editing else { return nil }
        let shown = shownHeads
        guard let source = heads[bot.id]?.block, !shown.isEmpty else { return nil }
        // [mac] Over an empty section (its heading or hint): filed there, as a drop on the list's empty section.
        if let empty = emptySection(at: y) {
            let block = BotListSectionID.user(empty)
            guard block != source, !bot.pinned, !bot.hidden, !editing.isReadOnly, organizer.target(for: block) != nil else { return nil }
            return RailLanding(block: block, index: 0, rows: [bot.id], before: nil, after: nil)
        }
        // The head the drop goes before, and the block it lands in.
        var block: BotListSectionID
        var beforeKey: String?
        if let next = shown.firstIndex(where: { y < self.frameOf($0).midY }) {
            let head = shown[next]
            // Above a group's first head, in the gap (the line between groups) or the head above's lower half: the end
            // of the block above.
            if next > 0, shown[next - 1].block != head.block, y < frameOf(head).minY {
                block = shown[next - 1].block
            } else {
                block = head.block
                beforeKey = head.item.key
            }
        } else {
            block = shown[shown.count - 1].block
        }
        // The Pinned section's rows follow the tiles in one group: past the tiles they are their own block.
        let members = shown.filter { $0.block == block }.compactMap(\.bot).map(\.id)
        guard !members.isEmpty || block == source else { return nil }
        if block != source {
            switch block {
            case .tiles: guard !bot.hidden else { return nil }   // a bot dropped among the tiles is pinned
            case .pinned, .user, .unassigned: guard !bot.pinned, !bot.hidden, !editing.isReadOnly, organizer.target(for: block) != nil else { return nil }
            default: return nil
            }
        } else if !(BotsOrganizer.isOrderedBlock(block) || block == .tiles) {
            return nil
        }
        // Its place among the block's bots (a group chat's tile after them counts as the end).
        var index = beforeKey.flatMap { members.firstIndex(of: $0) } ?? members.count
        if let from = members.firstIndex(of: bot.id), from < index { index -= 1 }
        var rows = members.filter { $0 != bot.id }
        index = min(index, rows.count)
        rows.insert(bot.id, at: index)
        // Where it is now: no drop line, nothing to do.
        if block == source, rows == members { return nil }
        return RailLanding(block: block, index: index, rows: rows,
                           before: index + 1 < rows.count ? rows[index + 1] : nil, after: index > 0 ? rows[index - 1] : nil)
    }

    /// [mac] The empty section whose heading or hint is at `y` in the rows' stack.
    private func emptySection(at y: CGFloat) -> String? {
        let views = botsStack.arrangedSubviews
        for (index, view) in views.enumerated() {
            guard let hint = view as? MacSidebarEmptyHint else { continue }
            var area = frameOf(hint)
            if index > 0, let heading = views[index - 1] as? MacSidebarHeading, heading.sectionId == hint.sectionId {
                area = area.union(frameOf(heading))
            }
            if y >= area.minY, y < area.maxY { return hint.sectionId }
        }
        return nil
    }

    /// The drop: within its block the head takes its new place (the tiles' order, or the rows' and Sort By › Manual,
    /// both kept on this device); into another block it is filed there first (Pin, or Move to Section), as a row
    /// dropped on another block of the list is (`BotsOrganizer.dropRow`).
    func railDrop(_ bot: Bot, _ landing: RailLanding) {
        guard let tabs, let organizer = tabs.botsViewController.organizer, let editing = organizer.editing else { return }
        let source = heads[bot.id]?.block
        if landing.block == .tiles {
            if source == .tiles {
                let before = shownHeads.filter { $0.block == .tiles }.compactMap(\.bot).map(\.id)
                Haptics.play(.light)
                editing.placeTiles(before: before, after: landing.rows)
            } else if bot.pinned {
                // A pin past the six takes the place of the tile it was dropped before (the last one at the end).
                organizer.drop(bot, on: .tiles, slot: min(landing.index, max(landing.rows.count - 2, 0)))
            } else {
                organizer.drop(bot, on: .tiles)
            }
        } else {
            if landing.block != source, let target = organizer.target(for: landing.block) { organizer.drop(bot, on: target) }
            else { Haptics.play(.light) }
            organizer.placeRows(landing.rows, in: landing.block)   // [pinned-rows] the pins' rows keep the pins' order
        }
        AppLog.note("mac", "rail: \(bot.id) moved to \(landing.block) place \(landing.index + 1)")
        HQAnnounce.say("\(bot.name), \(landing.index + 1) of \(landing.rows.count)")
        tabs.botsViewController.setNeedsReload()
    }

    /// The open sidebar's drop line, between the heads where the drag would land.
    private func showRailDropLine(_ landing: RailLanding) {
        let shown = shownHeads
        let y: CGFloat
        if let before = landing.before, let head = shown.first(where: { $0.item.key == before }) {
            y = frameOf(head).minY - stack.spacing / 2
        } else if let after = landing.after, let head = shown.first(where: { $0.item.key == after }) {
            y = frameOf(head).maxY + stack.spacing / 2
        } else if let head = shown.first(where: { $0.block == landing.block }) {
            y = frameOf(head).minY - stack.spacing / 2
        } else if case .user(let id) = landing.block,
                  let hint = botsStack.arrangedSubviews.first(where: { ($0 as? MacSidebarEmptyHint)?.sectionId == id }) {
            y = frameOf(hint).minY   // [mac] an empty section: the line where its first bot will be
        } else {
            dropLine.isHidden = true
            return
        }
        drawRailDropLine(at: y)
    }

    private func drawRailDropLine(at y: CGFloat) {
        if dropLine.superview !== scroll { scroll.addSubview(dropLine) }
        // Above the first head it would sit on the scroll view's clipped edge: just inside it.
        dropLine.frame = stack.convert(CGRect(x: 6, y: max(y - 1, 0), width: stack.bounds.width - 12, height: 2), to: scroll)
        dropLine.layer.cornerRadius = 1
        dropLine.backgroundColor = tintColor
        dropLine.isHidden = false
        scroll.bringSubviewToFront(dropLine)
    }
}

/// One tab: symbol, name, count. A button, so Full Keyboard Access and VoiceOver reach it as the tab bar's were.
/// Folded, the symbol alone, centred, with a dot for a count.
private final class Row: UIControl {
    private let icon = TabIconView()
    #if DEBUG
    var debugIcon: UIView { icon }
    var title: String? { item.title }
    #endif
    private let label = UILabel()
    private let count = UILabel()
    private let dot = UIView()
    private let folded: Bool
    /// [rail-names] In the named rail: the icon with its name under it.
    private let named: Bool
    let item: UITabBarItem
    private var hovered = false
    private var labelBeforeCount: NSLayoutConstraint?
    private var labelBeforeEdge: NSLayoutConstraint?

    var badge: String? { didSet { showBadge() } }
    /// [mac-sidebar] The place this row shows (one of `MainTabController.placedTabs`).
    weak var controller: UIViewController?
    var isMarked = false { didSet { if isMarked != oldValue { recolor() } } }
    /// [sidebar-tidy] One of Tools' pages: its name a step quieter than a bot's or a place's (owner 2026-11-10 liked
    /// "tools dimmer than bots so the bots lead"), still far above the label-2 grey that read at about 2:1 here.
    var isTool = false { didSet { if isTool != oldValue { recolor() } } }
    static let toolInk: CGFloat = 0.74

    init(item: UITabBarItem, shortcut: Int?, folded: Bool, named: Bool = false) {
        self.item = item
        self.folded = folded
        self.named = named
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityIdentifier = item.accessibilityIdentifier
        accessibilityLabel = item.title
        // Mac polish #50: every row names itself under the pointer, a name cut short too.
        toolTip = shortcut.map { "\(item.title ?? "") (⌘\($0))" } ?? item.title
        layer.cornerCurve = .continuous
        icon.contentMode = .center
        // The tab bar's drawn glyphs (Bots, Kanban) are sized for its 23.5 pt symbols; here they match the row's.
        let drawn = MacSidebar.rowIcon(item.image, folded: folded)
        icon.icon = drawn.image
        let iconSize = MacSidebar.iconSize(folded: folded)
        // Always, as the Desktop Look bar does: the idle Jobs icon is a drawn image whose stand-in here is the plain
        // `calendar.badge.clock` symbol, so a test on the tab's own image left it at the default size, a size jump
        // from the running icon's still (stress test 2026-10-31). Drawn glyphs ignore the configuration.
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: drawn.pointSize, weight: .regular)
        label.font = MacSidebar.font(MacSidebar.placeSize)   // the rows are made again when UI Scale changes (`rebuild`)
        label.text = item.title
        count.font = MacSidebar.font(MacSidebar.sized(15, 16))
        count.textAlignment = .right
        let dotSize = (7 * MacSidebar.chrome).rounded()
        dot.layer.cornerRadius = dotSize / 2
        // Folded, the name and count stay out (their constraints don't fit a 72 pt row); the tip names the tab.
        for view in (named ? [icon, label, dot] : folded ? [icon, dot] : [icon, label, count, dot]) as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            folded ? icon.centerXAnchor.constraint(equalTo: centerXAnchor)
                : icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacSidebar.iconLeading),
            icon.widthAnchor.constraint(equalToConstant: (iconSize * 1.5).rounded()),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: named ? -(9 * MacSidebar.chrome).rounded() : 0),
            dot.widthAnchor.constraint(equalToConstant: dotSize), dot.heightAnchor.constraint(equalToConstant: dotSize),
            dot.centerXAnchor.constraint(equalTo: icon.trailingAnchor, constant: -2),
            dot.centerYAnchor.constraint(equalTo: icon.centerYAnchor, constant: -(iconSize / 2).rounded()),
        ])
        // Mac polish #50: a longer name shrinks a little before it is cut short ("Status & Maintenance" in the iOS look's
        // narrower rows), as the named rail's do (`recolor` sets how far).
        label.adjustsFontSizeToFitWidth = !folded || named
        if named {
            label.textAlignment = .center
            label.lineBreakMode = .byTruncatingTail
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: icon.centerYAnchor, constant: (iconSize / 2 + 5).rounded()),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            ])
        }
        // [sidebar-feel] One name column down the sidebar: a place's name starts where the bots' names do
        // (`MacBotsRail.nameLeading`), not 4 pt short of them (the bots' faces are wider than these icons, so their
        // names had moved over and the places' had not). The count ends on the edge the headings' chevrons and a
        // bot's "Working…" end on.
        if !folded { NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacBotsRail.nameLeading), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacSidebar.edgeInset), count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]) }
        // [mac-sidebar] Without a count the name may run to the row's end: a page's longer name ("Status & Maintenance")
        // fit the glass panel's narrower rows only cut short.
        labelBeforeCount = count.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8)
        labelBeforeEdge = label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
        badge = item.badgeValue
        showBadge()   // [mac] stress test #65: `didSet` doesn't run in init, so every row kept a dot and no count
        recolor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func image(_ item: UITabBarItem, folded: Bool) -> UIImage? { MacSidebar.rowIcon(item.image, folded: folded).image }

    func imageChanged() { icon.icon = Self.image(item, folded: folded); showBadge() }   // "N running" comes with it

    /// [tabmotion] The icon's tap motion (`TabMotion`).
    func playMotion() { TabMotion.play(in: icon, source: icon.icon) }

    private func showBadge() {
        count.text = badge
        count.isHidden = folded || (badge ?? "").isEmpty
        if !folded {
            labelBeforeCount?.isActive = !count.isHidden
            labelBeforeEdge?.isActive = count.isHidden
        }
        dot.isHidden = !folded || (badge ?? "").isEmpty
        accessibilityValue = (badge ?? "").isEmpty ? item.accessibilityValue : "\(badge ?? "") new"
    }

    @objc private func hover(_ recognizer: UIHoverGestureRecognizer) {
        hovered = recognizer.state == .began || recognizer.state == .changed
        recolor()
    }

    override var isHighlighted: Bool { didSet { recolor() } }

    func recolor() {
        icon.tintColor = isMarked ? tintColor : HQPalette.label2
        label.textColor = isTool && !isMarked && !folded && MacSidebar.tidy ? HQPalette.label.withAlphaComponent(Self.toolInk) : HQPalette.label
        label.font = MacSidebar.font(named ? 13.5 : MacSidebar.placeSize, weight: isMarked ? .semibold : .regular)
        label.minimumScaleFactor = MacSidebar.shrink(label.font, least: named ? 0.8 : 0.85)
        count.textColor = HQPalette.label2
        dot.backgroundColor = tintColor
        // [mac] Stress test 2026-10-28 #54: the window's one source-list mark (`MacSelection`), its corners too.
        backgroundColor = MacSelection.fill(selected: isMarked, pressed: isHighlighted, in: .sidebar) ?? (hovered ? Self.hoverFill : .clear)
        layer.cornerRadius = MacSelection.radius
        accessibilityTraits = isMarked ? [.button, .selected] : .button
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        recolor()
    }

    static let hoverFill = UIColor { traits in UIColor.label.resolvedColor(with: traits).withAlphaComponent(0.05) }
}

#endif
