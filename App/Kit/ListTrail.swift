// [diagnostics] Which SwiftUI list was on screen, in the words a crash gives. Mac download 479 (2026-10-30) died with
// "<UpdateCoalescingCollectionView 0x…> is stuck in a recursive layout loop" a moment after a theme change on
// Settings › Theme, and nothing tied that address to a page. A pushed page and every theme change now note each SwiftUI
// list's address (tagged as the crash message's is, so the two `#` tags match) with its page and row count:
//   lists after theme change: ThemeSettingsController #f4b34d (5 sections, 9 rows)

import UIKit

@MainActor enum ListTrail {
    /// The lists in this page's view, a moment after it shows (a hosted List is built on the first layout).
    static func page(_ viewController: UIViewController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak viewController] in
            guard let viewController, let view = viewController.viewIfLoaded else { return }
            note("on \(typeName(viewController))", lists(in: view))
        }
    }

    /// Every window's lists, when the theme has just changed (each one re-lays its rows then).
    static func themeChanged(_ windows: [UIWindow]) {
        note("after theme change", windows.flatMap { lists(in: $0) })
    }

    private static func note(_ when: String, _ found: [UICollectionView]) {
        guard AppLog.detailed, !found.isEmpty else { return }
        let words = found.map { list in
            let rows = (0..<list.numberOfSections).reduce(0) { $0 + list.numberOfItems(inSection: $1) }
            // `%p` prints the address as UIKit's description does; the log tags it the same way in both lines.
            return "\(page(of: list)) \(String(format: "%p", unsafeBitCast(list, to: Int.self))) (\(list.numberOfSections) sections, \(rows) rows)"
        }
        AppLog.trace("screen", "lists \(when): " + words.joined(separator: ", "))
    }

    /// SwiftUI's own lists only (their class names say SwiftUI's; the app's UIKit lists never loop this way).
    private static func lists(in view: UIView) -> [UICollectionView] {
        var found: [UICollectionView] = []
        var stack = [view]
        while let next = stack.popLast() {
            if let list = next as? UICollectionView, !list.isHidden, list.window != nil,
               NSStringFromClass(type(of: list)).contains("UpdateCoalescing") { found.append(list) }
            stack.append(contentsOf: next.subviews)
        }
        return found
    }

    private static func page(of view: UIView) -> String {
        var responder: UIResponder? = view
        while let next = responder {
            if let controller = next as? UIViewController, !(controller is UINavigationController),
               !NSStringFromClass(type(of: controller)).contains("HostingController") { return typeName(controller) }
            responder = next.next
        }
        return "?"
    }

    private static func typeName(_ object: AnyObject) -> String {
        let name = String(describing: type(of: object))
        return name.split(separator: "<").first.map(String.init) ?? name
    }
}
