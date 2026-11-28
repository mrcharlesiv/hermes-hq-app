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

    /// On the Mac the field follows System Settings › Keyboard › Text Input (Correct spelling automatically, and the
    /// field's own Edit › Spelling and Grammar): a tester 2026-11-17 had correction off there and the field still
    /// changed commands and names, because it asked for correction outright. The iPhone and iPad ask for it as Messages.
    static let followsSystem: Bool = {
        #if targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }()

    /// On Mac Catalyst, `UITextView` with `.default` does not honor macOS's System Settings › Keyboard › Text Input
    /// "Use smart quotes and dashes" toggle (`NSAutomaticQuoteSubstitutionEnabled` / `NSAutomaticDashSubstitutionEnabled`).
    /// When the user explicitly turns that preference off, return `.no` so straight quotes and dashes stay untouched.
    static var systemSmartQuotesEnabled: Bool? {
        UserDefaults.standard.object(forKey: "NSAutomaticQuoteSubstitutionEnabled") as? Bool
    }

    static var systemSmartDashesEnabled: Bool? {
        UserDefaults.standard.object(forKey: "NSAutomaticDashSubstitutionEnabled") as? Bool
    }

    static func smartQuotesType(followsSystem: Bool = Self.followsSystem,
                                systemEnabled: Bool? = Self.systemSmartQuotesEnabled) -> UITextSmartQuotesType {
        followsSystem && systemEnabled == false ? .no : .default
    }

    static func smartDashesType(followsSystem: Bool = Self.followsSystem,
                                systemEnabled: Bool? = Self.systemSmartDashesEnabled) -> UITextSmartDashesType {
        followsSystem && systemEnabled == false ? .no : .default
    }

    @MainActor static func apply(to textView: UITextView) {
        textView.autocorrectionType = followsSystem ? .default : .yes
        textView.spellCheckingType = followsSystem ? .default : .yes
        textView.autocapitalizationType = .sentences
        textView.smartQuotesType = smartQuotesType()
        textView.smartDashesType = smartDashesType()
        textView.smartInsertDeleteType = .default
        textView.inlinePredictionType = .default
        textView.keyboardType = .default
        textView.returnKeyType = .default      // reads "return"
    }
}
