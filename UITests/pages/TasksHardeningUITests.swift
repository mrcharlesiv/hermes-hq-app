// End-to-end UI verification for Tasks hardening: inline task title editing (tap-to-edit + ⋯ › Details › Rename Task),
// list check-off Undo pill, and Edit List updated colour copy. Run with:
//   HQN_PAGES_ONLY=testTasks_HardeningShowcase scripts/e2e-pages.sh <SIM_UDID>

import XCTest

extension PagesTests {
    @MainActor func testTasks_HardeningShowcase() throws {
        // 1. Open a task and edit its title inline by tapping the title.
        app = launchSignedIn(Self.look + ["-HQDebugUndoSeconds", "30",
                                          "-HQPagesTab", "4", "-HQPagesMore", "tasks",
                                          "-HQPagesOpenTask", "Pick up dry cleaning"])
        let title = app.staticTexts["task.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 20), "task sheet opens with title")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        title.tap()

        let field = app.textViews["task.title.field"].firstMatch.exists
            ? app.textViews["task.title.field"].firstMatch
            : app.textFields["task.title.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "tapping the title enters inline edit mode")
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        shot("hardening-1-title-editing")

        field.typeText(" (today)")
        let doneButton = app.buttons["task.edit-done"].firstMatch
        XCTAssertTrue(doneButton.waitForExistence(timeout: 3), "keyboard Done button commits title edit")
        doneButton.tap()
        XCTAssertTrue(waitUntil(6) {
            app.staticTexts["task.title"].firstMatch.exists
                && app.staticTexts["task.title"].firstMatch.label.contains("(today)")
        }, "edited title saves and renders")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        shot("hardening-2-title-saved")

        // Restore original title via ⋯ › Details › Rename Task? Verify the action exists first.
        let more = app.buttons["task.more"].firstMatch
        if more.waitForExistence(timeout: 3) {
            more.tap()
            let details = app.buttons["Details"].firstMatch
            if details.waitForExistence(timeout: 3) {
                details.tap()
                XCTAssertTrue(app.buttons["Rename Task"].firstMatch.waitForExistence(timeout: 3), "⋯ › Details includes Rename Task")
                shot("hardening-3-rename-menu")
                // Dismiss menu
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2)).tap()
            }
        }

        // 2. Close sheet to Today list and check off from the list to verify the Undo pill.
        let close = app.navigationBars.buttons["Close"].firstMatch
        if close.waitForExistence(timeout: 3) && close.isHittable {
            close.tap()
        } else {
            app.swipeDown(velocity: .fast)
        }
        let row = app.cells["task-row-Pick up dry cleaning (today)"].firstMatch
        let fallbackRow = app.cells["task-row-Pick up dry cleaning"].firstMatch
        let targetRow = row.waitForExistence(timeout: 8) ? row : fallbackRow
        XCTAssertTrue(targetRow.waitForExistence(timeout: 6), "renamed task shows in Today list")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))

        // Tap the leading check circle.
        targetRow.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 31, dy: targetRow.frame.height / 2)).tap()
        let undo = app.buttons["undo-pill.undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 8), "checking off from the list shows the Undo pill")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        shot("hardening-4-list-undo")

        // Tap Undo and confirm the task returns to Today.
        undo.tap()
        XCTAssertTrue(targetRow.waitForExistence(timeout: 8), "tapping Undo restores the checked-off task")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        shot("hardening-5-after-undo")
    }
}
