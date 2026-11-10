// [m9/ipad] Shared helpers for the iPad layout and hardware-keyboard UI tests (docs/spec/3x-ipad.md §9).
// scripts/e2e-ipad.sh starts the stand-in gateways and passes their credentials files:
//   TEST_RUNNER_HQN_UI_CREDENTIALS            the performance fixture (bots, a long chat, send / stream / Stop)
//   TEST_RUNNER_HQN_UI_SESSIONS_CREDENTIALS   the sessions fixture (three bots, sessions, session.create, request log)
//   TEST_RUNNER_HQN_UI_PAGES_CREDENTIALS      the pages fixture (Jobs, Kanban, Artifacts)
//   TEST_RUNNER_HQN_SHOTS_DIR                 where screenshots go
// The app signs in from its process environment (DEBUG simulator hook), so no test types a password.

import XCTest

/// This Mac runs about ten agents, each with the same app in its own simulator. XCTest reports "Critical process
/// HermesHQNative crashed in (null)" in the middle of a test while this simulator's app is demonstrably still running
/// (the same process keeps logging and answering; no crash report is written). Such a report is dropped only when
/// this app is still in the foreground with the process id it was launched with; a real crash leaves it not running
/// and is recorded as always.
class IPadTestCase: XCTestCase {
    nonisolated(unsafe) static var launchedPid: Int32 = 0

    override func record(_ issue: XCTIssue) {
        // Ten agents run this same app (same process name) on other simulators of this Mac, and their crash reports
        // land in the one shared folder XCTest watches, so the name in the report cannot tell them apart (seen:
        // "Critical process HermesHQNative crashed" while this run's app was alive). The pid can: a report is
        // dropped only while the very process this test launched is still running in the foreground. If this app
        // had crashed, that pid would be gone and the report counts. Every drop is printed (IPAD-NOTE).
        if issue.compactDescription.contains("Critical process"), Thread.isMainThread {
            let alive = MainActor.assumeIsolated { () -> Bool in
                let app = XCUIApplication()
                return app.state == .runningForeground && Self.launchedPid != 0 && app.value(forKey: "processID") as? Int32 == Self.launchedPid
            }
            if alive {
                print("IPAD-NOTE dropped a crash report that is not this app's (pid \(Self.launchedPid) is still running): \(issue.compactDescription)")
                return
            }
        }
        super.record(issue)
    }
}

enum IPadFixture { case perf, sessions, pages }

@MainActor enum IPad {
    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    static func account(_ fixture: IPadFixture) throws -> FixtureAccount {
        switch fixture {
        case .perf:
            return try FixtureAccount.load()
        case .sessions, .pages:
            let name = fixture == .pages ? "HQN_UI_PAGES_CREDENTIALS" : "HQN_UI_SESSIONS_CREDENTIALS"
            guard let path = ProcessInfo.processInfo.environment[name], !path.isEmpty,
                  let data = FileManager.default.contents(atPath: path),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let url = object["url"] as? String, let username = object["username"] as? String,
                  let password = object["password"] as? String else {
                throw XCTSkip("Set TEST_RUNNER_\(name) (scripts/e2e-ipad.sh does).")
            }
            return FixtureAccount(url: url, username: username, password: password)
        }
    }

    /// A clean launch signed in to `account`. `arguments`: extra launch arguments (`-HQDebugPaneWidth`, `420`).
    static func launch(_ account: FixtureAccount, reset: Bool = true, arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (reset ? ["-HQDebugResetAccounts", "YES"] : []) + arguments
        app.launchEnvironment["HQN_SIGNIN_URL"] = account.url
        app.launchEnvironment["HQN_SIGNIN_USERNAME"] = account.username
        app.launchEnvironment["HQN_SIGNIN_PASSWORD"] = account.password
        keyCountFile = NSTemporaryDirectory() + "hqn-key-count-\(UUID().uuidString).txt"
        app.launchEnvironment["HQN_KEY_COUNT_FILE"] = keyCountFile
        app.launch()
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 40), "the Bots list shows after sign-in")
        IPadTestCase.launchedPid = (app.value(forKey: "processID") as? Int32) ?? 0
        return app
    }

    /// Where the app under test (DEBUG, `KeyLogWindow`) writes how many key presses with Command held have reached
    /// its window in this launch.
    static var keyCountFile: String?
    static func keysArrived() -> Int {
        keyCountFile.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }.flatMap { Int($0) } ?? 0
    }

    /// Presses Command-`key`. On this Mac under load the simulator sometimes never delivers a synthesized key press:
    /// the app's log for such a launch shows its window holding the keyboard and no key event at all, not even the
    /// Command key itself (repair after stress round 2, 2 of 24 launches, always the first key of a launch). Only in
    /// that proven case (the app's own count of arrived presses did not move in 4 s) is the key pressed again, and it
    /// is printed. A press that arrived is never repeated: what the app then does with it is the test's to judge.
    static func command(_ app: XCUIApplication, _ key: String, _ flags: XCUIElement.KeyModifierFlags = .command) {
        for attempt in 1...3 {
            let before = keysArrived()
            app.typeKey(key, modifierFlags: flags)
            if waitUntil(timeout: 4, { keysArrived() > before }) { return }
            print("IPAD-NOTE the simulator did not deliver Command-\(key) to the app (attempt \(attempt)): no key press reached its window")
        }
    }

    @discardableResult
    static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    static func shot(_ app: XCUIApplication, _ name: String, in test: XCTestCase) {
        let image = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["HQN_SHOTS_DIR"], !folder.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let dark = app.windows.firstMatch.exists && XCUIDevice.shared.appearance == .dark
        try? image.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name)\(dark ? "-dark" : "").png"))
    }

    /// The element is on screen (in the accessibility tree with a real frame).
    static func shows(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        return frame.width > 1 && frame.height > 1
    }

    /// The system Back button of the screen on show.
    static func back(_ app: XCUIApplication) {
        let button = app.navigationBars.buttons["BackButton"].firstMatch
        (button.exists ? button : app.navigationBars.buttons.element(boundBy: 0)).tap()
    }

    /// The Return key. XCUITest's `.return` ("\r") is never delivered as a key press on this runtime (the app's key log
    /// shows only the modifier); "\n" arrives as the real Return key (HID usage 40) in `pressesBegan`, modifiers too.
    static let returnKey = "\n"

    /// Presses the real Return key, with `flags`. No stand-in: a test that names Return fails if Return does nothing.
    static func pressReturn(_ app: XCUIApplication, _ flags: XCUIElement.KeyModifierFlags = []) {
        app.typeKey(returnKey, modifierFlags: flags)
    }

    /// Command-period, the "Stop or Close" command's second key. XCUITest cannot deliver a plain Escape key press on
    /// this runtime (KeyboardShortcutTests.test5 checks that and skips), so the ladder is driven through this key:
    /// it runs the same action (`AppDelegate.hqEscape`). Tests say "Stop or Close", not "Escape", for what they saw.
    @discardableResult
    static func stopOrClose(_ app: XCUIApplication, _ what: String, done: () -> Bool) -> Bool {
        app.typeKey(".", modifierFlags: .command)
        let worked = waitUntil(timeout: 6, done)
        print("IPAD-NOTE \(what): Command-period \(worked ? "worked" : "did nothing")")
        return worked
    }

    /// The message field sits on the keyboard (or at the window's bottom): never floating in the middle.
    static func fieldOnKeys(_ app: XCUIApplication, _ what: String) {
        Thread.sleep(forTimeInterval: 0.8)
        let keys = app.keyboards.firstMatch
        let window = app.windows.firstMatch.frame
        let bottom = keys.exists ? keys.frame.minY : window.maxY
        let gap = bottom - field(app).frame.maxY
        print("IPAD-NOTE \(what): field bottom \(field(app).frame.maxY), keys top \(bottom), keyboard \(keys.exists)")
        // The keyboard element's frame leaves out the suggestions bar above the keys (about 55 pt on iPad).
        XCTAssertTrue(gap > -2 && gap < 80, "\(what): the message field sits on the keyboard (gap \(gap) pt)")
        XCTAssertGreaterThan(field(app).frame.minY, window.height * 0.35, "\(what): in the lower part of the window")
    }

    static func placeholder(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["pane.placeholder"] }
    static func table(_ app: XCUIApplication) -> XCUIElement { app.tables["chat.table"] }
    static func field(_ app: XCUIApplication) -> XCUIElement { app.textViews["composer.text"] }

    static func message(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.tables["chat.table"].descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Opens a bot's chat from the Bots list and waits for its transcript.
    @discardableResult
    static func openBot(_ app: XCUIApplication, _ id: String = "default") -> XCUIElement {
        let row = app.cells["bot-row-\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the bot's row shows")
        row.tap()
        let table = table(app)
        if !table.waitForExistence(timeout: 6) { row.tap() }
        XCTAssertTrue(table.waitForExistence(timeout: 8), "the chat opens")
        return table
    }

    /// The title the chat's bar shows (the right pane's in two panes).
    /// What the app asked the gateway for, in order. The heartbeat (`gateway.ping`, sent by a timer whatever the
    /// user does) is left out unless asked for: "this tap sent nothing" is about the tap, not about the clock.
    static func rpcs(_ account: FixtureAccount, heartbeats: Bool = false) -> [String] {
        let state = (try? account.control("/__fixture/state")) ?? [:]
        let all = (state["rpc"] as? [[String: Any]])?.compactMap { $0["method"] as? String } ?? []
        return heartbeats ? all : all.filter { $0 != "gateway.ping" }
    }

    /// ⌃⌥⌘P (DEBUG): the stand-in window flips between 420 pt wide (phone layout) and the real window.
    static func toggleNarrow(_ app: XCUIApplication) { app.typeKey("p", modifierFlags: [.control, .option, .command]) }

    /// Queues reply plans for the next messages, after emptying what earlier tests left in the stand-in gateway's one
    /// queue (it only ever adds): a leftover long plan used to become the next test's first reply.
    static func plan(_ account: FixtureAccount, _ plans: [[String: Any]]) throws {
        try account.control("/__fixture/clear-plans", [:])
        try account.control("/__fixture/plan", ["plans": plans])
    }

    static func count(_ method: String, _ account: FixtureAccount) -> Int { rpcs(account).filter { $0 == method }.count }

    /// Focuses the message field and empties it.
    /// Taps Send, and once more if the text is still in the field two seconds later: on a simulator that has just
    /// been typed into by the hardware keyboard, the software keyboard can rise under the first tap and move the
    /// button away from it (seen on the release train, the text left in the field and nothing sent).
    static func send(_ app: XCUIApplication) {
        let typed = (field(app).value as? String) ?? ""
        app.buttons["composer.send"].tap()
        guard !typed.isEmpty else { return }
        let gone = waitUntil(timeout: 2) { ((field(app).value as? String) ?? "") != typed }
        if !gone, app.buttons["composer.send"].exists { app.buttons["composer.send"].tap() }
    }

    static func focusField(_ app: XCUIApplication) -> XCUIElement {
        let field = field(app)
        XCTAssertTrue(field.waitForExistence(timeout: 8), "the message field shows")
        field.tap()
        let value = (field.value as? String) ?? ""
        if !value.isEmpty, !value.hasPrefix("Message") {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count + 2))
        }
        return field
    }
}
