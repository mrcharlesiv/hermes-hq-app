// A transcript tool call's arguments, bounded so they stay readable (docs/spec/1x-activity.md §11.1): `ToolCall.argsText`
// holds at most 4 KB, and Bubbles, In Header, the Steps sheet and the delegate card parse it. Clipping the serialized
// JSON broke every call whose arguments ran past 4 KB (a big write_file, a patch, long execute_code, delegate_task with
// long contexts): the parse failed and the line lost its file name, its Shell block or its goals. Here each string value
// is clipped and arrays are capped instead, so the text stays valid JSON and keeps every key. Text that was clipped
// anyway (the transcript cache cuts args to 512 bytes when an entry is too big) is read by a tolerant scan.

import Foundation

nonisolated enum ToolArgs {
    /// The most `argsText` holds (the M1 bound).
    static let maxBytes = 4096
    /// Arrays keep this many items (the delegate card shows at most 16 goals, `ToolCards.maxGoals`).
    static let maxItems = 16
    private static let maxDepth = 6

    /// `args` as JSON of at most `maxBytes`: `raw` (what the gateway or the model wrote) when it fits, else the
    /// arguments with each string clipped (1,024 characters and "…", then less until the whole fits). Arguments that
    /// aren't an object (`args` empty) keep `raw`, clipped.
    static func boundedText(_ args: [String: JSONValue], raw: String?) -> String? {
        if args.isEmpty { return raw.map { ChatText.clip($0, max: maxBytes) } }
        if let raw, raw.utf8.count <= maxBytes { return raw }
        let full = ChatJSON.stringify(.object(args))
        if full.utf8.count <= maxBytes { return full }
        return clippedToFit(args)
    }

    /// `boundedText` for arguments already serialized by `inputText` ([perf] no second full pass over a big call).
    static func boundedText(_ args: [String: JSONValue], input: (prefix: String, isFull: Bool)) -> String {
        input.isFull ? input.prefix : clippedToFit(args)
    }

    /// The first 4 KB of the arguments' JSON (the Steps sheet's raw input), and whether that is the whole JSON. [perf]
    /// Strings over 4,096 characters are clipped before serializing, so a 500 KB write_file costs one small pass on the
    /// main thread instead of full ones; a clipped string still escapes to at least 4,096 bytes, so the first 4 KB are
    /// byte for byte the full JSON's (sorted keys; arrays and depth are left whole for the same reason).
    static func inputText(_ args: [String: JSONValue]) -> (prefix: String, isFull: Bool) {
        let (value, clipped) = clipStrings(.object(args), cap: maxBytes)
        let text = ChatJSON.stringify(value)
        return (ChatText.clip(text, max: maxBytes), !clipped && text.utf8.count <= maxBytes)
    }

    /// Every string longer than `cap` characters clipped to `cap` plus "…"; nothing else changes.
    static func clipStrings(_ value: JSONValue, cap: Int) -> (JSONValue, clipped: Bool) {
        switch value {
        case .string(let s):
            guard s.utf8.count > cap, s.count > cap else { return (value, false) }
            return (.string(String(s.prefix(cap)) + "…"), true)
        case .array(let items):
            var clipped = false
            let out = items.map { item -> JSONValue in
                let (v, c) = clipStrings(item, cap: cap)
                clipped = clipped || c
                return v
            }
            return (.array(out), clipped)
        case .object(let o):
            var clipped = false
            let out = o.mapValues { item -> JSONValue in
                let (v, c) = clipStrings(item, cap: cap)
                clipped = clipped || c
                return v
            }
            return (.object(out), clipped)
        default:
            return (value, false)
        }
    }

    /// Each string clipped (1,024 characters, then less) until the whole fits `maxBytes`.
    private static func clippedToFit(_ args: [String: JSONValue]) -> String {
        for cap in [1024, 512, 256, 128, 64, 32] {
            let text = ChatJSON.stringify(bound(.object(args), cap: cap, depth: 0))
            if text.utf8.count <= maxBytes { return text }
        }
        // Hundreds of keys: what fits (the tolerant scan still reads the start).
        return ChatText.clip(ChatJSON.stringify(bound(.object(args), cap: 32, depth: 0)), max: maxBytes)
    }

    /// Every string clipped to `cap` characters (plus "…"), arrays to `maxItems`, nesting to `maxDepth`.
    static func bound(_ value: JSONValue, cap: Int, depth: Int) -> JSONValue {
        switch value {
        case .string(let s):
            guard s.utf8.count > cap, s.count > cap else { return value }
            return .string(String(s.prefix(cap)) + "…")
        case .array(let items):
            guard depth < maxDepth else { return .array([]) }
            return .array(items.prefix(maxItems).map { bound($0, cap: cap, depth: depth + 1) })
        case .object(let o):
            guard depth < maxDepth else { return .object([:]) }
            return .object(o.mapValues { bound($0, cap: cap, depth: depth + 1) })
        default:
            return value
        }
    }

    // MARK: Reading

    /// The arguments of a transcript call: the JSON when it parses, else what a tolerant scan finds (a text clipped
    /// mid-string still gives its path, command or goals).
    static func parse(_ text: String?) -> [String: JSONValue] {
        guard let text, !text.isEmpty else { return [:] }
        if let object = ChatJSON.parse(string: text)?.object { return object }
        return scan(text)
    }

    /// The keys `ToolLine` and the cards read.
    static let scannedKeys = ["path", "command", "code", "pattern", "query", "url", "prompt", "goal", "text", "name", "ref",
                              "question", "category", "action", "file", "file_path", "aspect_ratio"]

    private static let field = try! NSRegularExpression(
        pattern: #""(path|command|code|pattern|query|url|prompt|goal|text|name|ref|question|category|action|file|file_path|aspect_ratio)"\s*:\s*"((?:[^"\\]|\\.)*)("|\\?$)"#)
    private static let goalField = try! NSRegularExpression(pattern: #""goal"\s*:\s*"((?:[^"\\]|\\.)*)("|\\?$)"#)
    private static let urlsField = try! NSRegularExpression(pattern: #""urls"\s*:\s*\[\s*"((?:[^"\\]|\\.)*)("|\\?$)"#)

    private static func unescape(_ raw: String) -> String {
        guard raw.contains("\\") else { return raw }
        var body = raw
        if body.hasSuffix("\\") && !body.hasSuffix("\\\\") { body.removeLast() }       // cut inside an escape
        if let data = "\"\(body)\"".data(using: .utf8), let s = try? JSONDecoder().decode(String.self, from: data) { return s }
        return body.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"")
    }

    /// A cheap scan of (possibly cut) JSON: the first value of each of `scannedKeys` — the last string may be
    /// unterminated — and, for a `tasks` list, each task's goal (`{"tasks": [{"goal": …}, …]}`).
    static func scan(_ text: String) -> [String: JSONValue] {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        var out: [String: JSONValue] = [:]
        for m in field.matches(in: text, range: range) {
            let key = ns.substring(with: m.range(at: 1))
            if out[key] == nil { out[key] = .string(unescape(ns.substring(with: m.range(at: 2)))) }
        }
        if let m = urlsField.firstMatch(in: text, range: range) {
            out["urls"] = .array([.string(unescape(ns.substring(with: m.range(at: 1))))])
        }
        let tasksAt = ns.range(of: "\"tasks\"")
        if tasksAt.location != NSNotFound {
            let after = NSRange(location: tasksAt.location, length: ns.length - tasksAt.location)
            let goals = goalField.matches(in: text, range: after).map { JSONValue.string(unescape(ns.substring(with: $0.range(at: 1)))) }
            if !goals.isEmpty {
                out["tasks"] = .array(goals.prefix(maxItems).map { .object(["goal": $0]) })
                // A top-level goal before the list is the call's own; one inside the list belongs to a task.
                if let goal = goalField.firstMatch(in: text, range: range), goal.range.location > tasksAt.location { out["goal"] = nil }
            }
        }
        return out
    }
}
