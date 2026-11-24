// [threads] What a thread starts out knowing (docs/spec/3x-threads.md §3).
//
// A thread is its own session of the same bot, so it does not see the bot chat's transcript. It is created with the
// newest part of that transcript as hidden seed rows (`session.create {messages: [{role, content, display_kind:
// "hidden"}]}`, H/tui_gateway/session_history.py `_coerce_seed_history`): the model reads them, no client draws them.
// Only the newest part goes over: a bot chat is a forever chat, and a copy of all of it would make every thread turn
// as heavy as the main chat's. Pure.

import Foundation

nonisolated enum ThreadSeed {
    /// One seed row, oldest first in a list.
    nonisolated struct Row: Hashable, Sendable {
        enum Role: String, Sendable { case user, assistant }
        var role: Role
        var text: String
    }

    /// The most the seed carries: the newest `maxTurns` rows (after merging neighbours of one role), `maxCharacters`
    /// in all, and `perRowCharacters` of any one row (its start and its end kept).
    static let maxTurns = 24
    static let maxCharacters = 16_000
    static let perRowCharacters = 4_000

    /// The seed for a thread started from a chat showing `messages` (oldest first); empty when that chat has nothing
    /// to tell yet.
    ///
    /// - `running`: a reply is running in that chat. The request it is working on stays at the end of the seed, and the
    ///   closing note says that job belongs to the main chat, so the thread answers its own question and does not start
    ///   the same work a second time.
    /// - `busyReason`: set when an auto-thread starts because the main chat is unavailable (e.g. a background task,
    ///   messaging turn, or busy refusal): emits a busy closing note even when the last visible row is an assistant reply.
    /// - `anchorRow`: the stored row of the message the thread hangs under in that chat. It rides in the closing note,
    ///   so every device draws the thread at the same place (`anchorRow(in:)` reads it back).
    /// - `isSeedable`: false for rows that are not part of the conversation (side answers, notices); the chat knows them.
    static func rows(from messages: [ChatMessage], running: Bool, anchorRow: Int? = nil, busyReason: String? = nil,
                     isSeedable: (ChatMessage) -> Bool = { _ in true }) -> [Row] {
        var merged: [Row] = []
        for message in messages {
            guard message.role != .system, message.sender == nil, message.error == nil, isSeedable(message) else { continue }
            // The reply still arriving is half a thought; the request that started it is enough.
            if message.role == .assistant && message.isStreaming { continue }
            let text = ChatTranscript.blocks(message)
            guard !text.isEmpty else { continue }
            let role: Row.Role = message.role == .user ? .user : .assistant
            if let last = merged.last, last.role == role {
                merged[merged.count - 1].text = last.text + "\n\n" + text
            } else {
                merged.append(Row(role: role, text: text))
            }
        }
        // Newest first, within the limits.
        var kept: [Row] = []
        var budget = maxCharacters
        for row in merged.reversed() {
            guard kept.count < maxTurns, budget > 0 else { break }
            let text = clipped(row.text, to: min(perRowCharacters, budget))
            budget -= text.count
            kept.append(Row(role: row.role, text: text))
        }
        kept.reverse()
        // A conversation opens with the person's words.
        while let first = kept.first, first.role == .assistant { kept.removeFirst() }
        guard !kept.isEmpty else { return [] }
        // The closing note, in the bot's voice, so the roles keep alternating up to the thread's first message.
        let note = closingNote(running: running && kept.last?.role == .user, anchorRow: anchorRow, busyReason: busyReason)
        if kept.last?.role == .assistant {
            kept[kept.count - 1].text += "\n\n" + note
        } else {
            kept.append(Row(role: .assistant, text: note))
        }
        return kept
    }

    /// What the seed ends with: what this chat is, and (machine-read) where it hangs in the main chat.
    static func closingNote(running: Bool, anchorRow: Int?, busyReason: String? = nil) -> String {
        let words: String
        if let busyReason, !busyReason.isEmpty {
            words = "(The main chat is currently busy with \(busyReason). This is a side thread of the same chat: here "
                + "I answer only what is asked in this thread, and I leave that job to the main chat.)"
        } else if running {
            words = "(I am still working on that in the main chat. This is a side thread of the same chat: here I answer only "
                + "what is asked in this thread, and I leave that job to the main chat.)"
        } else {
            words = "(This is a side thread of the main chat above: here I answer only what is asked in this thread.)"
        }
        return anchorRow.map { "\(words) [thread anchor: row \($0)]" } ?? words
    }

    private static let anchorPattern = try! NSRegularExpression(pattern: #"\[thread anchor: row (\d+)\]"#)

    /// The anchor row a seed's closing note carries; nil when `text` holds none.
    static func anchorRow(in text: String) -> Int? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = anchorPattern.matches(in: text, range: range).last, let digits = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[digits])
    }

    /// True when `text` carries one of our thread-seed closing notes (used to heal legacy threads whose gateway
    /// stripped `display_kind: "hidden"` via `_seed_branch_row`).
    static func isClosingNote(_ text: String) -> Bool {
        text.contains("This is a side thread of the same chat: here I answer only what is asked in this thread")
            || text.contains("This is a side thread of the main chat above: here I answer only what is asked in this thread")
    }

    /// `session.create`'s `messages`: every row hidden, so the thread's transcript holds only what is said in it.
    static func params(_ rows: [Row]) -> [JSONValue] {
        rows.map { .object(["role": .string($0.role.rawValue), "content": .string($0.text), "display_kind": "hidden"]) }
    }

    /// `text` within `limit` characters: its start and its end, with the cut marked.
    static func clipped(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let mark = "\n[…]\n"
        guard limit > mark.count + 40 else { return String(text.prefix(max(0, limit))) }
        let room = limit - mark.count
        let head = room * 2 / 3
        return String(text.prefix(head)) + mark + String(text.suffix(room - head))
    }
}
