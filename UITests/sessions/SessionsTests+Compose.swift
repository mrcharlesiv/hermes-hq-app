// Owner report (build 257, real iPhone): the Sessions tab's Compose button shows Choose a Bot, but picking a bot opened
// nothing. These tests do what the owner did, with a finger (a coordinate tap, not an accessibility activation).

import XCTest

extension SessionsTests {
    @MainActor private func fingerTap(_ app: XCUIApplication, _ element: XCUIElement) {
        let frame = element.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
    }

    @MainActor private func composeWithAFinger(_ app: XCUIApplication, bot: String) {
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        app.buttons["sessions.compose"].tap()
        let pill = app.buttons["new-chat-bot-\(bot)"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "New Chat")
        fingerTap(app, pill)
        XCTAssertTrue(waitUntil(3) { pill.isSelected }, "the pill lights")
        fingerTap(app, app.buttons["new-chat-project-none"])
        XCTAssertTrue(waitUntil(8) { self.rpc("session.create").contains { $0["profile"] as? String == bot } }, "session.create in \(bot)")
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 10), "the new chat opens")
        XCTAssertFalse(app.buttons["new-chat-bot-\(bot)"].exists, "the sheet is gone")
    }

    @MainActor func testC1_ComposePickedWithAFingerOpensTheChat() throws {
        composeWithAFinger(launch(), bot: "research")
    }

    @MainActor func testC2_ComposePickedWithAFingerOpensTheChatInDesktopLook() throws {
        composeWithAFinger(launch(extra: ["-HQDebugDesktopLook", "YES"]), bot: "deploys")
    }

    /// Compose under All: a bot's pill, then a project's row; the chat starts in that project's folder. The next time
    /// the sheet opens that bot is lit and the project carries "Last used".
    @MainActor func testC3_ComposeInAProject() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(10) { self.rpc("projects.tree").contains { $0["profile"] as? String == "default" } }, "projects read with the list")
        app.buttons["sessions.compose"].tap()
        let website = app.buttons["new-chat-project-Website"]
        XCTAssertTrue(website.waitForExistence(timeout: 5), "the projects, as rows")
        XCTAssertTrue(app.buttons["new-chat-project-none"].exists && app.buttons["new-chat-project-new"].exists, "No Project and New Project…")
        XCTAssertFalse(website.label.contains("Last used"), "nothing used yet")
        shot(app, "compose-project-choice")
        app.buttons["new-chat-bot-research"].tap()
        website.tap()
        XCTAssertTrue(waitUntil(8) {
            self.rpc("projects.create").contains { $0["profile"] as? String == "research" && $0["name"] as? String == "Website" }
        }, "Research is given Website (\(rpc("projects.create")))")
        XCTAssertTrue(waitUntil(8) {
            self.rpc("session.create").contains { $0["cwd"] as? String == "/home/hermes/site" && $0["profile"] as? String == "research" }
        }, "session.create in Website's folder (\(rpc("session.create")))")
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 10), "the new chat opens")
        backToList(app)
        app.buttons["sessions.compose"].tap()
        XCTAssertTrue(app.buttons["new-chat-bot-research"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["new-chat-bot-research"].isSelected, "the bot used last is lit")
        XCTAssertTrue(waitUntil(3) { app.buttons["new-chat-project-Website"].label.contains("Last used") }, "its project says Last used")
        shot(app, "compose-last-used")
    }

    /// New Project… is the sheet's last row: the New Project alert for the lit bot.
    @MainActor func testC3b_NewProjectFromTheSheet() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        app.buttons["sessions.compose"].tap()
        let new = app.buttons["new-chat-project-new"]
        XCTAssertTrue(new.waitForExistence(timeout: 5), "New Project… in the sheet")
        new.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 6), "the New Project alert")
        shot(app, "compose-new-project-alert")
    }

    /// Tester 2026-11-10: with a bot's pill picked, Compose opens the same sheet with that bot lit; a
    /// project's row starts the chat there.
    @MainActor func testC3c_ComposeWithAPillAsksForTheProject() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(10) { self.rpc("projects.tree").contains { $0["profile"] as? String == "default" } }, "projects read with the list")
        chip(app, "research").tap()
        app.buttons["sessions.compose"].tap()
        let pill = app.buttons["new-chat-bot-research"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "New Chat")
        XCTAssertTrue(pill.isSelected, "the picked bot is lit")
        XCTAssertTrue(app.buttons["new-chat-bot-deploys"].exists, "the other bots are one tap away")
        shot(app, "compose-with-pill")
        app.buttons["new-chat-project-Website"].tap()
        XCTAssertTrue(waitUntil(8) {
            self.rpc("session.create").contains { $0["cwd"] as? String == "/home/hermes/site" && $0["profile"] as? String == "research" }
        }, "session.create in Website's folder (\(rpc("session.create")))")
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 10), "the new chat opens")
    }

    /// Settings › Chat › New Chat Asks for a Project off: a picked pill's New Chat starts in no project at once.
    @MainActor func testC3d_ComposeWithAPillAndTheSwitchOffStartsAtOnce() throws {
        let app = launch(extra: ["-hqn.newChatAsksProject", "NO"])
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        chip(app, "research").tap()
        app.buttons["sessions.compose"].tap()
        XCTAssertTrue(waitUntil(8) { self.rpc("session.create").contains { $0["profile"] as? String == "research" } },
                      "a new Research chat, straight away")
        XCTAssertFalse(app.buttons["new-chat-bot-research"].exists, "no sheet")
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 8), "the new chat opens")
    }

    /// The empty page of a bot with no chats: its New Chat opens the same sheet, that bot lit.
    @MainActor func testC3e_EmptyBotPageOpensTheSheet() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        setRow("s-release", ["archived": true], event: true)
        XCTAssertTrue(waitUntil(15) { !self.row(app, "s-release").exists })
        chip(app, "deploys").tap()
        let new = app.buttons["sessions.empty.compose"]
        XCTAssertTrue(new.waitForExistence(timeout: 5), "New Chat on the page")
        shot(app, "empty-bot")
        new.tap()
        XCTAssertTrue(app.buttons["new-chat-bot-deploys"].waitForExistence(timeout: 5), "the New Chat sheet")
        XCTAssertTrue(app.buttons["new-chat-bot-deploys"].isSelected, "Deploys is lit")
        XCTAssertTrue(app.buttons["new-chat-project-new"].exists, "New Project… is in it")
        shot(app, "empty-bot-sheet")
    }
}

extension SessionsTests {
    /// Owner report (2026-10-26, iPhone): Compose's sheet sat flush with the bottom of the screen, its bottom corners
    /// cut off by the screen's (the Desktop Look's 8 pt sheet radius, not concentric with them). Opens the sheet in both
    /// looks, with a few bots and with many, at its medium height and swiped up. HQN_SHOT_HOLD (seconds) holds each
    /// state so a masked `simctl io screenshot` can be taken; ThemeChromeSheetTests checks the radius itself.
    @MainActor func testC4_ComposeSheetClearsTheBottomEdge() throws {
        for (look, extra, count) in [("plain", [String](), 3), ("desktop", ["-HQDebugDesktopLook", "YES"], 3),
                                     ("plain-12", [], 12), ("desktop-12", ["-HQDebugDesktopLook", "YES"], 12)] {
            fixture("/__fixture/mode", ["bots": count])
            let app = launch(extra: extra)
            XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
            app.buttons["sessions.compose"].tap()
            let bots = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'new-chat-bot-'"))
            XCTAssertTrue(bots.firstMatch.waitForExistence(timeout: 5), "New Chat")
            Thread.sleep(forTimeInterval: 0.8)
            shot(app, "compose-sheet-\(look)")
            Thread.sleep(forTimeInterval: Double(ProcessInfo.processInfo.environment["HQN_SHOT_HOLD"] ?? "") ?? 0)
            app.collectionViews.firstMatch.swipeUp()
            app.collectionViews.firstMatch.swipeUp()
            Thread.sleep(forTimeInterval: 0.8)
            shot(app, "compose-sheet-\(look)-scrolled")
            Thread.sleep(forTimeInterval: Double(ProcessInfo.processInfo.environment["HQN_SHOT_HOLD"] ?? "") ?? 0)
            app.terminate()
        }
    }
}

extension SessionsTests {
    /// Owner 2026-10-30: "a shortcut here to name the session". A new chat's intro offers Name Chat under Talk and Bot
    /// Info; it opens the Rename prompt with an empty field, the name goes out before anything is sent, and the
    /// shortcut leaves once the chat has a name.
    @MainActor func testC5_NameChatFromTheEmptyChat() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        chip(app, "research").tap()
        app.buttons["sessions.compose"].tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 8), "the new chat")
        let name = app.buttons["chat.intro.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 8), "an unnamed chat offers Name Chat")
        XCTAssertEqual(name.label, "Name Chat")
        XCTAssertGreaterThanOrEqual(name.frame.height, 44)
        let info = app.buttons["chat.intro.info"]
        if info.exists { XCTAssertGreaterThan(name.frame.minY, info.frame.maxY, "under the capsules") }
        shot(app, "C5-name-chat-intro")
        name.tap()
        let alert = app.alerts["Name Chat"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let field = alert.textFields["rename.field"]
        XCTAssertEqual(field.value as? String ?? "", field.placeholderValue ?? "", "the field opens empty, not \"New Chat\"")
        XCTAssertFalse(alert.buttons["Save"].isEnabled, "Save waits for a name")
        shot(app, "C5-name-chat-alert")
        field.typeText("Hiring plan")
        XCTAssertTrue(alert.buttons["Save"].isEnabled)
        alert.buttons["Save"].tap()
        XCTAssertTrue(waitUntil(5) { !alert.exists }, "the alert closed")
        XCTAssertTrue(waitUntil(5) { app.descendants(matching: .any)["chat.title"].label.contains("Hiring plan") }, "the bar shows it at once")
        XCTAssertTrue(waitUntil(8) { self.rpc("session.title").contains { $0["title"] as? String == "Hiring plan" } },
                      "session.title before the first message (\(rpc("session.title")))")
        XCTAssertTrue(waitUntil(5) { !name.exists }, "a named chat drops the shortcut")
        XCTAssertTrue(app.buttons["chat.intro.info"].exists || !info.exists, "the rest of the intro stays")
        shot(app, "C5-named")
    }

    /// The same shortcut in the Desktop Look (screenshots; every look is checked, not just the iOS one).
    @MainActor func testC5b_NameChatInDesktopLook() throws {
        let app = launch(extra: ["-HQDebugDesktopLook", "YES"])
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        chip(app, "research").tap()
        app.buttons["sessions.compose"].tap()
        let name = app.buttons["chat.intro.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "an unnamed chat offers Name Chat")
        XCTAssertGreaterThanOrEqual(name.frame.height, 44)
        shot(app, "C5b-name-chat-desktop")
        name.tap()
        XCTAssertTrue(app.alerts["Name Chat"].waitForExistence(timeout: 5))
        shot(app, "C5b-name-chat-alert-desktop")
        app.alerts["Name Chat"].buttons["Cancel"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5), "Cancel keeps it")
    }
}
