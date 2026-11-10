// The Link… dialog's text rules (docs/spec/3x-composer.md §4.2; R:src/fe-convo-r3.ts typedUrl, V:directive-text.tsx
// formatRefValue). Pure.

import Foundation

nonisolated enum LinkText {
    private static let schemeRE = try! NSRegularExpression(pattern: #"^[a-z][a-z\d+.-]*://"#, options: .caseInsensitive)
    private static let hostRE = try! NSRegularExpression(
        pattern: #"^(?:[a-z\d](?:[a-z\d-]*[a-z\d])?\.)+[a-z]{2,}(?::\d{1,5})?$"#, options: .caseInsensitive)
    private static let ipRE = try! NSRegularExpression(pattern: #"^\d{1,3}(?:\.\d{1,3}){3}(?::\d{1,5})?$"#)
    private static let httpRE = try! NSRegularExpression(pattern: #"^https?://."#, options: .caseInsensitive)

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// What was typed, with `https://` added when it is a bare host ("example.com/post"). Nothing else changes.
    static func normalised(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || matches(schemeRE, t) { return t }
        let lower = t.lowercased()
        for prefix in ["mailto:", "tel:", "data:", "blob:", "file:"] where lower.hasPrefix(prefix) { return t }
        let host = String(t.prefix { !"/?#".contains($0) })
        if matches(hostRE, host) || matches(ipRE, host) { return "https://" + t }
        return t
    }

    /// http(s) with at least one character after the slashes.
    static func isLink(_ text: String) -> Bool { matches(httpRE, text) }

    /// "https://example.com/a" -> "example.com/a" for the tray chip.
    static func display(_ url: String) -> String {
        var s = url
        for prefix in ["https://", "http://"] where s.lowercased().hasPrefix(prefix) { s.removeFirst(prefix.count); break }
        return s
    }
}

nonisolated enum RefValue {
    /// `formatRefValue`: bare unless the value has whitespace or one of ()[]{}<>"'` ; backticks preferred, else double
    /// quotes, else single quotes.
    static func format(_ value: String) -> String {
        let special = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "()[]{}<>\"'`"))
        guard value.rangeOfCharacter(from: special) != nil else { return value }
        if !value.contains("`") { return "`\(value)`" }
        if !value.contains("\"") { return "\"\(value)\"" }
        if !value.contains("'") { return "'\(value)'" }
        return value
    }

    static func urlRef(_ url: String) -> String { "@url:" + format(url) }
}
