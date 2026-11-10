// The phone's Kanban board model (docs/spec/1x-pages.md §4.3–§4.5), ported from the web's `src/ui-kanban/model.ts`
// with `kanban.test.ts` as the oracle, plus the plugin's words it uses (`V/plugins/kanban/i18n.ts`, `ui.tsx`,
// `drawer.tsx` `eventText`). Pure functions on value snapshots.

import Foundation

nonisolated enum KanbanModel {
    /// Chips in workflow order, except Blocked: it is often waiting on you, so it leads.
    static let statusOrder = ["blocked", "triage", "todo", "scheduled", "ready", "running", "review", "done"]

    /// Blocked covers every block kind (your input, another task, a missing tool, a retry): each row says which.
    static let statusHelp: [String: String] = [
        "blocked": "Waiting on something, often you.",
        "triage": "A bot turns the idea into a proper task first.",
        "todo": "Waits until the tasks it depends on are done.",
        "scheduled": "Waiting for its scheduled time.",
        "ready": "The assigned bot picks it up within a minute.",
        "running": "A bot is working on it.",
        "review": "A bot is checking the work.",
        "done": "Finished. The result is on the task.",
    ]

    /// A status's list heading, "2 Tasks · A bot is working on it": the help without its full stop (a heading, often drawn in
    /// tracked capitals in the Desktop Look, where "WAITING ON YOU." read as a typo).
    static func groupHeading(count: Int, status: String) -> String {
        var help = statusHelp[status] ?? ""
        if help.hasSuffix(".") { help.removeLast() }
        let tasks = "\(count) \(count == 1 ? "Task" : "Tasks")"
        return help.isEmpty ? tasks : "\(tasks) · \(help)"
    }

    /// The line under a task's title: a running task names the bot doing it ("Deploys is working on it.").
    static func statusLine(_ status: String, worker: String?) -> String {
        if status == "running", let worker, !worker.isEmpty { return "\(worker) is working on it." }
        return statusHelp[status] ?? ""
    }

    /// The task sheet's Priority value, with which way it counts ("3 (higher goes first)", as its menu's title says).
    static func priorityWords(_ priority: Int) -> String { priority == 0 ? "None" : "\(priority) (higher goes first)" }

    /// An unassigned task's Assigned To, and the Assign To choice that unassigns: the board's default bot runs it when
    /// there is one ("Deploys (default)"), else no one does.
    static func nobodyWords(defaultBot: String) -> String { defaultBot.isEmpty ? "No One" : "\(defaultBot) (default)" }

    /// Column labels (`i18n.ts` `col.*.label`).
    static let statusLabels: [String: String] = [
        "triage": "Triage", "todo": "Todo", "scheduled": "Scheduled", "ready": "Ready", "running": "Running",
        "blocked": "Blocked", "review": "Review", "done": "Done", "archived": "Archived",
    ]

    static func label(_ status: String) -> String {
        statusLabels[status] ?? (status.prefix(1).uppercased() + status.dropFirst()).replacingOccurrences(of: "_", with: " ")
    }

    /// System-owned targets: a card may leave them, never be moved into them (`ui.tsx` `LOCKED_COLUMNS`).
    static let lockedColumns: Set<String> = ["review", "running", "scheduled"]
    static func isLocked(_ status: String) -> Bool { lockedColumns.contains(status) }

    static let lockedReasons: [String: String] = [
        "review": "A bot moves tasks into Review when it checks the work.",
        "running": "A bot moves a task into Running when it starts work on it.",
        "scheduled": "A bot schedules a task when it gives it a time to start.",
    ]

    /// The chips a board shows: every known status in order, then any the backend adds, never `archived`.
    static func chipOrder(_ columns: [String]) -> [String] {
        statusOrder.filter(columns.contains) + columns.filter { !statusOrder.contains($0) && $0 != "archived" }
    }

    static func statusCounts(_ board: KanbanBoard) -> [String: Int] {
        Dictionary(board.columns.map { ($0.name, $0.tasks.count) }, uniquingKeysWith: { a, _ in a })
    }

    /// The first status with work in it (Done last, it is history), else the first chip.
    static func defaultStatus(_ order: [String], _ counts: [String: Int]) -> String {
        if let first = order.first(where: { $0 != "done" && (counts[$0] ?? 0) > 0 }) { return first }
        if (counts["done"] ?? 0) > 0 { return "done" }
        return order.first ?? "triage"
    }

    static func matches(_ task: KanbanTask, _ query: String) -> Bool {
        let words = query.pgTrim.lowercased()
        return words.isEmpty || "\(task.title) \(task.body ?? "") \(task.id)".lowercased().contains(words)
    }

    static func filter(_ board: KanbanBoard, _ query: String) -> KanbanBoard {
        guard !query.pgTrim.isEmpty else { return board }
        var out = board
        out.columns = board.columns.map { KanbanColumn(name: $0.name, tasks: $0.tasks.filter { matches($0, query) }) }
        return out
    }

    /// Done reads as history: Today, Yesterday, This Week, then months ("September", "June 2025").
    static func doneGroup(_ seconds: Double?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let seconds, seconds > 0 else { return "Earlier" }
        let date = Date(timeIntervalSince1970: seconds)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days < 7 { return "This Week" }
        let month = JobWords.months[calendar.component(.month, from: date) - 1]
        return calendar.component(.year, from: date) == calendar.component(.year, from: now) ? month : "\(month) \(calendar.component(.year, from: date))"
    }

    /// Consecutive runs under one heading, in the order given.
    static func groupBy<T>(_ items: [T], _ heading: (T) -> String) -> [(heading: String, items: [T])] {
        var groups: [(heading: String, items: [T])] = []
        for item in items {
            let name = heading(item)
            if let last = groups.last, last.heading == name { groups[groups.count - 1].items.append(item) }
            else { groups.append((name, [item])) }
        }
        return groups
    }

    /// "4m", "3h", "2d", "5w", "4mo", "1y" ("now" under a minute; "" for no time).
    static func shortAge(_ seconds: Double?, now: Date = Date()) -> String {
        guard let seconds, seconds > 0 else { return "" }
        let elapsed = max(0, now.timeIntervalSince1970 - seconds)
        if elapsed < 60 { return "now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3600))h" }
        if elapsed < 86_400 * 14 { return "\(Int(elapsed / 86_400))d" }
        if elapsed < 86_400 * 60 { return "\(Int(elapsed / (86_400 * 7)))w" }
        if elapsed < 86_400 * 365 { return "\(Int(elapsed / (86_400 * 30)))mo" }
        return "\(Int(elapsed / (86_400 * 365)))y"
    }

    /// The task sheet's Running For, units spelled out: "Just started", "12 min", "3 hr", "2 days" ("" for no time).
    /// Rows keep `shortAge`.
    static func runningFor(_ seconds: Double?, now: Date = Date()) -> String {
        guard let seconds, seconds > 0 else { return "" }
        let elapsed = max(0, now.timeIntervalSince1970 - seconds)
        if elapsed < 60 { return "Just started" }
        if elapsed < 3600 { return "\(Int(elapsed / 60)) min" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3600)) hr" }
        let days = Int(elapsed / 86_400)
        return days == 1 ? "1 day" : "\(days) days"
    }

    /// "3h ago", "Just now", "".
    static func ago(_ seconds: Double?, now: Date = Date()) -> String {
        let age = shortAge(seconds, now: now)
        return age.isEmpty ? "" : age == "now" ? "Just now" : "\(age) ago"
    }

    static func blockReason(_ kind: String?) -> String {
        switch kind {
        case "needs_input": return "Needs your input"
        case "dependency": return "Waiting on another task"
        case "capability": return "Missing a tool or skill"
        case "transient": return "Will try again"
        default: return "Needs you"
        }
    }

    /// The step a person usually takes from a status (a row's leading swipe, the sheet's primary button).
    static func quickMove(_ status: String) -> (to: String, label: String)? {
        switch status {
        case "blocked": return ("ready", "Unblock")
        case "triage", "todo": return ("ready", "Mark Ready")
        case "done": return ("ready", "Reopen")
        default: return nil
        }
    }

    /// The card leaves its column and goes to the top of the target (an optimistic edit).
    static func moveCard(_ board: KanbanBoard, _ id: String, to: String, token: Int = 0) -> KanbanBoard {
        var moved: KanbanTask?
        var columns = board.columns.map { column -> KanbanColumn in
            KanbanColumn(name: column.name, tasks: column.tasks.filter { task in
                if task.id == id { var t = task; t.status = to; t.editToken = token; moved = t; return false }
                return true
            })
        }
        guard let moved else { return board }
        columns = columns.map { $0.name == to ? KanbanColumn(name: $0.name, tasks: [moved] + $0.tasks) : $0 }
        var out = board
        out.columns = columns
        return out
    }

    static func removeCard(_ board: KanbanBoard, _ id: String) -> KanbanBoard {
        var out = board
        out.columns = board.columns.map { KanbanColumn(name: $0.name, tasks: $0.tasks.filter { $0.id != id }) }
        return out
    }

    static func editCard(_ board: KanbanBoard, _ id: String, token: Int, _ edit: (inout KanbanTask) -> Void) -> KanbanBoard {
        var out = board
        out.columns = board.columns.map { column in
            KanbanColumn(name: column.name, tasks: column.tasks.map { task in
                guard task.id == id else { return task }
                var t = task; edit(&t); t.editToken = token; return t
            })
        }
        return out
    }

    private static func locate(_ board: KanbanBoard, _ id: String) -> (column: String, index: Int, task: KanbanTask)? {
        for column in board.columns {
            if let index = column.tasks.firstIndex(where: { $0.id == id }) { return (column.name, index, column.tasks[index]) }
        }
        return nil
    }

    /// R21: one failed optimistic write undone on its own task, only while the task is still what this write left.
    static func restoreTask(now: KanbanBoard, before: KanbanBoard, after: KanbanBoard, id: String) -> KanbanBoard {
        let mine = locate(after, id), current = locate(now, id)
        if mine?.task != current?.task || mine?.column != current?.column { return now }
        let was = locate(before, id)
        var out = now
        out.columns = now.columns.map { KanbanColumn(name: $0.name, tasks: $0.tasks.filter { $0.id != id }) }
        guard let was else { return out }
        out.columns = out.columns.map { column in
            guard column.name == was.column else { return column }
            var tasks = column.tasks
            tasks.insert(was.task, at: min(was.index, tasks.count))
            return KanbanColumn(name: column.name, tasks: tasks)
        }
        return out
    }

    /// A board's name as people read it: its own name, else its slug in words.
    static func boardTitle(slug: String, name: String?) -> String {
        if let name = name?.pgTrim, !name.isEmpty, name != slug { return name }
        if slug.isEmpty || slug == "default" { return "Default Board" }
        let upper: Set<String> = ["ai", "ha", "ui", "ux", "api", "ios", "qa", "seo", "crm", "kpi", "mvp"]
        return slug.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { part in
            let word = String(part)
            if upper.contains(word) { return word.uppercased() }
            if word == "saas" { return "SaaS" }
            return word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    // MARK: Activity words

    /// The plugin's wording for an event (`drawer.tsx` `eventText`).
    static func eventText(kind: String, payload: JSONValue) -> (label: String, detail: String?) {
        var p: [String: JSONValue] = [:]
        if case .string(let raw) = payload, !raw.isEmpty {
            guard let data = raw.data(using: .utf8), let parsed = try? JSONValue.parse(data), let object = parsed.object else {
                return (kind.replacingOccurrences(of: "_", with: " "), raw)
            }
            p = object
        } else if let object = payload.object {
            p = object
        }
        func str(_ key: String) -> String? { if let v = p[key]?.string, !v.isEmpty { return v }; return nil }
        func col(_ key: String) -> String? { str(key).map(label) }
        switch kind {
        case "created":
            let where_ = col("status") ?? "", assignee = str("assignee") ?? ""
            return ("created\(where_.isEmpty ? "" : " in \(where_)")\(assignee.isEmpty ? "" : " · assigned to \(assignee)")", nil)
        case "status":
            let reason = str("reason")
            return ("moved to \(col("status") ?? "?")", reason == "parent_reopened" ? "parent \(str("parent") ?? "") reopened" : reason)
        case "assigned":
            if let assignee = str("assignee") { return ("assigned to \(assignee)", nil) }
            return ("unassigned", nil)
        case "commented": return ("comment by \(str("author") ?? "someone")", nil)
        case "claimed": return (str("source_status") == "review" ? "claimed by a review agent" : "claimed by a worker", nil)
        case "spawned": return ("worker started", p["pid"].flatMap { $0.isNull ? nil : "pid \($0.pgString ?? "")" })
        case "completed": return ("completed", nil)
        case "blocked": return ("blocked — needs human input", str("reason"))
        case "unblocked":
            let c = col("status") ?? ""
            return ("unblocked\(c.isEmpty ? " → Ready" : " → \(c)")", nil)
        case "reclaimed": return ("reclaimed — returned to the queue", str("reason"))
        case "specified": return ("spec written by the triage agent", nil)
        case "promoted": return ("dependencies done — promoted to Ready", nil)
        case "scheduled": return ("scheduled for later", str("reason"))
        case "archived": return ("archived", nil)
        case "reprioritized": return ("priority set to \(p["priority"]?.pgString ?? "?")", nil)
        default:
            let detail = p.keys.sorted().compactMap { key -> String? in
                guard let value = p[key], !value.isNull, value.object == nil, value.array == nil else { return nil }
                return "\(key)=\(value.pgString ?? "")"
            }.joined(separator: " ")
            return (kind.replacingOccurrences(of: "_", with: " "), detail.isEmpty ? nil : detail)
        }
    }

    /// The bot's own words for the two lines the plugin leaves raw (`model.ts` `activityLine`).
    static func activityLine(kind: String, payload: JSONValue, line: (label: String, detail: String?),
                             botName: (String) -> String) -> (label: String, detail: String?) {
        var p: [String: JSONValue] = [:]
        if case .string(let raw) = payload, let data = raw.data(using: .utf8), let parsed = try? JSONValue.parse(data), let o = parsed.object { p = o }
        else if let o = payload.object { p = o }
        if kind == "heartbeat" {
            if let note = p["note"]?.string { return ("Progress update", note) }
            return ("Progress update", line.detail.map { RX.c(#"^note="#).replace($0, with: "", all: false) })
        }
        if kind == "commented", let author = p["author"]?.string {
            return ("Comment from \(author == "desktop" ? "you" : botName(author))", nil)
        }
        return line
    }

    /// "Running is set by the dispatcher…" — or a generic word for an unknown locked status.
    static func lockedReason(_ status: String) -> String { lockedReasons[status] ?? "\(label(status)) is set by the board." }

    /// A reclaim writes an administrative note into the summary slot (hidden).
    static func isAdminSummary(_ summary: String) -> Bool {
        RX.c(#"^status changed to \w+ \(dashboard/direct\)$"#).test(summary)
    }
}
