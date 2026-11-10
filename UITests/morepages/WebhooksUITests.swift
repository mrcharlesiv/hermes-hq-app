// More › Webhooks end to end (docs/spec/3x-morepages.md §13 acceptance 2, §21) against the morepages stand-in
// (scripts/fixtures/morepages/webhooks.py); the receiver-off pass runs against the `wh` stand-in (--webhooks-off).

import XCTest

final class WebhooksUITests: IntegrationsCase {
    @MainActor private func openWebhooks() {
        openMore("webhooks")
        XCTAssertTrue(app.navigationBars["Webhooks"].waitForExistence(timeout: 10))
    }

    @MainActor private func row(_ name: String) -> XCUIElement { app.buttons["webhooks.row.\(name)"] }

    @MainActor func testU12_Webhooks() throws {
        launchSignedIn()
        let started = Date()
        openWebhooks()
        XCTAssertTrue(row("github-push").waitForExistence(timeout: 15))
        measured("Webhooks: tap to first rows \(String(format: "%.2f", Date().timeIntervalSince(started))) s (includes the tab switch)")
        XCTAssertTrue(row("invoice-paid").exists && row("status-page").exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'webhooks.row.'")).count, 3)
        XCTAssertTrue(app.staticTexts["Webhooks 3"].exists || app.staticTexts["WEBHOOKS 3"].exists)
        XCTAssertTrue(row("github-push").label.contains("push, pull_request → Telegram"), row("github-push").label)
        XCTAssertTrue(row("invoice-paid").label.contains("All Events → Log Only"), row("invoice-paid").label)
        shot("webhooks-list")

        // The switch writes {"enabled": false} only.
        let toggle = app.switches["webhooks.switch.github-push"]
        XCTAssertTrue(isOn(toggle))
        XCTAssertFalse(isOn(app.switches["webhooks.switch.status-page"]))
        flip(toggle)
        XCTAssertTrue(waitUntil(10) { (try? self.rest("PUT", "/api/webhooks/github-push/enabled").count) == 1 })
        XCTAssertEqual(try rest("PUT", "/api/webhooks/github-push/enabled").last?["body"] as? NSDictionary, ["enabled": false] as NSDictionary)
        XCTAssertTrue(waitUntil(5) { !self.isOn(toggle) })

        // New Webhook with only a name.
        app.buttons["webhooks.compose"].tap()
        let name = app.textFields["webhooks.new.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["webhooks.new.create"].isEnabled, "Create waits for a name")
        shot("webhooks-new-form")
        name.tap()
        name.typeText("deploy-hook")
        XCTAssertTrue(app.buttons["webhooks.new.create"].isEnabled)
        app.buttons["webhooks.new.create"].tap()
        let secretText = app.staticTexts["webhooks.created.secret"]
        XCTAssertTrue(secretText.waitForExistence(timeout: 15), "the Webhook Created sheet")
        XCTAssertTrue(app.navigationBars["Webhook Created"].exists)
        XCTAssertTrue(text(containing: "Copy the secret now. It is only shown once.").exists)
        let created = try XCTUnwrap((try module("webhooks")["created"] as? [[String: Any]])?.last)
        XCTAssertEqual(created["keys"] as? [String], ["deliver", "deliver_only", "name"], "absent keys are not sent")
        let secret = try XCTUnwrap(created["secret"] as? String)
        XCTAssertEqual(secretText.label, secret)
        shot("webhooks-created")
        // It cannot be swiped away by accident.
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(secretText.waitForExistence(timeout: 3), "still there after a swipe down")
        UIPasteboard.general.string = "something else"
        let copySecret = app.buttons["webhooks.created.copy-secret"]
        for _ in 0..<4 where !copySecret.isHittable || copySecret.frame.maxY > app.windows.firstMatch.frame.height - 60 {
            app.swipeUp(velocity: .slow)
        }
        copySecret.tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 5), "Copy answers Copied")
        XCTAssertEqual(pasteboard(), secret, "Copy puts the secret on the pasteboard")
        let copyURL = app.buttons["webhooks.created.copy-url"]
        app.swipeDown(velocity: .slow); app.swipeDown(velocity: .slow)   // back to the top of the sheet
        XCTAssertTrue(secretText.exists, "still there")
        copyURL.tap()
        XCTAssertTrue(waitUntil(8) { self.pasteboard()?.hasSuffix("/webhooks/deploy-hook") == true }, "Copy puts the URL on the pasteboard")
        app.buttons["webhooks.created.done"].tap()
        XCTAssertTrue(row("deploy-hook").waitForExistence(timeout: 15), "the new webhook is listed")
        assertNowhereOnScreen(secret, "the secret")
        UIPasteboard.general.string = ""

        // Detail: the facts, Copy URL, the switch, Delete.
        row("deploy-hook").tap()
        XCTAssertTrue(app.staticTexts["webhooks.detail.url"].waitForExistence(timeout: 10), "the detail page")
        assertNowhereOnScreen(secret, "the secret")
        XCTAssertTrue(app.switches["webhooks.detail.on"].exists, "the detail page's switch")
        shot("webhooks-detail")
        app.buttons["webhooks.detail.copy"].tap()
        XCTAssertTrue(waitUntil(8) { self.pasteboard()?.hasSuffix("/webhooks/deploy-hook") == true }, "Copy URL on the detail page")
        let delete = app.buttons["webhooks.detail.delete"]
        for _ in 0..<8 where !delete.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(delete.exists, "Delete Webhook at the foot of the detail page")
        back()

        // Delete asks, then the row goes.
        XCTAssertTrue(row("invoice-paid").waitForExistence(timeout: 10), "back on the list")
        row("invoice-paid").swipeLeft()
        XCTAssertTrue(app.buttons["webhooks.swipe.delete"].waitForExistence(timeout: 5), "swipe shows Delete")
        shot("webhooks-swipe")
        app.buttons["webhooks.swipe.delete"].tap()
        XCTAssertTrue(app.alerts["Delete Webhook?"].waitForExistence(timeout: 8), "Delete asks")
        XCTAssertTrue(app.alerts.staticTexts["This will permanently remove invoice-paid. This can’t be undone."].exists)
        XCTAssertTrue(try rest("DELETE", "/api/webhooks/").isEmpty)
        shot("webhooks-delete-question")
        app.alerts.buttons["Delete"].tap()
        XCTAssertTrue(waitUntil(10) { !self.row("invoice-paid").exists }, "the row goes")
        XCTAssertEqual(try rest("DELETE", "/api/webhooks/invoice-paid").count, 1)
        XCTAssertTrue(app.staticTexts["Webhooks 3"].waitForExistence(timeout: 10) || app.staticTexts["WEBHOOKS 3"].exists)

        // The hold menu: Copy URL.
        row("status-page").press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Copy URL"].waitForExistence(timeout: 5), "the hold menu")
        shot("webhooks-hold-menu")
        app.buttons["Copy URL"].tap()
        XCTAssertTrue(waitUntil(8) { self.pasteboard()?.hasSuffix("/webhooks/status-page") == true }, "Copy URL from the hold menu")
    }

    @MainActor func testNewWebhookFullFormAndRefusals() throws {
        launchSignedIn()
        openWebhooks()
        XCTAssertTrue(row("github-push").waitForExistence(timeout: 15))
        app.buttons["webhooks.compose"].tap()
        let name = app.textFields["webhooks.new.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        name.typeText("Bad/Name")
        XCTAssertFalse(app.buttons["webhooks.new.create"].isEnabled, "a name the gateway would refuse")
        XCTAssertTrue(text(containing: "Use lowercase letters, numbers, hyphens and underscores").exists)
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8))
        name.typeText("release-notes")
        let events = app.textFields["webhooks.new.events"]
        events.tap()
        events.typeText("push, release ,,")
        let picker = app.buttons["webhooks.new.deliver"]
        scrollTo(picker)
        picker.tap()
        app.buttons["Telegram"].tap()
        let chat = app.textFields["webhooks.new.chat-id"]
        XCTAssertTrue(chat.waitForExistence(timeout: 5), "a chat platform takes a chat")
        chat.tap()
        chat.typeText("-100123")
        shot("webhooks-new-form-filled")

        // The name is taken, then a gateway error: both stay on the form with the words.
        try knob("webhooks", ["create": 409])
        app.buttons["webhooks.new.create"].tap()
        XCTAssertTrue(app.staticTexts["A webhook with that name already exists."].waitForExistence(timeout: 10))
        shot("webhooks-new-name-taken")
        try knob("webhooks", ["create": 500])
        app.buttons["webhooks.new.create"].tap()
        XCTAssertTrue(app.staticTexts["Internal server error"].waitForExistence(timeout: 10))
        XCTAssertTrue(try writes("webhooks").isEmpty, "nothing was made")

        app.buttons["webhooks.new.create"].tap()
        XCTAssertTrue(app.staticTexts["webhooks.created.secret"].waitForExistence(timeout: 15))
        let created = try XCTUnwrap(try rest("POST", "/api/webhooks").last?["body"] as? [String: Any])
        XCTAssertEqual(created as NSDictionary, ["name": "release-notes", "events": ["push", "release"], "deliver": "telegram",
                                                 "deliver_chat_id": "-100123", "deliver_only": false] as NSDictionary)
        app.buttons["webhooks.created.done"].tap()
        XCTAssertTrue(row("release-notes").waitForExistence(timeout: 15))
        XCTAssertTrue(row("release-notes").label.contains("push, release · Telegram"))

        // Cancel leaves nothing behind.
        app.buttons["webhooks.compose"].tap()
        XCTAssertTrue(app.buttons["webhooks.new.cancel"].waitForExistence(timeout: 10))
        app.buttons["webhooks.new.cancel"].tap()
        XCTAssertTrue(waitUntil(5) { !app.textFields["webhooks.new.name"].exists })
        XCTAssertEqual(try rest("POST", "/api/webhooks").count, 3)
    }

    @MainActor func testEmptyState() throws {
        try knob("webhooks", ["empty": true])
        launchSignedIn()
        openWebhooks()
        XCTAssertTrue(app.staticTexts["No Webhooks Yet"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["A webhook lets another service start a bot."].exists)
        shot("webhooks-empty")
        XCTAssertFalse(app.buttons["webhooks.search"].exists && app.buttons["webhooks.search"].isHittable, "nothing to search")
        app.buttons.matching(NSPredicate(format: "identifier == 'more.page.empty' AND label == 'New Webhook'")).firstMatch.tap()
        XCTAssertTrue(app.textFields["webhooks.new.name"].waitForExistence(timeout: 10))
        app.buttons["webhooks.new.cancel"].tap()
    }

    @MainActor func testToggleFailureRollsBackAndRapidFlips() throws {
        launchSignedIn()
        openWebhooks()
        let toggle = app.switches["webhooks.switch.github-push"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        try fail("PUT", "/api/webhooks/github-push/enabled", status: 500, detail: "The file is locked.")
        flip(toggle)
        XCTAssertTrue(app.alerts["Couldn’t turn “github-push” off"].waitForExistence(timeout: 10))
        shot("webhooks-toggle-failed")
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(waitUntil(5) { self.isOn(toggle) }, "rolled back")

        for _ in 0..<9 { flip(toggle) }
        Thread.sleep(forTimeInterval: 2)
        let off = try XCTUnwrap(try module("webhooks")["off"] as? [String])
        XCTAssertEqual(isOn(toggle), !off.contains("github-push"), "the switch shows what the gateway holds")
        for write in try rest("PUT", "/api/webhooks/github-push/enabled") {
            XCTAssertEqual((write["body"] as? [String: Any])?.keys.sorted(), ["enabled"])
        }
    }

    @MainActor func testStress300AndSearch() throws {
        try knob("webhooks", ["count": 300])
        launchSignedIn()
        let started = Date()
        openWebhooks()
        XCTAssertTrue(row("github-push").waitForExistence(timeout: 15))
        measured("Webhooks with 300: tap to first rows \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        XCTAssertTrue(app.staticTexts["Webhooks 300"].exists || app.staticTexts["WEBHOOKS 300"].exists, "300, the repeated name once")
        app.buttons["webhooks.search"].tap()
        let field = app.searchFields["webhooks.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("hook-299")
        XCTAssertTrue(row("hook-299").waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'webhooks.row.'")).count, 1)
        shot("webhooks-search")
        let toggle = app.switches["webhooks.switch.hook-299"]
        let before = isOn(toggle)
        flip(toggle)
        XCTAssertTrue(waitUntil(10) { (try? self.rest("PUT", "/api/webhooks/hook-299/enabled").count) == 1 })
        XCTAssertEqual(isOn(toggle), !before)
        closeSearch(field)
        for _ in 0..<5 { app.swipeUp(velocity: .fast) }
        shot("webhooks-list-300")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'webhooks.row.hook-'")).firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor func testSlowReadThenFailureAndTryAgain() throws {
        launchSignedIn()
        tab("More")
        try delay("GET", "/api/webhooks", seconds: 4)
        openMore("webhooks")
        XCTAssertTrue(app.otherElements["more.page.loading"].waitForExistence(timeout: 3), "skeleton while the read is out")
        XCTAssertTrue(row("github-push").waitForExistence(timeout: 20), "a slow read still lands")
        back()
        try fail("GET", "/api/webhooks", status: 502, detail: "Bad gateway from the tunnel.")
        openMore("webhooks")
        XCTAssertTrue(app.staticTexts["Couldn’t Load Webhooks"].waitForExistence(timeout: 15))
        shot("webhooks-load-failed")
        XCTAssertFalse(app.buttons["webhooks.compose"].exists && app.buttons["webhooks.compose"].isHittable, "no New Webhook over an error")
        tryAgain.tap()
        XCTAssertTrue(row("github-push").waitForExistence(timeout: 15), "Try Again works")
    }

    @MainActor func testReadOnlyGatewayShowsNoWriteControl() throws {
        launchSignedIn(["-HQPagesReadOnly", "YES"])
        openWebhooks()
        XCTAssertTrue(row("github-push").waitForExistence(timeout: 15))
        XCTAssertEqual(app.switches.count, 0, "no switch")
        XCTAssertFalse(app.buttons["webhooks.compose"].exists && app.buttons["webhooks.compose"].isHittable, "no New Webhook")
        row("github-push").swipeLeft()
        XCTAssertTrue(app.buttons["webhooks.swipe.copy"].waitForExistence(timeout: 5), "Copy URL stays")
        XCTAssertFalse(app.buttons["webhooks.swipe.delete"].exists)
        shot("webhooks-read-only")
        app.buttons["webhooks.swipe.copy"].tap()
        row("github-push").tap()
        XCTAssertTrue(app.staticTexts["webhooks.detail.url"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.switches["webhooks.detail.on"].exists)
        XCTAssertFalse(app.buttons["webhooks.detail.delete"].exists)
        XCTAssertEqual(try nonReads(["/api/webhooks", "/api/gateway"]), [], "the gateway saw no write")
    }

    @MainActor func testRelaunchOnThePage() throws {
        launchSignedIn()
        openWebhooks()
        XCTAssertTrue(row("github-push").waitForExistence(timeout: 15))
        row("github-push").tap()
        XCTAssertTrue(app.staticTexts["webhooks.detail.url"].waitForExistence(timeout: 10))
        relaunch()
        XCTAssertTrue(app.tabBars.buttons["More"].waitForExistence(timeout: 20), "the tab bar shows after a relaunch")
        if !row("github-push").waitForExistence(timeout: 5) {
            if app.staticTexts["webhooks.detail.url"].exists { back() }
            if !row("github-push").exists { openMore("webhooks") }
        }
        XCTAssertTrue(row("github-push").waitForExistence(timeout: 15))
    }
}

/// The receiver starts off (`--webhooks-off`).
final class WebhooksOffUITests: IntegrationsCase {
    override class var gateway: String { "wh" }

    @MainActor func testU12_ReceiverOff() throws {
        launchSignedIn()
        openMore("webhooks")
        XCTAssertTrue(app.staticTexts["Webhook Receiver Is Off"].waitForExistence(timeout: 15))
        XCTAssertTrue(text(containing: "Turn it on to let other services send events to your bots.").exists)
        XCTAssertFalse(app.buttons["webhooks.compose"].exists && app.buttons["webhooks.compose"].isHittable, "no New Webhook while the receiver is off")
        shot("webhooks-receiver-off")
        app.buttons["webhooks.turn-on"].tap()
        XCTAssertTrue(text(containing: "Webhooks are enabled, but the gateway still needs a restart").waitForExistence(timeout: 15))
        XCTAssertEqual(try rest("POST", "/api/webhooks/enable").count, 1)
        XCTAssertFalse(app.staticTexts["Webhook Receiver Is Off"].exists)
        shot("webhooks-restart-notice")
        app.buttons["gateway-restart.button"].tap()
        confirmAlert("Restart", title: "Restart Your Gateway?")
        XCTAssertTrue(text(containing: "Restarting…").waitForExistence(timeout: 10))
        shot("webhooks-restart-running")
        XCTAssertTrue(text(containing: "Gateway Restarted").waitForExistence(timeout: 60))
        shot("webhooks-restart-done")
        // With the receiver on, a webhook can be made.
        XCTAssertTrue(waitUntil(10) { app.buttons["webhooks.compose"].exists && app.buttons["webhooks.compose"].isHittable })
    }

    @MainActor func testReadOnlyReceiverOff() throws {
        launchSignedIn(["-HQPagesReadOnly", "YES"])
        openMore("webhooks")
        XCTAssertTrue(app.staticTexts["Webhook Receiver Is Off"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["webhooks.turn-on"].exists)
        XCTAssertEqual(try nonReads(["/api/webhooks", "/api/gateway"]), [])
    }
}
