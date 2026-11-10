// [task-ideas] Owner 2026-11-05: "Instead of the add a task box at the top, I want a toggle between two pages: active
// tasks and suggested tasks … you land on the main tasks page but you can click the additional tab/page to see tasks
// that your agent suggests could be started based on all of your context." To Do | Ideas heads the page; Ideas starts
// off and says what it does; once on, each idea can be added (with its bot starting) or dismissed (Undo brings it
// back), and Look Now asks for more. Run with scripts/e2e-pages.sh (HQN_PAGES_ONLY=testTasks_Ideas); HQN_TASKS_LOOK
// picks the look.

import XCTest

extension PagesTests {
    @MainActor func testTasks_Ideas() throws {
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        // The page opens on To Do, with the switch where Add a task was.
        let modeSwitch = app.descendants(matching: .any)["tasks.mode"].firstMatch
        XCTAssertTrue(modeSwitch.waitForExistence(timeout: 20), "To Do | Ideas heads the page")
        XCTAssertFalse(app.textFields["tasks.quick-add"].exists, "the Add a task field is gone")
        XCTAssertTrue(app.descendants(matching: .any)["task-row-Call the dentist"].firstMatch.waitForExistence(timeout: 10),
                      "the page opens on To Do")
        shot("tasks-ideas-1-todo" + Self.lookName)

        // Ideas is off until you turn it on: what it does, and one button.
        modeSwitch.buttons["Ideas"].firstMatch.tap()
        let turnOn = app.buttons["tasks.ideas.turn-on"].firstMatch
        XCTAssertTrue(turnOn.waitForExistence(timeout: 10), "Ideas starts off and offers Turn On")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "until you choose")).firstMatch.exists,
                      "it says nothing happens until you choose")
        XCTAssertFalse(app.descendants(matching: .any)["tasks.idea.Renew the car registration"].exists, "no ideas while off")
        shot("tasks-ideas-2-off" + Self.lookName)
        turnOn.tap()
        XCTAssertTrue(waitUntil(10) {
            self.restCalls("PUT", suffix: "/tasks/settings").contains { ($0["body"] as? [String: Any])?["ideas"] as? Bool == true }
        }, "Turn On saves Ideas on")

        // The ideas, newest first: who looks and when, and a card each.
        let registration = app.descendants(matching: .any)["tasks.idea.Renew the car registration"].firstMatch
        XCTAssertTrue(registration.waitForExistence(timeout: 10), "the ideas show once on")
        let status = app.staticTexts["tasks.ideas.status"].firstMatch
        XCTAssertTrue(status.exists)
        XCTAssertTrue(status.label.contains("looks each day at"), status.label)
        // When it last looked stands on its own line (it had run on after a dot and broken there, owner 2026-11-08).
        let last = app.staticTexts["tasks.ideas.last-looked"].firstMatch
        XCTAssertTrue(last.exists && last.label.hasPrefix("Last looked "), last.label)
        XCTAssertFalse(status.label.contains("Looked"), status.label)
        XCTAssertTrue(modeSwitch.buttons["Ideas 3"].firstMatch.waitForExistence(timeout: 5), "the switch counts the new ideas")
        XCTAssertFalse(app.buttons["tasks.idea.start.Renew the car registration"].exists, "your own idea has no bot to start")
        XCTAssertTrue(app.buttons["tasks.idea.start.Compare internet plans before the promo ends"].exists,
                      "an idea a bot can help with offers it starting")
        shot("tasks-ideas-3-cards" + Self.lookName)

        // Add: it goes on To Do; the switch's count drops.
        app.buttons["tasks.idea.add.Renew the car registration"].firstMatch.tap()
        XCTAssertTrue(waitUntil(10) { !registration.exists }, "an added idea leaves Ideas")
        XCTAssertTrue(waitUntil(5) { !self.restCalls("POST", suffix: "/ideas/i_registration/add").isEmpty }, "the add is sent")
        XCTAssertTrue(modeSwitch.buttons["Ideas 2"].firstMatch.waitForExistence(timeout: 5), "two ideas left")

        // Add & Let Finance Start: added with its bot starting.
        app.buttons["tasks.idea.start.Compare internet plans before the promo ends"].firstMatch.tap()
        XCTAssertTrue(waitUntil(10) {
            self.restCalls("POST", suffix: "/ideas/i_internet/add").contains { ($0["body"] as? [String: Any])?["start"] as? Bool == true }
        }, "the add asks its bot to start")
        let notice = app.descendants(matching: .any)["pages.notice"].firstMatch
        XCTAssertTrue(waitUntil(5) { notice.label.contains("is starting on it") }, "says the bot is starting: \(notice.label)")
        shot("tasks-ideas-4-added" + Self.lookName)

        // ×: gone at once, with Undo.
        let offsite = app.descendants(matching: .any)["tasks.idea.Book the team offsite venue"].firstMatch
        XCTAssertTrue(offsite.waitForExistence(timeout: 5))
        app.buttons["tasks.idea.dismiss.Book the team offsite venue"].firstMatch.tap()
        // Undo first: the pill lasts a few seconds, and a busy simulator answers slowly.
        let undo = app.buttons["undo-pill.undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "Undo shows with the dismiss")
        XCTAssertFalse(offsite.exists, "a dismissed idea leaves at once")
        shot("tasks-ideas-5-dismissed" + Self.lookName)
        XCTAssertTrue(waitUntil(5) { !self.restCalls("POST", suffix: "/ideas/i_offsite/dismiss").isEmpty }, "the dismiss is sent")
        undo.tap()
        XCTAssertTrue(offsite.waitForExistence(timeout: 10), "Undo brings it back")
        XCTAssertFalse(restCalls("POST", suffix: "/ideas/i_offsite/restore").isEmpty, "the restore is sent")

        // Look Now: Looking… then the new idea.
        let look = app.buttons["tasks.ideas.look-now"].firstMatch
        XCTAssertTrue(look.waitForExistence(timeout: 5))
        look.tap()
        XCTAssertTrue(waitUntil(5) { status.label.contains("is looking") }, "says it's looking: \(status.label)")
        shot("tasks-ideas-6-looking" + Self.lookName)
        XCTAssertTrue(app.descendants(matching: .any)["tasks.idea.Plan dinners for next week"].firstMatch.waitForExistence(timeout: 20),
                      "the look's new idea shows")
        shot("tasks-ideas-7-new" + Self.lookName)

        // Back on To Do, the added ideas are tasks.
        modeSwitch.buttons.element(boundBy: 0).tap()
        let added = app.descendants(matching: .any)["task-row-Renew the car registration"].firstMatch
        let started = app.descendants(matching: .any)["task-row-Compare internet plans before the promo ends"].firstMatch
        XCTAssertTrue(app.descendants(matching: .any)["task-row-Call the dentist"].firstMatch.waitForExistence(timeout: 10))
        for _ in 0..<6 where !(added.exists && started.exists) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(added.exists, "the added idea is on To Do")
        XCTAssertTrue(started.exists, "so is the one its bot started")

        // Tasks Settings has Ideas, on.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesTasksSettings", "YES"])
        let toggle = app.switches["tasks.settings.ideas"].firstMatch
        for _ in 0..<4 where !(toggle.exists && toggle.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(toggle.waitForExistence(timeout: 15), "Tasks Settings has Ideas")
        shot("tasks-ideas-8-settings" + Self.lookName)
    }

    /// The fixture's REST log: calls with this method whose path ends with `suffix`.
    @MainActor private func restCalls(_ method: String, suffix: String) -> [[String: Any]] {
        let rest = ((try? account.control("/__fixture/state")) ?? [:])["rest"] as? [[String: Any]] ?? []
        return rest.filter { ($0["method"] as? String) == method && ($0["path"] as? String)?.hasSuffix(suffix) == true }
    }
}
