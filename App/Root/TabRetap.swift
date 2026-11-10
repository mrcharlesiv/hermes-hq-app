// [tabretap] A second tap of the tab on show, already at its root page, scrolls that page back to the top (owner
// 2026-11-10). Tapping into a tab still keeps the place it was left at; a second tap on a pushed page still goes back
// to the root first, as the system bar does.

import UIKit

enum TabRetap {
    /// `tab` (a tab's controller, its stack) was tapped again while on show: when its stack is at the root, the root
    /// page scrolls to the top. False when a page is pushed (the bar's pop to root comes first).
    @discardableResult static func scrollToTop(_ tab: UIViewController, animated: Bool = true) -> Bool {
        let root: UIViewController
        if let stack = tab as? UINavigationController {
            guard stack.viewControllers.count <= 1, let first = stack.viewControllers.first else { return false }
            root = first
        } else {
            root = tab
        }
        guard root.isViewLoaded, let scroll = mainScrollView(in: root.view) else { return false }
        let top = CGPoint(x: scroll.contentOffset.x, y: -scroll.adjustedContentInset.top)
        guard scroll.contentOffset.y > top.y + 0.5 else { return true }
        scroll.setContentOffset(top, animated: animated && !HQMotion.reduced)
        return true
    }

    /// The page's own list: the shallowest on-screen vertical scroll view at least half the page tall (not a text
    /// view, not one the page keeps out of the status bar's scroll-to-top, not a sideways rail).
    static func mainScrollView(in view: UIView) -> UIScrollView? {
        let minHeight = view.bounds.height * 0.5
        var queue: [UIView] = [view]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let scroll = next as? UIScrollView, !(scroll is UITextView), scroll.scrollsToTop,
               !scroll.isHidden, scroll.alpha > 0.01, scroll.window != nil, scroll.bounds.height >= minHeight {
                return scroll
            }
            queue.append(contentsOf: next.subviews.filter { !$0.isHidden && $0.alpha > 0.01 })
        }
        return nil
    }
}
