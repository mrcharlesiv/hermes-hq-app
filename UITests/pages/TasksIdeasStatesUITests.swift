// [task-ideas] The Ideas page's other states: an add-on before 0.9.39 (Ideas asks for the update) and then updated
// (Ideas turns up though the list's rev stayed), a list with no tasks
// (No Tasks stands under the switch, and Ideas still offers itself), and the cards at the largest text sizes. Run with
// scripts/e2e-pages.sh (HQN_PAGES_ONLY=testTasks_IdeasStates); HQN_TASKS_LOOK picks the look.

import XCTest

extension PagesTests {
    @MainActor func testTasks_IdeasStates() throws {
        // An add-on before 0.9.39: the switch is there, and Ideas asks for the update instead of offering Turn On.
        try account.control("/__fixture/tasks-mode", ["older_addon": true])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        let modeSwitch = app.descendants(matching: .any)["tasks.mode"].firstMatch
        XCTAssertTrue(modeSwitch.waitForExistence(timeout: 20), "To Do | Ideas heads the page")
        modeSwitch.buttons["Ideas"].firstMatch.tap()
        XCTAssertTrue(app.buttons["tasks.ideas.update"].firstMatch.waitForExistence(timeout: 10), "an older add-on: Ideas asks for the update")
        XCTAssertFalse(app.buttons["tasks.ideas.turn-on"].exists, "nothing to turn on yet")
        shot("tasks-ideas-states-1-older" + Self.lookName)

        // The add-on is updated (outside the app, or the sheet said Up to Date): the list's rev doesn't move, so its
        // `?since=` answer stays "unchanged". Ideas still turns up (owner 2026-11-05: "I go to update the plugin, and it
        // says it's done, and then nothing changes").
        try account.control("/__fixture/tasks-mode", ["older_addon": false, "keep_rev": true])
        modeSwitch.buttons["To Do"].firstMatch.tap()
        modeSwitch.buttons.element(boundBy: 1).tap()   // "Ideas 2" now: the add-on's ideas waiting
        XCTAssertTrue(app.buttons["tasks.ideas.turn-on"].firstMatch.waitForExistence(timeout: 10),
                      "after the update, Ideas offers Turn On, not the update again")
        XCTAssertFalse(app.buttons["tasks.ideas.update"].exists)

        // No tasks at all: No Tasks under the switch, with New Task; Ideas still offers itself.
        app.terminate()
        try account.control("/__fixture/reset", [:])
        try account.control("/__fixture/tasks-mode", ["empty": true])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        XCTAssertTrue(app.buttons["tasks.empty.new"].firstMatch.waitForExistence(timeout: 20), "an empty list says No Tasks, with New Task")
        XCTAssertTrue(modeSwitch.exists, "the switch shows on an empty list")
        shot("tasks-ideas-states-2-empty" + Self.lookName)
        modeSwitch.buttons["Ideas"].firstMatch.tap()
        XCTAssertTrue(app.buttons["tasks.ideas.turn-on"].firstMatch.waitForExistence(timeout: 10), "Ideas offers itself with no tasks")
        shot("tasks-ideas-states-3-empty-ideas" + Self.lookName)

        // The largest text: the cards still fit, and Add stays in reach.
        app.terminate()
        try account.control("/__fixture/reset", [:])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks",
                                          "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        // At the accessibility sizes the switch is a pull-down (WholeLabelTabs), as on the app's other pages.
        XCTAssertTrue(modeSwitch.waitForExistence(timeout: 20))
        shot("tasks-ideas-states-4-large-todo" + Self.lookName)
        modeSwitch.tap()
        let ideasItem = app.buttons["Ideas"].firstMatch
        XCTAssertTrue(ideasItem.waitForExistence(timeout: 5), "the pull-down offers Ideas")
        ideasItem.tap()
        let turnOn = app.buttons["tasks.ideas.turn-on"].firstMatch
        XCTAssertTrue(turnOn.waitForExistence(timeout: 10))
        shot("tasks-ideas-states-5-large-off" + Self.lookName)
        turnOn.tap()
        let add = app.buttons["tasks.idea.add.Book the team offsite venue"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "the cards show at the largest text")
        for _ in 0..<4 where !add.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(add.isHittable, "Add is in reach")
        let start = app.buttons["tasks.idea.start.Book the team offsite venue"].firstMatch
        XCTAssertTrue(start.exists, "so is Add & Let Inbox Start")
        XCTAssertLessThanOrEqual(start.frame.maxX, app.frame.maxX, "the start button stays on screen: \(start.frame)")
        shot("tasks-ideas-states-6-large-cards" + Self.lookName)
    }
}
