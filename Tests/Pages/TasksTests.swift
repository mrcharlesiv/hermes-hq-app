// [tasks] The Tasks page (docs/tasks.md): its sections and order, the rows' words, the chat card's `tasks_add`
// extract, and the store (cache, optimistic writes, a 409 re-sent or given way to, an add-on without Tasks).

import EventKit
import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

@MainActor
struct TasksTests {
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        c.locale = Locale(identifier: "en_US")
        return c
    }()
    /// 2026-11-04 09:41 in Chicago.
    private static let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 9, minute: 41))!

    private func task(_ id: String, _ title: String = "", who: String = "me", bot: String? = nil, status: String = "open",
                      note: String = "", due: String? = nil, rev: Int = 3, steps: [(String, Bool)] = [],
                      updated: String = "2026-11-04T08:00:00-06:00", created: String = "2026-11-03T08:00:00-06:00",
                      by: String? = nil) -> TodoTask {
        Self.make(id, title, who: who, bot: bot, status: status, note: note, due: due, rev: rev, steps: steps, updated: updated,
                  created: created, by: by)
    }

    private nonisolated static func make(_ id: String, _ title: String = "", who: String = "me", bot: String? = nil, status: String = "open",
                      note: String = "", due: String? = nil, rev: Int = 3, steps: [(String, Bool)] = [],
                      updated: String = "2026-11-04T08:00:00-06:00", created: String = "2026-11-03T08:00:00-06:00",
                      by: String? = nil) -> TodoTask {
        var o: [String: JSONValue] = ["id": .string(id), "rev": .number(Double(rev)), "title": .string(title.isEmpty ? id : title),
                                      "who": .string(who), "status": .string(status), "status_note": .string(note),
                                      "updated_at": .string(updated), "created_at": .string(created)]
        if let bot { o["bot"] = .string(bot) }
        if let due { o["due"] = .string(due) }
        if let by { o["created_by"] = .string(by) }
        o["steps"] = .array(steps.enumerated().map { .object(["id": .string("s\($0.offset)"), "title": .string($0.element.0),
                                                               "who": "bot", "done": .bool($0.element.1)]) })
        return try! JSONDecoder().decode(TodoTask.self, from: JSONValue.object(o).encoded())
    }

    private func json(_ task: TodoTask) -> JSONValue { Self.wire(task) }
    private nonisolated static func wire(_ task: TodoTask) -> JSONValue { try! JSONValue.parse(JSONEncoder().encode(task)) }

    // MARK: Sections

    @Test func whereATaskStands() {
        let list = [
            task("cleaning", due: "2026-11-04T18:00:00-06:00"),
            task("invoices", who: "bot", bot: "finance", status: "working", due: "2026-11-05"),
            task("venues", who: "bot", bot: "research", status: "needs_you"),
            task("dentist", who: "together", bot: "default", status: "ready", due: "2026-11-04"),
            task("gift", who: "together", bot: "default", due: "2026-11-12"),
            task("late", due: "2026-11-01"),
            task("porch"),
            task("water", status: "done"),
            task("passport", who: "together", bot: "default", status: "working", due: "2026-11-04"),
        ]
        // Where each stands (the Mac table's status words go by it; the page's own order is TodoViewsTests').
        let ids = Dictionary(grouping: list) { TodoSections.section($0, now: Self.now, calendar: Self.calendar) }.mapValues { Set($0.map(\.id)) }
        #expect(ids[.ready] == ["dentist"])
        #expect(ids[.needsYou] == ["venues"], "a bot's question is yours, above its other work")
        #expect(ids[.today] == ["cleaning", "passport"])
        #expect(ids[.bots] == ["invoices"])
        #expect(ids[.upcoming] == ["gift"])
        #expect(ids[.noDate] == ["porch"])
        #expect(ids[.overdue] == ["late"])
        #expect(ids[.done] == ["water"])
    }

    @Test func readyIsNewestFirstAndBotsWorkingFirst() {
        let older = task("a", status: "ready", updated: "2026-11-04T07:00:00-06:00")
        let newer = task("b", status: "ready", updated: "2026-11-04T09:00:00-06:00")
        #expect(TodoSections.sorted([older, newer], in: .ready, calendar: Self.calendar).map(\.id) == ["b", "a"])
        let idle = task("idle", who: "bot", bot: "finance", due: "2026-11-05")
        let busy = task("busy", who: "bot", bot: "finance", status: "working", due: "2026-11-09")
        #expect(TodoSections.sorted([idle, busy], in: .bots, calendar: Self.calendar).map(\.id) == ["busy", "idle"])
    }

    /// Owner 2026-11-04: "I would be cautious of too many things making it on the task list". What a bot added and
    /// nobody touched for two weeks asks to be kept, at the bottom; yours, dated ones and ones a bot works on stay put.
    @Test func forgottenBotTasksAskToBeKept() {
        let old = "2026-10-20T09:00:00-05:00"
        let list = [
            task("forgotten", updated: old, created: old, by: "default"),
            task("together", who: "together", bot: "research", updated: old, created: old, by: "research"),
            task("recent", updated: "2026-10-22T10:00:00-05:00", created: old, by: "default"),
            task("yours", updated: old, created: old, by: "you"),
            task("dated", due: "2026-11-20", updated: old, created: old, by: "default"),
            task("busy", who: "bot", bot: "finance", status: "working", updated: old, created: old, by: "finance"),
            task("ready", who: "together", bot: "default", status: "ready", updated: old, created: old, by: "default"),
            task("water", status: "done", updated: old, created: old, by: "default"),
        ]
        let ids = Dictionary(grouping: list) { TodoSections.section($0, now: Self.now, calendar: Self.calendar) }.mapValues { $0.map(\.id) }
        #expect(ids[.stale] == ["forgotten", "together"], "13 days isn't two weeks; you, a date or a bot at work keep it out")
        #expect(Set(ids[.noDate] ?? []) == ["recent", "yours"])
        // [tasks-first] They wait at Inbox's foot, above its Done.
        let inbox = TodoViews.groups(list, view: .inbox, now: Self.now, calendar: Self.calendar)
        #expect(inbox.map(\.kind) == [.open, .stale, .done], "the group sits above Done")
        #expect(inbox[1].tasks.map(\.id) == ["forgotten", "together"])
        let later = task("later", updated: "2026-10-21T09:00:00-05:00", created: old, by: "default")
        #expect(TodoSections.sorted([later, list[0]], in: .stale, calendar: Self.calendar).map(\.id) == ["forgotten", "later"],
                "the longest forgotten first")
        let line = TodoWords.rowLine(list[0], section: .stale, now: Self.now, calendar: Self.calendar) { $0 == "default" ? "Hermes" : "?" }
        #expect(line.text == "Added by Hermes · Oct 20" && line.tone == .plain)
    }

    @Test func searchAndScope() {
        let list = [task("a", "Call the dentist", who: "together", bot: "default"), task("b", "Invoices", who: "bot", bot: "finance"),
                    task("c", "Dry cleaning")]
        #expect(TodoSections.filtered(list, scope: "finance", query: "").map(\.id) == ["b"])
        #expect(TodoSections.filtered(list, scope: "all", query: "dent").map(\.id) == ["a"])
        #expect(TodoSections.filtered(list, scope: "@me", query: "").map(\.id) == ["c"], "your own: no bot helps")
    }

    // MARK: Words

    @Test func rowLines() {
        let name: (String?) -> String = { $0 == "finance" ? "Finance" : "Hermes" }
        let draft = TodoWords.rowLine(task("s", who: "together", bot: "default", status: "ready", note: "Draft ready",
                                           due: "2026-11-04T17:00:00-06:00"),
                                      section: .ready, now: Self.now, calendar: Self.calendar, botName: name)
        #expect(draft.lead == "Draft ready" && draft.tone == .ready)
        #expect(draft.rest.map { $0.replacingOccurrences(of: "\u{202F}", with: " ") } == ["Due 5:00 PM"])
        let dentist = TodoWords.rowLine(task("d", who: "together", bot: "default", status: "ready", note: "Number and a Dec 9 slot"),
                                        section: .ready, now: Self.now, calendar: Self.calendar, botName: name)
        #expect(dentist.text == "Ready · Number and a Dec 9 slot")
        let passport = TodoWords.rowLine(task("p", who: "together", bot: "default", status: "working",
                                              steps: [("a", true), ("b", true), ("c", false), ("d", false)]),
                                         section: .today, now: Self.now, calendar: Self.calendar, botName: name)
        #expect(passport.text == "Hermes is on it · 2 of 4 steps" && passport.tone == .working)
        let invoices = TodoWords.rowLine(task("i", who: "bot", bot: "finance", status: "working", note: "3 of 5 accounts"),
                                         section: .bots, now: Self.now, calendar: Self.calendar, botName: name)
        #expect(invoices.text == "Finance is working · 3 of 5 accounts")
        let venues = TodoWords.rowLine(task("v", who: "bot", bot: "research", status: "needs_you", note: "What’s the budget?"),
                                       section: .needsYou, now: Self.now, calendar: Self.calendar, botName: name)
        #expect(venues.lead == "Needs you" && venues.tone == .needsYou)
        let late = TodoWords.rowLine(task("l", due: "2026-11-01"), section: .overdue, now: Self.now, calendar: Self.calendar, botName: name)
        #expect(late.lead == "Overdue" && late.tone == .overdue && late.rest == ["Nov 1"])
    }

    @Test func dueWireForms() {
        let five = Self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 17))!
        #expect(TodoDates.wire(five, hasTime: false, calendar: Self.calendar) == "2026-11-05")
        #expect(TodoDates.wire(five, hasTime: true, calendar: Self.calendar) == "2026-11-05T17:00:00-06:00")
        let due = TodoDates.due("2026-11-05T17:00:00-06:00", calendar: Self.calendar)
        #expect(due?.hasTime == true && due?.date == five)
        #expect(TodoDates.due("2026-11-05", calendar: Self.calendar)?.hasTime == false)
    }

    @Test func askCarriesTheTask() {
        let text = TodoWords.askMessage("What's the number?", task: task("t_1", "Call the dentist", note: "Number and a Dec 9 slot"))
        #expect(text.hasPrefix("What's the number?"))
        #expect(text.contains("“Call the dentist”") && text.contains("t_1"))
    }

    // MARK: 409

    @Test func conflictResendsWhenTheOtherEditLeftTheFieldAlone() {
        let base = task("t", "Old", rev: 3)
        var renamed = task("t", "New title", rev: 4)
        #expect(TodoEdits.resolve(base: base, current: renamed, fields: ["status": "done"]) == .resend(rev: 4))
        renamed = task("t", "Old", status: "working", rev: 4)
        #expect(TodoEdits.resolve(base: base, current: renamed, fields: ["status": "done"]) == .theirs)
    }

    @Test func prepJobBots() {
        let prep = { (who: String, bot: String?) -> TodoTask in
            var t = self.task("t", who: who, bot: bot); t.prep = true; return t
        }
        #expect(TodoEdits.prepBots(before: nil, after: prep("together", "default"), fields: nil) == ["default"], "a new prep task")
        #expect(TodoEdits.prepBots(before: nil, after: task("t", who: "together", bot: "default"), fields: nil).isEmpty)
        #expect(TodoEdits.prepBots(before: prep("bot", "finance"), after: nil, fields: nil) == ["finance"], "a deleted one")
        #expect(TodoEdits.prepBots(before: prep("bot", "finance"), after: prep("bot", "research"), fields: ["bot"]) == ["finance", "research"],
                "moved to another bot: both")
        var off = prep("bot", "finance"); off.prep = false
        #expect(TodoEdits.prepBots(before: prep("bot", "finance"), after: off, fields: ["prep"]) == ["finance"], "turned off")
        #expect(TodoEdits.prepBots(before: prep("bot", "finance"), after: prep("bot", "finance"), fields: ["title"]).isEmpty,
                "a new title leaves the job alone")
    }

    // MARK: Chat card

    @Test func tasksAddCard() {
        let result: JSONValue = .string(#"{"id": "t_1", "rev": 1, "title": "Call the dentist", "who": "together", "bot": "default", "due": "2026-11-06", "undo": "Say 'undo'"}"#)
        let card = ToolCards.card(name: "tasks_add", args: [:], result: result)
        guard case .tasksAdded(let added)? = card else { Issue.record("no card"); return }
        #expect(added == [AddedTask(id: "t_1", title: "Call the dentist", who: "together", bot: "default", due: "2026-11-06")])
        #expect(ToolCard(json: card?.json) == card, "the transcript cache keeps it")
        #expect(ToolCards.card(name: "tasks_add", args: [:], result: .string(#"{"error": "title is required"}"#)) == nil)
        #expect(!ToolCards.isCardTool("tasks_add"), "its step draws as any other; the card goes under the reply")
        let line = TodoCardWords.line(added[0], now: Self.now, calendar: Self.calendar) { _ in "Hermes" }
        #expect(line == "You & Hermes · Nov 6")
        let tomorrow = AddedTask(id: "x", title: "x", who: "me", bot: nil, due: "2026-11-05")
        #expect(TodoCardWords.line(tomorrow, now: Self.now, calendar: Self.calendar) { _ in "" } == "You · Tomorrow")
    }

    /// [tasks] Owner, build 755 ("it just added it to my to-do list"): 0.9.33 splits a task Hermes can help with into
    /// steps and starts its own; the card lists them, and a task of yours alone offers help.
    @Test func tasksAddCardWithStepsAndHelp() {
        let result: JSONValue = .string(#"""
            {"id": "t_apps", "rev": 1, "title": "Go through the job applications", "who": "together", "bot": "default",
             "prep": true, "due": "2026-11-04T17:00:00-06:00", "start": "started: your Task prep job is working on it",
             "steps": [{"id": "a1", "title": "Rank all 167", "who": "bot", "done": false},
                       {"id": "a2", "title": "Review the shortlist", "who": "me", "done": false}]}
            """#)
        let card = ToolCards.card(name: "tasks_add", args: [:], result: result)
        guard case .tasksAdded(let added)? = card, let apps = added.first else { Issue.record("no card"); return }
        #expect(apps.started && apps.prep && apps.steps.map(\.who) == ["bot", "me"])
        #expect(ToolCard(json: card?.json) == card, "the transcript cache keeps the steps")
        let (steps, more) = TodoCardWords.steps(apps, botName: "Hermes")
        #expect(steps.map(\.text) == ["Hermes: Rank all 167", "You: Review the shortlist"] && more == 0)
        #expect(steps.map(\.status) == ["Started", ""], "the bot's step says it started")
        var ahead = apps; ahead.started = false
        #expect(TodoCardWords.steps(ahead, botName: "Hermes").steps.first?.status == "Ahead of time")
        #expect(!TodoCardWords.offersHelp(added), "already split: no offer")

        // A later tasks_update keeps "Started" and takes the new steps.
        var later = apps; later.started = false; later.steps[0].done = true
        let merged = apps.updated(by: later)
        #expect(merged.started && merged.steps[0].done)

        // Yours alone: one task, no steps.
        let vet = AddedTask(id: "t_vet", title: "Call the vet", who: "me", bot: nil, due: "2026-11-05")
        #expect(TodoCardWords.offersHelp([vet]))
        #expect(!TodoCardWords.offersHelp([vet, vet]), "two at once: Open Tasks instead")
        #expect(TodoWords.helpMessage(title: "Call the vet", id: "t_vet")
                == "Help me with this: ask me which parts you should take, then start them.\n\nAbout my task “Call the vet”\n(Task id t_vet)")

        // tasks_update where the bot took a part of your task.
        let took: JSONValue = .string(#"{"id": "t_vet", "title": "Call the vet", "who": "together", "bot": "default", "log": [{"by": "default", "text": "took a part"}], "steps": [{"title": "Find the number", "who": "bot"}]}"#)
        guard case .tasksAdded(let updated)? = ToolCards.card(name: "tasks_update", args: [:], result: took) else {
            Issue.record("no update card"); return
        }
        #expect(updated.first?.tookPart == true && updated.first?.who == "together")
    }

    // MARK: Store

    private func store(_ client: PagesFakeClient, directory: URL?) -> TasksStore {
        TasksStore(api: TasksAPI(client: client), account: client.account, directory: directory)
    }

    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "tasks-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func readsTheListAndPaintsItFromDiskNextTime() async throws {
        let one = task("t_1", "Call the dentist", status: "ready")
        let client = PagesFakeClient { request in
            #expect(request.path == "/api/plugins/hermes-hq-push/tasks")
            return .object(["rev": 9, "tasks": .array([Self.wire(one)]), "settings": ["capture": "ask", "prep_per_day": 2]])
        }
        let directory = scratch()
        let first = store(client, directory: directory)
        await first.refresh()
        #expect(first.tasks.map(\.id) == ["t_1"] && first.rev == 9 && first.settings.capture == "ask")
        #expect(client.log.first?.query["since"] == nil, "the first read takes the whole list")
        PagesCache.flush()
        let second = store(PagesFakeClient(), directory: directory)
        second.prepare()
        #expect(second.hasList && second.tasks.map(\.title) == ["Call the dentist"] && second.rev == 9)
    }

    // [13-5] A read still on its way at sign-out: its late answer writes nothing back and leaves the reminders alone.
    @Test func aReadLandingAfterSignOutIsDropped() async throws {
        let one = task("t_1", "Call the dentist", status: "ready")
        let client = PagesFakeClient { _ in
            try await Task.sleep(for: .milliseconds(150))
            return .object(["rev": 9, "tasks": .array([Self.wire(one)])])
        }
        let directory = scratch()
        let s = store(client, directory: directory)
        var listed: [[String]] = []
        s.onListChanged = { listed.append($0.map(\.id)) }
        let read = Task { await s.refresh() }
        try await Task.sleep(for: .milliseconds(30))
        s.forget()
        await read.value
        PagesCache.flush()
        #expect(s.tasks.isEmpty && !s.hasList)
        #expect(listed == [[]], "only the sign-out's own empty list reached the reminders")
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "tasks.json").path), "nothing written back")
    }

    /// [tasks-first] A read that left before a change landed never takes the change back (Move To › New List… read the
    /// list while it moved the task, and the read's late answer showed the task in no list).
    @Test func anOlderReadNeverUndoesANewerChange() async throws {
        let before = task("t_1", "Pick up dry cleaning", rev: 3)
        var after = before
        after.rev = 4
        after.section = "s_errands"
        let moved = Self.wire(after)
        let client = PagesFakeClient { _ in .object(["rev": 5, "tasks": .array([Self.wire(before)]), "sections": .array([])]) }
        let s = store(client, directory: nil)
        await s.refresh()
        client.respond { request in
            if request.method == "PATCH" { return moved }
            try await Task.sleep(for: .milliseconds(200))   // the read answers late, with the task as it was
            return .object(["rev": 5, "tasks": .array([Self.wire(before)]), "sections": .array([])])
        }
        let read = Task { await s.refresh(force: true) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await s.move(["t_1"], to: "s_errands"))
        await read.value
        #expect(s.task("t_1")?.section == "s_errands", "the late read left the move alone")
        // A read after it that has the change wins as usual.
        var renamed = after
        renamed.rev = 5
        renamed.title = "Pick up the dry cleaning"
        let newest = Self.wire(renamed)
        client.respond { _ in .object(["rev": 6, "tasks": .array([newest]), "sections": .array([])]) }
        await s.refresh(force: true)
        #expect(s.task("t_1")?.title == "Pick up the dry cleaning")
    }

    @Test func aStaleRevIsResentWhenNothingClashes() async throws {
        let base = task("t_1", "Old", rev: 3)
        let client = PagesFakeClient { _ in .object(["rev": 1, "tasks": .array([Self.wire(base)])]) }
        let s = store(client, directory: nil)
        await s.refresh()
        let theirs = task("t_1", "Renamed elsewhere", rev: 4)
        var finished = theirs
        finished.status = "done"; finished.rev = 5
        let done = finished
        client.respond { request in
            let rev = ActivityJSON.int(request.body?["rev"]) ?? 0
            if rev == 3 {
                throw HTTPError(status: 409, body: String(decoding: try JSONValue.object(["detail": ["task": Self.wire(theirs)]]).encoded(), as: UTF8.self))
            }
            return Self.wire(done)
        }
        var notices: [String] = []
        s.onNotice = { notices.append($0) }
        let ok = await s.patch("t_1", ["status": "done"])
        #expect(ok)
        #expect(client.log.filter { $0.method == "PATCH" }.map { ActivityJSON.int($0.body?["rev"]) } == [3, 4])
        #expect(s.task("t_1")?.status == "done" && s.task("t_1")?.title == "Renamed elsewhere" && s.task("t_1")?.rev == 5)
        #expect(notices.isEmpty)
    }

    @Test func aClashShowsTheirVersion() async throws {
        let base = task("t_1", rev: 3)
        let client = PagesFakeClient { _ in .object(["rev": 1, "tasks": .array([Self.wire(base)])]) }
        let s = store(client, directory: nil)
        await s.refresh()
        let theirs = task("t_1", status: "working", note: "Hermes took it", rev: 4)
        client.respond { _ in
            throw HTTPError(status: 409, body: String(decoding: try JSONValue.object(["detail": ["task": Self.wire(theirs)]]).encoded(), as: UTF8.self))
        }
        var notices: [String] = []
        s.onNotice = { notices.append($0) }
        let ok = await s.patch("t_1", ["status": "done"])
        #expect(!ok)
        #expect(client.log.filter { $0.method == "PATCH" }.count == 1)
        #expect(s.task("t_1")?.status == "working" && s.task("t_1")?.rev == 4)
        #expect(notices == ["This task changed somewhere else. Showing the latest."])
    }

    @Test func aFailedWriteGoesBack() async throws {
        let base = task("t_1", rev: 3)
        let client = PagesFakeClient { _ in .object(["rev": 1, "tasks": .array([Self.wire(base)])]) }
        let s = store(client, directory: nil)
        await s.refresh()
        client.respond { _ in throw httpError(500, "boom") }
        await s.setDone("t_1", true)
        #expect(s.task("t_1")?.status == "open")
    }

    @Test func addShowsAtOnceThenTakesTheGatewaysTask() async throws {
        let client = PagesFakeClient { _ in .object(["rev": 1, "tasks": []]) }
        let s = store(client, directory: nil)
        await s.refresh()
        let made = task("t_new", "Buy milk", rev: 1)
        client.respond { _ in Self.wire(made) }
        let answer = await s.add(TodoWire.newTask(title: "Buy milk", who: .me, bot: nil, due: nil, repeatRule: nil, prep: false))
        #expect(answer?.id == "t_new")
        #expect(s.tasks.map(\.id) == ["t_new"], "the local stand-in is gone")
        #expect(client.log.last?.body?["title"]?.string == "Buy milk")
    }

    // MARK: Ideas ([task-ideas])

    @Test func ideasAreReadFromTheListAndKeptOffAnOlderAddOn() async throws {
        let client = PagesFakeClient { _ in .object(["rev": 2, "tasks": [], "ideas": 3,
                                                       "settings": ["capture": "ask", "ideas": false, "ideas_bot": "atlas", "ideas_at": "06:45", "ideas_max": 2]]) }
        let s = store(client, directory: nil)
        await s.refresh()
        #expect(s.ideasCount == 3)
        #expect(s.settings.ideas == false && s.settings.ideasBot == "atlas" && s.settings.ideasAt == "06:45" && s.settings.ideasMax == 2)
        let sent = try JSONValue.parse(JSONEncoder().encode(s.settings))
        #expect(sent["ideas_bot"]?.string == "atlas")

        // An add-on before 0.9.39 sends neither: no count (no switch count), and Ideas' settings are never sent back.
        let older = PagesFakeClient { _ in .object(["rev": 2, "tasks": [], "settings": ["capture": "ask"]]) }
        let o = store(older, directory: nil)
        await o.refresh()
        #expect(o.ideasCount == nil && o.settings.ideas == nil)
        let back = try JSONValue.parse(JSONEncoder().encode(o.settings))
        #expect(back["ideas"] == nil && back["ideas_bot"] == nil && back["ideas_at"] == nil && back["ideas_max"] == nil)
    }

    @Test func ideasPageDecodesAndSkipsABadIdea() throws {
        let page = try JSONDecoder().decode(TaskIdeasPage.self, from: JSONValue.object([
            "on": true, "bot": "scout", "at": "07:30", "max": 3, "ran_at": "2026-11-05T07:31:00-06:00", "looking": false,
            "ideas": .array([
                .object(["id": "i_1", "title": "Renew the car registration", "who": "me", "bot": "scout", "source": "Chat with Scout, Mon"]),
                .object(["title": "no id"]),
                .object(["id": "i_2", "title": "Compare internet plans", "who": "together", "bot": "atlas", "help": "List the prices."]),
            ]),
        ]).encoded())
        #expect(page.on && page.bot == "scout" && page.ranAt != nil)
        #expect(page.ideas.map(\.id) == ["i_1", "i_2"], "one bad idea never loses the page")
        #expect(!page.ideas[0].botHelps && page.ideas[1].botHelps)
    }

    @Test func anIdeaLeavesAtOnceAndComesBackWhenTheGatewayRefuses() async throws {
        let ideas: JSONValue = .object(["on": true, "bot": "scout", "at": "07:30", "max": 3, "ideas": .array([
            .object(["id": "i_1", "title": "Renew the car registration", "who": "me", "bot": "scout"]),
            .object(["id": "i_2", "title": "Compare internet plans", "who": "together", "bot": "atlas"]),
        ])])
        let added = task("t_9", "Compare internet plans", who: "together", bot: "atlas", rev: 1)
        let client = PagesFakeClient { request in
            if request.path.hasSuffix("/ideas") { return ideas }
            if request.path.hasSuffix("/i_2/add") { return .object(["idea": [:], "task": Self.wire(added), "already": false]) }
            throw httpError(500, "boom")
        }
        let s = TaskIdeasStore(api: TasksAPI(client: client), directory: nil)
        await s.refresh()
        #expect(s.shown.map(\.id) == ["i_1", "i_2"])
        var notices: [String] = []
        s.onNotice = { notices.append($0) }

        // Dismiss fails: the idea is back, and a notice says so.
        let gone = await s.dismiss(s.shown[0])
        #expect(!gone && s.shown.map(\.id) == ["i_1", "i_2"] && notices.count == 1)

        // Add with its bot starting: the route gets start, the task comes back.
        let task = await s.add(s.shown[1], start: true)
        #expect(task?.id == "t_9")
        let sent = client.log.first { $0.path.hasSuffix("/i_2/add") }
        #expect(sent?.method == "POST" && sent?.body?["start"]?.bool == true)
    }

    @Test func anAddOnWithoutTasksAsksForTheUpdate() async throws {
        let client = PagesFakeClient { request in
            if request.path.hasSuffix("/status") { return .object(["seal": true, "pluginVersion": "0.9.31"]) }
            throw httpError(404, "Not Found")
        }
        let s = store(client, directory: nil)
        await s.refresh()
        #expect(s.needsAddOn && s.error == nil)
    }

    @Test func keepSendsNothingButTheRevAndLeavesTheGroupAtOnce() async throws {
        let old = "2026-10-20T09:00:00-05:00"
        let base = task("t_1", "Renew the passport", updated: old, created: old, by: "default")
        let client = PagesFakeClient { _ in .object(["rev": 1, "tasks": .array([Self.wire(base)])]) }
        let s = store(client, directory: nil)
        await s.refresh()
        #expect(TodoSections.section(s.task("t_1")!, now: Date()) == .stale)
        let kept = task("t_1", "Renew the passport", rev: 4, updated: TodoDates.now(), created: old, by: "default")
        let shownBeforeAnswer = Mutex<TodoSection?>(nil)
        client.respond { [s] _ in
            let shown = await MainActor.run { s.task("t_1").map { TodoSections.section($0, now: Date()) } }
            shownBeforeAnswer.withLock { $0 = shown }
            return Self.wire(kept)
        }
        let ok = await s.keep("t_1")
        #expect(ok)
        let sent = client.log.filter { $0.method == "PATCH" }
        #expect(sent.count == 1 && sent.first?.body?.object?.keys.sorted() == ["rev"], "\(String(describing: sent.first?.body))")
        #expect(shownBeforeAnswer.withLock { $0 } == .noDate, "it leaves the group before the gateway answers")
        #expect(s.task("t_1")?.rev == 4 && TodoSections.section(s.task("t_1")!, now: Date()) == .noDate)
    }

    @Test func aFailedKeepGoesBack() async throws {
        let old = "2026-10-20T09:00:00-05:00"
        let client = PagesFakeClient { _ in .object(["rev": 1, "tasks": .array([Self.wire(Self.make("t_1", updated: old, created: old, by: "default"))])]) }
        let s = store(client, directory: nil)
        await s.refresh()
        client.respond { _ in throw httpError(500, "boom") }
        let ok = await s.keep("t_1")
        #expect(!ok)
        #expect(s.task("t_1")?.updatedAt == old && TodoSections.section(s.task("t_1")!, now: Date()) == .stale)
    }

    @Test func deleteTreatsGoneAsDone() async throws {
        let client = PagesFakeClient { _ in .object(["rev": 1, "tasks": .array([Self.wire(Self.make("t_1"))])]) }
        let s = store(client, directory: nil)
        await s.refresh()
        client.respond { _ in throw httpError(404, "Task not found") }
        let gone = await s.delete("t_1")
        #expect(gone)
        #expect(s.tasks.isEmpty)
    }

    // MARK: Audit fixes (build 863)

    /// A refresh that fails while a list shows says so (as Jobs: "Couldn’t refresh. Showing what was saved."); with
    /// nothing in hand the page's error state says it instead.
    @Test func aFailedRefreshWithAListSaysSo() async throws {
        let client = PagesFakeClient { _ in .object(["rev": 1, "tasks": .array([Self.wire(Self.make("t_1"))])]) }
        let s = store(client, directory: nil)
        var failed: [String] = []
        s.onRefreshFailed = { failed.append($0) }
        await s.refresh()
        #expect(failed.isEmpty)
        client.respond { _ in throw httpError(500, "boom") }
        await s.refresh(force: true)
        #expect(failed.count == 1 && s.tasks.map(\.id) == ["t_1"], "the saved list stays, and the page is told")

        let empty = store(PagesFakeClient { _ in throw httpError(500, "boom") }, directory: nil)
        var told = false
        empty.onRefreshFailed = { _ in told = true }
        await empty.refresh()
        #expect(!told && empty.error != nil, "no list: the error state, not the notice")
    }

    /// New Task says the gateway's own reason; Import from Reminders adds quietly and sums up once.
    @Test func aFailedAddKeepsItsReason() async throws {
        let client = PagesFakeClient { _ in .object(["rev": 1, "tasks": []]) }
        let s = store(client, directory: nil)
        await s.refresh()
        var notices: [String] = []
        s.onNotice = { notices.append($0) }
        let refused = httpError(422, "Title is too long")
        client.respond { _ in throw refused }
        let fields = TodoWire.newTask(title: "Buy milk", who: .me, bot: nil, due: nil, repeatRule: nil, prep: false)
        #expect(await s.add(fields) == nil)
        #expect(s.addFailure == PagesREST.reason(refused) && notices.count == 1)
        #expect(await s.add(fields, quiet: true) == nil)
        #expect(s.addFailure == PagesREST.reason(refused) && notices.count == 1, "quiet: no notice of its own")

        client.respond { _ in Self.wire(Self.make("t_new", "Buy milk", rev: 1)) }
        #expect(await s.add(fields) != nil && s.addFailure == nil)

        s.readOnlyGateway = true
        #expect(await s.add(fields) == nil)
        #expect(s.addFailure == "Changes are off for this gateway." && notices.last == "Changes are off for this gateway.")
    }

    /// A Tasks setting that didn't save shows its old value again (and isn't sent again with the next change).
    @Test func aFailedSettingsSaveGoesBackInTheSheet() async throws {
        let client = PagesFakeClient { _ in .object(["rev": 1, "tasks": [], "settings": ["capture": "ask", "prep_per_day": 6]]) }
        let s = store(client, directory: nil)
        await s.refresh()
        let model = TodoSettingsModel(store: s)
        client.respond { _ in throw httpError(500, "boom") }
        model.draft.capture = "off"
        await model.commit()
        #expect(s.settings.capture == "ask" && model.draft.capture == "ask")

        client.respond { request in request.body ?? .object([:]) }
        model.draft.prepPerDay = 3
        await model.commit()
        let sent = client.log.last { $0.method == "PUT" }
        #expect(sent?.body?["capture"]?.string == "ask" && model.draft.prepPerDay == 3 && s.settings.prepPerDay == 3)
    }

    /// The writes the list plays a tap for say whether they landed: a refused move, Group By or step ticks the
    /// error (the notice says why), one that went through doesn't.
    @Test func movesLayoutsAndStepsSayWhetherTheyLanded() async throws {
        let one = Self.wire(Self.make("t_1", "Water the plants")), two = Self.wire(Self.make("t_2", "Book the vet"))
        let client = PagesFakeClient { _ in
            .object(["rev": 3, "tasks": .array([one, two]), "sections": .array([.object(["id": "s_home", "name": "Home"])])])
        }
        let s = store(client, directory: nil)
        await s.refresh()
        #expect(s.sectionsSupported)
        client.respond { request in
            if request.method == "PATCH" { return Self.wire(Self.make(request.path.hasSuffix("t_1") ? "t_1" : "t_2", rev: 2)) }
            return .object(["rev": 4, "tasks": .array([one, two])])
        }
        #expect(await s.move(["t_1", "t_2"], to: "s_home"))
        #expect(await s.setLayout(group: s.settings.group), "nothing to change is not a failure")

        let refused = httpError(422, "Not now")
        client.respond { request in
            if request.method == "PATCH", request.path.hasSuffix("t_2") { throw refused }
            if request.method == "PATCH" { return Self.wire(Self.make("t_1", rev: 3)) }
            if request.method == "PUT" || request.method == "POST" { throw refused }
            return .object(["rev": 4, "tasks": .array([one, two])])
        }
        #expect(await !s.move(["t_1", "t_2"], to: nil), "one of the two was refused")
        #expect(await !s.setStep("t_2", step: "x", done: true))
        #expect(await !s.setStep("t_gone", step: "x", done: true), "no such task")
    }

    /// Undo right after Dismiss: the restore goes out only once the dismiss has landed.
    @Test func undoWaitsForTheDismiss() async throws {
        let ideas: JSONValue = .object(["on": true, "bot": "scout", "ideas": .array([.object(["id": "i_1", "title": "Renew it", "bot": "scout"])])])
        let dismissed = Mutex(false)
        let restoredAfter = Mutex<Bool?>(nil)
        let client = PagesFakeClient { request in
            if request.path.hasSuffix("/dismiss") {
                try await Task.sleep(for: .milliseconds(300))
                dismissed.withLock { $0 = true }
                return .object(["ok": true])
            }
            if request.path.hasSuffix("/restore") {
                restoredAfter.withLock { $0 = dismissed.withLock { $0 } }
                return .object(["ok": true])
            }
            return ideas
        }
        let s = TaskIdeasStore(api: TasksAPI(client: client), directory: nil)
        await s.refresh()
        let idea = s.shown[0]
        let dismissing = Task { await s.dismiss(idea) }
        try await Task.sleep(for: .milliseconds(30))
        await s.restore(idea)
        #expect(await dismissing.value)
        #expect(restoredAfter.withLock { $0 } == true, "the restore was sent after the dismiss answered")
    }

    @Test func pageWords() {
        #expect(TasksViewController.nothingText(scope: "@me", botName: "Hermes") == "Nothing of your own yet.")
        #expect(TasksViewController.nothingText(scope: "finance", botName: "Finance") == "Nothing with Finance yet.")
        #expect(TasksViewController.nothingText(scope: "all", botName: "").hasPrefix("Add what you need to do."))
        #expect(TodoWords.deleteListMessage(open: 0, done: 0) == nil)
        #expect(TodoWords.deleteListMessage(open: 2, done: 0) == "Its 2 tasks are kept, in no list.")
        #expect(TodoWords.deleteListMessage(open: 0, done: 1) == "Its done task is kept, in no list.")
        #expect(TodoWords.deleteListMessage(open: 1, done: 3) == "Its 1 task and 3 done tasks are kept, in no list.")
        #expect(TodoWords.alertNote(hasTime: true) == "This phone reminds you at that time.")
        let day = TodoWords.alertNote(hasTime: false, calendar: Self.calendar, locale: Locale(identifier: "en_US"))
        #expect(day.hasPrefix("This phone reminds you at 9:00") && day.hasSuffix("that day."), "\(day)")
        #expect(TodoRemindersImport.importResult(added: 3, of: 3, reason: nil) == "Imported 3 reminders")
        #expect(TodoRemindersImport.importResult(added: 1, of: 3, reason: "x") == "Imported 1 reminder. 2 couldn’t be added.")
        #expect(TodoRemindersImport.importResult(added: 0, of: 2, reason: "The gateway is busy.") == "Couldn’t import your reminders. The gateway is busy.")
    }

    @Test func madeLinksOpenWithOrWithoutAScheme() {
        #expect(TodoMade.linkURL("https://example.com/a")?.absoluteString == "https://example.com/a")
        #expect(TodoMade.linkURL("example.com/menu")?.absoluteString == "https://example.com/menu")
        #expect(TodoMade.linkURL(" www.example.org ")?.absoluteString == "https://www.example.org")
        #expect(TodoMade.linkURL("example.com:8080/x")?.absoluteString == "https://example.com:8080/x")
        #expect(TodoMade.linkURL("mailto:ivy@example.com")?.scheme == "mailto")
        #expect(TodoMade.linkURL("the venue list") == nil)
        #expect(TodoMade.linkURL("notes") == nil)
    }

    /// Just Me: a bot's steps become yours (the who-does-it button is off on a Just Me task).
    @Test func justMeTakesTheBotsSteps() {
        let steps = [TodoStep(id: "a", title: "Look it up", who: "bot"), TodoStep(id: "b", title: "Call", who: "me")]
        #expect(TodoEdits.stepsForJustMe(.me, steps: steps)?.map(\.who) == ["me", "me"])
        #expect(TodoEdits.stepsForJustMe(.together, steps: steps) == nil)
        #expect(TodoEdits.stepsForJustMe(.me, steps: [steps[1]]) == nil, "nothing to change")
    }

    @Test func remindersRepeatsComeAlong() {
        #expect(TodoRemindersImport.repeatRule(nil) == nil)
        #expect(TodoRemindersImport.repeatRule([EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)]) == "daily")
        #expect(TodoRemindersImport.repeatRule([EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)]) == "weekly")
        #expect(TodoRemindersImport.repeatRule([EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)]) == "monthly")
        #expect(TodoRemindersImport.repeatRule([EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)]) == "yearly")
        #expect(TodoRemindersImport.repeatRule([EKRecurrenceRule(recurrenceWith: .weekly, interval: 2, end: nil)]) == nil, "every other week has no match")
        let weekdays = [EKWeekday.monday, .tuesday, .wednesday, .thursday, .friday].map { EKRecurrenceDayOfWeek($0) }
        let workdays = EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, daysOfTheWeek: weekdays, daysOfTheMonth: nil,
                                        monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil)
        #expect(TodoRemindersImport.repeatRule([workdays]) == "weekdays")
    }

    // MARK: Your own sections (hermes-hq-push 0.9.36)

    // [13-17] One malformed section is dropped; the others stay (and the add-on isn't called too old).
    @Test func oneBadSectionKeepsTheOthers() throws {
        let raw: JSONValue = ["rev": 3, "tasks": [], "sections": [["id": "work", "name": "Work"], ["id": "broken"], ["id": "home", "name": "Home"]]]
        let answer = try JSONDecoder().decode(TodoListAnswer.self, from: raw.encoded())
        #expect(answer.sections?.map(\.id) == ["work", "home"])
        let older: JSONValue = ["rev": 3, "tasks": []]
        let none = try JSONDecoder().decode(TodoListAnswer.self, from: older.encoded())
        #expect(none.sections == nil, "an older add-on still reads as one without sections")
    }

    // [13-18] The formatters are made once; every wire form still reads.
    @Test func momentsReadEveryWireForm() {
        #expect(TodoDates.moment("2026-11-05T16:30:00Z") == Date(timeIntervalSince1970: 1_793_896_200))
        #expect(TodoDates.moment("2026-11-05T10:30:00-06:00") == Date(timeIntervalSince1970: 1_793_896_200))
        #expect(TodoDates.moment("2026-11-05T16:30:00.250Z") == Date(timeIntervalSince1970: 1_793_896_200.25))
        #expect(TodoDates.moment("2026-11-05T16:30:00") != nil, "Python's zone-less form, read as the phone's time")
        #expect(TodoDates.moment("soon") == nil)
    }

    @Test func aListIsInYourOrder() throws {
        var a = task("a", "Milk"), b = task("b", "Bread"), c = task("c", "Report"), d = task("d", "Old", status: "done")
        var e = task("e", "Lost section")
        a.section = "home"; a.position = 20
        b.section = "home"; b.position = 10
        c.section = "work"
        e.section = "gone"
        let sections = [TodoUserSection(id: "work", name: "Work"), TodoUserSection(id: "home", name: "Home")]
        d.section = "home"
        func shown(_ view: TodoView) -> [TodoGroup] {
            TodoViews.groups([a, b, c, d, e], view: view, sections: sections, now: Self.now, calendar: Self.calendar)
        }
        #expect(shown(.inbox).first?.tasks.map(\.id) == ["e"], "a task whose list is gone counts as in no list")
        #expect(shown(.list("home")).map(\.kind) == [.open, .done])
        #expect(shown(.list("home"))[0].tasks.map(\.id) == ["b", "a"], "your drag order")
        #expect(shown(.list("home"))[1].tasks.map(\.id) == ["d"], "done stays in the list's Done")
        #expect(shown(.list("work"))[0].tasks.map(\.id) == ["c"])

        #expect(TodoSections.position(between: b, and: a) == 15)
        #expect(TodoSections.position(between: a, and: nil) == 21)
        #expect(TodoSections.position(between: nil, and: b) == 9)

        let wire = #"{"id":"x","title":"T","section":"home","position":12.5}"#
        let decoded = try JSONDecoder().decode(TodoTask.self, from: Data(wire.utf8))
        #expect(decoded.section == "home" && decoded.position == 12.5)
        let old = try JSONDecoder().decode(TodoTask.self, from: Data(#"{"id":"y","title":"T","created_at":"2026-11-03T08:00:00Z"}"#.utf8))
        #expect(old.section == nil && old.order > 0, "an older add-on: added time is the order")
    }

    @Test func sortByDueOrAdded() {
        let soon = task("soon", due: "2026-11-05"), later = task("later", due: "2026-11-09"), none = task("none")
        let newer = task("newer", created: "2026-11-04T08:00:00-06:00")
        #expect(TodoSections.ordered([none, later, soon], sort: "due", calendar: Self.calendar).map(\.id) == ["soon", "later", "none"])
        #expect(TodoSections.ordered([soon, newer], sort: "added", calendar: Self.calendar).map(\.id) == ["newer", "soon"])
    }
}

// [tasks] Owner 2026-11-04: "the way that some of the work was presented … needs to be improved". The first live
// shortlist (places and numbers changed) and the first live notes.
struct TasksReadableTests {
    static let shortlist = "North Bistro: 404 Aspen Dr, ~5 min, $25 lunch prix fixe, book online up to 8 / call 9+ (555) 555-0150. "
        + "Copper Kettle: 402 Aspen Dr, ~5 min, ~$$, OpenTable + semi-private/patio for groups. Bayside Grill: 15 W Main St, "
        + "~6 min, $$-$$$, online up to 4 / call 5+ (555) 555-0160. Alt: J. Marlow's, 17 Harbor Blvd, ~4 min, call "
        + "(555) 555-0170. Full table: /Users/me/.hermes/cache/scratch/lunch-shortlist.md"

    @Test func aRunOfNamedPlacesReadsAsLines() {
        let lines = TodoReadable.markdown(Self.shortlist).components(separatedBy: "\n")
        #expect(lines.count == 5)
        #expect(lines[0].hasPrefix("- **North Bistro:** 404 Aspen Dr"))
        #expect(lines[3] == "- **Alt:** J. Marlow's, 17 Harbor Blvd, ~4 min, call (555) 555-0170.")   // "J." stays whole
        #expect(lines[4] == "- **Full table:** /Users/me/.hermes/cache/scratch/lunch-shortlist.md")
        #expect(TodoReadable.preview(Self.shortlist).hasPrefix("North Bistro: 404 Aspen Dr"))
    }

    @Test func aListAfterAColonReadsAsAList() {
        let notes = "9 open (Design 3, Support 4, Ops 2). The review flagged what to check: 2 Support date + "
            + "1 Support place mismatches; Ops question wording flaw; 1 Design link broken."
        #expect(TodoReadable.markdown(notes) == "9 open (Design 3, Support 4, Ops 2). The review flagged what to check:\n"
            + "- 2 Support date + 1 Support place mismatches\n- Ops question wording flaw\n- 1 Design link broken")
    }

    @Test func shortTextAndTheBotsOwnLinesAreLeftAlone() {
        #expect(TodoReadable.markdown("3 spots ready. North Bistro is my pick; pick one") == "3 spots ready. North Bistro is my pick; pick one")
        let own = "- **Elm & Oak**: 5 min\n- **Copper Kettle**: 5 min, and a much longer line that goes on past the length "
            + "at which a run of sentences would be split. Dr. Lee: a name with a dot."
        #expect(TodoReadable.markdown(own) == own)
        let prose = "Dr. Lee Dental can see you Dec 9 at 10 AM. They asked that you bring the insurance card and arrive ten "
            + "minutes early to fill in the forms, and parking is behind the building."
        #expect(TodoReadable.markdown(prose) == prose)
    }

    @Test func aBareStatusInTheActivityReadsAsWords() {
        #expect(TodoReadable.logText("working") == "Started")
        #expect(TodoReadable.logText("ready") == "Got it ready")
        #expect(TodoReadable.logText("Ready: 3 spots ready") == "Ready: 3 spots ready")
    }
}

// MARK: - A task is a workspace (2026-11-04)

@MainActor
struct TaskWorkspaceTests {
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }()

    private func task(_ extra: [String: JSONValue]) -> TodoTask {
        var o: [String: JSONValue] = ["id": "0123456789abcdef", "rev": 3, "title": "Follow up with Ivy", "who": "me", "status": "open",
                                      "updated_at": "2026-11-04T08:00:00-06:00", "created_at": "2026-11-03T08:00:00-06:00"]
        o.merge(extra) { _, new in new }
        return try! JSONDecoder().decode(TodoTask.self, from: JSONValue.object(o).encoded())
    }

    /// A day alone rings at 9:00 (owner: "remind me … tomorrow" never rang); a time rings then.
    @Test func reminderTimes() {
        let day = TodoReminder.time(task(["due": "2026-11-05"]), calendar: Self.calendar)
        #expect(day == Self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 9)))
        let timed = TodoReminder.time(task(["due": "2026-11-05T10:30:00-06:00"]), calendar: Self.calendar)
        #expect(timed == Self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 10, minute: 30)))
        #expect(TodoReminder.time(task([:]), calendar: Self.calendar) == nil)
    }

    /// [13-14] A set moment's alert carries its zone (it rings at that moment after a trip); a day alone stays 9:00
    /// on the phone's clock.
    @Test func reminderTriggersKeepTheMomentAcrossZones() throws {
        let timedTask = task(["due": "2026-11-05T10:30:00-06:00"])
        let timed = try #require(TodoReminder.time(timedTask, calendar: Self.calendar))
        let parts = TodoReminder.triggerParts(timedTask, at: timed, calendar: Self.calendar)
        #expect(parts.timeZone == Self.calendar.timeZone)
        // Read in another zone (the phone after a trip), the parts still name the same moment.
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        #expect(tokyo.date(from: parts) == timed)
        let dayTask = task(["due": "2026-11-05"])
        let day = try #require(TodoReminder.time(dayTask, calendar: Self.calendar))
        let dayParts = TodoReminder.triggerParts(dayTask, at: day, calendar: Self.calendar)
        #expect(dayParts.timeZone == nil && dayParts.hour == 9 && dayParts.minute == 0)
    }

    /// The alert says what's waiting when the bot left a line; else when it's due.
    @Test func reminderBody() {
        #expect(TodoReminder.body(task(["due": "2026-11-05"])) == "Due today")
        #expect(TodoReminder.body(task(["due": "2026-11-05T10:30:00-06:00"])) == "Due now")
        #expect(TodoReminder.body(task(["due": "2026-11-05", "status": "ready", "status_note": "No reply yet; a nudge is drafted"]))
                == "No reply yet; a nudge is drafted")
        #expect(TodoReminder.body(task(["due": "2026-11-05", "status": "working", "status_note": "Checking"])) == "Due today")
    }

    @Test func watchingLine() {
        #expect(TodoWords.watching(task(["watch": "A reply from Ivy, by email"])) == "Watching for a reply from Ivy, by email")
        #expect(TodoWords.watching(task(["watch": "Ivy's signed contract"])) == "Watching for Ivy's signed contract")
        #expect(TodoWords.watching(task(["watch": "  "])) == nil)
        #expect(TodoWords.watching(task(["watch": "a reply", "status": "done"])) == nil)
    }

    /// `chat` reads back; `{}` (no chat yet) reads as none.
    @Test func chatLinkDecodes() {
        let linked = task(["chat": ["profile": "inbox", "session_id": "20261104_120000_ab12cd"]])
        #expect(linked.chat == TodoChat(profile: "inbox", sessionId: "20261104_120000_ab12cd"))
        #expect(task(["chat": .object([:])]).chat == nil)
        #expect(task([:]).chat == nil && task([:]).watch == "")
        #expect(linked.chat?.json == .object(["profile": "inbox", "session_id": "20261104_120000_ab12cd"]))
        // "No chat yet" from the gateway survives the disk cache and edit merges, so an old link on the device can't return.
        let none = task(["chat": .object([:])])
        #expect(none.chatKnown && !task([:]).chatKnown)
        let reread = try? JSONDecoder().decode(TodoTask.self, from: JSONEncoder().encode(none))
        #expect(reread?.chatKnown == true && reread?.chat == nil)
        #expect(TodoEdits.applying(["title": "Renamed"], to: none)?.chatKnown == true)
    }

    /// The chat's bot: the helper, else the chat it came from, else the bot that added it, else Hermes.
    /// [tasks] 2026-11-05: the task's page is its chat. Its first message carries the task's details (the bot
    /// learns the task); later ones go as typed; Ask to Help shows short.
    @MainActor @Test func pageMessages() {
        let t = task(["notes": .string("Ask for the blue coat")])
        let first = TaskPage.outgoing("  Is it open late? ", task: t, first: true)
        #expect(first?.display == "Is it open late?")
        #expect(first?.text.hasPrefix("Is it open late?\n\nAbout my task “") == true)
        #expect(first?.text.contains("(Task id ") == true && first?.text.contains("Notes: Ask for the blue coat") == true)
        #expect(TodoWords.askShown(first?.text ?? "") == "Is it open late?")
        #expect(TaskPage.outgoing("Thanks", task: t, first: false) == nil)
        #expect(TaskPage.outgoing("   ", task: t, first: true) == nil)
        let help = TaskPage.outgoing(TodoWords.helpQuestion, task: t, first: false)
        #expect(help?.text == TodoWords.helpQuestion && help?.display == "Help me with “\(t.title)”")
    }

    @Test func chatBot() {
        let bots = ["default", "inbox", "finance"].map {
            Bot(id: $0, name: $0.capitalized, role: nil, preview: nil, lastActive: nil, isWorking: false, unread: false, pinned: false,
                pinOrder: nil, sectionName: nil, hidden: false, canonicalSessionId: nil, head: nil)
        }
        #expect(TaskChatLinks.bot(for: task(["who": "together", "bot": "finance"]), bots: bots)?.id == "finance")
        #expect(TaskChatLinks.bot(for: task(["source": ["kind": "chat", "profile": "inbox", "session_id": "x"]]), bots: bots)?.id == "inbox")
        #expect(TaskChatLinks.bot(for: task(["created_by": "inbox"]), bots: bots)?.id == "inbox")
        #expect(TaskChatLinks.bot(for: task(["created_by": "you"]), bots: bots)?.id == "default")
    }

    /// Unique per task and within Hermes's 100 characters.
    @Test func sessionTitle() {
        #expect(TaskChatLinks.sessionTitle(task([:])) == "Task: Follow up with Ivy · 012345")
        let long = TaskChatLinks.sessionTitle(task(["title": .string(String(repeating: "a", count: 120))]))
        #expect(long.count <= 100 && long.hasSuffix("… · 012345"))
    }

    /// Your bubble shows your words, never the task's details sent with them (live and in history).
    @Test func askShown() {
        let t = task(["notes": "Contract v3", "status_note": "Waiting on Ivy"])
        #expect(TodoWords.askShown(TodoWords.askMessage("Can you draft a nudge?", task: t)) == "Can you draft a nudge?")
        #expect(TodoWords.askShown(TodoWords.askMessage(TodoWords.helpQuestion, task: t)) == "Help me with “Follow up with Ivy”")
        #expect(TodoWords.askShown(TodoWords.helpMessage(title: "Call the vet", id: "t_vet")) == "Help me with “Call the vet”")
        #expect(TodoWords.askShown("What is (Task id 5)?") == nil)
        #expect(TodoWords.askShown("Hello") == nil)
        let notes = TimelineNotes.resolve([ChatMessage(id: "stored-row-1-user", role: .user, parts: [.text(TodoWords.askMessage("Any news?", task: t))],
                                                          timestamp: Date(), rowId: 1)])
        guard case .text(let shown)? = notes.first?.parts.first else { Issue.record("no text"); return }
        #expect(shown == "Any news?")
    }
}

// MARK: - The brief's one move and its words (Pinned Task step 1, 2026-11-07)

@MainActor
struct TaskNowTests {
    private func task(_ extra: [String: JSONValue]) -> TodoTask {
        var o: [String: JSONValue] = ["id": "0123456789abcdef", "rev": 3, "title": "Follow up with Ivy", "who": "together", "bot": "inbox",
                                      "status": "open", "updated_at": "2026-11-04T08:00:00-06:00", "created_at": "2026-11-03T08:00:00-06:00"]
        o.merge(extra) { _, new in new }
        return try! JSONDecoder().decode(TodoTask.self, from: JSONValue.object(o).encoded())
    }

    private func step(_ title: String, who: String, done: Bool) -> JSONValue {
        .object(["id": .string(title), "title": .string(title), "who": .string(who), "done": .bool(done)])
    }

    private let note: JSONValue = .object(["id": "m1", "title": "Nudge to Ivy (draft)", "kind": "note", "ref": "Hi Ivy, checking in."])

    /// Ready with a draft and your step still open: the draft is the move (it had been Mark Done), Done beside it.
    @Test func readyActsOnWhatTheBotMade() throws {
        let ready = task(["status": "ready", "made": [note],
                          "steps": [step("Draft a nudge", who: "bot", done: true), step("Send the nudge", who: "me", done: false)]])
        let now = try #require(TaskNow.pick(ready, phone: nil))
        guard case .share(let made) = now.primary else { Issue.record("not Share: \(now.primary)"); return }
        #expect(made.title == "Nudge to Ivy (draft)")
        #expect(now.tinted && now.secondary == .markDone)
        #expect(now.primary.label(botName: "Inbox") == "Share Draft…")
        #expect(TaskNow.Action.markDone.label(botName: "Inbox", secondary: true) == "Done")
    }

    /// Every step of yours ticked: Done becomes the move, what was made a tap away.
    @Test func readyWithYourStepsDoneIsDone() throws {
        let ready = task(["status": "ready", "made": [note],
                          "steps": [step("Draft a nudge", who: "bot", done: true), step("Send the nudge", who: "me", done: true)]])
        let now = try #require(TaskNow.pick(ready, phone: nil))
        #expect(now.primary == .markDone && now.tinted)
        if case .share? = now.secondary {} else { Issue.record("no Share beside Done: \(String(describing: now.secondary))") }
    }

    /// A link opens, a file opens, nothing made with a number calls, nothing at all is Mark Done alone.
    @Test func readyMoves() throws {
        let link: JSONValue = .object(["title": "Booking", "kind": "link", "ref": "example.com/book"])
        if case .openLink? = TaskNow.pick(task(["status": "ready", "made": [note, link]]), phone: nil)?.primary {} else { Issue.record("newest is the link") }
        let file: JSONValue = .object(["title": "Shortlist", "kind": "file", "ref": "/tmp/a.md"])
        if case .openFile? = TaskNow.pick(task(["status": "ready", "made": [file]]), phone: nil)?.primary {} else { Issue.record("file") }
        let call = try #require(TaskNow.pick(task(["status": "ready"]), phone: "(512) 555-0168"))
        #expect(call.primary == .call("(512) 555-0168") && call.secondary == .markDone)
        let bare = try #require(TaskNow.pick(task(["status": "ready"]), phone: nil))
        #expect(bare == TaskNow(primary: .markDone, tinted: true, secondary: nil))
    }

    @Test func needsYouAnswers() throws {
        let now = try #require(TaskNow.pick(task(["status": "needs_you", "status_note": "What's the budget?"]), phone: "555-0100"))
        #expect(now == TaskNow(primary: .answer, tinted: true, secondary: .markDone))
    }

    /// Working: nothing waits on you, so nothing is tinted.
    @Test func workingAsksForAnUpdate() throws {
        let now = try #require(TaskNow.pick(task(["status": "working"]), phone: nil))
        #expect(now == TaskNow(primary: .askUpdate, tinted: false, secondary: .markDone))
        #expect(now.primary.label(botName: "Inbox") == "Ask for an Update")
    }

    @Test func doneReopensAndDeletedHasNoMove() throws {
        #expect(TaskNow.pick(task(["status": "done"]), phone: nil) == TaskNow(primary: .reopen, tinted: false, secondary: nil))
        #expect(TaskNow.pick(task(["status": "ready"]), phone: nil, deleted: true) == nil)
    }

    /// A helper bot that hasn't started is asked to; once it has done anything, Mark Done.
    @Test func toDoWithABot() throws {
        let fresh = try #require(TaskNow.pick(task([:]), phone: nil))
        #expect(fresh == TaskNow(primary: .askStart, tinted: true, secondary: .markDone))
        #expect(fresh.primary.label(botName: "Inbox") == "Ask Inbox to Start")
        let started = task(["steps": [step("Check for Ivy's reply", who: "bot", done: true), step("Send the nudge", who: "me", done: false)]])
        #expect(TaskNow.pick(started, phone: nil) == TaskNow(primary: .markDone, tinted: false, secondary: nil))
        #expect(TaskNow.pick(task(["status_note": "Looked once"]), phone: nil)?.primary == .markDone)
    }

    /// Your own task: Mark Done (tinted with nothing left open), and Ask to Help while it has no steps.
    @Test func yourOwnTask() throws {
        let plain = try #require(TaskNow.pick(task(["who": "me", "bot": .null]), phone: nil))
        #expect(plain == TaskNow(primary: .markDone, tinted: true, secondary: .askHelp))
        let stepped = task(["who": "me", "bot": .null, "steps": [step("Find the ticket", who: "me", done: false)]])
        #expect(TaskNow.pick(stepped, phone: nil) == TaskNow(primary: .markDone, tinted: false, secondary: nil))
    }

    /// The state line's words and time: the newest status line in the log, not the last edit.
    @Test func stateLine() {
        let ready = task(["status": "ready", "updated_at": "2026-11-04T09:30:00-06:00",
                          "log": [.object(["at": "2026-11-04T08:10:00-06:00", "by": "inbox", "text": "Started"]),
                                  .object(["at": "2026-11-04T09:26:00-06:00", "by": "inbox", "text": "Ready: No reply yet; a nudge is drafted"]),
                                  .object(["at": "2026-11-04T09:30:00-06:00", "by": "you", "text": "Notes changed"])]])
        #expect(TodoWords.stateWords(ready, botName: { _ in "Inbox" }) == "Ready for you")
        #expect(TodoWords.stateSince(ready) == "2026-11-04T09:26:00-06:00")
        let working = task(["status": "working", "log": [.object(["at": "2026-11-04T08:10:00-06:00", "by": "inbox", "text": "working"])]])
        #expect(TodoWords.stateWords(working, botName: { _ in "Inbox" }) == "Inbox is on it")
        #expect(TodoWords.stateSince(working) == "2026-11-04T08:10:00-06:00")
        #expect(TodoWords.stateSince(task(["status": "needs_you"])) == "2026-11-04T08:00:00-06:00")   // no line: its last change
        #expect(TodoWords.stateSince(task([:])) == nil)
    }

    /// The bot's words: its Task Page's summary when it sent one (0.9.43), else its line; Next, else what it watches.
    @Test func botWordsAndNext() throws {
        let plain = task(["status": "ready", "status_note": "No reply yet; a nudge is drafted", "watch": "A reply from Ivy"])
        #expect(TodoWords.botWords(plain) == "No reply yet; a nudge is drafted")
        #expect(TodoWords.nextLine(plain)?.text == "Watching for a reply from Ivy")
        #expect(TodoWords.nextLine(plain)?.isWatch == true)
        let paged = task(["status": "ready", "status_note": "No reply yet", "watch": "A reply from Ivy",
                          "page": .object(["summary": " No reply from Ivy yet. A friendly nudge is drafted. ", "next": "You send it; I check at 9 AM."])])
        #expect(TodoWords.botWords(paged) == "No reply from Ivy yet. A friendly nudge is drafted.")
        #expect(TodoWords.nextLine(paged)?.text == "Next: You send it; I check at 9 AM.")
        #expect(TodoWords.nextLine(paged)?.isWatch == false)
        #expect(task(["page": .object([:])]).page == nil)
        #expect(task(["page": "nonsense"]).page == nil)
        // The gist survives the disk cache.
        let again = try JSONDecoder().decode(TodoTask.self, from: JSONEncoder().encode(paged))
        #expect(again.page == paged.page)
    }

    /// Owner 2026-11-07: a smart-home task offered "Call". Only numbers written or named as phone numbers call.
    @Test func callOnlyForRealPhoneNumbers() {
        let ok = ["Dr. Lee Dental, (512) 555-0142. Mon-Fri 8-5.": "(512) 555-0142",
                  "Call them at 512-555-0168 before noon": "512-555-0168",
                  "Office: +1 512 555 0177": "+1 512 555 0177",
                  "their number is 5125550190": "5125550190"]
        for (text, number) in ok { #expect(TaskNow.callable(number, in: text), "\(text)") }
        let no = ["LAN status is live at 192.168.1.50; transport findings are prepared": "192.168.1.50",
                  "Device 0x00158d0001 joined at 1700000000": "1700000000",
                  "MQTT on port 18831234 answered": "18831234",
                  "Build 20261107 passed": "20261107",
                  "rainbow/reset test 2026-11-07 ready": "2026-11-07",
                  "zone 12 has 4 lights, 3 scenes, 7 sensors": "12"]
        for (text, number) in no { #expect(!TaskNow.callable(number, in: text), "\(text)") }
    }
}

/// [tasks] The plain task view (owner 2026-11-09, hermes-hq-push 0.9.47): one-tap answers, what the bot just changed,
/// and when it looks again.
struct TaskPlainTests {
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }()

    private func task(_ extra: [String: JSONValue]) -> TodoTask {
        var o: [String: JSONValue] = ["id": "0123456789abcdef", "rev": 3, "title": "Follow up with Ivy", "who": "together",
                                      "bot": "inbox", "status": "ready", "created_at": "2026-11-03T08:00:00-06:00"]
        o.merge(extra) { _, new in new }
        return try! JSONDecoder().decode(TodoTask.self, from: JSONValue.object(o).encoded())
    }

    private static func entry(_ at: String, _ by: String, _ text: String, change: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = ["at": .string(at), "by": .string(by), "text": .string(text)]
        if change { o["kind"] = "change" }
        return .object(o)
    }

    @Test func readsChoicesAndNextCheck() {
        let t = task(["choices": .array(["Send it", " ", "Not yet"]), "next_check": "2026-11-11T09:00:00-06:00"])
        #expect(t.choices == ["Send it", "Not yet"])
        #expect(t.nextCheck == "2026-11-11T09:00:00-06:00")
        let older = task([:])
        #expect(older.choices.isEmpty && older.nextCheck == nil)
        #expect(task(["next_check": ""]).nextCheck == nil)
    }

    @Test func recentChangesAreTheBotsSinceYourLastWord() {
        let now = ISO8601DateFormatter().date(from: "2026-11-09T16:00:00Z")!
        let t = task(["log": .array([
            Self.entry("2026-11-09T15:00:00Z", "inbox", "Ticked “Old”", change: true),
            Self.entry("2026-11-09T15:10:00Z", "you", "working"),
            Self.entry("2026-11-09T15:11:00Z", "inbox", "Ticked “Send it”", change: true),
            Self.entry("2026-11-09T15:11:00Z", "inbox", "Ready: Sent"),
            Self.entry("2026-11-09T15:11:00Z", "inbox", "Moved to Fri Nov 13, 9:00 AM", change: true),
        ])])
        #expect(TodoWords.recentChanges(t, now: now) == ["Ticked “Send it”", "Moved to Fri Nov 13, 9:00 AM"])
        let dayLater = now.addingTimeInterval(86_400)
        #expect(TodoWords.recentChanges(t, now: dayLater).isEmpty, "a day later it's history, not news")
    }

    @Test func nextCheckLine() {
        let now = ISO8601DateFormatter().date(from: "2026-11-09T16:00:00Z")!
        let tomorrow = task(["next_check": "2026-11-10T09:00:00-06:00"])
        let line = TodoWords.nextCheckLine(tomorrow, now: now, calendar: Self.calendar) ?? ""
        // The clock follows the phone's style ("9:00 AM", or "09:00" on a 24-hour phone).
        #expect(line.hasPrefix("Checks again tomorrow, ") && line.contains("9:00"), "\(line)")
        let past = task(["next_check": "2026-11-08T09:00:00-06:00"])
        #expect(TodoWords.nextCheckLine(past, now: now, calendar: Self.calendar) == nil)
        let done = task(["next_check": "2026-11-10T09:00:00-06:00", "status": "done"])
        #expect(TodoWords.nextCheckLine(done, now: now, calendar: Self.calendar) == nil)
    }
}
