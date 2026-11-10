// [mac] Watch Browser and Watch Screen over the panes, not the whole window (Mac stress test round 2, #30). Full
// screen they hid the sidebar, the list and the chat, and their ✕ sat just under the window's close, minimise and
// zoom buttons. On the Mac the viewer covers the right pane (one pane: the list's place) and the sidebar stays, so the
// ✕ is never near the window's corner. It is still presented by the window's root, so the rest of the app reads it as
// a sheet: the menu's other commands are off, Escape closes it (`EscapeAction.dismissPresented`), and, as under a Mac
// sheet, the rest of the window shows but takes no clicks. Presented from inside a sheet (nothing over a sheet but
// another sheet), it stays full screen with its bar moved down clear of the window's buttons. iPhone and iPad: full
// screen, as before.

import UIKit

@MainActor enum PaneViewer {
    static func present(_ viewer: UIViewController, from presenter: UIViewController) {
        #if targetEnvironment(macCatalyst)
        if let split = presenter.viewIfLoaded?.window?.rootViewController as? RootSplitController,
           split.presentedViewController == nil {
            viewer.modalPresentationStyle = .custom
            viewer.modalTransitionStyle = .crossDissolve
            viewer.transitioningDelegate = PanePresentation.Transitions.shared
            // Stress test 2026-10-28 #78: the bar's close sat 10 pt from the list's divider; the page's 20 pt gutter.
            (viewer as? UINavigationController)?.navigationBar.directionalLayoutMargins.leading = 20
            (viewer as? UINavigationController)?.navigationBar.directionalLayoutMargins.trailing = 20
            split.present(viewer, animated: true)
            return
        }
        // The bar's top was at about 36 pt, its ✕ just under the window's buttons; this puts it below `MacSidebar.topRoom`.
        viewer.additionalSafeAreaInsets.top = 16
        #endif
        viewer.modalPresentationStyle = .fullScreen
        presenter.present(viewer, animated: true)
    }
}

#if targetEnvironment(macCatalyst)
/// The viewer's place: the split's `viewerRect`, followed through window resizes, a dragged divider and a folded
/// sidebar (`RootSplitController.placePanes` asks for a new layout).
final class PanePresentation: UIPresentationController {
    final class Transitions: NSObject, UIViewControllerTransitioningDelegate {
        static let shared = Transitions()

        func presentationController(forPresented presented: UIViewController, presenting: UIViewController?,
                                    source: UIViewController) -> UIPresentationController? {
            PanePresentation(presentedViewController: presented, presenting: presenting)
        }
    }

    /// The panes stay where they are under it (a full-screen viewer took the presenter's view out of the window).
    override var shouldRemovePresentersView: Bool { false }

    override var frameOfPresentedViewInContainerView: CGRect {
        guard let containerView else { return .zero }
        guard let split = presentingViewController as? RootSplitController, split.isViewLoaded else { return containerView.bounds }
        return split.view.convert(split.viewerRect, to: containerView)
    }

    override func presentationTransitionWillBegin() {
        super.presentationTransitionWillBegin()
        presentedView?.clipsToBounds = true
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        let frame = frameOfPresentedViewInContainerView
        if presentedView?.frame != frame { presentedView?.frame = frame }
    }
}
#endif
