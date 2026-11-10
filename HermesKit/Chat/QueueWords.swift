// [m9/composer] The queue card's words (docs/spec/3x-composer.md §15.3, §16), the web's strings exactly
// (S:ui-chat/queue-view.tsx). Pure, unit tested in Tests/Composer.

import Foundation

nonisolated enum QueueWords {
    /// The card's header for `count` waiting messages.
    static func header(count: Int, paused: Bool, running: Bool) -> String {
        let one = count <= 1
        if paused { return one ? "Queue Paused" : "Queue Paused · \(count) Messages" }
        if running { return one ? "Queued · Sends After This Reply" : "\(count) Queued · Send After This Reply" }
        return one ? "Queued" : "\(count) Queued"
    }

    /// What VoiceOver reads for the header ("Queue paused, 2 messages").
    static func spokenHeader(count: Int, paused: Bool, running: Bool) -> String {
        let messages = count == 1 ? "1 message" : "\(count) messages"
        if paused { return "Queue paused, \(messages)" }
        if running { return "\(messages) queued, \(count == 1 ? "sends" : "send") after this reply" }
        return "\(messages) queued"
    }

    /// Resume shows only while the queue is paused and something waits.
    static func showsResume(count: Int, paused: Bool) -> Bool { paused && count > 0 }

    /// The caption under a row (spec §15.3): "Sending…" while it goes into the reply, "Editing" while its words are in
    /// the composer, else what is attached beside its words ("2 Photos"); nil for none.
    static func caption(sending: Bool, editing: Bool, attached: String?) -> String? {
        if sending { return "Sending…" }
        if editing { return "Editing" }
        return attached
    }

    /// VoiceOver's name for a row's ⋯: "More, " and the row's opening words, so each ⋯ says which message it is for.
    static func moreLabel(_ words: String) -> String {
        let flat = words.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !flat.isEmpty else { return "More" }
        let short = flat.count > 40 ? String(flat.prefix(40)).trimmingCharacters(in: .whitespaces) + "…" : flat
        return "More, " + short
    }

    /// The message field when a queued edit's row is gone by Save (its words can't go back in place): the edited words,
    /// over whatever the field held before the edit (nothing typed is lost either way).
    static func editedField(current: String, queued: String) -> String {
        let typed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty { return queued }
        if queued.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return current }
        var kept = current
        while kept.last?.isWhitespace == true { kept.removeLast() }
        return kept + "\n" + queued
    }
}
