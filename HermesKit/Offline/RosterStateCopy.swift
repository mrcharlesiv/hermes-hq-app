// [offline] The Bots list's slow, stale and failed states in words (docs/spec/3x-offline.md §4), from the web app's
// `src/ui-bots/roster-states.tsx` and `roster-empty.tsx`.

import Foundation

nonisolated enum RosterStateCopy {
    /// A first load still on its skeleton after this long says so.
    static let slowAfter: TimeInterval = 15
    static let skeletonRows = 5
    /// Under the slow card the skeleton is shorter.
    static let slowSkeletonRows = 3

    static let slowLoad = "Still loading your bots… Your gateway is taking longer than usual."
    /// The same words on a More page's skeleton (UX study #206).
    static let slowPage = "Still loading… Your gateway is taking longer than usual."
    static let tryAgain = "Try Again"
    static let loadingBots = "Loading bots"

    static let cantLoadTitle = "Couldn’t Load Bots"
    static let waitingReason = "Hermes HQ is waiting for your gateway to reconnect."
    static let busyReason = "Your gateway is busy, so your bots couldn’t load in time."
    static let defaultReason = "The gateway didn’t answer."
    /// The gateway answered the read with an error of its own that is not a sentence for a person.
    static let answeredReason = "Your gateway couldn’t load your bots."

    /// The stale card: the refresh failed and the last good list is still on show.
    static func stale(waiting: Bool, updated: Date?, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let lead = waiting ? "Waiting for your gateway. " : "Can’t refresh bots. "
        guard let updated else { return lead + "Showing the last list." }
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.locale = locale
        style.timeZone = timeZone
        return lead + "Showing the list from \(updated.formatted(style))."
    }

    /// The reason under "Couldn’t Load Bots".
    static func cantLoadReason(connected: Bool, busy: Bool, words: String?) -> String {
        if !connected { return waitingReason }
        if busy { return busyReason }
        return words ?? defaultReason
    }

    /// An error's own words when it has plain ones: the gateway's RPC message or a transport failure's sentence. An
    /// HTTP status, a code or a Swift error dump is never shown (nil → the default sentence).
    static func words(for error: any Error) -> String? {
        let text: String
        if let rpc = error as? RPCError {
            if rpc.isNotConnected || rpc.isConnectionLost { return waitingReason }
            // **DECISION** (stress round 1): the web shows the gateway's message as it came. Hermes writes those for
            // logs ("session not found", an exception's text), so only one that reads as a sentence (a capital first,
            // a full stop last) is shown; anything else becomes the app's own sentence.
            return plain(rpc.message).flatMap { sentence($0) } ?? answeredReason
        } else if let failure = error as? GatewayFailure {
            text = failure.message
        } else {
            return nil
        }
        return plain(text)
    }

    /// `text` when it is written as a sentence: an upper-case first letter and a closing mark.
    static func sentence(_ text: String) -> String? {
        guard let first = text.first, first.isUppercase, let last = text.last, ".!?…".contains(last) else { return nil }
        return text
    }

    static func plain(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4, trimmed.count <= 200, trimmed.contains(" ") else { return nil }
        let raw = ["Error Domain", "NSURLError", "RPCError", "GatewayFailure", "HTTP ", "Traceback", "{", "<", "0x"]
        if raw.contains(where: { trimmed.contains($0) }) { return nil }
        if trimmed.range(of: #"-?\d{3,}"#, options: .regularExpression) != nil { return nil }
        return trimmed
    }
}
