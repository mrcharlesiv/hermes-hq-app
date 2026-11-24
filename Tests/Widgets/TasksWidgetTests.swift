// [tasks-widget] The Tasks widget's rules (docs/tasks.md item 12): its rows are the Tasks page's first screen (same
// order, same words, same headings) in every view it offers, its counts, the Lock Screen's words hold no task's name,
// its timeline moves at the moments the page's words change, what fits each size, its links, the store's round trip
// and sign-out, and the check circle's optimistic write and roll-back. Keychain items go under a test prefix.

import Foundation
import Testing
@testable import HermesHQNative

private let calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Chicago")!
    c.locale = Locale(identifier: "en_US")
    return c
}()
/// Wednesday 2026-11-04, 09:41 in Chicago (as TodoViewsTests).
private let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 9, minute: 41))!

private func task(_ id: String, title: String? = nil, who: String = "me", bot: String? = nil, status: String = "open",
                  note: String = "", due: String? = nil, section: String? = nil, steps: [Bool] = [], repeats: String? = nil,
                  updated: String = "2026-11-04T08:00:00-06:00", created: String = "2026-11-03T08:00:00-06:00",
                  doneAt: String? = nil, by: String? = nil, rev: Int = 3) -> TodoTask {
    var o: [String: JSONValue] = ["id": .string(id), "rev": .number(Double(rev)), "title": .string(title ?? id), "who": .string(who),
                                  "status": .string(status), "status_note": .string(note), "updated_at": .string(updated),
                                  "created_at": .string(created), "notes": "", "position": 0]
    if let bot { o["bot"] = .string(bot) }
    if let due { o["due"] = .string(due) }
    if let section { o["section"] = .string(section) }
    if let repeats { o["repeat"] = .string(repeats) }
    if let doneAt { o["done_at"] = .string(doneAt) }
    if let by { o["created_by"] = .string(by) }
    o["steps"] = .array(steps.enumerated().map { .object(["id": .string("s\($0.offset)"), "title": "x", "who": "me", "done": .bool($0.element)]) })
    return try! JSONDecoder().decode(TodoTask.self, from: JSONValue.object(o).encoded())
}

private let lists = [TodoUserSection(id: "work", name: "Work"), TodoUserSection(id: "home", name: "Home")]
private let bots = ["default", "finance", "research"]

private func name(_ profile: String?) -> String {
    ["default": "Hermes", "finance": "Finance", "research": "Research"][profile ?? "default"] ?? (profile ?? "")
}

/// TodoViewsTests' list: late, due today at times, a bot ready, one with a question, a bot's own work, lists, done.
private let list: [TodoTask] = [
    task("late", due: "2026-11-01"),
    task("cleaning", due: "2026-11-04T18:00:00-06:00"),
    task("apps", due: "2026-11-04T17:00:00-06:00", section: "work"),
    task("dentist", who: "together", bot: "default", status: "ready", note: "Number and a Dec 9 slot", due: "2026-11-04"),
    task("passport", who: "together", bot: "default", status: "working", due: "2026-11-04"),
    task("contract", who: "together", bot: "default", status: "ready", due: "2026-11-05T10:00:00-06:00", updated: "2026-11-04T09:00:00-06:00"),
    task("venues", who: "bot", bot: "research", status: "needs_you", note: "What’s the budget?", due: "2026-11-08",
         updated: "2026-11-04T09:30:00-06:00"),
    task("invoices", who: "bot", bot: "finance", status: "working", note: "3 of 5 accounts", due: "2026-11-04"),
    task("report", who: "bot", bot: "finance", due: "2026-11-06"),
    task("gift", who: "together", bot: "default", due: "2026-11-12"),
    task("porch"),
    task("desk", section: "home", steps: [true, false]),
    task("water", status: "done", due: "2026-11-04", doneAt: "2026-11-04T08:10:00-06:00"),
    task("flights", status: "done", section: "work", doneAt: "2026-11-01T08:10:00-06:00"),
    task("ledger", who: "bot", bot: "finance", status: "done", doneAt: "2026-11-04T07:00:00-06:00"),
]

private func input(_ tasks: [TodoTask] = list, ticking: Set<String> = []) -> TasksWidgetWriter.Input {
    TasksWidgetWriter.Input(tasks: tasks, sections: lists, bots: bots, sort: "smart", paused: [], ticking: ticking)
}

private func frame(_ view: TodoView, _ tasks: [TodoTask] = list, at: Date = now) -> TasksWidgetFrame {
    TasksWidgetWriter.frame(view, input: input(tasks), botName: name, at: at, calendar: calendar)
}

/// The widget's write runs on main whenever the list changes. Builds 1160–1249 re-parsed every task's dates inside
/// each sort comparison (a Done list of hundreds, per view, per frame) — about half a second on main every few
/// seconds on the owner's phone. A list his size must write all its views quickly.
struct TasksWidgetWriteCostTests {
    @Test func aLongDoneListWritesEveryViewQuickly() {
        let open = (0..<30).map { i in
            task("open\(i)", due: i % 3 == 0 ? "2026-11-0\(5 + i % 4)T1\(i % 10):00:00-06:00" : nil,
                 section: i % 2 == 0 ? "work" : "home",
                 updated: "2026-11-0\(1 + i % 3)T08:\(10 + i):00.\(100000 + i)+00:00",
                 created: "2026-10-2\(i % 10)T08:00:00.\(200000 + i)+00:00")
        }
        let done = (0..<400).map { i in
            task("done\(i)", status: "done", section: [nil, "work", "home"][i % 3],
                 updated: "2026-10-\(10 + i % 18)T09:\(10 + i % 50):00.\(300000 + i)+00:00",
                 created: "2026-09-\(10 + i % 18)T09:00:00.\(400000 + i)+00:00",
                 doneAt: "2026-10-\(10 + i % 18)T09:\(10 + i % 50):\(10 + i % 40).\(500000 + i)+00:00")
        }
        let made = input(open + done)
        let start = Date()
        var frames = 0
        for choice in TasksWidgetWriter.choices(tasks: made.tasks, sections: made.sections) {
            guard let view = TodoView(key: choice.id) else { continue }
            frames += TasksWidgetWriter.view(view, name: choice.name, input: made, botName: name, now: now, calendar: calendar).frames.count
        }
        let seconds = Date().timeIntervalSince(start)
        #expect(frames > 5)
        #expect(seconds < 1.0, "writing every view took \(seconds) s")   // 9.4 s before the dates were remembered
    }
}

struct TasksWidgetRowsTests {
    /// Today on the widget is Today on the page: Overdue, Today, Waiting on You, Next in Home, in that order with the
    /// page's rows (Done folded away, as the page folds it).
    @Test func todayIsThePagesFirstScreen() {
        let today = frame(.today)
        #expect(today.sections.map(\.title) == ["Overdue", "Today", "Waiting on You", "Next in Home"])
        #expect(today.sections.map { $0.rows.map(\.id) } == [["late"], ["dentist", "passport", "apps", "cleaning"], ["venues", "contract"], ["desk"]])
        #expect(today.sections.map(\.red) == [true, false, false, false])
        // The page's words: a time under Today's heading, the day in red when late, a bot's line in its tone, steps.
        let rows = Dictionary(uniqueKeysWithValues: today.sections.flatMap(\.rows).map { ($0.id, $0) })
        #expect(rows["cleaning"]?.when == "6:00 PM" && rows["cleaning"]?.late == false)
        #expect(rows["late"]?.late == true)
        #expect(rows["dentist"]?.note == "Hermes: Number and a Dec 9 slot" && rows["dentist"]?.tone == "ready")
        #expect(rows["venues"]?.note == "Research asks: What’s the budget?" && rows["venues"]?.tone == "needsYou")
        #expect(rows["desk"]?.steps == "1/2")
        #expect(rows["apps"]?.dot == nil, "Work has no colour")
        #expect(today.count == 7, "the Today pill's number")
        #expect(today.waiting == 3, "dentist, contract (ready) and venues (a question)")
        #expect(today.empty == "Nothing due today.")
    }

    /// Every view the widget offers lists what the page lists, in its order, with its headings and its row words.
    @Test func everyViewIsThePages() {
        for view in [TodoView.today, .upcoming, .inbox, .list("work"), .list("home"), .bots] {
            let groups = TodoViews.groups(list, view: view, sections: lists, bots: bots, now: now, calendar: calendar)
                .filter { $0.kind != .done }
            let made = frame(view)
            #expect(made.sections.map { $0.rows.map(\.id) } == groups.map { $0.tasks.map(\.id) }, "\(view.key)")
            #expect(made.sections.map(\.title) == groups.map { TodoViews.heading($0.kind, now: now, calendar: calendar, sections: lists, botName: name)?.title },
                    "\(view.key)")
            for group in groups {
                for task in group.tasks {
                    let words = TodoViews.row(task, in: group.kind, now: now, calendar: calendar, botName: name)
                    let row = made.sections.flatMap(\.rows).first { $0.id == task.id }
                    #expect(row?.when == words.when && row?.late == words.late && row?.note == words.note
                            && row?.tone == words.tone.rawValue && row?.steps == words.steps && row?.repeats == words.repeats
                            && row?.priority == words.priority, "\(view.key) \(task.id)")
                }
            }
            #expect(made.count == TodoViews.openCount(list, view: view, sections: lists, now: now, calendar: calendar))
        }
    }

    /// The row is the page's own row model's words (`TodoRowModel.make`, what the list draws), in this time zone.
    @Test func aRowIsThePagesRowModel() {
        let here = Date()
        for item in list where !item.isDone {
            let made = TasksWidgetWriter.row(item, kind: .open, now: here, calendar: .current, botName: name, dot: nil, ticked: false)
            let page = TodoRowModel.make(item, kind: .open, now: here, botName: name, head: nil)
            #expect(made.title == page.title && made.when == page.words.when && made.late == page.words.late
                    && made.note == page.words.note && made.steps == page.words.steps, "\(item.id)")
        }
    }

    /// Show offers what the page's pills offer: Today, Upcoming, Inbox, each list, and Bots once a bot has its own.
    @Test func showOffersThePagesPills() {
        #expect(TasksWidgetWriter.choices(tasks: list, sections: lists).map(\.id) == ["today", "upcoming", "inbox", "list:work", "list:home", "bots"])
        #expect(TasksWidgetWriter.choices(tasks: [task("porch")], sections: []).map(\.name) == ["Today", "Upcoming", "Inbox"])
    }

    /// A row ticked on the widget stays where it stood, ticked, while its save is on its way.
    @Test func aTickedRowStaysWhereItStood() {
        var ticked = list
        let at = ticked.firstIndex { $0.id == "cleaning" }!
        ticked[at].status = "open"
        let made = TasksWidgetWriter.frame(.today, input: input(ticked, ticking: ["cleaning"]), botName: name, at: now, calendar: calendar)
        let row = made.sections.flatMap(\.rows).first { $0.id == "cleaning" }
        #expect(row?.done == true)
        #expect(made.sections[1].rows.map(\.id) == ["dentist", "passport", "apps", "cleaning"])
    }

    @Test func countsAndTheHeadline() {
        let today = frame(.today)
        #expect(TasksWidgetLayout.headline(today, view: "Today") == (3, "Waiting on You", true))
        let mine = frame(.today, [task("late", due: "2026-11-01"), task("cleaning", due: "2026-11-04T18:00:00-06:00")])
        #expect(TasksWidgetLayout.headline(mine, view: "Today") == (2, "Today", false))
        let none = frame(.today, [task("porch")])
        #expect(none.count == 0 && none.sections.isEmpty && none.empty == "Nothing due today.")
    }
}

struct TasksWidgetLockTests {
    /// docs/tasks.md rule 6: no task's name ever goes on the Lock Screen, in any view, state or family.
    @Test func theLockScreenHoldsNoTaskName() {
        let titled = list.map { var t = $0; t.title = "Secret \($0.id) errand"; return t }
        for view in [TodoView.today, .upcoming, .inbox, .list("work"), .bots] {
            let made = TasksWidgetWriter.frame(view, input: input(titled), botName: name, at: now, calendar: calendar)
            let words = TasksWidgetLock.words(made, view: "Today", state: .live)
            let all = [words.number, words.label, words.inline] + words.lines
            for item in titled {
                #expect(!all.contains { $0.contains(item.title) || $0.contains("Secret") }, "\(view.key)")
                if let note = made.sections.flatMap(\.rows).first(where: { $0.id == item.id })?.note {
                    #expect(!all.contains { $0.contains(note) })
                }
            }
        }
        let today = TasksWidgetLock.words(frame(.today), view: "Today", state: .live)
        #expect(today.inline == "7 Today · 3 Waiting")
        #expect(today.lines == ["Tasks", "7 Today", "3 Waiting on You"])
        #expect(today.number == "3" && today.label == "Waiting")
        #expect(TasksWidgetLock.words(nil, view: "Today", state: .off).inline == "Tasks · Tasks off")
        #expect(TasksWidgetLock.words(frame(.today, [task("porch")]), view: "Today", state: .live).inline == "Tasks · All Done")
    }
}

struct TasksWidgetTimelineTests {
    /// The moments the page's words change by the clock: each midnight, each due time, a bot's task growing stale.
    @Test func theTimelineMovesWhenTheWordsDo() {
        let stale = task("old", updated: "2026-10-21T11:00:00-05:00", created: "2026-10-21T11:00:00-05:00", by: "default")
        let moments = TasksWidgetWriter.moments(list + [stale], now: now, calendar: calendar)
        func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
        #expect(moments.contains(at("2026-11-05T06:00:01Z")), "midnight in Chicago")
        #expect(moments.contains(at("2026-11-06T06:00:01Z")), "the next midnight")
        #expect(moments.contains(at("2026-11-05T00:00:01Z")), "cleaning's 6:00 PM")
        #expect(moments.contains(at("2026-11-04T23:00:01Z")), "apps's 5:00 PM")
        #expect(moments.contains(at("2026-11-04T16:00:01Z")), "old turns two weeks untouched")
        #expect(moments == moments.sorted() && moments.allSatisfy { $0 > now && $0 <= now.addingTimeInterval(48 * 3600) })

        // The frames: one now, a new one where the words change, none where they don't.
        let view = TasksWidgetWriter.view(.today, name: "Today", input: input(list + [stale]), botName: name, now: now, calendar: calendar)
        #expect(view.frames.first?.at == now)
        #expect(view.frames.count < moments.count + 1, "alike frames are one")
        let tomorrow = view.frame(at: at("2026-11-05T15:00:00Z"))!
        // At midnight cleaning and apps (due yesterday by then) are overdue, and the contract is due today.
        #expect(tomorrow.sections.first?.title == "Overdue")
        #expect(tomorrow.sections.first?.rows.map(\.id).contains("cleaning") == true)
        #expect(view.frame(at: now.addingTimeInterval(-60))?.at == now, "before the first: the first")
        let inbox = TasksWidgetWriter.view(.inbox, name: "Inbox", input: input(list + [stale]), botName: name, now: now, calendar: calendar)
        let staled = inbox.frame(at: at("2026-11-04T16:30:00Z"))!
        #expect(staled.sections.contains { $0.title == "Still Need These?" && $0.rows.contains { $0.id == "old" } })
    }
}

struct TasksWidgetLayoutTests {
    private func row(_ id: String, note: String? = nil) -> TasksWidgetRow { TasksWidgetRow(id: id, title: id, note: note) }

    @Test func whatFitsEachSize() {
        let f = TasksWidgetFrame(at: now, count: 7, waiting: 1, sections: [
            TasksWidgetSection(title: "Overdue", red: true, rows: [row("a")]),
            TasksWidgetSection(title: "Today", rows: [row("b", note: "Hermes finished its part"), row("c"), row("d")]),
            TasksWidgetSection(title: "Next in Home", rows: [row("e"), row("f")], more: 2),
        ], empty: "")
        #expect(f.total == 8)
        // Medium: four lines, no headings, a note takes two; one line kept for "+N more".
        let medium = TasksWidgetLayout.pick(f, lines: 4, headings: false, notes: true)
        #expect(medium.sections.flatMap(\.rows).map(\.id) == ["a", "b"] && medium.hidden == 6)
        #expect(medium.sections.allSatisfy { $0.title == nil })
        // Large: headings, every row in the room.
        let large = TasksWidgetLayout.pick(f, lines: 11, headings: true, notes: true)
        #expect(large.sections.map(\.title) == ["Overdue", "Today", "Next in Home"])
        #expect(large.sections.flatMap(\.rows).count == 6 && large.hidden == 2, "Home's 2 more the page doesn't list either")
        // A heading never stands alone at the foot.
        let tight = TasksWidgetLayout.pick(f, lines: 7, headings: true, notes: true)
        #expect(tight.sections.last?.rows.isEmpty == false)
        #expect(tight.sections.map(\.title) == ["Overdue", "Today"] && tight.hidden == 5)
        // Small: three names and "+N more" (its four lines, measured).
        let small = TasksWidgetLayout.pick(f, lines: TasksWidgetLayout.lines(.small), headings: false, notes: false)
        #expect(small.sections.flatMap(\.rows).map(\.id) == ["a", "b", "c"] && small.hidden == 5)
        #expect(TasksWidgetLayout.moreLine(6) == "+6 more")
        let all = TasksWidgetFrame(at: now, count: 1, waiting: 0, sections: [TasksWidgetSection(rows: [row("a")])], empty: "")
        #expect(TasksWidgetLayout.pick(all, lines: 3, headings: false, notes: false).hidden == 0)
    }

    @Test func tasksLinksParse() throws {
        let url = try #require(WidgetLink.task(id: "t_42", account: "fedcba9876543210").url(scheme: "hermes"))
        #expect(url.absoluteString == "hermes://widget/task?id=t_42&account=fedcba9876543210")
        #expect(WidgetLink.parse(url, scheme: "hermes") == .task(id: "t_42", account: "fedcba9876543210"))
        #expect(WidgetLink.parse(URL(string: "hermes://widget/tasks")!, scheme: "hermes") == .tasks)
        #expect(WidgetLink.parse(URL(string: "hermes://widget/new-task")!, scheme: "hermes") == .newTask)
        #expect(WidgetLink.parse(URL(string: "hermes://widget/task?id=t%2F..&account=fedcba9876543210")!, scheme: "hermes") == nil)
        #expect(WidgetLink.parse(URL(string: "hermes://widget/task?id=t_42")!, scheme: "hermes") == nil, "no account")
    }
}

// MARK: - Keychain and the check circle (serialized with the Tile store's suite: one test prefix at a time)

private func withTasksVault(_ body: () async throws -> Void) async rethrows {
    let saved = WidgetVault.testPrefix
    WidgetVault.testPrefix = "ai.hermes.hq.widget-test-\(UUID().uuidString.prefix(8))."
    defer {
        TasksWidgetStore.removeAll()
        TileWidgetStore.removeAll()
        WidgetVault.testPrefix = saved
    }
    try await body()
}

extension TileWidgetStoreTests {
    /// A write a minute later with nothing new is not a change: no keychain write, no widget reload (builds
    /// 1160–1249 rewrote every view on each list change because the first frame carries the moment of writing).
    @Test func tasksStoreKeepsAViewThatDiffersOnlyInItsFirstStamp() async {
        await withTasksVault {
            let first = TasksWidgetWriter.view(.today, name: "Today", input: input(), botName: name, now: now, calendar: calendar)
            let later = TasksWidgetWriter.view(.today, name: "Today", input: input(), botName: name,
                                               now: now.addingTimeInterval(60), calendar: calendar)
            #expect(first != later, "the stamp moved")
            #expect(TasksWidgetStore.saveView(first) == .written)
            #expect(TasksWidgetStore.saveView(later) == .unchanged)
            #expect(TasksWidgetStore.loadView("today") == first, "the kept view stays as written")
            let edited = TasksWidgetWriter.view(.today, name: "Today", input: input(list + [task("new", due: "2026-11-04")]),
                                                botName: name, now: now.addingTimeInterval(60), calendar: calendar)
            #expect(TasksWidgetStore.saveView(edited) == .written, "a real change still writes")
            let older = TasksWidgetWriter.view(.today, name: "Today", input: input(list + [task("new", due: "2026-11-04")]),
                                               botName: name, now: now, calendar: calendar)
            #expect(TasksWidgetStore.saveView(older) == .written, "an earlier stamp is written, never skipped")
        }
    }

    @Test func tasksStoreRoundTripsAndSignsOut() async {
        await withTasksVault {
            let view = TasksWidgetWriter.view(.today, name: "Today", input: input(), botName: name, now: now, calendar: calendar)
            #expect(TasksWidgetStore.saveView(view) == .written)
            #expect(TasksWidgetStore.saveView(view) == .unchanged, "the same bytes: nothing written, nothing reloaded")
            #expect(TasksWidgetStore.loadView("today") == view)
            let index = TasksWidgetIndex(state: .live, scheme: "hermes", account: "acct", views: [.init(id: "today", name: "Today")])
            #expect(TasksWidgetStore.saveIndex(index))
            #expect(TasksWidgetStore.loadIndex() == index)
            #expect(TasksWidgetStore.keepViews(["today"]) == false)
            #expect(TasksWidgetStore.quiet(.signedOut, scheme: "hermes"))
            #expect(TasksWidgetStore.loadView("today") == nil, "signed out: no task stays")
            #expect(TasksWidgetStore.loadIndex()?.state == .signedOut && TasksWidgetStore.loadIndex()?.views.isEmpty == true)
            #expect(!TasksWidgetStore.quiet(.signedOut, scheme: "hermes"), "already quiet: nothing to reload")
        }
    }

    /// The check circle: the row shows ticked at once (written before the gateway answers), then leaves the list; a
    /// refused save puts it back as it was.
    @Test @MainActor func checkOffIsOptimisticAndRollsBack() async {
        await withTasksVault {
            let one = task("t_1", title: "Pick up the dry cleaning", due: TodoViews.dayKey(Date()))
            let wire = try! JSONValue.parse(JSONEncoder().encode(one))
            let client = PagesFakeClient { _ in .object(["rev": 1, "tasks": .array([wire])]) }
            let store = TasksStore(api: TasksAPI(client: client), account: client.account, directory: nil)
            await store.refresh()
            let writer = TasksWidgetWriter(enabled: true, store: { store })
            writer.holdTicked = 0
            writer.attach(account: client.account) { [] }
            #expect(writer.write(reason: "test"))
            func today() -> [TasksWidgetRow] { TasksWidgetStore.loadView("today")?.frame(at: Date())?.sections.flatMap(\.rows) ?? [] }
            #expect(today().map(\.id) == ["t_1"] && today().first?.done == false)
            let key = TileWidgetIndex.key(client.account.id)

            // Refused: shown ticked while the save is on its way, then back.
            client.respond { request in
                guard request.method == "PATCH" else { return .object([:]) }
                try await Task.sleep(for: .seconds(2))
                throw httpError(500, "boom")
            }
            let refused = Task { await writer.checkOff("t_1", account: key) }
            // Seen before the gateway answers (a busy run can be slow to start the tap's task: up to 1.5 s, the save takes 2).
            var ticked = false
            for _ in 0..<30 where !ticked {
                try? await Task.sleep(for: .milliseconds(50))
                ticked = today().first?.done == true
            }
            #expect(ticked, "ticked at once, where it stood")
            #expect(await refused.value == false)
            #expect(today().map(\.id) == ["t_1"] && today().first?.done == false, "put back")

            // Another account's widget: nothing happens.
            #expect(await writer.checkOff("t_1", account: "0000000000000000") == false)
            #expect(client.log.filter { $0.method == "PATCH" }.count == 1)

            // Saved: the row leaves the list (Done is folded away).
            var done = one; done.status = "done"; done.rev = 4; done.doneAt = TodoDates.now()
            let doneWire = try! JSONValue.parse(JSONEncoder().encode(done))
            client.respond { request in request.method == "PATCH" ? doneWire : .object(["rev": 2, "tasks": .array([doneWire])]) }
            #expect(await writer.checkOff("t_1", account: key))
            #expect(today().isEmpty)
            #expect(client.log.last?.body?["status"]?.string == "done", "the page's own save: status done")
            writer.signedOut()
            #expect(TasksWidgetStore.loadView("today") == nil && TasksWidgetStore.loadIndex()?.state == .signedOut)
        }
    }
}
