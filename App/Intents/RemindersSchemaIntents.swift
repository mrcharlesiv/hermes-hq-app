// [reminders-schema] Hermes HQ as a reminders app to the system (owner 2026-11-23: "How can we integrate to iMessage
// like this?", the Messages "Add to Reminders" suggestion showing Home Assistant's icon). iOS 27.2's Suggested Actions in
// Messages hands its "Add to Reminders" chip to an app whose intent conforms to the `.reminders.createReminder` schema;
// Siri and Shortcuts use the same intent. Conforming here makes Hermes HQ one of those apps: the chip's words become a
// task of your own in Tasks. Which app's icon the chip shows is the system's choice, not ours.
//
// Three types, as the schema asks: the list (Tasks, the only one), the reminder (a task) and the create intent. The
// intent runs without opening the app and reaches the gateway as Add Task does (`ShortcutGateway`, DECISION I21).
// iOS 27 only, and not in the Mac build: Apple doesn't offer the reminders schemas under Mac Catalyst.

import AppIntents
import Foundation
#if !targetEnvironment(macCatalyst)
import GeoToolbox
#endif

// MARK: - The body (pure: the tests read it, on any iOS)

/// What a reminder's fields become: the New Task sheet's body for a task of your own (`TodoWire.newTask`), plus
/// priority and tags (hermes-hq-push 0.9.53). Links go under the note: a new task has no link field.
nonisolated enum ReminderTaskBody {
    static func make(title: String, note: String?, flagged: Bool?, tags: [String], urls: [URL], due: DateComponents?,
                     repeatRule: String?, place: String? = nil, arriving: Bool = true, section: String? = nil,
                     calendar: Calendar = .current) -> [String: JSONValue] {
        var notes = (note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let links = urls.map(\.absoluteString).filter { !$0.isEmpty && !notes.contains($0) }
        // Tasks has no place alerts: a reminder's place stays in words.
        let spot = place?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let where_ = spot.isEmpty ? nil : (arriving ? "When arriving at \(spot)" : "When leaving \(spot)")
        let extra = links + [where_].compactMap { $0 }
        if !extra.isEmpty { notes = ([notes].filter { !$0.isEmpty } + extra).joined(separator: "\n") }
        var body = TodoWire.newTask(title: title.trimmingCharacters(in: .whitespacesAndNewlines), who: .me, bot: nil,
                                    due: Self.due(due, calendar: calendar), repeatRule: repeatRule, prep: false,
                                    notes: notes, source: TodoSource(kind: "app"))
        if flagged == true { body["priority"] = .number(1) }   // flagged: high
        let kept = tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !kept.isEmpty { body["tags"] = .array(kept.map(JSONValue.string)) }
        if let section, !section.isEmpty { body["section"] = .string(section) }   // one of your lists, by id
        return body
    }

    /// A due date's wire form: a day ("2026-11-25") without an hour, a moment with one; nil when it names no day.
    static func due(_ components: DateComponents?, calendar: Calendar = .current) -> String? {
        guard let components, components.day != nil || components.weekday != nil || components.hour != nil else { return nil }
        var calendar = components.calendar ?? calendar
        if let zone = components.timeZone { calendar.timeZone = zone }
        let hasTime = components.hour != nil
        var day = components
        day.calendar = nil
        day.timeZone = nil
        if day.year == nil || day.month == nil || day.day == nil {
            // "Wednesday", "at 5": the next such moment from now.
            guard let next = calendar.nextDate(after: Date(), matching: day, matchingPolicy: .nextTime) else { return nil }
            return TodoDates.wire(next, hasTime: hasTime, calendar: calendar)
        }
        guard let date = calendar.date(from: day) else { return nil }
        return TodoDates.wire(date, hasTime: hasTime, calendar: calendar)
    }

    /// A task's due back as components (the reminder entity's `dueDate`).
    static func components(_ due: String?, calendar: Calendar = .current) -> DateComponents? {
        guard let parsed = TodoDates.due(due, calendar: calendar) else { return nil }
        let units: Set<Calendar.Component> = parsed.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
        return calendar.dateComponents(units, from: parsed.date)
    }

    /// A repeat the Tasks list can keep ("daily" … "yearly", `TodoTask.repeatRule`); nil for any other.
    static func repeatRule(_ frequency: String, interval: Int, weekdays: Set<Int>) -> String? {
        guard interval == 1 else { return nil }
        switch frequency {
        case "daily": return "daily"
        case "weekly": return weekdays == [2, 3, 4, 5, 6] ? "weekdays" : "weekly"
        case "monthly": return "monthly"
        case "yearly": return "yearly"
        default: return nil
        }
    }
}

#if !targetEnvironment(macCatalyst)

// MARK: - The list

@available(iOS 27.0, *)
@AppEnum(schema: .reminders.listType)
nonisolated enum HQReminderListType: String {
    case standard

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.standard: "Standard"]
}

/// Tasks, as the reminders app's one list.
@available(iOS 27.0, *)
@AppEntity(schema: .reminders.list)
struct HQReminderList {
    static let defaultQuery = HQReminderListQuery()
    static let tasks = HQReminderList(id: "tasks", name: "Tasks", type: .standard)

    let id: String
    var name: String
    var type: HQReminderListType

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(id: String, name: String, type: HQReminderListType) {
        self.id = id
        self.name = name
        self.type = type
    }
}

@available(iOS 27.0, *)
nonisolated struct HQReminderListQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [HQReminderList] {
        identifiers.contains(HQReminderList.tasks.id) ? [.tasks] : []
    }

    func suggestedEntities() async throws -> [HQReminderList] { [.tasks] }

    func entities(matching string: String) async throws -> [HQReminderList] { [.tasks] }
}

// MARK: - Sections (your own lists inside Tasks)

/// One of your own lists on the Tasks page (`TodoUserSection`): the reminders app's sections of its one list.
@available(iOS 27.0, *)
@AppEntity(schema: .reminders.section)
struct HQReminderSection {
    static let defaultQuery = HQReminderSectionQuery()

    let id: String
    var name: String
    var list: HQReminderList

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(id: String, name: String) {
        self.id = id
        self.name = name
        self.list = .tasks
    }
}

/// Short-lived cache so rapid consecutive Siri/Shortcuts entity queries don't refetch `GET /tasks` on every lookup.
@available(iOS 27.0, *)
nonisolated enum HQReminderCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (at: Date, answer: TodoListAnswer)?
    private static let ttl: TimeInterval = 30

    static func list() async throws -> TodoListAnswer {
        if let hit = lock.withLock({ cached }), Date().timeIntervalSince(hit.at) < ttl {
            return hit.answer
        }
        let answer = try await ShortcutGateway.send("GET", TasksAPI.base, what: "your tasks")
        let decoded = try JSONDecoder().decode(TodoListAnswer.self, from: answer.data)
        lock.withLock { cached = (Date(), decoded) }
        return decoded
    }

    static func invalidate() {
        lock.withLock { cached = nil }
    }
}

@available(iOS 27.0, *)
nonisolated struct HQReminderSectionQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [HQReminderSection] {
        let all = try await Self.all()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [HQReminderSection] { try await Self.all() }

    func entities(matching string: String) async throws -> [HQReminderSection] {
        try await Self.all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    static func all() async throws -> [HQReminderSection] {
        let sections = (try await HQReminderCache.list()).sections ?? []
        return sections.map { HQReminderSection(id: $0.id, name: $0.name) }
    }
}

// MARK: - Place (kept in words: Tasks has no place alerts)

@available(iOS 27.0, *)
@AppEnum(schema: .reminders.locationTriggerEvent)
nonisolated enum HQReminderPlaceEvent: String {
    case arrive, depart

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.arrive: "Arrive", .depart: "Depart"]
}

/// A reminder's place, as Siri or Shortcuts give it. Tasks keeps none, so the query finds none and a new task carries
/// the place in its notes (`ReminderTaskBody`).
@available(iOS 27.0, *)
@AppEntity(schema: .reminders.locationTrigger)
struct HQReminderPlace {
    static let defaultQuery = HQReminderPlaceQuery()

    let id: String
    var place: PlaceDescriptor
    var event: HQReminderPlaceEvent

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(place.commonName ?? "Place")") }

    init(id: String, place: PlaceDescriptor, event: HQReminderPlaceEvent) {
        self.id = id
        self.place = place
        self.event = event
    }
}

@available(iOS 27.0, *)
nonisolated struct HQReminderPlaceQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [HQReminderPlace] { [] }

    func entities(matching string: String) async throws -> [HQReminderPlace] { [] }
}

// MARK: - The reminder (a task)

@available(iOS 27.0, *)
@AppEntity(schema: .reminders.reminder)
struct HQReminder {
    static let defaultQuery = HQReminderQuery()

    let id: String
    var title: String
    var note: AttributedString?
    var tags: Set<String>
    var urls: [URL]
    var dueDate: DateComponents?
    var recurrence: Calendar.RecurrenceRule?
    var isCompleted: Bool
    var isFlagged: Bool?
    var creationDate: Date?
    var completionDate: Date?
    var list: HQReminderList
    var locationTrigger: HQReminderPlace?

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }

    init(_ task: TodoTask) {
        id = task.id
        title = task.title
        note = task.notes.isEmpty ? nil : AttributedString(task.notes)
        tags = Set(task.tags)
        urls = []
        dueDate = ReminderTaskBody.components(task.due)
        recurrence = nil
        isCompleted = task.status == "done"
        isFlagged = task.priority == 1
        creationDate = TodoDates.moment(task.createdAt ?? "")
        completionDate = TodoDates.moment(task.doneAt ?? "")
        list = .tasks
        locationTrigger = nil
    }
}

@available(iOS 27.0, *)
nonisolated struct HQReminderQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [HQReminder] {
        let tasks = (try await HQReminderCache.list()).tasks ?? []
        return identifiers.compactMap { id in tasks.first { $0.id == id }.map(HQReminder.init) }
    }
}

// MARK: - Create

@available(iOS 27.0, *)
@AppIntent(schema: .reminders.createReminder)
struct CreateHQReminderIntent {
    static let supportedModes: IntentModes = .background

    var title: String
    var list: HQReminderList?
    var note: AttributedString?
    var isFlagged: Bool?
    var images: [IntentFile]
    var tags: Set<String>
    var urls: [URL]
    var dueDate: DateComponents?
    var recurrence: Calendar.RecurrenceRule?
    var locationTrigger: HQReminderPlace?
    var section: HQReminderSection?

    func perform() async throws -> some ReturnsValue<HQReminder> {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AskBotError.message("Give the reminder a title.") }
        let body = ReminderTaskBody.make(title: name, note: note.map { String($0.characters) }, flagged: isFlagged,
                                         tags: Array(tags), urls: urls, due: dueDate, repeatRule: Self.repeatRule(recurrence),
                                         place: locationTrigger?.place.commonName, arriving: locationTrigger?.event != .depart,
                                         section: section?.id)
        let answer = try await ShortcutGateway.send("POST", TasksAPI.base, json: try JSONValue.object(body).encoded(), what: "the task")
        var made = try TasksAPI.task(answer.data)
        // Upload any attached images (up to TasksStore.fileLimit each); older add-ons ignore or refuse gracefully.
        for (index, file) in images.enumerated() {
            let data = file.data
            guard !data.isEmpty, data.count <= TasksStore.fileLimit else { continue }
            let filename = file.filename.isEmpty ? "image-\(index + 1).jpg" : file.filename
            let attachBody: [String: JSONValue] = [
                "kind": .string("file"),
                "name": .string(filename),
                "data": .string(data.base64EncodedString()),
            ]
            if let encoded = try? JSONValue.object(attachBody).encoded(),
               let attached = try? await ShortcutGateway.send("POST", TasksAPI.base + "/" + PagesREST.segment(made.id) + "/attach",
                                                              json: encoded, what: "the image", timeout: 60),
               let updated = try? TasksAPI.task(attached.data) {
                made = updated
            }
        }
        HQReminderCache.invalidate()
        await ShortcutTasksSync.refreshAfterWrite()
        AppLog.note("intents", "reminders schema: added a task\(images.isEmpty ? "" : " with \(images.count) image(s)")")
        return .result(value: HQReminder(made))
    }

    static func repeatRule(_ rule: Calendar.RecurrenceRule?) -> String? {
        guard let rule, rule.end.occurrences == nil, rule.end.date == nil else { return nil }
        let frequency: String
        switch rule.frequency {
        case .daily: frequency = "daily"
        case .weekly: frequency = "weekly"
        case .monthly: frequency = "monthly"
        case .yearly: frequency = "yearly"
        default: return nil
        }
        let days = Set(rule.weekdays.compactMap { weekday -> Int? in
            if case .every(let day) = weekday { return Self.number(day) }
            return nil
        })
        return ReminderTaskBody.repeatRule(frequency, interval: rule.interval, weekdays: days)
    }

    /// Calendar's weekday number (Sunday 1).
    private static func number(_ day: Locale.Weekday) -> Int? {
        switch day {
        case .sunday: 1
        case .monday: 2
        case .tuesday: 3
        case .wednesday: 4
        case .thursday: 5
        case .friday: 6
        case .saturday: 7
        @unknown default: nil
        }
    }
}

#endif
