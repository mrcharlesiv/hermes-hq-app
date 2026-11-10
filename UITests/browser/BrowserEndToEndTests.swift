// Watch Browser end to end against the browser fixture (scripts/e2e-browser.sh starts scripts/fixtures/browser-gateway.py
// and passes TEST_RUNNER_HQN_UI_CREDENTIALS + TEST_RUNNER_HQN_UI_BROWSER=1; without them every test here skips).
// The fixture's page: username box at y 30–38 %, password box at 42–50 %, x 30–70 %. All values are invented.

import XCTest

final class BrowserEndToEndTests: XCTestCase {
    var account: FixtureAccount!
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["HQN_UI_BROWSER"] == "1" else {
            throw XCTSkip("Run with scripts/e2e-browser.sh (the browser fixture).")
        }
        account = try FixtureAccount.load()
        try account.control("/__fixture/browser/reset", [:])
    }

    // MARK: 1. Card → viewer → frames → take over → type (username, password) → copy → give back → close

    @MainActor func test1_CardViewerTakeOverTypeGiveBackClose() throws {
        try account.control("/__fixture/browser", ["active": true])
        launch()
        openChat()
        let chip = app.buttons["chat.shelf.browser"]
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "the browser card shows while the bot browses")
        XCTAssertTrue(chip.label.contains("Browsing example.test"), "the card says where: \(chip.label)")
        attach("chat-browser-card")
        chip.tap()

        let stage = app.descendants(matching: .any)["browser.stage"]
        XCTAssertTrue(stage.waitForExistence(timeout: 10), "the viewer opens")
        XCTAssertTrue(waitUntil(timeout: 15) { self.framesShown() >= 45 }, "frames are drawn (\(self.stageValue()))")
        let take = app.buttons["browser.take"]
        XCTAssertTrue(waitUntil(timeout: 10) { take.exists && take.isEnabled }, "Take Control is ready")
        XCTAssertEqual(app.textFields["browser.address"].value as? String, "example.test", "the address shows the site")
        attach("viewer-watching")
        let pacing = stageValue()
        let pacingNote = XCTAttachment(string: "viewer pacing (sim): \(pacing)")
        pacingNote.lifetime = .keepAlways
        add(pacingNote)
        XCTAssertTrue(pacing.contains("mainDecodes=0"), "no frame is decoded on the main thread: \(pacing)")
        if let p50 = number(after: "p50=", in: pacing) { XCTAssertLessThan(p50, 60, "frames keep coming at a steady pace: \(pacing)") }

        take.tap()
        let give = app.buttons["browser.give"]
        XCTAssertTrue(give.waitForExistence(timeout: 10), "the phone holds the browser")
        XCTAssertTrue(waitUntil(timeout: 5) { (try? self.state()["control"] as? String) == "person" })
        attach("viewer-holding")

        // The pointer starts in the middle of the page (y 50 %): up into the username box, then a tap clicks it and
        // raises the keyboard with the username field (AutoFill's sign-in slot).
        let pageHeight = stage.frame.width * 720 / 1280
        movePointer(on: stage, dy: -0.16 * pageHeight)
        stage.tap()
        let username = app.textFields["browser.keyboard.username"]
        XCTAssertTrue(waitUntil(timeout: 8) { self.hasFocus(username) }, "a tap on the page's username box raises the sign-in keyboard")
        XCTAssertTrue(waitUntil(timeout: 5) { (try? self.state()["focus"] as? String) == "username" })
        app.typeText("person@example.test")
        XCTAssertTrue(waitUntil(timeout: 8) { self.typed(in: "username") == "person@example.test" }, "the typing reached the page")
        attach("viewer-typing-username")

        // Down into the password box: the password slot (a secure field iOS offers password AutoFill on).
        movePointer(on: stage, dy: 0.12 * pageHeight)
        stage.tap()
        let password = app.secureTextFields["browser.keyboard.password"]
        XCTAssertTrue(waitUntil(timeout: 8) { self.hasFocus(password) }, "the password box gets the password field")
        app.typeText("fixture-pass-1")
        XCTAssertTrue(waitUntil(timeout: 8) { self.typed(in: "password") == "fixture-pass-1" }, "the password reached the page")
        app.typeText("\n")
        XCTAssertTrue(waitUntil(timeout: 5) { self.inputs().contains { $0["type"] as? String == "key" && $0["key"] as? String == "Enter" } },
                      "Return goes as Enter")
        attach("viewer-typing-password")

        // Copy and Paste menu › Copy: the page's selection comes back to the phone's clipboard.
        app.buttons["browser.keyboard"].tap()      // keyboard down first
        app.buttons["browser.clipboard"].tap()
        let copy = app.buttons["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "the clipboard menu opens")
        attach("viewer-clipboard-menu")
        copy.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.inputs().contains { $0["type"] as? String == "copy" } }, "Copy reached the page")
        XCTAssertTrue(app.descendants(matching: .any)["browser.notice"].waitForExistence(timeout: 5), "Copied shows")
        XCTAssertEqual(app.descendants(matching: .any)["browser.notice"].label, "Copied")

        give.tap()
        XCTAssertTrue(take.waitForExistence(timeout: 10), "Give Back hands the browser back")
        XCTAssertTrue(waitUntil(timeout: 5) { (try? self.state()["control"] as? String) == "bot" })

        app.buttons["browser.close"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !stage.exists }, "the viewer closes")
        XCTAssertTrue(app.tables["chat.table"].exists, "back in the chat")
        XCTAssertTrue(waitUntil(timeout: 10) { ((try? self.state()["viewers"] as? Int) ?? 1) == 0 }, "its socket closed")
    }

    // MARK: 2. The bot asks for the person; ⋯ › Watch Browser; closing while holding gives it back

    @MainActor func test2_AskCardMenuAndCloseWhileHolding() throws {
        try account.control("/__fixture/browser", ["active": true, "ask": "Sign in to Example with your account"])
        launch()
        openChat()
        let chip = app.buttons["chat.shelf.browser"]
        XCTAssertTrue(chip.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(timeout: 5) { chip.label.contains("needs you in its browser") }, "the card asks: \(chip.label)")
        attach("chat-browser-card-ask")
        app.buttons["chat.more"].firstMatch.tap()
        let item = app.buttons["Watch Browser"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "⋯ has Watch Browser")
        item.tap()
        XCTAssertTrue(app.otherElements["browser.ask"].waitForExistence(timeout: 10), "the viewer shows what the bot needs")
        let take = app.buttons["browser.take"]
        XCTAssertTrue(waitUntil(timeout: 15) { take.exists && take.isEnabled })
        attach("viewer-ask")
        take.tap()
        XCTAssertTrue(app.buttons["browser.give"].waitForExistence(timeout: 10))
        app.buttons["browser.close"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { (try? self.state()["control"] as? String) == "bot" }, "closing while holding gives it back")
    }

    // MARK: 6. Boxes the page opened (Chrome draws them outside the page): told while watching, answered while holding

    @MainActor func test6_PageBoxesReachThePhone() throws {
        try account.control("/__fixture/browser", ["active": true])
        launch()
        openChat()
        let chip = app.buttons["chat.shelf.browser"]
        XCTAssertTrue(chip.waitForExistence(timeout: 15))
        chip.tap()
        let take = app.buttons["browser.take"]
        XCTAssertTrue(waitUntil(timeout: 15) { take.exists && take.isEnabled }, "Take Control is ready")

        // Watching: the phone says the page has a box open.
        try account.control("/__fixture/browser", ["dialog": ["id": 1, "kind": "confirm", "site": "example.test",
                                                              "message": "Leave without saving?"]])
        let notice = app.descendants(matching: .any)["browser.notice"]
        XCTAssertTrue(waitUntil(timeout: 8) { notice.exists && notice.label.contains("example.test is showing a message") },
                      "watching, the phone says a box is open")
        XCTAssertFalse(app.alerts.firstMatch.exists, "only the person holding the browser answers it")
        attach("viewer-box-watching")

        // Holding: an iPhone alert with the page's words; Cancel goes back to the page.
        take.tap()
        XCTAssertTrue(app.buttons["browser.give"].waitForExistence(timeout: 10))
        let confirm = app.alerts["example.test says"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 8), "the box shows as an alert")
        XCTAssertTrue(confirm.staticTexts["Leave without saving?"].exists)
        attach("viewer-box-confirm")
        confirm.buttons["Cancel"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.answers().contains { $0["id"] as? Int == 1 && $0["accept"] as? Bool == false } },
                      "Cancel reached the page")
        XCTAssertTrue(waitUntil(timeout: 5) { !confirm.exists })

        // A "Sign in with…" account chooser: each account is a button.
        try account.control("/__fixture/browser", ["dialog": ["id": 2, "kind": "accounts", "title": "Sign in to example.test with idp.example",
                                                              "accounts": [["name": "Pat Example", "email": "pat@example.test"],
                                                                           ["name": "Pat Work", "email": "work@example.test"]]]])
        let chooser = app.alerts["Sign in to example.test with idp.example"]
        XCTAssertTrue(chooser.waitForExistence(timeout: 8), "the account chooser shows")
        attach("viewer-box-accounts")
        chooser.buttons["work@example.test"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.answers().contains { $0["id"] as? Int == 2 && $0["account"] as? Int == 1 } },
                      "the account picked reached the page")

        // A prompt: its text field starts with the page's default; what the person types goes back.
        try account.control("/__fixture/browser", ["dialog": ["id": 3, "kind": "prompt", "site": "example.test",
                                                              "message": "Your name?", "default": "def"]])
        let prompt = app.alerts["example.test says"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 8), "the prompt shows")
        let field = prompt.textFields.firstMatch
        XCTAssertEqual(field.value as? String, "def")
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "zed")
        attach("viewer-box-prompt")
        // The keyboard may still be sliding up (the alert moves with it): a tap mid-animation lands where OK was.
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        prompt.buttons["OK"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.answers().contains { $0["id"] as? Int == 3 && $0["text"] as? String == "zed" } },
                      "the prompt's text reached the page: \(self.answers())")

        app.buttons["browser.give"].tap()
        XCTAssertTrue(take.waitForExistence(timeout: 10))
    }

    // MARK: 3. Bot Info › Browser: a copy of a Chrome profile, the normal window; hidden on an older plugin

    @MainActor func test3_BotInfoBrowserChoice() throws {
        launch()
        openBotInfo()
        let row = app.buttons["bot-info.browser.choice"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Bot Info offers the browser choice")
        attach("bot-info-browser")
        row.tap()
        let work = app.buttons["browser.choice.profile.Profile 2"]
        XCTAssertTrue(work.waitForExistence(timeout: 10), "the person's Chrome profiles are listed")
        attach("browser-choice")
        work.tap()
        let use = app.alerts.buttons["Use a Copy"]
        XCTAssertTrue(use.waitForExistence(timeout: 5), "a copy is confirmed first (it signs the bot in as you)")
        attach("browser-choice-confirm")
        use.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { (try? self.state()["choice"] as? [String: Any])?["mode"] as? String == "copy" })
        XCTAssertTrue(app.buttons["browser.choice.refresh"].waitForExistence(timeout: 10), "Refresh Sign-ins shows for a copy")
        let window = app.switches["browser.choice.window"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        window.switches.firstMatch.exists ? window.switches.firstMatch.tap() : window.tap()
        // A bot using its browser right now: the restart is confirmed first.
        let restart = app.alerts.buttons["Restart"]
        if restart.waitForExistence(timeout: 2) { restart.tap() }
        XCTAssertTrue(waitUntil(timeout: 10) { (try? self.state()["choice"] as? [String: Any])?["window"] as? String == "normal" })
        attach("browser-choice-copy-normal")
        app.buttons["browser.choice.own"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { (try? self.state()["choice"] as? [String: Any])?["mode"] as? String == "own" })

        // An older plugin: no choice row.
        try account.control("/__fixture/browser", ["choice_feature": false])
        app.terminate()
        launch()
        openBotInfo()
        XCTAssertTrue(app.buttons["bot-info.browser.watch"].waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertFalse(app.buttons["bot-info.browser.choice"].exists, "an older plugin hides the choice")
    }

    // MARK: 4. No plugin: the viewer says how to get it

    @MainActor func test4_NoPluginExplains() throws {
        try account.control("/__fixture/browser", ["plugin": "missing"])
        launch()
        openChat()
        app.buttons["chat.more"].firstMatch.tap()
        app.buttons["Watch Browser"].tap()
        XCTAssertTrue(app.staticTexts["Watch Your Bots Browse"].waitForExistence(timeout: 10), "the setup state shows")
        XCTAssertTrue(app.buttons["browser.empty.action"].exists, "with Ask Hermes to Install It")
        attach("viewer-no-plugin")
        app.buttons["browser.close"].tap()
    }

    /// [setup-browser] On Hermes Cloud (the fixture passes for one) the bots browse in Browser Use's cloud: the missing
    /// add-on is explained, with nothing to install.
    @MainActor func test4b_CloudGatewayExplains() throws {
        try account.control("/__fixture/browser", ["plugin": "missing"])
        launch(extra: ["-HQDebugCloudHost", "YES"])
        openChat()
        app.buttons["chat.more"].firstMatch.tap()
        app.buttons["Watch Browser"].tap()
        XCTAssertTrue(app.staticTexts["Bots Browse in the Cloud Here"].waitForExistence(timeout: 10), "the cloud state shows")
        XCTAssertFalse(app.buttons["browser.empty.action"].exists, "nothing to install")
        attach("viewer-cloud-gateway")
        app.buttons["browser.close"].tap()
    }

    // MARK: 5. A bot whose browser the plugin doesn't run: why, take over (real profile) → rows enable → a copy;
    //         a bot that doesn't use a browser: why, and no button

    @MainActor func test5_BlockedBrowserTakeOver() throws {
        try account.control("/__fixture/browser", ["blocked": ["ivy": "real_profile"]])
        launch()
        openBotInfo(bot: "ivy")
        let row = app.buttons["bot-info.browser.choice"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Bot Info offers the browser page")
        attach("blocked-bot-info")
        row.tap()
        let why = app.descendants(matching: .any)["browser.choice.blocked"]
        XCTAssertTrue(why.waitForExistence(timeout: 10), "the page says why it can't change the browser")
        XCTAssertTrue(why.label.contains("real Chrome profile"), "real_profile is explained: \(why.label)")
        let work = app.buttons["browser.choice.profile.Profile 2"]
        XCTAssertTrue(work.waitForExistence(timeout: 10))
        XCTAssertFalse(work.isEnabled, "the profile rows are off until Hermes HQ runs the browser")
        let takeOver = app.buttons["browser.choice.takeOver"]
        XCTAssertTrue(takeOver.exists, "the take-over button shows")
        XCTAssertTrue(takeOver.label.contains("Let Hermes HQ Run"), takeOver.label)
        attach("blocked-real-profile")
        takeOver.tap()
        let confirm = app.alerts.buttons["Let Hermes HQ Run It"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "taking over is confirmed first")
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "use real Chrome profile")).firstMatch.exists,
                      "the alert says what changes")
        attach("blocked-take-over-confirm")
        confirm.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { ((try? self.state()["take_overs"] as? [String]) ?? []).contains("ivy") })
        XCTAssertTrue(waitUntil(timeout: 10) { !why.exists && work.isEnabled }, "the explanation goes and the rows enable")
        attach("blocked-taken-over")
        work.tap()
        let use = app.alerts.buttons["Use a Copy"]
        XCTAssertTrue(use.waitForExistence(timeout: 5))
        use.tap()
        XCTAssertTrue(waitUntil(timeout: 10) {
            (((try? self.state()["choices"] as? [String: Any])?["ivy"] as? [String: Any])?["mode"] as? String) == "copy"
        }, "a copy works after the take-over")
        XCTAssertTrue(app.buttons["browser.choice.refresh"].waitForExistence(timeout: 10))
        attach("blocked-then-copy")

        // A bot that doesn't use a browser: why, and never a take-over button.
        try account.control("/__fixture/browser", ["blocked": ["ivy": "no_browser"]])
        app.terminate()
        launch()
        openBotInfo(bot: "ivy")
        app.buttons["bot-info.browser.choice"].tap()
        XCTAssertTrue(why.waitForExistence(timeout: 10))
        XCTAssertTrue(why.label.contains("doesn’t use a browser"), why.label)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(app.buttons["browser.choice.takeOver"].exists, "a bot whose browser is deliberately off is never offered")
        attach("blocked-no-browser")
    }

    /// An add-on older than 3.7 can't send the page's popups: taking control offers, once, to have Hermes update it.
    @MainActor func test7_OldAddOnOffersThePopupsUpdate() throws {
        try account.control("/__fixture/browser", ["active": true, "dialogs_feature": false])
        launch()
        openChat()
        let chip = app.buttons["chat.shelf.browser"]
        XCTAssertTrue(chip.waitForExistence(timeout: 15))
        chip.tap()
        let take = app.buttons["browser.take"]
        XCTAssertTrue(waitUntil(timeout: 15) { take.exists && take.isEnabled }, "Take Control is ready")
        XCTAssertFalse(app.alerts.firstMatch.exists, "watching says nothing about the add-on")

        take.tap()
        let offer = app.alerts["Update the Browser Add-on?"]
        XCTAssertTrue(offer.waitForExistence(timeout: 8), "taking control with a 3.6 add-on offers the update")
        XCTAssertTrue(offer.buttons["Ask Hermes to Update It"].exists)
        attach("viewer-popups-update-offer")
        offer.buttons["Not Now"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !offer.exists })

        // Offered once: giving back and taking again says nothing more.
        let give = app.buttons["browser.give"]
        XCTAssertTrue(give.waitForExistence(timeout: 10))
        give.tap()
        XCTAssertTrue(waitUntil(timeout: 15) { take.exists && take.isEnabled })
        take.tap()
        XCTAssertTrue(give.waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertFalse(app.alerts["Update the Browser Add-on?"].exists, "the offer comes once")
    }

    /// With a 3.7 add-on there is nothing to offer.
    @MainActor func test8_CurrentAddOnOffersNothing() throws {
        try account.control("/__fixture/browser", ["active": true])
        launch()
        openChat()
        let chip = app.buttons["chat.shelf.browser"]
        XCTAssertTrue(chip.waitForExistence(timeout: 15))
        chip.tap()
        let take = app.buttons["browser.take"]
        XCTAssertTrue(waitUntil(timeout: 15) { take.exists && take.isEnabled })
        take.tap()
        XCTAssertTrue(app.buttons["browser.give"].waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertFalse(app.alerts["Update the Browser Add-on?"].exists)
    }

    // MARK: Helpers

    @MainActor private func launch(extra: [String] = []) {
        let app = XCUIApplication()
        app.launchArguments = ["-HQDebugResetAccounts", "YES"] + extra
        app.launchEnvironment = ["HQN_SIGNIN_URL": account.url, "HQN_SIGNIN_USERNAME": account.username,
                                 "HQN_SIGNIN_PASSWORD": account.password]
        app.launch()
        self.app = app
        XCTAssertTrue(app.cells["bot-row-default"].waitForExistence(timeout: 20), "signed in: the Bots list shows")
    }

    @MainActor private func openChat() {
        app.cells["bot-row-default"].tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 10), "the chat opens")
    }

    @MainActor private func openBotInfo(bot: String = "default") {
        let cell = app.cells["bot-row-\(bot)"]
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "the bot's row shows")
        cell.press(forDuration: 1.0)
        let info = app.buttons["Bot Info"]
        XCTAssertTrue(info.waitForExistence(timeout: 5), "the row menu opens")
        info.tap()
        XCTAssertTrue(app.collectionViews["bot-info.list"].waitForExistence(timeout: 5) || app.otherElements["bot-info.list"].waitForExistence(timeout: 1))
        let list = app.collectionViews["bot-info.list"]
        for _ in 0..<4 where !app.buttons["bot-info.browser.watch"].isHittable { list.swipeUp() }
        // [ship, m9] The Computer group begins with the Screen row now, so its lower rows (Profile and Window) can sit
        // under the edge with Watch Browser already in reach: bring the group's last row, the switch, into view.
        let last = app.switches["bot-info.computer.alert"]
        for _ in 0..<3 where !(last.exists && last.isHittable) {
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        }
    }

    /// One finger drags the pointer by `dy` points (no hold: a hold would press the mouse).
    @MainActor private func movePointer(on stage: XCUIElement, dy: CGFloat) {
        let start = stage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: dy))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.05)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))   // the move and the page's field state come back
    }

    @MainActor private func hasFocus(_ element: XCUIElement) -> Bool {
        element.exists && ((element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false)
    }

    @MainActor private func stageValue() -> String { (app.descendants(matching: .any)["browser.stage"].value as? String) ?? "" }

    @MainActor private func framesShown() -> Int { number(after: "frames=", in: stageValue()).map { Int($0) } ?? 0 }

    private func number(after key: String, in text: String) -> Double? {
        guard let range = text.range(of: key) else { return nil }
        return Double(text[range.upperBound...].prefix { $0.isNumber || $0 == "." })
    }

    private func state() throws -> [String: Any] { try account.control("/__fixture/browser") }

    private func inputs() -> [[String: Any]] { ((try? state())?["inputs"] as? [[String: Any]]) ?? [] }

    private func answers() -> [[String: Any]] { inputs().filter { $0["type"] as? String == "answer" } }

    /// Every `text` the page got while its `field` had the focus, joined.
    private func typed(in field: String) -> String {
        inputs().filter { $0["type"] as? String == "text" && $0["field"] as? String == field }.compactMap { $0["text"] as? String }.joined()
    }

    @MainActor private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor @discardableResult
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}
