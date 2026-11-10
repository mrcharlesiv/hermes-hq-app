// [diagnostics] One "Done" bar for every number pad (docs/spec/3x-diagnostics.md §13.2). The number pad has no Return
// key, so without a bar over it there is no way to put the keyboard away. The web app asked its native shell for the
// same bar (`numberAccessory`, `src/ui-pages/number-field.tsx`).
//
// The bar goes on the field itself, never on a Section or a List: a section hands its modifiers to its footer too, and
// a bar on a list shows over every field of the page. Here the bar's items exist only while this field has the focus,
// so there is exactly one "Done" whatever else is on the page.

import SwiftUI
import UIKit

struct NumberPadDone: ViewModifier {
    var onDone: () -> Void
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if focused {
                        Spacer()
                        Button("Done") {
                            onDone()
                            focused = false
                        }
                        .accessibilityIdentifier("numberpad.done")
                    }
                }
            }
    }
}

/// The bar only when `on` (a field whose keyboard depends on its data).
struct NumberPadDoneIf: ViewModifier {
    var on: Bool
    func body(content: Content) -> some View {
        if on { content.numberPadDone() } else { content }
    }
}

extension View {
    /// A "Done" bar over this field's number pad. `onDone` commits the field the way leaving it does; the keyboard
    /// then goes away.
    func numberPadDone(_ onDone: @escaping () -> Void = {}) -> some View { modifier(NumberPadDone(onDone: onDone)) }
}

extension UITextField {
    /// The same bar for a UIKit field: the system's toolbar over the keyboard with one "Done" that puts it away.
    func addNumberPadDone(_ onDone: (() -> Void)? = nil) {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        let done = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            onDone?()
            self?.resignFirstResponder()
        })
        done.accessibilityIdentifier = "numberpad.done"
        bar.items = [UIBarButtonItem(systemItem: .flexibleSpace), done]
        bar.sizeToFit()
        inputAccessoryView = bar
    }
}
