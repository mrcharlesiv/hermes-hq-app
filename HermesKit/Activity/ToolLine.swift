// One tool call as a line, worded the way Hermes words its own Telegram progress lines (docs/spec/1x-activity.md
// §10.3; port of R:src/ui-chat/tool-line.ts): the registry emoji, a friendly verb and the call's main argument; a
// terminal command or code apart as `code`. Used by Bubbles, In Header and the Steps sheet.

import Foundation

nonisolated struct ToolLine: Hashable, Sendable {
    var emoji: String
    var text: String
    var code: String?

    /// "💻 npm test" (the code's first line) or "🔍 Searching the web for …": the In Header status words.
    var statusWords: String {
        if let code, let first = code.split(separator: "\n", omittingEmptySubsequences: true).first {
            return "\(emoji) \(first.trimmingCharacters(in: .whitespaces))"
        }
        return "\(emoji) \(text)"
    }

    /// What Copy puts on the pasteboard for one line: `<emoji> <text>\n<code>`.
    var copyText: String { code.map { "\(emoji) \(text)\n\($0)" } ?? "\(emoji) \(text)" }
}

nonisolated enum ToolLines {
    static let emoji: [String: String] = [
        "terminal": "💻", "execute_code": "🐍", "process_manage": "⚙️", "read_terminal": "🖥️", "close_terminal": "🖥️",
        "read_file": "📖", "write_file": "✍️", "patch": "🔧", "search_files": "🔎",
        "web_search": "🔍", "web_extract": "📄", "x_search": "🐦",
        "browser_navigate": "🌐", "browser_snapshot": "📸", "browser_click": "👆", "browser_type": "⌨️", "browser_press": "⌨️",
        "browser_scroll": "📜", "browser_back": "◀️", "browser_get_images": "🖼️", "browser_vision": "👁️", "browser_console": "🖥️",
        "browser_exec": "🌐", "browser_cdp": "🧪", "browser_dialog": "💬",
        "image_generate": "🎨", "video_generate": "🎬", "video_analyze": "🎬", "vision_analyze": "👁️", "desktop_preview": "🖼️",
        "skill_view": "📚", "skills_list": "📚", "skill_manage": "📝", "delegate_task": "🔀", "cronjob_manage": "⏰",
        "clarify": "❓", "memory": "🧠", "todo_list": "📋", "todo": "📋", "react_to_message": "💛",
        "message_agent": "💬",
    ]
    static let verb: [String: String] = [
        "web_search": "Searching the web", "web_extract": "Reading", "browser_navigate": "Browsing", "browser_click": "Clicking",
        "browser_type": "Typing", "read_file": "Reading", "write_file": "Writing", "patch": "Editing", "search_files": "Searching files",
        "terminal": "Running", "execute_code": "Running code", "image_generate": "Generating image", "video_generate": "Generating video",
        "text_to_speech": "Generating speech", "vision_analyze": "Looking at the image", "session_search": "Searching past sessions",
        "skill_view": "Reading skill", "skills_list": "Listing skills", "skill_manage": "Updating skill", "delegate_task": "Delegating",
        "cronjob_manage": "Scheduling", "clarify": "Asking", "memory": "Updating memory", "todo_list": "Updating tasks",
        "message_agent": "Messaging",
    ]
    static let noPreview: Set<String> = ["skills_list", "session_search", "memory", "todo_list"]
    static let forConnector: Set<String> = ["web_search", "search_files"]
    static let primary: [String: String] = [
        "terminal": "command", "web_search": "query", "web_extract": "urls", "read_file": "path", "write_file": "path", "patch": "path",
        "search_files": "pattern", "browser_navigate": "url", "browser_click": "ref", "browser_type": "text", "image_generate": "prompt",
        "text_to_speech": "text", "vision_analyze": "question", "skill_view": "name", "skills_list": "category", "cronjob_manage": "action",
        "execute_code": "code", "browser_exec": "code", "delegate_task": "goal", "skill_manage": "name",
        "message_agent": "target",
    ]
    static let fallbackKeys = ["query", "text", "command", "path", "name", "prompt", "code", "goal"]
    static let pathTools: Set<String> = ["read_file", "write_file", "patch"]
    static let urlTools: Set<String> = ["browser_navigate", "web_extract"]

    private static func oneLine(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    private static func basename(_ path: String) -> String {
        var p = path.replacingOccurrences(of: "\\", with: "/")
        while p.hasSuffix("/") { p.removeLast() }
        return p.split(separator: "/").last.map(String.init) ?? path
    }

    private static func bareURL(_ url: String) -> String {
        var u = url
        if let range = u.range(of: #"^https?://(?:www\.)?"#, options: [.regularExpression, .caseInsensitive]) { u.removeSubrange(range) }
        if u.hasSuffix("/") { u.removeLast() }
        return u
    }

    /// JavaScript's `String(value)` for the scalar values a preview shows.
    private static func scalar(_ value: JSONValue) -> String? {
        switch value {
        case .string(let s): return s
        case .number(let n): return ActivityJSON.jsNumber(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    static func preview(_ tool: String, _ args: [String: JSONValue]) -> String {
        if tool == "delegate_task", case .array(let tasks)? = args["tasks"], !tasks.isEmpty {
            if tasks.count == 1 { return oneLine(tasks[0]["goal"].flatMap(scalar) ?? "") }
            return "\(tasks.count) tasks"
        }
        guard let key = primary[tool] ?? fallbackKeys.first(where: { args[$0] != nil }) else { return "" }
        guard var value = args[key] else { return "" }
        if case .array(let items) = value {
            guard let first = items.first else { return "" }
            value = first
        }
        guard let raw = scalar(value) else { return "" }
        let text = oneLine(raw)
        if pathTools.contains(tool) { return basename(text) }
        if urlTools.contains(tool) { return bareURL(text) }
        return text
    }

    /// The line for one call. `args` may be an object, a JSON string (unparsable → `{}`) or nil.
    static func line(_ toolName: String, args: JSONValue?) -> ToolLine {
        let tool = toolName.hasPrefix("functions.") ? String(toolName.dropFirst("functions.".count)) : toolName
        let values: [String: JSONValue]
        switch args {
        case .object(let o)?: values = o
        case .string(let s)?: values = ChatJSON.parse(string: s)?.object ?? [:]
        default: values = [:]
        }
        // The gateway's `tool_call` wrapper is the call inside it; Composio's say the app's action, never "Composio"
        // (owner, 2026-10-29).
        if let inner = ToolNow.unwrap(tool, args: values) { return line(inner.name, args: .object(inner.args)) }
        if tool.hasPrefix("mcp_"), ToolNow.humanName(tool).split(separator: " ").first?.lowercased() == "composio",
           let words = ToolNow.mcp(tool, args: values) {
            return ToolLine(emoji: emoji[tool] ?? "⚙️", text: words.prefix(1).uppercased() + words.dropFirst())
        }
        let mark = emoji[tool] ?? "⚙️"
        if tool == "terminal" || tool == "execute_code" {
            let raw = values[tool == "terminal" ? "command" : "code"].flatMap(scalar) ?? ""
            let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !command.isEmpty { return ToolLine(emoji: mark, text: tool == "terminal" ? "terminal" : "Running code", code: command) }
        }
        let shown = noPreview.contains(tool) ? "" : preview(tool, values)
        guard let words = verb[tool] else {
            return ToolLine(emoji: mark, text: shown.isEmpty ? "\(tool)…" : "\(tool): “\(shown)”")
        }
        return ToolLine(emoji: mark, text: shown.isEmpty ? words : "\(words)\(forConnector.contains(tool) ? " for " : " ")\(shown)")
    }

    /// A transcript call: its `argsText` holds the arguments (≤ 4 KB, each value bounded); text cut short anyway (the
    /// cache's 512-byte copy) is read by a tolerant scan, so the line keeps its file name or command.
    static func line(_ call: ToolCall) -> ToolLine {
        line(call.name, args: .object(ToolArgs.parse(call.argsText)))
    }
}
