// [tasks-first] The Tasks page's views (owner 2026-11-12, mockups hermes-hq-share/2026-11-12-tasks-first): Today opens
// on your day (Overdue, Today, Waiting on You), Upcoming by day under a week strip, Inbox with what has no date and no
// list, Bots with what each bot does by itself, and a list of your own made from the row's +. Run with
// scripts/e2e-pages.sh (HQN_PAGES_ONLY=testTasks_Views); HQN_TASKS_LOOK picks the look.

import XCTest

extension PagesTests {
    @MainActor private func settleViews() { RunLoop.current.run(until: Date().addingTimeInterval(1.0)) }

    @MainActor func testTasks_Views() throws {
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        let today = app.buttons["tasks.view.today"].firstMatch
        XCTAssertTrue(today.waitForExistence(timeout: 20), "the views sit under the bar")
        XCTAssertTrue(today.isSelected, "the page opens on Today")
        XCTAssertFalse(app.buttons["tasks.chip.all"].exists, "no bot pills")
        XCTAssertFalse(app.descendants(matching: .any)["tasks.mode"].exists, "no To Do | Ideas switch")

        // Today: your day first, then what a bot is stuck on you for.
        let cleaning = app.cells["task-row-Pick up dry cleaning"].firstMatch
        XCTAssertTrue(cleaning.waitForExistence(timeout: 10), "your own task for today is on the first screen")
        XCTAssertTrue(cleaning.isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["tasks.section.Today"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["tasks.section.Waiting on You"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["tasks.section.Ready for You"].exists, "no bot-state headings")
        XCTAssertFalse(app.cells["task-row-Summarize October invoices"].exists, "a bot's own task stays out of your day")
        XCTAssertTrue(app.cells["task-row-Find 3 venues for the party"].firstMatch.exists, "until it waits on you")
        settleViews(); shot("first-1-today" + Self.lookName)

        // Upcoming: each coming day under the week.
        app.buttons["tasks.view.upcoming"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["tasks.section.Tomorrow"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells["task-row-Follow up with Ivy on the contract"].firstMatch.exists)
        XCTAssertFalse(cleaning.exists, "today's tasks are not coming up")
        settleViews(); shot("first-2-upcoming" + Self.lookName)

        // Inbox: no date, no list.
        app.buttons["tasks.view.inbox"].firstMatch.tap()
        XCTAssertTrue(app.cells["task-row-Fix the porch light"].firstMatch.waitForExistence(timeout: 5))
        settleViews(); shot("first-3-inbox" + Self.lookName)

        // Bots: what each does by itself.
        app.buttons["tasks.view.bots"].firstMatch.tap()
        XCTAssertTrue(app.cells["task-row-Summarize October invoices"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["tasks.section.Finance"].firstMatch.exists, "grouped by bot")
        settleViews(); shot("first-4-bots" + Self.lookName)

        // A list of your own, from the row's +; a task moved into it shows there.
        let rail = app.descendants(matching: .any)["tasks.views"].firstMatch
        rail.swipeLeft()
        app.buttons["tasks.view.new-list"].firstMatch.tap()
        let name = app.textFields["tasks.list-name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("Home")
        app.alerts.buttons["Add"].tap()
        let home = app.buttons["tasks.view.list.Home"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 5), "the new list is a pill")
        XCTAssertTrue(home.isSelected, "and is on show")
        XCTAssertTrue(app.descendants(matching: .any)["tasks.view-empty"].firstMatch.waitForExistence(timeout: 5))
        settleViews(); shot("first-5-list-empty" + Self.lookName)
        rail.swipeRight()
        app.buttons["tasks.view.inbox"].firstMatch.tap()
        let porch = app.cells["task-row-Fix the porch light"].firstMatch
        XCTAssertTrue(porch.waitForExistence(timeout: 5))
        porch.press(forDuration: 1.0)
        app.buttons["Move To"].firstMatch.tap()
        app.buttons["Home"].firstMatch.tap()
        XCTAssertTrue(porch.waitForNonExistence(timeout: 5), "filed, it leaves Inbox")
        rail.swipeLeft()
        home.tap()
        XCTAssertTrue(porch.waitForExistence(timeout: 5), "and is in its list")
        settleViews(); shot("first-6-list" + Self.lookName)
    }
}

extension PagesTests {
    /// The bots are the bar's Filter (they were pills under the bar until the views took that row): one bot's tasks,
    /// your own under Me, every one under All Bots. The views' counts follow the filter.
    @MainActor func testTasks_FilterByBot() throws {
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        let dentist = app.cells["task-row-Call the dentist"].firstMatch
        XCTAssertTrue(dentist.waitForExistence(timeout: 20), "Hermes' task is listed")
        let filter = app.buttons["pages.scope"].firstMatch
        XCTAssertTrue(filter.exists, "Filter in the bar")
        let rail = app.descendants(matching: .any)["tasks.views"].firstMatch
        XCTAssertGreaterThan(dentist.frame.minY, rail.frame.maxY - 1, "the list starts under the views")

        // Research: only Research's task.
        filter.tap()
        app.buttons["Research"].firstMatch.tap()
        let venues = app.cells["task-row-Find 3 venues for the party"].firstMatch
        XCTAssertTrue(venues.waitForExistence(timeout: 5), "Research's task")
        XCTAssertTrue(waitUntil(5) { !dentist.exists }, "Hermes' task is not shown")
        shot("first-filter-research" + Self.lookName)

        // Me: your own tasks only, the ones no bot helps with.
        filter.tap()
        app.buttons["Me"].firstMatch.tap()
        XCTAssertTrue(app.cells["task-row-Pick up dry cleaning"].firstMatch.waitForExistence(timeout: 5), "your own task")
        XCTAssertTrue(waitUntil(5) { !venues.exists && !dentist.exists }, "no task a bot is on")
        XCTAssertFalse(app.descendants(matching: .any)["tasks.section.Waiting on You"].exists, "nobody is waiting on your own tasks")
        shot("first-filter-me" + Self.lookName)

        filter.tap()
        app.buttons["All Bots"].firstMatch.tap()
        XCTAssertTrue(dentist.waitForExistence(timeout: 5), "back to every task")
    }
}
