// [diagnostics] What leaves the phone through Copy Diagnostics and the performance log keeps the failure's own words
// and loses recognizable private values: a faithful port of the web app's `src/diagnostics-redact.ts`, rule for rule
// and in the same order (docs/spec/3x-diagnostics.md §5). Runs when an error is stored, when it is shown, and line by
// line on export. Idempotent, and linear in the text's length (longer text is cut to 64 K first).
//
// Offsets are UTF-16 code units throughout, as in the web app, so its test vectors give the same answers here.

import Foundation

nonisolated enum DiagnosticRedactor {
    static let mask = "[redacted]"
    static let limit = 64 * 1024

    static func redact(_ input: String) -> String {
        var text = input as NSString
        let cut = text.length > limit
        if cut { text = text.substring(to: limit) as NSString }
        // Overlapping rules can expose another match (a short value inside a long quote); a few passes settle it.
        for _ in 0..<4 {
            let safe = redactOnce(text)
            if safe.isEqual(to: text as String) { break }
            text = safe
        }
        // A long quote left open is still echoed input. A lone apostrophe is usually one ("can't"), so it only counts
        // after our own cut.
        return openQuote(text, opens: cut ? "\"'\u{201C}\u{2018}`" : "\"\u{201C}\u{2018}`", closes: cut ? "\"'\u{201D}\u{2019}`" : "\"\u{201D}\u{2019}`")
    }

    // MARK: Patterns

    private static let stop = #"\s"'<>\x60“”‘’"#
    /// A quote escaped with a backslash never opens one; \"…\" is its own form. The loops are unrolled and possessive
    /// (same matches as the web's alternation) so a 64 K quote costs no backtracking stack.
    private static let quoted = [
        #"(?<!\\)"[^"\\]*+(?:\\[\s\S][^"\\]*+)*+""#,
        #"(?<!\\)'[^'\\]*+(?:\\[\s\S][^'\\]*+)*+'"#,
        #"“[^“”]*+”"#,
        #"‘[^‘’]*+’"#,
        #"\x60[^\x60]*+\x60"#,
        #"\\"[^"\\]*+(?:\\[^"][^"\\]*+)*+\\""#,
    ].joined(separator: "|")
    private static let keys = "password|passwd|pwd|passphrase|secret|token|api[ _-]?key|x-api-key|private_key|credentials?|signature|sig|ticket|otp|session|sessionid|sid|authorization|cookie"
    /// A quote never closed (the error was cut inside a value): its value runs to the end of the text.
    private static let unclosed = #"(?<!\\)"[^"]*+\z|(?<!\\)'[^']*+\z|“[^”]*+\z|‘[^’]*+\z|\x60[^\x60]*+\z|\\"[^"]*+\z"#

    private static func regex(_ pattern: String, insensitive: Bool = false) -> NSRegularExpression {
        // The patterns are constants; a typo fails the first unit test, never a user.
        try! NSRegularExpression(pattern: pattern, options: insensitive ? [.caseInsensitive] : [])
    }

    private static let pem = regex(#"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----[\s\S]*?(?:-----END (?:[A-Z0-9]+ )*PRIVATE KEY-----|\z)"#)
    private static let quotedRun = regex(quoted)
    private static let content = regex(#"(\\?["'](?:text|content|body|prompt|transcript|delta|input|output|arguments)\\?["'][ \t\r\n]*:[ \t\r\n]*)(?:("# + quoted + #")|([\[{]))"#, insensitive: true)
    private static let header = regex(#"\b((?:Proxy-Authorization|Authorization|Set-Cookie|Cookie)[ \t]*:[ \t]*)[^\r\n]*"#, insensitive: true)
    private static let userInfo = regex(#"\b([a-z][a-z0-9+.-]{0,31}://)[^\s/?#@"'<>\x60“”‘’]*@"#, insensitive: true)
    private static let assigned = regex(#"(\b[A-Za-z0-9_]*?(?:"# + keys + #")(?:\\?["'])?[ \t\r\n]*[:=][ \t\r\n]*)(?:"# + quoted + "|" + unclosed + #"|\[redacted\]|[^\s,;"'\x60}\]\)\\]+)"#, insensitive: true)
    private static let bearer = regex(#"\b(Bearer)[ \t]+(?:\[redacted\]|[^\s,;"'`}\]\)]+)"#, insensitive: true)
    private static let scheme = regex(#"\b(Basic|Token)[ \t]+([A-Za-z0-9+/._~-]{12,}=*)"#, insensitive: true)
    private static let provider = regex(#"\b(?:sk-[A-Za-z0-9_-]{8,}|[rs]k_(?:live|test)_[A-Za-z0-9]{20,}|(?:xai-|gsk_|pplx-|r8_|hf_)[A-Za-z0-9]{20,}|gh[pousr]_[A-Za-z0-9_]{8,}|github_pat_[A-Za-z0-9_]{30,}|glpat-[A-Za-z0-9_-]{20,}|xox[abprs]-[A-Za-z0-9-]{8,}|AIza[0-9A-Za-z_-]{35}|(?:AKIA|ASIA)[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{2,1024}+\.[A-Za-z0-9_-]++\.[A-Za-z0-9_-]*)\b"#)
    private static let longRun = regex(#"\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b|[A-Za-z0-9]{24,}"#, insensitive: true)

    // MARK: One pass

    private static func redactOnce(_ input: NSString) -> NSString {
        var text = replace(pem, in: input) { _, _ in mask }
        // Long quoted text in an error is echoed input (a message, a body), not the error's own words.
        text = replace(quotedRun, in: text) { match, source in
            let run = source.substring(with: match.range) as NSString
            return run.length - (run.character(at: 0) == backslash ? 4 : 2) > 80 ? requote(run, mask) : nil
        }
        text = redactContent(text)
        text = replace(header, in: text) { match, source in source.substring(with: match.range(at: 1)) + mask }
        text = replace(userInfo, in: text) { match, source in source.substring(with: match.range(at: 1)) + mask + "@" }
        // A URL's (or a /path's) query and fragment carry tickets, file paths and search text; the path stays.
        text = redactQueries(text)
        text = replace(assigned, in: text) { match, source in source.substring(with: match.range(at: 1)) + mask }
        text = replace(bearer, in: text) { match, source in source.substring(with: match.range(at: 1)) + " " + mask }
        // "Token expired" and "Basic auth" are words; a credential after them has a digit, padding or mixed case.
        text = replace(scheme, in: text) { match, source in
            let value = source.substring(with: match.range(at: 2))
            let rest = value.dropFirst()
            let secret = value.contains(where: \.isASCIIDigit) || value.hasSuffix("=")
                || (value.contains(where: \.isASCIILower) && rest.contains(where: \.isASCIIUpper))
            return secret ? source.substring(with: match.range(at: 1)) + " " + mask : nil
        }
        text = replace(provider, in: text) { _, _ in mask }
        // UUID-shaped keys are indistinguishable from session ids in unstructured errors.
        text = replace(longRun, in: text) { match, source in
            let run = source.substring(with: match.range)
            if run.contains("-") { return mask }
            if run.contains(where: \.isASCIIDigit) && run.contains(where: { $0.isASCIILower || $0.isASCIIUpper }) { return mask }
            return run.utf16.count >= 32 && run.allSatisfy(\.isHexDigit) ? mask : nil
        }
        return text
    }

    private static let backslash: unichar = 0x5C

    /// A quoted run with `inner` between its own quote marks (\" is two characters).
    private static func requote(_ quoted: NSString, _ inner: String) -> String {
        let edge = quoted.character(at: 0) == backslash ? 2 : 1
        return quoted.substring(to: edge) + inner + quoted.substring(from: quoted.length - edge)
    }

    /// Every match replaced by what `with` answers; nil keeps the match as it is.
    private static func replace(_ regex: NSRegularExpression, in text: NSString, with: (NSTextCheckingResult, NSString) -> String?) -> NSString {
        let matches = regex.matches(in: text as String, range: NSRange(location: 0, length: text.length))
        guard !matches.isEmpty else { return text }
        let out = NSMutableString(capacity: text.length)
        var last = 0
        for match in matches {
            guard match.range.length > 0, let replacement = with(match, text) else { continue }
            out.append(text.substring(with: NSRange(location: last, length: match.range.location - last)))
            out.append(replacement)
            last = NSMaxRange(match.range)
        }
        out.append(text.substring(from: last))
        return out
    }

    // MARK: Content keys (`redactContent`, `bracketEnd`)

    private static func redactContent(_ text: NSString) -> NSString {
        let whole = text as String
        var units: [unichar]?
        let out = NSMutableString()
        var last = 0
        while last < text.length,
              let match = content.firstMatch(in: whole, range: NSRange(location: last, length: text.length - last)) {
            let prefix = match.range(at: 1)
            let quote = match.range(at: 2)
            let end: Int
            if quote.location != NSNotFound {
                end = NSMaxRange(match.range)
            } else {
                if units == nil { units = Array(whole.utf16) }
                end = bracketEnd(units!, NSMaxRange(prefix))
            }
            out.append(text.substring(with: NSRange(location: last, length: match.range.location - last)))
            out.append(text.substring(with: prefix))
            out.append(quote.location != NSNotFound ? requote(text.substring(with: quote) as NSString, mask) : mask)
            last = end
        }
        if last == 0 { return text }
        out.append(text.substring(from: min(last, text.length)))
        return out
    }

    /// A content key's array or object value, to its closing bracket (or the end of the text). Strings inside are
    /// skipped, so a bracket in one doesn't count.
    private static func bracketEnd(_ text: [unichar], _ start: Int) -> Int {
        var depth = 0
        var at = start
        while at < text.count {
            let char = text[at]
            if char == 0x22 {
                at += 1
                while at < text.count, text[at] != 0x22 { at += text[at] == backslash ? 2 : 1 }
            } else if char == 0x5B || char == 0x7B {
                depth += 1
            } else if char == 0x5D || char == 0x7D {
                depth -= 1
                if depth == 0 { return at + 1 }
            }
            at += 1
        }
        return text.count
    }

    // MARK: Queries and fragments

    /// The web's `QUERY` uses a look-behind of any length, which ICU refuses; this is the same rule as one scan. A `?`
    /// or `#` counts when the run before it (back to a stop character or another `?`/`#`) holds a `/` that starts the
    /// text or follows something that is neither a word character nor `/`. It is masked up to a stop character or `)`.
    private static func redactQueries(_ text: NSString) -> NSString {
        let units = Array((text as String).utf16)
        guard units.contains(where: { $0 == 0x3F || $0 == 0x23 }) else { return text }
        var out: [unichar] = []
        out.reserveCapacity(units.count)
        let maskUnits = Array(mask.utf16)
        var path = false
        var at = 0
        while at < units.count {
            let char = units[at]
            if char == 0x3F || char == 0x23 {
                var end = at + 1
                while end < units.count, !isStop(units[end]), units[end] != 0x29 { end += 1 }
                if path, end > at + 1 {
                    out.append(char)
                    out.append(contentsOf: maskUnits)
                    at = end
                    path = false
                    continue
                }
                path = false
            } else if isStop(char) {
                path = false
            } else if char == 0x2F {
                if at == 0 || !(isWord(units[at - 1]) || units[at - 1] == 0x2F) { path = true }
            }
            out.append(char)
            at += 1
        }
        return NSString(characters: out, length: out.count)
    }

    private static func isWord(_ c: unichar) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F
    }

    /// JavaScript's `\s` plus the quote marks and angle brackets of the web's STOP set.
    private static func isStop(_ c: unichar) -> Bool {
        switch c {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
        case 0x22, 0x27, 0x3C, 0x3E, 0x60, 0x201C, 0x201D, 0x2018, 0x2019: true
        default: false
        }
    }

    // MARK: Open quote

    /// The first opening mark after the last closing one, with 80+ characters after it, masked to the end: one scan
    /// back and one forward.
    private static func openQuote(_ text: NSString, opens: String, closes: String) -> String {
        let units = Array((text as String).utf16)
        let opening = Set(opens.utf16), closing = Set(closes.utf16)
        var at = units.count - 1
        while at >= 0, !closing.contains(units[at]) { at -= 1 }
        if at < 0 || !opening.contains(units[at]) {
            at += 1
            while at < units.count, !opening.contains(units[at]) { at += 1 }
        }
        guard at < units.count, units.count - at - 1 >= 80 else { return text as String }
        return text.substring(to: at + 1) + mask
    }
}

private extension Character {
    nonisolated var isASCIIDigit: Bool { isASCII && isNumber }
    nonisolated var isASCIILower: Bool { isASCII && isLowercase }
    nonisolated var isASCIIUpper: Bool { isASCII && isUppercase }
}
