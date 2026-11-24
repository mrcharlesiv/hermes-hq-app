// [mac] Double-clicking the top of a window zooms it, as any Mac window's title bar does (owner 2026-11-22: "Double
// clicking on the top of the Mac app isn't resizing it like other apps do"). The windows hide their title and toolbar
// (MacWindow.configure), so the app's own bars fill the top: AppKit's title bar only kept the thin strip above them,
// and a double-click on a pane's bar (a chat's name row, a list's title) went to UIKit, which did nothing with it.

import UIKit

#if targetEnvironment(macCatalyst)
final class MacTitleBarClick: NSObject, UIGestureRecognizerDelegate {
    static let shared = MacTitleBarClick()

    /// The strip AppKit's own title bar answers in: the window's safe area ends under it (UIKit's points, the app's
    /// 77 % scale: 28 pt on the screen is about 37 here).
    static func titleStrip(_ window: UIWindow) -> CGFloat { window.safeAreaInsets.top > 0 ? window.safeAreaInsets.top : 37 }
    /// How far under the strip a pane with no bar still counts as the top: a bar's height, so the empty right pane
    /// and the sidebar (round its search row) end the top where a chat's bar beside them does.
    static let gap: CGFloat = 54

    static func install(on window: UIWindow) {
        let click = UITapGestureRecognizer(target: shared, action: #selector(doubleClicked(_:)))
        click.numberOfTapsRequired = 2
        click.cancelsTouchesInView = false
        click.delaysTouchesBegan = false
        click.delaysTouchesEnded = false
        click.delegate = shared
        click.name = "hq.mac.titleBarDoubleClick"
        window.addGestureRecognizer(click)
    }

    @objc private func doubleClicked(_ click: UITapGestureRecognizer) {
        guard click.state == .ended, let window = click.view as? UIWindow else { return }
        Self.perform(Self.preferredAction(), in: window)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let window = gestureRecognizer.view as? UIWindow else { return false }
        // The strip AppKit answers itself would zoom twice (zoom, then back): leave it to AppKit.
        let point = touch.location(in: window)
        return point.y >= Self.titleStrip(window) && Self.isWindowTop(touch.view, at: point, in: window)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    /// A click on a bar along the window's top, not on anything in it that answers a click of its own (a button, the
    /// title's menu, a search field). A pane with no bar (the sidebar, the empty right pane) has the same band
    /// under the title strip.
    static func isWindowTop(_ hit: UIView?, at point: CGPoint, in window: UIWindow) -> Bool {
        var bar: UIView?
        var scrolls = false
        var view = hit
        while let current = view, current !== window {
            if answersClicks(current) { return false }
            if bar == nil, current is UINavigationBar { bar = current }
            if current is UIScrollView { scrolls = true }
            view = current.superview
        }
        guard let bar else { return !scrolls && point.y <= titleStrip(window) + gap }
        // The pane's own bar, right under the title strip: not a bar further down (a sheet's, a page inside a page).
        let frame = bar.convert(bar.bounds, to: window)
        return frame.minY <= titleStrip(window) + 8 && point.y <= frame.maxY
    }

    private static var interactiveKey: UInt8 = 0

    /// Marks a view (such as a SwiftUI strip inside a top bar) as answering clicks so double-clicking it never zooms the window.
    static func markInteractive(_ view: UIView) {
        objc_setAssociatedObject(view, &interactiveKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func answersClicks(_ view: UIView) -> Bool {
        if objc_getAssociatedObject(view, &interactiveKey) != nil { return true }
        if view is UIControl || view is UITextView || view is UISearchBar { return true }
        if view.accessibilityTraits.contains(.button) || view.accessibilityTraits.contains(.link) { return true }
        return view.gestureRecognizers?.contains { $0 is UITapGestureRecognizer && $0.isEnabled } ?? false
    }

    enum Action: Equatable { case zoom, minimize, none }

    /// System Settings › Desktop & Dock › "Double-click a window's title bar to": Zoom (Maximize) or Fill, Minimize,
    /// Do Nothing. Unset is Zoom; the older Minimize switch counts when the newer setting isn't there.
    static func preferredAction(_ defaults: UserDefaults = .standard) -> Action {
        switch defaults.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": return .minimize
        case "None": return .none
        case .some: return .zoom
        case nil: return defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick") ? .minimize : .zoom
        }
    }

    /// The window's own AppKit zoom or minimise, as its green and yellow buttons do. UIKit has no word for either.
    static func perform(_ action: Action, in window: UIWindow) {
        guard action != .none, let host = nsWindow(for: window) else { return }
        let selector = NSSelectorFromString(action == .minimize ? "performMiniaturize:" : "performZoom:")
        guard host.responds(to: selector) else { return }
        _ = host.perform(selector, with: nil)
        AppLog.note("mac", "title bar double-click: \(action)")
    }

    /// The AppKit window showing `window`: the one listing it among its UIWindows, else the key window (the first
    /// click of the double-click made it key).
    private static func nsWindow(for window: UIWindow) -> NSObject? {
        guard let type: AnyObject = NSClassFromString("NSApplication"),
              let app = type.perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? NSObject
        else { return nil }
        let windows = app.value(forKey: "windows") as? [NSObject] ?? []
        let uiWindows = NSSelectorFromString("uiWindows")
        if let host = windows.first(where: {
            $0.responds(to: uiWindows) && (($0.value(forKey: "uiWindows") as? [UIWindow])?.contains { $0 === window } ?? false)
        }) { return host }
        return app.value(forKey: "keyWindow") as? NSObject
    }
}
#endif
