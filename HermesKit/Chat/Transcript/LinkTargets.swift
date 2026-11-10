// [transcript] Where a tapped link goes (docs/spec/3x-transcript.md §7.1, rows L311 and L982). Ported from
// `S/ios-links.ts`: a web page opens inside the app; a page on the gateway computer's own loopback can't open on the
// phone and says so; anything else that isn't mail or a phone number is refused in words.

import Foundation

nonisolated enum LinkTarget: Equatable, Sendable {
    /// http(s) to somewhere the phone can reach: the in-app Safari view.
    case page(URL)
    /// mailto:, tel:, sms:, facetime: — the system's own app.
    case system(URL)
    /// A page on the gateway computer itself (localhost, 127.0.0.0/8, ::1, 0.0.0.0).
    case loopback
    case refused
}

nonisolated enum LinkTargets {
    /// `device`: "iPhone" or "iPad" (the web says "your phone").
    static func loopbackNotice(device: String) -> String {
        "This page runs on \(HostWord.phrase), so it can’t open on your \(device)."
    }
    static let refusedNotice = "This link can’t be opened here."

    static func isLoopback(host: String) -> Bool {
        var h = host.lowercased()
        if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        if h.hasSuffix(".") { h.removeLast() }
        if let zone = h.firstIndex(of: "%") { h = String(h[..<zone]) }   // an IPv6 zone ("::1%lo0")
        if h == "localhost" || h.hasSuffix(".localhost") { return true }
        // Every spelling of the gateway computer's own address: 127.0.0.0/8 and 0.0.0.0 however they are written
        // ("127.1", "2130706433", "0177.0.0.1", "0x7f.0.0.1"), ::1, ::, and an IPv4 address carried inside an IPv6 one
        // ("::ffff:127.0.0.1", "::ffff:7f00:1").
        func loopback4(_ b: ArraySlice<UInt8>) -> Bool { b.first == 127 || b.allSatisfy { $0 == 0 } }
        var v4 = in_addr()
        if !h.contains(":"), inet_aton(h, &v4) != 0 {
            return loopback4(withUnsafeBytes(of: v4.s_addr) { Array($0) }[...])
        }
        var v6 = in6_addr()
        guard h.contains(":"), inet_pton(AF_INET6, h, &v6) == 1 else { return false }
        let b = withUnsafeBytes(of: v6) { Array($0) }
        if b[..<15].allSatisfy({ $0 == 0 }) { return b[15] <= 1 }                       // :: and ::1
        let mapped = b[..<10].allSatisfy { $0 == 0 } && b[10] == 0xff && b[11] == 0xff   // ::ffff:a.b.c.d
        let compatible = b[..<12].allSatisfy { $0 == 0 }                                 // ::a.b.c.d
        return (mapped || compatible) && loopback4(b[12...])
    }

    static func target(_ url: URL) -> LinkTarget {
        switch url.scheme?.lowercased() {
        case "http", "https":
            guard let host = url.host, !host.isEmpty else { return .refused }
            return isLoopback(host: host) ? .loopback : .page(url)
        case "mailto", "tel", "sms", "facetime", "facetime-audio": return .system(url)
        default: return .refused
        }
    }
}

/// A file path a bot names in inline code (`/Users/me/.hermes/profiles/otto/research/report.md`): a link in its reply
/// that opens the file in the chat's Files (owner, 2026-10-29: "I need it to be clickable so that it opens up in the
/// files"). Bots are asked to put every path in backticks (docs/spec/3x-onboarding.md), so the span is the whole path;
/// one written out in the words links too (`bare(in:)`).
/// Only a place on the gateway computer counts: absolute ("/…", "~/…", "C:\…"), and either a name with an extension
/// or a home or system folder at the root, so an API route ("/api/fs/list") or a command ("/new") stays code. A line
/// number after the name (":12", ":12:5") is left off.
nonisolated enum FileLinks {
    static let prefix = "#file:"

    /// Top folders that are places on a computer even without a file name ("/Users/me/Projects/app").
    private static let roots: Set<String> = ["Users", "home", "root", "tmp", "private", "var", "etc", "opt", "usr", "Volumes",
                                             "Applications", "Library", "mnt", "srv", "workspace"]
    private static let lineNumber = TRx(#":\d+(?::\d+)?$"#)
    private static let drive = TRx(#"^[A-Za-z]:[\\/]"#)

    /// The path inline code names, or nil when the code is something else.
    static func path(inCode code: String) -> String? {
        var path = code.trimmingCharacters(in: .whitespaces)
        guard path.count >= 4, path.count <= 1024, !path.contains(where: \.isNewline),
              !path.contains(where: { "*?{}<>|$`\"';&".contains($0) }) else { return nil }   // a pattern or a command
        path = lineNumber.replace(path, with: "")
        let windows = drive.test(path)
        let home = path.hasPrefix("~/")
        guard windows || home || (path.hasPrefix("/") && !path.hasPrefix("//")) else { return nil }
        let parts = path.split(whereSeparator: { $0 == "/" || (windows && $0 == "\\") })
        guard let last = parts.last else { return nil }
        let named = hasExtension(String(last))
        // Words after a space are a command's arguments ("/usr/bin/env python3"), unless the name ends the path.
        if path.contains(where: \.isWhitespace), !named || path.contains(" -") { return nil }
        if windows || home { return parts.count >= 2 ? path : nil }
        guard parts.count >= 2 else { return nil }   // "/new", "/README.md"
        return named || roots.contains(String(parts[0])) ? path : nil
    }

    /// A path written out in the words rather than in backticks (Otto's "Files:" list, owner 2026-10-30: "The files
    /// mentioned in this aren't clickable"): it starts a word ("/…", "~/…", "C:\…") and runs to the next space, less
    /// the sentence punctuation, quote or unopened bracket after it. Not part of a word, a web address or another path
    /// ("and/or", "24/7", "example.com/a.md"); the rest is `path(inCode:)`'s rules, so a word holding a pattern
    /// ("/Users/me/*.md") stays words. A name with spaces only links in backticks.
    private static let bareWord = TRx(#"(?<![\w/\\:.~@%+=-])(?:~/|/(?!/)|[A-Za-z]:\\)[^\s`]+"#)

    /// Each bare path in prose text: the UTF-16 range it is drawn in (a line number stays inside) and the path it opens.
    static func bare(in text: String) -> [(range: NSRange, path: String)] {
        guard text.contains("/") || text.contains("\\") else { return [] }
        let ns = text as NSString
        return bareWord.re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            var drawn = ns.substring(with: m.range)
            while let last = drawn.last, trails(last, drawn) { drawn.removeLast() }
            guard let path = path(inCode: drawn) else { return nil }
            return (NSRange(location: m.range.location, length: (drawn as NSString).length), path)
        }
    }

    /// The last character of a word is the sentence's, not the path's: "report.md." / "(see /a/b.md)" / "\"/a/b.md\"".
    private static func trails(_ c: Character, _ word: String) -> Bool {
        switch c {
        case ".", ",", ";", ":", "!", "?", "…", "\"", "'", "”", "’": return true
        case ")": return word.filter { $0 == "(" }.count < word.filter { $0 == ")" }.count
        case "]": return word.filter { $0 == "[" }.count < word.filter { $0 == "]" }.count
        default: return false
        }
    }

    /// "report.md", "data.tar.gz": a dot that isn't the first character, then 1–10 letters or digits with a letter.
    static func hasExtension(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...]
        return (1...10).contains(ext.count) && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
            && ext.contains(where: \.isLetter)
    }

    /// The link a path taps through (`chatCellOpen(url:)`).
    static func url(_ path: String) -> URL? {
        URL(string: prefix + (path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? path))
    }

    /// The path behind a tapped file link, if it is one.
    static func path(fromLink url: URL) -> String? {
        let s = url.absoluteString
        guard s.hasPrefix(prefix) else { return nil }
        let raw = String(s.dropFirst(prefix.count))
        let path = raw.removingPercentEncoding ?? raw
        return path.isEmpty ? nil : path
    }

    /// The folder a path is in and the name it has there ("/a/b/c.md" → "/a/b", "c.md"); a path ending in a
    /// separator is the folder itself (no name).
    static func place(_ path: String) -> (folder: String, name: String?) {
        let windows = drive.test(path)
        let separator: (Character) -> Bool = { $0 == "/" || (windows && $0 == "\\") }
        if let end = path.last, separator(end) {
            let folder = String(path.dropLast())
            return (folder.isEmpty || (windows && folder.count == 2) ? path : folder, nil)
        }
        guard let cut = path.lastIndex(where: separator) else { return (path, nil) }
        let name = String(path[path.index(after: cut)...])
        var folder = String(path[..<cut])
        if folder.isEmpty || (windows && folder.count == 2) { folder.append(path[cut]) }   // "/" and "C:\"
        return (folder, name)
    }
}

/// A short CLI flag in inline code stays on one line (§8.2, row L307): a word joiner after each hyphen stops the line
/// from breaking inside "--user". Only the drawn text changes; what is copied, selected (Select Text), read aloud and
/// searched is the message's own source, and Find's marks on the drawn text look past the joiners (`findRanges`).
nonisolated enum InlineCodeText {
    static let joiner: Character = "\u{2060}"

    static func plain(_ drawn: String) -> String { drawn.filter { $0 != joiner } }

    /// The UTF-16 ranges of `query` in drawn text, found as if the joiners were not there (each range covers the
    /// joiners inside the match, so the mark is drawn over the whole flag).
    static func findRanges(of query: String, in drawn: String) -> [NSRange] {
        guard drawn.contains(joiner) else { return ChatFind.nsRanges(of: query, in: drawn) }
        var plain: [UInt16] = []                                 // UTF-16 units without joiners
        var origin: [Int] = []                                   // plain offset → drawn offset
        for (offset, unit) in drawn.utf16.enumerated() where unit != 0x2060 {
            plain.append(unit); origin.append(offset)
        }
        let text = String(utf16CodeUnits: plain, count: plain.count)
        return ChatFind.nsRanges(of: query, in: text).compactMap { range in
            guard range.length > 0, range.location >= 0, range.location + range.length <= origin.count else { return nil }
            let start = origin[range.location]
            let end = origin[range.location + range.length - 1] + 1
            return NSRange(location: start, length: end - start)
        }
    }

    private static let flag = TRx(#"^--?[A-Za-z0-9][A-Za-z0-9_=.:/-]{0,38}$"#)

    static func isFlag(_ code: String) -> Bool { flag.test(code) }

    static func display(_ code: String) -> String {
        guard isFlag(code) else { return code }
        return code.replacingOccurrences(of: "-", with: "-\u{2060}")
    }
}

/// What VoiceOver reads for a reply (§9.1, row L300): the words, not the Markdown that styles them.
nonisolated enum SpokenMarkdown {
    private static let fence = TRx(#"^[ \t]*(?:```|~~~)[^\n]*\n?"#, [.anchorsMatchLines])
    private static let image = TRx(#"!\[([^\]\n]*)\]\([^)\n]*\)"#)
    private static let link = TRx(#"\[([^\]\n]+)\]\([^)\n]*\)"#)
    private static let heading = TRx(#"^[ \t]{0,3}#{1,6}[ \t]+"#, [.anchorsMatchLines])
    private static let quote = TRx(#"^[ \t]{0,3}>[ \t]?"#, [.anchorsMatchLines])
    private static let bullet = TRx(#"^([ \t]*)[-*+][ \t]+(?:\[[ xX]\][ \t]+)?"#, [.anchorsMatchLines])
    private static let rule = TRx(#"^[ \t]*(?:-{3,}|\*{3,}|_{3,})[ \t]*$"#, [.anchorsMatchLines])
    private static let strong = TRx(#"(\*\*|__)(?=\S)([\s\S]*?\S)\1"#)
    private static let emphasis = TRx(#"(?<![\w*])([*_])(?=\S)([^*_\n]*?\S)\1(?![\w*])"#)
    private static let strike = TRx(#"~~(?=\S)([^~\n]*?\S)~~"#)
    private static let code = TRx(#"`+([^`\n]+)`+"#)
    private static let tableRule = TRx(#"^[ \t]*\|?[ \t]*:?-{2,}:?[ \t]*(?:\|[ \t]*:?-{2,}:?[ \t]*)*\|?[ \t]*$\n?"#, [.anchorsMatchLines])
    private static let pipes = TRx(#"[ \t]*\|[ \t]*"#)

    static func plain(_ markdown: String) -> String {
        // [transcript] F17: "Formula: " + its source; code blocks and tables read as their summaries (§1.1).
        let markdown = summarizingBlocks(MathText.spoken(markdown))
        guard markdown.contains(where: { "*_`#[>~|-".contains($0) }) else { return markdown }
        var text = fence.replace(markdown, with: "")
        text = image.replace(text, with: "$1")
        text = link.replace(text, with: "$1")
        text = tableRule.replace(text, with: "")
        text = rule.replace(text, with: "")
        text = heading.replace(text, with: "")
        text = quote.replace(text, with: "")
        text = bullet.replace(text, with: "$1")
        text = strong.replace(text, with: "$2")
        text = emphasis.replace(text, with: "$2")
        text = strike.replace(text, with: "$1")
        text = code.replace(text, with: "$1")
        if text.contains("|") {
            text = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("|") || t.hasSuffix("|") else { return String(line) }
                return pipes.replace(t.trimmingCharacters(in: CharacterSet(charactersIn: "| \t")), with: ", ")
            }.joined(separator: "\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The characters of a code block read after its summary.
    static let codePreview = 300

    /// Code blocks and tables as docs/spec/3x-transcript.md §1.1 reads them, so VoiceOver doesn't spell out a whole
    /// listing or every cell: a fence is "Code, Python, 12 lines: " and its first 300 characters (on one line), a
    /// table "Table, 3 rows, 2 columns. " and its header cells. The rest of the text is left as it is.
    static func summarizingBlocks(_ markdown: String) -> String {
        guard markdown.contains("```") || markdown.contains("~~~") || markdown.contains("|") else { return markdown }
        let lines = markdown.components(separatedBy: "\n")
        var out: [String] = []
        var i = 0
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        func cells(_ line: String) -> [String] {
            line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let mark = String(trimmed.prefix(while: { $0 == trimmed.first }))
                let language = CodeLanguage.label(String(trimmed.dropFirst(mark.count)))
                var body: [String] = []
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(mark), t.trimmingCharacters(in: CharacterSet(charactersIn: String(mark.prefix(1)))).isEmpty { break }
                    body.append(lines[i])
                    i += 1
                }
                i += 1   // the closing fence
                while body.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeLast() }
                guard !body.isEmpty else { continue }
                let head = "Code, " + (language.map { "\($0), " } ?? "") + plural(body.count, "line")
                let code = body.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
                out.append(head + ": " + String(code.prefix(codePreview)))
                continue
            }
            if trimmed.contains("|"), i + 1 < lines.count, tableRule.test(lines[i + 1]), lines[i + 1].contains("|") {
                let header = cells(line)
                var rows = 0
                var j = i + 2
                while j < lines.count, lines[j].contains("|"), !lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows += 1
                    j += 1
                }
                let named = header.filter { !$0.isEmpty }
                out.append("Table, " + plural(rows, "row") + ", " + plural(header.count, "column")
                           + (named.isEmpty ? "" : ". " + named.joined(separator: ", ")))
                i = j
                continue
            }
            out.append(line)
            i += 1
        }
        return out.joined(separator: "\n")
    }
}
