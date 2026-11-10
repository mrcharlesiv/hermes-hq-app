import XCTest

// 2026-10-30 (owner: the "‹ 2" Back had "too much padding inside it"): a chat's Back with the unread count is fitted to
// the chevron and the count, and still goes back by a tap and by the edge swipe.
extension SessionsTests {
    @MainActor func test90_BackWithACountIsFitted() throws {
        setRow("s-trip", ["unread": true])                              // with s-budget: two other chats unread
        let app = launch()
        openChat(app, "s-garden")
        let back = app.navigationBars.buttons["BackButton"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 6))
        XCTAssertTrue(waitUntil(6) { back.label.contains("2") }, "the count: \(back.label)")
        shot(app, "back-count")
        XCTAssertLessThan(back.frame.width, 66, "fitted (the system's was 82 pt): \(back.frame)")
        back.tap()
        XCTAssertTrue(app.collectionViews["sessions.list"].waitForExistence(timeout: 8), "a tap goes back")
        Thread.sleep(forTimeInterval: 0.6)
        openChat(app, "s-garden")
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        XCTAssertTrue(waitUntil(8) { app.collectionViews["sessions.list"].isHittable }, "the edge swipe goes back")
    }
}
