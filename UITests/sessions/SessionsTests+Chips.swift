// [sessions-m9] The bot chips rail and what is left of sessions-everything (docs/spec/3x-sessions.md §7; acceptance
// C1-C7), against scripts/fixtures/sessions-gateway.py.

import XCTest

extension SessionsTests {
    /// C1: two or more bots: All, Hermes, then the rest. One bot: no bot pills (All and New or Working may stay).
    @MainActor func test40_RailOrderAndNoRailForOneBot() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        let rail = app.scrollViews["sessions.chips"]
        XCTAssertTrue(rail.waitForExistence(timeout: 6), "the rail")
        XCTAssertEqual(rail.label, "Bots")
        // [switch-toggles] The Bots | Projects switch first (one button), then the bots.
        let chips = [pillSwitch(app)] + ["default", "research", "deploys"].map { app.buttons["sessions.chip.\($0)"] }
        XCTAssertTrue(chips.allSatisfy(\.exists), "the switch, Hermes, Research, Deploys")
        XCTAssertEqual(chips.map(\.label), ["Switch to Projects", "Hermes", "Research", "Deploys"])
        XCTAssertEqual(chips[0].value as? String, "Chats", "the switch says the view shown")      // [chats-switch]
        for (left, right) in zip(chips, chips.dropFirst()) {
            XCTAssertLessThan(left.frame.midX, right.frame.midX, "in that order")
        }
        XCTAssertTrue(nothingPicked(app), "nothing is picked at launch")
        // [sessions-layout] Pills: a 44 pt touch height around the 34 pt capsule (a frame reads 43.99999…).
        XCTAssertTrue(chips.allSatisfy { $0.frame.width >= 43.5 && $0.frame.height >= 43.5 }, "44 x 44 touch targets (\(chips.map(\.frame)))")
        // The rail ends where the list's first row begins or above it (the "Pinned" header sits between them).
        XCTAssertLessThanOrEqual(rail.frame.maxY, row(app, "s-release").frame.minY + 0.5,
                                 "the rail sits above the list (rail \(rail.frame), first row \(row(app, "s-release").frame))")
        shot(app, "C1-rail")
        // The status chips (New, Working) sit between All and the bots; the bot pills are one element each.
        // [projects-switch] Nor is the Bots | Projects switch at the rail's start a bot pill.
        let botPills = rail.buttons.matching(NSPredicate(format: "NOT (identifier BEGINSWITH %@) AND NOT (identifier BEGINSWITH %@)",
                                                         "sessions.chip.status.", "sessions.pills."))
        // [switch-scrolls] The switch is the rail's first item and scrolls with the pills. [switch-toggles] It is one
        // button, and no All beside it (the lit pill clears itself): the rail holds the three bots, each once.
        XCTAssertEqual(botPills.count, 3, "each chip is one element\n\(rail.debugDescription)")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.pills.'")).count, 1, "the switch is one element")
        XCTAssertFalse(app.buttons["sessions.chip.all"].exists, "no All beside the switch")
        app.terminate()

        fixture("/__fixture/mode", ["bots": 1])
        let alone = launch()
        XCTAssertTrue(row(alone, "s-garden").waitForExistence(timeout: 15))
        // [sessions-fresh] One bot: no bot pills. All stays only with New or Working chats beside it, to pick them.
        XCTAssertTrue(waitUntil(15) { !alone.buttons["sessions.chip.default"].exists }, "one bot: no bot pills")
        let status = alone.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sessions.chip.status."))
        XCTAssertTrue(!alone.buttons["sessions.chip.all"].exists || status.count > 0, "All only beside New or Working")
        let others = alone.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT (identifier BEGINSWITH %@) AND identifier != %@",
                                                        "sessions.chip.", "sessions.chip.status.", "sessions.chip.all"))
        XCTAssertEqual(others.count, 0, "no bot's pill")
        shot(alone, "C1-one-bot-no-rail")
        // Leave the next launch its three bots.
        fixture("/__fixture/mode", ["bots": 3])
        alone.terminate()
    }

    /// C2, C3: a chip narrows the list to its bot and lights; nothing else moves and no call goes out beyond sidebar
    /// reads. The lit chip shows every bot again.
    @MainActor func test41_ChipFiltersAndNothingElseMoves() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 2.0)                              // the launch's own calls are done
        let rpcBefore = rpcLog().count
        let restBefore = ((try? account.control("/__fixture/state")) ?? [:])["rest"] as? [[String: Any]] ?? []
        let deepBefore = sidebarReads().deep
        tapChip(app, "research")
        XCTAssertTrue(waitUntil(6) { self.order(app) == ["s-trip", "s-recipes"] }, "only Research's chats (\(order(app)))")
        XCTAssertTrue(chip(app, "research").isSelected, "its chip lights")
        XCTAssertFalse(nothingPicked(app))
        XCTAssertFalse(strip(app).exists, "a chip alone shows no strip")
        XCTAssertEqual(app.buttons["sessions.filter"].label, "Filter and Sort", "nor fills the button")
        shot(app, "C2-chip-research")
        Thread.sleep(forTimeInterval: 2.5)
        let sent = rpcLog().dropFirst(rpcBefore).map(\.method)
        XCTAssertEqual(sent, [], "no RPC goes out for a chip")
        let rest = (((try? account.control("/__fixture/state")) ?? [:])["rest"] as? [[String: Any]] ?? []).dropFirst(restBefore.count)
        XCTAssertTrue(rest.allSatisfy { $0["method"] as? String == "GET" }, "no write (\(rest.map { "\($0["method"] ?? "") \($0["path"] ?? "")" }))")
        XCTAssertLessThanOrEqual(sidebarReads().deep - deepBefore, 1, "at most the one deeper read")
        // The Bots tab is as it was: every bot, none picked out.
        app.tabBars.buttons["Bots"].tap()
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 6))
        for bot in ["default", "research", "deploys"] {
            XCTAssertTrue(app.cells["bot-row-\(bot)"].exists || app.cells["bot-tile-\(bot)"].exists, "\(bot) is still on Bots")
        }
        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(waitUntil(6) { self.order(app) == ["s-trip", "s-recipes"] }, "the pick survives leaving the tab")
        XCTAssertTrue(chip(app, "research").isSelected)
        // It survives opening a chat and coming back.
        openChat(app, "s-trip")
        backToList(app)
        XCTAssertTrue(chip(app, "research").isSelected, "and opening a chat")
        XCTAssertEqual(order(app), ["s-trip", "s-recipes"])

        // C3: the lit chip again shows every bot; so does another bot's lit chip.
        tapChip(app, "research")
        XCTAssertTrue(waitUntil(6) { self.order(app).count == 5 }, "the lit chip shows every bot again (\(order(app)))")
        XCTAssertTrue(nothingPicked(app))
        tapChip(app, "deploys")
        XCTAssertTrue(waitUntil(6) { self.order(app) == ["s-release"] }, "\(order(app))")
        shot(app, "C3-chip-deploys")
        tapChip(app, "deploys")
        XCTAssertTrue(waitUntil(6) { self.order(app).count == 5 }, "every bot again (\(order(app)))")
        XCTAssertTrue(nothingPicked(app) && !chip(app, "deploys").isSelected)
    }

    /// C4: the rail stays where it is while the list scrolls to its end and back.
    @MainActor func test42_RailStaysWhileTheListScrolls() throws {
        for index in 0..<30 {
            setRow("s-fill-\(index)", ["profile": ["default", "research", "deploys"][index % 3], "title": "Filler chat \(index)",
                                       "last_active": nowSeconds - Double(index) * 4000 - 9000])
        }
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        let rail = app.scrollViews["sessions.chips"]
        XCTAssertTrue(rail.waitForExistence(timeout: 6))
        let list = app.collectionViews["sessions.list"]
        list.swipeUp(velocity: .slow)                                    // the large title folds first
        Thread.sleep(forTimeInterval: 0.8)
        let folded = rail.frame, hermes = chip(app, "default").frame
        shot(app, "C4-rail-scrolled-once")
        for _ in 0..<6 { list.swipeUp(velocity: .fast) }
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertFalse(row(app, "s-garden").isHittable, "the list is far from its top")
        XCTAssertEqual(rail.frame, folded, "the rail did not move")
        XCTAssertEqual(chip(app, "default").frame, hermes)
        XCTAssertTrue(chip(app, "default").isHittable, "and still takes taps")
        // No row shows between the bar and the chips: the band above the faces is one colour, to the pixel.
        XCTAssertNil(oddPixel(app, from: rail.frame.minY - 4, to: pillSwitch(app).frame.minY - 0.5), "a row shows above the chips")
        shot(app, "C4-rail-at-the-end")
        for _ in 0..<8 { list.swipeDown(velocity: .fast) }
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(row(app, "s-release").isHittable, "back at the top")
        XCTAssertTrue(rail.exists && chip(app, "default").isHittable)
        XCTAssertEqual(rail.frame.height, folded.height, accuracy: 0.6, "the rail keeps its height")
        shot(app, "C4-rail-back-at-top")
    }

    /// C5, C6: a relaunch opens on All; Compose with a chip picked opens the New Chat sheet with that bot lit (tester
    /// a tester 2026-11-10), with All it opens the same sheet.
    @MainActor func test43_RelaunchOnAllAndComposeUsesTheChip() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        tapChip(app, "research")
        XCTAssertTrue(waitUntil(6) { self.order(app) == ["s-trip", "s-recipes"] })
        app.buttons["sessions.compose"].tap()
        let pill = app.buttons["new-chat-bot-research"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "New Chat")
        XCTAssertTrue(pill.isSelected, "Research is lit")
        shot(app, "C6-compose-with-chip-sheet")
        app.buttons["new-chat-start"].tap()
        XCTAssertTrue(waitUntil(8) { self.rpc("session.create").contains { $0["profile"] as? String == "research" } },
                      "a new Research chat")
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 8), "the new chat opens")
        shot(app, "C6-compose-with-chip")
        backToList(app)
        XCTAssertTrue(chip(app, "research").isSelected)
        tapChip(app, "research")
        app.buttons["sessions.compose"].tap()
        XCTAssertTrue(app.buttons["new-chat-bot-research"].waitForExistence(timeout: 5), "under All: the same sheet")
        shot(app, "C6-compose-under-all")
        app.terminate()

        // C5: the pick is not kept across launches.
        let picked = launch(keepView: true)
        XCTAssertTrue(row(picked, "s-garden").waitForExistence(timeout: 15))
        tapChip(picked, "deploys")
        XCTAssertTrue(waitUntil(6) { self.order(picked) == ["s-release"] })
        picked.terminate()
        let again = launch(keepView: true)
        XCTAssertTrue(row(again, "s-garden").waitForExistence(timeout: 15), "the list opens on every bot")
        XCTAssertTrue(nothingPicked(again), "nothing is picked")
        XCTAssertFalse(chip(again, "deploys").isSelected)
        XCTAssertTrue(row(again, "s-trip").exists && row(again, "s-release").exists)
        shot(again, "C5-relaunch-on-all")
    }

    /// C7: a bot's own chat is never a row: not in the list, not under its chip, not in a search, not in Archived.
    @MainActor func test44_NoRowForABotsOwnChat() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        let botChats = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'session-row-20261009_090000_bc'"))
        XCTAssertEqual(botChats.count, 0, "no bot chat row in the list")
        XCTAssertFalse(app.staticTexts["Bot Chat"].exists)
        tapChip(app, "default")
        XCTAssertTrue(waitUntil(6) { self.order(app) == ["s-budget", "s-garden"] }, "unread first, in New for You (\(order(app)))")
        XCTAssertEqual(botChats.count, 0, "nor under its chip")
        tapChip(app, "default")
        openFilter(app)
        tapFilter(app, "show", "runs")
        closeFilter(app)
        XCTAssertTrue(row(app, "s-run").waitForExistence(timeout: 6))
        XCTAssertEqual(botChats.count, 0, "nor with Background Runs on")
        openFilter(app)
        tapFilter(app, "show", "archived")
        closeFilter(app)
        XCTAssertTrue(row(app, "s-old").waitForExistence(timeout: 8))
        XCTAssertEqual(botChats.count, 0, "nor in Archived")
        shot(app, "C7-archived-no-bot-chat")
        XCTAssertTrue(row(app, "s-garden").exists, "Archived adds to the list")
        app.buttons["sessions.search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Morning")                                        // the bot chats' own words
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertEqual(botChats.count, 0, "nor in a search")
        XCTAssertFalse(app.staticTexts["Bot Chat"].exists)
        shot(app, "C7-search-no-bot-chat")
    }

    /// §7.4: while a query is typed the chip still applies and the strip is hidden; it returns with the list.
    @MainActor func test45_SearchHonoursTheChipAndHidesTheStrip() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        tapChip(app, "research")
        openFilter(app)
        tapFilter(app, "status", "status.idle")
        closeFilter(app)
        XCTAssertTrue(strip(app).waitForExistence(timeout: 4))
        app.buttons["sessions.search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("the")
        XCTAssertTrue(waitUntil(6) { !self.strip(app).exists }, "the strip hides while a query is typed")
        XCTAssertTrue(waitUntil(8) { self.rest("GET", "/api/sessions/search").contains { ($0["query"] as? [String: Any])?["profile"] as? String == "research" } },
                      "the gateway is asked for the chip's bot only")
        XCTAssertFalse(rest("GET", "/api/sessions/search").contains { ($0["query"] as? [String: Any])?["profile"] as? String == "default" })
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertFalse(row(app, "s-garden").exists || row(app, "s-budget").exists || row(app, "s-release").exists, "hits are Research's only (\(order(app)))")
        shot(app, "C-search-with-chip")
    }

    /// [project-pills] Owner 2026-11-15: "the pills at the top are the projects so that you can filter by project".
    /// Group By › Project swaps the bot pills for the projects (what needs you first); a project pill narrows the
    /// list to that project and lights, with no strip (the pill says it); the lit pill shows every project again.
    @MainActor func test40b_ProjectPills() throws {
        fixture("/__fixture/mode", ["working": ["s-trip"]])          // a turn at work in Reading
        defer { fixture("/__fixture/mode", ["working": [String]()]) }
        let app = launch(projectPages: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        // [projects-switch] One tap on the rail's switch is Group By › Project (the projects are read as
        // the list loads; the switch shows once they are known).
        let toProjects = app.buttons["sessions.pills.projects"], toBots = app.buttons["sessions.pills.bots"]
        XCTAssertTrue(toProjects.waitForExistence(timeout: 15), "the switch: both views side by side")
        XCTAssertEqual(toProjects.label, "Switch to Projects")
        XCTAssertEqual(toProjects.value as? String, "Chats")                                     // [chats-switch]
        XCTAssertTrue(nothingPicked(app) && !toBots.exists && !app.buttons["sessions.chip.all"].exists, "one switch, no All")
        shot(app, "P0-switch-bots")
        tapChip(app, "research")
        XCTAssertTrue(waitUntil(6) { !self.nothingPicked(app) && self.chip(app, "research").isSelected }, "a bot picked")
        app.scrollViews["sessions.chips"].swipeRight()     // the picked pill was centred, which can take the switch off
        XCTAssertTrue(waitUntil(4) { toProjects.isHittable })
        shot(app, "P0b-switch-bot-picked")
        // [switch-toggles] A tap anywhere on the switch flips the view: here on its lit (Bots) side, which had been All.
        toProjects.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        XCTAssertTrue(waitUntil(6) { toBots.exists && !toProjects.exists }, "the lit side flips it too")
        XCTAssertEqual(toBots.value as? String, "Projects")
        XCTAssertEqual(toBots.label, "Switch to Chats")                                          // [chats-switch]
        toBots.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()
        XCTAssertTrue(waitUntil(6) { toProjects.exists && !toBots.exists }, "and its lit (Projects) side flips it back")
        XCTAssertTrue(nothingPicked(app), "the bot picked before went with the view")
        // [chats-projects] A tester, 2026-11-20: the Chats side shows no project until Show › Projects is on (and Project
        // Chats in Recent is offered only then).
        let bySide = ["Website", "Reading", "App"].map { header(app, $0) }
        XCTAssertTrue(waitUntil(6) { self.headers(app).contains { $0.hasPrefix("Today") || $0.hasPrefix("Yesterday") } }, "\(headers(app))")
        XCTAssertFalse(bySide.contains(where: \.exists), "no project's row on the Chats side (\(headers(app)))")
        openFilter(app)
        tapFilter(app, "show")
        XCTAssertTrue(filterItem(app, "projects").waitForExistence(timeout: 5) && !filterItem(app, "projectchats").exists,
                      "Show › Projects, and no Project Chats in Recent while it is off")
        tapFilter(app, "projects")
        XCTAssertTrue(filterItem(app, "projectchats").waitForExistence(timeout: 5), "Project Chats in Recent with Projects on")
        closeFilter(app)
        // [sessions-shape] With it on, the Chats side keeps a shortcut to the projects (the starred ones, or the newest two).
        // [project-opens-page] On the Chats side a project's row opens its page too, on the Projects side; the switch's
        // other side goes back to the Chats side.
        XCTAssertTrue(waitUntil(8) { bySide.contains(where: \.exists) }, "a project's row on the Bots side")
        let projectRow = bySide.first(where: \.exists)!
        let projectName = String(projectRow.label.prefix { $0 != "," })
        XCTAssertFalse(((projectRow.value as? String) ?? "").contains("Collapsed"), "it opens, it doesn't unfold (\(projectRow.value ?? ""))")
        reveal(app, projectRow)
        projectRow.tap()
        XCTAssertTrue(app.cells["sessions.projectPage"].waitForExistence(timeout: 6), "the row opens \(projectName)'s page")
        XCTAssertTrue(waitUntil(6) { toBots.exists && !toProjects.exists }, "on the Projects side")
        XCTAssertTrue(app.staticTexts[projectName].exists, "the page is \(projectName)'s")
        shot(app, "P0c-bots-side-row-opens-page")
        toBots.tap()
        XCTAssertTrue(waitUntil(6) { toProjects.exists && !app.cells["sessions.projectPage"].exists }, "the switch goes back to the Bots side")
        XCTAssertTrue(waitUntil(6) { !self.chip(app, "research").exists || self.chip(app, "default").exists }, "the bot pills again")
        // [project-page-return] With a bot picked: its project's page shows the whole project, the switch is in view
        // (the rail scrolled only as far as the project's pill needed), and the way back brings the bot back.
        tapChip(app, "research")
        XCTAssertTrue(waitUntil(6) { self.chip(app, "research").isSelected }, "Research picked")
        let reading = header(app, "Reading")
        XCTAssertTrue(reading.waitForExistence(timeout: 6), "Research's project, Reading")
        reveal(app, reading)
        reading.tap()
        XCTAssertTrue(app.cells["sessions.projectPage"].waitForExistence(timeout: 6), "Reading's page")
        XCTAssertTrue(waitUntil(6) { toBots.exists && toBots.isHittable }, "the switch is in view, no swipe needed")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.chip.project.' AND selected == true")).firstMatch.label.hasPrefix("Reading"),
                      "Reading's pill lit")
        shot(app, "P0d-page-from-a-bot")
        toBots.tap()
        XCTAssertTrue(waitUntil(6) { toProjects.exists && self.chip(app, "research").isSelected }, "back: Research picked again")
        XCTAssertTrue(waitUntil(6) { self.order(app).allSatisfy { ["s-trip", "s-recipes"].contains($0) } }, "Research's chats (\(order(app)))")
        tapChip(app, "research")
        XCTAssertTrue(waitUntil(6) { self.nothingPicked(app) })
        toProjects.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()
        XCTAssertTrue(waitUntil(6) { toBots.exists && !toProjects.exists }, "now the projects")
        openFilter(app)
        XCTAssertTrue(filterWords(app, "group").contains("Project"), filterWords(app, "group"))
        closeFilter(app)
        let rail = app.scrollViews["sessions.chips"]
        XCTAssertTrue(waitUntil(6) { rail.label == "Projects" }, "the rail is the projects (\(rail.label))")
        XCTAssertFalse(chip(app, "research").exists, "no bot pills")
        let pills = (0..<3).map { app.buttons["sessions.chip.project.\($0)"] }
        XCTAssertTrue(pills.allSatisfy(\.exists), "three project pills\n\(rail.debugDescription)")
        XCTAssertEqual(pills.map(\.label), ["Website project, New", "Reading project, Working", "App project"],
                       "what needs you first: Website's unread reply, Reading's working chat, then App")
        XCTAssertTrue(nothingPicked(app), "nothing is picked")
        shot(app, "P1-project-pills")
        // [sessions-ux] A project's row opens its page, as its pill does (it opened in place); the lit pill shows the list again.
        let websiteRow = header(app, "Website")
        XCTAssertTrue(websiteRow.waitForExistence(timeout: 6), "Website's row")
        reveal(app, websiteRow)
        websiteRow.tap()
        XCTAssertTrue(app.cells["sessions.projectPage"].waitForExistence(timeout: 6), "the row opens the project's page")
        XCTAssertTrue(waitUntil(6) { pills[0].isSelected && !self.nothingPicked(app) }, "and lights its pill")
        onScreen(app, pills[0]).tap()
        XCTAssertTrue(waitUntil(6) { self.nothingPicked(app) && !app.cells["sessions.projectPage"].exists }, "the lit pill: the list again")
        onScreen(app, pills[0]).tap()
        XCTAssertTrue(waitUntil(6) { let o = self.order(app); return o.contains("s-budget") && !o.contains("s-garden") && !o.contains("s-trip") },
                      "only Website's chats (\(order(app)))")
        XCTAssertTrue(pills[0].isSelected, "its pill lights")
        XCTAssertFalse(nothingPicked(app))
        XCTAssertFalse(strip(app).exists, "the lit pill says it: no strip")
        // The project page: its header (name, folder, counts, New Chat), then its chats by what they wait on.
        let page = app.cells["sessions.projectPage"]
        XCTAssertTrue(page.waitForExistence(timeout: 6), "the project page's header")
        XCTAssertTrue(app.staticTexts["Website"].exists, "the project's name")
        // The three counts, always: a zero is dimmed and takes no tap.
        XCTAssertEqual(app.buttons["sessions.projectPage.ready"].label, "New, 1 chat")
        XCTAssertEqual(app.buttons["sessions.projectPage.needs"].label, "Needs You, 0 chats")
        XCTAssertFalse(app.buttons["sessions.projectPage.needs"].isEnabled, "a zero takes no tap")
        XCTAssertTrue(app.staticTexts["sessions.projectPage.place"].label.contains("~/site"), "its folder")
        // [sessions-ux] One go-to: no New Chat on the page; the bar's Compose starts the chat here and says so.
        XCTAssertFalse(app.buttons["sessions.projectPage.newChat"].exists, "no second New Chat on the page")
        XCTAssertEqual(app.buttons["sessions.compose"].label, "New Chat in Website with Hermes")
        XCTAssertTrue(waitUntil(6) { self.headers(app) == ["Active"] }, "its piles (\(headers(app)))")
        shot(app, "P2-project-pill-picked")
        // Reading's page: its working chat under Working.
        onScreen(app, pills[1]).tap()
        XCTAssertTrue(waitUntil(6) { self.headers(app) == ["Active"] && self.order(app) == ["s-trip"] }, "Reading's page (\(headers(app)), \(order(app)))")
        shot(app, "P2b-project-page-working")
        onScreen(app, pills[1]).tap()
        XCTAssertTrue(waitUntil(6) { !page.exists && self.headers(app).contains("Website") }, "every project again (\(headers(app)))")
        onScreen(app, pills[0]).tap()
        XCTAssertTrue(page.waitForExistence(timeout: 6))
        // The lit pill goes back to every project, as a lit bot pill does.
        onScreen(app, pills[0]).tap()
        XCTAssertTrue(waitUntil(6) { !page.exists && self.headers(app).contains("Website") }, "every project again (\(headers(app)))")
        XCTAssertFalse(pills[0].isSelected)
        XCTAssertTrue(waitUntil(4) { self.nothingPicked(app) }, "nothing is picked again")
        // Working narrows the pills to the projects at work.
        app.buttons["sessions.chip.status.working"].tap()
        XCTAssertTrue(waitUntil(6) { pills[0].exists && pills[0].label == "Reading project, Working" && !pills[1].exists },
                      "Working keeps Reading alone\n\(rail.debugDescription)")
        shot(app, "P3-working-projects")
        app.buttons["sessions.chip.status.working"].tap()
        XCTAssertTrue(waitUntil(6) { pills[2].exists }, "every project again")
        // Hold a pill: Archive Project. It leaves the pills and its chat the list; Show › Archived brings both back.
        onScreen(app, pills[1]).press(forDuration: 1.0)
        let archive = app.buttons["sessions.chip.project.archive"]
        XCTAssertTrue(archive.waitForExistence(timeout: 5), "Archive Project in the pill's menu")
        archive.tap()
        XCTAssertTrue(waitUntil(6) { pills[1].label == "App project" && !pills[2].exists }, "Reading's pill is gone\n\(rail.debugDescription)")
        XCTAssertTrue(waitUntil(6) { !self.headers(app).contains("Reading") }, "Reading's card leaves the list (\(headers(app)))")
        shot(app, "P4-project-archived")
        openFilter(app)
        tapFilter(app, "show", "archived")
        closeFilter(app)
        XCTAssertTrue(waitUntil(6) { pills[2].exists && pills[2].label.contains("Archived") }, "Reading comes back last, marked")
        XCTAssertTrue(waitUntil(6) { self.headers(app).contains("Reading") }, "and its card (\(headers(app)))")
        rail.swipeLeft()
        XCTAssertTrue(waitUntil(4) { pills[2].isHittable })
        shot(app, "P5-archived-shown")
        onScreen(app, pills[2]).press(forDuration: 1.0)
        XCTAssertTrue(archive.waitForExistence(timeout: 5))
        XCTAssertEqual(archive.label, "Unarchive Project")
        archive.tap()
        XCTAssertTrue(waitUntil(6) { pills[1].label == "Reading project, Working" }, "unarchived, in its place (\(pills[1].label))")
        openFilter(app)
        tapFilter(app, "show", "archived")
        closeFilter(app)
        // [projects-switch] A page with two sections: the Working chip counts its chat.
        fixture("/__fixture/mode", ["working": ["s-trip", "s-garden"]])          // a turn at work in App too
        let appPill = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.chip.project.' AND label BEGINSWITH 'App project'")).firstMatch
        XCTAssertTrue(waitUntil(20) { appPill.exists && appPill.label.contains("Working") }, "App is at work (\(appPill.exists ? appPill.label : "no pill"))")
        onScreen(app, appPill).tap()
        let workingChip = app.buttons["sessions.projectPage.working"]
        XCTAssertTrue(workingChip.waitForExistence(timeout: 6), "the Working count's chip")
        XCTAssertEqual(workingChip.label, "Working, 1 chat")
        // [three-piles] One Active pile, the working chat first in it.
        func pile(_ name: String) -> String? { self.headers(app).first { $0 == name || $0.hasPrefix(name + ", ") } }
        XCTAssertTrue(waitUntil(6) { pile("Active") == "Active" && self.order(app).contains("s-garden") }, "\(headers(app)), \(order(app))")
        shot(app, "P5b-project-page-chips")
        // A pile closes to its heading and count, and the count's chip opens it again (and goes to its chat).
        let activeHeader = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'sessions.header' AND label BEGINSWITH 'Active'")).firstMatch
        XCTAssertTrue(row(app, "s-garden").exists)
        activeHeader.tap()
        XCTAssertTrue(waitUntil(6) { !self.row(app, "s-garden").exists && (pile("Active") ?? "").hasPrefix("Active, ") }, "closed (\(headers(app)))")
        shot(app, "P5c-project-page-pile-closed")
        // [page-count-chips] A count narrows the page to its chats (a closed pile opens for them), the page staying; the
        // rail's Working pill lights with it. Tapped again, every chat is back (and the pile closed as it was).
        workingChip.tap()
        XCTAssertTrue(waitUntil(6) { self.order(app) == ["s-garden"] && pile("Active") == "Active" }, "Working's chat alone (\(headers(app)), \(order(app)))")
        XCTAssertTrue(app.cells["sessions.projectPage"].exists && workingChip.isSelected, "the page stays, the count lit")
        XCTAssertTrue(app.buttons["sessions.chip.status.working"].isSelected, "the rail's Working pill is the same choice")
        XCTAssertFalse(self.headers(app).contains { $0.hasPrefix("Done") }, "no Done while narrowed (\(headers(app)))")
        shot(app, "P5d-project-page-narrowed")
        workingChip.tap()
        XCTAssertTrue(waitUntil(6) { !workingChip.isSelected && (pile("Active") ?? "").hasPrefix("Active, ") }, "every chat again, the pile closed as it was (\(headers(app)))")
        activeHeader.tap()
        XCTAssertTrue(waitUntil(6) { self.row(app, "s-garden").exists && pile("Active") == "Active" }, "open again (\(headers(app)))")
        onScreen(app, appPill).tap()
        fixture("/__fixture/mode", ["working": ["s-trip"]])
        XCTAssertTrue(waitUntil(20) { !appPill.label.contains("Working") }, "App is quiet again")
        // [projects-switch] Show › Bot Faces off: the rows and the page draw no faces.
        openFilter(app)
        tapFilter(app, "show", "faces")
        closeFilter(app)
        shot(app, "P6-faces-off-all")
        rail.swipeRight()
        onScreen(app, pills[0]).tap()
        XCTAssertTrue(page.waitForExistence(timeout: 6))
        shot(app, "P7-faces-off-page")
        onScreen(app, pills[0]).tap()
        openFilter(app)
        tapFilter(app, "show", "faces")
        closeFilter(app)
        // Back to the bot pills.
        rail.swipeRight()
        XCTAssertTrue(waitUntil(4) { toBots.isHittable })
        toBots.tap()
        XCTAssertTrue(waitUntil(6) { self.chip(app, "research").exists && rail.label == "Bots" }, "the bot pills again")
    }
    /// [switch-thumb] Owner 2026-11-19: in the Desktop Look the switch's lit side was a capsule inside the track's
    /// 4 pt-corner box. Both views captured for the eye; the switch still flips.
    @MainActor func test40g_SwitchThumbInDesktopLook() throws {
        let app = launch(projectPages: true, extra: ["-HQDebugDesktopLook", "YES"])
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        let toProjects = app.buttons["sessions.pills.projects"], toBots = app.buttons["sessions.pills.bots"]
        XCTAssertTrue(toProjects.waitForExistence(timeout: 15))
        shot(app, "P9-desktop-switch-bots")
        toProjects.tap()
        XCTAssertTrue(waitUntil(6) { toBots.exists && !toProjects.exists })
        shot(app, "P9-desktop-switch-projects")
        toBots.tap()
        XCTAssertTrue(waitUntil(6) { toProjects.exists && !toBots.exists })
    }
    /// [press-corners] Owner 2026-11-19: in the Desktop Look on the iPhone a pressed row's box was cut by iOS's large
    /// card ends (More › Settings). Each outlined section's first and last row drawn pressed (`-HQDebugDesktopPress`),
    /// on More (the app's list) and Settings (SwiftUI's), for the eye.
    @MainActor func test40h_PressedRowsInDesktopLook() throws {
        let app = launch(extra: ["-HQDebugDesktopLook", "YES", "-HQDebugDesktopPress", "YES"])
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        app.tabButton(id: "tab-more", label: "More").tap()
        let settings = app.cells["more-row-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        app.collectionViews["more.list"].swipeDown()      // the list's own layout pass, then the press marks
        shot(app, "Q1-desktop-more-pressed")
        settings.tap()
        Thread.sleep(forTimeInterval: 1.5)
        shot(app, "Q2-desktop-settings-pressed")
    }
    /// [project-edge-swipe] Owner 2026-11-17: "Swiping from the left edge when in a project should go back a page when
    /// there is a page to go back to." Back the way the page was come into; on the list itself the swipe does nothing.
    @MainActor func test40e_EdgeSwipeLeavesProjectPage() throws {
        let app = launch(projectPages: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        let toProjects = app.buttons["sessions.pills.projects"], toBots = app.buttons["sessions.pills.bots"]
        let page = app.cells["sessions.projectPage"]
        XCTAssertTrue(toProjects.waitForExistence(timeout: 15))
        func edgeSwipe() {
            let window = app.windows.firstMatch
            let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.55))
            from.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.55)))
        }
        // From the Bots side, a bot picked: back is that bot's list again. [chats-projects] Its projects shown there.
        showProjectsOnChats(app)
        tapChip(app, "research")
        XCTAssertTrue(waitUntil(6) { self.chip(app, "research").isSelected }, "Research picked")
        let reading = header(app, "Reading")
        XCTAssertTrue(reading.waitForExistence(timeout: 6))
        reveal(app, reading)
        reading.tap()
        XCTAssertTrue(page.waitForExistence(timeout: 6), "Reading's page")
        edgeSwipe()
        XCTAssertTrue(waitUntil(6) { !page.exists && toProjects.exists && self.chip(app, "research").isSelected },
                      "the swipe goes back: the Bots side, Research picked again")
        // The list itself has no page to go back to: the swipe leaves it as it is.
        edgeSwipe()
        XCTAssertTrue(waitUntil(2) { toProjects.exists && self.chip(app, "research").isSelected }, "nothing to go back to")
        tapChip(app, "research")
        XCTAssertTrue(waitUntil(6) { self.nothingPicked(app) })
        // On the Projects side, a project's pill: back is every project.
        toProjects.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()
        XCTAssertTrue(waitUntil(6) { toBots.exists })
        let website = app.buttons["sessions.chip.project.0"]
        XCTAssertTrue(website.waitForExistence(timeout: 6))
        onScreen(app, website).tap()
        XCTAssertTrue(page.waitForExistence(timeout: 6), "Website's page")
        edgeSwipe()
        XCTAssertTrue(waitUntil(6) { !page.exists && toBots.exists && self.nothingPicked(app) && self.headers(app).contains("Website") },
                      "the swipe goes back to every project (\(headers(app)))")
    }

    /// [project-edge-swipe] Owner 2026-11-19 (voice memo): "toggle into projects and then click a project … swipe from
    /// the left side of the screen to go back, you go all the way back to the bots page." Switched to Projects by hand,
    /// a project opened from its row: back is every project, never the Bots side. Also after a page opened from the
    /// Bots side was left within the Projects side (its pill tapped off) and another project opened.
    @MainActor func test40i_EdgeSwipeStaysOnProjectsSide() throws {
        let app = launch(projectPages: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        let toProjects = app.buttons["sessions.pills.projects"], toBots = app.buttons["sessions.pills.bots"]
        let page = app.cells["sessions.projectPage"]
        XCTAssertTrue(toProjects.waitForExistence(timeout: 15))
        func edgeSwipe() {
            let window = app.windows.firstMatch
            let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.55))
            from.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.55)))
        }
        func onProjectsList() -> Bool { !page.exists && toBots.exists && !toProjects.exists && nothingPicked(app) }
        showProjectsOnChats(app)                        // [chats-projects] step 2 opens a project from the Chats side
        // 1. The switch to Projects, then a project's row in the list.
        toProjects.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()
        XCTAssertTrue(waitUntil(6) { toBots.exists })
        let reading = header(app, "Reading")
        XCTAssertTrue(reading.waitForExistence(timeout: 6))
        reveal(app, reading)
        reading.tap()
        XCTAssertTrue(page.waitForExistence(timeout: 6), "Reading's page")
        edgeSwipe()
        XCTAssertTrue(waitUntil(6) { onProjectsList() }, "back to every project, not the Bots side (\(headers(app)))")
        // 2. Back on the Bots side, a project opened from its list, left by its pill (still on Projects), another opened.
        toBots.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        XCTAssertTrue(waitUntil(6) { toProjects.exists })
        let again = header(app, "Reading")
        XCTAssertTrue(again.waitForExistence(timeout: 6))
        reveal(app, again)
        again.tap()
        XCTAssertTrue(page.waitForExistence(timeout: 6), "Reading's page from the Bots side")
        let lit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.chip.project.' AND selected == true")).firstMatch
        onScreen(app, lit).tap()
        XCTAssertTrue(waitUntil(6) { onProjectsList() }, "every project")
        let website = app.buttons["sessions.chip.project.0"]
        onScreen(app, website).tap()
        XCTAssertTrue(page.waitForExistence(timeout: 6), "Website's page")
        edgeSwipe()
        XCTAssertTrue(waitUntil(6) { onProjectsList() }, "back to every project, where the page was opened (\(headers(app)))")
    }

    /// [sessions-shape] Owner 2026-11-18 ("It doesn't feel like it has enough organization"; "an additional click to end
    /// up to your final destination"): the Bots side is Pinned, the projects' shortcut, and the chats by the day; on
    /// the Projects side a project's live chats (a reply not read, at work) sit under its row, one tap from the chat.
    @MainActor func test40f_DaysAndLiveChatsUnderProjects() throws {
        fixture("/__fixture/mode", ["working": ["s-trip"]])          // a turn at work in Reading
        defer { fixture("/__fixture/mode", ["working": [String]()]) }
        let app = launch(projectPages: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        let toProjects = app.buttons["sessions.pills.projects"], toBots = app.buttons["sessions.pills.bots"]
        XCTAssertTrue(toProjects.waitForExistence(timeout: 15))
        // The Bots side: no one long Recent; the chats under the day they were last at work.
        XCTAssertTrue(waitUntil(8) { self.headers(app).contains("Today") && !self.headers(app).contains("Recent") }, "\(headers(app))")
        XCTAssertTrue(headers(app).contains { $0.hasPrefix("Yesterday") || $0.hasPrefix("This Week") }, "an earlier day too (\(headers(app)))")
        shot(app, "D1-bots-days")
        // The Projects side: Website's unread chat and Reading's working one under their projects; App, quiet, is one row.
        toProjects.tap()
        XCTAssertTrue(toBots.waitForExistence(timeout: 8))
        XCTAssertTrue(waitUntil(8) { self.order(app) == ["s-budget", "s-trip"] }, "the live chats alone (\(order(app)))")
        XCTAssertEqual(rows(under: "Website", app), ["s-budget"])
        XCTAssertEqual(rows(under: "Reading", app), ["s-trip"])
        XCTAssertTrue(rows(under: "App", app).isEmpty, "a quiet project is its row alone")
        shot(app, "D2-projects-live")
        // The project's name still opens its page.
        reveal(app, header(app, "Reading"))
        header(app, "Reading").tap()
        XCTAssertTrue(app.cells["sessions.projectPage"].waitForExistence(timeout: 6), "Reading's page")
        let pill = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.chip.project.' AND selected == true")).firstMatch
        onScreen(app, pill).tap()
        XCTAssertTrue(waitUntil(6) { !app.cells["sessions.projectPage"].exists && self.order(app) == ["s-budget", "s-trip"] }, "\(order(app))")
        // One tap on a live chat opens it.
        row(app, "s-trip").tap()
        XCTAssertTrue(waitUntil(8) { !app.collectionViews["sessions.list"].isHittable || app.navigationBars.buttons.firstMatch.exists }, "the chat opens")
    }

    /// [three-piles] Owner 2026-11-17 (picked from pictures, "I like option 1"): a project's page is three piles.
    /// Pinned; Active, one run (a long one draws its first rows then Show More); Done, the archived chats, closed to
    /// its count until tapped. On the page the swipe says Done, and Not Done on a chat in Done.
    @MainActor func test40c_ProjectPageThreePiles() throws {
        let now = Date().timeIntervalSince1970
        for index in 0..<17 { setRow("s-act-\(index)", ["title": "Active \(index)", "last_active": now - Double(index + 3) * 600]) }
        setRow("s-keep", ["title": "Keep close", "pinned": true, "last_active": now - 5 * 86_400])
        for index in 0..<2 { setRow("s-done-\(index)", ["title": "Done \(index)", "archived": true, "last_active": now - Double(index + 20) * 86_400]) }
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        let toProjects = app.buttons["sessions.pills.projects"]
        XCTAssertTrue(toProjects.waitForExistence(timeout: 15))
        toProjects.tap()
        let appPill = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.chip.project.' AND label BEGINSWITH 'App project'")).firstMatch
        XCTAssertTrue(appPill.waitForExistence(timeout: 10))
        onScreen(app, appPill).tap()
        XCTAssertTrue(app.cells["sessions.projectPage"].waitForExistence(timeout: 6))
        let list = app.collectionViews["sessions.list"]
        func names() -> [String] { self.headers(app) }
        XCTAssertTrue(waitUntil(8) { Array(names().prefix(2)) == ["Pinned", "Active"] }, "Pinned, then Active (\(names()))")
        XCTAssertEqual(Set(order(app).prefix(2)), ["s-release", "s-keep"], "the pinned chats first (\(order(app)))")
        XCTAssertFalse(row(app, "s-done-0").exists, "Done's chats are put away")
        shot(app, "P8-page-three-piles")
        // Active draws its first rows, then Show More; Done is one closed line under it.
        let more = app.cells["sessions.showMore"].firstMatch
        for _ in 0..<6 where !more.exists { list.swipeUp(velocity: .slow) }
        XCTAssertTrue(more.exists, "Show More under a long Active")
        XCTAssertTrue(waitUntil(6) { (names().last ?? "").hasPrefix("Done, ") }, "Done closed, with its count (\(names()))")
        shot(app, "P8b-page-show-more-and-done")
        more.tap()
        for _ in 0..<4 where !row(app, "s-act-16").exists { list.swipeUp(velocity: .slow) }
        XCTAssertTrue(row(app, "s-act-16").exists, "all of Active")
        // Done opens with a tap on its heading.
        let done = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'sessions.header' AND label BEGINSWITH 'Done'")).firstMatch
        for _ in 0..<4 where !done.isHittable { list.swipeUp(velocity: .slow) }
        done.tap()
        for _ in 0..<3 where !row(app, "s-done-1").exists { list.swipeUp(velocity: .slow) }
        XCTAssertTrue(waitUntil(6) { self.row(app, "s-done-0").exists && names().last == "Done" }, "Done open (\(names()))")
        shot(app, "P9-page-done-open")
        // A chat in Done: the swipe takes it back out.
        row(app, "s-done-0").swipeLeft()
        let notDone = app.buttons["Not Done"]
        XCTAssertTrue(notDone.waitForExistence(timeout: 4), "Not Done on a chat in Done")
        shot(app, "P9b-page-not-done-swipe")
        notDone.tap()
        XCTAssertTrue(waitUntil(8) { names().last == "Done" && !self.order(app).suffix(1).contains("s-done-0") }, "back among the active chats (\(order(app)))")
        // An active chat: the swipe says Done and puts it in the pile.
        list.swipeDown(velocity: .fast); list.swipeDown(velocity: .fast)
        XCTAssertTrue(row(app, "s-act-0").waitForExistence(timeout: 6))
        row(app, "s-act-0").swipeLeft()
        let markDone = app.buttons["Done"]
        XCTAssertTrue(markDone.waitForExistence(timeout: 4), "Done on an active chat")
        shot(app, "P9c-page-done-swipe")
        markDone.tap()
        XCTAssertTrue(waitUntil(8) { !self.row(app, "s-act-0").exists || self.order(app).last == "s-act-0" }, "it left Active (\(order(app)))")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Done “Active 0”'")).firstMatch.waitForExistence(timeout: 4), "the Undo pill says so")
        // Off the page it is an archived chat: not in the list.
        onScreen(app, appPill).tap()
        XCTAssertTrue(waitUntil(6) { !app.cells["sessions.projectPage"].exists })
        XCTAssertFalse(row(app, "s-act-0").exists)
        setRow("s-act-0", ["archived": false], event: true)
    }

    /// Pixels unlike the page's ground in the strip `width` points wide at the screen's left edge, between `top` and `bottom`.
    static func inkBesideEdge(_ image: UIImage, top: CGFloat, bottom: CGFloat, width: CGFloat) -> Int {
        guard let cg = image.cgImage, cg.width > 40 else { return -1 }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return -1 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let k = CGFloat(w) / image.size.width
        func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
        }
        let y0 = max(0, Int(top * k)), y1 = min(h - 1, Int(bottom * k))
        guard y1 > y0 else { return -1 }
        let ground = px(Int(1 * k), (y0 + y1) / 2)
        var count = 0
        for y in y0...y1 {
            for x in 0..<Int(width * k) {
                let p = px(x, y)
                if max(abs(p.0 - ground.0), abs(p.1 - ground.1), abs(p.2 - ground.2)) > 40 { count += 1 }
            }
        }
        return count
    }
}
