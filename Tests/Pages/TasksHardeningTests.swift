// Hardening tests for Tasks: serialized per-task writes & edit-token rollbacks, 3-way step merges,
// persistent offline write queue, delete in-flight protection, answerOffer refresh, thread-safe TodoDates,
// TodoQuickParse false-positive guards, TaskReminders 60-cap sorting, TasksWidget Goal marks, and Shortcuts queries.

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

@MainActor
struct TasksHardeningTests {
    nonisolated private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        c.locale = Locale(identifier: "en_US")
        return c
    }()
    /// Wednesday 2026-11-04, 09:41 in Chicago.
    nonisolated private static let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 9, minute: 41))!

    private nonisolated static func makeTask(
        _ id: String,
        _ title: String = "Task",
        who: String = "me",
        bot: String? = nil,
        status: String = "open",
        due: String? = nil,
        starts: String? = nil,
        section: String? = nil,
        goal: String? = nil,
        priority: Int = 0,
        rev: Int = 3,
        steps: [(String, String, Bool)] = []
    ) -> TodoTask {
        var o: [String: JSONValue] = [
            "id": .string(id),
            "rev": .number(Double(rev)),
            "title": .string(title),
            "who": .string(who),
            "status": .string(status),
            "priority": .number(Double(priority)),
            "updated_at": .string("2026-11-04T08:00:00-06:00"),
            "created_at": .string("2026-11-03T08:00:00-06:00"),
        ]
        if let bot { o["bot"] = .string(bot) }
        if let due { o["due"] = .string(due) }
        if let starts { o["starts"] = .string(starts) }
        if let section { o["section"] = .string(section) }
        if let goal { o["goal"] = .string(goal) }
        o["steps"] = .array(steps.map {
            .object(["id": .string($0.0), "title": .string($0.1), "who": .string("me"), "done": .bool($0.2)])
        })
        return try! JSONDecoder().decode(TodoTask.self, from: JSONValue.object(o).encoded())
    }

    private nonisolated static func wire(_ task: TodoTask) -> JSONValue {
        try! JSONValue.parse(JSONEncoder().encode(task))
    }

    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "tasks-hardening-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: 1. Serialized per-task writes & edit-token rollback guard

    @Test func concurrentPatchesSerializeWithFreshRevsAndNeverClobberNewerEdits() async throws {
        let base = Self.makeTask("t_1", "Draft brief", priority: 0, rev: 3)
        let client = PagesFakeClient { _ in .object(["rev": 1, "tasks": .array([Self.wire(base)])]) }
        let store = TasksStore(api: TasksAPI(client: client), account: client.account, directory: nil)
        await store.refresh()

        let revsSeen = Mutex<[Int]>([])
        client.respond { request in
            guard request.method == "PATCH" else { return .object([:]) }
            let rev = ActivityJSON.int(request.body?["rev"]) ?? 0
            revsSeen.withLock { $0.append(rev) }
            if request.body?["notes"]?.string == "First note" {
                try await Task.sleep(for: .milliseconds(150))
                throw httpError(500, "boom")
            }
            var updated = Self.makeTask("t_1", "Draft brief", priority: 1, rev: rev + 1)
            updated.notes = ""
            return Self.wire(updated)
        }

        let first = Task { await store.patch("t_1", ["notes": .string("First note")]) }
        try await Task.sleep(for: .milliseconds(25))
        let second = Task { await store.patch("t_1", ["priority": .number(1)]) }

        #expect(await first.value == false)
        #expect(await second.value == true)
        #expect(store.task("t_1")?.priority == 1, "failed earlier write must not clobber newer optimistic edit")
        #expect(store.task("t_1")?.notes == "", "failed field was rolled back cleanly")
        #expect(revsSeen.withLock { $0 } == [3, 3])
    }

    @Test func failedSaveSectionsPreservesUnrelatedTaskEdits() async throws {
        let one = Self.makeTask("t_1", "Task 1", section: "s_work", rev: 1)
        let two = Self.makeTask("t_2", "Task 2", section: nil, rev: 1)
        let client = PagesFakeClient { _ in
            .object([
                "rev": 1,
                "tasks": .array([Self.wire(one), Self.wire(two)]),
                "sections": .array([.object(["id": "s_work", "name": "Work"])]),
            ])
        }
        let store = TasksStore(api: TasksAPI(client: client), account: client.account, directory: nil)
        await store.refresh()

        client.respond { request in
            if request.method == "PUT" {
                try await Task.sleep(for: .milliseconds(150))
                throw httpError(500, "boom")
            }
            if request.method == "PATCH" {
                return Self.wire(Self.makeTask("t_2", "Renamed Task 2", section: nil, rev: 2))
            }
            return .object(["rev": 1, "tasks": .array([Self.wire(one), Self.wire(two)])])
        }

        let saveSec = Task { await store.saveSections([]) }
        try await Task.sleep(for: .milliseconds(25))
        #expect(await store.patch("t_2", ["title": .string("Renamed Task 2")]))
        #expect(await saveSec.value == nil)
        #expect(store.task("t_1")?.section == "s_work", "cleared section was restored")
        #expect(store.task("t_2")?.title == "Renamed Task 2", "unrelated task edit survived saveSections rollback")
    }

    // MARK: 2. Delete in-flight protection

    @Test func refreshDuringInFlightDeleteNeverResurrectsTask() async throws {
        let one = Self.makeTask("t_1", "Delete me", rev: 1)
        let client = PagesFakeClient { _ in .object(["rev": 1, "tasks": .array([Self.wire(one)])]) }
        let store = TasksStore(api: TasksAPI(client: client), account: client.account, directory: nil)
        await store.refresh()

        client.respond { request in
            if request.method == "DELETE" {
                try await Task.sleep(for: .milliseconds(200))
                return .object(["ok": true])
            }
            return .object(["rev": 2, "tasks": .array([Self.wire(one)])])
        }

        let del = Task { await store.delete("t_1") }
        try await Task.sleep(for: .milliseconds(30))
        await store.refresh(force: true)
        #expect(store.task("t_1") == nil, "concurrent refresh must not resurrect a task being deleted")
        #expect(await del.value == true)
        #expect(store.task("t_1") == nil)
    }

    // MARK: 3. answerOffer refreshes offers cleanly

    @Test func answerOfferUpdatesOffersInForcedRefresh() async throws {
        let offer1: JSONValue = [
            "id": "o_1", "bot": "otto", "session_id": "s1", "at": "2026-11-04T09:00:00Z",
            "list": "Errands", "new": true, "state": "new",
            "tasks": [["title": "Buy milk", "who": "me"]],
        ]
        let offer2: JSONValue = [
            "id": "o_2", "bot": "ivy", "session_id": "s2", "at": "2026-11-04T09:05:00Z",
            "list": "Home", "new": true, "state": "new",
            "tasks": [["title": "Fix shelf", "who": "me"]],
        ]
        let acceptedOffer1: JSONValue = [
            "id": "o_1", "bot": "otto", "session_id": "s1", "at": "2026-11-04T09:00:00Z",
            "list": "Errands", "new": true, "state": "accepted",
            "tasks": [["title": "Buy milk", "who": "me"]],
        ]
        let client = PagesFakeClient { _ in
            .object(["rev": 1, "tasks": [], "sections": [], "lists": true, "offers": [offer1]])
        }
        let store = TasksStore(api: TasksAPI(client: client), account: client.account, directory: nil)
        await store.refresh()
        #expect(store.offers.map(\.id) == ["o_1"])

        client.respond { request in
            if request.method == "POST" {
                return .object(["rev": 2, "offer": acceptedOffer1, "sections": []])
            }
            return .object(["rev": 2, "tasks": [], "sections": [], "lists": true, "offers": [acceptedOffer1, offer2]])
        }
        #expect(await store.answerOffer("o_1", .accept))
        #expect(store.offers.map(\.id) == ["o_1", "o_2"], "forced refresh after answerOffer must adopt updated offers")
    }

    // MARK: 4. 3-way step merge on 409

    @Test func threeWayStepMergeResolvesNonConflictingStepTicks() throws {
        let baseSteps = [
            TodoStep(id: "s1", title: "Step 1", who: "me", done: false),
            TodoStep(id: "s2", title: "Step 2", who: "bot", done: false),
        ]
        let remoteSteps = [
            TodoStep(id: "s1", title: "Step 1", who: "me", done: false),
            TodoStep(id: "s2", title: "Step 2", who: "bot", done: true),
            TodoStep(id: "s3", title: "Bot added", who: "bot", done: false),
        ]
        let ourSteps = [
            TodoStep(id: "s1", title: "Step 1", who: "me", done: true),
            TodoStep(id: "s2", title: "Step 2", who: "bot", done: false),
        ]
        let merged = try #require(TodoEdits.mergeSteps(base: baseSteps, current: remoteSteps, ours: ourSteps))
        #expect(merged.map(\.id) == ["s1", "s2", "s3"])
        #expect(merged[0].done == true && merged[1].done == true && merged[2].done == false)

        // Conflicting edit on the same step returns nil.
        let conflictOurs = [
            TodoStep(id: "s1", title: "Step 1", who: "me", done: false),
            TodoStep(id: "s2", title: "Renamed locally", who: "bot", done: false),
        ]
        let conflictRemote = [
            TodoStep(id: "s1", title: "Step 1", who: "me", done: false),
            TodoStep(id: "s2", title: "Renamed remotely", who: "bot", done: false),
        ]
        #expect(TodoEdits.mergeSteps(base: baseSteps, current: conflictRemote, ours: conflictOurs) == nil)
    }

    // MARK: 5. Persistent offline write queue

    @Test func offlineWritesPersistAcrossRestartAndReplayOnReconnect() async throws {
        let dir = scratch()
        let existing = Self.makeTask("t_1", "Existing task", rev: 2)
        let client = PagesFakeClient { _ in .object(["rev": 1, "tasks": .array([Self.wire(existing)])]) }
        let store1 = TasksStore(api: TasksAPI(client: client), account: client.account, directory: dir)
        await store1.refresh()

        // Go offline (transport error, not HTTP 500).
        client.respond { _ in throw URLError(.notConnectedToInternet) }
        let added = await store1.add(TodoWire.newTask(title: "Offline milk", who: .me, bot: nil, due: nil, repeatRule: nil, prep: false))
        let localID = try #require(added?.id)
        #expect(TodoIDs.isLocal(localID))
        #expect(store1.pendingCount == 1)

        // Edit the offline-added task: folds into the pending add.
        #expect(await store1.patch(localID, ["title": .string("Offline oat milk")]))
        #expect(store1.pendingCount == 1)
        #expect(store1.task(localID)?.title == "Offline oat milk")

        // Also mark existing task done offline.
        #expect(await store1.setDone("t_1", true))
        #expect(store1.pendingCount == 2)
        #expect(store1.task("t_1")?.isDone == true)
        PagesCache.flush()

        // Relaunch store from disk and come back online.
        let serverNew = Self.makeTask("t_server_new", "Offline oat milk", rev: 1)
        var serverDoneDraft = existing
        serverDoneDraft.status = "done"
        serverDoneDraft.rev = 3
        let serverDone = serverDoneDraft
        let onlineClient = PagesFakeClient { request in
            if request.method == "POST" {
                #expect(request.body?["title"]?.string == "Offline oat milk")
                return Self.wire(serverNew)
            }
            if request.method == "PATCH" {
                #expect(request.body?["status"]?.string == "done")
                return Self.wire(serverDone)
            }
            return .object(["rev": 4, "tasks": .array([Self.wire(serverDone), Self.wire(serverNew)])])
        }
        let store2 = TasksStore(api: TasksAPI(client: onlineClient), account: onlineClient.account, directory: dir)
        store2.prepare()
        #expect(store2.pendingCount == 2)
        await store2.refresh(force: true)
        #expect(store2.pendingCount == 0)
        #expect(Set(store2.tasks.map(\.id)) == ["t_1", "t_server_new"])
        #expect(store2.task("t_1")?.isDone == true)
    }

    // MARK: 6. Thread-safe TodoDates

    @Test func todoDatesMomentAndFormatAreThreadSafe() async {
        let stamps = [
            "2026-11-05T16:30:00Z",
            "2026-11-05T16:30:00.250Z",
            "2026-11-05T10:30:00-06:00",
            "2026-11-05T16:30:00",
        ]
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<40 {
                group.addTask {
                    let s = stamps[i % stamps.count]
                    let parsed = TodoDates.moment(s)
                    let formatted = TodoDates.format(Self.now, template: "jmm", calendar: Self.calendar)
                    return parsed != nil && !formatted.isEmpty
                }
            }
            for await ok in group {
                #expect(ok)
            }
        }
    }

    // MARK: 7. TodoQuickParse false-positive guards

    @Test func quickParseAvoidsCommonFalsePositives() {
        for phrase in [
            "Send weekly report",
            "Pay monthly rent",
            "Study for SAT",
            "Buy 1/2 gallon milk",
            "Cut 3/4 inch trim",
            "Buy 2a fuses",
        ] {
            let parsed = TodoQuickParse.read(phrase, now: Self.now, calendar: Self.calendar)
            #expect(parsed.title == phrase && parsed.due == nil && parsed.repeatRule == nil, "\(phrase) → \(parsed)")
        }
        // Legitimate forms still work.
        let trailingRepeat = TodoQuickParse.read("Send report weekly", now: Self.now, calendar: Self.calendar)
        #expect(trailingRepeat.title == "Send report" && trailingRepeat.repeatRule == "weekly")
        let minuteSuffix = TodoQuickParse.read("Sync tomorrow 9:30a", now: Self.now, calendar: Self.calendar)
        #expect(minuteSuffix.title == "Sync" && minuteSuffix.hasTime)
    }

    // MARK: 8. TodoWire.newTask repeating together tasks

    @Test func newTaskKeepsRepeatForTogetherAndDropsForBotOnly() {
        let together = TodoWire.newTask(title: "Review metrics", who: .together, bot: "otto", due: "2026-11-05", repeatRule: "weekly", prep: false)
        #expect(together["repeat"]?.string == "weekly")
        let botOnly = TodoWire.newTask(title: "Sync logs", who: .bot, bot: "otto", due: "2026-11-05", repeatRule: "weekly", prep: false)
        #expect(botOnly["repeat"] == .null)
    }

    // MARK: 9. TaskReminders 60-cap & soonest sorting

    @Test func taskRemindersSelectSortsSoonestAndCapsAtMaxPending() {
        var tasks: [TodoTask] = []
        for day in (1...80).reversed() {
            let dueDate = Self.calendar.date(byAdding: .day, value: day, to: Self.now)!
            tasks.append(Self.makeTask("t_\(day)", "Task \(day)", due: TodoDates.wire(dueDate, hasTime: false, calendar: Self.calendar)))
        }
        let selected = TaskReminders.select(tasks, now: Self.now, limit: TaskReminders.maxPending, calendar: Self.calendar)
        #expect(selected.count == TaskReminders.maxPending)
        #expect(selected.first?.task.id == "t_1")
        #expect(selected.last?.task.id == "t_\(TaskReminders.maxPending)")
        #expect(TaskReminders.accountPrefix("acct1") == "hq.task.acct1.")
    }

    // MARK: 10. TasksWidget Goal marks & start-day moments

    @Test func tasksWidgetShowsGoalMarkInsteadOfListDotAndTracksStartDays() throws {
        let activeGoal = try JSONDecoder().decode(Goal.self, from: Data(#"""
            {"id":"g_1","rev":1,"title":"Run 5K","status":"active","color":"teal","position":1,"created_at":"2026-11-01T00:00:00Z","updated_at":"2026-11-01T00:00:00Z"}
            """#.utf8))
        let taskInGoal = Self.makeTask("t_goal", "Buy shoes", due: "2026-11-04", section: "work", goal: "g_1")
        let startTask = Self.makeTask("t_start", "Begin course", starts: "2026-11-05")
        let sections = [TodoUserSection(id: "work", name: "Work", color: "blue")]
        let input = TasksWidgetWriter.Input(tasks: [taskInGoal, startTask], sections: sections, bots: [], sort: "smart", paused: [], goals: [activeGoal])

        let frame = TasksWidgetWriter.frame(.today, input: input, botName: { _ in "Hermes" }, at: Self.now, calendar: Self.calendar)
        let row = try #require(frame.sections.flatMap(\.rows).first { $0.id == "t_goal" })
        #expect(row.dot == nil, "stale list colour dots are not drawn on the widget")
        #expect(row.goalColor == "teal", "active goal mark carries the goal's colour")

        let moments = TasksWidgetWriter.moments([startTask], now: Self.now, calendar: Self.calendar)
        let startMoment = try #require(TodoDates.day("2026-11-05", calendar: Self.calendar)).addingTimeInterval(1)
        #expect(moments.contains(startMoment))
    }

    // MARK: 11. Shortcuts body & query helpers

    @Test func shortcutTaskBodyAndQuerySupportFullFieldsAndMatching() throws {
        let due = Self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 15))!
        let starts = Self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 6))!
        let data = ShortcutTaskBody.make(
            title: "File taxes", bot: "otto", who: .together, due: due, hasTime: true, notes: "Check receipts",
            priority: 1, starts: starts, tags: ["finance", "q4"], repeatRule: "yearly", section: "s_admin", calendar: Self.calendar
        )
        let json = try JSONValue.parse(data)
        #expect(json["priority"]?.double == 1)
        #expect(json["starts"]?.string == "2026-11-06")
        #expect(json["tags"] == .array([.string("finance"), .string("q4")]))
        #expect(json["repeat"]?.string == "yearly")
        #expect(json["section"]?.string == "s_admin")

        let open1 = Self.makeTask("t_1", "Pay water bill", due: "2026-11-04")
        let open2 = Self.makeTask("t_2", "Book flights", due: "2026-11-09")
        let done1 = Self.makeTask("t_3", "Pay water bill", status: "done", due: "2026-11-04")
        let answerJSON: JSONValue = .object([
            "rev": 1,
            "tasks": .array([Self.wire(open1), Self.wire(open2), Self.wire(done1)]),
            "sections": .array([]),
        ])
        let listAnswer = try JSONDecoder().decode(TodoListAnswer.self, from: answerJSON.encoded())
        #expect(ShortcutTasksQuery.titles(from: listAnswer, view: .today, query: "", now: Self.now, calendar: Self.calendar) == ["Pay water bill"])
        #expect(ShortcutTasksQuery.titles(from: listAnswer, view: .upcoming, query: "", now: Self.now, calendar: Self.calendar) == ["Book flights"])
        #expect(ShortcutTasksQuery.titles(from: listAnswer, view: .all, query: "flight", now: Self.now, calendar: Self.calendar) == ["Book flights"])
        #expect(ShortcutTasksQuery.matchOpen("water", in: [done1, open1, open2])?.id == "t_1")
        #expect(ShortcutTasksQuery.matchOpen("t_2", in: [open1, open2])?.id == "t_2")
    }
}
