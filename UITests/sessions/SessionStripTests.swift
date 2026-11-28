import CryptoKit
import XCTest

/// Native mobile opt-in: an ordinary chat must never acquire its bot’s Live Tabs.
final class SessionStripTests: XCTestCase {
    var account: FixtureAccount!
    var env: [String: String] { ProcessInfo.processInfo.environment }
    override func setUpWithError() throws {
        continueAfterFailure = false
        account = try FixtureAccount.load()
        try account.control("/__fixture/reset", [:])
        try account.control("/__fixture/mode", ["working": ["s-garden"], "live": ["s-garden": "working"]])
        for (id, title, pinned) in [("s-launch", "Launch notes", true), ("s-dinner", "Dinner ideas", false), ("s-reading", "Reading list", false)] {
            try account.control("/__fixture/rows", ["id": id, "set": ["profile": "default", "title": title, "pinned": pinned, "last_active": Date().timeIntervalSince1970 - (id == "s-dinner" ? 900 : 260000)]])
        }
    }

    @MainActor func launch(stripOn: Bool? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HQDebugNoSwipePeek", "YES", "-HQDebugResetSessionsView", "YES", "-HQDebugResetUnread", "YES", "-dispatch.notifications.asked", "YES", "-HQDebugResetTheme", "YES", "-HQDebugResetAccounts", "YES", "-HQDebugNoDrag", "YES", "-HQDebugAppearance", env["HQN_SESSIONS_DARK"] == "1" ? "dark" : "light"]
        if let stripOn { app.launchArguments += ["-hqn.sessionStrip", stripOn ? "YES" : "NO"] }
        app.launchEnvironment["HQN_SIGNIN_URL"] = account.url
        app.launchEnvironment["HQN_SIGNIN_USERNAME"] = account.username
        app.launchEnvironment["HQN_SIGNIN_PASSWORD"] = account.password
        app.launch()
        return app
    }

    @MainActor func bot(_ app: XCUIApplication) {
        let bots = app.tabButton(id: "tab-bots", label: "Bots")
        if bots.isHittable { bots.tap() }
        let row = app.cells["bot-row-default"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "fixture bot")
        row.tap()
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 15))
    }

    @MainActor func back(_ app: XCUIApplication) { app.navigationBars.buttons.element(boundBy: 0).tap() }
    @MainActor func backToBot(_ app: XCUIApplication) {
        let button = app.navigationBars.buttons["BackButton"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 8) && button.isHittable, "visible Back on the opened chat")
        button.tap()
        XCTAssertTrue(all(app).waitForExistence(timeout: 12), "Back returns directly to the originating bot chat")
    }
    @MainActor func all(_ app: XCUIApplication) -> XCUIElement { app.buttons["session-strip.all"] }

    /// A real software keyboard keeps the bot's row visible and hittable without losing the draft.
    @MainActor func testTypingKeepsBotStripVisible() throws {
        let app = launch(stripOn: true)
        bot(app)
        let all = all(app)
        let field = app.textViews["composer.text"]
        let more = app.buttons["chat.more"]
        let title = app.descendants(matching: .any)["chat.title"].firstMatch
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(all.waitForExistence(timeout: 20))
        XCTAssertTrue(more.exists && title.exists && backButton.exists)
        let beforeFrame = all.frame
        shot(app, "typing-before")

        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "software keyboard must actually appear")
        field.typeText("An unsent fixture draft")
        XCTAssertTrue(waitUntil(10) { app.keyboards.firstMatch.exists }, "software keyboard returns after typing")
        shot(app, "typing-during")
        XCTAssertTrue(all.exists && all.isHittable, "the row stays visible while the keyboard is up")
        XCTAssertEqual(all.frame.minX, beforeFrame.minX, accuracy: 1)
        XCTAssertEqual(all.frame.minY, beforeFrame.minY, accuracy: 1)
        XCTAssertTrue(more.isHittable && title.exists && backButton.isHittable, "the navigation bar stays intact")
        XCTAssertEqual(field.value as? String, "An unsent fixture draft")

        // Open the actual menu while the keyboard is up; it may dismiss the keyboard as it presents.
        more.tap()
        let chatsWhileTyping = app.buttons["chat.more.bot-chats"]
        XCTAssertTrue(chatsWhileTyping.waitForExistence(timeout: 5), "Chats is reachable from the header")
        chatsWhileTyping.tap()
        let doneWhileTyping = app.buttons["phone-bot-chats.done"]
        XCTAssertTrue(doneWhileTyping.waitForExistence(timeout: 8)); doneWhileTyping.tap()
        XCTAssertEqual(field.value as? String, "An unsent fixture draft")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        let table = app.tables["chat.table"]
        table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            .press(forDuration: 0.1, thenDragTo: table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        XCTAssertTrue(waitUntil(10) { !app.keyboards.firstMatch.exists })
        XCTAssertTrue(all.waitForExistence(timeout: 10), "the row stays visible when the keyboard is dismissed")
        XCTAssertEqual(field.value as? String, "An unsent fixture draft")
        XCTAssertEqual(all.frame.minX, beforeFrame.minX, accuracy: 1)
        shot(app, "typing-after")

        more.tap()
        let chats = app.buttons["chat.more.bot-chats"]
        XCTAssertTrue(chats.waitForExistence(timeout: 5), "the bot's chats remain in the menu")
        chats.tap()
        let done = app.buttons["phone-bot-chats.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 8)); done.tap()
        let budget = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Quarterly budget")).firstMatch
        XCTAssertTrue(budget.waitForExistence(timeout: 8)); budget.tap()
        XCTAssertTrue(waitUntil(10) { !all.exists && app.textViews["composer.text"].exists })
        backToBot(app)
        XCTAssertEqual(field.value as? String, "An unsent fixture draft")
    }

    /// A long bot chat read from higher up: the line being read stays on screen while typing and dismissing,
    /// with the row staying visible, and neither focusing nor dismissing jumps the chat to its newest end.
    @MainActor func testTypingKeepsTheReadingPlaceInALongChat() throws {
        let digest = SHA256.hash(data: Data("default".utf8)).map { String(format: "%02x", $0) }.joined()
        let lines: [[String: Any]] = (1...48).map { n in
            ["role": n % 2 == 1 ? "user" : "assistant", "content": "Line \(n) of the long fixture chat."]
        }
        try account.control("/__fixture/rows", ["id": "20261009_090000_bc" + digest.prefix(6), "set": ["messages": lines]])
        let app = launch(stripOn: true)
        bot(app)
        let all = all(app)
        XCTAssertTrue(all.waitForExistence(timeout: 20))
        let table = app.tables["chat.table"]
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Line 48 of the long")).firstMatch
            .waitForExistence(timeout: 15), "the long history is drawn")
        for _ in 0..<2 { table.swipeDown(velocity: .slow) }   // up into the older lines
        Thread.sleep(forTimeInterval: 1.2)
        func onScreen() -> [(n: Int, y: CGFloat)] {
            let room = table.frame
            // A bubble's label may carry who said it before the words, so match the words anywhere in it.
            var seen: [Int: CGFloat] = [:]
            for e in app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "of the long fixture chat")).allElementsBoundByIndex {
                let f = e.frame
                guard f.height > 0, f.minX >= room.minX - 1, f.maxX <= room.maxX + 1, f.minY > room.minY + 60, f.maxY < room.maxY - 60,
                      let hit = e.label.firstMatch(of: /Line (\d+) of the long/), let n = Int(hit.1) else { continue }
                seen[n] = f.minY
            }
            return seen.map { (n: $0.key, y: $0.value) }
        }
        let before = onScreen()
        XCTAssertFalse(before.isEmpty, "some older lines are on screen")
        XCTAssertFalse(before.contains { $0.n == 48 }, "the chat was scrolled up away from the newest line")
        shot(app, "long-before")

        let field = app.textViews["composer.text"]
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(all.exists && all.isHittable, "the row stays visible while typing")
        Thread.sleep(forTimeInterval: 0.8)
        let during = onScreen()
        shot(app, "long-during")
        let middle = before.map(\.n).sorted()[before.count / 2]
        XCTAssertTrue(during.contains { $0.n == middle }, "line \(middle) is still on screen while typing: \(during.map(\.n))")
        XCTAssertFalse(during.contains { $0.n == 48 }, "focusing did not jump the chat to its newest end")

        table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            .press(forDuration: 0.1, thenDragTo: table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        XCTAssertTrue(waitUntil(10) { !app.keyboards.firstMatch.exists })
        XCTAssertTrue(all.exists, "the row stays visible after dismissing")
        Thread.sleep(forTimeInterval: 0.8)
        let after = onScreen()
        shot(app, "long-after")
        XCTAssertFalse(after.isEmpty)
        XCTAssertFalse(after.contains { $0.n == 48 }, "dismissing did not jump to the newest end either: \(after.map(\.n))")
    }

    @MainActor func testTypingWithStripSettingOff() throws {
        let app = launch(stripOn: false)
        bot(app)
        let field = app.textViews["composer.text"]
        XCTAssertFalse(all(app).exists)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(all(app).exists)
        let table = app.tables["chat.table"]
        table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            .press(forDuration: 0.1, thenDragTo: table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        XCTAssertTrue(waitUntil(10) { !app.keyboards.firstMatch.exists })
        XCTAssertFalse(all(app).exists)
    }

    /// Install default and real Settings toggle; run against a newly provisioned simulator. No preference launch override.
    @MainActor func testAcceptance_RealSettingsAndRelaunch() throws {
        let app = launch()
        bot(app)
        XCTAssertFalse(all(app).exists); XCTAssertFalse(app.buttons["chat.strip.new"].exists)
        shot(app, "01-default-off")
        back(app)
        settingsStrip(app, expected: "0", turnTo: "1")
        bot(app)
        let all = all(app)
        XCTAssertTrue(all.waitForExistence(timeout: 20), "opt-in shows the bot's live tabs")
        XCTAssertTrue(all.label.contains("5"), "count all five eligible chats: \(all.label)")
        let garden = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Garden plan")).firstMatch
        let budget = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Quarterly budget")).firstMatch
        XCTAssertTrue(garden.exists && budget.exists)
        // [compact-strip] A slim row (about 30 pt at the default text size) …
        XCTAssertLessThanOrEqual(garden.frame.height, 32, "the row of names is slim")
        XCTAssertLessThanOrEqual(all.frame.height, 32, "All is as slim as the names")
        shot(app, "03-live-tabs")
        all.tap()
        XCTAssertTrue(app.staticTexts["Launch notes"].waitForExistence(timeout: 8) || app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Launch notes")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Nightly index run"].exists)
        shot(app, "04-all-chats")
        let done = app.buttons["phone-bot-chats.done"]
        XCTAssertTrue(done.exists); done.tap()
        // … whose names still take a finger: a tap 10 pt below the drawn row opens the name above it.
        budget.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1)).withOffset(CGVector(dx: 0, dy: 10)).tap()
        XCTAssertTrue(waitUntil(10) { !all.exists }, "a tap just under a name opens that chat")
        shot(app, "05-chat-open")
        backToBot(app)
        shot(app, "06-back-at-bot")
        all.tap()
        let pinned = app.cells["phone-bot-chats.chat.s-launch"]
        XCTAssertTrue(pinned.waitForExistence(timeout: 8)); pinned.tap()
        XCTAssertTrue(waitUntil(10) { !all.exists && app.textViews["composer.text"].exists })
        backToBot(app)
        all.tap()
        let newChat = app.cells["phone-bot-chats.new"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 8)); newChat.tap()
        XCTAssertTrue(waitUntil(10) { !all.exists && app.textViews["composer.text"].exists })
        backToBot(app)
        back(app)
        settingsStrip(app, expected: "1", turnTo: "0")
        app.terminate(); app.launch()
        bot(app)
        XCTAssertFalse(all.exists, "off sticks after a relaunch")
        shot(app, "07-off-again")
    }

    @MainActor func settingsStrip(_ app: XCUIApplication, expected: String, turnTo: String?) {
        let more = app.tabButton(id: "tab-more", label: "More")
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let row = app.cells["more-row-settings"]
        if !app.switches["settings.session-strip"].exists {
            if !row.waitForExistence(timeout: 3) { more.tap() }
            XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        }

        let toggle = app.switches["settings.session-strip"]
        for _ in 0..<14 {
            if toggle.exists && toggle.isHittable && toggle.frame.maxY < app.windows.firstMatch.frame.height - 100 { break }
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(toggle.exists && toggle.isHittable, "actual Settings switch")
        XCTAssertEqual(toggle.value as? String, expected)
        shot(app, "acceptance-setting-\(expected)")
        if let turnTo {
            let inner = toggle.switches.firstMatch
            (inner.exists ? inner : toggle).tap()
            XCTAssertTrue(waitUntil(5) { toggle.value as? String == turnTo })
            shot(app, "setting-now-\(turnTo)")
        }
    }

    @MainActor func shot(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.8)
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = env["HQN_SHOTS_DIR"], !dir.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir)
                .appendingPathComponent("sessions-\(name)\(env["HQN_SESSIONS_DARK"] == "1" ? "-dark" : "").png"))
        }
    }

    @MainActor @discardableResult
    func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }
}
