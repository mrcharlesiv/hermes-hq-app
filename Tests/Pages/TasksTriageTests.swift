// Unit tests for the Tasks upgrades:
// 1. Today & Overdue triage (priority tiebreak, Sort By in Today & Inbox, bulk reschedule/priority/goal, duplicate).
// 2. Upcoming multi-week titles, drag-to-day time-preserving reschedule, Priority/Tag filters, allTags, Completed Logbook.
// 3. Task detail inline step editing, step reordering, step promotion, TaskTagPickerModel, and custom repeat labels/gating.

import Foundation
import Synchronization
import Testing
import UIKit
@testable import HermesHQNative

@MainActor private final class TriageFakePages: PagesServices {
    let client: PagesFakeClient
    init(_ client: PagesFakeClient) { self.client = client }
    var account: GatewayAccount? { client.account }
    var gateway: (any GatewayClient)? { client }
    var bots: [Bot] { [] }
    var readOnlyGateway: Bool { false }
    func chat(for session: SessionSummary) -> ChatSessionModel { fatalError("not opened here") }
    var onSignOutPages: (() -> Void)?
}

@MainActor
struct TasksTriageTests {
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        c.locale = Locale(identifier: "en_US")
        return c
    }()
    /// Wednesday 2026-11-18, 10:00 in Chicago.
    private static let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 10, minute: 0))!

    private nonisolated static func makeTask(
        _ id: String,
        _ title: String = "",
        who: String = "me",
        bot: String? = nil,
        status: String = "open",
        due: String? = nil,
        starts: String? = nil,
        section: String? = nil,
        goal: String? = nil,
        milestone: String? = nil,
        priority: Int = 0,
        tags: [String] = [],
        notes: String = "",
        repeats: String? = nil,
        alert: Int? = nil,
        position: Double = 0,
        rev: Int = 2,
        created: String = "2026-11-10T08:00:00-06:00",
        updated: String = "2026-11-18T08:00:00-06:00",
        doneAt: String? = nil,
        steps: [(String, String, String, Bool)] = []
    ) -> TodoTask {
        var o: [String: JSONValue] = [
            "id": .string(id),
            "rev": .number(Double(rev)),
            "title": .string(title.isEmpty ? id : title),
            "who": .string(who),
            "status": .string(status),
            "priority": .number(Double(priority)),
            "notes": .string(notes),
            "position": .number(position),
            "created_at": .string(created),
            "updated_at": .string(updated),
        ]
        if let bot { o["bot"] = .string(bot) }
        if let due { o["due"] = .string(due) }
        if let starts { o["starts"] = .string(starts) }
        if let section { o["section"] = .string(section) }
        if let goal { o["goal"] = .string(goal) }
        if let milestone { o["milestone"] = .string(milestone) }
        if !tags.isEmpty { o["tags"] = .array(tags.map(JSONValue.string)) }
        if let repeats { o["repeat"] = .string(repeats) }
        if let alert { o["alert"] = .number(Double(alert)) }
        if let doneAt { o["done_at"] = .string(doneAt) }
        o["steps"] = .array(steps.map {
            .object(["id": .string($0.0), "title": .string($0.1), "who": .string($0.2), "done": .bool($0.3)])
        })
        return try! JSONDecoder().decode(TodoTask.self, from: JSONValue.object(o).encoded())
    }

    private nonisolated static func wire(_ task: TodoTask) -> JSONValue {
        try! JSONValue.parse(JSONEncoder().encode(task))
    }

    // MARK: Board 1 — Today Priority Tiebreak, Sort By, Bulk Actions & Duplicate

    @Test func todayDefaultOrderElevatesHighAndMediumPriorityThenManualOrder() {
        let tasks = [
            Self.makeTask("plain-early", due: "2026-11-18T09:00:00-06:00", priority: 0, position: 1),
            Self.makeTask("med", due: "2026-11-18", priority: 2, position: 2),
            Self.makeTask("high-b", due: "2026-11-18", priority: 1, position: 5),
            Self.makeTask("high-a", due: "2026-11-18", priority: 1, position: 1),
            Self.makeTask("low", due: "2026-11-18", priority: 3, position: 0.5),
        ]
        let today = TodoViews.groups(tasks, view: .today, now: Self.now, sort: "smart", calendar: Self.calendar)
            .first { $0.kind == .today }?.tasks.map(\.id)
        #expect(today == ["high-a", "high-b", "med", "low", "plain-early"])
    }

    @Test func todayAndInboxRespectSortByOptions() {
        let todayTasks = [
            Self.makeTask("late-clock", due: "2026-11-18T17:00:00-06:00", priority: 1, created: "2026-11-12T08:00:00-06:00"),
            Self.makeTask("early-clock", due: "2026-11-18T09:00:00-06:00", priority: 0, created: "2026-11-15T08:00:00-06:00"),
            Self.makeTask("newest", due: "2026-11-18T14:00:00-06:00", priority: 2, created: "2026-11-18T09:00:00-06:00"),
        ]
        #expect(TodoViews.groups(todayTasks, view: .today, now: Self.now, sort: "due", calendar: Self.calendar)
            .first { $0.kind == .today }?.tasks.map(\.id) == ["early-clock", "newest", "late-clock"])
        #expect(TodoViews.groups(todayTasks, view: .today, now: Self.now, sort: "priority", calendar: Self.calendar)
            .first { $0.kind == .today }?.tasks.map(\.id) == ["late-clock", "newest", "early-clock"])
        #expect(TodoViews.groups(todayTasks, view: .today, now: Self.now, sort: "added", calendar: Self.calendar)
            .first { $0.kind == .today }?.tasks.map(\.id) == ["newest", "early-clock", "late-clock"])

        let inboxTasks = [
            Self.makeTask("none", due: "2026-11-22", priority: 0, created: "2026-11-17T08:00:00-06:00"),
            Self.makeTask("urgent", due: "2026-11-25", priority: 1, created: "2026-11-15T08:00:00-06:00"),
            Self.makeTask("soon", due: "2026-11-19", priority: 2, created: "2026-11-16T08:00:00-06:00"),
        ]
        #expect(TodoViews.groups(inboxTasks, view: .inbox, now: Self.now, sort: "smart", calendar: Self.calendar)
            .first { $0.kind == .open }?.tasks.map(\.id) == ["none", "soon", "urgent"], "default Inbox stays newest-added first")
        #expect(TodoViews.groups(inboxTasks, view: .inbox, now: Self.now, sort: "priority", calendar: Self.calendar)
            .first { $0.kind == .open }?.tasks.map(\.id) == ["urgent", "soon", "none"])
        #expect(TodoViews.groups(inboxTasks, view: .inbox, now: Self.now, sort: "due", calendar: Self.calendar)
            .first { $0.kind == .open }?.tasks.map(\.id) == ["soon", "none", "urgent"])
    }

    @Test func rescheduledDuePreservesClockTimeWhenRequested() throws {
        let target = try #require(Self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 21)))
        let timed = Self.makeTask("timed", due: "2026-11-16T14:30:00-06:00")
        let kept = TodoViews.rescheduledDue(for: timed, onto: target, preserveTime: true, calendar: Self.calendar)
        #expect(kept.hasPrefix("2026-11-21T14:30"))

        let dropped = TodoViews.rescheduledDue(for: timed, onto: target, preserveTime: false, calendar: Self.calendar)
        #expect(dropped == "2026-11-21")

        let dateOnly = Self.makeTask("day", due: "2026-11-16")
        #expect(TodoViews.rescheduledDue(for: dateOnly, onto: target, preserveTime: true, calendar: Self.calendar) == "2026-11-21")
    }

    @Test func storeReschedulePriorityGoalAndDuplicateRoundTrip() async throws {
        let base = Self.makeTask(
            "t_1", "Review launch checklist",
            due: "2026-11-15T16:15:00-06:00",
            section: "work",
            goal: "g_launch",
            milestone: "m_1",
            priority: 2,
            tags: ["launch", "q4"],
            notes: "Double-check screenshots",
            repeats: "weekly",
            alert: 30,
            steps: [("s1", "Check copy", "me", true), ("s2", "Verify builds", "me", false)]
        )
        let patchedBodies = Mutex<[[String: JSONValue]]>([])
        let postedBodies = Mutex<[[String: JSONValue]]>([])
        let client = PagesFakeClient { request in
            if request.method == "GET" {
                return .object([
                    "rev": 1,
                    "fields": true,
                    "custom_repeat": true,
                    "goals": .array([
                        .object(["id": "g_launch", "title": "Launch", "state": "active", "milestones": .array([.object(["id": "m_1", "title": "M1", "done": false])])]),
                        .object(["id": "g_other", "title": "Other", "state": "active", "milestones": .array([.object(["id": "m_2", "title": "M2", "done": false])])]),
                    ]),
                    "tasks": .array([Self.wire(base)]),
                ])
            }
            if request.method == "PATCH", let body = request.body?.object {
                patchedBodies.withLock { $0.append(body) }
                var copy = base
                copy.rev += 1
                if let due = body["due"]?.string { copy.due = due }
                if body["due"] == .null { copy.due = nil }
                if let p = ActivityJSON.int(body["priority"]) { copy.priority = p }
                if let g = body["goal"]?.string { copy.goal = g }
                if body["goal"] == .null { copy.goal = nil }
                return Self.wire(copy)
            }
            if request.method == "POST", let body = request.body?.object {
                postedBodies.withLock { $0.append(body) }
                let copy = Self.makeTask("t_copy", body["title"]?.string ?? "Copy", section: body["section"]?.string,
                                         priority: ActivityJSON.int(body["priority"]) ?? 0)
                return Self.wire(copy)
            }
            return .object([:])
        }
        let store = TasksStore(api: TasksAPI(client: client), account: client.account, directory: nil)
        await store.refresh()
        #expect(store.customRepeatSupported)

        let target = try #require(Self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 20)))
        #expect(await store.reschedule(["t_1"], to: target, preserveTime: true, calendar: Self.calendar))
        #expect(await store.setPriority(["t_1"], priority: 1))
        #expect(await store.setGoal(["t_1"], goal: "g_other", milestone: "m_2"))
        let copy = await store.duplicate("t_1")
        #expect(copy?.id == "t_copy")

        let patches = patchedBodies.withLock { $0 }
        #expect(patches.count == 3)
        #expect((patches[0]["due"]?.string ?? "").hasPrefix("2026-11-20T16:15"), "reschedule preserved original 16:15 time")
        #expect(ActivityJSON.int(patches[1]["priority"]) == 1)
        #expect(patches[2]["goal"]?.string == "g_other" && patches[2]["milestone"]?.string == "m_2")

        let posted = try #require(postedBodies.withLock { $0.first })
        #expect(posted["title"]?.string == "Review launch checklist")
        #expect(posted["notes"]?.string == "Double-check screenshots")
        #expect(posted["section"]?.string == "work")
        #expect(posted["tags"]?.array?.compactMap(\.string) == ["launch", "q4"])
        #expect(ActivityJSON.int(posted["alert"]) == 30)
        // Steps must be duplicated unticked.
        let steps = posted["steps"]?.array ?? []
        #expect(steps.count == 2)
        #expect(steps.allSatisfy { $0.object?["done"]?.bool == false })
    }

    // MARK: New Task Sheet (Roomy chips + Tags + Goal + Starts + Repeat + Who Strip)

    @Test func newTodoModelSupportsTagsGoalStartsRepeatAndFaceStrip() async {
        let posted = Mutex<[[String: JSONValue]]>([])
        let client = PagesFakeClient { request in
            if request.method == "GET" {
                return .object([
                    "rev": 1,
                    "fields": true,
                    "sections": .array([.object(["id": "work", "name": "Work"])]),
                    "goals": .array([.object(["id": "g1", "title": "Ship v2", "state": "active"])]),
                    "tasks": .array([]),
                ])
            }
            if request.method == "POST", let body = request.body?.object {
                posted.withLock { $0.append(body) }
                return Self.wire(Self.makeTask("t_new", body["title"]?.string ?? ""))
            }
            return .object([:])
        }
        let store = TasksStore(api: TasksAPI(client: client), account: client.account, directory: nil)
        await store.refresh()
        let bots = [Bot(id: "otto", name: "Otto", role: nil, preview: nil, lastActive: nil,
                        isWorking: false, unread: false, pinned: false, pinOrder: nil, sectionName: nil,
                        hidden: false, canonicalSessionId: nil, head: nil)]
        let model = NewTodoModel(store: store, bots: bots, preferredBot: nil, section: "work", dueDay: nil)

        #expect(model.who == TodoWho.me)
        model.setWho("otto", alone: false)
        #expect(model.who == TodoWho.together)
        model.repeatRule = "weekly"
        model.setWho("otto", alone: true)
        #expect(model.who == TodoWho.bot && model.repeatNow == nil, "bot-only clears repeat")
        model.setWho(nil, alone: false)

        // Merged parsed tags + manual tag picker override
        model.title = "Write release notes #launch"
        #expect(model.tagsNow == ["launch"])
        model.setTags(["launch", "q4"])
        #expect(model.tagsNow == ["launch", "q4"])
        model.notes = "Include new logbook"
        model.priority = 2
        model.repeatRule = "monthly"
        model.setGoal("g1", milestone: nil)
        model.setStarts(Self.now)

        let created = Mutex<String?>(nil)
        model.onCreated = { (task: TodoTask?) in created.withLock { $0 = task?.id } }
        model.add()
        for _ in 0..<40 where created.withLock({ $0 }) == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(created.withLock { $0 } == "t_new")
        let body = posted.withLock { $0.first }
        #expect(body?["title"]?.string == "Write release notes")
        #expect(body?["notes"]?.string == "Include new logbook")
        #expect(body?["section"]?.string == "work")
        #expect(body?["goal"]?.string == "g1")
        #expect(body?["repeat"]?.string == "monthly")
        #expect(body?["tags"]?.array?.compactMap(\.string) == ["launch", "q4"])
        #expect(ActivityJSON.int(body?["priority"]) == 2)
        #expect(body?["starts"]?.string == "2026-11-18")
        #expect(model.title.isEmpty && model.notes.isEmpty && model.tags.isEmpty && model.goal == nil && model.starts == nil && model.section == "work")
    }

    // MARK: Upcoming Multi-Week, Priority/Tag Filters & Completed Logbook

    @Test func weekRangeTitleFormatsSingleCrossMonthAndCrossYearRanges() throws {
        let sameMonth = [
            try #require(Self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 18))),
            try #require(Self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 24))),
        ]
        #expect(TodoViews.weekRangeTitle(sameMonth, calendar: Self.calendar) == "November 2026")

        let crossMonth = [
            try #require(Self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 28))),
            try #require(Self.calendar.date(from: DateComponents(year: 2026, month: 12, day: 4))),
        ]
        #expect(TodoViews.weekRangeTitle(crossMonth, calendar: Self.calendar) == "Nov – Dec 2026")

        let crossYear = [
            try #require(Self.calendar.date(from: DateComponents(year: 2026, month: 12, day: 29))),
            try #require(Self.calendar.date(from: DateComponents(year: 2027, month: 1, day: 4))),
        ]
        #expect(TodoViews.weekRangeTitle(crossYear, calendar: Self.calendar) == "Dec 2026 – Jan 2027")
    }

    @Test func filteredSupportsPriorityAndTagAndAllTagsCountsFrequency() {
        let tasks = [
            Self.makeTask("a", "Draft Q4 budget", priority: 1, tags: ["finance", "q4"]),
            Self.makeTask("b", "Pay vendor", priority: 2, tags: ["Finance"]),
            Self.makeTask("c", "Order cables", priority: 1, tags: ["office"]),
            Self.makeTask("d", "Archive receipt", status: "done", tags: ["finance", "done-only"]),
        ]
        #expect(TodoSections.filtered(tasks, scope: "all", query: "", priority: 1).map(\.id) == ["a", "c"])
        #expect(TodoSections.filtered(tasks, scope: "all", query: "", tag: "FINANCE").map(\.id) == ["a", "b", "d"])
        #expect(TodoSections.filtered(tasks, scope: "all", query: "", priority: 1, tag: "finance").map(\.id) == ["a"])
        #expect(TodoViews.allTags(in: tasks) == ["finance", "done-only", "office", "q4"], "most-used first, then alphabetical, case-insensitive dedupe")
    }

    @Test func logbookGroupsCompletedTasksChronologicallyAndSearches() {
        let tasks = [
            Self.makeTask("open-one", "Still open", status: "open"),
            Self.makeTask("done-today", "Send contract", status: "done", tags: ["legal"], doneAt: "2026-11-18T09:15:00-06:00"),
            Self.makeTask("done-yesterday", "File receipts", status: "done", doneAt: "2026-11-17T16:00:00-06:00"),
            Self.makeTask("done-week", "Book dentist", status: "done", doneAt: "2026-11-14T11:00:00-06:00"),
            Self.makeTask("done-month", "Renew passport", status: "done", doneAt: "2026-11-02T11:00:00-06:00"),
            Self.makeTask("done-oct", "Autumn cleanup", status: "done", doneAt: "2026-10-12T10:00:00-05:00"),
        ]
        let groups: [TodoLogbookGroup] = TodoViews.logbook(tasks, query: "", now: Self.now, calendar: Self.calendar)
        #expect(groups.map { $0.title } == ["Today", "Yesterday", "This Week", "Earlier This Month", "October 2026"])
        #expect(groups.flatMap { $0.tasks }.map { $0.id } == ["done-today", "done-yesterday", "done-week", "done-month", "done-oct"])

        let searched: [TodoLogbookGroup] = TodoViews.logbook(tasks, query: "legal", now: Self.now, calendar: Self.calendar)
        #expect(searched.count == 1 && searched[0].tasks.map { $0.id } == ["done-today"])
    }

    // MARK: Board 4 — Custom Repeat Labels, Tag Picker & Inline Step Editing/Reordering/Promotion

    @Test func customAndAfterCompletionRepeatLabelsFormatCleanly() throws {
        #expect(TodoWords.repeatLabel("every:2:weeks") == "Every 2 Weeks")
        #expect(TodoWords.repeatLabel("every:1:months") == "Every Month")
        #expect(TodoWords.repeatLabel("after:3:days") == "3 Days After Completion")
        #expect(TodoWords.repeatLabel("after:1:weeks") == "1 Week After Completion")
        #expect(TodoWords.repeatLabel("after:2:months") == "2 Months After Completion")
        let decoded = try JSONDecoder().decode(TodoListAnswer.self, from: Data(#"{"rev": 1, "tasks": [], "custom_repeat": true}"#.utf8))
        #expect(decoded.customRepeat)
        let legacy = try JSONDecoder().decode(TodoListAnswer.self, from: Data(#"{"rev": 1, "tasks": []}"#.utf8))
        #expect(!legacy.customRepeat)
    }

    @Test func tagPickerTogglesFiltersCommitsCommaSeparatedAndCapsAtTen() {
        var saved: [String] = []
        let picker = TaskTagPickerModel(selected: ["money"], existing: ["money", "hiring", "q4", "home"]) { saved = $0 }
        #expect(picker.allKnown == ["money", "hiring", "q4", "home"])
        picker.input = "hi"
        #expect(picker.filteredKnown == ["hiring"])
        picker.toggle("hiring")
        #expect(picker.isSelected("hiring"))
        picker.toggle("money")
        #expect(!picker.isSelected("money"))
        picker.input = "#2026, taxes, hiring"
        picker.commit()
        #expect(saved == ["hiring", "2026", "taxes"])

        // 10-tag cap
        let capped = TaskTagPickerModel(selected: (1...9).map { "t\($0)" }, existing: []) { saved = $0 }
        capped.input = "t10, t11, t12"
        capped.commit()
        #expect(saved.count == 10 && saved.last == "t10")
    }

    @Test func todoSheetModelEditsReordersAndPromotesSteps() async throws {
        let base = Self.makeTask(
            "t_1", "Host dinner",
            section: "home",
            priority: 2,
            tags: ["friends"],
            steps: [
                ("s1", "Plan menu", "me", false),
                ("s2", "Buy groceries", "me", false),
                ("s3", "Set table", "me", true),
            ]
        )
        let lastPatch = Mutex<[String: JSONValue]?>(nil)
        let lastPost = Mutex<[String: JSONValue]?>(nil)
        let client = PagesFakeClient { request in
            if request.method == "GET" {
                return .object(["rev": 1, "fields": true, "tasks": .array([Self.wire(base)])])
            }
            if request.method == "PATCH", let body = request.body?.object {
                lastPatch.withLock { $0 = body }
                var next = base
                next.rev += 1
                if let rawSteps = body["steps"]?.array {
                    next.steps = rawSteps.compactMap { item in
                        guard let obj = item.object, let id = obj["id"]?.string, let title = obj["title"]?.string else { return nil }
                        return TodoStep(id: id, title: title, who: obj["who"]?.string ?? "me", done: obj["done"]?.bool ?? false)
                    }
                }
                return Self.wire(next)
            }
            if request.method == "POST", let body = request.body?.object {
                lastPost.withLock { $0 = body }
                return Self.wire(Self.makeTask("t_promoted", body["title"]?.string ?? ""))
            }
            return .object([:])
        }
        let store = TasksStore(api: TasksAPI(client: client), account: client.account, directory: nil)
        await store.refresh()
        let pages = TriageFakePages(client)
        let context = MorePages.Context(services: FakeAppServices(), pages: pages, client: client, account: client.account,
                                        makeChat: { _ in UIViewController() })
        let model = TodoSheetModel(taskID: "t_1", store: store, context: context)

        // Inline step rename
        let step1 = try #require(store.task("t_1")?.steps.first)
        model.editStep(step1)
        #expect(model.editingStepID == "s1" && model.stepDraft == "Plan menu")
        model.stepDraft = "Plan vegetarian menu"
        model.saveStep()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.editingStepID == nil)
        #expect(store.task("t_1")?.steps.first?.title == "Plan vegetarian menu")

        // Reorder open steps (move s2 above s1; done step s3 stays untouched)
        model.reorderStep(from: "s2", to: "s1")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(store.task("t_1")?.steps.map { $0.id } == ["s2", "s1", "s3"])

        // Promote s2 into a standalone task (inherits section & tags, removes step)
        let step2 = try #require(store.task("t_1")?.steps.first { $0.id == "s2" })
        model.promoteStep(step2)
        for _ in 0..<40 where lastPost.withLock({ $0 }) == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(50))
        let promoted = try #require(lastPost.withLock { $0 })
        #expect(promoted["title"]?.string == "Buy groceries")
        #expect(promoted["section"]?.string == "home")
        #expect(promoted["tags"]?.array?.compactMap(\.string) == ["friends"])
        #expect(store.task("t_1")?.steps.contains(where: { $0.id == "s2" }) == false)
    }
}
