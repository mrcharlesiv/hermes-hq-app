// [tabretap] A second tap of the tab on show scrolls its page back to the top; tapping into another tab and back
// keeps the place it was left at (owner 2026-11-10).

import XCTest

extension SessionsTests {
    @MainActor func test95_SecondTabTapScrollsToTop() throws {
        for index in 0..<30 {
            setRow("s-fill-\(index)", ["profile": "default", "title": "Filler chat \(index)",
                                       "last_active": nowSeconds - Double(index) * 4000 - 9000])
        }
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        let list = app.collectionViews["sessions.list"]
        for _ in 0..<5 { list.swipeUp(velocity: .fast) }
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertFalse(row(app, "s-garden").isHittable, "the list is far from its top")
        shot(app, "TR1-scrolled")

        // Into Bots and back: Sessions is where it was left.
        app.tabButton(id: "tab-bots", label: "Bots").tap()
        Thread.sleep(forTimeInterval: 0.8)
        app.tabButton(id: "tab-sessions", label: "Sessions").tap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertFalse(row(app, "s-garden").isHittable, "switching tabs keeps the place")

        // The same tab again: back to the top.
        app.tabButton(id: "tab-sessions", label: "Sessions").tap()
        XCTAssertTrue(waitUntil(4) { self.row(app, "s-garden").isHittable }, "a second tap scrolls to the top")
        shot(app, "TR2-top")
    }
}
