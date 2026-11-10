// [a11y] Field validity for VoiceOver (spec 3x-a11y §6.2 c): the web marks the field at fault `aria-invalid` and puts
// the message in a `role="alert"` line (main.ts:187,237-281). Native: the field's hint says "Invalid." and why, and
// the message is spoken once when it appears. The red edge alone told a VoiceOver user nothing.

import SwiftUI
import UIKit

enum HQFieldValidity {
    /// The hint a field at fault carries; nil when it is fine.
    nonisolated static func hint(invalid: Bool, message: String?) -> String? {
        guard invalid else { return nil }
        guard let message, !message.isEmpty else { return "Invalid" }
        return "Invalid. \(message)"
    }
}

extension View {
    /// Marks a field at fault for VoiceOver. The mark goes as soon as `invalid` clears (the models clear it on typing).
    /// No branch: an `if` here would give the field a new identity when `invalid` flips, and SwiftUI would rebuild it
    /// (the keyboard would drop on the first correcting character). An empty hint reads as no hint.
    func hqFieldValidity(invalid: Bool, message: String?) -> some View {
        accessibilityHint(Text(HQFieldValidity.hint(invalid: invalid, message: message) ?? ""))
    }
}

extension UITextField {
    /// UIKit forms: marks (or clears, with nil) this field as the one at fault and speaks the message once.
    func hqSetInvalid(_ message: String?) {
        accessibilityHint = message.flatMap { HQFieldValidity.hint(invalid: true, message: $0) }
        // With VoiceOver the caller moves focus to the field and the hint speaks; otherwise say it.
        if let message, !message.isEmpty { HQAnnounce.say(message, priority: .high, coalesce: true) }
    }
}
