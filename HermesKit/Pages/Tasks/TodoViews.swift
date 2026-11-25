// [tasks-first] The Tasks page's views (owner 2026-11-12: "every task is pure task management first, agent stuff
// second … something that a human can jump in and use on their own to manage everything in their life … THEN agent
// stuff built along side it so it feels more like you have a teammate in there"; mockups
// hermes-hq-share/2026-11-12-tasks-first, "I love all of this" / "Go").
//
// The page shows one view at a time, picked in a row of pills: Today, Upcoming, Inbox, each of your lists (the
// sections of 0.9.36, by a plainer name), and Bots. Tasks are ordered by when, never by what a bot did:
// - Today: Overdue, Today, then Waiting on You (a bot is stuck on you, on a task dated another day), then the next
//   three of each list in your order ([task-lists], owner 2026-11-14: 3 of 13 open tasks had a date, so Today
//   opened on three rows), then what you finished today.
// - Upcoming: each coming day.
// - Inbox: every task in no list, dated or not ([task-lists]: it is what is left to file; a dated task in no list
//   used to show nowhere but its day). A bot's ideas sit under them (the page adds those).
// - A list: its tasks in your order.
// - Bots: what each bot does by itself. A bot's own task stays out of your day unless it waits on you.
// Plain data and rules, tested in Tests/Pages/TodoViewsTests.

import Foundation

/// What the Tasks page shows.
nonisolated enum TodoView: Hashable, Sendable {
    case today, upcoming, inbox
    /// [goals] Your goals (docs/goals.md): the first pill, when the add-on keeps goals. It shows cards, not tasks.
    case goals
    /// One of your lists (`TodoUserSection.id`).
    case list(String)
    /// [task-ideas] Suggested tasks from your bots (dedicated view, plus inline preview on iPhone Overview).
    case suggested
    case bots

    /// As kept on the device ("today", "list:<id>").
    var key: String {
        switch self {
        case .today: return "today"
        case .upcoming: return "upcoming"
        case .inbox: return "inbox"
        case .goals: return "goals"
        case .list(let id): return "list:" + id
        case .suggested: return "suggested"
        case .bots: return "bots"
        }
    }

    init?(key: String) {
        switch key {
        case "today": self = .today
        case "upcoming": self = .upcoming
        case "inbox": self = .inbox
        case "goals": self = .goals
        case "suggested": self = .suggested
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
    /// [task-lists] Today: the next few open tasks of one list (its id), in your order, with no date made up.
    case next(String)
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
    /// [task-lists] `.next`: how many more open tasks the list has ("4 more in Work ›").
    var more = 0
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
    /// 0 none, 1 high, 2 medium, 3 low: the mark before the name (`TodoViews.priorityMark`).
    var priority = 0
    /// Its tags, where the row has the room for them (a list, Inbox).
    var tags: [String] = []
    /// The second line, only when a bot has something for you (or, in Bots, what it is on).
    var note: String?
    var tone: TodoTone = .plain
    var dot: TodoDot?
    /// [tasks-calm] The second line as the iPhone's row draws it, after the bot's small face (owner 2026-11-19, pick A
    /// of hermes-hq/workspace/mockups/tasks-calm: "Quiet ink"): `note` without the bot's name, since the face says it,
    /// and a line for every task a bot is on ("Working on it", "Not started yet"), so its face has one place.
    var said: String?

    /// What VoiceOver hears after the title.
    var spoken: String {
        var parts: [String] = []
        if priority > 0 { parts.append("\(TodoViews.priorityWord(priority)) priority") }
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

    /// [task-lists] How many of a list's open tasks Today shows under the dated ones.
    static let nextCount = 3

    /// The view's groups, top to bottom; empty ones are left out. `sort` orders a list's open tasks ("smart": your
    /// drag order, "due", "added"). `bots`: the roster's order, for the Bots view.
    /// [goals] `paused`: paused goals' ids; their tasks stay out of Today's "Next in <List>" groups (a dated one
    /// still shows on its day).
    static func groups(_ tasks: [TodoTask], view: TodoView, sections: [TodoUserSection] = [], bots: [String] = [],
                       now: Date, sort: String = "smart", paused: Set<String> = [], calendar: Calendar = .current) -> [TodoGroup] {
        let today = calendar.startOfDay(for: now)
        let known = Set(sections.map(\.id))
        func dueDay(_ task: TodoTask) -> Date? { TodoDates.due(task.due, calendar: calendar).map { calendar.startOfDay(for: $0.date) } }
        // [tasks-first] A start day (0.9.53): until then the task waits under Upcoming on that day; from then on it
        // is in your day, under Today, until it is due (then by its due date as any task).
        func startDay(_ task: TodoTask) -> Date? { task.starts.flatMap { TodoDates.day(String($0.prefix(10)), calendar: calendar) } }
        func waits(_ task: TodoTask) -> Bool { startDay(task).map { $0 > today } ?? false }
        func started(_ task: TodoTask) -> Bool { startDay(task).map { $0 <= today } ?? false }
        func due(_ task: TodoTask) -> Date { TodoDates.due(task.due, calendar: calendar)?.date ?? .distantFuture }
        func created(_ task: TodoTask) -> Date { TodoDates.moment(task.createdAt) ?? .distantPast }
        func updated(_ task: TodoTask) -> Date { TodoDates.moment(task.updatedAt) ?? created(task) }
        func finished(_ task: TodoTask) -> Date { TodoDates.moment(task.doneAt) ?? updated(task) }
        func byDue(_ items: [TodoTask]) -> [TodoTask] {
            items.sorted { a, b in due(a) != due(b) ? due(a) < due(b) : (created(a), a.id) < (created(b), b.id) }
        }
        func priorityRank(_ task: TodoTask) -> Int { task.priority == 0 ? 4 : task.priority }
        func byToday(_ items: [TodoTask]) -> [TodoTask] {
            switch sort {
            case "due":
                return items.sorted { a, b in due(a) != due(b) ? due(a) < due(b) : (a.order, a.id) < (b.order, b.id) }
            case "priority":
                return items.sorted { a, b in priorityRank(a) != priorityRank(b) ? priorityRank(a) < priorityRank(b) : (a.order, a.id) < (b.order, b.id) }
            case "added":
                return items.sorted { (created($0), $0.id) > (created($1), $1.id) }
            default:
                // Default Today order: High/Medium priority rises to the top; ties break by due time, then manual order / created.
                return items.sorted { a, b in
                    let pa = priorityRank(a), pb = priorityRank(b)
                    if pa != pb { return pa < pb }
                    if due(a) != due(b) { return due(a) < due(b) }
                    return (a.order, a.id) < (b.order, b.id)
                }
            }
        }
        func newestDone(_ items: [TodoTask]) -> [TodoTask] { items.sorted { (finished($0), $0.id) > (finished($1), $1.id) } }
        var out: [TodoGroup] = []
        func add(_ kind: TodoGroupKind, _ items: [TodoTask]) { if !items.isEmpty { out.append(TodoGroup(kind: kind, tasks: items)) } }
        let open = tasks.filter { !$0.isDone }
        let done = tasks.filter(\.isDone)

        switch view {
        case .today:
            let mine = open.filter(inYourDay)
            let overdue = mine.filter { !waits($0) && (dueDay($0).map { $0 < today } ?? false) }
            let todays = mine.filter { task in
                guard !waits(task) else { return false }
                if dueDay(task) == today { return true }
                return started(task) && (dueDay(task).map { $0 > today } ?? true)   // it has started and isn't due yet
            }
            let dated = Set((overdue + todays).map(\.id))
            add(.overdue, byDue(overdue))
            add(.today, byToday(todays))
            // The newest news first.
            let waiting = mine.filter { waitsOnYou($0) && !dated.contains($0.id) }.sorted { (updated($0), $0.id) > (updated($1), $1.id) }
            add(.waiting, waiting)
            // [task-lists] What's next in each list, in your order: nothing shown twice, nothing that waits for its
            // start day or sits under Upcoming, and never a bot's own work.
            let shown = dated.union(waiting.map(\.id))
            for section in sections where section.inToday {
                let rest = TodoSections.ordered(mine.filter { task in
                    task.section == section.id && !botsOwn(task) && !shown.contains(task.id) && !waits(task)
                        && (dueDay(task).map { $0 <= today } ?? true) && !(task.goal.map(paused.contains) ?? false)
                }, sort: "smart", calendar: calendar)
                guard !rest.isEmpty else { continue }
                out.append(TodoGroup(kind: .next(section.id), tasks: Array(rest.prefix(nextCount)),
                                     more: max(0, rest.count - nextCount)))
            }
            add(.done, newestDone(done.filter { !botsOwn($0) && calendar.isDate(finished($0), inSameDayAs: now) }))
        case .upcoming:
            // Its day: the day it starts while that is still ahead, else the day it's due (one that has started and
            // isn't due yet is in Today).
            func day(_ task: TodoTask) -> Date? {
                if waits(task) { return startDay(task) }
                if started(task) { return nil }
                return dueDay(task).flatMap { $0 > today ? $0 : nil }
            }
            let coming = open.filter { inYourDay($0) && day($0) != nil }
            let days = Dictionary(grouping: coming) { dayKey(day($0) ?? today, calendar: calendar) }
            for key in days.keys.sorted() { add(.day(key), byDue(days[key] ?? [])) }
        case .inbox:
            // [task-lists] Dated or not: Inbox is what hasn't been filed.
            let loose = open.filter { !botsOwn($0) && list($0, known: known) == nil }
            let fresh = loose.filter { !TodoSections.isStale($0, now: now) }
            let orderedFresh = sort == "smart"
                ? fresh.sorted { (created($0), $0.id) > (created($1), $1.id) }
                : TodoSections.ordered(fresh, sort: sort, calendar: calendar)
            add(.open, orderedFresh)
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
        case .goals, .suggested:
            break   // Goals draws goal cards (GoalViews); Suggested draws task ideas (TaskIdeasViews)
        }
        return out
    }

    /// The number on a view's pill: its open tasks. Today's counts what is dated or waits on you; the lists' next
    /// tasks under them are counted on their own pills.
    static func openCount(_ tasks: [TodoTask], view: TodoView, sections: [TodoUserSection] = [], now: Date,
                          calendar: Calendar = .current) -> Int {
        groups(tasks, view: view, sections: sections, now: now, calendar: calendar)
            .filter { group in
                if case .next = group.kind { return false }
                return group.kind != .done
            }.reduce(0) { $0 + $1.tasks.count }
    }

    /// [task-lists] Today's Done group folds to one line: "Done today · 4".
    static func doneLine(_ count: Int) -> String { "Done today · \(count)" }

    /// [task-lists] Under a list's next tasks in Today: "4 more in Work".
    static func moreLine(_ more: Int, list: String) -> String { "\(more) more in \(list)" }

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
        return TodoDates.format(date, template: "EEE", calendar: calendar)
    }

    /// A day group's heading in Upcoming: ("Tomorrow", "Fri, Nov 13") or ("Sat, Nov 14", nil).
    static func dayHeading(_ key: String, now: Date, calendar: Calendar = .current) -> (title: String, detail: String?) {
        guard let date = TodoDates.day(key, calendar: calendar) else { return (key, nil) }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let full = TodoDates.format(date, template: sameYear ? "EEEMMMd" : "EEEyMMMd", calendar: calendar)
        let word = TodoWords.day(date, now: now, calendar: calendar)
        return word == "Tomorrow" ? (word, full) : (full, nil)
    }

    /// A row's words in a group.
    static func row(_ task: TodoTask, in kind: TodoGroupKind, now: Date, calendar: Calendar = .current,
                    botName: (String?) -> String) -> TodoRowWords {
        var words = TodoRowWords()
        words.priority = task.isDone ? 0 : task.priority
        // Tags where a row has no date heading over it and room to spare: a list and Inbox.
        if kind == .open, !task.isDone { words.tags = Array(task.tags.prefix(2)) }
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
            case .today where day > today:
                // Started, due later: when it's due.
                words.when = soon(due.date, now: now, calendar: calendar)
            case .day(let key) where key != dayKey(day, calendar: calendar):
                // Under the day it starts: when it's due.
                words.when = "Due " + soon(due.date, now: now, calendar: calendar)
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
            if let offer = TodoLists.closeOffer(task), kind != .stale {
                // [task-lists] A bot thinks it is settled: said in words under the name, with Mark Done on the task.
                words.note = TodoLists.closeLine(offer, botName: botName)
                words.tone = .ready
            } else if kind == .stale {
                let when = TodoDates.moment(task.createdAt).map { TodoWords.day($0, now: now, calendar: calendar) }
                words.note = (["Added by \(botName(task.createdBy))"] + [when].compactMap { $0 }).joined(separator: " · ")
            } else if case .bot = kind, task.status == "working", !note.isEmpty {
                words.note = note            // Bots: what it is on
            }
        }
        words.said = said(task, words: words, note: note, name: name)
        return words
    }

    /// [tasks-calm] `note` as it reads beside the face of the task's bot: its name left off (the face says it), and a
    /// quiet line while it works or hasn't started. A line by someone else (another bot's "looks done", Still Need
    /// These?'s "Added by …") keeps its words whole.
    private static func said(_ task: TodoTask, words: TodoRowWords, note: String, name: String) -> String? {
        guard task.helper != nil else { return words.note }
        switch task.status {
        case "ready": return note.isEmpty ? "Finished its part" : note
        case "needs_you": return note.isEmpty ? "Needs you" : note
        default: break
        }
        if let line = words.note {
            let own = "\(name): "
            return line.hasPrefix(own) ? String(line.dropFirst(own.count)) : line
        }
        return task.status == "working" ? "Working on it" : "Not started yet"
    }

    /// A group's heading; nil for one with none (a list's and Inbox's open tasks).
    static func heading(_ kind: TodoGroupKind, now: Date, calendar: Calendar = .current, sections: [TodoUserSection] = [],
                        botName: (String?) -> String) -> (title: String, detail: String?)? {
        switch kind {
        case .next(let id): return ("Next in \(sections.first { $0.id == id }?.name ?? "List")", nil)
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

    /// [tasks-colour] The mark before a row's name: "!!" for high, "!" for medium, none for low or no priority (the
    /// list's order and VoiceOver still say low). Ink, not a colour: on the list a colour means late or asked.
    static func priorityMark(_ priority: Int) -> String? {
        switch priority {
        case 1: return "!!"
        case 2: return "!"
        default: return nil
        }
    }

    /// "High", "Medium", "Low"; "None" for 0.
    static func priorityWord(_ priority: Int) -> String {
        switch priority {
        case 1: return "High"
        case 2: return "Medium"
        case 3: return "Low"
        default: return "None"
        }
    }

    /// "Starts tomorrow", "Starts Mon", "Started Nov 3": a task's start day in words.
    static func startWords(_ task: TodoTask, now: Date, calendar: Calendar = .current) -> String? {
        guard let raw = task.starts, let day = TodoDates.day(String(raw.prefix(10)), calendar: calendar) else { return nil }
        let word = soon(day, now: now, calendar: calendar)
        let lower = word == "Today" || word == "Tomorrow" || word == "Yesterday" ? word.lowercased() : word
        return (day > calendar.startOfDay(for: now) ? "Starts " : (calendar.isDate(day, inSameDayAs: now) ? "Starts " : "Started ")) + lower
    }

    /// Tags as typed in one field ("hiring, q4"): split at commas, a leading # dropped, each once, ten at most.
    static func tags(from text: String) -> [String] {
        var out: [String] = [], seen = Set<String>()
        for part in text.split(whereSeparator: { $0 == "," || $0.isNewline }) {
            var tag = part.trimmingCharacters(in: .whitespaces)
            while tag.hasPrefix("#") { tag.removeFirst() }
            tag = String(tag.trimmingCharacters(in: .whitespaces).prefix(30))
            if !tag.isEmpty, seen.insert(tag.lowercased()).inserted { out.append(tag) }
        }
        return Array(out.prefix(10))
    }

    // MARK: The task's page ([tasks-first] step 2: a task is a task; a bot is added to it like a co-worker)

    /// The task has a bot on it: its page carries the bot's conversation. A task of your own has none.
    static func hasTeammate(_ task: TodoTask) -> Bool { task.helper != nil }

    /// The who row's words: "You", "You & Hermes", "Finance" ([Mac UI check 2026-11-13] as the list and the Task Page
    /// say it; the pane said "Me").
    static func who(_ task: TodoTask, botName: (String?) -> String) -> String {
        switch task.whoKind {
        case .me: return "You"
        case .together: return "You & \(botName(task.helper))"
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
        case .inbox: return "Nothing left to file. A task in no list lands here."
        case .list: return "No tasks in \(listName ?? "this list") yet."
        case .suggested: return "No suggested tasks right now."
        case .bots: return "No bot has a task of its own right now."
        case .goals: return GoalViews.emptyText
        }
    }

    // MARK: Tags, Upcoming week header, Drag-to-day & Completed Logbook

    /// Every tag in use across `tasks`, most frequent first, then alphabetical (case-insensitive deduplication).
    static func allTags(in tasks: [TodoTask]) -> [String] {
        var counts: [String: Int] = [:]
        var canonical: [String: String] = [:]
        for task in tasks {
            for raw in task.tags {
                let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { continue }
                let key = clean.lowercased()
                counts[key, default: 0] += 1
                if canonical[key] == nil { canonical[key] = clean }
            }
        }
        return counts.keys.sorted { a, b in
            let ca = counts[a] ?? 0, cb = counts[b] ?? 0
            if ca != cb { return ca > cb }
            return (canonical[a] ?? a).localizedCaseInsensitiveCompare(canonical[b] ?? b) == .orderedAscending
        }.compactMap { canonical[$0] }
    }

    /// Heading over Upcoming's week strip: "November 2026", or "Nov – Dec 2026" when the 7 days span two months.
    static func weekRangeTitle(_ dates: [Date], calendar: Calendar = .current) -> String {
        guard let first = dates.first, let last = dates.last else { return "" }
        let m1 = calendar.component(.month, from: first), y1 = calendar.component(.year, from: first)
        let m2 = calendar.component(.month, from: last), y2 = calendar.component(.year, from: last)
        if m1 == m2 && y1 == y2 { return TodoDates.format(first, template: "yMMMM", calendar: calendar) }
        if y1 == y2 {
            return "\(TodoDates.format(first, template: "MMM", calendar: calendar)) – \(TodoDates.format(last, template: "yMMM", calendar: calendar))"
        }
        return "\(TodoDates.format(first, template: "yMMM", calendar: calendar)) – \(TodoDates.format(last, template: "yMMM", calendar: calendar))"
    }

    /// Wire due string when rescheduling `task` onto `day`, keeping its clock time if it already had one.
    static func rescheduledDue(for task: TodoTask, onto day: Date, preserveTime: Bool = true,
                               calendar: Calendar = .current) -> String {
        if preserveTime, let existing = TodoDates.due(task.due, calendar: calendar), existing.hasTime {
            let clock = calendar.dateComponents([.hour, .minute], from: existing.date)
            var parts = calendar.dateComponents([.year, .month, .day], from: day)
            parts.hour = clock.hour
            parts.minute = clock.minute
            if let combined = calendar.date(from: parts) {
                return TodoDates.wire(combined, hasTime: true, calendar: calendar)
            }
        }
        return TodoDates.wire(day, hasTime: false, calendar: calendar)
    }

    /// Unified Completed Logbook groups: Today, Yesterday, This Week, Earlier This Month, then month headings.
    static func logbook(_ tasks: [TodoTask], query: String = "", now: Date = Date(),
                        calendar: Calendar = .current) -> [TodoLogbookGroup] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let done = tasks.filter { task in
            guard task.isDone else { return false }
            guard !words.isEmpty else { return true }
            let fields = [task.title, task.notes, task.statusNote] + task.steps.map(\.title) + task.tags
            return fields.contains { $0.lowercased().contains(words) }
        }
        func finished(_ task: TodoTask) -> Date {
            TodoDates.moment(task.doneAt) ?? TodoDates.moment(task.updatedAt) ?? TodoDates.moment(task.createdAt) ?? .distantPast
        }
        let sorted = done.sorted { (finished($0), $0.id) > (finished($1), $1.id) }
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let weekAgo = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let thisMonth = calendar.dateComponents([.year, .month], from: today)

        var order: [String] = []
        var titles: [String: String] = [:]
        var buckets: [String: [TodoTask]] = [:]
        for task in sorted {
            let at = finished(task)
            let day = calendar.startOfDay(for: at)
            let key: String
            let title: String
            if day >= today {
                key = "today"; title = "Today"
            } else if day >= yesterday {
                key = "yesterday"; title = "Yesterday"
            } else if day >= weekAgo {
                key = "week"; title = "This Week"
            } else if calendar.dateComponents([.year, .month], from: day) == thisMonth {
                key = "month"; title = "Earlier This Month"
            } else if at == .distantPast {
                key = "earlier"; title = "Earlier"
            } else {
                let parts = calendar.dateComponents([.year, .month], from: day)
                key = String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 1)
                title = TodoDates.format(day, template: "yMMMM", calendar: calendar)
            }
            if buckets[key] == nil { order.append(key); titles[key] = title }
            buckets[key, default: []].append(task)
        }
        return order.compactMap { key in
            guard let items = buckets[key], !items.isEmpty else { return nil }
            return TodoLogbookGroup(id: key, title: titles[key] ?? key, tasks: items)
        }
    }
}

/// One time bucket in the Completed Logbook.
nonisolated struct TodoLogbookGroup: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var tasks: [TodoTask]
}

/// [tasks-first] The scheduled jobs the Hermes HQ add-on keeps to run Tasks: "Task prep" (a bot works through its
/// tasks), "Task check" (one run when a watched task's check is due) and "Task ideas" (the daily look). Owner
/// 2026-11-12: they showed among your own jobs ("Task ideas" and "Task check" among 53). They are told by their name
/// and the add-on's own instruction, so a job of yours that happens to be called "Task check" still shows.
/// Where a job of yours already holds one of the names, the add-on (from 0.9.56) leaves it alone and names its own
/// with `taken` after it ("Task check (Hermes HQ)"): that one is the add-on's too.
nonisolated enum TodoRunnerJobs {
    /// [goals step 4] "Goal check-in" (hermes-hq-push 0.9.66): one per bot that leads a goal with a check-in.
    static let names: Set<String> = ["Task prep", "Task check", "Task ideas", "Goal check-in"]
    static let taken = " (Hermes HQ)"
    static let openings = ["Work through Tasks prep.", "Find task ideas for the user.", "Run your goals' weekly check-in."]

    static func isOne(_ job: CronJob) -> Bool {
        guard var name = job.name?.trimmingCharacters(in: .whitespaces) else { return false }
        if name.hasSuffix(taken) { name.removeLast(taken.count) }
        guard names.contains(name) else { return false }
        let prompt = (job.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return openings.contains { prompt.hasPrefix($0) }
    }
}
