// [m9/composer] The message field's keyboard rules (docs/spec/3x-composer.md §2): autocorrect, spell-check and
// capitals as in Messages, a field of leftover line breaks counts as blank, and what a send carries. The text rules
// are pure and unit tested in Tests/Composer.

import UIKit

nonisolated enum ComposerKeyboard {
    /// Only line breaks (with or without spaces around them): the leftover of a Return in an empty field. Plain
    /// spaces alone are left, so typing a space does not fight the person.
    static func isLeftoverLineBreaks(_ text: String) -> Bool {
        text.contains(where: \.isNewline) && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What a send carries: no leading or trailing white space or line breaks; blank lines inside stay.
    static func sendText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor static func apply(to textView: UITextView) {
        textView.autocorrectionType = .yes
        textView.spellCheckingType = .yes
        textView.autocapitalizationType = .sentences
        textView.smartQuotesType = .default
        textView.smartDashesType = .default
        textView.smartInsertDeleteType = .default
        textView.inlinePredictionType = .default
        textView.keyboardType = .default
        textView.returnKeyType = .default      // reads "return"
    }
}
