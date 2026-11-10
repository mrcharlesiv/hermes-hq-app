// 3x-morepages §6 (U5): every bot hidden reads "All Bots Are Hidden" with a way back. Against the settings stand-in
// (it keeps the roster layout a hide writes): scripts/e2e-morepages.sh starts it as "settings".

import XCTest

final class HiddenBotsUITests: MorePagesCase {
    override class var gateway: String { "settings" }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try account.control("/__settings/reset", [:])
    }

    @MainActor private func visibleBot() -> XCUIElement? {
        let cells = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'bot-row-' OR identifier BEGINSWITH 'bot-tile-'"))
        return cells.count > 0 ? cells.element(boundBy: 0) : nil
    }

    @MainActor private func hide(_ cell: XCUIElement) {
        let item = app.buttons["Hide from Bots"].firstMatch
        for _ in 0..<3 {
            cell.press(forDuration: 1.0)
            if item.waitForExistence(timeout: 2) { break }
            let more = app.buttons["More"].firstMatch
            if more.waitForExistence(timeout: 2) { more.tap() }
            if item.waitForExistence(timeout: 3) { break }
        }
        XCTAssertTrue(item.exists, "the bot's menu has Hide from Bots")
        item.tap()
    }

    @MainActor func testU5_AllBotsHidden() throws {
        launchSignedIn(fresh: true)
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(15) { self.visibleBot() != nil }, "the roster loaded")
        let title = app.staticTexts["All Bots Are Hidden"]
        var hidden = 0
        while let cell = visibleBot(), hidden < 8 {
            XCTAssertFalse(title.exists, "a bot is still listed")
            let id = cell.identifier
            hide(cell)
            XCTAssertTrue(waitUntil(8) { !self.app.cells[id].exists }, "\(id) left the list")
            hidden += 1
        }
        XCTAssertGreaterThanOrEqual(hidden, 2, "the fixture's bots were hidden one by one")
        XCTAssertTrue(title.waitForExistence(timeout: 8), "every bot hidden reads so")
        XCTAssertTrue(app.staticTexts["Hidden bots keep working; they just aren’t listed."].exists)
        let show = app.buttons["Show Hidden Bots"]
        XCTAssertTrue(show.exists)
        XCTAssertFalse(app.cells["section-header-hidden"].exists, "the lone Hidden header is replaced by the empty state")
        // VoiceOver order: title, description, button.
        XCTAssertLessThan(title.frame.minY, app.staticTexts["Hidden bots keep working; they just aren’t listed."].frame.minY)
        XCTAssertLessThan(app.staticTexts["Hidden bots keep working; they just aren’t listed."].frame.minY, show.frame.minY)
        shot("bots-all-hidden")

        show.tap()
        XCTAssertTrue(waitUntil(8) { self.visibleBot() != nil }, "the hidden bots are listed under Hidden")
        XCTAssertFalse(title.exists)
        XCTAssertTrue(app.cells["section-header-hidden"].exists)
        shot("bots-hidden-shown")

        // Show one in Bots again: the normal list.
        let first = visibleBot()!
        let id = first.identifier
        first.press(forDuration: 1.0)
        let back = app.buttons["Show in Bots"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(waitUntil(8) { self.app.cells[id].exists || self.app.cells[id.replacingOccurrences(of: "bot-row-", with: "bot-tile-")].exists })
        // Fold Hidden again: a bot is listed, so no empty state.
        app.cells["section-header-hidden"].tap()
        XCTAssertFalse(title.waitForExistence(timeout: 2), "one bot is listed: the list, not the empty state")

        // A relaunch with every bot hidden opens on the state (Hidden starts folded).
        hide(app.cells[id].exists ? app.cells[id] : visibleBot()!)
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        relaunch()
        XCTAssertTrue(title.waitForExistence(timeout: 20), "the state survives a relaunch")
    }
}
