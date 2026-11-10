// Subagent roster rules (docs/spec/1x-activity.md §4.2), a line-by-line port of V:store/subagents.ts and the delegate
// stand-ins of V:app/session/hooks/use-message-stream/utils.ts (§4.6). Pure value code: `SubagentRoster` is one
// chat's list plus the ids it retired; every mutation reports whether anything changed.

import Foundation

nonisolated struct SubagentRoster: Hashable, Sendable {
    private(set) var items: [SubagentProgress] = []
    /// Ids that were terminal in a list that has since been replaced: a late event or roster never brings them back
    /// (a turn prunes display rows, not child identities).
    private(set) var retired: Set<String> = []

    init(items: [SubagentProgress] = []) { self.items = items }

    var liveCount: Int { items.filter(\.isLive).count }

    /// Replace the list, retiring the terminal ids of the list it replaces (`setSessionSubagents`).
    private mutating func replace(with next: [SubagentProgress]) {
        for item in items where item.status.isTerminal { retired.insert(item.id) }
        items = next
    }

    // MARK: Events

    /// `upsertSubagent`: creates only when `createIfMissing` (spawn_requested / start); terminal rows are frozen.
    @discardableResult
    mutating func upsert(_ payload: [String: JSONValue], createIfMissing: Bool, eventType: String?, now: Double) -> Bool {
        let id = SubagentRules.idOf(payload)
        let index = items.firstIndex { $0.id == id }
        if retired.contains(id) || (index == nil && !createIfMissing) { return false }
        let prev = index.map { items[$0] }
        if let prev, prev.status.isTerminal { return false }
        let next = SubagentRules.toProgress(payload, prev: prev, eventType: eventType ?? "", now: now)
        var list = items
        if let index { list[index] = next } else { list.append(next) }
        replace(with: list)
        return true
    }

    /// `pruneFinishedSessionSubagents` (message.start): keep running / queued rows.
    @discardableResult
    mutating func pruneFinished() -> Bool {
        let next = items.filter(\.isLive)
        guard next.count != items.count else { return false }
        replace(with: next)
        return true
    }

    /// `pruneDelegateFallbackSubagents`: the first native event removes the `delegate-tool:` stand-ins.
    @discardableResult
    mutating func pruneDelegateStandIns() -> Bool {
        let next = items.filter { !$0.isDelegateStandIn }
        guard next.count != items.count else { return false }
        replace(with: next)
        return true
    }

    /// The turn ended (`message.complete`): a `delegate-tool:` stand-in still running missed its `tool.complete` (a link
    /// drop with no replay), since the tool call ends inside its turn. It goes, or it said "Working…" / "1 subagent"
    /// across turns on gateways with no `subagent.list` to correct it.
    @discardableResult
    mutating func pruneLiveDelegateStandIns() -> Bool {
        let next = items.filter { !($0.isDelegateStandIn && $0.isLive) }
        guard next.count != items.count else { return false }
        replace(with: next)
        return true
    }

    /// `clearSessionSubagents` (Stop): everything goes, retirements included.
    @discardableResult
    mutating func clear() -> Bool {
        let changed = !items.isEmpty || !retired.isEmpty
        items = []
        retired = []
        return changed
    }

    /// Keep only the live rows whose gateway id is listed (`delegation.status` reconcile, §4.4). Stand-ins stay.
    @discardableResult
    mutating func keepLive(listed ids: Set<String>) -> Bool {
        let next = items.filter { !$0.isLive || $0.isDelegateStandIn || ids.contains($0.id) }
        guard next.count != items.count else { return false }
        replace(with: next)
        return true
    }

    // MARK: Roster (`subagent.list`)

    /// `reconcileSubagentSnapshot`: keep terminal rows and listed ones; merge each listed child; failed delegations the
    /// list doesn't cover land as terminal failed rows.
    @discardableResult
    mutating func reconcile(children: [[String: JSONValue]], failedDelegations: [[String: JSONValue]] = [], now: Double) -> Bool {
        let previous = items
        let ids = Set(children.map { ActivityJSON.str($0["subagent_id"]) }.filter { !$0.isEmpty })
        var next = previous.filter { $0.status.isTerminal || ids.contains($0.id) }

        for payload in children {
            let id = ActivityJSON.str(payload["subagent_id"])
            if id.isEmpty || retired.contains(id) { continue }
            let index = next.firstIndex { $0.id == id }
            let prev = index.map { next[$0] }
            if let prev, prev.status.isTerminal { continue }
            var projected = SubagentRules.toProgress(payload, prev: prev, eventType: "", now: now)
            let started = (ActivityJSON.num(payload["started_at"]) ?? 0)
            projected.startedAt = started != 0 ? started : (prev?.startedAt ?? projected.startedAt)
            projected.updatedAt = prev?.updatedAt ?? projected.startedAt
            // A roster names the last tool, not a call running now: seed cold activity only.
            let lastTool = ActivityJSON.str(payload["last_tool"])
            if projected.stream.isEmpty && !lastTool.isEmpty {
                projected.stream = [SubagentStreamEntry(at: projected.updatedAt, isError: false, kind: .tool,
                                                        text: SubagentRules.formatTool(lastTool))]
            }
            if let index {
                if next[index] != projected { next[index] = projected }
            } else {
                next.append(projected)
            }
        }

        for payload in failedDelegations {
            let id = SubagentRules.failedDelegationId(payload)
            let delegationId = ActivityJSON.str(payload["delegation_id"])
            let taskIndex = ActivityJSON.int(payload["task_index"]) ?? 0
            if delegationId.isEmpty || retired.contains(id)
                || next.contains(where: { $0.id == id || ($0.delegationId == delegationId && $0.taskIndex == taskIndex) }) {
                continue
            }
            let completed = ActivityJSON.num(payload["completed_at"]) ?? 0
            let at = completed != 0 ? completed : now
            let dispatched = ActivityJSON.num(payload["dispatched_at"]) ?? 0
            let startedAt = dispatched != 0 ? dispatched : at
            var merged = payload
            merged["subagent_id"] = .string(id)
            merged["summary"] = .string(ActivityJSON.str(payload["error"]))
            var row = SubagentRules.toProgress(merged, prev: nil, eventType: "subagent.complete", now: now)
            row.durationSeconds = max(0, (at - startedAt).rounded())
            row.id = id
            row.startedAt = startedAt
            row.updatedAt = at
            next.append(row)
        }

        guard next != previous else { return false }
        replace(with: next)
        return true
    }
}

nonisolated enum SubagentRules {
    static let maxStream = 24
    static let previewMax = 220
    static let toolPreviewMax = 96

    /// `idOf`: the gateway's id, else `<parent or root>:<task index>:<goal>`.
    static func idOf(_ p: [String: JSONValue]) -> String {
        let id = ActivityJSON.str(p["subagent_id"])
        if !id.isEmpty { return id }
        let parent = ActivityJSON.str(p["parent_id"])
        let index = ActivityJSON.num(p["task_index"]).map(ActivityJSON.jsNumber) ?? "0"
        return "\(parent.isEmpty ? "root" : parent):\(index):\(ActivityJSON.str(p["goal"]))"
    }

    static func failedDelegationId(_ p: [String: JSONValue]) -> String {
        let index = ActivityJSON.num(p["task_index"]).map(ActivityJSON.jsNumber) ?? "0"
        return "delegation:\(ActivityJSON.str(p["delegation_id"])):\(index)"
    }

    /// `asStatus`: timeout/error → failed, cancelled → interrupted; a completion with anything else fails closed.
    static func status(_ value: JSONValue?, terminalEvent: Bool) -> SubagentStatus {
        let s = ActivityJSON.str(value)
        switch s {
        case "completed": return .completed
        case "failed": return .failed
        case "interrupted": return .interrupted
        case "timeout", "error": return .failed
        case "cancelled", "canceled": return .interrupted
        default:
            if terminalEvent { return .failed }
            return s == "queued" ? .queued : .running
        }
    }

    /// Whitespace collapsed, at most `max` characters with "…".
    static func compact(_ text: String, max: Int = previewMax) -> String {
        let line = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !line.isEmpty else { return "" }
        return line.count > max ? String(line.prefix(max - 1)) + "…" : line
    }

    /// `read_file` → "Read File"; with a preview: `Read File("CHANGELOG.md")`.
    static func formatTool(_ name: String, _ preview: String = "") -> String {
        let words = name.split(separator: "_").filter { !$0.isEmpty }.map { word -> String in
            guard let first = word.first else { return String(word) }
            return first.uppercased() + word.dropFirst()
        }
        let label = words.isEmpty ? name : words.joined(separator: " ")
        let snippet = compact(preview, max: toolPreviewMax)
        return snippet.isEmpty ? label : "\(label)(\"\(snippet)\")"
    }

    static func timeoutSummary(_ p: [String: JSONValue]) -> String {
        guard ActivityJSON.str(p["status"]) == "timeout" else { return "" }
        let seconds = ActivityJSON.num(p["duration_seconds"]).map(ActivityJSON.jsNumber) ?? "?"
        return "Timed out after \(seconds)s"
    }

    static func stream(_ p: [String: JSONValue], status: SubagentStatus, eventType: String, at: Double) -> [SubagentStreamEntry] {
        var out: [SubagentStreamEntry] = []
        let tool = ActivityJSON.str(p["tool_name"])
        let toolPreview = ActivityJSON.str(p["tool_preview"])
        let preview = toolPreview.isEmpty ? ActivityJSON.str(p["text"]) : toolPreview
        let rawText = ActivityJSON.str(p["text"])
        let text = compact(rawText.isEmpty ? preview : rawText)
        let isError = p["error"].isTruthy
        if case .array(let tail)? = p["output_tail"] {
            for item in tail {
                guard case .object(let entry) = item else { continue }
                let tailTool = ActivityJSON.str(entry["tool"])
                let tailPreview = ActivityJSON.str(entry["preview"])
                let line = tailTool.isEmpty ? compact(tailPreview) : formatTool(tailTool, tailPreview)
                if !line.isEmpty {
                    out.append(SubagentStreamEntry(at: at, isError: entry["is_error"] == .bool(true),
                                                   kind: tailTool.isEmpty ? .progress : .tool, text: line))
                }
            }
        }
        if !tool.isEmpty { out.append(SubagentStreamEntry(at: at, isError: isError, kind: .tool, text: formatTool(tool, preview))) }
        if eventType == "subagent.progress", !text.isEmpty {
            out.append(SubagentStreamEntry(at: at, isError: isError, kind: .progress, text: text))
        }
        if eventType == "subagent.thinking", !text.isEmpty {
            out.append(SubagentStreamEntry(at: at, isError: false, kind: .thinking, text: text))
        }
        let summarySource = [ActivityJSON.str(p["summary"]), rawText, timeoutSummary(p)].first { !$0.isEmpty } ?? ""
        let summary = compact(summarySource)
        if status.isTerminal, !summary.isEmpty {
            out.append(SubagentStreamEntry(at: at, isError: status == .failed, kind: .summary, text: summary))
        }
        return out
    }

    /// A repeat of the last entry is not appended; at most `maxStream` entries.
    static func append(_ stream: [SubagentStreamEntry], _ entry: SubagentStreamEntry) -> [SubagentStreamEntry] {
        if let last = stream.last, last.kind == entry.kind, last.text == entry.text, last.isError == entry.isError { return stream }
        return Array((stream + [entry]).suffix(maxStream))
    }

    /// `toProgress`: one event (or roster entry) merged over the previous row.
    static func toProgress(_ p: [String: JSONValue], prev: SubagentProgress?, eventType: String, now: Double) -> SubagentProgress {
        let status = status(p["status"], terminalEvent: eventType == "subagent.complete")
        let tool = ActivityJSON.str(p["tool_name"])
        let entries = stream(p, status: status, eventType: eventType, at: now)
        let stream = entries.reduce(prev?.stream ?? [], append)
        let filesRead = ActivityJSON.strings(p["files_read"])
        let filesWritten = ActivityJSON.strings(p["files_written"])
        func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }
        let summary = nonEmpty(ActivityJSON.str(p["summary"])) ?? nonEmpty(timeoutSummary(p)) ?? prev?.summary
        return SubagentProgress(
            id: prev?.id ?? idOf(p),
            parentId: nonEmpty(ActivityJSON.str(p["parent_id"])) ?? prev?.parentId,
            goal: nonEmpty(ActivityJSON.str(p["goal"])) ?? nonEmpty(prev?.goal ?? "") ?? "Helper",
            sessionId: nonEmpty(ActivityJSON.str(p["child_session_id"])) ?? prev?.sessionId,
            delegationId: nonEmpty(ActivityJSON.str(p["delegation_id"])) ?? prev?.delegationId,
            model: nonEmpty(ActivityJSON.str(p["model"])) ?? prev?.model,
            status: status,
            taskCount: ActivityJSON.num(p["task_count"]).map { Int($0) } ?? prev?.taskCount ?? 1,
            taskIndex: ActivityJSON.num(p["task_index"]).map { Int($0) } ?? prev?.taskIndex ?? 0,
            startedAt: prev?.startedAt ?? now,
            updatedAt: now,
            durationSeconds: ActivityJSON.num(p["duration_seconds"]) ?? prev?.durationSeconds,
            inputTokens: ActivityJSON.num(p["input_tokens"]) ?? prev?.inputTokens,
            outputTokens: ActivityJSON.num(p["output_tokens"]) ?? prev?.outputTokens,
            toolCount: ActivityJSON.num(p["tool_count"]) ?? prev?.toolCount,
            filesRead: filesRead.isEmpty ? (prev?.filesRead ?? []) : filesRead,
            filesWritten: filesWritten.isEmpty ? (prev?.filesWritten ?? []) : filesWritten,
            stream: stream,
            summary: summary,
            currentTool: status.isTerminal ? nil : (nonEmpty(tool) ?? prev?.currentTool))
    }

    // MARK: Delegate stand-ins (§4.6, `delegateTaskPayloads`)

    /// The rows a `delegate_task` tool event stands in for on gateways that send no `subagent.*` (one per task).
    static func delegatePayloads(_ payload: JSONValue, complete: Bool, sourceEventType: String) -> [[String: JSONValue]] {
        guard payload["name"]?.string == "delegate_task" else { return [] }
        let args = ActivityJSON.object(payload["args"] ?? payload["input"])
        let result = ActivityJSON.object(payload["result"])
        let rawTasks: [JSONValue] = { if case .array(let a)? = args["tasks"] { return a }; return [] }()
        let tasks: [[String: JSONValue]] = rawTasks.isEmpty ? [args] : rawTasks.map { ActivityJSON.object($0) }
        let resultStatus = ActivityJSON.str(result["status"]).lowercased()
        let failed = payload["error"].isTruthy || ["timeout", "error", "failed", "failure"].contains(resultStatus)
        let status = complete ? (failed ? "failed" : "completed") : "running"
        let toolId = [payload["tool_id"], payload["tool_call_id"], payload["id"]].map(ActivityJSON.str).first { !$0.isEmpty } ?? "delegate_task"
        let progress = [payload["preview"], payload["message"], payload["context"]].map(ActivityJSON.str).first { !$0.isEmpty } ?? ""
        let eventType = complete ? "subagent.complete" : (sourceEventType == "tool.start" ? "subagent.start" : "subagent.progress")
        let summary = [result["summary"], payload["summary"], payload["message"]].map(ActivityJSON.str).first { !$0.isEmpty } ?? ""
        return tasks.enumerated().map { index, task in
            let goal = [task["goal"], args["goal"], payload["context"]].map(ActivityJSON.str).first { !$0.isEmpty } ?? "Delegated task"
            var out: [String: JSONValue] = [
                "depth": 0, "goal": .string(goal), "status": .string(status),
                "subagent_id": .string("delegate-tool:\(toolId):\(index)"),
                "task_count": .number(Double(tasks.count)), "task_index": .number(Double(index)),
            ]
            if let d = ActivityJSON.num(payload["duration_s"]) { out["duration_seconds"] = .number(d) }
            if !summary.isEmpty { out["summary"] = .string(summary) }
            if eventType == "subagent.progress" { out["text"] = .string(progress.isEmpty ? goal : progress) }
            if eventType == "subagent.start" {
                out["tool_name"] = "delegate_task"
                if !progress.isEmpty { out["tool_preview"] = .string(progress) }
            }
            if complete && !summary.isEmpty {
                out["output_tail"] = [["is_error": .bool(payload["error"].isTruthy), "preview": .string(summary), "tool": "delegate_task"]]
            }
            return out
        }
    }

    // MARK: Words

    /// "Ns" under a minute, else "m:ss" (`formatElapsed`, V:components/chat/activity-timer.ts), and "h:mm:ss" from an
    /// hour (never "75:00"), as the Talk dock's timer reads.
    static func formatElapsed(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    /// The detail's stats duration (`fmtDuration`, V:app/agents/index.tsx:105-118): "" for none, else the tool cards'
    /// words (`ToolCards.formatDurationSeconds`: "4.2s", "42s", "2m 5s", "1h 3m"), so a helper's time reads as its step's
    /// does. The whole seconds are rounded before they split, so 119.6 s is "2m", never "1m 60s".
    static func formatDuration(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "" }
        return ToolCards.formatDurationSeconds(seconds)
    }

    /// `fmtAge`: "now" under 2 s, "Ns ago", "Nm ago", then unbounded hours "Nh ago".
    static func formatAge(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 2 { return "now" }
        if s < 60 { return "\(s)s ago" }
        let m = s / 60
        return m < 60 ? "\(m)m ago" : "\(m / 60)h ago"
    }

    /// `compactNumber` (apps/shared/src/format.ts): 999 → "999", 1230 → "1.2k", 1_500_000 → "1.5M".
    static func compactNumber(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0" }
        func scaled(_ v: Double, _ suffix: String) -> String {
            var text = String(format: "%.1f", v)
            if text.hasSuffix(".0") { text.removeLast(2) }
            return text + suffix
        }
        if value >= 999_950 { return scaled(value / 1_000_000, "M") }
        if value >= 999.5 { return scaled(value / 1_000, "k") }
        return String(Int(value.rounded()))
    }

    /// The opened child's stats line: model · duration · N tools · N tok · updated <age> (V:app/agents/index.tsx:355-361).
    static func statsLine(_ s: SubagentProgress, now: Double) -> String {
        let elapsed = max(0, (now - s.startedAt).rounded(.down))
        let duration = s.durationSeconds.map { max(0, $0.rounded()) } ?? elapsed
        let tokens = (s.inputTokens ?? 0) + (s.outputTokens ?? 0)
        let parts = [s.model ?? "", formatDuration(duration),
                     (s.toolCount ?? 0) > 0 ? "\(ActivityJSON.jsNumber(s.toolCount ?? 0)) tools" : "",
                     tokens > 0 ? "\(compactNumber(tokens)) tok" : "",
                     "updated \(formatAge(now - s.updatedAt))"]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "1 helper" / "2 helpers": the chip's word, as its "Helpers finished" and the work line say (owner, 2026-10-28:
    /// "subagent" is a developer's word).
    static func chipWords(liveCount: Int) -> String { liveCount == 1 ? "1 helper" : "\(liveCount) helpers" }
}
