// One tap copies code in a reply (App/Chat/Cells/ChatCells.swift `ChatTapCopy`), as Telegram copies its monospace
// spans: an address Hermes sends as inline code, and a whole code block. Built only in the app: the replies are plain
// Markdown from the stand-in gateway.

import XCTest

extension SessionsTests {
    @MainActor private func reply(_ app: XCUIApplication, _ prompt: String, _ text: String) -> XCUIElement {
        type(app, prompt, send: true)
        XCTAssertTrue(app.buttons["composer.stop"].waitForExistence(timeout: 8), "the turn runs")
        fixture("/__fixture/emit", ["type": "message.complete", "session_id": "s-trip", "payload": ["text": text]])
        let needle = text.replacingOccurrences(of: "`", with: "").components(separatedBy: "\n").first { !$0.isEmpty }!
        let bubble = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", needle)).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 8), "the reply shows")
        return bubble
    }

    @MainActor private func hud(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["menus.hud"] }

    @MainActor func test26_OneTapCopiesCodeInAReply() throws {
        fixture("/__fixture/mode", ["prompts": "hold"])
        let app = launch()
        XCTAssertTrue(row(app, "s-trip").waitForExistence(timeout: 15))
        openChat(app, "s-trip")

        let address = reply(app, "Where is the gateway?", "`https://example-mac-mini.tail1234.ts.net:10030`")
        address.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        XCTAssertTrue(hud(app).waitForExistence(timeout: 4), "one tap on the address copies it")
        XCTAssertEqual(hud(app).label, "Copied")
        shot(app, "tapcopy-inline")
        XCTAssertTrue(waitUntil(4) { !self.hud(app).exists }, "the HUD goes")

        let plain = reply(app, "Say hi", "Hello there, nothing to copy here.")
        plain.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(hud(app).exists, "a tap on plain words copies nothing")

        let block = reply(app, "How do I check it?", "```\nhermes gateway status --verbose\n```")
        block.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)).tap()
        XCTAssertTrue(hud(app).waitForExistence(timeout: 4), "one tap on a code block copies it")
        shot(app, "tapcopy-block")
    }
}
