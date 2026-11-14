// [tasks] The plain task view (owner 2026-11-09: "no friction, it just works"; mockups share/2026-11-09-task-frictionless,
// "I like this"): a task in each state, the bot's offered answers as taps, what it changed, when it looks again, and the
// one line into the task's chat. Run with scripts/e2e-pages.sh (HQN_PAGES_ONLY=testTasks_PlainShots); HQN_TASKS_LOOK
// picks the look.

import XCTest

extension PagesTests {
    /// The page opens at a starting height and settles to its own; a picture waits for that.
    @MainActor private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(1.5)) }

    @MainActor func testTasks_PlainShots() throws {
        // Ready: Inbox's words whole, its draft, three answers to tap, what it ticked, and when it looks again.
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks",
                                          "-HQPagesOpenTask", "Follow up with Ivy on the contract"])
        let check = app.buttons["task.check"].firstMatch
        XCTAssertTrue(check.waitForExistence(timeout: 20), "Ivy's task opens with its circle")
        XCTAssertTrue(app.buttons["task.choice.0"].firstMatch.waitForExistence(timeout: 5), "Inbox's answers are taps")
        XCTAssertTrue(app.buttons["task.choice.0"].firstMatch.isHittable, "on the first screen")
        XCTAssertTrue(app.descendants(matching: .any)["task.next-check"].firstMatch.exists, "when Inbox looks again shows")
        // [tasks-first] The bot is on the who row, with what it is doing; the bar names the task's list, not the bot.
        let who = app.descendants(matching: .any)["task.who"].firstMatch
        XCTAssertTrue(who.exists && who.label.contains("You & Inbox") && who.label.contains("Finished its part"), "the who row: \(who.label)")
        XCTAssertFalse(app.buttons["task.standing"].exists, "no state row of the bot's above the task's own")
        XCTAssertTrue(app.descendants(matching: .any)["task.ask"].firstMatch.exists, "its question is one card under the who row")
        XCTAssertFalse(app.buttons["task.share-draft"].firstMatch.exists, "no move buttons")
        let title = app.descendants(matching: .any)["chat.title"].firstMatch
        XCTAssertTrue(title.exists && title.label.hasPrefix("Task"), "with no lists the bar just says Task, not a bot's name: \(title.label)")
        // The chat's own message box stands aside; the task's view has one line.
        let message = app.buttons["task.message"].firstMatch
        XCTAssertTrue(message.exists && message.isHittable, "the one-line message box is at the view's foot")
        XCTAssertFalse(app.textViews["composer.text"].firstMatch.exists, "the chat's full box is not on the task's view")
        settle(); shot("plain-1-ready" + Self.lookName)

        // The one line into the chat: the chat takes the screen with its own box, the task as its bar; the bar
        // brings the task back.
        message.tap()
        let bar = app.descendants(matching: .any)["task.bar"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "the chat has the screen, the task as its bar")
        XCTAssertTrue(app.textViews["composer.text"].firstMatch.waitForExistence(timeout: 5), "with the chat's own message box")
        settle(); shot("plain-2-chat" + Self.lookName)
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).tap()
        XCTAssertTrue(check.waitForExistence(timeout: 5), "the bar brings the task back")
        XCTAssertTrue(waitUntil(5) { !app.textViews["composer.text"].firstMatch.exists }, "and the full box steps aside again")

        // Needs you: the question set off, and its answers.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenTask", "Find 3 venues for the party"])
        XCTAssertTrue(app.buttons["task.choice.0"].firstMatch.waitForExistence(timeout: 20), "the budget's answers are taps")
        settle(); shot("plain-3-needs-you" + Self.lookName)

        // Working: the bot is on it; steps as a plain list.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenTask", "Renew passport"])
        XCTAssertTrue(who.waitForExistence(timeout: 20) && who.label.contains("Working"), "the who row says Hermes is working: \(who.label)")
        XCTAssertFalse(app.descendants(matching: .any)["task.ask"].exists, "nothing asked: no card under the who row")
        XCTAssertTrue(app.descendants(matching: .any)["task.chat-line"].firstMatch.exists, "its conversation is the last section")
        settle(); shot("plain-4-working" + Self.lookName)

        // Your own task: its date, its notes and its steps; no bot section until there is something in it.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenTask", "Go through the open job applications"])
        XCTAssertTrue(check.waitForExistence(timeout: 20), "your own task opens")
        // [tasks-first] A task of your own is a task: no bot's name, no message box; Assign is on the who row.
        XCTAssertTrue(who.exists && who.label.contains("Who: Me"), "the who row: \(who.label)")
        XCTAssertTrue(app.descendants(matching: .any)["task.list"].firstMatch.exists, "the bar says its list")
        XCTAssertFalse(app.buttons["task.message"].exists, "nobody to message")
        XCTAssertFalse(app.textViews["composer.text"].exists, "no chat's message box")
        XCTAssertFalse(app.descendants(matching: .any)["task.chat-line"].exists, "no bot's section")
        XCTAssertFalse(app.buttons["task.help"].exists, "no Ask to Help row: Assign is the way")
        settle(); shot("plain-6-own" + Self.lookName)
        who.tap()
        XCTAssertTrue(app.buttons["Just Me"].firstMatch.waitForExistence(timeout: 5), "the who row's menu")
        XCTAssertTrue(app.staticTexts["With Me"].firstMatch.exists || app.buttons["Hermes"].firstMatch.exists, "offers the bots")
        settle(); shot("plain-7-assign" + Self.lookName)
        app.buttons["Just Me"].firstMatch.tap()   // already so: nothing changes
        XCTAssertTrue(waitUntil(5) { check.exists && check.isHittable }, "the task is still on show")

        // A long needs-you task (the owner's screenshot, 2026-11-08): all of it reads on the first screen.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenTask", "Follow up with Dana on Fixture Co redlines"])
        XCTAssertTrue(check.waitForExistence(timeout: 20), "Dana's task opens")
        settle(); shot("plain-5-long" + Self.lookName)
    }
}
