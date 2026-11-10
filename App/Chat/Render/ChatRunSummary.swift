import Foundation

// The one grey line that stands in for a run of tool calls ("Explored 3 files, ran 5 commands"), ported from the
// renderer's run-summary.ts (spec 06 §3.2, spec 03 §8.3). Works from the contract's ToolCall: name, argsText (JSON),
// state. Note: the Data module ports the same wording as `ToolPresentation`; integration may switch to it.

nonisolated enum ChatRunSummary {
    enum Category: Int, CaseIterable {
        case edit, explore, search, read, browse, interact, analyze, run, delegate, other

        var past: String {
            ["Edited", "Explored", "Searched", "Read", "Opened", "Performed", "Analyzed", "Ran", "Delegated", "Used"][rawValue]
        }
        var present: String {
            ["Editing", "Exploring", "Searching", "Reading", "Opening", "Performing", "Analyzing", "Running", "Delegating", "Using"][rawValue]
        }
        var nouns: (String, String) {
            [("file", "files"), ("file", "files"), ("query", "queries"), ("page", "pages"), ("page", "pages"),
             ("browser action", "browser actions"), ("image", "images"), ("command", "commands"), ("task", "tasks"),
             ("tool", "tools")][rawValue]
        }
    }

    static let fileEditTools: Set<String> = ["edit_file", "patch", "write_file"]
    static let cardTools: Set<String> = ["clarify", "delegate_task", "image_generate", "manage_catalog", "manage_connections"]
    static let silentTools: Set<String> = ["react_to_message", "todo", "todo_list"]

    static func isFileEdit(_ name: String) -> Bool { fileEditTools.contains(name) }
    /// Tools that never join a run: file edits and card tools draw their own row.
    static func standsAlone(_ name: String) -> Bool { fileEditTools.contains(name) || cardTools.contains(name) }
    static func isSilent(_ name: String) -> Bool { silentTools.contains(name) }

    static func category(_ name: String) -> Category {
        if isFileEdit(name) { return .edit }
        switch name {
        case "browser_navigate": return .browse
        case "delegate_task": return .delegate
        case "execute_code", "terminal": return .run
        case "list_files", "read_file", "search_files": return .explore
        case "session_search_recall", "web_search": return .search
        case "vision_analyze": return .analyze
        case "web_extract": return .read
        default: return name.hasPrefix("browser_") ? .interact : .other
        }
    }

    /// Arguments up to this size are parsed in full; bigger ones (a whole file for write_file) only have the keys the
    /// wording reads pulled out of their start (spec 03 §8.8: collapsed rows never parse big payloads).
    static let argsParseLimit = 8_192

    static func args(_ tool: ToolCall) -> [String: JSONValue] {
        guard let text = tool.argsText, !text.isEmpty else { return [:] }
        if text.utf8.count > argsParseLimit { return scannedArgs(text) }
        // [activity] Text cut short (the cache's 512-byte copy) still gives its keys (docs/spec/1x-activity.md §11.1).
        guard let data = text.data(using: .utf8), let value = try? JSONValue.parse(data), let object = value.object else { return ToolArgs.scan(text) }
        return object
    }

    // swiftlint:disable force_try
    private static let stringField = try! NSRegularExpression(
        pattern: #""(path|file|filepath|file_path|command|code|query|search_term|url|name)"\s*:\s*"((?:[^"\\]|\\.){0,4096})""#)
    private static let urlsField = try! NSRegularExpression(pattern: #""urls"\s*:\s*\[([^\]]{0,6000})"#)
    private static let stringLiteral = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
    // swiftlint:enable force_try

    /// The wording's keys from the first 8 KB of a big argument object, by a cheap scan (no full parse).
    static func scannedArgs(_ text: String) -> [String: JSONValue] {
        let head = String(decoding: text.utf8.prefix(argsParseLimit), as: UTF8.self)
        let ns = head as NSString
        var out: [String: JSONValue] = [:]
        func unescape(_ raw: String) -> String {
            guard raw.contains("\\"), let data = "\"\(raw)\"".data(using: .utf8),
                  let s = try? JSONDecoder().decode(String.self, from: data) else { return raw }
            return s
        }
        for m in stringField.matches(in: head, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: m.range(at: 1))
            if out[key] == nil { out[key] = .string(unescape(ns.substring(with: m.range(at: 2)))) }
        }
        if let m = urlsField.firstMatch(in: head, range: NSRange(location: 0, length: ns.length)) {
            let list = ns.substring(with: m.range(at: 1))
            let lns = list as NSString
            let urls = stringLiteral.matches(in: list, range: NSRange(location: 0, length: lns.length))
                .map { JSONValue.string(unescape(lns.substring(with: $0.range(at: 1)))) }
            out["urls"] = .array(urls)
        }
        return out
    }

    /// `summarizeToolRun(tools, live)`.
    static func summarize(_ tools: [ToolCall], live: Bool) -> String {
        let narrating = live ? (tools.first(where: { $0.state == .running }) ?? tools.last) : nil
        let liveCategory = narrating.map { category($0.name) }
        var groups: [Category: [ToolCall]] = [:]
        var skillClauses: [String] = []
        for tool in tools {
            if let skill = skillTitle(tool, live: live) { skillClauses.append(skill); continue }
            // [transcript] Tools with plain words of their own ("Checked how to use terminal", "Checked a background process";
            // docs/spec/3x-transcript.md §5.1, L344); a failed one is counted with the failures below.
            if tool.state != .failed, let plain = ToolWords.plainLabel(name: tool.name, args: args(tool), preview: tool.title) {
                skillClauses.append(plain); continue
            }
            groups[category(tool.name), default: []].append(tool)
        }
        var clauses = Category.allCases.compactMap { cat in
            groups[cat].map { clause(cat, $0, live: cat == liveCategory) }
        }
        let failed = tools.filter { $0.state == .failed }.count
        if failed > 0 { clauses.append("\(failed) tool call\(failed == 1 ? "" : "s") failed") }
        return (skillClauses + clauses).enumerated()
            .map { $0.offset == 0 ? $0.element : lowerFirst($0.element) }
            .joined(separator: ", ")
    }

    private static func clause(_ cat: Category, _ tools: [ToolCall], live: Bool) -> String {
        let verb = live ? cat.present : cat.past
        // [transcript] §12, n20 F10: One Line / At the Bottom fold every edit call into this one group, where a file
        // touched twice would otherwise count twice — "Edited 4 files" beside the card's own "3 files changed" for
        // the same turn. `ChangedFiles.derive` counts files, not calls; this does the same.
        let count = cat == .edit ? uniqueEditCount(tools) : tools.reduce(0) { $0 + unitCount($1) }
        let target = count == 1 && cat != .interact ? toolTarget(tools[0]) : ""
        if !target.isEmpty && (live || cat != .run) { return "\(verb) \(target)" }
        return "\(verb) \(count) \(count == 1 ? cat.nouns.0 : cat.nouns.1)"
    }

    private static func unitCount(_ tool: ToolCall) -> Int {
        guard tool.name == "web_extract" else { return 1 }
        if let urls = args(tool)["urls"]?.array, !urls.isEmpty { return urls.count }
        return 1
    }

    /// The same path keys `ChangedFiles.path` reads (minus the diff-header fallback, which needs no args here): two
    /// calls that named the same file are one file, as the files card's own row for it already is.
    private static func uniqueEditCount(_ tools: [ToolCall]) -> Int {
        var paths: Set<String> = []
        for (i, tool) in tools.enumerated() {
            let path = firstString(args(tool), ["path", "file_path", "file", "filepath", "target_file"])
            paths.insert(path.isEmpty ? "|\(i)" : path)   // no path found at all: never collapsed into another call
        }
        return paths.count
    }

    private static func toolTarget(_ tool: ToolCall) -> String {
        let a = args(tool)
        switch category(tool.name) {
        case .run:
            // [transcript] A heredoc script is named by its command, not by its first setup line (§5.1).
            return summarizeShellCommand(ToolWords.scriptTitleSource(firstString(a, ["command", "code"])))
        case .search:
            let q = firstString(a, ["query", "search_term"])
            return q.isEmpty ? "" : "“\(compactPreview(q, max: 48))”"
        case .read, .browse:
            return hostname(findFirstURL(.object(a)))
        default:
            let path = firstString(a, ["path", "file", "filepath"])
            return path.isEmpty ? firstString(a, ["query", "url"]) : fileBasename(path)
        }
    }

    private static func skillTitle(_ tool: ToolCall, live: Bool) -> String? {
        guard tool.name == "skill_view" || tool.name == "skills_list" else { return nil }
        let a = args(tool)
        let failed = tool.state == .failed
        let pending = live && tool.state == .running
        let missing = !pending && tool.summary == nil && tool.state == .running
        let file = firstString(a, ["file_path"])
        let name = firstString(a, ["name"])
        let target = [name, file].filter { !$0.isEmpty }.joined(separator: " → ")
        let words: (pending: String, done: String, failed: String)
        if tool.name == "skills_list" {
            words = ("Listing skills", "Listed skills", "Failed to list skills")
        } else if !file.isEmpty {
            words = ("Reading skill resource", "Read skill resource", "Failed to read skill resource")
        } else {
            words = ("Loading skill", "Loaded skill", "Failed to load skill")
        }
        let label = failed ? words.failed : missing ? "Skill result unavailable" : pending ? words.pending : words.done
        return target.isEmpty ? label : "\(label): \(target)"
    }

    // MARK: Helpers (lib/text.ts, fallback-model/*)

    static func firstString(_ record: [String: JSONValue], _ keys: [String]) -> String {
        for key in keys {
            if let s = record[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        }
        return ""
    }

    static func compactPreview(_ value: String, max: Int) -> String {
        let line = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return line.count > max ? String(line.prefix(max - 1)) + "…" : line
    }

    static func fileBasename(_ path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: .whitespaces)
        return normalized.split(separator: "/").last.map(String.init) ?? normalized
    }

    static func findFirstURL(_ value: JSONValue) -> String {
        switch value {
        case .string(let s):
            if let r = s.range(of: #"https?://[^\s'"<>)\]]+"#, options: [.regularExpression, .caseInsensitive]) {
                return String(s[r])
            }
            return ""
        case .array(let a):
            for v in a { let f = findFirstURL(v); if !f.isEmpty { return f } }
            return ""
        case .object(let o):
            for key in o.keys.sorted() { let f = findFirstURL(o[key]!); if !f.isEmpty { return f } }
            return ""
        default:
            return ""
        }
    }

    static func hostname(_ value: String) -> String {
        guard let url = URL(string: value), let host = url.host() else { return value }
        let path = url.path()
        return host + (path.isEmpty || path == "/" ? "" : path)
    }

    private static func lowerFirst(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }

    // MARK: summarizeShellCommand (lib/summarize-command.ts)

    private static let silentHeads: Set<String> = ["cd", "pushd", "popd", "export", "set", "unset", "source", ".", "true", "false", ":"]
    private static let pipeTailHeads: Set<String> = ["head", "tail", "wc", "sort", "uniq"]

    static func summarizeShellCommand(_ raw: String) -> String {
        let original = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if original.isEmpty { return "" }
        let segments = splitCompound(original)
        if segments.count <= 1 {
            let cleaned = cleanSegment(original)
            return cleaned.isEmpty ? original : cleaned
        }
        let core = segments.map(cleanSegment).filter { !$0.isEmpty && !silentHeads.contains(headWord($0)) && !isBoundaryEcho($0) }
        if core.isEmpty { return original }
        if core.count == 1 { return core[0] }
        return "\(core[0]) + \(core.count - 1) \(core.count == 2 ? "command" : "commands")"
    }

    private static func basename(_ head: String) -> String {
        head.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init).flatMap { $0.isEmpty ? nil : $0 } ?? head
    }

    private static func splitCompound(_ input: String) -> [String] {
        var segments: [String] = []
        var buf = ""
        var quote: Character?
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if let q = quote {
                buf.append(ch)
                if ch == q && (i == 0 || chars[i - 1] != "\\") { quote = nil }
                i += 1
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; buf.append(ch); i += 1; continue }
            if i + 1 < chars.count, (ch == "&" && chars[i + 1] == "&") || (ch == "|" && chars[i + 1] == "|") {
                segments.append(buf); buf = ""; i += 2; continue
            }
            if ch == ";" || ch == "\n" { segments.append(buf); buf = ""; i += 1; continue }
            buf.append(ch)
            i += 1
        }
        segments.append(buf)
        return segments.map { stripPipeTail($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.filter { !$0.isEmpty }
    }

    private static func splitWords(_ segment: String) -> [String] {
        var words: [String] = []
        var buf = ""
        var quote: Character?
        let chars = Array(segment)
        for (i, ch) in chars.enumerated() {
            if let q = quote {
                buf.append(ch)
                if ch == q && (i == 0 || chars[i - 1] != "\\") { quote = nil }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; buf.append(ch); continue }
            if ch.isWhitespace {
                if !buf.isEmpty { words.append(buf); buf = "" }
                continue
            }
            buf.append(ch)
        }
        if !buf.isEmpty { words.append(buf) }
        return words
    }

    private static func headWord(_ segment: String) -> String {
        let tokens = splitWords(segment)
        var index = 0
        while index < tokens.count, tokens[index].range(of: #"^[A-Za-z_]\w*="#, options: .regularExpression) != nil { index += 1 }
        return basename(index < tokens.count ? tokens[index] : "")
    }

    private static func stripPipeTail(_ segment: String) -> String {
        let words = splitWords(segment)
        var out: [String] = []
        for (i, word) in words.enumerated() {
            if word == "|", i + 1 < words.count, pipeTailHeads.contains(basename(words[i + 1])) { break }
            out.append(word)
        }
        return out.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func cleanSegment(_ segment: String) -> String {
        let words = splitWords(segment)
        var out: [String] = []
        var i = 0
        while i < words.count {
            let word = words[i]
            if word.range(of: #"^\d*(?:>>?|<)$"#, options: .regularExpression) != nil { i += 2; continue }
            if word.range(of: #"^\d*(?:>&|<&)\d+$"#, options: .regularExpression) != nil { i += 1; continue }
            out.append(word)
            i += 1
        }
        return out.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func isBoundaryEcho(_ segment: String) -> Bool {
        let words = splitWords(segment)
        guard basename(words.first ?? "") == "echo" else { return false }
        let rest = words.dropFirst().joined(separator: " ")
        return rest.range(of: #"-{2,}|_exit=|(?:^|\s|=)\$[?{]|PIPESTATUS"#, options: .regularExpression) != nil
    }

    /// A run's glyph from its summary's first word (trail-model.ts `summaryKind`).
    static func glyph(forSummary summary: String) -> ChatGlyph {
        if summary.hasPrefix("Edited") || summary.hasPrefix("Editing") { return .file }
        if summary.hasPrefix("Explored") || summary.hasPrefix("Exploring") { return .explore }
        if summary.hasPrefix("Ran") || summary.hasPrefix("Running") { return .terminal }
        return .other
    }
}
