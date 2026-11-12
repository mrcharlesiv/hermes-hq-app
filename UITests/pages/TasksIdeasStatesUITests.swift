// [task-ideas] Ideas' other states, at Inbox's foot ([tasks-first]): an add-on before 0.9.39 (nothing about ideas) and
// then updated (the line turns up though the list's rev stayed), a list with no tasks (No Tasks in every view, and
// Inbox still offers Ideas), and the rows and card at the largest text sizes. Run with scripts/e2e-pages.sh
// (HQN_PAGES_ONLY=testTasks_IdeasStates); HQN_TASKS_LOOK picks the look.

import XCTest

extension PagesTests {
    @MainActor func testTasks_IdeasStates() throws {
        // An add-on before 0.9.39: Inbox is your tasks, with nothing about ideas.
        try account.control("/__fixture/tasks-mode", ["older_addon": true])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        let today = app.buttons["tasks.view.today"].firstMatch, inbox = app.buttons["tasks.view.inbox"].firstMatch
        XCTAssertTrue(inbox.waitForExistence(timeout: 20), "the views head the page")
        inbox.tap()
        XCTAssertTrue(app.cells["task-row-Fix the porch light"].firstMatch.waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertFalse(app.buttons["tasks.ideas.turn-on"].exists, "an older add-on has no ideas to turn on")
        shot("tasks-ideas-states-1-older" + Self.lookName)

        // The add-on is updated (outside the app, or the sheet said Up to Date): the list's rev doesn't move, so its
        // `?since=` answer stays "unchanged". Ideas still turns up (owner 2026-11-05: "I go to update the plugin, and it
        // says it's done, and then nothing changes").
        try account.control("/__fixture/tasks-mode", ["older_addon": false, "keep_rev": true])
        today.tap()
        inbox.tap()
        XCTAssertTrue(app.buttons["tasks.ideas.turn-on"].firstMatch.waitForExistence(timeout: 10),
                      "after the update, Inbox offers Ideas")

        // No tasks at all: No Tasks with New Task in every view; Inbox still offers Ideas under it.
        app.terminate()
        try account.control("/__fixture/reset", [:])
        try account.control("/__fixture/tasks-mode", ["empty": true])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        XCTAssertTrue(app.buttons["tasks.empty.new"].firstMatch.waitForExistence(timeout: 20), "an empty list says No Tasks, with New Task")
        XCTAssertTrue(today.exists, "the views show on an empty list")
        XCTAssertFalse(app.buttons["tasks.view.bots"].exists, "no Bots view until a bot has a task of its own")
        shot("tasks-ideas-states-2-empty" + Self.lookName)
        inbox.tap()
        XCTAssertTrue(app.buttons["tasks.ideas.turn-on"].firstMatch.waitForExistence(timeout: 10), "Ideas offers itself with no tasks")
        XCTAssertTrue(app.buttons["tasks.empty.new"].firstMatch.exists, "No Tasks stays above it")
        shot("tasks-ideas-states-3-empty-inbox" + Self.lookName)

        // The largest text: the rows still fit, and Add stays in reach.
        app.terminate()
        try account.control("/__fixture/reset", [:])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks",
                                          "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        XCTAssertTrue(inbox.waitForExistence(timeout: 20))
        shot("tasks-ideas-states-4-large-today" + Self.lookName)
        inbox.tap()
        let turnOn = app.buttons["tasks.ideas.turn-on"].firstMatch
        for _ in 0..<4 where !(turnOn.exists && turnOn.isHittable) { app.swipeUp(velocity: .slow) }
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
        XCTAssertTrue(start.waitForExistence(timeout: 5), "its card has Add & Let Inbox Start")
        XCTAssertLessThanOrEqual(start.frame.maxX, app.frame.maxX, "the start button stays on screen: \(start.frame)")
        shot("tasks-ideas-states-7-large-card" + Self.lookName)
    }
}
