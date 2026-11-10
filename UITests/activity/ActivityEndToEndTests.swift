// End-to-end checks of the activity stream (docs/spec/1x-activity.md §16) against the activity fixture
// (scripts/fixtures/activity-gateway.py). Run with scripts/e2e-activity.sh: it starts the fixture on 9732, passes its
// credentials as TEST_RUNNER_HQN_UI_CREDENTIALS and, for screenshots, a folder as TEST_RUNNER_HQN_SHOTS_DIR with the
// appearance as TEST_RUNNER_HQN_SHOTS_SUFFIX. Without the credentials every test skips.

import XCTest

final class ActivityEndToEndTests: XCTestCase {
    static let botRow = "bot-row-default"
    static let rid = "5cc537d1"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Fixture

    nonisolated(unsafe) static let goal: [String: Any] = [
        "title": "Ship 2.4", "status": "active", "turns_used": 3, "max_turns": 20,
        "contract": ["outcome": "Notes published", "verification": "The changelog page shows 2.4", "constraints": "",
                     "boundaries": "", "stop_when": ""],
        "subgoals": ["Draft notes", "Publish to the blog"], "gates": [] as [Any],
        "last_verdict": "continue", "last_reason": "Notes drafted; publishing next",
    ]

    /// A clean slate on the fixture: no goal, no children, no task snapshot, display flags on.
    func reset(_ account: FixtureAccount) throws {
        try account.control("/__fixture/control", ["profile": "default", "control": [String: Any](), "emit": false])
        try account.control("/__fixture/subagents", ["subagents": [Any](), "delegations": [Any]()])
        try account.control("/__fixture/todo-state", ["profile": "default", "todos": [Any](), "revision": 0])
        try account.control("/__fixture/config", ["profile": "default", "display": [String: Any]()])
    }

    func event(_ account: FixtureAccount, _ type: String, _ payload: [String: Any]) throws {
        try account.control("/__fixture/event", ["profile": "default", "type": type, "payload": payload])
    }

    func activityLog(_ account: FixtureAccount) throws -> [String: Any] { try account.control("/__fixture/activity") }

    func calls(_ account: FixtureAccount, _ method: String) throws -> [[String: Any]] {
        ((try activityLog(account)["calls"] as? [[String: Any]]) ?? []).filter { $0["method"] as? String == method }
    }

    nonisolated(unsafe) static let delegationPlan: [String: Any] = {
        let tasks: [[String: Any]] = [["goal": "Read the changelog"], ["goal": "Check open issues"]]
        let events: [[String: Any]] = [
            ["type": "reasoning.delta", "payload": ["text": "Split the work: changelog and open issues."]],
            ["after": 2.4, "type": "tool.start", "payload": ["tool_id": "call_d1", "name": "delegate_task", "args": ["tasks": tasks]]],
            ["type": "subagent.spawn_requested", "payload": ["goal": "Read the changelog", "task_count": 2, "task_index": 0, "subagent_id": "sa_1", "model": "fixture-model"]],
            ["type": "subagent.start", "payload": ["goal": "Read the changelog", "task_count": 2, "task_index": 0, "subagent_id": "sa_1", "status": "running"]],
            ["type": "subagent.start", "payload": ["goal": "Check open issues", "task_count": 2, "task_index": 1, "subagent_id": "sa_2", "status": "running"]],
            ["after": 1.5, "type": "subagent.tool", "payload": ["goal": "Read the changelog", "task_count": 2, "task_index": 0, "subagent_id": "sa_1", "tool_name": "read_file", "tool_preview": "CHANGELOG.md", "text": "CHANGELOG.md"]],
            ["after": 1.5, "type": "todo.updated", "payload": ["todos": [["id": "1", "content": "Read the changelog", "status": "in_progress"], ["id": "2", "content": "Write the notes", "status": "pending"]], "revision": 1]],
            ["after": 1.5, "type": "tool.start", "payload": ["tool_id": "call_p1", "name": "patch", "args": ["path": "/app/src/app.py"]]],
            ["after": 0.5, "type": "tool.complete", "payload": ["tool_id": "call_p1", "name": "patch", "args": ["path": "/app/src/app.py"], "result": ["success": true], "inline_diff": "┊ review diff\na/src/app.py → b/src/app.py\n@@ -1 +1 @@\n-print(\"before\")\n+print(\"after\")", "duration_s": 0.4]],
            ["after": 2, "type": "subagent.complete", "payload": ["goal": "Read the changelog", "task_count": 2, "task_index": 0, "subagent_id": "sa_1", "status": "completed", "summary": "Found 14 changes", "duration_seconds": 4.2]],
            ["after": 1, "type": "subagent.complete", "payload": ["goal": "Check open issues", "task_count": 2, "task_index": 1, "subagent_id": "sa_2", "status": "timeout", "duration_seconds": 9]],
            ["type": "tool.complete", "payload": ["tool_id": "call_d1", "name": "delegate_task", "args": ["tasks": tasks], "result": ["results": [["task_index": 0, "status": "completed", "summary": "Found 14 changes", "model": "fixture-model", "duration_seconds": 4.2], ["task_index": 1, "status": "timeout", "summary": "Timed out after 9s", "duration_seconds": 9]]], "duration_s": 9.5]],
            ["type": "todo.updated", "payload": ["todos": [["id": "1", "content": "Read the changelog", "status": "completed"], ["id": "2", "content": "Write the notes", "status": "completed"]], "revision": 2]],
            ["after": 0.3, "type": "message.delta", "payload": ["text": "Done: 14 changes, notes written; the issues check timed out."]],
        ]
        return ["holdAfter": 0.5, "events": events]
    }()

    // MARK: App

    /// The first launch of a run starts from a clean slate: the simulator may still hold another account (a demo
    /// gateway, a fixture from an earlier run) whose cached Bots list would pass for this fixture's.
    nonisolated(unsafe) static var signedInThisRun = false

    @MainActor func launch(_ account: FixtureAccount, args: [String] = [], reset accounts: Bool = false, pinsStyle: Bool = true) -> XCUIApplication {
        if !Self.signedInThisRun && !accounts {
            let first = XCUIApplication()
            first.launchArguments = ["-HQDebugResetAccounts", "YES"]
            first.launch()
            signIn(first, account)
            XCTAssertTrue(first.cells[Self.botRow].waitForExistence(timeout: 20), "signed in to the fixture")
            first.terminate()
        }
        Self.signedInThisRun = true
        let app = XCUIApplication()
        // [talk] The first-run Talk tip is switched off here: it is a card above the composer that the transcript's end
        // makes room for (docs/spec/3x-talk.md §5.1), and these tests measure that end to the point.
        // These tests were written for Rows and every timestamp; One Line and Fewer Timestamps became the defaults later.
        // `pinsStyle: false` for a test that switches the style: a launch argument outranks the switch's stored value.
        let look = !pinsStyle || args.contains("-hq.chat.toolCallStyle") ? [] : ["-hq.chat.toolCallStyle", "rows"]
        app.launchArguments = (accounts ? ["-HQDebugResetAccounts", "YES"] : []) + ["-hq.voice.tip.talk", "YES"] + look
            + ["-hq.chat.fewerTimestamps", "NO"] + args
        app.launch()
        let row = app.cells[Self.botRow]
        let chat = app.tables["chat.table"]
        let form = app.textFields["sign-in-address"]
        _ = waitUntil(timeout: 15) { row.exists || chat.exists || form.exists }
        if !row.exists && !chat.exists && form.exists { signIn(app, account) }
        XCTAssertTrue(waitUntil(timeout: 15) { row.exists || chat.exists }, "the Bots list (or the chat a launch hook opened) shows")
        return app
    }

    @MainActor func signIn(_ app: XCUIApplication, _ account: FixtureAccount) {
        let address = app.textFields["sign-in-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 15))
        address.tap()
        if let current = address.value as? String, !current.isEmpty, current != "my-mac.tail1234.ts.net" {
            address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        address.typeText(account.url)
        let username = app.textFields["sign-in-username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap()
        if let current = username.value as? String, !current.isEmpty, current != "Username" {
            username.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        username.typeText(account.username)
        let password = app.secureTextFields["sign-in-password"]
        // [a11y] The keyboard the username raised covers the password field's middle, so a tap there can land on a
        // key ("Neither element nor any descendant has keyboard focus", seen on the train too). The keyboard's Next
        // key moves on to the password, as the form intends; a tap is only the fallback.
        username.typeText("\n")
        let focused = { (password.value(forKey: "hasKeyboardFocus") as? Bool) ?? false }
        if !waitUntil(timeout: 6, focused) {
            password.tap()
            XCTAssertTrue(waitUntil(timeout: 6, focused), "the password field takes the keyboard")
        }
        password.typeText(account.password)
        app.buttons["sign-in-password-button"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for candidate in [app.buttons["Not Now"], springboard.buttons["Not Now"]] where candidate.waitForExistence(timeout: 2) {
            candidate.tap()
            break
        }
    }

    @MainActor @discardableResult func openChat(_ app: XCUIApplication) -> XCUIElement {
        let row = app.cells[Self.botRow]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the bot row shows")
        row.tap()
        let table = app.tables["chat.table"]
        if !table.waitForExistence(timeout: 4) {
            // A tap the sign-in's own transition (or the Save Password offer) swallowed: once more.
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            for candidate in [app.buttons["Not Now"], springboard.buttons["Not Now"]] where candidate.exists { candidate.tap() }
            row.tap()
        }
        XCTAssertTrue(table.waitForExistence(timeout: 5), "the chat opens")
        return table
    }

    /// Signs in if needed, opens Hermes's chat and sends `text` through the app's DEBUG hook (the words go in the field
    /// and Send is pressed without raising the keyboard, so the shelf and the newest rows stay in view).
    @MainActor func launchAndSend(_ account: FixtureAccount, _ text: String, args: [String] = []) -> XCUIApplication {
        let attempts = { ((try? account.control("/__fixture/state"))?["promptAttempts"] as? Int) ?? 0 }
        let before = attempts()
        let app = launch(account, args: ["-HQDebugOpenBot", "default", "-HQDebugSend", text] + args)
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 10), "the chat opens")
        if !waitUntil(timeout: 8, { attempts() > before }) {
            // Signed in through the form: the launch hooks ran before the Bots list; send by hand.
            if !app.tables["chat.table"].exists { openChat(app) }
            send(app, text, account)
        }
        return app
    }

    @MainActor func send(_ app: XCUIApplication, _ text: String, _ account: FixtureAccount) {
        let field = app.textViews["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
        let button = app.buttons["composer.send"]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        let attempts = { ((try? account.control("/__fixture/state"))?["promptAttempts"] as? Int) ?? 0 }
        let before = attempts()
        button.tap()
        if !waitUntil(timeout: 3, { attempts() > before }) { button.tap() }
        dismissKeyboard(app)
    }

    /// Drags the transcript down into the keyboard (the table dismisses it interactively).
    @MainActor func dismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.firstMatch.waitForExistence(timeout: 0.5) else { return }
        let table = app.tables["chat.table"]
        let start = table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let end = table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.05)
        _ = waitUntil(timeout: 2) { !app.keyboards.firstMatch.exists }
    }

    @MainActor func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    /// The app's per-frame motion sampler (`-HQDebugMotionProbe YES`, App/Chat/Activity/ActivityMotionProbe.swift): what
    /// every rendered frame since its last reset measured (largest move of any row, of its height, one-frame step, the
    /// newest row's distance to the dock, and the watched rows of a fold).
    @MainActor func motion(_ app: XCUIApplication) -> [String: Any] {
        let probe = element(app, "debug.motion")
        guard probe.waitForExistence(timeout: 3), let data = probe.label.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    @MainActor func number(_ json: [String: Any], _ key: String) -> Double { (json[key] as? NSNumber)?.doubleValue ?? .nan }

    @MainActor func labelled(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
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

    @MainActor @discardableResult
    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    // MARK: Verify round 1: the composer row under a tall dock

    /// A message queued while the goal chip, an open Tasks card (4 todos) and a subagent chip fill the shelf, keyboard
    /// up: ☰, + and the field stay on Stop's row, the queue card keeps its height above it (verify round 1: the jump
    /// button's limit squashed the composer, its field dropped 30 pt under the keys and the card lost a line).
    /// Verify round 2: a chat whose last turn left a finished task list opens with the folded Previous tasks chip (no
    /// opened Tasks card that folds 4 s later), and a reopen draws its whole shelf — goal, running child, previous tasks —
    /// from the first frame: the rows never move.
    @MainActor func test31_OpenWithShelfStateNeverSlides() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        try account.control("/__fixture/history", ["profile": "default", "count": 40])
        try account.control("/__fixture/control", ["profile": "default", "control": ["goal": Self.goal], "emit": false])
        try account.control("/__fixture/todo-state", ["profile": "default", "revision": 4, "todos": [
            ["id": "1", "content": "Read the changelog", "status": "completed"], ["id": "2", "content": "Write the notes", "status": "completed"]]])
        try account.control("/__fixture/subagents", ["delegations": [Any](), "subagents": [[
            "subagent_id": "sa_open", "goal": "Index the docs", "status": "running", "started_at": Date().timeIntervalSince1970 - 30,
            "model": "fixture-model", "depth": 0, "tool_count": 2, "last_tool": "read_file", "accepting_steer": true]]])
        let app = launch(account, args: ["-HQDebugMotionProbe", "YES"])
        openChat(app)
        let previous = element(app, "chat.shelf.previousTasks")
        XCTAssertTrue(previous.waitForExistence(timeout: 5), "Previous tasks shows")
        XCTAssertEqual(previous.value as? String, "collapsed", "folded from the start")
        XCTAssertFalse(element(app, "chat.shelf.tasks").exists, "no live Tasks card on an idle open")
        XCTAssertTrue(element(app, "chat.shelf.goal").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "chat.shelf.subagents").waitForExistence(timeout: 8))
        let first = motion(app)
        print("[test31] first open motion: \(first)")
        Thread.sleep(forTimeInterval: 5)          // past the old 4 s linger: nothing folds and nothing moves
        XCTAssertEqual(number(motion(app), "still"), number(first, "still"), accuracy: 1, "nothing moves once the chat settled")
        // Back and open again: the store's state draws the shelf in the first frame.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.cells[Self.botRow].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        openChat(app)
        XCTAssertTrue(element(app, "chat.shelf.subagents").waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 2.5)
        let again = motion(app)
        XCTAssertLessThanOrEqual(number(again, "still"), 1, "a reopen never slides the transcript: \(again)")
        shot("reopen-shelf-steady")
        try reset(account)
    }

    @MainActor func test30_ComposerRowStaysWholeUnderAFullShelfAndQueue() throws {
        let account = try FixtureAccount.load()
        let goal: [String: Any] = ["title": "Ship 2.4", "status": "active", "turns_used": 3, "max_turns": 20,
            "contract": ["outcome": "Notes published", "verification": "", "constraints": "", "boundaries": "", "stop_when": ""],
            "subgoals": ["Draft notes"], "gates": [] as [Any], "last_verdict": "continue", "last_reason": "Notes drafted"]
        try account.control("/__fixture/subagents", ["subagents": [Any](), "delegations": [Any]()])
        try account.control("/__fixture/todo-state", ["profile": "default", "todos": [Any](), "revision": 0])
        try account.control("/__fixture/control", ["profile": "default", "control": ["goal": goal], "emit": false])
        let app = launch(account)
        openChat(app)
        try account.control("/__fixture/plan", ["plans": [["chunks": Array(repeating: "slow ", count: 160), "chunkDelay": 0.25],
                                                         ["chunks": ["Queued reply done."]]]])
        let field = app.textViews["composer.text"]
        send(app, "start a long one", account)
        XCTAssertTrue(app.buttons["composer.stop"].waitForExistence(timeout: 8), "the reply runs")
        try account.control("/__fixture/event", ["profile": "default", "type": "subagent.start", "payload": [
            "goal": "Read the changelog since 2.3", "task_count": 1, "task_index": 0, "subagent_id": "sa_r1", "status": "running",
            "model": "fixture-model"]])
        let todos: [[String: Any]] = (1...4).map { ["id": "\($0)", "content": "Task number \($0)", "status": $0 == 1 ? "in_progress" : "pending"] }
        try account.control("/__fixture/event", ["profile": "default", "type": "todo.updated", "payload": ["todos": todos, "revision": 1]])
        XCTAssertTrue(labelled(app, containing: "Task number 1").waitForExistence(timeout: 5), "the Tasks card shows")
        field.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { app.keyboards.count > 0 }, "the keyboard is up")
        field.typeText("queued behind")
        XCTAssertTrue(waitUntil(timeout: 5) { (field.value as? String) == "queued behind" }, "the words are in the field")
        IPad.pressReturn(app, .command)                    // ⌘Return queues; a plain send would go into the reply
        XCTAssertTrue(waitUntil(timeout: 3) { ((field.value as? String) ?? "").isEmpty }, "⌘Return took the words")
        let queue = element(app, "chat.queue")
        XCTAssertTrue(queue.waitForExistence(timeout: 5), "the queue card shows")
        Thread.sleep(forTimeInterval: 1)
        shot("composer-under-full-shelf")
        // [talk] The circle tells accessibility its 44 pt touch box (PrimaryButton.accessibilityFrame); the drawn
        // 40 pt circle these checks are about is 2 pt inside it on every side.
        let stop = app.buttons["composer.stop"].frame.insetBy(dx: 2, dy: 2), text = field.frame, commands = element(app, "composer.commands").frame
        XCTAssertEqual(text.maxY, stop.maxY, accuracy: 2.5, "the field stays on Stop's row (\(text) vs \(stop))")
        XCTAssertEqual(commands.maxY, stop.maxY, accuracy: 2.5, "☰ stays on Stop's row")
        XCTAssertGreaterThanOrEqual(text.height, 38, "the field keeps its height")
        XCTAssertGreaterThanOrEqual(queue.frame.height, 60, "the queue card keeps its two lines")
        XCTAssertLessThanOrEqual(queue.frame.maxY, stop.minY + 1, "the queue card sits above the row")
        // Verify round 2: the docked cards share the row's side edges, and the shelf never climbs under the title:
        // with the subagents card opened too, its cards give way (and scroll) instead.
        let shelf = element(app, "chat.shelf")
        XCTAssertEqual(queue.frame.minX, commands.minX, accuracy: 1, "the queue card lines up with ☰")
        XCTAssertEqual(shelf.frame.minX, commands.minX, accuracy: 1, "the shelf lines up with ☰")
        XCTAssertEqual(shelf.frame.maxX, stop.maxX, accuracy: 1, "the shelf lines up with Stop")
        let chip = element(app, "chat.shelf.subagents")
        if chip.exists && chip.isHittable { chip.tap() }
        Thread.sleep(forTimeInterval: 1)
        shot("full-shelf-subagents-open")
        let bar = app.navigationBars.firstMatch.frame
        XCTAssertGreaterThanOrEqual(shelf.frame.minY, bar.maxY + 18, "the shelf stays under the status line (\(shelf.frame) vs bar \(bar))")
        XCTAssertEqual(field.frame.maxY, stop.maxY, accuracy: 2.5, "the composer row is still whole")
        app.buttons["composer.stop"].tap()
        // Leave the fixture as the other tests expect it.
        try account.control("/__fixture/subagents", ["subagents": [Any](), "delegations": [Any]()])
        try account.control("/__fixture/todo-state", ["profile": "default", "todos": [Any](), "revision": 0])
        try account.control("/__fixture/control", ["profile": "default", "control": [String: Any](), "emit": false])
    }

    // MARK: (11, 13, 14) Subagent chip, card, tail, Steer and Stop

    @MainActor func test11_SubagentChipCardSteerAndStop() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        let app = launch(account)
        openChat(app)
        let goal = "Read the changelog since 2.3 and list the user-facing changes"
        try event(account, "subagent.start", ["goal": goal, "task_count": 1, "task_index": 0, "subagent_id": "sa_ui1", "status": "running", "model": "fixture-model"])
        try event(account, "subagent.tool", ["goal": goal, "task_count": 1, "task_index": 0, "subagent_id": "sa_ui1", "tool_name": "read_file", "tool_preview": "CHANGELOG.md"])
        try account.control("/__fixture/tail", ["subagent_id": "sa_ui1", "text": "$ git log v2.3..HEAD --oneline\na1b2c3 Export chats\nd4e5f6 Faster sync", "truncated": false])
        let chip = element(app, "chat.shelf.subagents")
        XCTAssertTrue(chip.waitForExistence(timeout: 3), "the chip appears")
        XCTAssertTrue(chip.label.hasPrefix("1 helper"), "chip words: \(chip.label)")
        shot("subagents-chip")
        chip.tap()
        let row = labelled(app, containing: goal)
        XCTAssertTrue(row.waitForExistence(timeout: 3), "the card lists the child")
        XCTAssertTrue((row.value as? String)?.contains("Read File(\"CHANGELOG.md\")") == true, "with its newest activity: \(String(describing: row.value))")
        shot("subagents-card")
        row.tap()
        let field = element(app, "chat.subagent.steer-field")
        XCTAssertTrue(field.waitForExistence(timeout: 3), "the detail shows the Steer row")
        XCTAssertFalse(app.buttons["chat.subagent.steer"].isEnabled, "Send is off while the field is empty")
        XCTAssertTrue(labelled(app, containing: "Output").waitForExistence(timeout: 5), "the tail shows")
        shot("subagents-detail")
        field.tap()
        field.typeText("Only open issues")
        app.buttons["chat.subagent.steer"].tap()
        let feedback = element(app, "chat.subagent.feedback")
        XCTAssertTrue(waitUntil(timeout: 5) { feedback.exists && feedback.label == "Queued for the next checkpoint" }, "steer queued")
        let steers = (try activityLog(account)["steers"] as? [[String: Any]]) ?? []
        XCTAssertEqual(steers.last?["text"] as? String, "Only open issues")
        XCTAssertEqual(steers.last?["queued"] as? Bool, true)
        XCTAssertEqual((field.value as? String).map { $0 == "Steer this helper…" || $0.isEmpty }, true, "the field cleared")
        shot("subagents-steered")
        // The headless simulator keeps the on-screen keys minimized while the field has focus; a touch can bring the full
        // keyboard up under the finger, and the card riding up with it ends the touch outside Stop. Once the keys have
        // settled, a second tap lands.
        let stop = app.buttons["chat.subagent.stop"]
        stop.tap()
        if !waitUntil(timeout: 2, { !((try? self.calls(account, "subagent.interrupt")) ?? []).isEmpty }) { stop.tap() }
        // The child's `subagent.complete` (interrupted, ~0.3 s later) marks its page Stopped; the open card stays with it
        // (owner, 2026-10-29: finished helpers keep their results) until you fold it.
        XCTAssertTrue(labelled(app, containing: "Stopped").waitForExistence(timeout: 5), "the page says the child stopped")
        XCTAssertTrue(waitUntil(timeout: 3) { chip.label.hasPrefix("Helper finished") }, "chip words: \(chip.label)")
        shot("subagents-stopped")
        chip.tap()
        let gone = waitUntil(timeout: 5) { !chip.exists || !chip.isHittable }
        if !gone { shot("zz-11-chip-stays") }
        XCTAssertTrue(gone, "folding the finished card puts it away (chip: \(chip.exists ? chip.label : "gone"))")
        let interrupts = try calls(account, "subagent.interrupt")
        XCTAssertEqual(interrupts.last?["params"] as? [String: String], ["session_id": Self.rid, "profile": "default", "subagent_id": "sa_ui1"])
        let list = try calls(account, "subagent.list")
        XCTAssertFalse(list.isEmpty, "the roster was read")
        XCTAssertEqual(list.first?["params"] as? [String: String], ["session_id": Self.rid, "profile": "default"])
        let tails = try calls(account, "subagent.tail")
        XCTAssertFalse(tails.isEmpty, "the tail was read while the detail was open")
        // The child ended with its detail open: the tail read stops with it (§4.4, "detail closed / chat left").
        Thread.sleep(forTimeInterval: 5)
        XCTAssertEqual(try calls(account, "subagent.tail").count, tails.count, "no tail reads after the child ended")
    }

    // MARK: (4.1) Several helpers: the list, a finished one's result, a page with steps, files and output

    /// TEST_RUNNER_HQN_DESKTOP_LOOK=1: the same in the Desktop Look (shots named "dl-…").
    @MainActor func test11c_SeveralHelpersListAndPage() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        let desktop = ProcessInfo.processInfo.environment["HQN_DESKTOP_LOOK"] == "1"
        let dark = ProcessInfo.processInfo.environment["HQN_SHOTS_SUFFIX"] == "dark"
        let app = launch(account, args: ["-HQDebugDesktopLook", desktop ? "YES" : "NO"] + (dark ? ["-hqn.appearance", "dark"] : []))
        let shot: (String) -> Void = { name in self.shot((desktop ? "dl-" : "") + name) }
        openChat(app)
        let goals = ["Read the changelog since 2.3 and list the user-facing changes", "Check open issues tagged for the release",
                     "Run the test suite and report failures"]
        for (i, g) in goals.enumerated() {
            try event(account, "subagent.start", ["goal": g, "task_count": 3, "task_index": i, "subagent_id": "sa_m\(i)", "status": "running", "model": "fixture-model"])
        }
        try event(account, "subagent.tool", ["goal": goals[0], "task_count": 3, "task_index": 0, "subagent_id": "sa_m0", "tool_name": "read_file", "tool_preview": "CHANGELOG.md"])
        try event(account, "subagent.tool", ["goal": goals[0], "task_count": 3, "task_index": 0, "subagent_id": "sa_m0", "tool_name": "search_files", "tool_preview": "Export"])
        try event(account, "subagent.tool", ["goal": goals[0], "task_count": 3, "task_index": 0, "subagent_id": "sa_m0", "tool_name": "terminal", "tool_preview": "git log v2.3..HEAD --oneline"])
        try event(account, "subagent.tool", ["goal": goals[2], "task_count": 3, "task_index": 2, "subagent_id": "sa_m2", "tool_name": "terminal", "tool_preview": "swift test"])
        try event(account, "subagent.complete", ["goal": goals[1], "task_count": 3, "task_index": 1, "subagent_id": "sa_m1", "status": "completed",
                                                 "summary": "3 open issues are tagged 2.4: #412 export crash, #418 sync stall, #421 dark mode contrast.", "duration_seconds": 6.4])
        try account.control("/__fixture/tail", ["subagent_id": "sa_m0", "text": (["$ git log v2.3..HEAD --oneline"] + (1...20).map { "a1b2c\($0) Change number \($0)" }).joined(separator: "\n"), "truncated": false])
        let chip = element(app, "chat.shelf.subagents")
        XCTAssertTrue(waitUntil(timeout: 5) { chip.exists && chip.label.hasPrefix("2 helpers · 1 done") }, "chip words: \(chip.label)")
        shot("subagents-many-chip")
        chip.tap()
        let row = labelled(app, containing: goals[0])
        XCTAssertTrue(row.waitForExistence(timeout: 3), "the card lists the children")
        shot("subagents-many-card")
        row.tap()
        XCTAssertTrue(labelled(app, containing: "Output").waitForExistence(timeout: 5), "the page shows the output")
        shot("subagents-many-page")
        let finished = labelled(app, containing: goals[1])
        if !finished.isHittable { element(app, "chat.subagent.back").tap() }
        XCTAssertTrue(finished.waitForExistence(timeout: 3))
        finished.tap()
        XCTAssertTrue(labelled(app, containing: "#412 export crash").waitForExistence(timeout: 3), "the finished one's result")
        XCTAssertFalse(element(app, "chat.subagent.steer-field").exists, "no Steer row for a finished one")
        shot("subagents-many-finished")
    }

    // MARK: (4.1) The opened card with the keyboard up

    /// The card's cap follows the keyboard: with a child's detail open and the Steer field focused, the card stays under
    /// the bar. Needs the software keyboard (e2e-activity.sh turns the simulator's keyboard minimization off for it).
    @MainActor func test11b_SteerWithTheKeyboardUp() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        let app = launch(account)
        openChat(app)
        let goal = "Audit the release checklist"
        try event(account, "subagent.start", ["goal": goal, "task_count": 1, "task_index": 0, "subagent_id": "sa_kb", "status": "running"])
        try account.control("/__fixture/tail", ["subagent_id": "sa_kb", "text": (1...80).map { "line \($0) of the child's own transcript" }.joined(separator: "\n"),
                                                "truncated": true])
        let chip = element(app, "chat.shelf.subagents")
        XCTAssertTrue(chip.waitForExistence(timeout: 3))
        chip.tap()
        let row = labelled(app, containing: goal)
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        XCTAssertTrue(labelled(app, containing: "Output").waitForExistence(timeout: 5), "the tail makes the card tall")
        let field = element(app, "chat.subagent.steer-field")
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        guard app.keyboards.firstMatch.waitForExistence(timeout: 3) else {
            throw XCTSkip("no software keyboard on this simulator (hardware keyboard attached)")
        }
        Thread.sleep(forTimeInterval: 0.8)
        let bar = app.navigationBars.firstMatch
        shot("subagents-keyboard")
        XCTAssertGreaterThanOrEqual(chip.frame.minY, bar.frame.maxY, "the card's top stays under the bar with the keyboard up")
        XCTAssertLessThanOrEqual(field.frame.maxY, app.keyboards.firstMatch.frame.minY, "the Steer row stays above the keyboard")
        XCTAssertTrue(field.isHittable, "the card keeps the focused Steer row in sight")
        try event(account, "subagent.complete", ["goal": goal, "task_count": 1, "task_index": 0, "subagent_id": "sa_kb", "status": "completed"])
    }

    // MARK: (12) Roster polls back off, and stop when no child is live

    @MainActor func test12_RosterPollsBackOffAndStop() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        let app = launch(account)
        openChat(app)
        Thread.sleep(forTimeInterval: 2)
        let idle = try calls(account, "subagent.list").count
        Thread.sleep(forTimeInterval: 4)
        XCTAssertEqual(try calls(account, "subagent.list").count, idle, "no polls while no child is live")
        let goal = "Index the docs"
        try event(account, "subagent.start", ["goal": goal, "task_count": 1, "task_index": 0, "subagent_id": "sa_poll", "status": "running"])
        XCTAssertTrue(element(app, "chat.shelf.subagents").waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 20)
        // At once, then 5 s, doubling while nothing changes (0, 5, 15 s): a flat 5 s poll would make 5 or more.
        let polled = try calls(account, "subagent.list").count - idle
        XCTAssertGreaterThanOrEqual(polled, 2, "the roster is read while a child runs")
        XCTAssertLessThanOrEqual(polled, 4, "…backing off while nothing changes (\(polled) reads in 20 s)")
        try event(account, "subagent.complete", ["goal": goal, "task_count": 1, "task_index": 0, "subagent_id": "sa_poll", "status": "completed", "summary": "done"])
        Thread.sleep(forTimeInterval: 1)
        let ended = try calls(account, "subagent.list").count
        Thread.sleep(forTimeInterval: 8)
        XCTAssertEqual(try calls(account, "subagent.list").count, ended, "no polls once the last child ended")
    }

    // MARK: (16) Tasks and Previous tasks

    @MainActor func test16_TasksThenPreviousTasks() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        let app = launch(account)
        openChat(app)
        try event(account, "todo.updated", ["todos": [["id": "1", "content": "Read the changelog", "status": "in_progress"],
                                                      ["id": "2", "content": "Draft the notes", "status": "pending"]], "revision": 1])
        let chip = element(app, "chat.shelf.tasks")
        XCTAssertTrue(chip.waitForExistence(timeout: 3))
        XCTAssertTrue(chip.label.hasPrefix("Tasks 0/2"), chip.label)
        XCTAssertEqual(chip.value as? String, "expanded", "the live list opens by default")
        XCTAssertTrue(labelled(app, containing: "Draft the notes, pending").exists)
        shot("tasks-card")
        try event(account, "todo.updated", ["todos": [["id": "1", "content": "Read the changelog", "status": "completed"],
                                                      ["id": "2", "content": "Draft the notes", "status": "completed"]], "revision": 3])
        XCTAssertTrue(waitUntil(timeout: 2) { chip.label.hasPrefix("Tasks 2/2") })
        try event(account, "todo.updated", ["todos": [["id": "1", "content": "Read the changelog", "status": "pending"]], "revision": 2])
        XCTAssertTrue(chip.label.hasPrefix("Tasks 2/2"), "an older revision changes nothing")
        let previous = element(app, "chat.shelf.previousTasks")
        XCTAssertTrue(previous.waitForExistence(timeout: 7), "the finished list lingers 4 s, then Previous tasks")
        XCTAssertTrue(previous.label.hasPrefix("Previous tasks 2/2"), previous.label)
        XCTAssertEqual(previous.value as? String, "collapsed")
        XCTAssertTrue(waitUntil(timeout: 2) { !chip.isHittable })
        shot("previous-tasks-chip")
        previous.tap()
        XCTAssertTrue(labelled(app, containing: "Draft the notes, completed").waitForExistence(timeout: 3))
        shot("previous-tasks-card")
    }

    // MARK: (17) Goal

    @MainActor func test17_GoalChipCardAndActions() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        try account.control("/__fixture/control", ["profile": "default", "control": ["goal": Self.goal], "emit": false])
        let app = launch(account)
        openChat(app)
        let chip = element(app, "chat.shelf.goal")
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "the goal chip shows (read on open)")
        XCTAssertTrue(chip.label.hasPrefix("Goal active · Turn 3/20"), chip.label)
        shot("goal-chip")
        chip.tap()
        XCTAssertTrue(labelled(app, containing: "Notes drafted; publishing next").waitForExistence(timeout: 3), "the reason")
        XCTAssertTrue(labelled(app, containing: "Criteria · 2").exists)
        shot("goal-card")
        // Pause from ⋯.
        app.buttons["Goal Actions"].tap()
        app.buttons["Pause Goal"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { chip.label.hasPrefix("Goal paused · Turn 3/20") }, chip.label)
        let pause = try calls(account, "session.control").last
        XCTAssertEqual(pause?["params"] as? NSDictionary, ["session_id": Self.rid, "profile": "default", "action": "goal.pause", "args": [String: Any]()] as NSDictionary)
        // Resume while idle: a hidden continuation, no bubble.
        app.buttons["Goal Actions"].tap()
        app.buttons["Resume Goal"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { chip.label.hasPrefix("Goal active") })
        let state = try account.control("/__fixture/state")
        let submits = ((state["rpc"] as? [[String: Any]]) ?? []).filter { $0["method"] as? String == "prompt.submit" }
        XCTAssertEqual((submits.last?["params"] as? [String: Any])?["display_kind"] as? String, "hidden", "the continuation is hidden")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(labelled(app, containing: "[Continue working toward the standing goal").exists, "no user bubble for it")
        // Add a criterion.
        let add = app.buttons["Add Criterion"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        add.tap()
        let field = app.textFields["goal.criterion-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("Publish")
        shot("goal-add-criterion")
        XCTAssertTrue(waitUntil(timeout: 2) { app.alerts.buttons["Add"].isEnabled }, "Add turns on once there is text")
        // XCUITest's typing hides the simulator's keyboard for a moment and the alert slides down and back up with it: tap
        // Add once the alert rests, and again if a tap landed while it moved.
        let addButton = app.alerts.buttons["Add"]
        for _ in 0..<3 where addButton.exists {
            var last = CGRect.null
            _ = waitUntil(timeout: 3) { let f = addButton.frame; defer { last = f }; return f == last }
            addButton.tap()
            _ = waitUntil(timeout: 1.5) { !addButton.exists }
        }
        XCTAssertTrue(waitUntil(timeout: 5) { (try? self.calls(account, "session.control").last?["params"] as? [String: Any])?["action"] as? String == "subgoal.add" })
        XCTAssertEqual((try calls(account, "session.control").last?["params"] as? [String: Any])?["args"] as? [String: String], ["text": "Publish"])
        XCTAssertTrue(waitUntil(timeout: 3) { self.labelled(app, containing: "Criteria · 3").exists })
        // Remove criterion 2 (confirm).
        app.buttons.matching(NSPredicate(format: "label == %@", "Remove criterion")).element(boundBy: 1).tap()
        app.alerts.buttons["Remove Criterion 2"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { (try? self.calls(account, "session.control").last?["params"] as? [String: Any])?["action"] as? String == "subgoal.remove" })
        XCTAssertEqual((try calls(account, "session.control").last?["params"] as? [String: Any])?["args"] as? [String: Int], ["index": 2])
        // Clear the goal (confirm): the chip goes.
        app.buttons["Goal Actions"].tap()
        app.buttons["Clear Goal"].tap()
        app.alerts.buttons["Clear Goal"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !chip.exists || !chip.isHittable }, "the goal chip goes")
    }

    // MARK: (22, 24, 25) Rows + Hide: the delegation turn folds; delegate card; Show Steps; the diff

    @MainActor func test22_DelegationFoldsShowStepsAndDiff() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        try account.control("/__fixture/plan", ["plans": [Self.delegationPlan]])
        let app = launchAndSend(account, "Write the release notes", args: ["-hq.chat.toolCallsAfterReply", "hide", "-HQDebugMotionProbe", "YES"])
        let card = element(app, "chat.delegate-card")
        XCTAssertTrue(card.waitForExistence(timeout: 6), "the delegate card shows")
        XCTAssertTrue(element(app, "chat.shelf.subagents").waitForExistence(timeout: 4), "the subagents chip shows")
        XCTAssertTrue(element(app, "chat.shelf.tasks").waitForExistence(timeout: 5), "the tasks chip shows")
        shot("delegation-live")
        let edited = app.tables["chat.table"].buttons.matching(NSPredicate(format: "label BEGINSWITH 'Edit'")).firstMatch
        XCTAssertTrue(edited.waitForExistence(timeout: 8), "the file edit shows while the turn runs")
        XCTAssertTrue(labelled(app, containing: "Done: 14 changes").waitForExistence(timeout: 12), "the reply")
        XCTAssertTrue(waitUntil(timeout: 4) { !edited.exists }, "Hide folds the steps away")
        Thread.sleep(forTimeInterval: 0.8)
        // Every frame of the fold (spec §16 check 22, owner on 188): no row changes height; the reply moves once at most —
        // with its action row, in the slide — never back and forth, never a jump.
        let m = motion(app)
        XCTAssertEqual(m["mode"] as? String, "fold", "the fold was sampled: \(m)")
        XCTAssertEqual(number(m, "settled"), 1, "…to the end of its slide: \(m)")
        XCTAssertGreaterThan(number(m, "watched"), 0, "the reply was watched: \(m)")
        XCTAssertLessThanOrEqual(number(m, "height"), 0.5, "no visible row changed height in any frame: \(m)")
        XCTAssertEqual(number(m, "watchReversals"), 0, "the reply never bounced: \(m)")
        // Frame timing under XCUITest is coarse (a 46 pt slide may take one 35 pt step): a jump is the whole distance in
        // one frame, a slide spreads over several.
        if number(m, "watchDy") > 0.5 {
            XCTAssertLessThan(number(m, "watchStep"), number(m, "watchDy") - 0.5, "the reply never jumped the whole way at once: \(m)")
            XCTAssertGreaterThanOrEqual(number(m, "watchMoves"), 3, "the reply slid over several frames: \(m)")
        }
        XCTAssertTrue(element(app, "chat.copy-reply").exists, "the action row came with the fold")
        XCTAssertTrue(card.exists, "the card stays")
        XCTAssertTrue(labelled(app, containing: "Read the changelog, done").exists, "the first child done")
        XCTAssertTrue(labelled(app, containing: "Check open issues, failed").exists, "the second child failed")
        shot("delegation-folded")
        // Show Steps from the reply's menu.
        labelled(app, containing: "Done: 14 changes").press(forDuration: 1.0)
        let show = app.buttons["Show Steps"]
        XCTAssertTrue(show.waitForExistence(timeout: 3), "the reply offers Show Steps")
        show.tap()
        XCTAssertTrue(edited.waitForExistence(timeout: 3), "the steps come back")
        edited.tap()
        XCTAssertTrue(element(app, "step.diff").waitForExistence(timeout: 3), "the step sheet shows the diff")
        XCTAssertTrue(labelled(app, containing: "Removed: print(\"before\")").exists)
        XCTAssertTrue(labelled(app, containing: "Added: print(\"after\")").exists)
        shot("step-sheet-diff")
        app.buttons["sheet.close"].firstMatch.tap()
        // Hide Steps folds them again.
        labelled(app, containing: "Done: 14 changes").press(forDuration: 1.0)
        let hide = app.buttons["Hide Steps"]
        XCTAssertTrue(hide.waitForExistence(timeout: 3), "Hide Steps after Show Steps")
        hide.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { !edited.exists }, "the steps fold again")
    }

    // MARK: (21) Bubbles

    @MainActor func test21_BubblesFoldEarlierStepsAndShowShell() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        var events: [[String: Any]] = []
        for i in 0..<10 {
            let id = "call_t\(i)"
            let command = i == 0 ? "git log v2.3..HEAD --oneline --no-merges --since=2026-09-01 --author=hermes" : "npm run check:\(i)"
            events.append(["after": 0.15, "type": "tool.start", "payload": ["tool_id": id, "name": "terminal", "args": ["command": command]]])
            var complete: [String: Any] = ["tool_id": id, "name": "terminal", "args": ["command": command],
                                           "result": i == 9 ? ["output": "1 check failed", "exit_code": 2, "error": "Command failed with exit code 2"]
                                                            : ["output": "ok \(i)", "exit_code": 0], "duration_s": 0.2]
            if i == 9 { complete["error"] = true }
            events.append(["after": 0.1, "type": "tool.complete", "payload": complete])
        }
        events.append(["after": 0.2, "type": "message.delta", "payload": ["text": "The checks ran; one failed."]])
        try account.control("/__fixture/plan", ["plans": [["events": events, "holdAfter": 0.3]]])
        let app = launchAndSend(account, "Run the checks", args: ["-hq.chat.toolCallStyle", "bubbles"])
        XCTAssertTrue(labelled(app, containing: "The checks ran").waitForExistence(timeout: 12))
        let bubble = element(app, "chat.tool-bubble")
        XCTAssertTrue(bubble.waitForExistence(timeout: 3), "the steps are a tool bubble")
        XCTAssertTrue(labelled(app, containing: "⋯ 3 earlier steps").exists, "8+ lines fold the earliest")
        let failed = labelled(app, containing: "terminal: npm run check:9: Failed")
        XCTAssertTrue(failed.exists, "the failed call says so")
        shot("bubbles")
        failed.tap()
        XCTAssertTrue(app.navigationBars["Terminal"].waitForExistence(timeout: 3), "a line opens its step sheet")
        shot("step-sheet-terminal")
        app.buttons["sheet.close"].firstMatch.tap()
    }

    // MARK: (23) In Header

    @MainActor func test23_InHeaderStatusAndStepsSheet() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        let events: [[String: Any]] = [
            ["type": "reasoning.delta", "payload": ["text": "Run the tests first."]],
            ["after": 0.5, "type": "tool.start", "payload": ["tool_id": "call_h1", "name": "read_file", "args": ["path": "/app/package.json"]]],
            ["after": 0.3, "type": "tool.complete", "payload": ["tool_id": "call_h1", "name": "read_file", "args": ["path": "/app/package.json"], "result": ["content": "{}"]]],
            ["after": 0.2, "type": "tool.start", "payload": ["tool_id": "call_h2", "name": "terminal", "args": ["command": "npm test"]]],
            ["after": 6, "type": "tool.complete", "payload": ["tool_id": "call_h2", "name": "terminal", "args": ["command": "npm test"], "result": ["output": "42 passing", "exit_code": 0]]],
            ["after": 0.2, "type": "message.delta", "payload": ["text": "All 42 tests pass."]],
        ]
        try account.control("/__fixture/plan", ["plans": [["events": events, "holdAfter": 0.3]]])
        let app = launchAndSend(account, "Run the tests", args: ["-hq.chat.toolCallStyle", "header"])
        let status = element(app, "chat.status.steps")
        XCTAssertTrue(waitUntil(timeout: 6) { status.exists && status.label.contains("npm test") }, "the status line names the step")
        XCTAssertFalse(labelled(app, containing: "is thinking").exists, "no waiting row while the status line says what runs")
        XCTAssertFalse(app.tables["chat.table"].buttons.matching(NSPredicate(format: "label BEGINSWITH 'Read' OR label BEGINSWITH 'Explor' OR label BEGINSWITH 'Thought'")).firstMatch.exists,
                       "no steps or thoughts in the transcript")
        shot("in-header-status")
        status.tap()
        XCTAssertTrue(app.navigationBars["Steps"].waitForExistence(timeout: 3), "the Steps sheet opens")
        let row = labelled(app, containing: "npm test")
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        shot("in-header-steps-sheet")
        app.tables["steps.list"].cells.element(boundBy: 1).tap()
        XCTAssertTrue(app.navigationBars["Terminal"].waitForExistence(timeout: 3), "the step is pushed in the same sheet")
        app.navigationBars["Terminal"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Steps"].waitForExistence(timeout: 3), "Back returns to Steps")
        app.buttons["sheet.close"].firstMatch.tap()
        XCTAssertTrue(labelled(app, containing: "All 42 tests pass").waitForExistence(timeout: 12))
    }

    // MARK: (23b) The Steps sheet as a timeline

    /// Six steps of every kind: a long path, many lines of Python, a failed command, one still running. The sheet is
    /// photographed while the last runs and after the turn ends, in the iOS look and the Desktop Look.
    @MainActor func test23b_StepsSheetTimeline() throws {
        let account = try FixtureAccount.load()
        let python = "import subprocess,re,html,json\nS='python3 /Users/me/.hermes/profiles/otto/scripts/report.py --week 44'\nrows = json.loads(subprocess.check_output(S, shell=True))\nprint(len(rows))"
        let pool = "from concurrent.futures import ThreadPoolExecutor\ndef get(t):\n    return fetch(t)\nwith ThreadPoolExecutor(8) as ex:\n    print(list(ex.map(get, tickers)))"
        for look in ["ios", "desktop"] {
            try reset(account)
            let events: [[String: Any]] = [
                ["type": "tool.start", "payload": ["tool_id": "s1", "name": "read_file", "args": ["path": "/Users/me/.hermes/profiles/otto/reports/weekly-report-2026-w44.md"]]],
                ["after": 0.2, "type": "tool.complete", "payload": ["tool_id": "s1", "name": "read_file", "args": ["path": "/Users/me/.hermes/profiles/otto/reports/weekly-report-2026-w44.md"], "duration_s": 0.04, "result": ["content": String(repeating: "x", count: 12_000)]]],
                ["after": 0.2, "type": "tool.start", "payload": ["tool_id": "s2", "name": "execute_code", "args": ["code": python]]],
                ["after": 0.2, "type": "tool.complete", "payload": ["tool_id": "s2", "name": "execute_code", "args": ["code": python], "duration_s": 4.2, "result": ["output": "3580", "exit_code": 0]]],
                ["after": 0.2, "type": "tool.start", "payload": ["tool_id": "s3", "name": "web_search", "args": ["query": "conversion rate benchmarks"]]],
                ["after": 0.2, "type": "tool.complete", "payload": ["tool_id": "s3", "name": "web_search", "args": ["query": "conversion rate benchmarks"], "duration_s": 1.8, "result": ["results": [["title": "a"]]]]],
                ["after": 0.2, "type": "tool.start", "payload": ["tool_id": "s4", "name": "terminal", "args": ["command": "sqlite3 shop.db 'select count(*) from orders'"]]],
                ["after": 0.2, "type": "tool.complete", "payload": ["tool_id": "s4", "name": "terminal", "args": ["command": "sqlite3 shop.db 'select count(*) from orders'"], "duration_s": 0.3, "error": true, "result": ["output": "Error: no such table: sets", "exit_code": 1]]],
                ["after": 0.2, "type": "tool.start", "payload": ["tool_id": "s5", "name": "execute_code", "args": ["code": pool]]],
                ["after": 8, "type": "tool.complete", "payload": ["tool_id": "s5", "name": "execute_code", "args": ["code": pool], "duration_s": 8.1, "result": ["output": "[...]", "exit_code": 0]]],
                ["after": 0.2, "type": "message.delta", "payload": ["text": "Orders are down against last year."]],
            ]
            try account.control("/__fixture/plan", ["plans": [["events": events, "holdAfter": 0.3]]])
            // The dark pass asks the app itself: the simulator's own appearance did not reach it (2026-11-01).
            let dark = ProcessInfo.processInfo.environment["HQN_SHOTS_SUFFIX"] == "dark" ? ["-hqn.appearance", "dark"] : []
            let app = launchAndSend(account, "How are leads this week?",
                                    args: ["-hq.chat.toolCallStyle", "header", "-hqn.theme.desktopLook", look == "desktop" ? "<true/>" : "<false/>"] + dark)
            let status = element(app, "chat.status.steps")
            XCTAssertTrue(waitUntil(timeout: 10) { status.exists && status.label.contains("concurrent") }, "the last step runs: \(status.exists ? status.label : "no status")")
            status.tap()
            XCTAssertTrue(app.navigationBars["Steps"].waitForExistence(timeout: 3), "the Steps sheet opens")
            XCTAssertTrue(app.tables["steps.list"].cells.element(boundBy: 4).waitForExistence(timeout: 3), "five rows")
            Thread.sleep(forTimeInterval: 0.6)
            shot("steps-timeline-running-\(look)")
            app.swipeUp()   // the large detent
            XCTAssertTrue(waitUntil(timeout: 12) { app.navigationBars["Steps"].staticTexts["5 steps · 1 failed · 14s"].exists }, "the turn ends")
            Thread.sleep(forTimeInterval: 0.6)
            shot("steps-timeline-done-\(look)")
            app.tables["steps.list"].cells.element(boundBy: 1).tap()
            XCTAssertTrue(app.navigationBars["Terminal"].waitForExistence(timeout: 3), "the step is pushed")
            app.terminate()
        }
    }

    /// A long run like the owner's (2026-11-01: 44 steps, nearly all commands that start `cd ~/.hermes;`): the sheet
    /// mid-run at half height, after the turn at full height, and a folded run of commands opened.
    @MainActor func test23c_StepsSheetLongRun() throws {
        let account = try FixtureAccount.load()
        let commands = [
            "cd ~/.hermes; python3 -c \"\nimport json,collections;J=json.load(open('cron/jobs.json'))\nprint(collections.Counter(j['profile'] for j in J))\"",
            "cd ~/.hermes; sed -n 252,262p workflows/otto-weekly.md",
            "cd ~/.hermes; hermes cron create --name 'weekly leads' --at 'mon 08:00' --profile otto",
            "cd ~/.hermes; (hermes cron run bf3a2 && python3 -c \"import json;print('job present:', 'bf3a2' in open('cron/jobs.json').read())\")",
            "cd ~/.hermes; grep -n 'schedule' cron/jobs.json",
            "cd ~/.hermes && ls -la profiles/otto/reports | tail -20",
            "cd ~/.hermes; hermes cron list --json | python3 -m json.tool | head -40",
            "cd ~/.hermes; tail -n 50 logs/gateway.log",
            "cd ~/.hermes; cat profiles/otto/config.yaml",
            "cd ~/.hermes; hermes cron delete 7c1e9",
        ]
        var events: [[String: Any]] = []
        func add(_ id: String, _ name: String, _ args: [String: Any], seconds: Double, last: Bool = false) {
            events.append(["after": 0.05, "type": "tool.start", "payload": ["tool_id": id, "name": name, "args": args]])
            events.append(["after": last ? 9 : 0.05, "type": "tool.complete",
                           "payload": ["tool_id": id, "name": name, "args": args, "duration_s": seconds, "result": ["output": "ok", "exit_code": 0]]])
        }
        for i in 1...44 {
            switch i {
            case 12: add("l\(i)", "read_file", ["path": "/Users/me/.hermes/cron/jobs.json"], seconds: 0.03)
            case 25: add("l\(i)", "search_files", ["pattern": "weekly", "path": "/Users/me/.hermes/workflows"], seconds: 0.4)
            default: add("l\(i)", "terminal", ["command": commands[(i * 7) % commands.count]], seconds: Double(i % 9) * 0.7 + 0.2, last: i == 44)
            }
        }
        events.append(["after": 0.2, "type": "message.delta", "payload": ["text": "The weekly leads job is set for Monday 8:00."]])
        try reset(account)
        try account.control("/__fixture/plan", ["plans": [["events": events, "holdAfter": 0.3]]])
        let dark = ProcessInfo.processInfo.environment["HQN_SHOTS_SUFFIX"] == "dark" ? ["-hqn.appearance", "dark"] : []
        // HQN_STEPS_EXTRA: more launch arguments, space-separated (a background picture behind the sheet).
        let extra = (ProcessInfo.processInfo.environment["HQN_STEPS_EXTRA"] ?? "").split(separator: " ").map(String.init)
        let app = launchAndSend(account, "Set up the weekly leads job", args: ["-hq.chat.toolCallStyle", "header"] + dark + extra)
        let status = element(app, "chat.status.steps")
        XCTAssertTrue(status.waitForExistence(timeout: 20), "the run starts")
        Thread.sleep(forTimeInterval: 5)   // 43 steps take about 4.4 s; the last runs for 9 s
        status.tap()
        XCTAssertTrue(app.navigationBars["Steps"].waitForExistence(timeout: 3), "the Steps sheet opens")
        // The same moment in every run: all 44 in, the last still running.
        XCTAssertTrue(waitUntil(timeout: 10) { app.navigationBars["Steps"].staticTexts["44 steps · 1 running"].exists }, "the last step runs")
        Thread.sleep(forTimeInterval: 0.8)
        shot("steps-long-running")
        app.swipeUp()   // the large detent
        XCTAssertTrue(waitUntil(timeout: 15) { app.navigationBars["Steps"].staticTexts.matching(NSPredicate(format: "label BEGINSWITH '44 steps' AND NOT label CONTAINS 'running'")).count > 0 }, "the turn ends")
        Thread.sleep(forTimeInterval: 0.8)
        shot("steps-long-done")
        let fold = app.tables["steps.list"].cells.matching(NSPredicate(format: "identifier BEGINSWITH 'steps.fold'")).firstMatch
        if fold.exists {
            fold.tap()
            Thread.sleep(forTimeInterval: 0.8)
            shot("steps-long-fold-open")
        }
        app.terminate()
    }

    // MARK: (15) A stale Working… claim ends with delegation.status

    @MainActor func test15_StaleClaimEndsAfterReturn() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        let app = launch(account)
        openChat(app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let row = app.cells[Self.botRow]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        try event(account, "subagent.start", ["goal": "Background audit", "task_count": 1, "task_index": 0, "subagent_id": "sa_bg", "status": "running"])
        let rowText = row.buttons.firstMatch
        XCTAssertTrue(waitUntil(timeout: 4) { rowText.label.contains("Working") }, "the row says Working… while its child runs: \(rowText.label)")
        shot("bot-row-working")
        XCUIDevice.shared.press(.home)
        try account.control("/__fixture/subagents", ["subagents": [Any](), "delegations": [Any]()])
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        XCTAssertTrue(waitUntil(timeout: 8) { !rowText.label.contains("Working") }, "the claim ends: \(rowText.label)")
        let status = try calls(account, "delegation.status")
        XCTAssertFalse(status.isEmpty, "delegation.status was asked")
        XCTAssertEqual(status.last?["params"] as? [String: String], ["profile": "default"])
    }

    // MARK: (15b) [toolnow] The Bots and Sessions rows name the step a turn is on, not "Working…" (owner, 2026-10-30)

    @MainActor func test15b_RowsNameTheRunningStep() throws { try rowsNameTheRunningStep("") }

    @MainActor func test15c_RowsNameTheRunningStepInTheDesktopLook() throws {
        try rowsNameTheRunningStep("-desktop", args: ["-HQDebugDesktopLook", "YES"])
    }

    @MainActor private func rowsNameTheRunningStep(_ look: String, args: [String] = []) throws {
        let account = try FixtureAccount.load()
        try reset(account)
        let app = launch(account, args: args)
        openChat(app)
        try event(account, "message.start", [:])
        Thread.sleep(forTimeInterval: 0.5)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let row = app.cells[Self.botRow]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let rowText = row.buttons.firstMatch
        XCTAssertTrue(waitUntil(timeout: 4) { rowText.label.contains("Working") }, "no step yet: Working… (\(rowText.label))")
        try event(account, "tool.start", ["name": "read_file", "tool_id": "tn1", "args": ["path": "/Users/x/app/package.json"]])
        XCTAssertTrue(waitUntil(timeout: 4) { rowText.label.contains("Reading package.json") }, "the step: \(rowText.label)")
        shot("bot-row-step\(look)")
        // A finished step stays named through the thinking after it; the next one takes over.
        try event(account, "tool.complete", ["name": "read_file", "tool_id": "tn1", "summary": "Read 40 lines"])
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertTrue(rowText.label.contains("Reading package.json"), "kept after it ends: \(rowText.label)")
        try event(account, "tool.start", ["name": "terminal", "tool_id": "tn2", "args": ["command": "cd /Users/x/app && npm test"]])
        XCTAssertTrue(waitUntil(timeout: 4) { rowText.label.contains("Running npm test") }, "the next step: \(rowText.label)")
        shot("bot-row-step-next\(look)")
        // (A side chat's Sessions row: SessionsTests+ToolNow.swift. A bot's own chat is not on that list.)

        // The reply writes: back to Working…; the turn ends: the preview.
        try event(account, "message.delta", ["text": "All tests pass."])
        XCTAssertTrue(waitUntil(timeout: 4) { !rowText.label.contains("Running npm test") && rowText.label.contains("Working") },
                      "writing: Working… (\(rowText.label))")
        try event(account, "message.complete", ["text": "All tests pass.", "status": "complete"])
        XCTAssertTrue(waitUntil(timeout: 6) { !rowText.label.contains("Working") }, "the turn ended: \(rowText.label)")
    }

    // MARK: (18) A chip coming or going never moves what you are reading

    @MainActor func test18_ChipsDoNotMoveRowsWhileScrolledUp() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        try account.control("/__fixture/history", ["profile": "default", "count": 200, "non_dense": true])
        let app = launch(account, args: ["-HQDebugMotionProbe", "YES"])
        let table = openChat(app)
        let newest = labelled(app, containing: "Synthetic history row 199.")
        XCTAssertTrue(newest.waitForExistence(timeout: 10))
        table.swipeDown(velocity: .slow)
        table.swipeDown(velocity: .slow)
        Thread.sleep(forTimeInterval: 1.0)
        // A row in the middle of the screen.
        let rows = table.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Synthetic history row'"))
        let probe = (0..<rows.count).map { rows.element(boundBy: $0) }.first { $0.frame.midY > 250 && $0.frame.midY < 650 }
        guard let probe else { shot("no-row-mid-screen"); XCTFail("no row mid-screen (\(rows.count) rows)"); return }
        // Read by its label from here on: an element bound by index is looked up again on every read, and older rows
        // paging in shift the indices (the "before" frame came from another row).
        let label = probe.label
        let before = labelled(app, containing: label).frame.minY
        try event(account, "subagent.start", ["goal": "Index the docs", "task_count": 1, "task_index": 0, "subagent_id": "sa_jump", "status": "running"])
        let chip = element(app, "chat.shelf.subagents")
        XCTAssertTrue(chip.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.6)
        let held = labelled(app, containing: label)
        XCTAssertEqual(held.frame.minY, before, accuracy: 0.5, "the row on screen stays put when a chip appears")
        // Every frame, not just the end: no row on screen moved at all.
        var m = motion(app)
        XCTAssertEqual(m["mode"] as? String, "still", "\(m)")
        XCTAssertGreaterThan(number(m, "frames"), 20, "sampled through the chip's arrival: \(m)")
        XCTAssertLessThanOrEqual(number(m, "still"), 0.5, "no row moved in any frame while a chip came: \(m)")
        let jump = element(app, "chat.jump")
        XCTAssertTrue(jump.waitForExistence(timeout: 3) && jump.isHittable, "the jump button stays tappable beside the chip")
        shot("chip-while-scrolled-up")
        try event(account, "subagent.complete", ["goal": "Index the docs", "task_count": 1, "task_index": 0, "subagent_id": "sa_jump", "status": "completed", "summary": "done"])
        XCTAssertTrue(waitUntil(timeout: 3) { !chip.exists || !chip.isHittable })
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(held.frame.minY, before, accuracy: 0.5, "…and when it goes")
        m = motion(app)
        XCTAssertLessThanOrEqual(number(m, "still"), 0.5, "…in any frame of its leaving: \(m)")
        jump.tap()
        XCTAssertTrue(waitUntil(timeout: 4) { newest.exists && newest.frame.maxY < app.frame.maxY - 80 }, "the jump brings the newest row back")
    }

    /// At the newest end a chip's arrival and leaving carry the rows with the shelf: in every frame the newest row stays
    /// the content gap above the dock's top, give or take the shelf's own 6 pt gap opening or closing (a jump would be
    /// the chip's whole 50 pt in one frame).
    @MainActor func test18b_ChipsCarryTheNewestRowSmoothly() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        try account.control("/__fixture/history", ["profile": "default", "count": 40])
        let app = launch(account, args: ["-HQDebugMotionProbe", "YES"])
        openChat(app)
        XCTAssertTrue(labelled(app, containing: "Synthetic history row 39.").waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1.5)
        try event(account, "subagent.start", ["goal": "Index the docs", "task_count": 1, "task_index": 0, "subagent_id": "sa_end", "status": "running"])
        let chip = element(app, "chat.shelf.subagents")
        XCTAssertTrue(chip.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.8)
        var m = motion(app)
        XCTAssertLessThanOrEqual(number(m, "gap"), 6.5, "the newest row rides the shelf as the chip comes: \(m)")
        shot("chip-at-newest-end")
        try event(account, "subagent.complete", ["goal": "Index the docs", "task_count": 1, "task_index": 0, "subagent_id": "sa_end", "status": "completed", "summary": "done"])
        XCTAssertTrue(waitUntil(timeout: 3) { !chip.exists || !chip.isHittable })
        Thread.sleep(forTimeInterval: 0.8)
        m = motion(app)
        XCTAssertLessThanOrEqual(number(m, "gap"), 6.5, "…and as it goes: \(m)")
    }

    // MARK: (19, 20) Reasoning timing and the fallback notice

    @MainActor func test19_ThoughtForSecondsAndFallbackNotice() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        let events: [[String: Any]] = [
            ["type": "reasoning.delta", "payload": ["text": "Weigh the two options."]],
            ["after": 3.2, "type": "message.delta", "payload": ["text": "Option B is simpler."]],
        ]
        try account.control("/__fixture/plan", ["plans": [["events": events, "holdAfter": 0.2]]])
        let app = launchAndSend(account, "Which option")
        XCTAssertTrue(app.tables["chat.table"].buttons.matching(NSPredicate(format: "label BEGINSWITH 'Thinking'")).firstMatch.waitForExistence(timeout: 4),
                      "Thinking while live")
        let thought = app.tables["chat.table"].buttons.matching(NSPredicate(format: "label BEGINSWITH 'Thought for 3s'")).firstMatch
        XCTAssertTrue(thought.waitForExistence(timeout: 8), "Thought for 3s once the text starts")
        try event(account, "status.update", ["kind": "fallback", "text": "⚠ Model fallback: switched to fixture-2"])
        XCTAssertTrue(labelled(app, containing: "Model fallback: switched to fixture-2").waitForExistence(timeout: 3), "the notice row")
        shot("reasoning-and-fallback")
        // The bot's config turns reasoning off: reopened, no thought rows at all.
        try account.control("/__fixture/config", ["profile": "default", "display": ["show_reasoning": false]])
        app.terminate()
        let reopened = launch(account, args: ["-HQDebugOpenBot", "default"])
        XCTAssertTrue(labelled(reopened, containing: "Option B is simpler").waitForExistence(timeout: 10), "the chat reopens")
        XCTAssertTrue(waitUntil(timeout: 4) { !reopened.tables["chat.table"].buttons.matching(NSPredicate(format: "label BEGINSWITH 'Thought'")).firstMatch.exists },
                      "no thought rows when show_reasoning is off")
        try account.control("/__fixture/config", ["profile": "default", "display": [String: Any]()])
    }

    // MARK: (19b) The waiting row names the bot

    /// [waiting] Before the first word, the row is the typing dots and "<Bot> is thinking…", not the model.
    @MainActor func test19b_WaitingRowNamesTheBot() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        try account.control("/__fixture/plan", ["plans": [["events": [["after": 13, "type": "message.delta", "payload": ["text": "Here now."]]], "holdAfter": 0.2]]])
        let app = launchAndSend(account, "Are you there")
        let waiting = element(app, "chat.waiting")
        XCTAssertTrue(waiting.waitForExistence(timeout: 3), "the waiting row")
        XCTAssertTrue(waiting.label.contains("is thinking"), "names the bot: \(waiting.label)")
        XCTAssertFalse(waiting.label.contains("Waiting for"), "not the model")
        XCTAssertFalse(waiting.label.contains("·"), "no counter for the first 10 s: \(waiting.label)")
        shot("waiting-row")
        // From 10 s on, how long it has waited: "· 0:10".
        XCTAssertTrue(waitUntil(timeout: 12) { waiting.label.contains("· 0:1") }, "the counter after 10 s: \(waiting.label)")
        _ = waitUntil(timeout: 0.6) { false }          // the counter's fade-in
        shot("waiting-row-counter")
        XCTAssertTrue(labelled(app, containing: "Here now.").waitForExistence(timeout: 10), "the reply")
        XCTAssertTrue(waitUntil(timeout: 3) { !waiting.exists }, "the waiting row goes once the words start")
    }

    // MARK: (19d) The thinking row names the step

    /// [toolnow] While a step runs the row reads "Hermes is running npm test…", it keeps naming it while the bot thinks
    /// after it, and it goes once the reply writes.
    @MainActor func test19d_ThinkingRowNamesTheRunningStep() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        let args: [String: Any] = ["command": "cd /Users/fixture/app && npm test -- --watch=false"]
        let events: [[String: Any]] = [
            ["after": 0.5, "type": "tool.start", "payload": ["tool_id": "call_t1", "name": "terminal", "args": args]],
            ["after": 5, "type": "tool.complete", "payload": ["tool_id": "call_t1", "name": "terminal", "args": args,
                                                              "result": ["output": "42 passing", "exit_code": 0]]],
            ["after": 6, "type": "message.delta", "payload": ["text": "All 42 tests pass."]],
        ]
        try account.control("/__fixture/plan", ["plans": [["events": events, "holdAfter": 0.2]]])
        let app = launchAndSend(account, "Run the tests", args: ["-hq.chat.toolCallStyle", "line"])   // One Line, the default
        let waiting = element(app, "chat.waiting")
        XCTAssertTrue(waitUntil(timeout: 6) { waiting.exists && waiting.label.contains("is running npm test") }, "names the step: \(waiting.label)")
        let line = app.tables["chat.table"].buttons.matching(NSPredicate(format: "label BEGINSWITH 'Working'")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 2),
                      "the steps line doesn't repeat the step: \(app.tables["chat.table"].buttons.allElementsBoundByIndex.map(\.label))")
        usleep(600_000)   // the counter and the line settle before the picture
        shot("thinking-row-step")
        usleep(5_500_000)   // past tool.complete: the finished step stays named while it thinks
        XCTAssertTrue(waiting.exists && waiting.label.contains("is running npm test"), "between steps: \(waiting.label)")
        XCTAssertTrue(labelled(app, containing: "All 42 tests pass.").waitForExistence(timeout: 8), "the reply")
        XCTAssertTrue(waitUntil(timeout: 3) { !waiting.exists }, "gone once the reply writes")
    }

    // MARK: (19e) At the Bottom

    /// At the Bottom (owner, 2026-10-28; the turn of 06:45 that day): while the bot works nothing is drawn above its
    /// reply, the thinking row names each step in a few words with the timer whole beside it, and the reply's line comes
    /// once it is done.
    @MainActor func test19e_AtTheBottomNamesEachStepBelow() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        let search: [String: Any] = ["queries": [["use_case": "find unread email in gmail"]]]
        // As bots send it: inside the gateway's tool_call wrapper (2026-10-29: every Composio call on the owner's Mac was).
        let multi: [String: Any] = ["calls": [["name": "mcp__composio__COMPOSIO_MULTI_EXECUTE_TOOL",
                                               "arguments": ["tools": [["tool_slug": "GMAIL_FETCH_EMAILS", "arguments": ["max_results": 10]]]]]]]
        let term: [String: Any] = ["command": "cd /Users/fixture/app && date +%H:%M"]
        let events: [[String: Any]] = [
            ["after": 0.3, "type": "thinking.delta", "payload": ["text": "(⌐■_■) computing..."]],
            ["after": 2, "type": "tool.start", "payload": ["tool_id": "c1", "name": "mcp__composio__COMPOSIO_SEARCH_TOOLS", "args": search]],
            ["after": 1, "type": "tool.complete", "payload": ["tool_id": "c1", "name": "mcp__composio__COMPOSIO_SEARCH_TOOLS", "args": search, "result": ["ok": true]]],
            ["after": 3, "type": "tool.start", "payload": ["tool_id": "c2", "name": "tool_call", "args": multi]],
            ["after": 8, "type": "tool.complete", "payload": ["tool_id": "c2", "name": "tool_call", "args": multi, "result": ["ok": true]]],
            ["after": 1, "type": "tool.start", "payload": ["tool_id": "c3", "name": "terminal", "args": term]],
            ["after": 0.2, "type": "tool.complete", "payload": ["tool_id": "c3", "name": "terminal", "args": term, "result": ["output": "06:45", "exit_code": 0]]],
            ["after": 2, "type": "message.delta", "payload": ["text": "You have 3 unread emails."]],
        ]
        try account.control("/__fixture/plan", ["plans": [["events": events, "holdAfter": 0.2]]])
        let app = launchAndSend(account, "Check my email", args: ["-hq.chat.toolCallStyle", "bottom"])
        let waiting = element(app, "chat.waiting")
        let table = app.tables["chat.table"]
        let line = table.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Working' OR label BEGINSWITH 'Worked' OR label CONTAINS 'used 2 tools' OR label BEGINSWITH 'Using'")).firstMatch
        XCTAssertTrue(waitUntil(timeout: 8) { waiting.exists && waiting.label.contains("is looking for a tool to find unread") }, "first step: \(waiting.label)")
        XCTAssertTrue(waitUntil(timeout: 8) { waiting.label.contains("is fetching emails in Gmail") }, "the app's action, not Composio: \(waiting.label)")
        XCTAssertFalse(waiting.label.lowercased().contains("composio"), waiting.label)
        XCTAssertFalse(line.exists, "no line above the reply while it works: \(table.buttons.allElementsBoundByIndex.map(\.label))")
        // Nor in the pill under the bot's name (owner, 2026-10-28: the step showed twice).
        let pill = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Using' OR label == 'Thinking…' OR label == 'Working…'")).firstMatch
        XCTAssertFalse(pill.exists, "the pill doesn't say it as well: \(pill.exists ? pill.label : "")")
        XCTAssertTrue(waitUntil(timeout: 8) { waiting.label.contains("· 0:1") }, "the timer: \(waiting.label)")
        shot("at-the-bottom-step")
        // A tap opens every step of the turn (owner, 2026-10-29: "aren't clickable").
        waiting.tap()
        XCTAssertTrue(app.navigationBars["Steps"].waitForExistence(timeout: 3), "the Steps sheet opens")
        XCTAssertTrue(labelled(app, containing: "Fetching emails in Gmail").waitForExistence(timeout: 3), "the step names Gmail's action")
        shot("at-the-bottom-steps-sheet")
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(waitUntil(timeout: 3) { !app.navigationBars["Steps"].exists }, "the sheet closes")
        XCTAssertTrue(labelled(app, containing: "You have 3 unread emails.").waitForExistence(timeout: 12), "the reply")
        XCTAssertTrue(waitUntil(timeout: 3) { !waiting.exists }, "gone once the reply writes")
        XCTAssertTrue(line.waitForExistence(timeout: 5), "the reply's line once it is done")
        shot("at-the-bottom-done")
    }

    // MARK: (19c) A message to another bot

    /// [botdm] `message_agent` draws as a centred "To Hermes" line with that bot's face, not a tool step. [updates] The
    /// reply's work line folds with it: one line led by "To Hermes", opening on a card whose rows say what was sent.
    @MainActor func test19c_MessageToAnotherBotReadsAsAMessage() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        let args: [String: Any] = ["target": "hermes", "message": "The 5 pm cleanup skipped Personal and Work. Can you check the job?"]
        let events: [[String: Any]] = [
            ["type": "tool.start", "payload": ["tool_id": "call_dm1", "name": "message_agent", "args": args]],
            ["after": 0.3, "type": "tool.complete", "payload": ["tool_id": "call_dm1", "name": "message_agent", "args": args,
                                                                "result": ["status": "queued", "to": "@hermes"]]],
            ["after": 0.2, "type": "message.delta", "payload": ["text": "I asked Hermes to check the job."]],
        ]
        try account.control("/__fixture/plan", ["plans": [["events": events, "holdAfter": 0.2]]])
        let app = launchAndSend(account, "Tell Hermes")
        XCTAssertTrue(labelled(app, containing: "I asked Hermes").waitForExistence(timeout: 8), "the reply")
        // A line of its own reads "To Hermes"; folded with the work line, "2 updates: …, To Hermes" (it leads the line).
        let row = app.tables["chat.table"].buttons.matching(NSPredicate(format: "label == 'To Hermes' OR (label BEGINSWITH '2 updates:' AND label CONTAINS 'To Hermes')")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "the message line")
        shot("bot-dm-sent")
        row.tap()
        XCTAssertTrue(labelled(app, containing: "Can you check the job?").waitForExistence(timeout: 3), "opens on the message")
        shot("bot-dm-sent-open")
    }

    // MARK: (26) The generated image

    @MainActor func test26_GeneratedImageCard() throws {
        let account = try FixtureAccount.load()
        guard let media = ProcessInfo.processInfo.environment["HQN_ACTIVITY_MEDIA"] else { throw XCTSkip("needs HQN_ACTIVITY_MEDIA") }
        try reset(account)
        let path = media + "/sunrise.png"
        try account.control("/__fixture/rows", ["profile": "default", "rows": [
            ["role": "user", "content": "Draw a sunrise"],
            ["role": "assistant", "content": "", "tool_calls": [["id": "img_1", "type": "function", "function": ["name": "image_generate", "arguments": "{\"prompt\":\"sunrise\",\"aspect_ratio\":\"square\"}"]]]],
            ["role": "tool", "tool_call_id": "img_1", "tool_name": "image_generate", "content": "{\"success\": true, \"host_image\": \"\(path)\", \"pixel_size\": \"512x512\"}"],
            ["role": "assistant", "content": "Here is the sunrise."],
        ]])
        let app = launch(account)
        openChat(app)
        // Integration: the attachments stream draws the image_generate row (one implementation, its media tile); the
        // activity card is the fallback when that row has nothing to show.
        let image = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Image, sunrise.png'")).firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 6), "the image card shows")
        let frame = image.frame
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(image.frame.height, frame.height, accuracy: 0.5, "loading the picture never changes the row's height")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH \"Couldn’t load sunrise.png\"")).firstMatch.exists,
                       "a good path draws the picture")
        shot("generated-image")
    }

    /// A good path that won't load collapses to the "Open image: …" link row (44 pt); tapping it tries again.
    @MainActor func test26b_ImageThatWontLoadBecomesALink() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        try account.control("/__fixture/rows", ["profile": "default", "rows": [
            ["role": "user", "content": "Draw a sunset"],
            ["role": "assistant", "content": "", "tool_calls": [["id": "img_2", "type": "function", "function": ["name": "image_generate", "arguments": "{\"prompt\":\"sunset\",\"aspect_ratio\":\"square\"}"]]]],
            ["role": "tool", "tool_call_id": "img_2", "tool_name": "image_generate", "content": "{\"success\": true, \"host_image\": \"/fixture/missing/sunset.png\", \"pixel_size\": \"1024x1024\"}"],
            ["role": "assistant", "content": "Here is the sunset."],
        ]])
        let app = launch(account)
        openChat(app)
        // Integration: the attachments stream's row (see test26): "Couldn’t load <name>. Tap to open.", a tap tries
        // the file preview, which says the file is missing.
        let link = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Couldn’t load sunset.png. Tap to open.")).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 20), "the frame collapses to the link row")
        XCTAssertGreaterThanOrEqual(link.frame.height, 44, "a 44 pt target")
        shot("generated-image-link")
        link.tap()
        let missing = app.alerts["Couldn’t Open File"]
        XCTAssertTrue(missing.waitForExistence(timeout: 10), "a missing file says so")
        missing.buttons["OK"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { link.exists && link.isHittable }, "the link stays for another try")
    }

    // MARK: (28) Tool Calls settings

    @MainActor func test28_ToolCallsScreen() throws {
        let account = try FixtureAccount.load()
        let app = launch(account)
        openChat(app)
        app.buttons["chat.more"].tap()
        app.buttons["Tool Calls"].tap()
        XCTAssertTrue(app.navigationBars["Tool Calls"].waitForExistence(timeout: 3))
        // Four options with a line each (UX study #111) push the footer under a medium sheet's edge: pull it up to large.
        let footer = labelled(app, containing: "Each tool call shows as a step")
        // A swipe on the bar doesn't always lift the sheet: scrolling the list does, or brings the footer up. A few tries,
        // as one swipe can land while the sheet is still settling.
        for attempt in 0..<4 where !footer.waitForExistence(timeout: 1) {
            if attempt == 0 { app.navigationBars["Tool Calls"].swipeUp() } else { labelled(app, containing: "Tool Call Style").swipeUp() }
        }
        XCTAssertTrue(footer.waitForExistence(timeout: 3), "the style footer")
        shot("tool-calls-screen")
        app.buttons["In Header"].tap()
        XCTAssertTrue(waitUntil(timeout: 2) { !self.labelled(app, containing: "Hide shows each step").exists }, "After Reply hides under In Header")
        shot("tool-calls-in-header")
        app.buttons["Rows"].tap()
        app.buttons["sheet.close"].firstMatch.tap()
    }

    /// Switching the style rebuilds the open chat without moving the rows being read (§10.1, §16 check 28).
    @MainActor func test28b_StyleSwitchKeepsTheRowsInPlace() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        try account.control("/__fixture/history", ["profile": "default", "count": 60])
        var calls: [[String: Any]] = []
        var results: [[String: Any]] = []
        for i in 0..<6 {
            calls.append(["id": "sw_\(i)", "type": "function", "function": ["name": "terminal", "arguments": "{\"command\":\"npm run step:\(i)\"}"]])
            results.append(["role": "tool", "tool_call_id": "sw_\(i)", "tool_name": "terminal", "content": "{\"output\": \"ok\", \"exit_code\": 0}"])
        }
        try account.control("/__fixture/rows", ["profile": "default", "rows":
            [["role": "user", "content": "Run the six steps"], ["role": "assistant", "content": "", "tool_calls": calls]] + results
            + [["role": "assistant", "content": "All six steps ran."], ["role": "user", "content": "Thanks"], ["role": "assistant", "content": "Any time."]]])
        let app = launch(account, pinsStyle: false)
        let table = openChat(app)
        // Rows to start, set the way the switch below sets it (no launch argument pinning it).
        app.buttons["chat.more"].tap()
        app.buttons["Tool Calls"].tap()
        XCTAssertTrue(app.navigationBars["Tool Calls"].waitForExistence(timeout: 3))
        app.buttons["Rows"].tap()
        app.buttons["sheet.close"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(labelled(app, containing: "Any time.").waitForExistence(timeout: 10))
        table.swipeDown(velocity: .slow)
        Thread.sleep(forTimeInterval: 1.0)
        let rows = table.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Synthetic history row'"))
        let probe = (0..<rows.count).map { rows.element(boundBy: $0) }.first { $0.frame.midY > 150 && $0.frame.midY < 500 }
        guard let probe else { shot("style-switch-no-row"); XCTFail("no row on screen"); return }
        // By its label from here on (an index-bound element is looked up again on every read).
        let label = probe.label
        let before = labelled(app, containing: label).frame.minY
        app.buttons["chat.more"].tap()
        app.buttons["Tool Calls"].tap()
        XCTAssertTrue(app.navigationBars["Tool Calls"].waitForExistence(timeout: 3))
        app.buttons["Bubbles"].tap()
        app.buttons["sheet.close"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(element(app, "chat.tool-bubble").exists || labelled(app, containing: "npm run step").exists, "the steps redrew as a bubble")
        XCTAssertEqual(labelled(app, containing: label).frame.minY, before, accuracy: 0.5, "the row being read stays put")
        shot("style-switch-bubbles")
        app.buttons["chat.more"].tap()
        app.buttons["Tool Calls"].tap()
        app.buttons["Rows"].tap()
        app.buttons["sheet.close"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(labelled(app, containing: label).frame.minY, before, accuracy: 0.5, "…and back")
    }

    // MARK: Large text: the shelf wraps, Tool Calls becomes checkmark rows (§7.5, §13)

    @MainActor func test29_LargeTextShelfAndToolCalls() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        try account.control("/__fixture/control", ["profile": "default", "control": ["goal": Self.goal], "emit": false])
        let app = launch(account, args: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        openChat(app)
        try event(account, "subagent.start", ["goal": "Read the changelog since 2.3 and list the user-facing changes", "task_count": 1,
                                              "task_index": 0, "subagent_id": "sa_ax", "status": "running"])
        let chip = element(app, "chat.shelf.subagents")
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "chat.shelf.goal").waitForExistence(timeout: 5))
        shot("large-text-shelf")
        chip.tap()
        Thread.sleep(forTimeInterval: 0.8)
        shot("large-text-subagents-card")
        try event(account, "subagent.complete", ["goal": "x", "task_count": 1, "task_index": 0, "subagent_id": "sa_ax", "status": "completed"])
        app.buttons["chat.more"].tap()
        // At the largest text size the DEBUG item sits under the menu's fold: scroll the menu to it.
        let toolCalls = app.buttons["Tool Calls"]
        for _ in 0..<4 where !toolCalls.waitForExistence(timeout: 1) { app.buttons["chat.more.share"].firstMatch.swipeUp() }
        toolCalls.tap()
        XCTAssertTrue(app.navigationBars["Tool Calls"].waitForExistence(timeout: 3))
        // Tool Call Style is checkmark rows at every size now, each with a line saying what it does (UX study #111): at
        // this size Bubbles, the third, sits under the medium sheet's edge. Pull the sheet up, then scroll the form to it.
        let first = element(app, "settings.tool-call-style.Rows")
        XCTAssertTrue(first.waitForExistence(timeout: 3), "the options are checkmark rows")
        let bubbles = element(app, "settings.tool-call-style.Bubbles")
        if !bubbles.waitForExistence(timeout: 1) { app.navigationBars["Tool Calls"].swipeUp() }
        // The sheet's own form (the transcript's collection view sits behind it).
        let form = app.collectionViews.containing(.any, identifier: "settings.tool-call-style.Rows").firstMatch
        for _ in 0..<4 where !(bubbles.waitForExistence(timeout: 1) && bubbles.isHittable) { form.swipeUp(velocity: .slow) }
        XCTAssertTrue(bubbles.exists && bubbles.isHittable, "each option is its own row (Bubbles)")
        XCTAssertEqual(bubbles.label, "Bubbles", "the row is named by its option alone")
        shot("large-text-tool-calls")
        app.buttons["sheet.close"].firstMatch.tap()
    }

    // MARK: (10) Strict params

    @MainActor func test99_NoUnknownParams() throws {
        let account = try FixtureAccount.load()
        let violations = (try activityLog(account)["violations"] as? [Any]) ?? ["unreadable"]
        XCTAssertTrue(violations.isEmpty, "no call carried an unknown param: \(violations)")
    }
}
