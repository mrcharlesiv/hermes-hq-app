// Pure rules behind the step views (docs/spec/1x-activity.md §10.5, §12): where a reply's steps stand for After Reply ›
// Hide (port of R:src/ui-chat/tool-calls-setting.ts `stepsState`), the coloured diff's lines (port of
// V:components/chat/diff-lines.tsx and `stripInlineDiffChrome`), and the 20,000-character pages of long sections.

import Foundation

nonisolated enum StepsState: Hashable, Sendable { case working, done, failed }

nonisolated enum StepRules {
    /// Still working; finished cleanly; or finished with a failed call that no prose after it accounts for (those steps
    /// stay, so a failure never vanishes unexplained).
    static func state(_ parts: [ChatPart], working: Bool) -> StepsState {
        if working { return .working }
        guard let failed = parts.lastIndex(where: { if case .tool(let c) = $0 { return c.state == .failed } else { return false } }) else {
            return .done
        }
        let explained = parts[(failed + 1)...].contains { part in
            if case .text(let t) = part { return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return false
        }
        return explained ? .done : .failed
    }

    /// Whether `message` is still working: it streams, or the chat runs and it is the newest reply after the last prompt.
    /// `turnAnchor`: the newest message when a hidden goal continuation went out (a turn with no prompt row) — the
    /// running turn starts after it, so the previous reply doesn't count as working until the new one appears.
    static func isWorking(_ message: ChatMessage, at index: Int, in messages: [ChatMessage], running: Bool,
                          turnAnchor: String? = nil) -> Bool {
        if message.isStreaming { return true }
        guard running else { return false }
        var lastUser = messages.lastIndex { $0.role == .user } ?? -1
        if let turnAnchor, let anchor = messages.lastIndex(where: { $0.id == turnAnchor }) { lastUser = max(lastUser, anchor) }
        guard index > lastUser else { return false }
        return messages[(index + 1)...].allSatisfy { $0.role != .assistant }
    }

    // MARK: Diff (§12 item 3)

    nonisolated enum DiffKind: Hashable, Sendable { case added, removed, context }

    nonisolated struct DiffLine: Hashable, Sendable {
        var kind: DiffKind
        var text: String
    }

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-?]*[ -/]*[@-~]")
    private static let headerPrefixes = ["diff --git", "index ", "--- ", "+++ ", "similarity ", "rename ", "new file", "deleted file"]

    /// ANSI escapes and a leading "┊ review diff" line stripped, trimmed.
    static func stripChrome(_ value: String) -> String {
        var text = ansi.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
        if let range = text.range(of: #"^\s*┊\s*review diff\s*\n"#, options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(range)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isArrowHeader(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("→"), let first = t.first, !"+-@".contains(first) else { return false }
        return t.range(of: #"^\S.*→\s*\S+$"#, options: .regularExpression) != nil
    }

    /// The header zone before the first hunk goes (it repeats the path).
    static func stripHeaders(_ diff: String) -> [Substring] {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        var start = 0
        while start < lines.count {
            let line = lines[start]
            if line.hasPrefix("@@") { break }
            let s = String(line)
            if s.trimmingCharacters(in: .whitespaces).isEmpty || isArrowHeader(s) || headerPrefixes.contains(where: { s.hasPrefix($0) }) {
                start += 1
                continue
            }
            break
        }
        return Array(lines[start...])
    }

    private static func kind(_ line: Substring) -> DiffKind {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .added }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .removed }
        return .context
    }

    private static func stripMarker(_ line: Substring) -> String {
        if kind(line) != .context || line.hasPrefix(" ") { return String(line.dropFirst()) }
        return String(line)
    }

    /// Lines to draw: hunks' lines with their marker dropped, `@@` headers dropped (a blank line between hunks).
    static func diffLines(_ raw: String) -> [DiffLine] {
        let lines = stripHeaders(stripChrome(raw))
        var hunks: [[DiffLine]] = []
        var active = false
        for line in lines {
            if line.hasPrefix("@@") {
                if line.range(of: #"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#, options: .regularExpression) != nil {
                    hunks.append([])
                    active = true
                } else {
                    active = false
                }
                continue
            }
            if !active || line.hasPrefix("\\") { continue }
            hunks[hunks.count - 1].append(DiffLine(kind: kind(line), text: stripMarker(line)))
        }
        if hunks.isEmpty { return lines.map { DiffLine(kind: kind($0), text: stripMarker($0)) } }
        var out: [DiffLine] = []
        for (i, hunk) in hunks.enumerated() {
            if i > 0 && !out.isEmpty { out.append(DiffLine(kind: .context, text: "")) }
            out.append(contentsOf: hunk)
        }
        return out
    }

    // MARK: Pages (§12 item 4)

    static let pageSize = 20_000

    /// The page count and one page of `text` (Unicode scalars, the server's own unit).
    static func pages(_ text: String) -> Int { max(1, Int((Double(text.unicodeScalars.count) / Double(pageSize)).rounded(.up))) }

    static func page(_ text: String, _ index: Int) -> String {
        let scalars = text.unicodeScalars
        let start = scalars.index(scalars.startIndex, offsetBy: min(scalars.count, index * pageSize))
        let end = scalars.index(start, offsetBy: min(pageSize, scalars.distance(from: start, to: scalars.endIndex)))
        return String(scalars[start..<end])
    }
}
