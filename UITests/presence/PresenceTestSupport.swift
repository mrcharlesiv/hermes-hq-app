// Shared by the presence UI tests (docs/spec/3x-presence.md §13, §14). They run against the presence fixture
// (scripts/e2e-presence.sh starts scripts/fixtures/presence-gateway.py and passes TEST_RUNNER_HQN_UI_CREDENTIALS +
// TEST_RUNNER_HQN_UI_PRESENCE=1; without them every test skips). All values are invented.

import XCTest

class PresenceUITestCase: XCTestCase {
    var account: FixtureAccount!
    var app: XCUIApplication!

    static let installTitle = "Install the Hermes HQ browser add-on on this Hermes."
    static let installPrefix = "Please install Hermes HQ's browser plugin"
    /// `HQN_UI_DARK=1` (scripts/e2e-presence.sh with HQN_PRESENCE_DARK=1): the whole run in dark appearance, and every
    /// screenshot named "-dark". The appearance is set before the app launches (switching it under a running app did
    /// not take on this simulator).
    static var darkRun: Bool { ProcessInfo.processInfo.environment["HQN_UI_DARK"] == "1" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["HQN_UI_PRESENCE"] == "1" else {
            throw XCTSkip("Run with scripts/e2e-presence.sh <UDID> (the presence fixture).")
        }
        account = try FixtureAccount.load()
        try account.control("/__fixture/presence/reset", [:])
    }

    override func tearDown() {
        // Never leave the fixture down or the simulator dark for the next test.
        _ = try? account?.control("/__fixture/presence", ["gateway": "up"])
        MainActor.assumeIsolated { XCUIDevice.shared.appearance = .light }
        super.tearDown()
    }

    // MARK: Launch and getting around

    /// Signs in to the fixture. `-HQDebugNoticeHold` keeps the notice up long enough to read; `-HQDebugPeekHold` the reply peek.
    @MainActor func launch(_ arguments: [String] = [], hold: Bool = true) {
        let app = XCUIApplication()
        app.launchArguments = ["-HQDebugResetAccounts", "YES"] + (hold ? ["-HQDebugNoticeHold", "YES", "-HQDebugPeekHold", "YES"] : []) + arguments
        app.launchEnvironment = ["HQN_SIGNIN_URL": account.url, "HQN_SIGNIN_USERNAME": account.username,
                                 "HQN_SIGNIN_PASSWORD": account.password]
        XCUIDevice.shared.appearance = Self.darkRun ? .dark : .light
        app.launch()
        self.app = app
        XCTAssertTrue(app.cells["bot-row-default"].waitForExistence(timeout: 30), "signed in: the Bots list shows")
        let offer = app.alerts.firstMatch
        if offer.waitForExistence(timeout: 1.5), offer.buttons["Not Now"].exists { offer.buttons["Not Now"].tap() }
    }

    @MainActor func row(_ bot: String) -> XCUIElement { app.cells["bot-row-\(bot)"] }

    @MainActor func openChat(_ bot: String = "default") {
        let cell = row(bot)
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "\(bot)'s row shows")
        cell.tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 10), "the chat opens")
    }

    @MainActor func goBack() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(row("default").waitForExistence(timeout: 10), "back on the Bots list")
        pause(0.5)
    }

    /// Opens the bot's chat once and comes back: the chat is bound, so its events are known to be this bot's (spec §3.1).
    @MainActor func bind(_ bot: String) {
        openChat(bot)
        pause(1.5)
        goBack()
    }

    @MainActor func openBotInfo(_ bot: String = "ivy") {
        let cell = row(bot)
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "the bot's row shows")
        cell.press(forDuration: 1.0)
        let info = app.buttons["Bot Info"]
        XCTAssertTrue(info.waitForExistence(timeout: 5), "the row menu opens")
        info.tap()
        let list = app.collectionViews["bot-info.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 8), "Bot Info opens")
        // The Computer group sits low in the sheet: bring it up, down to its last row (the switch), in small steps so
        // its first row stays on screen.
        for _ in 0..<5 where !app.buttons["bot-info.browser.watch"].exists { list.swipeUp() }
        let toggle = app.switches["bot-info.computer.alert"]
        for _ in 0..<8 where !(toggle.exists && toggle.isHittable) { nudge(list, up: true) }
    }

    /// A short scroll (about a quarter of the list's height), so rows near the edge stay loaded.
    @MainActor func nudge(_ list: XCUIElement, up: Bool) {
        let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.7 : 0.45))
        let to = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.45 : 0.7))
        from.press(forDuration: 0.05, thenDragTo: to)
        pause(0.4)
    }

    /// "Know When a Bot Replies?" (the app offers it after the first message sent): Not Now.
    @MainActor func dismissOffer(wait: TimeInterval = 0) {
        let offer = app.alerts["Know When a Bot Replies?"]
        guard wait > 0 ? offer.waitForExistence(timeout: wait) : offer.exists else { return }
        if offer.buttons["Not Now"].exists { offer.buttons["Not Now"].tap() }
        pause(0.5)
    }

    @MainActor func closeBotInfo() {
        let close = app.buttons["bot-info.close"]
        if close.exists { close.tap() }
        XCTAssertTrue(waitUntil(timeout: 8) { !self.app.collectionViews["bot-info.list"].exists }, "Bot Info closes")
    }

    /// Chat ⋯: opens the menu and returns its Watch Browser item.
    @MainActor func openMoreMenu() -> XCUIElement {
        let more = app.buttons["chat.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 8), "the chat has ⋯")
        more.tap()
        let byId = app.buttons["chat.more.browser"]
        if byId.waitForExistence(timeout: 3) { return byId }
        return app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Watch Browser'")).firstMatch
    }

    @MainActor func dismissMenu() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82)).tap()
        pause(0.6)
    }

    @MainActor func tapSwitch(_ id: String) {
        let element = app.switches[id]
        XCTAssertTrue(element.waitForExistence(timeout: 8), "\(id) shows")
        if element.switches.firstMatch.exists { element.switches.firstMatch.tap() } else { element.tap() }
    }

    @MainActor func switchIsOn(_ id: String) -> Bool { (app.switches[id].value as? String) == "1" }

    @MainActor func send(_ text: String) {
        let field = app.textViews["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the composer shows")
        dismissOffer()
        XCTAssertTrue(waitUntil(timeout: 10) { field.isHittable }, "the composer can be tapped")
        field.tap()
        field.typeText(text)
        let button = app.buttons["composer.send"]
        for _ in 0..<3 {
            XCTAssertTrue(waitUntil(timeout: 5) { button.exists && button.isEnabled && button.isHittable })
            pause(0.4)
            button.tap()
            if waitUntil(timeout: 3, { !field.exists || ((field.value as? String) ?? "").isEmpty || !((field.value as? String) ?? "").contains(text) }) { return }
        }
        XCTFail("the message didn't send")
    }

    // MARK: What is on screen

    @MainActor var notice: XCUIElement { app.descendants(matching: .any)["presence-notice"] }

    /// A tap on the notice by its place on screen, as a finger lands: not through the element, so nothing about what
    /// else is on screen (an alert) is consulted first.
    @MainActor func tapNoticeByPoint() {
        let frame = notice.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
    }
    @MainActor var peek: XCUIElement { app.descendants(matching: .any)["reply-peek"] }
    @MainActor var stage: XCUIElement { app.descendants(matching: .any)["browser.stage"] }

    @MainActor func rowSays(_ bot: String, _ words: String) -> Bool {
        let cell = row(bot)
        return cell.label.contains(words)
            || cell.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch.exists
    }

    /// What VoiceOver reads for the row.
    @MainActor func rowLabel(_ bot: String) -> String {
        let cell = row(bot)
        if !cell.label.isEmpty { return cell.label }
        return cell.descendants(matching: .any).allElementsBoundByIndex.map(\.label).max { $0.count < $1.count } ?? ""
    }

    @MainActor func chatTitle() -> String {
        let title = app.descendants(matching: .any)["chat.title"]
        return title.exists ? title.label : ""
    }

    @MainActor func chatSays(_ words: String) -> Bool {
        app.tables["chat.table"].descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch.exists
    }

    @MainActor func stageValue() -> String { (stage.value as? String) ?? "" }

    @MainActor func framesShown() -> Int {
        let text = stageValue()
        guard let range = text.range(of: "frames=") else { return 0 }
        return Int(text[range.upperBound...].prefix { $0.isNumber }) ?? 0
    }

    /// Frames are arriving: the count rose between two reads.
    @MainActor func framesRising(within timeout: TimeInterval) -> Bool {
        var last = framesShown()
        return waitUntil(timeout: timeout) {
            let now = self.framesShown()
            defer { last = now }
            return now > last
        }
    }

    // MARK: The fixture

    func event(_ profile: String, _ type: String, _ payload: [String: Any]) {
        _ = try? account.control("/__fixture/event", ["profile": profile, "type": type, "payload": payload])
    }

    func toolStart(_ profile: String, _ name: Any, id: String = UUID().uuidString) {
        event(profile, "tool.start", ["tool_id": id, "name": name, "args": [String: Any]()])
    }

    func presence(_ body: [String: Any]) {
        do { try account.control("/__fixture/presence", body) } catch { XCTFail("fixture control failed: \(error)") }
    }

    func presenceState() -> [String: Any] { (try? account.control("/__fixture/presence")) ?? [:] }

    func configureCalls() -> [[String: Any]] { (presenceState()["configure_calls"] as? [[String: Any]]) ?? [] }

    /// The `hermes-bots` object the fixture stores for a bot.
    func storedMeta(_ profile: String) -> [String: Any] {
        (((presenceState()["ui_meta"] as? [String: Any])?[profile] as? [String: Any])?["hermes-bots"] as? [String: Any]) ?? [:]
    }

    func count(_ key: String) -> Int { (presenceState()[key] as? Int) ?? -1 }

    /// Every prompt.submit the fixture took whose text is the install request.
    func installSubmits() -> [[String: Any]] {
        let rpc = ((try? account.control("/__fixture/state"))?["rpc"] as? [[String: Any]]) ?? []
        return rpc.filter { $0["method"] as? String == "prompt.submit" }
            .compactMap { $0["params"] as? [String: Any] }
            .filter { ($0["text"] as? String ?? "").hasPrefix(Self.installPrefix) }
    }

    // MARK: Screenshots (attached, and written to HQN_UI_SHOTS as <name>-light.png, or <name>-dark.png in a dark run)

    /// A screen the report shows in both appearances: this run's half ("-light", or "-dark" in a dark run).
    @MainActor func shots(_ name: String) { shot(name) }

    @MainActor func shot(_ name: String) {
        pause(0.4)
        capture(name, Self.darkRun ? "dark" : "light")
    }

    @MainActor private func capture(_ name: String, _ mode: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(name)-\(mode)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let dir = ProcessInfo.processInfo.environment["HQN_UI_SHOTS"], !dir.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "\(name)-\(mode).png"))
    }

    /// A timing the summary prints (scripts/e2e-summary.py lists "[measure] …" activities).
    @MainActor func measure(_ words: String) {
        XCTContext.runActivity(named: "[measure] \(words)") { _ in }
    }

    // MARK: Waiting

    func pause(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    @discardableResult
    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    /// Seconds until `condition` holds, or nil when it never did.
    func secondsUntil(timeout: TimeInterval, _ condition: () -> Bool) -> TimeInterval? {
        let start = Date()
        return waitUntil(timeout: timeout, condition) ? Date().timeIntervalSince(start) : nil
    }
}
