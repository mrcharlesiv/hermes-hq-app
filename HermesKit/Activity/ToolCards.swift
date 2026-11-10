// Card tools drawn in place in the transcript (docs/spec/1x-activity.md §11): the bounded extract of a finished call's
// result that its card needs (`ToolCard`), the `delegate_task` rows (port of
// V:components/assistant-ui/tool/delegate-model.ts) and the generated-image frame's geometry.

import Foundation

nonisolated struct DelegateResult: Hashable, Sendable {
    var status: String
    var summary: String?
    var model: String?
    var durationSeconds: Double?
}

/// What a finished card tool's result says, bounded (≤ 16 goals × 300 characters). Running calls have none.
nonisolated enum ToolCard: Hashable, Sendable {
    case delegate(goals: [String], results: [DelegateResult]?, dispatchedGoals: [String]?)
    case image(path: String, aspect: String?, pixelWidth: Int?, pixelHeight: Int?)
    /// [tasks] `tasks_add`: the tasks a bot put on your list ("Added to Tasks" under the reply). Not a card tool: its
    /// step draws as any other; the card goes under the settled reply.
    case tasksAdded([AddedTask])
}

/// [tasks] One task a bot added, as the chat card shows it.
nonisolated struct AddedTask: Hashable, Sendable {
    /// A step of a together task: "me" (yours) or "bot".
    nonisolated struct Step: Hashable, Sendable {
        var title: String
        var who: String
        var done: Bool
    }

    var id: String
    var title: String
    /// "me" | "bot" | "together".
    var who: String
    var bot: String?
    /// The wire due ("2026-11-05" or a moment).
    var due: String?
    var steps: [Step] = []
    /// The bot gets its part ready ahead of time (hermes-hq-push `prep`).
    var prep = false
    /// [tasks] 0.9.33's `start_now` started the bot's part in the background (`start: "started: …"`).
    var started = false
    /// [tasks] 0.9.33: a `tasks_update` where the bot took a part of your own task (its log's last line).
    var tookPart = false

    init(id: String, title: String, who: String, bot: String?, due: String?, steps: [Step] = [], prep: Bool = false,
         started: Bool = false, tookPart: Bool = false) {
        self.id = id; self.title = title; self.who = who; self.bot = bot; self.due = due
        self.steps = steps; self.prep = prep; self.started = started; self.tookPart = tookPart
    }

    init?(_ record: [String: JSONValue]) {
        let id = ToolCards.field(record, ["id"]), title = ToolCards.field(record, ["title"])
        guard !id.isEmpty, !title.isEmpty else { return nil }
        let who = ToolCards.field(record, ["who"]), bot = ToolCards.field(record, ["bot"]), due = ToolCards.field(record, ["due"])
        let steps = (record["steps"]?.array ?? []).prefix(ToolCards.maxGoals).compactMap { value -> Step? in
            let step = ActivityJSON.object(value)
            let title = ToolCards.field(step, ["title"])
            guard !title.isEmpty else { return nil }
            let who = ToolCards.field(step, ["who"])
            return Step(title: String(title.prefix(ToolCards.maxText)), who: who == "me" ? "me" : "bot",
                        done: step["done"]?.bool ?? false)
        }
        var tookPart = record["took_part"]?.bool ?? false
        if !tookPart, let last = record["log"]?.array?.last, ActivityJSON.object(last)["text"]?.string == "took a part" {
            tookPart = true
        }
        self.init(id: id, title: String(title.prefix(ToolCards.maxText)), who: who.isEmpty ? "me" : who,
                  bot: bot.isEmpty ? nil : bot, due: due.isEmpty ? nil : due, steps: Array(steps),
                  prep: record["prep"]?.bool ?? false,
                  started: (record["start"]?.string ?? "").hasPrefix("started") || (record["started"]?.bool ?? false),
                  tookPart: tookPart)
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "title": .string(title), "who": .string(who)]
        if let bot { o["bot"] = .string(bot) }
        if let due { o["due"] = .string(due) }
        if !steps.isEmpty {
            o["steps"] = .array(steps.map { .object(["title": .string($0.title), "who": .string($0.who), "done": .bool($0.done)]) })
        }
        if prep { o["prep"] = .bool(true) }
        if started { o["started"] = .bool(true) }
        if tookPart { o["took_part"] = .bool(true) }
        return .object(o)
    }

    /// A later `tasks_update` in the same reply (0.9.33: the bot added your task, then took its part): its who,
    /// helper and steps; the start stays started once either call started it.
    func updated(by later: AddedTask) -> AddedTask {
        var task = self
        task.title = later.title; task.who = later.who; task.bot = later.bot; task.due = later.due
        task.steps = later.steps; task.prep = later.prep; task.started = started || later.started
        return task
    }
}

nonisolated enum ToolCards {
    static let maxGoals = 16
    static let maxText = 300

    /// Tools that draw a card instead of a step (§11.1). `clarify` is a card too, drawn by the questions stream.
    static let cardTools: Set<String> = ["delegate_task", "image_generate"]

    static func isCardTool(_ name: String) -> Bool { cardTools.contains(name) || name == "clarify" }

    private static func clip(_ s: String) -> String { s.count > maxText ? String(s.prefix(maxText - 1)) + "…" : s }

    /// `firstStringField`: the trimmed value of the first non-blank string among `keys`.
    static func field(_ record: [String: JSONValue], _ keys: [String]) -> String {
        for key in keys {
            if case .string(let s)? = record[key] {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        return ""
    }

    /// The card for a finished call (nil for a non-card tool, a failure, or a result without what the card needs).
    static func card(name: String, args: [String: JSONValue], result: JSONValue?) -> ToolCard? {
        guard let result else { return nil }
        switch name {
        case "delegate_task":
            let record = ActivityJSON.object(result)
            let goals = Array(delegateGoals(.object(args)).prefix(maxGoals)).map(clip)
            var results: [DelegateResult]?
            if case .array(let rows)? = record["results"] {
                results = rows.prefix(maxGoals).map { row in
                    let r = ActivityJSON.object(row)
                    let summary = field(r, ["summary"])
                    let model = field(r, ["model"])
                    return DelegateResult(status: field(r, ["status"]), summary: summary.isEmpty ? nil : clip(summary),
                                          model: model.isEmpty ? nil : model, durationSeconds: number(r["duration_seconds"]))
                }
            }
            var dispatched: [String]?
            if field(record, ["status"]) == "dispatched" {
                dispatched = ActivityJSON.strings(record["goals"]).prefix(maxGoals).map(clip)
            }
            return .delegate(goals: goals, results: results, dispatchedGoals: dispatched)
        case "image_generate":
            let record = ActivityJSON.object(result)
            if record["success"] == .bool(false) { return nil }
            let path = field(record, ["host_image", "image"])
            guard !path.isEmpty else { return nil }
            var w: Int?, h: Int?
            if case .string(let size)? = record["pixel_size"],
               let match = size.wholeMatch(of: /(\d+)x(\d+)/), let a = Int(match.1), let b = Int(match.2), a > 0, b > 0 {
                w = a; h = b
            }
            let aspect = field(args, ["aspect_ratio"])
            return .image(path: path, aspect: aspect.isEmpty ? nil : aspect, pixelWidth: w, pixelHeight: h)
        case "tasks_add", "tasks_update":
            // [tasks] The task itself (hermes-hq-push 0.9.32), or `{task: …}` / `{tasks: [...]}`; a refusal has no id.
            // A `tasks_update` only changes a card its reply's `tasks_add` made, or says the bot took a part of yours.
            let record = ActivityJSON.object(result)
            var rows: [[String: JSONValue]] = [record]
            if case .array(let many)? = record["tasks"] { rows = many.map { ActivityJSON.object($0) } }
            else if case .object(let one)? = record["task"] { rows = [one] }
            let added = rows.prefix(maxGoals).compactMap { AddedTask($0) }
            return added.isEmpty ? nil : .tasksAdded(added)
        default:
            return nil
        }
    }

    /// `numberValue`: a number or a numeric string.
    static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .number(let n)? where n.isFinite: return n
        case .string(let s)?: return Double(s.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
        default: return nil
        }
    }

    // MARK: Delegate rows (`delegate-model.ts`)

    enum RowStatus: Hashable, Sendable {
        case queued, running, completed, failed, interrupted
        /// A background dispatch whose children outlived the turn: nothing here watches it, so it must not spin.
        case dispatched

        var isLive: Bool { self == .running || self == .queued }

        init(_ s: SubagentStatus) {
            switch s {
            case .queued: self = .queued
            case .running: self = .running
            case .completed: self = .completed
            case .failed: self = .failed
            case .interrupted: self = .interrupted
            }
        }
    }

    struct DelegateRow: Hashable, Sendable {
        /// Oldest → newest; the card tickers the newest.
        var activity: [String]
        var durationSeconds: Double?
        var goal: String
        var id: String
        var model: String?
        var sessionId: String?
        var status: RowStatus
        /// When the live child started (for the elapsed timer), seconds since 1970.
        var startedAt: Double?
    }

    /// The goals a call dispatched, in task order.
    static func delegateGoals(_ args: JSONValue?) -> [String] {
        let record = ActivityJSON.object(args)
        if case .array(let tasks)? = record["tasks"], !tasks.isEmpty {
            return tasks.enumerated().map { index, task in
                let goal = field(ActivityJSON.object(task), ["goal"])
                return goal.isEmpty ? "Task \(index + 1)" : goal
            }
        }
        let goal = field(record, ["goal"])
        return goal.isEmpty ? [] : [goal]
    }

    private static func settled(_ status: String) -> RowStatus {
        status.isEmpty || status == "ok" || status == "completed" ? .completed : .failed
    }

    /// The rows a call describes on its own (`delegateRowsFromCall`): running before a result, parked once dispatched.
    static func rows(goals: [String], card: ToolCard?, hasResult: Bool, toolCallId: String) -> [DelegateRow] {
        var finished: [DelegateResult] = []
        var dispatched: [String] = []
        if case .delegate(_, let results, let d)? = card {
            finished = results ?? []
            dispatched = d ?? []
        }
        let titles = !goals.isEmpty ? goals : !dispatched.isEmpty ? dispatched : finished.map { _ in "Delegated task" }
        let idle: RowStatus = hasResult ? .dispatched : .running
        return titles.enumerated().map { index, goal in
            let entry = index < finished.count ? finished[index] : nil
            let summary = entry?.summary ?? ""
            return DelegateRow(activity: summary.isEmpty ? [] : [summary], durationSeconds: entry?.durationSeconds, goal: goal,
                               id: "\(toolCallId):\(index)", model: entry?.model,
                               status: entry.map { settled($0.status) } ?? idle, startedAt: nil)
        }
    }

    private static func normalize(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// Layer the chat's live subagents over the rows (`mergeDelegateRows`): by stand-in id, then goal, then task order
    /// only when both sides have the same count. Live state wins.
    static func merge(_ rows: [DelegateRow], live: [SubagentProgress], toolCallId: String) -> [DelegateRow] {
        guard !live.isEmpty else { return rows }
        var unclaimed = live
        func claim(_ predicate: (SubagentProgress) -> Bool) -> SubagentProgress? {
            guard let index = unclaimed.firstIndex(where: predicate) else { return nil }
            return unclaimed.remove(at: index)
        }
        let prefix = toolCallId.isEmpty ? "" : "delegate-tool:\(toolCallId):"
        let byId: [SubagentProgress?] = rows.indices.map { index in prefix.isEmpty ? nil : claim { $0.id == "\(prefix)\(index)" } }
        var byGoal: [SubagentProgress?] = []
        for (index, row) in rows.enumerated() {
            byGoal.append(byId[index] ?? claim { normalize($0.goal) == normalize(row.goal) })
        }
        let sameShape = rows.count == live.count
        return rows.enumerated().map { index, row in
            guard let matched = byGoal[index] ?? (sameShape ? claim { $0.taskIndex == index } : nil) else { return row }
            return DelegateRow(activity: matched.stream.map(\.text).filter { !$0.isEmpty }, durationSeconds: matched.durationSeconds,
                               goal: matched.goal.isEmpty ? row.goal : matched.goal, id: matched.id.isEmpty ? row.id : matched.id,
                               model: matched.model, sessionId: matched.sessionId, status: RowStatus(matched.status),
                               startedAt: matched.startedAt)
        }
    }

    // MARK: Words

    /// `formatDurationSeconds`: "Nms" under 1 s, "4.2s" under 10 s, "42s" under a minute, then "Xm Ys"/"Xm", "Xh Ym"/"Xh".
    static func formatDurationSeconds(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        if seconds < 1 { return "\(max(1, Int((seconds * 1000).rounded())))ms" }
        if seconds < 60 { return seconds >= 10 ? "\(Int(seconds.rounded()))s" : String(format: "%.1fs", seconds) }
        let whole = Int(seconds.rounded())
        let minutes = whole / 60, rem = whole % 60
        if minutes < 60 { return rem > 0 ? "\(minutes)m \(rem)s" : "\(minutes)m" }
        let hours = minutes / 60, remMinutes = minutes % 60
        return remMinutes > 0 ? "\(hours)h \(remMinutes)m" : "\(hours)h"
    }

    /// Width / height of the generated-image frame: the result's pixel size when known, else the hinted aspect
    /// (landscape 16:9 by default, square 1:1, portrait 9:16).
    static func imageRatio(aspect: String?, pixelWidth: Int?, pixelHeight: Int?) -> Double {
        if let w = pixelWidth, let h = pixelHeight, w > 0, h > 0 { return Double(w) / Double(h) }
        switch (aspect ?? "").lowercased().trimmingCharacters(in: .whitespaces) {
        case "square": return 1
        case "portrait": return 9.0 / 16.0
        default: return 16.0 / 9.0
        }
    }

    /// The hinted aspect from a running call's arguments.
    static func aspectHint(_ argsText: String?) -> String? {
        let args = ToolArgs.parse(argsText)
        let a = field(args, ["aspect_ratio"])
        return a.isEmpty ? nil : a
    }
}

// MARK: - Provider waits and fallback notices (§8.2, §8.3)

nonisolated enum ProviderWait {
    private static let pattern = try! NSRegularExpression(
        pattern: #"^(?:⏳|⚠|↻|⚙)\s*(?:(?:still\s+)?waiting on|loading|processing prompt|no (?:output|response)|model returned|rate limited|provider (?:overloaded|temporarily unavailable))"#,
        options: [.caseInsensitive])

    /// The explained-wait text a `thinking.delta` carries, trimmed; "" for every other frame (spinner rewrites), which
    /// clears a shown wait (V:store/provider-wait.ts `providerWaitText`, `setSessionProviderWait`).
    static func text(_ raw: String?) -> String {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        let range = NSRange(value.startIndex..., in: value)
        return pattern.firstMatch(in: value, range: range) != nil ? value : ""
    }

    /// Events that end a shown wait (V:app/session/hooks/use-message-stream/gateway-event/index.ts:67-78).
    static let clearingEvents: Set<String> = ["error", "message.complete", "message.delta", "message.interim", "message.start",
                                              "reasoning.available", "reasoning.delta", "tool.complete", "tool.generating", "tool.start"]

    private static let fallbackPattern = try! NSRegularExpression(
        pattern: "model fallback|provider fallback|switched to fallback|switching to fallback", options: [.caseInsensitive])

    /// The id prefix of a fallback notice row (`fallback-switch-<seconds>` with M1's client-side "local-" mark).
    static let noticeIdPrefix = "local-fallback-switch-"

    /// A `status.update` that announces a model / provider fallback: its text, else nil.
    static func fallbackNotice(kind: String?, text: String?) -> String? {
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if kind == "fallback" { return t }
        let range = NSRange(t.startIndex..., in: t)
        return fallbackPattern.firstMatch(in: t, range: range) != nil ? t : nil
    }

    /// The notice in plain words: "Opus 5.5 hit a usage limit, so GPT-6.1-sol is answering for now." Both gateway shapes
    /// (`agent/chat_completion_helpers.py` "Model fallback: …", `hermes_cli/fallback_config.py` "Provider fallback: …");
    /// any other line stays as it came, without its leading mark.
    static func plainNotice(_ text: String, displayName: (String) -> String = { ModelNames.displayModelName($0) },
                            providerName: (String) -> String = { ModelNames.providerDisplayName($0) }) -> String {
        let providerShape = text.contains("Provider fallback:")
        func name(_ id: String, placeholder: String, or words: String) -> String {
            var bare = id
            if bare.hasSuffix("]"), let open = bare.lastIndex(of: "[") { bare = String(bare[..<open]) }
            if bare.lowercased() == placeholder { return words }
            let shown: String
            if let slash = bare.lastIndex(of: "/") {
                bare = String(bare[bare.index(after: slash)...])
                shown = displayName(bare)
            } else {
                shown = providerShape ? providerName(bare) : displayName(bare)
            }
            let trimmed = shown.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? bare : trimmed
        }
        if let f = ModelFallback.parse(text) {
            let reason = (f.reason ?? "").lowercased()
            let what: String
            if ["rate", "limit", "quota", "billing", "429"].contains(where: reason.contains) {
                what = "hit a usage limit"
            } else if ["overload", "busy", "529", "503"].contains(where: reason.contains) {
                what = "is busy"
            } else if reason.contains("auth") {
                what = "couldn't sign in"
            } else if ["timeout", "server error"].contains(where: reason.contains) {
                what = "isn't responding"
            } else {
                what = "isn't available"
            }
            let primary = name(f.primary, placeholder: "primary", or: "Your usual model")
            let fallback = name(f.fallback, placeholder: "fallback", or: "another model")
            return "\(primary) \(what), so \(fallback) is answering for now."
        }
        if ModelFallback.restores(text), let range = text.range(of: "Primary model restored:") {
            let id = text[range.upperBound...].split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
            let trimmed = id.trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
            return trimmed.isEmpty ? "Back to your usual model." : "Back to \(name(trimmed, placeholder: "", or: ""))."
        }
        var t = text
        for mark in ["⚠️", "⚠", "↻", "⚙"] where t.hasPrefix(mark) { t = String(t.dropFirst(mark.count)) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Cache form (TranscriptCoding stores a card as compact JSON)

nonisolated extension ToolCard {
    var json: JSONValue {
        switch self {
        case .delegate(let goals, let results, let dispatched):
            var o: [String: JSONValue] = ["kind": "delegate", "goals": .array(goals.map { .string($0) })]
            if let results {
                o["results"] = .array(results.map { r in
                    var e: [String: JSONValue] = ["status": .string(r.status)]
                    if let s = r.summary { e["summary"] = .string(s) }
                    if let m = r.model { e["model"] = .string(m) }
                    if let d = r.durationSeconds { e["duration_seconds"] = .number(d) }
                    return .object(e)
                })
            }
            if let dispatched { o["dispatched"] = .array(dispatched.map { .string($0) }) }
            return .object(o)
        case .image(let path, let aspect, let w, let h):
            var o: [String: JSONValue] = ["kind": "image", "path": .string(path)]
            if let aspect { o["aspect"] = .string(aspect) }
            if let w { o["w"] = .number(Double(w)) }
            if let h { o["h"] = .number(Double(h)) }
            return .object(o)
        case .tasksAdded(let tasks):
            return .object(["kind": "tasks", "tasks": .array(tasks.map(\.json))])
        }
    }

    init?(json: JSONValue?) {
        guard let json else { return nil }
        switch json["kind"]?.string {
        case "delegate":
            let goals = ActivityJSON.strings(json["goals"])
            let results = json["results"]?.array.map { rows in
                rows.map { r in
                    DelegateResult(status: r["status"]?.string ?? "", summary: r["summary"]?.string, model: r["model"]?.string,
                                   durationSeconds: ActivityJSON.num(r["duration_seconds"]))
                }
            }
            let dispatched = json["dispatched"].map { ActivityJSON.strings($0) }
            self = .delegate(goals: goals, results: results, dispatchedGoals: dispatched)
        case "image":
            guard let path = json["path"]?.string else { return nil }
            self = .image(path: path, aspect: json["aspect"]?.string, pixelWidth: ActivityJSON.int(json["w"]),
                          pixelHeight: ActivityJSON.int(json["h"]))
        case "tasks":
            let tasks = (json["tasks"]?.array ?? []).compactMap { AddedTask(ActivityJSON.object($0)) }
            guard !tasks.isEmpty else { return nil }
            self = .tasksAdded(tasks)
        default:
            return nil
        }
    }
}
