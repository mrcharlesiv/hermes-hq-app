// [keys-return] Owner 2026-10-31: "when you have the keyboard pulled up and you open one of the any of the buttons and
// then close that pop-up, you should be returned to the keyboard open again. Right now it returns you to the keyboard
// closed."
//
// A pop-up that opens over the chat while the keys are up brings them back when it closes, whichever way it closes
// (a pick, Done, a swipe down). That covers the ☰ commands sheet, All Models, Prompts, Usage and Prices, and the +
// menu's pickers. Presenters that put the keys down first call `stowKeys()` so the chat remembers they were up;
// `present(_:animated:)` hangs a probe on the pop-up's view, and the probe calls back once that view has left the
// screen for good. The keys come back only when nothing else is over the chat. The model panel (not a presented
// controller) does the same itself. The Mac has no keys to bring back; its pop-overs give the caret back their own way.

import UIKit

extension ChatViewController {
    /// Puts the keys down for a pop-up about to open, remembering whether they were up.
    func stowKeys() {
        if composer.textView.isFirstResponder { oweKeys() }
        view.endEditing(true)
    }

    /// The keys were up a moment ago; the next pop-up to open brings them back when it closes.
    func oweKeys() {
        keysOwedAt = CACurrentMediaTime()
    }

    /// From `present(_:animated:)`: a pop-up opening over the keys (or just after they went down for it) is watched.
    func noteKeys(for controller: UIViewController) {
        let owed = keysOwedAt.map { CACurrentMediaTime() - $0 < 2 } ?? false
        keysOwedAt = nil
        // The Mac too (Mac UI check 2026-11-13): Prompts, Usage & Limits and Model Prices are plain sheets there, and
        // closing one left the message field without its caret. Its ☰ and Models panels still give it back themselves.
        guard owed || composer.textView.isFirstResponder else { return }
        // An alert gives the field back itself.
        guard !(controller is UIAlertController) else { return }
        KeysReturnProbe.watch(controller) { [weak self] in self?.returnKeys() }
    }

    /// After a pop-up the keys were up for has closed: back up, unless something else is over the chat now. The
    /// closing pop-up can still count as shown for a moment after its view has gone; that is waited out (1 s at most).
    func returnKeys(attempt: Int = 0) {
        guard view.window != nil, menus?.modelPanelOpen != true, !composer.isHidden else { return }
        if let shown = presentedViewController {
            // Something else is open over the chat: the keys stay down.
            if !shown.isBeingDismissed, shown.view.window != nil { return }
            guard attempt < 10 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.returnKeys(attempt: attempt + 1) }
            return
        }
        AppLog.trace("chatui", "keys back after a pop-up")
        focusComposer()
    }
}

/// Rides a pop-up's view. When the view leaves the window because the pop-up is being dismissed, it calls back once.
/// (A pop-up covered by a full-screen one of its own leaves the window too; that is not its closing.)
final class KeysReturnProbe: UIView {
    private weak var controller: UIViewController?
    private var closed: (() -> Void)?
    private var closing = false

    static func watch(_ controller: UIViewController, closed: @escaping () -> Void) {
        let probe = KeysReturnProbe(frame: .zero)
        probe.controller = controller
        probe.closed = closed
        controller.view.addSubview(probe)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        // Read on the way out: by the time the view has gone, the flag may have dropped.
        if newWindow == nil, window != nil { closing = controller?.isBeingDismissed ?? true }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window == nil, closing, let closed else { return }
        self.closed = nil
        DispatchQueue.main.async { [weak self] in
            self?.removeFromSuperview()
            closed()
        }
    }
}
