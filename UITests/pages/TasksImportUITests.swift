// [tasks] Import from Reminders on the Tasks page (docs/tasks.md, "Adding"). EventKit hands the reminders back on its
// own queue; builds 755 (iPhone) and 756 (Mac) read them in a closure the main actor owned, and Swift's isolation
// check stopped the app on every import. Run with scripts/e2e-pages.sh (HQN_PAGES_ONLY=testTasks_ImportFromReminders).

import XCTest

extension PagesTests {
    /// The import asks first, adds each open reminder as your own task (`source.kind` reminders), and a second import
    /// from the ⋯ menu adds nothing again.
    @MainActor func testTasks_ImportFromReminders() throws {
        // `-HQPagesImportReminders 2` adds two reminders to the simulator's Reminders, then taps Import from Reminders.
        app = launchSignedIn(["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesImportReminders", "2"])
        allowReminders()
        let importButton = app.alerts.buttons["Import"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 25), "asks to import (builds 755/756 stopped the app here)")
        shot("tasks-import-ask")
        importButton.tap()

        let posted = { self.requests().filter { $0.method == "POST" && $0.path == "/api/plugins/hermes-hq-push/tasks" } }
        XCTAssertTrue(waitUntil(10) { posted().count >= 2 }, "each reminder is sent as a task")
        for request in posted() {
            XCTAssertEqual(request.body?["who"] as? String, "me")
            XCTAssertEqual((request.body?["source"] as? [String: Any])?["kind"] as? String, "reminders")
        }
        XCTAssertTrue(app.state == .runningForeground, "the app is still open")
        // Every reminder the simulator holds goes (earlier runs left more than two): wait until the posts stop coming.
        var count = posted().count, since = Date()
        _ = waitUntil(15) {
            let now = posted().count
            if now != count { count = now; since = Date() }
            return Date().timeIntervalSince(since) > 1.5
        }

        // The real menu, as you'd tap it: everything is in already.
        app.buttons["tasks.more"].firstMatch.tap()   // [bot-pills] the page's commands; the bots are pills under the bar
        let menuItem = app.buttons["Import from Reminders…"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5))
        menuItem.tap()
        XCTAssertTrue(app.staticTexts["Already imported"].waitForExistence(timeout: 10), "a second import adds nothing")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertEqual(posted().count, count)
        shot("tasks-import-again")
    }

    /// The system's Reminders question, if this simulator hasn't been asked yet.
    @MainActor private func allowReminders() {
        // iOS 27 says "Allow"; iOS 17-26 said "Allow Full Access".
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // iOS 27 can list the alert's "Allow" twice: the first one is the button.
        let buttons = [springboard.buttons["Allow"].firstMatch, springboard.buttons["Allow Full Access"].firstMatch]
        if waitUntil(8, app: springboard, { buttons.contains { $0.exists } }), let allow = buttons.first(where: { $0.exists }) {
            allow.tap()
        }
    }
}
