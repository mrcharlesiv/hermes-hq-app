// [tasks-first] The Tasks page's views (owner 2026-11-12: "every task is pure task management first, agent stuff
// second … something that a human can jump in and use on their own to manage everything in their life … THEN agent
// stuff built along side it so it feels more like you have a teammate in there"; mockups
// hermes-hq-share/2026-11-12-tasks-first, "I love all of this" / "Go").
//
// The page shows one view at a time, picked in a row of pills: Today, Upcoming, Inbox, each of your lists (the
// sections of 0.9.36, by a plainer name), and Bots. Tasks are ordered by when, never by what a bot did:
// - Today: Overdue, Today, then Waiting on You (a bot is stuck on you, on a task dated another day), then what you
//   finished today.
// - Upcoming: each coming day.
// - Inbox: no date and no list yet. A bot's ideas sit under them (the page adds those).
// - A list: its tasks in your order.
// - Bots: what each bot does by itself. A bot's own task stays out of your day unless it waits on you.
// Plain data and rules, tested in Tests/Pages/TodoViewsTests.

import Foundation

/// What the Tasks page shows.
nonisolated enum TodoView: Hashable, Sendable {
    case today, upcoming, inbox
    /// One of your lists (`TodoUserSection.id`).
    case list(String)
    case bots

    /// As kept on the device ("today", "list:<id>").
    var key: String {
        switch self {
        case .today: return "today"
        case .upcoming: return "upcoming"
        case .inbox: return "inbox"
        case .list(let id): return "list:" + id
        case .bots: return "bots"
        }
    }

    init?(key: String) {
        switch key {
        case "today": self = .today
        case "upcoming": self = .upcoming
        case "inbox": self = .inbox
        case "bots": self = .bots
        default:
            guard key.hasPrefix("list:"), key.count > 5 else { return nil }
            self = .list(String(key.dropFirst(5)))
        }
    }
}

/// A group of rows in a view, top to bottom.
nonisolated enum TodoGroupKind: Hashable, Sendable {
    case overdue, today
    /// Today: a bot finished its part or has a question, on a task not dated today.
    case waiting
    /// Upcoming: one day ("2026-11-13").
    case day(String)
    /// Inbox and a list: its open tasks (no heading).
    case open
    /// Inbox: a bot added it and nobody touched it for two weeks.
    case stale
    /// Bots: one bot's own tasks (its profile).
    case bot(String)
    case done
}

nonisolated struct TodoGroup: Sendable {
    var kind: TodoGroupKind
    var tasks: [TodoTask]
}

/// The dot on a bot's face: what it is doing on the task.
nonisolated enum TodoDot: String, Sendable { case working, ready, question }

/// A row's words: the name is the task's; these are what goes beside and under it.
nonisolated struct TodoRowWords: Hashable, Sendable {
    /// At the row's end: "5:00 PM", "Tomorrow", "Nov 10".
    var when: String?
    /// `when` in red: overdue, or due today in a view that isn't today's.
    var late = false
    /// "2/4" with steps.
    var steps: String?
    var repeats = false
    /// The second line, only when a bot has something for you (or, in Bots, what it is on).
    var note: String?
    var tone: TodoTone = .plain
    var dot: TodoDot?

    /// What VoiceOver hears after the title.
    var spoken: String {
        var parts: [String] = []
        if let when { parts.append(late ? "due \(when), late" : when) }
        if let steps { parts.append("\(steps.replacingOccurrences(of: "/", with: " of ")) steps") }
        if let note { parts.append(note) }
        else if dot == .working { parts.append("a bot is working on it") }
        return parts.joined(separator: ", ")
    }
}

nonisolated enum TodoViews {
    /// A bot finished its part, or has a question: the task waits on you.
    static func waitsOnYou(_ task: TodoTask) -> Bool { task.status == "ready" || task.status == "needs_you" }

    /// A task a bot does by itself.
    static func botsOwn(_ task: TodoTask) -> Bool { task.whoKind == .bot }

    /// It belongs in your day and your calendar: yours, one you share, or a bot's own once it waits on you.
    static func inYourDay(_ task: TodoTask) -> Bool { !botsOwn(task) || waitsOnYou(task) }

    /// "2026-11-13" for a day.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 1, parts.day ?? 1)
    }

    /// The task's list, when it is one that still exists.
    static func list(_ task: TodoTask, known: Set<String>) -> String? {
        task.section.flatMap { known.contains($0) ? $0 : nil }
    }

    /// The Bots pill shows once a bot has a task of its own (open or finished): nobody without one sees it.
    static func showsBots(_ tasks: [TodoTask]) -> Bool { tasks.contains(where: botsOwn) }

    /// The view's groups, top to bottom; empty ones are left out. `sort` orders a list's open tasks ("smart": your
    /// drag order, "due", "added"). `bots`: the roster's order, for the Bots view.
    static func groups(_ tasks: [TodoTask], view: TodoView, sections: [TodoUserSection] = [], bots: [String] = [],
                       now: Date, sort: String = "smart", calendar: Calendar = .current) -> [TodoGroup] {
        let today = calendar.startOfDay(for: now)
        let known = Set(sections.map(\.id))
        func dueDay(_ task: TodoTask) -> Date? { TodoDates.due(task.due, calendar: calendar).map { calendar.startOfDay(for: $0.date) } }
        func due(_ task: TodoTask) -> Date { TodoDates.due(task.due, calendar: calendar)?.date ?? .distantFuture }
        func created(_ task: TodoTask) -> Date { TodoDates.moment(task.createdAt) ?? .distantPast }
        func updated(_ task: TodoTask) -> Date { TodoDates.moment(task.updatedAt) ?? created(task) }
        func finished(_ task: TodoTask) -> Date { TodoDates.moment(task.doneAt) ?? updated(task) }
        func byDue(_ items: [TodoTask]) -> [TodoTask] {
            items.sorted { a, b in due(a) != due(b) ? due(a) < due(b) : (created(a), a.id) < (created(b), b.id) }
        }
        func newestDone(_ items: [TodoTask]) -> [TodoTask] { items.sorted { (finished($0), $0.id) > (finished($1), $1.id) } }
        var out: [TodoGroup] = []
        func add(_ kind: TodoGroupKind, _ items: [TodoTask]) { if !items.isEmpty { out.append(TodoGroup(kind: kind, tasks: items)) } }
        let open = tasks.filter { !$0.isDone }
        let done = tasks.filter(\.isDone)

        switch view {
        case .today:
            let mine = open.filter(inYourDay)
            let overdue = mine.filter { dueDay($0).map { $0 < today } ?? false }
            let todays = mine.filter { dueDay($0) == today }
            let dated = Set((overdue + todays).map(\.id))
            add(.overdue, byDue(overdue))
            add(.today, byDue(todays))
            // The newest news first.
            add(.waiting, mine.filter { waitsOnYou($0) && !dated.contains($0.id) }.sorted { (updated($0), $0.id) > (updated($1), $1.id) })
            add(.done, newestDone(done.filter { !botsOwn($0) && calendar.isDate(finished($0), inSameDayAs: now) }))
        case .upcoming:
            let coming = open.filter { task in inYourDay(task) && (dueDay(task).map { $0 > today } ?? false) }
            let days = Dictionary(grouping: coming) { dayKey(dueDay($0) ?? today, calendar: calendar) }
            for key in days.keys.sorted() { add(.day(key), byDue(days[key] ?? [])) }
        case .inbox:
            let loose = open.filter { !botsOwn($0) && $0.due == nil && list($0, known: known) == nil }
            add(.open, loose.filter { !TodoSections.isStale($0, now: now) }.sorted { (created($0), $0.id) > (created($1), $1.id) })
            add(.stale, loose.filter { TodoSections.isStale($0, now: now) }.sorted { (updated($0), $0.id) < (updated($1), $1.id) })
            add(.done, newestDone(done.filter { !botsOwn($0) && list($0, known: known) == nil }))
        case .list(let id):
            add(.open, TodoSections.ordered(open.filter { $0.section == id }, sort: sort, calendar: calendar))
            add(.done, newestDone(done.filter { $0.section == id }))
        case .bots:
            let theirs = open.filter(botsOwn)
            let byBot = Dictionary(grouping: theirs) { $0.helper ?? "default" }
            let order = bots.filter { byBot[$0] != nil } + byBot.keys.filter { !bots.contains($0) }.sorted()
            for bot in order {
                // At work first, then by due, then oldest first.
                add(.bot(bot), (byBot[bot] ?? []).sorted { a, b in
                    let wa = a.status == "working" ? 0 : 1, wb = b.status == "working" ? 0 : 1
                    if wa != wb { return wa < wb }
                    return due(a) != due(b) ? due(a) < due(b) : (created(a), a.id) < (created(b), b.id)
                })
            }
            add(.done, newestDone(done.filter(botsOwn)))
        }
        return out
    }

    /// The number on a view's pill: its open tasks.
    static func openCount(_ tasks: [TodoTask], view: TodoView, sections: [TodoUserSection] = [], now: Date,
                          calendar: Calendar = .current) -> Int {
        groups(tasks, view: view, sections: sections, now: now, calendar: calendar)
            .filter { $0.kind != .done }.reduce(0) { $0 + $1.tasks.count }
    }

    /// Upcoming with one day picked on its week strip (owner 2026-11-12: "the calendar dates aren't clickable"): that
    /// day's tasks alone. Today's are the ones due today (they aren't "coming up", so the whole view leaves them out).
    static func dayGroups(_ tasks: [TodoTask], day key: String, sections: [TodoUserSection], bots: [String], now: Date,
                          sort: String = "smart", calendar: Calendar = .current) -> [TodoGroup] {
        if key == dayKey(calendar.startOfDay(for: now), calendar: calendar) {
            return groups(tasks, view: .today, sections: sections, bots: bots, now: now, sort: sort, calendar: calendar)
                .filter { $0.kind == .today }
        }
        return groups(tasks, view: .upcoming, sections: sections, bots: bots, now: now, sort: sort, calendar: calendar)
            .filter { $0.kind == .day(key) }
    }

    /// A picked day with nothing on it: "Nothing due today.", "Nothing on Fri, Nov 13."
    static func dayEmptyText(_ key: String, now: Date, calendar: Calendar = .current) -> String {
        if key == dayKey(calendar.startOfDay(for: now), calendar: calendar) { return "Nothing due today." }
        let heading = dayHeading(key, now: now, calendar: calendar)
        return "Nothing on \(heading.detail ?? heading.title)."
    }

    /// The day a new task takes in a view: today on Today, none elsewhere.
    static func startsToday(_ view: TodoView) -> Bool { view == .today }

    // MARK: Words

    /// "Mon" for a day in the next six, else "Nov 16".
    static func soon(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let word = TodoWords.day(date, now: now, calendar: calendar)
        if word == "Today" || word == "Tomorrow" || word == "Yesterday" { return word }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 99
        guard (2...6).contains(days) else { return word }
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.locale = calendar.locale ?? .current
        format.setLocalizedDateFormatFromTemplate("EEE")
        return format.string(from: date)
    }

    /// A day group's heading in Upcoming: ("Tomorrow", "Fri, Nov 13") or ("Sat, Nov 14", nil).
    static func dayHeading(_ key: String, now: Date, calendar: Calendar = .current) -> (title: String, detail: String?) {
        guard let date = TodoDates.day(key, calendar: calendar) else { return (key, nil) }
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.locale = calendar.locale ?? .current
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        format.setLocalizedDateFormatFromTemplate(sameYear ? "EEEMMMd" : "EEEyMMMd")
        let full = format.string(from: date)
        let word = TodoWords.day(date, now: now, calendar: calendar)
        return word == "Tomorrow" ? (word, full) : (full, nil)
    }

    /// A row's words in a group.
    static func row(_ task: TodoTask, in kind: TodoGroupKind, now: Date, calendar: Calendar = .current,
                    botName: (String?) -> String) -> TodoRowWords {
        var words = TodoRowWords()
        if !task.steps.isEmpty { words.steps = "\(task.steps.filter(\.done).count)/\(task.steps.count)" }
        words.repeats = task.repeatRule != nil
        let name = botName(task.helper)
        let note = task.statusNote.trimmingCharacters(in: .whitespacesAndNewlines)

        if task.isDone {
            words.when = TodoDates.moment(task.doneAt).map { TodoWords.day($0, now: now, calendar: calendar) }
            return words
        }
        if let due = TodoDates.due(task.due, calendar: calendar) {
            let time = due.hasTime ? TodoWords.clock(due.date, calendar: calendar) : nil
            let today = calendar.startOfDay(for: now), day = calendar.startOfDay(for: due.date)
            switch kind {
            case .today, .day:
                words.when = time            // the heading says the day
            case .overdue:
                words.when = TodoWords.day(due.date, now: now, calendar: calendar)
                words.late = true
            default:
                words.when = day == today ? (time ?? "Today") : soon(due.date, now: now, calendar: calendar)
                words.late = day <= today
            }
        }
        if task.helper != nil {
            switch task.status {
            case "working": words.dot = .working
            case "ready": words.dot = .ready
            case "needs_you": words.dot = .question
            default: break
            }
        }
        switch task.status {
        case "ready":
            words.note = note.isEmpty ? "\(name) finished its part" : "\(name): \(note)"
            words.tone = .ready
        case "needs_you":
            if note.isEmpty { words.note = "\(name) needs you" }
            else { words.note = note.hasSuffix("?") ? "\(name) asks: \(note)" : "\(name) needs you: \(note)" }
            words.tone = .needsYou
        default:
            if kind == .stale {
                let when = TodoDates.moment(task.createdAt).map { TodoWords.day($0, now: now, calendar: calendar) }
                words.note = (["Added by \(botName(task.createdBy))"] + [when].compactMap { $0 }).joined(separator: " · ")
            } else if case .bot = kind, task.status == "working", !note.isEmpty {
                words.note = note            // Bots: what it is on
            }
        }
        return words
    }

    /// A group's heading; nil for one with none (a list's and Inbox's open tasks).
    static func heading(_ kind: TodoGroupKind, now: Date, calendar: Calendar = .current, botName: (String?) -> String)
        -> (title: String, detail: String?)? {
        switch kind {
        case .overdue: return ("Overdue", nil)
        case .today: return ("Today", nil)
        case .waiting: return ("Waiting on You", nil)
        case .day(let key): return dayHeading(key, now: now, calendar: calendar)
        case .open: return nil
        case .stale: return (TodoSection.stale.rawValue, nil)
        case .bot(let profile): return (botName(profile), nil)
        case .done: return ("Done", nil)
        }
    }

    // MARK: The task's page ([tasks-first] step 2: a task is a task; a bot is added to it like a co-worker)

    /// The task has a bot on it: its page carries the bot's conversation. A task of your own has none.
    static func hasTeammate(_ task: TodoTask) -> Bool { task.helper != nil }

    /// The who row's words: "Me", "Me & Hermes", "Finance".
    static func who(_ task: TodoTask, botName: (String?) -> String) -> String {
        switch task.whoKind {
        case .me: return "Me"
        case .together: return "Me & \(botName(task.helper))"
        case .bot: return botName(task.helper)
        }
    }

    /// What the task's bot is doing, at the who row's end: "Working", "Has a question", "Finished its part". Nil for a
    /// task of your own, one that is done, and a bot that hasn't started. `running`: its turn is on in the task's chat.
    static func botState(_ task: TodoTask, running: Bool = false) -> (words: String, tone: TodoTone)? {
        guard task.helper != nil, !task.isDone else { return nil }
        if running { return ("Working", .working) }
        switch task.status {
        case "working": return ("Working", .working)
        case "needs_you": return ("Has a question", .needsYou)
        case "ready": return ("Finished its part", .ready)
        default: return nil
        }
    }

    /// The bot waits on an answer from you: its card stands right under the who row, with its answers as taps.
    /// Everything else it says stays in its section at the page's foot.
    static func asksYou(_ task: TodoTask) -> Bool {
        guard task.helper != nil, !task.isDone else { return false }
        return task.status == "needs_you" || (task.status == "ready" && !task.choices.isEmpty)
    }

    /// The bar's words on a task's page: the list it is in, else "No List"; plain "Task" for someone with no lists
    /// (nothing to say, and nowhere to move it).
    static func listTitle(_ task: TodoTask, sections: [TodoUserSection]) -> String {
        guard !sections.isEmpty else { return "Task" }
        return task.section.flatMap { id in sections.first { $0.id == id }?.name } ?? "No List"
    }

    /// What a view says with nothing in it.
    static func emptyText(_ view: TodoView, listName: String?) -> String {
        switch view {
        case .today: return "Nothing due today."
        case .upcoming: return "Nothing coming up. A task with a date shows here."
        case .inbox: return "Nothing waiting to be sorted. A task with no date and no list lands here."
        case .list: return "No tasks in \(listName ?? "this list") yet."
        case .bots: return "No bot has a task of its own right now."
        }
    }
}

/// [tasks-first] The scheduled jobs the Hermes HQ add-on keeps to run Tasks: "Task prep" (a bot works through its
/// tasks), "Task check" (one run when a watched task's check is due) and "Task ideas" (the daily look). Owner
/// 2026-11-12: they showed among your own jobs ("Task ideas" and "Task check" among 53). They are told by their name
/// and the add-on's own instruction, so a job of yours that happens to be called "Task check" still shows.
nonisolated enum TodoRunnerJobs {
    static let names: Set<String> = ["Task prep", "Task check", "Task ideas"]
    static let openings = ["Work through Tasks prep.", "Find task ideas for the user."]

    static func isOne(_ job: CronJob) -> Bool {
        guard let name = job.name?.trimmingCharacters(in: .whitespaces), names.contains(name) else { return false }
        let prompt = (job.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return openings.contains { prompt.hasPrefix($0) }
    }
}
