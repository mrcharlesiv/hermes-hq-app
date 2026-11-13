// [tasks] Owner 2026-11-04: "We need a way for users to be able to turn off the tasks feature entirely." Settings ›
// Tasks off: the gateway is told (every bot loses the tools, the note and the prep jobs: hermes-hq-push 0.9.36), and
// the page leaves More, staying gone after a relaunch; on brings it back. Run with scripts/e2e-pages.sh
// (HQN_PAGES_ONLY=testTasks_TurnOffEntirely); every look: TEST_RUNNER_HQN_TASKS_LOOK=dark | desktop | desktop-dark.

import XCTest

extension PagesTests {
    @MainActor func testTasks_TurnOffEntirely() throws {
        let look = ProcessInfo.processInfo.environment["HQN_TASKS_LOOK"]
        let name = look.map { "-" + $0 } ?? ""
        let arguments: [String] = switch look {
        case "dark": ["-hqn.appearance", "dark"]
        case "desktop": ["-hqn.appearance", "light", "-hqn.theme.desktopLook", "<true/>"]
        case "desktop-dark": ["-hqn.appearance", "dark", "-hqn.theme.desktopLook", "<true/>"]
        default: ["-hqn.appearance", "light"]
        }
        app = launchSignedIn(arguments + ["-HQPagesTab", "4"])
        let row = app.cells["more-row-tasks"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "Tasks is in More")

        // Off, from Settings.
        let toggle = openTasksSwitch()
        XCTAssertEqual(toggle.value as? String, "1", "on by default")
        shot("tasks-off-switch-on" + name)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let saved = { (on: Bool) in self.requests().contains { $0.method == "PUT" && $0.path.hasSuffix("/tasks/settings") && ($0.body?["enabled"] as? Bool) == on } }
        XCTAssertTrue(waitUntil(10) { saved(false) }, "the gateway is told, so the bots stop too")
        XCTAssertTrue(waitUntil(5) { toggle.value as? String == "0" })
        shot("tasks-off-switch-off" + name)

        // The page is gone from More, and stays gone after a relaunch.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.cells["more-row-settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(5) { !app.cells["more-row-tasks"].exists }, "Tasks left More")
        shot("tasks-off-more" + name)
        app.terminate()
        app = launchSignedIn(arguments + ["-HQPagesTab", "4"])
        XCTAssertTrue(app.cells["more-row-settings"].waitForExistence(timeout: 20))
        sleep(2)
        XCTAssertFalse(app.cells["more-row-tasks"].exists, "still gone after a relaunch")

        // On again: it comes back.
        let again = openTasksSwitch()
        XCTAssertEqual(again.value as? String, "0")
        again.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(waitUntil(10) { saved(true) }, "on is saved")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.cells["more-row-tasks"].waitForExistence(timeout: 10), "Tasks is back")
    }

    /// More › Settings, scrolled to the Tasks switch.
    @MainActor private func openTasksSwitch() -> XCUIElement {
        let settingsRow = app.cells["more-row-settings"]
        XCTAssertTrue(settingsRow.waitForExistence(timeout: 10))
        settingsRow.tap()
        let toggle = app.switches["settings.tasks"].firstMatch
        // Clear of the floating tab bar: a switch under it counts as hittable, and the tap lands on the bar (Settings
        // put Tasks at the foot of the first screen, 2026-11-09, and this test tapped More for four days).
        let bar = app.tabBars.firstMatch
        let floor = { bar.exists ? bar.frame.minY - 12 : self.app.frame.height * 0.8 }
        for _ in 0..<6 where !(toggle.exists && toggle.isHittable && toggle.frame.maxY < floor()) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Settings › Tasks")
        return toggle
    }
}
