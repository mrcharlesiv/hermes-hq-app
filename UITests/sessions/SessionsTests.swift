// End-to-end tests of the Sessions tab's row actions and search (docs/parity-240.md §4) against the sessions fixture
// (scripts/fixtures/sessions-gateway.py). Run with scripts/e2e-sessions.sh: it starts the fixture on
// ${HQN_SESSIONS_PORT:-9820}, passes its credentials as TEST_RUNNER_HQN_UI_CREDENTIALS and stops it afterwards. Each
// test resets the fixture first (`/__fixture/reset`) and reads its request log (`/__fixture/state`) to check what the
// app wrote. TEST_RUNNER_HQN_SHOTS_DIR: screenshots are written there as `sessions-*.png` too.

import XCTest

final class SessionsTests: XCTestCase {
    var account: FixtureAccount!
    nonisolated(unsafe) static var freshThisRun = false
    /// [sessions-layout] This test's first launch clears the device's unread marks (a test's own relaunches keep them).
    var launchedThisTest = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        account = try FixtureAccount.load()
        try account.control("/__fixture/reset", [:])
    }

    // MARK: - Peek, swipes, Archive with Undo

    /// The first list with rows peeks its first row's trailing actions once per install.
    @MainActor func test01_SwipePeekPlaysOnce() throws {
        launch().terminate()                                    // signed in (a fresh run signs in first)
        clearTextOut()
        // The row rests open 20 seconds here (0.45 in the app), so a busy Mac's slow queries still catch it open.
        let app = launch(peek: true, extra: ["-HQDebugResetSwipePeek", "YES", "-HQDebugPeekHold", "20"])
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        let peek = app.otherElements["sessions.peek"]
        XCTAssertTrue(peek.waitForExistence(timeout: 15), "the first row peeks its More action")
        shot(app, "peek")
        XCTAssertTrue(waitUntil(40) { !peek.exists }, "the row slides back")
        if Self.textOutFolder != nil { XCTAssertEqual(textOut("peek.txt"), "played") }
        app.terminate()
        clearTextOut()
        let again = launch(peek: true, extra: ["-HQDebugPeekHold", "4"])
        XCTAssertTrue(row(again, "s-garden").waitForExistence(timeout: 15))
        XCTAssertFalse(again.descendants(matching: .any)["sessions.peek"].waitForExistence(timeout: 4), "only once per install")
        if let folder = Self.textOutFolder {
            XCTAssertFalse(FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent("peek.txt")), "not played again")
        }
    }

    /// Trailing swipe: More, Delete, Archive (Archive outermost, UX study #66). Archive asks nothing, shows "Archived · Undo" naming Filter and Sort › Show › Archived;
    /// Undo brings the row back. Both writes carry the owner.
    @MainActor func test02_ArchiveSwipeWithUndo() throws {
        let app = launch(extra: ["-HQDebugUndoSeconds", "60"])      // the pill outlasts a busy Mac's slow queries
        let garden = row(app, "s-garden")
        XCTAssertTrue(garden.waitForExistence(timeout: 15))
        shot(app, "list")
        swipe(garden, left: true)
        for title in ["Delete", "Archive", "More"] {
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 3), "trailing \(title)")
        }
        // UX study #66: Archive is outermost (the full swipe's), Delete inside it, More innermost.
        // Read inside the list: the tab bar has a "More" button too.
        let list = app.collectionViews["sessions.list"]
        XCTAssertGreaterThan(list.buttons["Archive"].frame.minX, list.buttons["Delete"].frame.minX, "Archive outermost")
        XCTAssertGreaterThan(list.buttons["Delete"].frame.minX, list.buttons["More"].frame.minX, "More innermost")
        shot(app, "swipe-trailing")
        app.buttons["Archive"].tap()
        let pill = app.descendants(matching: .any)["undo-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 3), "the Undo pill shows at the tap")
        let label = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Archived'")).firstMatch
        XCTAssertTrue(label.exists)
        XCTAssertTrue(label.label.contains("Filter and Sort › Show › Archived"), "it names the way back (\(label.label))")
        shot(app, "archive-undo-pill")
        XCTAssertTrue(waitUntil(5) { !garden.exists }, "the row leaves")
        XCTAssertTrue(waitUntil(5) { self.writes("PATCH", "/api/sessions/s-garden").contains { $0["archived"] as? Bool == true } })
        let patch = try XCTUnwrap(writes("PATCH", "/api/sessions/s-garden").first)
        XCTAssertEqual(patch["profile"] as? String, "default", "the owner travels in the body")
        app.buttons["undo-pill.undo"].tap()
        XCTAssertTrue(waitUntil(5) { self.writes("PATCH", "/api/sessions/s-garden").contains { $0["archived"] as? Bool == false } }, "Undo unarchives")
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 8), "the row is back")
    }

    /// Leading swipe: Unread/Read and Pin. Pin moves the row under Pinned; Unread marks it.
    @MainActor func test03_LeadingSwipeUnreadAndPin() throws {
        let app = launch()
        let trip = row(app, "s-trip")
        XCTAssertTrue(trip.waitForExistence(timeout: 15))
        swipe(trip, left: false)
        XCTAssertTrue(app.buttons["Mark as Unread"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Pin"].exists)
        shot(app, "swipe-leading")
        app.buttons["Mark as Unread"].tap()
        XCTAssertTrue(waitUntil(5) { self.writes("PATCH", "/api/sessions/s-trip").contains { $0["unread"] as? Bool == true } }, "unread:true sent")
        XCTAssertTrue(waitUntil(5) { labelOf(trip).contains("Unread") }, "the row reads Unread (\(labelOf(trip)))")
        swipe(trip, left: false)
        XCTAssertTrue(app.buttons["Pin"].waitForExistence(timeout: 3))
        app.buttons["Pin"].tap()
        XCTAssertTrue(waitUntil(5) { self.writes("PATCH", "/api/sessions/s-trip").contains { $0["pinned"] as? Bool == true } }, "pinned:true sent")
        XCTAssertTrue(waitUntil(5) { labelOf(trip).contains("Pinned") }, "the row reads Pinned (\(labelOf(trip)))")
        let header = app.staticTexts["Pinned"].firstMatch
        XCTAssertTrue(header.exists)
        XCTAssertLessThan(header.frame.minY, row(app, "s-garden").frame.minY, "Pinned comes first")
    }

    /// Delete asks with an action sheet, then the row goes and DELETE carries the owner.
    @MainActor func test04_DeleteAsksFirst() throws {
        let app = launch()
        let recipes = row(app, "s-recipes")
        XCTAssertTrue(recipes.waitForExistence(timeout: 15))
        swipe(recipes, left: true)
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 3))
        app.buttons["Delete"].tap()
        let confirm = app.buttons["Delete Chat"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "Delete asks")
        XCTAssertTrue(app.staticTexts["This chat and its history will be deleted from the computer running Hermes."].exists)
        shot(app, "delete-sheet")
        XCTAssertTrue(writes("DELETE", "/api/sessions/s-recipes", any: true).isEmpty, "nothing deleted before the answer")
        // A slow answer: the row dims with a spinner meanwhile.
        // (Twelve seconds, so a busy Mac's slow queries read the row while it is still there.)
        try account.control("/__fixture/fail", ["method": "DELETE", "path": "/api/sessions/s-recipes", "delay": 12])
        confirm.tap()
        XCTAssertTrue(waitUntil(6) { labelOf(recipes).contains("Deleting") }, "the row dims with a spinner")
        shot(app, "delete-busy")
        XCTAssertTrue(waitUntil(30) { !recipes.exists }, "the row closes up")
        let state = try account.control("/__fixture/state")
        let delete = (state["rest"] as? [[String: Any]] ?? []).first { $0["method"] as? String == "DELETE" }
        XCTAssertEqual((delete?["query"] as? [String: Any])?["profile"] as? String, "research")
    }

    // MARK: - The menu

    /// Long press: tiles Pin · Mark Unread · Share; Rename…, Branch in New Chat, Move to Project ›, More ›; Archive; Delete Chat.
    /// Rename sends the title; More › Color tags the row (VoiceOver "Color: Blue"); Copy Chat ID copies it.
    @MainActor func test05_MenuRenameColorCopy() throws {
        let app = launch()
        let trip = row(app, "s-trip")
        XCTAssertTrue(trip.waitForExistence(timeout: 15))
        openMenu(app, trip, until: "Rename…")
        XCTAssertTrue(app.buttons["Mark Unread"].firstMatch.exists || app.buttons["Mark Read"].firstMatch.exists, "the read tile")
        for title in ["Pin", "Share", "Branch in New Chat", "Move to Project", "More", "Archive", "Delete Chat"] {
            XCTAssertTrue(app.buttons[title].firstMatch.exists, "menu item \(title)")
        }
        shot(app, "menu")
        app.buttons["Rename…"].firstMatch.tap()
        let field = app.textFields["session.rename"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.5)
        field.typeText("Lisbon hotels")                    // the title starts selected: typing replaces it
        XCTAssertTrue(waitUntil(5) { app.buttons["Save"].isEnabled }, "Save takes the new title")
        app.buttons["Save"].tap()
        XCTAssertTrue(waitUntil(5) { self.writes("PATCH", "/api/sessions/s-trip").contains { $0["title"] as? String == "Lisbon hotels" } }, "title sent")
        XCTAssertTrue(waitUntil(5) { labelOf(trip).hasPrefix("Lisbon hotels") }, "the row shows it (\(labelOf(trip)))")

        openMenu(app, trip, until: "More")
        app.buttons["More"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Blue"].firstMatch.waitForExistence(timeout: 3), "the colour palette")
        XCTAssertTrue(app.buttons["No Color"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Export Chat"].firstMatch.exists)
        shot(app, "menu-more-color")
        app.buttons["Blue"].firstMatch.tap()
        XCTAssertTrue(waitUntil(5) { labelOf(trip).contains("Color: Blue") }, "the colour tag reads (\(labelOf(trip)))")
        shot(app, "color-tag")

        openMenu(app, trip, until: "More")
        app.buttons["More"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Copy Chat ID"].firstMatch.waitForExistence(timeout: 3))
        clearTextOut()
        app.buttons["Copy Chat ID"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["menus.hud"].waitForExistence(timeout: 3), "Copied HUD")
        if let copied = textOut("copy.txt") { XCTAssertEqual(copied, "s-trip") }
    }

    /// The long press and the More swipe open the same menu (no ⋯ on the row): a pull-down from the row's end, never the
    /// action sheet iOS 26 draws as a popover of glass capsules (owner 2026-10-30).
    @MainActor func test06_MoreSwipeOpensTheRowMenu() throws {
        let app = launch()
        let garden = row(app, "s-garden")
        XCTAssertTrue(garden.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["session-menu-s-garden"].exists, "no ⋯ on the row")
        openMenu(app, garden, until: "Rename…")
        shot(app, "menu-long-press")
        // Outside the menu, beside it (it opens up or down with the row's place on screen).
        let item = app.buttons["Rename…"].firstMatch.frame
        let side: CGFloat = item.maxX < app.frame.width * 0.8 ? 0.92 : 0.08
        app.coordinate(withNormalizedOffset: CGVector(dx: side, dy: item.midY / app.frame.height)).tap()
        XCTAssertTrue(waitUntil(3) { !app.buttons["Rename…"].firstMatch.exists })
        swipe(garden, left: true)
        shot(app, "swipe-for-more")
        // The swipe's More (the tab bar has a More too): the one on the row.
        let more = app.buttons.matching(NSPredicate(format: "label == 'More'")).allElementsBoundByIndex
            .first { abs($0.frame.midY - garden.frame.midY) < 30 }
        XCTAssertNotNil(more, "the swipe's More")
        more?.tap()
        XCTAssertTrue(app.buttons["Rename…"].firstMatch.waitForExistence(timeout: 4), "More opens the row's menu")
        shot(app, "more-swipe-menu")
        XCTAssertFalse(app.sheets.firstMatch.exists, "a menu, not an action sheet")
        XCTAssertFalse(app.buttons["Move to Project…"].firstMatch.exists, "Move to Project is the menu's submenu")
        // It grows from the row's trailing end, where More was (as the row's ⋯ pull-down did), the row pressed behind it.
        XCTAssertGreaterThan(app.buttons["Rename…"].firstMatch.frame.midX, garden.frame.midX, "from the row's trailing end")
        app.buttons["Move to Project"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Website"].firstMatch.waitForExistence(timeout: 5), "its submenu opens in place")
        app.buttons["Website"].firstMatch.tap()
        XCTAssertTrue(waitUntil(5) { self.rpc("session.workspace.move").contains { $0["session_key"] as? String == "s-garden" } })
    }

    /// Move to Project › lists the profile's projects (read on open) and moves the chat (session.workspace.move).
    @MainActor func test07_MoveToProject() throws {
        let app = launch()
        let garden = row(app, "s-garden")
        XCTAssertTrue(garden.waitForExistence(timeout: 15))
        openMenu(app, garden, until: "Move to Project")
        app.buttons["Move to Project"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Website"].firstMatch.waitForExistence(timeout: 5), "the projects")
        XCTAssertFalse(app.buttons["App"].firstMatch.exists, "not the chat's own project")
        XCTAssertTrue(app.buttons["New Project…"].firstMatch.exists)
        shot(app, "menu-move")
        app.buttons["Website"].firstMatch.tap()
        XCTAssertTrue(waitUntil(5) {
            self.rpc("session.workspace.move").contains { $0["cwd"] as? String == "/home/hermes/site" && $0["session_key"] as? String == "s-garden" }
        }, "moved into Website's folder")
    }

    /// Branch in New Chat: the gateway copies the chat (session.branch_stored) and the new chat opens.
    @MainActor func test08_BranchOpensTheNewChat() throws {
        let app = launch()
        let garden = row(app, "s-garden")
        XCTAssertTrue(garden.waitForExistence(timeout: 15))
        openMenu(app, garden, until: "Branch in New Chat")
        app.buttons["Branch in New Chat"].firstMatch.tap()
        XCTAssertTrue(waitUntil(5) { self.rpc("session.branch_stored").contains { $0["parent_session_id"] as? String == "s-garden" } })
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 8), "the branch opens")
        shot(app, "branch-open")
    }

    /// Share sends the whole chat as text; Export Chat hands over a .json file (UX study #73: was Export JSON).
    @MainActor func test09_ShareAndExport() throws {
        let app = launch()
        let garden = row(app, "s-garden")
        XCTAssertTrue(garden.waitForExistence(timeout: 15))
        clearTextOut()
        openMenu(app, garden, until: "Share")
        app.buttons["Share"].firstMatch.tap()
        if let text = textOut("share.txt") {
            XCTAssertTrue(text.hasPrefix("Garden plan"), text)
            XCTAssertTrue(text.contains("You:") && text.contains("Tomatoes along the south fence"), text)
        }
        XCTAssertTrue(waitUntil(6) { app.otherElements["ActivityListView"].exists || app.navigationBars["UIActivityContentView"].exists
            || app.buttons["Copy"].exists }, "the share sheet")
        shot(app, "share-sheet")
        dismissShareSheet(app)
        openMenu(app, garden, until: "More")
        app.buttons["More"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Export Chat"].firstMatch.waitForExistence(timeout: 3))
        app.buttons["Export Chat"].firstMatch.tap()
        if let export = textOut("export.txt") {
            XCTAssertTrue(export.hasPrefix("garden-plan-s-garden.json"), export)
            XCTAssertTrue(export.contains("\"session_id\" : \"s-garden\"") && export.contains("\"messages\""), export)
        }
        XCTAssertTrue(waitUntil(6) { app.otherElements["ActivityListView"].exists || app.buttons["Copy"].exists || app.buttons["Save to Files"].exists })
        dismissShareSheet(app)
    }

    // MARK: - Search and Filter

    /// The loaded rows match as you type; the gateway's hits follow with the match marked (a background run the list
    /// hides is still found).
    @MainActor func test10_SearchLocalAndServer() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        XCTAssertFalse(row(app, "s-run").exists, "background runs are hidden")
        XCTAssertFalse(app.searchFields.firstMatch.exists, "no search field until the magnifier opens it")
        for item in ["sessions.filter", "sessions.search", "sessions.compose"] {
            XCTAssertTrue(app.buttons[item].exists, "\(item) in the bar's capsule")
        }
        let filter = app.buttons["sessions.filter"].frame, magnifier = app.buttons["sessions.search"].frame,
            compose = app.buttons["sessions.compose"].frame
        XCTAssertTrue(filter.maxX <= magnifier.minX + 1 && magnifier.maxX <= compose.minX + 1, "Filter · Search · Compose, in that order")
        XCTAssertEqual(filter.midY, compose.midY, accuracy: 2, "one row, top right")
        shot(app, "bar-capsule")
        app.buttons["sessions.search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the magnifier unfolds the field")
        XCTAssertTrue(waitUntil(3) { app.keyboards.count > 0 }, "with the keyboard up")
        field.typeText("budget")
        let budget = row(app, "s-budget")
        XCTAssertTrue(budget.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(6) { !self.row(app, "s-garden").exists }, "others filtered out")
        XCTAssertTrue(waitUntil(6) { self.rest("GET", "/api/sessions/search").contains { ($0["query"] as? [String: Any])?["q"] as? String == "budget" } },
                      "the gateway is searched")
        shot(app, "search")
        // The query stays across tab changes (the keyboard put away first: it covers the tab bar).
        field.typeText("\n")
        XCTAssertTrue(waitUntil(3) { app.keyboards.count == 0 })
        app.tabBars.buttons["Bots"].tap()
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(budget.waitForExistence(timeout: 5), "the search is as it was left")
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "budget")
        XCTAssertFalse(row(app, "s-garden").exists)
        app.searchFields.firstMatch.tap()
        field.typeText(XCUIKeyboardKey.delete.rawValue + String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "index")
        let run = row(app, "s-run")
        XCTAssertTrue(run.waitForExistence(timeout: 8), "a hidden background run is found by the gateway")
        XCTAssertTrue(labelOf(run).contains("Rebuild the search index") || labelOf(run).contains("index"), labelOf(run))
        shot(app, "search-server-hit")
        // Cancel (iOS 26 draws it as a glass ✕) clears the field and folds it away.
        let cancel = app.buttons.matching(NSPredicate(format: "label IN {'Cancel', 'Close'} OR identifier IN {'Cancel', 'Close'}")).firstMatch
        if cancel.waitForExistence(timeout: 2) {
            cancel.tap()
        } else {
            app.searchFields.firstMatch.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "\n")
        }
        XCTAssertTrue(waitUntil(4) { !app.searchFields.firstMatch.exists }, "the field folds away")
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 4))
    }

    /// Compose: the New Chat sheet (the bots as pills, the projects as rows); a bot, then No Project, and a new chat
    /// in that bot (session.create) opens.
    @MainActor func test12_ComposeChoosesABotThenOpensANewChat() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        app.buttons["sessions.compose"].tap()
        let research = app.buttons["new-chat-bot-research"]
        XCTAssertTrue(research.waitForExistence(timeout: 4), "New Chat")
        XCTAssertTrue(app.buttons["new-chat-bot-default"].exists && app.buttons["new-chat-bot-deploys"].exists)
        XCTAssertTrue(app.buttons["new-chat-bot-default"].isSelected, "Hermes is lit until a bot has been used")
        XCTAssertTrue(app.staticTexts["Tap one to start the chat"].exists, "the heading says what a row does")
        shot(app, "compose-choose-bot")
        research.tap()
        XCTAssertTrue(waitUntil(3) { research.isSelected }, "a pill only lights its bot")
        app.buttons["new-chat-project-none"].tap()
        XCTAssertTrue(waitUntil(6) { self.rpc("session.create").contains { $0["profile"] as? String == "research" } }, "session.create in Research")
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 8), "the new chat opens")
        shot(app, "compose-new-chat")
    }

    /// Filter › Show › Archived adds the archived chats to the list, marked (2026-10-24: Show's checks add rows);
    /// Unarchive keeps the row and drops the mark.
    @MainActor func test11_FilterArchivedAndUnarchive() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        XCTAssertFalse(row(app, "s-old").exists)
        app.buttons["sessions.filter"].tap()
        let show = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show'")).firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 3))
        show.tap()
        XCTAssertTrue(app.buttons["Archived"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Background Runs"].firstMatch.exists)
        shot(app, "filter-menu")
        app.buttons["Archived"].firstMatch.tap()
        let old = row(app, "s-old")
        XCTAssertTrue(old.waitForExistence(timeout: 8), "the archived chat is listed")
        XCTAssertTrue(rest("GET", "/api/profiles/sessions").contains { ($0["query"] as? [String: Any])?["archived"] as? String == "only" })
        // Close the menu (the toggles keep it open).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        XCTAssertTrue(row(app, "s-garden").exists, "the other chats stay: Archived adds to the list")
        XCTAssertTrue(labelOf(old).contains("Archived"), "the archived chat says so (\(labelOf(old)))")
        XCTAssertFalse(labelOf(row(app, "s-garden")).contains("Archived"))
        XCTAssertFalse(strip(app).exists, "Archived is not a filter: no strip")
        shot(app, "filter-archived")
        // Dated with the rest, the old chat sits under the tab bar: its bot's chip brings it up to swipe.
        chip(app, "deploys").tap()
        XCTAssertTrue(waitUntil(6) { self.order(app).contains("s-old") && self.order(app).count == 2 }, "\(order(app))")
        shot(app, "filter-archived-marked")
        swipe(old, left: true)
        XCTAssertTrue(app.buttons["Unarchive"].waitForExistence(timeout: 3))
        app.buttons["Unarchive"].tap()
        XCTAssertTrue(waitUntil(5) { self.writes("PATCH", "/api/sessions/s-old").contains { $0["archived"] as? Bool == false } })
        XCTAssertTrue(waitUntil(8) { old.exists && !self.labelOf(old).contains("Archived") }, "it stays, no longer marked")
    }

    // MARK: - Helpers

    /// The run is in the dark appearance (HQN_SESSIONS_DARK=1): screenshots get a "-dark" suffix.
    static var dark: Bool { ProcessInfo.processInfo.environment["HQN_SESSIONS_DARK"] == "1" }

    /// `keepView`: a relaunch that must find Filter and Sort as it was left (every other launch starts from its
    /// defaults, so one test's filter never reaches the next).
    /// Every launch starts from the standard theme (a test's `-HQDebugDesktopLook YES` is applied after the reset), so
    /// the Desktop Look tests never leave the stored look to the tests after them. The "Know When a Bot Replies?" offer
    /// belongs to another feature's tests: answered already in these (on a fresh install it covered the first reply).
    @MainActor func launch(peek: Bool = false, fresh: Bool = false, keepView: Bool = false, drag: Bool = false,
                          extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HQDebugSessionsTab", "YES", "-HQDebugHUDSeconds", "5", "-HQDebugResetTheme", "YES",
                               "-dispatch.notifications.asked", "YES"] + extra
            + (peek ? [] : ["-HQDebugNoSwipePeek", "YES"]) + (Self.textOutFolder.map { ["-HQDebugTextOut", $0] } ?? [])
            + (keepView ? [] : ["-HQDebugResetSessionsView", "YES"]) + (Self.dark ? ["-HQDebugAppearance", "dark"] : [])
            + (drag ? [] : ["-HQDebugNoDrag", "YES"])
        if !launchedThisTest {
            launchedThisTest = true
            app.launchArguments += ["-HQDebugResetUnread", "YES"]
        }
        if fresh || !Self.freshThisRun {
            Self.freshThisRun = true
            app.launchArguments += ["-HQDebugResetAccounts", "YES"]
        }
        // The app's own alerts are the tests' to answer: without this, XCTest's default handler presses Cancel on one
        // whenever it judges (wrongly, under load) that the alert is in the way of its own field or button.
        _ = addUIInterruptionMonitor(withDescription: "the app's own alerts") { _ in true }
        app.launch()
        let list = app.collectionViews["sessions.list"]
        let form = app.textFields["sign-in-address"]
        _ = waitUntil(15) { list.exists || form.exists }
        if !list.exists && form.exists {
            signIn(app)
            let tab = app.tabBars.buttons["Sessions"]
            if tab.waitForExistence(timeout: 15) { tab.tap() }
        }
        XCTAssertTrue(list.waitForExistence(timeout: 15), "the Sessions list")
        return app
    }

    /// A tap, then a wait for the field to hold the keyboard: under load `typeText` ran before the focus had moved
    /// ("Neither element nor any descendant has keyboard focus"), which failed the first test of a run at sign-in.
    @MainActor func focus(_ field: XCUIElement) {
        for _ in 0..<4 {
            field.tap()
            if waitUntil(5, { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true }) { return }
        }
    }

    @MainActor func signIn(_ app: XCUIApplication) {
        let address = app.textFields["sign-in-address"]
        focus(address)
        if let current = address.value as? String, !current.isEmpty, current != "my-mac.tail1234.ts.net" {
            address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        address.typeText(account.url)
        let username = app.textFields["sign-in-username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        focus(username)
        if let current = username.value as? String, !current.isEmpty, current != "Username" {
            username.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        username.typeText(account.username)
        let password = app.secureTextFields["sign-in-password"]
        focus(password)
        password.typeText(account.password)
        app.buttons["sign-in-password-button"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let notNow = [app.buttons["Not Now"], springboard.buttons["Not Now"]]
        if waitUntil(5, { notNow.contains { $0.exists } }), let candidate = notNow.first(where: { $0.exists }) { candidate.tap() }
    }

    @MainActor func row(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.cells["session-row-\(id)"] }

    /// What VoiceOver reads for a row (its one element).
    @MainActor func labelOf(_ cell: XCUIElement) -> String {
        guard cell.exists else { return "" }
        let element = cell.descendants(matching: .any)
            .matching(NSPredicate(format: "label != '' AND NOT (identifier BEGINSWITH 'session-menu-')")).firstMatch
        return element.exists ? element.label : cell.label
    }

    /// A partial swipe that shows the actions without the full-swipe action.
    @MainActor func swipe(_ cell: XCUIElement, left: Bool) {
        let start = cell.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.85 : 0.15, dy: 0.5))
        let end = cell.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.35 : 0.65, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 0.4)
    }

    /// Long-presses until the menu shows `item` (a press during a reload can be lost).
    @MainActor func openMenu(_ app: XCUIApplication, _ cell: XCUIElement, until item: String) {
        for _ in 0..<3 {
            cell.press(forDuration: 1.0)
            if app.buttons[item].firstMatch.waitForExistence(timeout: 3) { return }
        }
        XCTFail("the row menu with \(item)")
    }

    @MainActor func dismissShareSheet(_ app: XCUIApplication) {
        for name in ["Close", "Cancel"] where app.buttons[name].firstMatch.exists {
            app.buttons[name].firstMatch.tap()
            Thread.sleep(forTimeInterval: 0.8)
            return
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        Thread.sleep(forTimeInterval: 0.8)
    }

    /// REST requests the fixture logged for a method and path.
    func rest(_ method: String, _ path: String) -> [[String: Any]] {
        let state = (try? account.control("/__fixture/state")) ?? [:]
        return (state["rest"] as? [[String: Any]] ?? []).filter { $0["method"] as? String == method && $0["path"] as? String == path }
    }

    /// The bodies of writes to a path (`any`: the requests themselves).
    func writes(_ method: String, _ path: String, any: Bool = false) -> [[String: Any]] {
        rest(method, path).map { any ? $0 : ($0["body"] as? [String: Any] ?? [:]) }
    }

    func rpc(_ method: String) -> [[String: Any]] {
        let state = (try? account.control("/__fixture/state")) ?? [:]
        return (state["rpc"] as? [[String: Any]] ?? []).filter { $0["method"] as? String == method }.map { $0["params"] as? [String: Any] ?? [:] }
    }

    static var textOutFolder: String? {
        guard let dir = ProcessInfo.processInfo.environment["HQN_SHOTS_DIR"], !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: dir).deletingLastPathComponent().appending(path: "ui-text-sessions").path
    }

    func clearTextOut() {
        guard let folder = Self.textOutFolder else { return }
        for name in ["share.txt", "copy.txt", "export.txt", "peek.txt"] { try? FileManager.default.removeItem(atPath: (folder as NSString).appendingPathComponent(name)) }
    }

    @MainActor func textOut(_ name: String) -> String? {
        guard let folder = Self.textOutFolder else { return nil }
        let path = (folder as NSString).appendingPathComponent(name)
        _ = waitUntil(6) { FileManager.default.fileExists(atPath: path) }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    @MainActor func shot(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.4)
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["HQN_SHOTS_DIR"], !dir.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir)
                .appendingPathComponent("sessions-\(name)\(Self.dark ? "-dark" : "").png"))
        }
    }

    @MainActor @discardableResult
    func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        return condition()
    }
}
