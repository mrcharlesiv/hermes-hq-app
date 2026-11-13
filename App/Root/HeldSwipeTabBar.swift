// A swipe back held by the finger, from a page that hides the tab bar (a chat, a file) to one that shows it (owner
// 2026-11-12: "look at the bottom bar when you swipe to go back. It's all beaded up"). iOS shows its tab bar's buttons
// at full strength the moment the swipe starts, but the bar's glass only forms late in the slide, and the slide stands
// still under a finger: buttons with no bar behind them, the selected one a dark bead, for as long as the finger holds
// the page.
//
// So while the finger holds the page the tab bar stays hidden, and when the finger lets go it comes in whole, glass and
// buttons together, as the slide finishes. A swipe let go early never shows it. The chat keeps its own bottom bar on
// its page for the same stretch (`ChatViewController.fadeBottomBarWithTabBar`), so there is one bottom bar at a time.
// The Desktop Look and the Mac draw their own bar (`DesktopTabBar`) and are left alone.

import UIKit

@MainActor enum HeldSwipeTabBar {
    /// The system tab bar is the one a slide uncovers (not the Desktop Look's or the Mac's own).
    static var applies: Bool { DesktopTabBar.wanted == nil }

    /// `navigation` is about to show `page` (`PushedPageTitles`, every stack's delegate).
    static func willShow(_ page: UIViewController, in navigation: UINavigationController) {
        guard applies, let tabs = navigation.tabBarController, navigation.parent === tabs,
              let coordinator = navigation.transitionCoordinator, coordinator.isAnimated, coordinator.isInteractive,
              let leaving = coordinator.viewController(forKey: .from), leaving !== page,
              uncovers(leaving: leaving, stack: navigation.viewControllers) else { return }
        let bar = tabs.tabBar
        // The buttons, apart from iOS's own fade of the bar: they come in over a quarter second once the finger lets go.
        let veil = UIView(frame: bar.bounds)
        veil.backgroundColor = .black
        veil.alpha = 0
        bar.mask = veil
        // From clear, iOS fades the bar in with the slide (it sets 1 inside the slide's own animation; left at 1 there
        // is nothing to fade, which is how the buttons got ahead of the glass).
        UIView.performWithoutAnimation { bar.alpha = 0 }
        var letGo = false
        // iOS unhides the bar as the slide starts, after this call: hidden again a turn later, glass and all.
        DispatchQueue.main.async {
            guard !letGo else { return }
            UIView.performWithoutAnimation { bar.isHidden = true }
        }
        coordinator.notifyWhenInteractionChanges { context in
            letGo = true
            guard !context.isCancelled else { return }   // back to the page that hides it: it stays hidden
            UIView.performWithoutAnimation { bar.isHidden = false }
            HQMotion.animate(0.25, changes: { veil.alpha = 1 })
        }
        coordinator.animate(alongsideTransition: nil, completion: { context in
            letGo = true
            if bar.mask === veil { bar.mask = nil }
            bar.alpha = 1
            if !context.isCancelled { bar.isHidden = false }
        })
    }

    /// Leaving `leaving` brings the tab bar back: it (or a page that goes with it) hid the bar, and no page that stays
    /// does.
    static func uncovers(leaving: UIViewController, stack: [UIViewController]) -> Bool {
        let staying = stack.filter { $0 !== leaving }
        return leaving.hidesBottomBarWhenPushed && !staying.contains(where: \.hidesBottomBarWhenPushed)
    }
}
