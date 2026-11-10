// [mac] The Mac app (Mac Catalyst, scripts/build-mac.sh) is the iPad layout in a Mac window. This is what a Mac
// expects on top of it: the window's own chrome, the menu bar's system items, and the pages' bars.

import ObjectiveC
import UIKit

#if targetEnvironment(macCatalyst)
nonisolated(unsafe) private var pageBarKey: UInt8 = 0

@MainActor enum MacWindow {
    static let supportPage = URL(string: "https://gethermeshq.com/support")!
    static let support = #selector(AppDelegate.hqOpenSupport(_:))

    /// No title text over the app's own bars (each pane already says where you are) and no toolbar row. The window
    /// never gets narrower than the sidebar beside a phone-wide list, nor shorter than a sheet's form.
    static func configure(_ scene: UIWindowScene) {
        scene.titlebar?.titleVisibility = .hidden
        scene.titlebar?.toolbar = nil
        scene.sizeRestrictions?.minimumSize = minimumSize
        DesktopSegments.macTitles(UISegmentedControl.appearance())   // the iOS look has no theme walk at launch
        MacDockMenu.install()   // quick actions and Talk's controls on the Dock icon
        MacDockIcon.apply()     // [app-icons] the icon picked in Settings › App Icon
        DesktopBars.hookBars()  // stress test 2026-10-28 #50: plain toolbar items in the iOS look too
        DesktopBack.install()   // stress test 2026-10-28 #104: the plain named Back in the iOS look too
    }

    /// In the iPad points the Mac draws at 77 %: the sidebar and a 375 pt list (about 470 × 460 pt on the screen).
    static var minimumSize: CGSize { CGSize(width: (MacSidebar.isCollapsed ? MacSidebar.width : MacSidebar.narrowestOpen) + 375, height: 600) }   // [sidebar-width] a wider sidebar squeezes back before the window stops

    // MARK: Text size (View › Make Text Bigger / Smaller / Actual Size, as in Mail and Safari)

    /// An iPad app on the Mac has no text size of its own: every text size reads the same 17 pt body there, whatever
    /// the window's or the app's size category says (measured 2026-10-25 with `-HQDebugMacShots`, a trait override
    /// and a swapped `preferredContentSizeCategory` alike). What does move the whole layout is UI Scale (text, faces,
    /// rows and icons), which applies in both looks (`ThemeState.scale`) and starts at 100 %,
    /// Grok Bot's sizes (`ThemeState.macBase`). The View menu steps through its presets, the same ones Settings › Theme
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
        let bar = UINavigationBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = colour
        bar.shadowColor = .clear
        // The page's title follows UI Scale with its rows (the system's 17 pt carries none).
        bar.titleTextAttributes[.font] = MacType.pageTitle   // [mac] Stress test 2026-10-28 #52
        bar.subtitleTextAttributes[.font] = pageSubtitle     // Mac polish #77
        item.standardAppearance = bar
        item.scrollEdgeAppearance = bar
        item.compactAppearance = bar
        item.compactScrollEdgeAppearance = bar
        objc_setAssociatedObject(item, &pageBarKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
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
        var lists: [UIScrollView] = []
        func walk(_ view: UIView, depth: Int) {
            if let list = view as? UIScrollView, !list.isHidden, list.bounds.width > 100 { lists.append(list) }
            guard depth < 8 else { return }
            for child in view.subviews { walk(child, depth: depth + 1) }
        }
        walk(view, depth: 0)
        guard let biggest = lists.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) else { return nil }
        if let colour = biggest.backgroundColor, colour.cgColor.alpha > 0.5 { return colour }
        return HQPalette.groupedPage
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
    @objc func hqOpenSupport(_ sender: Any?) { UIApplication.shared.open(MacWindow.supportPage) }
    @objc func hqTextBigger(_ sender: Any?) { MacWindow.changeTextSize(by: 1) }
    @objc func hqTextSmaller(_ sender: Any?) { MacWindow.changeTextSize(by: -1) }
    @objc func hqTextNormal(_ sender: Any?) { MacWindow.changeTextSize(by: 0) }
    @objc func hqToggleSidebar(_ sender: Any?) { KeyCommands.root?.split?.macSidebar.toggleCollapsed() }
}
#endif
