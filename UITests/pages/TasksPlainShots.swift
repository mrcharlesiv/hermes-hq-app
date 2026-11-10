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
        XCTAssertTrue(app.buttons["task.standing"].firstMatch.exists, "where it stands is the first row")
        XCTAssertFalse(app.buttons["task.share-draft"].firstMatch.exists, "no move buttons")
        settle(); shot("plain-1-ready" + Self.lookName)

        // The one line into the chat: the chat takes the screen, the task as its bar; the bar brings it back.
        let line = app.buttons["task.chat-line"].firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5) && line.isHittable, "the chat's line is above the composer")
        line.tap()
        let bar = app.descendants(matching: .any)["task.bar"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "the chat has the screen, the task as its bar")
        settle(); shot("plain-2-chat" + Self.lookName)
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).tap()
        XCTAssertTrue(check.waitForExistence(timeout: 5), "the bar brings the task back")

        // Needs you: the question set off, and its answers.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenTask", "Find 3 venues for the party"])
        XCTAssertTrue(app.buttons["task.choice.0"].firstMatch.waitForExistence(timeout: 20), "the budget's answers are taps")
        settle(); shot("plain-3-needs-you" + Self.lookName)

        // Working: the bot is on it; steps as a plain list.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenTask", "Renew passport"])
        XCTAssertTrue(app.buttons["task.standing"].firstMatch.waitForExistence(timeout: 20), "where it stands: Hermes is on it")
        settle(); shot("plain-4-working" + Self.lookName)

        // Your own task: its date, its notes and its steps; no bot section until there is something in it.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenTask", "Go through the open job applications"])
        XCTAssertTrue(check.waitForExistence(timeout: 20), "your own task opens")
        settle(); shot("plain-6-own" + Self.lookName)

        // A long needs-you task (the owner's screenshot, 2026-11-08): all of it reads on the first screen.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenTask", "Follow up with Dana on Fixture Co redlines"])
        XCTAssertTrue(check.waitForExistence(timeout: 20), "Dana's task opens")
        settle(); shot("plain-5-long" + Self.lookName)
    }
}
