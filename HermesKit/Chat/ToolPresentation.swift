// Tool-call wording and classification (spec 03 §8.2, §8.3, §8.10), ported from
// V:components/assistant-ui/tool/run-summary.ts, V:lib/summarize-command.ts, V:lib/tool-render-class.ts,
// V:components/assistant-ui/tool/fallback-model/format.ts and V:lib/tool-result-summary.ts (failure detection).
// Pure and `nonisolated`; used by history hydration and by the live turn fold.

import Foundation

nonisolated enum ToolPresentation {
    // MARK: Classes (§8.2)

    static let fileEditTools: Set<String> = ["edit_file", "patch", "write_file"]
    /// Draw their own card; never folded into a run (V:lib/tool-render-class.ts:11-45).
    static let cardTools: Set<String> = ["clarify", "delegate_task", "image_generate", "manage_catalog",
                                         "manage_connections", "edit_file", "patch", "write_file"]
    /// Draw nothing unless they failed (§8.10). Native M1: successful ones are dropped entirely.
    static let silentTools: Set<String> = ["react_to_message", "todo", "todo_list"]

    static func isSilent(_ name: String) -> Bool { silentTools.contains(name) }
    static func isTodo(_ name: String?) -> Bool { name == "todo" || name == "todo_list" }

    // MARK: Run summary wording (§8.3)

    enum Category: CaseIterable { case edit, explore, search, read, browse, interact, analyze, run, delegate, other }

    private static let copy: [Category: (singular: String, plural: String, past: String, present: String)] = [
        .analyze: ("image", "images", "Analyzed", "Analyzing"),
        .browse: ("page", "pages", "Opened", "Opening"),
        .delegate: ("task", "tasks", "Delegated", "Delegating"),
        .edit: ("file", "files", "Edited", "Editing"),
        .explore: ("file", "files", "Explored", "Exploring"),
        .interact: ("browser action", "browser actions", "Performed", "Performing"),
        .other: ("tool", "tools", "Used", "Using"),
        .read: ("page", "pages", "Read", "Reading"),
        .run: ("command", "commands", "Ran", "Running"),
        .search: ("query", "queries", "Searched", "Searching"),
    ]

    private static let toolCategory: [String: Category] = [
        "browser_navigate": .browse, "delegate_task": .delegate, "execute_code": .run, "list_files": .explore,
        "read_file": .explore, "search_files": .explore, "session_search_recall": .search, "terminal": .run,
        "vision_analyze": .analyze, "web_extract": .read, "web_search": .search,
    ]

    static func category(_ name: String) -> Category {
        if fileEditTools.contains(name) { return .edit }
        return toolCategory[name] ?? (name.hasPrefix("browser_") ? .interact : .other)
    }

    /// "Editing", "Running" … for the status line before a tool starts (toolPresentVerb).
    static func presentVerb(_ name: String) -> String {
        if name == "skill_view" { return "Loading skill" }
        return copy[category(name)]!.present
    }

    /// A tool call as `summarizeToolRun` sees it.
    struct Call {
        var name: String
        var args: [String: JSONValue]
        var pending: Bool          // no result and not settled
        var failed: Bool
        var hasResult: Bool
    }

    /// The single-call title ("Ran 1 command", "Explored App.swift", "Running npm test") per §8.3, including the
    /// failure clause ("…, 1 tool call failed"). `live` = the turn is still running.
    static func title(for call: Call, live: Bool) -> String { summarizeRun([call], live: live) }

    /// `summarizeToolRun` (run-summary.ts:205-252).
    static func summarizeRun(_ calls: [Call], live: Bool) -> String {
        let narrating: Call? = live ? (calls.first(where: { $0.pending }) ?? calls.last) : nil
        let liveCategory = narrating.map { category($0.name) }
        var groups: [Category: [Call]] = [:]
        var skillClauses: [String] = []
        for call in calls {
            if let skill = skillActivityTitle(call, live: live) { skillClauses.append(skill); continue }
            groups[category(call.name), default: []].append(call)
        }
        var clauses: [String] = []
        for cat in Category.allCases {
            guard let group = groups[cat] else { continue }
            clauses.append(clause(cat, group, live: cat == liveCategory))
        }
        let failed = calls.filter(\.failed).count
        if failed > 0 { clauses.append("\(failed) tool call\(failed == 1 ? "" : "s") failed") }
        let all = skillClauses + clauses
        return all.enumerated().map { index, text in index == 0 ? text : lowerFirst(text) }.joined(separator: ", ")
    }

    private static func clause(_ cat: Category, _ calls: [Call], live: Bool) -> String {
        let c = copy[cat]!
        let verb = live ? c.present : c.past
        // [transcript] §12, n20 F10: a caller that folds a whole turn's calls into one group (as the native app's
        // One Line / At the Bottom do) would otherwise count a file edited twice as two, disagreeing with the files
        // card's own `ChangedFiles.derive`, which counts files, not calls.
        let count = cat == .edit ? uniqueEditCount(calls) : calls.reduce(0) { $0 + unitCount($1) }
        let target = (count == 1 && cat != .interact) ? toolTarget(calls[0]) : ""
        if !target.isEmpty && (live || cat != .run) { return "\(verb) \(target)" }
        return "\(verb) \(count) \(count == 1 ? c.singular : c.plural)"
    }

    private static func unitCount(_ call: Call) -> Int {
        guard call.name == "web_extract" else { return 1 }
        if case .array(let urls)? = call.args["urls"], !urls.isEmpty { return urls.count }
        return 1
    }

    /// The same path keys `ChangedFiles.path` reads (minus the diff-header fallback, which needs no args here).
    private static func uniqueEditCount(_ calls: [Call]) -> Int {
        var paths: Set<String> = []
        for (i, call) in calls.enumerated() {
            let path = firstString(call.args, ["path", "file_path", "file", "filepath", "target_file"])
            paths.insert(path.isEmpty ? "|\(i)" : path)
        }
        return paths.count
    }

    private static func toolTarget(_ call: Call) -> String {
        let args = call.args
        let cat = category(call.name)
        if cat == .run { return summarizeShellCommand(firstString(args, ["command", "code"])) }
        if cat == .search {
            let query = firstString(args, ["query", "search_term"])
            return query.isEmpty ? "" : "“\(ChatText.compactPreview(query, max: 48))”"
        }
        if cat == .read || cat == .browse { return hostname(findFirstURL(.object(args))) }
        let path = firstString(args, ["path", "file", "filepath"])
        return path.isEmpty ? firstString(args, ["query", "url"]) : fileBasename(path)
    }

    private static func skillActivityTitle(_ call: Call, live: Bool) -> String? {
        guard call.name == "skill_view" || call.name == "skills_list" else { return nil }
        let pending = live && call.pending
        let missing = !pending && !call.hasResult
        let file = firstString(call.args, ["file_path"])
        let name = firstString(call.args, ["name"])
        let target = [name, file].filter { !$0.isEmpty }.joined(separator: " → ")
        let label: String
        if call.failed {
            label = call.name == "skills_list" ? "Failed to list skills"
                : file.isEmpty ? "Failed to load skill" : "Failed to read skill resource"
        } else if missing {
            label = "Skill result unavailable"
        } else if pending {
            label = call.name == "skills_list" ? "Listing skills" : file.isEmpty ? "Loading skill" : "Reading skill resource"
        } else {
            label = call.name == "skills_list" ? "Listed skills" : file.isEmpty ? "Loaded skill" : "Read skill resource"
        }
        return target.isEmpty ? label : "\(label): \(target)"
    }

    private static func lowerFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }

    static func firstString(_ record: [String: JSONValue], _ keys: [String]) -> String {
        for key in keys {
            if case .string(let s)? = record[key] {
                let t = ChatText.trimmed(s)
                if !t.isEmpty { return t }
            }
        }
        return ""
    }

    static func fileBasename(_ path: String) -> String {
        let normalized = ChatText.trimmed(path.replacingOccurrences(of: "\\", with: "/"))
        return normalized.split(separator: "/").last.map(String.init) ?? normalized
    }

    static func findFirstURL(_ value: JSONValue) -> String {
        switch value {
        case .string(let s):
            if let range = s.range(of: #"https?://[^\s'"<>)\]]+"#, options: [.regularExpression, .caseInsensitive]) {
                return String(s[range])
            }
            return ""
        case .object(let o):
            for key in o.keys.sorted() { let f = findFirstURL(o[key]!); if !f.isEmpty { return f } }
            return ""
        case .array(let a):
            for v in a { let f = findFirstURL(v); if !f.isEmpty { return f } }
            return ""
        default: return ""
        }
    }

    static func hostname(_ value: String) -> String {
        guard let url = URL(string: value), let host = url.host(), !host.isEmpty else { return value }
        let path = url.path()
        return host + (path.isEmpty || path == "/" ? "" : path)
    }

    // MARK: Shell command summary (V:lib/summarize-command.ts)

    private static let silentHeads: Set<String> = ["cd", "pushd", "popd", "export", "set", "unset", "source", ".", "true", "false", ":"]
    private static let pipeTailHeads: Set<String> = ["head", "tail", "wc", "sort", "uniq"]

    static func summarizeShellCommand(_ raw: String) -> String {
        let original = ChatText.trimmed(raw)
        guard !original.isEmpty else { return "" }
        let segments = splitCompound(original)
        if segments.count <= 1 {
            let cleaned = cleanSegment(original)
            return cleaned.isEmpty ? original : cleaned
        }
        let core = segments.map(cleanSegment).filter { seg in
            !seg.isEmpty && !silentHeads.contains(headWord(seg)) && !isBoundaryEcho(seg)
        }
        if core.isEmpty { return original }
        if core.count == 1 { return core[0] }
        return "\(core[0]) + \(core.count - 1) \(core.count == 2 ? "command" : "commands")"
    }

    private static func basenameOfHead(_ head: String) -> String {
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
                i += 1; continue
            }
            if ch == "\"" || ch == "'" { quote = ch; buf.append(ch); i += 1; continue }
            var opLength = 0
            if i + 1 < chars.count, (ch == "&" && chars[i + 1] == "&") || (ch == "|" && chars[i + 1] == "|") { opLength = 2 }
            else if ch == ";" || ch == "\n" { opLength = 1 }
            if opLength > 0 { segments.append(buf); buf = ""; i += opLength; continue }
            buf.append(ch)
            i += 1
        }
        segments.append(buf)
        return segments.map { stripPipeTail(ChatText.trimmed($0)) }.filter { !$0.isEmpty }
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
            if ch.isWhitespace { if !buf.isEmpty { words.append(buf); buf = "" }; continue }
            buf.append(ch)
        }
        if !buf.isEmpty { words.append(buf) }
        return words
    }

    private static func headWord(_ segment: String) -> String {
        let tokens = splitWords(segment)
        var index = 0
        while index < tokens.count, tokens[index].range(of: #"^[A-Za-z_]\w*="#, options: .regularExpression) != nil { index += 1 }
        return basenameOfHead(index < tokens.count ? tokens[index] : "")
    }

    private static func stripPipeTail(_ segment: String) -> String {
        let words = splitWords(segment)
        var out: [String] = []
        var i = 0
        while i < words.count {
            let word = words[i]
            if word == "|", pipeTailHeads.contains(basenameOfHead(i + 1 < words.count ? words[i + 1] : "")) { break }
            out.append(word)
            i += 1
        }
        return ChatText.trimmed(out.joined(separator: " "))
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
        return ChatText.trimmed(out.joined(separator: " "))
    }

    private static func isBoundaryEcho(_ segment: String) -> Bool {
        let words = splitWords(segment)
        guard basenameOfHead(words.first ?? "") == "echo" else { return false }
        let rest = words.dropFirst().joined(separator: " ")
        return rest.range(of: #"-{2,}|_exit=|(?:^|\s|=)\$[?{]|PIPESTATUS"#, options: .regularExpression) != nil
    }

    // MARK: Failure detection (format.ts toolCallFailed + tool-result-summary.ts extractToolErrorMessage)

    private static let errorKeys = ["error", "errors", "failure", "exception"]
    private static let errorMessageKeys = ["message", "reason", "detail"]
    private static let wrapperKeys = ["data", "result", "output", "response", "payload"]
    private static let nonErrorText: Set<String> = ["", "0", "false", "none", "null", "nil", "ok", "success", "n/a", "na"]

    /// `toolCallFailed`: explicit success beats a stale error envelope.
    static func callFailed(isError: Bool, result: JSONValue?) -> Bool {
        let record = result.flatMap { parseMaybeObject($0) } ?? [:]
        if record["success"] == .bool(true) || record["ok"] == .bool(true) { return false }
        if isError || record["success"] == .bool(false) || record["ok"] == .bool(false) { return true }
        guard let result else { return false }
        return !errorMessage(result).isEmpty
    }

    static func parseMaybeObject(_ value: JSONValue) -> [String: JSONValue]? {
        switch value {
        case .object(let o): return o
        case .string(let s):
            // Cheap first-byte check before any copy or parse: most big outputs are plain text.
            guard ChatText.firstNonSpaceByte(s) == UInt8(ascii: "{"), case .object(let o)? = ChatJSON.parse(string: s) else { return nil }
            return o
        default: return nil
        }
    }

    /// `extractToolErrorMessage`: the error text a failed result carries ("" when none).
    static func errorMessage(_ value: JSONValue) -> String { findNestedError(value, depth: 0, failed: false) }

    /// Strings longer than this are never re-parsed while looking for an error (nested error fields are short; a huge
    /// string is output, and parsing it again on the main thread costs milliseconds mid-stream).
    static let maxErrorParseBytes = 65_536

    private static func norm(_ value: JSONValue) -> JSONValue {
        guard case .string(let s) = value else { return value }
        guard let first = ChatText.firstNonSpaceByte(s) else { return .string("") }
        guard first == UInt8(ascii: "{") || first == UInt8(ascii: "[") || first == UInt8(ascii: "\""),
              s.utf8.count <= maxErrorParseBytes else { return value }
        return ChatJSON.parse(string: s) ?? value
    }

    private static func meaningfulError(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        switch norm(value) {
        case .null: return false
        case .string(let s): return !nonErrorText.contains(ChatText.trimmed(s).lowercased())
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .array(let a): return a.contains { meaningfulError($0) }
        case .object(let o): return !o.isEmpty
        }
    }

    private static func hasErrorSignal(_ record: [String: JSONValue]) -> Bool {
        let status = record["status"]?.string ?? ""
        return record["success"] == .bool(false) || record["ok"] == .bool(false)
            || ["error", "failed", "failure", "fatal", "exception"].contains(ChatText.trimmed(status).lowercased())
            || errorKeys.contains { meaningfulError(record[$0]) }
    }

    private static func valueErrorText(_ value: JSONValue) -> String {
        switch norm(value) {
        case .string(let s): return meaningfulError(.string(s)) ? clipBlock(s) : ""
        case .array(let a): return clipBlock(a.map(valueErrorText).filter { !$0.isEmpty }.prefix(3).joined(separator: "; "))
        case .object(let o):
            let direct = firstString(o, errorMessageKeys)
            return direct.isEmpty ? "" : clipBlock(direct)
        default: return ""
        }
    }

    private static func findNestedError(_ value: JSONValue, depth: Int, failed: Bool) -> String {
        guard depth <= 5 else { return "" }
        let v = norm(value)
        switch v {
        case .array(let items):
            for item in items { let n = findNestedError(item, depth: depth + 1, failed: failed); if !n.isEmpty { return n } }
            return ""
        case .object(let record):
            if record["success"] == .bool(true) || record["ok"] == .bool(true) { return "" }
            for key in errorKeys where meaningfulError(record[key]) {
                let text = valueErrorText(record[key]!)
                if !text.isEmpty { return text }
            }
            if hasErrorSignal(record) {
                let direct = firstString(record, errorMessageKeys)
                if !direct.isEmpty { return clipBlock(direct) }
            }
            let declared = failed || hasErrorSignal(record)
            let keys = declared ? errorKeys + wrapperKeys + ["details"] : errorKeys
            for key in keys {
                guard let child = record[key] else { continue }
                let n = findNestedError(child, depth: depth + 1, failed: declared)
                if !n.isEmpty { return n }
            }
            return ""
        default: return ""
        }
    }

    private static func clipBlock(_ value: String, maxChars: Int = 700, maxLines: Int = 12) -> String {
        let t = ChatText.trimmed(ChatText.clip(value, max: maxChars * 4 + 64))
        guard !t.isEmpty else { return "" }
        let lines = t.split(separator: "\n", omittingEmptySubsequences: false)
        var text = lines.prefix(maxLines).joined(separator: "\n")
        var cut = lines.count > maxLines
        if text.count > maxChars { text = String(text.prefix(maxChars)); cut = true }
        return cut ? ChatText.trimmed(text) + "…" : text
    }

    // MARK: Result projection for the step sheet (R:src/ui-chat/tool-presentation.ts)

    private static let resultKeys = ["success", "ok", "status", "error", "errors", "failure", "exception", "message", "reason",
                                     "detail", "exit_code", "stdout", "stderr", "output", "output_preview", "data", "result",
                                     "response", "payload", "content", "summary"]
    private static let argKeys = ["command", "code", "path", "file", "filepath", "query", "url", "skill", "name", "skill_name",
                                  "operation", "action", "goal", "tasks", "pattern", "urls", "site"]

    private struct Budget { var nodes: Int; var chars: Int }

    private static func project(_ value: JSONValue, keys: [String], budget: inout Budget, depth: Int = 0) -> JSONValue? {
        budget.nodes -= 1
        if budget.nodes < 0 || depth > 6 { return nil }
        switch value {
        case .string(let s):
            if s.utf8.count <= 4096, s.drop(while: { $0.isWhitespace }).first.map({ $0 == "{" || $0 == "[" }) == true,
               let parsed = ChatJSON.parse(string: s) {
                return project(parsed, keys: keys, budget: &budget, depth: depth + 1)
            }
            let size = min(2048, max(0, budget.chars), s.count)
            budget.chars -= size
            return .string(size == s.count ? s : String(s.prefix(size)))
        case .array(let a):
            return .array(a.prefix(8).compactMap { project($0, keys: keys, budget: &budget, depth: depth + 1) })
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for key in keys { if let child = o[key], let p = project(child, keys: keys, budget: &budget, depth: depth + 1) { out[key] = p } }
            return .object(out)
        default: return value
        }
    }

    /// A bounded, display-only copy of a tool result (≤64 nodes, ≤8192 chars) — what the cache keeps.
    static func projectResult(_ result: JSONValue) -> JSONValue {
        var budget = Budget(nodes: 64, chars: 8192)
        return project(result, keys: resultKeys, budget: &budget) ?? .null
    }

    /// A bounded copy of the args (≤32 nodes, ≤4096 chars).
    static func projectArgs(_ args: [String: JSONValue]) -> [String: JSONValue] {
        var budget = Budget(nodes: 32, chars: 4096)
        return project(.object(args), keys: argKeys, budget: &budget)?.object ?? [:]
    }

    /// The step-sheet detail for one tool call from its (possibly huge) result. Field caps are UTF-8 bytes (stdout and
    /// detail 8 KB, stderr 2 KB, input 4 KB, inline diff 20 KB); the transcript cache keeps a slimmer copy
    /// (`ToolDetail.slimmedForCache`).
    static func detail(args: [String: JSONValue], argsText: String?, result: JSONValue?, isError: Bool,
                       inlineDiff: String?, payloadRef: JSONValue?) -> ToolDetail {
        var d = ToolDetail()
        d.command = firstString(args, ["command", "code"]).nilIfEmpty.map { ChatText.clip($0, max: 4096) }
        d.input = argsText.map { ChatText.clip($0, max: 4096) }
        d.inlineDiff = inlineDiff.map { ChatText.clip($0, max: 20_000) }
        d.payloadRef = payloadRef
        // Parse a JSON-string result once; every check below reads the parsed record.
        let record = result.flatMap(parseMaybeObject)
        let normalized: JSONValue? = record.map { .object($0) } ?? result
        d.failed = callFailed(isError: isError, result: normalized)
        guard let result = normalized else { return d }
        if d.failed {
            let message = errorMessage(result)
            d.errorText = message.isEmpty ? nil : message
        }
        if let o = record {
            d.stdout = (o["stdout"]?.string ?? o["output"]?.string ?? o["content"]?.string).map { ChatText.clip($0, max: 8192) }
            d.stderr = o["stderr"]?.string.flatMap { ChatText.firstNonSpaceByte($0) == nil ? nil : ChatText.clip($0, max: 2048) }
            if let code = o["exit_code"]?.int { d.exitCode = code }
            // The projection keeps display fields only: a result whose keys were all dropped (an edit's `path` and
            // `inline_diff`, shown as Changes) has no output to show, not an empty "{ }" (verification round 3).
            if d.stdout == nil && d.stderr == nil, !o.isEmpty, case .object(let kept) = projectResult(.object(o)), !kept.isEmpty {
                d.detail = ChatText.clip(ChatJSON.stringifyPretty(.object(kept)), max: 8192)
            }
        } else if case .string(let s) = result {
            d.detail = ChatText.firstNonSpaceByte(s) == nil ? nil : ChatText.clip(s, max: 8192)
        } else if !result.isNull {
            d.detail = ChatText.clip(ChatJSON.stringify(projectResult(result)), max: 8192)
        }
        if d.inlineDiff == nil, let o = record {
            d.inlineDiff = (o["inline_diff"]?.string ?? o["diff"]?.string).map { ChatText.clip($0, max: 20_000) }
        }
        return d
    }

    /// One short line for `ToolCall.summary`: the gateway's own summary, else the error, else the first output line.
    static func shortSummary(payloadSummary: String?, detail: ToolDetail) -> String? {
        if let s = payloadSummary.flatMap({ ChatText.trimmed($0).isEmpty ? nil : $0 }) { return ChatText.compactPreview(s, max: 160) }
        if let e = detail.errorText { return ChatText.compactPreview(e, max: 160) }
        for candidate in [detail.stdout, detail.detail, detail.stderr] {
            if let text = candidate,
               let line = text.split(whereSeparator: \.isNewline).first(where: { !ChatText.trimmed(String($0)).isEmpty }) {
                return ChatText.compactPreview(String(line), max: 160)
            }
        }
        return nil
    }
}

nonisolated extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
