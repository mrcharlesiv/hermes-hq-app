// [task-ideas] Suggested tasks live front and center: top pending ideas show inline right on Grouped Overview (with
// 1-tap Add / ×, tap-to-expand, and "See all ›"), and Suggested has its own dedicated view under Agents (and in the
// Mac sidebar). Ideas starts off; once on, each idea can be added from Overview or Suggested, expanded for full details
// and "Add & Let <Bot> Start", or dismissed (Undo brings it back), and the heading's menu looks for more. Run with
// scripts/e2e-pages.sh (HQN_PAGES_ONLY=testTasks_Ideas); HQN_TASKS_LOOK picks the look.

import XCTest

extension PagesTests {
    @MainActor func testTasks_Ideas() throws {
        app = launchSignedIn(Self.look + ["-HQDebugHapticsProbe", "YES", "-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        // Tasks opens on Grouped Overview; Suggested sits under Agents (no inline card while Ideas is off).
        let suggested = app.buttons["tasks.view.suggested"].firstMatch
        XCTAssertTrue(suggested.waitForExistence(timeout: 20), "Suggested is listed under Agents on Overview")
        XCTAssertFalse(app.descendants(matching: .any)["tasks.mode"].exists, "no To Do | Ideas switch")
        XCTAssertFalse(app.descendants(matching: .any)["tasks.overview.suggested"].exists, "inline card stays hidden while off")
        shot("tasks-ideas-1-overview-off" + Self.lookName)

        // Ideas starts off until you turn it on from the dedicated Suggested page.
        suggested.tap()
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

        // The ideas, newest first, right at the top of the dedicated Suggested page.
        let registration = app.descendants(matching: .any)["tasks.idea.Renew the car registration"].firstMatch
        XCTAssertTrue(registration.waitForExistence(timeout: 10), "the ideas show once on")
        let status = app.staticTexts["tasks.ideas.status"].firstMatch
        XCTAssertTrue(status.exists)
        XCTAssertTrue(status.label.hasPrefix("Suggested by Hermes") && status.label.hasSuffix("3"), status.label)
        let sourcesBar = app.buttons["tasks.ideas.sources"].firstMatch
        XCTAssertTrue(sourcesBar.waitForExistence(timeout: 5), "Where to Look summary strip shows on Suggested page")
        XCTAssertTrue(sourcesBar.label.contains("Chats, Memory"), sourcesBar.label)
        let look = app.buttons["tasks.ideas.look"].firstMatch
        XCTAssertTrue(look.exists, "when it looked is the heading's menu")
        XCTAssertTrue(look.label.hasPrefix("Look"), look.label)
        let internet = "Compare internet plans before the promo ends"
        XCTAssertFalse(app.buttons["tasks.idea.start.\(internet)"].exists, "a row has Add and ×; the bot starting is on its card")
        shot("tasks-ideas-3-rows" + Self.lookName)

        // Tap Sources › to open Where to Look, enable Notion (on Finance -> multi-bot sweep!), and confirm live update.
        sourcesBar.tap()
        let notionToggle = app.switches["tasks.ideas.connector.mcp:notion"].firstMatch
        for _ in 0..<4 where !(notionToggle.exists && notionToggle.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(notionToggle.waitForExistence(timeout: 5), "auto-discovered Notion connector appears (off by default)")
        XCTAssertEqual(notionToggle.value as? String, "0", "newly connected apps default to off")
        shot("tasks-ideas-3a-where-to-look" + Self.lookName)
        notionToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(waitUntil(10) {
            self.restCalls("PUT", suffix: "/tasks/settings").contains { call in
                guard let body = call["body"] as? [String: Any],
                      let src = body["ideas_sources"] as? [String: Any],
                      let conns = src["connectors"] as? [String],
                      let bots = body["ideas_bots"] as? [String] else { return false }
                return conns.contains("mcp:notion") && bots.contains("default") && bots.contains("finance")
            }
        }, "enabling Notion saves connector and auto-includes Finance in multi-bot ideas_bots")
        let closeBtn = app.navigationBars["Where to Look"].buttons.firstMatch
        if closeBtn.exists { closeBtn.tap() } else { app.swipeDown(velocity: .fast) }
        XCTAssertTrue(waitUntil(10) { sourcesBar.exists && sourcesBar.label.contains("Notion") },
                      "Suggested banner updates with Notion: \(sourcesBar.label)")
        shot("tasks-ideas-3a2-after-sources" + Self.lookName)

        // Back on Overview: pending suggestions now appear inline right under the Smart Views grid.
        backToTasksOverview()
        let inlineCard = app.descendants(matching: .any)["tasks.overview.suggested"].firstMatch
        XCTAssertTrue(inlineCard.waitForExistence(timeout: 10), "inline Suggested card shows on Overview when ideas are pending")
        shot("tasks-ideas-3b-overview-inline" + Self.lookName)

        // 1-tap Add directly from Overview's inline card.
        let inlineAdd = app.buttons["tasks.overview.idea.add.Renew the car registration"].firstMatch
        XCTAssertTrue(inlineAdd.waitForExistence(timeout: 5), "Add button right on Overview")
        inlineAdd.tap()
        XCTAssertTrue(waitUntil(10) { !app.descendants(matching: .any)["tasks.overview.idea.Renew the car registration"].exists },
                      "added idea leaves Overview's inline card")
        XCTAssertTrue(waitUntil(5) { !self.restCalls("POST", suffix: "/ideas/i_registration/add").isEmpty }, "the add is sent")

        // Tap a row on Overview to expand details inline, then tap "See all ›" to open the full Suggested page.
        let inlineInternet = app.descendants(matching: .any)["tasks.overview.idea.\(internet)"].firstMatch
        XCTAssertTrue(inlineInternet.waitForExistence(timeout: 5))
        inlineInternet.tap()
        XCTAssertTrue(app.buttons["tasks.overview.idea.start.\(internet)"].firstMatch.waitForExistence(timeout: 5),
                      "tapping an inline suggestion expands its details and bot-start button")
        shot("tasks-ideas-4a-overview-expanded" + Self.lookName)

        let seeAll = app.buttons["tasks.overview.suggested.see-all"].firstMatch
        XCTAssertTrue(seeAll.exists, "See all opens the dedicated Suggested page")
        seeAll.tap()
        XCTAssertTrue(waitUntil(5) { status.exists && status.label.hasSuffix("2") }, "two ideas left: \(status.label)")

        // Tap an idea on the Suggested page to expand its card and tap Add & Let Finance Start.
        let internetRow = app.descendants(matching: .any)["tasks.idea.\(internet)"].firstMatch
        XCTAssertTrue(internetRow.waitForExistence(timeout: 5))
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
        let probe = app.descendants(matching: .any)["debug.haptics"].firstMatch
        XCTAssertTrue(waitUntil(5) { (probe.value as? String)?.hasSuffix("last=light") == true }, "× plays a light tap: \(probe.value ?? "no probe")")
        let undo = app.buttons["undo-pill.undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "Undo shows with the dismiss")
        XCTAssertFalse(offsite.exists, "a dismissed idea leaves at once")
        shot("tasks-ideas-5-dismissed" + Self.lookName)
        XCTAssertTrue(waitUntil(5) { !self.restCalls("POST", suffix: "/ideas/i_offsite/dismiss").isEmpty }, "the dismiss is sent")
        undo.tap()
        XCTAssertTrue(offsite.waitForExistence(timeout: 10), "Undo brings it back")
        XCTAssertFalse(restCalls("POST", suffix: "/ideas/i_offsite/restore").isEmpty, "the restore is sent")

        // Look Now, in the heading's menu: Looking… then the new idea.
        look.tap()
        let lookNow = app.buttons["Look Now"].firstMatch
        XCTAssertTrue(lookNow.waitForExistence(timeout: 5))
        lookNow.tap()
        XCTAssertTrue(app.descendants(matching: .any)["tasks.ideas.looking"].firstMatch.waitForExistence(timeout: 5), "says it's looking")
        shot("tasks-ideas-6-looking" + Self.lookName)
        XCTAssertTrue(app.descendants(matching: .any)["tasks.idea.Plan dinners for next week"].firstMatch.waitForExistence(timeout: 20),
                      "the look's new idea shows")
        shot("tasks-ideas-7-new" + Self.lookName)

        // Added ideas became tasks in Inbox, and Inbox no longer duplicates the Suggested section.
        tapView("inbox")
        XCTAssertTrue(app.descendants(matching: .any)["task-row-Renew the car registration"].firstMatch.waitForExistence(timeout: 10),
                      "the added idea is a task in Inbox")
        XCTAssertTrue(app.descendants(matching: .any)["task-row-\(internet)"].firstMatch.exists,
                      "the one its bot started is a task too")
        XCTAssertFalse(app.staticTexts["tasks.ideas.status"].exists, "Inbox no longer duplicates Suggested")

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
