// Find in chat (parity 240 §5 "Find in chat"; S:build/fe-convo-gates.ts r1-46, r3-13, r4-84): the words on screen,
// counted and stepped through. On touch the web searches only text that is drawn — bubbles, not tool rows, notices,
// slash output or VoiceOver-only labels (r4-84) — so this searches your messages and the bot's prose, one unit per
// bubble, oldest first, case- and diacritic-insensitively.

import Foundation

/// One bubble's searchable text: the bubble's row id ("<message id>|b<part>") and its words as they read on screen.
nonisolated struct ChatFindUnit: Hashable, Sendable {
    var rowId: String
    var messageId: String
    var text: String
}

/// A match: the bubble it sits in and which occurrence of the query it is there (0-based, in reading order).
nonisolated struct ChatFindMatch: Hashable, Sendable {
    var rowId: String
    var messageId: String
    var occurrence: Int
}

nonisolated enum ChatFind {
    static let compareOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// The bubbles the transcript draws for these messages, oldest first, with the text each shows. Mirrors
    /// `ChatRowBuilder`'s bubble ids: your message is "b0" (a voice memo: anything typed with it, "b1"); each
    /// non-empty text part of a reply is "b<part index>". System rows (notices, slash output) are not searched, nor is
    /// another bot's delivery or a cron run: each draws as one folded row, so a match there could be counted but never shown.
    static func units(_ messages: [ChatMessage]) -> [ChatFindUnit] {
        var out: [ChatFindUnit] = []
        for m in messages {
            switch m.role {
            case .system:
                continue
            case .user where m.sender != nil:
                continue
            case .user:
                let text = m.parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: "\n")
                if let memo = VoiceMemo.parse(text) {
                    // The memo's own bubble is an audio message (its transcript folds away): only what was typed with it.
                    if !memo.rest.isEmpty { out.append(ChatFindUnit(rowId: "\(m.id)|b1", messageId: m.id, text: memo.rest)) }
                } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(ChatFindUnit(rowId: "\(m.id)|b0", messageId: m.id, text: text))
                }
            case .assistant:
                for (i, part) in m.parts.enumerated() {
                    guard case .text(let raw) = part, !ReasoningTags.isBlank(raw) else { continue }
                    out.append(ChatFindUnit(rowId: "\(m.id)|b\(i)", messageId: m.id, text: drawnText(raw)))
                }
            }
        }
        return out
    }

    /// A reply part's words as its bubble draws them, so the count only holds matches that can be shown: no hidden
    /// thinking (`<think>…</think>`), a link's words without its address, and no `MEDIA:` line (its picture or file
    /// row is drawn instead of the words).
    static func drawnText(_ markdown: String) -> String {
        var text = ReasoningTags.strip(markdown)
        if text.contains("MEDIA:") {
            text = text.components(separatedBy: "\n").compactMap { line -> String? in
                guard line.contains("MEDIA:") else { return line }
                let tags = MediaTags.renderTags(line)
                return tags.mediaOnly ? nil : tags.text
            }.joined(separator: "\n")
        }
        return ChatTranscript.readableText(text, linkAddresses: false)
    }

    /// The query as searched: as typed, minus leading and trailing spaces ("" finds nothing).
    static func normalized(_ query: String) -> String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Every occurrence of `query` in `text`, in order, never overlapping.
    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        let query = normalized(query)
        guard !query.isEmpty, !text.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex, let found = text.range(of: query, options: compareOptions, range: from..<text.endIndex) {
            out.append(found)
            from = found.upperBound > found.lowerBound ? found.upperBound : text.index(after: found.lowerBound)
        }
        return out
    }

    /// The same occurrences as UTF-16 ranges (for NSAttributedString / TextKit).
    static func nsRanges(of query: String, in text: String) -> [NSRange] {
        ranges(of: query, in: text).map { NSRange($0, in: text) }
    }

    /// Every match in the messages, oldest first.
    static func matches(_ query: String, in messages: [ChatMessage]) -> [ChatFindMatch] {
        let query = normalized(query)
        guard !query.isEmpty else { return [] }
        var out: [ChatFindMatch] = []
        for unit in units(messages) {
            let count = ranges(of: query, in: unit.text).count
            for k in 0..<count { out.append(ChatFindMatch(rowId: unit.rowId, messageId: unit.messageId, occurrence: k)) }
        }
        return out
    }

    /// Where a match is drawn: the bubble that holds it and its occurrence counted across that bubble. A match is found
    /// in one text part of a reply ("<id>|b<part>"), but parts with nothing drawn between them are one bubble under the
    /// first one's id (`bubbleParts`: the part indices the reply's built bubbles start at, nil while unbuilt), so a match
    /// in a later part goes to the bubble that starts at or before it, counted after every match of the parts joined
    /// into that bubble before it.
    static func drawnPlace(of match: ChatFindMatch, bubbleParts: [Int]?, units: [ChatFindUnit], query: String) -> (rowId: String, occurrence: Int) {
        let prefix = "\(match.messageId)|b"
        guard match.rowId.hasPrefix(prefix), let part = Int(match.rowId.dropFirst(prefix.count)),
              let start = bubbleParts?.last(where: { $0 <= part }), start < part else {
            return (match.rowId, match.occurrence)
        }
        var before = 0
        for unit in units where unit.messageId == match.messageId && unit.rowId.hasPrefix(prefix) {
            guard let p = Int(unit.rowId.dropFirst(prefix.count)), p >= start, p < part else { continue }
            before += ranges(of: query, in: unit.text).count
        }
        return ("\(prefix)\(start)", before + match.occurrence)
    }

    /// "2 of 5" (the current match's 1-based place), "No Results" for none, "" before anything is typed. While there are
    /// earlier messages not loaded yet (`hasOlder`) only the loaded ones were searched, so none found reads "No Results
    /// Yet" (the bar offers Search Earlier Messages under it).
    static func countText(current: Int?, total: Int, query: String, hasOlder: Bool = false) -> String {
        if normalized(query).isEmpty { return "" }
        guard total > 0 else { return hasOlder ? "No Results Yet" : "No Results" }
        return "\((current ?? 0) + 1) of \(total)"
    }

    /// The match to show after the matches changed: the same one when it is still there, otherwise the newest (the one
    /// nearest the end of the chat, where the reader is).
    static func keepCurrent(_ previous: ChatFindMatch?, in matches: [ChatFindMatch]) -> Int? {
        guard !matches.isEmpty else { return nil }
        if let previous, let same = matches.firstIndex(of: previous) { return same }
        return matches.count - 1
    }

    /// Steps forward (newer, `down`) or back (older), wrapping around as the find bars of iOS do.
    static func step(_ current: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return forward ? 0 : count - 1 }
        return forward ? (current + 1) % count : (current - 1 + count) % count
    }
}
