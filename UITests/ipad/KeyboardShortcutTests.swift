// [m9/ipad] Hardware keyboard shortcuts (docs/spec/3x-ipad.md §4.10, §9), on an iPad and an iPhone simulator.
// Keys are real key presses (`typeKey`), so they travel the app's own responder chain. Run with scripts/e2e-ipad.sh.

import XCTest

final class KeyboardShortcutTests: IPadTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Return sends, Shift-Return and Option-Return add a line, Return in an empty field does nothing, Command-Return
    /// sends. Every key here is the real key press (`IPad.returnKey`); nothing stands in for it.
    @MainActor func test1_ReturnSendsAndShiftReturnAddsALine() throws {
        let account = try IPad.account(.perf)
        let app = IPad.launch(account)
        IPad.openBot(app)
        // The stand-in gateway is shared by the tests of one run: a reply an earlier test left running would turn
        // a send into a queued message, and a long plan left over would keep the next reply running.
        let short: [String: Any] = ["chunks": ["fine ", "then"], "chunkDelay": 0.01]
        try IPad.plan(account, [short, short])
        if app.buttons["composer.stop"].waitForExistence(timeout: 2) { app.buttons["composer.stop"].tap() }
        XCTAssertTrue(IPad.waitUntil(timeout: 20) { !app.buttons["composer.stop"].exists }, "no reply is running at the start")
        let field = IPad.focusField(app)
        func value() -> String { (field.value as? String) ?? "" }
        func isEmpty() -> Bool { value().hasPrefix("Message") || value().isEmpty }
        let submits = IPad.count("prompt.submit", account)
        IPad.pressReturn(app)
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(IPad.count("prompt.submit", account), submits, "Return in an empty field sends nothing")
        XCTAssertTrue(isEmpty(), "and adds no line (\(value().debugDescription))")

        let token = "t\(Int(Date().timeIntervalSince1970) % 1_000_000)"   // the fixture keeps earlier runs' bubbles
        field.typeText("line one")
        IPad.pressReturn(app, .shift)
        field.typeText("two")
        XCTAssertTrue(IPad.waitUntil(timeout: 3) { value() == "line one\ntwo" }, "Shift-Return adds a line (\(value().debugDescription))")
        IPad.pressReturn(app, .option)
        field.typeText(token)
        XCTAssertTrue(IPad.waitUntil(timeout: 3) { value() == "line one\ntwo\n\(token)" }, "Option-Return adds a line (\(value().debugDescription))")
        XCTAssertEqual(IPad.count("prompt.submit", account), submits, "neither sends")
        IPad.shot(app, "keys-shift-return", in: self)

        IPad.pressReturn(app)
        XCTAssertTrue(IPad.message(app, containing: token).waitForExistence(timeout: 8), "Return sends: the bubble shows")
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { IPad.count("prompt.submit", account) == submits + 1 }, "exactly one prompt.submit")
        XCTAssertTrue(IPad.waitUntil(timeout: 3) { isEmpty() }, "the field is empty after the send")
        IPad.shot(app, "keys-return-sent", in: self)

        // ⌘Return sends too.
        _ = IPad.waitUntil(timeout: 20) { !app.buttons["composer.stop"].exists }
        IPad.focusField(app).typeText("second \(token)")
        IPad.pressReturn(app, .command)
        let sent = IPad.message(app, containing: "second \(token)").waitForExistence(timeout: 8)
        IPad.shot(app, "keys-command-return", in: self)
        print("IPAD-NOTE Command-Return: bubble \(sent), field \(value().debugDescription), prompt.submit \(IPad.count("prompt.submit", account) - submits)")
        XCTAssertTrue(sent, "Command-Return sends")
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { IPad.count("prompt.submit", account) == submits + 2 }, "one more prompt.submit")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(IPad.count("prompt.submit", account), submits + 2, "and only one")
    }

    /// "Stop or Close" (Escape's command, pressed here through its second key, Command-period: see `IPad.stopOrClose`)
    /// with Find open closes Find and the reply keeps running; it closes a sheet without touching the reply behind it;
    /// with nothing on top it stops the reply with exactly one interrupt, however often it is pressed.
    @MainActor func test2_EscapeLadder() throws {
        let account = try IPad.account(.perf)
        let app = IPad.launch(account)
        IPad.openBot(app)
        // A reply an earlier test (or an earlier run that died) left running would turn this send into a queued
        // message: the test starts from a quiet chat, as test 1 does.
        if app.buttons["composer.stop"].waitForExistence(timeout: 2) { app.buttons["composer.stop"].tap() }
        XCTAssertTrue(IPad.waitUntil(timeout: 20) { !app.buttons["composer.stop"].exists }, "no reply is running at the start")
        try IPad.plan(account, [["chunks": Array(repeating: "word ", count: 2500), "chunkDelay": 0.04]])
        let field = IPad.focusField(app)
        field.typeText("a long reply please")
        XCTAssertTrue(IPad.waitUntil(timeout: 10) { (field.value as? String) == "a long reply please" }, "the words are in the field before Return")
        let stop = app.buttons["composer.stop"]
        let submits = IPad.count("prompt.submit", account)
        IPad.pressReturn(app)
        XCTAssertTrue(IPad.waitUntil(timeout: 20) { IPad.count("prompt.submit", account) == submits + 1 }, "Return sent it: one prompt.submit")
        XCTAssertTrue(stop.waitForExistence(timeout: 20), "Return sent it: the reply runs")
        let interrupts = IPad.count("session.interrupt", account)

        // Find open: Stop or Close closes Find only.
        IPad.command(app, "f")
        let find = app.descendants(matching: .any)["chat.find.field"]
        XCTAssertTrue(find.waitForExistence(timeout: 6), "Command-F opens Find in the chat")
        IPad.shot(app, "keys-find-open", in: self)
        XCTAssertTrue(IPad.stopOrClose(app, "find") { !find.exists }, "Stop or Close closes Find")
        XCTAssertTrue(stop.exists, "the reply is still running")
        XCTAssertEqual(IPad.count("session.interrupt", account), interrupts, "with Find open it did not stop the reply")

        // A sheet open: it closes the sheet only.
        app.buttons["composer.commands"].tap()
        let close = app.navigationBars["Commands"]
        XCTAssertTrue(close.waitForExistence(timeout: 8), "the commands sheet opens")
        app.typeKey("n", modifierFlags: .command)          // a shortcut never acts behind a sheet
        XCTAssertTrue(IPad.stopOrClose(app, "sheet") { !close.exists }, "Stop or Close closes the sheet")
        XCTAssertTrue(stop.exists, "the reply is still running behind it")
        XCTAssertEqual(IPad.count("session.interrupt", account), interrupts)
        XCTAssertEqual(IPad.count("session.create", account), 0, "Command-N under a sheet started nothing")

        // Find open again, then two presses in a row: the first closes Find, the second stops the reply.
        IPad.command(app, "f")
        XCTAssertTrue(find.waitForExistence(timeout: 6))
        app.typeKey(".", modifierFlags: .command)
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(IPad.waitUntil(timeout: 10) { !find.exists && !stop.exists }, "two presses: Find closes, then the reply stops")
        for _ in 0..<3 { app.typeKey(".", modifierFlags: .command) }
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(IPad.count("session.interrupt", account), interrupts + 1, "exactly one session.interrupt")
        IPad.shot(app, "keys-escape-stopped", in: self)
    }

    /// The plain Escape key itself. XCUITest does not deliver it on this runtime (no key press reaches the app), so
    /// this test skips, saying so, unless a later runtime delivers it; then it must close Find.
    @MainActor func test5_PlainEscapeKey() throws {
        let account = try IPad.account(.perf)
        let app = IPad.launch(account)
        IPad.openBot(app)
        IPad.command(app, "f")
        let find = app.descendants(matching: .any)["chat.find.field"]
        XCTAssertTrue(find.waitForExistence(timeout: 6), "Command-F opens Find in the chat")
        app.typeKey(.escape, modifierFlags: [])
        guard IPad.waitUntil(timeout: 4, { !find.exists }) else {
            throw XCTSkip("XCUITest cannot deliver a plain Escape key press on this simulator runtime; Escape's binding is checked by KeyCommandTests and its ladder through Command-period (test2).")
        }
    }

    /// ⌘1 / ⌘2 switch tabs, ⌘, opens Settings, ⌘W closes the chat, ⌘F on a list opens its search, ⌘⇧F searches Sessions.
    @MainActor func test3_TabsSettingsCloseAndSearch() throws {
        let account = try IPad.account(.perf)
        let app = IPad.launch(account)
        IPad.command(app, "2")
        XCTAssertTrue(app.collectionViews["sessions.list"].waitForExistence(timeout: 8), "Command-2 shows Sessions")
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(IPad.waitUntil(timeout: 8) { IPad.shows(app.collectionViews["bots.list"]) }, "Command-1 shows Bots")

        IPad.openBot(app)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(IPad.waitUntil(timeout: 6) { !IPad.table(app).exists }, "Command-W closes the chat")
        if IPad.isPad { XCTAssertTrue(IPad.placeholder(app).waitForExistence(timeout: 4), "the right pane is empty again") }
        XCTAssertTrue(IPad.shows(app.collectionViews["bots.list"]))

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["settings.list"].waitForExistence(timeout: 8), "Command-comma opens Settings")
        IPad.shot(app, "keys-settings", in: self)

        app.typeKey("f", modifierFlags: [.command, .shift])
        let search = app.descendants(matching: .any)["sessions.search.field"]
        XCTAssertTrue(search.waitForExistence(timeout: 8), "Command-Shift-F opens the Sessions search")
        XCTAssertTrue(app.collectionViews["sessions.list"].exists)
        IPad.shot(app, "keys-search-sessions", in: self)
        XCTAssertTrue(IPad.stopOrClose(app, "search") { !search.exists || !(search.value(forKey: "hasKeyboardFocus") as? Bool ?? false) },
                      "Stop or Close leaves the search")
    }

    /// ⌘N starts a new chat (one session.create); ⌘↓ / ⌘↑ walk the bots in list order and stop at the ends.
    @MainActor func test4_NewChatAndWalkingTheList() throws {
        let account = try IPad.account(.sessions)
        try account.control("/__fixture/reset", [:])
        let app = IPad.launch(account)
        let order = ["default", "research", "deploys"]
        for id in order { XCTAssertTrue(app.cells["bot-row-\(id)"].waitForExistence(timeout: 15), "\(id) is listed") }
        let listed = order.sorted { app.cells["bot-row-\($0)"].frame.minY < app.cells["bot-row-\($1)"].frame.minY }

        func shownBot() -> String? { listed.first { app.cells["bot-row-\($0)"].isSelected } }
        func title(_ id: String) -> Bool {
            if IPad.isPad { return shownBot() == id }
            return IPad.table(app).exists
        }

        IPad.command(app, XCUIKeyboardKey.downArrow.rawValue)   // the first key of the launch (see IPad.command)
        XCTAssertTrue(IPad.table(app).waitForExistence(timeout: 10), "Command-Down with nothing open opens the first chat")
        if IPad.isPad {
            XCTAssertTrue(IPad.waitUntil(timeout: 6) { shownBot() == listed[0] }, "the first row's chat")
            app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: .command)
            XCTAssertTrue(IPad.waitUntil(timeout: 8) { shownBot() == listed[1] }, "Command-Down opens the next row's chat")
            app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: .command)
            XCTAssertTrue(IPad.waitUntil(timeout: 8) { shownBot() == listed[2] }, "and the one after")
            IPad.shot(app, "keys-walk-last", in: self)
            app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: .command)
            Thread.sleep(forTimeInterval: 1.0)
            XCTAssertEqual(shownBot(), listed[2], "no wrap at the end")
            app.typeKey(XCUIKeyboardKey.upArrow, modifierFlags: .command)
            XCTAssertTrue(IPad.waitUntil(timeout: 8) { shownBot() == listed[1] }, "Command-Up goes back")
            app.typeKey(.tab, modifierFlags: [.control, .shift])
            XCTAssertTrue(IPad.waitUntil(timeout: 8) { shownBot() == listed[0] }, "Control-Shift-Tab is Previous Chat too")
            app.typeKey(XCUIKeyboardKey.upArrow, modifierFlags: .command)
            Thread.sleep(forTimeInterval: 1.0)
            XCTAssertEqual(shownBot(), listed[0], "no wrap at the start")
            // With words in the field ⌘↑ belongs to the caret.
            let field = IPad.focusField(app)
            field.typeText("words")
            app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: .command)
            Thread.sleep(forTimeInterval: 1.0)
            XCTAssertEqual(shownBot(), listed[0], "Command-Down in a field with text keeps the chat")
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5))
        } else {
            // Phone layout: the next chat takes the place of the one on show; one Back returns to the list.
            let title = app.descendants(matching: .any)["chat.title"].firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 6))
            let first = title.label
            app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: .command)
            XCTAssertTrue(IPad.waitUntil(timeout: 8) { title.exists && title.label != first }, "Command-Down opens the next chat (\(first) → \(title.label))")
            IPad.shot(app, "keys-walk-phone", in: self)
            IPad.back(app)
            XCTAssertTrue(IPad.waitUntil(timeout: 6) { IPad.shows(app.collectionViews["bots.list"]) }, "one Back returns to the list")
        }

        // [cmd-n] ⌘N: no chooser, one session.create with Hermes (the default profile).
        XCTAssertEqual(IPad.count("session.create", account), 0)
        IPad.command(app, "n")
        XCTAssertTrue(IPad.waitUntil(timeout: 10) { IPad.count("session.create", account) == 1 }, "one session.create")
        XCTAssertFalse(app.descendants(matching: .any)["choose-bot-research"].exists, "Command-N does not ask which bot")
        func created(_ index: Int) throws -> [String: Any]? {
            let state = try account.control("/__fixture/state")
            let creates = (state["rpc"] as? [[String: Any]])?.filter { $0["method"] as? String == "session.create" } ?? []
            return creates.count > index ? creates[index]["params"] as? [String: Any] : nil
        }
        XCTAssertEqual(try created(0)?["profile"] as? String, "default")
        XCTAssertEqual(try created(0)?["follow_profile_config"] as? Bool, true, "the same call the Compose button makes")
        XCTAssertTrue(IPad.field(app).waitForExistence(timeout: 10), "the new chat is open")
        IPad.shot(app, "keys-new-chat-open", in: self)

        // ⇧⌘N: the bot chooser (three bots), then one session.create with the chosen bot.
        app.typeKey("n", modifierFlags: [.command, .shift])
        let choice = app.descendants(matching: .any)["choose-bot-research"]
        XCTAssertTrue(choice.waitForExistence(timeout: 8), "Shift-Command-N asks which bot")
        IPad.shot(app, "keys-new-chat-choose", in: self)
        choice.tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 10) { IPad.count("session.create", account) == 2 }, "one more session.create")
        XCTAssertEqual(try created(1)?["profile"] as? String, "research")
    }

    /// [cmd-n] A tester 2026-11-02: with ⌘N Opens › Bot Chat, Command-N opens the bot's own chat (no session.create)
    /// with the caret in its message field, from another tab too; ⇧⌘N still starts a new chat.
    @MainActor func test9_BotChatModeOpensTheBotsOwnChat() throws {
        let account = try IPad.account(.sessions)
        try account.control("/__fixture/reset", [:])
        let app = IPad.launch(account, arguments: ["-hqn.newChatKeyMode", "botChat", "-hqn.newChatKeyBot", "research"])
        XCTAssertTrue(app.cells["bot-row-research"].waitForExistence(timeout: 15), "the Bots list is on show")
        app.typeKey("3", modifierFlags: .command)   // from Jobs
        Thread.sleep(forTimeInterval: 1.0)
        IPad.command(app, "n")
        XCTAssertTrue(IPad.field(app).waitForExistence(timeout: 10), "Command-N opens a chat")
        XCTAssertTrue(IPad.waitUntil(timeout: 6) { (IPad.field(app).value(forKey: "hasKeyboardFocus") as? Bool) == true },
                      "the caret is in its message field")
        if IPad.isPad { XCTAssertTrue(IPad.waitUntil(timeout: 6) { app.cells["bot-row-research"].isSelected }, "research's own chat, marked in Bots") }
        XCTAssertFalse(app.descendants(matching: .any)["choose-bot-research"].exists, "no chooser")
        IPad.shot(app, "keys-bot-chat-mode", in: self)
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(IPad.count("session.create", account), 0, "the bot's own chat: no new session")
        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.descendants(matching: .any)["choose-bot-research"].waitForExistence(timeout: 8), "Shift-Command-N still asks")
    }

    /// Stress round 1: Command-N from a tab other than Sessions, with no walk first. In the phone layout the new chat
    /// was pushed on the hidden Sessions tab and never seen. It must show; one Back lands on the Sessions list.
    @MainActor func test6_NewChatFromAnotherTab() throws {
        let account = try IPad.account(.sessions)
        try account.control("/__fixture/reset", [:])
        let app = IPad.launch(account)
        XCTAssertTrue(app.cells["bot-row-research"].waitForExistence(timeout: 15), "the Bots list is on show")
        XCTAssertEqual(IPad.count("session.create", account), 0)
        for round in 1...2 {
            // Round 1 from Bots; round 2 from Jobs (the third tab), with round 1's chat left open on Sessions.
            if round == 2 {
                app.typeKey("3", modifierFlags: .command)
                XCTAssertTrue(IPad.waitUntil(timeout: 8) { !IPad.field(app).exists || IPad.isPad }, "Command-3 leaves the chat for Jobs")
            }
            IPad.command(app, "n")   // [cmd-n] no chooser: a chat with Hermes at once
            XCTAssertTrue(IPad.waitUntil(timeout: 10) { IPad.count("session.create", account) == round }, "one session.create per chat (round \(round))")
            XCTAssertTrue(IPad.field(app).waitForExistence(timeout: 10), "the new chat is on show (round \(round))")
            XCTAssertTrue(IPad.waitUntil(timeout: 5) { IPad.field(app).isHittable }, "and its message field can be used (round \(round))")
            IPad.shot(app, "keys-new-chat-other-tab-\(round)", in: self)
        }
        if IPad.isPad {
            XCTAssertFalse(IPad.shows(app.collectionViews["sessions.list"]), "two panes: the left pane keeps its tab (Jobs)")
        } else {
            IPad.back(app)
            XCTAssertTrue(IPad.waitUntil(timeout: 8) { IPad.shows(app.collectionViews["sessions.list"]) }, "one Back lands on the Sessions list")
            XCTAssertFalse(IPad.field(app).exists, "round 1's chat is not underneath")
            IPad.shot(app, "keys-new-chat-other-tab-back", in: self)
        }
    }

    /// Phone layout (an iPhone, or a narrow iPad window): Command-N with a new chat already open on Sessions puts the
    /// next new chat in its place over the list. Each press made one more level before (stress round 2: Back landed
    /// on the previous chat). Three presses, three chats made, and one Back is the Sessions list.
    @MainActor func test7_NewChatOverAnOpenChatStaysOneBackFromSessions() throws {
        let account = try IPad.account(.sessions)
        try account.control("/__fixture/reset", [:])
        let app = IPad.launch(account, arguments: IPad.isPad ? ["-HQDebugPaneWidth", "420"] : [])
        XCTAssertTrue(app.cells["bot-row-research"].waitForExistence(timeout: 15), "the Bots list is on show")
        for round in 1...3 {
            IPad.command(app, "n")   // [cmd-n] no chooser: a chat with Hermes at once
            XCTAssertTrue(IPad.waitUntil(timeout: 10) { IPad.count("session.create", account) == round }, "one session.create per chat (round \(round))")
            XCTAssertTrue(IPad.field(app).waitForExistence(timeout: 10), "the new chat is on show (round \(round))")
            XCTAssertTrue(IPad.waitUntil(timeout: 5) { IPad.field(app).isHittable }, "and its message field can be used (round \(round))")
            Thread.sleep(forTimeInterval: 1.0)   // the push has ended before the next press
        }
        IPad.shot(app, "keys-new-chat-over-chat", in: self)
        IPad.back(app)
        XCTAssertTrue(IPad.waitUntil(timeout: 8) { IPad.shows(app.collectionViews["sessions.list"]) }, "one Back lands on the Sessions list")
        XCTAssertFalse(IPad.field(app).exists, "no earlier new chat is underneath")
        IPad.shot(app, "keys-new-chat-over-chat-back", in: self)
    }

    /// Command-F as the very first key after a chat opens from a row tap, with nothing in the chat focused yet (stress
    /// rounds 1 and 2: once in a run it did nothing and the app's log had no Find at all). Unlike test 5 this never
    /// skips, so it can be repeated (HQN_IPAD_ITERATIONS) to look for the lost press. Three chats in one launch.
    @MainActor func test8_FindIsTheFirstKeyAfterAChatOpens() throws {
        let account = try IPad.account(.perf)
        let app = IPad.launch(account)
        let find = app.descendants(matching: .any)["chat.find.field"]
        for (round, bot) in ["default", "ivy", "default"].enumerated() {
            if round == 0 || !IPad.isPad {
                IPad.openBot(app, bot)
            } else {
                app.cells["bot-row-\(bot)"].tap()
                XCTAssertTrue(IPad.waitUntil(timeout: 10) { app.cells["bot-row-\(bot)"].isSelected && IPad.table(app).exists }, "the chat opens (round \(round + 1))")
            }
            IPad.command(app, "f")
            XCTAssertTrue(find.waitForExistence(timeout: 6), "Command-F opens Find in the chat (round \(round + 1))")
            XCTAssertTrue(IPad.stopOrClose(app, "find") { !find.exists }, "Stop or Close closes Find (round \(round + 1))")
            if !IPad.isPad {
                IPad.back(app)
                XCTAssertTrue(IPad.waitUntil(timeout: 8) { IPad.shows(app.collectionViews["bots.list"]) }, "back on the Bots list")
            }
        }
    }
}
