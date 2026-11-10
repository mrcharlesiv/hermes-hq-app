// Notifications end to end against the push fixture (scripts/e2e-push.sh starts scripts/fixtures/push-gateway.py and
// passes TEST_RUNNER_HQN_UI_CREDENTIALS + TEST_RUNNER_HQN_UI_PUSH=1; without them every test here skips). Deliveries go
// through `xcrun simctl push` (the fixture runs it), which never runs the notification extension: alerts here are
// unsealed, as a plugin sends them to a device without a seal key. All values are invented.

import XCTest

final class PushEndToEndTests: XCTestCase {
    var account: FixtureAccount!
    var app: XCUIApplication!
    @MainActor var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["HQN_UI_PUSH"] == "1" else {
            throw XCTSkip("Run with scripts/e2e-push.sh (the push fixture).")
        }
        account = try FixtureAccount.load()
        try account.control("/__fixture/push/reset", [:])
    }

    // MARK: 1. Setup offer → Settings › Notifications → permission → registration → previews / off / on

    @MainActor func test1_SetupOfferSettingsAndRegistration() throws {
        try account.control("/__fixture/push", ["plugin": "missing"])
        launch()
        // At launch a gateway without the plugin is offered setup by its main bot, in the update sheet.
        let offer = updateSheetAsks()
        XCTAssertTrue(offer.exists, "the setup offer shows once the roster is in")
        XCTAssertTrue(headline().hasPrefix("Set Up the Add-on"), headline())
        XCTAssertEqual(offer.label, "Set Up")
        attach("setup-offer")
        offer.tap()
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 10), "the main bot's chat opens")
        XCTAssertTrue(chatShows("notification add-on on this Hermes").waitForExistence(timeout: 10),
                      "the manager wasn't there to use: the whole install goes to the bot")
        XCTAssertTrue(app.staticTexts["addon-update.detail.install"].waitForExistence(timeout: 5), "the sheet says the bot installs it")
        attach("setup-request-typed")
        closeUpdateSheet()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        openNotificationSettings()
        XCTAssertTrue(app.switches["notifications.enabled"].exists)
        for kind in ["approval", "input", "turnDone", "turnError", "backgroundDone", "credits"] {
            XCTAssertTrue(app.switches["notifications.kind.\(kind)"].exists, "the \(kind) switch")
        }
        XCTAssertFalse(app.switches["notifications.kind.plugin"].exists, "Plugin Notifications stays hidden until it's wired (d30bdce)")
        XCTAssertTrue(waitUntil(timeout: 10) { self.pushRowLabel().contains("Add-on Needed") }, "the gateway lacks the add-on: \(pushRowLabel())")
        XCTAssertTrue(app.buttons["notifications.ask-bot"].exists, "with Ask Hermes to Install It")
        attach("settings-addon-needed")

        // The bot installed it: Send Test Notification asks iOS, then the device registers with the plugin.
        try account.control("/__fixture/push", ["plugin": "ready"])
        let list = app.collectionViews["notifications.list"]
        for _ in 0..<4 where !app.buttons["notifications.test"].isHittable { list.swipeUp() }
        app.buttons["notifications.test"].tap()
        allowNotifications()
        XCTAssertTrue(waitUntil(timeout: 20) { (self.devices().first?["sealKeyBytes"] as? Int) == 32 }, "registered with a seal key: \(devices())")
        let device = try XCTUnwrap(devices().first)
        XCTAssertEqual(device["environment"] as? String, "sandbox")
        XCTAssertEqual(device["profile"] as? String, "*")
        XCTAssertEqual(device["previews"] as? Bool, true)
        // "outside": Outside Chats alerts, asked for only while Sessions › Show › Outside Chats is on (off here).
        XCTAssertEqual(device["kinds"] as? [String: Bool], ["turnDone": true, "approval": true, "outside": false])
        XCTAssertEqual((device["account"] as? String)?.count, 64, "the opaque account tag")
        list.swipeDown(); list.swipeDown()
        XCTAssertTrue(waitUntil(timeout: 10) { self.pushRowLabel().contains("On") }, "the page says alerts come while closed: \(pushRowLabel())")
        attach("settings-registered")

        // Show Previews off: the plugin is told (it then sends only who).
        tapSwitch("notifications.previews")
        XCTAssertTrue(waitUntil(timeout: 10) { (self.devices().first?["previews"] as? Bool) == false }, "previews off reaches the plugin")
        // Response Ready off: that kind is off at the plugin.
        tapSwitch("notifications.kind.turnDone")
        XCTAssertTrue(waitUntil(timeout: 10) { ((self.devices().first?["kinds"] as? [String: Bool]) ?? [:])["turnDone"] == false })
        // Enable Notifications off: the device leaves the plugin; on again: back.
        tapSwitch("notifications.enabled")
        XCTAssertTrue(waitUntil(timeout: 10) { self.devices().isEmpty && !self.removed().isEmpty }, "off removes the device")
        tapSwitch("notifications.enabled")
        XCTAssertTrue(waitUntil(timeout: 10) { !self.devices().isEmpty }, "on registers again")
        attach("settings-final")   // (the next launch resets the switches: -HQDebugResetNotificationPrefs)
    }

    // MARK: 2. Another chat's reply while the app is open: the peek, Back's count, tap opens it

    @MainActor func test2_ReplyPeekBackCountAndTapOpens() throws {
        try account.control("/__fixture/push", ["plugin": "missing"])   // local alerts (no push delivers replies)
        try account.control("/__fixture/plan", ["plans": [["replyDelay": 60]]])
        launch()
        dismissSetupOffer()
        openBot("ivy")
        send("Fixture question for Ivy")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        openBot("default")
        try account.control("/__fixture/finish", ["profile": "ivy", "text": "Ivy's fixture reply is ready."])
        let peek = app.descendants(matching: .any)["reply-peek"]
        XCTAssertTrue(peek.waitForExistence(timeout: 15), "another chat's reply drops in as the peek")
        XCTAssertTrue(peek.label.contains("Ivy replied"), "it names Ivy: \(peek.label)")
        XCTAssertTrue(peek.label.contains("fixture reply"), "and the reply's first words: \(peek.label)")
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(waitUntil(timeout: 10) { back.label == "Back, 1" }, "Back says one other chat has an unread reply: \(back.label)")
        attach("reply-peek")
        peek.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { self.chatTitle().contains("Ivy") }, "a tap opens Ivy's chat: \(chatTitle())")
        attach("peek-opened-chat")
    }

    // MARK: 3. A pushed reply's tap opens its chat, warm and cold

    @MainActor func test3_PushTapOpensChatWarmAndCold() throws {
        try account.control("/__fixture/push", ["plugin": "ready"])
        launch()
        dismissSetupOffer()
        ensurePermission()
        // Warm: the app is in the background.
        goHome()
        try account.control("/__fixture/push/deliver", ["kind": "turnDone", "profile": "ivy", "text": "Warm fixture reply."])
        tapBanner(containing: "Warm fixture reply")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 15) { self.chatTitle().contains("Ivy") }, "the tap opens Ivy's chat (warm): \(chatTitle())")
        attach("push-tap-warm")
        // Cold: the app isn't running.
        app.terminate()
        try account.control("/__fixture/push/deliver", ["kind": "turnDone", "profile": "ivy", "text": "Cold fixture reply."])
        tapBanner(containing: "Cold fixture reply")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(waitUntil(timeout: 25) { self.chatTitle().contains("Ivy") }, "the tap opens Ivy's chat (cold launch): \(chatTitle())")
        attach("push-tap-cold")
    }

    // MARK: 4. Approve once from a pushed approval, without opening the app

    @MainActor func test4_ApproveOnceFromTheAlert() throws {
        try account.control("/__fixture/push", ["plugin": "ready"])
        launch()
        dismissSetupOffer()
        ensurePermission()
        XCTAssertTrue(waitUntil(timeout: 20) { !self.devices().isEmpty }, "registered (the alert's account tag is this device's)")
        goHome()
        // A new request id each run: the app remembers answered ids (the first tap wins, across launches too).
        let request = "req_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        try account.control("/__fixture/push/deliver", ["kind": "approval", "profile": "ivy", "request": request, "text": "npm run deploy"])
        let banner = banner(containing: "npm run deploy")
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "the approval alert shows")
        banner.press(forDuration: 1.2)
        let approve = springboard.buttons["Approve Once"]
        XCTAssertTrue(approve.waitForExistence(timeout: 5), "with Approve Once and Deny")
        XCTAssertTrue(springboard.buttons["Deny"].exists)
        attach("approval-actions")
        approve.tap()
        XCTAssertTrue(waitUntil(timeout: 25) { self.approvals().contains { $0["request"] as? String == request && $0["choice"] as? String == "once" } },
                      "Approve once reached the plugin with its token: \(approvals())")
        XCTAssertEqual(approvals().count, 1, "sent once")
    }

    // MARK: Helpers

    // MARK: 5. The app installs the plugin itself (plugins.manage); the bot only restarts, and a Hermes too old says so

    @MainActor func test5_SetupInstallsThroughThePluginManager() throws {
        // A Hermes without a plugin manager: an honest "Update Hermes First", and nothing is sent to the bot.
        try account.control("/__fixture/push", ["plugin": "missing", "manager": "none"])
        launch()
        let offer = updateSheetAsks()
        XCTAssertTrue(offer.exists, "the setup offer shows")
        offer.tap()
        XCTAssertTrue(waitUntil(timeout: 15) { self.headline() == "Update Hermes First" }, "a Hermes too old for plugins is told plainly: \(headline())")
        attach("setup-too-old")
        closeUpdateSheet()
        XCTAssertFalse(app.textViews["composer.text"].exists, "no chat opened: nothing goes to the bot")
        app.terminate()

        // The manager installs it and needs the web server restarted: the bot is asked for the restart alone.
        try account.control("/__fixture/push/reset", [:])
        try account.control("/__fixture/push", ["plugin": "missing", "manager": "restart"])
        launch()
        updateSheetAsks().tap()
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 30), "the main bot's chat opens for the restart")
        // [setup-browser] A first setup puts Watch Browser's add-on in too, so the one restart loads both.
        XCTAssertTrue(chatShows("Restart Hermes so the").waitForExistence(timeout: 10), "only the restart is asked")
        // (The full install request may still be in this chat from test1: the stand-in gateway keeps its messages, so
        // "only the restart" is the restart title above plus the manager's install below.)
        let install = ((state()["manage"] as? [[String: Any]]) ?? []).first { ($0["action"] as? String) == "install" }
        XCTAssertEqual(install?["identifier"] as? String, "mrcharlesiv/hermes-hq-plugins/hermes-hq-push")
        XCTAssertEqual(install?["enable"] as? Bool, true)
        XCTAssertTrue(waitUntil(timeout: 10) { self.headline() == "Restarting Hermes…" }, "the sheet stays over the chat: \(headline())")
        attach("setup-restart-asked")

        // [addon-progress] Hidden while it waits, a tap on Settings' row brings the same sheet back (it used to buzz
        // and do nothing), and the restart is seen within seconds.
        closeUpdateSheet()
        app.navigationBars.buttons.element(boundBy: 0).tap()   // out of the chat, where the tabs show
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        let settingsRow = app.cells["more-row-settings"]
        XCTAssertTrue(settingsRow.waitForExistence(timeout: 5))
        settingsRow.tap()
        let row = app.buttons["settings.addon-update"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the row shows the update under way")
        XCTAssertTrue(row.label.contains("Updating Add-on"), row.label)
        attach("setup-restart-row")
        row.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.headline() == "Restarting Hermes…" }, "the second tap shows the sheet again: \(headline())")
        attach("setup-restart-second-tap")
        try account.control("/__fixture/push", ["plugin": "ready"])   // Hermes is back with the add-on
        XCTAssertTrue(waitUntil(timeout: 15) { self.headline().hasSuffix("Is On") || self.headline().hasSuffix("Are On") || self.headline() == "Add-on Set Up" },
                      "the restart is seen: \(headline())")
        attach("setup-restart-done")
        app.terminate()

        // The routes come up at once: no bot at all, straight to iOS's permission. An update, as a first setup brings
        // Watch Browser's add-on too, whose hooks always need the restart ([setup-browser]).
        try account.control("/__fixture/push/reset", [:])
        try account.control("/__fixture/push", ["plugin": "outdated", "manager": "reload"])
        launch()
        updateSheetAsks().tap()
        allowNotifications()
        XCTAssertTrue(waitUntil(timeout: 20) { !self.devices().isEmpty }, "registered without the bot: \(state())")
        XCTAssertFalse(app.textViews["composer.text"].exists, "no chat opened: nothing asked of the bot")
    }

    // MARK: 6. [addon-reminder] Not Now once: no alert at the next launch, a quiet reminder until it's updated

    // MARK: 5c. [manual-restart] "I'll Restart Hermes Myself": the app installs, no chat opens, and the owner's restart finishes it

    @MainActor func test5c_OwnerRestartsHermesThemselves() throws {
        try account.control("/__fixture/push/reset", [:])
        try account.control("/__fixture/push", ["plugin": "missing", "manager": "restart"])
        launch()
        let go = updateSheetAsks()
        XCTAssertTrue(go.exists, "the setup offer shows")
        let choice = app.switches["addon-update.restart-choice"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "under Update: a switch for restarting Hermes yourself")
        XCTAssertEqual(choice.value as? String, "0", "off until asked for")
        attach("manual-restart-asking")
        tapSwitch("addon-update.restart-choice")
        XCTAssertTrue(waitUntil(timeout: 5) { (self.app.switches["addon-update.restart-choice"].value as? String) == "1" }, "the switch is on")
        attach("manual-restart-chosen")
        updateSheetAsks().tap()
        XCTAssertTrue(waitUntil(timeout: 40) { self.headline() == "Restart Hermes to Finish" }, "installed, the restart is the owner's: \(headline())")
        XCTAssertFalse(app.textViews["composer.text"].exists, "no chat opened: nothing goes to the bot")
        XCTAssertTrue(app.buttons["addon-update.ask-bot"].exists, "the bot can still be asked")
        let install = ((state()["manage"] as? [[String: Any]]) ?? []).first { ($0["action"] as? String) == "install" }
        XCTAssertEqual(install?["identifier"] as? String, "mrcharlesiv/hermes-hq-plugins/hermes-hq-push", "the app installed it itself")
        settleUpdateSheet()
        attach("manual-restart-waiting")
        try account.control("/__fixture/push", ["plugin": "ready"])   // the owner restarted Hermes
        XCTAssertTrue(waitUntil(timeout: 20) { self.headline().hasSuffix("Is On") || self.headline().hasSuffix("Are On") || self.headline() == "Add-on Set Up" },
                      "the restart is seen: \(headline())")
        XCTAssertFalse(app.textViews["composer.text"].exists, "still no chat")
        attach("manual-restart-done")
        app.terminate()

        // The choice is kept for this gateway: Settings › Notifications shows it, and its button no longer says "Ask".
        try account.control("/__fixture/push", ["plugin": "outdated", "manager": "restart"])
        launch(reset: false)
        openNotificationSettings()
        let picker = app.descendants(matching: .any)["notifications.restart-choice"]
        let list = app.collectionViews["notifications.list"]
        for _ in 0..<4 where !picker.exists { list.swipeUp() }
        XCTAssertTrue(picker.exists, "Settings has the choice")
        XCTAssertTrue(waitUntil(timeout: 10) { (self.app.switches["notifications.restart-choice"].value as? String) == "1" }, "kept from the sheet")
        XCTAssertTrue(waitUntil(timeout: 15) { self.app.buttons["notifications.ask-bot"].label == "Update the Add-on" },
                      "the button is the app's own: \(app.buttons["notifications.ask-bot"].label)")
        attach("manual-restart-settings")
        app.terminate()
    }

    @MainActor func test6_NotNowLeavesAQuietReminder() throws {
        try account.control("/__fixture/push", ["plugin": "outdated"])
        launch()
        let offer = updateSheetAsks()
        XCTAssertTrue(offer.exists, "an old add-on is offered an update")
        XCTAssertEqual(headline(), "Update the Add-on?")
        attach("reminder-1-launch-offer")
        closeUpdateSheet()   // Not Now

        // More counts it, and More's Settings row carries the red 1.
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(waitUntil(timeout: 10) { ((more.value as? String) ?? "").contains("Add-on update available") },
                      "More counts the reminder: \(String(describing: more.value))")
        attach("reminder-2-bots-with-more-count")
        more.tap()
        let settingsRow = app.cells["more-row-settings"]
        XCTAssertTrue(settingsRow.waitForExistence(timeout: 5))
        XCTAssertTrue(settingsRow.label.contains("Add-on update available"), settingsRow.label)
        attach("reminder-3-more-settings-badge")
        settingsRow.tap()
        let row = app.buttons["settings.addon-update"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the row at the top of Settings")
        XCTAssertTrue(row.label.contains("Add-on Update Available"), row.label)
        attach("reminder-4-settings-row")
        app.terminate()

        // The next launch: no alert for the same add-on level, and the reminder is there from the start.
        launch(reset: false)
        XCTAssertFalse(app.buttons["addon-update.go"].waitForExistence(timeout: 15), "Not Now holds until a build asks for more")
        XCTAssertTrue(waitUntil(timeout: 5) { ((more.value as? String) ?? "").contains("Add-on update available") }, "still counted")
        attach("reminder-5-next-launch-no-alert")

        // Its row offers the same update; the plugin manager installs it and the reminder goes.
        try account.control("/__fixture/push", ["manager": "reload"])
        more.tap()
        XCTAssertTrue(settingsRow.waitForExistence(timeout: 5))
        settingsRow.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let again = updateSheetAsks(timeout: 15)
        XCTAssertTrue(again.exists, "the row offers the update")
        attach("reminder-6-row-offers-update")
        again.tap()
        allowNotifications()
        XCTAssertFalse(app.textViews["composer.text"].exists, "no chat opened: every bot's copy is current, nothing to restart")
        XCTAssertTrue(waitUntil(timeout: 20) { !row.exists }, "updated: the row goes")
        XCTAssertTrue(waitUntil(timeout: 5) { !((more.value as? String) ?? "").contains("Add-on") }, "and More's count")
        XCTAssertTrue(headline().hasSuffix("Is On"), "the sheet says it's done: \(headline())")
        attach("reminder-7-updated")
    }

    // MARK: 6b. [addon-progress] The newest add-on out is older than the app asks for: said in the sheet, no restart,
    // and Settings' row says "not out yet" without the red count; once it's out, the row's update goes through

    @MainActor func test6b_UpdateNotOutYet() throws {
        try account.control("/__fixture/push", ["plugin": "outdated", "manager": "reload", "version": "0.9.31"])
        launch()
        updateSheetAsks().tap()
        XCTAssertTrue(waitUntil(timeout: 20) { self.headline().contains("Isn’t Out Yet") }, "said plainly: \(headline())")
        XCTAssertFalse(app.textViews["composer.text"].exists, "no restart asked: a restart can't bring a newer add-on")
        XCTAssertTrue(((state()["manage"] as? [[String: Any]]) ?? []).contains { ($0["action"] as? String) == "install" })
        attach("notout-1-sheet")
        closeUpdateSheet()

        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(waitUntil(timeout: 5) { !((more.value as? String) ?? "").contains("Add-on update available") },
                      "nothing to update to: no red count on More: \(String(describing: more.value))")
        more.tap()
        let settingsRow = app.cells["more-row-settings"]
        XCTAssertTrue(settingsRow.waitForExistence(timeout: 5))
        settingsRow.tap()
        let row = app.buttons["settings.addon-update"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Not Out Yet"), row.label)
        attach("notout-2-settings-row")

        // It comes out: the row checks again, and this time it goes in.
        try account.control("/__fixture/push", ["version": "0.9.47"])
        row.tap()
        let go = updateSheetAsks(timeout: 15)
        XCTAssertTrue(go.exists, "the row offers the update again")
        go.tap()
        allowNotifications()
        XCTAssertTrue(waitUntil(timeout: 20) { self.headline().hasSuffix("Is On") }, "updated: \(headline())")
        XCTAssertTrue(waitUntil(timeout: 10) { !row.exists }, "and the row goes")
        attach("notout-3-out-and-updated")
    }

    // MARK: 7. [addon-reminder] The same reminder in dark mode and in the Desktop Look (screenshots)

    @MainActor func test7_ReminderInEveryLook() throws {
        for (desktop, dark) in [(false, true), (true, false), (true, true)] {
            try account.control("/__fixture/push/reset", [:])
            try account.control("/__fixture/push", ["plugin": "outdated"])
            launch(extra: ["-HQDebugDesktopLook", desktop ? "YES" : "NO", "-hqn.appearance", dark ? "dark" : "light"])
            let name = (desktop ? "desktop" : "ios") + (dark ? "-dark" : "-light")
            XCTAssertTrue(updateSheetAsks().exists, "\(name): the offer")
            attach("look-\(name)-0-offer")
            closeUpdateSheet()
            let more = app.buttons["tab-more"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 10), "\(name): More")
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            attach("look-\(name)-1-tabs")
            more.tap()
            let settingsRow = app.cells["more-row-settings"]
            XCTAssertTrue(settingsRow.waitForExistence(timeout: 5), "\(name): More's Settings row")
            attach("look-\(name)-2-more")
            settingsRow.tap()
            XCTAssertTrue(app.buttons["settings.addon-update"].waitForExistence(timeout: 5), "\(name): the Settings row")
            attach("look-\(name)-3-settings")
            app.terminate()
        }
    }

    // MARK: 8. [device-access] Settings › Device Access: switches reach the add-on, a bot's lookup wakes the app and
    // comes back with only the shared details, in the foreground and from the background; all off stops sharing

    @MainActor func test8_DeviceAccessContacts() throws {
        try account.control("/__fixture/push", ["plugin": "ready"])
        try account.control("/__fixture/device/setup", [:])   // Contacts allowed, Ann Fixture added (before launch)
        launch(extra: ["-HQDebugResetDeviceAccess", "YES"])
        dismissSetupOffer()
        ensurePermission()   // the simulator takes a push only for an app allowed to notify
        openDeviceAccess()
        XCTAssertTrue(waitUntil(timeout: 10) { self.deviceGatewayLabel().contains("Ready") }, "the add-on takes it: \(deviceGatewayLabel())")
        attach("device-0-kinds")
        openDeviceKind("contacts")
        for field in ["phone", "email", "birthday", "address"] {
            XCTAssertEqual(app.switches["device-access.contacts.\(field)"].value as? String, "0", "\(field) starts off")
        }
        XCTAssertTrue(deviceShares().isEmpty, "nothing is told before anything is shared")
        attach("device-1-all-off")

        tapDeviceSwitch("device-access.contacts.phone")
        tapDeviceSwitch("device-access.contacts.email")
        XCTAssertTrue(waitUntil(timeout: 10) { self.sharedContacts() == ["phone": true, "email": true, "birthday": false, "address": false] },
                      "the add-on hears exactly what is on: \(deviceShares())")
        attach("device-2-phone-email")

        // A bot asks for more than is shared, with the app on screen: the wake-up push runs it at once.
        let first = try XCTUnwrap(try account.control("/__fixture/device", ["op": "contacts.search", "wake": true,
            "args": ["query": "Ann Fixture", "fields": ["phone", "email", "birthday"]]])["id"] as? String)
        XCTAssertTrue(waitUntil(timeout: 20) { self.deviceRequest(first)["status"] as? String == "done" }, "answered: \(deviceRequest(first))")
        let person = try XCTUnwrap(((deviceRequest(first)["result"] as? [String: Any])?["contacts"] as? [[String: Any]])?.first)
        XCTAssertEqual(person["name"] as? String, "Ann Fixture")
        XCTAssertEqual(person["organization"] as? String, "Fixture Works")
        XCTAssertNotNil(person["phones"], "phone numbers are shared")
        XCTAssertNotNil(person["emails"], "email addresses are shared")
        XCTAssertNil(person["birthday"], "a birthday was asked but isn't shared")
        XCTAssertNil(person["addresses"], "addresses weren't asked and aren't shared")

        // From the background (iOS gives a silent push a short time): the same, woken.
        goHome()
        let second = try XCTUnwrap(try account.control("/__fixture/device", ["op": "contacts.search", "wake": true,
            "args": ["query": "ann@fixture.example"]])["id"] as? String)
        if waitUntil(timeout: 30, { self.deviceRequest(second)["status"] as? String == "done" }) {
            let found = ((deviceRequest(second)["result"] as? [String: Any])?["contacts"] as? [[String: Any]]) ?? []
            XCTAssertEqual(found.first?["name"] as? String, "Ann Fixture", "found by email from the background")
        } else {
            // The simulator may hold a background push back, as iOS can: then the next open answers it.
            app.activate()
            XCTAssertTrue(waitUntil(timeout: 20) { self.deviceRequest(second)["status"] as? String == "done" },
                          "answered once the app is back on screen: \(deviceRequest(second))")
        }
        if app.state != .runningForeground { app.activate() }

        // A request for something unknown is refused by the phone itself.
        let unknown = try XCTUnwrap(try account.control("/__fixture/device", ["op": "photos.list", "wake": true, "args": [:]])["id"] as? String)
        XCTAssertTrue(waitUntil(timeout: 20) { self.deviceRequest(unknown)["status"] as? String == "unavailable" }, "\(deviceRequest(unknown))")

        // Everything off: the gateway is told to stop asking.
        XCTAssertTrue(app.collectionViews["device-access.contacts.list"].waitForExistence(timeout: 10), "still on Contacts")
        tapDeviceSwitch("device-access.contacts.phone")
        tapDeviceSwitch("device-access.contacts.email")
        XCTAssertTrue(waitUntil(timeout: 10) { self.deviceShares().isEmpty && !self.deviceForgotten().isEmpty }, "all off stops sharing")
        attach("device-3-all-off-again")
    }

    // MARK: 9. [device-access] The pages in every look (screenshots): the kinds, Contacts, Location and Recent Requests

    @MainActor func test9_DeviceAccessInEveryLook() throws {
        try account.control("/__fixture/push", ["plugin": "ready"])
        try account.control("/__fixture/device/setup", ["grants": ["location-always"]])
        for (desktop, dark) in [(false, false), (false, true), (true, false), (true, true)] {
            let look = (desktop ? "desktop" : "ios") + (dark ? "-dark" : "-light")
            launch(extra: ["-HQDebugResetDeviceAccess", "YES", "-HQDebugDesktopLook", desktop ? "YES" : "NO",
                           "-hqn.appearance", dark ? "dark" : "light"])
            dismissSetupOffer()
            openDeviceAccess()
            openDeviceKind("contacts")
            tapDeviceSwitch("device-access.contacts.phone")
            tapDeviceSwitch("device-access.contacts.birthday")
            attach("device-look-contacts-" + look)
            backToDeviceAccess()
            openDeviceKind("location")
            tapDeviceRow("device-access.location.city")
            attach("device-look-location-" + look)
            backToDeviceAccess()
            XCTAssertTrue(waitUntil(timeout: 10) { self.deviceGatewayLabel().contains("On") }, "\(deviceGatewayLabel())")
            attach("device-look-kinds-" + look)
            let recent = app.descendants(matching: .any)["device-access.recent"]
            XCTAssertTrue(recent.waitForExistence(timeout: 5))
            recent.tap()
            XCTAssertTrue(app.descendants(matching: .any)["device-access.recent.empty"].waitForExistence(timeout: 5), "no requests yet")
            attach("device-look-recent-" + look)
            app.terminate()
        }
    }

    // MARK: 10. [device-access] Every other kind the Simulator has: reminders, calendar, location, photos, alarms and
    // drafts, each switched on in its own page, asked by a bot and answered within the switches; Recent Requests lists them

    @MainActor func test10_DeviceAccessKinds() throws {
        try account.control("/__fixture/push", ["plugin": "ready"])
        try account.control("/__fixture/device/setup", ["grants": ["reminders", "calendar", "photos", "location-always"],
                                                         "location": "41.8781,-87.6298", "photo": true])
        launch(extra: ["-HQDebugResetDeviceAccess", "YES"])
        dismissSetupOffer()
        ensurePermission()
        openDeviceAccess()
        XCTAssertTrue(waitUntil(timeout: 10) { self.deviceGatewayLabel().contains("Ready") }, "0.9.21 takes every kind: \(deviceGatewayLabel())")

        openDeviceKind("reminders")
        tapDeviceSwitch("device-access.reminders.read")
        tapDeviceSwitch("device-access.reminders.write")
        attach("kinds-1-reminders")
        backToDeviceAccess()
        openDeviceKind("calendar")
        tapDeviceSwitch("device-access.calendar.read")
        tapDeviceSwitch("device-access.calendar.write")
        backToDeviceAccess()
        openDeviceKind("location")
        tapDeviceRow("device-access.location.city")
        attach("kinds-2-location-city")
        backToDeviceAccess()
        openDeviceKind("photos")
        tapDeviceSwitch("device-access.photos.find")
        tapDeviceSwitch("device-access.photos.send")
        backToDeviceAccess()
        openDeviceKind("drafts")
        tapDeviceSwitch("device-access.drafts.email")
        backToDeviceAccess()
        openDeviceKind("alarms")
        tapDeviceSwitch("device-access.alarms.set")
        allowSystemAlert()
        let alarmsOn = waitUntil(timeout: 5) { self.app.switches["device-access.alarms.set"].value as? String == "1" }
        attach("kinds-3-alarms")
        backToDeviceAccess()
        XCTAssertTrue(waitUntil(timeout: 10) {
            let access = self.deviceShares().values.first?["access"] as? [String: [String: Bool]] ?? [:]
            return access["reminders"] == ["read": true, "write": true] && access["calendar"] == ["read": true, "write": true]
                && access["location"] == ["city": true, "address": false, "exact": false, "locked": false]
                && access["photos"] == ["find": true, "send": true] && access["drafts"] == ["email": true, "text": false]
        }, "the add-on hears each kind's switches: \(deviceShares())")
        attach("kinds-4-root")

        // Reminders: add one, tick it off, find it.
        let added = try ask("reminders.create", ["title": "Fixture milk", "due": "2026-11-02T09:00", "priority": "high"])
        let reminder = try XCTUnwrap(result(added)["reminder"] as? [String: Any], "\(added)")
        XCTAssertEqual(reminder["title"] as? String, "Fixture milk")
        XCTAssertEqual(reminder["priority"] as? String, "high")
        let reminderId = try XCTUnwrap(reminder["id"] as? String)
        let ticked = try ask("reminders.update", ["id": reminderId, "completed": true])
        XCTAssertEqual((result(ticked)["reminder"] as? [String: Any])?["completed"] as? Bool, true, "\(ticked)")
        let listed = try ask("reminders.list", ["search": "Fixture milk", "include_completed": true])
        XCTAssertGreaterThanOrEqual(result(listed)["count"] as? Int ?? 0, 1, "\(listed)")

        // Calendar: add an event and find it.
        let event = try ask("calendar.create", ["title": "Fixture lunch", "start": "2026-11-02T12:00", "location": "Fixture Café"])
        XCTAssertEqual((result(event)["event"] as? [String: Any])?["title"] as? String, "Fixture lunch", "\(event)")
        let events = try ask("calendar.list", ["start": "2026-11-02", "end": "2026-11-03", "search": "Fixture lunch"])
        XCTAssertGreaterThanOrEqual(result(events)["count"] as? Int ?? 0, 1, "\(events)")

        // Location: exact asked, City shared: the city, never coordinates.
        let place = try ask("location.get", ["precision": "exact"])
        XCTAssertEqual(place["status"] as? String, "done", "\(place)")
        XCTAssertEqual(result(place)["precision"] as? String, "city")
        XCTAssertNil(result(place)["coordinates"], "City shared: no coordinates")
        XCTAssertNil((result(place)["place"] as? [String: Any])?["address"], "City shared: no street")

        // Photos: find the invented photo, then fetch it: the JPEG goes up before the answer.
        let photos = try ask("photos.search", ["limit": 5])
        let photo = try XCTUnwrap((result(photos)["photos"] as? [[String: Any]])?.first, "\(photos)")
        let fetched = try ask("photos.get", ["id": photo["id"] as? String ?? "", "max_pixels": 400])
        XCTAssertEqual(fetched["status"] as? String, "done", "\(fetched)")
        let file = try XCTUnwrap(fetched["file"] as? [String: Any], "the photo came up as a file")
        XCTAssertEqual(file["type"] as? String, "image/jpeg")
        XCTAssertEqual(file["jpeg"] as? Bool, true)
        XCTAssertGreaterThan(file["bytes"] as? Int ?? 0, 100)

        // Drafts: an email waits on the phone; a text isn't shared, and the phone says so.
        let email = try ask("drafts.create", ["kind": "email", "to": ["ann@fixture.example"], "subject": "Fixture", "body": "Hello from the fixture"])
        XCTAssertEqual(result(email)["draft"] as? String, "waiting", "\(email)")
        let text = try ask("drafts.create", ["kind": "text", "to": ["+1 555 0100"], "body": "Hi"])
        XCTAssertEqual(text["status"] as? String, "unavailable", "\(text)")

        // Alarms & Timers (AlarmKit asks on the Simulator too): a timer, listed, then cancelled.
        if alarmsOn {
            let timer = try ask("alarms.timer", ["seconds": 600, "label": "Fixture tea"])
            let timerId = try XCTUnwrap((result(timer)["timer"] as? [String: Any])?["id"] as? String, "\(timer)")
            let alarms = try ask("alarms.list", [:])
            XCTAssertTrue((result(alarms)["alarms"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == timerId }, "\(alarms)")
            let cancelled = try ask("alarms.cancel", ["id": timerId])
            XCTAssertEqual(result(cancelled)["cancelled"] as? String, timerId, "\(cancelled)")
        } else {
            attach("kinds-alarms-not-allowed")
        }

        // Recent Requests lists what bots asked (newest first), with the asking bot.
        let recent = app.descendants(matching: .any)["device-access.recent"]
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        recent.tap()
        XCTAssertTrue(app.collectionViews["device-access.recent.list"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "finance")).firstMatch.waitForExistence(timeout: 5),
                      "a row names the bot that asked")
        attach("kinds-5-recent")

        // The email draft waits on the Drafts page until it's sent or deleted.
        backToDeviceAccess()
        openDeviceKind("drafts")
        let waiting = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "device-access.draft.")).firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 5), "the email draft is listed under Waiting for You")
        XCTAssertTrue(waiting.label.contains("ann@fixture.example"), waiting.label)
        attach("kinds-6-drafts-waiting")
    }

    /// One bot request through the fixture (the app on screen: the wake-up runs it at once); the request when it ends.
    @MainActor private func ask(_ op: String, _ args: [String: Any]) throws -> [String: Any] {
        let id = try XCTUnwrap(try account.control("/__fixture/device", ["op": op, "args": args, "wake": true, "profile": "finance"])["id"] as? String)
        XCTAssertTrue(waitUntil(timeout: 25) { (self.deviceRequest(id)["status"] as? String ?? "pending") != "pending" }, "\(op) answered")
        return deviceRequest(id)
    }

    private func result(_ request: [String: Any]) -> [String: Any] { request["result"] as? [String: Any] ?? [:] }

    @MainActor private func openDeviceKind(_ kind: String) {
        let row = app.descendants(matching: .any)["device-access.kind.\(kind)"]
        let list = app.collectionViews["device-access.list"]
        for _ in 0..<4 where !row.isHittable { list.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Device Access lists \(kind)")
        row.tap()
        XCTAssertTrue(app.collectionViews["device-access.\(kind).list"].waitForExistence(timeout: 5), "\(kind) opens")
    }

    @MainActor private func backToDeviceAccess() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.collectionViews["device-access.list"].waitForExistence(timeout: 5), "back on Device Access")
    }

    @MainActor private func tapDeviceRow(_ id: String) {
        let row = app.descendants(matching: .any)[id]
        XCTAssertTrue(row.waitForExistence(timeout: 5), id)
        row.tap()
        allowDeviceAccessConsent()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    }

    /// The first switch of a kind asks "Share … With Your Bots?" before iOS's own permission does
    /// (App/DeviceAccess/DeviceAccessSettingsView.swift); Allow, so the rest of the flow runs as before.
    @MainActor private func allowDeviceAccessConsent() {
        let alert = app.alerts["device-access.consent"]
        guard alert.waitForExistence(timeout: 1) else { return }
        alert.buttons["Allow"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    /// iOS's own permission alert (AlarmKit's has no simctl grant): Allow when it shows.
    @MainActor private func allowSystemAlert() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 5) else { return }
        for title in ["Allow", "OK", "Continue"] where alert.buttons[title].exists {
            alert.buttons[title].tap()
            break
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    @MainActor private func openDeviceAccess() {
        let more = app.tabBars.buttons["More"].exists ? app.tabBars.buttons["More"] : app.buttons["tab-more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        let settingsRow = app.cells["more-row-settings"]
        for _ in 0..<4 {
            more.tap()
            if settingsRow.waitForExistence(timeout: 2), settingsRow.isHittable { break }
        }
        for _ in 0..<3 {
            settingsRow.tap()
            if app.buttons["settings.gateway-card"].waitForExistence(timeout: 3) { break }
        }
        let row = app.buttons["settings.device-access"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Settings has Device Access")
        row.tap()
        XCTAssertTrue(app.collectionViews["device-access.list"].waitForExistence(timeout: 5), "Settings › Device Access opens")
    }

    @MainActor private func tapDeviceSwitch(_ id: String) {
        let toggle = app.switches[id]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), id)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        allowDeviceAccessConsent()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    }

    @MainActor private func deviceGatewayLabel() -> String {
        let row = app.descendants(matching: .any)["device-access.gateway"]
        return row.exists ? row.label : ""
    }

    private func deviceState() -> [String: Any] { (try? account.control("/__fixture/device")) ?? [:] }
    private func deviceShares() -> [String: [String: Any]] { deviceState()["shares"] as? [String: [String: Any]] ?? [:] }
    private func deviceForgotten() -> [String] { deviceState()["forgotten"] as? [String] ?? [] }
    private func sharedContacts() -> [String: Bool] {
        (deviceShares().values.first?["access"] as? [String: Any])?["contacts"] as? [String: Bool] ?? [:]
    }
    private func deviceRequest(_ id: String) -> [String: Any] {
        (deviceState()["requests"] as? [String: [String: Any]])?[id] ?? [:]
    }

    /// `reset`: false keeps the sign-in and what the app remembers (a second launch of the same install).
    @MainActor private func launch(reset: Bool = true, extra: [String] = []) {
        let app = XCUIApplication()
        app.launchArguments = (reset ? ["-HQDebugResetAccounts", "YES", "-HQDebugResetNotificationPrefs", "YES"] : [])
            + ["-HQDebugPushAnyTopic", "YES", "-HQDebugPeekHold", "YES"] + extra
        app.launchEnvironment = ["HQN_SIGNIN_URL": account.url, "HQN_SIGNIN_USERNAME": account.username,
                                 "HQN_SIGNIN_PASSWORD": account.password, "HQN_APNS_TOKEN": String(repeating: "ab", count: 32)]
        app.launch()
        self.app = app
        // A second launch reopens on the tab it was left on; a clean one starts on Bots.
        if reset { XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 20), "signed in: the Bots list shows") }
        else { XCTAssertTrue(app.tabBars.buttons["More"].waitForExistence(timeout: 20), "signed in: the tabs show") }
    }

    /// The launch-time setup offer may come (plugin missing) or not; close it if it does.
    @MainActor private func dismissSetupOffer() {
        if app.buttons["addon-update.go"].waitForExistence(timeout: 4) { closeUpdateSheet() }
    }

    /// [addon-progress] The update sheet's Update / Set Up (the offer at launch, or Settings' row).
    @MainActor private func updateSheetAsks(timeout: TimeInterval = 40) -> XCUIElement {
        let go = app.buttons["addon-update.go"]
        guard go.waitForExistence(timeout: timeout) else { return go }
        settleUpdateSheet()
        return go
    }

    @MainActor private func headline() -> String {
        let text = app.staticTexts["addon-update.headline"]
        return text.exists ? text.label : ""
    }

    /// [addon-sheet-button] The sheet can still change height as it settles (the button stays pinned at the bottom);
    /// a tap while it moves is lost, so wait until its top (the ✕) has stayed put.
    @MainActor private func settleUpdateSheet() {
        let close = app.buttons["addon-update.close"]
        guard close.waitForExistence(timeout: 5) else { return }
        var last = close.frame, still = 0
        _ = waitUntil(timeout: 8) {
            let now = close.frame
            still = now == last ? still + 1 : 0
            last = now
            return still >= 4   // a second (four 0.25 s looks) without moving
        }
    }

    /// The sheet's ✕ (Not Now, Hide or Done); waits for it to go.
    @MainActor private func closeUpdateSheet() {
        let close = app.buttons["addon-update.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the update sheet's ✕")
        settleUpdateSheet()
        close.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !close.exists }, "the sheet closes")
    }

    @MainActor private func openBot(_ id: String) {
        let row = app.cells["bot-row-\(id)"].exists ? app.cells["bot-row-\(id)"] : app.cells["bot-tile-\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the \(id) bot is listed")
        row.tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 10), "the chat opens")
    }

    @MainActor private func send(_ text: String) {
        let field = app.textViews["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
        let attempts = { ((try? self.account.control("/__fixture/state"))?["promptAttempts"] as? Int) ?? 0 }
        let before = attempts()
        let button = app.buttons["composer.send"]
        button.tap()
        // As the chat e2e does: a tap the keyboard's suggestion bar swallowed is tapped again.
        if !waitUntil(timeout: 3, { attempts() > before }) { button.tap() }
        XCTAssertTrue(waitUntil(timeout: 8) { attempts() > before }, "the prompt went out")
    }

    @MainActor private func chatTitle() -> String {
        let title = app.descendants(matching: .any)["chat.title"]
        return title.exists ? title.label : ""
    }

    @MainActor private func openNotificationSettings() {
        // More › Settings (the Bots bar has no Settings button, as on the web). A second tap on More pops a page left open.
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        let settingsRow = app.cells["more-row-settings"]
        for _ in 0..<4 {
            more.tap()
            if settingsRow.waitForExistence(timeout: 2), settingsRow.isHittable { break }
        }
        for _ in 0..<3 {
            settingsRow.tap()
            if app.buttons["settings.gateway-card"].waitForExistence(timeout: 3) { break }
        }
        let row = app.buttons["settings.notifications"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.collectionViews["notifications.list"].waitForExistence(timeout: 5), "Settings › Notifications opens")
    }

    /// The "While the App Is Closed" value (the list draws rows lazily: it scrolls down to it first).
    @MainActor private func pushRowLabel() -> String {
        let row = app.descendants(matching: .any)["notifications.push"]
        let list = app.collectionViews["notifications.list"]
        if !row.exists, list.exists { list.swipeUp() }
        return row.exists ? row.label : ""
    }

    /// Home, then wait until the app is really in the background (an alert delivered before that is the peek).
    @MainActor private func goHome() {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(waitUntil(timeout: 10) { self.app.state == .runningBackground || self.app.state == .runningBackgroundSuspended },
                      "the app went to the background")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    @MainActor private func tapSwitch(_ id: String) {
        let toggle = app.switches[id]
        let list = app.collectionViews["notifications.list"]
        // Lazy rows: look up the list first, then down.
        for _ in 0..<4 where !(toggle.exists && toggle.isHittable) { list.swipeDown() }
        for _ in 0..<4 where !(toggle.exists && toggle.isHittable) { list.swipeUp() }
        // SwiftUI toggles flip from their switch, at the trailing edge.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    }

    /// iOS's notification prompt: Allow.
    @MainActor private func allowNotifications() {
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }
    }

    /// Permission for this app (a fresh simulator asks once): Settings › Notifications › Send Test asks.
    @MainActor private func ensurePermission() {
        openNotificationSettings()
        let list = app.collectionViews["notifications.list"]
        for _ in 0..<4 where !app.buttons["notifications.test"].isHittable { list.swipeUp() }
        app.buttons["notifications.test"].tap()
        allowNotifications()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        app.navigationBars.buttons.element(boundBy: 0).tap()                 // back to Settings
        let close = app.buttons["settings.close"]
        if close.waitForExistence(timeout: 1) { close.tap() } else { app.tabBars.buttons["Bots"].tap() }
    }

    @MainActor private func banner(containing text: String) -> XCUIElement {
        springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    @MainActor private func tapBanner(containing text: String) {
        let element = banner(containing: text)
        XCTAssertTrue(element.waitForExistence(timeout: 15), "the alert shows: \(text)")
        attach("banner")
        element.tap()
    }

    private func state() -> [String: Any] { (try? account.control("/__fixture/push")) ?? [:] }
    private func devices() -> [[String: Any]] { ((state()["devices"] as? [String: [String: Any]]) ?? [:]).map(\.value) }
    private func removed() -> [String] { (state()["removed"] as? [String]) ?? [] }
    @MainActor private func chatShows(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }
    private func approvals() -> [[String: Any]] { (state()["approvals"] as? [[String: Any]]) ?? [] }

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
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }
}
