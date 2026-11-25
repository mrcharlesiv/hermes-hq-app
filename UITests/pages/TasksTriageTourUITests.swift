// Live visual tour of the four upgraded Tasks surfaces: Today & Overdue triage, Compact Quick Capture,
// Upcoming multi-week + Filter menu + Completed Logbook, and Task Detail steps + Tag Picker.

import XCTest

extension PagesTests {
    @MainActor func testTasks_TriageVisualTour() throws {
        try account.control("/__fixture/tasks-mode", ["lists": true, "goals": true])
        defer { _ = try? account.control("/__fixture/tasks-mode", ["lists": false, "goals": false]) }

        // 1. Today & Overdue Triage (Reschedule menu on Overdue, priority-ordered Today)
        app = launchSignedIn(["-hqn.appearance", "light", "-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        let plus = app.buttons["tasks.new"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 20), "Tasks page loaded")
        _ = waitUntil(5) { self.app.cells.count > 2 }
        shot("live-1-today")

        // 2. Compact New Task Quick Capture (over keyboard, live parsed line, visible notes, task chips, Just Me footer)
        plus.tap()
        let title = app.textViews["tasks.new.title"].firstMatch.exists ? app.textViews["tasks.new.title"].firstMatch : app.textFields["tasks.new.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "Quick capture opened")
        title.typeText("Call mom tomorrow 9am #family")
        _ = app.descendants(matching: .any)["tasks.new.read"].firstMatch.waitForExistence(timeout: 5)
        shot("live-2-quick-add")
        app.buttons["sheet.close"].firstMatch.tap()
        let discard = app.buttons["Discard Changes"].firstMatch
        if discard.waitForExistence(timeout: 3) { discard.tap() }
        _ = waitUntil(5) { !title.exists }

        // 3. Upcoming Multi-Week Strip (month header, week arrows, Today jump button)
        tapView("upcoming")
        let nextWeek = app.buttons["tasks.week.next"].firstMatch
        XCTAssertTrue(nextWeek.waitForExistence(timeout: 8), "multi-week strip loaded")
        nextWeek.tap()
        _ = app.buttons["tasks.week.today"].firstMatch.waitForExistence(timeout: 3)
        shot("live-3-upcoming")
        app.buttons["tasks.week.today"].firstMatch.tap()

        // 4. Filter Menu (Priority, Tag, Sort By, Completed Logbook…) & Completed Logbook Sheet
        let filter = app.buttons["pages.scope"].firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.tap()
        let logbookBtn = app.buttons["Completed Logbook…"].firstMatch
        XCTAssertTrue(logbookBtn.waitForExistence(timeout: 5), "Completed Logbook in Filter menu")
        shot("live-4-filter-menu")
        logbookBtn.tap()
        XCTAssertTrue(app.descendants(matching: .any)["tasks.logbook"].firstMatch.waitForExistence(timeout: 8), "Logbook opened")
        shot("live-5-logbook")
        app.buttons["sheet.close"].firstMatch.tap()
        _ = waitUntil(5) { !self.app.descendants(matching: .any)["tasks.logbook"].firstMatch.exists }

        // 5. Inside a Task: Steps with drag grips & context actions
        app.terminate()
        app = launchSignedIn(["-hqn.appearance", "light", "-HQPagesTab", "4", "-HQPagesMore", "tasks",
                              "-HQPagesOpenTask", "Renew passport"])
        XCTAssertTrue(app.descendants(matching: .any)["task.sheet"].firstMatch.waitForExistence(timeout: 15))
        _ = waitUntil(3) { self.app.staticTexts["Get a new photo"].exists }
        shot("live-6-task-steps")

        // 6. Inside a Task: Tappable Tag Picker Sheet
        app.terminate()
        app = launchSignedIn(["-hqn.appearance", "light", "-HQPagesTab", "4", "-HQPagesMore", "tasks",
                              "-HQPagesOpenTask", "Go through the open job applications"])
        let tagsRow = app.descendants(matching: .any)["task.tags"].firstMatch
        XCTAssertTrue(tagsRow.waitForExistence(timeout: 15))
        tagsRow.tap()
        XCTAssertTrue(app.textFields["task.tags.field"].firstMatch.waitForExistence(timeout: 5))
        shot("live-7-tag-picker")
    }
}
