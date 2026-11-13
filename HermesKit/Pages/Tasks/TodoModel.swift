// [tasks] The shared task list (docs/tasks.md): you and your bots. The hermes-hq-push add-on (0.9.32+, `tasks.py`)
// stores it and serves `/api/plugins/hermes-hq-push/tasks`; the app draws it. Named Todo* in code so they never meet
// Swift's `Task`, Hermes's Kanban tasks or the activity shelf's `todo` tool.
// Everything here is plain data and rules (sections, row words, the 409 merge), tested in Tests/Pages/TasksTests.

import Foundation
import Synchronization

/// One task, as the routes send it. Decoding is lenient: a missing field takes its empty value, so an add-on that adds
/// fields later (or sends fewer) never empties the list.
nonisolated struct TodoTask: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var rev: Int
    var title: String
    var notes: String
    /// "me" | "bot" | "together".
    var who: String
    /// A profile name ("default" is the root bot); nil for a `me` task.
    var bot: String?
    /// "open" | "working" | "ready" | "needs_you" | "done".
    var status: String
    var statusNote: String
    /// "2026-11-05" (a day) or "2026-11-05T17:00:00-06:00" (a time).
    var due: String?
    /// nil | "daily" | "weekdays" | "weekly" | "monthly" | "yearly" (`me` tasks only).
    var repeatRule: String?
    var prep: Bool
    var steps: [TodoStep]
    var made: [TodoMade]
    var source: TodoSource?
    var createdAt: String?
    var updatedAt: String?
    var doneAt: String?
    /// "you" or a profile.
    var createdBy: String?
    /// Newest last, at most 50.
    var log: [TodoLogEntry]
    /// One of your own sections (`TodoUserSection.id`), or nil (hermes-hq-push 0.9.36).
    var section: String?
    /// Its place in its section, smallest first: when it was added (seconds) until you drag it. 0 from an older add-on.
    var position: Double
    /// What its bot is watching for, and where ("a reply from Ivy, by email"); empty when nothing (hermes-hq-push 0.9.37).
    var watch: String
    /// The task's own chat: the hidden session its page opened (hermes-hq-push 0.9.37). Owner 2026-11-04: "a session
    /// tied to every task … it lived inside the task".
    var chat: TodoChat?
    /// The gateway sent `chat` (an add-on that keeps it, 0.9.37+): its answer stands, even "none yet".
    var chatKnown = false
    /// When its bot last wrote on its Task Page (hermes-hq-push 0.9.38); nil before it has.
    var pageAt: String?
    /// [tasks] Where it stands and what's next, as its bot wrote them on its Task Page (hermes-hq-push 0.9.43); nil from
    /// an older add-on or before the bot wrote any. The brief leads with them.
    var page: TodoPageGist?
    /// [tasks] When its bot looks at it again by itself, as it said it would (hermes-hq-push 0.9.47): a due-style time,
    /// nil when none. Owner 2026-11-09: "no friction, it just works" — a promise in a sentence became a real run.
    var nextCheck: String?
    /// [tasks] Up to three answers the bot offers with its question, each a tap (hermes-hq-push 0.9.47).
    var choices: [String] = []
    /// [tasks-first] What a task manager's task has (hermes-hq-push 0.9.53; owner 2026-11-12: "complex enough to
    /// handle any task or use case"). 0 none, 1 high, 2 medium, 3 low.
    var priority = 0
    var tags: [String] = []
    /// Minutes before it's due that the phone rings (0: at that time); nil: at its due time, as before.
    var alert: Int?
    /// The day it joins your day ("2026-11-20"); nil: by its due date alone.
    var starts: String?

    enum CodingKeys: String, CodingKey {
        case id, rev, title, notes, who, bot, status, due, prep, steps, made, source, log, section, position, watch, chat
        case statusNote = "status_note", repeatRule = "repeat", createdAt = "created_at", updatedAt = "updated_at"
        case doneAt = "done_at", createdBy = "created_by", pageAt = "page_at", page, nextCheck = "next_check", choices
        case priority, tags, alert, starts
        // App-only: kept in the disk cache and edit merges so a reopened list still knows the gateway said "no chat".
        case chatKnown = "chat_known"
    }

    init(id: String, rev: Int = 0, title: String, notes: String = "", who: String = "me", bot: String? = nil,
         status: String = "open", statusNote: String = "", due: String? = nil, repeatRule: String? = nil, prep: Bool = false,
         steps: [TodoStep] = [], made: [TodoMade] = [], source: TodoSource? = nil, createdAt: String? = nil,
         updatedAt: String? = nil, doneAt: String? = nil, createdBy: String? = nil, log: [TodoLogEntry] = [],
         section: String? = nil, position: Double = 0, watch: String = "", chat: TodoChat? = nil) {
        self.id = id; self.rev = rev; self.title = title; self.notes = notes; self.who = who; self.bot = bot
        self.status = status; self.statusNote = statusNote; self.due = due; self.repeatRule = repeatRule; self.prep = prep
        self.steps = steps; self.made = made; self.source = source; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.doneAt = doneAt; self.createdBy = createdBy; self.log = log
        self.section = section; self.position = position; self.watch = watch; self.chat = chat
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        rev = (try? c.decodeIfPresent(Int.self, forKey: .rev)) ?? 0
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? ""
        who = (try? c.decodeIfPresent(String.self, forKey: .who)) ?? "me"
        bot = (try? c.decodeIfPresent(String.self, forKey: .bot)).flatMap { $0?.isEmpty == true ? nil : $0 }
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "open"
        statusNote = (try? c.decodeIfPresent(String.self, forKey: .statusNote)) ?? ""
        due = (try? c.decodeIfPresent(String.self, forKey: .due)).flatMap { $0?.isEmpty == true ? nil : $0 }
        repeatRule = (try? c.decodeIfPresent(String.self, forKey: .repeatRule)).flatMap { $0?.isEmpty == true ? nil : $0 }
        prep = (try? c.decodeIfPresent(Bool.self, forKey: .prep)) ?? false
        steps = (try? c.decodeIfPresent([TodoStep].self, forKey: .steps)) ?? []
        made = (try? c.decodeIfPresent([TodoMade].self, forKey: .made)) ?? []
        source = try? c.decodeIfPresent(TodoSource.self, forKey: .source)
        createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try? c.decodeIfPresent(String.self, forKey: .updatedAt)
        doneAt = try? c.decodeIfPresent(String.self, forKey: .doneAt)
        createdBy = try? c.decodeIfPresent(String.self, forKey: .createdBy)
        log = (try? c.decodeIfPresent([TodoLogEntry].self, forKey: .log)) ?? []
        section = (try? c.decodeIfPresent(String.self, forKey: .section)).flatMap { $0?.isEmpty == true ? nil : $0 }
        position = (try? c.decodeIfPresent(Double.self, forKey: .position)) ?? 0
        watch = (try? c.decodeIfPresent(String.self, forKey: .watch)) ?? ""
        chat = (try? c.decodeIfPresent(TodoChat.self, forKey: .chat)).flatMap { $0 }
        chatKnown = c.contains(.chat) || (try? c.decodeIfPresent(Bool.self, forKey: .chatKnown)) == true
        pageAt = (try? c.decodeIfPresent(String.self, forKey: .pageAt)).flatMap { $0?.isEmpty == true ? nil : $0 }
        page = (try? c.decodeIfPresent(TodoPageGist.self, forKey: .page)).flatMap { $0?.isEmpty == true ? nil : $0 }
        nextCheck = (try? c.decodeIfPresent(String.self, forKey: .nextCheck)).flatMap { $0?.isEmpty == true ? nil : $0 }
        choices = ((try? c.decodeIfPresent([String].self, forKey: .choices)) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let level = (try? c.decodeIfPresent(Int.self, forKey: .priority)) ?? 0
        priority = (0...3).contains(level) ? level : 0
        tags = ((try? c.decodeIfPresent([String].self, forKey: .tags)) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        alert = (try? c.decodeIfPresent(Int.self, forKey: .alert)).flatMap { $0 }.flatMap { $0 >= 0 ? $0 : nil }
        starts = (try? c.decodeIfPresent(String.self, forKey: .starts)).flatMap { $0?.isEmpty == true ? nil : $0 }
    }

    /// Where it sits in its section: its position, or when it was added on an older add-on.
    var order: Double {
        position != 0 ? position : (TodoDates.moment(createdAt)?.timeIntervalSince1970 ?? 0)
    }

    var isDone: Bool { status == "done" }
    /// Who does it, as the app reads it ("me" for anything it doesn't know).
    var whoKind: TodoWho { TodoWho(rawValue: who) ?? .me }
    /// The bot on a bot or together task (a together task with none named reads as the root bot's).
    var helper: String? { whoKind == .me ? nil : (bot ?? "default") }
}

nonisolated enum TodoWho: String, CaseIterable, Sendable { case me, bot, together }

/// [tasks] The words a bot wrote at the top of a task's Task Page, sent with the task (hermes-hq-push 0.9.43).
nonisolated struct TodoPageGist: Codable, Hashable, Sendable {
    var summary: String
    var next: String

    init(summary: String = "", next: String = "") { self.summary = summary; self.next = next }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = ((try? c.decodeIfPresent(String.self, forKey: .summary)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        next = ((try? c.decodeIfPresent(String.self, forKey: .next)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isEmpty: Bool { summary.isEmpty && next.isEmpty }
}

nonisolated struct TodoStep: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    /// "me" | "bot".
    var who: String
    var done: Bool

    init(id: String = TodoIDs.make(), title: String, who: String = "me", done: Bool = false) {
        self.id = id; self.title = title; self.who = who; self.done = done
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? TodoIDs.make()
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        who = (try? c.decodeIfPresent(String.self, forKey: .who)) ?? "me"
        done = (try? c.decodeIfPresent(Bool.self, forKey: .done)) ?? false
    }
}

/// Something a bot made for the task: a file (path), a link (URL) or a note (text).
nonisolated struct TodoMade: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    /// "file" | "link" | "note".
    var kind: String
    var ref: String
    /// [tasks-first] Who put it on the task: "you" for your own file or link (hermes-hq-push 0.9.53), else its bot
    /// (nil from before then: its bot's).
    var by: String?

    init(id: String = TodoIDs.make(), title: String, kind: String, ref: String, by: String? = nil) {
        self.id = id; self.title = title; self.kind = kind; self.ref = ref; self.by = by
    }

    /// You attached it (not something a bot made).
    var isYours: Bool { by == "you" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? TodoIDs.make()
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "note"
        ref = (try? c.decodeIfPresent(String.self, forKey: .ref)) ?? ""
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        by = (try? c.decodeIfPresent(String.self, forKey: .by)).flatMap { $0?.isEmpty == true ? nil : $0 }
    }

    /// A made link's address to open: as written when it has a scheme, else as a web address ("example.com/x" →
    /// https://example.com/x). nil for words that aren't an address.
    static func linkURL(_ ref: String) -> URL? {
        let text = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        if let url = URL(string: text), let scheme = url.scheme, !scheme.isEmpty, text.contains(":") {
            // "example.com:8080" reads as scheme "example.com"; a real scheme has no dot and is followed by "//" or is mailto/tel.
            if !scheme.contains(".") { return url }
        }
        guard let host = text.split(separator: "/").first, host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return nil }
        guard let url = URL(string: "https://" + text), url.host != nil else { return nil }
        return url
    }
}

/// A task's own chat (hermes-hq-push 0.9.37): `{}` on the wire when it has none, read as nil.
nonisolated struct TodoChat: Codable, Hashable, Sendable {
    var profile: String
    var sessionId: String

    enum CodingKeys: String, CodingKey { case profile, sessionId = "session_id" }

    init(profile: String, sessionId: String) { self.profile = profile; self.sessionId = sessionId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = (try? c.decodeIfPresent(String.self, forKey: .profile)) ?? ""
        sessionId = (try? c.decodeIfPresent(String.self, forKey: .sessionId)) ?? ""
        if profile.isEmpty || sessionId.isEmpty {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "no chat"))
        }
    }

    var json: JSONValue { .object(["profile": .string(profile), "session_id": .string(sessionId)]) }
}

nonisolated struct TodoSource: Codable, Hashable, Sendable {
    /// "app" | "chat" | "reminders".
    var kind: String
    var profile: String?
    var sessionId: String?
    var reminderId: String?

    enum CodingKeys: String, CodingKey { case kind, profile, sessionId = "session_id", reminderId = "reminder_id" }

    init(kind: String, profile: String? = nil, sessionId: String? = nil, reminderId: String? = nil) {
        self.kind = kind; self.profile = profile; self.sessionId = sessionId; self.reminderId = reminderId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "app"
        profile = try? c.decodeIfPresent(String.self, forKey: .profile)
        sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
        reminderId = try? c.decodeIfPresent(String.self, forKey: .reminderId)
    }
}

nonisolated struct TodoLogEntry: Codable, Hashable, Sendable {
    var at: String
    /// "you" or a profile.
    var by: String
    var text: String
    /// "change": a line the add-on wrote for something the bot changed ("Ticked “Book it”", hermes-hq-push 0.9.47).
    var kind: String?

    init(at: String, by: String, text: String, kind: String? = nil) { self.at = at; self.by = by; self.text = text; self.kind = kind }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = (try? c.decodeIfPresent(String.self, forKey: .at)) ?? ""
        by = (try? c.decodeIfPresent(String.self, forKey: .by)) ?? "you"
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)).flatMap { $0 }
    }
}

/// `GET/PUT /tasks/settings`.
nonisolated struct TodoSettings: Codable, Hashable, Sendable {
    /// Settings › Tasks (hermes-hq-push 0.9.36). Off: the page leaves the app, and the bots lose the tools, the note
    /// and their prep jobs. The list is kept. An older add-on leaves it out (on).
    var enabled = true
    /// "ask" | "auto" | "off": how a bot catches "I need to…" in a chat. Ask First is the default (hermes-hq-push
    /// 0.9.34): the bot offers what it could do, and nothing goes on the list without a yes.
    var capture: String = "ask"
    /// Prep runs a day across every bot.
    var prepPerDay: Int = 6
    var quietStart: String = "22:00"
    var quietEnd: String = "08:00"
    var prepEveryHours: Int = 3
    /// "smart" | "sections": how the page grouped its tasks before its views (2026-11-12). Kept as the gateway sends
    /// it, so an older app on the same gateway keeps its choice; this app no longer reads it.
    var group: String = "smart"
    /// A list's order: "smart" (your drag order) | "due" | "added" | "priority" (hermes-hq-push 0.9.53).
    var sort: String = "smart"
    /// [task-ideas] Ideas (hermes-hq-push 0.9.39): one bot reads your recent chats each day and suggests a few tasks.
    /// nil from an older add-on, and then never sent back.
    var ideas: Bool?
    /// The bot that looks.
    var ideasBot: String?
    /// "07:30", on the computer's clock.
    var ideasAt: String?
    /// Ideas a day, 1–5.
    var ideasMax: Int?

    enum CodingKeys: String, CodingKey {
        case enabled, capture, prepPerDay = "prep_per_day", quietStart = "quiet_start", quietEnd = "quiet_end", prepEveryHours = "prep_every_hours"
        case group, sort
        case ideas, ideasBot = "ideas_bot", ideasAt = "ideas_at", ideasMax = "ideas_max"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        capture = (try? c.decodeIfPresent(String.self, forKey: .capture)) ?? "ask"
        prepPerDay = (try? c.decodeIfPresent(Int.self, forKey: .prepPerDay)) ?? 6
        quietStart = (try? c.decodeIfPresent(String.self, forKey: .quietStart)) ?? "22:00"
        quietEnd = (try? c.decodeIfPresent(String.self, forKey: .quietEnd)) ?? "08:00"
        prepEveryHours = (try? c.decodeIfPresent(Int.self, forKey: .prepEveryHours)) ?? 3
        group = (try? c.decodeIfPresent(String.self, forKey: .group)) ?? "smart"
        sort = (try? c.decodeIfPresent(String.self, forKey: .sort)) ?? "smart"
        ideas = try? c.decodeIfPresent(Bool.self, forKey: .ideas)
        ideasBot = try? c.decodeIfPresent(String.self, forKey: .ideasBot)
        ideasAt = try? c.decodeIfPresent(String.self, forKey: .ideasAt)
        ideasMax = try? c.decodeIfPresent(Int.self, forKey: .ideasMax)
    }
}

/// One of your own sections on the Tasks page (owner 2026-11-04: "can we create sections? And an easy way to move the
/// tasks amongst the sections"). The list's order is the page's.
nonisolated struct TodoUserSection: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
}

/// `GET /tasks`: the list, or `unchanged` when `?since=` matched the list's rev.
nonisolated struct TodoListAnswer: Decodable, Sendable {
    var rev: Int
    var tasks: [TodoTask]?
    var settings: TodoSettings?
    /// Your own sections; nil from an add-on older than 0.9.36 (which can't keep them).
    var sections: [TodoUserSection]?
    var unchanged: Bool
    /// The add-on draws every task a Task Page (`GET /tasks/{id}/page`, 0.9.38).
    var pages = false
    /// [task-ideas] New ideas to decide (0 while Ideas is off); nil from an add-on older than 0.9.39, which has none.
    var ideas: Int?
    /// [tasks-first] The add-on keeps a task's priority, tags, alert and start day, and lets a shared task repeat
    /// (hermes-hq-push 0.9.53); `files`: it takes your own files and links.
    var fields = false
    var files = false

    enum CodingKeys: String, CodingKey { case rev, tasks, settings, sections, unchanged, pages, ideas, fields, files }

    init(rev: Int, tasks: [TodoTask]?, settings: TodoSettings? = nil, sections: [TodoUserSection]? = nil, unchanged: Bool = false) {
        self.rev = rev; self.tasks = tasks; self.settings = settings; self.sections = sections; self.unchanged = unchanged
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rev = (try? c.decodeIfPresent(Int.self, forKey: .rev)) ?? 0
        // One bad task never loses the list: each is decoded on its own.
        if let raw = try? c.decodeIfPresent([JSONValue].self, forKey: .tasks) {
            tasks = raw.compactMap { value in (try? value.encoded()).flatMap { try? JSONDecoder().decode(TodoTask.self, from: $0) } }
        } else {
            tasks = nil
        }
        settings = try? c.decodeIfPresent(TodoSettings.self, forKey: .settings)
        // [13-17] Each section on its own too: one malformed section (a name missing) hid them all, and adding or moving
        // one then said the add-on was too old.
        if let raw = try? c.decodeIfPresent([JSONValue].self, forKey: .sections) {
            sections = raw.compactMap { value in (try? value.encoded()).flatMap { try? JSONDecoder().decode(TodoUserSection.self, from: $0) } }
        } else {
            sections = nil
        }
        unchanged = (try? c.decodeIfPresent(Bool.self, forKey: .unchanged)) ?? false
        pages = (try? c.decodeIfPresent(Bool.self, forKey: .pages)) ?? false
        ideas = try? c.decodeIfPresent(Int.self, forKey: .ideas)
        fields = (try? c.decodeIfPresent(Bool.self, forKey: .fields)) ?? false
        files = (try? c.decodeIfPresent(Bool.self, forKey: .files)) ?? false
    }
}

nonisolated enum TodoIDs {
    /// uuid4 hex, as the add-on makes them.
    static func make() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    /// A task added here that the gateway has not answered for yet.
    static func local() -> String { "local-" + make() }
    static func isLocal(_ id: String) -> Bool { id.hasPrefix("local-") }
}

// MARK: - Dates

/// A task's due: a day, or a moment.
nonisolated struct TodoDue: Hashable, Sendable {
    var date: Date
    var hasTime: Bool
}

nonisolated enum TodoDates {
    /// "2026-11-05" (the day's start where the phone is) or an ISO 8601 moment; nil for anything else.
    static func due(_ raw: String?, calendar: Calendar = .current) -> TodoDue? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.count == 10, let day = day(raw, calendar: calendar) { return TodoDue(date: day, hasTime: false) }
        return moment(raw).map { TodoDue(date: $0, hasTime: true) }
    }

    /// "2026-11-05" as that day's start in `calendar`.
    static func day(_ raw: String, calendar: Calendar = .current) -> Date? {
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    // [13-18] Made once: a Done list's sort read two dates per comparison, each making new formatters, on main.
    // (ISO 8601 parsing is safe from any thread; neither depends on the phone's zone.)
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// An ISO 8601 moment, with or without fractional seconds ("…Z", "…+00:00", "…-06:00").
    static func moment(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let date = plain.date(from: raw) { return date }
        if let date = fractional.date(from: raw) { return date }
        // Python's isoformat() with no zone: read as the phone's time.
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            local.dateFormat = format
            if let date = local.date(from: raw) { return date }
        }
        return nil
    }

    /// The wire form of a due: "2026-11-05" for a day, "2026-11-05T17:00:00-06:00" for a time.
    static func wire(_ date: Date, hasTime: Bool, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 1, parts.day ?? 1)
        guard hasTime else { return day }
        let seconds = calendar.timeZone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let offset = String(format: "%@%02d:%02d", sign, abs(seconds) / 3600, (abs(seconds) % 3600) / 60)
        return day + String(format: "T%02d:%02d:00", parts.hour ?? 0, parts.minute ?? 0) + offset
    }

    /// Now as the routes write times.
    static func now(_ date: Date = Date()) -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        return format.string(from: date)
    }
}

// MARK: - Sections

/// Where a task stands (the page's sections until 2026-11-12, when its views took over: `TodoViews`). Still what the
/// Mac table's status words go by, and the name of "Still Need These?".
nonisolated enum TodoSection: String, CaseIterable, Sendable {
    case ready = "Ready for You"
    case needsYou = "Needs You"
    case overdue = "Overdue"
    case today = "Today"
    case bots = "Bots’ Tasks"
    case upcoming = "Upcoming"
    case noDate = "No Date"
    /// A bot added it, it has no date, and nobody touched it for two weeks: keep it, finish it, or let it go. So
    /// what bots add from chats can't quietly bury the list (owner 2026-11-04: "too many things making it on the task
    /// list"). Nothing here is deleted on its own.
    case stale = "Still Need These?"
    case done = "Done"
}

nonisolated enum TodoSections {
    static func section(_ task: TodoTask, now: Date, calendar: Calendar = .current) -> TodoSection {
        switch task.status {
        case "done": return .done
        case "ready": return .ready
        case "needs_you": return .needsYou
        default: break
        }
        if isStale(task, now: now) { return .stale }
        if task.whoKind == .bot { return .bots }
        guard let due = TodoDates.due(task.due, calendar: calendar) else { return .noDate }
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: due.date)
        if day < today { return .overdue }
        if day == today { return .today }
        return .upcoming
    }

    /// Untouched this long, a bot's dateless task asks to be kept.
    static let staleAfter: TimeInterval = 14 * 86_400

    /// An open task a bot added (not you, not Reminders), with no due, that nobody changed in two weeks. A bot at work
    /// on it, a due date or a Keep takes it out.
    static func isStale(_ task: TodoTask, now: Date) -> Bool {
        guard task.status == "open", task.due == nil, let by = task.createdBy, !by.isEmpty, by != "you",
              let touched = TodoDates.moment(task.updatedAt) ?? TodoDates.moment(task.createdAt) else { return false }
        return now.timeIntervalSince(touched) >= staleAfter
    }

    static func sorted(_ items: [TodoTask], in section: TodoSection, calendar: Calendar = .current) -> [TodoTask] {
        let far = Date.distantFuture
        func due(_ t: TodoTask) -> Date { TodoDates.due(t.due, calendar: calendar)?.date ?? far }
        func created(_ t: TodoTask) -> Date { TodoDates.moment(t.createdAt) ?? .distantPast }
        func updated(_ t: TodoTask) -> Date { TodoDates.moment(t.updatedAt) ?? created(t) }
        switch section {
        case .ready, .needsYou:
            // The newest news first.
            return items.sorted { (updated($0), $0.id) > (updated($1), $1.id) }
        case .bots:
            // Bots at work first, then by due, then oldest first.
            return items.sorted { a, b in
                let wa = a.status == "working" ? 0 : 1, wb = b.status == "working" ? 0 : 1
                if wa != wb { return wa < wb }
                if due(a) != due(b) { return due(a) < due(b) }
                return (created(a), a.id) < (created(b), b.id)
            }
        case .overdue, .today, .upcoming:
            return items.sorted { a, b in
                if due(a) != due(b) { return due(a) < due(b) }
                return (created(a), a.id) < (created(b), b.id)
            }
        case .noDate:
            return items.sorted { (created($0), $0.id) < (created($1), $1.id) }
        case .stale:
            // The longest forgotten first.
            return items.sorted { (updated($0), $0.id) < (updated($1), $1.id) }
        case .done:
            return items.sorted { (TodoDates.moment($0.doneAt) ?? updated($0), $0.id) > (TodoDates.moment($1.doneAt) ?? updated($1), $1.id) }
        }
    }

    /// A group's tasks in the Sort By order: "smart" is your drag order (`position`), "due" soonest first (no date
    /// last), "added" newest first.
    static func ordered(_ items: [TodoTask], sort: String, calendar: Calendar = .current) -> [TodoTask] {
        func created(_ t: TodoTask) -> Date { TodoDates.moment(t.createdAt) ?? .distantPast }
        switch sort {
        case "due":
            func due(_ t: TodoTask) -> Date { TodoDates.due(t.due, calendar: calendar)?.date ?? .distantFuture }
            return items.sorted { a, b in due(a) != due(b) ? due(a) < due(b) : (a.order, a.id) < (b.order, b.id) }
        case "added":
            return items.sorted { (created($0), $0.id) > (created($1), $1.id) }
        case "priority":
            // High, medium, low, then none; your own order inside each.
            func rank(_ t: TodoTask) -> Int { t.priority == 0 ? 4 : t.priority }
            return items.sorted { a, b in rank(a) != rank(b) ? rank(a) < rank(b) : (a.order, a.id) < (b.order, b.id) }
        default:
            return items.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
        }
    }

    /// A dragged task's new position between its new neighbours (nil when there are none).
    static func position(between above: TodoTask?, and below: TodoTask?, now: Date = Date()) -> Double {
        switch (above?.order, below?.order) {
        case let (a?, b?): return (a + b) / 2
        case let (a?, nil): return a + 1
        case let (nil, b?): return b - 1
        case (nil, nil): return now.timeIntervalSince1970
        }
    }

    /// The All Bots filter: one bot's tasks (its bot and together tasks); everything for All Bots.
    static func filtered(_ tasks: [TodoTask], scope: String, query: String) -> [TodoTask] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return tasks.filter { task in
            // [bot-pills] "@me": your own tasks, with no bot helping.
            if scope == "@me" { if task.helper != nil { return false } } else if scope != "all", task.helper != scope { return false }
            guard !words.isEmpty else { return true }
            let fields = [task.title, task.notes, task.statusNote] + task.steps.map(\.title) + task.tags
            // "#hiring" finds the tag alone.
            if words.hasPrefix("#") { return task.tags.contains { $0.lowercased().hasPrefix(String(words.dropFirst())) } }
            return fields.contains { $0.lowercased().contains(words) }
        }
    }
}

// MARK: - Words

nonisolated enum TodoTone: String, Sendable { case plain, ready, working, needsYou, overdue }

/// A row's second line: a coloured lead ("Ready", "Hermes is on it", "Needs you") and the rest in grey, joined by " · ".
nonisolated struct TodoRowLine: Hashable, Sendable {
    var lead: String?
    var tone: TodoTone
    var rest: [String]

    var text: String { ([lead].compactMap { $0 } + rest).joined(separator: " · ") }
}

nonisolated enum TodoWords {
    static func whoWords(_ task: TodoTask, botName: (String?) -> String) -> String {
        switch task.whoKind {
        case .me: return "You"
        case .bot: return botName(task.helper)
        case .together: return "You & \(botName(task.helper))"
        }
    }

    static func statusLabel(_ status: String) -> String {
        switch status {
        case "working": return "Working"
        case "ready": return "Ready for You"
        case "needs_you": return "Needs You"
        case "done": return "Done"
        default: return "To Do"
        }
    }

    static func tone(_ status: String) -> TodoTone {
        switch status {
        case "working": return .working
        case "ready": return .ready
        case "needs_you": return .needsYou
        default: return .plain
        }
    }

    static func repeatLabel(_ rule: String?) -> String {
        switch rule {
        case "daily": return "Every Day"
        case "weekdays": return "Every Weekday"
        case "weekly": return "Every Week"
        case "monthly": return "Every Month"
        case "yearly": return "Every Year"
        default: return "Never"
        }
    }

    static let repeatRules = ["daily", "weekdays", "weekly", "monthly", "yearly"]

    /// "x of y steps" (nil without steps).
    static func stepsProgress(_ task: TodoTask) -> String? {
        guard !task.steps.isEmpty else { return nil }
        return "\(task.steps.filter(\.done).count) of \(task.steps.count) steps"
    }

    /// The clock in the phone's style ("5:00 PM").
    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.locale = calendar.locale ?? .current
        format.setLocalizedDateFormatFromTemplate("jmm")
        return format.string(from: date)
    }

    /// "Nov 12" (with the year when it isn't this year's).
    static func monthDay(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.locale = calendar.locale ?? .current
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        format.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yMMMd")
        return format.string(from: date)
    }

    /// "Today", "Tomorrow", "Yesterday" or "Nov 12".
    static func day(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        return monthDay(date, now: now, calendar: calendar)
    }

    /// The due in a tile or a sheet: "Today", "Today, 5:00 PM", "Nov 12", "None".
    static func dueTile(_ task: TodoTask, now: Date, calendar: Calendar = .current) -> String {
        guard let due = TodoDates.due(task.due, calendar: calendar) else { return "None" }
        let day = day(due.date, now: now, calendar: calendar)
        return due.hasTime ? "\(day), \(clock(due.date, calendar: calendar))" : day
    }

    /// The due inside a row, given the section the row is in (a section that already says the day leaves it out).
    static func dueInRow(_ task: TodoTask, section: TodoSection, now: Date, calendar: Calendar = .current) -> String? {
        guard let due = TodoDates.due(task.due, calendar: calendar) else { return nil }
        let time = due.hasTime ? clock(due.date, calendar: calendar) : nil
        switch section {
        case .today:
            return time
        case .overdue, .upcoming:
            let day = section == .upcoming ? Self.day(due.date, now: now, calendar: calendar) : monthDay(due.date, now: now, calendar: calendar)
            return time.map { "\(day), \($0)" } ?? day
        default:
            if calendar.isDate(due.date, inSameDayAs: now) { return time.map { "Due \($0)" } ?? "Due today" }
            let day = Self.day(due.date, now: now, calendar: calendar)
            return "Due \(day)" + (time.map { ", \($0)" } ?? "")
        }
    }

    /// A row's second line (mockup 1-list).
    static func rowLine(_ task: TodoTask, section: TodoSection, now: Date, calendar: Calendar = .current,
                        botName: (String?) -> String) -> TodoRowLine {
        let note = task.statusNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let due = dueInRow(task, section: section, now: now, calendar: calendar)
        let name = botName(task.helper)
        switch task.status {
        case "done":
            let when = TodoDates.moment(task.doneAt).map { day($0, now: now, calendar: calendar) }
            return TodoRowLine(lead: nil, tone: .plain, rest: [when.map { "Done \($0 == "Today" || $0 == "Yesterday" ? $0.lowercased() : $0)" } ?? "Done"])
        case "ready":
            // A note that says what is ready ("Draft ready") is the lead itself; otherwise "Ready", then the note, or
            // when there is none, the due.
            if !note.isEmpty, note.lowercased().contains("ready"), note.count <= 28 {
                return TodoRowLine(lead: note, tone: .ready, rest: [due].compactMap { $0 })
            }
            return TodoRowLine(lead: "Ready", tone: .ready, rest: [note.isEmpty ? due : note].compactMap { $0 })
        case "needs_you":
            return TodoRowLine(lead: "Needs you", tone: .needsYou, rest: [note.isEmpty ? due : note].compactMap { $0 })
        case "working":
            if task.whoKind == .together {
                return TodoRowLine(lead: "\(name) is on it", tone: .working, rest: [stepsProgress(task) ?? (note.isEmpty ? nil : note)].compactMap { $0 })
            }
            return TodoRowLine(lead: "\(name) is working", tone: .working, rest: [note.isEmpty ? stepsProgress(task) : note].compactMap { $0 })
        default:
            if section == .stale {
                // "Added by Hermes · Oct 20": who put it there, and how long ago.
                let by = "Added by \(botName(task.createdBy))"
                let when = TodoDates.moment(task.createdAt).map { day($0, now: now, calendar: calendar) }
                return TodoRowLine(lead: nil, tone: .plain, rest: [by] + [when].compactMap { $0 })
            }
            var rest: [String] = []
            if let due { rest.append(due) }
            switch task.whoKind {
            case .together: rest.append("\(name) can help")
            case .bot: if rest.isEmpty { rest.append(task.prep ? "\(name) gets it ready" : "For \(name)") }
            case .me: if task.repeatRule != nil { rest.append(repeatLabel(task.repeatRule)) }
            }
            if section == .overdue { return TodoRowLine(lead: "Overdue", tone: .overdue, rest: rest) }
            return TodoRowLine(lead: nil, tone: .plain, rest: rest)
        }
    }

    /// The sheet's origin line: "Added from your chat with Hermes · Today".
    static func origin(_ task: TodoTask, now: Date, calendar: Calendar = .current, botName: (String?) -> String) -> String {
        let source: String
        switch task.source?.kind {
        case "chat": source = "Added from your chat with \(botName(task.source?.profile ?? task.createdBy ?? task.helper))"
        case "reminders": source = "Imported from Reminders"
        default:
            if let by = task.createdBy, by != "you", !by.isEmpty { source = "Added by \(botName(by))" } else { source = "Added by you" }
        }
        guard let created = TodoDates.moment(task.createdAt) else { return source }
        return "\(source) · \(day(created, now: now, calendar: calendar))"
    }

    /// "12 min ago", "Just now", "3 h ago", "Nov 2".
    static func ago(_ raw: String?, now: Date, calendar: Calendar = .current) -> String {
        guard let date = TodoDates.moment(raw) else { return "" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        return day(date, now: now, calendar: calendar)
    }

    /// The question a needs-you task asks, or what a ready task holds, for the sheet's now card.
    static func nowTitle(_ task: TodoTask, botName: (String?) -> String) -> String? {
        let name = botName(task.helper)
        switch task.status {
        case "ready": return "\(name) got this ready"
        case "needs_you": return "\(name) needs you"
        default: return nil
        }
    }

    /// [tasks] The brief's state line: "Ready for you", "Inbox is on it", "Inbox needs you", "To do", "Done".
    static func stateWords(_ task: TodoTask, botName: (String?) -> String) -> String {
        switch task.status {
        case "working": return "\(botName(task.helper)) is on it"
        case "ready": return "Ready for you"
        case "needs_you": return "\(botName(task.helper)) needs you"
        case "done": return "Done"
        default: return "To do"
        }
    }

    /// When the task came to its state: the newest status line in its log ("Ready: …", "Started"; the bare status
    /// from an older add-on), when it was done, else when it last changed. Nil for a task still to do (nothing to say).
    static func stateSince(_ task: TodoTask) -> String? {
        if task.isDone { return task.doneAt ?? task.updatedAt }
        guard task.status != "open" else { return nil }
        let words = ["working": "Started", "ready": "Ready", "needs_you": "Needs you"][task.status] ?? ""
        let entry = task.log.last { entry in
            entry.text == task.status || entry.text == words || entry.text.hasPrefix(words + ": ")
        }
        return entry?.at ?? task.updatedAt
    }

    /// The brief's time: "15 min ago", or the day and clock for Done ("today 4:12 PM").
    static func stateTime(_ task: TodoTask, now: Date, calendar: Calendar = .current) -> String? {
        guard let raw = stateSince(task) else { return nil }
        if task.isDone, let date = TodoDates.moment(raw) {
            let day = day(date, now: now, calendar: calendar)
            return "\(day == "Today" || day == "Yesterday" ? day.lowercased() : day) \(clock(date, calendar: calendar))"
        }
        let ago = ago(raw, now: now, calendar: calendar)
        return ago.isEmpty ? nil : ago
    }

    /// [tasks] What the bot made, once each: a bot that saved the same draft twice ("Nudge draft to Dana", two links,
    /// owner's screenshot 2026-11-08) shows it once, its newest; the order stays the order they came in.
    static func shownMade(_ task: TodoTask) -> [TodoMade] {
        var seen = Set<String>()
        let newestFirst = task.made.reversed().filter { made in
            seen.insert(made.kind + "|" + made.title.trimmingCharacters(in: .whitespaces).lowercased()).inserted
        }
        return newestFirst.reversed()
    }

    /// What the bot says about it: where it stands from its Task Page, else its line. Nil when it has said nothing.
    static func botWords(_ task: TodoTask) -> String? {
        if let summary = task.page?.summary, !summary.isEmpty { return summary }
        let note = task.statusNote.trimmingCharacters(in: .whitespacesAndNewlines)
        return note.isEmpty ? nil : note
    }

    /// [tasks] What the bot just changed on the task (hermes-hq-push 0.9.47's "change" lines): the ones after your
    /// own last entry, newest three, while the newest is under a day old. Owner 2026-11-09: telling the bot something
    /// "doesn't really change the task" — now the page shows that it did.
    static func recentChanges(_ task: TodoTask, now: Date = Date(), within: TimeInterval = 86_400) -> [String] {
        var out: [TodoLogEntry] = []
        for entry in task.log.reversed() {
            if entry.by == "you" { break }
            if entry.kind == "change" { out.append(entry) }
        }
        guard let newest = out.first, let at = TodoDates.moment(newest.at), now.timeIntervalSince(at) < within else { return [] }
        return out.prefix(3).reversed().map(\.text)
    }

    /// [tasks] "Checks again Wed, 9:00 AM": when the bot looks again by itself (hermes-hq-push 0.9.47); nil when not
    /// set, done, or already past.
    static func nextCheckLine(_ task: TodoTask, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard !task.isDone, let raw = task.nextCheck, let due = TodoDates.due(raw, calendar: calendar), due.date > now else { return nil }
        let day = day(due.date, now: now, calendar: calendar)
        let words = due.hasTime ? "\(day), \(clock(due.date, calendar: calendar))" : day
        return "Checks again \(day == "Today" || day == "Tomorrow" ? words.prefix(1).lowercased() + words.dropFirst() : words)"
    }

    /// The line under the bot's words: its Next, else what it watches for (which then has no other place).
    static func nextLine(_ task: TodoTask) -> (text: String, isWatch: Bool)? {
        if !task.isDone, let next = task.page?.next, !next.isEmpty {
            return (next.lowercased().hasPrefix("next") ? next : "Next: " + next, false)
        }
        return watching(task).map { ($0, true) }
    }

    /// The message an "Ask <Bot> about this task" sends: the question, then the task (title, notes, steps).
    static func askMessage(_ question: String, task: TodoTask) -> String {
        var lines = [question.trimmingCharacters(in: .whitespacesAndNewlines), "", "About my task “\(task.title)”"]
        let notes = task.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { lines.append("Notes: \(notes)") }
        if !task.steps.isEmpty {
            lines.append("Steps:")
            for step in task.steps { lines.append("- [\(step.done ? "x" : " ")] \(step.title) (\(step.who == "bot" ? "you" : "me"))") }
        }
        if !task.statusNote.isEmpty { lines.append("Status: \(task.statusNote)") }
        lines.append("(Task id \(task.id))")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Edits and the 409 merge

nonisolated enum TodoEdits {
    /// Who changes to Just Me: a bot's steps become yours (there's no bot to do them, and a Just Me task's step can't
    /// be handed back). nil when nothing changes.
    static func stepsForJustMe(_ who: TodoWho, steps: [TodoStep]) -> [TodoStep]? {
        guard who == .me, steps.contains(where: { $0.who != "me" }) else { return nil }
        return steps.map { step in var step = step; step.who = "me"; return step }
    }

    /// `task` with `fields` (wire names) applied, as the gateway would apply a PATCH; nil when the result doesn't decode.
    static func applying(_ fields: [String: JSONValue], to task: TodoTask) -> TodoTask? {
        guard case .object(var object)? = try? JSONValue.parse(JSONEncoder().encode(task)) else { return nil }
        for (key, value) in fields { object[key] = value }
        guard let data = try? JSONValue.object(object).encoded() else { return nil }
        return try? JSONDecoder().decode(TodoTask.self, from: data)
    }

    /// One wire field's value on `task` (`.null` when absent).
    static func value(_ key: String, of task: TodoTask) -> JSONValue {
        guard case .object(let object)? = try? JSONValue.parse(JSONEncoder().encode(task)) else { return .null }
        return object[key] ?? .null
    }

    enum Resolution: Equatable, Sendable {
        /// Nobody else touched these fields: send the change again on the current rev.
        case resend(rev: Int)
        /// Someone changed the same field: the current version stands.
        case theirs
    }

    /// A PATCH came back 409 with the `current` task. `base` is the task the change was made on. When every field the
    /// change sets still holds what it held in `base`, the change is re-applied on the current rev; otherwise the
    /// other device's (or bot's) edit wins and the sheet shows it.
    /// The bots whose "Task prep" job a change may start or end (hermes-hq-push 0.9.32's `POST /tasks/prep-job/{bot}`):
    /// an added or deleted prep task's bot; for an edit to who, bot, prep or status, the bot before and after when
    /// either side gets things ready.
    static func prepBots(before: TodoTask?, after: TodoTask?, fields: Set<String>?) -> [String] {
        if let fields, fields.isDisjoint(with: ["prep", "bot", "who", "status"]) { return [] }
        var bots: [String] = []
        for task in [before, after].compactMap({ $0 }) where task.prep {
            if let bot = task.helper, !bots.contains(bot) { bots.append(bot) }
        }
        if fields != nil, before?.prep == true || after?.prep == true {
            for task in [before, after].compactMap({ $0 }) { if let bot = task.helper, !bots.contains(bot) { bots.append(bot) } }
        }
        return bots
    }

    static func resolve(base: TodoTask, current: TodoTask, fields: [String: JSONValue]) -> Resolution {
        for key in fields.keys where key != "rev" {
            if value(key, of: base) != value(key, of: current) { return .theirs }
        }
        return .resend(rev: current.rev)
    }
}

// MARK: - The chat card ("Added to Tasks")

nonisolated enum TodoCardWords {
    /// "You & Hermes · Tomorrow", "Hermes · Nov 20", "You".
    static func line(_ task: AddedTask, now: Date, calendar: Calendar = .current, botName: (String?) -> String) -> String {
        var parts: [String] = []
        switch TodoWho(rawValue: task.who) ?? .me {
        case .me: parts.append("You")
        case .bot: parts.append(botName(task.bot))
        case .together: parts.append("You & \(botName(task.bot))")
        }
        if let due = TodoDates.due(task.due, calendar: calendar) {
            let day = TodoWords.day(due.date, now: now, calendar: calendar)
            parts.append(due.hasTime ? "\(day), \(TodoWords.clock(due.date, calendar: calendar))" : day)
        }
        return parts.joined(separator: " · ")
    }
}

nonisolated extension TodoCardWords {
    /// One step under a together task on the card.
    nonisolated struct Step: Hashable, Sendable {
        var text: String
        var mine: Bool
        var done: Bool
        /// "Started" (0.9.33's start_now) or "Ahead of time" (prep) on the bot's first open step; "" otherwise.
        var status: String
    }

    static let maxSteps = 4

    /// "Hermes: Rank the 167 applications" · "You: Review the shortlist", at most `maxSteps` (the rest are counted).
    static func steps(_ task: AddedTask, botName: String) -> (steps: [Step], more: Int) {
        var statusShown = false
        let all = task.steps.map { step -> Step in
            let mine = step.who == "me"
            var status = ""
            if !mine, !step.done, !statusShown {
                statusShown = true
                status = task.started ? "Started" : task.prep ? "Ahead of time" : ""
            }
            return Step(text: "\(mine ? "You" : botName): \(step.title)", mine: mine, done: step.done, status: status)
        }
        return (Array(all.prefix(maxSteps)), max(0, all.count - maxSteps))
    }

    /// The card's "Ask Hermes to Help": one task of yours alone, nothing split yet.
    static func offersHelp(_ tasks: [AddedTask]) -> Bool {
        tasks.count == 1 && tasks[0].who == "me" && tasks[0].steps.isEmpty
    }
}

nonisolated extension TodoWords {
    /// New Task's footer once a bot is picked: what happens when you tap Add ([mac] Mac polish #138: click on the Mac).
    /// The quick add's date button: "Today", "Tomorrow 9:00 AM", "Fri 9:00 AM", "Nov 20".
    static func newTaskDue(_ date: Date, hasTime: Bool, now: Date, calendar: Calendar = .current) -> String {
        let day = TodoViews.soon(date, now: now, calendar: calendar)
        guard hasTime else { return day }
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.locale = calendar.locale ?? .current
        format.timeStyle = .short
        format.dateStyle = .none
        return day + " " + format.string(from: date)
    }

    static func newTaskHelpNote(_ bot: String, tap: String = DeviceWord.tap) -> String {
        "When you \(tap) Add, \(bot)’s chat opens and \(bot) reads the task right away, then asks what it should take on."
    }

    /// Delete Section's message: what happens to the tasks in it, open and done (both lose the section; none is deleted).
    static func deleteListMessage(open: Int, done: Int) -> String? {
        // [tasks-first] A list is where a task is filed, not the task: deleting it keeps every task, in no list.
        switch (open, done) {
        case (0, 0): return nil
        case (1, 0): return "Its task is kept, in no list."
        case (0, 1): return "Its done task is kept, in no list."
        case (_, 0): return "Its \(open) tasks are kept, in no list."
        case (0, _): return "Its \(done) done tasks are kept, in no list."
        default:
            let tasks = open == 1 ? "1 task" : "\(open) tasks"
            let finished = done == 1 ? "1 done task" : "\(done) done tasks"
            return "Its \(tasks) and \(finished) are kept, in no list."
        }
    }

    /// Under Due (New Task, Choose Date): when this phone's alert rings. A day alone rings at 9:00 (`TodoReminder`).
    /// [mac] Mac polish #138: "This Mac" on the Mac; the iPhone and iPad keep "This phone".
    static func alertNote(hasTime: Bool, calendar: Calendar = .current, locale: Locale = .current,
                          mac: Bool = DeviceWord.isMac) -> String {
        let device = mac ? "This Mac" : "This phone"
        guard !hasTime else { return "\(device) reminds you at that time." }
        let nine = calendar.date(bySettingHour: TodoReminder.dayHour, minute: 0, second: 0, of: Date()) ?? Date()
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.locale = locale
        style.timeZone = calendar.timeZone
        return "\(device) reminds you at \(nine.formatted(style)) that day."
    }

    /// "Ask Hermes to Help" (the chat card, a task's sheet, New Task with a bot): the bot asks which parts it should take
    /// (one card, up to 3 things it could do), then takes them (hermes-hq-push 0.9.34; tasks_update who='together').
    static let helpQuestion = "Help me with this: ask me which parts you should take, then start them."

    /// [tasks] What the bot checks before it reminds you (hermes-hq-push 0.9.37 `watch`): "Watching for a reply from …".
    static func watching(_ task: TodoTask) -> String? {
        let watch = task.watch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !watch.isEmpty, !task.isDone else { return nil }
        // "A reply from Ivy" reads "Watching for a reply from Ivy"; a name keeps its capital.
        let article = ["A ", "An ", "The ", "Any ", "Their ", "His ", "Her "].contains { watch.hasPrefix($0) }
        return "Watching for " + (article ? watch.prefix(1).lowercased() + watch.dropFirst() : watch)
    }

    /// Under "Still Need These?".
    static let staleNote = "Bots added these and nobody touched them for 2 weeks. Keep the ones you still want."

    /// [tasks] Your bubble for a message that asked a bot about a task (`askMessage`, `helpMessage`): your words alone,
    /// the task's details (sent for the bot) left out, in history as when you sent it (owner 2026-11-04: a chat
    /// "preloaded with some text and my response … That's chaos"). Nil for any other message.
    static func askShown(_ text: String) -> String? {
        guard text.hasSuffix(")"), let idLine = text.range(of: "\n(Task id ", options: .backwards),
              !text[idLine.upperBound...].contains("\n"),
              let about = text.range(of: "\n\nAbout my task “"), about.upperBound <= idLine.lowerBound else { return nil }
        let words = text[..<about.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        if words == helpQuestion { return "Help me with “\(text[about.upperBound...].prefix { $0 != "”" })”" }
        return words.isEmpty ? nil : words
    }

    /// The chat card's message: the question, the task's title and id (the bot's tools take the id).
    static func helpMessage(title: String, id: String) -> String {
        "\(helpQuestion)\n\nAbout my task “\(title)”\n(Task id \(id))"
    }
}

/// Tasks a chat card's Undo took back (this run of the app): the card reads "Removed from Tasks" when it is drawn again.
nonisolated enum TodoUndone {
    private static let ids = Mutex<Set<String>>([])
    static func add(_ new: [String]) { ids.withLock { $0.formUnion(new) } }
    static func contains(_ id: String) -> Bool { ids.withLock { $0.contains(id) } }
}

// MARK: - A bot's words, readable (owner 2026-11-04: "the way that some of the work was presented … needs to be improved")

/// A bot wrote its shortlist as one long paragraph ("Elm & Oak: …, (512) 555-0168. Copper Kettle: …. Full table:
/// /Users/…/shortlist.md"), and hermes-hq-push 0.9.32 and the first 0.9.33 ran every line break into a space anyway. Shown, it reads as
/// lines: one per "Name: …" sentence with the name in bold, and "check: a; b; c" as a list. Text with lines of its own
/// is the bot's layout and is left alone.
nonisolated enum TodoReadable {
    /// Markdown for `text`; the same text when nothing reads better split.
    static func markdown(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("\n"), trimmed.count > 120 else { return trimmed }
        let sentences = split(trimmed)
        let labelled = sentences.filter { label(in: $0) != nil }.count
        if labelled >= 2 {
            return sentences.map { sentence -> String in
                guard let label = label(in: sentence) else { return listed(sentence) }
                let rest = sentence.dropFirst(label.count + 1).trimmingCharacters(in: .whitespaces)
                return "- **\(label):** \(rest)"
            }.joined(separator: "\n")
        }
        let listedOnes = sentences.map(listed)
        return listedOnes == sentences ? trimmed : listedOnes.joined(separator: "\n\n")
    }

    /// Sentences, cut only at ". " before a short "Name:" (so "J. Smith's" and "Dr. Lee" stay whole), or before
    /// any sentence once the text is a run of them.
    static func split(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            current.append(chars[i])
            if chars[i] == ".", i + 2 < chars.count, chars[i + 1] == " ",
               label(in: String(chars[(i + 2)...].prefix(60))) != nil {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                i += 2
                continue
            }
            i += 1
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    /// "Elm & Oak" in "Elm & Oak: 410 Aspen Dr…": a capitalised name of up to five words before ": ".
    static func label(in sentence: String) -> String? {
        guard let colon = sentence.range(of: ": ") else { return nil }
        let head = String(sentence[..<colon.lowerBound])
        guard let first = head.first, first.isUppercase || first.isNumber, head.count <= 40,
              !head.contains("."), !head.contains("("), !head.contains(","),
              head.split(separator: " ").count <= 5 else { return nil }
        return head
    }

    /// "Review flagged what to check: a; b; c." → the lead, then a list (three or more items).
    static func listed(_ sentence: String) -> String {
        guard let colon = sentence.range(of: ": ") else { return sentence }
        let tail = sentence[colon.upperBound...]
        let items = tail.components(separatedBy: "; ").map { $0.trimmingCharacters(in: .whitespaces) }
        guard items.count >= 3, items.allSatisfy({ !$0.isEmpty && $0.count <= 160 }) else { return sentence }
        let lead = sentence[..<colon.lowerBound]
        let last = items.count - 1
        return "\(lead):\n" + items.enumerated().map { index, item in
            "- " + (index == last && item.hasSuffix(".") ? String(item.dropLast()) : item)
        }.joined(separator: "\n")
    }

    /// An activity line as words: hermes-hq-push 0.9.32 and the first 0.9.33 logged a status change as the bare status.
    static func logText(_ text: String) -> String {
        switch text {
        case "open": return "Back to To Do"
        case "working": return "Started"
        case "ready": return "Got it ready"
        case "needs_you": return "Needs you"
        case "done": return "Done"
        default: return text
        }
    }

    /// The made note's one-line preview on its row: the first line, without list marks or bold.
    static func preview(_ text: String) -> String {
        let first = markdown(text).components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        var line = first.trimmingCharacters(in: .whitespaces)
        for mark in ["- ", "* ", "• "] where line.hasPrefix(mark) { line = String(line.dropFirst(mark.count)) }
        return line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
    }
}

/// When a task's alert rings, and what it says. Owner 2026-11-04: a "remind me … tomorrow" from Inbox was saved as a
/// day with no time, so no alert was ever set. A day alone rings at 9:00; your own and together tasks ring (a bot's
/// own work never does). A bot's line ("No reply yet; a nudge is drafted") says what's waiting.
nonisolated enum TodoReminder {
    static let dayHour = 9

    /// When the phone rings: at its due time (a day alone: 9:00), or `alert` minutes before that when it has one.
    static func time(_ task: TodoTask, calendar: Calendar = .current) -> Date? {
        guard let due = TodoDates.due(task.due, calendar: calendar) else { return nil }
        let at = due.hasTime ? due.date : calendar.date(bySettingHour: dayHour, minute: 0, second: 0, of: due.date)
        guard let at, let alert = task.alert, alert > 0 else { return at }
        return at.addingTimeInterval(-Double(alert) * 60)
    }

    /// The alerts you can choose, in minutes before; nil is "at its time" by default (no alert of its own).
    static let alerts = [0, 5, 15, 30, 60, 120, 1440]

    /// "At its time", "30 min before", "1 hour before", "1 day before".
    static func alertWords(_ minutes: Int) -> String {
        switch minutes {
        case 0: return "At its time"
        case 1..<60: return "\(minutes) min before"
        case 1440: return "1 day before"
        default:
            if minutes % 1440 == 0 { return "\(minutes / 1440) days before" }
            if minutes % 60 == 0 { return minutes == 60 ? "1 hour before" : "\(minutes / 60) hours before" }
            return "\(minutes) min before"
        }
    }

    /// [13-14] The alert's trigger for `date` (from `time`). A set moment carries its time zone, so it rings at that
    /// moment wherever the phone is (zone-less, it rang at the same clock time in the new zone after a trip); a day
    /// alone stays 9:00 on the phone's clock, wherever it is then.
    static func triggerParts(_ task: TodoTask, at date: Date, calendar: Calendar = .current) -> DateComponents {
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        if TodoDates.due(task.due, calendar: calendar)?.hasTime == true { parts.timeZone = calendar.timeZone }
        return parts
    }

    static func body(_ task: TodoTask) -> String {
        let line = task.statusNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if (task.status == "ready" || task.status == "needs_you"), !line.isEmpty { return line }
        if let alert = task.alert, alert > 0 {
            // It rings ahead: say how far ("Due in 30 min", "Due in 1 hour", "Due tomorrow").
            if alert == 1440 { return "Due tomorrow" }
            return "Due in " + alertWords(alert).replacingOccurrences(of: " before", with: "")
        }
        return TodoDates.due(task.due)?.hasTime == false ? "Due today" : "Due now"
    }
}
