// [mac] Watch Browser and Watch Screen over the panes, not the whole window (Mac stress test round 2, #30). Full
// screen they hid the sidebar, the list and the chat, and their ✕ sat just under the window's close, minimise and
// zoom buttons. On the Mac the viewer covers the right pane (one pane: the list's place) and the sidebar stays, so the
// ✕ is never near the window's corner. It is still presented by the window's root, so the rest of the app reads it as
// a sheet: the menu's other commands are off, Escape closes it (`EscapeAction.dismissPresented`), and, as under a Mac
// sheet, the rest of the window shows but takes no clicks. Presented from inside a sheet (nothing over a sheet but
// another sheet), it stays full screen with its bar moved down clear of the window's buttons. iPhone and iPad: full
// screen, as before. Since #351 Watch Screen and Watch Browser come here on the Mac only when no window of their own
// could be had (`ViewerWindow`, below).

import UIKit

// [#351] A tester: on the Mac a bot's Screen "stays very small and cannot be enlarged"; its zoom enlarged only the
// picture. Over the right pane it was as big as that pane and no bigger. Watch Screen and Watch Browser now open in a
// window of their own on the Mac (a page window, `MacFileWindow.open(page:)`): nearly the main window's size at first,
// then resized by its edges, zoomed by its green button or made full screen, moved to another display or set beside
// the chat; the main window stays usable meanwhile. The picture follows the window's size (Fit fills it); − and + still zoom the
// picture inside it. Its ✕, ⌘W, Escape and the red button all close it as the ✕ did (control handed back). Should the
// Mac give no window, the viewer covers the pane as before (`PaneViewer.present`). iPhone and iPad: unchanged.

/// A page shown in a window of its own that has work to end when that window closes.
@MainActor protocol MacWindowPage: AnyObject {
    /// The window has gone (its red button, or ⌘W / Escape handled by the window): stop as the page's ✕ does.
    func windowClosed()
}

/// What asking for a viewer does while one is already up (`ScreenViewerController.present`, `BrowserViewerController.present`).
enum ViewerReopen: Equatable {
    /// None is up: open it.
    case open
    /// Leave things as they are: on iPhone and iPad the viewer covers everything, so the ask can only come from under
    /// it (a notice's Watch is handled before this), and one on its way out finishes first.
    case ignore
    /// The same bot's is up in its own window: bring that window to the front.
    case front
    /// Another bot's is up in its own window (the main window stays usable beside it): it closes, handing control
    /// back, and the one asked for opens.
    case replace

    static func decide(shown: String?, leaving: Bool, asked: String, ownWindow: Bool) -> ViewerReopen {
        guard let shown else { return .open }
        guard ownWindow, !leaving else { return .ignore }
        return shown == asked ? .front : .replace
    }
}

/// [#351] Watch Screen and Watch Browser in a window of their own on the Mac. Everywhere else every call answers
/// false and the viewer is presented as before.
@MainActor enum ViewerWindow {
    /// Opens `viewer` (the page itself, not a navigation controller: the window gives it its bar) in a new window.
    /// `failed` runs if the Mac gives none. False off the Mac.
    static func open(_ viewer: UIViewController & MacWindowPage, title: String, failed: @escaping () -> Void) -> Bool {
        #if targetEnvironment(macCatalyst)
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "HQDebugViewersInPane") { return false }   // the old placing, for a "before" picture
        #endif
        waiting.add(viewer)
        // A key of its own: a window still closing for an earlier viewer is never handed this one.
        return MacFileWindow.open(page: viewer, title: title, key: "viewer-\(UUID().uuidString)") { [weak viewer] in
            if let viewer { waiting.remove(viewer) }
            failed()
        }
        #else
        return false
        #endif
    }

    /// The window `viewer` has to itself, if it has one.
    static func scene(of viewer: UIViewController) -> UIWindowScene? {
        #if targetEnvironment(macCatalyst)
        guard let scene = viewer.viewIfLoaded?.window?.windowScene, scene.delegate is FileSceneDelegate else { return nil }
        return scene
        #else
        return nil
        #endif
    }

    /// Whether `viewer` is in (or on its way to) a window of its own.
    static func owns(_ viewer: UIViewController) -> Bool {
        #if targetEnvironment(macCatalyst)
        return scene(of: viewer) != nil || waiting.contains(viewer)
        #else
        return false
        #endif
    }

    /// Brings `viewer`'s window to the front. False when it has none.
    @discardableResult static func bringForward(_ viewer: UIViewController) -> Bool {
        #if targetEnvironment(macCatalyst)
        guard let scene = scene(of: viewer) else { return waiting.contains(viewer) }   // it is on its way
        UIApplication.shared.requestSceneSessionActivation(scene.session, userActivity: nil, options: nil)
        return true
        #else
        return false
        #endif
    }

    /// Closes `viewer`'s window (or, not shown yet, the window coming for it). False when it has none: the caller
    /// dismisses it as a presented page.
    @discardableResult static func close(_ viewer: UIViewController) -> Bool {
        #if targetEnvironment(macCatalyst)
        waiting.remove(viewer)
        if MacFileWindow.withdraw(page: viewer) { return true }
        guard let scene = scene(of: viewer) else { return false }
        MacFileWindow.close(scene)
        return true
        #else
        return false
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// Viewers given a window of their own (held weakly): found here before that window has connected.
    private static let waiting = NSHashTable<UIViewController>.weakObjects()
    #endif
}

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
        // [macpass r4 tools] With the chat's inspector open the viewer covered the chat column alone: the screen got a
        // third of a 900 pt window, beside the chat's Info that took no clicks while it was up. It covers the inspector too.
        var rect = split.viewerRect
        let inspector = split.inspector.view.frame
        let canvas = split.macCanvas
        if !split.inspector.view.isHidden, inspector.width > 0, inspector.intersects(canvas.bounds) { rect = rect.union(inspector) }
        return canvas.convert(rect, to: containerView)
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
