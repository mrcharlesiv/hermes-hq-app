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
        let length = ns.length
        let code = codeRanges(ns)
        var codeIndex = 0
        var removals: [NSRange] = []
        var skipUntil = 0
        var noClose = Set<String>()
        var scanPos = 0
        var ticksOnLine = 0
        var lineHasNonSpace = false
        var firstNonSpace: Int?

        func advanceLineScan(to target: Int) {
            while scanPos < target {
                let c = ns.character(at: scanPos)
                if c == 0x0A {
                    ticksOnLine = 0
                    lineHasNonSpace = false
                } else {
                    if c == 0x60 { ticksOnLine += 1 }
                    if c != 0x20 && c != 0x09 { lineHasNonSpace = true }
                }
                scanPos += 1
            }
        }

        func startsText(at index: Int) -> Bool {
            if firstNonSpace == nil {
                var i = 0
                while i < length {
                    let u = ns.character(at: i)
                    if u == 0x20 || u == 0x09 || u == 0x0A || u == 0x0D || u == 0x0B || u == 0x0C {
                        i += 1
                        continue
                    }
                    if u < 0x80 { break }
                    if let scalar = UnicodeScalar(u), CharacterSet.whitespacesAndNewlines.contains(scalar) {
                        i += 1
                        continue
                    }
                    break
                }
                firstNonSpace = i
            }
            return index <= (firstNonSpace ?? 0)
        }

        openTag.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: length)) { match, _, stop in
            guard let open = match else { return }
            let loc = open.range.location
            if loc < skipUntil { return }
            while codeIndex < code.count && code[codeIndex].location + code[codeIndex].length <= loc {
                codeIndex += 1
            }
            if codeIndex < code.count && NSLocationInRange(loc, code[codeIndex]) {
                return
            }
            advanceLineScan(to: loc)
            if ticksOnLine & 1 == 1 {
                return
            }
            let tag = ns.substring(with: open.range(at: 1))
            let tagLower = tag.lowercased()
            let afterOpen = loc + open.range.length
            if !noClose.contains(tagLower) {
                let close = ns.range(of: "</\(tag)>", options: [.caseInsensitive],
                                     range: NSRange(location: afterOpen, length: length - afterOpen))
                if close.location != NSNotFound {
                    var end = close.location + close.length
                    while end < length, ns.character(at: end) == 0x20 || ns.character(at: end) == 0x09 { end += 1 }
                    if end < length, ns.character(at: end) == 0x0D, end + 1 < length, ns.character(at: end + 1) == 0x0A {
                        end += 2
                    } else if end < length, ns.character(at: end) == 0x0A {
                        end += 1
                    }
                    removals.append(NSRange(location: loc, length: end - loc))
                    skipUntil = end
                    return
                }
                noClose.insert(tagLower)
            }
            if streaming ? !lineHasNonSpace : startsText(at: loc) {
                // Keep the line break before it, as the web's `$1` does.
                var start = loc
                while start > 0, ns.character(at: start - 1) == 0x20 || ns.character(at: start - 1) == 0x09 { start -= 1 }
                removals.append(NSRange(location: start, length: length - start))
                stop.pointee = true
            }
        }
        guard !removals.isEmpty else { return text }
        let out = NSMutableString(string: text)
        for range in removals.reversed() { out.deleteCharacters(in: range) }
        return out as String
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
