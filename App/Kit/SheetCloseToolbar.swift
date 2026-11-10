// [mac] Mac polish #123: how a SwiftUI sheet closes (Update Hermes, Update Add-on, Account). The iPhone and iPad keep
// the system's ✕ at the leading edge, its word (Done, Not Now, Hide) for VoiceOver. The Mac shows the word itself at the
// trailing edge, in the label colour and `MacCloseItem`'s font, as every other Mac sheet closes
// (`UIBarButtonItem.hqClose`, stress test 2026-10-28 #55): the ✕ in a grey circle at the top left was the iPhone's.

import SwiftUI

struct SheetCloseToolbar: ToolbarContent {
    /// What closing does here: "Done", "Not Now", "Hide".
    var word: String
    var id: String
    /// The iPhone's ✕ says the word to VoiceOver (false: the system's own "Close", as the sheet had).
    var speaksWord = true
    var action: () -> Void

    var body: some ToolbarContent {
        #if targetEnvironment(macCatalyst)
        ToolbarItem(placement: .confirmationAction) {
            Button(action: action) {
                Text(word)
                    .font(Font(MacCloseItem.font(semibold: word == "Done")))   // Done is the default button's weight
                    .foregroundStyle(Color.hqLabel)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(id)
        }
        .sharedBackgroundVisibility(.hidden)   // a word on the bar, not a glass capsule
        #else
        ToolbarItem(placement: .cancellationAction) {
            let close = Button(role: .close, action: action).accessibilityIdentifier(id)
            if speaksWord { close.accessibilityLabel(word) } else { close }
        }
        #endif
    }
}
