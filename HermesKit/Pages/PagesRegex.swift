// A small NSRegularExpression wrapper for the pages' word and collector ports: the web's patterns are copied as they
// are, so the ports read like their sources. Compiled once (static lets); thread-safe.

import Foundation

nonisolated final class RX: @unchecked Sendable {
    let regex: NSRegularExpression

    init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        // The patterns are constants in this module: a typo is a programming error caught by the unit tests.
        regex = try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: RX] = [:]

    /// A compiled pattern from a process-wide cache (patterns written inline in a function compile once).
    static func c(_ pattern: String, _ options: NSRegularExpression.Options = []) -> RX {
        let key = "\(options.rawValue)|" + pattern
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        let made = RX(pattern, options)
        cache[key] = made
        return made
    }

    private static func range(_ s: String) -> NSRange { NSRange(s.startIndex..<s.endIndex, in: s) }

    func test(_ s: String) -> Bool { regex.firstMatch(in: s, range: Self.range(s)) != nil }

    /// Groups of the first match (index 0 = whole match); nil groups that did not take part.
    func exec(_ s: String) -> [String?]? {
        guard let m = regex.firstMatch(in: s, range: Self.range(s)) else { return nil }
        return Self.groups(m, in: s)
    }

    /// Every match: groups plus the whole match's start offset (UTF-16) and its end.
    func all(_ s: String) -> [Match] {
        regex.matches(in: s, range: Self.range(s)).map { m in
            Match(groups: Self.groups(m, in: s), range: m.range)
        }
    }

    struct Match {
        var groups: [String?]
        var range: NSRange
        subscript(i: Int) -> String? { i < groups.count ? groups[i] : nil }
    }

    /// `String.replace(re, template)` with `$1`-style templates (global when the pattern is used for all matches).
    func replace(_ s: String, with template: String, all: Bool = true) -> String {
        if all {
            return regex.stringByReplacingMatches(in: s, range: Self.range(s), withTemplate: template)
        }
        guard let m = regex.firstMatch(in: s, range: Self.range(s)), let r = Range(m.range, in: s) else { return s }
        let replacement = regex.replacementString(for: m, in: s, offset: 0, template: template)
        return s.replacingCharacters(in: r, with: replacement)
    }

    /// Replace each match with what `transform` returns for its groups.
    func replace(_ s: String, all: Bool = true, _ transform: ([String?]) -> String) -> String {
        let matches = regex.matches(in: s, range: Self.range(s))
        guard !matches.isEmpty else { return s }
        var out = ""
        var cursor = s.startIndex
        for m in all ? matches : [matches[0]] {
            guard let r = Range(m.range, in: s) else { continue }
            out += s[cursor..<r.lowerBound]
            out += transform(Self.groups(m, in: s))
            cursor = r.upperBound
        }
        out += s[cursor...]
        return out
    }

    /// First match's UTF-16 offset, or -1 (`String.search`).
    func search(_ s: String) -> Int {
        guard let m = regex.firstMatch(in: s, range: Self.range(s)) else { return -1 }
        return m.range.location
    }

    private static func groups(_ m: NSTextCheckingResult, in s: String) -> [String?] {
        (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            guard r.location != NSNotFound, let range = Range(r, in: s) else { return nil }
            return String(s[range])
        }
    }
}

nonisolated extension String {
    /// UTF-16 based slicing, like JS `slice` (the ports keep JS indices).
    func pgSlice(_ from: Int, _ to: Int? = nil) -> String {
        let units = Array(utf16)
        let n = units.count
        func clamp(_ i: Int) -> Int { i < 0 ? max(0, n + i) : min(i, n) }
        let a = clamp(from), b = clamp(to ?? n)
        guard a < b else { return "" }
        return String(decoding: units[a..<b], as: UTF16.self)
    }

    var pgTrim: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// JS `trimStart`.
    var pgTrimStart: String {
        guard let i = firstIndex(where: { !$0.isWhitespace }) else { return "" }
        return String(self[i...])
    }
}
