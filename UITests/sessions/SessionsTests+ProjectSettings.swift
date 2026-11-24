import XCTest

/// [project-settings] Owner 2026-11-20/21: a project's page has its own settings, on one page (⋯ › Project Settings…):
/// Keep Chats in This Project, Pins Stay in Project, Move Quiet Chats to Done, Notifications, the model and reasoning
/// its new chats start with, its icon and colour, and (a coding project) Show Branch on Rows.
extension SessionsTests {
    // MARK: Helpers

    /// Website's pill moves when reading its last unread chat changes the rail order.
    @MainActor func openWebsitePage(_ app: XCUIApplication) {
        let toProjects = app.buttons["sessions.pills.projects"]
        XCTAssertTrue(toProjects.waitForExistence(timeout: 15))
        tapSide(app, toProjects)
        let website = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.chip.project.' AND label BEGINSWITH 'Website project'")).firstMatch
        XCTAssertTrue(website.waitForExistence(timeout: 6))
        onScreen(app, website).tap()
        let page = app.cells["sessions.projectPage"]
        XCTAssertTrue(page.waitForExistence(timeout: 6))
        XCTAssertTrue(page.staticTexts["Website"].waitForExistence(timeout: 6), "Website's page, not just its pill")
    }

    /// ⋯ › Project Settings… on the page shown.
    @MainActor func openProjectSettings(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let more = app.buttons["sessions.projectPage.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), "the header's ⋯", file: file, line: line)
        more.tap()
        let settings = app.buttons["Project Settings…"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "the ⋯ has Project Settings…", file: file, line: line)
        settings.tap()
        XCTAssertTrue(app.switches["sessions.projectPage.localPins"].waitForExistence(timeout: 8), "the settings page opens", file: file, line: line)
    }

    @MainActor func closeProjectSettings(_ app: XCUIApplication) {
        app.buttons["sheet.close"].firstMatch.tap()
        XCTAssertTrue(waitUntil(6) { !app.switches["sessions.projectPage.localPins"].exists }, "the settings page closes")
    }

    /// An element of the settings page, scrolled to.
    @MainActor func projectSetting(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
        for _ in 0..<5 where !element.exists || !element.isHittable { app.swipeUp(velocity: .slow) }
        return element
    }

    /// Flips a switch of the settings page (the control itself, at the row's trailing end) and waits for its value.
    @MainActor func flipProjectSwitch(_ app: XCUIApplication, _ id: String, to on: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let toggle = app.switches[id].firstMatch
        for _ in 0..<5 where !toggle.exists || !toggle.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "switch \(id)", file: file, line: line)
        let inner = toggle.switches.firstMatch
        (inner.exists ? inner : toggle).tap()
        XCTAssertTrue(waitUntil(4) { (toggle.value as? String) == (on ? "1" : "0") }, "\(id) is \(on ? "on" : "off") (\(String(describing: toggle.value)))",
                      file: file, line: line)
    }

    /// Picks `choice` in a menu picker of the settings page.
    @MainActor func pickProjectSetting(_ app: XCUIApplication, _ id: String, _ choice: String, file: StaticString = #filePath, line: UInt = #line) {
        let picker = projectSetting(app, id)
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "picker \(id)", file: file, line: line)
        picker.tap()
        let item = app.buttons[choice].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(id) offers \(choice)", file: file, line: line)
        item.tap()
        XCTAssertTrue(waitUntil(4) { self.projectSetting(app, id).label.contains(choice) || (self.projectSetting(app, id).value as? String)?.contains(choice) == true },
                      "\(id) says \(choice) (\(projectSetting(app, id).label))", file: file, line: line)
    }

    // MARK: Step 0: the page

    /// The ⋯ has Project Settings… near its top and no longer Pins Stay in Project; the sheet is titled with the
    /// project's name and lists Chats, Notifications, New Chats and Look; a change is kept at once (no Save), and a
    /// coding project gets its two extra rows.
    @MainActor func test40k_ProjectSettingsPage() throws {
        let app = launch(projectPages: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openWebsitePage(app)
        let more = app.buttons["sessions.projectPage.more"]
        more.tap()
        let settings = app.buttons["Project Settings…"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "the ⋯ has Project Settings…")
        XCTAssertTrue(app.buttons["Coding Project"].exists && app.buttons["Sort"].exists, "Coding Project and Sort stay in the ⋯")
        XCTAssertFalse(app.buttons["Pins Stay in Project"].exists, "Pins Stay in Project moved to the page")
        shot(app, "PS0-menu")
        settings.tap()
        XCTAssertTrue(app.navigationBars["Website"].waitForExistence(timeout: 8), "the sheet is titled with the project's name")
        let keep = app.switches["sessions.projectSettings.keep"], pins = app.switches["sessions.projectPage.localPins"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5) && pins.exists, "Chats: Keep Chats in This Project, Pins Stay in Project")
        let keepHelp = "Its chats leave Recent and Pinned. Chats that need you still show in New for You. To keep a shortcut under a bot, choose Show Under in the chat’s menu."
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", keepHelp)).firstMatch.exists)
        XCTAssertTrue(projectSetting(app, "sessions.projectSettings.autoDone").exists, "Move Quiet Chats to Done")
        XCTAssertTrue(app.staticTexts["Only on this page. Nothing is archived."].exists)
        shot(app, "PS0-page-top")
        XCTAssertTrue(projectSetting(app, "sessions.projectSettings.notify").exists, "Notifications")
        XCTAssertTrue(projectSetting(app, "sessions.projectSettings.model").exists, "New Chats: Model")
        XCTAssertTrue(projectSetting(app, "sessions.projectSettings.reasoning").exists, "New Chats: Reasoning")
        XCTAssertTrue(projectSetting(app, "sessions.projectSettings.emoji").exists, "Look: Icon")
        XCTAssertTrue(projectSetting(app, "sessions.projectSettings.color.0").exists, "Look: Color")
        XCTAssertFalse(app.switches["sessions.projectSettings.branchRows"].exists, "Show Branch on Rows is a coding project's")
        XCTAssertFalse(app.switches["sessions.projectSettings.autoDoneMerged"].exists, "When the Pull Request Merges is a coding project's")
        shot(app, "PS0-page-bottom")
        app.swipeDown(velocity: .fast)
        // Live: flipped, closed, opened again, it is still on.
        flipProjectSwitch(app, "sessions.projectSettings.keep", to: true)
        closeProjectSettings(app)
        openProjectSettings(app)
        XCTAssertEqual(app.switches["sessions.projectSettings.keep"].value as? String, "1", "kept without a Save button")
        flipProjectSwitch(app, "sessions.projectSettings.keep", to: false)
        closeProjectSettings(app)
        // A coding project: its two extra rows.
        more.tap()
        let coding = app.buttons["Coding Project"].firstMatch
        XCTAssertTrue(coding.waitForExistence(timeout: 5))
        coding.tap()
        // [coding-pr-review] Website's chats have no pull request, and a state at zero is not drawn (owner 2026-11-21):
        // the coding-only rows below say it is a coding project now.
        Thread.sleep(forTimeInterval: 1)
        openProjectSettings(app)
        XCTAssertTrue(app.switches["sessions.projectSettings.autoDoneMerged"].waitForExistence(timeout: 5), "Website is a coding project: When the Pull Request Merges")
        XCTAssertTrue(projectSetting(app, "sessions.projectSettings.branchRows").exists, "Show Branch on Rows")
        shot(app, "PS0-page-coding")
        closeProjectSettings(app)
        more.tap()
        XCTAssertTrue(coding.waitForExistence(timeout: 5))
        coding.tap()
    }

    // MARK: Step 1: Keep Chats in This Project

    /// Quarterly budget (Website's) is in Recent; with Keep Chats in This Project on it leaves the list and stays on
    /// Website's page; once it waits on the owner the New pill lists it; turned off, it is back in Recent.
    @MainActor func test40l_KeepChatsInProject() throws {
        let app = launch(projectPages: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        let toBots = app.buttons["sessions.pills.bots"]
        XCTAssertTrue(row(app, "s-budget").waitForExistence(timeout: 6), "Quarterly budget is in Recent")
        shot(app, "PS1-list-before")
        openWebsitePage(app)
        XCTAssertTrue(row(app, "s-budget").waitForExistence(timeout: 6), "Quarterly budget is Website's")
        openProjectSettings(app)
        flipProjectSwitch(app, "sessions.projectSettings.keep", to: true)
        shot(app, "PS1-setting-on")
        closeProjectSettings(app)
        XCTAssertTrue(row(app, "s-budget").exists, "still on its project's page")
        shot(app, "PS1-page-keeps-it")

        tapSide(app, toBots)
        XCTAssertTrue(waitUntil(6) { !app.cells["sessions.projectPage"].exists }, "back on the list")
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 6), "the other chats are listed")
        XCTAssertTrue(waitUntil(6) { !self.row(app, "s-budget").exists }, "Quarterly budget left Recent (\(order(app)))")
        shot(app, "PS1-list-without-it")
        // Unread alone does not count it under the New pill (it was the only unread chat: the pill is gone); waiting on
        // the owner does.
        let newPill = app.buttons["sessions.chip.status.new"]
        XCTAssertTrue(waitUntil(6) { !newPill.exists }, "a reply not read yet stays on the project's page: nothing under New")
        fixture("/__fixture/mode", ["live": ["s-budget": "waiting"]])
        fixture("/__fixture/rows", ["id": "s-budget", "set": ["title": "Quarterly budget"], "event": true])
        XCTAssertTrue(waitUntil(60) { newPill.exists }, "a chat that needs the owner counts under New")
        onScreen(app, newPill).tap()
        XCTAssertTrue(waitUntil(10) { self.row(app, "s-budget").exists }, "and the New pill lists it (\(order(app)))")
        shot(app, "PS1-new-pill-needs-you")
        onScreen(app, newPill).tap()
        fixture("/__fixture/mode", ["live": [:] as [String: String]])
        fixture("/__fixture/rows", ["id": "s-budget", "set": ["title": "Quarterly budget"], "event": true])

        // Off again: back in Recent.
        openWebsitePage(app)
        openProjectSettings(app)
        flipProjectSwitch(app, "sessions.projectSettings.keep", to: false)
        closeProjectSettings(app)
        tapSide(app, toBots)
        XCTAssertTrue(waitUntil(8) { self.row(app, "s-budget").exists }, "back in Recent (\(order(app)))")
        shot(app, "PS1-list-after-off")
    }

    /// Owner 2026-11-22 ("I don't believe the keep chats in this project feature is working"): with Chats Under Bots on,
    /// Quarterly budget (Website's) sat under its bot's row in Bots even with the project keeping its chats. Kept, it
    /// leaves there as it leaves Recent; turned off, it is back.
    @MainActor func test40l2_KeptChatsLeaveTheBotsRows() throws {
        let app = launch(projectPages: true, extra: ["-hq.bots.chatsUnder", "recent:5"])
        XCTAssertTrue(row(app, "s-budget").waitForExistence(timeout: 15), "Quarterly budget is in Recent")
        let bots = app.tabBars.buttons["Bots"], sessions = app.tabBars.buttons["Sessions"]
        let under = app.cells["bot-chat-s-budget"]
        bots.tap()
        XCTAssertTrue(under.waitForExistence(timeout: 10), "Quarterly budget is under its bot's row")
        shot(app, "PS1b-bots-before")

        sessions.tap()
        openWebsitePage(app)
        openProjectSettings(app)
        flipProjectSwitch(app, "sessions.projectSettings.keep", to: true)
        closeProjectSettings(app)
        bots.tap()
        XCTAssertTrue(waitUntil(8) { !under.exists }, "kept: Quarterly budget left its bot's row")
        shot(app, "PS1b-bots-kept")

        sessions.tap()
        openProjectSettings(app)
        flipProjectSwitch(app, "sessions.projectSettings.keep", to: false)
        closeProjectSettings(app)
        bots.tap()
        XCTAssertTrue(under.waitForExistence(timeout: 8), "off again: back under its bot's row")
    }

    /// One explicit shortcut with both project switches on and automatic bot rows off. No other chat follows it.
    @MainActor func testKeptChatShortcutUnderItsBotOnly() throws {
        let options = ["-hq.bots.chatsUnder", "off", "-hq.bots.pinnedLook", "faces"]
        let app = launch(projectPages: true, extra: options)
        XCTAssertTrue(row(app, "s-budget").waitForExistence(timeout: 20))
        openWebsitePage(app)
        openProjectSettings(app)
        flipProjectSwitch(app, "sessions.projectSettings.keep", to: true)
        flipProjectSwitch(app, "sessions.projectPage.localPins", to: true)
        closeProjectSettings(app)
        let budget = row(app, "s-budget")
        openMenu(app, budget, until: "Pin")
        let show = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show Under '")).firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 5), "a bot shortcut is separate from Pin")
        shot(app, "kept-chat-shortcut-menu")
        let bot = String(show.label.dropFirst("Show Under ".count))
        show.tap()
        XCTAssertFalse(header(app, "Pinned").exists, "not a project pin either")
        tapSide(app, app.buttons["sessions.pills.bots"])
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 8))
        XCTAssertFalse(budget.exists, "still out of Recent and Pinned")
        app.tabBars.buttons["Bots"].tap()
        let shortcut = app.cells["bot-chat-s-budget"]
        XCTAssertTrue(shortcut.waitForExistence(timeout: 10))
        XCTAssertEqual(app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'bot-chat-'")).count, 1)
        shot(app, "kept-chat-under-bot")
        shortcut.tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 15), "the shortcut opens the chat")
        XCTAssertTrue(app.tables["chat.table"].descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Draft the quarterly budget for four teams."))
            .firstMatch.waitForExistence(timeout: 15), "the project conversation, not the bot’s own chat")
        app.terminate()

        let again = launch(keepView: true, projectPages: true, extra: options)
        again.tabBars.buttons["Bots"].tap()
        let kept = again.cells["bot-chat-s-budget"]
        XCTAssertTrue(kept.waitForExistence(timeout: 15), "the choice survived relaunch")
        let owner = again.cells["bot-row-default"], face = again.cells["bot-tile-default"]
        openMenu(again, owner, until: "Pin")
        again.buttons["Pin"].firstMatch.tap()
        XCTAssertTrue(face.waitForExistence(timeout: 15) && owner.exists && kept.exists, "a pinned face keeps its shortcut under a labelled row")
        let remove = "Remove Shortcut Under " + bot
        openMenu(again, kept, until: remove)
        again.buttons[remove].firstMatch.tap()
        XCTAssertTrue(waitUntil(8) { !kept.exists }, "removing the last shortcut immediately clears this bot")
        XCTAssertTrue(face.exists && !owner.exists, "the pin is still a face; the extra row is gone")
        openMenu(again, face, until: "Unpin")
        again.buttons["Unpin"].firstMatch.tap()
        again.tabBars.buttons["Sessions"].tap()
        openWebsitePage(again)
        XCTAssertTrue(row(again, "s-budget").waitForExistence(timeout: 8), "removal left the project chat alone")
        XCTAssertFalse(writes("PATCH", "/api/sessions/s-budget").contains { $0["pinned"] != nil }, "no global pin write")
    }

    // MARK: Step 2: Move Quiet Chats to Done

    /// Website's page with a chat quiet for ten days: After 7 Days lists it in Done (closed, counted), nothing is
    /// written to the gateway, and Never brings it back to Active.
    @MainActor func test40m_QuietChatsMoveToDone() throws {
        let now = Date().timeIntervalSince1970
        fixture("/__fixture/rows", ["id": "s-stale", "set": ["profile": "default", "title": "Old sitemap", "cwd": "/home/hermes/site",
                                                            "last_active": now - 10 * 86_400, "unread": false]])
        fixture("/__fixture/rows", ["id": "s-copy", "set": ["profile": "default", "title": "Homepage copy", "cwd": "/home/hermes/site",
                                                           "last_active": now - 600, "unread": false]])
        let app = launch(projectPages: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openWebsitePage(app)
        XCTAssertTrue(row(app, "s-stale").waitForExistence(timeout: 8), "the old chat is in Active")
        XCTAssertFalse(headers(app).contains { $0.hasPrefix("Done") }, "no Done pile yet (\(headers(app)))")
        shot(app, "PS2-before")
        openProjectSettings(app)
        pickProjectSetting(app, "sessions.projectSettings.autoDone", "After 7 Days")
        shot(app, "PS2-setting")
        closeProjectSettings(app)
        XCTAssertTrue(waitUntil(8) { self.headers(app).last == "Done, 1" || (self.headers(app).last ?? "").hasPrefix("Done, 1") },
                      "Done holds the one old chat, closed (\(headers(app)))")
        XCTAssertFalse(row(app, "s-stale").exists, "out of Active")
        XCTAssertTrue(row(app, "s-copy").exists && row(app, "s-budget").exists, "the newer chats stay in Active")
        shot(app, "PS2-done-closed")
        let done = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'sessions.header' AND label BEGINSWITH 'Done'")).firstMatch
        done.tap()
        XCTAssertTrue(row(app, "s-stale").waitForExistence(timeout: 6), "Done, opened, lists it")
        XCTAssertFalse(labelOf(row(app, "s-stale")).contains("Archived"), "it is not archived (\(labelOf(row(app, "s-stale"))))")
        shot(app, "PS2-done-open")
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(writes("PATCH", "/api/sessions/s-stale").isEmpty, "nothing written to the gateway (\(writes("PATCH", "/api/sessions/s-stale")))")
        // Never: back in Active, no Done pile.
        openProjectSettings(app)
        pickProjectSetting(app, "sessions.projectSettings.autoDone", "Never")
        closeProjectSettings(app)
        XCTAssertTrue(waitUntil(8) { !self.headers(app).contains { $0.hasPrefix("Done") } && self.row(app, "s-stale").exists },
                      "back in Active (\(headers(app)))")
        shot(app, "PS2-never")
    }

    // MARK: Step 3: Notifications

    /// Website's Notifications: Mute names Website's chats (and no other project's) in the list this iPhone's alerts are
    /// checked against; Only When It Needs Me changes their level; a chat that appears in the project later joins once
    /// the list has seen it; All empties it. (What each level lets sound is unit-tested: no push reaches a simulator's
    /// notification extension.)
    @MainActor func test40n_ProjectNotifications() throws {
        guard Self.textOutFolder != nil else { throw XCTSkip("reads the app's text out (HQN_SHOTS_DIR)") }
        let now = Date().timeIntervalSince1970
        fixture("/__fixture/rows", ["id": "s-copy", "set": ["profile": "default", "title": "Homepage copy", "cwd": "/home/hermes/site",
                                                           "last_active": now - 600, "unread": false]])
        let app = launch(projectPages: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        func named() -> [String] {
            guard let folder = Self.textOutFolder,
                  let text = try? String(contentsOfFile: (folder as NSString).appendingPathComponent("project-mutes.txt"), encoding: .utf8) else { return [] }
            return text.split(separator: "\n").map(String.init)
        }
        openWebsitePage(app)
        openProjectSettings(app)
        XCTAssertTrue(projectSetting(app, "sessions.projectSettings.notify").label.contains("All"), "All until changed")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'New chats are included once this'")).firstMatch.exists,
                      "the footer says when new chats join")
        pickProjectSetting(app, "sessions.projectSettings.notify", "Mute")
        shot(app, "PS3-mute")
        XCTAssertTrue(waitUntil(8) { named() == ["s-budget=mute", "s-copy=mute"] }, "Website's chats are muted, no other project's (\(named()))")
        pickProjectSetting(app, "sessions.projectSettings.notify", "Only When It Needs Me")
        shot(app, "PS3-needs-me")
        XCTAssertTrue(waitUntil(8) { named() == ["s-budget=needsMe", "s-copy=needsMe"] }, "their level follows the setting (\(named()))")
        closeProjectSettings(app)
        // A chat made in the project elsewhere: in the list once this iPhone's Sessions list has it.
        fixture("/__fixture/rows", ["id": "s-late", "set": ["profile": "default", "title": "Made elsewhere", "cwd": "/home/hermes/site",
                                                           "last_active": now, "unread": false], "event": true])
        XCTAssertTrue(row(app, "s-late").waitForExistence(timeout: 20), "the new chat is listed")
        XCTAssertTrue(waitUntil(8) { named().contains("s-late=needsMe") }, "and joins the quieted chats (\(named()))")
        openProjectSettings(app)
        XCTAssertTrue(projectSetting(app, "sessions.projectSettings.notify").label.contains("Only When It Needs Me"), "kept")
        pickProjectSetting(app, "sessions.projectSettings.notify", "All")
        XCTAssertTrue(waitUntil(8) { named() == ["none"] }, "All: no chat is quieted (\(named()))")
        closeProjectSettings(app)
    }

    // MARK: Step 4: New Chats: Model and Reasoning

    /// With nothing chosen a project's New Chat sends `session.create` as before (no model, provider or reasoning).
    /// Project Settings › New Chats lists the default bot's models by provider (a provider not signed in is left out);
    /// with a model and High chosen, Compose's `session.create` carries the model, its provider and the level.
    @MainActor func test40o_ProjectNewChatModel() throws {
        let app = launch(projectPages: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openWebsitePage(app)
        let compose = app.buttons["sessions.compose"]
        func creates() -> [[String: Any]] { rpc("session.create").filter { $0["cwd"] as? String == "/home/hermes/site" } }
        compose.tap()
        XCTAssertTrue(waitUntil(10) { creates().count == 1 }, "session.create in Website's folder (\(rpc("session.create")))")
        let plain = creates()[0]
        XCTAssertTrue(plain["model"] == nil && plain["provider"] == nil && plain["reasoning_effort"] == nil,
                      "nothing chosen: nothing added (\(plain))")
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 10), "the new chat opens")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.cells["sessions.projectPage"].waitForExistence(timeout: 8), "back on Website's page")

        openProjectSettings(app)
        let model = projectSetting(app, "sessions.projectSettings.model")
        XCTAssertTrue(model.label.contains("Bot’s Default"), "Model: Bot’s Default (\(model.label))")
        XCTAssertTrue(projectSetting(app, "sessions.projectSettings.reasoning").label.contains("Bot’s Default"), "Reasoning: Bot’s Default")
        model.tap()
        let haiku = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'haiku'")).firstMatch
        XCTAssertTrue(haiku.waitForExistence(timeout: 10), "the default bot's models are listed")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sonnet'")).firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'signedout'")).firstMatch.exists, "a provider not signed in is left out")
        shot(app, "PS4-model-menu")
        haiku.tap()
        XCTAssertTrue(waitUntil(5) { self.projectSetting(app, "sessions.projectSettings.model").label.range(of: "haiku", options: .caseInsensitive) != nil },
                      "Model shows the pick (\(projectSetting(app, "sessions.projectSettings.model").label))")
        pickProjectSetting(app, "sessions.projectSettings.reasoning", "High")
        shot(app, "PS4-chosen")
        closeProjectSettings(app)

        compose.tap()
        XCTAssertTrue(waitUntil(10) { creates().count == 2 }, "a second session.create (\(rpc("session.create")))")
        let chosen = creates()[1]
        XCTAssertEqual(chosen["model"] as? String, "claude-haiku-5-5", "\(chosen)")
        XCTAssertEqual(chosen["provider"] as? String, "anthropic", "the model's provider goes with it")
        XCTAssertEqual(chosen["reasoning_effort"] as? String, "high")
        XCTAssertEqual(chosen["profile"] as? String, "default")
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 10), "the new chat opens")
        shot(app, "PS4-chat-open")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.cells["sessions.projectPage"].waitForExistence(timeout: 8))

        // Back to Bot’s Default: the next chat adds nothing again.
        openProjectSettings(app)
        pickProjectSetting(app, "sessions.projectSettings.model", "Bot’s Default")
        pickProjectSetting(app, "sessions.projectSettings.reasoning", "Bot’s Default")
        closeProjectSettings(app)
        compose.tap()
        XCTAssertTrue(waitUntil(10) { creates().count == 3 })
        let again = creates()[2]
        XCTAssertTrue(again["model"] == nil && again["provider"] == nil && again["reasoning_effort"] == nil, "Bot’s Default adds nothing (\(again))")
    }

    // MARK: Step 5: Look

    /// Website gets an emoji and a colour: its page's header draws them before its name, its pill carries the emoji,
    /// and so does its row under Group By Recent's Projects; cleared, the folder is back.
    @MainActor func test40p_ProjectLook() throws {
        let app = launch(projectPages: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openWebsitePage(app)
        XCTAssertFalse(app.descendants(matching: .any)["sessions.projectPage.look"].exists, "no mark before the name yet")
        shot(app, "PS5-before")
        openProjectSettings(app)
        let field = projectSetting(app, "sessions.projectSettings.emoji")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Look: Icon")
        focus(field)
        field.typeText("🚀🌊")
        XCTAssertTrue(waitUntil(4) { (field.value as? String) == "🌊" }, "one character: the last typed (\(String(describing: field.value)))")
        let teal = projectSetting(app, "sessions.projectSettings.color.6")
        XCTAssertTrue(teal.waitForExistence(timeout: 5), "Look: Color")
        teal.tap()
        XCTAssertTrue(waitUntil(4) { teal.isSelected }, "the colour is picked")
        XCTAssertEqual(teal.label, "Teal")
        shot(app, "PS5-setting")
        closeProjectSettings(app)
        XCTAssertTrue(app.descendants(matching: .any)["sessions.projectPage.look"].waitForExistence(timeout: 6), "the header draws the look before the name")
        XCTAssertTrue(app.buttons["sessions.chip.project.0"].isHittable, "the pill keeps its touch")
        XCTAssertGreaterThanOrEqual(app.buttons["sessions.chip.project.0"].frame.height, 43.5, "44 pt touch")
        shot(app, "PS5-page-and-pill")
        // The pill let go: the Projects side lists every project, Website's row with its emoji in the folder's place,
        // and its pill (not picked) carries it too.
        let pill = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.chip.project.' AND label BEGINSWITH 'Website project'")).firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "Website's pill")
        onScreen(app, pill).tap()
        XCTAssertTrue(waitUntil(6) { !app.cells["sessions.projectPage"].exists }, "the Projects side")
        Thread.sleep(forTimeInterval: 1.0)
        shot(app, "PS5-projects-side")
        onScreen(app, pill).tap()
        XCTAssertTrue(app.cells["sessions.projectPage"].waitForExistence(timeout: 6), "Website's page again")
        // Colour alone: the folder in that colour.
        openProjectSettings(app)
        let again = projectSetting(app, "sessions.projectSettings.emoji")
        let clear = projectSetting(app, "sessions.projectSettings.emojiClear")
        XCTAssertTrue(clear.waitForExistence(timeout: 5), "a set icon can be cleared")
        clear.tap()
        XCTAssertTrue(waitUntil(4) { ((again.value as? String) ?? "") != "🌊" }, "the emoji is cleared (\(String(describing: again.value)))")
        shot(app, "PS5-colour-only-setting")
        closeProjectSettings(app)
        XCTAssertTrue(app.descendants(matching: .any)["sessions.projectPage.look"].exists, "a colour alone still marks the header")
        shot(app, "PS5-colour-only")
        // None: back to the plain folder, nothing before the name.
        openProjectSettings(app)
        projectSetting(app, "sessions.projectSettings.color.none").tap()
        closeProjectSettings(app)
        XCTAssertTrue(waitUntil(6) { !app.descendants(matching: .any)["sessions.projectPage.look"].exists }, "cleared")
        shot(app, "PS5-cleared")
    }

    // MARK: Step 6: Show Branch on Rows

    /// A coding project's page: with Show Branch on Rows on, a chat with a branch starts its line with it and a chat
    /// without one is unchanged; off, no row names its branch. The switch is a coding project's alone.
    @MainActor func test40q_BranchOnRows() throws {
        let now = Date().timeIntervalSince1970
        fixture("/__fixture/rows", ["id": "s-copy", "set": ["profile": "default", "title": "Homepage copy", "cwd": "/home/hermes/site",
                                                           "last_active": now - 600, "unread": false, "git_branch": "feat/homepage-copy"]])
        fixture("/__fixture/rows", ["id": "s-long", "set": ["profile": "default", "title": "Long branch name", "cwd": "/home/hermes/site",
                                                           "last_active": now - 700, "unread": false,
                                                           "git_branch": "feat/a-very-long-branch-name-for-the-pricing-page-rewrite"]])
        fixture("/__fixture/rows", ["id": "s-plain", "set": ["profile": "default", "title": "No branch here", "cwd": "/home/hermes/site",
                                                            "last_active": now - 900, "unread": false]])
        let app = launch(projectPages: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openWebsitePage(app)
        // [coding-pr-review] No PR here, and a zero count is not drawn (2026-11-21): the settings say it is coding.
        setPageCoding(app, true)
        XCTAssertTrue(pageIsCoding(app), "Website is a coding project")
        let copy = row(app, "s-copy"), plain = row(app, "s-plain")
        XCTAssertTrue(copy.waitForExistence(timeout: 8) && plain.exists)
        XCTAssertFalse(labelOf(copy).contains("feat/homepage-copy"), "off by default (\(labelOf(copy)))")
        let plainBefore = labelOf(plain)
        shot(app, "PS6-off")
        openProjectSettings(app)
        flipProjectSwitch(app, "sessions.projectSettings.branchRows", to: true)
        shot(app, "PS6-setting")
        closeProjectSettings(app)
        XCTAssertTrue(waitUntil(8) { self.labelOf(copy).contains("Branch feat/homepage-copy") }, "the row starts with its branch (\(labelOf(copy)))")
        XCTAssertFalse(labelOf(plain).contains("Branch"), "a chat without a branch is unchanged (\(labelOf(plain)))")
        XCTAssertEqual(labelOf(plain), plainBefore)
        shot(app, "PS6-on")
        // Not a coding project any more: the rows are the usual ones and the switch is gone.
        app.buttons["sessions.projectPage.more"].tap()
        let coding = app.buttons["Coding Project"].firstMatch
        XCTAssertTrue(coding.waitForExistence(timeout: 5))
        coding.tap()
        XCTAssertTrue(waitUntil(8) { !self.labelOf(copy).contains("Branch feat/homepage-copy") }, "only in a coding project (\(labelOf(copy)))")
        openProjectSettings(app)
        XCTAssertFalse(app.switches["sessions.projectSettings.branchRows"].exists, "the switch is a coding project's")
        closeProjectSettings(app)
    }
}
