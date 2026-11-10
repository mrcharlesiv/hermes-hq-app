// Bot Screen end to end (docs/spec/3x-screen.md §8.2) against the screen fixture. scripts/e2e-screen.sh <udid> starts
// scripts/fixtures/screen-gateway.py and passes TEST_RUNNER_HQN_UI_CREDENTIALS + TEST_RUNNER_HQN_UI_SCREEN=1 (without
// them every test here skips), and a folder for screenshots as TEST_RUNNER_HQN_SHOTS_DIR with the appearance as
// TEST_RUNNER_HQN_SHOTS_SUFFIX. Every value is invented. The app's test seam is the `screen.debug` element (DEBUG
// builds launched with HQN_UI_SCREEN=1): the stream's pacing plus zoom, pan, pointer and the viewer's modes.

import XCTest

class ScreenTestCase: XCTestCase {
    var account: FixtureAccount!
    var app: XCUIApplication!

    static let screenTitles = ["View Screen", "Watch Screen", "Latest Screenshots"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["HQN_UI_SCREEN"] == "1" else {
            throw XCTSkip("Run with scripts/e2e-screen.sh <udid> (the screen fixture).")
        }
        account = try FixtureAccount.load()
        try account.control("/__fixture/screen/reset", [:])
    }

    // MARK: Fixture

    func ctl(_ body: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNoThrow(try account.control("/__fixture/screen", body), "fixture control \(body.keys.sorted())", file: file, line: line)
    }

    func ledger() -> [String: Any] { (try? account.control("/__fixture/screen")) ?? [:] }
    func inputs() -> [[String: Any]] { (ledger()["inputs"] as? [[String: Any]]) ?? [] }
    func lease() -> [String: Any] { (ledger()["lease"] as? [String: Any]) ?? [:] }
    func calls(_ method: String) -> [[String: Any]] {
        ((ledger()["calls"] as? [[String: Any]]) ?? []).filter { $0["method"] as? String == method }
    }
    func sockets() -> [[String: Any]] { (ledger()["sockets"] as? [[String: Any]]) ?? [] }
    func int(_ any: Any?) -> Int { (any as? NSNumber)?.intValue ?? -1 }
    func health() -> (new: Int, legacy: Int) {
        let hits = (ledger()["health_hits"] as? [String: Any]) ?? [:]
        return (int(hits["new"]), int(hits["legacy"]))
    }

    struct Pointer: Equatable { var mask: Int; var x: Int; var y: Int }

    func pointers(from index: Int) -> [Pointer] {
        inputs().dropFirst(index).filter { $0["kind"] as? String == "pointer" }.map { Pointer(mask: int($0["mask"]), x: int($0["x"]), y: int($0["y"])) }
    }

    /// The key events since `index` as (keysym, down).
    func keys(from index: Int) -> [(sym: Int, down: Bool)] {
        inputs().dropFirst(index).filter { $0["kind"] as? String == "key" }.map { (int($0["keysym"]), ($0["down"] as? Bool) ?? false) }
    }

    func cuts(from index: Int) -> [String] {
        inputs().dropFirst(index).filter { $0["kind"] as? String == "cut" }.compactMap { $0["text"] as? String }
    }

    // MARK: App

    @MainActor func launch(reset: Bool = true, arguments: [String] = []) {
        let app = XCUIApplication()
        // The run's appearance is the screenshots' suffix. Set here as well as by the script: the simulator's own
        // setting did not hold through the start of a run (the first dark pass came out light).
        XCUIDevice.shared.appearance = ProcessInfo.processInfo.environment["HQN_SHOTS_SUFFIX"] == "dark" ? .dark : .light
        // The "Know When a Bot Replies?" offer belongs to another feature's tests: answered already in these.
        var args = arguments + ["-dispatch.notifications.asked", "YES"]
        var env = ["HQN_UI_SCREEN": "1"]
        if reset {
            args += ["-HQDebugResetAccounts", "YES"]
            env["HQN_SIGNIN_URL"] = account.url
            env["HQN_SIGNIN_USERNAME"] = account.username
            env["HQN_SIGNIN_PASSWORD"] = account.password
        }
        app.launchArguments = args
        app.launchEnvironment = env
        app.launch()
        self.app = app
        let row = app.cells["bot-row-default"]
        if !row.waitForExistence(timeout: 25) {
            let bots = app.buttons["tab-bots"]
            if bots.exists { bots.tap() }
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "signed in: the Bots list shows")
    }

    @MainActor func el(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    @MainActor func screenMenuItem(bot: String) -> XCUIElement {
        let cell = app.cells["bot-row-\(bot)"]
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "the bot's row shows")
        let item = app.buttons.matching(NSPredicate(format: "label IN %@", Self.screenTitles)).firstMatch
        for _ in 0..<3 where !item.exists {
            cell.press(forDuration: 1.1)
            _ = item.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(item.exists, "the row menu has its Screen entry")
        return item
    }

    @MainActor func dismissMenu() {
        let info = app.buttons["Bot Info"]
        for point in [CGVector(dx: 0.5, dy: 0.97), CGVector(dx: 0.5, dy: 0.04), CGVector(dx: 0.97, dy: 0.6)] where info.exists {
            app.coordinate(withNormalizedOffset: point).tap()
            _ = waitUntil(timeout: 3) { !info.exists }
        }
        XCTAssertFalse(info.exists, "the row menu closes")
    }

    @MainActor func menuLabel(bot: String = "default") -> String {
        let label = screenMenuItem(bot: bot).label
        dismissMenu()
        return label
    }

    @MainActor func openScreen(bot: String = "default", expecting: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let item = screenMenuItem(bot: bot)
        if let expecting { XCTAssertEqual(item.label, expecting, "the Screen entry's label", file: file, line: line) }
        item.tap()
        XCTAssertTrue(app.buttons["screen.close"].waitForExistence(timeout: 10), "the Screen opens", file: file, line: line)
    }

    @MainActor func closeScreen(file: StaticString = #filePath, line: UInt = #line) {
        let close = app.buttons["screen.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the Screen is open", file: file, line: line)
        close.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !close.exists && self.app.cells["bot-row-default"].exists }, "the Screen closes", file: file, line: line)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }

    // MARK: The test seam

    @MainActor func debugValue() -> String { (el("screen.debug").value as? String) ?? "" }

    func field(_ name: String, in text: String) -> String {
        guard let range = text.range(of: name + "=") else { return "" }
        return String(text[range.upperBound...].prefix { $0 != " " })
    }

    @MainActor func value(_ name: String) -> Double { Double(field(name, in: debugValue())) ?? -1 }

    @MainActor func pointer() -> (x: Int, y: Int) {
        let parts = field("pointer", in: debugValue()).split(separator: ",").compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : (-1, -1)
    }

    @MainActor func waitLive(_ timeout: TimeInterval = 25, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitUntil(timeout: timeout) { self.value("frames") >= 1 }, "the picture shows (\(debugValue()))", file: file, line: line)
    }

    @MainActor func caption() -> String {
        let label = app.staticTexts["screen.caption"]
        return label.exists ? label.label : ""
    }

    /// The caption names the bot: "<Bot> is in control" (not another viewer).
    @MainActor func botInControl() -> Bool {
        let line = caption()
        return line.hasSuffix(" is in control") && line != "Another viewer is in control"
    }

    @MainActor func takeOver(file: StaticString = #filePath, line: UInt = #line) {
        let take = app.buttons["screen.take"]
        XCTAssertTrue(waitUntil(timeout: 20) { take.exists && take.isEnabled }, "Take over is ready", file: file, line: line)
        take.tap()
        XCTAssertTrue(waitUntil(timeout: 12) { self.caption() == "You are in control" }, "in control (\(caption()))", file: file, line: line)
    }

    /// One finger drags the pointer (no hold: a hold would press the mouse).
    @MainActor func movePointer(dx: CGFloat = 0, dy: CGFloat) {
        let start = el("screen.stage").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: dx, dy: dy)), withVelocity: .slow, thenHoldForDuration: 0.05)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    @MainActor func text(_ id: String) -> String {
        let found = el(id)
        return found.exists ? found.label : ""
    }

    /// A screenshot kept in the result bundle, and as a PNG in TEST_RUNNER_HQN_SHOTS_DIR when set.
    @MainActor func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["HQN_SHOTS_DIR"], !dir.isEmpty else { return }
        let suffix = env["HQN_SHOTS_SUFFIX"].map { "-\($0)" } ?? ""
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "\(name)\(suffix).png"))
    }

    @MainActor func note(_ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTContext.runActivity(named: "[measure] " + text) { _ in }     // scripts/e2e-summary.py prints these
        print("SCREEN-NOTE \(text)")
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

    @MainActor func pause(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    /// Two fingers dragged together by `dy` points. XCUITest has no public call for a two-finger drag (only pinch and
    /// rotate), so this uses the test runner's own event records; when this Xcode does not have them the test skips.
    @MainActor func twoFingerDrag(on element: XCUIElement, dy: CGFloat, spread: CGFloat = 56, seconds: TimeInterval = 0.7) throws {
        typealias Touch = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Unmanaged<AnyObject>?
        typealias Move = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Void
        typealias Lift = @convention(c) (AnyObject, Selector, Double) -> Void
        typealias Record = @convention(c) (AnyObject, Selector, NSString, Int) -> Unmanaged<AnyObject>?
        typealias Add = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        typealias Run = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
        let touch = NSSelectorFromString("initForTouchAtPoint:offset:"), move = NSSelectorFromString("moveToPoint:atOffset:")
        let lift = NSSelectorFromString("liftUpAtOffset:"), make = NSSelectorFromString("initWithName:interfaceOrientation:")
        let add = NSSelectorFromString("addPointerEventPath:"), run = NSSelectorFromString("synthesizeWithError:")
        guard let paths = NSClassFromString("XCPointerEventPath") as? NSObject.Type,
              let records = NSClassFromString("XCSynthesizedEventRecord") as? NSObject.Type,
              paths.instancesRespond(to: touch), paths.instancesRespond(to: move), paths.instancesRespond(to: lift),
              records.instancesRespond(to: make), records.instancesRespond(to: add), records.instancesRespond(to: run) else {
            throw XCTSkip("this Xcode has no two-finger event records")
        }
        func alloc(_ kind: NSObject.Type) -> AnyObject { (kind as AnyObject).perform(NSSelectorFromString("alloc")).takeUnretainedValue() }
        func call<T>(_ object: AnyObject, _ selector: Selector, as type: T.Type) -> T {
            unsafeBitCast((object as! NSObject).method(for: selector), to: type)
        }
        let blank = alloc(records)
        guard let record = call(blank, make, as: Record.self)(blank, make, "two finger drag" as NSString, 1)?.takeUnretainedValue() else {
            throw XCTSkip("no event record")
        }
        let frame = element.frame, steps = 14
        for side in [-0.5, 0.5] as [CGFloat] {
            let from = CGPoint(x: frame.midX + side * spread, y: frame.midY - dy / 2)
            let raw = alloc(paths)
            guard let path = call(raw, touch, as: Touch.self)(raw, touch, from, 0)?.takeUnretainedValue() else { throw XCTSkip("no event path") }
            for step in 1...steps {
                let part = CGFloat(step) / CGFloat(steps)
                call(path, move, as: Move.self)(path, move, CGPoint(x: from.x, y: from.y + dy * part), 0.05 + seconds * Double(part))
            }
            call(path, lift, as: Lift.self)(path, lift, seconds + 0.15)
            call(record, add, as: Add.self)(record, add, path)
        }
        XCTAssertTrue(call(record, run, as: Run.self)(record, run, nil), "the two-finger drag was synthesised")
        pause(0.4)
    }

    /// Raises the keyboard and waits for the keys. A fresh simulator shows the keyboard's own "slide to type" card
    /// once: it is sent away.
    @MainActor func raiseKeyboard(file: StaticString = #filePath, line: UInt = #line) {
        let toggle = app.buttons["screen.keyboard.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the keyboard button", file: file, line: line)
        toggle.tap()
        XCTAssertTrue(waitUntil(timeout: 6) { self.value("typing") == 1 }, "the keyboard is up (\(debugValue()))", file: file, line: line)
        let intro = app.buttons["Continue"]
        if intro.waitForExistence(timeout: 1) { intro.tap() }
        pause(0.6)
    }

    /// Taps a key of the bar, scrolling its row sideways when the key is out of sight.
    @MainActor func tapKey(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let key = app.buttons[id]
        XCTAssertTrue(key.waitForExistence(timeout: 4), id, file: file, line: line)
        for _ in 0..<4 where !key.isHittable {
            let rows = ["screen.mods", "screen.keys"].map { el($0) }.filter { $0.exists && $0.frame.intersects(key.frame) }
            (rows.first ?? el("screen.bar")).swipeLeft(velocity: .slow)
            pause(0.3)
        }
        key.tap()
    }

    /// Taps Paste and answers iOS's own "Allow Paste" question when it asks.
    @MainActor func tapPaste(asks: Bool = true, wait: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        tapKey("screen.paste", file: file, line: line)
        guard asks else { return }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Allow Paste")).firstMatch
        if allow.waitForExistence(timeout: wait) {
            allow.tap()
            pause(0.5)
        }
    }
}

final class ScreenEndToEndTests: ScreenTestCase {
    @MainActor override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
        app?.terminate()
    }

    // MARK: L166, L508 — the row menu's Screen entry follows the status

    @MainActor func test01_menuLabelFollowsStatus() throws {
        launch()
        let before = int(ledger()["status_calls"])
        let item = screenMenuItem(bot: "default")
        XCTAssertEqual(item.label, "View Screen", "a gateway never opened reads View Screen")
        shot("screen-menu-view")
        dismissMenu()
        XCTAssertEqual(int(ledger()["status_calls"]), before, "opening the menu asks the gateway nothing")

        openScreen(expecting: "View Screen")
        waitLive()
        let titled = app.navigationBars.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "’s Screen")).firstMatch
        XCTAssertTrue(titled.exists, "titled with the bot's name")
        XCTAssertEqual(titled.label, "Hermes’s Screen")
        closeScreen()
        XCTAssertEqual(menuLabel(bot: "default"), "Watch Screen", "a live screen reads Watch Screen")
        XCTAssertEqual(menuLabel(bot: "ivy"), "Watch Screen", "a bot never opened takes the gateway's remembered kind")

        // With the menu open the label cannot change under the finger; the next opening shows the new one.
        let open = screenMenuItem(bot: "default")
        ctl(["mode": "unsupported"])
        pause(1.5)
        XCTAssertEqual(open.label, "Watch Screen", "an open menu keeps its label")
        dismissMenu()
        let next = screenMenuItem(bot: "default")
        XCTAssertEqual(next.label, "Latest Screenshots", "the status event moved the label")
        shot("screen-menu-screenshots")
        next.tap()
        XCTAssertTrue(el("screenshots.page").waitForExistence(timeout: 10), "the latest screenshots open instead")
        closeScreen()

        // The kind is remembered for the gateway across a relaunch.
        app.terminate()
        launch(reset: false)
        XCTAssertEqual(menuLabel(bot: "default"), "Latest Screenshots", "remembered after a relaunch")

        // Any known tone but the two fallbacks is the live Screen: off still reads Watch Screen.
        ctl(["mode": "off"])
        openScreen()
        XCTAssertTrue(el("screen.off.title").waitForExistence(timeout: 10), "Screen Is Off")
        closeScreen()
        XCTAssertEqual(menuLabel(bot: "default"), "Watch Screen")
        ctl(["mode": "unavailable"])
        openScreen()
        XCTAssertTrue(el("screenshots.page").waitForExistence(timeout: 10))
        XCTAssertEqual(text("screenshots.heading"), "Screen needs a newer Hermes")
        closeScreen()
        XCTAssertEqual(menuLabel(bot: "default"), "Latest Screenshots")
        XCTAssertEqual(int(ledger()["forbidden_calls"]), 0)
        XCTAssertEqual((ledger()["unknown_params"] as? [Any])?.count, 0, "only the allowed keys were sent")
    }

    // MARK: L516 — "Couldn’t Reach <Bot>’s Screen" with Retry

    @MainActor func test02_noAnswerThenRetry() throws {
        ctl(["mode": "no-answer"])
        launch()
        openScreen()
        XCTAssertTrue(el("screen.connecting").waitForExistence(timeout: 5), "Connecting to the screen…")
        XCTAssertEqual(text("screen.connecting"), "Connecting to the screen…")
        shot("screen-connecting")
        let started = Date()
        let title = el("screen.no-answer.title")
        XCTAssertTrue(title.waitForExistence(timeout: 30), "the 20 s timeout")
        let waited = Date().timeIntervalSince(started)
        note("no-answer shown after \(String(format: "%.1f", waited)) s")
        XCTAssertGreaterThan(waited, 12, "not before the status had its 20 seconds")
        XCTAssertTrue(title.label.hasPrefix("Couldn’t Reach ") && title.label.hasSuffix("’s Screen"), title.label)
        XCTAssertEqual(text("screen.no-answer"),
                       "The screen’s status never arrived. Check that the computer running Hermes is on and reachable, then try again.")
        shot("screen-no-answer")
        // Retry asks again; the gateway is still silent, so the page waits again.
        let silent = int(ledger()["status_calls"])
        app.buttons["screen.retry"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.int(self.ledger()["status_calls"]) > silent }, "Retry asks the gateway again")
        XCTAssertTrue(el("screen.connecting").waitForExistence(timeout: 5), "and waits for it")
        // A status that arrives late replaces the page at once, without a tap (the gateway's own status event).
        ctl(["mode": "mac"])
        waitLive()
        closeScreen()

        // A failing status says the gateway's words at once, with one period; Retry works once it answers. A screen this
        // run has seen running opens on what it knew (no status read), so each of these starts from a fresh launch.
        ctl(["fail": ["display.status": "Bot Desktop state is unreadable."]])
        launch(reset: false)
        openScreen()
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        XCTAssertEqual(text("screen.no-answer"),
                       "Bot Desktop state is unreadable. Check that the computer running Hermes is on and reachable, then try again.")
        ctl(["fail": ["display.status": NSNull()]])
        pause(0.5)
        XCTAssertTrue(title.exists, "the page stays until Retry")
        app.buttons["screen.retry"].tap()
        waitLive()
        closeScreen()

        // A slow answer is not a failure (12 s is well inside the 20, and long enough to look while it is pending
        // on a loaded simulator).
        ctl(["status_delay_ms": 12000])
        launch(reset: false)
        let opened = Date()
        openScreen()
        XCTAssertTrue(el("screen.connecting").exists && !title.exists,
                      "still connecting \(String(format: "%.1f", Date().timeIntervalSince(opened))) s after the tap (\(debugValue()))")
        waitLive()
        XCTAssertFalse(title.exists)
        closeScreen()
        ctl(["status_delay_ms": 0])

        // Coming back to the front asks again and the 20 s start over.
        ctl(["mode": "no-answer"])
        launch(reset: false)
        openScreen()
        pause(4)
        let asked = int(ledger()["status_calls"])
        XCUIDevice.shared.press(.home)
        pause(2)
        app.activate()
        let front = Date()
        XCTAssertTrue(waitUntil(timeout: 8) { self.int(self.ledger()["status_calls"]) > asked }, "a new status request after foregrounding")
        XCTAssertTrue(el("screen.connecting").exists, "connecting again")
        // The page was opened about 8 s before it came back to the front: a clock that had kept running would give
        // up about 12 s from here, a fresh one takes its whole 20.
        XCTAssertTrue(title.waitForExistence(timeout: 30), "that request was never answered either")
        let again = Date().timeIntervalSince(front)
        note("no-answer after coming back to the front: \(String(format: "%.1f", again)) s")
        XCTAssertGreaterThan(again, 16, "the 20 s started over")
        // The gateway wakes up: its status event replaces the page without a tap.
        ctl(["mode": "mac"])
        waitLive()
    }

    // MARK: L509 — watching: zoom, pan, double tap, no input

    @MainActor func test03_liveWatchZoomPanDoubleTap() throws {
        launch()
        let tapped = Date()
        openScreen()
        waitLive()
        note("menu tap to first picture: \(String(format: "%.1f", Date().timeIntervalSince(tapped))) s (includes the menu's long press)")
        XCTAssertTrue(botInControl())
        let first = value("frames")
        pause(2)
        XCTAssertGreaterThan(value("frames"), first, "frames keep coming (\(debugValue()))")
        XCTAssertEqual(field("mainDecodes", in: debugValue()), "0", "nothing is decoded on the main thread")
        XCTAssertEqual(field("size", in: debugValue()), "1280x800")
        XCTAssertEqual(value("idle"), 1, "the phone stays awake while the picture is live")
        shot("screen-live-watching")

        let stage = el("screen.stage")
        stage.pinch(withScale: 2.5, velocity: 2)
        XCTAssertTrue(waitUntil(timeout: 4) { self.value("zoom") > 1.3 }, "pinch out zooms (\(debugValue()))")
        shot("screen-live-zoomed")
        stage.pinch(withScale: 4, velocity: 3)
        stage.pinch(withScale: 4, velocity: 3)
        pause(0.5)
        XCTAssertLessThanOrEqual(value("zoom"), 5.0, "never past 5×")
        XCTAssertGreaterThan(value("zoom"), 3.0)
        let pan = field("pan", in: debugValue())
        let middle = stage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 70, dy: 40)), withVelocity: .slow, thenHoldForDuration: 0.05)
        XCTAssertTrue(waitUntil(timeout: 3) { self.field("pan", in: self.debugValue()) != pan }, "one finger pans")
        let fit = app.buttons["screen.fit"]
        XCTAssertTrue(fit.waitForExistence(timeout: 3), "Fit is offered while zoomed")
        fit.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { abs(self.value("zoom") - 1) < 0.01 }, "Fit returns to the whole desktop")
        XCTAssertTrue(waitUntil(timeout: 3) { !fit.exists }, "and is gone when there is nothing to fit")
        stage.doubleTap()
        XCTAssertTrue(waitUntil(timeout: 3) { self.value("zoom") > 1.1 }, "double tap fills (\(debugValue()))")
        stage.doubleTap()
        XCTAssertTrue(waitUntil(timeout: 3) { abs(self.value("zoom") - 1) < 0.01 }, "double tap again fits")
        stage.tap()
        pause(0.5)

        let seen = ledger()
        XCTAssertEqual((seen["inputs"] as? [Any])?.count, 0, "watching sends no input")
        XCTAssertEqual(int(seen["dropped_inputs"]), 0)
        let kinds = Set(((seen["client_messages"] as? [String: Any]) ?? [:]).keys)
        XCTAssertTrue(kinds.isSubset(of: ["0", "2", "3"]), "only SetPixelFormat, SetEncodings and update requests: \(kinds)")
        XCTAssertEqual(int(seen["max_outstanding_requests"]), 1, "one request at a time")
        XCTAssertEqual((seen["set_encodings"] as? [NSNumber])?.map(\.intValue), [7, 1, 0, -25, -254, -224, -223, -308])
        closeScreen()
        XCTAssertTrue(waitUntil(timeout: 5) { self.int(self.ledger()["open_sockets"]) == 0 }, "no socket left")
        XCTAssertEqual(lease()["holder"] as? String, "agent")
    }

    // MARK: L509 — in control: swipe, tap, hold = right click, hold-move = drag, hand back

    @MainActor func test04_takeOverPointerClicks() throws {
        launch()
        openScreen()
        waitLive()
        let pressed = Date()
        takeOver()
        note("Take over to “You are in control”: \(String(format: "%.2f", Date().timeIntervalSince(pressed))) s (includes the test's polling)")
        XCTAssertEqual(lease()["holder"] as? String, "human")
        XCTAssertNotNil(lease()["viewer_hash"] as? String)
        XCTAssertTrue(el("screen.hint.gestures").waitForExistence(timeout: 3), "the gestures hint")
        shot("screen-control")
        let stage = el("screen.stage")

        // Swipe: the pointer moves from the desktop's centre, no button.
        var mark = inputs().count
        movePointer(dx: 30, dy: 60)
        XCTAssertTrue(waitUntil(timeout: 5) { !self.pointers(from: mark).isEmpty }, "the swipe reached the gateway")
        let moves = pointers(from: mark)
        XCTAssertTrue(moves.allSatisfy { $0.mask == 0 }, "a swipe presses nothing: \(moves.prefix(6))")
        if let start = moves.first { XCTAssertTrue(abs(start.x - 640) < 120 && abs(start.y - 400) < 120, "it starts at the centre: \(start)") }
        let at = pointer()
        XCTAssertTrue(at.y > 400 && at.x > 640, "the pointer went down and right: \(at)")
        XCTAssertEqual(moves.last.map { [$0.x, $0.y] }, [at.x, at.y], "the gateway has the pointer where the ring is")

        // Tap: a left click at the cursor.
        mark = inputs().count
        stage.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.pointers(from: mark).map(\.mask).contains(1) && self.pointers(from: mark).last?.mask == 0 })
        let click = pointers(from: mark)
        XCTAssertEqual(click.map(\.mask).filter { $0 != 0 }, [1], "one left press: \(click)")
        XCTAssertTrue(click.allSatisfy { $0.x == at.x && $0.y == at.y }, "at the cursor: \(click) vs \(at)")

        // Hold and lift: a right click.
        mark = inputs().count
        stage.press(forDuration: 0.9)
        XCTAssertTrue(waitUntil(timeout: 5) { self.pointers(from: mark).map(\.mask).contains(4) && self.pointers(from: mark).last?.mask == 0 })
        let right = pointers(from: mark)
        XCTAssertEqual(right.map(\.mask).filter { $0 != 0 }, [4], "one right press and no left: \(right)")

        // Hold, then move: a drag with the left button down, released on lift.
        mark = inputs().count
        let middle = stage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        middle.press(forDuration: 0.9, thenDragTo: middle.withOffset(CGVector(dx: -60, dy: -40)), withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(waitUntil(timeout: 5) { self.pointers(from: mark).count > 3 && self.pointers(from: mark).last?.mask == 0 })
        let drag = pointers(from: mark)
        let held = drag.filter { $0.mask == 1 }
        XCTAssertGreaterThan(held.count, 2, "moves with the button down: \(drag.prefix(8))")
        XCTAssertTrue(Set(held.map(\.x)).count > 1, "the pointer moved while dragging")
        XCTAssertFalse(drag.contains { $0.mask == 4 }, "a drag is never a right click")
        XCTAssertEqual(drag.last?.mask, 0, "released on lift")
        shot("screen-control-after-clicks")

        // Hand back: the bot is in control and touches send nothing.
        app.buttons["screen.give"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.botInControl() })
        XCTAssertTrue(waitUntil(timeout: 5) { self.lease()["holder"] as? String == "agent" })
        mark = inputs().count
        stage.tap()
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: 40)), withVelocity: .slow, thenHoldForDuration: 0.05)
        pause(0.8)
        XCTAssertEqual(inputs().count, mark, "watching again: nothing is sent")
        XCTAssertEqual(int(ledger()["dropped_inputs"]), 0, "and nothing was sent without the lease")
    }

    // MARK: L510 — the keyboard, the special keys and the modifiers

    @MainActor func test05_keyboardKeysAndModifiers() throws {
        launch()
        openScreen()
        waitLive()
        takeOver()
        raiseKeyboard()
        let stage = el("screen.stage")
        let bar = el("screen.bar")
        XCTAssertGreaterThanOrEqual(stage.frame.height, 120, "the picture keeps its room above the keys")
        XCTAssertLessThanOrEqual(stage.frame.maxY, bar.frame.minY + 1, "nothing covers the picture")
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists { XCTAssertLessThanOrEqual(bar.frame.maxY, keyboard.frame.minY + 1, "the bar rides the keyboard") }
        shot("screen-keyboard")

        // The simulator's key synthesiser, asked for the whole string at once, is only recorded (it has been seen to
        // swallow a space after an accented letter); the keys the test stands on are typed one at a time.
        var mark = inputs().count
        app.typeText("Hi é€")
        pause(2)
        note("one typeText(\"Hi é€\") gave \(keys(from: mark).filter(\.down).map { String($0.sym, radix: 16) })")

        mark = inputs().count
        for piece in ["H", "i", " ", "é", " ", "€"] {
            app.typeText(piece)
            pause(0.25)
        }
        XCTAssertTrue(waitUntil(timeout: 8) { self.keys(from: mark).count >= 12 }, "six characters as press and release: \(keys(from: mark))")
        var typed = keys(from: mark)
        XCTAssertEqual(typed.filter(\.down).map(\.sym), [0x48, 0x69, 0x20, 0xE9, 0x20, 0x010020AC])
        XCTAssertEqual(typed.filter { !$0.down }.map(\.sym), [0x48, 0x69, 0x20, 0xE9, 0x20, 0x010020AC])
        XCTAssertEqual(typed.map(\.down), Array(repeating: [true, false], count: 6).flatMap { $0 }, "each key is released before the next")

        mark = inputs().count
        app.typeText("\n")
        app.typeText(XCUIKeyboardKey.delete.rawValue)
        for id in ["screen.key.esc", "screen.key.tab", "screen.key.left", "screen.key.up", "screen.key.down", "screen.key.right"] { tapKey(id) }
        XCTAssertTrue(waitUntil(timeout: 8) { self.keys(from: mark).count >= 16 }, "\(keys(from: mark))")
        typed = keys(from: mark)
        XCTAssertEqual(typed.filter(\.down).map(\.sym), [0xFF0D, 0xFF08, 0xFF1B, 0xFF09, 0xFF51, 0xFF52, 0xFF54, 0xFF53])

        // Ctrl is armed for one key.
        let ctrl = app.buttons["screen.mod.ctrl"]
        XCTAssertTrue(ctrl.exists && app.buttons["screen.mod.alt"].exists && app.buttons["screen.mod.meta"].exists, "a Mac has ⌥ and ⌘ too")
        mark = inputs().count
        ctrl.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { ctrl.isSelected }, "Ctrl is armed")
        shot("screen-keys-ctrl-armed")
        app.typeText("c")
        XCTAssertTrue(waitUntil(timeout: 5) { self.keys(from: mark).count >= 4 })
        typed = keys(from: mark)
        XCTAssertEqual(typed.map(\.sym), [0xFFE3, 0x63, 0x63, 0xFFE3], "the chord: \(typed)")
        XCTAssertEqual(typed.map(\.down), [true, true, false, false])
        XCTAssertTrue(waitUntil(timeout: 3) { !ctrl.isSelected }, "Ctrl is no longer armed")

        // Hand back with the keyboard up: it falls and the keys go.
        app.buttons["screen.give"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.botInControl() && self.value("typing") == 0 })
        XCTAssertFalse(app.buttons["screen.key.esc"].exists, "no keys while watching")
        closeScreen()

        // A Linux screen has Ctrl only.
        ctl(["mode": "linux"])
        openScreen()
        waitLive()
        takeOver()
        raiseKeyboard()
        XCTAssertTrue(app.buttons["screen.mod.ctrl"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["screen.mod.alt"].exists || app.buttons["screen.mod.meta"].exists, "no ⌥ or ⌘ off the Mac")
        // With the keyboard up the picture has little room: the size under the title steps aside, as on the Mac.
        XCTAssertTrue(waitUntil(timeout: 6) { self.value("compact") == 1 }, debugValue())
        XCTAssertTrue(waitUntil(timeout: 4) { !self.app.navigationBars.staticTexts["1280×800"].exists }, "no second line under the title while typing")
        shot("screen-keys-linux")
    }

    // MARK: L509 — two fingers scroll the bot's screen (wheel steps), without moving the pointer or the view

    @MainActor func test21_twoFingerScrollSendsWheelSteps() throws {
        launch()
        openScreen()
        waitLive()
        takeOver()
        let stage = el("screen.stage")
        let at = pointer()
        var mark = inputs().count
        try twoFingerDrag(on: stage, dy: -120)                       // fingers up: the page goes down
        XCTAssertTrue(waitUntil(timeout: 6) { self.pointers(from: mark).contains { $0.mask & 16 != 0 } }, "wheel-down steps: \(pointers(from: mark))")
        pause(0.5)
        var sent = pointers(from: mark)
        let down = sent.filter { $0.mask & 16 != 0 }.count
        note("two fingers 120 pt up: \(down) wheel-down steps (24 pt each)")
        XCTAssertTrue((3...5).contains(down), "about one step per 24 pt: \(sent)")
        XCTAssertFalse(sent.contains { $0.mask & 8 != 0 }, "none the other way")
        XCTAssertFalse(sent.contains { $0.mask & 7 != 0 }, "and no button: \(sent)")
        XCTAssertTrue(sent.allSatisfy { $0.x == at.x && $0.y == at.y }, "the wheel turns where the pointer is: \(sent) vs \(at)")
        // Every step is a press of the wheel bit and its release.
        let masks = sent.map(\.mask)
        XCTAssertEqual(masks.filter { $0 == 0 }.count, down, "each step is released: \(masks)")

        mark = inputs().count
        try twoFingerDrag(on: stage, dy: 120)
        XCTAssertTrue(waitUntil(timeout: 6) { self.pointers(from: mark).contains { $0.mask & 8 != 0 } }, "wheel-up steps: \(pointers(from: mark))")
        pause(0.5)
        sent = pointers(from: mark)
        XCTAssertTrue((3...5).contains(sent.filter { $0.mask & 8 != 0 }.count), "\(sent)")
        XCTAssertFalse(sent.contains { $0.mask & 16 != 0 })
        XCTAssertEqual(value("zoom"), 1, accuracy: 0.01, "the view did not zoom")
        XCTAssertEqual(pointer().x, at.x)
        XCTAssertEqual(pointer().y, at.y, "the pointer stayed where it was")

        // Watching, two fingers never reach the bot's screen.
        app.buttons["screen.give"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.botInControl() })
        mark = inputs().count
        try twoFingerDrag(on: stage, dy: -120)
        pause(0.6)
        XCTAssertEqual(inputs().count, mark, "nothing is sent while watching")
    }

    // MARK: L510 — Paste: the clipboard on a Mac when it fits Latin-1, typed otherwise

    @MainActor func test06_pasteClipboardAndTyped() throws {
        launch()
        openScreen()
        waitLive()
        takeOver()
        raiseKeyboard()
        XCTAssertTrue(app.buttons["screen.paste"].waitForExistence(timeout: 5), "Paste sits with the keys")

        UIPasteboard.general.string = "Hello"
        var mark = inputs().count
        tapPaste()
        XCTAssertTrue(waitUntil(timeout: 20) { !self.cuts(from: mark).isEmpty && self.keys(from: mark).count >= 4 },
                      "\(inputs().dropFirst(mark)) \(debugValue())")
        XCTAssertEqual(cuts(from: mark), ["Hello"], "one clipboard message of 5 bytes")
        XCTAssertEqual(keys(from: mark).map(\.sym), [0xFFEB, 0x76, 0x76, 0xFFEB], "then ⌘V")
        XCTAssertEqual(keys(from: mark).map(\.down), [true, true, false, false])
        // iOS's question does not cost the keyboard: the keys are still there for the next paste.
        XCTAssertTrue(waitUntil(timeout: 10) { self.value("typing") == 1 && self.app.buttons["screen.paste"].exists }, "the keyboard stays up (\(debugValue()))")

        UIPasteboard.general.string = "héllo 👋"
        mark = inputs().count
        tapPaste()
        XCTAssertTrue(waitUntil(timeout: 20) { self.keys(from: mark).count >= 14 }, "\(keys(from: mark))")
        XCTAssertTrue(cuts(from: mark).isEmpty, "text beyond Latin-1 is typed, not put on the clipboard")
        XCTAssertEqual(keys(from: mark).filter(\.down).map(\.sym), [0x68, 0xE9, 0x6C, 0x6C, 0x6F, 0x20, 0x0101F44B])
        XCTAssertTrue(waitUntil(timeout: 10) { self.value("typing") == 1 && self.app.buttons["screen.paste"].exists })

        UIPasteboard.general.items = []
        mark = inputs().count
        let pills = value("pills")
        tapPaste(asks: false)
        shot("screen-paste-empty")
        // The note stays 3 s, which a loaded simulator can spend on one query: the app's own count is the proof, and
        // the words are checked on screen whenever the query is in time.
        let onScreen = text("screen.pill.clipboard")
        XCTAssertTrue(waitUntil(timeout: 10) { self.value("pills") == pills + 1 }, "one note shows: \(debugValue())")
        XCTAssertEqual(field("lastPill", in: debugValue()), "screen.pill.clipboard:There’s_no_text_to_paste.")
        if !onScreen.isEmpty { XCTAssertEqual(onScreen, "There’s no text to paste.") }
        XCTAssertEqual(keys(from: mark).count + cuts(from: mark).count, 0, "nothing is sent for an empty clipboard")
        closeScreen()

        // Off the Mac the text is always typed.
        ctl(["mode": "linux"])
        openScreen()
        waitLive()
        takeOver()
        raiseKeyboard()
        XCTAssertTrue(app.buttons["screen.paste"].waitForExistence(timeout: 5))
        UIPasteboard.general.string = "Hello"
        mark = inputs().count
        tapPaste()
        XCTAssertTrue(waitUntil(timeout: 20) { self.keys(from: mark).count >= 10 }, "\(keys(from: mark))")
        XCTAssertTrue(cuts(from: mark).isEmpty)
        XCTAssertEqual(keys(from: mark).filter(\.down).map(\.sym), [0x48, 0x65, 0x6C, 0x6C, 0x6F])
        UIPasteboard.general.items = []
    }

    // MARK: L511 — the rotate hint, landscape, compact typing

    @MainActor func test07_rotateHintLandscapeCompactTyping() throws {
        launch()
        openScreen()
        waitLive()
        let hint = el("screen.hint.rotate")
        // One query for the hint and its words: the hint is gone after 6 s, and on a loaded machine a second look at it
        // (existence, then the label) came after that.
        let worded = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label == %@", "screen.hint.rotate",
                                                                          "Turn your iPhone sideways for a larger screen")).firstMatch
        XCTAssertTrue(worded.waitForExistence(timeout: 6), "the hint shows the first time, with its words")
        shot("screen-rotate-hint")
        closeScreen()
        openScreen()
        waitLive()
        pause(1.5)
        XCTAssertFalse(hint.exists, "and never again")

        let stage = el("screen.stage")
        let tall = stage.frame
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitUntil(timeout: 8) { self.value("landscape") == 1 }, "the viewer rotates (\(debugValue()))")
        pause(0.8)
        XCTAssertGreaterThan(stage.frame.width, tall.width + 200, "the desktop grows")
        shot("screen-landscape")

        takeOver()
        // Zoomed in before typing, so the view that returns afterwards can be told from the fitted one.
        stage.pinch(withScale: 2, velocity: 1.5)
        XCTAssertTrue(waitUntil(timeout: 4) { self.value("zoom") > 1.4 }, "\(debugValue())")
        let before = value("zoom")
        let toggle = app.buttons["screen.keyboard.toggle"]
        raiseKeyboard()
        XCTAssertTrue(waitUntil(timeout: 6) { self.value("typing") == 1 && self.value("compact") == 1 }, "compact typing (\(debugValue()))")
        pause(0.8)
        shot("screen-compact-typing")
        XCTAssertFalse(el("screen.note.mac").exists, "the notes make room while typing on a short screen")
        XCTAssertGreaterThanOrEqual(stage.frame.height, 100, "the picture keeps room above the keys (\(stage.frame))")
        XCTAssertTrue(app.buttons["screen.give"].isHittable, "Hand back stays in reach")
        XCTAssertTrue(app.buttons["screen.key.esc"].exists && app.buttons["screen.paste"].exists, "the keys are one row")
        // Review finding 4: Paste was drawn cut in half under Hand back. Every key is whole and clear of it now.
        let handBack = app.buttons["screen.give"]
        XCTAssertEqual(handBack.label, "Give Back", "the icon keeps its name")
        XCTAssertLessThanOrEqual(handBack.frame.width, 64, "Hand back is an icon here, the row belongs to the keys (\(handBack.frame))")
        for id in ["screen.keyboard.toggle", "screen.key.esc", "screen.key.tab", "screen.key.left", "screen.key.up", "screen.key.down",
                   "screen.key.right", "screen.mod.ctrl", "screen.mod.alt", "screen.mod.meta", "screen.paste"] {
            let key = app.buttons[id]
            XCTAssertTrue(key.exists && key.isHittable, "\(id) is on screen")
            XCTAssertLessThanOrEqual(key.frame.maxX, handBack.frame.minX, "\(id) is whole, left of Hand back (\(key.frame) vs \(handBack.frame))")
            XCTAssertGreaterThanOrEqual(key.frame.width, 43.5, "\(id) keeps its 44 pt target")
        }
        toggle.tap()
        XCTAssertTrue(waitUntil(timeout: 6) { self.value("typing") == 0 && self.value("compact") == 0 })
        XCTAssertTrue(waitUntil(timeout: 4) { abs(self.value("zoom") - before) < 0.05 }, "the earlier view returns (\(debugValue()) vs \(before))")

        // Changing the view while typing keeps the changed view.
        toggle.tap()
        XCTAssertTrue(waitUntil(timeout: 6) { self.value("compact") == 1 })
        pause(0.6)
        let fit = app.buttons["screen.fit"]
        XCTAssertTrue(fit.exists)
        fit.tap()
        XCTAssertTrue(waitUntil(timeout: 4) { abs(self.value("zoom") - 1) < 0.01 })
        toggle.tap()
        XCTAssertTrue(waitUntil(timeout: 6) { self.value("compact") == 0 })
        pause(0.8)
        XCTAssertEqual(value("zoom"), 1, accuracy: 0.01, "the view chosen while typing stays")

        // Closing gives the phone back to portrait even though it is still held sideways.
        closeScreen()
        let row = app.cells["bot-row-default"]
        XCTAssertTrue(waitUntil(timeout: 6) { row.exists && row.frame.width < 500 }, "the Bots list is portrait (\(row.frame))")
        shot("screen-closed-while-sideways")
        XCUIDevice.shared.orientation = .portrait
        pause(0.5)
        XCTAssertLessThan(row.frame.width, 500)
    }

    // MARK: L512 — control survives a gateway socket swap

    @MainActor func test08_controlSurvivesSocketSwap() throws {
        launch()
        openScreen()
        waitLive()
        takeOver()
        let old = lease()["viewer_hash"] as? String
        let observes = calls("display.observe").count
        let log = (ledger()["lease_log"] as? [Any])?.count ?? 0
        ctl(["drop_ws": true])
        XCTAssertTrue(waitUntil(timeout: 30) {
            let now = self.lease()
            return now["holder"] as? String == "human" && (now["viewer_hash"] as? String) != old && self.caption() == "You are in control"
                && self.value("frames") >= 1
        }, "in control again with a new viewer id (\(lease()), \(caption()))")
        XCTAssertGreaterThan(calls("display.observe").count, observes, "a new observe on the new connection")
        let later = ((ledger()["lease_log"] as? [[String: Any]]) ?? []).dropFirst(log)
        XCTAssertFalse(later.contains { $0["holder"] as? String == "agent" }, "the bot never had the lease in between: \(later)")
        let mark = inputs().count
        movePointer(dy: 40)
        XCTAssertTrue(waitUntil(timeout: 5) { self.inputs().count > mark }, "input still lands")
        XCTAssertEqual(int(ledger()["max_open_sockets"]), 1, "never two display sockets")
        closeScreen()
        XCTAssertTrue(waitUntil(timeout: 5) { self.lease()["holder"] as? String == "agent" }, "Close hands back")
    }

    // MARK: L512 — "You were in control" after a relaunch; Close hands back

    @MainActor func test09_relaunchHeldResumeAndHandBack() throws {
        launch()
        openScreen()
        waitLive()
        takeOver()
        let old = ledger()["lease"].flatMap { ($0 as? [String: Any])?["viewer_id"] as? String }
        XCTAssertNotNil(old)
        pause(0.5)
        app.terminate()

        launch(reset: false)
        openScreen()
        waitLive()
        XCTAssertTrue(waitUntil(timeout: 8) { self.caption() == "You were in control" }, "the badge (\(caption()))")
        XCTAssertEqual(text("screen.note.held"), "You were in control of this screen. Resume Control, or give it back to the bot.")
        XCTAssertEqual(app.buttons["screen.take"].label, "Resume Control")
        XCTAssertTrue(app.buttons["screen.give"].exists, "Hand back")
        shot("screen-held")
        app.buttons["screen.give"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.botInControl() && self.lease()["holder"] as? String == "agent" })
        let release = calls("display.lease.release").last
        XCTAssertEqual(release?["viewer_id"] as? String, old, "released by the old id")
        XCTAssertEqual(release?["force"] as? Bool, true)
        XCTAssertFalse(el("screen.note.held").exists)

        // Again, and resume instead.
        takeOver()
        pause(0.5)
        app.terminate()
        launch(reset: false)
        openScreen()
        waitLive()
        XCTAssertTrue(waitUntil(timeout: 8) { self.caption() == "You were in control" })
        app.buttons["screen.take"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { self.caption() == "You are in control" }, "resumed (\(caption()))")
        let mark = inputs().count
        movePointer(dy: 40)
        XCTAssertTrue(waitUntil(timeout: 5) { self.inputs().count > mark }, "input works after resuming")

        // Close while in control: the socket closes with 1000 and the lease is the bot's; no badge next time.
        closeScreen()
        XCTAssertTrue(waitUntil(timeout: 6) { self.lease()["holder"] as? String == "agent" }, "Close hands back at once")
        XCTAssertEqual(int(sockets().last?["close_code"]), 1000, "with a close frame: \(String(describing: sockets().last))")
        app.terminate()
        launch(reset: false)
        openScreen()
        waitLive()
        pause(1)
        XCTAssertTrue(botInControl(), "no saved hold after a clean Close")

        // A hold saved more than 24 hours ago is forgotten.
        takeOver()
        pause(0.5)
        app.terminate()
        launch(reset: false, arguments: ["-HQScreenHoldAge", "90000"])
        openScreen()
        waitLive()
        pause(1)
        XCTAssertNotEqual(caption(), "You were in control", "a day-old hold shows no badge")
        XCTAssertFalse(el("screen.note.held").exists)
    }

    // MARK: L512 — another viewer: force hand-back, eviction, the loop guard

    @MainActor func test10_otherViewerForceHandBackAndEviction() throws {
        launch()
        openScreen()
        waitLive()
        ctl(["other_takes": true])
        XCTAssertTrue(waitUntil(timeout: 8) { self.caption() == "Another viewer is in control" }, caption())
        XCTAssertEqual(text("screen.note.other"), "Another viewer has control. End Their Control gives it back to the bot.")
        let force = app.buttons["screen.force"]
        XCTAssertTrue(force.exists)
        XCTAssertEqual(force.label, "End Their Control")
        shot("screen-other-viewer")
        force.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.lease()["holder"] as? String == "agent" && self.botInControl() })

        // Evicted while in control: the pill, watching, the keyboard down, nothing sent afterwards.
        takeOver()
        raiseKeyboard()
        ctl(["other_takes": true])
        XCTAssertTrue(el("screen.pill.taken").waitForExistence(timeout: 8), "the pill")
        XCTAssertEqual(text("screen.pill.taken"), "Another viewer took control. Watching only.")
        shot("screen-control-taken")
        XCTAssertTrue(waitUntil(timeout: 8) { self.caption() == "Another viewer is in control" && self.value("typing") == 0 && self.value("control") == 0 })
        waitLive()
        let mark = inputs().count
        let dropped = int(ledger()["dropped_inputs"])
        el("screen.stage").tap()
        pause(0.6)
        XCTAssertEqual(inputs().count, mark)
        XCTAssertEqual(int(ledger()["dropped_inputs"]), dropped, "nothing is sent without the lease")

        // Four evictions in ten seconds: the viewer stops re-attaching and says so.
        app.buttons["screen.force"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.botInControl() })
        takeOver()
        ctl(["other_takes": 4, "every_ms": 500])
        let ended = el("screen.ended.title")
        XCTAssertTrue(ended.waitForExistence(timeout: 30), "the loop guard (\(debugValue()))")
        XCTAssertEqual(ended.label, "Another viewer took control. Watching only.")
        XCTAssertTrue(app.buttons["screen.reconnect"].exists)
        shot("screen-evicted")
        pause(7)
        app.buttons["screen.reconnect"].tap()
        waitLive()
        XCTAssertEqual(caption(), "Another viewer is in control")
    }

    // MARK: L513 — the notes, the error line, the control-only setup

    @MainActor func test11_notes() throws {
        launch()
        openScreen()
        waitLive()
        XCTAssertEqual(text("screen.note.mac"), "This is the Mac’s own screen, shared by all bots on this Mac.")
        XCTAssertFalse(el("screen.note.control").exists || el("screen.enable-control").exists)

        ctl(["health": ["control": false], "health_now": true])
        XCTAssertTrue(el("screen.note.control").waitForExistence(timeout: 8))
        XCTAssertEqual(text("screen.note.control"), "Control needs setup on this Mac before taps and typing can work.")
        XCTAssertTrue(waitUntil(timeout: 5) { !self.app.buttons["screen.take"].isEnabled }, "Take over waits for control")
        let enable = app.buttons["screen.enable-control"]
        XCTAssertTrue(enable.exists, "Enable Screen Control")
        shot("screen-note-control")

        // The control-only card and "Check setup" (readiness rows 10, 11, 12 and 16).
        enable.tap()
        XCTAssertTrue(el("screen.setup.card.control").waitForExistence(timeout: 5))
        XCTAssertEqual(text("screen.setup.heading"), "Enable Screen Control")
        XCTAssertEqual(app.buttons["screen.setup.primary"].label, "Enable Control with Hermes")
        let check = app.buttons["screen.setup.check"]
        check.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.text("screen.setup.message") == "Viewing is ready. Finish setup with Hermes to enable pointer, clicks, and typing." },
                      text("screen.setup.message"))
        shot("screen-control-setup")
        ctl(["health": ["tcc_screen": false]])
        check.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.text("screen.setup.message") == "Allow Screen Recording for Hermes HQ Screen on the Mac." }, text("screen.setup.message"))
        ctl(["health": ["tcc_screen": true, "control": true, "tcc_events": false]])
        check.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.text("screen.setup.message") == "Allow Accessibility for Hermes HQ Screen on the Mac to use control." }, text("screen.setup.message"))
        ctl(["health": ["tcc_events": true]])
        check.tap()
        XCTAssertTrue(waitUntil(timeout: 8) {
            self.text("screen.setup.message") == "Viewing and control are ready. Open Screen, then tap Take Control to use the pointer and keyboard."
        }, text("screen.setup.message"))
        app.buttons["sheet.close"].firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { !self.el("screen.setup.card.control").exists })
        waitLive()
        ctl(["health_now": true])
        XCTAssertTrue(waitUntil(timeout: 20) { !self.el("screen.note.control").exists }, "control is ready again")

        ctl(["health": ["locked": true], "health_now": true])
        XCTAssertTrue(el("screen.note.locked").waitForExistence(timeout: 8), "the locked line without reopening")
        XCTAssertEqual(text("screen.note.locked"), "The Mac is locked: taps and typing are ignored until it is unlocked at the Mac.")
        ctl(["health": ["secure_input": true], "health_now": true])
        XCTAssertTrue(el("screen.note.secure").waitForExistence(timeout: 8))
        XCTAssertEqual(text("screen.note.secure"), "A password field has focus on the Mac, so macOS blocks typed text.")
        shot("screen-notes-locked-secure")
        ctl(["health": ["locked": false, "secure_input": false], "health_now": true])
        XCTAssertTrue(waitUntil(timeout: 8) { !self.el("screen.note.locked").exists && !self.el("screen.note.secure").exists })

        // A failing Take over: the gateway's words, Dismiss, and a later success clears it too.
        ctl(["fail": ["display.lease.acquire": "Display lease is unreadable"]])
        let take = app.buttons["screen.take"]
        XCTAssertTrue(waitUntil(timeout: 10) { take.isEnabled })
        take.tap()
        let error = el("screen.error")
        XCTAssertTrue(error.waitForExistence(timeout: 8), "the error line")
        XCTAssertTrue(error.label.contains("Display lease is unreadable"), error.label)
        shot("screen-error-line")
        app.buttons["screen.error.dismiss"].tap()
        XCTAssertTrue(waitUntil(timeout: 4) { !error.exists }, "Dismiss removes it")
        take.tap()
        XCTAssertTrue(error.waitForExistence(timeout: 8))
        ctl(["fail": ["display.lease.acquire": NSNull()]])
        takeOver()
        XCTAssertFalse(error.exists, "a successful Take over clears the error")
        closeScreen()

        ctl(["mode": "linux"])
        openScreen()
        waitLive()
        pause(1)
        XCTAssertFalse(el("screen.note.mac").exists, "no shared-Mac line off the Mac")
        XCTAssertFalse(el("screen.notes").exists && el("screen.notes").frame.height > 1, "no notes at all")
    }

    // MARK: L514 — the Mac health poll

    @MainActor func test12_healthPollAndLegacyRoute() throws {
        launch()
        XCTAssertEqual(health().new + health().legacy, 0, "nothing is asked before a Screen opens")
        XCTAssertEqual(int(ledger()["status_calls"]), 0, "and no status either")
        openScreen()
        waitLive()
        pause(38)
        var hits = health()
        note("health hits after about 40 s: \(hits)")
        XCTAssertTrue((3...4).contains(hits.new), "one at once and one every 15 s: \(hits)")
        XCTAssertEqual(hits.legacy, 0)

        // In the background nothing is asked; back in front one request at once.
        XCUIDevice.shared.press(.home)
        pause(3)
        let quiet = health()
        pause(20)
        XCTAssertEqual(health().new, quiet.new, "no poll in the background")
        app.activate()
        XCTAssertTrue(waitUntil(timeout: 8) { self.health().new > quiet.new }, "asked again at once in front")
        waitLive()
        closeScreen()

        // The old route answers on a gateway with the old plugin, and is remembered.
        ctl(["health": ["plugin": "legacy"]])
        hits = health()
        openScreen()
        waitLive()
        pause(18)
        let legacy = health()
        note("legacy gateway: \(legacy) (before \(hits))")
        XCTAssertEqual(legacy.new - hits.new, 1, "the new route was tried once")
        XCTAssertGreaterThanOrEqual(legacy.legacy - hits.legacy, 2, "then only the old one")
        XCTAssertTrue(waitUntil(timeout: 10) { self.app.buttons["screen.take"].isEnabled }, "its answer counts")
        closeScreen()

        // No plugin at all: no Mac lines, no Take over, the control-only setup offered.
        ctl(["health": ["plugin": "none"]])
        openScreen()
        waitLive()
        XCTAssertTrue(app.buttons["screen.enable-control"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["screen.take"].isEnabled, "input readiness is unknown")
        XCTAssertFalse(el("screen.note.control").exists || el("screen.note.locked").exists)
        closeScreen()

        // A Linux screen has no health route.
        try account.control("/__fixture/screen/reset", [:])
        ctl(["mode": "linux"])
        openScreen()
        waitLive()
        pause(4)
        XCTAssertEqual(health().new + health().legacy, 0, "no health request off the Mac")
    }

    // MARK: L515 — out of view pauses the stream; it comes back by itself

    @MainActor func test13_pauseInBackgroundAndResume() throws {
        launch()
        openScreen()
        waitLive()
        takeOver()
        let hash = lease()["viewer_hash"] as? String
        XCUIDevice.shared.press(.home)
        pause(5)
        var socket = sockets().last ?? [:]
        XCTAssertFalse(socket["closed_at"] is NSNull, "the socket ended in the background: \(socket)")
        // URLSession ends a cancelled socket with a bare close frame (no status), which a gateway reads as 1005:
        // never 1000 or 1001, the two codes that hand the lease back.
        XCTAssertFalse([1000, 1001].contains(int(socket["close_code"])), "not a close that hands control back: \(socket)")
        let sent = int(socket["frames_sent"])
        XCTAssertEqual(lease()["holder"] as? String, "human", "the lease is kept")
        XCTAssertEqual(lease()["viewer_hash"] as? String, hash)
        pause(2)
        XCTAssertEqual(int(sockets().last?["frames_sent"]), sent, "no frames afterwards")
        XCTAssertEqual(int(ledger()["open_sockets"]), 0)

        app.activate()
        XCTAssertTrue(waitUntil(timeout: 15) { self.int(self.ledger()["open_sockets"]) == 1 && self.value("frames") >= 1 }, "live again without a tap")
        XCTAssertTrue(waitUntil(timeout: 10) { self.caption() == "You are in control" }, "and in control again (\(caption()))")
        XCTAssertEqual(lease()["holder"] as? String, "human")

        // One dropped stream is re-attached silently.
        var count = sockets().count
        ctl(["stream": ["drop": true]])
        XCTAssertTrue(waitUntil(timeout: 15) { self.sockets().count > count && self.int(self.ledger()["open_sockets"]) == 1 }, "a new socket by itself")
        XCTAssertFalse(el("screen.ended.title").exists)
        waitLive()
        // A second within ten seconds is said out loud, and Reconnect works.
        ctl(["stream": ["drop": true]])
        let ended = el("screen.ended.title")
        XCTAssertTrue(ended.waitForExistence(timeout: 15), "the second drop ends the Screen")
        XCTAssertEqual(ended.label, "Screen Stopped")
        shot("screen-stream-ended")
        app.buttons["screen.reconnect"].tap()
        waitLive()

        // A stream that stalls mid-update is replaced by itself.
        pause(11)
        count = sockets().count
        ctl(["stream": ["stall_after": 5]])
        socket = [:]
        XCTAssertTrue(waitUntil(timeout: 25) { self.sockets().count > count }, "a new socket after the stall")
        waitLive()
        XCTAssertFalse(ended.exists, "one stall is healed silently")
    }

    // MARK: L517 — the setup card

    @MainActor func test14_setupCardRequestCheckAndAutoOpen() throws {
        ctl(["mode": "unsupported"])
        launch()
        openScreen()
        let primary = app.buttons["screen.setup.primary"], check = app.buttons["screen.setup.check"]
        XCTAssertTrue(primary.waitForExistence(timeout: 10), "the card shows under the screenshots")
        XCTAssertEqual(primary.label, "Set Up with Hermes")
        XCTAssertEqual(check.label, "Check Setup")
        XCTAssertEqual(text("screen.setup.heading"), "Set Up Viewing and Control")
        reveal(check)
        shot("screenshots-setup-card")

        // Check setup: the first line that applies.
        check.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.text("screen.setup.message") == "This bot does not have access to the Mac’s screen." }, text("screen.setup.message"))
        ctl(["health": ["plugin": "none"]])
        check.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.text("screen.setup.message") == "The Mac screen plugin is not loaded in this gateway yet." }, text("screen.setup.message"))
        ctl(["health": ["plugin": "new", "enabled": false]])
        check.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.text("screen.setup.message") == "Screen sharing is not enabled on the Mac yet." }, text("screen.setup.message"))
        reveal(el("screen.setup.message"))      // the line sits under the buttons: on screen for the picture
        shot("screenshots-setup-checked")
        ctl(["health": ["enabled": true]])

        // A refused attach: an alert on the chat, nothing queued.
        ctl(["fail": ["file.attach": "No space left on the gateway"]])
        primary.tap()
        let alert = app.alerts["Couldn’t Start Screen Setup"]
        XCTAssertTrue(alert.waitForExistence(timeout: 25), "the failure is said")
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "No space left on the gateway")).firstMatch.exists)
        XCTAssertTrue(app.tables["chat.table"].exists, "over the bot's chat")
        shot("screen-setup-failed")
        alert.buttons["OK"].tap()
        XCTAssertEqual((ledger()["prompts"] as? [Any])?.count, 0, "nothing was sent")
        ctl(["fail": ["file.attach": NSNull()]])
        backToBots()

        // The request: the installer attached once, then the prompt with its three installer lines.
        openScreen()
        XCTAssertTrue(primary.waitForExistence(timeout: 10))
        XCTAssertEqual(primary.label, "Set Up with Hermes", "a failed request is not a requested one")
        primary.tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 15), "the Screen closes and the chat opens")
        XCTAssertTrue(waitUntil(timeout: 25) { ((self.ledger()["prompts"] as? [Any])?.count ?? 0) == 1 }, "the request went out")
        // The message is in the chat: under its short title while it is on its way, and as the gateway stored it
        // once the transcript comes back (the web app's transcript shows the stored words too).
        let bubble = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "You said: Set up live")).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 10), "the request is in the chat")
        note("setup bubble: \(bubble.label.prefix(90))")
        shot("screen-setup-requested-chat")
        let seen = ledger()
        let attached = (seen["attach"] as? [[String: Any]]) ?? []
        XCTAssertEqual(attached.count, 1)
        XCTAssertEqual(attached.first?["name"] as? String, "hermes-hq-screen-setup.zip")
        XCTAssertEqual(int(attached.first?["bytes"]), 550_200)
        XCTAssertEqual(attached.first?["sha256"] as? String, "71ff241d0a3e803b8a457a9df5f91c14df48c1f227893d785974837af0c8de09")
        let prompt = ((seen["prompts"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(prompt.hasPrefix("Set up"), "it starts with the setup prompt: \(prompt.prefix(80))")
        XCTAssertTrue(prompt.hasSuffix("Installer source: @file:/tmp/fixture/hermes-hq-screen-setup.zip\nSHA-256: 71ff241d0a3e803b8a457a9df5f91c14df48c1f227893d785974837af0c8de09\nSigned helper inside the bundle: hermes-hq-screen-setup/Hermes HQ Screen.app"),
                      "and ends with the three installer lines: \(prompt.suffix(220))")
        XCTAssertFalse(prompt.localizedCaseInsensitiveContains("dispatch"), "the old product name is never sent")

        // Reopened: "Continue with Hermes", and a second tap attaches nothing new.
        backToBots()
        openScreen()
        XCTAssertTrue(primary.waitForExistence(timeout: 10))
        XCTAssertEqual(primary.label, "Continue with Hermes")
        XCTAssertEqual(text("screen.setup.message"), "Setup was requested in your bot’s chat. Hermes will report any permissions or requirements that still need attention.")
        reveal(check)
        shot("screenshots-setup-continue")

        // The gateway finishes setting up while the card is on screen: the live Screen opens by itself. (The test
        // says when: a timer started at the request raced the steps above on a loaded Mac and swapped the card for
        // the live Screen while the test was still reading it.)
        ctl(["mode": "mac"])
        XCTAssertTrue(waitUntil(timeout: 40) { self.value("frames") >= 1 }, "the live Screen replaced the card, untouched (\(debugValue()))")
        XCTAssertFalse(el("screenshots.page").exists && el("screenshots.page").isHittable)
        XCTAssertEqual(((ledger()["attach"] as? [Any]) ?? []).count, 1, "one installer only")
        closeScreen()

        // A Windows gateway: the sentence only, no buttons.
        try account.control("/__fixture/screen/reset", [:])
        ctl(["mode": "unsupported", "host": "windows", "shots": ["seed": 1]])
        openScreen()
        XCTAssertTrue(el("screen.setup.windows").waitForExistence(timeout: 15), "the Windows sentence")
        XCTAssertEqual(text("screen.setup.windows"), "Live screen sharing isn’t available on Windows yet. Your bot’s latest screenshots will appear here.")
        XCTAssertEqual(text("screenshots.heading"), "Live screen sharing isn’t available on the computer running Hermes")
        XCTAssertFalse(app.buttons["screen.setup.primary"].exists || app.buttons["screen.setup.check"].exists, "no buttons that could do nothing")
        reveal(el("screen.setup.windows"))
        shot("screenshots-windows")
    }

    @MainActor private func backToBots() {
        let row = app.cells["bot-row-default"]
        for _ in 0..<3 where !(row.exists && row.isHittable) {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists { back.tap() }
            _ = waitUntil(timeout: 4) { row.exists && row.isHittable }
        }
        XCTAssertTrue(row.exists && row.isHittable, "back on the Bots list")
    }

    /// Scrolls the fallback page until `element` can be tapped.
    @MainActor private func reveal(_ element: XCUIElement) {
        let page = el("screenshots.page")
        for _ in 0..<6 {
            if element.exists && element.isHittable { return }
            page.swipeUp()
        }
    }

    // MARK: L212, L518 — the latest screenshots

    @MainActor func test15_latestScreenshotsLiveStoredExpired() throws {
        ctl(["mode": "unsupported"])
        launch()
        // The bot's chat was opened in this run, so the tool events of its session count as this bot's (also after
        // the chat was left: a bot keeps working while nobody looks).
        app.cells["bot-row-default"].tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 10))
        _ = waitUntil(timeout: 6) { self.app.tables["chat.table"].cells.count > 0 }   // its history, when it has any
        pause(2)
        backToBots()

        openScreen()
        XCTAssertTrue(el("screenshots.page").waitForExistence(timeout: 10))
        XCTAssertEqual(text("screenshots.heading"), "Screen sharing isn’t set up on the computer running Hermes")
        XCTAssertEqual(text("screenshots.detail"), "Instead, Hermes’s latest screenshot shows here and updates while the bot works.")
        XCTAssertTrue(waitUntil(timeout: 10) {
            self.text("screenshots.status") == "No screenshots yet. When Hermes uses its computer or browser, the newest one appears here."
        }, text("screenshots.status"))
        shot("screenshots-empty")

        // Seeded: the newest shows with its caption and age, within two polls.
        ctl(["shots": ["seed": 3]])
        XCTAssertTrue(el("screenshots.frame.shown").waitForExistence(timeout: 12), "the newest screenshot shows")
        let line = el("screenshots.caption")
        XCTAssertTrue(waitUntil(timeout: 5) { line.exists && line.label.contains(" · ") }, text("screenshots.caption"))
        let first = line.label
        note("caption: \(first)")
        XCTAssertTrue(first.hasPrefix("Looked at the screen · "), "the newest of three is the capture: \(first)")
        let shown = el("screenshots.frame.shown").frame
        XCTAssertEqual(shown.height / max(1, shown.width), 400.0 / 640.0, accuracy: 0.02, "the frame has the picture's shape: \(shown)")
        shot("screenshots-shown")
        XCTAssertTrue(waitUntil(timeout: 14) { line.label != first }, "the age advances while watching (\(line.label))")

        // Zoom: pinch to at most 5×, double tap in and out.
        let picture = el("screenshots.picture")
        picture.pinch(withScale: 3, velocity: 2)
        XCTAssertTrue(waitUntil(timeout: 4) { self.value("shotZoom") > 1.3 }, debugValue())
        picture.pinch(withScale: 5, velocity: 3)
        picture.pinch(withScale: 5, velocity: 3)
        pause(0.5)
        XCTAssertLessThanOrEqual(value("shotZoom"), 5.0)
        shot("screenshots-zoomed")
        picture.doubleTap()
        XCTAssertTrue(waitUntil(timeout: 4) { abs(self.value("shotZoom") - 1) < 0.01 }, "double tap fits")
        picture.doubleTap()
        XCTAssertTrue(waitUntil(timeout: 4) { self.value("shotZoom") > 2 }, "double tap zooms")
        picture.doubleTap()
        pause(0.6)

        // Nothing changing: only the sessions list is polled.
        var seen = ledger()
        let polls = int(seen["sessions_polls"]), fetches = int(seen["messages_fetches"])
        pause(10)
        seen = ledger()
        note("10 s idle: \(int(seen["sessions_polls"]) - polls) session polls, \(int(seen["messages_fetches"]) - fetches) message fetches")
        XCTAssertTrue((2...5).contains(int(seen["sessions_polls"]) - polls), "about one poll every 3 s")
        XCTAssertEqual(int(seen["messages_fetches"]), fetches, "no messages fetch while nothing changes")

        // A stored screenshot arrives with no event, within two polls.
        ctl(["shots": ["stored": 1]])
        XCTAssertTrue(waitUntil(timeout: 12) { line.label.hasPrefix("Clicked in Safari") }, "the stored step shows: \(line.label)")

        // A live step: the caption says what is happening, then the new picture replaces the old one.
        ctl(["shots": ["live": ["tool": "computer_use", "action": "type", "app": "Notes"]]])
        XCTAssertTrue(waitUntil(timeout: 10) { line.label.contains("Notes") }, "the live step is captioned: \(line.label)")
        XCTAssertTrue(el("screenshots.frame.shown").exists, "no blank gap")
        // The picture that came with the event (an inline 640 × 400 capture) replaces the stored one, in a frame of
        // its own proportions.
        XCTAssertTrue(waitUntil(timeout: 8) { line.label.hasPrefix("Typed in Notes · ") }, "the live step's picture arrived: \(line.label)")
        let box = el("screenshots.frame.shown").frame
        XCTAssertEqual(box.height / max(1, box.width), 400.0 / 640.0, accuracy: 0.02, "the frame keeps the picture's shape: \(box)")
        shot("screenshots-live")

        // In the background nothing is asked.
        XCUIDevice.shared.press(.home)
        pause(4)
        let quiet = int(ledger()["sessions_polls"])
        pause(8)
        XCTAssertEqual(int(ledger()["sessions_polls"]), quiet, "no poll in the background")
        app.activate()
        XCTAssertTrue(waitUntil(timeout: 10) { self.int(self.ledger()["sessions_polls"]) > quiet }, "polling again in front")
        closeScreen()

        // The newest capture is gone from the gateway: the sentence, never a broken picture.
        ctl(["shots": ["stored": 1, "expire": "latest"]])
        openScreen()
        XCTAssertTrue(el("screenshots.frame.expired").waitForExistence(timeout: 15), "expired")
        XCTAssertEqual(text("screenshots.status"), "This screenshot has expired: the gateway keeps only its 20 most recent screenshots.")
        shot("screenshots-expired")
        closeScreen()

        // The blocked heading carries the blocker with one period.
        ctl(["mode": "blocked"])
        openScreen()
        XCTAssertTrue(waitUntil(timeout: 10) { self.text("screenshots.heading") == "Screen sharing needs attention" }, text("screenshots.heading"))
        XCTAssertEqual(text("screenshots.detail"),
                       "Screen sharing is off on this Mac. Choose Set up with Hermes to enable it. Meanwhile, Hermes’s latest screenshot shows here.")
        shot("screenshots-blocked")
    }

    // MARK: L345 — a step's screenshot in its sheet; an expired one says so

    @MainActor func test16_toolScreenshotInStepSheet() throws {
        ctl(["shots": ["seed": 3, "chat": true]])
        // Written for Rows: One Line (the default) draws each step as its own line, with no run to open.
        launch(arguments: ["-hq.chat.toolCallStyle", "rows"])
        app.cells["bot-row-default"].tap()
        let table = app.tables["chat.table"]
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        let steps = try openSteps()
        XCTAssertGreaterThanOrEqual(steps, 3, "the chat's screen steps")

        // First step: the screenshot shows; a tap opens the viewer.
        openStep(0)
        let picture = el("step.screenshot")
        XCTAssertTrue(picture.waitForExistence(timeout: 10), "the step shows its screenshot")
        XCTAssertTrue(waitUntil(timeout: 10) { picture.images.firstMatch.exists || picture.frame.height > 60 })
        pause(1)
        shot("step-screenshot")
        XCTAssertFalse(el("step.screenshot.expired").exists)
        picture.tap()
        let viewer = app.buttons["viewer.close"]   // the photo viewer, or the screenshot viewer under the same bars
        if viewer.waitForExistence(timeout: 4) {
            shot("step-screenshot-viewer")
            viewer.tap()
        }
        closeStep()
        openStep(1)
        XCTAssertTrue(picture.waitForExistence(timeout: 10))
        closeStep()
        openStep(2)
        XCTAssertTrue(picture.waitForExistence(timeout: 10))
        closeStep()
        XCTAssertEqual(int(ledger()["fs_list_hits"]), 1, "three steps of one folder cost one listing")

        // The first capture is pruned on the gateway: a new chat load shows the note, and Output starts with it.
        ctl(["shots": ["expire": ["shot-0001.png"]]])
        backToBots()
        app.terminate()
        launch(reset: false, arguments: ["-hq.chat.toolCallStyle", "rows"])
        app.cells["bot-row-default"].tap()
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        _ = try openSteps()
        openStep(0)
        let gone = el("step.screenshot.expired")
        XCTAssertTrue(gone.waitForExistence(timeout: 12), "the expired note")
        XCTAssertEqual(gone.label, "This screenshot has expired: the gateway keeps only its 20 most recent screenshots.")
        XCTAssertFalse(picture.exists && picture.isHittable, "no broken picture")
        // The Output block's whole text is its value: the note, a blank line, then what the tool said.
        let output = app.textViews.matching(NSPredicate(format: "value BEGINSWITH %@", "This screenshot has expired: the gateway keeps only its 20 most recent screenshots.\n\n")).firstMatch
        XCTAssertTrue(output.waitForExistence(timeout: 5), "Output starts with the note")
        XCTAssertTrue(((output.value as? String) ?? "").contains("Shareable screenshot saved to"), "and keeps the tool's own words after it")
        shot("step-screenshot-expired")
        closeStep()
        // A stored row after the relaunch still shows its screenshot (the path form).
        openStep(1)
        XCTAssertTrue(picture.waitForExistence(timeout: 10), "a stored step keeps its screenshot")
        closeStep()

        // An unreadable folder proves nothing: the picture still loads, and the folder is not asked again at once.
        ctl(["shots": ["listing": "fail"]])
        backToBots()
        app.terminate()
        launch(reset: false, arguments: ["-hq.chat.toolCallStyle", "rows"])
        app.cells["bot-row-default"].tap()
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        _ = try openSteps()
        let before = int(ledger()["fs_list_hits"])
        for _ in 0..<3 {
            openStep(2)
            XCTAssertTrue(picture.waitForExistence(timeout: 10), "the picture loads without a listing")
            XCTAssertFalse(gone.exists)
            closeStep()
        }
        XCTAssertLessThanOrEqual(int(ledger()["fs_list_hits"]) - before, 1, "at most one listing in 30 s for that step")
    }

    /// Opens the chat's run of steps (one row, "… used 2 tools", until it is tapped) and returns how many it has.
    @MainActor private func openSteps() throws -> Int {
        let table = app.tables["chat.table"]
        let run = table.buttons.matching(NSPredicate(format: "value IN %@", ["Collapsed", "Expanded"])).firstMatch
        XCTAssertTrue(run.waitForExistence(timeout: 12), "the run of steps shows")
        note("steps row: \(run.label)")
        if (run.value as? String) == "Collapsed" {
            run.tap()
            XCTAssertTrue(waitUntil(timeout: 5) { (run.value as? String) == "Expanded" }, "the run opens in place")
        }
        XCTAssertTrue(waitUntil(timeout: 5) { self.stepLines().count > 0 }, "the steps are buttons")
        let lines = stepLines()
        note("steps: \(lines.map(\.label))")
        return lines.count
    }

    /// The steps of the open run, top to bottom: the table's buttons that are neither the run's own row nor a reply's
    /// actions.
    @MainActor private func stepLines() -> [XCUIElement] {
        let other = ["Copy", "Regenerate", "More"]
        let all = app.tables["chat.table"].buttons.matching(NSPredicate(
            format: "identifier == '' AND NOT (label IN %@) AND NOT (value IN %@)", other, ["Collapsed", "Expanded"])).allElementsBoundByIndex
        return all.filter(\.exists).sorted { $0.frame.minY < $1.frame.minY }
    }

    @MainActor private func openStep(_ index: Int) {
        let lines = stepLines()
        XCTAssertTrue(index < lines.count, "step \(index) of \(lines.count)")
        guard index < lines.count else { return }
        lines[index].tap()
        XCTAssertTrue(app.buttons["sheet.close"].firstMatch.waitForExistence(timeout: 6), "the step's sheet opens")
    }

    @MainActor private func closeStep() {
        app.buttons["sheet.close"].firstMatch.tap()
        _ = waitUntil(timeout: 5) { !self.app.buttons["sheet.close"].exists }
    }

    // MARK: L509, L520 — a Linux screen: the lossless encodings, pixel for pixel

    @MainActor func test17_linuxEncodingsPixelExact() throws {
        ctl(["mode": "linux"])
        launch()
        for encoding in ["tight-basic", "raw", "copyrect", "mixed"] {
            ctl(["stream": ["encoding": encoding, "fps": 4]])
            openScreen()
            waitLive()
            XCTAssertTrue(waitUntil(timeout: 12) { self.value("frames") >= 4 }, "\(encoding): \(debugValue())")
            var got = "", want = ""
            let same = waitUntil(timeout: 12) {
                want = ((try? self.account.control("/__fixture/screen/expect"))?["probe"] as? String) ?? "-"
                got = self.field("probe", in: self.debugValue())
                return got == want
            }
            XCTAssertTrue(same, "\(encoding): the phone's pixels are the fixture's: \(got) vs \(want)")
            XCTAssertEqual(field("mainDecodes", in: debugValue()), "0")
            if encoding == "mixed" {
                XCTAssertFalse(el("screen.note.mac").exists)
                takeOver()
                let mark = inputs().count
                movePointer(dy: 50)
                el("screen.stage").tap()
                XCTAssertTrue(waitUntil(timeout: 5) { self.pointers(from: mark).contains { $0.mask == 1 } }, "control works on a Linux screen")
                shot("screen-linux-control")
            }
            closeScreen()
        }
        let seen = ledger()
        XCTAssertEqual((seen["unknown_params"] as? [Any])?.count, 0)
        XCTAssertEqual(int(seen["forbidden_calls"]), 0, "never stop, thumbnail, install or switch")
        let kinds = Set(((seen["client_messages"] as? [String: Any]) ?? [:]).keys)
        XCTAssertTrue(kinds.isSubset(of: ["0", "2", "3", "4", "5", "6"]), "only the six client messages: \(kinds)")
        XCTAssertEqual(int(seen["max_outstanding_requests"]), 1)
        XCTAssertEqual(int(seen["open_sockets"]), 0)
    }

    // MARK: Hooks — Bot Info's Screen tile and the Computer group's Screen row

    @MainActor func test18_botInfoTileAndComputerRow() throws {
        launch()
        openBotInfo()
        let tile = app.buttons["bot-info.tile.screen"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "the Screen tile")
        XCTAssertEqual(tile.label, "Screen")
        shot("bot-info-screen-tile")
        let before = int(ledger()["status_calls"])
        tile.tap()
        XCTAssertTrue(app.buttons["screen.close"].waitForExistence(timeout: 10), "the tile opens the Screen over Bot Info")
        waitLive()
        XCTAssertGreaterThan(int(ledger()["status_calls"]), before)
        let close = app.buttons["screen.close"]
        close.tap()
        let list = app.collectionViews["bot-info.list"]
        XCTAssertTrue(waitUntil(timeout: 10) { !close.exists && list.exists }, "closing the Screen leaves Bot Info open")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        let row = app.buttons["bot-info.screen"]
        for _ in 0..<5 where !(row.exists && row.isHittable) { list.swipeUp() }
        XCTAssertTrue(row.exists, "the Computer group's Screen row")
        XCTAssertTrue(row.label.contains("Watch Screen"), row.label)
        XCTAssertTrue(row.label.contains("Live"), "the bot holds a running screen: \(row.label)")
        XCTAssertTrue(app.staticTexts["Computer"].exists || app.staticTexts["COMPUTER"].exists, "under Computer")
        shot("bot-info-computer-row")
        row.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 10), "the row opens the Screen")
        waitLive()
        close.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !close.exists && list.exists }, "the Screen closes back to Bot Info")
    }

    @MainActor private func openBotInfo() {
        let cell = app.cells["bot-row-default"]
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        let info = app.buttons["Bot Info"]
        for _ in 0..<3 where !info.exists {
            cell.press(forDuration: 1.1)
            _ = info.waitForExistence(timeout: 5)
        }
        info.tap()
        XCTAssertTrue(app.collectionViews["bot-info.list"].waitForExistence(timeout: 6), "Bot Info opens")
    }

    // MARK: States S3, S4 — Screen is off; Screen packages missing

    // MARK: Review findings 3 and 5 — a Mac with no picture yet; a screenshot that cannot be fetched

    /// The Mac's helper answers the handshake but has no picture (sharing paused from its menu): the viewer waits
    /// longer than the 8 s stuck limit, then says why, and Reconnect shows the picture once the Mac sends one.
    @MainActor func test22_macWithNoPictureSaysWhy() throws {
        ctl(["mode": "mac", "stream": ["first_frame_delay_ms": -1], "health": ["paused": true]])
        launch()
        openScreen()
        let began = Date()
        let ended = el("screen.ended.title")
        XCTAssertTrue(ended.waitForExistence(timeout: 45), "the viewer gives up on the first picture in words (\(debugValue()))")
        let took = Date().timeIntervalSince(began)
        note(String(format: "no first picture: said so after %.1f s", took))
        XCTAssertGreaterThan(took, 12, "it waited well past the 8 s stuck limit before saying so")
        XCTAssertEqual(ended.label, "The Mac hasn’t sent a picture yet")
        XCTAssertEqual(text("screen.ended"), "Resume sharing from Hermes HQ Screen’s menu on the Mac.")
        XCTAssertTrue(app.buttons["screen.reconnect"].exists)
        XCTAssertEqual(calls("display.observe").count, 1, "it did not try again by itself")
        shot("screen-no-picture")
        // Sharing resumed on the Mac: Reconnect shows the picture.
        ctl(["stream": ["first_frame_delay_ms": 0], "health": ["paused": false]])
        app.buttons["screen.reconnect"].tap()
        waitLive()
        closeScreen()
    }

    /// A screenshot the gateway still has but cannot hand over just now (503) is not called expired; the page says it
    /// is trying again and shows the picture by itself once the download works.
    @MainActor func test23_aScreenshotThatCannotBeFetchedIsRetriedNotExpired() throws {
        ctl(["mode": "unsupported", "shots": ["seed": 2, "download_status": 503]])
        launch()
        openScreen()
        XCTAssertTrue(el("screenshots.page").waitForExistence(timeout: 10))
        XCTAssertTrue(el("screenshots.frame.unloadable").waitForExistence(timeout: 15), "the failed download is not an expired capture")
        XCTAssertEqual(text("screenshots.status"), "Can’t load the screenshot. Trying again…")
        XCTAssertFalse(el("screenshots.frame.expired").exists)
        shot("screenshots-unloadable")
        let tried = int(ledger()["downloads"])
        XCTAssertTrue(waitUntil(timeout: 12) { self.int(self.ledger()["downloads"]) > tried }, "it asks again by itself")
        ctl(["shots": ["download_status": 0]])
        // After its first five quick tries the page asks every tenth poll (30 s), so a slow run may be on that pace.
        XCTAssertTrue(el("screenshots.frame.shown").waitForExistence(timeout: 50), "and shows the picture once the gateway hands it over")
        // A file that is really gone (404) is still the expired sentence.
        ctl(["shots": ["stored": 1, "expire": "latest"]])
        XCTAssertTrue(el("screenshots.frame.expired").waitForExistence(timeout: 15), "a missing file is expired")
        XCTAssertEqual(text("screenshots.status"), "This screenshot has expired: the gateway keeps only its 20 most recent screenshots.")
        closeScreen()
    }

    @MainActor func test19_screenOffStartAndPackagesMissing() throws {
        ctl(["mode": "off"])
        launch()
        openScreen()
        XCTAssertTrue(el("screen.off.title").waitForExistence(timeout: 10))
        XCTAssertEqual(text("screen.off.title"), "Screen Is Off")
        XCTAssertEqual(text("screen.off"), "Start this bot’s desktop to watch what it does and take over when it needs you.")
        let start = app.buttons["screen.start"]
        XCTAssertEqual(start.label, "Start Screen")
        shot("screen-off")
        start.tap()
        waitLive()
        XCTAssertEqual(calls("display.start").count, 1)
        closeScreen()

        ctl(["mode": "not-installed"])
        openScreen()
        XCTAssertTrue(el("screen.missing.title").waitForExistence(timeout: 10))
        XCTAssertEqual(text("screen.missing.title"), "Screen Add-on Missing")
        XCTAssertEqual(text("screen.missing"), "The computer running Hermes needs a desktop add-on before Hermes can have a screen. Whoever looks after it can run this there:")
        let command = el("screen.command")
        XCTAssertTrue(command.exists, "the install command")
        XCTAssertFalse(((command.value as? String) ?? "").isEmpty, "the command is shown")
        shot("screen-missing")
        let pills = value("pills")
        app.buttons["screen.copy"].tap()
        // The note stays 2 s: the app's own count is the proof, the words are checked whenever the query is in time.
        let onScreen = text("screen.pill.copied")
        XCTAssertTrue(waitUntil(timeout: 8) { self.value("pills") == pills + 1 }, "one note shows: \(debugValue())")
        XCTAssertEqual(field("lastPill", in: debugValue()), "screen.pill.copied:Copied")
        if !onScreen.isEmpty { XCTAssertEqual(onScreen, "Copied") }
        // Check Again asks the gateway once more; with the packages still missing the page stays.
        let asked = int(ledger()["status_calls"])
        app.buttons["screen.check-again"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.int(self.ledger()["status_calls"]) > asked }, "Check Again reads the status again")
        XCTAssertTrue(el("screen.missing.title").waitForExistence(timeout: 8), "still missing")
        // Once the host has them the Screen opens by itself (the gateway says so in a status event).
        ctl(["mode": "mac"])
        waitLive(20)
        XCTAssertEqual(int(ledger()["forbidden_calls"]), 0, "the app never installs anything itself")
    }

    /// A Hermes Cloud agent (the fixture passes for one with -HQDebugCloudHost): Nous picks its image, so a missing screen
    /// offers the agent's size instead of an install command, and an old release says Nous updates it.
    @MainActor func test19b_cloudAgentScreenNotIncluded() throws {
        ctl(["mode": "not-installed"])
        launch(arguments: ["-HQDebugCloudHost", "YES"])
        openScreen()
        XCTAssertTrue(el("screen.cloud-missing.title").waitForExistence(timeout: 10))
        XCTAssertEqual(text("screen.cloud-missing.title"), "Screen Isn’t Included")
        XCTAssertEqual(text("screen.cloud-missing"), "Hermes Cloud includes Screen on agents with 8 GB of memory or more. Hermes’s agent is smaller, so it can’t be added there.")
        XCTAssertFalse(el("screen.command").exists, "no install command on a cloud agent")
        XCTAssertEqual(app.buttons["screen.cloud-agent"].label, "Agent Size…")
        shot("screen-cloud-missing")
        closeScreen()

        ctl(["mode": "unavailable"])
        openScreen()
        XCTAssertTrue(el("screenshots.heading").waitForExistence(timeout: 10))
        XCTAssertEqual(text("screenshots.heading"), "Screen isn’t on this Hermes Cloud release yet")
        shot("screen-cloud-unavailable")
        closeScreen()
        XCTAssertEqual(int(ledger()["forbidden_calls"]), 0, "the app never installs anything itself")
    }

    /// Whether `button` can be tapped, scrolling its page up to three times to get to it.
    @MainActor private func reach(_ button: XCUIElement) -> Bool {
        for _ in 0..<3 where !(button.exists && button.isHittable) { app.swipeUp() }
        return button.exists && button.isHittable
    }

    // MARK: Every state at the largest text size

    @MainActor func test20_largestTextSize() throws {
        launch(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        ctl(["health": ["control": false, "locked": true, "secure_input": true]])
        openScreen()
        waitLive()
        XCTAssertTrue(el("screen.note.secure").waitForExistence(timeout: 10))
        let stage = el("screen.stage"), window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(stage.frame.height, 119, "the picture keeps its room with every note showing")
        shot("screen-ax5-notes")
        ctl(["health": ["control": true, "locked": false, "secure_input": false], "health_now": true])
        XCTAssertTrue(waitUntil(timeout: 10) { !self.el("screen.note.secure").exists })
        takeOver()
        let give = app.buttons["screen.give"]
        XCTAssertTrue(give.isHittable, "Hand back can be reached")
        XCTAssertTrue(window.contains(give.frame), "and is on screen: \(give.frame)")
        XCTAssertGreaterThanOrEqual(stage.frame.height, 119)
        XCTAssertGreaterThanOrEqual(app.buttons["screen.keyboard.toggle"].frame.height, 43.5, "the keyboard button keeps a 44 pt target")
        shot("screen-ax5-control")
        raiseKeyboard()
        XCTAssertGreaterThanOrEqual(stage.frame.height, 119, "also with the keyboard up")
        for id in ["screen.key.esc", "screen.mod.ctrl", "screen.paste"] {
            XCTAssertGreaterThanOrEqual(app.buttons[id].frame.height, 43.5, "\(id) keeps a 44 pt target")
        }
        shot("screen-ax5-keyboard")
        app.buttons["screen.keyboard.toggle"].tap()
        closeScreen()

        // A failing status read, from a fresh launch: a screen this run has seen running opens on what it knew.
        ctl(["fail": ["display.status": "Bot Desktop state is unreadable."]])
        launch(reset: false, arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        openScreen()
        XCTAssertTrue(el("screen.no-answer.title").waitForExistence(timeout: 10))
        XCTAssertTrue(reach(app.buttons["screen.retry"]), "Retry can be reached")
        shot("screen-ax5-no-answer")
        ctl(["fail": ["display.status": NSNull()]])
        closeScreen()

        ctl(["mode": "unsupported", "shots": ["seed": 2]])
        openScreen()
        XCTAssertTrue(el("screenshots.heading").waitForExistence(timeout: 10))
        XCTAssertTrue(el("screenshots.frame.shown").waitForExistence(timeout: 12))
        shot("screenshots-ax5-top")
        let check = app.buttons["screen.setup.check"]
        let page = el("screenshots.page")
        for _ in 0..<12 where !(check.exists && check.isHittable) { page.swipeUp() }
        XCTAssertTrue(check.isHittable, "the card's buttons are reached by scrolling")
        shot("screenshots-ax5-card")
        check.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { !self.text("screen.setup.message").isEmpty })
        closeScreen()

        ctl(["mode": "off"])
        openScreen()
        XCTAssertTrue(el("screen.off.title").waitForExistence(timeout: 10))
        XCTAssertTrue(reach(app.buttons["screen.start"]), "Start screen can be reached")
        shot("screen-ax5-off")
    }
}
