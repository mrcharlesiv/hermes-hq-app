// Sessions with Show › Archived: Mark as Read on an archived chat clears its dot at once (n20-sessions B3: the server
// flag was rewritten in the live slices only, so an archived row kept its dot until the next archived read).

import XCTest

extension SessionsTests {
    @MainActor func test101_MarkReadOnAnArchivedChat() throws { archivedReadRound(desktop: false) }

    @MainActor func test102_MarkReadOnAnArchivedChatInTheDesktopLook() throws { archivedReadRound(desktop: true) }

    @MainActor func archivedReadRound(desktop: Bool) {
        let look = desktop ? "desktop" : "standard"
        setRow("s-old", ["unread": true])
        let app = launch(extra: desktop ? ["-HQDebugDesktopLook", "YES"] : [])
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openFilter(app)
        tapFilter(app, "show", "archived")
        closeFilter(app)
        chip(app, "deploys").tap()                    // brings the old chat up from under the tab bar
        let old = row(app, "s-old")
        XCTAssertTrue(old.waitForExistence(timeout: 8), "the archived chat is listed")
        XCTAssertTrue(waitUntil(6) { self.labelOf(old).contains("Unread") }, "it is unread (\(labelOf(old)))")
        shot(app, "archived-unread-before-\(look)")
        let before = unreadWrites().count
        swipe(old, left: false)
        XCTAssertTrue(app.buttons["Mark as Read"].waitForExistence(timeout: 3))
        app.buttons["Mark as Read"].tap()
        XCTAssertTrue(waitUntil(3) { !self.labelOf(old).contains("Unread") }, "the dot goes with the tap (\(labelOf(old)))")
        XCTAssertTrue(waitUntil(6) { self.unreadWrites().count == before + 1 })
        XCTAssertEqual(unreadWrites().last?.path, "/api/sessions/s-old")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(labelOf(old).contains("Unread"), "and stays gone (\(labelOf(old)))")
        shot(app, "archived-unread-after-\(look)")
    }
}
