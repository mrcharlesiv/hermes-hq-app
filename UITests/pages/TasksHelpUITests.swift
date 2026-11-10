// [tasks] Owner 2026-11-04 (build 755: "it just added it to my to-do list. I think we can do better"). A task of yours
// alone gets "Ask Hermes to Help" on its chat card and in its sheet; one Hermes takes part in shows its steps, with its
// own step started. Run with scripts/e2e-pages.sh (HQN_PAGES_ONLY=testTasks_AskToHelp).

import XCTest

extension PagesTests {
    /// The chat card of a task Hermes helps with lists the steps and "Started"; the card of a task of yours alone offers
    /// help, and the tap asks Hermes in this chat with the task's id. The task sheet offers the same.
    @MainActor func testTasks_AskToHelp() throws {
        app = launchSignedIn()
        tabButton("Sessions", in: app).tap()
        let row = app.cells["session-row-s-help"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the job applications chat is listed")
        row.tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 15), "the chat opens")

        // Hermes's part, started: the steps are read out with the card.
        let together = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Rank all 167")).firstMatch
        XCTAssertTrue(together.waitForExistence(timeout: 10), "the card lists the steps")
        XCTAssertTrue(together.label.contains("Started"), together.label)
        shot("tasks-help-steps")

        // Yours alone: Ask Hermes to Help, in this chat.
        let help = app.buttons["chat.tasks.help"].firstMatch
        if !help.isHittable { app.tables["chat.table"].swipeDown(velocity: .slow) }
        XCTAssertTrue(help.waitForExistence(timeout: 5), "the vet card offers help")
        XCTAssertEqual(help.label, "Ask Hermes to Help")
        shot("tasks-help-offer")
        help.tap()
        XCTAssertTrue(waitUntil(10) { self.prompts().contains { $0.contains("(Task id t_vet)") } }, "asks Hermes: \(prompts())")
        let asked = prompts().first { $0.contains("(Task id t_vet)") } ?? ""
        XCTAssertTrue(asked.hasPrefix("Help me with this: ask me which parts you should take, then start them."), asked)
        XCTAssertTrue(asked.contains("“Call the vet”"), asked)
        let bubble = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Help me with “Call the vet”")).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5), "your bubble says it short")
        shot("tasks-help-asked")

        // The task sheet: a task of yours with no steps gets the same button.
        app.terminate()
        app = launchSignedIn(["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenTask", "Pick up dry cleaning"])
        let sheetHelp = app.buttons["task.help"].firstMatch
        XCTAssertTrue(sheetHelp.waitForExistence(timeout: 15), "the sheet offers help")
        XCTAssertTrue(sheetHelp.label.contains("Ask Hermes to Help"), sheetHelp.label)
        shot("tasks-help-sheet")
    }

    /// What the app sent Hermes as prompts, oldest first.
    private func prompts() -> [String] {
        let state = (try? account.control("/__fixture/state")) ?? [:]
        return ((state["rpc"] as? [[String: Any]]) ?? []).filter { ($0["method"] as? String) == "prompt.submit" }
            .compactMap { ($0["params"] as? [String: Any])?["text"] as? String }
    }
}
