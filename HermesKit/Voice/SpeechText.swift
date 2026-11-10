// What is said aloud (docs/spec/3x-talk.md §3.3, §7): Markdown cleaned for a voice, and sentence cutting for the
// one-clip fallback. Ported from `vendor/hermes/apps/desktop/src/lib/speech-text.ts`.

import Foundation

nonisolated enum SpeechText {
    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // The patterns are literals of this file; one that did not compile would be a programming error.
        (try? NSRegularExpression(pattern: pattern, options: options)) ?? NSRegularExpression()
    }
    private static let emoji = regex("(?:[\\x{1F000}-\\x{1FAFF}\\x{2600}-\\x{27BF}]|[\\x{FE0F}\\x{200D}]|[\\x{E0020}-\\x{E007F}])+")
    private static let fencedCode = regex("```[\\s\\S]*?(?:```|\\z)")
    private static let inlineCode = regex("`([^`]+)`")
    private static let markdownLink = regex("\\[([^\\]]+)\\]\\(([^)]+)\\)")
    private static let paragraphBreak = regex("[ \\t]*\\n{2,}[ \\t]*")
    private static let punctuatedParagraphBreak = regex("([.!?])([*_~`>\"'’”)}\\]]*)[ \\t]*\\n{2,}[ \\t]*")
    private static let softBreak = regex("[ \\t]*\\n[ \\t]*")
    private static let mediaPath = regex("[ \\t]*MEDIA:\\S+?(?=[.,;:!?)\\]]*(?:\\s|\\z))")
    /// A desktop directive line (`::preview{file="…"}`): a page to look at, not words.
    private static let directiveLine = regex("^[ \\t]*::[a-z][\\w-]*\\{[^}\\n]*\\}[ \\t]*$", [.anchorsMatchLines])
    private static let lineFinalColon = regex(":\\s*$", [.anchorsMatchLines])
    private static let thinkingPrefix = regex(
        "^\\s*(?:\\([^)\\n]{1,48}\\)\\s*)?(?:processing|thinking|reasoning|analyzing|pondering|contemplating|musing|cogitating|ruminating|deliberating|mulling|reflecting|computing|synthesizing|formulating|brainstorming)\\.\\.\\.\\s*",
        [.caseInsensitive])
    private static let url = regex("\\bhttps?://\\S+", [.caseInsensitive])
    private static let hyphenBreak = regex("(\\p{L})-\\n(\\p{L})")
    private static let heading = regex("^#{1,6}\\s+", [.anchorsMatchLines])
    private static let markup = regex("[*_~>#]")
    private static let bullet = regex("^\\s*[-+*]\\s+", [.anchorsMatchLines])
    private static let trailingColon = regex(":\\s*\\z")
    private static let whitespace = regex("\\s+")
    /// A full stop left standing alone where a code block was taken out ("Here is the command. . Then…").
    private static let orphanStop = regex("(?:(?<=[.!?…])\\s+|^\\s*)\\.(?=\\s|\\z)")
    private static let tableDelimiter = regex("^:?-{3,}:?$")
    private static let sentenceCut = regex("[.!?…。！？]+[\"'”’)\\]]*\\s+")
    static let minSentence = 24

    private static func replace(_ text: String, _ expression: NSRegularExpression, _ template: String) -> String {
        expression.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }

    // MARK: Tables: only the header row is spoken

    private struct TableRow { var depth: Int; var cells: [String] }

    private static func unescapedPipes(_ row: [Character]) -> [Int] {
        row.indices.filter { index in
            guard row[index] == "|" else { return false }
            var slashes = 0, cursor = index - 1
            while cursor >= 0, row[cursor] == "\\" { slashes += 1; cursor -= 1 }
            return slashes % 2 == 0
        }
    }

    private static func tableRow(_ line: String) -> TableRow? {
        var row = Substring(line)
        var depth = 0
        while true {
            let indentation = row.prefix { $0 == " " || $0 == "\t" }
            if indentation.contains("\t") || indentation.count > 3 { return nil }
            row = row.dropFirst(indentation.count)
            guard row.hasPrefix(">") else { break }
            depth += 1
            row = row.dropFirst()
            if row.hasPrefix(" ") { row = row.dropFirst() }
        }
        var characters = Array(String(row).replacingOccurrences(of: "\\s+\\z", with: "", options: .regularExpression))
        let pipes = unescapedPipes(characters)
        guard let first = pipes.first, let last = pipes.last else { return nil }
        let leading = first == 0, trailing = last == characters.count - 1
        if trailing { characters.removeLast() }
        if leading, !characters.isEmpty { characters.removeFirst() }
        var cells: [String] = [], start = 0
        for index in unescapedPipes(characters) {
            cells.append(String(characters[start..<index]).trimmingCharacters(in: .whitespaces))
            start = index + 1
        }
        cells.append(String(characters[start...]).trimmingCharacters(in: .whitespaces))
        if cells.count < 2, !(leading && trailing && cells.count == 1) { return nil }
        return TableRow(depth: depth, cells: cells)
    }

    private static func tableHeader(_ cells: [String]) -> String {
        let header = cells.map { $0.replacingOccurrences(of: "\\|", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: ", ")
        guard let last = header.last else { return header }
        return ".!?:".contains(last) ? header : header + "."
    }

    static func summarizeTables(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var tableLines = Set<Int>(), headers: [Int: String] = [:]
        var index = 1
        while index < lines.count {
            guard let delimiter = tableRow(lines[index]), let header = tableRow(lines[index - 1]),
                  delimiter.cells.allSatisfy({ tableDelimiter.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }),
                  header.cells.count == delimiter.cells.count, header.depth == delimiter.depth else {
                index += 1
                continue
            }
            tableLines.insert(index - 1)
            tableLines.insert(index)
            headers[index - 1] = tableHeader(header.cells)
            var row = index + 1
            while row < lines.count, let body = tableRow(lines[row]), body.depth == delimiter.depth {
                tableLines.insert(row)
                row += 1
            }
            index = row
        }
        return lines.enumerated().compactMap { index, line -> String? in
            guard tableLines.contains(index) else { return line }
            guard let header = headers[index], !header.isEmpty else { return nil }
            return header
        }.joined(separator: "\n")
    }

    private static func normalizeLineBreaks(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        value = replace(value, hyphenBreak, "$1$2")
        value = replace(value, punctuatedParagraphBreak, "$1$2 ")
        value = replace(value, paragraphBreak, ". ")
        return replace(value, softBreak, " ")
    }

    /// The text a voice should say for this Markdown: no code blocks, links read as their words, no addresses, no
    /// emoji, no markup characters. Empty when nothing is speakable.
    static func sanitizeForSpeech(_ text: String) -> String {
        var value = replace(summarizeTables(replace(text, directiveLine, "")), lineFinalColon, ".")
        value = normalizeLineBreaks(value)
        value = replace(value, fencedCode, "")
        value = replace(value, thinkingPrefix, " ")
        value = replace(value, markdownLink, "$1")
        value = replace(value, inlineCode, "$1")
        value = replace(value, url, "")
        value = replace(value, mediaPath, "")
        value = replace(value, emoji, " ")
        value = replace(value, heading, "")
        value = replace(value, markup, "")
        value = replace(value, bullet, "")
        value = replace(value, trailingColon, ".")
        value = replace(value, whitespace, " ")
        value = replace(value, orphanStop, "")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let closedCodeBlock = regex("```[\\s\\S]*?```")

    /// Written text with its finished code blocks taken out; `held` is a code block that has not closed yet.
    static func withoutCodeBlocks(_ text: String) -> (text: String, held: String) {
        let closed = replace(text, closedCodeBlock, "\n")
        guard let open = closed.range(of: "```") else { return (closed, "") }
        return (String(closed[..<open.lowerBound]), String(closed[open.lowerBound...]))
    }

    /// Whole sentences of at least `minimum` characters, and what is left. `flush` returns the tail as a sentence too.
    static func cutSentences(_ buffer: String, flush: Bool, minimum: Int = minSentence) -> (sentences: [String], rest: String) {
        let whole = buffer as NSString
        var sentences: [String] = [], start = 0
        for match in sentenceCut.matches(in: buffer, range: NSRange(location: 0, length: whole.length)) {
            let end = match.range.location + match.range.length
            let candidate = whole.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.count >= minimum {
                sentences.append(candidate)
                start = end
            }
        }
        var rest = whole.substring(from: start)
        if flush {
            let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { sentences.append(tail) }
            rest = ""
        }
        return (sentences, rest)
    }
}

/// Sentences out of text that arrives a piece at a time.
nonisolated struct SentenceBuffer: Sendable {
    private var buffer = ""
    init() {}
    mutating func append(_ delta: String) -> [String] {
        let cut = SpeechText.cutSentences(buffer + delta, flush: false)
        buffer = cut.rest
        return cut.sentences
    }
    mutating func flush() -> [String] {
        let cut = SpeechText.cutSentences(buffer, flush: true)
        buffer = ""
        return cut.sentences
    }
}
