// Visual tour for the redesigned New Task sheet with structured Schedule and Organize sections
// plus the visual Who's Involved face strip right under Title & Notes.

import XCTest

extension PagesTests {
    @MainActor func testTasks_NewTaskRedesignShots() throws {
        try account.control("/__fixture/tasks-mode", ["lists": true, "goals": true])
        defer { _ = try? account.control("/__fixture/tasks-mode", ["lists": false, "goals": false]) }

        // Light mode: top of sheet (Title + Notes + Who's involved + Schedule)
        app = launchSignedIn(["-hqn.appearance", "light", "-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        let plus = app.buttons["tasks.new"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 20))
        plus.tap()
        let title = app.textViews["tasks.new.title"].firstMatch.exists ? app.textViews["tasks.new.title"].firstMatch : app.textFields["tasks.new.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["tasks.new.person.default"].firstMatch.waitForExistence(timeout: 5))
        shot("new-task-v3-1-top")

        // Type natural language + pick Hermes (tapping Hermes is immediately above the keyboard!)
        title.typeText("Call mom tomorrow 9am #family")
        _ = app.descendants(matching: .any)["tasks.new.read"].firstMatch.waitForExistence(timeout: 5)
        app.buttons["tasks.new.person.default"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Work together"].waitForExistence(timeout: 5))
        shot("new-task-v3-2-bot")
        // Scroll down to show Schedule & Organize cleanly
        app.swipeUp()
        XCTAssertTrue(app.descendants(matching: .any)["tasks.new.due"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["tasks.new.tags"].firstMatch.waitForExistence(timeout: 5))
        shot("new-task-v3-3-schedule-organize")

        // Dark mode: filled + scrolled to show Schedule & Organize
        app.terminate()
        app = launchSignedIn(["-hqn.appearance", "dark", "-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        XCTAssertTrue(app.buttons["tasks.new"].firstMatch.waitForExistence(timeout: 20))
        app.buttons["tasks.new"].firstMatch.tap()
        let darkTitle = app.textViews["tasks.new.title"].firstMatch.exists ? app.textViews["tasks.new.title"].firstMatch : app.textFields["tasks.new.title"].firstMatch
        XCTAssertTrue(darkTitle.waitForExistence(timeout: 10))
        darkTitle.typeText("Prepare Q4 review friday 2pm !high #work")
        _ = app.descendants(matching: .any)["tasks.new.read"].firstMatch.waitForExistence(timeout: 5)
        app.swipeUp()
        XCTAssertTrue(app.descendants(matching: .any)["tasks.new.priority"].firstMatch.waitForExistence(timeout: 5))
        shot("new-task-v3-4-dark")
    }
}
