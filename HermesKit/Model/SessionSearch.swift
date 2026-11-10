// Sessions search (spec 02 §9; the web's `S/search-snippet.ts`, `S/stress-c-words.ts`, `V/lib/session-search.ts`,
// `S/fe-lists-r5.ts` searchScoped): the loaded rows that match as you type, then the gateway's full-text hits
// (`GET /api/sessions/search?q=…&profile=…`, one profile per request) merged round-robin across profiles, put in
// order of fit to the query's words, and appended after the local rows. Snippets are cleaned of tool JSON, line
// numbers and Markdown, windowed to open just before the match, and keep the match marked. Pure.

import Foundation

/// One full-text hit (`SessionSearchResult`, `V/types/hermes.ts:1346-1366`).
nonisolated struct SessionSearchHit: Sendable, Hashable {
    var sessionId: String
    var profile: String
    var title: String?
    var snippet: String
    var source: String?
    var model: String?
    var lineageRoot: String?
    var lastActive: Double?
    var started: Double?

    init(sessionId: String, profile: String, title: String? = nil, snippet: String = "", source: String? = nil,
         lastActive: Double? = nil, started: Double? = nil) {
        self.sessionId = sessionId; self.profile = profile; self.title = title; self.snippet = snippet; self.source = source
        self.lastActive = lastActive; self.started = started
    }

    init?(json: JSONValue, profile: String) {
        guard let id = RosterText.trimmed(json["session_id"]) else { return nil }
        sessionId = id
        self.profile = RosterText.trimmed(json["profile"]) ?? profile
        title = json["title"]?.string
        snippet = json["snippet"]?.string ?? ""
        source = RosterText.trimmed(json["source"])
        model = RosterText.trimmed(json["model"])
        lineageRoot = RosterText.trimmed(json["lineage_root"])
        lastActive = RosterText.number(json["last_active"])
        started = RosterText.number(json["session_started"])
        firstMessage = json["first_message"]?.string
    }

    /// The first user message, when the gateway sends it (its name when untitled).
    var firstMessage: String?

    /// `{"results":[…]}` for one profile.
    static func decode(_ data: Data, profile: String) throws -> [SessionSearchHit] {
        let json = try JSONValue.parse(data)
        return (json["results"]?.array ?? []).compactMap { SessionSearchHit(json: $0, profile: profile) }
    }
}

nonisolated enum SessionSearch {
    // MARK: Local rows

    /// `sessionMatchesSearch`: the query (trimmed, lowercased) inside the id, the lineage root, the title, the preview,
    /// the folder or the source's words.
    static func matches(_ session: SessionSummary, query: String, cwd: String? = nil, lineageRoot: String? = nil) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        let fields = [session.id, lineageRoot ?? "", session.title, session.preview ?? "", cwd ?? "", session.source ?? ""]
        return fields.contains { $0.lowercased().contains(needle) }
    }

    // MARK: Hits

    /// A hit the list never shows: a bot's own chat ("Bot Chat") or a group chat (`hiddenSearchHit`).
    static func isHidden(_ hit: SessionSearchHit) -> Bool {
        let title = hit.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title == RosterRules.botChatTitle || title.hasPrefix("Group: ")
    }

    /// Every profile's answer, round-robin by rank (`searchScoped`'s merge): the first hit of each profile, then the
    /// second…; a profile + id seen once is dropped after.
    static func merge(_ lists: [[SessionSearchHit]]) -> [SessionSearchHit] {
        var out: [SessionSearchHit] = []
        var seen = Set<String>()
        var rank = 0
        while lists.contains(where: { rank < $0.count }) {
            for list in lists where rank < list.count {
                let hit = list[rank]
                if seen.insert(hit.profile + "\u{0}" + hit.sessionId).inserted { out.append(hit) }
            }
            rank += 1
        }
        return out
    }

    /// The stopwords `rankByTerms` ignores.
    static let stopwords: Set<String> = Set("a an and are as at be but by for from i in is it of on or so the to was we with you".split(separator: " ").map(String.init))

    /// `rankByTerms` (C-03): hits with every non-stopword term of the query (whole words, title + snippet) first, then
    /// those with some, then the rest; the gateway's order kept within each. A query of stopwords keeps its order.
    static func rank<T>(_ rows: [T], query: String, text: (T) -> String) -> [T] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty && !stopwords.contains($0) }
        guard !terms.isEmpty else { return rows }
        func fit(_ row: T) -> Int {
            let words = Set(text(row).lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init))
            let hits = terms.filter { words.contains($0) }.count
            return hits == terms.count ? 0 : hits > 0 ? 1 : 2
        }
        return rows.enumerated().map { (index: $0.offset, row: $0.element, fit: fit($0.element)) }
            .sorted { $0.fit != $1.fit ? $0.fit < $1.fit : $0.index < $1.index }.map(\.row)
    }

    static func rank(_ hits: [SessionSearchHit], query: String) -> [SessionSearchHit] {
        rank(hits, query: query) { "\($0.title ?? "") \($0.snippet)" }
    }

    /// `phoneSearchOrder`: the local rows where they were, then the gateway's other hits in its (ranked) order.
    static func order<T>(local: [T], server: [T], id: (T) -> String) -> [T] {
        var seen = Set<String>()
        var out: [T] = []
        for row in local + server where seen.insert(id(row)).inserted { out.append(row) }
        return out
    }

    /// A first message that opens with a bracketed instruction ("[SYSTEM: …") is a prompt preamble, not a name.
    private static let preamble = JSRegex(#"^\s*\[[A-Za-z][\w -]{0,24}:"#)

    /// `searchResultName`: the title, else the first message, else "Scheduled job run" for a job's session.
    static func resultName(title: String?, firstMessage: String?, source: String?) -> String? {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        if let first = firstMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty,
           let raw = firstMessage, !preamble.test(raw) { return first }
        return source == "cron" ? "Scheduled job run" : nil
    }

    // MARK: Snippets (`S/search-snippet.ts`)

    static let markOpen: Character = "\u{E000}"
    static let markClose: Character = "\u{E001}"
    private static let line = "\n"

    private static func rx(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }
    private static let jsonKeyTest = rx(#""[A-Za-z0-9_.$@-]*"\s*:"#)
    private static let escapedBreak = rx(#"\\[nr]"#)
    private static let escapedTab = rx(#"\\t"#)
    private static let escapedChar = rx(#"\\(["\\/])"#)
    private static let markdownLink = rx(#"\[([^\]\n]+)\]\([^)\s]+\)"#)
    private static let jsonLiteral = rx(#"(^[.…\s]*|[:\[,]\s*)(?:null|true|false)(?=\s*[,}\]]|\s*$)"#)
    private static let jsonKey = rx(#""[A-Za-z0-9_.$@-]+"\s*:"#)
    private static let brackets = rx(#"[{}\[\]"]+"#)
    private static let emphasis = rx(#"\*\*|__|`"#)
    private static let listingNumber = rx(#"(^|\s)[0-9]+(?:[ \t]+[0-9]+)*[ \t]*[|│→][ \t]?"#)
    private static let grepFile = rx(#"(\.[A-Za-z]{1,6}):[0-9]+:[ \t]?"#)
    private static let grepLine = rx(#"(^|\s)[0-9]+:(?=[ \t]*(?:$|\n|#{1,6}[ \t]|[-*+>•][ \t]|[0-9]+:))"#)
    private static let lineMarker = rx(#"(^|\n)([.…]*)[ \t]*(?:(?:#{1,6}|[-*+>•])[ \t]+)+"#)
    private static let pythonLiteral = rx(#"(^|[\s(,=:])(?:None|True|False)(?=\s*(?:[,)\]};:]|…|$))"#)
    private static let jsonCount = rx(#"(^|\s)[.…]*[0-9]+(?:\.[0-9]+)?\s*,(?=\s|$)"#)
    private static let jsonPath = rx(#"(^|\s)(?:~|/[A-Za-z0-9_.@~-]+)(?:/[A-Za-z0-9_.@~-]+)*/([A-Za-z0-9_.@~-]+)(?=[\s,:;)]|…|$)"#)
    private static let absolutePath = rx(#"(^|[\s(=])((?:~|/)[^\s"',;()]*/[^\s"',;()]*)"#)
    private static let commaRun = rx(#"\s*,(\s*,)+"#)
    private static let loosePunctuation = rx(#"(^|\s)[,:]+(?=\s|$)"#)
    private static let ends = rx(#"^[\s.…,:;]+|[\s,:;]+$"#)
    private static let spaces = rx(#"\s+"#)
    private static let spaceEllipsis = rx(#"\s+…$"#)
    private static let repeatedJSON = rx(#"(^|\s)(\S+?),?(?:\s\2,?)+(?=\s|$)"#)
    private static let repeated = rx(#"(^|\s)(\S+(?:\s\S+)?)(?:\s\2)+(?=\s|$)"#)

    private static func cleanText(_ snippet: String) -> String {
        let json = Rx.matches(jsonKeyTest, snippet)
        var text = Rx.replace(escapedBreak, in: snippet, with: line)
        text = Rx.replace(escapedTab, in: text, with: " ")
        text = Rx.replace(escapedChar, in: text, with: "$1")
        text = Rx.replace(markdownLink, in: text, with: "$1")
        text = Rx.replace(jsonLiteral, in: text, with: "$1 ")
        text = Rx.replace(jsonKey, in: text, with: " ")
        text = Rx.replace(brackets, in: text, with: " ")
        text = Rx.replace(emphasis, in: text, with: "")
        text = Rx.replace(listingNumber, in: text, with: "$1" + line)
        text = Rx.replace(grepFile, in: text, with: "$1" + line)
        text = Rx.replace(grepLine, in: text, with: "$1" + line)
        text = Rx.replace(lineMarker, in: text, with: "$1$2")
        text = Rx.replace(pythonLiteral, in: text, with: "$1")
        if json {
            text = Rx.replace(jsonCount, in: text, with: "$1")
            text = Rx.replace(jsonPath, in: text, with: "$1$2")
        }
        // An absolute path reads by its file name, or from the folder a search match is in.
        text = Rx.replace(absolutePath, in: text) { whole, groups in
            let lead = groups[1], path = groups[2]
            let parts = path.components(separatedBy: "/")
            guard parts.count >= 3 else { return whole }
            if let hit = parts.firstIndex(where: { $0.contains(markOpen) }), hit > 0 {
                return lead + parts[hit...].joined(separator: "/")
            }
            let last = parts[parts.count - 1]
            return lead + (last.isEmpty ? whole.trimmingCharacters(in: .whitespacesAndNewlines) : last)
        }
        text = Rx.replace(commaRun, in: text, with: ",")
        text = Rx.replace(loosePunctuation, in: text, with: " ")
        text = Rx.replace(ends, in: text, with: "")
        text = Rx.replace(spaces, in: text, with: " ")
        text = Rx.replace(spaceEllipsis, in: text, with: "…")
        if json { text = Rx.replace(repeatedJSON, in: text, with: "$1$2") }
        return Rx.replace(repeated, in: text, with: "$1$2")
    }

    /// `cleanSearchSnippet`: readable words of an FTS snippet, at most `max` characters.
    static func cleanSnippet(_ snippet: String, max: Int = 140) -> String {
        let text = cleanText(snippet)
        guard text.count > max else { return text }
        return String(text.prefix(max - 1)).trimmingTrailingWhitespace() + "…"
    }

    /// `matchSnippet`: cleaned, windowed to open about 20 characters before the first match (with "…"), each match
    /// wrapped in U+E000…U+E001. The gateway marks FTS matches `>>>…<<<`; without them the query's first word (2+
    /// characters) is marked where it first appears.
    static func matchSnippet(_ snippet: String, query: String = "", max: Int = 140) -> String {
        let open = String(markOpen), close = String(markClose)
        var text = cleanText(snippet.replacingOccurrences(of: ">>>", with: open).replacingOccurrences(of: "<<<", with: close))
        text = Rx.replace(rx(open + #"\s*"# + close), in: text, with: "")
        text = Rx.replace(rx(open + #"\s+"#), in: text, with: open)
        text = Rx.replace(rx(#"\s+"# + close), in: text, with: close)
        var chars = Array(text)
        if !chars.contains(markOpen),
           let word = query.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).first(where: { $0.count > 1 }) {
            let lower = Array(text.lowercased()), needle = Array(String(word).lowercased())
            if lower.count == chars.count, let at = firstIndex(of: needle, in: lower) {
                chars.insert(markClose, at: at + needle.count)
                chars.insert(markOpen, at: at)
            }
        }
        let lead = 20
        var prefix = ""
        if let first = chars.firstIndex(of: markOpen), first > lead {
            var start = first - lead
            let before = lastIndex(of: " ", in: chars, atOrBefore: start)
            let after = chars[start...].firstIndex(of: " ")
            if let before, start - before <= 12 { start = before + 1 } else if let after, after < first { start = after + 1 }
            chars = Array(chars[start...])
            prefix = "…"
        }
        let visible = chars.filter { $0 != markOpen && $0 != markClose }.count
        if visible + prefix.count > max {
            var count = prefix.count, cut = 0
            while cut < chars.count && count < max - 1 {
                if chars[cut] != markOpen && chars[cut] != markClose { count += 1 }
                cut += 1
            }
            var kept = String(chars[..<cut]).trimmingTrailingWhitespace()
            if (kept.lastIndex(of: markOpen).map { o in kept.lastIndex(of: markClose).map { o > $0 } ?? true } ?? false) { kept.append(markClose) }
            return prefix + kept + "…"
        }
        return prefix + String(chars)
    }

    /// `snippetParts`: a marked snippet as runs of plain and matched text.
    static func parts(_ text: String) -> [(text: String, match: Bool)] {
        var out: [(String, Bool)] = []
        var current = ""
        var inside = false
        for character in text {
            if character == markOpen || character == markClose {
                if !current.isEmpty { out.append((current, inside)) }
                current = ""
                inside = character == markOpen
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { out.append((current, inside)) }
        return out
    }

    /// The snippet without its marks (VoiceOver, plain rows).
    static func plain(_ text: String) -> String { String(text.filter { $0 != markOpen && $0 != markClose }) }

    private static func firstIndex(of needle: [Character], in haystack: [Character]) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle { return start }
        return nil
    }

    private static func lastIndex(of character: Character, in chars: [Character], atOrBefore position: Int) -> Int? {
        var index = min(position, chars.count - 1)
        while index >= 0 { if chars[index] == character { return index }; index -= 1 }
        return nil
    }
}

private extension String {
    nonisolated func trimmingTrailingWhitespace() -> String {
        var copy = self
        while let last = copy.last, last.isWhitespace { copy.removeLast() }
        return copy
    }
}

// MARK: - Chat colours (`V/lib/profile-color.ts` PROFILE_SWATCHES, `S/ui-lists/row-model.ts` HUES)

/// The twelve row colours of More › Color: hsl(i × 30°, 68 %, 58 %), named as the web names them. Device-local, kept
/// under the chat's durable id (its lineage root) so a colour survives compression.
nonisolated enum SessionColors {
    static let names = ["Red", "Orange", "Yellow", "Lime", "Green", "Mint", "Teal", "Sky", "Blue", "Purple", "Magenta", "Pink"]
    static var count: Int { names.count }

    static func name(_ index: Int?) -> String? {
        guard let index, names.indices.contains(index) else { return nil }
        return names[index]
    }

    /// The swatch as RGB 0…1 (`hslRgb`).
    static func rgb(_ index: Int) -> (red: Double, green: Double, blue: Double) {
        let h = Double(index * 30 % 360), s = 0.68, l = 0.58
        let a = s * Swift.min(l, 1 - l)
        func f(_ n: Double) -> Double {
            let k = (n + h / 30).truncatingRemainder(dividingBy: 12)
            return l - a * Swift.max(-1, Swift.min(k - 3, 9 - k, 1))
        }
        return (f(0), f(8), f(4))
    }

    /// The CSS the web stores ("hsl(30 68% 58%)"): an export or a desktop copy reads the same value.
    static func css(_ index: Int) -> String { "hsl(\(index * 30) 68% 58%)" }
}
