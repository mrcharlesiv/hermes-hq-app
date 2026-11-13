// [tasks-first] Step 4 (owner 2026-11-12, mockup 5-new-task: "New Task: type it and go"): + opens a small sheet over the
// keyboard with the list behind it. The line's date, time and tags are read as it is typed; Add leaves the sheet open
// for the next task. Run with scripts/e2e-pages.sh (HQN_PAGES_ONLY=testTasks_QuickAdd); HQN_TASKS_LOOK picks the look.

import XCTest

extension PagesTests {
    @MainActor func testTasks_QuickAdd() throws {
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        let plus = app.buttons["tasks.new"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 20), "the page has +")
        // From Inbox, so a new task has no date until the line gives it one.
        app.buttons["tasks.view.inbox"].firstMatch.tap()
        plus.tap()
        let title = app.textViews["tasks.new.title"].firstMatch.exists ? app.textViews["tasks.new.title"].firstMatch : app.textFields["tasks.new.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the quick add opens with the keys up")
        XCTAssertTrue(app.cells["task-row-Fix the porch light"].firstMatch.exists, "the list is still behind it")
        XCTAssertFalse(app.navigationBars["New Task"].exists, "a small sheet, not a page")
        let due = app.descendants(matching: .any)["tasks.new.due"].firstMatch
        XCTAssertTrue(due.exists && app.descendants(matching: .any)["tasks.new.bot"].firstMatch.exists, "the buttons: date and who")
        XCTAssertTrue(app.descendants(matching: .any)["tasks.new.priority"].firstMatch.exists, "priority, on an add-on that keeps it")
        XCTAssertEqual(due.label, "Date", "no date yet")
        shot("quick-add-1-empty" + Self.lookName)

        // The date is read from the words; the name loses them.
        title.typeText("Call mom tomorrow 9am #family")
        XCTAssertTrue(waitUntil(5) { due.label.contains("Tomorrow 9:00") }, "the date button says what was read: \(due.label)")
        let read = app.descendants(matching: .any)["tasks.new.read"].firstMatch
        XCTAssertTrue(read.exists && read.label.contains("Call mom"), "it says the name the task will have")
        shot("quick-add-2-read" + Self.lookName)
        app.buttons["tasks.new.add"].firstMatch.tap()
        let posted = { (name: String) in self.requests().first { $0.method == "POST" && $0.path.hasSuffix("/tasks") && ($0.body?["title"] as? String) == name } }
        XCTAssertTrue(waitUntil(10) { posted("Call mom") != nil }, "added under the name without the date words")
        let body = posted("Call mom")?.body ?? [:]
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: tomorrow)
        let day = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        XCTAssertTrue((body["due"] as? String ?? "").hasPrefix(day + "T09:00"), "due tomorrow at 9: \(body["due"] ?? "nil")")
        XCTAssertEqual(body["tags"] as? [String], ["family"])
        XCTAssertEqual(body["who"] as? String, "me")

        // The sheet stays for the next one, its line empty, and says what went in.
        XCTAssertTrue(app.descendants(matching: .any)["tasks.new.added"].firstMatch.waitForExistence(timeout: 5), "Added “Call mom”")
        XCTAssertTrue(title.exists, "the sheet is still open")
        XCTAssertTrue(waitUntil(3) { due.label == "Date" }, "the date starts over: \(due.label)")
        shot("quick-add-3-added" + Self.lookName)

        // A date picked by hand wins, and the words stay in the name.
        title.typeText("Friday report")
        XCTAssertTrue(waitUntil(5) { due.label.hasPrefix("Due") }, "friday is read: \(due.label)")
        due.tap()
        let today = app.buttons["Today"].firstMatch
        XCTAssertTrue(today.waitForExistence(timeout: 5), "the date button's menu")
        today.tap()
        XCTAssertTrue(waitUntil(5) { due.label.contains("Today") }, due.label)
        app.buttons["tasks.new.add"].firstMatch.tap()
        XCTAssertTrue(waitUntil(10) { posted("Friday report") != nil }, "the name keeps its words once the date is picked by hand")

        // A tap outside closes it.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(waitUntil(5) { !title.exists }, "a tap on the list behind closes the quick add")
        XCTAssertTrue(app.cells["task-row-Friday report"].firstMatch.waitForExistence(timeout: 5) || app.buttons["tasks.view.today"].exists)
    }
}
