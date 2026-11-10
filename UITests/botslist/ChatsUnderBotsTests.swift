// [chats-under] Each bot's chats under its row, end to end against the Sessions fixture's everyday list
// (scripts/fixtures/sessions-gateway.py --seed everyday). Run with scripts/e2e-chats-under.sh <SIM>.

import XCTest

final class ChatsUnderBotsTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        guard env["HQN_CHATS_UNDER"] == "1" else { throw XCTSkip("Run scripts/e2e-chats-under.sh (the everyday Sessions fixture).") }
        continueAfterFailure = false
    }

    @MainActor private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HQDebugAppearance", env["HQN_SHOTS_DARK"] == "1" ? "dark" : "light"] + extra
        if let path = env["HQN_CHATS_CRED"], let data = FileManager.default.contents(atPath: path),
           let cred = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            app.launchEnvironment["HQN_SIGNIN_URL"] = cred["url"] as? String
            app.launchEnvironment["HQN_SIGNIN_USERNAME"] = cred["username"] as? String
            app.launchEnvironment["HQN_SIGNIN_PASSWORD"] = cred["password"] as? String
        }
        app.launch()
        let bots = app.buttons["tab-bots"]
        if bots.waitForExistence(timeout: 15) { bots.tap() }
        XCTAssertTrue(app.cells["bot-row-app"].waitForExistence(timeout: 20), "the Bots list shows")
        return app
    }

    @MainActor private func shot(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.8)
        let screenshot = app.screenshot()
        if let dir = env["HQN_SHOTS"], !dir.isEmpty {
            let mode = env["HQN_SHOTS_DARK"] == "1" ? "dark" : "light"
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(mode).png"))
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A menu item by its title (its label may carry its subtitle after a comma).
    @MainActor private func item(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")).firstMatch
    }

    @MainActor private func chats(_ app: XCUIApplication) -> XCUIElementQuery {
        app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'bot-chat-'"))
    }

    @MainActor private func openFilterSubmenu(_ app: XCUIApplication) {
        let filter = app.buttons["bots.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.tap()
        let entry = item(app, "Chats Under Bots")
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "Filter has Chats Under Bots")
        entry.tap()
        XCTAssertTrue(item(app, "Pinned Only").waitForExistence(timeout: 5), "its choices open")
    }

    @MainActor func testChatsUnderBots() throws {
        let app = launch()
        // Off is where everyone starts (the unit tests check the first launch; earlier runs leave a choice behind).
        openFilterSubmenu(app)
        item(app, "Off").tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.chats(app).count == 0 }, "Off: the page as it was")
        shot(app, "0-off")
        openFilterSubmenu(app)
        item(app, "Pinned + Recent").tap()
        XCTAssertTrue(app.cells["bot-chats-more-app"].waitForExistence(timeout: 10), "App's chats end with N more")
        XCTAssertTrue(chats(app).count > 0, "chats are listed under the bots")
        shot(app, "1-bots")

        // Filter › Chats Under Bots
        app.buttons["bots.filter"].tap()
        _ = item(app, "Chats Under Bots").waitForExistence(timeout: 5)
        shot(app, "2-filter-menu")
        XCTAssertTrue(item(app, "Chats Under Bots").exists, "Filter has Chats Under Bots")
        item(app, "Chats Under Bots").tap()
        XCTAssertTrue(item(app, "Pinned Only").waitForExistence(timeout: 5))
        shot(app, "3-chats-under-menu")
        item(app, "Pinned Only").tap()
        XCTAssertTrue(app.cells["bot-chat-e-01"].waitForExistence(timeout: 5), "Otto's pinned chat stays")
        XCTAssertFalse(app.cells["bot-chat-e-09"].exists, "its recent ones go")
        shot(app, "4-pinned-only")

        // Pinned + Recent, 3 each
        openFilterSubmenu(app)
        item(app, "3").tap()
        XCTAssertTrue(app.cells["bot-chat-e-11"].waitForExistence(timeout: 5), "App's third recent chat shows")
        shot(app, "5-three-recent")

        // Active: working, waiting for you, or unread
        openFilterSubmenu(app)
        item(app, "Active").tap()
        XCTAssertTrue(app.cells["bot-chat-e-00"].waitForExistence(timeout: 5), "App's unread chat shows")
        XCTAssertFalse(app.cells["bot-chat-e-01"].exists, "a read pinned chat doesn't")
        shot(app, "5b-active")

        // Off
        openFilterSubmenu(app)
        item(app, "Off").tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.chats(app).count == 0 }, "no chats under any bot")
        shot(app, "6-off")

        // Back to the standard: Pinned + Recent, 2
        openFilterSubmenu(app)
        item(app, "2").tap()
        XCTAssertTrue(app.cells["bot-chats-more-app"].waitForExistence(timeout: 5))

        // One bot's own choice: hold Otto › Chats Under Otto › Off
        let otto = app.cells["bot-row-otto"]
        if !otto.isHittable { app.swipeUp() }
        otto.press(forDuration: 1.0)
        let own = item(app, "Chats Under Otto")
        XCTAssertTrue(own.waitForExistence(timeout: 5), "the hold menu has Chats Under Otto")
        own.tap()
        XCTAssertTrue(item(app, "Same as All Bots").waitForExistence(timeout: 5))
        shot(app, "7-bot-menu")
        item(app, "Off").tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !app.cells["bot-chat-e-01"].exists }, "Otto lists no chats")
        XCTAssertTrue(app.cells["bot-chats-more-app"].exists, "App still does")
        otto.press(forDuration: 1.0)
        item(app, "Chats Under Otto").tap()
        item(app, "Same as All Bots").tap()
        XCTAssertTrue(app.cells["bot-chat-e-01"].waitForExistence(timeout: 5), "Otto follows all bots again")

        // Hold Otto › View Sessions
        otto.press(forDuration: 1.0)
        let view = item(app, "View Sessions")
        XCTAssertTrue(view.waitForExistence(timeout: 5), "the hold menu has View Sessions")
        view.tap()
        XCTAssertTrue(app.descendants(matching: .any)["sessions.chip.otto"].waitForExistence(timeout: 8), "Sessions opens on Otto")
        shot(app, "7b-view-sessions")
        app.buttons["tab-bots"].tap()

        // N more › Sessions with the bot picked
        app.swipeDown()
        let more = app.cells["bot-chats-more-app"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        let chip = app.descendants(matching: .any)["sessions.chip.app"]
        XCTAssertTrue(chip.waitForExistence(timeout: 8), "Sessions opens with the bots' chips")
        shot(app, "8-more-opens-sessions")
        XCTAssertTrue(chip.isSelected || (chip.value as? String)?.isEmpty == false, "App's chip is picked")

        // A chat opens from its row
        app.buttons["tab-bots"].tap()
        let row = app.cells["bot-chat-e-05"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 15), "the chat opens")
        shot(app, "9-chat-opens")
    }

    /// Settings › Appearance › Chats Under Bots: the style's page, a pick, and the Bots page drawn in it.
    @MainActor func testChatsUnderStyle() throws {
        let first = launch()
        openFilterSubmenu(first)
        item(first, "Pinned + Recent").tap()
        XCTAssertTrue(first.cells["bot-chats-more-app"].waitForExistence(timeout: 10))
        first.terminate()
        let again = launch(["-HQDebugOpenSettings", "YES"])
        again.buttons["tab-more"].tap()
        let row = again.buttons["settings.chats-under-row"]
        _ = row.waitForExistence(timeout: 8)
        for _ in 0..<8 where !(row.exists && row.isHittable) { again.swipeUp() }
        XCTAssertTrue(row.exists, "Appearance has Chats Under Bots")
        row.tap()
        let app = again
        let dots = app.buttons["chats-under.style.dots"]
        XCTAssertTrue(dots.waitForExistence(timeout: 5), "the page lists the styles")
        shot(app, "10-style-page")
        dots.tap()
        shot(app, "11-style-dots")
        app.buttons["tab-bots"].tap()
        app.buttons["tab-bots"].tap()
        XCTAssertTrue(app.cells["bot-chats-more-app"].waitForExistence(timeout: 8))
        shot(app, "12-bots-dots")
        // Back to the default for the next run.
        app.buttons["tab-more"].tap()
        if app.buttons["chats-under.style.branch"].waitForExistence(timeout: 5) { app.buttons["chats-under.style.branch"].tap() }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }
}
