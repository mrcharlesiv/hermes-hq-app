// [composer-drawers] The slash drawer and the @ drawer above the composer (docs/spec/3x-composer.md §9.6, §10.4),
// against the composer stand-in (scripts/fixtures/composer-gateway.py: `complete.slash`, `complete.path`, the chats'
// folders /home/fx/proj for the main bot and /home/fx/other for Ivy).
//
// Rows covered: L440 (test10–test16), L441 (test17–test21).

import XCTest

extension ComposerUITests {
    // MARK: Helpers

    @MainActor private func row(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any)["drawer.row.\(title)"]
    }

    @MainActor private func note(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["drawer.note"] }

    /// Any drawer row or note is on screen.
    @MainActor private func drawerOpen(_ app: XCUIApplication) -> Bool {
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'drawer.row.' OR identifier == 'drawer.note'"))
        return rows.count > 0 && rows.firstMatch.exists
    }

    @MainActor private func value(_ app: XCUIApplication) -> String {
        let v = IPad.field(app).value as? String ?? ""
        return v.hasPrefix("Message") ? "" : v
    }

    @MainActor private func type(_ app: XCUIApplication, _ text: String) {
        IPad.field(app).typeText(text)
    }

    @MainActor private func clear(_ app: XCUIApplication) {
        let n = value(app).count
        if n > 0 { IPad.field(app).typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: n + 1)) }
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { self.value(app).isEmpty }, "the field is empty")
    }

    @MainActor private func composerState(_ account: FixtureAccount) -> [String: Any] {
        (try? account.control("/__composer/state")) ?? [:]
    }

    @MainActor private func completeLog(_ account: FixtureAccount, _ method: String) -> [[String: Any]] {
        (composerState(account)["completeLog"] as? [[String: Any]] ?? []).filter { $0["method"] as? String == method }
    }

    @MainActor private func gone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        IPad.waitUntil(timeout: timeout) { !element.exists }
    }

    // MARK: L440 · The slash drawer

    /// §9.6 1, 2, 3, 7: "/" opens the drawer without moving the keyboard or the composer; "/mo" shows /model with its
    /// description and nothing the phone hides; "/zzz" says "No matches."; deleting the "/" closes it, nothing left.
    @MainActor func test10_SlashDrawerOpensWithoutMovingTheKeyboard() throws {
        let (account, app) = try start()
        let field = IPad.focusField(app)
        // The field with one ordinary character in it (Send shows, the mic hides): the same field "/" gives it.
        type(app, "a")
        Thread.sleep(forTimeInterval: 1.2)
        let fieldBefore = field.frame
        let keysBefore = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame : .zero
        print("IPAD-NOTE drawer: before field \(fieldBefore) keys \(keysBefore)")
        field.typeText(XCUIKeyboardKey.delete.rawValue + "/")
        XCTAssertTrue(IPad.waitUntil(timeout: 8) { self.drawerOpen(app) }, "the drawer opened")
        XCTAssertFalse(note(app).exists && note(app).label == "No matches.", "the catalog's sections show")
        Thread.sleep(forTimeInterval: 0.6)
        IPad.shot(app, "drawer-slash-open", in: self)
        print("IPAD-NOTE drawer: after field \(field.frame) keys \(app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame : .zero)")
        XCTAssertEqual(field.frame, fieldBefore, "the composer did not move")
        XCTAssertEqual(app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame : .zero, keysBefore, "the keyboard did not move")

        type(app, "mo")
        let model = row(app, "/model")
        XCTAssertTrue(model.waitForExistence(timeout: 5), "/model is offered")
        XCTAssertTrue(model.label.hasPrefix("/model, ") && model.label.count > 9, "with its description (\(model.label))")
        XCTAssertTrue(IPad.waitUntil(timeout: 8) { !self.completeLog(account, "complete.slash").isEmpty }, "the gateway was asked")
        Thread.sleep(forTimeInterval: 1)
        for hidden in ["/debug", "/worktree", "/pet"] { XCTAssertFalse(row(app, hidden).exists, "\(hidden) is not listed") }
        let asked = completeLog(account, "complete.slash").compactMap { $0["params"] as? [String: Any] }
        XCTAssertTrue(asked.allSatisfy { Set($0.keys).isSubset(of: ["text", "session_id", "profile"]) }, "strict params (\(asked))")

        clear(app)
        type(app, "/zzz")
        XCTAssertTrue(IPad.waitUntil(timeout: 6) { self.note(app).exists && self.note(app).label == "No matches." }, "No matches.")

        clear(app)
        // A run of typed deletes can make the simulator take its hardware keyboard and lower the software one (seen:
        // the caret stays in the field); the check below is against where the field is now, before the "/".
        Thread.sleep(forTimeInterval: 0.8)
        let emptyAt = field.frame
        let keysAt = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame : .zero
        type(app, "/")
        XCTAssertTrue(IPad.waitUntil(timeout: 6) { self.drawerOpen(app) })
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        Thread.sleep(forTimeInterval: 0.8)
        IPad.shot(app, "drawer-slash-deleted", in: self)
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { !self.drawerOpen(app) }, "deleting the / closes the drawer")
        XCTAssertEqual(value(app), "", "nothing is left behind")
        // The simulator can also raise or lower its keys again on its own between the two reads (seen: down at emptyAt,
        // up a second later with the field at the keys' top): compare once the keys are back where they were then.
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { (app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame : .zero) == keysAt },
                      "the keys are back where they were (\(keysAt))")
        _ = IPad.waitUntil(timeout: 2) { field.frame == emptyAt }   // the composer follows the keys a beat later
        XCTAssertEqual(field.frame, emptyAt, "the composer is where it was")
    }

    /// §9.6 4: a command with no argument is sent at once; the field ends empty, no stray "/".
    @MainActor func test11_HelpPickSendsAtOnce() throws {
        let (account, app) = try start()
        _ = IPad.focusField(app)
        type(app, "/he")
        let help = row(app, "/help")
        XCTAssertTrue(help.waitForExistence(timeout: 6))
        help.tap()
        XCTAssertTrue(app.descendants(matching: .any)["commands.sheet"].waitForExistence(timeout: 8), "/help ran: the commands list opened")
        XCTAssertEqual(value(app), "", "the field is empty, no stray /")
        XCTAssertFalse(texts(account).contains { $0.hasPrefix("/") }, "a command is never sent as a message")
    }

    /// §9.6 5: /reasoning goes to its options; "high" completes the field; Send runs it.
    @MainActor func test12_ReasoningOptionsCompleteTheCommand() throws {
        let (account, app) = try start()
        _ = IPad.focusField(app)
        type(app, "/reas")
        let reasoning = row(app, "/reasoning")
        XCTAssertTrue(reasoning.waitForExistence(timeout: 6))
        reasoning.tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { self.value(app) == "/reasoning " }, "the field reads \"/reasoning \" (\(value(app)))")
        for option in ["low", "medium", "high"] { XCTAssertTrue(row(app, option).waitForExistence(timeout: 6), "option \(option)") }
        IPad.shot(app, "drawer-slash-options", in: self)
        row(app, "high").tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { self.value(app) == "/reasoning high" }, "the field reads \"/reasoning high\" (\(value(app)))")
        XCTAssertTrue(IPad.waitUntil(timeout: 3) { !self.drawerOpen(app) }, "the drawer closed: nothing was sent")
        XCTAssertTrue(texts(account).isEmpty)
        IPad.send(app)
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { self.value(app).isEmpty }, "Send ran it")
        XCTAssertFalse(texts(account).contains("/reasoning high"), "as a command, not a message")
    }

    /// §9.6 6: "/" mid-text offers skills only; a pick replaces just that word.
    @MainActor func test13_InlineSlashOffersSkillsOnly() throws {
        let (_, app) = try start()
        _ = IPad.focusField(app)
        type(app, "please /")
        XCTAssertTrue(row(app, "/release-notes").waitForExistence(timeout: 6), "skills show")
        XCTAssertFalse(row(app, "/reasoning").exists, "commands don't")
        type(app, "rel")
        let skill = row(app, "/release-notes")
        XCTAssertTrue(skill.waitForExistence(timeout: 4))
        skill.tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { self.value(app) == "please /release-notes " }, "only the /word changed (\(value(app)))")
    }

    /// §9.6 8: with the gateway hanging, or too old to complete, the local rows still come at once.
    @MainActor func test14_LocalRowsWhenTheGatewayHangsOrIsOld() throws {
        let (account, app) = try start()
        try account.control("/__composer/mode", ["complete": "hang"])
        _ = IPad.focusField(app)
        type(app, "/st")
        XCTAssertTrue(row(app, "/status").waitForExistence(timeout: 1.5), "the local rows show at once while the gateway hangs")
        type(app, "o")
        XCTAssertTrue(row(app, "/stop").waitForExistence(timeout: 1.5))
        XCTAssertFalse(row(app, "/status").exists, "and follow each key")
        clear(app)
        try account.control("/__composer/mode", ["complete": "old"])
        type(app, "/us")
        XCTAssertTrue(row(app, "/usage").waitForExistence(timeout: 1.5), "an older gateway (-32601): local rows")
        XCTAssertFalse(note(app).exists, "no error row")
        try account.control("/__composer/mode", ["complete": "ok"])
    }

    /// §9.6 9: typed fast, one call in flight at a time, and a late answer for an older query never shows.
    @MainActor func test15_FastTypingKeepsOneCallInFlight() throws {
        let (account, app) = try start()
        try account.control("/__composer/mode", ["complete": "slow"])   // "/r" and "/re" answer after 1.5 s
        _ = IPad.focusField(app)
        type(app, "/r")
        Thread.sleep(forTimeInterval: 0.3)
        type(app, "easoning h")
        XCTAssertTrue(row(app, "high").waitForExistence(timeout: 8), "the final text's options show")
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertTrue(row(app, "high").exists, "the slow answer for /r did not replace them")
        XCTAssertFalse(row(app, "/retry").exists)
        let log = completeLog(account, "complete.slash")
        XCTAssertGreaterThan(log.count, 0)
        for (a, b) in zip(log, log.dropFirst()) {
            let end = a["end"] as? Double ?? .infinity, next = b["start"] as? Double ?? 0
            XCTAssertLessThanOrEqual(end, next + 0.05, "one complete.slash in flight at a time (\(log.map { ($0["params"] as? [String: Any])?["text"] ?? "" }))")
        }
        XCTAssertLessThan(log.count, "/reasoning h".count, "the debounce skipped keys typed while one was out")
        try account.control("/__composer/mode", ["complete": "ok"])
    }

    /// Hardware keys (§9.5): ↓ highlights, Return picks; Stop or Close (the Escape ladder) closes and keeps the words.
    @MainActor func test16_KeysPickAndCloseTheDrawer() throws {
        let (_, app) = try start()
        _ = IPad.focusField(app)
        type(app, "/stat")
        XCTAssertTrue(row(app, "/status").waitForExistence(timeout: 6))
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        IPad.pressReturn(app)
        // /status takes no argument: Return on its row runs it.
        XCTAssertTrue(IPad.waitUntil(timeout: 6) { self.value(app).isEmpty }, "Return picked the highlighted row (\(value(app)))")
        type(app, "/stat")
        XCTAssertTrue(row(app, "/status").waitForExistence(timeout: 6))
        let closed = IPad.stopOrClose(app, "drawer") { !self.drawerOpen(app) }
        if closed { XCTAssertEqual(value(app), "/stat", "the words stay") }
    }

    /// §9.6 10: at the largest text size the rows grow and the drawer still leaves the field and 44 pt of transcript.
    @MainActor func test16b_LargestTextLeavesTheFieldAndTranscript() throws {
        let (_, app) = try start(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        _ = IPad.focusField(app)
        type(app, "a")
        Thread.sleep(forTimeInterval: 1.2)
        IPad.shot(app, "drawer-slash-ax-xxxl-before", in: self)
        let before = IPad.field(app).frame
        clear(app)
        type(app, "/")
        XCTAssertTrue(IPad.waitUntil(timeout: 8) { self.drawerOpen(app) })
        Thread.sleep(forTimeInterval: 0.8)
        IPad.shot(app, "drawer-slash-ax-xxxl", in: self)
        XCTAssertEqual(IPad.field(app).frame, before, "the drawer never moves the field")
        let list = app.descendants(matching: .any)["composer.drawer.list"]
        XCTAssertTrue(list.exists)
        let bar = app.navigationBars.firstMatch
        let top = bar.exists ? bar.frame.maxY : app.windows.firstMatch.frame.minY
        XCTAssertGreaterThanOrEqual(list.frame.minY - top, 44, "44 pt of transcript stay above the drawer")
        XCTAssertLessThanOrEqual(list.frame.maxY, IPad.field(app).frame.minY, "the field stays visible below it")
        IPad.shot(app, "drawer-slash-ax-xxxl", in: self)
    }

    // MARK: L441 · The @ drawer

    /// §10.4 1, 5, 7, 8: "@" lists the starters and the other bots (this chat's own absent); "@sa" → @ivy named by its
    /// display name; the main bot reads "Your main bot"; "hello@" opens nothing; with the gateway hanging the
    /// starters and Bots still show at once.
    @MainActor func test17_AtDrawerStartersAndBots() throws {
        let (account, app) = try start(bot: "ivy")
        try account.control("/__composer/mode", ["complete": "hang"])
        _ = IPad.focusField(app)
        type(app, "@")
        for starter in ["@file:", "@folder:", "@url:", "@diff", "@staged"] {
            XCTAssertTrue(row(app, starter).waitForExistence(timeout: 1.5), "starter \(starter) (at once, gateway hanging)")
        }
        let hermes = row(app, "@hermes")
        XCTAssertTrue(hermes.waitForExistence(timeout: 2), "the main bot is offered")
        XCTAssertEqual(hermes.label, "@hermes, Your main bot")
        XCTAssertFalse(row(app, "@ivy").exists, "this chat's own bot is not")
        IPad.shot(app, "drawer-at-open", in: self)
        clear(app)
        try account.control("/__composer/mode", ["complete": "ok"])
        IPad.back(app)
        IPad.openBot(app, "default")
        _ = IPad.focusField(app)
        type(app, "@sa")
        let ivy = row(app, "@ivy")
        XCTAssertTrue(ivy.waitForExistence(timeout: 4))
        XCTAssertEqual(ivy.label, "@ivy, Ivy", "described by its display name")
        clear(app)
        type(app, "hello@")
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertFalse(drawerOpen(app), "an address never opens the drawer")
    }

    /// §10.4 2, 3: @file: lists the folder's files, dotfiles only once "." is typed; a folder keeps its "/" and the
    /// drawer goes inside it.
    @MainActor func test18_AtFileListsTheChatsFolder() throws {
        let (_, app) = try start()
        _ = IPad.focusField(app)
        type(app, "@")
        let file = row(app, "@file:")
        XCTAssertTrue(file.waitForExistence(timeout: 4))
        file.tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 4) { self.value(app) == "@file:" }, "the field reads @file: (\(value(app)))")
        XCTAssertTrue(row(app, "README.md").waitForExistence(timeout: 6), "the folder's files")
        XCTAssertFalse(row(app, ".env").exists, "dotfiles hidden")
        IPad.shot(app, "drawer-at-files", in: self)
        type(app, ".")
        XCTAssertTrue(row(app, ".env").waitForExistence(timeout: 6), "typing . shows them")

        clear(app)
        type(app, "@folder:src/")
        let util = row(app, "src/util/")
        XCTAssertTrue(util.waitForExistence(timeout: 6))
        util.tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 4) { self.value(app) == "@folder:src/util/" }, "the trailing / stays (\(value(app)))")
        XCTAssertTrue(row(app, "src/util/deep/").waitForExistence(timeout: 6), "the drawer lists inside it")
    }

    /// §10.4 4: a file pick ends with a space, the drawer closes, and the message carries the ref verbatim.
    @MainActor func test19_AtFilePickIsSentVerbatim() throws {
        let (account, app) = try start()
        _ = IPad.focusField(app)
        type(app, "read @file:src/ma")
        let main = row(app, "src/main.py")
        XCTAssertTrue(main.waitForExistence(timeout: 6))
        main.tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 4) { self.value(app) == "read @file:src/main.py " }, "\(value(app))")
        XCTAssertTrue(IPad.waitUntil(timeout: 3) { !self.drawerOpen(app) }, "the drawer closed")
        IPad.send(app)
        XCTAssertTrue(IPad.waitUntil(timeout: 10) { self.texts(account).contains { $0.contains("@file:src/main.py") } },
                      "the ref went out verbatim (\(texts(account)))")
    }

    /// §10.4 6: a chat folder the gateway can't list says so in words.
    @MainActor func test20_AMissingFolderSaysSo() throws {
        let (account, app) = try start()
        try account.control("/__composer/mode", ["fs": "enoent"])
        _ = IPad.focusField(app)
        type(app, "@file:")
        XCTAssertTrue(IPad.waitUntil(timeout: 8) { self.note(app).exists && self.note(app).label == "This chat’s folder isn’t on the computer running Hermes." },
                      "the folder note shows")
        IPad.shot(app, "drawer-at-folder-missing", in: self)
        try account.control("/__composer/mode", ["fs": "ok"])
    }

    /// §10.4 9: `complete.path` carries this chat's own folder only, never another chat's.
    @MainActor func test21_AtAsksWithThisChatsFolder() throws {
        let (account, app) = try start()
        _ = IPad.focusField(app)
        type(app, "@file:s")
        XCTAssertTrue(IPad.waitUntil(timeout: 8) { !self.completeLog(account, "complete.path").isEmpty })
        let first = composerState(account)["pathCwds"] as? [String?] ?? []
        clear(app)
        IPad.back(app)
        IPad.openBot(app, "ivy")
        _ = IPad.focusField(app)
        type(app, "@file:n")
        XCTAssertTrue(row(app, "notes.txt").waitForExistence(timeout: 8), "Ivy's folder lists")
        let all = composerState(account)["pathCwds"] as? [String?] ?? []
        XCTAssertFalse(first.isEmpty)
        XCTAssertTrue(first.allSatisfy { $0 == "/home/fx/proj" }, "the main bot's chat asked with its folder (\(first))")
        XCTAssertTrue(all.dropFirst(first.count).allSatisfy { $0 == "/home/fx/other" }, "Ivy's chat with its own (\(all))")
        let params = completeLog(account, "complete.path").compactMap { $0["params"] as? [String: Any] }
        XCTAssertTrue(params.allSatisfy { Set($0.keys).isSubset(of: ["word", "cwd", "session_id", "profile"]) }, "strict params")
    }

    /// The drawers at Extra Large text and in the Desktop Look (screenshots only).
    @MainActor func test22_DrawerLooks() throws {
        for (name, arguments) in [("xl", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXL"]),
                                  ("desktop", ["-hqn.theme.desktopLook", "<true/>"])] {
            let (_, app) = try start(arguments: arguments)
            _ = IPad.focusField(app)
            type(app, "/re")
            XCTAssertTrue(row(app, "/reasoning").waitForExistence(timeout: 6))
            Thread.sleep(forTimeInterval: 1)
            IPad.shot(app, "drawer-slash-\(name)", in: self)
            clear(app)
            type(app, "@")
            XCTAssertTrue(row(app, "@file:").waitForExistence(timeout: 6))
            Thread.sleep(forTimeInterval: 0.6)
            IPad.shot(app, "drawer-at-\(name)", in: self)
            app.terminate()
        }
    }

    /// The slash drawer at the default text size, the iOS look and the Desktop Look, beside the Commands sheet and the
    /// ⋯ menu (screenshots, and each first row's text height in the log, for the drawer's row size: owner 2026-10-27
    /// "the font size of all / commands in the pop up are oddly large").
    @MainActor func test23_SlashDrawerRowSize() throws {
        for (name, arguments) in [("ios", ["-hqn.theme.desktopLook", "<false/>"]), ("desktop", ["-hqn.theme.desktopLook", "<true/>"])] {
            let (_, app) = try start(arguments: arguments)
            _ = IPad.focusField(app)
            type(app, "/")
            XCTAssertTrue(IPad.waitUntil(timeout: 8) { self.drawerOpen(app) }, "the drawer opened")
            Thread.sleep(forTimeInterval: 1)
            let first = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'drawer.row./'")).firstMatch
            print("IPAD-NOTE drawer-size \(name): row \(first.frame) \(first.staticTexts.allElementsBoundByIndex.map { "\($0.label.prefix(12)) h=\($0.frame.height)" })")
            IPad.shot(app, "drawer-size-\(name)", in: self)
            clear(app)
            type(app, "/he")
            let help = row(app, "/help")
            XCTAssertTrue(help.waitForExistence(timeout: 6))
            help.tap()
            let sheet = app.descendants(matching: .any)["commands.sheet"]
            XCTAssertTrue(sheet.waitForExistence(timeout: 8), "the Commands sheet")
            Thread.sleep(forTimeInterval: 1)
            let sheetRow = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'commands.row./'")).firstMatch
            print("IPAD-NOTE drawer-size \(name): sheet row \(sheetRow.frame) \(sheetRow.staticTexts.allElementsBoundByIndex.map { "\($0.label.prefix(12)) h=\($0.frame.height)" })")
            IPad.shot(app, "drawer-size-\(name)-sheet", in: self)
            app.terminate()
        }
    }

    /// §9.7: a command row in the drawer stars from its hold menu (Favorite / Unfavorite) and from a leading swipe, in
    /// the store the Commands sheet's star writes; the drawer's Favorites section follows at once. The keyboard's
    /// frame before, under and after the menu is logged (a context menu used to lower it).
    @MainActor func test24_FavoriteFromTheDrawer() throws {
        for (name, arguments) in [("ios", ["-hqn.theme.desktopLook", "<false/>"]), ("desktop", ["-hqn.theme.desktopLook", "<true/>"])] {
            let (_, app) = try start(arguments: arguments)
            let keys = app.keyboards.firstMatch
            _ = IPad.focusField(app)
            type(app, "/sta")
            let status = row(app, "/status")
            XCTAssertTrue(status.waitForExistence(timeout: 8), "/status is offered")
            let keysBefore = keys.exists ? keys.frame : .zero
            status.press(forDuration: 1.0)
            let favorite = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR label == %@", "drawer.favorite./status", "Add to Favorites")).firstMatch
            XCTAssertTrue(favorite.waitForExistence(timeout: 5), "the hold menu offers Add to Favorites")
            XCTAssertEqual(favorite.label, "Add to Favorites")
            print("IPAD-NOTE drawer-favorite \(name): keys before \(keysBefore), under the menu \(keys.exists ? keys.frame : .zero)")
            IPad.shot(app, "drawer-favorite-menu-\(name)", in: self)
            favorite.tap()
            Thread.sleep(forTimeInterval: 1)
            print("IPAD-NOTE drawer-favorite \(name): keys after \(keys.exists ? keys.frame : .zero), drawer open \(drawerOpen(app))")
            clear(app)
            type(app, "/")
            XCTAssertTrue(IPad.waitUntil(timeout: 8) { self.drawerOpen(app) }, "the drawer opened")
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Favorites")).firstMatch.waitForExistence(timeout: 5), "Favorites leads the drawer")
            Thread.sleep(forTimeInterval: 0.6)
            IPad.shot(app, "drawer-favorite-starred-\(name)", in: self)
            // A leading swipe on /stop stars it too; its hold menu now reads Unfavorite… after one more swipe, gone again.
            clear(app)
            type(app, "/sto")
            let stop = row(app, "/stop")
            XCTAssertTrue(stop.waitForExistence(timeout: 6))
            stop.swipeRight()
            let swipe = app.buttons["Favorite"]
            if swipe.waitForExistence(timeout: 3) { IPad.shot(app, "drawer-favorite-swipe-\(name)", in: self); swipe.tap() }
            Thread.sleep(forTimeInterval: 1)
            stop.press(forDuration: 1.0)
            let unfavorite = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR label == %@", "drawer.favorite./stop", "Remove from Favorites")).firstMatch
            XCTAssertTrue(unfavorite.waitForExistence(timeout: 5))
            XCTAssertEqual(unfavorite.label, "Remove from Favorites", "the swipe starred /stop")
            unfavorite.tap()
            // The sheet's star reads the same store: /status starred, /stop not.
            clear(app)
            type(app, "/he")
            XCTAssertTrue(row(app, "/help").waitForExistence(timeout: 6))
            row(app, "/help").tap()
            XCTAssertTrue(app.descendants(matching: .any)["commands.sheet"].waitForExistence(timeout: 8))
            XCTAssertTrue(app.descendants(matching: .any)["commands.row.fav./status"].waitForExistence(timeout: 5), "/status leads the sheet")
            XCTAssertFalse(app.descendants(matching: .any)["commands.row.fav./stop"].exists, "/stop was unstarred")
            app.terminate()
        }
    }
}
