// [working-ledger] "The session is running and adding a skill from the marketplace but it isn't showing as running in
// the session list" (a tester, 2026-11-09): a turn another process runs (the add-on's sessions/working names it) says
// Working… on its Sessions row without the chat being opened, still does after the chat is opened and left, and stops
// when the gateway no longer names it.

import XCTest

extension SessionsTests {
    @MainActor func test103_ATurnRunElsewhereSaysWorkingOnItsRow() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-trip").waitForExistence(timeout: 15))
        XCTAssertFalse(labelOf(row(app, "s-trip")).contains("Working"), labelOf(row(app, "s-trip")))
        shot(app, "ledger-1-idle")

        fixture("/__fixture/mode", ["working": ["s-trip"]])
        XCTAssertTrue(waitUntil(12) { self.labelOf(self.row(app, "s-trip")).contains("Working") },
                      "the gateway's turn shows without opening the chat (\(labelOf(row(app, "s-trip"))))")
        shot(app, "ledger-2-working")

        openChat(app, "s-trip")
        Thread.sleep(forTimeInterval: 1.5)
        backToList(app)
        XCTAssertTrue(waitUntil(8) { self.labelOf(self.row(app, "s-trip")).contains("Working") },
                      "still Working… after the chat was opened and left (\(labelOf(row(app, "s-trip"))))")

        fixture("/__fixture/mode", ["working": NSNull()])
        XCTAssertTrue(waitUntil(12) { !self.labelOf(self.row(app, "s-trip")).contains("Working") },
                      "it ends when the gateway's turn does (\(labelOf(row(app, "s-trip"))))")
        shot(app, "ledger-3-done")
    }
}
