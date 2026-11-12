// [m9/ipad] The signed-in root on iPad (docs/spec/3x-ipad.md §4.3-§4.5): the phone's tab controller on the leading
// side and one detail stack beside it when the window is at least 768 pt wide and more than 500 pt tall (the web
// app's phone query, `src/ui-kit/phone.ts`); the phone layout in any narrower or shorter window. Telegram's iPad
// shape. Only system pieces draw here (the system tab bar and navigation bars, one separator hairline). On iPhone
// the window's root stays `MainTabController`.

import UIKit

final class RootSplitController: UIViewController {
    let tabs: MainTabController
    /// The right pane's stack. Its first screen is the placeholder whenever nothing is open.
    let detail = DetailNavigationController()
    private let hairline = UIView()
    private(set) var layout: PaneLayout = .single
    private var lastSize = CGSize.zero
    /// The app is in the background, where the window's size is the system's own (see `applyLayout`).
    private var away = false
    /// A change between one pane and two waits for the app to come back.
    private var heldLayout = false
    /// The list stack the right pane's content was opened from (a collapse puts the content back over it).
    private(set) weak var origin: UINavigationController?
    /// The right pane changed (the lists mark the row of the chat on show).
    var onDetailChange: (() -> Void)?
    #if targetEnvironment(macCatalyst)
    /// [mac] The list pane is wider on the Mac to start with (the Mac draws the app at 77 %, so the iPad's 375 pt was
    /// 289 pt on its screen), and the line between the panes drags it wider or narrower; the width is remembered.
    static let listWidthKey = "HQListPaneWidth"
    private let grip = UIView()
    private var dragStart: CGFloat = 0
    private var dragWidth: CGFloat?
    /// [mac] Stress test 2026-10-28 #63: below this window width (a laptop's ~1000 pt window is 1299 here) a 440 pt
    /// list left the chat the smallest share, so the list starts at the narrowest (320) there, and a drag in a window
    /// that narrow is kept apart from the wide one's (`narrowListWidthKey`).
    static let narrowWindow: CGFloat = 1400
    static let narrowListWidthKey = "HQListPaneWidthNarrow"
    private func preferredSidebar(window: CGFloat) -> CGFloat? {
        if let dragWidth { return dragWidth }
        let narrow = window < Self.narrowWindow
        let saved = UserDefaults.standard.double(forKey: narrow ? Self.narrowListWidthKey : Self.listWidthKey)
        return saved > 0 ? saved : narrow ? PaneLayout.narrowSidebar : 440
    }
    /// [mac] The tabs, down the window's leading edge (App/Mac/MacSidebar.swift); the panes share what is left.
    private(set) lazy var macSidebar = MacSidebar(tabs: tabs)
    private static var macSidebarWidth: CGFloat { MacSidebar.width }
    #else
    private static let macSidebarWidth: CGFloat = 0
    private func preferredSidebar(window: CGFloat) -> CGFloat? { nil }
    #endif
    private static var isMac: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }

    /// `size`: the window's size, so a chat the launch reopened is in the right pane before any view loads.
    init(tabs: MainTabController, size: CGSize) {
        self.tabs = tabs
        super.init(nibName: nil, bundle: nil)
        detail.navigationBar.prefersLargeTitles = false
        detail.delegate = PushedPageTitles.shared
        detail.setViewControllers([DetailPlaceholderViewController()], animated: false)
        // The list pane is a phone: the bottom glass tab bar and phone rows at any window width.
        tabs.traitOverrides.horizontalSizeClass = .compact
        addChild(tabs)
        addChild(detail)
        #if targetEnvironment(macCatalyst)
        _ = MacSidebar.windowWidthChanged(Self.debugSize(size).width)   // [mac] stress test #13: a narrow launch starts folded
        #endif
        let panes = Self.panesSize(Self.debugSize(size))
        layout = decideLayout(for: panes, window: Self.debugSize(size).width)
        noteOpeningSize(layout, panes: panes, window: Self.debugSize(size), pixel: 1 / max(1, UITraitCollection.current.displayScale))
        if layout.isDouble { sweepTabsIntoDetail() }
        _ = Self.keysWatch   // [ipad-polish] where the keyboard is, for `guideIsDead`
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(wentAway), name: UIScene.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(cameBack), name: UIScene.willEnterForegroundNotification, object: nil)
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "HQDebugSnapshotResize") { replaySnapshotResizes() }
        // [ipad-polish] `-HQDebugNarrowAt <seconds>` / `-HQDebugWidenAt <seconds>`: the stand-in window goes to the phone
        // layout (420 pt) and back that long after launch, to watch a chat cross between the panes without a UI test.
        for (key, width) in [("HQDebugNarrowAt", CGFloat(420) as CGFloat?), ("HQDebugWidenAt", nil)] {
            let at = UserDefaults.standard.double(forKey: key)
            guard at > 0 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in self?.setDebugSize(width: width, height: nil) }
        }
        #if !targetEnvironment(macCatalyst)
        // [ipad-polish] `-HQDebugHideListAt <seconds>`: the list is put away that long after launch (pictures).
        let hideAt = UserDefaults.standard.double(forKey: "HQDebugHideListAt")
        if hideAt > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + hideAt) { [weak self] in self?.setListHidden(true) } }
        #endif
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var isDouble: Bool { layout.isDouble }

    /// [duo] An iPhone that unfolds (`AppRoot.foldable`). DEBUG `-HQDebugDuoUpright YES` pretends so on an iPad, for
    /// pictures of the open Duo held upright (a stand-in window from `-HQDebugPaneWidth`).
    private static var foldable: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "HQDebugDuoUpright") { return true }
        #endif
        return AppRoot.foldable
    }
    /// Nothing is open on the right (or there is no right pane).
    var detailIsEmpty: Bool { detail.viewControllers.first is DetailPlaceholderViewController || detail.viewControllers.isEmpty }
    /// What the right pane shows, placeholder left out.
    var detailScreens: [UIViewController] { detail.viewControllers.filter { !($0 is DetailPlaceholderViewController) } }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Self.debugWidth != nil || Self.debugHeight != nil ? .black : HQPalette.page
        view.addSubview(tabs.view)
        view.addSubview(detail.view)
        hairline.backgroundColor = HQPalette.separator   // the theme's line, as the lists' own hairlines
        #if targetEnvironment(macCatalyst)
        hairline.backgroundColor = HQPalette.paneLine     // [mac] stress test #26: a neutral divider, not the navy outline
        #endif
        hairline.isUserInteractionEnabled = false
        view.addSubview(hairline)
        #if targetEnvironment(macCatalyst)
        view.addSubview(macSidebar)
        grip.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged(_:))))
        grip.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        view.addSubview(grip)
        #endif
        tabs.didMove(toParent: self)
        detail.didMove(toParent: self)
        #if targetEnvironment(macCatalyst)
        addChild(inspector)
        inspector.view.frame = .zero   // placed by placePanes; never the window's whole size, over the panes, before that
        view.addSubview(inspector.view)
        inspector.didMove(toParent: self)
        inspector.takesRoom = { [weak self] in (self?.inspectorRoom ?? 0) > 0 }
        inspector.makeRoom = { [weak self] in self?.foldListForInspector() ?? false }
        inspector.onWidthChange = { [weak self] in   // [mac-ui-issues] its edge dragged: follow the pointer, no glide
            guard let self, !self.applyingLayout else { return }
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
        inspector.onShownChange = { [weak self] in
            guard let self else { return }
            if !MacInspector.isShown { self.inspectorTakesList = false }   // ⌘I again: the list comes back
            self.view.setNeedsLayout()
            // Mac polish #1: a chat a layout moved never forces another from inside it; the next pass places the panel.
            guard !self.applyingLayout else { return }
            guard self.view.window != nil, !HQMotion.reduced else { self.view.layoutIfNeeded(); return }
            HQMotion.animate(0.22, options: [.curveEaseInOut, .beginFromCurrentState], changes: { self.view.layoutIfNeeded() })
        }
        #endif
        detail.view.accessibilityIdentifier = "pane.detail"
        #if DEBUG
        // [duo] -HQDebugDuoUpright: the Duo's 84 pt status column down the right edge, kept clear as on the device.
        if UserDefaults.standard.bool(forKey: "HQDebugDuoUpright") { detail.additionalSafeAreaInsets.right = 84 }
        #endif
        placePanes()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // In the same pass as the size change, before the children lay out: no frame shows a half state.
        applyLayout()
    }

    override var childForStatusBarStyle: UIViewController? { tabs }
    override var childForHomeIndicatorAutoHidden: UIViewController? { tabs }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

    // MARK: Layout

    /// The room the window gives: the whole view, or the DEBUG stand-in for a smaller window.
    private var windowRect: CGRect {
        let bounds = view.bounds
        let size = Self.debugSize(bounds.size)
        return CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(),
                      width: size.width, height: size.height)
    }

    /// The room the panes get: the window's, less the Mac's sidebar.
    private var contentRect: CGRect { split(windowRect).panes }

    #if targetEnvironment(macCatalyst)
    /// [mac-layout] The inspector at the chat's trailing edge (⌘I), see `MacInspector`.
    let inspector = MacInspector()
    /// Shown beside a chat, and the window wide enough that the panes keep their layout beside it.
    private var inspectorRoom: CGFloat {
        guard isViewLoaded, inspector.hasChat else { return 0 }
        return inspectorRoom(besideChatIn: Self.panesSize(windowRect.size))
    }
    /// The room the inspector takes beside a chat in panes this big: none when taking it would leave one pane, so the
    /// layout never depends on itself (Mac polish #1).
    private func inspectorRoom(besideChatIn panes: CGSize) -> CGFloat {
        guard MacInspector.isShown, PaneLayout.inspectorFits(panes: panes, inspector: MacInspector.narrowest, listFolded: listFolded)
        else { return 0 }
        // [mac-ui-issues] As wide as it was dragged, or what this window has room for beside the panes.
        var width = MacInspector.chosenWidth
        while width > MacInspector.narrowest, !PaneLayout.inspectorFits(panes: panes, inspector: width, listFolded: listFolded) {
            width = max(MacInspector.narrowest, width - 10)
        }
        // [mac-ui-issues] Owner 2026-11-09: in a narrow window (the list folded away) the panel kept the width it was
        // dragged to and the chat was left about half the room. The chat keeps at least 60 % there.
        if listFolded { width = max(MacInspector.narrowest, min(width, (panes.width * 0.4).rounded())) }
        return width
    }
    /// Inside `applyLayout`: the inspector following a chat this pass moved waits for the next pass, never a layout
    /// forced from inside this one (Mac polish #1).
    private var applyingLayout = false

    /// Owner 2026-11-07 ("yes" to the polish pass's call): ⌘I in a window with no room for the inspector beside two
    /// panes (a laptop-size window beside Sessions) folds the list away for it, as Bots' list folds into the sidebar,
    /// instead of doing nothing; ⌘I again brings the list back. Only asked for, never from a resize, and only while the
    /// chat and the panel still fit: in a narrower window the list stays and the panel waits, as before.
    private var inspectorTakesList = false
    private var listFoldedForInspector: Bool {
        guard inspectorTakesList, MacInspector.isShown, isViewLoaded, inspector.hasChat else { return false }
        let panes = Self.panesSize(windowRect.size)
        return !PaneLayout.inspectorFits(panes: panes, inspector: MacInspector.narrowest, listFolded: false)
            && PaneLayout.inspectorFits(panes: panes, inspector: MacInspector.narrowest, listFolded: true)
    }
    /// The inspector was asked for with no room: fold the list away when that gives it some. Read from the window's
    /// size alone, so the layout never depends on itself.
    private func foldListForInspector() -> Bool {
        guard isDouble, inspectorRoom == 0 else { return false }
        inspectorTakesList = true
        guard listFoldedForInspector else { inspectorTakesList = false; return false }
        AppLog.note("mac", "list folded away for the inspector")
        return true
    }
    #endif

    /// [mac] The sidebar's strip on the leading edge and what is left for the panes (everything for the panes elsewhere).
    private func split(_ rect: CGRect) -> (sidebar: CGRect, panes: CGRect) {
        guard Self.macSidebarWidth > 0 else { return (.zero, rect) }
        let rightToLeft = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        var (strip, rest) = rect.divided(atDistance: min(Self.macSidebarWidth, rect.width), from: rightToLeft ? .maxXEdge : .minXEdge)
        #if targetEnvironment(macCatalyst)
        rest = rest.divided(atDistance: inspectorRoom, from: rightToLeft ? .minXEdge : .maxXEdge).remainder
        #endif
        return (strip, rest)
    }

    private static func panesSize(_ window: CGSize) -> CGSize {
        CGSize(width: max(0, window.width - macSidebarWidth), height: window.height)
    }

    private func applyLayout() {
        #if targetEnvironment(macCatalyst)
        if MacSidebar.windowWidthChanged(windowRect.width) { macSidebar.widthStateChanged() }   // [mac] stress test #13
        applyingLayout = true
        defer { applyingLayout = false }
        #endif
        let rect = contentRect
        guard rect.width > 0, rect.height > 0 else { return }
        let next = decideLayout(for: rect.size, window: windowRect.width)
        // Away, a change between one pane and two is held. As the app leaves, a real iPad lays it out narrower for its
        // app-switcher snapshots and widens it back a moment later; moving the open chat onto its list for that ended the
        // app (a tester's iPad, build 337: 46 of 46 trips home with a chat in the right pane). The panes keep their
        // frames meanwhile, so nothing lays out again for a size nobody sees; the return applies the window's size then.
        // [mac] Not on the Mac: a window covered by others is "away" there, and a resize it gets (tiling, a display
        // change) is real; held, the panes stayed squeezed into the new size, the list a sliver and the chat off the
        // window (stress test 2026-10-28). The Mac takes no app-switcher snapshots.
        if away, !Self.isMac, next.isDouble != layout.isDouble {
            if !heldLayout { AppLog.note("screen", next.isDouble ? "layout: two panes held while away" : "layout: one pane held while away") }
            heldLayout = true
            return
        }
        heldLayout = false
        // Every size change, not only a change of layout: a rotation or a Stage Manager resize that keeps two panes
        // still changes the width the next chat opens at (§4.6).
        if rect.size != lastSize || next != layout {
            // [duo] Folded or unfolded: the screen it is on now says which ways the app may turn.
            if AppRoot.foldable, lastSize != .zero { setNeedsUpdateOfSupportedInterfaceOrientations() }
            lastSize = rect.size
        }
        noteOpeningSize(next, panes: rect.size, window: windowRect.size, pixel: 1 / max(1, traitCollection.displayScale))
        if next != layout {
            let was = layout
            layout = next
            if was.isDouble != next.isDouble {
                UIView.performWithoutAnimation {
                    if next.isDouble { sweepTabsIntoDetail() } else { collapseDetailOntoTabs() }
                }
                AppLog.note("screen", next.isDouble ? "layout: two panes" : "layout: one pane")
                #if !targetEnvironment(macCatalyst)
                // [ipad-polish] The list was put away before the window went narrow: the layout was decided with the
                // chat still over its list (nothing on the right yet), so it is decided again now that it has moved.
                if next.isDouble { layout = decideLayout(for: rect.size, window: windowRect.width) }
                #endif
            }
        }
        placePanes()
    }

    @objc private func wentAway() { away = true }

    /// A layout held while away follows the size the window came back at, screens moving as usual.
    @objc private func cameBack() {
        away = false
        if heldLayout { viewIfLoaded?.setNeedsLayout() }
    }

    private func placePanes() {
        guard isViewLoaded else { return }
        let rect = contentRect
        let pixel = 1 / max(1, traitCollection.displayScale)
        var tabsFrame = rect, detailFrame = rect, lineFrame = CGRect.zero
        if case .double(0) = layout {
            // [bots-rail] The Bots list folded into the sidebar's heads: the chat takes the whole room. The list keeps a
            // list's width just off the window (hidden), so nothing in it lays out at zero width and it comes back as
            // it was.
            let rightToLeft = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            let width = preferredSidebar(window: windowRect.width) ?? PaneLayout.wideSidebar
            tabsFrame = CGRect(x: rightToLeft ? rect.maxX : rect.minX - width, y: rect.minY, width: width, height: rect.height)
        } else if case .double(let sidebar) = layout {
            let rightToLeft = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            let (list, rest) = rect.divided(atDistance: sidebar, from: rightToLeft ? .maxXEdge : .minXEdge)
            tabsFrame = list
            detailFrame = rest
            lineFrame = CGRect(x: rightToLeft ? list.minX - pixel : list.maxX, y: rect.minY, width: pixel, height: rect.height)
            if rightToLeft { detailFrame.size.width -= pixel } else { detailFrame.origin.x += pixel; detailFrame.size.width -= pixel }
        }
        #if targetEnvironment(macCatalyst)
        let wide = listWide
        placedWide = wide
        if wide { tabsFrame = rect; lineFrame = .zero }
        // [mac-tools] The board beside its task's panel.
        let boardPanel = wide ? nil : boardPanel(in: rect.width)
        placedBoardPanel = boardPanel != nil
        if let boardPanel {
            let rightToLeft = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            let (panel, board) = rect.divided(atDistance: boardPanel, from: rightToLeft ? .minXEdge : .maxXEdge)
            tabsFrame = board
            detailFrame = panel
            lineFrame = CGRect(x: rightToLeft ? panel.maxX - pixel : panel.minX, y: rect.minY, width: pixel, height: rect.height)
            if rightToLeft { detailFrame.size.width -= pixel } else { detailFrame.origin.x += pixel; detailFrame.size.width -= pixel }
        }
        #else
        let wide = false
        #endif
        if tabs.view.frame != tabsFrame { tabs.view.frame = tabsFrame }
        if detail.view.frame != detailFrame { detail.view.frame = detailFrame }
        hairline.frame = lineFrame
        let double = layout.isDouble
        if detail.view.isHidden != (!double || wide) { detail.view.isHidden = !double || wide }
        let folded = layout == .double(sidebar: 0)
        if hairline.isHidden != (!double || folded || wide) { hairline.isHidden = !double || folded || wide }
        #if targetEnvironment(macCatalyst)
        if tabs.view.isHidden != folded { tabs.view.isHidden = folded }
        #else
        if tabs.view.isHidden != folded, !(folded && slidingList) { tabs.view.isHidden = folded }   // [ipad-polish] slides out first
        #endif
        #if targetEnvironment(macCatalyst)
        grip.frame = lineFrame.insetBy(dx: -4, dy: 0)
        grip.isHidden = !double || folded || wide || boardPanel != nil   // the panel's width is the board's call, not the lists'
        let strip = split(windowRect).sidebar
        if macSidebar.frame != strip { macSidebar.frame = strip }
        // [mac-layout] The inspector beside the chat: off the window's edge while hidden, so it slides in and out.
        let room = inspectorRoom
        let rightToLeft = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let window = windowRect
        let panel = room > 0 ? room : max(MacInspector.narrowest, inspector.view.frame.width)
        let inspectorFrame = CGRect(x: rightToLeft ? (room > 0 ? window.minX : window.minX - panel)
                                                   : (room > 0 ? window.maxX - room : window.maxX),
                                    y: window.minY, width: panel, height: window.height)
        if inspector.view.frame != inspectorFrame { inspector.view.frame = inspectorFrame }
        inspector.view.isHidden = room == 0 && !MacInspector.isShown
        // [mac-ui-issues] Its Desktop Look band ends where the chat's bar does.
        let bar = detail.navigationBar
        inspector.bandBottom = bar.isHidden || bar.window == nil ? 0 : max(0, bar.convert(bar.bounds, to: view).maxY - inspectorFrame.minY)
        // [mac-ten] Its tabs sit level with the bar's buttons. The bar is 54 pt tall on the Mac and its buttons stand
        // in its top 44 pt (measured 2026-11-11: bar y 41, buttons y 41 to 85), so the middle is that row's, not the bar's.
        let barFrame = bar.convert(bar.bounds, to: view)
        inspector.barMiddle = bar.isHidden || bar.window == nil ? 0 : max(0, barFrame.minY + min(barFrame.height, 44) / 2 - inspectorFrame.minY)
        NotificationCenter.default.post(name: MacSidebar.neighbourMayChange, object: nil)   // [sidebar-light] folded or not
        // A viewer over the panes (`PanePresentation`) follows them: a divider drag or a sidebar fold moves them
        // without resizing the window.
        (presentedViewController?.presentationController as? PanePresentation)?.containerView?.setNeedsLayout()
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// [mac] Where Watch Browser and Watch Screen go (`PaneViewer`): the right pane, or the list's place in one pane.
    var viewerRect: CGRect { layout.isDouble ? detail.view.frame : tabs.view.frame }
    #endif

    #if targetEnvironment(macCatalyst)
    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            dragStart = layout.sidebar
        case .changed:
            let moved = pan.translation(in: view).x
            dragWidth = dragStart + (view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -moved : moved)
            MacWindow.cursor("resizeLeftRightCursor")
            view.setNeedsLayout()
            view.layoutIfNeeded()
        default:
            dragWidth = nil
            let key = windowRect.width < Self.narrowWindow ? Self.narrowListWidthKey : Self.listWidthKey   // [mac] #63
            if layout.isDouble { UserDefaults.standard.set(Double(layout.sidebar), forKey: key) }
        }
    }

    /// The Mac's left-right arrows over the line, so it reads as something to drag.
    @objc private func hovered(_ hover: UIHoverGestureRecognizer) {
        let over = hover.state == .began || hover.state == .changed
        MacWindow.cursor(over || dragWidth != nil ? "resizeLeftRightCursor" : "arrowCursor")
    }
    #endif

    /// One pane or two in `panes` (`window` wide): the list folded away, or the web's rule with the list as wide as it
    /// was dragged.
    private func decideLayout(for panes: CGSize, window: CGFloat) -> PaneLayout {
        #if targetEnvironment(macCatalyst)
        listFolded ? .double(sidebar: 0)
            : PaneLayout.decide(size: panes, pad: true, preferred: preferredSidebar(window: window), foldable: Self.foldable)
        #else
        // [ipad-polish] A list put away only where there would be two panes: a narrow window is the phone layout.
        let base = PaneLayout.decide(size: panes, pad: true, preferred: preferredSidebar(window: window), foldable: Self.foldable)
        return base.isDouble && listFolded ? .double(sidebar: 0) : base
        #endif
    }

    /// A chat built from now on lays its first screen out at the width it is about to get (§4.6): the right pane's, cut
    /// as `placePanes` cuts it. [mac] Mac polish #85: beside the inspector when it takes its room there (when a list
    /// opens a chat no chat is beside it yet), and with no line beside a list folded away; counting neither, a chat
    /// opened with the inspector on or from the rail laid every message out twice. Reads no view: the launch notes it
    /// before any loads.
    private func noteOpeningSize(_ next: PaneLayout, panes: CGSize, window: CGSize, pixel: CGFloat) {
        #if targetEnvironment(macCatalyst)
        let whole = Self.panesSize(window)
        let besideChat = CGSize(width: whole.width - inspectorRoom(besideChatIn: whole), height: whole.height)
        if abs(besideChat.width - panes.width) > 0.5 {
            let layout = decideLayout(for: besideChat, window: window.width)
            ChatViewController.openingSize = CGSize(width: layout.detailWidth(panes: besideChat.width, pixel: pixel), height: besideChat.height)
            return
        }
        #endif
        ChatViewController.openingSize = CGSize(width: next.detailWidth(panes: panes.width, pixel: pixel), height: panes.height)
    }

    // MARK: Opening and closing (the seam, PaneRouter.swift)

    /// Shows `screens` in the right pane, replacing what was there. `from`: the list stack they were opened from.
    func show(_ screens: [UIViewController], from navigation: UINavigationController?, animated: Bool = true) {
        guard isDouble, let first = screens.first else { return }
        // The chat already on show is not built again.
        if screens.count == 1, let next = first as? ChatViewController, let shown = detail.viewControllers.first as? ChatViewController,
           detail.viewControllers.count == 1, shown.isSameChat(as: next) {
            // Backstop (the lists do not build the open row's chat again): a rejected screen never got a parent, so
            // nothing else would end its session's observing.
            if next !== shown, next.session !== shown.session { next.discardUnshown() }
            return
        }
        if let navigation { origin = navigation }
        first.navigationItem.largeTitleDisplayMode = .never
        settleMoves()
        let swap = { self.detail.setViewControllers(screens, animated: false) }
        if animated, detail.viewIfLoaded?.window != nil, !HQMotion.reduced {
            UIView.transition(with: detail.view, duration: 0.12, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                UIView.performWithoutAnimation(swap)
            }
        } else {
            swap()
        }
        screens.forEach { ($0 as? PaneNavigationFollowing)?.paneNavigationChanged(detail) }
        detailChanged()
    }

    /// Empties the right pane (the placeholder shows).
    func closeDetail(animated: Bool) {
        guard !detailIsEmpty else { return }
        settleMoves()
        let swap = { self.detail.setViewControllers([DetailPlaceholderViewController()], animated: false) }
        if animated, isDouble, detail.viewIfLoaded?.window != nil, !HQMotion.reduced {
            UIView.transition(with: detail.view, duration: 0.12, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                UIView.performWithoutAnimation(swap)
            }
        } else {
            swap()
        }
        detailChanged()
    }

    /// A chat that only just crossed panes and is now really closing must end as any closed chat does.
    private func settleMoves() {
        detail.viewControllers.forEach { ($0 as? ChatViewController)?.movingBetweenPanes = false }
    }

    private func detailChanged() {
        #if targetEnvironment(macCatalyst)
        if isViewLoaded, listWide != placedWide || (boardPanel(in: contentRect.width) != nil) != placedBoardPanel {
            view.setNeedsLayout()   // a page opened beside a whole page, or closed; [mac-tools] a task beside the board
        }
        if isViewLoaded, listFolded != (layout == .double(sidebar: 0)) { listFoldMayHaveChanged() }   // [mac-ui-issues] Settings opened or closed
        #else
        // [ipad-polish] Nothing left on the right: the list comes back, and stays for the next thing opened.
        if detailIsEmpty { listHidden = false }
        syncListToggle()
        if isViewLoaded, listFolded != (layout == .double(sidebar: 0)) { view.setNeedsLayout() }
        #endif
        onDetailChange?()
        tabs.paneSelectionChanged()
        tabs.noteLaunchScreen()
    }

    /// The tabs were made again for another gateway (`MainTabController.installTabs(fresh:)`): a chat belonged to the
    /// old one; Settings pages read the current gateway and stay (a switch lands on the page it was made from).
    func tabsRebuilt() {
        guard isDouble else { return }
        let first = detail.viewControllers.first
        if first is SettingsRootController || first is GatewayPageController {
            origin = tabs.placedTabs.compactMap { $0 as? UINavigationController }.first { tabs.pages?.isMore($0) ?? false }
        } else {
            closeDetail(animated: false)
        }
    }

    // MARK: Moving between layouts (§4.5)

    /// One pane → two: what the selected tab shows over its list moves to the right pane; the other tabs go back to
    /// their lists (one right pane cannot show two chats).
    private func sweepTabsIntoDetail() {
        let stacks = tabs.placedTabs.compactMap { $0 as? UINavigationController }
        let selected = tabs.selectedViewController as? UINavigationController
        for stack in stacks {
            // [mac-audit G] Owner 2026-11-02 (Mac audit #14, "switching tabs throws away the open chat"): on the Mac
            // another tab's screens stay over its list, as a tab switch leaves them (`followSelectedTab`), and come
            // back to the right pane when that tab is picked. Closing them here lost every other tab's chat each time
            // the window went down to one pane and back. The iPad has no `followSelectedTab`, so it still closes them.
            if Self.isMac, stack !== selected { continue }
            let screens = stack.viewControllers
            guard let index = screens.indices.dropFirst().first(where: { !(screens[$0] is ListPaneContent) }) else { continue }
            let moved = Array(screens[index...])
            // Only what goes to the right pane stays attached; another tab's chat really closes.
            if stack === selected, detailIsEmpty { moved.forEach { ($0 as? ChatViewController)?.movingBetweenPanes = true } }
            let focused = stack === selected ? moved.last?.viewIfLoaded?.hqFirstResponder : nil
            Self.lowerKeyboard(focused)
            PaneNavigationController.passThrough { stack.setViewControllers(Array(screens[..<index]), animated: false) }
            guard stack === selected, detailIsEmpty else { continue }
            moved.first?.hidesBottomBarWhenPushed = false
            origin = stack
            detail.setViewControllers(moved, animated: false)
            moved.forEach { ($0 as? PaneNavigationFollowing)?.paneNavigationChanged(detail) }
            restoreFocus(focused, in: moved)
        }
        syncListToggle()
        tabs.paneSelectionChanged()
    }

    /// [bots-rail] Owner 2026-11-02: with the sidebar folded, the Bots list folds into it as a rail of heads and the
    /// chat takes the rest of the window. Only while Bots is the tab on show: another tab's list comes back beside the
    /// rail (Sessions, Kanban, Jobs and More are its foot).
    var listFolded: Bool {
        #if targetEnvironment(macCatalyst)
        // [mac-layout] Owner 2026-11-03 "I like the bots in the sidebar": open or folded, the bots are in the sidebar, so
        // the Bots list never sits beside it; a bot's chat takes the room. Another list folds away while ⌘I's inspector
        // needs its room (`inspectorTakesList`).
        tabs.shownTab == .bots || listFoldedForInspector || settingsTakesList
        #else
        listHidden && !detailIsEmpty   // [ipad-polish] put away by its button (`setListHidden`)
        #endif
    }

    #if !targetEnvironment(macCatalyst)
    // MARK: Hiding the list (iPad)

    /// [ipad-polish] Owner 2026-11-11 ("get the app to work well on an iPad … you can do better"): an 11-inch iPad held
    /// upright gives the chat 448 pt beside the list, a phone's width on a tablet. The button at the leading end of the
    /// right pane's bar (Mail's and Notes' sidebar button, ⌃⌘S) puts the list away and the chat takes the window; the
    /// same button brings it back, tabs and all. Only with something open on the right: closing it brings the list
    /// back, since there is nothing else to look at. Not kept across launches.
    private(set) var listHidden = false
    /// The list is on its way out: it stays drawn until the slide ends.
    private var slidingList = false
    private weak var toggleHost: UIViewController?
    private lazy var listToggle: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "sidebar.leading"), primaryAction: UIAction { [weak self] _ in self?.toggleList() })
        item.accessibilityIdentifier = "pane.listToggle"
        return item
    }()

    /// A swipe in from the leading edge brings a hidden list back, as the sidebar comes back in Mail. Only on the
    /// right pane's first screen: a pushed page's own swipe goes back.
    private lazy var edgeSwipe: UIScreenEdgePanGestureRecognizer = {
        let swipe = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgeSwiped(_:)))
        swipe.edges = view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? .right : .left
        swipe.delegate = self
        return swipe
    }()

    @objc private func edgeSwiped(_ swipe: UIScreenEdgePanGestureRecognizer) {
        if swipe.state == .began { setListHidden(false) }
    }

    /// The list can be put away or brought back now (the menu's item is on).
    var canToggleList: Bool { isDouble && !detailIsEmpty }

    func toggleList() { setListHidden(!listHidden) }

    func setListHidden(_ hidden: Bool, animated: Bool = true) {
        guard hidden != listHidden, hidden ? canToggleList : true else { return }
        listHidden = hidden
        AppLog.note("screen", hidden ? "list put away: the right pane takes the window" : "list back beside the right pane")
        syncListToggle()
        guard isViewLoaded else { return }
        if hidden, edgeSwipe.view == nil { detail.view.addGestureRecognizer(edgeSwipe) }
        view.setNeedsLayout()
        guard animated, view.window != nil, !HQMotion.reduced else { view.layoutIfNeeded(); return }
        slidingList = hidden
        HQMotion.animate(0.25, options: [.curveEaseInOut, .beginFromCurrentState], changes: { self.view.layoutIfNeeded() }, completion: { _ in
            self.slidingList = false
            let folded = self.layout == .double(sidebar: 0)
            if self.tabs.view.isHidden != folded { self.tabs.view.isHidden = folded }
        })
    }

    /// The button sits on the right pane's first screen while there are two panes, and nowhere else: moved onto a
    /// tab's stack (one pane) the screen needs its Back there.
    private func syncListToggle() {
        let first = isDouble ? detail.viewControllers.first : nil
        let host = first is DetailPlaceholderViewController ? nil : first
        if let old = toggleHost, old !== host, old.navigationItem.leftBarButtonItem === listToggle {
            old.navigationItem.leftBarButtonItem = nil
        }
        toggleHost = host
        if let host, host.navigationItem.leftBarButtonItems?.isEmpty ?? true { host.navigationItem.leftBarButtonItem = listToggle }
        listToggle.accessibilityLabel = listHidden ? "Show List" : "Hide List"
        listToggle.isSelected = false
    }
    #else
    private func syncListToggle() {}
    #endif

    #if targetEnvironment(macCatalyst)
    /// [mac-ui-issues] Owner 2026-11-09 (Settings "looks exactly like it does on the iPhone"): Settings in the right pane
    /// is a Mac settings page with its own category column, so the More list beside it folds away and Settings has the
    /// room right of the sidebar. Its pushed pages keep it; closing Settings (Back, Escape, another place) brings the
    /// list back. Wide enough for the columns without the list is asked of the panes alone, so the layout never
    /// depends on itself.
    private var settingsTakesList: Bool {
        guard isViewLoaded, tabs.pages?.isMore(tabs.selectedViewController) == true,
              detail.viewControllers.first is SettingsRootController else { return false }
        return Self.panesSize(windowRect.size).width >= 820
    }

    /// [mac] Tester 2026-11-08 (a tester): a plugin page (Radar, Memory Wiki…) is a web page made for a browser window, but
    /// it sat in the list's column beside an empty right pane, and the divider stopped at 640 pt, so most of the window
    /// stayed blank. While a whole page is the place on show and nothing is open beside it, it takes the whole room:
    /// no right pane, no divider. Something opened beside it (a chat from Spawn Tree) brings the right pane back. The
    /// width the divider was dragged to is kept for the other lists.
    var listWide: Bool {
        guard isDouble, !listFolded, detailIsEmpty, let stack = tabs.selectedViewController as? UINavigationController,
              let page = stack.topViewController else { return false }
        return Self.isWholePage(page)
    }
    /// Owner 2026-11-08 ("get it all right"): the plugin pages and the Tools that are a page of their own, not rows that
    /// open beside them: Terminal, Usage, Spawn Tree, Star Map. Files, Changes, Status & Maintenance, Marketplace and
    /// Kanban's boards open their pages in the right pane, so they keep it.
    // [mac-tools] Status & Maintenance is a dashboard over the window; Recent Logs, Messaging and an action's output
    // open beside it, with a ✕.
    private static let wholePages: Set<String> = ["more-usage.page", "spawn-tree.page", "starmap.page", "command-center.page"]
    private static func isWholePage(_ page: UIViewController) -> Bool {
        switch page {
        case is PluginWebPageController, is TerminalViewController: true
        case let kanban as KanbanViewController: kanban.isBoard   // [mac-tools] the board of columns
        case let files as MoreWorkspaceController: files.isTable  // [mac-tools] Files' and Changes' table, until a file opens beside it
        case let artifacts as ArtifactsViewController: artifacts.isGrid   // [mac-tools] Artifacts' and Tiles' grid
        case is MarketplaceController: DeviceWord.isMac   // [mac-tools] the Marketplace's store front
        case is TasksViewController: DeviceWord.isMac     // [mac-tools] Tasks' table, until a task opens beside it
        default: page.viewIfLoaded?.accessibilityIdentifier.map(wholePages.contains) ?? false
        }
    }
    /// What `placePanes` last laid out, so a tab switch slides between the two as the Bots list's fold does.
    private var placedWide = false

    /// [mac-tools] Owner 2026-11-09 (the Tools sketch): Kanban's board keeps most of the window while a task is open
    /// beside it: the task is a panel on the trailing side, not the board squeezed into a list's column. Only for a
    /// task's page; a chat opened from the task gets the usual panes. The width is read from the panes alone.
    private func boardPanel(in panes: CGFloat) -> CGFloat? {
        guard isDouble, !listFolded, !detailIsEmpty, detail.viewControllers.first is KanbanTaskHostController,
              let stack = tabs.selectedViewController as? UINavigationController,
              (stack.topViewController as? KanbanViewController)?.isBoard == true else { return nil }
        let panel = min(520, max(400, (panes * 0.34).rounded()))
        return panes - panel >= 460 ? panel : nil
    }
    private var placedBoardPanel = false

    /// [bots-rail] The tab on show or the sidebar's fold changed: the list folds away or comes back, sliding. On the
    /// next turn of the run loop: a tab picked in the sidebar first has its screens follow it (`followSelectedTab`),
    /// so a narrow window's change to one pane moves the new tab's own chat, never pulls the old one back over Bots.
    func listFoldMayHaveChanged(animated: Bool = true) {
        DispatchQueue.main.async { [weak self] in self?.applyListFold(animated: animated) }
    }

    private func applyListFold(animated: Bool) {
        let fold = listFolded != (layout == .double(sidebar: 0))
        guard isViewLoaded, fold || listWide != placedWide || (boardPanel(in: contentRect.width) != nil) != placedBoardPanel else { return }
        if fold { AppLog.note("mac", listFolded ? "bots list folded into the rail" : "list pane back beside the rail") }
        if listWide != placedWide { AppLog.note("mac", listWide ? "page takes the whole width" : "list pane back beside the right pane") }
        view.setNeedsLayout()
        guard animated, view.window != nil, !HQMotion.reduced else { view.layoutIfNeeded(); return }
        HQMotion.animate(0.22, options: [.curveEaseInOut, .beginFromCurrentState], changes: { self.view.layoutIfNeeded() })
    }

    /// [mac] Stress test 2026-10-28 #62: the right pane follows the tab picked in the sidebar (or with ⌘1…⌘5), as a Mac
    /// source list's detail does, instead of keeping another tab's chat beside an unrelated list (D7 stays on the iPad).
    /// What was open goes back over the list it came from, the same objects a collapse to one pane moves (draft, scroll
    /// and stream kept), and comes back to the right pane when that tab is picked again; a tab with nothing of its own
    /// shows the placeholder. Only a person's tab switch: code that selects a tab and then opens something keeps D7.
    func followSelectedTab() {
        guard isDouble else { return }
        let stacks = tabs.placedTabs.compactMap { $0 as? UINavigationController }
        let selected = tabs.selectedViewController as? UINavigationController
        if !detailIsEmpty, let origin, origin !== selected, stacks.contains(where: { $0 === origin }) {
            let moved = detailScreens
            AppLog.trace("nav", "tab switch: \(moved.count) screen(s) back over their own tab's list")
            moved.forEach { ($0 as? ChatViewController)?.movingBetweenPanes = true }
            Self.lowerKeyboard(moved.last?.viewIfLoaded?.hqFirstResponder)
            detail.setViewControllers([DetailPlaceholderViewController()], animated: false)
            moved.first?.hidesBottomBarWhenPushed = true
            PaneNavigationController.passThrough { origin.setViewControllers(origin.viewControllers + moved, animated: false) }
            moved.forEach { ($0 as? PaneNavigationFollowing)?.paneNavigationChanged(origin) }
        }
        if detailIsEmpty, let selected {
            let screens = selected.viewControllers
            if let index = screens.indices.dropFirst().first(where: { !(screens[$0] is ListPaneContent) }) {
                let moved = Array(screens[index...])
                moved.forEach { ($0 as? ChatViewController)?.movingBetweenPanes = true }
                PaneNavigationController.passThrough { selected.setViewControllers(Array(screens[..<index]), animated: false) }
                moved.first?.hidesBottomBarWhenPushed = false
                origin = selected
                detail.setViewControllers(moved, animated: false)
                moved.forEach { ($0 as? PaneNavigationFollowing)?.paneNavigationChanged(detail) }
            }
        }
        detailChanged()
        // Mac polish #85: the list folds away (or comes back) in this same pass, once the screens have followed the tab,
        // so the chat that just came to the right pane never lays out beside a list that is going (as Bots' did).
        applyListFold(animated: true)
    }
    #endif

    /// Two panes → one: the right pane's screens go over the list they were opened from, and its tab is selected, so
    /// the phone layout lands on the open chat (D14). The same objects move: scroll position, draft and stream stay.
    private func collapseDetailOntoTabs() {
        let moved = detailScreens
        guard !moved.isEmpty else { tabs.paneSelectionChanged(); return }
        AppLog.trace("nav", "collapse to one pane: \(moved.count) screen(s) moved onto the tab's stack")
        let stacks = tabs.placedTabs.compactMap { $0 as? UINavigationController }
        // [taborder] No known origin: Bots' stack, as before tabs could move.
        guard let target = origin.flatMap({ origin in stacks.first { $0 === origin } }) ?? (tabs.controller(for: .bots) as? UINavigationController)
                ?? stacks.first else { return }
        moved.forEach { ($0 as? ChatViewController)?.movingBetweenPanes = true }
        let focused = moved.last?.viewIfLoaded?.hqFirstResponder
        Self.lowerKeyboard(focused)
        detail.setViewControllers([DetailPlaceholderViewController()], animated: false)
        syncListToggle()   // [ipad-polish] off the screen that is about to need its Back
        if tabs.selectedViewController !== target { tabs.selectedViewController = target }
        moved.first?.hidesBottomBarWhenPushed = true
        PaneNavigationController.passThrough { target.setViewControllers(target.viewControllers + moved, animated: false) }
        moved.forEach { ($0 as? PaneNavigationFollowing)?.paneNavigationChanged(target) }
        restoreFocus(focused, in: moved)
        tabs.paneSelectionChanged()
        tabs.noteLaunchScreen()
    }

    /// The keyboard goes down while the screen is still in its old pane. A view that leaves the window with the
    /// keyboard up comes back with a dead `keyboardLayoutGuide` (seen: a zero-size guide near the top that no later
    /// keyboard change moves, so the composer floated 740 pt above the keys); lowered first, the guide follows the
    /// keyboard again when `restoreFocus` raises it in the new pane.
    private static func lowerKeyboard(_ focused: UIView?) {
        guard let focused, focused.isFirstResponder else { return }
        UIView.performWithoutAnimation {
            focused.resignFirstResponder()
            focused.window?.layoutIfNeeded()
        }
    }

    /// The moved screens are laid out in their new pane in this same pass, and the field that had the keyboard gets
    /// it back, so the composer sits on the keys in the new layout.
    private func restoreFocus(_ focused: UIView?, in moved: [UIViewController]) {
        guard isViewLoaded, view.window != nil else { return }
        placePanes()
        view.layoutIfNeeded()
        moved.forEach { Self.reviveKeyboardGuide($0) }
        if let focused, focused.window != nil, !focused.isFirstResponder { focused.becomeFirstResponder() }
        moved.forEach { $0.viewIfLoaded?.setNeedsLayout() }
        view.layoutIfNeeded()
        // [ipad-polish] The keyboard comes back up over the next half second; a guide that looked alive just now can
        // still be one the keyboard no longer moves (see `guideIsDead`), so the moved screens are checked again once
        // it has settled.
        guard let focused else { return }
        for (pass, delay) in [0.7, 1.5].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isViewLoaded else { return }
                let stale = moved.filter { $0.parent != nil && Self.guideIsDead($0) }
                guard !stale.isEmpty else { return }
                let typing = focused.isFirstResponder
                // Setting the guide up again takes the screen out of the window for a moment, which puts the keys
                // down. The first time they come straight back, and the guide, alive now, follows them up. If it is
                // dead a second time the keys stay down: the message box at the foot of the pane, the draft in it.
                stale.forEach { Self.reviveKeyboardGuide($0) }
                if pass == 0, typing, focused.window != nil, !focused.isFirstResponder { focused.becomeFirstResponder() }
                moved.forEach { $0.viewIfLoaded?.setNeedsLayout() }
                self.view.layoutIfNeeded()
            }
        }
    }

    /// [ipad-polish] The screen's keyboard guide no longer follows the keyboard: it has no size (the first way this
    /// was seen), or the keyboard is up and the guide's top is not where the window's own guide has the keys. The
    /// second way is an iPad mini turned sideways while typing (one pane → two with the keyboard up): the guide kept
    /// the place of a keyboard that was down, so the message box and the newest messages sat under the keys.
    private static func guideIsDead(_ screen: UIViewController) -> Bool {
        guard let view = screen.viewIfLoaded, let window = view.window, view.bounds.width > 0 else { return false }
        let own = view.keyboardLayoutGuide.layoutFrame
        if own.width == 0 { return true }
        // Where the system last said the keyboard ends up (`keysFrame`), in the window: only a docked keyboard that is
        // up says anything about the guide.
        let keys = window.convert(keysFrame, from: window.screen.coordinateSpace)
        guard keys.height > 100, keys.maxY >= window.bounds.maxY - 1, keys.minY < window.bounds.maxY - 100 else { return false }
        return abs(view.convert(own, to: window).minY - keys.minY) > 2
    }

    /// [ipad-polish] The keyboard's last announced frame, in the screen's coordinates (`.zero`: never shown).
    private static var keysFrame = CGRect.zero
    private static let keysWatch: Void = {
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification,
                     UIResponder.keyboardDidHideNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
                let hidden = note.name == UIResponder.keyboardDidHideNotification
                MainActor.assumeIsolated { keysFrame = hidden ? .zero : frame }
            }
        }
    }()

    /// A screen that left the window while it had the keyboard can come back with a dead `keyboardLayoutGuide`: a
    /// zero-size guide that no later keyboard change moves (seen on iOS 27: the composer, which rides the guide,
    /// floated near the top of the pane). A live guide is as wide as the window. Taking the view out of its parent
    /// and putting it straight back makes UIKit set the guide up again.
    private static func reviveKeyboardGuide(_ screen: UIViewController) {
        guard let view = screen.viewIfLoaded, view.window != nil, view.bounds.width > 0,
              guideIsDead(screen), let parent = view.superview,
              let index = parent.subviews.firstIndex(of: view) else { return }
        if let window = view.window {
            AppLog.note("screen", "keyboard guide dead after a move between panes: own \(view.convert(view.keyboardLayoutGuide.layoutFrame, to: window)), window's \(window.keyboardLayoutGuide.layoutFrame)")
        }
        let frame = view.frame
        UIView.performWithoutAnimation {
            view.removeFromSuperview()
            parent.insertSubview(view, at: index)
            view.frame = frame
            parent.layoutIfNeeded()
        }
        AppLog.note("screen", "keyboard guide set up again after a move between panes (\(guideIsDead(screen) ? "still dead" : "ok"))")
    }

    // MARK: DEBUG: a smaller "window" for UI tests (`-HQDebugPaneWidth <points>`, `-HQDebugPaneHeight <points>`)

    #if DEBUG
    static var debugWidth: CGFloat? = UserDefaults.standard.object(forKey: "HQDebugPaneWidth").flatMap { _ in
        CGFloat(UserDefaults.standard.double(forKey: "HQDebugPaneWidth"))
    }
    static var debugHeight: CGFloat? = UserDefaults.standard.object(forKey: "HQDebugPaneHeight").flatMap { _ in
        CGFloat(UserDefaults.standard.double(forKey: "HQDebugPaneHeight"))
    }
    /// Tests and the stress sweep change the stand-in window's size while the app runs.
    func setDebugSize(width: CGFloat?, height: CGFloat?) {
        Self.debugWidth = width
        Self.debugHeight = height
        guard isViewLoaded else { return }
        view.backgroundColor = width != nil || height != nil ? .black : HQPalette.page
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    /// `-HQDebugSnapshotResize YES`: going to the background narrows the stand-in window to the phone layout and widens
    /// it back, as a real iPad does for its app-switcher snapshots (the simulator doesn't).
    private func replaySnapshotResizes() {
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.setDebugSize(width: 420, height: nil) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.setDebugSize(width: nil, height: nil) }
            }
        }
    }
    #else
    static let debugWidth: CGFloat? = nil
    static let debugHeight: CGFloat? = nil
    #endif

    private static func debugSize(_ size: CGSize) -> CGSize {
        CGSize(width: debugWidth.map { min(max($0, 280), size.width) } ?? size.width,
               height: debugHeight.map { min(max($0, 320), size.height) } ?? size.height)
    }
}

private extension UIView {
    /// The first responder inside this view, if any.
    var hqFirstResponder: UIView? {
        if isFirstResponder { return self }
        for child in subviews { if let found = child.hqFirstResponder { return found } }
        return nil
    }
}

/// The right pane's stack. [sidebar-light] On the Mac its layout tells the sidebar's strip to take the page's colour again.
final class DetailNavigationController: UINavigationController {
    #if targetEnvironment(macCatalyst)
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        NotificationCenter.default.post(name: MacSidebar.neighbourMayChange, object: nil)
    }
    #endif
}

#if !targetEnvironment(macCatalyst)
extension RootSplitController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        listHidden && layout == .double(sidebar: 0) && detail.viewControllers.count == 1 && presentedViewController == nil
    }
}
#endif
