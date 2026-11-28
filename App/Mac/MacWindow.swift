// [mac] The Mac app (Mac Catalyst, scripts/build-mac.sh) is the iPad layout in a Mac window. This is what a Mac
// expects on top of it: the window's own chrome, the menu bar's system items, and the pages' bars.

import ObjectiveC
import UIKit
import UIKit.UIGestureRecognizerSubclass

#if targetEnvironment(macCatalyst)
nonisolated(unsafe) private var pageBarKey: UInt8 = 0
nonisolated(unsafe) private var pageBarWatchKey: UInt8 = 0

@MainActor enum MacWindow {
    static let supportPage = URL(string: "https://gethermeshq.com/support")!
    static let support = #selector(AppDelegate.hqOpenSupport(_:))

    /// No title text over the app's own bars (each pane already says where you are) and no toolbar row. The window
    /// never gets narrower than the sidebar beside a phone-wide list, nor shorter than a sheet's form.
    static func configure(_ scene: UIWindowScene) {
        scene.titlebar?.titleVisibility = .hidden
        scene.titlebar?.toolbar = nil
        scene.sizeRestrictions?.minimumSize = minimumSize
        restoreFrame(scene)
        DesktopSegments.macTitles(UISegmentedControl.appearance())   // the iOS look has no theme walk at launch
        noWindowTabs()
        MacDockMenu.install()   // quick actions and Talk's controls on the Dock icon
        MacDockIcon.apply()     // [app-icons] the icon picked in Settings › App Icon
        DesktopBars.hookBars()  // stress test 2026-10-28 #50: plain toolbar items in the iOS look too
        DesktopBack.install()   // stress test 2026-10-28 #104: the plain named Back in the iOS look too
        // [Mac AAA 2026-11-16] What the lines are sized against (`HQShape.pixel`), for the tours' log.
        AppLog.note("mac", "scale: screen \(HQShape.macBacking) px/pt, UIKit \(scene.traitCollection.displayScale), "
            + "pixel line \(HQShape.pixel(1)) pt")
    }

    // MARK: The main window's place and size, kept between launches

    /// The main window's frame as it was left (`WindowFit.encode`, the screen's own points). A tester 2026-11-18: the
    /// window came back at the system's first size after every quit. An iPad app's window on the Mac is not restored by
    /// the system unless "Close windows when quitting an application" is off, which it is not by default.
    static let frameKey = "HQMacMainWindowFrame"
    /// The frame asked for while the window opens, and whether its frame is being kept yet.
    private static var opening: CGRect?
    private static var asks = 0
    private static var keeps = false
    private static var restoreGen = 0
    /// A tour sizes the window itself, and its sizes are nobody's choice.
    private static var touring: Bool { ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-HQDebugMacShots") } }

    /// Puts the main window where it was left, inside the screen it is on now (a second screen unplugged, a Dock that
    /// grew). For its first 1.5 s nothing is kept and the frame is held: the system places a new window itself once it
    /// shows (measured 2026-11-19: 0.2 s after the frame asked for here, it put its own first size back).
    static func restoreFrame(_ scene: UIWindowScene) {
        guard !touring else { return }
        keeps = false
        asks = 0
        restoreGen += 1
        let gen = restoreGen
        if let kept = WindowFit.decode(UserDefaults.standard.string(forKey: frameKey), minimum: CGSize(width: 320, height: 240)) {
            let frame = WindowFit.inside(kept, visible: MacSettingsWindow.visibleScreen(around: kept))
            AppLog.note("mac", "main window: as left, \(Int(frame.width))×\(Int(frame.height)) at \(Int(frame.minX)),\(Int(frame.minY))")
            opening = frame
            scene.requestGeometryUpdate(.Mac(systemFrame: frame)) { _ in }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard restoreGen == gen else { return }
            opening = nil
            keeps = true
        }
    }

    /// Every move and resize of the main window: where it is now is where it opens next time. Full screen is a state
    /// of the window, not a size to come back at.
    static func frameChanged(_ scene: UIWindowScene) {
        guard !touring else { return }
        let frame = scene.effectiveGeometry.systemFrame
        if let asked = opening {
            let there = abs(frame.minX - asked.minX) < 2 && abs(frame.minY - asked.minY) < 2
                && abs(frame.width - asked.width) < 2 && abs(frame.height - asked.height) < 2
            if there {
                opening = nil
                keeps = true
                return
            }
            // The system's own placement, or a frame on the way: asked again (a few times at most), never kept.
            if !frame.isEmpty, !scene.isFullScreen, asks < 6 {
                asks += 1
                scene.requestGeometryUpdate(.Mac(systemFrame: asked)) { _ in }
            }
            return
        }
        guard keeps, !scene.isFullScreen, !frame.isEmpty else { return }
        UserDefaults.standard.set(WindowFit.encode(frame), forKey: frameKey)
    }

    /// [macpass] 2026-11-14: the app's windows are never tabs, but AppKit's automatic tabbing put Show Tab Bar and
    /// Show All Tabs in View and Show Previous Tab, Show Next Tab, Move Tab to New Window and Merge All Windows in
    /// Window, all dimmed. Turning tabbing off takes them out, as in apps that have no tabs.
    static func noWindowTabs() {
        let selector = NSSelectorFromString("setAllowsAutomaticWindowTabbing:")
        guard let window: AnyClass = NSClassFromString("NSWindow"), let method = class_getClassMethod(window, selector) else { return }
        typealias Setter = @convention(c) (AnyClass, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(window, selector, false)
    }

    /// In the iPad points the Mac draws at 77 %: the sidebar, floating canvas inset, and a 375 pt list.
    static var minimumSize: CGSize { CGSize(width: (MacSidebar.isCollapsed ? MacSidebar.width : MacSidebar.narrowestOpen) + 375 + MacGlassShell.canvasInset, height: 600) }   // [sidebar-width] a wider sidebar squeezes back before the window stops

    // MARK: Text size (View › Make Text Bigger / Smaller / Actual Size, as in Mail and Safari)

    /// An iPad app on the Mac has no text size of its own: every text size reads the same 17 pt body there, whatever
    /// the window's or the app's size category says (measured 2026-10-25 with `-HQDebugMacShots`, a trait override
    /// and a swapped `preferredContentSizeCategory` alike). What does move the whole layout is UI Scale (text, faces,
    /// rows and icons), which applies in both looks (`ThemeState.scale`) and starts at 100 %,
    /// 15 pt body text (`ThemeState.macBase`). The View menu steps through its presets, the same ones Settings › Theme
    /// offers; Actual Size is 100 %.
    static func stepScale(_ current: Int, by: Int) -> Int? {
        let presets = ThemeState.scalePresets
        guard by != 0 else { return ThemeStore.defaultScale }
        let index = presets.firstIndex(of: current) ?? presets.lastIndex(where: { $0 < current }) ?? 0
        let next = index + by
        return presets.indices.contains(next) ? presets[next] : nil
    }

    static func changeTextSize(by: Int) {
        let current = Theme.shared.state.uiScalePercent
        guard let next = stepScale(current, by: by), next != current else { return }
        Theme.shared.setUIScale(next)
    }

    /// Whether the text size item that steps `by` does anything now.
    static func canChangeTextSize(by: Int) -> Bool {
        let current = Theme.shared.state.uiScalePercent
        guard let next = stepScale(current, by: by) else { return false }
        return next != current
    }

    /// AppKit's cursor, which UIKit has no word for: `name` is an `NSCursor` class property (`resizeLeftRightCursor`).
    static func cursor(_ name: String) {
        guard let type: AnyObject = NSClassFromString("NSCursor"),
              let cursor = type.perform(NSSelectorFromString(name))?.takeUnretainedValue() else { return }
        _ = cursor.perform(NSSelectorFromString("set"))
    }

    /// The tab bar's 10 pt labels came out at 7.7 pt on the Mac's screen; 13 pt is 10 pt there (HQFont.macSmallest).
    static func tabLabels(_ bar: UITabBar) {
        let label = HQFont.macTabLabel
        let appearance = bar.standardAppearance.copy()
        for layout in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            layout.normal.titleTextAttributes[.font] = label
            layout.selected.titleTextAttributes[.font] = label
        }
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
    }

    /// The system's items for documents, text styling, a window toolbar and a sidebar the app does not have (Show
    /// Sidebar stayed greyed out: the sidebar is the list pane, which never hides). Help said "Help isn't available
    /// for Hermes HQ"; it opens the website's support page instead, as About › Support does.
    static func trimMenus(_ builder: UIMenuBuilder) {
        builder.remove(menu: .open)
        builder.remove(menu: .openRecent)
        builder.remove(menu: .format)
        builder.remove(menu: .toolbar)
        builder.remove(menu: .sidebar)
        // [keys] Mac UI check 2026-11-13 (V29): groups that hold nothing in a Mac's menu bar (printing, and
        // the text menu's Replace, Share, Look Up and Learn, which only a right-click on text shows) left
        // a lone line: File ended in a separator and Edit had two in a row under Select All. The right-click menu on
        // text is built apart (`UIMenuSystem.context`) and keeps them.
        for menu: UIMenu.Identifier in [.print, .replace, .share, .lookup, .learn] { builder.remove(menu: menu) }
        for menu: UIMenu.Identifier in [.file, .edit] {
            builder.replaceChildren(ofMenu: menu) { children in children.filter { ($0 as? UIMenu)?.children.isEmpty != true } }
        }
        builder.replaceChildren(ofMenu: .help) { _ in [UICommand(title: "Hermes HQ Support", action: support)] }
    }

    /// A page that leaves its bar to the system (Settings and its pages, Bot Profiles, Status & Maintenance…): on the iPad
    /// its rows fade out under the clear bar, but the Mac draws no such edge, so the title and the bar's buttons sat
    /// right on the rows once they scrolled. Its bar is the page's own colour there instead, as the lists' bars are once
    /// rows scroll under them (`ListBarAppearance`). A chat keeps its clear bar over the messages; the Desktop Look
    /// has solid bars of its own. A pane's first page is put in place without a slide, before SwiftUI has built its list,
    /// so it's looked at again once that's done.
    static func pageBar(_ page: UIViewController, again: Bool = true) {
        guard !(page is ChatViewController) else { return }
        let item = page.navigationItem
        let ours = objc_getAssociatedObject(item, &pageBarKey) != nil
        if Theme.isDesktop {
            guard ours else { titleToken(item); return }
            item.standardAppearance = nil
            item.scrollEdgeAppearance = nil
            item.compactAppearance = nil
            item.compactScrollEdgeAppearance = nil
            objc_setAssociatedObject(item, &pageBarKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return
        }
        // [mac] Stress test 2026-10-28 #52 (round 3): a page that brought its own bar was left alone, title and all, so
        // its title kept the system's size. It keeps its own bar, with the page-title token folded into it.
        guard ours || (item.standardAppearance == nil && item.scrollEdgeAppearance == nil && item.compactAppearance == nil) else {
            titleToken(item)
            return
        }
        // [mac] Stress test 2026-10-28 #52 (round 2): a titled page with nothing that scrolls (a More page showing its
        // empty or error state: Messaging, Spawn Tree, Webhooks, Star Map) kept the system's bar, whose title is
        // smaller and lighter than every other page's. It takes the bar too, in its own background colour.
        // [mac] #52 (round 3): a hosted SwiftUI page builds its List only after it is shown, often after the one look
        // again, and its hosting view may not report a solid colour; such a page then kept the system's bar (the
        // smaller, lighter title on Bot Profiles, Messaging, Webhooks and Star Map). A titled page always takes the bar
        // on the second look, in the grouped page colour most pages are when nothing else says.
        let titled = !(page.navigationItem.title ?? page.title ?? "").isEmpty
        let fallback: UIColor? = again || !titled ? nil : (solidColour(page.view) ?? HQPalette.groupedPage)
        guard let colour = pageColour(page.view) ?? fallback else {
            if again { DispatchQueue.main.async { [weak page] in if let page { pageBar(page, again: false) } } }
            return
        }
        // In the glass canvas the bar is clear while the page is at its top and takes a near-solid veil once rows pass
        // under it. At rest it has no background at all, not a clear colour: with any colour there the bar keeps its
        // scrolled background drawn underneath (it can't tell that the colour is clear), a strip across the page's top.
        let glass = page.traitCollection[MacGlassCanvasTrait.self] && MacGlassShell.isTransparencyEnabled
        let standard = UINavigationBarAppearance()
        standard.configureWithTransparentBackground()
        standard.backgroundColor = glass ? MacGlassShell.canvasPageBarVeilColor : colour
        standard.shadowColor = .clear
        // The page's title follows UI Scale with its rows (the system's 17 pt carries none).
        standard.titleTextAttributes[.font] = MacType.pageTitle   // [mac] Stress test 2026-10-28 #52
        standard.subtitleTextAttributes[.font] = pageSubtitle     // Mac polish #77

        let rest = standard.copy()
        if glass { rest.backgroundColor = nil }

        item.standardAppearance = standard
        item.scrollEdgeAppearance = rest
        item.compactAppearance = standard
        item.compactScrollEdgeAppearance = rest
        objc_setAssociatedObject(item, &pageBarKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        // Window Transparency switched (or the page moved into the canvas after its bar was made): made again.
        if objc_getAssociatedObject(page, &pageBarWatchKey) == nil {
            objc_setAssociatedObject(page, &pageBarWatchKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            page.registerForTraitChanges([MacGlassCanvasTrait.self]) { (page: UIViewController, _: UITraitCollection) in
                pageBar(page)
            }
        }
    }

    /// [mac] Stress test 2026-10-28 #52 (round 3): the page-title token on bars a page set itself (each state that has
    /// one), so every page title is one size and weight whoever made the bar. Nothing is written when it already is.
    static func titleToken(_ item: UINavigationItem) {
        if let next = tokened(item.standardAppearance) { item.standardAppearance = next }
        if let next = tokened(item.scrollEdgeAppearance) { item.scrollEdgeAppearance = next }
        if let next = tokened(item.compactAppearance) { item.compactAppearance = next }
        if let next = tokened(item.compactScrollEdgeAppearance) { item.compactScrollEdgeAppearance = next }
    }

    /// `appearance` with the page-title and subtitle tokens, or nil when it already has them (nothing to write).
    static func tokened(_ appearance: UINavigationBarAppearance?) -> UINavigationBarAppearance? {
        let title = MacType.pageTitle, subtitle = pageSubtitle
        guard let appearance, (appearance.titleTextAttributes[.font] as? UIFont) != title
                || (appearance.subtitleTextAttributes[.font] as? UIFont) != subtitle else { return nil }
        let copy = appearance.copy()
        copy.titleTextAttributes[.font] = title
        copy.subtitleTextAttributes[.font] = subtitle
        return copy
    }

    /// Mac polish #77: the grey line under a bar's title ("7 rows · 4 columns" on the Table page, Steps, Usage & Limits)
    /// follows UI Scale like the rest of the page's text; the system's own stayed at its fixed size, a quarter smaller
    /// than every other grey line.
    static var pageSubtitle: UIFont { HQFont.preferred(.footnote) }

    /// The colour behind the page's rows: its biggest list's own, else the grouped page most pages are. Nil for a page
    /// with nothing that scrolls (the empty right pane), which has nothing to pass under its bar.
    private static func pageColour(_ view: UIView) -> UIColor? {
        guard let biggest = biggestList(view) else { return nil }
        if let colour = biggest.backgroundColor, colour.cgColor.alpha > 0.5 { return colour }
        return HQPalette.groupedPage
    }

    /// The page's biggest list (its rows), or nil for a page with nothing that scrolls.
    private static func biggestList(_ view: UIView) -> UIScrollView? {
        var lists: [UIScrollView] = []
        func walk(_ view: UIView, depth: Int) {
            if let list = view as? UIScrollView, !list.isHidden, list.bounds.width > 100 { lists.append(list) }
            guard depth < 8 else { return }
            for child in view.subviews { walk(child, depth: depth + 1) }
        }
        walk(view, depth: 0)
        return lists.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
    }

    /// The page view's own colour when it is solid (a hosted SwiftUI page paints its grouped grey there).
    private static func solidColour(_ view: UIView) -> UIColor? {
        guard let colour = view.backgroundColor, colour.cgColor.alpha > 0.5 else { return nil }
        return colour
    }
}

/// [mac] Icon-only buttons say what they do when the pointer rests on them, as a Mac's do (stress test 2026-10-28): one
/// tool tip on the window finds the button under the pointer and shows the name it already has for VoiceOver. Buttons
/// with words of their own, rows, and views with a tool tip of their own (the sidebar's) are left alone.
final class MacToolTips: NSObject, UIToolTipInteractionDelegate {
    static let shared = MacToolTips()

    static func install(on window: UIWindow) {
        let interaction = UIToolTipInteraction()
        interaction.delegate = shared
        window.addInteraction(interaction)
    }

    func toolTipInteraction(_ interaction: UIToolTipInteraction, configurationAt point: CGPoint) -> UIToolTipConfiguration? {
        guard let window = interaction.view, let hit = window.hitTest(point, with: nil) else { return nil }
        var view: UIView? = hit
        for _ in 0..<6 {
            guard let current = view, current !== window else { return nil }
            if current is UITableViewCell || current is UICollectionViewCell || current is UIScrollView { return nil }
            if let tip = Self.tip(for: current) {
                return UIToolTipConfiguration(toolTip: tip, in: current.convert(current.bounds, to: window))
            }
            view = current.superview
        }
        return nil
    }

    /// The words a button under the pointer shows as its tip: its accessibility label, when it draws none itself.
    static func tip(for view: UIView) -> String? {
        guard view is UIControl || view.accessibilityTraits.contains(.button),
              !(view is UITextField || view is UISwitch || view is UISegmentedControl || view is UISlider),
              let label = view.accessibilityLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty,
              !showsWords(view, depth: 0) else { return nil }
        return label
    }

    static func showsWords(_ view: UIView, depth: Int) -> Bool {
        if let button = view as? UIButton, !(button.currentTitle ?? button.configuration?.title ?? "").isEmpty { return true }
        if let label = view as? UILabel, !(label.text ?? "").isEmpty, !label.isHidden, label.alpha > 0.01 { return true }
        guard depth < 4 else { return false }
        return view.subviews.contains { !$0.isHidden && $0.alpha > 0.01 && showsWords($0, depth: depth + 1) }
    }
}

extension AppDelegate {
    @objc func hqOpenSupport(_ sender: Any?) { LinkOpener.openOutside(MacWindow.supportPage) }
    @objc func hqTextBigger(_ sender: Any?) { MacWindow.changeTextSize(by: 1) }
    @objc func hqTextSmaller(_ sender: Any?) { MacWindow.changeTextSize(by: -1) }
    @objc func hqTextNormal(_ sender: Any?) { MacWindow.changeTextSize(by: 0) }
    @objc func hqToggleSidebar(_ sender: Any?) { KeyCommands.root?.split?.macSidebar.toggleCollapsed() }
}

/// [rest-hands 2026-11-17] A divider's drag (the sidebar's edge, the list's, the right-hand panel's), measured from where
/// the button went down. A pan's own translation only counts from where it was recognised, a few points into the move,
/// so the edge trailed the pointer by about 8 pt for the whole drag (measured with the real pointer: a 50 pt drag moved
/// the edge 42).
final class MacGripPan: UIPanGestureRecognizer {
    private var down: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible, let touch = touches.first, let window = view?.window { down = touch.location(in: window) }
        super.touchesBegan(touches, with: event)
    }

    /// The pointer's travel since the button went down, in `target`'s coordinates.
    func travel(in target: UIView?) -> CGPoint {
        guard let down, let window = view?.window else { return translation(in: target) }
        let from = target?.convert(down, from: window) ?? down
        let now = location(in: target)
        return CGPoint(x: now.x - from.x, y: now.y - from.y)
    }

    override func reset() {
        super.reset()
        down = nil
    }
}
#endif
