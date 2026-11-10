// [m9/composer] End-to-end checks of the composer stream (docs/spec/3x-composer.md) against its stand-in gateway
// (scripts/fixtures/composer-gateway.py). Run with scripts/e2e-composer.sh <SIM_UDID>: it starts the fixture, passes
// its credentials file as TEST_RUNNER_HQN_UI_CREDENTIALS and the screenshot folder as TEST_RUNNER_HQN_SHOTS_DIR.
// Without the credentials every test skips. The app signs in from its process environment (DEBUG simulator hook), so
// no test types a password. Keys are real key presses (`typeKey`); Escape is driven through Command-period, its
// second key (XCUITest cannot deliver a plain Escape on this runtime: KeyboardShortcutTests.test5).
//
// Rows covered: L385 (test1, test2), L388 (test1, test2, test7), L464 (test1, test3), L448 (test4, test5), L386 (test6).

import XCTest

final class ComposerUITests: IPadTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Fixture

    @MainActor func start(arguments: [String] = [], bot: String = "default") throws -> (FixtureAccount, XCUIApplication) {
        let account = try FixtureAccount.load()
        try account.control("/__composer/reset", [:])
        let app = IPad.launch(account, arguments: arguments)
        IPad.openBot(app, bot)
        XCTAssertTrue(IPad.waitUntil(timeout: 20) { !app.buttons["composer.stop"].exists }, "no reply is running at the start")
        // The phone keeps a chat's queue across launches (that is the feature test3 checks), and every test signs in
        // to the same stand-in account: rows an earlier test left waiting are taken out before this one starts.
        let leftover = app.buttons.matching(identifier: "queue.more")
        var taps = 0
        while taps < 12, leftover.firstMatch.waitForExistence(timeout: 1.5) {
            leftover.firstMatch.tap()
            let delete = app.buttons["Delete"]
            if delete.waitForExistence(timeout: 3) { delete.tap() }
            taps += 1
        }
        XCTAssertFalse(app.staticTexts["chat.queue.header"].exists, "the queue is empty at the start")
        // A row taken out hands its words to the field: Select All, then Delete, wherever the caret landed.
        let field = IPad.field(app)
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        if let words = field.value as? String, !words.isEmpty, !words.hasPrefix("Message") {
            app.typeKey("a", modifierFlags: .command)
            field.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { (field.value as? String ?? "").isEmpty || (field.value as? String ?? "").hasPrefix("Message") },
                      "the field is empty at the start (\((field.value as? String ?? "nil").debugDescription))")
        return (account, app)
    }

    /// The same phone opened again (nothing reset). The app may come back on the Bots list or in the chat it had open.
    @MainActor private func relaunch(_ account: FixtureAccount) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HQN_SIGNIN_URL"] = account.url
        app.launchEnvironment["HQN_SIGNIN_USERNAME"] = account.username
        app.launchEnvironment["HQN_SIGNIN_PASSWORD"] = account.password
        app.launch()
        IPadTestCase.launchedPid = (app.value(forKey: "processID") as? Int32) ?? 0
        let table = IPad.table(app), row = app.cells["bot-row-default"]
        XCTAssertTrue(IPad.waitUntil(timeout: 40) { table.exists || row.exists }, "the app is back (the Bots list or the chat)")
        if !table.exists { IPad.openBot(app) }
        return app
    }

    /// Every call of `method` the fixture has seen since its reset, in order (its params).
    @MainActor func calls(_ account: FixtureAccount, _ method: String) -> [[String: Any]] {
        let state = (try? account.control("/__menus/state")) ?? [:]
        return (state["calls"] as? [[String: Any]] ?? []).filter { $0["method"] as? String == method }
            .map { $0["params"] as? [String: Any] ?? [:] }
    }

    @MainActor func texts(_ account: FixtureAccount) -> [String] { calls(account, "prompt.submit").compactMap { $0["text"] as? String } }

    @MainActor private func modelCalls(_ account: FixtureAccount) -> Int {
        ((try? account.control("/__composer/state")) ?? [:])["modelCalls"] as? Int ?? -1
    }

    /// The next reply is held open until the test ends it (`finish`).
    @MainActor private func holdNextReply(_ account: FixtureAccount) throws {
        try account.control("/__fixture/plan", ["plans": [["replyDelay": 120]]])
    }

    @MainActor private func header(_ app: XCUIApplication) -> String {
        let label = app.staticTexts["chat.queue.header"]
        return label.exists ? ((label.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? label.label) : ""
    }

    /// The header's shown words (its accessibility label is the spoken form).
    @MainActor private func headerShows(_ app: XCUIApplication, _ words: String, spoken: String, timeout: TimeInterval = 8) -> Bool {
        IPad.waitUntil(timeout: timeout) {
            let label = app.staticTexts["chat.queue.header"]
            return label.exists && label.label == spoken
        }
    }

    @MainActor private func typeAndReturn(_ app: XCUIApplication, _ text: String, _ flags: XCUIElement.KeyModifierFlags = []) {
        let field = IPad.focusField(app)
        field.typeText(text)
        XCTAssertTrue(IPad.waitUntil(timeout: 10) { (field.value as? String) == text }, "\(text.debugDescription) is in the field before Return (it holds \((field.value as? String ?? "nil").debugDescription))")
        IPad.pressReturn(app, flags)
    }

    /// A reply held open with "next" and "third" waiting behind it.
    @MainActor private func runningWithTwoQueued(_ account: FixtureAccount, _ app: XCUIApplication) throws {
        try holdNextReply(account)
        typeAndReturn(app, "hold this reply")
        XCTAssertTrue(app.buttons["composer.stop"].waitForExistence(timeout: 20), "Return sent it: the reply runs")
        XCTAssertTrue(IPad.waitUntil(timeout: 10) { self.texts(account) == ["hold this reply"] }, "one prompt.submit")
        typeAndReturn(app, "next", .command)
        XCTAssertTrue(headerShows(app, "Queued · Sends After This Reply", spoken: "1 message queued, sends after this reply"),
                      "Command-Return while a reply runs queues (header: \(header(app)))")
        typeAndReturn(app, "third", .command)
        XCTAssertTrue(headerShows(app, "2 Queued · Send After This Reply", spoken: "2 messages queued, send after this reply"),
                      "a second Command-Return queues behind it (header: \(header(app)))")
        XCTAssertEqual(texts(account), ["hold this reply"], "nothing else was sent")
    }

    // MARK: L385, L388, L464 · Stop pauses the queue; Resume sends it in order

    @MainActor func test1_StopPausesTheQueueAndResumeSendsItInOrder() throws {
        let (account, app) = try start()
        try runningWithTwoQueued(account, app)
        IPad.shot(app, "composer-queue-running", in: self)

        // "Stop or Close" (Escape's command) with the field focused stops the reply: one interrupt, the queue pauses.
        XCTAssertTrue(IPad.stopOrClose(app, "stop") { !app.buttons["composer.stop"].exists }, "Stop or Close stops the reply")
        XCTAssertTrue(headerShows(app, "Queue Paused · 2 Messages", spoken: "Queue paused, 2 messages"), "the queue reads paused (\(header(app)))")
        let resume = app.buttons["queue.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5), "Resume shows while paused")
        XCTAssertEqual(resume.label, "Resume queue")
        XCTAssertGreaterThanOrEqual(resume.frame.width, 44, "a real tap target")
        IPad.shot(app, "composer-queue-paused", in: self)
        for _ in 0..<2 { app.typeKey(".", modifierFlags: .command) }
        Thread.sleep(forTimeInterval: 4)
        XCTAssertEqual(calls(account, "session.interrupt").count, 1, "exactly one session.interrupt")
        XCTAssertEqual(texts(account), ["hold this reply"], "paused: nothing was sent")
        // With nothing left to stop, the command's next rung closes the chat (the iPad stream's ladder): open it again.
        if !IPad.field(app).waitForExistence(timeout: 3) { IPad.openBot(app) }
        XCTAssertTrue(headerShows(app, "Queue Paused · 2 Messages", spoken: "Queue paused, 2 messages"), "the paused queue is still there")

        // Return in the empty field never drains a paused queue.
        _ = IPad.focusField(app)
        IPad.pressReturn(app)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(texts(account), ["hold this reply"], "Return on a paused queue sends nothing")
        XCTAssertTrue(resume.exists)

        // Resume: the oldest goes now, the other after its reply.
        try account.control("/__fixture/plan", ["plans": [["chunks": ["one ", "done"], "chunkDelay": 0.4], ["chunks": ["two"], "chunkDelay": 0.05]]])
        resume.tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 10) { self.texts(account).count >= 2 }, "Resume sent the first")
        XCTAssertEqual(Array(texts(account).prefix(2)), ["hold this reply", "next"])
        XCTAssertTrue(IPad.waitUntil(timeout: 20) { self.texts(account) == ["hold this reply", "next", "third"] }, "then the second, after its reply (\(texts(account)))")
        XCTAssertTrue(IPad.waitUntil(timeout: 10) { !app.buttons["queue.resume"].exists && !app.staticTexts["chat.queue.header"].exists }, "the card is gone")
        XCTAssertTrue(IPad.message(app, containing: "third").waitForExistence(timeout: 8))
        IPad.shot(app, "composer-queue-resumed", in: self)
    }

    // MARK: L385 · Return in the empty field while a reply runs is Send Now on the head row

    @MainActor func test2_EmptyReturnSendsTheWaitingMessageNow() throws {
        let (account, app) = try start()
        try holdNextReply(account)
        typeAndReturn(app, "a long one")
        XCTAssertTrue(app.buttons["composer.stop"].waitForExistence(timeout: 20))
        typeAndReturn(app, "next", .command)
        XCTAssertTrue(app.staticTexts["chat.queue.header"].waitForExistence(timeout: 8), "queued")
        try account.control("/__fixture/plan", ["plans": [["chunks": ["ok"], "chunkDelay": 0.05]]])
        // The transcript is tapped first: the keys work whatever holds the focus; then the field again, empty.
        let field = IPad.focusField(app)
        XCTAssertTrue((field.value as? String ?? "").isEmpty || (field.value as? String ?? "").hasPrefix("Message"))
        IPad.pressReturn(app)
        XCTAssertTrue(IPad.waitUntil(timeout: 15) { self.texts(account) == ["a long one", "next"] }, "the waiting message went out (\(texts(account)))")
        XCTAssertEqual(calls(account, "session.interrupt").count, 1, "the running reply was stopped once for it")
        XCTAssertTrue(IPad.waitUntil(timeout: 10) { !app.staticTexts["chat.queue.header"].exists }, "nothing is left in the queue")
        XCTAssertTrue(IPad.message(app, containing: "next").waitForExistence(timeout: 8))
        // An empty Return with nothing waiting does nothing.
        _ = IPad.waitUntil(timeout: 15) { !app.buttons["composer.stop"].exists }
        _ = IPad.focusField(app)
        IPad.pressReturn(app)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(texts(account).count, 2)
        IPad.shot(app, "composer-empty-return", in: self)
    }

    // MARK: L388 · Stop or Close stops the reply once and never clears the draft

    @MainActor func test7_StopOrCloseStopsOnceAndKeepsTheDraft() throws {
        let (account, app) = try start()
        try holdNextReply(account)
        typeAndReturn(app, "keep going")
        let stop = app.buttons["composer.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 20))
        IPad.focusField(app).typeText("my draft")
        // The transcript is dragged first. With a hardware keyboard the field usually keeps the focus (the note below
        // prints which it was): this test does not claim the unfocused case.
        let table = IPad.table(app)
        table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).press(forDuration: 0.05, thenDragTo: table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        Thread.sleep(forTimeInterval: 0.8)
        let focused = (IPad.field(app).value(forKey: "hasKeyboardFocus") as? Bool) ?? false
        print("COMPOSER-NOTE field focused before Stop or Close: \(focused)")
        XCTAssertTrue(IPad.stopOrClose(app, "stop with a draft") { !stop.exists }, "Stop or Close stops the reply")
        for _ in 0..<3 { app.typeKey(".", modifierFlags: .command) }
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(calls(account, "session.interrupt").count, 1, "exactly one session.interrupt, however often it is pressed")
        XCTAssertEqual(IPad.field(app).value as? String, "my draft", "the draft is kept")
        IPad.shot(app, "composer-stop-keeps-draft", in: self)
    }

    // MARK: L464 · After a relaunch the kept queue starts paused

    @MainActor func test3_ARelaunchedQueueStartsPausedUntilResume() throws {
        let (account, app) = try start()
        try runningWithTwoQueued(account, app)
        Thread.sleep(forTimeInterval: 1.5)                       // the queue reaches the disk 0.3 s after its last change
        XCUIDevice.shared.press(.home)                           // going to the background writes it now
        Thread.sleep(forTimeInterval: 1.5)
        app.terminate()
        try account.control("/__fixture/finish", ["profile": "default", "text": "The held reply ended while the app was closed."])
        Thread.sleep(forTimeInterval: 1)

        let again = relaunch(account)
        XCTAssertTrue(headerShows(again, "Queue Paused · 2 Messages", spoken: "Queue paused, 2 messages", timeout: 15),
                      "the kept queue comes back paused (\(header(again)))")
        XCTAssertTrue(again.buttons["queue.resume"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 6)
        XCTAssertEqual(texts(account), ["hold this reply"], "nothing is sent by itself after a relaunch")
        IPad.shot(again, "composer-queue-relaunch-paused", in: self)
        again.buttons["queue.resume"].tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 30) { self.texts(account) == ["hold this reply", "next", "third"] }, "Resume sends both in order (\(texts(account)))")
    }

    // MARK: L448 · The model list is tried twice; one failure is never seen

    /// ⋯ › Model opens the model panel; its name opens Switch Model.
    @MainActor private func openModels(_ app: XCUIApplication) {
        let more = app.buttons["chat.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 8))
        more.tap()
        let model = app.buttons["chat.more.model"]
        XCTAssertTrue(model.waitForExistence(timeout: 8), "the ⋯ menu's Model row")
        Thread.sleep(forTimeInterval: 1.5)                       // the menu's one background read (both tries) settles
        model.tap()
        let name = app.buttons["model.panel.switch"]
        XCTAssertTrue(name.waitForExistence(timeout: 8), "the model panel opens")
        name.tap()
    }

    @MainActor func test4_OneFailedReadOfTheModelListIsNeverSeen() throws {
        let (account, app) = try start()
        try account.control("/__composer/mode", ["models": "fail_once"])
        openModels(app)
        let more = app.buttons["model.panel.search"]
        XCTAssertTrue(more.waitForExistence(timeout: 8))
        XCTAssertTrue(IPad.waitUntil(timeout: 10) { self.modelCalls(account) == 2 }, "the read was tried twice (\(modelCalls(account)))")
        XCTAssertFalse(app.buttons["model.tryAgain"].exists, "no failure in the menu")
        more.tap()
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.cells["models.row.anthropic::claude-sonnet-5"].waitForExistence(timeout: 10), "the list shows")
        XCTAssertFalse(app.staticTexts["Couldn’t Load Models"].exists, "the failure state never showed")
        IPad.shot(app, "composer-models-after-one-failure", in: self)
        // With rows on show a failed refresh keeps them and says nothing.
        try account.control("/__composer/mode", ["models": "error_text"])
        let before = modelCalls(account)
        app.buttons["models.refresh"].tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 10) { self.modelCalls(account) == before + 2 }, "the refresh was tried twice")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(app.cells["models.row.anthropic::claude-sonnet-5"].exists, "the rows stay")
        XCTAssertFalse(app.staticTexts["Couldn’t Load Models"].exists)
    }

    @MainActor func test5_TwoFailedReadsSayWhyAndTryAgainWorks() throws {
        let (account, app) = try start(arguments: ["-HQNModelTimeout", "3"])
        try account.control("/__composer/mode", ["models": "error_text"])
        openModels(app)
        // The ⋯ menu's own background read failed twice, and Switch Model's read too: the menu says so and offers one
        // more go.
        XCTAssertTrue(app.buttons["model.tryAgain"].waitForExistence(timeout: 12), "Try Again in Switch Model")
        XCTAssertTrue(app.buttons["Couldn’t load models"].exists, "and the plain words above it")
        XCTAssertEqual(modelCalls(account), 4, "exactly two tries each, not three")
        IPad.shot(app, "composer-model-menu-failed", in: self)
        app.buttons["model.panel.search"].tap()
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 8))
        let title = app.staticTexts["Couldn’t Load Models"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the failure shows after the second failure")
        XCTAssertEqual(modelCalls(account), 6, "the sheet's read was tried exactly twice")
        let words = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "The model inventory could not be read")).firstMatch
        XCTAssertTrue(words.exists, "the gateway's own words")
        XCTAssertTrue(words.label.hasSuffix("…"), "cut with an ellipsis")
        XCTAssertLessThanOrEqual(words.label.count, 121, "at 120 characters")
        IPad.shot(app, "composer-models-failed", in: self)

        // A gateway that never answers: "Loading models…" while both tries run, then the words for it.
        try account.control("/__composer/mode", ["models": "hang"])
        app.buttons["Try Again"].tap()
        XCTAssertTrue(app.staticTexts["Loading models…"].waitForExistence(timeout: 3), "it says it is loading")
        IPad.shot(app, "composer-models-loading", in: self)
        XCTAssertTrue(app.staticTexts["The computer running Hermes didn’t answer in time."].waitForExistence(timeout: 15), "the time-out in words")
        XCTAssertEqual(modelCalls(account), 8)
        IPad.shot(app, "composer-models-timeout", in: self)

        try account.control("/__composer/mode", ["models": "ok"])
        app.buttons["Try Again"].tap()
        XCTAssertTrue(app.cells["models.row.anthropic::claude-sonnet-5"].waitForExistence(timeout: 10), "Try Again reads the list")
        XCTAssertFalse(title.exists)
    }

    // MARK: L386 · A field of leftover line breaks is blank; a send drops trailing blank lines

    @MainActor func test6_LeftoverLineBreaksAreBlankAndASendDropsTrailingLines() throws {
        let (account, app) = try start()
        let field = IPad.focusField(app)
        func value() -> String { (field.value as? String) ?? "" }
        func isEmpty() -> Bool { value().isEmpty || value().hasPrefix("Message") }
        for _ in 0..<3 { IPad.pressReturn(app, .shift) }          // three line breaks into an empty field
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertTrue(isEmpty(), "a field of line breaks is blank again (\(value().debugDescription))")
        XCTAssertFalse(app.buttons["composer.send"].exists && app.buttons["composer.send"].isEnabled, "nothing to send")
        IPad.shot(app, "composer-blank-after-returns", in: self)

        try account.control("/__fixture/plan", ["plans": [["chunks": ["ok"], "chunkDelay": 0.05]]])
        field.typeText("alpha")
        IPad.pressReturn(app, .shift)
        IPad.pressReturn(app, .shift)
        XCTAssertTrue(IPad.waitUntil(timeout: 3) { value() == "alpha\n\n" }, "the line breaks after words stay while typing (\(value().debugDescription))")
        field.typeText("beta")
        IPad.pressReturn(app, .shift)
        IPad.pressReturn(app, .shift)
        IPad.pressReturn(app)
        XCTAssertTrue(IPad.waitUntil(timeout: 10) { self.texts(account).count == 1 }, "sent")
        XCTAssertEqual(texts(account).first, "alpha\n\nbeta", "trailing blank lines dropped, the inner one kept")
        XCTAssertTrue(IPad.waitUntil(timeout: 3) { isEmpty() }, "the field is empty after the send")
        // The field's keyboard settings as the app set them (autocorrect, capitals, spell-check): the unit test
        // `ComposerKeyboardTests` holds the values; here the field must still take focus and type after a send.
        field.typeText("x")
        XCTAssertTrue(IPad.waitUntil(timeout: 3) { value().lowercased() == "x" }, "typing goes on without touching the field (\(value().debugDescription))")
    }

    // MARK: L390 · Link… attaches a URL chip; the next send leads with its @url: line

    @MainActor func test8_LinkAttachesAndLeadsTheNextSend() throws {
        let (account, app) = try start()
        func openDialog() {
            let item = app.buttons["composer.plus.link"]
            for _ in 0..<3 where !item.exists {          // the first tap can land while the keyboard or a notice moves
                app.buttons["composer.plus"].tap()
                _ = item.waitForExistence(timeout: 4)
            }
            XCTAssertTrue(item.exists, "the + menu has Link…")
            item.tap()
        }
        openDialog()
        XCTAssertTrue(app.alerts["Add Link"].waitForExistence(timeout: 5), "titled Add Link")
        XCTAssertTrue(app.staticTexts["The page is fetched and included with your next message."].exists)
        let field = app.textFields["link.field"]
        XCTAssertTrue(field.exists)
        XCTAssertTrue(app.keyboards.buttons.matching(NSPredicate(format: "label ==[c] %@", "go")).firstMatch.waitForExistence(timeout: 5), "Return reads Go")
        XCTAssertFalse(app.alerts["Add Link"].firstMatch.buttons["Attach"].firstMatch.isEnabled, "Attach is off while empty")
        IPad.shot(app, "composer-link-empty", in: self)
        field.typeText("hello world")
        XCTAssertTrue(app.staticTexts["Include the full URL, e.g. https://…"].waitForExistence(timeout: 3), "the hint shows for non-links")
        XCTAssertFalse(app.alerts["Add Link"].firstMatch.buttons["Attach"].firstMatch.isEnabled)
        IPad.shot(app, "composer-link-hint", in: self)
        app.typeKey("a", modifierFlags: .command)
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        field.typeText("example.com/post")
        XCTAssertTrue(IPad.waitUntil(timeout: 3) { app.alerts["Add Link"].firstMatch.buttons["Attach"].firstMatch.isEnabled }, "a bare host is a link")
        app.textFields["link.field"].typeText("\n")
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { !app.alerts["Add Link"].exists }, "Go attaches and closes")
        let chip = app.buttons["composer.tray.tile.0"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "a chip is in the tray")
        XCTAssertEqual(chip.label, "Link, https://example.com/post")
        IPad.shot(app, "composer-link-chip", in: self)

        // The same link twice is one chip; a link with ( ) is quoted with backticks.
        openDialog()
        app.textFields["link.field"].typeText("https://example.com/post")
        app.textFields["link.field"].typeText("\n")
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { !app.alerts["Add Link"].exists })
        XCTAssertFalse(app.buttons["composer.tray.tile.1"].exists, "the same link is one chip")

        try account.control("/__fixture/plan", ["plans": [["chunks": ["ok"], "chunkDelay": 0.05]]])
        typeAndReturn(app, "hi")
        XCTAssertTrue(IPad.waitUntil(timeout: 15) { self.texts(account).count == 1 }, "sent")
        XCTAssertEqual(texts(account).first, "@url:https://example.com/post\n\nhi", "the ref line leads, then a blank line, then the words")
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { !app.buttons["composer.tray.tile.0"].exists }, "the tray is empty after the send")
        IPad.shot(app, "composer-link-sent", in: self)

        // Links alone, with parentheses.
        try account.control("/__fixture/plan", ["plans": [["chunks": ["ok"], "chunkDelay": 0.05]]])
        openDialog()
        app.textFields["link.field"].typeText("https://e.com/a(b)")
        app.textFields["link.field"].typeText("\n")
        XCTAssertTrue(app.buttons["composer.tray.tile.0"].waitForExistence(timeout: 5))
        _ = IPad.focusField(app)
        IPad.pressReturn(app)
        XCTAssertTrue(IPad.waitUntil(timeout: 15) { self.texts(account).count == 2 }, "a link alone sends")
        XCTAssertEqual(texts(account).last, "@url:`https://e.com/a(b)`")
    }

    // MARK: L463 · Send Now steers into the running reply; ⋯ has Stop and Send and Delete

    @MainActor func test9_QueueRowSteersAndHasAMenu() throws {
        let (account, app) = try start()
        try holdNextReply(account)
        typeAndReturn(app, "hold this reply")
        XCTAssertTrue(app.buttons["composer.stop"].waitForExistence(timeout: 20))
        typeAndReturn(app, "also update the README", .command)
        XCTAssertTrue(app.buttons["queue.sendnow"].waitForExistence(timeout: 8), "a text row offers a Send Now capsule")
        XCTAssertTrue(app.buttons["queue.more"].exists, "and the ⋯ menu")
        IPad.shot(app, "composer-queue-row", in: self)

        // Steered: session.redirect with exactly session_id + text; no second prompt.submit; the row is gone.
        app.buttons["queue.sendnow"].tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 10) { !self.calls(account, "session.redirect").isEmpty }, "session.redirect was called")
        let redirect = calls(account, "session.redirect")
        XCTAssertEqual(redirect.count, 1, "once, however fast")
        XCTAssertEqual(redirect.first?["text"] as? String, "also update the README")
        XCTAssertEqual(Set((redirect.first ?? [:]).keys).subtracting(["profile"]), ["session_id", "text"])
        XCTAssertTrue(IPad.waitUntil(timeout: 8) { !app.staticTexts["chat.queue.header"].exists }, "the row left the queue")
        XCTAssertEqual(texts(account), ["hold this reply"], "steering is not a second send")

        // A refusal keeps the row, says so, and the menu still has Stop and Send and Delete.
        try account.control("/__composer/mode", ["redirect": "rejected"])
        typeAndReturn(app, "second thought", .command)
        XCTAssertTrue(app.buttons["queue.sendnow"].waitForExistence(timeout: 8))
        app.buttons["queue.more"].tap()
        // Menu items carry subtitles that say how the two sends differ (UIKit joins them into the label).
        XCTAssertTrue(app.buttons["Stop and Send, Stops the reply, then sends this"].waitForExistence(timeout: 3), "Stop and Send while a reply runs")
        XCTAssertTrue(app.buttons["Delete"].exists)
        XCTAssertTrue(app.buttons["Send Now, Adds it to the current reply"].exists, "the menu's Send Now says it steers")
        IPad.shot(app, "composer-queue-menu", in: self)
        app.buttons["Delete"].tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { !app.staticTexts["chat.queue.header"].exists }, "Delete removes the row")

        typeAndReturn(app, "second thought", .command)
        XCTAssertTrue(app.buttons["queue.sendnow"].waitForExistence(timeout: 8))
        try account.control("/__composer/mode", ["redirect": "hang"])
        let before = calls(account, "session.redirect").count
        for _ in 0..<3 where app.buttons["queue.sendnow"].exists { app.buttons["queue.sendnow"].tap() }   // while the first is out the capsule is off (the lock)
        XCTAssertTrue(IPad.waitUntil(timeout: 10) { self.calls(account, "session.redirect").count > before })
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(calls(account, "session.redirect").count, before + 1, "three quick taps made one call")
        XCTAssertEqual(calls(account, "session.interrupt").count, 0, "a second tap never becomes Stop and Send")
        try account.control("/__composer/mode", ["redirect": "rejected"])
        XCTAssertTrue(app.staticTexts["Couldn’t add this to the running reply. It’ll send after this reply."].waitForExistence(timeout: 40)
                      || app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Couldn’t add this")).firstMatch.exists, "the refusal is said in words")
        IPad.shot(app, "composer-queue-refused", in: self)
        XCTAssertTrue(app.staticTexts["chat.queue.header"].exists, "the row stays queued")
    }

    // MARK: Desktop parity (owner 2026-10-28) · Return while a reply runs adds the message to it

    @MainActor func test27_ReturnWhileAReplyRunsAddsToIt() throws {
        let (account, app) = try start()
        try holdNextReply(account)
        typeAndReturn(app, "hold this reply")
        XCTAssertTrue(app.buttons["composer.stop"].waitForExistence(timeout: 20), "the reply runs")
        XCTAssertTrue(IPad.waitUntil(timeout: 10) { self.texts(account) == ["hold this reply"] })

        // Return: straight into the running reply, its bubble at once, no queue card, no second prompt.submit.
        typeAndReturn(app, "also update the README")
        XCTAssertTrue(IPad.waitUntil(timeout: 10) { self.calls(account, "session.redirect").count == 1 }, "session.redirect was called")
        XCTAssertEqual(calls(account, "session.redirect").first?["text"] as? String, "also update the README")
        XCTAssertTrue(IPad.message(app, containing: "also update the README").waitForExistence(timeout: 8), "its bubble shows")
        XCTAssertFalse(app.staticTexts["chat.queue.header"].exists, "nothing waits in the queue")
        XCTAssertEqual(texts(account), ["hold this reply"], "steering is not a second send")
        XCTAssertTrue(app.buttons["composer.stop"].exists, "the reply still runs")
        IPad.shot(app, "composer-return-adds-to-reply", in: self)

        // Turned down (the reply ended first): it waits in the queue instead, and says so.
        try account.control("/__composer/mode", ["redirect": "rejected"])
        typeAndReturn(app, "one more thing")
        XCTAssertTrue(app.staticTexts["chat.queue.header"].waitForExistence(timeout: 10), "a refused steer joins the queue")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Couldn’t add this")).firstMatch.waitForExistence(timeout: 5),
                      "the refusal is said in words")
        XCTAssertEqual(texts(account), ["hold this reply"])
        IPad.shot(app, "composer-return-refused-queues", in: self)
    }

    // MARK: Owner 2026-10-31 · hold Send while a reply runs to pick Steer or Queue

    @MainActor func test28_HoldSendPicksSteerOrQueue() throws {
        let (account, app) = try start()
        try holdNextReply(account)
        typeAndReturn(app, "hold this reply")
        XCTAssertTrue(app.buttons["composer.stop"].waitForExistence(timeout: 20), "the reply runs")
        XCTAssertTrue(IPad.waitUntil(timeout: 10) { self.texts(account) == ["hold this reply"] })

        IPad.focusField(app).typeText("wait for this one")
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.press(forDuration: 0.8)
        let queue = app.buttons["composer.send.queue"]
        XCTAssertTrue(queue.waitForExistence(timeout: 5), "the hold opens Steer / Queue")
        XCTAssertTrue(app.buttons["composer.send.steer"].exists)
        IPad.shot(app, "composer-hold-send-menu", in: self)
        queue.tap()
        XCTAssertTrue(app.staticTexts["chat.queue.header"].waitForExistence(timeout: 10), "Queue waits for the reply")
        XCTAssertTrue(calls(account, "session.redirect").isEmpty, "nothing went into the reply")

        IPad.focusField(app).typeText("steer into it")
        send.press(forDuration: 0.8)
        let steer = app.buttons["composer.send.steer"]
        XCTAssertTrue(steer.waitForExistence(timeout: 5))
        steer.tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 10) { self.calls(account, "session.redirect").count == 1 }, "Steer calls session.redirect")
        XCTAssertEqual(calls(account, "session.redirect").first?["text"] as? String, "steer into it")
        XCTAssertEqual(texts(account), ["hold this reply"], "steering is not a second send")
    }
}
