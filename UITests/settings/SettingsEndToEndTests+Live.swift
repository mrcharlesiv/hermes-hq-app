// [live] Settings › Notifications › Show Progress on Lock Screen, and a long turn's Live Activity, end to end against the
// settings fixture (POST /__settings/turn makes a reply's turn run long). The app's "debug.live" probe
// (`-HQDebugLiveProbe YES`) says what is on show. Two builds:
//   HQ_ORIGINAL=YES TEST_RUNNER_HQN_LIVE=1 HQN_E2E_ONLY="testLA1_…" scripts/e2e-settings.sh <SIM>   the widget extension is in
//   HQN_E2E_ONLY="testLA1_…" scripts/e2e-settings.sh <SIM>                                       a shipping-like (native identity) build
// The widget extension is HermesHQTalkActivity (shared with Talk's own Live Activity, docs/spec/3x-talk-background.md):
// the original identity is what carries it, same as Talk — no HQ_LIVE_ACTIVITY flag of this feature's own.
// Without it the switch must not show and leaving the app must start nothing.
// Screens: live-settings-<look>-<appearance>-<size>.png, live-turn-island.png, live-turn-lock.png and (the widget build)
// live-turn-lock-later.png, live-turn-island-later.png, live-turn-island-expanded.png: the card naming the fixture's
// steps (in HQN_SHOTS).

import XCTest

extension SettingsEndToEndTests {
    var liveBuild: Bool { ProcessInfo.processInfo.environment["HQN_LIVE"] == "1" }

    // MARK: - LA1 The switch: on by default, kept across a relaunch, in both looks, light and dark, at Extra Large

    @MainActor func testLA1_ShowProgressOnLockScreenSwitch() throws {
        let looks: [(name: String, arguments: [String])] = [("ios", []), ("desktop", ["-HQDebugDesktopLook", "YES"])]
        let sizes: [(name: String, arguments: [String])] = [
            ("default", []), ("xl", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXL"]),
        ]
        var first = true
        for look in looks {
            for dark in [false, true] {
                for size in sizes {
                    let appearance = dark ? "dark" : "light"
                    let app = launchSignedIn(["-hqn.appearance", appearance, "-HQDebugLiveReset", "YES"] + look.arguments + size.arguments)
                    openNotifications(app)
                    let toggle = app.switches["notifications.live-activities"]
                    let list = app.collectionViews["notifications.list"]
                    if !liveBuild {
                        for _ in 0..<5 { list.swipeUp() }
                        XCTAssertFalse(toggle.exists, "no switch in a build without the widget extension")
                        XCTAssertFalse(app.staticTexts[SettingsLiveWords.label].exists)
                        shot(app, "live-settings-absent-\(look.name)-\(size.name)")
                        app.terminate()
                        return
                    }
                    reveal(toggle, in: list)
                    XCTAssertTrue(toggle.exists, "the switch shows (\(look.name), \(appearance), \(size.name))")
                    XCTAssertEqual(toggle.value as? String, "1", "on by default")
                    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", SettingsLiveWords.footer)).firstMatch.exists,
                                  "the footer says what it does, and that Talk's own controls aren't affected")
                    named(app, "live-settings-\(look.name)-\(appearance)-\(size.name)")
                    if first {
                        first = false
                        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
                        XCTAssertTrue(waitUntil(timeout: 3) { toggle.value as? String == "0" }, "off")
                        app.terminate()
                        // Signed in afresh (a reset of the accounts, not of this switch): the switch is kept.
                        let again = launchSignedIn(["-hqn.appearance", appearance])
                        openNotifications(again)
                        let kept = again.switches["notifications.live-activities"]
                        reveal(kept, in: again.collectionViews["notifications.list"])
                        XCTAssertEqual(kept.value as? String, "0", "off is kept across a relaunch")
                        kept.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
                        XCTAssertTrue(waitUntil(timeout: 3) { kept.value as? String == "1" }, "back on")
                        again.terminate()
                    } else {
                        app.terminate()
                    }
                }
            }
        }
    }

    // MARK: - LA2 A long turn: on the Lock Screen once the app is left, Done when the reply comes

    @MainActor func testLA2_LongTurnShowsWhileTheAppIsAway() throws {
        try a.control("/__settings/turn", ["seconds": 30])
        let app = launchSignedIn(["-HQDebugLiveProbe", "YES", "-HQDebugLiveThreshold", "3", "-HQDebugLiveReset", "YES"])
        let probe = app.descendants(matching: .any)["debug.live"]
        talk(app, to: "ivy", "Please take your time.")
        Thread.sleep(forTimeInterval: 5)   // past the (shortened) threshold, while the turn still runs
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(XCUIApplication(bundleIdentifier: "com.apple.springboard").wait(for: .runningForeground, timeout: 5))
        Thread.sleep(forTimeInterval: 2)
        LiveGlance.look(lock: { springShot("live-turn-lock") }, island: { springShot("live-turn-island") })
        if liveBuild {
            // [live-steps] Still away, a few steps later: the card moved on to the step the bot is on now.
            Thread.sleep(forTimeInterval: 6)
            LiveGlance.look(lock: { springShot("live-turn-lock-later") }, island: { springShot("live-turn-island-later") })
            // Held, the island opens to its expanded view: the step and the one before it.
            XCUIApplication(bundleIdentifier: "com.apple.springboard").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.035))
                .press(forDuration: 1.0)
            Thread.sleep(forTimeInterval: 1)
            springShot("live-turn-island-expanded")
            XCUIDevice.shared.press(.home)
        }
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        if liveBuild {
            XCTAssertTrue(waitUntil(timeout: 5) { (probe.value as? String)?.contains("turn:ivy=working") == true || probe.label == "turn:ivy=done" },
                          "the long turn went on the Lock Screen (\(probe.value ?? "-"), \(probe.label))")
            XCTAssertTrue(waitUntil(timeout: 40) { probe.label == "turn:ivy=done" && probe.value as? String == "none" },
                          "it ends Done with the reply (\(probe.value ?? "-"), \(probe.label))")
        } else {
            XCTAssertTrue(!probe.exists || (probe.value as? String) == "none", "nothing starts without the extension")
        }
    }

    // MARK: - LA3 Off: a long turn starts nothing

    @MainActor func testLA3_OffStartsNothing() throws {
        try XCTSkipUnless(liveBuild, "only a build with the widget extension has the switch (testLA2 checks the other build)")
        try a.control("/__settings/turn", ["seconds": 20])
        let app = launchSignedIn(["-HQDebugLiveProbe", "YES", "-HQDebugLiveThreshold", "3", "-HQDebugLiveReset", "YES"])
        openNotifications(app)
        let toggle = app.switches["notifications.live-activities"]
        reveal(toggle, in: app.collectionViews["notifications.list"])
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(waitUntil(timeout: 3) { toggle.value as? String == "0" }, "off")
        closeSettings(app)
        let probe = app.descendants(matching: .any)["debug.live"]
        talk(app, to: "ivy", "Slowly, please.")
        Thread.sleep(forTimeInterval: 5)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        springShot("live-turn-off")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(!probe.exists || probe.value as? String == "none", "off: nothing on the Lock Screen (\(probe.value ?? "-"))")
        XCTAssertTrue(!probe.exists || probe.label.isEmpty, "and nothing ended either (\(probe.label))")
        // The next test launches with -HQDebugLiveReset, which puts the switch back on.
        app.terminate()
    }

    // MARK: - LA4 A card that is over goes once the app is opened again

    /// Owner, 2026-11-01: a new message to Hermes, the phone locked at once, and the card "just said done": the reply
    /// before's, which ended while the app was away and lingered on after the app was opened.
    @MainActor func testLA4_ADoneCardGoesWhenTheAppIsOpenedAgain() throws {
        try XCTSkipUnless(liveBuild, "only a build with the widget extension shows cards")
        try a.control("/__settings/turn", ["seconds": 12])
        let app = launchSignedIn(["-HQDebugLiveProbe", "YES", "-HQDebugLiveThreshold", "3", "-HQDebugLiveReset", "YES"])
        let probe = app.descendants(matching: .any)["debug.live"]
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let done = springboard.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Done"))
        talk(app, to: "ivy", "Not long, please.")
        Thread.sleep(forTimeInterval: 5)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 14)   // the reply ends while the app is away (its socket's grace): Done, to linger
        var doneAway = false
        LiveGlance.look(lock: { springShot("live-done-away"); doneAway = done.count > 0 }, island: {})
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 5) { probe.label == "turn:ivy=done" }, "the card ended Done while away (\(probe.label))")
        Thread.sleep(forTimeInterval: 2)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        var doneBack = true
        LiveGlance.look(lock: { springShot("live-done-cleared"); doneBack = done.count > 0 }, island: {})
        if doneAway { XCTAssertFalse(doneBack, "opening the app took the Done card away") }
        print("live-done: Done on the Lock Screen away \(doneAway), after a return \(doneBack)")
    }

    // MARK: - LA5 A side chat's reply gets its own card

    /// [live-chats] A tester, 2026-11-05: a reply in a chat started from Sessions never showed on the Lock Screen;
    /// only a bot's Bot Chat had a card. A New Chat's long reply now gets one, under its own subject ("ivy/<id>").
    @MainActor func testLA5_ASideChatsReplyGetsItsOwnCard() throws {
        try a.control("/__settings/turn", ["seconds": 30])
        let app = launchSignedIn(["-HQDebugLiveProbe", "YES", "-HQDebugLiveThreshold", "3", "-HQDebugLiveReset", "YES"])
        let probe = app.descendants(matching: .any)["debug.live"]
        pressMenu(app, app.cells["bot-row-ivy"], "New Chat")
        XCTAssertTrue(waitUntil(timeout: 10) { self.a.writes("session.create").contains { same($0["profile"], "ivy") } }, "a New Chat for Ivy")
        let field = app.textViews["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 8), "the new chat opens")
        field.tap()
        field.typeText("Check the day, slowly.")
        app.buttons["composer.send"].tap()
        Thread.sleep(forTimeInterval: 5)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(XCUIApplication(bundleIdentifier: "com.apple.springboard").wait(for: .runningForeground, timeout: 5))
        Thread.sleep(forTimeInterval: 2)
        LiveGlance.look(lock: { springShot("live-side-chat-lock") }, island: { springShot("live-side-chat-island") })
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        if liveBuild {
            XCTAssertTrue(waitUntil(timeout: 5) {
                let value = probe.value as? String ?? ""
                return value.contains("turn:ivy/") && value.contains("=working") || probe.label.hasPrefix("turn:ivy/")
            }, "the side chat's reply went on the Lock Screen under its own subject (\(probe.value ?? "-"), \(probe.label))")
            XCTAssertFalse((probe.value as? String ?? "").contains("turn:ivy="), "Ivy's Bot Chat isn't working: no card of its own")
            XCTAssertTrue(waitUntil(timeout: 40) { probe.label.hasPrefix("turn:ivy/") && probe.label.hasSuffix("=done") && probe.value as? String == "none" },
                          "it ends Done with the reply (\(probe.value ?? "-"), \(probe.label))")
        } else {
            XCTAssertTrue(!probe.exists || (probe.value as? String) == "none", "nothing starts without the extension")
        }
    }

    // MARK: - LA6 A long chat title leaves the timer whole

    /// Owner's iPad, 2026-11-05: "Orchestrator · Update herm…  8 steps  6:4" — the side chat's long title pushed the
    /// timer off the card's edge. The title gives way now; the shots show the whole timer.
    @MainActor func testLA6_ALongChatTitleLeavesTheTimerWhole() throws {
        try XCTSkipUnless(liveBuild, "only a build with the widget extension shows cards")
        try a.control("/__settings/turn", ["seconds": 30])
        // The fixture numbers a bot's extra chats in order; this one is the last.
        let made = try a.control("/__settings/chats", ["profile": "ivy", "titles": ["Update hermes plugins and validate every scanner rule"]])
        let app = launchSignedIn(["-HQDebugLiveProbe", "YES", "-HQDebugLiveThreshold", "3", "-HQDebugLiveReset", "YES"])
        XCTAssertTrue(app.cells["bot-row-ivy"].waitForExistence(timeout: 15))
        app.tabButton(id: "tab-sessions", label: "Sessions").tap()
        let n = String(format: "%02d", ((made["chats"] as? [String])?.count ?? 1) - 1)
        let row = app.cells["session-row-20261104_0900\(n)_ddeeff\(n)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Sessions lists the long-titled chat")
        row.tap()
        let field = app.textViews["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the titled chat opens")
        field.tap()
        field.typeText("Take your time.")
        app.buttons["composer.send"].tap()
        Thread.sleep(forTimeInterval: 12)   // a few steps in, so the step count shows beside the title
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        LiveGlance.look(lock: { springShot("live-long-title-lock") }, island: {})
    }

    // MARK: - Helpers

    @MainActor func openNotifications(_ app: XCUIApplication) {
        openSettings(app)
        let row = app.buttons["settings.notifications"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.collectionViews["notifications.list"].waitForExistence(timeout: 5), "Settings › Notifications opens")
    }

    /// Lazy rows: down the list until the element is on screen.
    @MainActor func reveal(_ element: XCUIElement, in list: XCUIElement) {
        for _ in 0..<6 where !(element.exists && element.isHittable) { list.swipeUp() }
        Thread.sleep(forTimeInterval: 0.4)
    }

    /// A screenshot under its own name (the run's light or dark suffix doesn't apply: the name says it).
    @MainActor func named(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.6)
        save(app.screenshot(), name)
    }

    /// The whole screen (the Home Screen, its Dynamic Island, Notification Center).
    @MainActor func springShot(_ name: String) { save(XCUIScreen.main.screenshot(), name) }

    @MainActor private func save(_ screenshot: XCUIScreenshot, _ name: String) {
        if let dir = ProcessInfo.processInfo.environment["HQN_SHOTS"], !dir.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// [live] The Lock Screen and the Dynamic Island as a person sees them, from the Home Screen. Pulls Notification Center
/// down (it lists Live Activities as the Lock Screen does), says Allow when iOS asks "Allow Live Activities from …?"
/// (on the app's first activity, and again later; the prompt covers half the card), then goes back to the Home
/// Screen, where a running one sits in the Dynamic Island. Leaves the Home Screen showing.
@MainActor enum LiveGlance {
    static func look(lock: () -> Void, island: () -> Void) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.005))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.7)))
        // The first ask says Allow; a later one asks again whether to "continue to allow" (Always Allow).
        let allow = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "Always Allow"])).firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        Thread.sleep(forTimeInterval: 2)
        lock()
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        Thread.sleep(forTimeInterval: 2)
        island()
    }
}

/// The words the app shows (App/Notifications/NotificationsSettingsView.swift, HermesKit/Live/LiveActivityRules.swift).
enum SettingsLiveWords {
    static let label = "Show Progress on Lock Screen"
    static let footer = "A bot’s reply that’s still going when you leave the app, or a job you run from Jobs, shows on the Lock Screen and in the Dynamic Island with how long it has run, until it’s done. A reply also names the step its bot is on. Your voice chat’s own Lock Screen controls aren’t affected."
}
