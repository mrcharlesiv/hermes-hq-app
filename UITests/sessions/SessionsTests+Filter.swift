// [sessions-m9] Filter and Sort, the Filter button, the strip and the empty state (docs/spec/3x-sessions.md §5, §6;
// acceptance A1-A10, B1-B4) and New Project… from the menu (§8; D1-D4), against scripts/fixtures/sessions-gateway.py.
// Run with scripts/e2e-sessions.sh <UDID> <PORT> (HQN_SESSIONS_ONLY="test20_SortByCreatedSurvivesRelaunch" for one).

import XCTest

extension SessionsTests {
    // MARK: - Sort By, Group By, Row Detail (L255)

    /// A1: Sort By › Created reorders two chats whose created and updated times disagree; a relaunch keeps it.
    @MainActor func test20_SortByCreatedSurvivesRelaunch() throws {
        setRow("s-recipes", ["started_at": nowSeconds - 30])            // made last, though untouched for three days
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        // [sessions-layout] The unread budget chat sits in New for You, on top whatever the sort.
        XCTAssertEqual(order(app), ["s-budget", "s-release", "s-garden", "s-trip", "s-recipes"], "by the last update")
        openFilter(app)
        XCTAssertTrue(filterWords(app, "sort").contains("Updated"), filterWords(app, "sort"))
        tapFilter(app, "sort", "sort.created")
        XCTAssertTrue(waitUntil(6) { Array(self.order(app).prefix(4)) == ["s-budget", "s-release", "s-recipes", "s-garden"] },
                      "the newest-made chat leads, under Pinned (\(order(app)))")
        XCTAssertTrue(waitUntil(4) { !self.filterItem(app, "sort").exists }, "one choice closes the menu")
        shot(app, "A1-sort-created")
        app.terminate()

        let again = launch(keepView: true)
        XCTAssertTrue(row(again, "s-recipes").waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(6) { Array(self.order(again).prefix(4)) == ["s-budget", "s-release", "s-recipes", "s-garden"] },
                      "the relaunch keeps Created (\(order(again)))")
        openFilter(again)
        XCTAssertTrue(filterWords(again, "sort").contains("Created"), filterWords(again, "sort"))
        tapFilter(again, "sort")
        XCTAssertTrue(filterItem(again, "sort.created").waitForExistence(timeout: 4))
        XCTAssertTrue(filterChecked(again, "sort.created"), "Created carries the check")
        XCTAssertFalse(filterChecked(again, "sort.updated"))
        shot(again, "A1-sort-menu")
    }

    /// Review finding: Sort By › Status ranks inside each date group; the date headers keep their order. (An unread
    /// chat from yesterday must not pull "Yesterday" above "Earlier today".)
    @MainActor func test35_SortByStatusKeepsTheDateHeadersInOrder() throws {
        setRow("s-trip", ["unread": true])                              // today's second chat is unread; s-budget (yesterday) too
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(8) { self.labelOf(self.row(app, "s-trip")).contains("Unread") })
        let byUpdate = headers(app)
        XCTAssertGreaterThanOrEqual(byUpdate.count, 3, "Pinned and at least two date groups (\(byUpdate))")
        // [sessions-layout] Both unread chats sit in New for You, newest first, whatever the sort; Sort By Status then
        // leaves the date groups as they were (the ranking inside a group: SessionListPipelineTests).
        XCTAssertEqual(order(app), ["s-trip", "s-budget", "s-release", "s-garden", "s-recipes"], "by the last update")
        openFilter(app)
        tapFilter(app, "sort", "sort.status")
        XCTAssertTrue(waitUntil(6) { self.order(app) == ["s-trip", "s-budget", "s-release", "s-garden", "s-recipes"] },
                      "no unread chat pulls its date group up (\(order(app)))")
        XCTAssertEqual(headers(app), byUpdate, "the date headers keep their order")
        shot(app, "A1-sort-status")
        openFilter(app)
        XCTAssertTrue(filterWords(app, "sort").contains("Status"), filterWords(app, "sort"))
        closeFilter(app)
    }

    /// A2: Sort By › Tokens is one run without date headers, Pinned still first; Group By then says "None". Cost is
    /// offered because chats report spend.
    @MainActor func test21_SortByTokensIsOneFlatRun() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        XCTAssertGreaterThan(headers(app).filter { $0 != "Pinned" }.count, 0, "date headers by default (\(headers(app)))")
        openFilter(app)
        tapFilter(app, "sort", "sort.tokens")
        XCTAssertTrue(waitUntil(6) { self.order(app) == ["s-release", "s-trip", "s-garden", "s-budget", "s-recipes"] },
                      "largest first under Pinned (\(order(app)))")
        XCTAssertEqual(headers(app), ["Pinned"], "no date headers")
        shot(app, "A2-sort-tokens")
        openFilter(app)
        XCTAssertTrue(filterWords(app, "group").contains("None"), "Group By says None (\(filterWords(app, "group")))")
        shot(app, "A2-group-none")
        tapFilter(app, "sort")
        XCTAssertTrue(filterItem(app, "sort.cost").waitForExistence(timeout: 4), "Cost is offered once a chat reports spend")
        tapFilter(app, "sort.cost")
        XCTAssertTrue(waitUntil(6) { self.order(app) == ["s-release", "s-trip", "s-garden", "s-budget", "s-recipes"] }, "\(order(app))")
        XCTAssertEqual(headers(app), ["Pinned"])
    }

    /// A3: Group By › Status draws "Working" and "Done"; a chat whose turn starts moves up by itself, and back once
    /// when the turn ends.
    @MainActor func test22_GroupByStatusFollowsARunningTurn() throws {
        fixture("/__fixture/mode", ["prompts": "hold"])
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openFilter(app)
        tapFilter(app, "group", "group.status")
        // [sessions-layout] The unread budget chat sits in New for You, above Pinned.
        XCTAssertTrue(waitUntil(6) { self.headers(app) == ["New for You", "Pinned", "Done"] }, "nothing runs yet (\(headers(app)))")
        openChat(app, "s-trip")
        type(app, "Add a fourth hotel", send: true)
        XCTAssertTrue(app.buttons["composer.stop"].waitForExistence(timeout: 8), "the turn runs")
        backToList(app)
        XCTAssertTrue(waitUntil(8) { self.headers(app) == ["New for You", "Pinned", "Working", "Done"] }, "Working shows (\(headers(app)))")
        XCTAssertEqual(Array(order(app).prefix(3)), ["s-budget", "s-release", "s-trip"], "the running chat is under Working")
        XCTAssertTrue(labelOf(row(app, "s-trip")).contains("Working"), labelOf(row(app, "s-trip")))
        shot(app, "A3-group-status-working")
        fixture("/__fixture/emit", ["type": "message.complete", "session_id": "s-trip", "payload": ["text": "Added the Ribeira Inn."]])
        XCTAssertTrue(waitUntil(8) { self.headers(app) == ["New for You", "Pinned", "Done"] }, "the turn ended: Done (\(headers(app)))")
        XCTAssertTrue(waitUntil(4) { !self.labelOf(self.row(app, "s-trip")).contains("Working") })
        shot(app, "A3-group-status-done")
    }

    /// A4: Group By › Project: one header per project, Home last; Group By never offers "Bot".
    @MainActor func test23_GroupByProject() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        // The projects are read when the menu first opens; Project is offered once they are known.
        var offered = false
        for _ in 0..<4 where !offered {
            openFilter(app)
            tapFilter(app, "group")
            offered = filterItem(app, "group.project").waitForExistence(timeout: 3)
            if !offered { closeFilter(app) }
        }
        XCTAssertTrue(offered, "Group By offers Project")
        XCTAssertTrue(filterItem(app, "group.date").exists && filterItem(app, "group.status").exists)
        // [manual-order] Two bots: Group By Bot is offered (tester, "sort by profile").
        XCTAssertTrue(filterItem(app, "group.bot").exists, "Group By Bot with a second bot")
        shot(app, "A4-group-menu")
        tapFilter(app, "group.project")
        // [sessions-layout] New for You and Pinned, then each project folded to its row (Website keeps its unread chat).
        XCTAssertTrue(waitUntil(6) { self.headers(app) == ["New for You", "Pinned", "App", "Reading", "Website", "Home"] },
                      "one header per project, by its newest chat, Home last (\(headers(app)))")
        XCTAssertEqual(order(app), ["s-budget", "s-release"], "the projects start folded")
        XCTAssertTrue((header(app, "Website").value as? String)?.contains("1 unread") == true, "Website counts its unread chat")
        shot(app, "A4-group-project")
        closeFilter(app)
        for project in ["App", "Reading", "Website", "Home"] { openProject(app, project) }
        // [project-cards] Website's one chat is in New for You and, opened, in Website too (a second row of its own).
        XCTAssertTrue(waitUntil(6) { self.order(app) == ["s-budget", "s-release", "s-garden", "s-trip", "also-s-budget", "s-recipes"] },
                      "each project opens in place (\(order(app)))")
        shot(app, "A4-group-project-open")
    }

    /// 2026-10-28 owner: "i also need a way to be able to edit the names of projects". A hold on a project's header
    /// offers Rename Project…; the name goes to every bot holding the folder (App: Hermes and Deploys). Home has none.
    @MainActor func test23c_RenameProjectFromItsHeader() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        var offered = false
        for _ in 0..<4 where !offered {
            openFilter(app)
            tapFilter(app, "group")
            offered = filterItem(app, "group.project").waitForExistence(timeout: 3)
            if !offered { closeFilter(app) }
        }
        XCTAssertTrue(offered, "Group By offers Project")
        tapFilter(app, "group.project")
        XCTAssertTrue(waitUntil(6) { self.headers(app).contains("App") }, "project headers (\(headers(app)))")
        closeFilter(app)
        let home = header(app, "Home")
        if home.waitForExistence(timeout: 3) {
            reveal(app, home)
            home.press(forDuration: 1.0)
            // [manual-order] Home's menu holds only the order rows; it goes with a tap on the dimmed list.
            XCTAssertTrue(app.buttons["Add to Favorites"].waitForExistence(timeout: 4), "Home's menu")
            XCTAssertFalse(app.buttons["Rename Project…"].exists, "Home can't be renamed")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.15)).tap()
            XCTAssertTrue(waitUntil(4) { !app.buttons["Add to Favorites"].exists }, "Home's menu closed")
        }
        let appHeader = header(app, "App")
        reveal(app, appHeader)
        appHeader.press(forDuration: 1.0)
        let rename = app.buttons["Rename Project…"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "the header's hold menu")
        XCTAssertTrue(app.buttons["New Chat"].exists, "and New Chat")
        shot(app, "project-header-menu")
        rename.tap()
        let field = app.textFields["project.rename"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.5)
        field.typeText("Mobile App")                     // the name starts selected: typing replaces it
        shot(app, "project-rename")
        let save = app.alerts["Rename Project"].buttons["Save"]
        XCTAssertTrue(waitUntil(3) { save.isEnabled }, "Save waits for a changed name")
        press(save)
        XCTAssertTrue(waitUntil(3) { !app.alerts["Rename Project"].exists }, "the alert closes on Save")
        XCTAssertTrue(waitUntil(8) {
            let sent = self.rpc("projects.update")
            return sent.contains { $0["profile"] as? String == "default" && $0["id"] as? String == "p_app" && $0["name"] as? String == "Mobile App" }
                && sent.contains { $0["profile"] as? String == "deploys" && $0["id"] as? String == "p_app" && $0["name"] as? String == "Mobile App" }
        }, "projects.update for both bots (\(rpc("projects.update")))")
        XCTAssertTrue(waitUntil(8) { self.headers(app).contains("Mobile App") && !self.headers(app).contains("App") },
                      "the header shows the new name (\(headers(app)))")
        shot(app, "project-renamed")
    }

    /// Delete Project…: a saved project's header hold › Delete Project… asks first, then `projects.delete`; the
    /// header goes. Home has no Delete.
    @MainActor func test23d_DeleteProjectFromItsHeader() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        var offered = false
        for _ in 0..<4 where !offered {
            openFilter(app)
            tapFilter(app, "group")
            offered = filterItem(app, "group.project").waitForExistence(timeout: 3)
            if !offered { closeFilter(app) }
        }
        XCTAssertTrue(offered, "Group By offers Project")
        tapFilter(app, "group.project")
        XCTAssertTrue(waitUntil(6) { self.headers(app).contains("Website") }, "project headers (\(headers(app)))")
        closeFilter(app)
        let home = header(app, "Home")
        if home.waitForExistence(timeout: 3) {
            reveal(app, home)
            home.press(forDuration: 1.0)
            // [manual-order] Home's menu holds only the order rows; it goes with a tap on the dimmed list.
            XCTAssertTrue(app.buttons["Add to Favorites"].waitForExistence(timeout: 4), "Home's menu")
            XCTAssertFalse(app.buttons["Delete Project…"].exists, "Home can't be deleted")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.15)).tap()
            XCTAssertTrue(waitUntil(4) { !app.buttons["Add to Favorites"].exists }, "Home's menu closed")
        }
        let site = header(app, "Website")
        reveal(app, site)
        site.press(forDuration: 1.0)
        let delete = app.buttons["Delete Project…"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "the header's hold menu")
        shot(app, "project-header-menu-delete")
        delete.tap()
        let alert = app.alerts["Delete “Website”?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3), "asked first")
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS 'kept'")).firstMatch.exists,
                      "says the chats and folder are kept")
        shot(app, "project-delete-confirm")
        XCTAssertTrue(rpc("projects.delete").isEmpty, "nothing deleted before the confirmation")
        press(alert.buttons["Delete Project"])
        XCTAssertTrue(waitUntil(8) {
            self.rpc("projects.delete").contains { $0["profile"] as? String == "default" && $0["id"] as? String == "p_site" }
        }, "projects.delete (\(rpc("projects.delete")))")
        XCTAssertTrue(waitUntil(8) { !self.headers(app).contains("Website") }, "the header goes (\(headers(app)))")
        shot(app, "project-deleted")
    }

    /// New chat inside a project: [project-cards] New Chat at the foot of an open project's card; its bot capsule asks
    /// which bot (Other Bots… offers every bot) and starts the chat in the project's folder; a folded project or Home
    /// shows none.
    @MainActor func test23b_NewChatFromAProjectHeader() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        var offered = false
        for _ in 0..<4 where !offered {
            openFilter(app)
            tapFilter(app, "group")
            offered = filterItem(app, "group.project").waitForExistence(timeout: 3)
            if !offered { closeFilter(app) }
        }
        XCTAssertTrue(offered, "Group By offers Project")
        tapFilter(app, "group.project")
        XCTAssertTrue(waitUntil(6) { self.headers(app).contains("Website") }, "project headers (\(headers(app)))")
        closeFilter(app)
        XCTAssertFalse(app.buttons["New Chat in Home"].exists, "a folded Home has no New Chat")
        XCTAssertFalse(app.buttons["New Chat in Website"].exists, "a folded project shows its time, not New Chat")
        openProject(app, "Website")                    // [project-cards] an open project's card ends with New Chat
        let plus = app.buttons["New Chat in Website"]
        reveal(app, plus)
        XCTAssertTrue(plus.waitForExistence(timeout: 5), "Website's New Chat")
        shot(app, "project-new-chat")
        app.buttons["sessions.project.newChatBot"].firstMatch.tap()
        // The bot's menu names the project's bots (Hermes, the one bot with Website) and Other Bots…, which offers every bot.
        let other = app.buttons["Other Bots…"]
        XCTAssertTrue(other.waitForExistence(timeout: 5), "New Chat's menu offers Other Bots…")
        XCTAssertTrue(menuBot(app, "Hermes").exists, "and the project's own bot")
        shot(app, "project-new-chat-menu")
        other.tap()
        let research = app.buttons["choose-bot-research"]
        XCTAssertTrue(research.waitForExistence(timeout: 5), "Choose a Bot offers Research")
        XCTAssertTrue(app.buttons["choose-bot-default"].exists && app.buttons["choose-bot-deploys"].exists, "and every other bot")
        shot(app, "project-choose-any-bot")
        research.tap()
        // Research has no Website: it is given the project first, then the chat starts in its folder.
        XCTAssertTrue(waitUntil(8) {
            self.rpc("projects.create").contains { $0["profile"] as? String == "research" && $0["name"] as? String == "Website"
                && ($0["folders"] as? [String]) == ["/home/hermes/site"] }
        }, "projects.create for Research (\(rpc("projects.create")))")
        XCTAssertTrue(waitUntil(8) {
            self.rpc("session.create").contains { $0["cwd"] as? String == "/home/hermes/site" && $0["cwd_explicit"] as? Bool == true
                && $0["profile"] as? String == "research" }
        }, "session.create in Website's folder (\(rpc("session.create")))")
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 10), "the new chat opens")
    }

    /// [project-cards] A bot in New Chat's menu (not the bot's chip, which has the same name).
    @MainActor func menuBot(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ AND NOT (identifier BEGINSWITH 'sessions.chip')", name)).firstMatch
    }

    /// One tap on New Chat starts the chat with the bot it shows, keys up; a bot that already has the project starts
    /// it with no projects.create.
    @MainActor func test23d_NewChatWithABotThatHasTheProject() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        var offered = false
        for _ in 0..<4 where !offered {
            openFilter(app)
            tapFilter(app, "group")
            offered = filterItem(app, "group.project").waitForExistence(timeout: 3)
            if !offered { closeFilter(app) }
        }
        tapFilter(app, "group.project")
        XCTAssertTrue(waitUntil(6) { self.headers(app).contains("Website") }, "project headers (\(headers(app)))")
        closeFilter(app)
        openProject(app, "Website")                    // [project-cards] New Chat's menu names Hermes
        let plus = app.buttons["New Chat in Website"]
        reveal(app, plus)
        plus.tap()
        XCTAssertTrue(waitUntil(8) {
            self.rpc("session.create").contains { $0["cwd"] as? String == "/home/hermes/site" && $0["profile"] as? String == "default" }
        }, "session.create in Website's folder")
        XCTAssertTrue(rpc("projects.create").isEmpty, "Hermes already has Website")
        let text = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 10), "the new chat opens")
        XCTAssertTrue(waitUntil(5) { (text.value(forKey: "hasKeyboardFocus") as? Bool) ?? false }, "ready to type")
    }

    /// New chat inside a project from a chat's menu: New Chat in <its project>, with the chat's bot.
    @MainActor func test23c_NewChatInAChatsProject() throws {
        let app = launch()
        let trip = row(app, "s-trip")
        XCTAssertTrue(trip.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(10) { self.rpc("projects.tree").contains { $0["profile"] as? String == "research" } }, "projects read with the list")
        openMenu(app, trip, until: "New Chat in Reading")
        shot(app, "menu-new-chat-in-project")
        app.buttons["New Chat in Reading"].firstMatch.tap()
        XCTAssertTrue(waitUntil(8) {
            self.rpc("session.create").contains { $0["cwd"] as? String == "/home/hermes/reading" && $0["profile"] as? String == "research" }
        }, "session.create in Reading's folder (\(rpc("session.create")))")
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 10), "the new chat opens")
    }

    /// A5: Row Detail › Tokens shows on the row while the menu is still open; the subtitle follows.
    @MainActor func test24_RowDetailIsLive() throws {
        let app = launch()
        let garden = row(app, "s-garden")
        XCTAssertTrue(garden.waitForExistence(timeout: 15))
        XCTAssertFalse(labelOf(garden).contains("tokens"), labelOf(garden))
        openFilter(app)
        XCTAssertTrue(filterWords(app, "detail").contains("Time, Preview"), filterWords(app, "detail"))
        tapFilter(app, "detail", "detail.tokens")
        XCTAssertTrue(filterItem(app, "detail.tokens").exists, "the menu stays open")
        XCTAssertTrue(waitUntil(4) { self.labelOf(garden).contains("1.2k tokens") }, "the row follows at once (\(labelOf(garden)))")
        XCTAssertTrue(filterChecked(app, "detail.tokens"), "its check shows")
        XCTAssertTrue(waitUntil(4) { self.submenuHeader(app, "Row Detail").contains("3 Selected") },
                      "the open submenu's own subtitle follows without stepping back (\(submenuHeader(app, "Row Detail")))")
        shot(app, "A5-detail-tokens-live")
        tapFilter(app, "detail.cost")
        XCTAssertTrue(waitUntil(4) { self.labelOf(garden).contains("$0.02") }, labelOf(garden))
        tapFilter(app, "detail.preview")
        XCTAssertTrue(waitUntil(4) { self.labelOf(garden).contains("main · hermes-4 · 2 messages") },
                      "Preview off: the metadata (\(labelOf(garden)))")
        closeFilter(app)
        shot(app, "A5-detail-figures")
        openFilter(app)
        XCTAssertTrue(filterWords(app, "detail").contains("3 Selected"), "Time, Tokens, Cost (\(filterWords(app, "detail")))")
    }

    // MARK: - Status, Project, All Bots, Show (L256)

    /// A6, B1: Status › Unread narrows the list with the menu open, fills the button and shows the strip; a second
    /// status makes it "Working · Unread". Background Runs alone fills nothing.
    @MainActor func test25_StatusFilterIsLiveAndNamesItself() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        let button = app.buttons["sessions.filter"]
        XCTAssertEqual(button.label, "Filter and Sort")
        XCTAssertFalse(strip(app).exists, "no strip without a filter")
        openFilter(app)
        tapFilter(app, "show", "runs")
        closeFilter(app)
        XCTAssertTrue(row(app, "s-run").waitForExistence(timeout: 6), "Background Runs shows the run")
        XCTAssertEqual(button.label, "Filter and Sort", "Background Runs is not a filter")
        XCTAssertFalse(strip(app).exists)
        shot(app, "B1-runs-not-a-filter")

        openFilter(app)
        XCTAssertTrue(filterWords(app, "status").contains("Any"), filterWords(app, "status"))
        tapFilter(app, "status", "status.unread")
        XCTAssertTrue(filterItem(app, "status.unread").exists, "the menu stays open")
        XCTAssertTrue(waitUntil(6) { self.order(app) == ["s-budget"] }, "only the unread chat, behind the open menu (\(order(app)))")
        XCTAssertTrue(strip(app).waitForExistence(timeout: 4), "the strip shows")
        XCTAssertEqual(strip(app).label, "Showing Unread. Clear Filters")
        XCTAssertTrue(waitUntil(4) { self.submenuHeader(app, "Status").contains("Unread") },
                      "Status's subtitle follows while its menu is open (\(submenuHeader(app, "Status")))")
        shot(app, "A6-status-unread-live")
        tapFilter(app, "status.working")
        XCTAssertTrue(waitUntil(4) { self.strip(app).label == "Showing Working · Unread. Clear Filters" }, strip(app).label)
        XCTAssertTrue(waitUntil(4) { self.submenuHeader(app, "Status").contains("Working, Unread") },
                      "and names both (\(submenuHeader(app, "Status")))")
        closeFilter(app)
        XCTAssertEqual(button.label, "Filter and Sort, 2 filters on")
        XCTAssertEqual(button.value as? String, "Working · Unread")
        shot(app, "B1-button-filled")
        openFilter(app)
        XCTAssertTrue(filterWords(app, "status").contains("Working, Unread"), filterWords(app, "status"))
        tapFilter(app, "status", "status.working")
        closeFilter(app)
        XCTAssertEqual(button.label, "Filter and Sort, 1 filter on")
        XCTAssertEqual(button.value as? String, "Unread")
        shot(app, "A6-strip-unread")
    }

    /// A7: Project narrows the list; All Bots off lights the Hermes chip; Show › Archived adds the archived chats.
    @MainActor func test26_ProjectAllBotsAndArchived() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        // Project: read at the first open, listed at the next.
        var listed = false
        for _ in 0..<4 where !listed {
            openFilter(app)
            tapFilter(app, "project")
            listed = filterItem(app, "project.0").waitForExistence(timeout: 3)
            if !listed { closeFilter(app) }
        }
        XCTAssertTrue(listed, "Project lists the projects")
        XCTAssertTrue(filterItem(app, "project.new").exists, "then New Project…")
        shot(app, "A7-project-menu")
        let website = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.filter.project.' AND label == 'Website'")).firstMatch
        XCTAssertTrue(website.exists, "Website is listed by the name its user gave it")
        website.tap()
        XCTAssertTrue(waitUntil(6) { self.order(app) == ["s-budget"] }, "only Website's chat (\(order(app)))")
        XCTAssertEqual(strip(app).label, "Showing Project. Clear Filters")
        closeFilter(app)
        XCTAssertEqual(app.buttons["sessions.filter"].value as? String, "Website", "the button's value names the project")
        shot(app, "A7-project-filter")
        strip(app).tap()
        XCTAssertTrue(waitUntil(6) { self.order(app).count == 5 }, "the strip clears it (\(order(app)))")

        // All Bots: a second handle on the chips.
        openFilter(app)
        XCTAssertTrue(filterChecked(app, "allbots"), "All Bots is on while no chip is picked")
        tapFilter(app, "allbots")
        XCTAssertTrue(waitUntil(6) { self.order(app) == ["s-budget", "s-garden"] }, "only Hermes's chats (\(order(app)))")
        closeFilter(app)
        XCTAssertTrue(chip(app, "default").isSelected, "the Hermes chip lights")
        XCTAssertFalse(chip(app, nil).isSelected)
        shot(app, "A7-allbots-off")
        openFilter(app)
        XCTAssertFalse(filterChecked(app, "allbots"))
        tapFilter(app, "allbots")
        closeFilter(app)
        XCTAssertTrue(waitUntil(6) { self.order(app).count == 5 })
        XCTAssertTrue(chip(app, nil).isSelected)

        // Show › Archived: the archived chats join the rest (2026-10-24: Show's checks add rows).
        openFilter(app)
        XCTAssertTrue(filterWords(app, "show").contains("Chats"), filterWords(app, "show"))
        tapFilter(app, "show", "archived")
        XCTAssertTrue(waitUntil(8) { self.order(app).count == 6 && self.order(app).contains("s-old") }, "added to the list (\(order(app)))")
        closeFilter(app)
        XCTAssertFalse(strip(app).exists, "not a filter: no strip")
        XCTAssertEqual(app.buttons["sessions.filter"].label, "Filter and Sort", "nor counted on the button")
        XCTAssertFalse(headers(app).isEmpty, "still grouped by date")
        XCTAssertTrue(labelOf(row(app, "s-old")).contains("Archived"), labelOf(row(app, "s-old")))
        shot(app, "A7-archived")
        openFilter(app)
        XCTAssertTrue(filterWords(app, "show").contains("Archived"), filterWords(app, "show"))
    }

    /// [tester batch 3] Show's subtitle names every check that is on, in the menu's order: one by its row's title, two
    /// or three by their first words ("Outside, Background, Archived"; all three read "Runs, Archived" before). Said
    /// while the submenu is open and on the Show row after it closes. HQN_SESSIONS_DARK=1 for the dark screenshots.
    @MainActor func test26b_ShowNamesEachCheck() throws {
        showNamesEachCheck(launch(), "show")
    }

    /// The same under Desktop Look, and at the largest text size, where the subtitle must not be cut short.
    @MainActor func test26c_ShowNamesEachCheckDesktopLookAndLargestText() throws {
        showNamesEachCheck(launch(extra: ["-HQDebugDesktopLook", "YES"]), "show-desktop")
        showNamesEachCheck(launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]), "show-ax")
    }

    @MainActor private func showNamesEachCheck(_ app: XCUIApplication, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        // The list is in: any row (at the largest text size on an iPhone SE the pinned row alone fills the screen).
        XCTAssertTrue(app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'session-row-'")).firstMatch
            .waitForExistence(timeout: 15), "the list", file: file, line: line)
        // Some element says exactly these words: each name in them, no other check's. (`submenuHeader` joins every
        // element whose label starts "Show" with " ; ".)
        func says(_ said: @escaping () -> String, _ words: String, _ why: String) {
            let others = ["Outside", "Background", "Runs", "Archived"].filter { !words.contains($0) }
            XCTAssertTrue(waitUntil(5) {
                said().components(separatedBy: " ; ").contains { text in text.contains(words) && !others.contains { text.contains($0) } }
            }, "\(why): \(words) (\(said()))", file: file, line: line)
        }
        let row = { self.filterWords(app, "show") }
        // The submenu's header, scrolled back into the window first: a tap on a row low in a submenu that scrolls
        // takes the header out of the tree.
        func heard(_ words: String, _ why: String) {
            revealShowHeader(app)
            says({ self.submenuHeader(app, "Show") }, words, why)
        }
        // Each element is brought into the menu's window first: at the largest text sizes the menu and the submenu
        // scroll, and a row outside the window isn't in the tree.
        func tap(_ keys: String...) {
            for key in keys {
                revealFilter(app, key)
                tapFilter(app, key, file: file, line: line)
            }
        }
        openFilter(app, file: file, line: line)
        revealFilter(app, "show")
        says(row, "Chats", "none on")
        tap("show", "outside")
        heard("Outside Chats", "one on: its row's title")
        tap("runs")
        heard("Outside, Background", "two: first words, the menu's order")
        tap("archived")
        let checked = ["outside", "runs", "archived"].map { key in
            revealFilter(app, key)
            return filterChecked(app, key)
        }
        XCTAssertEqual(checked, [true, true, true], "all three checked", file: file, line: line)
        heard("Outside, Background, Archived", "all three")
        shot(app, "\(name)-submenu-all")
        closeFilter(app, file: file, line: line)
        XCTAssertEqual(app.buttons["sessions.filter"].label, "Filter and Sort", "none of them is a filter", file: file, line: line)
        openFilter(app, file: file, line: line)
        // On to the menu's end where it scrolls, so the shot holds the whole Show row.
        if revealFilter(app, "show") { app.swipeUp() }
        says(row, "Outside, Background, Archived", "the Show row after the submenu closed")
        shot(app, "\(name)-menu-all")
        // Off again: the other two, then one by its title, then none.
        tap("show", "outside")
        heard("Background, Archived", "outside off")
        tap("archived")
        heard("Background Runs", "only runs")
        tap("runs")
        heard("Chats", "none on again")
        closeFilter(app, file: file, line: line)
    }

    /// At the largest text sizes the menu, and the submenu over it, scroll, and a row outside the window isn't in the
    /// tree until it scrolls in, nor pressable while it is only partly in: flicks up, then down, until it is in. True
    /// when it had to scroll. (The menu covers the middle of the screen at those sizes, where a flick starts. A row
    /// that shows once a submenu has opened is left alone: a drag across a menu that doesn't scroll would choose the
    /// row it ends on.)
    @discardableResult @MainActor private func revealFilter(_ app: XCUIApplication, _ key: String) -> Bool {
        let item = filterItem(app, key)
        func shown() -> Bool { item.exists && item.isHittable }
        if item.waitForExistence(timeout: 2), waitUntil(1, shown) { return false }
        for _ in 0..<4 where !shown() { app.swipeUp() }
        for _ in 0..<8 where !shown() { app.swipeDown() }
        return true
    }

    /// Scrolls an open Show submenu back to its top when its header has left the tree, and one flick past where it
    /// comes in, so all of the header is in the window. (Only a submenu that scrolls loses its header.)
    @MainActor private func revealShowHeader(_ app: XCUIApplication) {
        let header = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Show")).firstMatch
        if header.waitForExistence(timeout: 1) { return }
        for _ in 0..<6 where !header.exists { app.swipeDown() }
        app.swipeDown()
    }

    // MARK: - The end row (L257)

    /// A8: with a filter on the end row is Clear Filters; it clears status, project and the chip, not the sort.
    @MainActor func test27_ClearFiltersKeepsTheSort() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openFilter(app)
        XCTAssertTrue(filterItem(app, "readall").exists, "no filter: Mark All as Read")
        XCTAssertFalse(filterItem(app, "clear").exists)
        tapFilter(app, "sort", "sort.created")
        openFilter(app)
        tapFilter(app, "status", "status.unread")
        closeFilter(app)
        chip(app, "default").tap()
        XCTAssertTrue(waitUntil(6) { self.order(app) == ["s-budget"] }, "\(order(app))")
        openFilter(app)
        XCTAssertTrue(filterItem(app, "clear").exists, "a filter is on: Clear Filters")
        XCTAssertFalse(filterItem(app, "readall").exists, "it takes Mark All as Read's place")
        shot(app, "A8-clear-filters-row")
        tapFilter(app, "clear")
        closeFilter(app)
        XCTAssertTrue(waitUntil(6) { self.order(app).count == 5 }, "every chat is back (\(order(app)))")
        XCTAssertFalse(strip(app).exists)
        XCTAssertTrue(chip(app, nil).isSelected, "the chip is cleared too")
        XCTAssertEqual(app.buttons["sessions.filter"].label, "Filter and Sort")
        openFilter(app)
        XCTAssertTrue(filterWords(app, "sort").contains("Created"), "the sort stays (\(filterWords(app, "sort")))")
        XCTAssertTrue(filterWords(app, "status").contains("Any"))
        XCTAssertTrue(filterItem(app, "readall").exists)
        shot(app, "A8-cleared")
    }

    /// A9: Mark All as Read sends one `PATCH {"unread":false}` per server-unread chat (a hidden run included), clears
    /// the device-only dots, zeroes the tab's badge, and is disabled afterwards.
    @MainActor func test28_MarkAllAsRead() throws {
        setRow("s-trip", ["unread": true])
        setRow("s-run", ["unread": true])                      // a background run the list hides
        let app = launch()
        let recipes = row(app, "s-recipes")
        XCTAssertTrue(recipes.waitForExistence(timeout: 15))
        // New messages past what this phone has seen: unread on the device only.
        setRow("s-recipes", ["message_count": 9, "last_active": nowSeconds], event: true)
        XCTAssertTrue(waitUntil(15) { self.labelOf(recipes).contains("Unread") }, "a device-only dot (\(labelOf(recipes)))")
        XCTAssertTrue(labelOf(row(app, "s-budget")).contains("Unread") && labelOf(row(app, "s-trip")).contains("Unread"))
        XCTAssertFalse(sessionsBadge(app).isEmpty, "the tab carries a badge")
        shot(app, "A9-before")
        let before = unreadWrites().count
        openFilter(app)
        XCTAssertTrue(filterItem(app, "readall").isEnabled)
        tapFilter(app, "readall")
        XCTAssertTrue(waitUntil(8) { self.unreadWrites().count - before == 3 }, "three writes (\(unreadWrites().dropFirst(before)))")
        Thread.sleep(forTimeInterval: 1.0)
        let sent = unreadWrites().dropFirst(before)
        XCTAssertEqual(sent.map(\.path).sorted(), ["/api/sessions/s-budget", "/api/sessions/s-run", "/api/sessions/s-trip"],
                       "one per server-unread chat, none for the device-only one, none twice")
        XCTAssertTrue(sent.allSatisfy { !$0.unread })
        for id in ["s-budget", "s-trip", "s-recipes"] {
            XCTAssertTrue(waitUntil(5) { !self.labelOf(self.row(app, id)).contains("Unread") }, "\(id) reads as read (\(labelOf(row(app, id))))")
        }
        XCTAssertTrue(waitUntil(5) { self.sessionsBadge(app).isEmpty }, "the badge is gone (\(sessionsBadge(app)))")
        XCTAssertFalse(app.alerts.firstMatch.exists, "no confirmation, no alert")
        shot(app, "A9-after")
        openFilter(app)
        XCTAssertTrue(filterItem(app, "readall").exists)
        XCTAssertFalse(filterItem(app, "readall").isEnabled, "nothing unread: disabled")
        shot(app, "A9-disabled")
    }

    /// A10: two of five writes fail: "Couldn’t Mark All as Read" / "2 chats: …"; Try Again sends exactly those two.
    @MainActor func test29_MarkAllAsReadFailuresAndTryAgain() throws {
        for id in ["s-garden", "s-trip", "s-release", "s-recipes"] { setRow(id, ["unread": true]) }     // with s-budget: five
        fixture("/__fixture/fail", ["method": "PATCH", "path": "/api/sessions/s-trip", "status": 500, "detail": "The disk is full.", "count": 1])
        fixture("/__fixture/fail", ["method": "PATCH", "path": "/api/sessions/s-recipes", "status": 500, "detail": "The disk is full.", "count": 1])
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(6) { self.labelOf(self.row(app, "s-garden")).contains("Unread") })
        // [sessions-layout] Five unread: New for You draws three, then Show More.
        let more = app.cells["sessions.showMore"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 6), "Show More under New for You")
        more.tap()
        XCTAssertTrue(row(app, "s-recipes").waitForExistence(timeout: 5), "all five in New for You")
        openFilter(app)
        tapFilter(app, "readall")
        let alert = app.alerts["Couldn’t Mark All as Read"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "the failure is said once every write has answered")
        let reason = alert.staticTexts.allElementsBoundByIndex.map(\.label).first { $0.hasPrefix("2 chats: ") }
        XCTAssertNotNil(reason, "the reason counts the chats (\(alert.staticTexts.allElementsBoundByIndex.map(\.label)))")
        shot(app, "A10-alert")
        XCTAssertEqual(unreadWrites().count, 5, "five writes, one each")
        XCTAssertTrue(labelOf(row(app, "s-trip")).contains("Unread") && labelOf(row(app, "s-recipes")).contains("Unread"),
                      "the failed chats keep their mark")
        XCTAssertFalse(labelOf(row(app, "s-garden")).contains("Unread"))
        alert.buttons["Try Again"].tap()
        XCTAssertTrue(waitUntil(8) { self.unreadWrites().count == 7 }, "Try Again writes the two that failed (\(unreadWrites().count))")
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(unreadWrites().suffix(2).map(\.path).sorted(), ["/api/sessions/s-recipes", "/api/sessions/s-trip"])
        XCTAssertEqual(unreadWrites().count, 7, "and nothing else")
        XCTAssertTrue(waitUntil(5) { !self.labelOf(self.row(app, "s-trip")).contains("Unread") && !self.labelOf(self.row(app, "s-recipes")).contains("Unread") })
        XCTAssertFalse(app.alerts.firstMatch.exists)
        shot(app, "A10-after-retry")
    }

    // MARK: - The strip and the empty state (L259)

    /// B2, B3: the strip sits under the chips, stays put while the list scrolls, and its tap clears the filters but
    /// leaves a picked chip picked; a relaunch has it at the first paint.
    @MainActor func test30_StripStaysAndSurvivesRelaunch() throws {
        // Enough unread chats to scroll a full screen.
        for index in 0..<24 {
            setRow("s-more-\(index)", ["profile": index % 2 == 0 ? "default" : "research", "title": "Unread chat \(index)",
                                       "last_active": nowSeconds - Double(index) * 500 - 4000, "unread": true])
        }
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openFilter(app)
        tapFilter(app, "status", "status.unread")
        closeFilter(app)
        chip(app, "research").tap()
        let token = strip(app)
        XCTAssertTrue(token.waitForExistence(timeout: 4))
        let rail = app.descendants(matching: .any)["sessions.chips"]
        XCTAssertGreaterThan(token.frame.minY, chip(app, "research").frame.maxY - 1, "the strip is under the chips")
        XCTAssertTrue(waitUntil(6) { self.order(app).first == "s-more-1" }, "Research's unread chats (\(order(app).prefix(3)))")
        let stripFrame = token.frame, chipFrame = chip(app, "research").frame
        shot(app, "B2-strip-top")
        let list = app.collectionViews["sessions.list"]
        list.swipeUp(velocity: .fast)
        list.swipeUp(velocity: .fast)
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertFalse(row(app, "s-more-1").isHittable, "the list scrolled a full screen")
        XCTAssertEqual(token.frame, stripFrame, "the strip did not move")
        XCTAssertEqual(chip(app, "research").frame, chipFrame, "nor did the chips")
        XCTAssertTrue(rail.exists && token.isHittable)
        shot(app, "B2-strip-scrolled")
        token.tap()
        XCTAssertTrue(waitUntil(4) { !self.strip(app).exists }, "the tap clears the filters")
        XCTAssertTrue(chip(app, "research").isSelected, "the picked chip stays picked")
        for _ in 0..<4 { list.swipeDown(velocity: .fast) }                 // back to the top: Research's read chats lead
        XCTAssertTrue(waitUntil(6) { self.row(app, "s-trip").exists && !self.row(app, "s-garden").exists }, "still only Research (\(order(app)))")
        XCTAssertFalse(order(app).contains { $0.hasPrefix("s-more-") && (Int($0.dropFirst(7)) ?? 1) % 2 == 0 }, "none of Hermes's chats (\(order(app)))")
        shot(app, "B2-strip-cleared")

        // B3: left on, the filter names itself at the next launch's first paint (the cached rows).
        openFilter(app)
        tapFilter(app, "status", "status.unread")
        closeFilter(app)
        app.terminate()
        fixture("/__fixture/mode", ["sidebarDelay": 25])            // the network page is late: what shows is the cache
        let again = launch(keepView: true)
        XCTAssertTrue(strip(again).waitForExistence(timeout: 3), "the strip is there with the cached list")
        XCTAssertEqual(strip(again).label, "Showing Unread. Clear Filters")
        XCTAssertTrue(chip(again, nil).isSelected, "the chip is not kept: every launch opens on All")
        XCTAssertTrue(row(again, "s-more-0").exists, "cached rows, already narrowed (\(order(again).prefix(4)))")   // the newest unread chat
        XCTAssertFalse(row(again, "s-garden").exists)
        shot(again, "B3-relaunch-strip")
        fixture("/__fixture/mode", ["sidebarDelay": 0])
    }

    /// B4: a filter that matches nothing says "No Matching Chats"; its button brings the list back.
    @MainActor func test31_NoMatchingChats() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openFilter(app)
        tapFilter(app, "status", "status.needs-input")
        closeFilter(app)
        XCTAssertTrue(app.staticTexts["No Matching Chats"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No chats match these filters."].exists)
        XCTAssertEqual(order(app), [])
        shot(app, "B4-no-match")
        app.buttons["sessions.empty.clear"].tap()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 6), "Clear Filters brings the list back")
        XCTAssertFalse(strip(app).exists)
        // A chip whose bot has no chats.
        setRow("s-release", ["archived": true], event: true)
        XCTAssertTrue(waitUntil(15) { !self.row(app, "s-release").exists })
        chip(app, "deploys").tap()
        XCTAssertTrue(app.staticTexts["Deploys Has No Chats Yet"].waitForExistence(timeout: 5), "a chip alone can leave nothing")
        XCTAssertTrue(app.buttons["sessions.empty.compose"].exists, "and offers a new chat with that bot")
        shot(app, "B4-no-match-chip")
        app.buttons["sessions.empty.clear"].tap()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 6))
        XCTAssertTrue(chip(app, nil).isSelected)
    }

    // MARK: - New Project… (L261)

    /// D1, D3: Filter › Project › New Project… with a chip picked: one `projects.create` with exactly
    /// {name, folders, use:false, profile}, "Created Site", and Project then lists Site. A failing create says why and
    /// Try Again brings the typed words back.
    @MainActor func test32_NewProjectFromTheFilter() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        chip(app, "default").tap()
        fixture("/__fixture/fail", ["rpc": "projects.create", "message": "That folder is not on this computer.", "count": 1])
        openFilter(app)
        tapFilter(app, "project", "project.new")
        let alert = app.alerts["New Project"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "the New Project alert")
        let create = alert.buttons["Create"]
        XCTAssertFalse(create.isEnabled, "Create waits for a name")
        let name = alert.textFields["project.name"], folder = alert.textFields["project.folder"]
        fill(name, "Site")
        XCTAssertTrue(create.isEnabled, "a name is enough: the folder is optional")
        XCTAssertEqual(folder.placeholderValue, "~/Projects/site", "the empty folder says where it will go")
        fill(folder, "~/Projects/site")
        XCTAssertTrue(create.isEnabled)
        shot(app, "D1-new-project")
        press(create)
        let failed = app.alerts["Couldn’t Create Project"]
        XCTAssertTrue(failed.waitForExistence(timeout: 8), "the failure")
        XCTAssertTrue(failed.staticTexts["That folder is not on this computer."].exists)
        shot(app, "D3-create-failed")
        failed.buttons["Try Again"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Try Again reopens the alert")
        XCTAssertEqual(alert.textFields["project.name"].value as? String, "Site", "with the name as typed")
        XCTAssertEqual(alert.textFields["project.folder"].value as? String, "~/Projects/site", "and the folder")
        press(alert.buttons["Create"])
        XCTAssertTrue(app.descendants(matching: .any)["menus.hud"].waitForExistence(timeout: 6), "the HUD")
        XCTAssertTrue(app.staticTexts["Created Site"].exists, "it says Created Site")
        shot(app, "D1-created-hud")
        let calls = rpc("projects.create")
        XCTAssertEqual(calls.count, 2, "the failed call and the retry")
        let sent = try XCTUnwrap(calls.last)
        XCTAssertEqual(Set(sent.keys), ["name", "folders", "use", "profile"], "exactly these keys")
        XCTAssertEqual(sent["name"] as? String, "Site")
        XCTAssertEqual(sent["folders"] as? [String], ["~/Projects/site"])
        XCTAssertEqual(sent["use"] as? Bool, false)
        XCTAssertEqual(sent["profile"] as? String, "default", "the chip's bot")
        // The next open of Project lists it (not turned on as a filter).
        XCTAssertFalse(strip(app).exists)
        var listed = false
        for _ in 0..<4 where !listed {
            openFilter(app)
            tapFilter(app, "project")
            listed = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.filter.project.' AND label == 'Site'"))
                .firstMatch.waitForExistence(timeout: 3)
            if !listed { closeFilter(app) }
        }
        XCTAssertTrue(listed, "Project lists Site")
        shot(app, "D1-project-lists-site")
    }

    /// D2: under All with three bots, Choose a Bot comes first and the call carries that bot. Cancel changes nothing.
    @MainActor func test33_NewProjectChoosesABotUnderAll() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openFilter(app)
        tapFilter(app, "project", "project.new")
        let research = app.buttons["choose-bot-research"]
        XCTAssertTrue(research.waitForExistence(timeout: 5), "Choose a Bot comes first")
        shot(app, "D2-choose-bot")
        research.tap()
        let alert = app.alerts["New Project"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        press(alert.buttons["Cancel"])
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(rpc("projects.create").isEmpty, "Cancel sends nothing")
        openFilter(app)
        tapFilter(app, "project", "project.new")
        XCTAssertTrue(research.waitForExistence(timeout: 5))
        research.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        // 2026-10-28 owner: no folder to type. A name alone makes ~/Projects/<name> on the gateway's computer.
        fill(alert.textFields["project.name"], "Papers")
        XCTAssertTrue(alert.buttons["Create"].isEnabled, "a name is enough")
        shot(app, "D2-name-only")
        press(alert.buttons["Create"])
        let sent = waitUntil(8) { self.rpc("projects.create").count == 1 }
        if !sent { shot(app, "D2-create-not-sent") }
        XCTAssertTrue(sent, "one projects.create (\(rpc("projects.create")); alerts \(app.alerts.allElementsBoundByIndex.map(\.label)))")
        XCTAssertEqual(rpc("projects.create").first?["profile"] as? String, "research", "the chosen bot")
        XCTAssertEqual(rpc("projects.create").first?["folders"] as? [String], ["/home/hermes/Projects/papers"], "the folder the gateway made")
        XCTAssertTrue(app.staticTexts["Created Papers"].waitForExistence(timeout: 5))
    }

    /// D4: Move to Project › New Project… still creates the project, then moves the chat.
    @MainActor func test34_MoveToANewProject() throws {
        let app = launch()
        let garden = row(app, "s-garden")
        XCTAssertTrue(garden.waitForExistence(timeout: 15))
        openMenu(app, garden, until: "Move to Project")
        app.buttons["Move to Project"].firstMatch.tap()
        XCTAssertTrue(app.buttons["New Project…"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["New Project…"].firstMatch.tap()
        let alert = app.alerts["New Project"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        fill(alert.textFields["project.name"], "Beds")
        fill(alert.textFields["project.folder"], "~/beds")
        XCTAssertTrue(alert.buttons["Create"].isEnabled, "both fields are filled")
        press(alert.buttons["Create"])
        let sent = waitUntil(8) { self.rpc("projects.create").contains { $0["name"] as? String == "Beds" && $0["profile"] as? String == "default" } }
        if !sent { shot(app, "D4-create-not-sent") }
        XCTAssertTrue(sent, "projects.create for Beds (\(rpc("projects.create")); alerts \(app.alerts.allElementsBoundByIndex.map(\.label)))")
        XCTAssertTrue(waitUntil(20) { self.rpc("session.workspace.move").contains { $0["session_key"] as? String == "s-garden" && $0["cwd"] as? String == "~/beds" } },
                      "then the chat moves into it")
        shot(app, "D4-moved")
    }
}
