// [task-ideas] Ideas' other states: an add-on before 0.9.39 (no Suggested row) and then updated (Suggested turns up
// though the list's rev stayed), a list with no tasks (No Tasks on Overview, Suggested still offers Ideas), and the
// inline card, rows, and expanded card at the largest text sizes. Run with scripts/e2e-pages.sh
// (HQN_PAGES_ONLY=testTasks_IdeasStates); HQN_TASKS_LOOK picks the look.

import XCTest

extension PagesTests {
    @MainActor func testTasks_IdeasStates() throws {
        // An add-on before 0.9.39: Overview has Smart Views, with nothing about Suggested.
        try account.control("/__fixture/tasks-mode", ["older_addon": true])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        let today = app.buttons["tasks.view.today"].firstMatch
        let suggested = app.buttons["tasks.view.suggested"].firstMatch
        XCTAssertTrue(today.waitForExistence(timeout: 20), "Overview shows Smart Views")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertFalse(suggested.exists, "an older add-on has no Suggested row")
        XCTAssertFalse(app.descendants(matching: .any)["tasks.overview.suggested"].exists, "no inline Suggested card on older add-on")
        shot("tasks-ideas-states-1-older" + Self.lookName)

        // The add-on is updated (outside the app, or the sheet said Up to Date): the list's rev doesn't move, so its
        // `?since=` answer stays "unchanged". Returning to Overview still discovers Ideas.
        try account.control("/__fixture/tasks-mode", ["older_addon": false, "keep_rev": true])
        today.tap()
        backToTasksOverview()
        XCTAssertTrue(suggested.waitForExistence(timeout: 10), "after the update, Overview offers Suggested")
        suggested.tap()
        XCTAssertTrue(app.buttons["tasks.ideas.turn-on"].firstMatch.waitForExistence(timeout: 10),
                      "Suggested offers Turn On")

        // No tasks at all: Overview shows No Tasks with New Task, and Suggested still opens Ideas cleanly.
        app.terminate()
        try account.control("/__fixture/reset", [:])
        try account.control("/__fixture/tasks-mode", ["empty": true])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        XCTAssertTrue(app.buttons["tasks.empty.new"].firstMatch.waitForExistence(timeout: 20), "an empty list says No Tasks, with New Task")
        XCTAssertTrue(today.exists, "the Smart Views show on an empty list")
        XCTAssertFalse(app.buttons["tasks.view.bots"].exists, "no Bots view until a bot has a task of its own")
        XCTAssertTrue(suggested.exists, "Suggested stays reachable even with no tasks")
        shot("tasks-ideas-states-2-empty" + Self.lookName)
        suggested.tap()
        XCTAssertTrue(app.buttons["tasks.ideas.turn-on"].firstMatch.waitForExistence(timeout: 10), "Ideas offers itself with no tasks")
        XCTAssertFalse(app.buttons["tasks.empty.new"].exists, "Suggested focuses on Ideas without No Tasks crowding it")
        shot("tasks-ideas-states-3-empty-suggested" + Self.lookName)

        // The largest text: Overview, Suggested rows, and card still fit, and Add stays in reach.
        app.terminate()
        try account.control("/__fixture/reset", [:])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks",
                                          "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        XCTAssertTrue(today.waitForExistence(timeout: 20))
        shot("tasks-ideas-states-4-large-overview" + Self.lookName)
        for _ in 0..<4 where !(suggested.exists && suggested.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(suggested.waitForExistence(timeout: 10))
        suggested.tap()
        let turnOn = app.buttons["tasks.ideas.turn-on"].firstMatch
        XCTAssertTrue(turnOn.waitForExistence(timeout: 10))
        shot("tasks-ideas-states-5-large-off" + Self.lookName)
        turnOn.tap()
        let add = app.buttons["tasks.idea.add.Book the team offsite venue"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "the rows show at the largest text")
        for _ in 0..<4 where !add.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(add.isHittable, "Add is in reach")
        XCTAssertLessThanOrEqual(add.frame.maxX, app.frame.maxX, "Add stays on screen: \(add.frame)")
        shot("tasks-ideas-states-6-large-rows" + Self.lookName)
        app.descendants(matching: .any)["tasks.idea.Book the team offsite venue"].firstMatch.tap()
        let start = app.buttons["tasks.idea.start.Book the team offsite venue"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5), "its card has Add & Let Hermes Start")
        XCTAssertLessThanOrEqual(start.frame.maxX, app.frame.maxX, "the start button stays on screen: \(start.frame)")
        shot("tasks-ideas-states-7-large-card" + Self.lookName)
    }
}
