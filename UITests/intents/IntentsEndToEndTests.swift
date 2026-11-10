// Siri, Shortcuts, the Action Button and Home Screen quick actions end to end (docs/spec/3x-intents.md §13 A9,
// A14–A20, A22–A23, A28–A33, A36–A42, A46–A48; §14 S1, S2, S26, S28, S32), run by scripts/e2e-intents.sh against
// scripts/fixtures/intents-gateway.py (two bots and the memo pipeline) and scripts/fixtures/restore-gateway.py (five
// bots and listed chats). The simulator has no Action Button and Siri there is not dependable, so the shortcuts are
// run through the app's DEBUG hooks, which perform the real intent types (`<scheme>://debug-intent/<word>` on a
// running app, `-HQDebugIntent <word>` on a cold launch); the Home Screen menu is the real one. What happened is read
// from `intents-state.json`, which the app rewrites on every change. Without TEST_RUNNER_HQN_UI_INTENTS=1 every test
// skips. All values are invented.

import CryptoKit
import XCTest

final class IntentsEndToEndTests: XCTestCase {
    private var account: FixtureAccount!
    private var app: XCUIApplication!
    private var folder = ""
    private static let environment = ProcessInfo.processInfo.environment
    private static let scheme = environment["HQN_UI_SCHEME"] ?? "hermeshq-native"
    private static let appName = environment["HQN_UI_APP_NAME"] ?? "Hermes HQ"
    private static let ivyChat = "20260929_120000_aabbcc02"
    /// The simulator's own appearance, set by scripts/e2e-intents.sh for its last pass (`xcrun simctl ui … appearance`):
    /// the Home Screen's menu and the Shortcuts app are the system's screens, and only that changes them.
    private static let deviceLook = environment["HQN_UI_DEVICE_LOOK"] == "dark" ? "dark" : "light"
    /// Whether the simulator asks "Open in <app>?" for a link the test opens (decided on the first one).
    nonisolated(unsafe) private static var asksToOpen: Bool?

    @MainActor private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard Self.environment["HQN_UI_INTENTS"] == "1" else { throw XCTSkip("Run with scripts/e2e-intents.sh (the intents fixtures).") }
        account = try FixtureAccount.load()
        try account.control("/__fixture/intents", ["reset": true])
        try account.control("/__fixture/voice", ["reset": true])
        folder = Self.outputRoot + "/state/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: folder)
        super.tearDown()
    }

    // MARK: A9. The pickers' bots follow the roster (L608)

    @MainActor func testA09_TheCatalogFollowsTheRoster() throws {
        launch()
        let first = try waitState("the catalog lists both bots") { self.names($0) == ["Hermes", "Ivy"] }
        let refreshes = first["parameterRefreshes"] as? Int ?? 0
        XCTAssertGreaterThanOrEqual(refreshes, 1, "the system was told once the bots were stored")
        try account.control("/__fixture/intents", ["names": ["ivy": "Samantha"]])
        refreshBots()
        try waitState("the rename reaches the pickers") { self.names($0) == ["Hermes", "Samantha"] }
        let renamed = try waitState("and the system is told once") { ($0["parameterRefreshes"] as? Int ?? 0) == refreshes + 1 }
        XCTAssertEqual((renamed["catalog"] as? [[String: Any]])?.map { $0["key"] as? String }, ["ios-direct::default", "ios-direct::ivy"])
        try account.control("/__fixture/intents", ["removed": ["ivy"]])
        refreshBots()
        try waitState("a removed bot leaves the pickers") { self.names($0) == ["Hermes"] }
        // A shortcut that still names Ivy fails in the intent itself, with the sentence the Shortcuts app shows.
        trigger("voice-note:ivy")
        let sentence = "error Open \(Self.appName) to refresh your bots, then choose a bot in this shortcut."
        let state = try waitState("the intent throws its own sentence") { self.events($0).contains(sentence) }
        XCTAssertTrue(state["request"] is NSNull, "no request was written")
        XCTAssertFalse(app.tables["chat.table"].exists, "no chat opened")
        XCTAssertFalse(app.alerts.firstMatch.exists, "the intent's error is the system's to show, not the app's")
    }

    // MARK: A11. The Shortcuts app

    /// A11, as far as a simulator shows it: the Shortcuts app lists the app with its "Record Voice Memo" action. What
    /// it finds goes to the notes and a screenshot; a Shortcuts app that cannot be driven here is a skip, never a pass.
    @MainActor func testA11_TheShortcutsAppListsTheAction() throws {
        launch(systemRefresh: true)
        try waitState("the pickers' bots are stored") { self.names($0) == ["Hermes", "Ivy"] }
        let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        shortcuts.activate()
        guard shortcuts.wait(for: .runningForeground, timeout: 25) else {
            note("A11 the Shortcuts app did not open in this simulator")
            throw XCTSkip("the Shortcuts app did not open in this simulator")
        }
        defer { shortcuts.terminate() }
        for title in ["Continue", "Not Now", "OK"] {
            let button = shortcuts.buttons[title]
            if button.waitForExistence(timeout: 2) { button.tap() }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        save(XCUIScreen.main.screenshot(), "A11-shortcuts-app-" + Self.deviceLook)
        let dump = URL(fileURLWithPath: Self.outputRoot + "/shortcuts-app.txt")
        try? shortcuts.debugDescription.write(to: dump, atomically: true, encoding: .utf8)
        let named = NSPredicate(format: "label CONTAINS[c] %@", Self.appName)
        let action = NSPredicate(format: "label CONTAINS[c] %@", "Record Voice Memo")
        func seen(_ predicate: NSPredicate) -> XCUIElement? {
            for query in [shortcuts.buttons, shortcuts.staticTexts, shortcuts.cells] {
                let match = query.matching(predicate).firstMatch
                if match.exists { return match }
            }
            return nil
        }
        var row = seen(named)
        if row == nil {
            // The app's row may be under the list of folders ("Shortcuts" at the top left), or further down.
            for title in ["Shortcuts", "Library", "Back"] where row == nil {
                let button = shortcuts.navigationBars.buttons[title]
                if button.exists { button.tap(); RunLoop.current.run(until: Date().addingTimeInterval(1.5)); row = seen(named) }
            }
            for _ in 0..<3 where row == nil { shortcuts.swipeUp(); row = seen(named) }
        }
        guard let row else {
            note("A11 the Shortcuts app opened, but this simulator's list does not show “\(Self.appName)” (hierarchy in \(dump.path))")
            throw XCTSkip("the Shortcuts app does not show the app here")
        }
        note("A11 the Shortcuts app lists “\(row.label)”")
        var shown = seen(action)
        if shown == nil, row.isHittable {
            row.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            shown = seen(action)
        }
        save(XCUIScreen.main.screenshot(), "A11-shortcuts-app-action-" + Self.deviceLook)
        try? shortcuts.debugDescription.write(to: dump, atomically: true, encoding: .utf8)
        guard let shown else {
            note("A11 “\(Self.appName)” is listed, but its action row was not found (hierarchy in \(dump.path))")
            throw XCTSkip("the action row was not found")
        }
        note("A11 the Shortcuts app shows the action “\(shown.label)” for \(Self.appName)")
        XCTAssertFalse(shown.label.contains("Dispatch"))
        // The pickers' bots are offered beside it, one tile each (the App Shortcut's parameter).
        func tile(_ name: String) -> XCUIElement? { seen(NSPredicate(format: "label ==[c] %@", name)) }
        XCTAssertTrue(waitUntil(timeout: 10) { tile("Ivy") != nil && tile("Hermes") != nil }, "the bots are offered: Hermes and Ivy")
        note("A11 the Shortcuts app offers the bots Hermes and Ivy beside the action")
        // The real thing, with no test hook: the system runs the App Shortcut for Ivy.
        let ivy = shortcuts.otherElements.matching(NSPredicate(format: "label ==[c] %@", "Ivy")).firstMatch
        guard ivy.exists else {
            note("A11 Ivy’s tile could not be addressed, so the App Shortcut was not run from the Shortcuts app")
            return
        }
        let hooksBefore = events(state()).filter { $0.hasPrefix("hook ") }.count
        ivy.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()      // the round icon, above its name
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        save(XCUIScreen.main.screenshot(), "A11-shortcuts-app-ivy-tapped-" + Self.deviceLook)
        // A prompt of the system's, if one comes, is answered. Once the app is in front the Shortcuts app is not asked
        // any more: it has left the screen, and a snapshot of it can then time out, which XCUITest counts as a failure.
        let promptsUntil = Date().addingTimeInterval(6)
        while Date() < promptsUntil, self.app.state != .runningForeground {
            for title in ["Allow", "Always Allow", "Open", "Run"] where self.app.state != .runningForeground {
                let button = shortcuts.buttons[title]
                if button.exists { button.tap() }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        guard self.app.wait(for: .runningForeground, timeout: 25), self.app.buttons["memo.stop"].waitForExistence(timeout: 25) else {
            save(XCUIScreen.main.screenshot(), "A11-shortcuts-app-after-ivy-" + Self.deviceLook)
            note("A11 tapping Ivy’s tile in the Shortcuts app did not bring the recorder here (screenshot A11-shortcuts-app-after-ivy)")
            XCTFail("the App Shortcut for Ivy, run by the system from the Shortcuts app, did not start the recorder")
            return
        }
        XCTAssertTrue(chatTitle().contains("Ivy"), chatTitle())
        let after = try waitState("the system performed the intent") { self.events($0).contains("memo started ivy") }
        XCTAssertTrue(events(after).contains("perform RecordVoiceNoteIntent ivy"), "the real intent ran")
        XCTAssertEqual(events(after).filter { $0.hasPrefix("hook ") }.count, hooksBefore, "with no test hook")
        note("A11/A14 the App Shortcut for Ivy, tapped in the Shortcuts app and run by the system, started the locked recorder in Ivy’s chat")
        shots("A11-app-shortcut-run-by-the-system")
        discardTake()

        // L608 for real: the bot is renamed on the gateway, the app reads its roster, and the Shortcuts app's tile follows.
        back()
        try account.control("/__fixture/intents", ["names": ["ivy": "Samantha"]])
        refreshBots()
        let stored = try waitState("the rename reached the pickers") { Set(self.names($0)) == ["Hermes", "Samantha"] }
        let renamedAt = Date()
        let writesBefore = events(stored).filter { $0.hasPrefix("catalog ") }
        func reopenAppPage() {
            shortcuts.terminate()
            shortcuts.activate()
            _ = shortcuts.wait(for: .runningForeground, timeout: 20)
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            if seen(action) != nil { return }               // it came back on the app's page
            var row = seen(named)
            for title in ["Shortcuts", "Library", "Back"] where row == nil {
                let button = shortcuts.navigationBars.buttons[title]
                if button.exists { button.tap(); RunLoop.current.run(until: Date().addingTimeInterval(1.5)); row = seen(named) }
            }
            if let row, row.isHittable { row.tap(); RunLoop.current.run(until: Date().addingTimeInterval(2)) }
        }
        shortcuts.activate()
        XCTAssertTrue(shortcuts.wait(for: .runningForeground, timeout: 20))
        var renamed = waitUntil(timeout: 10) { tile("Samantha") != nil }
        // The page may have been drawn before the system told the Shortcuts app: open it afresh, a few times.
        for _ in 0..<4 where !renamed {
            reopenAppPage()
            renamed = waitUntil(timeout: 12) { tile("Samantha") != nil }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))          // the switch between the apps has finished
        save(XCUIScreen.main.screenshot(), "A11-shortcuts-app-renamed-" + Self.deviceLook)
        // One rename is one write and one call to the system, however the roster's order moved meanwhile.
        let writes = events(state()).filter { $0.hasPrefix("catalog ") }
        note("A11 the pickers' bots were written: \(writes)")
        XCTAssertEqual(writes.count, writesBefore.count, "nothing more was written after the rename: \(writes)")
        XCTAssertEqual(writes.count, 2, "sign-in and the rename, one write each: \(writes)")
        guard renamed else {
            let waited = Int(Date().timeIntervalSince(renamedAt))
            // Not failed here: the system rations parameter refreshes ("Donation quota exceeded" in the simulator's
            // log; this test's two calls fit, but not after other runs moments ago). scripts/e2e-intents.sh reads
            // the log for this run: not seen AND not refused by the system is a failure there.
            note("A11/L608 NOT SEEN: \(waited) s after the rename reached the app’s stored bots (and its parameter refresh ran), the Shortcuts app in this simulator still offers “Ivy”, not “Samantha”")
            return
        }
        XCTAssertNil(tile("Ivy"), "and no longer Ivy")
        note("A11/L608 the tile followed \(Int(Date().timeIntervalSince(renamedAt))) s after the rename")
        note("A11/L608 after the bot was renamed on the gateway, the Shortcuts app offers “Samantha” (and no longer “Ivy”)")
    }

    // MARK: A14, A16, A17. A shortcut on a running app: the bot's chat, the locked recorder, one memo
    @MainActor func testA14_WarmShortcutRecordsInTheBotsChatAndSendsOnce() throws {
        launch()
        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.collectionViews["sessions.list"].waitForExistence(timeout: 10))
        trigger("voice-note:ivy")
        let stop = app.buttons["memo.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 20), "the locked recorder shows")
        XCTAssertTrue(chatTitle().contains("Ivy"), "Ivy's chat is on top: \(chatTitle())")
        XCTAssertTrue(app.buttons["memo.delete"].exists && app.buttons["composer.send"].exists, "trash and Send beside it")
        let first = recordingSeconds()
        RunLoop.current.run(until: Date().addingTimeInterval(2.4))
        let second = recordingSeconds()
        XCTAssertGreaterThan(second, first, "its time advances (\(first) → \(second))")
        var state = try waitState("the request is acknowledged") { $0["request"] is NSNull }
        XCTAssertEqual(events(state).filter { $0 == "memo started ivy" }.count, 1)
        XCTAssertTrue(events(state).contains("perform RecordVoiceNoteIntent ivy"), "the real intent ran")
        note("A14 warm: the shortcut to the recorder started, in the app: \(elapsed(state, from: "hook voice-note:ivy", to: "memo started ivy") ?? -1) ms")
        shots("A14-shortcut-recording-ivy")

        // A17: the same shortcut again leaves the take running; another bot's is refused.
        trigger("voice-note:ivy")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertTrue(stop.exists, "still recording")
        XCTAssertGreaterThanOrEqual(recordingSeconds(), second, "the take did not restart")
        XCTAssertFalse(app.alerts.firstMatch.exists, "no alert for the same bot")
        trigger("voice-note:default")
        expectNotice(title: "Couldn’t Start the Voice Memo", message: "Finish the current voice memo before starting another.", buttons: ["OK"])
        shots("A17-finish-current-voice-note")
        app.alerts.firstMatch.buttons["OK"].tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 3) && chatTitle().contains("Ivy"), "the take keeps running in Ivy's chat")
        state = try waitState("that request is acknowledged too") { $0["request"] is NSNull }
        XCTAssertEqual(events(state).filter { $0.hasPrefix("memo started") }.count, 1, "one take in all")

        // A16: Stop, then Send: one memo, in Ivy's chat only.
        stop.tap()
        XCTAssertTrue(app.buttons["memo.review.play"].waitForExistence(timeout: 5), "Stop opens review")
        app.buttons["composer.send"].tap()
        XCTAssertTrue(waitUntil(timeout: 20) { self.prompts().count == 1 }, "one prompt went out")
        let voice = try account.control("/__fixture/voice-state")
        XCTAssertEqual((voice["uploads"] as? [Any])?.count, 1, "one upload")
        let attaches = voice["attaches"] as? [[String: Any]] ?? []
        XCTAssertEqual(attaches.count, 1, "one file.attach")
        XCTAssertEqual(attaches.first?["profile"] as? String, "ivy")
        XCTAssertEqual(prompts().first?["profile"] as? String, "ivy", "the prompt is Ivy's")
        XCTAssertTrue((prompts().first?["text"] as? String ?? "").hasPrefix("MEDIA:\""), "and it is the memo")
        XCTAssertTrue(app.buttons["memo.play"].firstMatch.waitForExistence(timeout: 10), "the memo bubble shows")
        XCTAssertFalse(prompts().contains { ($0["profile"] as? String) == "default" }, "nothing went to Hermes")
    }

    // MARK: A15. A shortcut that launches the app

    @MainActor func testA15_ColdShortcutOpensTheBotsChatNotTheLastOne() throws {
        launch()
        openBot("default")                                  // the chat a plain launch would reopen
        leave()
        let began = Date()
        launch(["-HQDebugIntent", "voice-note:ivy"], reset: false, waitForBots: false)
        XCTAssertTrue(app.buttons["memo.stop"].waitForExistence(timeout: 40), "the locked recorder shows")
        note("A15 cold launch to locked recorder: \(ms(began)) ms (includes XCUITest's launch)")
        XCTAssertTrue(chatTitle().contains("Ivy"), "Ivy's chat, not the last one: \(chatTitle())")
        let state = try waitState("acknowledged") { $0["request"] is NSNull }
        XCTAssertEqual(events(state).filter { $0 == "memo started ivy" }.count, 1)
        shots("A15-cold-shortcut-recording")
        discardTake()
        XCTAssertTrue(app.buttons["composer.mic"].waitForExistence(timeout: 5), "the take is gone")
        back()
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 5), "Back goes to Bots")
        XCTAssertFalse(app.tables["chat.table"].exists, "the last chat was not pushed under it")
    }

    // MARK: A16. A cold launch the system makes, and the order it may take

    /// The real thing, with no test hook at launch: the app is not running, Ivy's tile is tapped in the Shortcuts app,
    /// and the system launches the app and performs the intent in whatever order it chooses. The last chat (Hermes's)
    /// must not come back first. A Shortcuts app that cannot be driven here is a skip, never a pass.
    @MainActor func testA16_ColdAppShortcutRunByTheSystem() throws {
        launch(systemRefresh: true)
        try waitState("the pickers' bots are stored") { self.names($0) == ["Hermes", "Ivy"] }
        openBot("default")                                  // the chat a plain launch would reopen
        trigger("persist-hooks")                            // the system's launch carries no arguments
        let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        shortcuts.activate()
        guard shortcuts.wait(for: .runningForeground, timeout: 25) else {
            note("A16 the Shortcuts app did not open in this simulator")
            throw XCTSkip("the Shortcuts app did not open in this simulator")
        }
        defer { shortcuts.terminate() }
        for title in ["Continue", "Not Now", "OK"] {
            let button = shortcuts.buttons[title]
            if button.waitForExistence(timeout: 2) { button.tap() }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        func seen(_ predicate: NSPredicate) -> XCUIElement? {
            for query in [shortcuts.buttons, shortcuts.staticTexts, shortcuts.cells] {
                let match = query.matching(predicate).firstMatch
                if match.exists { return match }
            }
            return nil
        }
        let named = NSPredicate(format: "label CONTAINS[c] %@", Self.appName)
        let action = NSPredicate(format: "label CONTAINS[c] %@", "Record Voice Memo")
        if seen(action) == nil {
            var row = seen(named)
            for title in ["Shortcuts", "Library", "Back"] where row == nil {
                let button = shortcuts.navigationBars.buttons[title]
                if button.exists { button.tap(); RunLoop.current.run(until: Date().addingTimeInterval(1.5)); row = seen(named) }
            }
            for _ in 0..<3 where row == nil { shortcuts.swipeUp(); row = seen(named) }
            if let row, row.isHittable { row.tap(); RunLoop.current.run(until: Date().addingTimeInterval(2)) }
        }
        // The tile may still carry the name an earlier test gave the bot (the system rations the refreshes); it is the
        // same bot either way.
        let ivy = shortcuts.otherElements.matching(NSPredicate(format: "label ==[c] %@ OR label ==[c] %@", "Ivy", "Samantha")).firstMatch
        guard seen(action) != nil, ivy.waitForExistence(timeout: 10) else {
            note("A16 the Shortcuts app in this simulator does not show Ivy’s tile, so the system’s cold launch was not run")
            throw XCTSkip("Ivy's tile is not shown by the Shortcuts app here")
        }
        // The app is not running any more (it left the screen with Hermes's chat on top).
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "the app ended")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        try? FileManager.default.removeItem(atPath: folder + "/intents-state.json")
        let began = Date()
        ivy.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        let promptsUntil = Date().addingTimeInterval(6)
        while Date() < promptsUntil, app.state != .runningForeground {
            for title in ["Allow", "Always Allow", "Open", "Run"] where app.state != .runningForeground {
                let button = shortcuts.buttons[title]
                if button.exists { button.tap() }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        guard app.wait(for: .runningForeground, timeout: 30), app.buttons["memo.stop"].waitForExistence(timeout: 40) else {
            save(XCUIScreen.main.screenshot(), "A16-cold-system-launch-failed-" + Self.deviceLook)
            XCTFail("the App Shortcut for Ivy, run by the system on an app that was not running, did not start the recorder: \(events(state()).suffix(20))")
            return
        }
        note("A16 cold, run by the system: tile tapped to locked recorder in \(ms(began)) ms")
        XCTAssertTrue(chatTitle().contains("Ivy"), "Ivy's chat, not the last one: \(chatTitle())")
        let after = try waitState("the system performed the intent in a new process") { self.events($0).contains("memo started ivy") }
        let all = events(after)
        XCTAssertTrue(all.contains("perform RecordVoiceNoteIntent ivy"), "the real intent ran: \(all)")
        XCTAssertFalse(all.contains { $0.hasPrefix("hook ") }, "with no test hook: \(all)")
        // The system launches the app first and performs the intent when it is ready (measured here: the saved
        // sign-in was back 0.1 s after the scene connected, the intent was performed 7 s after that), and nothing in
        // the launch says a shortcut is coming. So the last chat may be on screen first; what must hold is that the
        // shortcut's chat then takes its place, with nothing left under it.
        XCTAssertEqual(all.filter { $0.hasPrefix("memo started") }, ["memo started ivy"], "one take, Ivy's: \(all)")
        let order = all.contains("launch restore replaced") || all.contains("visited bot:ios-direct::default") ? "the last chat was back on screen when the system performed the intent; Ivy’s chat took its place"
            : all.contains("launch restore canceled") ? "the intent was performed before the last chat was put back; it never showed"
            : "the last chat was not on screen when the intent was performed"
        note("A16 the order the system took: " + order)
        shots("A16-cold-app-shortcut-run-by-the-system")
        discardTake()
        XCTAssertTrue(app.buttons["composer.mic"].waitForExistence(timeout: 5), "the take is gone")
        back()
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 5), "Back goes to Bots")
        XCTAssertFalse(app.tables["chat.table"].exists, "the last chat was not left under it")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertFalse(app.tables["chat.table"].exists, "and it does not come back by itself")
    }

    /// The order nothing else pins down: the intent is performed after the scene connected, so the scene saw no
    /// request. Straight after (before the saved sign-in is back) and 3 s after (the last chat is already on screen).
    @MainActor func testA16_AShortcutPerformedAfterTheSceneConnected() throws {
        launch()
        openBot("default")
        leave()
        launch(["-HQDebugLateIntent", "voice-note:ivy"], reset: false, waitForBots: false)
        XCTAssertTrue(app.buttons["memo.stop"].waitForExistence(timeout: 40), "the locked recorder shows")
        XCTAssertTrue(chatTitle().contains("Ivy"), "Ivy's chat: \(chatTitle())")
        var state = try waitState("acknowledged") { $0["request"] is NSNull && self.events($0).contains("memo started ivy") }
        var all = events(state)
        // Which of the two it is depends on whether the saved sign-in was back first (about 0.1 s): never neither.
        XCTAssertTrue(all.contains("launch restore canceled") || all.contains("launch restore replaced"),
                      "reopening the last chat was called off, or its chat replaced: \(all)")
        discardTake()
        back()
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 5), "Back goes to Bots")
        XCTAssertFalse(app.tables["chat.table"].exists, "nothing under it")

        // The late case: the last chat is back on screen when the intent runs. Ivy's chat replaces it.
        openBot("default")
        leave()
        launch(["-HQDebugLateIntent", "voice-note:ivy", "-HQDebugLateIntentDelay", "3"], reset: false, waitForBots: false)
        XCTAssertTrue(app.buttons["memo.stop"].waitForExistence(timeout: 40), "the locked recorder shows")
        XCTAssertTrue(chatTitle().contains("Ivy"), "Ivy's chat: \(chatTitle())")
        state = try waitState("acknowledged") { $0["request"] is NSNull && self.events($0).contains("memo started ivy") }
        all = events(state)
        XCTAssertEqual(all.filter { $0 == "memo started ivy" }.count, 1)
        XCTAssertTrue(all.contains("launch restore replaced") || all.contains("visited bot:ios-direct::default"),
                      "the last chat had come back before the intent ran (that is the case under test): \(all)")
        shots("A16-shortcut-after-the-last-chat-came-back")
        discardTake()
        back()
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 5), "Back goes to Bots")
        XCTAssertFalse(app.tables["chat.table"].exists, "the reopened chat is not left under Ivy's")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertFalse(app.tables["chat.table"].exists, "and it does not come back by itself")
    }

    // MARK: A18, A19. Refusals

    @MainActor func testA18_AnotherAccountsShortcutAndARemovedBotAreRefused() throws {
        launch()
        trigger("voice-note-foreign:ivy")
        expectNotice(title: "Couldn’t Start the Voice Memo",
                     message: "This shortcut belongs to another account or to another computer running Hermes. Choose your bot again in Shortcuts.", buttons: ["OK"])
        shots("A18-another-gateway-account")
        app.alerts.firstMatch.buttons["OK"].tap()
        XCTAssertFalse(app.tables["chat.table"].exists, "no chat opened")
        try waitState("the request is gone") { $0["request"] is NSNull }

        // A19: the shortcut's bot has left the roster since.
        try account.control("/__fixture/intents", ["removed": ["ivy"]])
        refreshBots()
        XCTAssertTrue(waitUntil(timeout: 20) { !self.app.cells["bot-row-ivy"].exists && !self.app.cells["bot-tile-ivy"].exists },
                      "Ivy left the Bots list")
        let before = count("profiles.list")
        trigger("voice-note-request:ivy")
        expectNotice(title: "Couldn’t Start the Voice Memo", message: "“Ivy” is unavailable. Reconnect to the computer running Hermes and try again.", buttons: ["OK"])
        XCTAssertGreaterThan(count("profiles.list"), before, "the roster was read once more before refusing")
        shots("A19-bot-unavailable")
        app.alerts.firstMatch.buttons["OK"].tap()
        XCTAssertFalse(app.tables["chat.table"].exists, "no chat opened")
        let state = try waitState("the request is gone") { $0["request"] is NSNull }
        XCTAssertFalse(events(state).contains { $0.hasPrefix("memo started") })
    }

    // MARK: A20. A chat whose composer is not ready

    @MainActor func testA20_ANotReadyChatEitherRecordsOrSaysSoAndNeverRecordsLater() throws {
        launch()
        try account.control("/__fixture/intents", ["fail": ["session.resume": 5], "delay": ["session.resume": 6]])
        trigger("voice-note:default")
        let stop = app.buttons["memo.stop"], alert = app.alerts.firstMatch
        XCTAssertTrue(waitUntil(timeout: 25) { stop.exists || alert.exists }, "it records, or it says why not: never nothing")
        let state = try waitState("the request is acknowledged either way") { $0["request"] is NSNull }
        if alert.exists {
            expectNotice(title: "Couldn’t Start the Voice Memo",
                         message: "The message field isn’t ready, so the voice memo didn’t start. Wait for the chat to connect, then try again.",
                         buttons: ["OK"])
            shots("A20-message-field-not-ready")
            alert.buttons["OK"].tap()
            note("A20 outcome: the 5 s sentence (the composer was not usable)")
            foregroundAgain()
            RunLoop.current.run(until: Date().addingTimeInterval(4))
            XCTAssertFalse(stop.exists, "nothing records later")
            XCTAssertFalse(events(self.state()).contains { $0.hasPrefix("memo started") })
        } else {
            XCTAssertTrue(chatTitle().contains("Hermes"), chatTitle())
            XCTAssertEqual(events(state).filter { $0 == "memo started default" }.count, 1)
            note("A20 outcome: the recorder started (the composer is usable while the chat connects)")
            foregroundAgain()
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            XCTAssertEqual(events(self.state()).filter { $0.hasPrefix("memo started") }.count, 1, "and only once")
        }
    }

    // MARK: A22, A23. The hidden intents of builds 26–28

    @MainActor func testA22_LegacyIntentsStillRun() throws {
        launch()
        trigger("legacy-memo:ivy")
        XCTAssertTrue(app.buttons["memo.stop"].waitForExistence(timeout: 20), "Send a Memo to Bot starts the recorder")
        XCTAssertTrue(chatTitle().contains("Ivy"), chatTitle())
        var state = try waitState("acknowledged") { $0["request"] is NSNull }
        XCTAssertTrue(events(state).contains("perform DispatchMemoIntent") && events(state).contains("memo started ivy"))
        discardTake()
        XCTAssertTrue(app.buttons["composer.mic"].waitForExistence(timeout: 5))
        back()
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 5))

        // An id from an earlier sign-in: the intent's own sentence, and nothing opens.
        trigger("legacy-memo-stale:ivy")
        let sentence = "error Open \(Self.appName) and choose the bot again. This shortcut is no longer available."
        state = try waitState("the stale shortcut is refused") { self.events($0).contains(sentence) }
        XCTAssertTrue(state["request"] is NSNull)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertFalse(app.tables["chat.table"].exists || app.alerts.firstMatch.exists, "nothing opened")

        // A23: Open Bot from another tab.
        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.collectionViews["sessions.list"].waitForExistence(timeout: 10))
        trigger("open-bot:ivy")
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 15), "Ivy's chat opens")
        XCTAssertTrue(waitUntil(timeout: 5) { self.chatTitle().contains("Ivy") }, chatTitle())
        XCTAssertTrue(app.buttons["composer.mic"].waitForExistence(timeout: 8), "the composer, not a recorder")
        XCTAssertFalse(app.buttons["memo.stop"].exists)
        XCTAssertTrue(events(self.state()).contains("perform DispatchOpenBotIntent"))
        shots("A23-open-bot")
    }

    // MARK: A28. A note an older build left behind becomes its bot chat's draft

    @MainActor func testA28_ASavedOlderNoteBecomesADraftAndIsNotSent() throws {
        launch()
        leave()
        launch(["-HQDebugVoiceNote", "seed-pending:ivy"], reset: false, waitForBots: false)
        let chip = app.staticTexts["memo.chip.title"]
        XCTAssertTrue(chip.waitForExistence(timeout: 40), "Ivy's chat opens with the note as its draft")
        XCTAssertEqual(chip.label, "Voice Memo 0:04")
        XCTAssertTrue(chatTitle().contains("Ivy"), chatTitle())
        let state = try waitState("the saved note is taken") { ($0["pendingNote"] as? Bool) == false }
        let seeded = try XCTUnwrap(events(state).first { $0.hasPrefix("seeded ") }).dropFirst(7)
        XCTAssertFalse(FileManager.default.fileExists(atPath: String(seeded)), "the older build's file is gone")
        XCTAssertTrue(events(state).contains("saved note recovered ivy"))
        XCTAssertFalse(app.buttons["memo.stop"].exists, "nothing records")
        let play = app.buttons["memo.chip.play"]
        play.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { play.label == "Pause Voice Memo" }, "it plays (\(play.label))")
        shots("A28-older-note-as-draft")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(prompts().isEmpty, "nothing was sent")
        XCTAssertEqual(((try account.control("/__fixture/voice-state"))["uploads"] as? [Any])?.count, 0)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    // MARK: A29–A32. A shortcut while a saved note waits: the question and its three answers

    @MainActor func testA29_SavedNoteQuestionThenOpenChat() throws {
        try launchWithSavedNoteAndShortcut()
        shots("A29-saved-voice-note")
        app.alerts.firstMatch.buttons["Open Chat"].tap()
        let chip = app.staticTexts["memo.chip.title"]
        XCTAssertTrue(chip.waitForExistence(timeout: 20), "Ivy's chat with the note as its draft")
        XCTAssertEqual(chip.label, "Voice Memo 0:04")
        XCTAssertTrue(chatTitle().contains("Ivy"), chatTitle())
        XCTAssertFalse(app.buttons["memo.stop"].exists, "the shortcut's recording did not start")
        let state = try waitState("the request is dropped") { $0["request"] is NSNull && ($0["pendingNote"] as? Bool) == false }
        XCTAssertFalse(events(state).contains { $0.hasPrefix("memo started") })
    }

    @MainActor func testA31_SavedNoteQuestionThenDiscardAndRecord() throws {
        try launchWithSavedNoteAndShortcut()
        let seeded = String(try XCTUnwrap(events(state()).first { $0.hasPrefix("seeded ") }).dropFirst(7))
        XCTAssertTrue(FileManager.default.fileExists(atPath: seeded), "the note's file is there while the question is up")
        app.alerts.firstMatch.buttons["Discard and Record"].tap()
        XCTAssertTrue(app.buttons["memo.stop"].waitForExistence(timeout: 20), "the recorder starts")
        XCTAssertTrue(chatTitle().contains("Hermes"), "in the shortcut's bot's chat: \(chatTitle())")
        let state = try waitState("the note is gone") { ($0["pendingNote"] as? Bool) == false && $0["request"] is NSNull }
        XCTAssertTrue(events(state).contains("saved note discarded") && events(state).contains("memo started default"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: seeded), "its file was deleted")
        discardTake()
        XCTAssertTrue(app.buttons["composer.mic"].waitForExistence(timeout: 5))
        back()
        openBot("ivy")
        XCTAssertFalse(app.staticTexts["memo.chip.title"].waitForExistence(timeout: 2), "Ivy's chat has no draft")
    }

    @MainActor func testA32_SavedNoteQuestionThenCancel() throws {
        try launchWithSavedNoteAndShortcut()
        app.alerts.firstMatch.buttons["Cancel"].tap()
        var state = try waitState("the request is dropped and the note kept") { $0["request"] is NSNull && ($0["pendingNote"] as? Bool) == true }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertFalse(app.tables["chat.table"].exists, "nothing opened")
        XCTAssertFalse(events(state).contains { $0.hasPrefix("memo started") })
        // Coming back to the app brings the note into its chat quietly.
        foregroundAgain()
        let chip = app.staticTexts["memo.chip.title"]
        XCTAssertTrue(chip.waitForExistence(timeout: 20), "recovered on the next foreground")
        XCTAssertTrue(chatTitle().contains("Ivy"), chatTitle())
        state = try waitState("the note is taken") { ($0["pendingNote"] as? Bool) == false }
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    // MARK: A33. Another account's note; a note whose recording is gone

    @MainActor func testA33_AnotherAccountsNoteIsSaidOnceAndAMissingOneIsForgotten() throws {
        launch()
        leave()
        launch(["-HQDebugVoiceNote", "seed-pending-foreign:ivy"], reset: false, waitForBots: false)
        expectNotice(title: "Saved Voice Memo", message: "A saved voice memo belongs to another account or to another computer running Hermes. Sign back in to recover it.",
                     buttons: ["OK"], timeout: 40)
        shots("A33-note-of-another-account")
        app.alerts.firstMatch.buttons["OK"].tap()
        foregroundAgain()
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertFalse(app.alerts.firstMatch.exists, "not said again in this run")
        XCTAssertEqual(state()["pendingNote"] as? Bool, true, "the note is still stored")
        XCTAssertFalse(app.tables["chat.table"].exists)
        let foreign = String(try XCTUnwrap(events(state()).first { $0.hasPrefix("seeded ") }).dropFirst(7))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign), "and its recording untouched")

        leave()
        launch(["-HQDebugVoiceNote", "seed-pending-missing:ivy"], reset: false, waitForBots: false)
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 40))
        let state = try waitState("a note with no recording is forgotten") { ($0["pendingNote"] as? Bool) == false }
        XCTAssertTrue(events(state).contains("saved note gone"))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertFalse(app.alerts.firstMatch.exists, "without a word")
        XCTAssertFalse(app.tables["chat.table"].exists)
        try? FileManager.default.removeItem(atPath: (foreign as NSString).deletingLastPathComponent)
    }

    // MARK: A36, A38, A40, A42. Home Screen quick actions (five bots, listed chats)

    @MainActor func testA36_QuickActionsFollowTheListsAndTheLastChat() throws {
        let pages = try pagesAccount()
        launch(as: pages)
        var state = try waitState("four items") { self.actions($0).count == 4 }
        var items = actions(state)
        XCTAssertTrue(items[0].title.hasPrefix("New Voice Memo for ") && items[0].symbol == "mic" && items[0].type == "dispatch.memo", "\(items[0])")
        XCTAssertTrue(items[1].title.hasPrefix("Open ") && items[1].symbol == "bubble.left" && items[1].type == "dispatch.open", "\(items[1])")
        XCTAssertTrue(items[2].title.hasPrefix("Open ") && items[2].symbol == "bubble.left", "\(items[2])")
        XCTAssertTrue(items[3].title == "Search Chats" && items[3].symbol == "magnifyingglass" && items[3].type == "dispatch.search", "\(items[3])")
        XCTAssertNotEqual(items[1].title, items[2].title)
        let epoch = state["epoch"] as? String ?? ""
        XCTAssertNotNil(UUID(uuidString: epoch), "the sign-in epoch")
        let targets = state["targets"] as? [[String: Any]] ?? []
        XCTAssertTrue(targets.allSatisfy { ($0["id"] as? String ?? "").hasPrefix(epoch + ":") }, "every target is bound to this sign-in")
        XCTAssertTrue(targets.contains { $0["kind"] as? String == "session" } && targets.contains { $0["kind"] as? String == "bot" })
        XCTAssertLessThanOrEqual(targets.count, 128)
        note("A36 items: \(items.map(\.title)); \(targets.count) targets")

        // The chat last opened moves to the front.
        XCTAssertFalse(items[1].title == "Open Finance", "Finance is not the most recent yet")
        openBot("finance")
        state = try waitState("Finance is the first Open") { self.actions($0).count == 4 && self.actions($0)[1].title == "Open Finance" }
        // By the app's own clock: from the chat's open being applied to the items being handed to the system.
        let all = events(state), times = state["times"] as? [Double] ?? []
        if times.count == all.count, let end = all.lastIndex(where: { $0.hasPrefix("quick actions ") }) {
            let previous = all[..<end].lastIndex(where: { $0.hasPrefix("quick actions ") }) ?? -1
            if let start = all[(previous + 1)..<end].firstIndex(where: { $0.hasPrefix("visited bot:") }) {
                let rebuilt = Int(times[end] - times[start])
                note("A36 chat opened to items rebuilt, in the app: \(rebuilt) ms (the app gathers changes for up to 0.5 s first)")
                XCTAssertLessThan(rebuilt, 1000, "the items follow the chat within a second")
            } else {
                XCTFail("no visit before the items were rebuilt: \(all.suffix(12))")
            }
        } else {
            XCTFail("the items were never rebuilt: \(all.suffix(12))")
        }
        items = actions(state)
        XCTAssertEqual(items[0].title, "New Voice Memo for Finance", "and the memo item follows the most recent bot")
        back()
        openSession("s-reading")
        state = try waitState("a listed chat too") { self.actions($0).count == 4 && self.actions($0)[1].title == "Open Anything worth reading?" }
        XCTAssertEqual(actions(state)[2].title, "Open Finance")
        XCTAssertEqual(actions(state)[0].title, "New Voice Memo for Finance", "a listed chat is not a memo target")
    }

    @MainActor func testA37_TheHomeScreenMenuShowsTheItemsAndSearchChatsOpensSearch() throws {
        let pages = try pagesAccount()
        launch(as: pages)
        let items = actions(try waitState("four items") { self.actions($0).count == 4 })
        openIconMenu()
        let search = springboard.buttons["Search Chats"]
        XCTAssertTrue(search.waitForExistence(timeout: 8), "the menu shows Search Chats")
        for item in items {
            XCTAssertTrue(springboard.buttons[item.title].exists, "the menu shows “\(item.title)”")
        }
        save(XCUIScreen.main.screenshot(), "A37-home-screen-menu-" + Self.deviceLook)
        search.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "the app comes forward")
        XCTAssertTrue(app.collectionViews["sessions.list"].waitForExistence(timeout: 10), "on Sessions")
        let field = app.searchFields["sessions.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 8), "the search field shows")
        XCTAssertTrue(waitUntil(timeout: 8) { self.app.keyboards.count > 0 }, "the keyboard is up")
        field.typeText("report")                            // typing needs the focus: this fails if the field is not focused
        XCTAssertTrue(waitUntil(timeout: 5) { (field.value as? String) == "report" }, "the field took the typing: \(String(describing: field.value))")
        let state = try waitState("the real item was performed") { self.events($0).contains("routed search") }
        XCTAssertTrue(events(state).contains("quick action search"))
        note("A37 the Home Screen menu was driven for real: Search Chats tapped in Springboard")
        shots("A37-search-chats-focused")
    }

    @MainActor func testA38_OpenFromAQuickActionWarmAndCold() throws {
        let pages = try pagesAccount()
        launch(as: pages)
        var items = actions(try waitState("four items") { self.actions($0).count == 4 })
        // Warm: the second Open.
        let second = String(items[2].title.dropFirst(5))
        trigger("quick:open:1")
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 15), "the chat opens")
        XCTAssertTrue(waitUntil(timeout: 8) { self.chatTitle().contains(second) }, "“\(second)”: \(chatTitle())")
        XCTAssertFalse(app.buttons["memo.stop"].exists, "Open does not record")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        back()
        // Cold: leave with a chat on screen (a plain launch would reopen it), then launch by the first Open.
        openBot("inbox")
        items = actions(try waitState("Inbox is first") { self.actions($0).count == 4 && self.actions($0)[1].title == "Open Inbox" })
        back()
        openSession("s-report")
        items = actions(try waitState("the report chat is first") { self.actions($0).count == 4 && self.actions($0)[1].title == "Open The 2.4 report" })
        back()
        openBot("default")
        items = actions(try waitState("Hermes is first") { self.actions($0).count == 4 && self.actions($0)[1].title == "Open Hermes" })
        XCTAssertEqual(items[2].title, "Open The 2.4 report")
        leave()
        let began = Date()
        launch(["-HQDebugQuickAction", "open:1"], as: pages, reset: false, waitForBots: false)
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 40), "the chat opens")
        XCTAssertTrue(waitUntil(timeout: 10) { self.chatTitle().contains("2.4 report") }, "the item's chat, not the last one: \(chatTitle())")
        note("A38 cold quick action to its chat: \(ms(began)) ms (includes XCUITest's launch)")
        XCTAssertTrue(events(try waitState("routed") { self.events($0).contains("routed open") }).contains("quick action result true"))
        back()
        XCTAssertTrue(app.collectionViews["sessions.list"].waitForExistence(timeout: 8), "Back goes to Sessions")
        XCTAssertFalse(app.tables["chat.table"].exists, "the last chat was not pushed under it")
    }

    @MainActor func testA40_AStaleItemIsRefusedAndSigningOutEndsTheSignIn() throws {
        let pages = try pagesAccount()
        launch(as: pages)
        var state = try waitState("four items") { self.actions($0).count == 4 }
        let epoch = state["epoch"] as? String ?? ""
        trigger("quick:stale")
        state = try waitState("refused") { self.events($0).contains("quick action result false") }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertFalse(app.tables["chat.table"].exists || app.alerts.firstMatch.exists, "nothing opened and nothing was said")
        XCTAssertFalse(events(state).contains { $0.hasPrefix("routed") })

        // A42: sign out. The items, the pickers' bots and the sign-in go.
        trigger("sign-out")
        state = try waitState("signed out: no items", timeout: 30) {
            self.actions($0).isEmpty && self.names($0).isEmpty && ($0["epoch"] as? String) == "" && self.events($0).contains("signed out")
        }
        XCTAssertTrue((state["targets"] as? [Any])?.isEmpty == true && (state["donations"] as? [Any])?.isEmpty == true)
        openIconMenu()
        XCTAssertTrue(waitUntil(timeout: 8) { self.springboard.buttons["Remove App"].exists || self.springboard.buttons["Edit Home Screen"].exists },
                      "the icon's menu is up")
        for title in ["Search Chats", "New Voice Memo for Hermes", "Open Hermes"] {
            XCTAssertFalse(springboard.buttons[title].exists, "signed out: no “\(title)”")
        }
        save(XCUIScreen.main.screenshot(), "A42-home-screen-menu-signed-out-" + Self.deviceLook)
        closeIconMenu()

        // Signing in again is a new sign-in: another epoch, so an item captured before is refused.
        launch(as: pages)
        state = try waitState("items again") { self.actions($0).count == 4 }
        let again = state["epoch"] as? String ?? ""
        XCTAssertNotNil(UUID(uuidString: again))
        XCTAssertNotEqual(again, epoch, "a new sign-in epoch")
    }

    @MainActor func testA41_AnItemWhoseChatWasDeletedSaysSo() throws {
        let pages = try pagesAccount()
        launch(as: pages)
        openSession("s-report")
        try waitState("the chat is the first Open") { self.actions($0).count == 4 && self.actions($0)[1].title == "Open The 2.4 report" }
        back()
        app.tabBars.buttons["Bots"].tap()
        try pages.control("/__restore/delete", ["session_id": "s-report"])
        trigger("quick:open:0")
        // The list still holds the chat, so it is opened; the gateway answers that it no longer has it; the screen is
        // closed again and the owner is told. (Had the list been read in between, the item is not found: the other
        // sentence. Either way a sentence, and never a chat left open on nothing.)
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "it says so")
        let said = noticeText()
        let allowed = ["That chat is no longer available. Open \(Self.appName) and choose it again.", "That chat didn’t open."]
        XCTAssertTrue(allowed.contains { said.contains($0) }, "one of the two sentences: \(said)")
        XCTAssertTrue(said.contains("Shortcut Unavailable"), said)
        XCTAssertFalse(said.contains("Dispatch"), said)
        note("A41 outcome: “\(allowed.first { said.contains($0) } ?? said)”")
        shots("A41-chat-is-gone")
        alert.buttons["OK"].tap()
        XCTAssertFalse(app.tables["chat.table"].waitForExistence(timeout: 3), "no chat is left open")
        XCTAssertTrue(app.collectionViews["sessions.list"].exists || app.collectionViews["bots.list"].exists, "a list is on show, not a chat")
        let state = try waitState("it was said") { state in self.events(state).contains { $0.hasPrefix("notice That chat") } }
        XCTAssertFalse(events(state).contains("routed open"), "and it does not count as opened")
    }

    // MARK: A39. "New Voice Memo for <bot>"

    @MainActor func testA39_NewMemoQuickActionStartsTheRecorder() throws {
        launch()
        let items = actions(try waitState("four items") { self.actions($0).count == 4 })
        XCTAssertEqual(items.map(\.title), ["New Voice Memo for Hermes", "Open Hermes", "Open Ivy", "Search Chats"])
        app.tabBars.buttons["Sessions"].tap()
        trigger("quick:memo")
        XCTAssertTrue(app.buttons["memo.stop"].waitForExistence(timeout: 20), "the locked recorder shows")
        XCTAssertTrue(chatTitle().contains("Hermes"), chatTitle())
        let state = try waitState("routed") { self.events($0).contains("routed memo") }
        XCTAssertTrue(events(state).contains("memo started default") && events(state).contains("quick action result true"))
        shots("A39-new-memo-quick-action")
        // The same item again leaves the take alone.
        let before = recordingSeconds()
        trigger("quick:memo")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertGreaterThanOrEqual(recordingSeconds(), before)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        discardTake()
    }

    // MARK: A46, A48. The conversation is donated with a local alert, and forgotten at sign-out

    @MainActor func testA46_ALocalAlertDonatesItsConversation() throws {
        launch()
        openBot("default")
        // Without permission nothing alerts and nothing is donated (a fresh install has not been asked).
        trigger("local-alert:ivy")
        var state = try waitState("the alert was tried") { self.events($0).contains { $0.hasPrefix("local alert ") } }
        let allowedBefore = events(state).contains("local alert posted")
        if !allowedBefore {
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            XCTAssertTrue((self.state()["donations"] as? [Any])?.isEmpty == true, "no permission: no donation")
            note("A46 not allowed: no alert, no donation (checked)")
        } else {
            note("A46 not allowed: could not be checked in this run (the simulator had already allowed notifications)")
        }
        back()
        ensureNotificationPermission()
        openBot("default")
        let before = donations(self.state()).count
        trigger("local-alert:ivy")
        state = try waitState("the donation finished") { self.donations($0).count == before + 1 }
        let donated = try XCTUnwrap(donations(state).last)
        XCTAssertEqual(donated.conversation, Self.ivyChat, "Ivy's stored chat id")
        note("A46 donation result in the simulator: \(donated.result)")
        XCTAssertEqual(donated.result, "ok", "the simulator answered the donation with: \(donated.result)")
        XCTAssertTrue(events(state).contains("local alert posted"), "the alert posted as before")

        // The real flow: a reply that finishes in a chat that is not on screen.
        try account.control("/__fixture/plan", ["plans": [["replyDelay": 7, "replyText": "A slow synthetic reply."]]])
        back()
        openBot("ivy")
        let field = app.textViews["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText("Take your time")
        let sent = count("prompt.submit")
        app.buttons["composer.send"].tap()
        if !waitUntil(timeout: 3, { self.count("prompt.submit") > sent }) { app.buttons["composer.send"].tap() }
        XCTAssertTrue(waitUntil(timeout: 8) { self.count("prompt.submit") > sent }, "the prompt went out")
        back()
        openBot("default")
        state = try waitState("the finished reply donated Ivy's conversation", timeout: 40) { self.donations($0).count == before + 2 }
        XCTAssertEqual(donations(state).last?.conversation, Self.ivyChat)
        XCTAssertEqual(donations(state).last?.result, "ok")

        // A48: sign-out forgets them.
        trigger("sign-out")
        state = try waitState("signed out", timeout: 30) { self.events($0).contains("signed out") && self.donations($0).isEmpty }
        launch()
        state = try waitState("signed in again") { self.names($0) == ["Hermes", "Ivy"] }
        XCTAssertTrue(donations(state).isEmpty, "nothing is donated by signing in")
    }

    // MARK: A47. A conversation the system hands back opens its chat

    @MainActor func testA47_ADonatedConversationOpensItsChat() throws {
        let pages = try pagesAccount()
        launch(as: pages)
        openBot("finance")                                  // the chat a plain launch would reopen
        leave()
        launch(["-HQDebugContinueChat", botChat("deploys")], as: pages, reset: false, waitForBots: false)
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 40), "the chat opens")
        XCTAssertTrue(waitUntil(timeout: 10) { self.chatTitle().contains("Deploys") }, "Deploys' own chat: \(chatTitle())")
        back()
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 8), "a bot's own chat comes from Bots")
        // Warm: a listed chat comes from Sessions.
        trigger("continue:s-reading")
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil(timeout: 10) { self.chatTitle().contains("worth reading") }, chatTitle())
        back()
        XCTAssertTrue(app.collectionViews["sessions.list"].waitForExistence(timeout: 8), "a listed chat comes from Sessions")
        // An id an alert could never name: nothing opens.
        trigger("continue:not%20an%20id")
        let state = try waitState("refused") { self.events($0).contains("continue refused") }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertFalse(app.tables["chat.table"].exists || app.alerts.firstMatch.exists, "nothing opened")
        XCTAssertEqual(events(state).filter { $0.hasPrefix("continue ") && $0 != "continue refused" }.count, 2)
    }

    // MARK: Stress (docs/spec/3x-intents.md §14)

    /// S1: fifty shortcut runs in ten seconds give exactly one take.
    @MainActor func testS01_FiftyTriggersGiveOneTake() throws {
        launch()
        let began = Date()
        trigger("burst:50:200:voice-note:ivy", settle: false)
        XCTAssertTrue(app.buttons["memo.stop"].waitForExistence(timeout: 30), "a take is recording")
        let state = try waitState("everything settled", timeout: 60) {
            self.events($0).contains("burst done") && $0["request"] is NSNull && ($0["busy"] as? Bool) == false
        }
        note("S1 fifty runs of the shortcut settled \(ms(began)) ms after the first")
        let all = events(state)
        XCTAssertEqual(all.filter { $0 == "hook voice-note:ivy" }.count, 50)
        XCTAssertEqual(all.filter { $0.hasPrefix("perform RecordVoiceNoteIntent") }.count, 50, "every run reached the real intent")
        XCTAssertEqual(all.filter { $0.hasPrefix("memo started") }, ["memo started ivy"], "exactly one take")
        // One delivery at a time: a begin is always followed by its end before the next begin.
        var open = 0, most = 0
        for event in all {
            if event == "deliver begin" { open += 1; most = max(most, open) }
            if event == "deliver end" { open -= 1 }
        }
        XCTAssertEqual(most, 1, "deliveries never overlap")
        XCTAssertEqual(open, 0, "and every one ended")
        note("S1 deliveries for 50 runs: \(all.filter { $0 == "deliver begin" }.count)")
        XCTAssertTrue(chatTitle().contains("Ivy"), chatTitle())
        XCTAssertFalse(app.alerts.firstMatch.exists, "and no alert")
        XCTAssertEqual(app.buttons.matching(identifier: "memo.stop").count, 1, "one recorder")
        XCTAssertFalse(all.contains { $0.hasPrefix("notice ") || $0.hasPrefix("error ") }, "nothing was refused or said")
        let first = recordingSeconds()
        RunLoop.current.run(until: Date().addingTimeInterval(2.2))
        XCTAssertGreaterThan(recordingSeconds(), first, "it is recording")
        XCTAssertGreaterThanOrEqual(first, 8, "and it is the take that began with the first run, not a restarted one (\(first) s)")
        discardTake()
        XCTAssertTrue(app.buttons["composer.mic"].waitForExistence(timeout: 5))
        XCTAssertEqual(((try account.control("/__fixture/voice-state"))["uploads"] as? [Any])?.count, 0, "nothing was sent")
    }

    /// S2: alternating bots: one take, the other bot's runs are refused with one alert, never a stack.
    @MainActor func testS02_AlternatingBotsGiveOneTakeAndOneAlert() throws {
        launch()
        trigger("burst:20:250:voice-note:ivy,voice-note:default", settle: false)
        let state = try waitState("everything settled", timeout: 60) {
            self.events($0).contains("burst done") && $0["request"] is NSNull && ($0["busy"] as? Bool) == false
        }
        let all = events(state)
        XCTAssertEqual(all.filter { $0.hasPrefix("hook voice-note:") }.count, 20)
        XCTAssertEqual(all.filter { $0.hasPrefix("memo started") }.count, 1, "one take: \(all.filter { $0.hasPrefix("memo started") })")
        let taken = String(all.first { $0.hasPrefix("memo started ") }?.dropFirst(13) ?? "")
        XCTAssertTrue(app.buttons["memo.stop"].waitForExistence(timeout: 10), "it is recording")
        XCTAssertEqual(app.buttons.matching(identifier: "memo.stop").count, 1, "one recorder")
        XCTAssertTrue(chatTitle().contains(taken == "ivy" ? "Ivy" : "Hermes"), "in its own bot's chat (\(taken)): \(chatTitle())")
        // Every run for the other bot after the take started is refused with the one sentence, once at most (runs that
        // came while a delivery was busy are coalesced into the newest, so there can be fewer refusals than runs).
        // A run counts from the moment the intent wrote its request ("perform …"), not from the test hook that asked
        // for it a task hop earlier. One request can straddle the start: written for the other bot just before the take
        // started, its delivery not yet begun (had it begun, the take would not have started: the newest request
        // wins), and so refused just after. That is the last request before the start, when it is for the other bot.
        let finish = "notice Finish the current voice memo before starting another."
        let startIndex = all.firstIndex { $0.hasPrefix("memo started ") } ?? all.count
        let after = Array(all[startIndex...])
        let performOther = "perform RecordVoiceNoteIntent " + (taken == "ivy" ? "default" : "ivy")
        let laterRuns = after.filter { $0 == performOther }.count
        let straddling = all[..<startIndex].last { $0.hasPrefix("perform RecordVoiceNoteIntent ") } == performOther ? 1 : 0
        let refusals = after.filter { $0.hasPrefix("notice ") }
        XCTAssertTrue(refusals.allSatisfy { $0 == finish }, "after the take started the only sentence is “Finish the current…”: \(Set(refusals))")
        XCTAssertLessThanOrEqual(refusals.count, laterRuns + straddling, "one refusal per run at most: \(all)")
        if laterRuns >= 3 { XCTAssertGreaterThanOrEqual(refusals.count, 1, "the other bot's later runs were refused (\(laterRuns) runs)") }
        // Before it started, a run overtaken by the next one may have said so (§7.4), and that is all.
        let known = [finish, "notice Recording was canceled because the selected chat is no longer active. Run the shortcut again.",
                     "notice Recording was canceled because the selected chat is no longer active.",
                     "notice The selected bot’s chat changed before recording could start."]
        let notices = all.filter { $0.hasPrefix("notice ") }
        XCTAssertTrue(notices.allSatisfy { known.contains($0) }, "only the sentences of §7.4: \(Set(notices))")
        XCTAssertEqual(app.alerts.count, refusals.isEmpty ? 0 : 1, "one alert on screen for the refusals, never a stack")
        note("S2: take for \(taken); \(laterRuns) later runs for the other bot (and \(straddling) written just before the take started), \(refusals.count) refusals; \(notices.count - refusals.count) sentences before the take; alerts on screen: \(app.alerts.count)")
        if app.alerts.firstMatch.exists {
            app.alerts.firstMatch.buttons["OK"].tap()
            XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 1.5), "none behind it")
        }
        XCTAssertTrue(app.buttons["memo.stop"].exists, "the take still runs")
        discardTake()
    }

    /// S11: a cold launch with nothing cached and a slow roster: the runtime waits for the bots, then records once.
    @MainActor func testS11_AColdLaunchWaitsForASlowRoster() throws {
        try account.control("/__fixture/intents", ["delay": ["profiles.list": 5]])
        let began = Date()
        launch(["-HQDebugIntent", "voice-note-request:ivy"], waitForBots: false)        // a fresh sign-in: no cache at all
        XCTAssertTrue(app.buttons["memo.stop"].waitForExistence(timeout: 60), "it records once the roster has arrived")
        note("S11 cold launch, roster 5 s late, to the locked recorder: \(ms(began)) ms (includes XCUITest's launch)")
        XCTAssertTrue(chatTitle().contains("Ivy"), chatTitle())
        let state = try waitState("acknowledged") { $0["request"] is NSNull && ($0["busy"] as? Bool) == false }
        XCTAssertEqual(events(state).filter { $0.hasPrefix("memo started") }, ["memo started ivy"])
        XCTAssertFalse(events(state).contains { $0.hasPrefix("notice ") }, "and nothing was said")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        discardTake()
    }

    /// S31: the microphone is not allowed: the chat opens and the recorder's own notice says so.
    @MainActor func testS31_MicrophoneOffShowsTheRecordersNotice() throws {
        launch(microphone: "denied")
        trigger("voice-note:ivy")
        let title = app.staticTexts["memo.notice.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 25), "the recorder's notice shows")
        XCTAssertEqual(title.label, "Microphone Access Is Off")
        XCTAssertTrue(chatTitle().contains("Ivy"), "in Ivy's chat: \(chatTitle())")
        XCTAssertFalse(app.buttons["memo.stop"].exists, "nothing records")
        let state = try waitState("the request is acknowledged") { $0["request"] is NSNull && ($0["busy"] as? Bool) == false }
        XCTAssertFalse(app.alerts.firstMatch.exists, "one notice, the recorder's, and no alert over it")
        note("S31 microphone off: events \(events(state).filter { !$0.hasPrefix("quick actions") && !$0.hasPrefix("catalog") })")
        shots("S31-microphone-off")
    }

    /// S26: leaving the app between the trigger and the recorder: nothing records in the background; coming back inside
    /// the minute either starts it once or says why not.
    @MainActor func testS26_NothingRecordsInTheBackground() throws {
        launch()
        try holdDeliveryForSam(seconds: 4)
        trigger("voice-note-request:ivy", settle: false)
        try waitState("the delivery began") { self.events($0).contains("deliver begin") }
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(waitUntil(timeout: 10) { self.app.state != .runningForeground })
        RunLoop.current.run(until: Date().addingTimeInterval(7))
        var all = events(state())
        let startedAway = all.filter { $0.hasPrefix("memo started") }.count
        note("S26 takes started while in the background: \(startedAway)")
        XCTAssertEqual(startedAway, 0, "nothing records in the background")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let state = try waitState("settled", timeout: 40) { $0["request"] is NSNull && ($0["busy"] as? Bool) == false }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        all = events(self.state())
        XCTAssertLessThanOrEqual(all.filter { $0.hasPrefix("memo started") }.count, 1, "at most one take")
        _ = state
        if all.contains("memo started ivy") {
            XCTAssertTrue(app.buttons["memo.stop"].waitForExistence(timeout: 5) && chatTitle().contains("Ivy"))
            note("S26 outcome: the take started once after coming back")
            discardTake()
        } else {
            // The delivery that was cut short said why; the request is gone and nothing records later.
            let said = all.filter { $0.hasPrefix("notice ") }
            XCTAssertEqual(said.count, 1, "it said why, once: \(all.suffix(10))")
            XCTAssertEqual(said.first.map { String($0.dropFirst(7)) },
                           "Recording was canceled because the selected chat is no longer active. Run the shortcut again.")
            XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5), "and the sentence is on screen")
            XCTAssertFalse(app.tables["chat.table"].exists && chatTitle().contains("Ivy"), "and no chat was pushed while the app was away")
            shots("S26-canceled-after-leaving")
            note("S26 outcome: no take; it said “\(said.first?.dropFirst(7) ?? "")”")
            app.alerts.firstMatch.buttons["OK"].tap()
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            XCTAssertFalse(app.buttons["memo.stop"].exists, "nothing records later")
        }
    }

    /// S28: signing out while a request is being delivered: nothing is said, and nothing records after signing back in.
    @MainActor func testS28_SigningOutDropsAWaitingRequest() throws {
        launch()
        try holdDeliveryForSam(seconds: 6)
        trigger("voice-note-request:ivy", settle: false)
        try waitState("the delivery began with the request stored") { self.events($0).contains("deliver begin") && !($0["request"] is NSNull) }
        trigger("sign-out", settle: false)
        var state = try waitState("signed out: the request is gone", timeout: 30) {
            self.events($0).contains("signed out") && $0["request"] is NSNull && self.names($0).isEmpty
        }
        RunLoop.current.run(until: Date().addingTimeInterval(8))          // the held roster read has answered by now
        state = self.state()
        XCTAssertFalse(events(state).contains { $0.hasPrefix("memo started") }, "nothing recorded")
        XCTAssertFalse(events(state).contains { $0.hasPrefix("notice ") }, "and nothing was said: \(events(state).suffix(8))")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(app.buttons["memo.stop"].exists)
        // Signing in again inside the request's minute.
        try account.control("/__fixture/intents", ["delay": [:]])
        app.terminate()
        launch(reset: false)
        state = try waitState("signed in") { self.names($0) == ["Hermes", "Ivy"] }
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        XCTAssertFalse(app.buttons["memo.stop"].exists, "nothing records after signing back in")
        XCTAssertFalse(events(self.state()).contains { $0.hasPrefix("memo started") })
        XCTAssertFalse(app.tables["chat.table"].exists || app.alerts.firstMatch.exists)
    }

    /// S32: the app ends right after the shortcut wrote its request; a relaunch inside the minute records once.
    /// S33: ended during a take, nothing starts by itself afterwards.
    @MainActor func testS32_ARequestSurvivesARelaunchInsideItsMinuteOnly() throws {
        launch()
        try holdDeliveryForSam(seconds: 8)
        trigger("voice-note-request:ivy", settle: false)
        try waitState("the request is stored and being delivered") { self.events($0).contains("deliver begin") && !($0["request"] is NSNull) }
        app.terminate()                                                   // ended with the request stored
        try account.control("/__fixture/intents", ["delay": [:]])
        launch(reset: false, waitForBots: false)
        XCTAssertTrue(app.buttons["memo.stop"].waitForExistence(timeout: 40), "relaunched inside the minute: it records")
        XCTAssertTrue(chatTitle().contains("Ivy"), chatTitle())
        var state = try waitState("acknowledged") { $0["request"] is NSNull }
        XCTAssertEqual(events(state).filter { $0 == "memo started ivy" }.count, 1, "once")
        // S33: the app ends during the take.
        leave()
        launch(reset: false, waitForBots: false)
        XCTAssertTrue(waitUntil(timeout: 40) { self.app.collectionViews["bots.list"].exists || self.app.tables["chat.table"].exists })
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        state = self.state()
        XCTAssertTrue(state["request"] is NSNull, "the request is gone")
        XCTAssertFalse(events(state).contains { $0.hasPrefix("memo started") }, "nothing started by itself after the relaunch")
        XCTAssertFalse(app.buttons["memo.stop"].exists)
    }

    /// Makes the next request for Ivy wait in a roster read for `seconds`: the app's own roster loses Ivy (removed on
    /// the gateway, seen at the next foreground), then the gateway has Ivy again and answers `profiles.list` slowly.
    @MainActor private func holdDeliveryForSam(seconds: Int) throws {
        try account.control("/__fixture/intents", ["removed": ["ivy"]])
        refreshBots()
        XCTAssertTrue(waitUntil(timeout: 25) { !self.app.cells["bot-row-ivy"].exists && !self.app.cells["bot-tile-ivy"].exists
                                               && self.names(self.state()) == ["Hermes"] }, "Ivy left the app's roster")
        try account.control("/__fixture/intents", ["removed": [], "delay": ["profiles.list": seconds]])
    }

    // MARK: Helpers

    private static var outputRoot: String {
        if let shots = environment["HQN_UI_SHOTS"], !shots.isEmpty { return URL(fileURLWithPath: shots).deletingLastPathComponent().appending(path: "intents-ui").path }
        return NSTemporaryDirectory() + "hqn-intents-ui"
    }

    private func pagesAccount() throws -> FixtureAccount {
        guard let path = Self.environment["HQN_UI_CREDENTIALS_PAGES"], !path.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_HQN_UI_CREDENTIALS_PAGES to the restore fixture's credentials (scripts/e2e-intents.sh does).")
        }
        let pages = try FixtureAccount.load(path: path)
        try pages.control("/__restore/reset", [:])
        return pages
    }

    /// The pages fixture's id for a bot's own chat.
    private func botChat(_ profile: String) -> String {
        "20261009_090000_bc" + SHA256.hash(data: Data(profile.utf8)).map { String(format: "%02x", $0) }.joined().prefix(6)
    }

    /// One sign-in per launch, from the fixture's invented credentials (DEBUG simulator builds only).
    /// `systemRefresh`: the app really tells the system when the pickers' bots changed. iOS rations those calls (about
    /// five in a few minutes), so only the test that looks in the Shortcuts app asks for it; the others count them.
    @MainActor private func launch(_ extra: [String] = [], as who: FixtureAccount? = nil, reset: Bool = true, waitForBots: Bool = true,
                                   microphone: String = "granted", systemRefresh: Bool = false) {
        let who = who ?? account!
        let app = XCUIApplication()
        var arguments = ["-HQDebugMemoFixture", microphone, "-HQDebugIntentsOut", folder]
        if !systemRefresh { arguments += ["-HQDebugQuietShortcutParameters", "YES"] }
        if reset { arguments += ["-HQDebugResetAccounts", "YES", "-HQDebugResetVoice", "YES", "-HQDebugResetIntents", "YES"] }
        app.launchArguments = arguments + extra
        app.launchEnvironment = ["HQN_SIGNIN_URL": who.url, "HQN_SIGNIN_USERNAME": who.username, "HQN_SIGNIN_PASSWORD": who.password]
        app.launch()
        self.app = app
        guard waitForBots else { return }
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 40), "signed in: the Bots list shows")
        XCTAssertTrue(waitUntil(timeout: 20) { !self.names(self.state()).isEmpty }, "the pickers' bots are stored")
    }

    /// To the Home Screen, then the end of the process, as iOS ends a backgrounded app.
    @MainActor private func leave() {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(waitUntil(timeout: 10) { self.app.state == .runningBackground || self.app.state == .runningBackgroundSuspended },
                      "the app went to the background")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        app.terminate()
    }

    /// Home and back: what the owner does between changing something on the gateway and looking again.
    @MainActor private func foregroundAgain() {
        XCUIDevice.shared.press(.home)
        _ = waitUntil(timeout: 10) { self.app.state != .runningForeground }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    }

    /// Runs a hook word on the running app, as the system would run the shortcut: the link is opened by the system
    /// (`XCUIApplication.open` would relaunch the app). A simulator that asks "Open in <app>?" is answered.
    @MainActor private func trigger(_ word: String, settle: Bool = true) {
        XCUIDevice.shared.system.open(URL(string: "\(Self.scheme)://debug-intent/\(word)")!)
        if Self.asksToOpen != false {
            let open = springboard.buttons["Open"]
            let asked = open.waitForExistence(timeout: Self.asksToOpen == nil ? 4 : 8)
            if Self.asksToOpen == nil { Self.asksToOpen = asked }
            if asked { open.tap() }
        }
        if settle { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
    }

    /// Pull to refresh on the Bots list: the roster is read now (a foreground alone reads it on a 30 s cadence).
    /// Pull to refresh on the Bots list, until the fixture has answered one more roster read (a pull made while an
    /// alert was still leaving the screen is not a pull).
    @MainActor private func refreshBots() {
        let list = app.collectionViews["bots.list"]
        if !list.isHittable, app.tabBars.buttons["Bots"].isHittable { app.tabBars.buttons["Bots"].tap() }
        XCTAssertTrue(list.waitForExistence(timeout: 10), "the Bots list")
        let before = count("profiles.list")
        for _ in 0..<4 {
            _ = waitUntil(timeout: 3) { !self.app.alerts.firstMatch.exists && list.isHittable }
            let top = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            top.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
            if waitUntil(timeout: 4) { self.count("profiles.list") > before } {
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                return
            }
        }
        XCTFail("the pull did not make the app read its roster")
    }

    @MainActor private func openBot(_ id: String) {
        if !app.collectionViews["bots.list"].isHittable, app.tabBars.buttons["Bots"].isHittable { app.tabBars.buttons["Bots"].tap() }
        XCTAssertTrue(waitUntil(timeout: 20) { self.app.cells["bot-row-\(id)"].exists || self.app.cells["bot-tile-\(id)"].exists }, "the \(id) bot is listed")
        let row = app.cells["bot-row-\(id)"].exists ? app.cells["bot-row-\(id)"] : app.cells["bot-tile-\(id)"]
        row.tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 15), "the chat opens")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    @MainActor private func openSession(_ id: String) {
        app.tabBars.buttons["Sessions"].tap()
        let row = app.cells["session-row-\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the \(id) chat is listed")
        row.tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 15), "the chat opens")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    @MainActor private func back() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    }

    @MainActor private func chatTitle() -> String {
        let title = app.descendants(matching: .any)["chat.title"]
        return title.exists ? title.label : ""
    }

    /// The locked recorder's time, in seconds ("Recording, 0:04").
    @MainActor private func recordingSeconds() -> Int {
        let status = app.descendants(matching: .any)["memo.status"]
        guard status.exists else { return -1 }
        let text = [status.label, status.value as? String ?? ""].first { $0.contains(":") } ?? ""
        let digits = text.split(whereSeparator: { !$0.isNumber })
        guard digits.count >= 2, let minutes = Int(digits[digits.count - 2]), let seconds = Int(digits[digits.count - 1]) else { return -1 }
        return minutes * 60 + seconds
    }

    // MARK: The shortcuts' alerts

    @MainActor private func noticeText() -> String {
        let alert = app.alerts.firstMatch
        return ([alert.label] + alert.staticTexts.allElementsBoundByIndex.map(\.label)).joined(separator: " | ")
    }

    @MainActor private func expectNotice(title: String, message: String, buttons: [String], timeout: TimeInterval = 20) {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: timeout), "the alert “\(title)” shows")
        XCTAssertTrue(waitUntil(timeout: 5) { self.noticeText().contains(message) }, "its message: \(noticeText())")
        XCTAssertTrue(noticeText().contains(title), "its title: \(noticeText())")
        XCTAssertEqual(alert.buttons.allElementsBoundByIndex.map(\.label), buttons, "its buttons")
        XCTAssertEqual(app.alerts.count, 1, "one alert")
    }

    /// A cold launch with an older build's note for Ivy and a shortcut for Hermes: the question (A29).
    @MainActor private func launchWithSavedNoteAndShortcut() throws {
        launch()
        leave()
        launch(["-HQDebugVoiceNote", "seed-pending:ivy", "-HQDebugIntent", "voice-note:default"], reset: false, waitForBots: false)
        expectNotice(title: "Saved Voice Memo", message: "Your memo for Ivy is waiting to be added to its chat.",
                     buttons: ["Open Chat", "Discard and Record", "Cancel"], timeout: 40)
        let state = try waitState("asked, with both waiting") { self.events($0).contains("ask saved note") }
        XCTAssertFalse(state["request"] is NSNull, "the request waits for the answer")
        XCTAssertEqual(state["pendingNote"] as? Bool, true)
        XCTAssertFalse(app.tables["chat.table"].exists, "no chat opened yet")
        XCTAssertFalse(events(state).contains { $0.hasPrefix("memo started") })
    }

    // MARK: Notifications permission (as UITests/push does)

    @MainActor private func ensureNotificationPermission() {
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
        let list = app.collectionViews["notifications.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5), "Settings › Notifications opens")
        for _ in 0..<4 where !app.buttons["notifications.test"].isHittable { list.swipeUp() }
        app.buttons["notifications.test"].tap()
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let close = app.buttons["settings.close"]
        if close.waitForExistence(timeout: 1) { close.tap() }
        app.tabBars.buttons["Bots"].tap()
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 8))
    }

    // MARK: The state file and the fixtures' ledgers

    private func state() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: folder + "/intents-state.json"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    @MainActor @discardableResult
    private func waitState(_ what: String, timeout: TimeInterval = 20, _ condition: ([String: Any]) -> Bool) throws -> [String: Any] {
        var last: [String: Any] = [:]
        let met = waitUntil(timeout: timeout) {
            last = self.state()
            return !last.isEmpty && condition(last)
        }
        if !met {
            var shown = last
            shown["events"] = Array(events(last).suffix(25))
            XCTFail("\(what): the state file never showed it. Last: \(shown)")
            throw NSError(domain: "intents", code: 1, userInfo: [NSLocalizedDescriptionKey: what])
        }
        return last
    }

    private func events(_ state: [String: Any]) -> [String] { state["events"] as? [String] ?? [] }

    /// The app's own time from the last `from` event to the first `to` event after it (ms), by the state file's clock.
    private func elapsed(_ state: [String: Any], from: String, to: String) -> Int? {
        let all = events(state), times = state["times"] as? [Double] ?? []
        guard times.count == all.count, let start = all.lastIndex(where: { $0.hasPrefix(from) }),
              let end = all[start...].firstIndex(where: { $0.hasPrefix(to) }) else { return nil }
        return Int(times[end] - times[start])
    }
    private func names(_ state: [String: Any]) -> [String] { (state["catalog"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } }

    private func actions(_ state: [String: Any]) -> [(type: String, title: String, symbol: String)] {
        (state["quickActions"] as? [[String: Any]] ?? []).map { ($0["type"] as? String ?? "", $0["title"] as? String ?? "", $0["symbol"] as? String ?? "") }
    }

    private func donations(_ state: [String: Any]) -> [(conversation: String, result: String)] {
        (state["donations"] as? [[String: String]] ?? []).map { ($0["conversation"] ?? "", $0["result"] ?? "") }
    }

    /// How many times the fixture was asked `method`.
    private func count(_ method: String) -> Int {
        (((try? account.control("/__fixture/intents-state"))?["counts"] as? [String: Any])?[method] as? Int) ?? 0
    }

    /// The prompts the gateway admitted.
    private func prompts() -> [[String: Any]] {
        ((try? account.control("/__fixture/voice-state"))?["prompts"] as? [[String: Any]] ?? []).filter { ($0["refused"] as? Bool) != true }
    }

    // MARK: Screens and notes

    /// The app's screen in light and in dark, to the shots folder and the result bundle. The app is put in each
    /// appearance by its `look:` hook: `XCUIDevice.shared.appearance` changed nothing in this simulator (every "dark"
    /// screenshot of the first runs was a light one).
    @MainActor private func shots(_ name: String) {
        trigger("look:light")
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let light = app.screenshot()
        save(light, name + "-light")
        trigger("look:dark")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let dark = app.screenshot()
        save(dark, name + "-dark")
        XCTAssertLessThan(Self.brightness(dark), Self.brightness(light) - 0.2,
                          "“\(name)”: the dark screenshot is darker than the light one")
        trigger("look:system")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    /// Mean brightness of a screenshot (0 black … 1 white), from a 32 × 64 copy.
    private static func brightness(_ screenshot: XCUIScreenshot) -> Double {
        guard let image = screenshot.image.cgImage else { return 1 }
        let width = 32, height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sum = 0
        for index in stride(from: 0, to: pixels.count, by: 4) { sum += Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2]) }
        return Double(sum) / Double(width * height * 3 * 255)
    }

    /// The Home Screen, with the menu a long press on the app's icon brings (the quick actions are its first rows).
    /// The appearance is never changed while the app is behind the Home Screen: that stalled the runner for minutes.
    @MainActor private func openIconMenu() {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(waitUntil(timeout: 10) { self.app.state != .runningForeground }, "the app went to the background")
        let icon = springboard.icons[Self.appName]
        XCTAssertTrue(icon.waitForExistence(timeout: 10), "the app's icon is on the Home Screen")
        for _ in 0..<4 where !icon.isHittable { springboard.swipeLeft() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        icon.press(forDuration: 1.3)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    }

    /// Closes the icon's menu and brings the app back on screen.
    @MainActor private func closeIconMenu() {
        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "the app is back on screen")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    /// Throws the running take away. A take of ten seconds or more asks first ("Delete This 0:14 Voice Memo?").
    @MainActor private func discardTake() {
        app.buttons["memo.delete"].tap()
        let delete = app.alerts.buttons["Delete"]
        if delete.waitForExistence(timeout: 1.5) { delete.tap() }
        XCTAssertTrue(waitUntil(timeout: 8) { !self.app.buttons["memo.stop"].exists }, "the recorder closed")
    }

    @MainActor private func save(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let dir = Self.environment["HQN_UI_SHOTS"], !dir.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "intents-\(name).png"))
    }

    /// A number or an outcome for the report (appended to intents-ui/notes.txt beside the shots folder).
    private func note(_ line: String) {
        let path = Self.outputRoot + "/notes.txt"
        try? FileManager.default.createDirectory(atPath: Self.outputRoot, withIntermediateDirectories: true)
        let text = line + "\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func ms(_ since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }

    @MainActor @discardableResult
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        return condition()
    }
}
