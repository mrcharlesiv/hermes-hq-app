// [duo] DEBUG only: `-HQDebugDuoTurn YES` turns the app sideways 8 s after launch and upright again 8 s later, logging
// each layout, so the live one-pane ↔ two-pane switch on an iPhone Duo's open screen can be checked without anyone at
// Device Hub's rotate button (simctl has no rotate or fold command). The inner screen ignores the app's portrait-only
// setting anyway; while the turn runs the app allows every orientation so the request is granted.

#if DEBUG
import UIKit

@MainActor enum DuoDebugHooks {
    static var turning = false

    static func applyAfterLaunch(_ root: MainTabController) {
        if UserDefaults.standard.bool(forKey: "HQDebugDuoWatch") { watch(root) }
        guard UserDefaults.standard.bool(forKey: "HQDebugDuoTurn") else { return }
        turning = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { turn(root, .landscapeRight, "sideways") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 16) { turn(root, .portrait, "upright") }
    }

    /// `-HQDebugDuoWatch YES`: every 2 s, the window and the chat on show (its frame in the window and its safe area),
    /// for folding and turning by hand in Device Hub.
    private static func watch(_ root: MainTabController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak root] in
            guard let root, let window = root.view.window else { return }
            if let chat = root.chatOnShow, chat.isViewLoaded {
                let frame = chat.view.convert(chat.view.bounds, to: window)
                AppLog.note("screen", "duo watch: window \(window.bounds.size) chat \(frame) safe \(chat.view.safeAreaInsets) window safe \(window.safeAreaInsets)")
            } else {
                AppLog.note("screen", "duo watch: window \(window.bounds.size) no chat, window safe \(window.safeAreaInsets)")
            }
            watch(root)
        }
    }

    private static func turn(_ root: MainTabController, _ mask: UIInterfaceOrientationMask, _ name: String) {
        guard let scene = root.view.window?.windowScene else { return }
        AppLog.note("screen", "duo turn: \(name) requested")
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            AppLog.note("screen", "duo turn: \(name) refused (\(error.localizedDescription))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let size = scene.coordinateSpace.bounds.size
            let split = root.view.window?.rootViewController as? RootSplitController
            AppLog.note("screen", "duo turn: \(name) window \(Int(size.width))x\(Int(size.height)) panes \(split?.isDouble == true ? 2 : 1) right pane \(split?.detailScreens.map { String(describing: type(of: $0)) } ?? [])")
        }
    }
}
#endif
