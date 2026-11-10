// End-to-end checks of the m9 transcript stream (docs/spec/3x-transcript.md) against its stand-in gateway
// (scripts/fixtures/transcript-gateway.py). Run with scripts/e2e-transcript.sh <udid> <port>: it starts the fixture,
// passes its credentials as TEST_RUNNER_HQN_UI_CREDENTIALS and a screenshot folder as TEST_RUNNER_HQN_SHOTS_DIR with
// the appearance as TEST_RUNNER_HQN_SHOTS_SUFFIX. Without the credentials every test skips.

import XCTest

final class TranscriptEndToEndTests: XCTestCase {
    static let botRow = "bot-row-default"
    nonisolated(unsafe) static var signedInThisRun = false

    override func setUpWithError() throws { continueAfterFailure = false }

    // MARK: Helpers

    func preset(_ account: FixtureAccount, _ name: String) throws {
        try account.control("/__fixture/preset", ["profile": "default", "name": name])
    }

    @MainActor func launch(_ account: FixtureAccount, args: [String] = [], covered: Bool = false) -> XCUIApplication {
        if !Self.signedInThisRun {
            let first = XCUIApplication()
            first.launchArguments = ["-HQDebugResetAccounts", "YES"]
            first.launch()
            signIn(first, account)
            XCTAssertTrue(first.cells[Self.botRow].waitForExistence(timeout: 25), "signed in to the fixture")
            first.terminate()
            Self.signedInThisRun = true
        }
        let app = XCUIApplication()
        // Written for Rows and every timestamp (One Line and Fewer Timestamps became the defaults later). The "Know When
        // a Bot Replies?" offer is answered already: on a fresh install it came up over a reply's composer (S3).
        let look = args.contains("-hq.chat.toolCallStyle") ? [] : ["-hq.chat.toolCallStyle", "rows"]
        // `-HQDebugDesktopLook` is saved, not just read for one launch: a test that asks for no look gets the iOS look,
        // so one run in the Desktop Look doesn't carry over into every test after it.
        let skin = args.contains("-HQDebugDesktopLook") || args.contains("-hqn.theme.desktopLook") ? [] : ["-HQDebugDesktopLook", "NO"]
        app.launchArguments = ["-hq.voice.tip.talk", "YES", "-HQDebugOpenBot", "default", "-dispatch.notifications.asked", "YES"]
            + look + skin + ["-hq.chat.fewerTimestamps", "NO"] + args
        app.launch()
        let table = app.tables["chat.table"]
        // `covered`: the launch hook puts a sheet over the chat at once (the Safari view), so the chat is not looked for.
        if covered { return app }
        if !table.waitForExistence(timeout: 15) {
            let row = app.cells[Self.botRow]
            XCTAssertTrue(row.waitForExistence(timeout: 10), "the Bots list shows")
            row.tap()
        }
        XCTAssertTrue(table.waitForExistence(timeout: 10), "the chat opens")
        return app
    }

    @MainActor func signIn(_ app: XCUIApplication, _ account: FixtureAccount) {
        let address = app.textFields["sign-in-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 20))
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

    /// Types into the composer and taps Send; taps once more only if the words are still in the box (a tap that landed
    /// while the button was still turning from Talk into Send does nothing).
    @MainActor func typeAndSend(_ app: XCUIApplication, _ text: String, tapAgain: Bool = true) {
        let field = app.textViews["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(text)
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
        if !tapAgain { return }
        if waitUntil(timeout: 3, { (field.value as? String) != text }) { return }
        if send.exists { send.tap() }
    }

    @MainActor func labelled(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["HQN_SHOTS_DIR"], !dir.isEmpty else { return }
        let suffix = env["HQN_SHOTS_SUFFIX"].map { "-\($0)" } ?? ""
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "transcript-\(name)\(suffix).png"))
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

    // MARK: T1 Cron deliveries fold to one line named by the job; a silent run says so (L302)

    @MainActor func testT1_CronDeliveries() throws {
        let account = try FixtureAccount.load()
        try preset(account, "cron")
        let app = launch(account)
        // A run is one line, its job and report, without its wrapper or its Markdown (owner, 2026-10-23).
        XCTAssertTrue(labelled(app, containing: "Morning brief: Three things today").waitForExistence(timeout: 10),
                      "the run is one line named by its job")
        XCTAssertTrue(labelled(app, containing: "Nightly check: All 12 services answered").exists, "the second wrapper form is unwrapped too")
        XCTAssertTrue(labelled(app, containing: "Disk watch: Nothing to report — this run was silent").exists, "a silent job is named")
        XCTAssertTrue(app.staticTexts["Nothing to report — this run was silent"].exists
                      || labelled(app, containing: "Nothing to report — this run was silent").exists, "a silent reply says so")
        for raw in ["[Cron delivery", "Cronjob Response", "[SILENT]", "job_id", "To stop or manage this job"] {
            XCTAssertFalse(labelled(app, containing: raw).exists, "no wrapper text on screen: \(raw)")
        }
        shot("cron")
    }

    // MARK: T2 Timeline notes in words (L303)

    @MainActor func testT2_TimelineNotes() throws {
        let account = try FixtureAccount.load()
        try preset(account, "timeline")
        let app = launch(account)
        XCTAssertTrue(labelled(app, containing: "Model changed to").waitForExistence(timeout: 10), "the model switch reads in words")
        XCTAssertTrue(labelled(app, containing: "Background task finished").exists, "the process note reads in words")
        for raw in ["[System:", "[IMPORTANT", "From this point"] {
            XCTAssertFalse(labelled(app, containing: raw).exists, "no machine text on screen: \(raw)")
        }
        shot("timeline")
    }

    // MARK: T3 A reply is read without its Markdown; a flag in inline code is drawn whole (L300, L307)

    @MainActor func testT3_SpokenTextAndFlags() throws {
        let account = try FixtureAccount.load()
        try preset(account, "text")
        let app = launch(account)
        let reply = labelled(app, containing: "Install it for one user with --user")
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "VoiceOver reads the words")
        let label = reply.label
        XCTAssertTrue(label.hasPrefix("Hermes said: "), "who said it comes first: \(label.prefix(40))")
        for mark in ["**", "`", "##", "]("] { XCTAssertFalse(label.contains(mark), "no Markdown in what is read: \(mark)") }
        XCTAssertTrue(label.contains("The install guide has the rest"), "a link is read as its words")
        shot("text")
    }

    // MARK: T4 Tool rows in plain words (L344)

    @MainActor func testT4_ToolWording() throws {
        let account = try FixtureAccount.load()
        try preset(account, "tools")
        let app = launch(account)
        XCTAssertTrue(labelled(app, containing: "Checked how to use web search").waitForExistence(timeout: 10), "tool_describe reads as what it looked up")
        // A finished run is counted ("Ran 1 command", as the web does); the script's name shows while it runs
        // (unit: TranscriptWiringTests.toolRowsInPlainWords).
        XCTAssertTrue(labelled(app, containing: "Ran 1 command").exists, "the finished script is one command")
        XCTAssertFalse(labelled(app, containing: "export CI").exists, "not by its setup lines")
        XCTAssertTrue(labelled(app, containing: "12 KB output").waitForExistence(timeout: 8), "a big result says its size in words")
        shot("tools")
    }

    // MARK: T5 A page on the gateway computer says why it can't open; a web page opens inside the app (L311, L982)

    @MainActor func testT5_LoopbackLinkSaysWhy() throws {
        let account = try FixtureAccount.load()
        try preset(account, "text")
        let app = launch(account, args: ["-HQNDebugOpenLink", "http://127.0.0.1:8080/status"])
        // The app's own notice above the composer, not a system alert: nothing to dismiss, the chat stays usable.
        let notice = labelled(app, containing: "This page runs on the computer running Hermes, so it can’t open on your iPhone.")
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "the loopback page is refused in words")
        XCTAssertEqual(app.alerts.count, 0, "no system alert")
        shot("link-loopback")
        XCTAssertTrue(app.tables["chat.table"].exists, "still in the chat")
    }

    @MainActor func testT6_WebLinkOpensInsideTheApp() throws {
        let account = try FixtureAccount.load()
        try preset(account, "text")
        // A name that can never resolve (RFC 6761): the Safari view goes up without the internet.
        let app = launch(account, args: ["-HQNDebugOpenLink", "https://hermes-hq.invalid/install"], covered: true)
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 15), "the in-app Safari view is up (its Done button)")
        XCTAssertEqual(app.state, .runningForeground, "the app stayed in front: Safari did not take over")
        shot("link-safari")
        // The Safari view is drawn by another process: its Done button is pressed where it is on the screen.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.095, dy: 0.1)).tap()
        if !app.tables["chat.table"].waitForExistence(timeout: 6), done.exists { done.tap() }
        let back = app.tables["chat.table"].waitForExistence(timeout: 10)
        shot("link-after-done")
        XCTAssertTrue(back, "Done returns to the chat")
    }

    // MARK: T7 One of the app's links it has no screen for says so (L981)

    @MainActor func testT7_UnsupportedDeepLink() throws {
        let account = try FixtureAccount.load()
        try preset(account, "text")
        let app = launch(account, args: ["-HQNDebugOpenLink", "hermeshq-native://blueprint/morning-brief?time=7"])
        let notice = labelled(app, containing: "That isn’t available on iPhone yet.")
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "an unsupported link gives a notice")
        XCTAssertEqual(app.alerts.count, 0, "no system alert")
        shot("deeplink-unsupported")
    }

    // MARK: T8 "Waking up…" while a cold bot starts, after the grace; gone when it answers (L360, L361)

    @MainActor func testT8_WakingUp() throws {
        let account = try FixtureAccount.load()
        try preset(account, "text")
        try account.control("/__fixture/slow", ["method": "session.resume", "seconds": 7, "times": 1])
        let app = launch(account)
        let pill = labelled(app, containing: "Waking up…")
        XCTAssertTrue(pill.waitForExistence(timeout: 6), "the status reads Waking up… while session.resume is pending")
        shot("waking")
        XCTAssertTrue(waitUntil(timeout: 12) { !pill.exists }, "and clears when the bot answers")
        XCTAssertTrue(labelled(app, containing: "Install it for one user").exists, "the transcript stayed on screen")
    }

    // MARK: T9 A send the gateway refuses: "Couldn’t Send" at the composer, the words back in the box (L354)

    @MainActor func testT9_CouldntSendCard() throws {
        let account = try FixtureAccount.load()
        try preset(account, "text")
        let app = launch(account)
        try account.control("/__fixture/plan", ["plans": [["reject": "the gateway refused this message", "code": 4000]]])
        let field = app.textViews["composer.text"]
        typeAndSend(app, "Please keep these words", tapAgain: false)
        let card = app.descendants(matching: .any)["chat.sendFailure"]
        if !card.waitForExistence(timeout: 10) { shot("send-failed-missing") }
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the Couldn’t Send card is at the composer")
        XCTAssertTrue(app.staticTexts["Couldn’t Send"].exists)
        XCTAssertTrue(labelled(app, containing: "Your message is still in the box below. The gateway refused this message.").exists,
                      "it says where the words are and why")
        XCTAssertEqual(field.value as? String, "Please keep these words", "the words are back in the box")
        XCTAssertFalse(labelled(app, containing: "You said: Please keep these words").exists, "no bubble for a message that never left")
        shot("couldnt-send")
        // Try Again sends what is in the box; this time the gateway takes it.
        try account.control("/__fixture/plan", ["plans": [["replyText": "Got it this time."]]])
        app.buttons["chat.sendFailure.action"].tap()
        XCTAssertTrue(labelled(app, containing: "You said: Please keep these words").waitForExistence(timeout: 10), "Try Again sent it")
        XCTAssertTrue(waitUntil(timeout: 5) { !card.exists }, "the card goes when the send goes")
        XCTAssertTrue(labelled(app, containing: "Got it this time.").waitForExistence(timeout: 10))
    }

    // MARK: T10 The reply's time is under it (L363)

    @MainActor func testT10_TurnDuration() throws {
        let account = try FixtureAccount.load()
        try preset(account, "text")
        let app = launch(account)
        try account.control("/__fixture/plan", ["plans": [["replyText": "Two seconds of thought.", "replyDelay": 2.2]]])
        typeAndSend(app, "Think for a moment")
        if !labelled(app, containing: "Two seconds of thought.").waitForExistence(timeout: 15) { shot("duration-noreply") }
        XCTAssertTrue(labelled(app, containing: "Two seconds of thought.").exists)
        let duration = app.descendants(matching: .any)["chat.turn-duration"]
        if !duration.waitForExistence(timeout: 8) { shot("duration-missing") }
        XCTAssertTrue(duration.exists, "the finished reply shows how long it took")
        let words = duration.label
        XCTAssertTrue(words.range(of: #"^\d+ ?s$|second"#, options: .regularExpression) != nil, "a short time in seconds: \(words)")
        shot("turn-duration")
    }

    // MARK: T11 A model that can't start: the card at the composer offers the model list (L353)

    @MainActor func testT11_ModelCantStartCard() throws {
        let account = try FixtureAccount.load()
        try preset(account, "text")
        let app = launch(account)
        XCTAssertTrue(labelled(app, containing: "Install it for one user").waitForExistence(timeout: 10))
        // The link has to be up for the event to arrive: the fixture sends to whoever is connected.
        let card = app.descendants(matching: .any)["chat.problem"]
        for _ in 0..<4 where !card.exists {
            try account.control("/__fixture/event", ["profile": "default", "type": "error",
                                                     "payload": ["message": "agent init failed: could not start the assistant"]])
            _ = card.waitForExistence(timeout: 4)
        }
        XCTAssertTrue(card.exists, "the problem card is at the composer")
        XCTAssertTrue(app.staticTexts["This chat’s model couldn’t start"].exists, "in plain words")
        XCTAssertFalse(labelled(app, containing: "agent init failed").exists, "not the raw error")
        let choose = app.buttons["chat.problem.action"]
        XCTAssertEqual(choose.label, "Choose a Model")
        shot("model-cant-start")
        choose.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { app.navigationBars.count > 0 && !choose.isHittable }, "the model list opens")
        shot("model-cant-start-list")
    }

    // MARK: T12 A table opens in its own sheet; Copy as Text (§3.4, L309)

    @MainActor func testT12_TableSheet() throws {
        let account = try FixtureAccount.load()
        try preset(account, "table")
        let app = launch(account)
        let expand = app.buttons["chat.table.expand"]
        if !expand.waitForExistence(timeout: 10) { shot("table-missing") }
        XCTAssertTrue(expand.waitForExistence(timeout: 10), "the table has its Expand button")
        XCTAssertEqual(expand.label, "Expand table")
        shot("table")
        expand.tap()
        XCTAssertTrue(app.navigationBars["Table"].waitForExistence(timeout: 8), "the sheet is titled Table")
        shot("table-sheet-open")
        let copy = app.buttons["table.sheet.copy"]
        XCTAssertTrue(copy.exists)
        XCTAssertEqual(copy.label, "Copy as Text")
        shot("table-sheet")
        copy.tap()
        XCTAssertTrue(waitUntil(timeout: 4) { copy.label == "Copied" }, "the button says Copied: \(copy.label)")
        XCTAssertTrue(waitUntil(timeout: 6) { copy.label == "Copy as Text" }, "and goes back")
    }

    // MARK: T12b A wide table: the card's footer, and the Table page (owner 2026-10-29)

    @MainActor func testT12b_WideTable() throws {
        let account = try FixtureAccount.load()
        try preset(account, "widetable")
        let extra = ProcessInfo.processInfo.environment["HQN_TABLE_ARGS"].map { $0.split(separator: " ").map(String.init) } ?? []
        let app = launch(account, args: extra)
        let expand = app.buttons.matching(identifier: "chat.table.expand")
        XCTAssertTrue(expand.firstMatch.waitForExistence(timeout: 10), "the tables have their footers")
        // The first (wide) table on screen.
        let chat = app.tables["chat.table"]
        let first = expand.element(boundBy: 0)
        for _ in 0..<6 where !(first.frame.minY > 120 && first.frame.maxY < app.frame.height - 170) { chat.swipeDown() }
        XCTAssertEqual(expand.element(boundBy: 0).label, "Expand table")
        XCTAssertEqual(expand.element(boundBy: 0).value as? String, "7 rows, 4 columns")
        shot("widetable-card")
        let card = expand.element(boundBy: 0)
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -3)).press(forDuration: 0.05, thenDragTo:
            card.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: -3)))
        shot("widetable-card-scrolled")
        // A press where the footer is drawn: the bubble's words element stands over it for the accessibility check
        // (a real touch reaches it: aTouchOnATableFooterReachesItWithMoreBelow).
        XCTAssertGreaterThan(card.frame.minY, 120, "the footer is still on screen")
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Rep by rep"].waitForExistence(timeout: 8), "titled by the words above the table")
        shot("widetable-page")
        let header = app.descendants(matching: .any).matching(identifier: "table.sheet.contents").firstMatch
        XCTAssertTrue(header.exists)
        // Sort by the first "Reply rate": ascending, then descending.
        let rate = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Reply rate")).element(boundBy: 0)
        rate.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { (rate.value as? String) == "Sorted ascending" }, "\(String(describing: rate.value))")
        rate.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { (rate.value as? String) == "Sorted descending" })
        shot("widetable-page-sorted")
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Strong at follow-up, Morgan Lee")).firstMatch.tap()
        shot("widetable-page-marked")
        // Names and numbers: it scrolls sideways with the names pinned, until Fit to Screen is picked.
        app.descendants(matching: .any).matching(identifier: "table.sheet.contents").firstMatch.swipeLeft()
        shot("widetable-page-frozen")
        app.buttons["table.sheet.more"].tap()
        let fit = app.buttons["Fit to Screen"]
        if fit.waitForExistence(timeout: 3) {
            fit.tap()
            shot("widetable-page-fitted")
        } else {
            shot("widetable-page-menu")
            app.tap()
        }
        app.buttons["table.sheet.share"].tap()
        shot("widetable-page-share")
        XCTAssertTrue(app.buttons["Copy as CSV"].waitForExistence(timeout: 3))
        app.buttons["Copy as CSV"].tap()
        XCTAssertTrue(waitUntil(timeout: 3) { app.buttons["table.sheet.copy"].label == "Copied" })
        app.buttons["sheet.close"].tap()
        // The long table: search it.
        XCTAssertTrue(expand.element(boundBy: 1).waitForExistence(timeout: 6))
        let long = expand.element(boundBy: 1)
        for _ in 0..<6 where long.frame.maxY > app.frame.height - 170 { chat.swipeUp() }
        shot("widetable-card-long")
        long.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Pipeline by source"].waitForExistence(timeout: 8))
        shot("widetable-page-long")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 4), "12 rows can be searched")
        // The field rides away as the rows scroll down and comes back at the top (owner 2026-11-03).
        let contents = app.descendants(matching: .any).matching(identifier: "table.sheet.contents").firstMatch
        contents.swipeUp()
        shot("widetable-page-long-scrolled")
        contents.swipeDown(); contents.swipeDown()
        XCTAssertTrue(waitUntil(timeout: 3) { search.isHittable }, "the field is back at the top")
        search.tap()
        search.typeText("re")
        shot("widetable-page-search")
        XCTAssertTrue(labelled(app, containing: "of 12 rows").exists || app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "of 12 rows")).count > 0)
    }

    // MARK: T13 A web address on its own line gets a chip with the page's title (L313)

    @MainActor func testT13_LinkChip() throws {
        let account = try FixtureAccount.load()
        try preset(account, "links")
        let stub = "https://docs.hermes-hq.invalid/guide=>The Hermes Guide"
        let app = launch(account, args: ["-HQNLinkPreviewStub", stub])
        let chip = app.descendants(matching: .any)["chat.link-chip"]
        if !chip.waitForExistence(timeout: 10) { shot("chip-missing") }
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "the chip is under the address")
        _ = waitUntil(timeout: 8) { chip.label.contains("The Hermes Guide") }; shot("link-chip-nostub")
        XCTAssertTrue(chip.label.contains("The Hermes Guide"), "it shows the page's title: \(chip.label)")
        shot("link-chip")
        chip.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 15), "the chip opens the page inside the app")
    }

    // MARK: T14 A bot that never comes up: "Couldn’t reopen this chat", and Try Again (L361, §6.5)

    @MainActor func testT14_CouldntReopen() throws {
        let account = try FixtureAccount.load()
        try preset(account, "text")
        try account.control("/__fixture/slow", ["method": "session.resume", "seconds": 20, "times": 2])
        let app = launch(account, args: ["-HQNResumeTimeout", "3"])
        XCTAssertTrue(labelled(app, containing: "Waking up…").waitForExistence(timeout: 6), "first it reads Waking up…")
        let card = app.descendants(matching: .any)["chat.problem"]
        XCTAssertTrue(card.waitForExistence(timeout: 20), "after both tries: the card")
        XCTAssertTrue(app.staticTexts["Couldn’t reopen this chat"].exists)
        XCTAssertTrue(labelled(app, containing: "This chat is still starting on the computer running Hermes.").exists)
        XCTAssertFalse(labelled(app, containing: "Waking up…").exists, "the waiting words stop when the card is up")
        shot("couldnt-reopen")
        app.buttons["chat.problem.action"].tap()
        XCTAssertTrue(waitUntil(timeout: 15) { !card.exists }, "Try Again reopens the chat and the card goes")
        XCTAssertTrue(labelled(app, containing: "Install it for one user").exists, "the transcript stayed on screen")
    }

    // MARK: T15 An older page that fails says so, and Try Again loads it (§4.2, L331)

    @MainActor func testT15_EarlierMessages() throws {
        let account = try FixtureAccount.load()
        try preset(account, "long")
        try account.control("/__fixture/older", ["fail": -1])
        defer { _ = try? account.control("/__fixture/older", ["fail": 0, "seconds": 0]) }
        let app = launch(account)
        XCTAssertTrue(labelled(app, containing: "Line 200 of a long chat.").waitForExistence(timeout: 10))
        let table = app.tables["chat.table"]
        let failed = labelled(app, containing: "Couldn’t load earlier messages")
        for _ in 0..<30 where !failed.exists { table.swipeDown(velocity: .fast) }
        XCTAssertTrue(failed.waitForExistence(timeout: 5), "at the top of what loaded: the failed read says so")
        XCTAssertFalse(labelled(app, containing: "Line 1 of a long chat.").exists)
        shot("earlier-failed")
        try account.control("/__fixture/older", ["fail": 0, "seconds": 3])
        app.buttons["chat.earlier.action"].tap()
        XCTAssertTrue(labelled(app, containing: "Loading earlier messages…").waitForExistence(timeout: 3), "it says it is loading")
        shot("earlier-loading")
        XCTAssertTrue(waitUntil(timeout: 15) { !labelled(app, containing: "Loading earlier messages…").exists }, "then the pill goes")
        try account.control("/__fixture/older", ["fail": 0, "seconds": 0])
        let first = labelled(app, containing: "Line 1 of a long chat.")
        for _ in 0..<40 where !first.exists { table.swipeDown(velocity: .fast) }
        XCTAssertTrue(first.exists, "the earlier messages are there")
        XCTAssertFalse(app.descendants(matching: .any)["chat.earlier.text"].exists, "nothing more to show at the very start")
    }

    // MARK: T16 A usage limit: the card's button is "Choose a Model" (L352, §6.1)

    @MainActor func testT16_UsageLimitCard() throws {
        let account = try FixtureAccount.load()
        try preset(account, "text")
        let app = launch(account)
        try account.control("/__fixture/plan", ["plans": [["events": [["type": "error", "payload": ["message": "HTTP 429: usage_limit reached for provider anthropic"]]]]]])
        typeAndSend(app, "Say something")
        let title = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'usage limit reached'")).firstMatch
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "usage limit reached")).firstMatch
        if !card.waitForExistence(timeout: 15) { shot("usage-limit-missing") }
        XCTAssertTrue(card.exists, "the failed turn reads in plain words")
        _ = title
        XCTAssertFalse(labelled(app, containing: "HTTP 429").exists, "the raw error stays behind Details")
        let choose = app.buttons["chat.error-retry"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        XCTAssertEqual(choose.label, "Choose a Model")
        shot("usage-limit")
        choose.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { app.navigationBars.count > 0 && !choose.isHittable }, "the model list opens")
    }

    // MARK: T17 A send waits while a scheduled job's run holds the chat ([owner-wait], build 300)

    @MainActor func testT17_WaitsForABackgroundTask() throws {
        let account = try FixtureAccount.load()
        try preset(account, "text")
        let app = launch(account)
        let owned = ["reject": "This chat is open in another Hermes window/terminal. Use it there, or start a new chat here.\n"
                     + "Details: session 20260101_090000_aa0001 opened by cli 0m ago.", "code": 4090] as [String: Any]
        try account.control("/__fixture/plan", ["plans": [owned, owned, owned, owned, ["replyText": "Sally and Jack: line is 3.5."]]])
        typeAndSend(app, "What the current line for sally and jack?", tapAgain: false)
        let card = app.descendants(matching: .any)["chat.ownerWait"]
        if !card.waitForExistence(timeout: 10) { shot("owner-wait-missing") }
        XCTAssertTrue(card.exists, "the waiting card is at the composer")
        XCTAssertTrue(app.staticTexts["Your message is waiting"].exists)
        XCTAssertTrue(labelled(app, containing: "scheduled job or a message from another bot").exists)
        XCTAssertEqual(app.buttons["chat.ownerWait.action"].label, "Cancel Message")
        XCTAssertFalse(app.descendants(matching: .any)["chat.sendFailure"].exists, "no Couldn’t Send card")
        shot("owner-wait")
        XCTAssertTrue(labelled(app, containing: "Sally and Jack: line is 3.5.").waitForExistence(timeout: 20), "it sent by itself")
        XCTAssertTrue(waitUntil(timeout: 5) { !card.exists }, "the card goes when the send goes")
        shot("owner-wait-sent")
    }

    // MARK: T18 Plain-words provider failures reuse the card's own Choose a Model button (n20 ec0a3896's words; no
    // separate Switch Provider button, docs/spec/3x-transcript.md §6.1)

    @MainActor func testT18_LowCreditCard() throws { try lowCreditCard("", args: []) }
    @MainActor func testT18b_LowCreditCardInTheDesktopLook() throws { try lowCreditCard("-desktop", args: ["-HQDebugDesktopLook", "YES"]) }
    @MainActor func testT18c_LowCreditCardAtExtraLargeText() throws {
        try lowCreditCard("-xl", args: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
    }

    @MainActor private func lowCreditCard(_ tag: String, args: [String]) throws {
        let account = try FixtureAccount.load()
        try preset(account, "text")
        let app = launch(account, args: args)
        try account.control("/__fixture/plan", ["plans": [["events": [["type": "error", "payload": ["message": "Anthropic: your credit balance is too low (402)."]]]]]])
        typeAndSend(app, "Say something")
        XCTAssertTrue(labelled(app, containing: "Low on credit").waitForExistence(timeout: 15), "low credit reads in plain words")
        XCTAssertFalse(labelled(app, containing: "credit balance is too low").exists, "the raw error stays behind Details")
        let choose = app.buttons["chat.error-retry"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        XCTAssertEqual(choose.label, "Choose a Model")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'switch provider'")).firstMatch.exists, "no Switch Provider wording")
        shot("provider-failure-billing\(tag)")
        choose.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { app.navigationBars.count > 0 && !choose.isHittable }, "the model list opens")
    }

    @MainActor func testT19_ModelGoneCard() throws {
        let account = try FixtureAccount.load()
        try preset(account, "text")
        let app = launch(account)
        try account.control("/__fixture/plan", ["plans": [["events": [["type": "error", "payload": ["message": "The model 'claude-9' does not exist (404)."]]]]]])
        typeAndSend(app, "Say something")
        XCTAssertTrue(labelled(app, containing: "This model is gone").waitForExistence(timeout: 15), "a retired model reads in plain words")
        XCTAssertTrue(labelled(app, containing: "Choose another model to continue this chat.").exists)
        let choose = app.buttons["chat.error-retry"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        XCTAssertEqual(choose.label, "Choose a Model")
        shot("provider-failure-model-gone")
    }

    // MARK: T20 "N files changed" card, inline diff preview, Review, and a file's own open (§12, n20 F10)

    @MainActor func testT20_FilesCard() throws {
        let account = try FixtureAccount.load()
        try preset(account, "diffs")
        let app = launch(account)

        let card = labelled(app, containing: "2 files changed")
        if !card.waitForExistence(timeout: 15) { shot("files-card-missing") }
        XCTAssertTrue(card.exists, "the settled reply carries the card")
        XCTAssertTrue(app.descendants(matching: .any)["chat.diff-preview"].waitForExistence(timeout: 5),
                     "an edit's own row (Rows) carries its first changed lines")
        shot("files-card")

        let fileRow = cardRow(app, "app.py,")
        XCTAssertTrue(fileRow.exists, "the card names the file by itself, not its full path")
        fileRow.tap()
        XCTAssertTrue(labelled(app, containing: "def handle(req):").waitForExistence(timeout: 10), "the file opened at its current text")
        shot("files-card-file-open")
        // The file opens on top of its folder in Files (as a bot's own file link): back to the folder, then close.
        app.navigationBars.buttons.firstMatch.tap()
        let close = app.buttons["sheet.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "back on the folder, under the file")
        close.tap()

        XCTAssertTrue(waitUntil(timeout: 5) { card.isHittable }, "back on the chat")
        card.tap()
        XCTAssertTrue(app.navigationBars["Changes"].waitForExistence(timeout: 8), "Review opens the chat's own Changes page")
        XCTAssertTrue(app.cells["workspace.change.src/app.py"].waitForExistence(timeout: 5), "and names the edited file")
        shot("files-card-review")
    }

    /// The card in the other looks: Desktop Look, extra-large text, and the default At the Bottom style (no
    /// per-step diff previews there, just the card under the reply).
    @MainActor func testT20c_FilesCardInTheDesktopLook() throws { try filesCardLook("-desktop", args: ["-HQDebugDesktopLook", "YES"]) }
    @MainActor func testT20d_FilesCardAtExtraLargeText() throws {
        try filesCardLook("-xl", args: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
    }
    @MainActor func testT20e_FilesCardAtTheBottom() throws { try filesCardLook("-bottom", args: ["-hq.chat.toolCallStyle", "bottom"]) }

    @MainActor private func filesCardLook(_ tag: String, args: [String]) throws {
        let account = try FixtureAccount.load()
        try preset(account, "diffs")
        let app = launch(account, args: args)
        let card = labelled(app, containing: "2 files changed")
        XCTAssertTrue(card.waitForExistence(timeout: 15), "the settled reply carries the card")
        XCTAssertTrue(cardRow(app, "app.py,").exists && cardRow(app, "README.md,").exists, "a row per file")
        shot("files-card\(tag)")
    }

    /// A file row on the files card itself (a step's diff preview reads "<path>, …" too).
    private func cardRow(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.cells["chat.changed-files"].descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    // MARK: T20b Seven files: five then "Show All 7 Files" (§12, n20 F10)

    @MainActor func testT20b_SevenFilesShowAll() throws {
        let account = try FixtureAccount.load()
        try preset(account, "diffs7")
        let app = launch(account)

        XCTAssertTrue(labelled(app, containing: "7 files changed").waitForExistence(timeout: 15), "the card names every edited file")
        let showAll = labelled(app, containing: "Show All 7 Files")
        XCTAssertTrue(showAll.waitForExistence(timeout: 5))
        XCTAssertFalse(cardRow(app, "config.yaml,").exists, "the sixth and seventh wait behind Show All")
        shot("files-card-seven")
        showAll.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { cardRow(app, "config.yaml,").exists }, "Show All reveals the rest")
        shot("files-card-seven-expanded")
    }

    // MARK: Stress: S1 a very long chat, S2 rapid streaming, S3 the link dropping mid-reply

    @MainActor func testS1_VeryLongChat() throws {
        let account = try FixtureAccount.load()
        try preset(account, "huge")
        let app = launch(account)
        XCTAssertTrue(labelled(app, containing: "Line 1500 of a huge chat.").waitForExistence(timeout: 15), "opens on the newest")
        let table = app.tables["chat.table"]
        for _ in 0..<12 { table.swipeDown(velocity: .fast) }
        for _ in 0..<12 { table.swipeUp(velocity: .fast) }
        XCTAssertTrue(app.textViews["composer.text"].exists, "still responsive after flinging both ways")
        XCTAssertTrue(labelled(app, containing: "huge chat.").exists, "rows are on screen")
    }

    @MainActor func testS2_RapidStreaming() throws {
        let account = try FixtureAccount.load()
        try preset(account, "text")
        let app = launch(account)
        var events: [[String: Any]] = []
        for i in 0..<400 { events.append(["type": "message.delta", "after": 0.004, "payload": ["text": "w\(i) "]]) }
        events.append(["type": "message.delta", "after": 0.004, "payload": ["text": "THE-END"]])
        try account.control("/__fixture/plan", ["plans": [["events": events]]])
        typeAndSend(app, "Stream a lot")
        XCTAssertTrue(labelled(app, containing: "THE-END").waitForExistence(timeout: 40), "every delta arrived, in order")
        XCTAssertTrue(labelled(app, containing: "w0 w1 w2").exists, "the start is intact")
        XCTAssertTrue(app.textViews["composer.text"].exists)
    }

    @MainActor func testS3_LinkDropsMidReply() throws {
        let account = try FixtureAccount.load()
        try preset(account, "text")
        let app = launch(account)
        var events: [[String: Any]] = [["type": "message.delta", "after": 0.05, "payload": ["text": "Half of an answer "]]]
        for _ in 0..<40 { events.append(["type": "message.delta", "after": 0.1, "payload": ["text": "and more "]]) }
        try account.control("/__fixture/plan", ["plans": [["events": events]]])
        typeAndSend(app, "Answer slowly")
        XCTAssertTrue(labelled(app, containing: "Half of an answer").waitForExistence(timeout: 15))
        try account.control("/__fixture/drop", [:])
        // The fixture's resume says nothing is running, so the phone keeps the partial reply and settles (no cut-off card: that
        // needs a gateway that answers the resync with an error).
        XCTAssertTrue(app.tables["chat.table"].exists, "the chat stays up")
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        shot("reply-after-drop")
        XCTAssertTrue(labelled(app, containing: "Half of an answer").exists, "the words that arrived stay")
        XCTAssertTrue(app.textViews["composer.text"].isHittable, "the composer still takes words")
        _ = try? account.control("/__fixture/finish", ["profile": "default", "text": "Done."])
    }
}
