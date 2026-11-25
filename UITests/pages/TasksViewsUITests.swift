// [tasks-first] The Tasks page's views (owner 2026-11-12, mockups hermes-hq-share/2026-11-12-tasks-first): Today opens
// on your day (Overdue, Today, Waiting on You), Upcoming by day under a week strip, Inbox with what has no date and no
// list, Bots with what each bot does by itself, and a list of your own made from the row's +. Run with
// scripts/e2e-pages.sh (HQN_PAGES_ONLY=testTasks_Views); HQN_TASKS_LOOK picks the look.

import XCTest

extension PagesTests {
    @MainActor private func settleViews() { RunLoop.current.run(until: Date().addingTimeInterval(1.0)) }

    @MainActor func testTasks_Views() throws {
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        // Flow 1: Tasks opens on the Grouped Overview (Smart Views 2×2 grid, My Lists, Agents).
        let today = app.buttons["tasks.view.today"].firstMatch
        XCTAssertTrue(today.waitForExistence(timeout: 20), "Tasks opens on Grouped Overview")
        XCTAssertTrue(app.buttons["tasks.view.upcoming"].firstMatch.exists, "Upcoming tile")
        XCTAssertTrue(app.buttons["tasks.view.inbox"].firstMatch.exists, "Inbox tile")
        XCTAssertFalse(app.buttons["tasks.chip.all"].exists, "no bot pills")
        XCTAssertFalse(app.descendants(matching: .any)["tasks.mode"].exists, "no To Do | Ideas switch")
        settleViews(); shot("first-0-overview" + Self.lookName)

        // Today: your day first, then what a bot is stuck on you for.
        today.tap()
        let cleaning = app.cells["task-row-Pick up dry cleaning"].firstMatch
        XCTAssertTrue(cleaning.waitForExistence(timeout: 10), "your own task for today is on Today")
        XCTAssertTrue(cleaning.isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["tasks.section.Today"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["tasks.section.Waiting on You"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["tasks.section.Ready for You"].exists, "no bot-state headings")
        XCTAssertFalse(app.cells["task-row-Summarize October invoices"].exists, "a bot's own task stays out of your day")
        XCTAssertTrue(app.cells["task-row-Find 3 venues for the party"].firstMatch.exists, "until it waits on you")
        settleViews(); shot("first-1-today" + Self.lookName)

        // Upcoming: step back to Overview, tap Upcoming.
        backToTasksOverview()
        let upcoming = app.buttons["tasks.view.upcoming"].firstMatch
        XCTAssertTrue(upcoming.label.contains("task"), "Upcoming tile says its count: \(upcoming.label)")
        upcoming.tap()
        XCTAssertTrue(app.descendants(matching: .any)["tasks.section.Tomorrow"].firstMatch.waitForExistence(timeout: 5))
        let contract = app.cells["task-row-Follow up with Ivy on the contract"].firstMatch
        XCTAssertTrue(contract.exists)
        XCTAssertFalse(cleaning.exists, "today's tasks are not coming up")
        settleViews(); shot("first-2-upcoming" + Self.lookName)

        // Every day on the week answers a tap: the list holds that day alone. The picked day again shows every coming day.
        func weekDay(_ offset: Int) -> XCUIElement {
            let date = Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: Date()))!
            let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
            return app.buttons[String(format: "tasks.week.%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)].firstMatch
        }
        let empty = weekDay(5)   // nothing in the fixture is due in five days
        XCTAssertTrue(empty.exists, "the week's days")
        empty.tap()
        XCTAssertTrue(app.descendants(matching: .any)["tasks.view-empty"].firstMatch.waitForExistence(timeout: 5), "a day with nothing says so")
        XCTAssertTrue(waitUntil(5) { !contract.exists }, "only the picked day is listed")
        XCTAssertTrue(empty.isSelected, "the picked day is marked")
        shot("first-2b-upcoming-empty-day" + Self.lookName)
        weekDay(1).tap()
        XCTAssertTrue(contract.waitForExistence(timeout: 5), "tomorrow's task")
        XCTAssertFalse(app.cells["task-row-Pick a spot for Friday’s team lunch"].exists, "the day after is not listed")
        shot("first-2c-upcoming-tomorrow" + Self.lookName)
        weekDay(0).tap()
        XCTAssertTrue(cleaning.waitForExistence(timeout: 5), "today's day shows what is due today")
        weekDay(0).tap()
        XCTAssertTrue(contract.waitForExistence(timeout: 5), "the picked day again shows every coming day")
        XCTAssertTrue(waitUntil(5) { !cleaning.exists }, "and today's tasks are gone again")

        // Inbox: no date, no list.
        tapView("inbox")
        XCTAssertTrue(app.cells["task-row-Fix the porch light"].firstMatch.waitForExistence(timeout: 5))
        settleViews(); shot("first-3-inbox" + Self.lookName)

        // Bots: in its own Agents section on Overview.
        tapView("bots")
        XCTAssertTrue(app.cells["task-row-Summarize October invoices"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["tasks.section.Finance"].firstMatch.exists, "grouped by bot")
        settleViews(); shot("first-4-bots" + Self.lookName)

        // A list of your own, from My Lists on Overview; a task moved into it shows there.
        backToTasksOverview()
        app.buttons["tasks.view.new-list"].firstMatch.tap()
        let name = app.textFields["tasks.list-name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("Home")
        app.alerts.buttons["Add"].tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5), "the new list is pushed on show")
        XCTAssertTrue(app.descendants(matching: .any)["tasks.view-empty"].firstMatch.waitForExistence(timeout: 5))
        settleViews(); shot("first-5-list-empty" + Self.lookName)
        tapView("inbox")
        let porch = app.cells["task-row-Fix the porch light"].firstMatch
        XCTAssertTrue(porch.waitForExistence(timeout: 5))
        porch.press(forDuration: 1.0)
        app.buttons["Move To"].firstMatch.tap()
        app.buttons["Home"].firstMatch.tap()
        XCTAssertTrue(porch.waitForNonExistence(timeout: 5), "filed, it leaves Inbox")
        tapView("list.Home")
        XCTAssertTrue(porch.waitForExistence(timeout: 5), "and is in its list")
        settleViews(); shot("first-6-list" + Self.lookName)
    }
}

extension PagesTests {
    /// The bots are the bar's Filter inside a view: one bot's tasks, your own under Me, every one under All Bots.
    @MainActor func testTasks_FilterByBot() throws {
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        tapView("today")
        let dentist = app.cells["task-row-Call the dentist"].firstMatch
        XCTAssertTrue(dentist.waitForExistence(timeout: 20), "Hermes' task is listed")
        let filter = app.buttons["pages.scope"].firstMatch
        XCTAssertTrue(filter.exists, "Filter in the bar")

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
