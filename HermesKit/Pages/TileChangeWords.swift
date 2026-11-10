// [tiles] Change Tile's quick changes (owner 2026-11-10: "the experience when you request a change on a tile needs to be
// greatly improved"): a tap adds a change to the person's own words, a second tap takes it out again. Several can be
// put together ("Make it a bar chart, compare with last month").

import Foundation

nonisolated enum TileChangeWords {
    /// The quick changes: a short name for its chip (dense: several to a line, owner's "too much wasted space"), the
    /// words it adds, and its symbol.
    static let quick: [(label: String, words: String, symbol: String)] = [
        ("Bar Chart", "Make it a bar chart", "chart.bar.fill"),
        ("Vs Last Month", "Compare with last month", "calendar"),
        ("Trend", "Show the trend over time", "chart.line.uptrend.xyaxis"),
        ("Bigger Numbers", "Bigger numbers, fewer words", "textformat.size"),
        ("More Detail", "Show more detail", "list.bullet"),
        ("New Colors", "Change the colors", "paintpalette"),
        ("Fix What’s Wrong", "Fix anything that looks wrong", "wrench.and.screwdriver"),
        ("Update More Often", "Update it more often", "clock.arrow.circlepath"),
    ]

    /// The words already hold this change (any case).
    static func contains(_ text: String, _ change: String) -> Bool {
        text.range(of: change, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// The change added after what's there: on its own when the field is empty, else after a comma (a full stop or
    /// another mark the person ended on is kept), with a small first letter.
    static func adding(_ change: String, to text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return change }
        guard !contains(trimmed, change) else { return text }
        let joiner = trimmed.last.map { ".,;:!?".contains($0) } == true ? " " : ", "
        let start = trimmed.last.map { ".!?".contains($0) } == true ? change : lowerFirst(change)
        return trimmed + joiner + start
    }

    /// The change taken out again, with the comma that joined it; what's left starts with a capital.
    static func removing(_ change: String, from text: String) -> String {
        guard let range = text.range(of: change, options: [.caseInsensitive, .diacriticInsensitive]) else { return text }
        var lower = range.lowerBound, upper = range.upperBound
        // The joiner before it ("…, make it a bar chart"), else the one after it ("Make it a bar chart, …").
        let before = text[text.startIndex..<lower]
        if let comma = before.lastIndex(where: { !$0.isWhitespace }), text[comma] == "," || text[comma] == ";" {
            lower = comma
        } else {
            var after = upper
            while after < text.endIndex, text[after].isWhitespace { after = text.index(after: after) }
            if after < text.endIndex, text[after] == "," || text[after] == ";" {
                after = text.index(after: after)
                while after < text.endIndex, text[after].isWhitespace { after = text.index(after: after) }
                upper = after
            }
        }
        var left = text
        left.removeSubrange(lower..<upper)
        left = left.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = left.first, first == "," || first == ";" {
            left.removeFirst()
            left = left.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return upperFirst(left)
    }

    /// A tap on a quick change: added when it isn't there, taken out when it is.
    static func toggling(_ change: String, in text: String) -> String {
        contains(text, change) ? removing(change, from: text) : adding(change, to: text)
    }

    private static func lowerFirst(_ words: String) -> String {
        guard let first = words.first else { return words }
        // "Make it…" → "make it…"; a word that is capitals throughout ("Otto") stays as it is.
        let firstWord = words.prefix { !$0.isWhitespace }
        if firstWord.count > 1, firstWord == firstWord.uppercased() { return words }
        return first.lowercased() + words.dropFirst()
    }

    private static func upperFirst(_ words: String) -> String {
        guard let first = words.first else { return words }
        return first.uppercased() + words.dropFirst()
    }
}
