// [bot-pills] Owner 2026-11-05: "take the little bot pills that are on the top of the sessions page … and use it on
// the top of the tasks page" (Tiles was tried and dropped: its own pages sort it better). Tasks shows Sessions' rail
// under the bar (All, Me, then each bot with its face) in place of "All Bots ⌄"; a pill shows that bot's tasks, Me
// your own, the lit pill (or All) every one. Run with scripts/e2e-pages.sh (HQN_PAGES_ONLY=testBotPills_Tasks); every look:
// TEST_RUNNER_HQN_TASKS_LOOK=dark | desktop | desktop-dark.

import XCTest

extension PagesTests {
    @MainActor func testBotPills_Tasks() throws {
        let look = ProcessInfo.processInfo.environment["HQN_TASKS_LOOK"]
        let name = look.map { "-" + $0 } ?? ""
        let arguments: [String] = switch look {
        case "dark": ["-hqn.appearance", "dark"]
        case "desktop": ["-hqn.appearance", "light", "-hqn.theme.desktopLook", "<true/>"]
        case "desktop-dark": ["-hqn.appearance", "dark", "-hqn.theme.desktopLook", "<true/>"]
        default: ["-hqn.appearance", "light"]
        }

        // Tasks: the pills under the bar, All lit; no bot menu in the bar.
        app = launchSignedIn(arguments + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        let dentist = app.cells["task-row-Call the dentist"].firstMatch
        XCTAssertTrue(dentist.waitForExistence(timeout: 20), "Hermes' task is listed")
        let rail = app.descendants(matching: .any)["tasks.chips"]
        XCTAssertTrue(rail.exists, "the bot pills")
        XCTAssertFalse(app.buttons["pages.scope"].exists, "no \"All Bots\" menu in the bar")
        let all = app.buttons["tasks.chip.all"], hermes = app.buttons["tasks.chip.default"]
        XCTAssertTrue(all.isSelected, "All is lit")
        XCTAssertTrue(hermes.exists, "Hermes has a pill")
        XCTAssertGreaterThan(dentist.frame.minY, rail.frame.maxY - 1, "the list starts under the pills")
        shot("bot-pills-tasks-all" + name)

        // Research's pill: only Research's task.
        let research = app.buttons["tasks.chip.research"]
        XCTAssertTrue(research.exists, "Research has a pill")
        let width = app.windows.firstMatch.frame.maxX
        for _ in 0..<3 where research.frame.maxX > width - 8 { rail.swipeLeft() }   // past the screen's edge: the rail scrolls
        research.tap()
        XCTAssertTrue(waitUntil(5) { research.isSelected }, "Research is lit")
        XCTAssertTrue(app.cells["task-row-Find 3 venues for the party"].firstMatch.waitForExistence(timeout: 5), "Research's task")
        XCTAssertTrue(waitUntil(5) { !dentist.exists }, "Hermes' task is not shown")
        shot("bot-pills-tasks-research" + name)

        // The lit pill again: every bot.
        research.tap()
        XCTAssertTrue(waitUntil(5) { all.isSelected && dentist.exists }, "back to All")

        // Me: your own tasks only, the ones no bot helps with.
        let me = app.buttons["tasks.chip.me"]
        XCTAssertTrue(me.exists, "a Me pill")
        for _ in 0..<3 where me.frame.minX < 8 { rail.swipeRight() }
        XCTAssertLessThan(all.frame.midX, me.frame.midX)
        XCTAssertLessThan(me.frame.midX, hermes.frame.midX, "Me sits between All and the bots")
        me.tap()
        XCTAssertTrue(waitUntil(5) { me.isSelected }, "Me is lit")
        XCTAssertTrue(app.cells["task-row-Pick up dry cleaning"].firstMatch.waitForExistence(timeout: 5), "your own task")
        XCTAssertTrue(waitUntil(5) { !dentist.exists }, "a task Hermes helps with is not shown")
        XCTAssertFalse(app.cells["task-row-Find 3 venues for the party"].firstMatch.exists, "nor Research's")
        shot("bot-pills-tasks-me" + name)
        me.tap()
        XCTAssertTrue(waitUntil(5) { all.isSelected && dentist.exists }, "the lit Me goes back to All")
    }
}
