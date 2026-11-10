// [manualorder] Filter › Sort By end to end against the settings fixture (tester, 2026-10-29: "a 'manual sort'
// option"): a row's More › Move Down puts Research above Ivy in Work and turns Sort By to Manual, the order is kept
// across a relaunch, Recent Activity puts it back; and a row dragged to a new place lands there. Run with
//   HQN_SETTINGS_PORTS="9961 9962 9963" HQN_E2E_ONLY="testBB6_MoveDownKeepsAManualOrder,testBB7_DragARowToANewPlace" \
//   scripts/e2e-settings.sh <SIM>
// (HQN_SETTINGS_DESKTOPLOOK=1 for the Desktop Look's shots.)

import XCTest

extension SettingsEndToEndTests {
    /// Whether Research's row sits above Ivy's (both in Work).
    @MainActor func researchAboveSam(_ app: XCUIApplication) -> Bool {
        let research = app.cells["bot-row-research"], ivy = app.cells["bot-row-ivy"]
        return research.exists && ivy.exists && research.frame.midY < ivy.frame.midY
    }

    /// Filter › Sort By, open (its two choices showing).
    @MainActor func openSortBy(_ app: XCUIApplication) {
        let filter = app.buttons["bots.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5), "Filter (always on the bar: [filters-only])")
        let sortBy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sort By'")).firstMatch
        for _ in 0..<3 where !sortBy.exists {
            filter.tap()
            _ = sortBy.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(sortBy.exists, "Sort By ›")
        sortBy.tap()
        XCTAssertTrue(app.buttons["Recent Activity"].firstMatch.waitForExistence(timeout: 3), "Recent Activity")
        XCTAssertTrue(app.buttons["Manual"].firstMatch.exists, "Manual")
    }

    @MainActor func closeMenu(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
        _ = waitUntil(timeout: 3) { !app.buttons["Manual"].firstMatch.exists }
    }

    @MainActor func testBB6_MoveDownKeepsAManualOrder() throws {
        let app = launchSignedIn()
        XCTAssertTrue(app.cells["bot-row-research"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 5) { !self.researchAboveSam(app) }, "Recent Activity: Ivy (2 h ago) above Research (3 h)")
        openSortBy(app)
        shot(app, "bots-sort-by-menu")
        closeMenu(app)

        // Ivy's menu › More › Move Down: Research first, and Sort By says Manual.
        // The menu's More, not the tab bar's (the Desktop Look's docked bar has buttons of that name too).
        let tabTop = app.buttons["tab-more"].firstMatch.frame.minY
        func menuMore() -> XCUIElement? {
            app.buttons.matching(NSPredicate(format: "label == 'More'")).allElementsBoundByIndex
                .first { $0.exists && $0.frame.maxY < tabTop - 4 }
        }
        for _ in 0..<3 where menuMore() == nil {
            app.cells["bot-row-ivy"].press(forDuration: 1.0)
            _ = waitUntil(timeout: 3) { menuMore() != nil }
        }
        let more = try XCTUnwrap(menuMore(), "the row's menu › More")
        more.tap()
        tapMenu(app, "Move Down")
        XCTAssertTrue(waitUntil(timeout: 5) { self.researchAboveSam(app) }, "Research above Ivy after Move Down")
        // [main-e2e] The order travels to the owner's other devices as a synced document (left out of `writes`).
        XCTAssertEqual(a.writes("profiles.configure").count, 0, "the order is not written onto the bots")
        shot(app, "bots-manual-reordered")
        openSortBy(app)
        shot(app, "bots-sort-by-manual")
        closeMenu(app)

        // A relaunch with the saved sign-in: still Research first.
        app.terminate()
        app.launchArguments = ["-HQDebugNoDrag", "YES"] + appearanceArguments
        app.launch()
        XCTAssertTrue(app.cells["bot-row-research"].waitForExistence(timeout: 20), "signed in still")
        XCTAssertTrue(waitUntil(timeout: 5) { self.researchAboveSam(app) }, "Research still above Ivy after a relaunch")
        shot(app, "bots-manual-after-relaunch")

        // Sort By › Recent Activity: the saved order goes, Ivy is back on top.
        openSortBy(app)
        tapMenu(app, "Recent Activity")
        XCTAssertTrue(waitUntil(timeout: 5) { !self.researchAboveSam(app) }, "Recent Activity puts Ivy back above Research")
    }

    @MainActor func testBB7_DragARowToANewPlace() throws {
        let app = launchSignedIn(drag: true)
        let research = app.cells["bot-row-research"], ivy = app.cells["bot-row-ivy"]
        XCTAssertTrue(research.waitForExistence(timeout: 10) && ivy.exists)
        XCTAssertTrue(waitUntil(timeout: 5) { !self.researchAboveSam(app) })
        // Research held, then dragged onto Ivy's upper part: it takes Ivy's place. Points fixed on the screen before the
        // hold (a lifted row's menu moves the elements' frames). A straight, slow drag down the list never lifts the row
        // out of its menu under XCUITest; a sideways part at the default speed does.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let from = origin.withOffset(CGVector(dx: research.frame.midX, dy: research.frame.midY))
        let to = origin.withOffset(CGVector(dx: ivy.frame.midX + 90, dy: ivy.frame.minY + ivy.frame.height * 0.2))
        from.press(forDuration: 0.6, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 1.0)
        let moved = waitUntil(timeout: 5) { self.researchAboveSam(app) }
        if !moved { dump(app, "row-drag") }
        XCTAssertTrue(moved, "Research above Ivy after the drop")
        XCTAssertTrue(app.cells["section-header-Work"].exists, "still in Work")
        XCTAssertEqual(a.writes("profiles.configure").count, 0, "a place in the same section sends nothing")
        shot(app, "bots-row-dragged")
    }

    /// Notes (no section) dropped on Ivy's upper part: filed in Work (one write), and placed above Ivy.
    @MainActor func testBB8_DragARowIntoAnotherSectionLandsInPlace() throws {
        let app = launchSignedIn(drag: true)
        let notes = app.cells["bot-row-notes"], ivy = app.cells["bot-row-ivy"]
        XCTAssertTrue(notes.waitForExistence(timeout: 10) && ivy.exists)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let from = origin.withOffset(CGVector(dx: notes.frame.midX, dy: notes.frame.midY))
        let to = origin.withOffset(CGVector(dx: ivy.frame.midX + 90, dy: ivy.frame.minY + ivy.frame.height * 0.2))
        from.press(forDuration: 0.6, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 1.0)
        let header = app.cells["section-header-Work"]
        let landed = waitUntil(timeout: 8) {
            notes.exists && ivy.exists && header.exists && notes.frame.midY > header.frame.midY && notes.frame.midY < ivy.frame.midY
        }
        if !landed { dump(app, "row-drag-section") }
        XCTAssertTrue(landed, "Notes in Work, above Ivy")
        XCTAssertTrue(waitUntil(timeout: 5) { self.a.writes("profiles.configure").count == 1 }, "the filing is one write")
        shot(app, "bots-row-dragged-into-section")
    }
}
