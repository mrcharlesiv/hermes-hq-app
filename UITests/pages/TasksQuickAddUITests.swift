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
        tapView("inbox")
        plus.tap()
        let title = app.textViews["tasks.new.title"].firstMatch.exists ? app.textViews["tasks.new.title"].firstMatch : app.textFields["tasks.new.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the quick add opens with the keys up")
        XCTAssertTrue(app.cells["task-row-Fix the porch light"].firstMatch.exists, "the list is still behind it")
        XCTAssertTrue(app.navigationBars["New Task"].exists, "the native sheet navigation bar is present")
        XCTAssertTrue(app.navigationBars.buttons["tasks.new.add"].firstMatch.exists)
        XCTAssertTrue(app.buttons["sheet.close"].firstMatch.exists)
        let due = app.descendants(matching: .any)["tasks.new.due"].firstMatch
        XCTAssertTrue(due.waitForExistence(timeout: 5) && app.buttons["tasks.new.person.you"].firstMatch.exists, "date chip and who strip are directly visible")
        XCTAssertTrue(app.descendants(matching: .any)["tasks.new.notes"].firstMatch.exists, "notes field is directly visible")
        XCTAssertTrue(app.descendants(matching: .any)["tasks.new.priority"].firstMatch.exists, "priority, on an add-on that keeps it")
        XCTAssertEqual(due.label, "Date", "no date yet")
        shot("quick-add-1-empty" + Self.lookName)

        // The date is read from the words; the name loses them.
        title.tap()
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
        title.tap()
        title.typeText("Friday report")
        XCTAssertTrue(waitUntil(5) { due.label.hasPrefix("Due") }, "friday is read: \(due.label)")
        due.tap()
        let today = app.buttons["Today"].firstMatch
        XCTAssertTrue(today.waitForExistence(timeout: 5), "the date button's menu")
        today.tap()
        XCTAssertTrue(waitUntil(5) { due.label.contains("Today") }, due.label)
        app.buttons["tasks.new.add"].firstMatch.tap()
        XCTAssertTrue(waitUntil(10) { posted("Friday report") != nil }, "the name keeps its words once the date is picked by hand")

        // The explicit close control dismisses the sheet.
        app.buttons["sheet.close"].firstMatch.tap()
        XCTAssertTrue(waitUntil(5) { !title.exists }, "a tap on the list behind closes the quick add")
        XCTAssertTrue(app.cells["task-row-Friday report"].firstMatch.waitForExistence(timeout: 5) || app.buttons["tasks.view.today"].exists)
    }
    @MainActor func testTasks_QuickAddDiscardGuard() throws {
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        let plus = app.buttons["tasks.new"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 20))
        plus.tap()
        let title = app.textFields["tasks.new.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.typeText("An unfinished task")
        app.buttons["sheet.close"].firstMatch.tap()
        let discard = app.buttons["Discard Changes"].firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        XCTAssertTrue(title.exists)
        discard.tap()
        XCTAssertTrue(waitUntil(5) { !title.exists })
    }
    @MainActor func testTasks_QuickAddLiteralTitle() throws {
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        let plus = app.buttons["tasks.new"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 20))
        tapView("inbox")
        plus.tap()
        let title = app.textFields["tasks.new.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.typeText("Review P1 #123")
        let preview = app.descendants(matching: .any)["tasks.new.read"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.label.contains("Review"))
        let literal = app.buttons["tasks.new.literal"].firstMatch
        if !literal.isHittable { app.swipeUp() }
        XCTAssertTrue(literal.waitForExistence(timeout: 5))
        // A tap right after a swipe can only stop the scroll: tap again if the switch hasn't taken.
        let exact = app.staticTexts["Using your title exactly as typed"].firstMatch
        literal.tap()
        if !exact.waitForExistence(timeout: 2) { literal.tap() }
        XCTAssertTrue(exact.waitForExistence(timeout: 3), "Keep literal switches the preview to the exact words")
        XCTAssertFalse(requests().contains { $0.method == "POST" && $0.path.hasSuffix("/tasks") })
        app.buttons["tasks.new.add"].firstMatch.tap()
        let posted = { self.requests().first { $0.method == "POST" && $0.path.hasSuffix("/tasks") && ($0.body?["title"] as? String) == "Review P1 #123" } }
        XCTAssertTrue(waitUntil(10) { posted() != nil })
        XCTAssertNil(posted()?.body?["priority"])
        XCTAssertNil(posted()?.body?["tags"])
    }

    @MainActor func testTasks_QuickAddDisclosureAndSubmit() throws {
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        let plus = app.buttons["tasks.new"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 20))
        tapView("inbox")
        plus.tap()
        let title = app.textViews["tasks.new.title"].firstMatch.exists ? app.textViews["tasks.new.title"].firstMatch : app.textFields["tasks.new.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let notes = app.descendants(matching: .any)["tasks.new.notes"].firstMatch
        XCTAssertTrue(notes.exists, "notes field is directly visible")
        title.typeText("work on first video #content")
        XCTAssertTrue(app.descendants(matching: .any)["tasks.new.read"].firstMatch.waitForExistence(timeout: 5))
        shot("quick-add-room-expanded")
        app.buttons["tasks.new.add"].firstMatch.tap()
        XCTAssertTrue(waitUntil(10) { self.requests().contains { $0.method == "POST" && $0.path.hasSuffix("/tasks") && ($0.body?["title"] as? String) == "work on first video" && ($0.body?["tags"] as? [String]) == ["content"] } })
    }

}
