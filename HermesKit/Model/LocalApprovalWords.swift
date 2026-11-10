// What the app says when Approve or Deny on a local approval alert didn't reach the gateway (UX study 2026-10-19
// #138): it opened the chat and said nothing, so the person thought they had answered while the bot kept waiting. The
// card in that chat is open again, so the words point there. Pure, so the choice is unit-tested without UIKit.

import Foundation

nonisolated enum LocalApprovalWords {
    /// The card's own buttons (UX study #259: it has Run and Reject, not the alert's Approve and Deny).
    static let notSent = "Your answer didn’t reach Hermes. \(DeviceWord.Tap) Run or Reject on the card in the chat to try again."
    /// [#256] The request wasn't there to answer: the push plugin's own words for a resolved request.
    static let gone = "That request was already answered or had expired."
    static func sent(approve: Bool) -> String { approve ? "Approved" : "Denied" }

    static func title(approve: Bool) -> String { approve ? "Couldn’t Approve" : "Couldn’t Deny" }

    /// Offline: the center's own sentence (it already says to reconnect and send again); anything else: `notSent`.
    static func reason(for error: any Error) -> String {
        if let answer = error as? PromptAnswerError, answer.offline { return answer.message }
        return notSent
    }
}
