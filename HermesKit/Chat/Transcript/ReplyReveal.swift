// [transcript] Reply reveal (docs/spec/3x-transcript.md §3.9, row L321): a reply that arrives whole (a provider that
// does not stream sends the finished reply as one message.delta) is drawn a few words at a time, over well under a
// second. Only the drawing is paced; the model has the whole text at once. Ported from `S/ui-chat/reply-reveal.ts`.

import Foundation

nonisolated enum ReplyReveal {
    /// A delta this long arrived whole: a streamed one is a few tokens.
    static let wholeReplyChars = 60
    /// About a phone screen of reply text; past it the rest lands at once.
    static let revealChars = 1200
    static let minMs = 280.0
    static let maxMs = 700.0
    /// A delta this soon after the previous one belongs to a stream.
    static let streamGapMs = 1000.0
    /// A reveal nothing drew within this long is dropped.
    static let claimMs = 1500.0
    static let stepMs = 33.0
    static let charsPerMs = 1.6

    /// How long the reveal of `count` characters takes, in milliseconds.
    static func duration(chars count: Int) -> Double {
        min(maxMs, max(minMs, Double(min(count, revealChars)) / charsPerMs))
    }

    /// The character counts shown at each step (increasing; the last is the whole text). Cuts land after a space
    /// where one is near and never inside a character (Swift characters keep surrogate pairs and emoji whole).
    static func ends(_ text: String) -> [Int] {
        let chars = Array(text)
        let total = chars.count
        let shown = min(total, revealChars)
        let count = max(2, Int((duration(chars: total) / stepMs).rounded()))
        var out: [Int] = []
        var start = 0
        var index = 1
        while index < count && start < shown {
            defer { index += 1 }
            var end = Int((Double(shown) * Double(index) / Double(count)).rounded())
            if end <= start { continue }
            var space = -1
            var probe = end
            while probe < min(total, end + 16) {
                if chars[probe].isWhitespace { space = probe - end; break }
                probe += 1
            }
            if space >= 0 { end += space + 1 }
            if end >= total { break }
            out.append(end)
            start = end
        }
        out.append(total)
        return out
    }

    /// Whether a delta starts a reveal: long enough, the turn's first delta or more than a second after the previous
    /// one, and not a replayed frame.
    static func isWhole(deltaLength: Int, msSincePreviousDelta: Double?, replayed: Bool) -> Bool {
        guard !replayed, deltaLength >= wholeReplyChars else { return false }
        if let gap = msSincePreviousDelta, gap < streamGapMs { return false }
        return true
    }

    /// How many characters to draw `elapsedMs` after the reveal started; nil once it is over.
    static func limit(ends: [Int], elapsedMs: Double) -> Int? {
        guard ends.count > 1 else { return nil }
        let step = Int((max(0, elapsedMs) / stepMs).rounded(.down))
        if step >= ends.count - 1 { return nil }
        return ends[step]
    }
}
