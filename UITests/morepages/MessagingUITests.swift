// More › Messaging end to end (docs/spec/3x-morepages.md §12 acceptance 2-3, §21) against the morepages stand-in
// (scripts/fixtures/morepages/messaging.py, zz_restart_fallback.py).

import XCTest

/// What the Messaging and Webhooks tests share.
class IntegrationsCase: MorePagesCase {
    /// More › the row: at a large text size the row may not be laid out until the list is scrolled to it.
    @MainActor override func openMore(_ row: String, file: StaticString = #filePath, line: UInt = #line) {
        tab("More")
        let cell = app.cells["more-row-\(row)"]
        _ = cell.waitForExistence(timeout: 5)
        for _ in 0..<10 where !cell.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "More lists \(row)", file: file, line: line)
        reach(cell)
        cell.tap()
    }

    func knob(_ module: String, _ body: [String: Any]) throws { _ = try account.control("/__fixture/\(module)", body) }

    func writes(_ module: String) throws -> [[String: Any]] {
        ((try state()["writes"] as? [[String: Any]]) ?? []).filter { ($0["module"] as? String) == module }
    }

    func module(_ name: String) throws -> [String: Any] { (try state()[name] as? [String: Any]) ?? [:] }

    /// Every logged request under these prefixes that is not a GET.
    func nonReads(_ prefixes: [String]) throws -> [String] {
        try restLog().filter { row in
            let path = (row["path"] as? String) ?? ""
            return (row["method"] as? String) != "GET" && prefixes.contains { path.hasPrefix($0) }
        }.map { "\($0["method"] ?? "") \($0["path"] ?? "")" }
    }

    @MainActor func text(containing words: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    }

    /// Nothing on screen shows `secret`: no label, no value.
    @MainActor func assertNowhereOnScreen(_ secret: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let hits = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", secret, secret))
        XCTAssertEqual(hits.count, 0, "\(what) is nowhere on screen", file: file, line: line)
    }

    /// Flips a switch: a full-width row's switch is at its trailing edge.
    @MainActor func flip(_ element: XCUIElement) {
        let frame = element.frame
        if frame.width > 120 {
            element.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.width - 32, dy: frame.height / 2)).tap()
        } else {
            element.tap()
        }
    }

    @MainActor func isOn(_ element: XCUIElement) -> Bool { (element.value as? String) == "1" }

    /// Scrolls the page until `element` exists and can be tapped clear of the tab bar.
    @MainActor func scrollTo(_ element: XCUIElement, swipes: Int = 12) {
        let limit = app.windows.firstMatch.frame.height - 130
        for _ in 0..<swipes where !element.exists || !element.isHittable || element.frame.midY > limit {
            app.swipeUp(velocity: .slow)
        }
    }

    /// The general pasteboard's text. iOS asks before a test runner reads what the app copied: the read waits on a
    /// background thread while the question is answered here.
    @MainActor func pasteboard() -> String? {
        final class Box: @unchecked Sendable { var value: String?; var done = false }
        let box = Box()
        DispatchQueue.global().async {
            let value = UIPasteboard.general.string
            box.value = value
            box.done = true
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(15)
        while !box.done, Date() < deadline {
            for host in [springboard, app!] where host.buttons["Allow Paste"].exists { host.buttons["Allow Paste"].tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return box.value
    }

    /// Clears the search field and folds it away.
    @MainActor func closeSearch(_ field: XCUIElement) {
        if let typed = field.value as? String, !typed.isEmpty, field.buttons["Clear text"].exists { field.buttons["Clear text"].tap() }
        for name in ["Close", "Cancel", "close"] where app.buttons[name].exists && app.buttons[name].isHittable {
            app.buttons[name].tap()
            return
        }
        field.typeText("\n")
    }

    /// Try Again on the page's error state.
    @MainActor var tryAgain: XCUIElement { app.buttons["Try Again"] }

    @MainActor func confirmAlert(_ button: String, title: String, file: StaticString = #filePath, line: UInt = #line) {
        let alert = app.alerts[title]
        XCTAssertTrue(alert.waitForExistence(timeout: 8), "the question \(title)", file: file, line: line)
        alert.buttons[button].tap()
    }
}

final class MessagingUITests: IntegrationsCase {
    @MainActor private func openPlatform(_ id: String) {
        let row = app.buttons["messaging.row.\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the \(id) row")
        row.tap()
        XCTAssertTrue(app.collectionViews["messaging.platform.list"].waitForExistence(timeout: 10), "\(id)'s page")
    }

    @MainActor func testU11_Messaging() throws {
        launchSignedIn()
        let started = Date()
        openMore("messaging")
        let chirp = app.buttons["messaging.row.chirp"]
        XCTAssertTrue(chirp.waitForExistence(timeout: 15))
        measured("Messaging: tap to first rows \(String(format: "%.2f", Date().timeIntervalSince(started))) s (includes the tab switch)")
        XCTAssertEqual(chirp.label, "Chirp, Connected")
        XCTAssertEqual(app.buttons["messaging.row.telegram"].label, "Telegram, Needs setup")
        XCTAssertEqual(app.buttons["messaging.row.pigeon"].label, "Pigeon Post, Off")
        XCTAssertEqual(app.buttons["messaging.row.semaphore"].label, "Semaphore, Sign-in was refused. Check the bot token.")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'messaging.row.'")).count, 4)
        XCTAssertTrue(app.navigationBars["Messaging"].exists, "the small title on the bar")
        shot("messaging-list")

        // A configured platform.
        openPlatform("chirp")
        shot("messaging-platform-configured")

        // Test Connection shows the gateway's message.
        let test = app.buttons["messaging.test"]
        scrollTo(test)
        test.tap()
        XCTAssertTrue(text(containing: "Chirp is connected.").waitForExistence(timeout: 10))
        shot("messaging-test-result")

        // Who Can Message This Bot: Approve moves a person to Approved.
        let approve = app.buttons["messaging.approve.2001"]
        scrollTo(approve)
        shot("messaging-pairing")
        approve.tap()
        XCTAssertTrue(app.descendants(matching: .any)["messaging.approved.2001"].waitForExistence(timeout: 10), "Ada is approved")
        XCTAssertFalse(app.buttons["messaging.approve.2001"].exists)
        let approved = try XCTUnwrap(try rest("POST", "/api/pairing/approve").last?["body"] as? [String: Any])
        XCTAssertEqual(approved as NSDictionary, ["platform": "chirp", "request_id": "req-2001"] as NSDictionary, "the default bot sends no profile")

        // Remove asks first.
        let alan = app.descendants(matching: .any)["messaging.approved.1001"]
        scrollTo(alan)
        alan.swipeLeft()
        let remove = app.buttons["messaging.remove.1001"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(app.alerts["Remove Alan Turing?"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.alerts.staticTexts["They won’t be able to message this bot until you approve them again."].exists)
        XCTAssertTrue(try rest("POST", "/api/pairing/revoke").isEmpty, "nothing is sent before the answer")
        shot("messaging-remove-question")
        app.alerts.buttons["Remove"].tap()
        XCTAssertTrue(waitUntil(10) { !alan.exists }, "Alan is gone")
        let revoked = try XCTUnwrap(try rest("POST", "/api/pairing/revoke").last?["body"] as? [String: Any])
        XCTAssertEqual(revoked as NSDictionary, ["platform": "chirp", "user_id": "1001"] as NSDictionary)

        // A key: saved in the PUT body; the row reads Set and the value is nowhere on screen afterwards.
        app.swipeDown(); app.swipeDown()
        let key = app.buttons["messaging.key.CHIRP_BOT_TOKEN"]
        scrollTo(key)
        key.tap()
        let field = app.secureTextFields["env-editor.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the app's key page")
        XCTAssertFalse(app.buttons["env-editor.show"].exists, "a messaging key is never shown again")
        let secret = "chp-NEW-secret-7788-zz"
        field.tap()
        field.typeText(secret)
        shot("messaging-key-entry")
        app.buttons["env-editor.save"].tap()
        XCTAssertTrue(waitUntil(10) { (try? self.rest("PUT", "/api/messaging/platforms/chirp").count) == 1 }, "one PUT")
        let saved = try XCTUnwrap(try rest("PUT", "/api/messaging/platforms/chirp").last)
        XCTAssertEqual(saved["body"] as? NSDictionary, ["env": ["CHIRP_BOT_TOKEN": secret]] as NSDictionary, "exactly {env:{KEY:value}}")
        XCTAssertFalse(String(describing: saved["query"] ?? "").contains(secret), "never in the URL")
        XCTAssertTrue(waitUntil(10) { !app.buttons["env-editor.save"].isEnabled }, "the field is cleared once the key is saved")
        assertNowhereOnScreen(secret, "the saved key")
        shot("messaging-key-saved")
        back()
        XCTAssertTrue(key.waitForExistence(timeout: 10))
        XCTAssertTrue(key.label.contains("Set"), "the row reads Set: \(key.label)")
        assertNowhereOnScreen(secret, "the saved key")
        // That change was not served hot: the restart notice.
        XCTAssertTrue(text(containing: "Restart your gateway to use this change.").waitForExistence(timeout: 10))

        // On: written at once, {"enabled": false} only.
        let on = app.switches["messaging.platform.on"]
        scrollTo(on)
        XCTAssertTrue(isOn(on))
        flip(on)
        XCTAssertTrue(waitUntil(10) { (try? self.rest("PUT", "/api/messaging/platforms/chirp").count) == 2 })
        XCTAssertEqual(try rest("PUT", "/api/messaging/platforms/chirp").last?["body"] as? NSDictionary, ["enabled": false] as NSDictionary)
        XCTAssertTrue(waitUntil(5) { !self.isOn(on) })
        XCTAssertTrue(text(containing: "Off").waitForExistence(timeout: 10), "the status line follows")
        app.swipeDown()
        shot("messaging-restart-notice")
        back()
        XCTAssertTrue(waitUntil(10) { app.buttons["messaging.row.chirp"].label == "Chirp, Off" })

        // Telegram, not set up: the sheet.
        openPlatform("telegram")
        shot("messaging-platform-telegram-unconfigured")
        app.buttons["messaging.telegram.setup"].tap()
        XCTAssertTrue(app.buttons["telegram.open"].waitForExistence(timeout: 15), "Open Telegram")
        XCTAssertTrue(app.images["telegram.qr"].exists, "the QR code")
        XCTAssertTrue(text(containing: "Waiting for Telegram…").exists)
        shot("messaging-telegram-waiting")
        try knob("telegram", ["status": "ready", "bot_username": "demo_bot", "owner_user_id": "42"])
        XCTAssertTrue(app.staticTexts["Connected to @demo_bot"].waitForExistence(timeout: 15))
        shot("messaging-telegram-connected")
        app.buttons["telegram.finish"].tap()
        XCTAssertTrue(waitUntil(15) { !app.buttons["telegram.finish"].exists }, "the sheet closes after Finish")
        let telegram = try XCTUnwrap(try module("messaging")["telegram"] as? [String: Any])
        let applied = try XCTUnwrap((telegram["applied"] as? [[String: Any]])?.first)
        XCTAssertEqual(applied["allowed_user_ids"] as? [String], ["42"])
        XCTAssertEqual(applied["keys"] as? [String], ["allowed_user_ids"], "the default bot sends no profile")
        XCTAssertEqual((telegram["cancelled"] as? [String])?.count, 0, "Finish does not send the DELETE")

        // The restart notice, to "Gateway Restarted".
        let restart = app.buttons["gateway-restart.button"]
        XCTAssertTrue(restart.waitForExistence(timeout: 15), "the restart notice after Finish")
        restart.tap()
        XCTAssertTrue(app.alerts["Restart Your Gateway?"].waitForExistence(timeout: 8))
        shot("messaging-restart-question")
        app.alerts.buttons["Restart"].tap()
        XCTAssertTrue(text(containing: "Restarting…").waitForExistence(timeout: 10))
        shot("messaging-restart-running")
        XCTAssertTrue(text(containing: "Gateway Restarted").waitForExistence(timeout: 60), "the restart ends")
        shot("messaging-restart-done")
        XCTAssertEqual(try module("zz_restart_fallback")["restarts"] as? Int ?? (try rest("POST", "/api/gateway/restart").count), 1)
        XCTAssertFalse(app.buttons["messaging.telegram.setup"].exists, "Telegram is set up now")
    }

    /// Closing the sheet before Finish gives the pairing back; an expired link says so and starts again.
    @MainActor func testTelegramCloseAndExpiry() throws {
        launchSignedIn()
        openMore("messaging")
        openPlatform("telegram")
        app.buttons["messaging.telegram.setup"].tap()
        XCTAssertTrue(app.buttons["telegram.open"].waitForExistence(timeout: 15))
        app.buttons["sheet.close"].tap()
        XCTAssertTrue(waitUntil(10) {
            (((try? self.module("messaging"))?["telegram"] as? [String: Any])?["cancelled"] as? [String])?.count == 1
        }, "DELETE on close")
        XCTAssertEqual(try rest("DELETE", "/api/messaging/telegram/onboarding/").count, 1)

        try knob("messaging", ["expires_in": 4])
        app.buttons["messaging.telegram.setup"].tap()
        XCTAssertTrue(app.buttons["telegram.open"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["This link expired. Start again."].waitForExistence(timeout: 20), "the link expires")
        shot("messaging-telegram-expired")
        try knob("messaging", ["expires_in": 600])
        app.buttons["telegram.restart"].tap()
        XCTAssertTrue(app.buttons["telegram.open"].waitForExistence(timeout: 15), "Start Again makes a new link")
        // No owner detected: Finish waits for a numeric user ID.
        try knob("telegram", ["status": "ready", "bot_username": "demo_bot"])
        let field = app.textFields["telegram.user-id"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["telegram.finish"].isEnabled)
        field.tap()
        field.typeText("777")
        XCTAssertTrue(app.buttons["telegram.finish"].isEnabled)
        shot("messaging-telegram-user-id")
        app.buttons["sheet.close"].tap()
        XCTAssertTrue(waitUntil(10) {
            (((try? self.module("messaging"))?["telegram"] as? [String: Any])?["cancelled"] as? [String])?.count == 2
        }, "DELETE on close when connected but not finished")
    }

    /// Another bot: the profile rides in the query for reads and platform writes, in the body for approve.
    @MainActor func testOtherBotScope() throws {
        launchSignedIn()
        openMore("messaging")
        XCTAssertTrue(app.buttons["messaging.row.chirp"].waitForExistence(timeout: 15))
        let picker = app.buttons["more.bot-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "the bot picker (five bots)")
        picker.tap()
        app.buttons["Inbox"].tap()
        XCTAssertTrue(waitUntil(10) { (try? self.rest("GET", "/api/messaging/platforms").contains { ($0["query"] as? [String: Any])?["profile"] as? String == "inbox" }) == true })
        shot("messaging-list-other-bot")
        openPlatform("chirp")
        let approve = app.buttons["messaging.approve.2002"]
        scrollTo(approve)
        approve.tap()
        XCTAssertTrue(waitUntil(10) { (try? self.rest("POST", "/api/pairing/approve").count) == 1 })
        let body = try XCTUnwrap(try rest("POST", "/api/pairing/approve").last?["body"] as? [String: Any])
        XCTAssertEqual(body as NSDictionary, ["platform": "chirp", "request_id": "req-2002", "profile": "inbox"] as NSDictionary, "profile in the body")
        app.swipeDown(); app.swipeDown()
        let on = app.switches["messaging.platform.on"]
        scrollTo(on)
        flip(on)
        XCTAssertTrue(waitUntil(10) { (try? self.rest("PUT", "/api/messaging/platforms/chirp").count) == 1 })
        let put = try XCTUnwrap(try rest("PUT", "/api/messaging/platforms/chirp").last)
        XCTAssertEqual((put["query"] as? [String: Any])?["profile"] as? String, "inbox")
        XCTAssertEqual(put["body"] as? NSDictionary, ["enabled": false] as NSDictionary)
        // The choice is remembered; put it back for the tests that follow.
        back()
        app.buttons["more.bot-picker"].tap()
        app.buttons["Hermes"].tap()
        XCTAssertTrue(waitUntil(10) { app.buttons["messaging.row.chirp"].label == "Chirp, Connected" }, "the default bot's Chirp is untouched")
    }

    @MainActor func testWriteFailureRollsBackAndRapidFlips() throws {
        launchSignedIn()
        openMore("messaging")
        openPlatform("chirp")
        let on = app.switches["messaging.platform.on"]
        XCTAssertTrue(on.waitForExistence(timeout: 10))
        try fail("PUT", "/api/messaging/platforms/chirp", status: 500, detail: "The config file is locked.")
        flip(on)
        XCTAssertTrue(app.alerts["Couldn’t Turn Off Chirp"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.alerts.staticTexts["The config file is locked."].exists)
        shot("messaging-write-failed")
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(waitUntil(5) { self.isOn(on) }, "rolled back")
        XCTAssertTrue(try writes("messaging").isEmpty)

        // Rapid flips: the page ends where the gateway ends.
        for _ in 0..<7 { flip(on) }
        XCTAssertTrue(waitUntil(10) { !app.activityIndicators.firstMatch.exists })
        Thread.sleep(forTimeInterval: 1.5)
        let enabled = try XCTUnwrap(((try module("messaging")["platforms"] as? [String: Any])?["default"] as? [[String: Any]])?
            .first { ($0["id"] as? String) == "chirp" }?["enabled"] as? Bool)
        XCTAssertEqual(isOn(on), enabled, "the switch shows what the gateway holds")
        for write in try writes("messaging") { XCTAssertEqual(write["keys"] as? [String], ["enabled"]) }
    }

    @MainActor func testSlowReadThenFailureAndTryAgain() throws {
        launchSignedIn()
        tab("More")
        try delay("GET", "/api/pairing", seconds: 5)
        try fail("GET", "/api/messaging/platforms", status: 503, detail: "The gateway is starting.")
        openMore("messaging")
        XCTAssertTrue(app.otherElements["more.page.loading"].waitForExistence(timeout: 3), "skeleton while the read is out")
        shot("messaging-loading")
        XCTAssertTrue(app.staticTexts["Couldn’t Load Messaging"].waitForExistence(timeout: 20))
        XCTAssertTrue(text(containing: "The gateway is starting.").exists)
        shot("messaging-load-failed")
        tryAgain.tap()
        XCTAssertTrue(app.buttons["messaging.row.chirp"].waitForExistence(timeout: 15), "Try Again works")
    }

    @MainActor func testStressManyPlatformsAndPeople() throws {
        try knob("messaging", ["platforms": 40, "pending": 500])
        launchSignedIn()
        openMore("messaging")
        XCTAssertTrue(app.buttons["messaging.row.chirp"].waitForExistence(timeout: 15))
        // Search behind the magnifier finds one of forty.
        app.buttons["messaging.search"].tap()
        let field = app.searchFields["messaging.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("App 37")
        XCTAssertTrue(app.buttons["messaging.row.app-37"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'messaging.row.'")).count, 1)
        shot("messaging-search")
        field.buttons["Clear text"].tap()
        field.typeText("zzzz")
        XCTAssertTrue(text(containing: "No Results").waitForExistence(timeout: 5))
        closeSearch(field)
        let last = app.buttons["messaging.row.app-39"]
        for _ in 0..<12 where !last.exists { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(last.exists, "forty platforms, the repeated one listed once")
        shot("messaging-list-40")
        for _ in 0..<12 where !app.buttons["messaging.row.chirp"].exists { app.swipeDown(velocity: .fast) }
        let started = Date()
        openPlatform("chirp")
        let first = app.buttons["messaging.approve.5000"]
        scrollTo(first)
        XCTAssertTrue(first.exists, "500 people waiting")
        measured("Messaging platform with 500 waiting: first person reachable after \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        shot("messaging-pairing-500")
        // The list still scrolls and answers with 500 rows in it.
        for _ in 0..<4 { app.swipeUp(velocity: .fast) }
        for _ in 0..<10 where !(first.exists && first.isHittable) { app.swipeDown(velocity: .fast) }
        scrollTo(first)
        first.tap()
        XCTAssertTrue(waitUntil(15) { !first.exists }, "the person leaves the waiting rows")
        XCTAssertEqual(try rest("POST", "/api/pairing/approve").last?["body"] as? NSDictionary,
                       ["platform": "chirp", "request_id": "req-5000"] as NSDictionary)
        XCTAssertTrue(app.buttons["messaging.approve.5001"].waitForExistence(timeout: 10), "the next person moves up")
    }

    @MainActor func testReadOnlyGatewayShowsNoWriteControl() throws {
        launchSignedIn(["-HQPagesReadOnly", "YES"])
        openMore("messaging")
        openPlatform("chirp")
        XCTAssertFalse(app.switches["messaging.platform.on"].exists)
        XCTAssertFalse(app.buttons["messaging.test"].exists)
        XCTAssertFalse(app.buttons["messaging.key.CHIRP_BOT_TOKEN"].exists, "a key is not a button")
        XCTAssertTrue(app.descendants(matching: .any)["messaging.key.CHIRP_BOT_TOKEN"].exists, "but it is listed")
        let alan = app.descendants(matching: .any)["messaging.approved.1001"]
        scrollTo(alan)
        XCTAssertFalse(app.buttons["messaging.approve.2001"].exists)
        alan.swipeLeft()
        XCTAssertFalse(app.buttons["messaging.remove.1001"].exists)
        shot("messaging-read-only")
        back()
        openPlatform("telegram")
        XCTAssertFalse(app.buttons["messaging.telegram.setup"].exists)
        XCTAssertFalse(app.buttons["gateway-restart.button"].exists)
        XCTAssertEqual(try nonReads(["/api/messaging", "/api/pairing", "/api/gateway"]), [], "the gateway saw no write")
        XCTAssertTrue(try writes("messaging").isEmpty)
    }

    @MainActor func testRelaunchOnThePage() throws {
        launchSignedIn()
        openMore("messaging")
        openPlatform("chirp")
        relaunch()
        XCTAssertTrue(app.tabBars.buttons["More"].waitForExistence(timeout: 20), "the tab bar shows after a relaunch")
        // The page is restored, or More's root shows: either way Messaging opens again from More.
        if !app.buttons["messaging.row.chirp"].waitForExistence(timeout: 5) {
            if app.collectionViews["messaging.platform.list"].exists { back() }
            if !app.buttons["messaging.row.chirp"].exists { openMore("messaging") }
        }
        XCTAssertTrue(app.buttons["messaging.row.chirp"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.tabBars.buttons["More"].isSelected || app.tabBars.buttons["More"].exists)
    }
}
