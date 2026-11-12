// [tap-out] A tap outside the on-screen keyboard and the field being typed in gives a light tick, then closes the keyboard.
// One window-wide rule (the owner, 2026-11-11), installed once per window, so every page and sheet behaves the same way.
//
// The tap still reaches what it landed on (cancelsTouchesInView is off): a row opens, a link follows. It is left alone when
// it lands on the field being typed in, on another text field (focus simply moves), on a button or switch (they act with
// the keyboard up, like Send), or inside a view marked `KeepsKeyboardOnTap` (the message box, the / and @ drawer).
// A hardware keyboard's thin bar is not a keyboard to close, and the Mac has none.

import UIKit

/// A view whose taps never close the keyboard (the message box and what floats above it).
protocol KeepsKeyboardOnTap: UIView {}

@MainActor
final class KeyboardTapOut: NSObject, UIGestureRecognizerDelegate {
    private static var installed: [ObjectIdentifier: KeyboardTapOut] = [:]
    /// The on-screen keyboard is up (taller than a hardware keyboard's bar).
    private static var keyboardUp = false
    private static var observing = false

    private weak var window: UIWindow?

    static func install(on window: UIWindow) {
        if DeviceWord.isMac { return }
        let id = ObjectIdentifier(window)
        guard installed[id] == nil else { return }
        observeKeyboard()
        let owner = KeyboardTapOut()
        owner.window = window
        let tap = UITapGestureRecognizer(target: owner, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = owner
        tap.name = "hq.keyboardTapOut"
        window.addGestureRecognizer(tap)
        installed[id] = owner
    }

    private static func observeKeyboard() {
        guard !observing else { return }
        observing = true
        let center = NotificationCenter.default
        center.addObserver(forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main) { note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
            MainActor.assumeIsolated { keyboardUp = frame.height > 120 }
        }
        center.addObserver(forName: UIResponder.keyboardDidChangeFrameNotification, object: nil, queue: .main) { note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
            MainActor.assumeIsolated { if frame.height <= 120 { keyboardUp = false } }
        }
        center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { keyboardUp = false }
        }
    }

    // MARK: Gesture

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard Self.keyboardUp, let window, let typing = FirstResponder.current(), let typingView = typing as? UIView,
              typingView.window === window, typing is UIKeyInput else { return false }
        guard let hit = touch.view else { return false }
        var view: UIView? = hit
        while let current = view {
            if current === typingView { return false }                   // inside the field itself
            if Self.takesTyping(current) { return false }               // another field: focus moves to it
            if current is UIControl { return false }                     // buttons and switches act with the keys up
            if current is KeepsKeyboardOnTap { return false }            // the message box and its drawer
            view = current.superview
        }
        return true
    }

    /// A field that types (a message's selectable text is not one: a tap there closes the keyboard).
    private static func takesTyping(_ view: UIView) -> Bool {
        if let text = view as? UITextView { return text.isEditable }
        if let field = view as? UITextField { return field.isEnabled }
        return view is UIKeyInput && view.canBecomeFirstResponder
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended, Self.keyboardUp, let window else { return }
        Haptics.play(.light)
        window.endEditing(true)
        // A field inside a web page or a custom view that endEditing misses.
        if let still = FirstResponder.current() as? UIView, still.window === window, still is UIKeyInput {
            still.resignFirstResponder()
        }
    }
}

/// Finds the current first responder (UIKit has no public getter): the nil-targeted action lands on it.
@MainActor
enum FirstResponder {
    fileprivate static weak var found: UIResponder?

    static func current() -> UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.hq_noteFirstResponder), to: nil, from: nil, for: nil)
        return found
    }
}

extension UIResponder {
    @objc fileprivate func hq_noteFirstResponder() { FirstResponder.found = self }
}
