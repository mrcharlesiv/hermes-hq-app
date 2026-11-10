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
        let chips = ["all", "default", "research", "deploys"].map { app.buttons["sessions.chip.\($0)"] }
        XCTAssertTrue(chips.allSatisfy(\.exists), "All, Hermes, Research, Deploys")
        XCTAssertEqual(chips.map(\.label), ["All Bots", "Hermes", "Research", "Deploys"])
        for (left, right) in zip(chips, chips.dropFirst()) {
            XCTAssertLessThan(left.frame.midX, right.frame.midX, "in that order")
        }
        XCTAssertTrue(chips[0].isSelected, "All is picked at launch")
        // [sessions-layout] Pills: a 44 pt touch height around the 34 pt capsule (a frame reads 43.99999…).
        XCTAssertTrue(chips.allSatisfy { $0.frame.width >= 43.5 && $0.frame.height >= 43.5 }, "44 x 44 touch targets (\(chips.map(\.frame)))")
        // The rail ends where the list's first row begins or above it (the "Pinned" header sits between them).
        XCTAssertLessThanOrEqual(rail.frame.maxY, row(app, "s-release").frame.minY + 0.5,
                                 "the rail sits above the list (rail \(rail.frame), first row \(row(app, "s-release").frame))")
        shot(app, "C1-rail")
        // The status chips (New, Working) sit between All and the bots; the bot pills are one element each.
        let botPills = rail.buttons.matching(NSPredicate(format: "NOT (identifier BEGINSWITH %@)", "sessions.chip.status."))
        XCTAssertEqual(botPills.count, 4, "each chip is one element\n\(rail.debugDescription)")
        app.terminate()

        fixture("/__fixture/mode", ["bots": 1])
        let alone = launch()
        XCTAssertTrue(row(alone, "s-garden").waitForExistence(timeout: 15))
        // [sessions-fresh] One bot: no bot pills. All stays only with New or Working chats beside it, to pick them.
        XCTAssertTrue(waitUntil(15) { !alone.buttons["sessions.chip.default"].exists }, "one bot: no bot pills")
        let status = alone.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sessions.chip.status."))
        XCTAssertEqual(alone.buttons["sessions.chip.all"].exists, status.count > 0, "All only beside New or Working")
        let others = alone.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT (identifier BEGINSWITH %@) AND identifier != %@",
                                                        "sessions.chip.", "sessions.chip.status.", "sessions.chip.all"))
        XCTAssertEqual(others.count, 0, "no bot's pill")
        shot(alone, "C1-one-bot-no-rail")
        // Leave the next launch its three bots.
        fixture("/__fixture/mode", ["bots": 3])
        alone.terminate()
    }

    /// C2, C3: a chip narrows the list to its bot and lights; nothing else moves and no call goes out beyond sidebar
    /// reads. The lit chip, or All, shows every bot again.
    @MainActor func test41_ChipFiltersAndNothingElseMoves() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 2.0)                              // the launch's own calls are done
        let rpcBefore = rpcLog().count
        let restBefore = ((try? account.control("/__fixture/state")) ?? [:])["rest"] as? [[String: Any]] ?? []
        let deepBefore = sidebarReads().deep
        chip(app, "research").tap()
        XCTAssertTrue(waitUntil(6) { self.order(app) == ["s-trip", "s-recipes"] }, "only Research's chats (\(order(app)))")
        XCTAssertTrue(chip(app, "research").isSelected, "its chip lights")
        XCTAssertFalse(chip(app, nil).isSelected)
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

        // C3: the lit chip again, then All.
        chip(app, "research").tap()
        XCTAssertTrue(waitUntil(6) { self.order(app).count == 5 }, "the lit chip shows every bot again (\(order(app)))")
        XCTAssertTrue(chip(app, nil).isSelected)
        chip(app, "deploys").tap()
        XCTAssertTrue(waitUntil(6) { self.order(app) == ["s-release"] }, "\(order(app))")
        shot(app, "C3-chip-deploys")
        chip(app, nil).tap()
        XCTAssertTrue(waitUntil(6) { self.order(app).count == 5 }, "All shows every bot (\(order(app)))")
        XCTAssertTrue(chip(app, nil).isSelected && !chip(app, "deploys").isSelected)
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
        XCTAssertNil(oddPixel(app, from: rail.frame.minY - 4, to: chip(app, nil).frame.minY - 0.5), "a row shows above the chips")
        shot(app, "C4-rail-at-the-end")
        for _ in 0..<8 { list.swipeDown(velocity: .fast) }
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(row(app, "s-release").isHittable, "back at the top")
        XCTAssertTrue(rail.exists && chip(app, "default").isHittable)
        XCTAssertEqual(rail.frame.height, folded.height, accuracy: 0.6, "the rail keeps its height")
        shot(app, "C4-rail-back-at-top")
    }

    /// C5, C6: a relaunch opens on All; Compose with a chip picked starts that bot's chat with no chooser, with All it
    /// shows Choose a Bot.
    @MainActor func test43_RelaunchOnAllAndComposeUsesTheChip() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        chip(app, "research").tap()
        XCTAssertTrue(waitUntil(6) { self.order(app) == ["s-trip", "s-recipes"] })
        app.buttons["sessions.compose"].tap()
        XCTAssertTrue(waitUntil(8) { self.rpc("session.create").contains { $0["profile"] as? String == "research" } },
                      "a new Research chat, straight away")
        XCTAssertFalse(app.buttons["choose-bot-research"].exists, "no Choose a Bot")
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 8), "the new chat opens")
        shot(app, "C6-compose-with-chip")
        backToList(app)
        XCTAssertTrue(chip(app, "research").isSelected)
        chip(app, nil).tap()
        app.buttons["sessions.compose"].tap()
        XCTAssertTrue(app.buttons["choose-bot-research"].waitForExistence(timeout: 5), "under All: Choose a Bot")
        shot(app, "C6-compose-under-all")
        app.terminate()

        // C5: the pick is not kept across launches.
        let picked = launch(keepView: true)
        XCTAssertTrue(row(picked, "s-garden").waitForExistence(timeout: 15))
        chip(picked, "deploys").tap()
        XCTAssertTrue(waitUntil(6) { self.order(picked) == ["s-release"] })
        picked.terminate()
        let again = launch(keepView: true)
        XCTAssertTrue(row(again, "s-garden").waitForExistence(timeout: 15), "the list opens on every bot")
        XCTAssertTrue(chip(again, nil).isSelected, "All is picked")
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
        chip(app, "default").tap()
        XCTAssertTrue(waitUntil(6) { self.order(app) == ["s-budget", "s-garden"] }, "unread first, in New for You (\(order(app)))")
        XCTAssertEqual(botChats.count, 0, "nor under its chip")
        chip(app, nil).tap()
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
        chip(app, "research").tap()
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
}
