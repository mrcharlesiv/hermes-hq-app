// Helpers of the live-voice end-to-end tests (TalkEndToEndTests): launching with the stand-in microphone and speaker,
// the probe, the fixture's ledger, and the few gestures every test repeats.

import XCTest

extension TalkEndToEndTests {
    // MARK: Launching

    /// One sign-in per launch from the fixture's invented credentials (DEBUG simulator builds only). `reset: false`
    /// keeps the account and the voice keys of the launch before. `introSeen: nil` leaves the intro's key alone.
    /// `tips: false` marks the three voice tips as seen for this launch, so no popover is in a test's way.
    /// `speaks: true` turns Read Replies Aloud and the conversation's Speak Replies on; `false` (with `reset`) turns both
    /// off, a speech-to-text-only conversation (spec §4.3 rule 7), though a real conversation speaks until switched off.
    @MainActor func launch(_ extra: [String] = [], script: String = "", reset: Bool = true, permission: String = "granted",
                           introSeen: Bool? = true, tips: Bool = false, speaker: String = "fixture",
                           speaks: Bool = false, opens: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-HQDebugTalkFixture", permission, "-HQDebugMemoFixture", permission == "denied" ? "denied" : "granted",
                         "-HQDebugTalkSpeaker", speaker, "-HQDebugTalkProbe", "YES"]
        if !script.isEmpty { arguments += ["-HQDebugTalkScript", script] }
        if reset { arguments += ["-HQDebugResetAccounts", "YES", "-HQDebugResetVoice", "YES"] }
        if let introSeen { arguments += ["-HQDebugTalkIntroSeen", introSeen ? "YES" : "NO"] }
        // Both switches: a conversation speaks until told not to, so a fresh launch says "NO" too. A relaunch without
        // `reset` keeps the launch before's, and a test's own flag wins.
        if !extra.contains("-HQDebugReadRepliesAloud"), speaks || reset {
            arguments += ["-HQDebugReadRepliesAloud", speaks ? "YES" : "NO"]
        }
        if let opens { arguments += ["-HQDebugOpenBot", opens] }
        if !tips { arguments += ["-hq.voice.tip.talk", "YES", "-hq.voice.tip.nowHold", "YES", "-hq.voice.tip.holdToRecord", "YES"] }
        app.launchArguments = arguments + extra
        app.launchEnvironment = ["HQN_SIGNIN_URL": account.url, "HQN_SIGNIN_USERNAME": account.username,
                                 "HQN_SIGNIN_PASSWORD": account.password]
        app.launch()
        if opens != nil {
            XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 40), "the chat opens at launch")
            Thread.sleep(forTimeInterval: 0.8)
            return app
        }
        // The app comes back on the tab it was left on: a relaunch after Settings starts on More.
        let row = app.cells["bot-row-default"], bots = app.buttons["tab-bots"]
        _ = waitUntil(timeout: 30) { row.exists || bots.exists }
        if !row.exists, bots.exists, !bots.isSelected { bots.tap() }
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the Bots list shows")
        return app
    }

    @MainActor func openChat(_ app: XCUIApplication, _ profile: String) {
        let row = app.cells["bot-row-\(profile)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 8), "the chat opens")
        Thread.sleep(forTimeInterval: 0.8)
    }

    @MainActor func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        _ = app.cells["bot-row-default"].waitForExistence(timeout: 5)
    }

    // MARK: Elements

    @MainActor func talk(_ app: XCUIApplication) -> XCUIElement { app.buttons["composer.talk"] }
    @MainActor func plus(_ app: XCUIApplication) -> XCUIElement { app.buttons["composer.plus"] }
    @MainActor func dockTitle(_ app: XCUIApplication) -> XCUIElement { app.staticTexts["talk.dock.title"] }
    /// The state's advice. The one-row bar shows it only as the first listening turn's status; VoiceOver hears it as the
    /// status's hint, which XCUITest cannot read, so the probe reports it.
    @MainActor func dockHint(_ app: XCUIApplication) -> String { probe(app)["hint"] as? String ?? "" }
    /// The line above the bar: only a turn's failure or speech dropped while reconnecting.
    @MainActor func dockNotice(_ app: XCUIApplication) -> XCUIElement { app.staticTexts["talk.dock.problem"] }

    /// Any element whose label is (or contains) the text.
    @MainActor func labelled(_ app: XCUIApplication, _ text: String, contains: Bool = false) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: contains ? "label CONTAINS %@" : "label == %@", text)).firstMatch
    }

    @MainActor func inChat(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.tables["chat.table"].descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor func waitForTitle(_ app: XCUIApplication, _ text: String, timeout: TimeInterval) -> Bool {
        let title = dockTitle(app)
        return waitUntil(timeout: timeout) { title.exists && title.label == text }
    }

    /// Every title the dock showed until `stop` (or the time ran out), in order, without repeats.
    @MainActor func titles(_ app: XCUIApplication, until stop: String, timeout: TimeInterval) -> [String] {
        let title = dockTitle(app)
        var seen: [String] = []
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if title.exists {
                let now = title.label
                if seen.last != now { seen.append(now) }
                if now == stop { break }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return seen
    }

    /// `wanted` appears in `seen` in this order (other titles may sit between).
    func inOrder(_ seen: [String], _ wanted: [String]) -> Bool {
        var from = seen.startIndex
        for item in wanted {
            guard let found = seen[from...].firstIndex(of: item) else { return false }
            from = seen.index(after: found)
        }
        return true
    }

    /// Ends the live conversation from its dock.
    @MainActor func end(_ app: XCUIApplication) {
        let button = app.buttons["talk.dock.end"]
        guard button.waitForExistence(timeout: 4) else { return }
        button.tap()
        _ = waitUntil(timeout: 5) { !button.exists }
    }

    /// Holds `element` until its menu shows `item` (a press during a list's first reload can be lost).
    @MainActor @discardableResult
    func holdMenu(_ app: XCUIApplication, _ element: XCUIElement, _ item: String, prefix: Bool = false) -> XCUIElement {
        let wanted = menuItem(app, item, prefix: prefix)
        for _ in 0..<3 {
            element.press(forDuration: 1.0)
            if wanted.waitForExistence(timeout: 4) { break }
        }
        XCTAssertTrue(wanted.exists, "the menu shows \(item)")
        return wanted
    }

    /// A button of the open menu with this label (or a label that starts with it). The reply's own Copy and Read Aloud
    /// buttons stay in the tree behind a hold menu and carry the same labels: they are `chat.…` and never match.
    @MainActor func menuItem(_ app: XCUIApplication, _ label: String, prefix: Bool = false) -> XCUIElement {
        let match = prefix ? "label BEGINSWITH %@" : "label == %@"
        return app.buttons.matching(NSPredicate(format: "\(match) AND NOT (identifier BEGINSWITH 'chat.')", label)).firstMatch
    }

    /// Holds Talk until the voice options menu is open.
    @MainActor func openOptions(_ app: XCUIApplication) {
        let button = talk(app)
        XCTAssertTrue(button.waitForExistence(timeout: 8), "Talk is the circle")
        let first = app.buttons["voice.options.start"]
        for _ in 0..<3 {
            button.press(forDuration: 1.0)
            if first.waitForExistence(timeout: 4) { break }
        }
        XCTAssertTrue(first.exists, "holding Talk opens the voice options")
    }

    @MainActor func dismissMenu(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        Thread.sleep(forTimeInterval: 0.6)
    }

    /// Types a message and sends it. A tap that lands while the keyboard is still settling after the typing can be
    /// lost on a busy simulator, so Send is tapped once more when nothing went out.
    @MainActor func send(_ app: XCUIApplication, _ text: String) {
        let field = app.textViews["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
        let before = prompts().count
        app.buttons["composer.send"].tap()
        if !waitUntil(timeout: 4, { self.prompts().count > before }) { app.buttons["composer.send"].tap() }
        XCTAssertTrue(waitUntil(timeout: 8) { self.prompts().count > before }, "the message went out")
    }

    // MARK: The probe and the ledger

    /// What the app's audio pieces say right now (`talk.debug`, refreshed four times a second).
    @MainActor func probe(_ app: XCUIApplication) -> [String: Any] {
        let element = app.staticTexts["talk.debug"]
        guard element.exists, let text = element.value as? String, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    func voiceState() throws -> [String: Any] { try account.control("/__fixture/voice-state") }

    /// The prompts the gateway admitted.
    func prompts() -> [[String: Any]] {
        ((try? voiceState())?["prompts"] as? [[String: Any]] ?? []).filter { ($0["refused"] as? Bool) != true }
    }

    func ledger(_ key: String) -> [[String: Any]] { (try? voiceState())?[key] as? [[String: Any]] ?? [] }

    /// The warm-up leases a conversation holds on the gateway. Read Replies Aloud keeps its own speech lease while a
    /// chat is on screen (`…:read-aloud:…`), which is not a conversation's and does not count here.
    func talkLeases() -> (tts: Int, stt: Int) {
        let now = (try? voiceState())?["leases"] as? [String: [Any]] ?? [:]
        func count(_ kind: String) -> Int { (now[kind] ?? []).filter { "\($0)".contains(":talk:") }.count }
        return (count("tts"), count("stt"))
    }

    // MARK: Screenshots and waiting

    @MainActor func shot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor @discardableResult
    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        return condition()
    }
}
