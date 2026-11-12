// [tasks] Owner 2026-11-04: "I would be cautious of too many things making it on the task list, so then the task list
// is not effective because it's just flooded … But it also has to be, like, used". What bots added from chats and
// nobody touched for two weeks waits under "Still Need These?" with Keep (swipe or hold), and Ask First is the default
// for catching tasks in chats. Run with scripts/e2e-pages.sh (HQN_PAGES_ONLY=testTasks_StillNeedTheseAndAskFirst);
// every look: TEST_RUNNER_HQN_TASKS_LOOK=dark | desktop | desktop-dark.

import XCTest

extension PagesTests {
    @MainActor func testTasks_StillNeedTheseAndAskFirst() throws {
        let look = ProcessInfo.processInfo.environment["HQN_TASKS_LOOK"]
        let name = look.map { "-" + $0 } ?? ""
        let arguments: [String] = switch look {
        case "dark": ["-hqn.appearance", "dark"]
        case "desktop": ["-hqn.appearance", "light", "-hqn.theme.desktopLook", "<true/>"]
        case "desktop-dark": ["-hqn.appearance", "dark", "-hqn.theme.desktopLook", "<true/>"]
        default: ["-hqn.appearance", "light"]
        }
        app = launchSignedIn(arguments + ["-HQDebugHapticsProbe", "YES", "-HQPagesTab", "4", "-HQPagesMore", "tasks"])

        // [tasks-first] They have no date and no list, so they are in Inbox: the group sits under its tasks, above
        // Done, and says why.
        let inbox = app.buttons["tasks.view.inbox"].firstMatch
        XCTAssertTrue(inbox.waitForExistence(timeout: 20), "the views head the page")
        inbox.tap()
        let header = app.descendants(matching: .any)["tasks.section.Still Need These?"].firstMatch
        for _ in 0..<8 where !(header.exists && header.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(header.waitForExistence(timeout: 15), "forgotten bot tasks ask to be kept")
        XCTAssertTrue(app.descendants(matching: .any)["tasks.stale.note"].firstMatch.exists, "the group says why")
        let desk = app.cells["task-row-Look into a standing desk"].firstMatch
        for _ in 0..<3 where !(desk.exists && desk.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(desk.exists, "the oldest is listed")
        XCTAssertGreaterThan(desk.frame.minY, header.frame.minY)
        let addedBy = desk.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Added by Hermes")).firstMatch
        XCTAssertTrue(desk.label.contains("Added by Hermes") || addedBy.exists, "who added it, and when: \(desk.label)")
        shot("tasks-ask-first-stale" + name)

        // Keep: a swipe shows it beside Delete; it's felt, sends nothing but the rev, and the task leaves the group.
        desk.swipeLeft()
        let keep = app.buttons["Keep"].firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 5), "Keep beside Delete")
        shot("tasks-ask-first-keep" + name)
        let cues = hapticCount()
        keep.tap()
        XCTAssertTrue(waitUntil(5) { self.hapticCount() > cues }, "Keep is felt")
        let patched = { self.requests().filter { $0.method == "PATCH" && $0.path.hasSuffix("/tasks/t_desk") } }
        XCTAssertTrue(waitUntil(10) { !patched().isEmpty }, "Keep reaches the gateway")
        XCTAssertEqual(patched().first?.body?.keys.sorted(), ["rev"], "nothing about the task changes")
        XCTAssertTrue(waitUntil(5) { !desk.exists || desk.frame.minY < header.frame.minY }, "it leaves the group")

        // Hold a row: Keep is first in its menu.
        let sitter = app.cells["task-row-Find a plant sitter for December"].firstMatch
        for _ in 0..<3 where !(sitter.exists && sitter.isHittable) { app.swipeUp(velocity: .slow) }
        sitter.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["Keep"].firstMatch.waitForExistence(timeout: 5), "Keep in the menu")
        shot("tasks-ask-first-menu" + name)
        app.buttons["Keep"].firstMatch.tap()

        // Tasks Settings: Ask First is the default, first in the picker.
        for _ in 0..<8 where !app.buttons["pages.scope"].firstMatch.isHittable { app.swipeDown(velocity: .fast) }
        app.buttons["pages.scope"].firstMatch.tap()   // [tasks-first] Filter: the bots, then the page's commands
        app.buttons["Tasks Settings…"].firstMatch.tap()
        let footer = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "When you say you need to do something, a bot asks")).firstMatch
        XCTAssertTrue(footer.waitForExistence(timeout: 10), "Ask First is on")
        shot("tasks-ask-first-settings" + name)
    }

    /// The DEBUG probe's count of cues that would have played (`-HQDebugHapticsProbe YES`).
    @MainActor private func hapticCount() -> Int {
        let probe = app.descendants(matching: .any)["debug.haptics"]
        guard probe.waitForExistence(timeout: 5), let value = probe.value as? String,
              let count = value.split(separator: " ").first?.split(separator: "=").last.flatMap({ Int($0) }) else { return -1 }
        return count
    }
}
