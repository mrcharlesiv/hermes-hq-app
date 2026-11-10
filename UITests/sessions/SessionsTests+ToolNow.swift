// [toolnow] A running chat's Sessions row names the step its turn is on ("Running npm test…"), not "Working…"
// (owner, 2026-10-30), in both looks; the reply writing brings "Working…" back and the turn's end the preview.

import XCTest

extension SessionsTests {
    @MainActor private func stepRound(_ app: XCUIApplication, _ name: String) {
        XCTAssertTrue(row(app, "s-trip").waitForExistence(timeout: 15))
        openChat(app, "s-trip")
        type(app, "Add a fourth hotel", send: true)
        XCTAssertTrue(app.buttons["composer.stop"].waitForExistence(timeout: 8), "the turn runs")
        backToList(app)
        XCTAssertTrue(waitUntil(8) { self.labelOf(self.row(app, "s-trip")).contains("Working") }, labelOf(row(app, "s-trip")))
        fixture("/__fixture/emit", ["type": "tool.start", "session_id": "s-trip",
                                    "payload": ["name": "web_search", "tool_id": "tn1", "args": ["query": "hotels in Porto"]]])
        XCTAssertTrue(waitUntil(6) { self.labelOf(self.row(app, "s-trip")).contains("Searching the web for hotels in Porto") },
                      labelOf(row(app, "s-trip")))
        fixture("/__fixture/emit", ["type": "tool.start", "session_id": "s-trip",
                                    "payload": ["name": "terminal", "tool_id": "tn2", "args": ["command": "cd ~/trip && npm test"]]])
        XCTAssertTrue(waitUntil(6) { self.labelOf(self.row(app, "s-trip")).contains("Running npm test") }, labelOf(row(app, "s-trip")))
        Thread.sleep(forTimeInterval: 0.4)
        shot(app, "toolnow-\(name)-sessions")
        fixture("/__fixture/emit", ["type": "message.delta", "session_id": "s-trip", "payload": ["text": "Added the Ribeira Inn."]])
        XCTAssertTrue(waitUntil(6) { let l = self.labelOf(self.row(app, "s-trip")); return l.contains("Working") && !l.contains("npm") },
                      labelOf(row(app, "s-trip")))
        fixture("/__fixture/emit", ["type": "message.complete", "session_id": "s-trip", "payload": ["text": "Added the Ribeira Inn."]])
        XCTAssertTrue(waitUntil(8) { !self.labelOf(self.row(app, "s-trip")).contains("Working") }, labelOf(row(app, "s-trip")))
    }

    @MainActor func test70_RowNamesTheRunningStep() throws {
        fixture("/__fixture/mode", ["prompts": "hold"])
        stepRound(launch(), "ios")
    }

    @MainActor func test71_RowNamesTheRunningStepInTheDesktopLook() throws {
        fixture("/__fixture/mode", ["prompts": "hold"])
        stepRound(launch(extra: ["-HQDebugDesktopLook", "YES"]), "desktop")
    }
}
