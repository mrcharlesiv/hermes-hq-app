// Reasoning-tag blocks a model writes into its reply (docs/spec/03-chat-history.md §9.2): `<think>…</think>` and its kin
// are hidden wherever a reply is shown or handed on (the bubble, Copy, Share, Select Text, Find, VoiceOver), in prose
// only — a code block's text, fenced or in backticks, stays exactly as written.

import Foundation

nonisolated enum ReasoningTags {
    /// The web's tag set (`V:lib/markdown-preprocess.ts` REASONING_TAGS).
    static let names = "think|thinking|reasoning|thought|reasoning_scratchpad|scratchpad|analysis"
    // swiftlint:disable force_try
    private static let openTag = try! NSRegularExpression(pattern: "<(\(names))>", options: [.caseInsensitive])
    // swiftlint:enable force_try

    /// Nothing would be drawn: only spaces, or only hidden thinking.
    static func isBlank(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return trimmed.contains("<") && strip(trimmed).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The text without its reasoning blocks. A closed block goes wherever it starts in prose (with the spaces and the
    /// one line break after it). An opening tag that is never closed hides the rest: while the reply is `streaming`,
    /// when it starts its own line (its thinking is still arriving, the web's rule); once the reply has settled, only
    /// when it opens the reply (a thinking preamble whose close never came), so a later line that merely starts with
    /// "<analysis>" no longer wipes out everything under it. A tag inside a code fence or an inline code span is left
    /// alone, as is everything it would have closed.
    static func strip(_ text: String, streaming: Bool = false) -> String {
        guard text.contains("<") else { return text }
        let ns = text as NSString
        let code = codeRanges(ns)
        var removals: [NSRange] = []
        var from = 0
        while from < ns.length,
              let open = openTag.firstMatch(in: text, range: NSRange(location: from, length: ns.length - from)) {
            if code.contains(where: { NSLocationInRange(open.range.location, $0) }) || inInlineCode(ns, at: open.range.location) {
                from = open.range.location + open.range.length
                continue
            }
            let tag = ns.substring(with: open.range(at: 1))
            let afterOpen = open.range.location + open.range.length
            let close = ns.range(of: "</\(tag)>", options: [.caseInsensitive],
                                 range: NSRange(location: afterOpen, length: ns.length - afterOpen))
            if close.location != NSNotFound {
                var end = close.location + close.length
                while end < ns.length, ns.character(at: end) == 0x20 || ns.character(at: end) == 0x09 { end += 1 }
                if end < ns.length, ns.character(at: end) == 0x0A { end += 1 }
                removals.append(NSRange(location: open.range.location, length: end - open.range.location))
                from = end
                continue
            }
            if streaming ? startsLine(ns, at: open.range.location) : startsText(ns, at: open.range.location) {
                // Keep the line break before it, as the web's `$1` does.
                var start = open.range.location
                while start > 0, ns.character(at: start - 1) == 0x20 || ns.character(at: start - 1) == 0x09 { start -= 1 }
                removals.append(NSRange(location: start, length: ns.length - start))
                break
            }
            from = afterOpen
        }
        guard !removals.isEmpty else { return text }
        let out = NSMutableString(string: text)
        for range in removals.reversed() { out.deleteCharacters(in: range) }
        return out as String
    }

    /// Only white space before it.
    private static func startsText(_ ns: NSString, at index: Int) -> Bool {
        ns.substring(to: index).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The tag sits at the start of its line, spaces or tabs before it at most.
    private static func startsLine(_ ns: NSString, at index: Int) -> Bool {
        var i = index
        while i > 0 {
            let c = ns.character(at: i - 1)
            if c == 0x0A { return true }
            if c != 0x20 && c != 0x09 { return false }
            i -= 1
        }
        return true
    }

    /// An odd number of backticks before it on its line: it is inside an inline code span.
    private static func inInlineCode(_ ns: NSString, at index: Int) -> Bool {
        var ticks = 0
        var i = index
        while i > 0 {
            let c = ns.character(at: i - 1)
            if c == 0x0A { break }
            if c == 0x60 { ticks += 1 }
            i -= 1
        }
        return ticks % 2 == 1
    }

    /// The fenced code blocks (``` or ~~~, from the fence line to its closing line, or to the end when never closed).
    private static func codeRanges(_ ns: NSString) -> [NSRange] {
        guard ns.range(of: "```").location != NSNotFound || ns.range(of: "~~~").location != NSNotFound else { return [] }
        var out: [NSRange] = []
        var fence: String?
        var fenceStart = 0
        var lineStart = 0
        while lineStart <= ns.length {
            let newline = ns.range(of: "\n", range: NSRange(location: lineStart, length: ns.length - lineStart))
            let lineEnd = newline.location == NSNotFound ? ns.length : newline.location
            let line = ns.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
                .trimmingCharacters(in: .whitespaces)
            if let f = fence {
                if line.hasPrefix(f), line.trimmingCharacters(in: CharacterSet(charactersIn: String(f.prefix(1)))).isEmpty {
                    out.append(NSRange(location: fenceStart, length: lineEnd - fenceStart))
                    fence = nil
                }
            } else if line.hasPrefix("```") || line.hasPrefix("~~~") {
                fence = String(line.prefix(while: { $0 == line.first }))
                fenceStart = lineStart
            }
            if newline.location == NSNotFound { break }
            lineStart = lineEnd + 1
        }
        if fence != nil { out.append(NSRange(location: fenceStart, length: ns.length - fenceStart)) }
        return out
    }
}
