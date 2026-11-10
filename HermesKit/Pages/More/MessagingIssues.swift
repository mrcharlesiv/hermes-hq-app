// What More's Messaging row says when a messaging app is failing (UX study 2026-10-19 #118: a refused bot token only
// showed once Command Center (now Status & Maintenance) or Messaging was opened). An issue is a platform whose status line is red (`MessagingStatus`
// tone `.bad`): an error, a failed start. Pure, so the rule is unit-tested without UIKit.

import Foundation

nonisolated enum MessagingIssues {
    struct RowWords: Equatable, Sendable {
        /// "1 Issue", "2 Issues": the row's trailing red value.
        var text: String
        /// For VoiceOver after the title: "Telegram: bot token was refused".
        var spoken: String
    }

    static func failing(_ platforms: [MessagingPlatform]) -> [MessagingPlatform] {
        platforms.filter { MessagingStatus($0).tone == .bad }
    }

    /// Nil when nothing is failing.
    static func rowWords(_ platforms: [MessagingPlatform]) -> RowWords? {
        let failing = failing(platforms)
        guard !failing.isEmpty else { return nil }
        let text = failing.count == 1 ? "1 Issue" : "\(failing.count) Issues"
        let spoken = failing.map { "\($0.name.isEmpty ? $0.id : $0.name): \(MessagingStatus($0).text)" }.joined(separator: ". ")
        return RowWords(text: text, spoken: spoken)
    }
}
