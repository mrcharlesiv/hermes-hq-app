// [task-ideas] A bot's ideas for your list. Owner 2026-11-05 had them behind a To Do | Ideas switch; [tasks-first]
// owner 2026-11-12 (mockup 2-list-other-views): they are short rows at the foot of Inbox. Ideas starts off and says
// what it does in one line; once on, each idea can be added from its row, opened as a card (with its bot starting), or
// dismissed (Undo brings it back), and the heading's menu looks for more. Run with scripts/e2e-pages.sh
// (HQN_PAGES_ONLY=testTasks_Ideas); HQN_TASKS_LOOK picks the look.

import XCTest

extension PagesTests {
    @MainActor func testTasks_Ideas() throws {
        app = launchSignedIn(Self.look + ["-HQDebugHapticsProbe", "YES", "-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        // The page opens on Today; no switch gives half the page to Ideas.
        let inbox = app.buttons["tasks.view.inbox"].firstMatch
        XCTAssertTrue(inbox.waitForExistence(timeout: 20), "the views head the page")
        XCTAssertFalse(app.descendants(matching: .any)["tasks.mode"].exists, "no To Do | Ideas switch")
        XCTAssertTrue(app.descendants(matching: .any)["task-row-Call the dentist"].firstMatch.waitForExistence(timeout: 10),
                      "the page opens on your day")
        shot("tasks-ideas-1-today" + Self.lookName)

        // Ideas is off until you turn it on: one line at Inbox's foot, and one button.
        inbox.tap()
        let turnOn = app.buttons["tasks.ideas.turn-on"].firstMatch
        XCTAssertTrue(turnOn.waitForExistence(timeout: 10), "Ideas starts off and offers Turn On")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "can suggest tasks from your chats")).firstMatch.exists,
                      "it says what it does")
        XCTAssertFalse(app.descendants(matching: .any)["tasks.idea.Renew the car registration"].exists, "no ideas while off")
        shot("tasks-ideas-2-off" + Self.lookName)
        turnOn.tap()
        XCTAssertTrue(waitUntil(10) {
            self.restCalls("PUT", suffix: "/tasks/settings").contains { ($0["body"] as? [String: Any])?["ideas"] as? Bool == true }
        }, "Turn On saves Ideas on")

        // The ideas, newest first, under who suggested them: a short row each.
        let registration = app.descendants(matching: .any)["tasks.idea.Renew the car registration"].firstMatch
        XCTAssertTrue(registration.waitForExistence(timeout: 10), "the ideas show once on")
        let status = app.staticTexts["tasks.ideas.status"].firstMatch
        XCTAssertTrue(status.exists)
        XCTAssertTrue(status.label.hasPrefix("Suggested by Hermes") && status.label.hasSuffix("3"), status.label)
        let look = app.buttons["tasks.ideas.look"].firstMatch
        XCTAssertTrue(look.exists, "when it looked is the heading's menu")
        XCTAssertTrue(look.label.hasPrefix("Look"), look.label)
        let internet = "Compare internet plans before the promo ends"
        XCTAssertFalse(app.buttons["tasks.idea.start.\(internet)"].exists, "a row has Add and ×; the bot starting is on its card")
        shot("tasks-ideas-3-rows" + Self.lookName)

        // Add, from the row: it becomes a task (here, in Inbox) and leaves the ideas.
        app.buttons["tasks.idea.add.Renew the car registration"].firstMatch.tap()
        XCTAssertTrue(waitUntil(10) { !registration.exists }, "an added idea leaves the ideas")
        XCTAssertTrue(waitUntil(5) { !self.restCalls("POST", suffix: "/ideas/i_registration/add").isEmpty }, "the add is sent")
        XCTAssertTrue(app.descendants(matching: .any)["task-row-Renew the car registration"].firstMatch.waitForExistence(timeout: 10),
                      "the added idea is a task")
        XCTAssertTrue(waitUntil(5) { status.label.hasSuffix("2") }, "two ideas left: \(status.label)")

        // A tap opens an idea's card: why now, where it came from, and Add & Let Finance Start.
        let internetRow = app.descendants(matching: .any)["tasks.idea.\(internet)"].firstMatch
        for _ in 0..<4 where !internetRow.isHittable { app.swipeUp(velocity: .slow) }
        internetRow.tap()
        let start = app.buttons["tasks.idea.start.\(internet)"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5), "the card offers its bot starting")
        shot("tasks-ideas-4-card" + Self.lookName)
        start.tap()
        XCTAssertTrue(waitUntil(10) {
            self.restCalls("POST", suffix: "/ideas/i_internet/add").contains { ($0["body"] as? [String: Any])?["start"] as? Bool == true }
        }, "the add asks its bot to start")
        let notice = app.descendants(matching: .any)["pages.notice"].firstMatch
        XCTAssertTrue(waitUntil(5) { notice.label.contains("is starting on it") }, "says the bot is starting: \(notice.label)")

        // ×: gone at once, with Undo.
        let offsite = app.descendants(matching: .any)["tasks.idea.Book the team offsite venue"].firstMatch
        XCTAssertTrue(offsite.waitForExistence(timeout: 5))
        app.buttons["tasks.idea.dismiss.Book the team offsite venue"].firstMatch.tap()
        // The × is felt: a light impact (it was the faint selection tick; owner 2026-11-12).
        let probe = app.descendants(matching: .any)["debug.haptics"].firstMatch
        XCTAssertTrue(waitUntil(5) { (probe.value as? String)?.hasSuffix("last=light") == true }, "× plays a light tap: \(probe.value ?? "no probe")")
        // Undo first: the pill lasts a few seconds, and a busy simulator answers slowly.
        let undo = app.buttons["undo-pill.undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "Undo shows with the dismiss")
        XCTAssertFalse(offsite.exists, "a dismissed idea leaves at once")
        shot("tasks-ideas-5-dismissed" + Self.lookName)
        XCTAssertTrue(waitUntil(5) { !self.restCalls("POST", suffix: "/ideas/i_offsite/dismiss").isEmpty }, "the dismiss is sent")
        undo.tap()
        XCTAssertTrue(offsite.waitForExistence(timeout: 10), "Undo brings it back")
        XCTAssertFalse(restCalls("POST", suffix: "/ideas/i_offsite/restore").isEmpty, "the restore is sent")

        // Look Now, in the heading's menu: Looking… then the new idea.
        for _ in 0..<4 where !look.isHittable { app.swipeUp(velocity: .slow) }
        look.tap()
        let lookNow = app.buttons["Look Now"].firstMatch
        XCTAssertTrue(lookNow.waitForExistence(timeout: 5))
        lookNow.tap()
        XCTAssertTrue(app.descendants(matching: .any)["tasks.ideas.looking"].firstMatch.waitForExistence(timeout: 5), "says it's looking")
        shot("tasks-ideas-6-looking" + Self.lookName)
        XCTAssertTrue(app.descendants(matching: .any)["tasks.idea.Plan dinners for next week"].firstMatch.waitForExistence(timeout: 20),
                      "the look's new idea shows")
        shot("tasks-ideas-7-new" + Self.lookName)

        // The one its bot started is a task too.
        let started = app.descendants(matching: .any)["task-row-\(internet)"].firstMatch
        for _ in 0..<4 where !started.exists { app.swipeDown(velocity: .slow) }
        XCTAssertTrue(started.exists, "the one its bot started is a task")

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
