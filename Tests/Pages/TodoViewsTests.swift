// [tasks-first] The Tasks page's views (owner 2026-11-12: "pure task management first, agent stuff second"): which
// tasks each view shows and in what order, a row's words, and Tasks' own runner jobs kept out of Jobs.

import Foundation
import Testing
@testable import HermesHQNative

struct TodoViewsTests {
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        c.locale = Locale(identifier: "en_US")
        return c
    }()
    /// Wednesday 2026-11-04, 09:41 in Chicago.
    private static let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 9, minute: 41))!

    private func task(_ id: String, who: String = "me", bot: String? = nil, status: String = "open", note: String = "",
                      due: String? = nil, section: String? = nil, steps: [Bool] = [], notes: String = "", repeats: String? = nil,
                      updated: String = "2026-11-04T08:00:00-06:00", created: String = "2026-11-03T08:00:00-06:00",
                      doneAt: String? = nil, by: String? = nil, position: Double = 0, choices: [String] = []) -> TodoTask {
        var o: [String: JSONValue] = ["id": .string(id), "title": .string(id), "who": .string(who), "status": .string(status),
                                      "status_note": .string(note), "updated_at": .string(updated), "created_at": .string(created),
                                      "notes": .string(notes), "position": .number(position)]
        if let bot { o["bot"] = .string(bot) }
        if let due { o["due"] = .string(due) }
        if let section { o["section"] = .string(section) }
        if let repeats { o["repeat"] = .string(repeats) }
        if let doneAt { o["done_at"] = .string(doneAt) }
        if let by { o["created_by"] = .string(by) }
        if !choices.isEmpty { o["choices"] = .array(choices.map(JSONValue.string)) }
        o["steps"] = .array(steps.enumerated().map { .object(["id": .string("s\($0.offset)"), "title": "x", "who": "me", "done": .bool($0.element)]) })
        return try! JSONDecoder().decode(TodoTask.self, from: JSONValue.object(o).encoded())
    }

    private var lists: [TodoUserSection] { [TodoUserSection(id: "work", name: "Work"), TodoUserSection(id: "home", name: "Home")] }

    private func groups(_ tasks: [TodoTask], _ view: TodoView, sort: String = "smart") -> [(TodoGroupKind, [String])] {
        TodoViews.groups(tasks, view: view, sections: lists, bots: ["default", "finance", "research"], now: Self.now, sort: sort,
                         calendar: Self.calendar).map { ($0.kind, $0.tasks.map(\.id)) }
    }

    private func name(_ profile: String?) -> String {
        ["default": "Hermes", "finance": "Finance", "research": "Research"][profile ?? "default"] ?? (profile ?? "")
    }

    private var list: [TodoTask] {
        [
            task("late", due: "2026-11-01"),
            task("cleaning", due: "2026-11-04T18:00:00-06:00"),
            task("apps", due: "2026-11-04T17:00:00-06:00", section: "work"),
            task("dentist", who: "together", bot: "default", status: "ready", note: "Number and a Dec 9 slot", due: "2026-11-04"),
            task("passport", who: "together", bot: "default", status: "working", due: "2026-11-04"),
            task("contract", who: "together", bot: "default", status: "ready", due: "2026-11-05T10:00:00-06:00",
                 updated: "2026-11-04T09:00:00-06:00"),
            task("venues", who: "bot", bot: "research", status: "needs_you", note: "What’s the budget?", due: "2026-11-08",
                 updated: "2026-11-04T09:30:00-06:00"),
            task("invoices", who: "bot", bot: "finance", status: "working", note: "3 of 5 accounts", due: "2026-11-04"),
            task("report", who: "bot", bot: "finance", due: "2026-11-06"),
            task("gift", who: "together", bot: "default", due: "2026-11-12"),
            task("porch"),
            task("desk", section: "home"),
            task("water", status: "done", due: "2026-11-04", doneAt: "2026-11-04T08:10:00-06:00"),
            task("flights", status: "done", section: "work", doneAt: "2026-11-01T08:10:00-06:00"),
            task("ledger", who: "bot", bot: "finance", status: "done", doneAt: "2026-11-04T07:00:00-06:00"),
        ]
    }

    // MARK: Views

    /// Today is your day: what's late, what's due, then what a bot is stuck on you for, then what you finished.
    @Test func todayIsYourDayThenWhatWaitsOnYou() {
        let today = groups(list, .today)
        #expect(today.map(\.0) == [.overdue, .today, .waiting, .done])
        #expect(today[0].1 == ["late"])
        // By time; a day with no time comes first, in the order they were added.
        #expect(today[1].1 == ["dentist", "passport", "apps", "cleaning"])
        // The newest news first; one due today stays under Today, not here.
        #expect(today[2].1 == ["venues", "contract"])
        #expect(today[3].1 == ["water"], "finished today, and not a bot's own")
    }

    /// A bot's own task is the bot's until it waits on you.
    @Test func aBotsOwnTaskStaysOutOfYourDay() {
        let today = groups(list, .today).flatMap(\.1)
        #expect(!today.contains("invoices"), "due today, but Finance is doing it by itself")
        #expect(today.contains("venues"), "Research has a question: it waits on you")
        #expect(!groups(list, .upcoming).flatMap(\.1).contains("report"))
        #expect(!groups(list, .inbox).flatMap(\.1).contains("report"))
    }

    @Test func upcomingIsEachComingDay() {
        let upcoming = groups(list, .upcoming)
        #expect(upcoming.map(\.0) == [.day("2026-11-05"), .day("2026-11-08"), .day("2026-11-12")])
        #expect(upcoming.map(\.1) == [["contract"], ["venues"], ["gift"]])
    }

    /// Inbox: no date and no list yet. A task whose list was deleted counts as having none.
    @Test func inboxIsWhatHasNoDateAndNoList() {
        // Its Done is what was finished with no list.
        #expect(groups(list, .inbox).map(\.1) == [["porch"], ["water"]])
        let orphan = task("orphan", section: "gone")
        let stale = task("stale", updated: "2026-10-10T08:00:00-05:00", created: "2026-10-10T08:00:00-05:00", by: "default")
        let inbox = groups(list + [orphan, stale], .inbox)
        #expect(inbox.map(\.0) == [.open, .stale, .done])
        #expect(Set(inbox[0].1) == ["porch", "orphan"])
        #expect(inbox[1].1 == ["stale"], "a bot added it and nobody touched it for two weeks")
    }

    /// A list holds its tasks whoever does them, in your order, and its own Done.
    @Test func aListIsItsTasksInYourOrder() {
        let work = groups(list, .list("work"))
        #expect(work.map(\.0) == [.open, .done])
        #expect(work[0].1 == ["apps"])
        #expect(work[1].1 == ["flights"])
        let ordered = [task("b", section: "work", position: 2), task("a", due: "2026-11-09", section: "work", position: 1),
                       task("c", due: "2026-11-05", section: "work", position: 3)]
        #expect(groups(ordered, .list("work"))[0].1 == ["a", "b", "c"])
        #expect(groups(ordered, .list("work"), sort: "due")[0].1 == ["c", "a", "b"])
    }

    /// Bots: each bot's own tasks, in the roster's order, the one it is on first; then what they finished.
    @Test func botsIsWhatEachDoesByItself() {
        let bots = groups(list, .bots)
        #expect(bots.map(\.0) == [.bot("finance"), .bot("research"), .done])
        #expect(bots[0].1 == ["invoices", "report"])
        #expect(bots[1].1 == ["venues"])
        #expect(bots[2].1 == ["ledger"])
        #expect(TodoViews.showsBots(list))
        #expect(!TodoViews.showsBots(list.filter { $0.whoKind != .bot }), "nobody without a bot's task sees the pill")
    }

    /// Every open task shows in at least one view.
    @Test func noOpenTaskIsLost() {
        let views: [TodoView] = [.today, .upcoming, .inbox, .list("work"), .list("home"), .bots]
        let shown = Set(views.flatMap { groups(list, $0).filter { $0.0 != .done }.flatMap(\.1) })
        #expect(shown == Set(list.filter { !$0.isDone }.map(\.id)))
    }

    @Test func thePillsCount() {
        func count(_ view: TodoView) -> Int { TodoViews.openCount(list, view: view, sections: lists, now: Self.now, calendar: Self.calendar) }
        #expect(count(.today) == 7)
        #expect(count(.upcoming) == 3)
        #expect(count(.inbox) == 1)
        #expect(count(.list("work")) == 1)
        #expect(count(.bots) == 3)
    }

    @Test func aViewKeepsItsKey() {
        for view in [TodoView.today, .upcoming, .inbox, .bots, .list("abc")] { #expect(TodoView(key: view.key) == view) }
        #expect(TodoView(key: "list:") == nil)
        #expect(TodoView(key: "") == nil)
        #expect(TodoViews.startsToday(.today) && !TodoViews.startsToday(.inbox))
    }

    // MARK: Words

    /// The clock's narrow space ("5:00\u{202F}PM") read as a plain one.
    private func row(_ task: TodoTask, _ kind: TodoGroupKind) -> TodoRowWords {
        var words = TodoViews.row(task, in: kind, now: Self.now, calendar: Self.calendar, botName: name)
        words.when = words.when?.replacingOccurrences(of: "\u{202F}", with: " ")
        return words
    }

    /// A row says when, and nothing about a bot unless the bot has something for you.
    @Test func aRowSaysWhen() {
        #expect(row(task("a", due: "2026-11-04T17:00:00-06:00"), .today).when == "5:00 PM")
        #expect(row(task("a", due: "2026-11-04"), .today).when == nil, "the heading says the day")
        let late = row(task("a", due: "2026-11-01"), .overdue)
        #expect(late.when == "Nov 1" && late.late)
        #expect(row(task("a", due: "2026-11-03"), .overdue).when == "Yesterday")
        #expect(row(task("a", due: "2026-11-06T09:00:00-06:00"), .day("2026-11-06")).when == "9:00 AM")
        // Where no heading says the day: today's time (or "Today") in red, then the day's name, then the date.
        let today = row(task("a", due: "2026-11-04T17:00:00-06:00"), .open)
        #expect(today.when == "5:00 PM" && today.late)
        #expect(row(task("a", due: "2026-11-04"), .open).when == "Today")
        #expect(row(task("a", due: "2026-11-05"), .open).when == "Tomorrow")
        #expect(row(task("a", due: "2026-11-09"), .open).when == "Mon")
        let far = row(task("a", due: "2026-11-16"), .open)
        #expect(far.when == "Nov 16" && !far.late)
        #expect(row(task("a"), .open).when == nil)
        #expect(row(task("a", status: "done", due: "2026-11-01", doneAt: "2026-11-04T08:00:00-06:00"), .done).when == "Today")
    }

    @Test func aRowMarksStepsAndRepeats() {
        let words = row(task("a", steps: [true, true, false, false], notes: "Bring the card", repeats: "weekly"), .open)
        #expect(words.steps == "2/4" && words.repeats)
        let plain = row(task("a"), .open)
        #expect(plain.steps == nil && !plain.repeats && plain.note == nil && plain.dot == nil)
    }

    /// The second line is the bot's, and only when it has something for you.
    @Test func theSecondLineIsOnlyWhatABotHasForYou() {
        let working = row(task("a", who: "together", bot: "default", status: "working", note: "Filling in the form"), .today)
        #expect(working.note == nil && working.dot == .working)
        let ready = row(task("a", who: "together", bot: "default", status: "ready", note: "Number and a Dec 9 slot"), .today)
        #expect(ready.note == "Hermes: Number and a Dec 9 slot" && ready.tone == .ready && ready.dot == .ready)
        #expect(row(task("a", who: "together", bot: "default", status: "ready"), .today).note == "Hermes finished its part")
        let asks = row(task("a", who: "bot", bot: "research", status: "needs_you", note: "What’s the budget?"), .waiting)
        #expect(asks.note == "Research asks: What’s the budget?" && asks.tone == .needsYou && asks.dot == .question)
        #expect(row(task("a", who: "bot", bot: "research", status: "needs_you", note: "Send the reply to Lee"), .waiting).note
                    == "Research needs you: Send the reply to Lee")
        #expect(row(task("a", who: "bot", bot: "research", status: "needs_you"), .waiting).note == "Research needs you")
        // A bot that hasn't started is a face with no dot and no line.
        let idle = row(task("a", who: "together", bot: "default"), .open)
        #expect(idle.note == nil && idle.dot == nil)
        // In Bots, what it is on.
        #expect(row(task("a", who: "bot", bot: "finance", status: "working", note: "3 of 5 accounts"), .bot("finance")).note == "3 of 5 accounts")
        // Still Need These?: who put it there, and when.
        let stale = row(task("a", created: "2026-10-20T08:00:00-05:00", by: "default"), .stale)
        #expect(stale.note == "Added by Hermes · Oct 20" && stale.tone == .plain)
    }

    @Test func headingsAndEmptyWords() {
        #expect(TodoViews.heading(.overdue, now: Self.now, botName: name)?.title == "Overdue")
        #expect(TodoViews.heading(.waiting, now: Self.now, botName: name)?.title == "Waiting on You")
        #expect(TodoViews.heading(.open, now: Self.now, botName: name) == nil)
        #expect(TodoViews.heading(.bot("finance"), now: Self.now, botName: name)?.title == "Finance")
        let tomorrow = TodoViews.dayHeading("2026-11-05", now: Self.now, calendar: Self.calendar)
        #expect(tomorrow.title == "Tomorrow" && tomorrow.detail == "Thu, Nov 5")
        let later = TodoViews.dayHeading("2026-11-07", now: Self.now, calendar: Self.calendar)
        #expect(later.title == "Sat, Nov 7" && later.detail == nil)
        #expect(TodoViews.emptyText(.list("work"), listName: "Work") == "No tasks in Work yet.")
        #expect(TodoViews.emptyText(.today, listName: nil) == "Nothing due today.")
        #expect(row(task("a", due: "2026-11-04T17:00:00-06:00", steps: [true, false]), .today).spoken == "5:00 PM, 1 of 2 steps")
    }

    // MARK: The task's page (step 2)

    /// The who row names the bot like a co-worker, and says what it is doing; a task of your own says "Me".
    @Test func theWhoRowNamesTheBotAndWhatItIsDoing() {
        #expect(TodoViews.who(task("a"), botName: name) == "Me")
        #expect(TodoViews.who(task("a", who: "together", bot: "default"), botName: name) == "Me & Hermes")
        #expect(TodoViews.who(task("a", who: "bot", bot: "finance"), botName: name) == "Finance")
        #expect(TodoViews.botState(task("a")) == nil, "a task of your own has no bot's state")
        #expect(TodoViews.botState(task("a", who: "together", bot: "default")) == nil, "a bot that hasn't started says nothing")
        let working = TodoViews.botState(task("a", who: "together", bot: "default", status: "working"))
        #expect(working?.words == "Working" && working?.tone == .working)
        let asks = TodoViews.botState(task("a", who: "bot", bot: "research", status: "needs_you"))
        #expect(asks?.words == "Has a question" && asks?.tone == .needsYou)
        let ready = TodoViews.botState(task("a", who: "together", bot: "default", status: "ready"))
        #expect(ready?.words == "Finished its part" && ready?.tone == .ready)
        #expect(TodoViews.botState(task("a", who: "together", bot: "default", status: "done")) == nil)
        // Its turn running in the task's chat is work, whatever the task last said.
        #expect(TodoViews.botState(task("a", who: "together", bot: "default", status: "needs_you"), running: true)?.words == "Working")
        #expect(TodoViews.hasTeammate(task("a", who: "bot", bot: "finance")) && !TodoViews.hasTeammate(task("a")))
    }

    /// Only an answer the bot waits on moves up under the who row; the rest of what it says stays at the foot.
    @Test func onlyAQuestionForYouMovesUp() {
        #expect(TodoViews.asksYou(task("a", who: "bot", bot: "research", status: "needs_you")))
        #expect(TodoViews.asksYou(task("a", who: "together", bot: "default", status: "ready", choices: ["Send it", "Wait a day"])))
        #expect(!TodoViews.asksYou(task("a", who: "together", bot: "default", status: "ready")), "finished, nothing to answer")
        #expect(!TodoViews.asksYou(task("a", who: "together", bot: "default", status: "working")))
        #expect(!TodoViews.asksYou(task("a", who: "bot", bot: "research", status: "done", choices: ["Yes"])))
        #expect(!TodoViews.asksYou(task("a", status: "needs_you")), "nobody to ask on a task of your own")
    }

    /// The bar on a task's page says its list, never a bot's name; plain "Task" for someone with no lists.
    @Test func theBarSaysTheTasksList() {
        #expect(TodoViews.listTitle(task("a", section: "work"), sections: lists) == "Work")
        #expect(TodoViews.listTitle(task("a"), sections: lists) == "No List")
        #expect(TodoViews.listTitle(task("a", section: "gone"), sections: lists) == "No List")
        #expect(TodoViews.listTitle(task("a", who: "bot", bot: "finance"), sections: []) == "Task")
    }

    // MARK: Jobs

    /// Tasks' own runners are not jobs you made; a job of yours with one of their names still shows.
    @Test func tasksRunnersStayOutOfJobs() throws {
        func job(_ name: String, _ prompt: String) throws -> CronJob {
            try #require(CronJob(json: .object(["id": .string(name), "name": .string(name), "prompt": .string(prompt)])))
        }
        #expect(TodoRunnerJobs.isOne(try job("Task prep", "Work through Tasks prep. Call tasks_next_prep. If it returns…")))
        #expect(TodoRunnerJobs.isOne(try job("Task check", "Work through Tasks prep. Call tasks_next_prep.")))
        #expect(TodoRunnerJobs.isOne(try job("Task ideas", "Find task ideas for the user. First call tasks_ideas…")))
        #expect(!TodoRunnerJobs.isOne(try job("Task check", "Check my open pull requests each morning.")))
        #expect(!TodoRunnerJobs.isOne(try job("Morning brief", "Work through Tasks prep.")))
    }
}
