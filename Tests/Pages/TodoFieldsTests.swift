// [tasks-first] Step 3 (owner 2026-11-12: "complex enough to handle any task or use case"): what a task manager's
// task has, kept by hermes-hq-push 0.9.53: a priority, tags, an alert before it's due, a start day, and your own
// files and links. How they are read, where a task with a start day shows, how a list sorts by priority, when the
// phone rings, and what a row says.

import Foundation
import Testing
@testable import HermesHQNative

struct TodoFieldsTests {
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        c.locale = Locale(identifier: "en_US")
        return c
    }()
    /// Wednesday 2026-11-04, 09:41 in Chicago.
    private static let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 9, minute: 41))!

    private func task(_ id: String, _ more: [String: JSONValue] = [:]) -> TodoTask {
        var o: [String: JSONValue] = ["id": .string(id), "title": .string(id), "who": "me", "status": "open",
                                      "updated_at": "2026-11-04T08:00:00-06:00", "created_at": "2026-11-03T08:00:00-06:00"]
        for (key, value) in more { o[key] = value }
        return try! JSONDecoder().decode(TodoTask.self, from: JSONValue.object(o).encoded())
    }

    private func groups(_ tasks: [TodoTask], _ view: TodoView, sort: String = "smart") -> [(TodoGroupKind, [String])] {
        TodoViews.groups(tasks, view: view, sections: [TodoUserSection(id: "work", name: "Work")], bots: ["default"], now: Self.now,
                         sort: sort, calendar: Self.calendar).map { ($0.kind, $0.tasks.map(\.id)) }
    }

    /// What the add-on sends is read leniently: an older add-on sends none of it, a wrong value is no value.
    @Test func theFieldsAreRead() {
        let plain = task("a")
        #expect(plain.priority == 0 && plain.tags.isEmpty && plain.alert == nil && plain.starts == nil)
        let full = task("b", ["priority": 1, "tags": [" hiring ", "q4", ""], "alert": 30, "starts": "2026-11-10",
                              "made": [["id": "m1", "title": "brief.pdf", "kind": "file", "ref": "/x/brief.pdf", "by": "you"],
                                       ["id": "m2", "title": "Draft", "kind": "note", "ref": "Hi", "by": "default"],
                                       ["id": "m3", "title": "Old", "kind": "note", "ref": "Hi"]]])
        #expect(full.priority == 1 && full.tags == ["hiring", "q4"] && full.alert == 30 && full.starts == "2026-11-10")
        #expect(full.made.map(\.isYours) == [true, false, false], "only what you attached is yours")
        #expect(task("c", ["priority": 9, "alert": -5, "starts": ""]).priority == 0)
        #expect(task("c", ["priority": 9, "alert": -5, "starts": ""]).alert == nil)
        #expect(task("c", ["priority": 9, "alert": -5, "starts": ""]).starts == nil)
    }

    /// A start day: until then the task waits under Upcoming on that day; from then on it is in Today until it's due.
    @Test func aStartDayDecidesWhereItShows() {
        let tasks = [
            task("waits", ["starts": "2026-11-10", "due": "2026-11-20"]),
            task("started", ["starts": "2026-11-02", "due": "2026-11-20"]),
            task("open-ended", ["starts": "2026-11-03"]),
            task("someday", ["starts": "2026-11-09"]),
            task("late", ["starts": "2026-10-20", "due": "2026-11-01"]),
            task("plain", ["due": "2026-11-20"]),
            task("loose"),
        ]
        let today = groups(tasks, .today)
        #expect(today.first { $0.0 == .overdue }?.1 == ["late"])
        #expect(Set(today.first { $0.0 == .today }?.1 ?? []) == ["started", "open-ended"], "started and not due yet")
        let upcoming = groups(tasks, .upcoming)
        #expect(upcoming.first { $0.0 == .day("2026-11-10") }?.1 == ["waits"], "under the day it starts, not the day it's due")
        #expect(upcoming.first { $0.0 == .day("2026-11-09") }?.1 == ["someday"])
        #expect(upcoming.first { $0.0 == .day("2026-11-20") }?.1 == ["plain"], "one that has started is in Today, not here")
        let inbox = groups(tasks, .inbox).flatMap(\.1)
        #expect(inbox == ["loose"], "a task with a start day has a place in your day")
    }

    /// What its row says when: under Today, when it's due; under the day it starts, "Due" and the day.
    @Test func aStartedTasksRowSaysWhenItIsDue() {
        let name: (String?) -> String = { _ in "Hermes" }
        let started = TodoViews.row(task("a", ["starts": "2026-11-02", "due": "2026-11-20"]), in: .today, now: Self.now,
                                    calendar: Self.calendar, botName: name)
        #expect(started.when == "Nov 20")
        let waits = TodoViews.row(task("a", ["starts": "2026-11-10", "due": "2026-11-20"]), in: .day("2026-11-10"), now: Self.now,
                                  calendar: Self.calendar, botName: name)
        #expect(waits.when == "Due Nov 20")
        #expect(TodoViews.startWords(task("a", ["starts": "2026-11-05"]), now: Self.now, calendar: Self.calendar) == "Starts tomorrow")
        #expect(TodoViews.startWords(task("a", ["starts": "2026-11-04"]), now: Self.now, calendar: Self.calendar) == "Starts today")
        #expect(TodoViews.startWords(task("a", ["starts": "2026-11-07"]), now: Self.now, calendar: Self.calendar) == "Starts Sat")
        #expect(TodoViews.startWords(task("a", ["starts": "2026-11-03"]), now: Self.now, calendar: Self.calendar) == "Started yesterday")
        #expect(TodoViews.startWords(task("a", ["starts": "2026-10-20"]), now: Self.now, calendar: Self.calendar) == "Started Oct 20")
        #expect(TodoViews.startWords(task("a"), now: Self.now, calendar: Self.calendar) == nil)
    }

    /// A row carries its priority (the circle's colour) while it is open, and its tags in a list and Inbox only.
    @Test func aRowCarriesItsPriorityAndTags() {
        let name: (String?) -> String = { _ in "Hermes" }
        let it = task("a", ["priority": 1, "tags": ["hiring", "q4", "ops"], "due": "2026-11-04"])
        let listed = TodoViews.row(it, in: .open, now: Self.now, calendar: Self.calendar, botName: name)
        #expect(listed.priority == 1 && listed.tags == ["hiring", "q4"], "two tags at most on a row")
        #expect(listed.spoken.contains("High priority"))
        let dated = TodoViews.row(it, in: .today, now: Self.now, calendar: Self.calendar, botName: name)
        #expect(dated.priority == 1 && dated.tags.isEmpty)
        let done = TodoViews.row(task("a", ["priority": 1, "status": "done", "done_at": "2026-11-04T08:00:00-06:00"]), in: .done,
                                 now: Self.now, calendar: Self.calendar, botName: name)
        #expect(done.priority == 0, "a finished task's circle is plain")
        #expect(TodoViews.priorityWord(1) == "High" && TodoViews.priorityWord(2) == "Medium" && TodoViews.priorityWord(3) == "Low")
    }

    /// Sort By › Priority: high, medium, low, then none; your own order inside each.
    @Test func aListSortsByPriority() {
        let tasks = [
            task("none", ["section": "work", "position": 1]),
            task("low", ["section": "work", "position": 2, "priority": 3]),
            task("high-b", ["section": "work", "position": 4, "priority": 1]),
            task("medium", ["section": "work", "position": 3, "priority": 2]),
            task("high-a", ["section": "work", "position": 0.5, "priority": 1]),
        ]
        let sorted = groups(tasks, .list("work"), sort: "priority").first { $0.0 == .open }?.1
        #expect(sorted == ["high-a", "high-b", "medium", "low", "none"])
    }

    /// Tags as typed in one field.
    @Test func tagsAreReadFromOneField() {
        #expect(TodoViews.tags(from: "hiring, q4") == ["hiring", "q4"])
        #expect(TodoViews.tags(from: " #hiring ,, Q4,hiring, ") == ["hiring", "Q4"], "a # is dropped; each once")
        #expect(TodoViews.tags(from: "").isEmpty)
        #expect(TodoViews.tags(from: (1...14).map { "t\($0)" }.joined(separator: ",")).count == 10)
        #expect(TodoViews.tags(from: String(repeating: "x", count: 50)) == [String(repeating: "x", count: 30)])
    }

    /// Search finds a task by its tag; "#word" looks at tags alone.
    @Test func searchFindsATag() {
        let tasks = [task("a", ["tags": ["hiring"]]), task("b", ["notes": "about hiring"]), task("c")]
        #expect(TodoSections.filtered(tasks, scope: "all", query: "hiring").map(\.id) == ["a", "b"])
        #expect(TodoSections.filtered(tasks, scope: "all", query: "#hir").map(\.id) == ["a"])
    }

    /// The phone rings `alert` minutes before a task is due (a day alone is due at 9:00), and says how far off it is.
    @Test func theAlertRingsAhead() throws {
        let timed = task("a", ["due": "2026-11-05T10:30:00-06:00", "alert": 30])
        let at = try #require(TodoReminder.time(timed, calendar: Self.calendar))
        #expect(Self.calendar.dateComponents([.day, .hour, .minute], from: at) == DateComponents(day: 5, hour: 10, minute: 0))
        #expect(TodoReminder.body(timed) == "Due in 30 min")
        let day = task("a", ["due": "2026-11-05", "alert": 1440])
        let before = try #require(TodoReminder.time(day, calendar: Self.calendar))
        #expect(Self.calendar.dateComponents([.day, .hour, .minute], from: before) == DateComponents(day: 4, hour: 9, minute: 0))
        #expect(TodoReminder.body(day) == "Due tomorrow")
        #expect(TodoReminder.body(task("a", ["due": "2026-11-05T10:30:00-06:00", "alert": 60])) == "Due in 1 hour")
        let plain = task("a", ["due": "2026-11-05T10:30:00-06:00"])
        #expect(TodoReminder.time(plain, calendar: Self.calendar) == TodoDates.due(plain.due, calendar: Self.calendar)?.date)
        #expect(TodoReminder.body(task("a", ["due": "2026-11-05T10:30:00-06:00", "alert": 0])) == "Due now", "0 is at its time")
        #expect(TodoReminder.alertWords(5) == "5 min before" && TodoReminder.alertWords(120) == "2 hours before")
        #expect(TodoReminder.alertWords(1440) == "1 day before" && TodoReminder.alertWords(2880) == "2 days before")
    }

    /// The list answer says what the add-on keeps: an older one says nothing, and the rows stay away.
    @Test func theListSaysWhatTheAddOnKeeps() throws {
        let old = try JSONDecoder().decode(TodoListAnswer.self, from: Data(#"{"rev": 1, "tasks": []}"#.utf8))
        #expect(!old.fields && !old.files)
        let new = try JSONDecoder().decode(TodoListAnswer.self, from: Data(#"{"rev": 1, "tasks": [], "fields": true, "files": true}"#.utf8))
        #expect(new.fields && new.files)
        #expect(PushPolicy.taskFields(["task_fields": true]) && !PushPolicy.taskFields(["tasks": true]) && !PushPolicy.taskFields(nil))
    }
}
