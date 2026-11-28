// [shortcuts] "Add Task" and "Run Job" for Shortcuts and Siri (owner 2026-11-20 picked both from the shortcut ideas).
// Both run without opening Hermes HQ, as Ask Bot does: the system may run them with no window and no `AppModel`, so
// they reach the gateway the way the Share extension does (`ShareSender.rest`: the Keychain's sign-in, its own
// throwaway session), for the account the Bots list was last saved for (`AskRoster`).
//
//   Add Task  POST <hermes-hq-push>/tasks with the New Task sheet's body (`TodoWire.newTask`): your own task, or one
//             a bot does (alone, or with you). Returns the task's title.
//   Run Job   POST /api/cron/jobs/<id>/trigger?profile=<owner> (Run Now's call, `CronRunOnce`); a paused job is paused
//             again afterwards. With Wait for Result on, the newest run's words (`/runs`) go to the next step.

import AppIntents
import Foundation

// MARK: - Add Task

nonisolated enum ShortcutTaskWho: String, AppEnum {
    case together, bot

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Who Does It")
    static let caseDisplayRepresentations: [ShortcutTaskWho: DisplayRepresentation] = [
        .together: "You and the Bot",
        .bot: "The Bot",
    ]
    var wire: TodoWho { self == .bot ? .bot : .together }
}

nonisolated enum ShortcutTaskPriority: String, AppEnum {
    case high, medium, low

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Priority")
    static let caseDisplayRepresentations: [ShortcutTaskPriority: DisplayRepresentation] = [
        .high: "High",
        .medium: "Medium",
        .low: "Low",
    ]
    var wire: Int {
        switch self {
        case .high: 1
        case .medium: 2
        case .low: 3
        }
    }
}

nonisolated enum ShortcutTaskRepeat: String, AppEnum {
    case daily, weekdays, weekly, monthly, yearly

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Repeat")
    static let caseDisplayRepresentations: [ShortcutTaskRepeat: DisplayRepresentation] = [
        .daily: "Every Day",
        .weekdays: "Every Weekday",
        .weekly: "Every Week",
        .monthly: "Every Month",
        .yearly: "Every Year",
    ]
}

nonisolated enum ShortcutTasksFilter: String, AppEnum {
    case today, upcoming, inbox, all

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "View")
    static let caseDisplayRepresentations: [ShortcutTasksFilter: DisplayRepresentation] = [
        .today: "Today",
        .upcoming: "Upcoming",
        .inbox: "Inbox",
        .all: "All Open",
    ]
}

struct AddTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Task"
    static let description: IntentDescription? = IntentDescription(
        "Add a task to your Tasks list without opening Hermes HQ. Pick a bot to have it help, or leave Bot empty for a task of your own.",
        categoryName: "Tasks")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Title") var taskTitle: String
    @Parameter(title: "Bot") var bot: VoiceNoteBot?
    @Parameter(title: "Who Does It", default: .together) var who: ShortcutTaskWho
    @Parameter(title: "Due") var due: Date?
    @Parameter(title: "Due Time Matters", default: false) var dueHasTime: Bool
    @Parameter(title: "Start Date") var starts: Date?
    @Parameter(title: "Priority") var priority: ShortcutTaskPriority?
    @Parameter(title: "List") var list: String?
    @Parameter(title: "Tags") var tags: [String]?
    @Parameter(title: "Repeat") var repeatRule: ShortcutTaskRepeat?
    @Parameter(title: "Notes", inputOptions: String.IntentInputOptions(multiline: true)) var notes: String?

    static var parameterSummary: some ParameterSummary {
        When(\.$bot, .hasAnyValue) {
            Summary("Add task \(\.$taskTitle) for \(\.$bot)") {
                \.$who
                \.$due
                \.$dueHasTime
                \.$starts
                \.$priority
                \.$list
                \.$tags
                \.$repeatRule
                \.$notes
            }
        } otherwise: {
            Summary("Add task \(\.$taskTitle)") {
                \.$bot
                \.$due
                \.$dueHasTime
                \.$starts
                \.$priority
                \.$list
                \.$tags
                \.$repeatRule
                \.$notes
            }
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let title = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw AskBotError.message("Give the task a title.") }
        var profile: String?
        if let bot {
            guard let record = VoiceBotCatalog.resolve(id: bot.id), let id = VoiceBotCatalog.profile(key: record.key) else {
                throw VoiceNoteError.unavailableBot
            }
            profile = id
        }
        var sectionID: String?
        if let rawList = list?.trimmingCharacters(in: .whitespacesAndNewlines), !rawList.isEmpty {
            if let answer = try? await ShortcutGateway.send("GET", TasksAPI.base, what: "your tasks"),
               let decoded = try? JSONDecoder().decode(TodoListAnswer.self, from: answer.data),
               let sections = decoded.sections {
                sectionID = sections.first { $0.id == rawList || $0.name.localizedCaseInsensitiveCompare(rawList) == .orderedSame }?.id
            }
        }
        let body = ShortcutTaskBody.make(title: title, bot: profile, who: who.wire, due: due, hasTime: dueHasTime,
                                         notes: notes ?? "", priority: priority?.wire, starts: starts,
                                         tags: tags ?? [], repeatRule: repeatRule?.rawValue, section: sectionID)
        let answer = try await ShortcutGateway.send("POST", TasksAPI.base, json: body, what: "the task")
        let made = (try? TasksAPI.task(answer.data))?.title ?? title
        await ShortcutTasksSync.refreshAfterWrite()
        AppLog.note("intents", "Add Task shortcut: added\(profile == nil ? "" : " for a bot")")
        return .result(value: made, dialog: IntentDialog(stringLiteral: "Added “\(made)” to Tasks."))
    }
}

/// Lists open tasks from Hermes HQ without opening the app.
struct GetTasksIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Tasks"
    static let description: IntentDescription? = IntentDescription(
        "Get your open tasks from Hermes HQ, optionally filtered by view or search text.",
        categoryName: "Tasks")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "View", default: .today) var view: ShortcutTasksFilter
    @Parameter(title: "Search") var query: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$view) tasks") { \.$query }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let answer = try await ShortcutGateway.send("GET", TasksAPI.base, what: "your tasks")
        let decoded = try JSONDecoder().decode(TodoListAnswer.self, from: answer.data)
        let titles = ShortcutTasksQuery.titles(from: decoded, view: view, query: query ?? "", now: Date())
        let spoken: String
        if titles.isEmpty {
            spoken = "You have no matching tasks."
        } else {
            spoken = "You have \(titles.count) task\(titles.count == 1 ? "" : "s"): \(titles.prefix(5).joined(separator: ", "))."
        }
        return .result(value: titles, dialog: IntentDialog(stringLiteral: spoken))
    }
}

/// Marks a matching open task done without opening Hermes HQ.
struct CompleteTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete Task"
    static let description: IntentDescription? = IntentDescription(
        "Mark an open task done in Hermes HQ by its title or ID.",
        categoryName: "Tasks")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Task") var taskName: String

    static var parameterSummary: some ParameterSummary {
        Summary("Complete task \(\.$taskName)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let clean = taskName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw AskBotError.message("Name the task to complete.") }
        let listAnswer = try await ShortcutGateway.send("GET", TasksAPI.base, what: "your tasks")
        let decoded = try JSONDecoder().decode(TodoListAnswer.self, from: listAnswer.data)
        guard let target = ShortcutTasksQuery.matchOpen(clean, in: decoded.tasks ?? []) else {
            throw AskBotError.message("Couldn’t find an open task matching “\(clean)”.")
        }
        let body = try JSONValue.object(["rev": .number(Double(target.rev)), "status": .string("done")]).encoded()
        _ = try await ShortcutGateway.send("PATCH", TasksAPI.base + "/" + PagesREST.segment(target.id), json: body, what: "the task")
        await ShortcutTasksSync.refreshAfterWrite()
        AppLog.note("intents", "Complete Task shortcut: marked done")
        return .result(value: target.title, dialog: IntentDialog(stringLiteral: "Marked “\(target.title)” done."))
    }
}

/// Refreshes the in-process `TasksStore` (local reminders) and Tasks widget after a Shortcut/Siri write.
@MainActor enum ShortcutTasksSync {
    static func refreshAfterWrite() async {
        if let store = TasksHub.current {
            await store.refresh(force: true)
            _ = TasksWidgetWriter.shared.write(reason: "shortcut")
        } else {
            await TasksWidgetWriter.shared.refreshHeadless(reason: "shortcut")
        }
    }
}

/// Pure query helpers for `GetTasksIntent` and `CompleteTaskIntent` (tested directly).
nonisolated enum ShortcutTasksQuery {
    static func titles(from answer: TodoListAnswer, view: ShortcutTasksFilter, query: String,
                       now: Date, calendar: Calendar = .current) -> [String] {
        let all = TodoSections.filtered(answer.tasks ?? [], scope: "all", query: query, goals: answer.goals ?? [])
        let sections = answer.sections ?? []
        let open: [TodoTask]
        switch view {
        case .today:
            open = TodoViews.groups(all, view: .today, sections: sections, now: now, calendar: calendar)
                .filter { $0.kind != .done }.flatMap(\.tasks)
        case .upcoming:
            open = TodoViews.groups(all, view: .upcoming, sections: sections, now: now, calendar: calendar)
                .filter { $0.kind != .done }.flatMap(\.tasks)
        case .inbox:
            open = TodoViews.groups(all, view: .inbox, sections: sections, now: now, calendar: calendar)
                .filter { $0.kind != .done }.flatMap(\.tasks)
        case .all:
            open = all.filter { !$0.isDone }
        }
        return open.map(\.title)
    }

    static func matchOpen(_ query: String, in tasks: [TodoTask]) -> TodoTask? {
        let open = tasks.filter { !$0.isDone }
        if let exactID = open.first(where: { $0.id == query }) { return exactID }
        if let exact = open.first(where: { $0.title.localizedCaseInsensitiveCompare(query) == .orderedSame }) { return exact }
        return open.first(where: { $0.title.localizedCaseInsensitiveContains(query) })
    }
}

/// The New Task sheet's body for a shortcut's task (pure: the tests read it).
nonisolated enum ShortcutTaskBody {
    static func make(title: String, bot: String?, who: TodoWho, due: Date?, hasTime: Bool, notes: String,
                     priority: Int? = nil, starts: Date? = nil, tags: [String] = [], repeatRule: String? = nil,
                     section: String? = nil, calendar: Calendar = .current) -> Data {
        var fields = TodoWire.newTask(title: title, who: bot == nil ? .me : who, bot: bot,
                                      due: due.map { TodoDates.wire($0, hasTime: hasTime, calendar: calendar) },
                                      repeatRule: repeatRule, prep: false,
                                      notes: notes.trimmingCharacters(in: .whitespacesAndNewlines), source: TodoSource(kind: "app"))
        if let priority, (1...3).contains(priority) { fields["priority"] = .number(Double(priority)) }
        if let starts { fields["starts"] = .string(TodoDates.wire(starts, hasTime: false, calendar: calendar)) }
        let keptTags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !keptTags.isEmpty { fields["tags"] = .array(keptTags.map(JSONValue.string)) }
        if let section, !section.isEmpty { fields["section"] = .string(section) }
        return (try? JSONValue.object(fields).encoded()) ?? Data()
    }
}

// MARK: - Run Job

nonisolated struct ShortcutJob: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Job")
    static let defaultQuery = ShortcutJobQuery()
    /// `<owner>|<id>`.
    let id: String
    let name: String
    let owner: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ record: JobShortcutRecord) {
        id = record.key
        name = record.name
        owner = record.owner
    }
}

nonisolated struct ShortcutJobQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ShortcutJob] {
        let all = JobShortcutCatalog.jobs()
        return identifiers.compactMap { id in all.first { $0.key == id }.map(ShortcutJob.init) }
    }

    func suggestedEntities() async throws -> [ShortcutJob] { JobShortcutCatalog.jobs().map(ShortcutJob.init) }

    func entities(matching string: String) async throws -> [ShortcutJob] {
        JobShortcutCatalog.jobs().filter { $0.name.localizedCaseInsensitiveContains(string) }.map(ShortcutJob.init)
    }
}

struct RunJobIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Job"
    static let description: IntentDescription? = IntentDescription(
        "Run one of your jobs now, without opening Hermes HQ. Its schedule doesn’t change. Turn on Wait for Result to get what the run wrote for the next action.",
        categoryName: "Jobs")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Job") var job: ShortcutJob
    @Parameter(title: "Wait for Result", default: true) var waitForResult: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$job)") { \.$waitForResult }
    }

    /// How long Run Now waits for a run (the app's Run Now waits 120 s; a shortcut gets a little less).
    static let runWait: TimeInterval = 110

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let record = JobShortcutCatalog.jobs().first(where: { $0.key == job.id }) else {
            throw AskBotError.message("That job isn’t in Hermes HQ any more. Open Jobs so the list updates, then pick it again.")
        }
        let ran = try await Self.run(record, wait: waitForResult)
        return .result(value: ran.value, dialog: IntentDialog(stringLiteral: ran.said))
    }

    /// [quick-actions] Run Now's calls for `record`: this intent's road, and a Quick Actions Run Job tile's (I22, no
    /// wait). `value` is the run's words for a shortcut's next step (empty without waiting); `said` is the sentence. A
    /// refusal throws the gateway's own words (`ShortcutGateway.refusal`).
    static func run(_ record: JobShortcutRecord, wait: Bool) async throws -> (value: String, said: String) {
        let path = CronRunOnce.jobPath(record.id)
        let owner = [URLQueryItem(name: "profile", value: record.owner)]
        let before = try await ShortcutGateway.send("GET", path, query: owner, what: "the job")
        guard let state = try? JSONValue.parse(before.data) else { throw AskBotError.message("Your gateway answered in a way Hermes HQ doesn’t understand.") }
        let paused = state["enabled"]?.bool == false || state["state"]?.string == "paused"
        let started = Date().timeIntervalSince1970
        let trigger = await Result.of {
            try await ShortcutGateway.send("POST", path + "/trigger", query: owner, what: "the job",
                                           timeout: wait ? Self.runWait : 15)
        }
        // Run Now's rule: a paused job runs once and stays paused.
        if paused { _ = try? await ShortcutGateway.send("POST", path + "/pause", query: owner, what: "the job") }
        switch trigger {
        case .success:
            break
        case .failure(let error):
            if case ShareFailure.timedOut = error, wait {
                AppLog.note("intents", "Run Job shortcut: still running")
                return ("", "“\(record.name)” is still running. Its result will be in Jobs.")
            }
            if !wait, case ShareFailure.timedOut = error { return ("", "Started “\(record.name)”.") }
            throw error
        }
        AppLog.note("intents", "Run Job shortcut: ran")
        guard wait else { return ("", "Started “\(record.name)”.") }
        let runs = try? await ShortcutGateway.send("GET", path + "/runs", query: owner + [URLQueryItem(name: "limit", value: "5")], what: "the job")
        let list = runs.flatMap { try? JSONValue.parse($0.data) }.map(CronRun.list) ?? []
        let text = JobShortcutCatalog.resultText(runs: list, startedAfter: started, job: record.name)
        return (text, text)
    }
}

// MARK: - The gateway, with no app

nonisolated enum ShortcutGateway {
    /// One request as a share makes it; a refusal is worded for a shortcut (the gateway's own reason when it gave one).
    static func send(_ method: String, _ path: String, query: [URLQueryItem] = [], json: Data? = nil, what: String,
                     timeout: TimeInterval = 30) async throws -> ShareRESTAnswer {
        let roster = AskRoster.read()
        let outcome = await Result.of {
            try await ShareSender().rest(method, path, query: query, json: json, roster: roster, timeout: timeout)
        }
        let answer: ShareRESTAnswer
        switch outcome {
        case .success(let got): answer = got
        case .failure(let failure as ShareFailure):
            if case .timedOut = failure { throw failure }
            throw AskBotError.words(failure, bot: "")
        case .failure(let error): throw error
        }
        guard answer.ok else { throw AskBotError.message(refusal(answer, what: what)) }
        return answer
    }

    /// The gateway's `detail`, else a sentence for the status (pure: the tests read it).
    static func refusal(_ answer: ShareRESTAnswer, what: String) -> String {
        if answer.status == 404 { return "Your gateway doesn’t have \(what). Update the Hermes HQ add-on, or open Hermes HQ to check." }
        if let value = try? JSONValue.parse(answer.data) {
            if let text = value["detail"]?.string, !text.isEmpty { return text }
            if let text = value["detail"]?["message"]?.string, !text.isEmpty { return text }
            if let text = value["error"]?.string, !text.isEmpty { return text }
        }
        if answer.status == 409 { return "That’s already running." }
        return "Your gateway didn’t accept \(what) (\(answer.status))."
    }
}
