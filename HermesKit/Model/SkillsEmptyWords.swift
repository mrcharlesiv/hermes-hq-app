// What Capabilities › Skills says when a bot has no skills installed (UX study 2026-10-19 #55: a bare "No skills yet."
// with no next step). Pure, so the words are unit-tested without SwiftUI.

import Foundation

nonisolated struct SkillsEmptyWords: Equatable, Sendable {
    var title: String
    var text: String
    /// The search button's title, or nil when a search could only answer "No Results" (nothing left to install).
    var action: String?

    /// `hasAvailable`: Hermes offers skills this bot hasn't installed (listed under the empty card).
    static func make(botName: String, hasAvailable: Bool) -> SkillsEmptyWords {
        hasAvailable
            ? SkillsEmptyWords(title: "No Skills Installed",
                               text: "Install one from the list below, or ask \(botName) in a chat to make one.",
                               action: "Search Skills")
            : SkillsEmptyWords(title: "No Skills Installed", text: "Ask \(botName) in a chat to make one.", action: nil)
    }
}
