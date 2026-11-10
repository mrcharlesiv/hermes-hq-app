// [transcript] Tool row wording (docs/spec/3x-transcript.md §5.1, row L344). Ported from the web's helpers:
// `S/fe-convo-r1.ts` byteCountLabel (r1-47), `S/fe-convo-r5.ts` plainToolLabel (r5-98), `S/fe-convo-r4.ts`
// toolErrorBody / failedToolTitle (r4-94), `S/fe-convo-r6.ts` collapseHeredocs / setupSegment (r6-13), and the
// one-line shell output rule (r5-99).

import Foundation

nonisolated enum ToolWords {
    // MARK: Sizes in words (r1-47)

    /// "10 KB output", as iOS counts file sizes (1000-based).
    static func byteCountLabel(_ bytes: Double, what: String = "output") -> String {
        guard bytes.isFinite, bytes >= 0 else { return "" }
        let units = ["bytes", "KB", "MB", "GB"]
        var value = bytes
        var unit = 0
        while value >= 1000 && unit < units.count - 1 { value /= 1000; unit += 1 }
        let shown: String
        if unit == 0 { shown = String(Int(value.rounded())) }
        else if value < 10 {
            let one = String(format: "%.1f", value)
            shown = one.hasSuffix(".0") ? String(one.dropLast(2)) : one
        } else { shown = String(Int(value.rounded())) }
        return "\(shown) \(units[unit]) \(what)"
    }

    /// The trailing detail of a finished tool row that returned text: its size in words; nil under 1 KB (a short
    /// answer is not news) and for a call with no output.
    static func outputSize(stdout: String?, stderr: String?) -> String? {
        let out = stdout?.utf8.count ?? 0
        let err = stderr?.utf8.count ?? 0
        if out == 0 && err >= 1000 { return byteCountLabel(Double(err), what: "error output") }
        guard out >= 1000 else { return nil }
        return byteCountLabel(Double(out))
    }

    /// The size of a result's text before the step sheet's cap: a string, or the text of `stdout`/`output`/`content`.
    static func resultBytes(_ result: JSONValue?) -> Double? {
        switch result {
        case .string(let text)?: return Double(text.utf8.count)
        case .object(let o)?:
            for key in ["stdout", "output", "content"] { if let text = o[key]?.string { return Double(text.utf8.count) } }
            return nil
        default: return nil
        }
    }

    /// The note at the trailing edge of a finished tool row: one short line of shell output (at most 24 characters, so
    /// the title keeps its room), else the output's size in words. nil for a failed call and for a short answer. A line
    /// that is JSON (`{"ok": true}`) is machine output, not words: it falls back to the size note.
    static func rowNote(name: String, stdout: String?, stderr: String?, detail: String?, bytes: Double?, failed: Bool) -> String? {
        guard !failed else { return nil }
        if name == "terminal", let line = oneLineOutput(stdout), line.count <= 24, !looksLikeJSON(line) { return line }
        if let bytes, bytes >= 1000 { return byteCountLabel(bytes) }
        return outputSize(stdout: stdout ?? detail, stderr: stderr)
    }

    /// A line that opens as a JSON object or array.
    static func looksLikeJSON(_ line: String) -> Bool {
        let first = line.trimmingCharacters(in: .whitespaces).first
        return first == "{" || first == "["
    }

    // MARK: Checked how to use <tool>, background processes (r5-98)

    static let process: [String: String] = [
        "log": "Checked a background process’s log", "kill": "Stopped a background process", "stop": "Stopped a background process",
        "poll": "Checked a background process", "status": "Checked a background process", "wait": "Waited for a background process",
        "list": "Listed background processes", "write": "Sent input to a background process", "submit": "Sent input to a background process",
        "input": "Sent input to a background process", "close": "Closed a background process’s input",
        "handoff": "Handed off a background process", "spawn": "Started a background process", "start": "Started a background process",
    ]

    private static let mcpPrefix = TRx(#"^mcp__([^_]+(?:_[^_]+)*)__"#)
    private static let connectorPrefix = TRx(#"^connectors__[^_]+__"#)
    private static let underscores = TRx(#"[_-]+"#)

    /// "web_search" → "web search".
    static func toolWords(_ name: String) -> String {
        var out = mcpPrefix.replace(name, with: "$1 ")
        out = connectorPrefix.replace(out, with: "")
        out = underscores.replace(out, with: " ")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The row's title for the calls the gateway's own labels word badly; nil keeps the usual wording.
    static func plainLabel(name: String, args: [String: JSONValue], preview: String = "") -> String? {
        let tool = name.trimmingCharacters(in: .whitespaces)
        if tool == "tool_describe" {
            let raw = args["names"] ?? args["name"] ?? args["tool"] ?? args["tools"] ?? args["tool_name"]
            var names: [String] = []
            if let list = raw?.array { names = list.compactMap(\.string) } else if let one = raw?.string { names = [one] }
            names = names.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            // "Looked up web search" read as if a web search ran: it is the bot reading how to use the tool.
            if names.isEmpty { return "Checked how to use a tool" }
            return names.count == 1 ? "Checked how to use \(toolWords(names[0]))" : "Checked how to use \(names.count) tools"
        }
        if tool == "process_manage" || tool == "process" {
            let action = (args["action"]?.string ?? preview.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? "")
                .lowercased()
            return process[action] ?? "Managed a background process"
        }
        return nil
    }

    // MARK: Failed tools (r4-94)

    private static let statusLine = TRx(#"^\s*(?:[-*•]\s*)?(?:error|success|ok|status|message|exit_?code)\s*:"#, [.caseInsensitive])
    private static let statusOnly = TRx(#"^\s*(?:[-*•]\s*)?(?:success|ok|status|exit_?code)\s*:"#, [.caseInsensitive])
    private static let alreadyFailed = TRx(#"^(?:failed|couldn[’']t|could not|error)\b"#, [.caseInsensitive])
    private static let marks = TRx(#"[`*_]"#)
    private static let spaces = TRx(#"\s+"#)
    private static let errorKey = TRx(#"^\s*(?:[-*•]\s*)?(?:error|message)\s*:\s*"#, [.caseInsensitive])

    private static func plain(_ text: String) -> String {
        spaces.replace(marks.replace(text, with: ""), with: " ").trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// A failed tool's explanation without the key/value dump that repeats it.
    static func toolErrorBody(summary: String, body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !statusLine.test($0) && plain($0) != plain(summary) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Failed: Scheduling create", unless the title already says so.
    static func failedToolTitle(_ title: String) -> String {
        alreadyFailed.test(title.trimmingCharacters(in: .whitespaces)) ? title : "Failed: \(title)"
    }

    /// A failed tool as prose: the error's own words (a JSON `error` / `message` value, or the text without its
    /// status-key lines); "This step didn’t finish." when nothing is left (DECISION, spec §5.1).
    static func failedProse(errorText: String?, summary: String = "") -> String {
        let raw = (errorText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return "This step didn’t finish." }
        if raw.hasPrefix("{"), let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["error", "message", "detail", "stderr"] {
                if let words = object[key] as? String, !words.trimmingCharacters(in: .whitespaces).isEmpty {
                    return words.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return "This step didn’t finish."
        }
        // "error: No such file" keeps its words; "status: error" is only a key.
        let lines = raw.split(separator: "\n").map(String.init).filter { !statusOnly.test($0) }
            .map { errorKey.replace($0, with: "") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && plain($0) != plain(summary) }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? "This step didn’t finish." : body
    }

    // MARK: One-line shell output (r5-99)

    /// A terminal call's output when it is one line of at most 120 characters: shown right under the command.
    static func oneLineOutput(_ stdout: String?) -> String? {
        guard let text = stdout?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= 120,
              !text.contains(where: \.isNewline) else { return nil }
        return text
    }

    // MARK: Heredoc scripts (r6-13)

    static let interpreters: Set<String> = ["python", "python3", "python2", "node", "bash", "sh", "zsh", "ruby", "perl", "php",
                                            "osascript", "deno", "bun", "lua", "Rscript", "swift", "sqlite3", "psql", "mysql", "jq"]
    private static let heredoc = TRx(#"(?<!<)<<(-?)\s*(['"]?)([A-Za-z_][\w-]*)\2"#)
    private static let assignment = TRx(#"^[A-Za-z_]\w*="#)
    private static let leadingTabs = TRx(#"^\t+"#)

    /// The script with each heredoc's body folded into its command: "python3 - <<'PY' … PY" is one line,
    /// "python3 script" (an interpreter reading its program), else the command without the heredoc.
    static func collapseHeredocs(_ text: String) -> String {
        guard heredoc.test(text) else { return text }
        var out: [String] = []
        var end: String?
        var tabs = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let terminator = end {
                let candidate = tabs ? leadingTabs.replace(line, with: "") : line
                if candidate.trimmingCharacters(in: .whitespaces) == terminator { end = nil }
                continue
            }
            guard let groups = heredoc.groups(line), let whole = groups[0], let word = groups[3] else { out.append(line); continue }
            end = word
            tabs = groups[1] == "-"
            var rest = line
            if let range = rest.range(of: whole) { rest.replaceSubrange(range, with: " ") }
            rest = spaces.replace(rest, with: " ").trimmingCharacters(in: .whitespaces)
            let words = rest.split(separator: " ").map(String.init)
            var at = 0
            while at < words.count, assignment.test(words[at]) { at += 1 }
            let head = at < words.count ? (words[at].split(separator: "/").last.map(String.init) ?? "") : ""
            out.append(interpreters.contains(head) ? "\(head) script" : rest)
        }
        return out.joined(separator: "\n")
    }

    /// A segment that only sets up the script: variable assignments with no command ("SM=/path"), or a comment.
    static func setupSegment(_ words: [String]) -> Bool {
        guard let first = words.first else { return false }
        return first.hasPrefix("#") || words.allSatisfy { assignment.test($0) }
    }

    /// The command a shell row is titled by: heredocs folded, setup-only lines dropped.
    static func scriptTitleSource(_ command: String) -> String {
        let folded = collapseHeredocs(command)
        let lines = folded.split(separator: "\n").map(String.init)
            .filter { !setupSegment($0.split(separator: " ").map(String.init)) }
        return lines.isEmpty ? folded : lines.joined(separator: "\n")
    }
}
