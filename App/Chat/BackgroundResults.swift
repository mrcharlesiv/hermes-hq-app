import Foundation

// A finished subagent or background process in the timeline (the desktop's BackgroundResult, system-message.tsx):
// Hermes' one-line title ("Subagent Task Completed: <goal>") as a row cut to one line, and what the work reported
// behind it. The goal can be a paragraph; drawn whole it filled the screen (owner, 2026-10-15).

nonisolated enum BackgroundResults {
    /// The opened card holds this much of a report; the rest is cut with "…" (a report can run to pages).
    static let shownLimit = 12_000

    /// "Background Process Finished: npm test", "2 Background Processes Finished", "background process finished",
    /// and the timeline's own "Background task finished: npm test" (TimelineNotes.processHeadline).
    static func isProcess(_ title: String) -> Bool {
        title.range(of: "background process", options: .caseInsensitive) != nil || title.hasPrefix("Background task ")
    }

    /// The gateway's own titles ("Background Process Finished: npm test", "2 Background Processes Finished", "background
    /// process finished") in the timeline's and the alerts' words ("Background task finished: npm test"), so one chat
    /// never names the same thing two ways. Any other title is left as it is.
    static func plainTitle(_ title: String) -> String {
        // [updates] What finished leads: "npm test finished", "Subagent finished: <goal>" (owner, 2026-10-27: plain words).
        if let g = subagentTitle.groups(title), let whole = g[0] {
            var rest = title.dropFirst(whole.count).trimmingCharacters(in: .whitespaces)
            let verb = helperVerbs[g[2]?.lowercased() ?? ""] ?? "finished"
            // [helper-note] A job run by hand runs as a helper: the job leads, as a task's name does ("Fleet failure
            // review finished", not "Helper finished: Manual run of cron job 'Fleet failure review' (4bcc04325d3d)").
            if g[1] == nil, let job = manualCronRun.groups(rest)?[1] { return "\(job) \(verb)" }
            // [updates] Helpers, the work line's word ("1 helper"); "subagent" is a developer's word (owner, 2026-10-28).
            var words = g[1] == nil ? "Helper \(verb)" : "Helpers \(verb)"
            if g[1] != nil, let count = taskCount.groups(rest), let whole = count[0], let n = count[1] {
                words = "\(n) helpers \(verb)"
                rest = String(rest.dropLast(whole.count))
            }
            return rest.isEmpty ? words : words + ": " + rest
        }
        if let g = namedTask.groups(title), let whole = g[0], let verb = g[1] {
            let what = title.dropFirst(whole.count).trimmingCharacters(in: .whitespaces)
            if !what.isEmpty { return what + (verb.lowercased() == "failed" ? " failed" : " finished") }
        }
        if let g = agentsTitle.groups(title), let whole = g[0] {
            let count = g[1].flatMap { Int($0) }
            let words = count.map { $0 == 1 ? "1 helper finished" : "\($0) helpers finished" } ?? "Helpers finished"
            return words + title.dropFirst(whole.count)
        }
        guard let groups = gatewayTitle.groups(title), let whole = groups[0] else { return title }
        let verb = groups[2]?.lowercased() == "failed" ? "failed" : "finished"
        let words: String
        if let count = groups[1].flatMap({ Int($0) }) {
            words = count == 1 ? "1 background task \(verb)" : "\(count) background tasks \(verb)"
        } else {
            words = "Background task \(verb)"
        }
        return words + title.dropFirst(whole.count)
    }

    /// "Background Process Finished:" / "Background task failed:" before one task's name.
    private static let namedTask = TRx(#"^background (?:process|task) (finished|completed|failed):"#, [.caseInsensitive])
    /// "Background agents finished", "2 background agents finished", "background agent work finished": helpers.
    private static let agentsTitle = TRx(#"^(?:(\d+) )?background agents?(?: work)? finished\b"#, [.caseInsensitive])
    /// The gateway's "Subagent Task Completed:" before a goal, and its other outcomes ("Subagent Task Failed:",
    /// "Subagent Tasks Finished with Issues:", H:tools/process_registry_notifications.py async_delegation_display_text).
    private static let subagentTitle = TRx(#"^subagent task(s)? (completed|finished with issues|finished|incomplete|failed|cancelled|interrupted|timed out|stalled|unknown):?"#,
                                           [.caseInsensitive])
    private static let helperVerbs = ["failed": "failed", "incomplete": "stopped early", "cancelled": "cancelled",
                                      "interrupted": "interrupted", "timed out": "timed out", "stalled": "stalled",
                                      "finished with issues": "finished with problems"]
    /// The goal Hermes gives a job run by hand (`cronjob(action='run')`).
    private static let manualCronRun = TRx(#"^Manual run of cron job '(.+)' \([^()]*\)$"#)
    /// A batch title's count after its goals: " (3 tasks)".
    private static let taskCount = TRx(#" \((\d+) tasks\)$"#)

    /// [updates] A line shows only the words before its colon: "Subagents finished", "Ivy", "Watch" (owner, 2026-10-27:
    /// "should only have the words before the :"). The rest leads the opened card unless the card already says it.
    /// [updates] A bot's name on a line: a handle with no roster seat ("inbox") reads as a name ("From Inbox", beside
    /// "From Ivy"); a name with capitals is kept as it is.
    static func botName(_ name: String) -> String {
        guard let first = name.first, name == name.lowercased() else { return name }
        return first.uppercased() + name.dropFirst()
    }

    static func split(_ title: String) -> (head: String, rest: String) {
        guard let colon = title.range(of: ": ") else { return (title, "") }
        let head = String(title[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty else { return (title, "") }
        return (head, String(title[colon.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The opened card's words: the title's rest (when the report doesn't already hold it), then the report.
    static func opened(title: String, result: String) -> String {
        let rest = split(title).rest
        let says = rest.isEmpty || result.contains(String(rest.prefix(40)).replacingOccurrences(of: "…", with: ""))
        return [says ? nil : rest, result].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    private static let gatewayTitle = TRx(#"^(?:(\d+) )?background process(?:es)? (finished|completed|failed)\b"#, [.caseInsensitive])

    /// A process's output as it printed it (the desktop shows it as a log), cut like a report.
    static func log(_ output: String) -> String {
        output.utf8.count > shownLimit ? ChatText.clip(output, max: shownLimit) + "…" : output
    }

    /// The report as written, cut like the rest: an opened card draws its Markdown as a reply's (`.formatted`), so a
    /// /btw answer keeps its bold and code (Mac polish #25).
    static func clipped(_ report: String) -> String {
        let text = ChatText.trimmed(report)
        return text.utf8.count > shownLimit ? ChatText.clip(text, max: shownLimit) + "…" : text
    }

    /// The report as plain lines: Markdown marks dropped (`**`, backticks, `#` headings), bullets as "•".
    static func readable(_ report: String) -> String {
        var text = clipped(report)
        text = text.replacingOccurrences(of: #"\*\*|__|`+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^[ \t]{0,3}#{1,6}[ \t]+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^([ \t]*)[-*+][ \t]+"#, with: "$1• ", options: .regularExpression)
        return text
    }

    /// Markdown links (and images) as their words: "[the thread](https://…)" reads "the thread".
    static func linkWords(_ text: String) -> String {
        markdownLink.replace(text, with: "$1")
    }

    /// [updates] A note that is another bot's message ("Message from 🤖 inbox (@inbox): …"): its name for the line and
    /// the words without the prefix for the card (owner, 2026-10-27: "needs to be formatted … legible").
    static func fromBot(_ text: String) -> (name: String, body: String)? {
        guard let g = botMessage.groups(text), let whole = g[0], let name = g[1], !name.isEmpty else { return nil }
        return (name, String(text.dropFirst(whole.count)).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static let botMessage = TRx(#"^\s*Message from\s+(?:[^\w\s(]+\s+)?([^\n(]{1,40}?)\s*\(@[\w.-]+\):\s*"#)

    /// "[words](address)" and "![words](address)": the words in group 1, the address in group 2.
    static let markdownLink = TRx(#"!?\[([^\]\n]*)\]\(([^)\s]+)\)"#)
}

/// A chat whose timeline notes can carry a report (`MessageMeta.asyncResult`).
protocol ChatBackgroundResultSource: AnyObject {
    func backgroundResult(_ messageId: String) -> String?
}

extension LiveChatSession: ChatBackgroundResultSource {
    func backgroundResult(_ messageId: String) -> String? { meta(for: messageId)?.asyncResult }
}

/// [botdm] This chat's bot messaging another (`message_agent`): one line, "To Hermes: <the message>", with Hermes's
/// face, that opens on the whole message. Drawn like the reply that comes back (a delivery's row), so the exchange
/// reads as two bots talking, not a tool run and a process note. A call that failed sent nothing: no line ("Not sent
/// to Hermes" told you of a message that never went anywhere; owner, 2026-10-29: "what was the purpose of the
/// notification there? Bad UX"). It stays a failed step of the reply's work, as any failed tool call does.
nonisolated enum BotDMRows {
    static func sent(_ m: ChatMessage, call: ToolCall, part: Int, input: ChatRowBuilder.Input) -> ChatRow? {
        guard call.state != .failed else { return nil }
        let args = ToolArgs.parse(call.argsText)
        guard let target = args["target"]?.string, !target.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let message = args["message"]?.string ?? ""
        let to = BotDMs.sender(target, roster: input.bots)
        let id = "\(m.id)|dm\(part)"
        let expanded = input.expanded.contains(id)
        let name = BackgroundResults.botName(to.name)
        let title = DeliveryRows.title(sender: "To \(name)", text: message)
        var h = Hasher()
        RowHash.add(title, to: &h)
        RowHash.add(message, to: &h)
        h.combine(expanded)
        h.combine(to)
        var row = BackgroundResultRow(title: title, result: BackgroundResults.readable(message), process: false, expanded: expanded)
        row.delivery = true
        row.sentTo = true
        row.face = to
        // [updates] Centred like every other update, also inside a reply (owner, 2026-10-28: it went full width once sent):
        // the build folds it with the small rows around it (UpdateGroups), a line of its own when it stands alone.
        return ChatRow(id: id, messageId: m.id, scope: input.scope, fingerprint: h.finalize(),
                       kind: .backgroundResult(row), gapAbove: ChatMetrics.turnGap, variant: expanded ? 1 : 0)
    }
}

/// [groups] A message another bot delivered into a bot's own chat (docs/spec/3x-groups.md §7.12) draws as a background
/// result's line: "Inbox: Three new emails need a reply." cut to one line, the whole message behind it.
nonisolated enum DeliveryRows {
    /// The row's line: the sender's name and its words on one line (newlines and runs of spaces as one space), as plain
    /// words: no Markdown marks, heading hashes or link addresses.
    static func title(sender: String, text: String) -> String {
        let plain = BackgroundResults.linkWords(BackgroundResults.readable(text))
        let words = ChatText.trimmed(plain).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let line = words.utf8.count > 400 ? ChatText.clip(words, max: 400) : words
        return line.isEmpty ? sender : sender + ": " + line
    }
}
