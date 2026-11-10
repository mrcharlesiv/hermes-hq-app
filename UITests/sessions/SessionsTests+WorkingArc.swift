// The desktop's running arc on a working chat (App/Kit/WorkingArc.swift): round the whole row in both looks, on
// Sessions and Bots; it moves (two looks at the row differ) and ends with the turn.

import XCTest

extension SessionsTests {
    @MainActor private func runTrip(_ app: XCUIApplication) {
        XCTAssertTrue(row(app, "s-trip").waitForExistence(timeout: 15))
        openChat(app, "s-trip")
        type(app, "Add a fourth hotel", send: true)
        XCTAssertTrue(app.buttons["composer.stop"].waitForExistence(timeout: 8), "the turn runs")
        backToList(app)
        XCTAssertTrue(waitUntil(8) { self.labelOf(self.row(app, "s-trip")).contains("Working") }, labelOf(row(app, "s-trip")))
    }

    /// Two looks at the row a third of a lap apart differ: the arc travels.
    @MainActor private func assertMoves(_ element: XCUIElement, _ what: String) {
        let first = element.screenshot().pngRepresentation
        Thread.sleep(forTimeInterval: 0.7)
        XCTAssertNotEqual(first, element.screenshot().pngRepresentation, "\(what): the arc moves")
    }

    @MainActor private func arcRound(_ app: XCUIApplication, _ name: String) {
        runTrip(app)
        assertMoves(row(app, "s-trip"), "\(name) session row")
        shot(app, "arc-\(name)-sessions")
        for step in 1...3 {                     // a third of a lap apart: the lit arcs travel round the row
            Thread.sleep(forTimeInterval: 0.25)
            if let dir = ProcessInfo.processInfo.environment["HQN_SHOTS_DIR"], !dir.isEmpty {
                try? row(app, "s-trip").screenshot().pngRepresentation
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("arc-\(name)-lap\(step).png"))
            }
        }
        app.buttons["Bots"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.2)
        shot(app, "arc-\(name)-bots")
        app.buttons["Sessions"].firstMatch.tap()
        fixture("/__fixture/emit", ["type": "message.complete", "session_id": "s-trip", "payload": ["text": "Added the Ribeira Inn."]])
        XCTAssertTrue(waitUntil(8) { !self.labelOf(self.row(app, "s-trip")).contains("Working") })
        Thread.sleep(forTimeInterval: 0.5)
        shot(app, "arc-\(name)-done")
    }

    @MainActor func test23_WorkingArcInTheIOSLook() throws {
        fixture("/__fixture/mode", ["prompts": "hold"])
        arcRound(launch(), "ios")
    }

    @MainActor func test24_WorkingArcInTheDesktopLook() throws {
        fixture("/__fixture/mode", ["prompts": "hold"])
        arcRound(launch(extra: ["-HQDebugDesktopLook", "YES"]), "desktop")
    }

    /// The iOS look: a working row between two others wears a rounded ring with no hairline touching it, on Sessions
    /// and on Bots (owner, build 328: the ring sat on the rule beneath it), at the default size and at XL text.
    @MainActor private func clearOfHairlines(_ name: String, extra: [String] = []) {
        fixture("/__fixture/mode", ["prompts": "hold"])
        for id in ["s-garden", "s-trip", "s-budget"] {
            fixture("/__fixture/rows", ["id": id, "set": ["pinned": true], "event": true])
        }
        let app = launch(extra: extra)
        runTrip(app)
        Thread.sleep(forTimeInterval: 0.6)
        shot(app, "arc-\(name)-between")
        app.buttons["Bots"].firstMatch.tap()
        let bot = app.cells["bot-row-research"]
        XCTAssertTrue(bot.waitForExistence(timeout: 10), "the Research row")
        bot.tap()
        type(app, "Anything new?", send: true)
        XCTAssertTrue(app.buttons["composer.stop"].waitForExistence(timeout: 8), "the bot's turn runs")
        if app.keyboards.count > 0 { app.tables["chat.table"].tap(); Thread.sleep(forTimeInterval: 0.4) }
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.2)
        shot(app, "arc-\(name)-bots-between")
    }

    @MainActor func test26_WorkingArcClearOfHairlines() throws { clearOfHairlines("hairlines") }

    @MainActor func test27_WorkingArcClearOfHairlinesXL() throws {
        clearOfHairlines("hairlines-xl", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"])
    }

    /// Reduce Motion: the ring holds still at its start, as the desktop's `animation: none` leaves it.
    @MainActor func test25_WorkingArcStillUnderReduceMotion() throws {
        fixture("/__fixture/mode", ["prompts": "hold"])
        let app = launch(extra: ["-HQA11yReduceMotion", "YES"])
        runTrip(app)
        Thread.sleep(forTimeInterval: 0.5)
        shot(app, "arc-reduced-sessions")
    }
}
