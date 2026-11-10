// [sessions-m9] The stress plan of docs/spec/3x-sessions.md §14 as repeatable tests, against
// scripts/fixtures/sessions-gateway.py. test80-test88 run on the default seed; test90-test92 need the load seed:
//   HQN_SESSIONS_SEED=big HQN_SESSIONS_ONLY="test90_Big_MarkAllAsRead,test91_Big_ChipsTwelveToForty,test92_Big_ScrollAndToggle" \
//     scripts/e2e-sessions.sh <UDID> <PORT>
// HQN_SESSIONS_DROPS=50 runs test81 with the plan's fifty reconnects (default 12).

import XCTest

extension SessionsTests {
    static var dropCount: Int { Int(ProcessInfo.processInfo.environment["HQN_SESSIONS_DROPS"] ?? "") ?? 12 }

    // MARK: Interruption

    /// 200 `sessions.changed` in four seconds with the Filter menu open: the menu stays open, a toggle made meanwhile
    /// is not undone, and the list is read once per throttle window rather than once per event.
    @MainActor func test80_BurstWithTheMenuOpen() throws {
        let app = launch()
        let garden = row(app, "s-garden")
        XCTAssertTrue(garden.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 2.0)
        let before = sidebarReads()
        openFilter(app)
        tapFilter(app, "detail")
        XCTAssertTrue(filterItem(app, "detail.tokens").waitForExistence(timeout: 4))
        fixture("/__fixture/burst", ["count": 200, "interval": 0.02])
        Thread.sleep(forTimeInterval: 1.0)
        tapFilter(app, "detail.tokens")                                   // mid-burst
        XCTAssertTrue(waitUntil(4) { self.labelOf(garden).contains("1.2k tokens") }, labelOf(garden))
        Thread.sleep(forTimeInterval: 5.0)                                // the burst ends, its last read lands
        XCTAssertTrue(filterItem(app, "detail.tokens").exists, "the submenu is still open")
        XCTAssertTrue(filterChecked(app, "detail.tokens"), "the toggle was not undone")
        XCTAssertTrue(labelOf(garden).contains("1.2k tokens"), labelOf(garden))
        shot(app, "S-burst-menu-open")
        tapFilter(app, "detail.cost")
        XCTAssertTrue(waitUntil(4) { self.labelOf(garden).contains("$0.02") }, "the menu still works (\(labelOf(garden)))")
        closeFilter(app)
        let after = sidebarReads()
        let reads = (after.probe + after.full + after.deep + after.top) - (before.probe + before.full + before.deep + before.top)
        XCTAssertGreaterThanOrEqual(reads, 1, "the burst is noticed")
        XCTAssertLessThanOrEqual(reads, 12, "one read per throttle window, not one per event (\(reads) for 200 events)")
        XCTAssertEqual(order(app).count, 5)
    }

    /// Reconnect after reconnect with nothing changed: a probe each time and never a full read.
    @MainActor func test81_ManyReconnectsNeverReadInFull() throws {
        // A burst of `sessions.changed` an earlier test started (test80) may still be going: each event is a read of the
        // list this test counts. Wait it out, and the last throttled read after it (10 s on screen).
        let bursting = burstLeft() > 0
        XCTAssertTrue(waitUntil(180) { self.burstLeft() == 0 }, "an earlier test's burst ends")
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: bursting ? 12.0 : 3.0)
        let before = sidebarReads(), fullBefore = fullReads()
        let drops = Self.dropCount
        for index in 0..<drops {
            let probes = sidebarReads().probe
            fixture("/__fixture/drop")
            XCTAssertTrue(waitUntil(40) { self.sidebarReads().probe > probes }, "reconnect \(index + 1): a probe")
            Thread.sleep(forTimeInterval: 3.5)   // past the 3 s inside which reconnects share one refresh (offline, ReconnectShare)
        }
        XCTAssertEqual(sidebarReads().probe - before.probe, drops, "\(drops) probes")
        XCTAssertEqual(fullReads() - fullBefore, 0, "and no full read")
        XCTAssertEqual(order(app).count, 5, "the list is as it was")
        XCTAssertEqual(app.state, .runningForeground)
        shot(app, "S-many-reconnects")
    }

    /// The socket drops while the Filter menu is open: the menu stays usable.
    @MainActor func test82_SocketDropWithTheMenuOpen() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openFilter(app)
        tapFilter(app, "status")
        XCTAssertTrue(filterItem(app, "status.unread").waitForExistence(timeout: 4))
        fixture("/__fixture/drop")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(filterItem(app, "status.unread").exists, "the menu is still open")
        tapFilter(app, "status.unread")
        XCTAssertTrue(waitUntil(6) { self.order(app) == ["s-budget"] }, "and still filters (\(order(app)))")
        closeFilter(app)
        XCTAssertEqual(strip(app).label, "Showing Unread. Clear Filters")
        shot(app, "S-drop-menu-open")
    }

    // MARK: Bad network

    /// Every Mark All as Read write fails: the alert counts all of them; once the gateway answers again Try Again
    /// writes exactly those chats.
    @MainActor func test83_MarkAllAsReadEveryWriteFails() throws {
        for id in ["s-garden", "s-trip"] { setRow(id, ["unread": true]) }            // with s-budget: three
        fixture("/__fixture/fail", ["method": "PATCH", "path": "/api/sessions/", "prefix": true, "status": 503,
                                    "detail": "The gateway is restarting.", "count": 3])
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(6) { self.labelOf(self.row(app, "s-garden")).contains("Unread") })
        openFilter(app)
        tapFilter(app, "readall")
        let alert = app.alerts["Couldn’t Mark All as Read"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        let words = alert.staticTexts.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(words.contains { $0.hasPrefix("3 chats: ") }, "the reason counts every chat (\(words))")
        shot(app, "S-readall-all-failed")
        for id in ["s-garden", "s-trip", "s-budget"] {
            XCTAssertTrue(labelOf(row(app, id)).contains("Unread"), "\(id) keeps its mark")
        }
        XCTAssertFalse(sessionsBadge(app).isEmpty, "the badge stays")
        let before = unreadWrites().count
        XCTAssertEqual(before, 3)
        alert.buttons["Try Again"].tap()
        XCTAssertTrue(waitUntil(8) { self.unreadWrites().count == before + 3 }, "three more writes (\(unreadWrites().count))")
        for id in ["s-garden", "s-trip", "s-budget"] {
            XCTAssertTrue(waitUntil(5) { !self.labelOf(self.row(app, id)).contains("Unread") }, "\(id) reads as read")
        }
        XCTAssertTrue(waitUntil(5) { self.sessionsBadge(app).isEmpty })
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(unreadWrites().count, before + 3, "none repeated")
    }

    /// The first page is late: the cached list shows at once, the menu and chips answer meanwhile, and the late page
    /// does not undo a toggle made while it was in the air. The fixture holds the page until the test lets go, so
    /// nothing here races a clock.
    @MainActor func test84_LateSidebarKeepsWhatTheUserDid() throws {
        let first = launch()
        XCTAssertTrue(row(first, "s-garden").waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 1.5)
        first.terminate()
        fixture("/__fixture/mode", ["sidebarHold": true])
        setRow("s-late", ["profile": "default", "title": "Arrived late", "last_active": nowSeconds, "unread": true])
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15), "the cached list shows though no page has come")
        XCTAssertTrue(waitUntil(20) { self.heldReads().sidebar > 0 }, "the app asked for the page, and it is held")
        let asked = Date()
        XCTAssertFalse(row(app, "s-late").exists, "the network page is still on its way")
        openFilter(app)
        tapFilter(app, "status", "status.unread")
        XCTAssertTrue(waitUntil(6) { self.order(app) == ["s-budget"] }, "the filter answers from the cache (\(order(app)))")
        closeFilter(app)
        chip(app, "default").tap()
        XCTAssertTrue(chip(app, "default").isSelected)
        XCTAssertFalse(row(app, "s-late").exists, "still nothing from the network")
        shot(app, "S-late-page-before")
        // The app gives a read 30 seconds. Let go inside that and the held page itself lands; on a Mac so busy that
        // the steps above outlasted it, that read has already failed in the app, and the next page (asked for when the
        // gateway says the list changed) is the late one. Either way a page lands after what the user did.
        let heldFor = Date().timeIntervalSince(asked)
        fixture("/__fixture/mode", ["sidebarHold": false])
        if heldFor > 24, !row(app, "s-late").waitForExistence(timeout: 10) {
            setRow("s-late", ["title": "Arrived late"], event: true)
        }
        XCTAssertTrue(row(app, "s-late").waitForExistence(timeout: 45), "the late page lands (held \(Int(heldFor)) s)")
        XCTAssertTrue(waitUntil(10) { self.order(app) == ["s-late", "s-budget"] }, "with the filter and the chip as the user left them (\(order(app)))")
        XCTAssertEqual(strip(app).label, "Showing Unread. Clear Filters")
        XCTAssertTrue(chip(app, "default").isSelected)
        shot(app, "S-late-page-after")
    }

    /// The projects read is late: the Filter menu opens without them while the fixture still holds `projects.tree`,
    /// and lists them, in the open menu, once they arrive.
    @MainActor func test85_LateProjectsNeverBlockTheMenu() throws {
        // The device keeps each bot's projects from the last launch (the menu lists those at once), so a first launch
        // reads none: what the second launch then lists can only have come from the held answer.
        fixture("/__fixture/mode", ["projects": "empty"])
        let first = launch()
        XCTAssertTrue(row(first, "s-garden").waitForExistence(timeout: 15))
        openFilter(first)
        XCTAssertTrue(waitUntil(15) { self.rpcLog().filter { $0.method == "projects.tree" }.count >= 3 }, "every bot's projects were read (none)")
        tapFilter(first, "project")
        XCTAssertTrue(filterItem(first, "project.new").waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(8) { !self.filterItem(first, "project.0").exists }, "the gateway has no project now, so none is listed")
        Thread.sleep(forTimeInterval: 1.5)
        first.terminate()
        fixture("/__fixture/mode", ["projects": false, "projectsHold": true])
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openFilter(app)
        XCTAssertTrue(waitUntil(15) { self.heldReads().projects > 0 }, "opening the menu asked for the projects, and they are held")
        let asked = Date()
        XCTAssertTrue(filterItem(app, "sort").exists, "the menu is open")
        XCTAssertGreaterThan(heldReads().projects, 0, "while the projects are still on their way: it never waited for them")
        tapFilter(app, "project")
        XCTAssertTrue(filterItem(app, "project.new").waitForExistence(timeout: 5), "New Project… is offered meanwhile")
        XCTAssertFalse(filterItem(app, "project.0").exists, "no project is listed yet")
        XCTAssertGreaterThan(heldReads().projects, 0, "still held")
        shot(app, "S-projects-late")
        // The app gives `projects.tree` 20 seconds. Let go inside that and the open submenu gains the projects by
        // itself; on a Mac so busy that the steps above outlasted it, that ask has failed in the app, and the menu
        // asks again when it is next opened.
        let heldFor = Date().timeIntervalSince(asked)
        fixture("/__fixture/mode", ["projectsHold": false])
        if heldFor < 15 {
            XCTAssertTrue(filterItem(app, "project.0").waitForExistence(timeout: 20), "the open menu lists the projects once they arrive (held \(Int(heldFor)) s)")
            XCTAssertTrue(filterItem(app, "project.new").exists, "New Project… is still there")
            shot(app, "S-projects-arrived-in-the-open-menu")
        } else {
            var listed = filterItem(app, "project.0").waitForExistence(timeout: 5)
            for _ in 0..<6 where !listed {
                closeFilter(app)
                Thread.sleep(forTimeInterval: 2.0)
                openFilter(app)
                tapFilter(app, "project")
                listed = filterItem(app, "project.0").waitForExistence(timeout: 5)
            }
            XCTAssertTrue(listed, "the projects are listed once they arrive (held \(Int(heldFor)) s: the first ask had timed out)")
        }
    }

    // MARK: Bad data

    /// Odd rows ride along (no id, null words, a 300-character title, emoji, right-to-left, tokens as strings, NaN,
    /// absurd costs, a profile no bot has): the list shows what is sound, every view of it works, nothing crashes.
    @MainActor func test86_BadRows() throws {
        fixture("/__fixture/mode", ["badRows": true])
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        XCTAssertTrue(row(app, "bad-time-ahead").waitForExistence(timeout: 8), "the odd rows came (\(order(app)))")
        shot(app, "S-bad-rows")
        // The list is longer than the screen: every row is read by scrolling to the end and back.
        let all = everyRow(app)
        for id in ["bad-null", "bad-long", "bad-emoji", "bad-rtl", "bad-tokens-text", "bad-tokens-negative", "bad-tokens-huge",
                   "bad-cost-negative", "bad-time-zero", "bad-time-ahead", "bad-source", "bad-cwd", "bad-cwd-null"] {
            XCTAssertTrue(all.contains(id), "\(id) is listed (\(all))")
        }
        XCTAssertFalse(all.contains(""), "a row without an id is dropped (\(all))")
        XCTAssertEqual(order(app).first, all.first, "the list is back at its top")
        XCTAssertTrue(reveal(app, "bad-long"), "the long title scrolls in")
        XCTAssertLessThanOrEqual(row(app, "bad-long").frame.height, 140, "a 300-character title stays one line (\(row(app, "bad-long").frame.height))")
        shot(app, "S-bad-rows-long-emoji-rtl")
        for _ in 0..<16 where order(app).first != all.first { list(app).swipeDown(velocity: .fast) }
        openFilter(app)
        tapFilter(app, "detail", "detail.tokens", "detail.cost")
        closeFilter(app)
        XCTAssertTrue(waitUntil(5) { self.labelOf(self.row(app, "s-garden")).contains("1.2k tokens. $0.02") })
        shot(app, "S-bad-rows-figures")
        for width in app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'session-row-'")).allElementsBoundByIndex.map(\.frame.width) {
            XCTAssertLessThanOrEqual(width, app.frame.width + 0.5, "no row is wider than the screen")
        }
        openFilter(app)
        tapFilter(app, "sort", "sort.tokens")
        XCTAssertTrue(waitUntil(6) { self.headers(app) == ["Pinned"] || self.headers(app).isEmpty }, "one flat run (\(headers(app)))")
        shot(app, "S-bad-rows-by-tokens")
        openFilter(app)
        tapFilter(app, "sort", "sort.cost")
        Thread.sleep(forTimeInterval: 0.8)
        openFilter(app)
        tapFilter(app, "sort", "sort.updated")
        openFilter(app)
        tapFilter(app, "group", "group.status")
        Thread.sleep(forTimeInterval: 0.8)
        list(app).swipeUp()
        list(app).swipeUp()
        shot(app, "S-bad-rows-scrolled")
        list(app).swipeDown()
        list(app).swipeDown()
        XCTAssertEqual(app.state, .runningForeground, "the app is still running")
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 6))
    }

    @MainActor func list(_ app: XCUIApplication) -> XCUIElement { app.collectionViews["sessions.list"] }

    /// An older gateway (no sidebar route, no projects, no session.usage): the list still comes, the Filter menu
    /// works, New Project… says what is needed, and Session Info opens with what it has.
    @MainActor func test87_OlderGateway() throws {
        fixture("/__fixture/mode", ["oldGateway": true])
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 20), "the list comes by the older route")
        openFilter(app)
        tapFilter(app, "status", "status.unread")
        XCTAssertTrue(waitUntil(6) { self.order(app) == ["s-budget"] }, "\(order(app))")
        closeFilter(app)
        strip(app).tap()
        XCTAssertTrue(waitUntil(6) { self.order(app).count >= 5 })
        chip(app, "default").tap()
        openFilter(app)
        tapFilter(app, "project", "project.new")
        let alert = app.alerts["New Project"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        fill(alert.textFields["project.name"], "Site")
        fill(alert.textFields["project.folder"], "~/site")
        press(alert.buttons["Create"])
        let failed = app.alerts["Couldn’t Create Project"]
        XCTAssertTrue(failed.waitForExistence(timeout: 8))
        XCTAssertTrue(failed.staticTexts["This gateway doesn’t have projects yet. Update Hermes on the computer running Hermes, then try again."].exists,
                      "\(failed.staticTexts.allElementsBoundByIndex.map(\.label))")
        XCTAssertFalse(failed.buttons["Try Again"].exists, "no Try Again for a gateway without projects")
        shot(app, "S-old-gateway-projects")
        failed.buttons.firstMatch.tap()
        XCTAssertFalse(app.staticTexts["Created Site"].waitForExistence(timeout: 1.5), "no stale HUD")
        chip(app, nil).tap()
        openChat(app, "s-trip")
        openSessionInfo(app)
        XCTAssertTrue(hasInfoRow(app, "Model") && hasInfoRow(app, "Gateway") && hasInfoRow(app, "Chat ID"))
        XCTAssertEqual(infoRow(app, "Cost"), "$0.34, Estimated", "the stored row still speaks for the cost")
        XCTAssertFalse(hasInfoRow(app, "Context"), "no live usage on this gateway")
        shot(app, "S-old-gateway-info")
    }

    // MARK: Load on the default seed

    /// Chips tapped as fast as the test can, forty times: the list matches the last tap and at most one deeper read
    /// went out.
    @MainActor func test88_RapidChipTaps() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 2.0)
        let deepBefore = sidebarReads().deep
        let chips: [String?] = ["research", "deploys", "default", nil]
        let points = chips.map { chip(app, $0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)) }
        for index in 0..<40 { points[index % 4].tap() }
        points[0].tap()                                                    // Research last
        XCTAssertTrue(waitUntil(8) { self.order(app) == ["s-trip", "s-recipes"] }, "the list matches the last tap (\(order(app)))")
        XCTAssertTrue(chip(app, "research").isSelected)
        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertLessThanOrEqual(sidebarReads().deep - deepBefore, 1, "at most one deeper read")
        XCTAssertEqual(app.state, .runningForeground)
        shot(app, "S-rapid-chips")
    }

    // MARK: Load on the big seed (HQN_SESSIONS_SEED=big)

    /// Mark All as Read with 200 unread chats: exactly 200 writes, none repeated, the badge reaches zero.
    @MainActor func test90_Big_MarkAllAsRead() throws {
        try XCTSkipUnless(Self.bigSeed, "needs HQN_SESSIONS_SEED=big")
        let app = launch()
        XCTAssertTrue(waitUntil(30) { !self.order(app).isEmpty }, "the list")
        XCTAssertFalse(sessionsBadge(app).isEmpty, "unread chats carry a badge")
        shot(app, "S-big-list")
        openFilter(app)
        tapFilter(app, "status", "status.unread")                          // a filter on: the deeper read holds all 200
        closeFilter(app)
        Thread.sleep(forTimeInterval: 4.0)
        strip(app).tap()
        openFilter(app)
        XCTAssertTrue(filterItem(app, "readall").isEnabled)
        tapFilter(app, "readall")
        XCTAssertTrue(waitUntil(60) { self.unreadWrites().count >= 200 }, "the writes go out (\(unreadWrites().count))")
        // The list stays usable meanwhile.
        list(app).swipeUp()
        list(app).swipeDown()
        Thread.sleep(forTimeInterval: 3.0)
        let sent = unreadWrites()
        XCTAssertEqual(sent.count, 200, "exactly 200 writes")
        XCTAssertEqual(Set(sent.map(\.path)).count, 200, "none repeated")
        XCTAssertTrue(sent.allSatisfy { !$0.unread })
        XCTAssertTrue(waitUntil(10) { self.sessionsBadge(app).isEmpty }, "the badge reaches zero (\(sessionsBadge(app)))")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        shot(app, "S-big-all-read")
    }

    /// Twelve chips, then forty: the rail scrolls to its end and every chip still filters.
    @MainActor func test91_Big_ChipsTwelveToForty() throws {
        try XCTSkipUnless(Self.bigSeed, "needs HQN_SESSIONS_SEED=big")
        let app = launch()
        XCTAssertTrue(waitUntil(30) { !self.order(app).isEmpty }, "the list")
        let rail = app.scrollViews["sessions.chips"]
        XCTAssertTrue(rail.waitForExistence(timeout: 8))
        func chips() -> [String] { rail.buttons.allElementsBoundByIndex.map(\.identifier).filter { $0.hasPrefix("sessions.chip.") } }
        if !waitUntil(8, { Set(chips()).count == 13 }) { print("RAIL-TREE", rail.debugDescription) }
        XCTAssertEqual(Set(chips()).count, 13, "All and twelve bots (\(chips()))")
        XCTAssertEqual(chips().count, 13, "each chip is said once (\(chips()))")
        shot(app, "S-big-chips-12")
        fixture("/__fixture/mode", ["bots": 40])
        fixture("/__fixture/rows", ["id": "s-poke", "set": ["profile": "default", "title": "Poke"], "event": true])
        app.tabBars.buttons["Bots"].tap()                                  // the roster is re-read on Bots
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 8))
        app.collectionViews["bots.list"].swipeDown()
        Thread.sleep(forTimeInterval: 3.0)
        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(waitUntil(20) { Set(chips()).count == 41 }, "the rail grows to All and forty bots (\(Set(chips()).count))")
        // The rail moves with each swipe until its last chip is on screen (All's own place says how far it has gone).
        var places: [CGFloat] = [chip(app, nil).frame.minX]
        for _ in 0..<14 {
            rail.swipeLeft()
            places.append(chip(app, nil).frame.minX)
            if places.count > 2, places[places.count - 1] == places[places.count - 2] { break }      // the end: it no longer moves
        }
        print("RAIL-PLACES", places)
        let identified = rail.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.chip.'")).allElementsBoundByIndex
        let farthest = identified.map(\.frame.maxX).max() ?? 0
        XCTAssertLessThanOrEqual(farthest, app.frame.width + 0.5, "the rail scrolls to its last chip (\(places))")
        XCTAssertLessThan(places.last ?? 0, -2_000, "past forty chips (\(places))")
        shot(app, "S-big-chips-40-end")
        // By place, not by asking whether each is hittable: XCTest cannot say that of a chip thousands of points away.
        let last = identified.last { $0.frame.minX >= 0 && $0.frame.maxX <= app.frame.width + 0.5 }
        XCTAssertNotNil(last, "a chip at the rail's end")
        last?.tap()
        XCTAssertTrue(waitUntil(5) { last?.isSelected == true }, "it takes the pick")
        for _ in 0..<16 where chip(app, nil).frame.minX < 0 { rail.swipeRight() }
        chip(app, nil).tap()
        XCTAssertTrue(chip(app, nil).isSelected)
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// 300 rows loaded with Tokens and Cost on: every toggle settles quickly and the list scrolls to its end.
    @MainActor func test92_Big_ScrollAndToggle() throws {
        try XCTSkipUnless(Self.bigSeed, "needs HQN_SESSIONS_SEED=big")
        let app = launch()
        XCTAssertTrue(waitUntil(30) { !self.order(app).isEmpty }, "the list")
        openFilter(app)
        tapFilter(app, "detail", "detail.tokens", "detail.cost")
        closeFilter(app)
        openFilter(app)
        tapFilter(app, "status", "status.idle")                            // a filter: the deeper read (300 rows)
        closeFilter(app)
        XCTAssertTrue(waitUntil(15) { self.sidebarReads().deep >= 1 }, "the deeper read")
        Thread.sleep(forTimeInterval: 3.0)
        shot(app, "S-big-filtered")
        // Each toggle settles (the measure includes XCUITest's own time; the bound is loose on purpose).
        for (menu, item) in [("sort", "sort.tokens"), ("sort", "sort.created"), ("group", "group.project"), ("group", "group.status"), ("sort", "sort.updated")] {
            openFilter(app)
            // The yardstick: a tap that only opens a submenu (no list work), timed the same way. On a busy Mac a
            // tap alone can take seconds, so the toggle is held to three times that, and to 3 s when taps are quick.
            let opener = filterItem(app, menu)
            XCTAssertTrue(opener.waitForExistence(timeout: 6), menu)
            let openerStarted = Date()
            opener.tap()
            let plainTap = Date().timeIntervalSince(openerStarted)
            Thread.sleep(forTimeInterval: 0.45)
            let target = filterItem(app, item)
            XCTAssertTrue(target.waitForExistence(timeout: 4), item)
            // The tap returns once the app is idle again: that is the toggle, the menu's own animation and XCUITest's
            // overhead (reading the rows back costs the test seconds more, so it is not in the measure). The list
            // pipeline's own time is measured without the harness in SessionListPipelineTests.
            let started = Date()
            target.tap()
            let took = Date().timeIntervalSince(started)
            XCTAssertLessThan(took, max(3.0, plainTap * 3), "\(item) took \(took) s (a plain tap took \(plainTap) s)")
            XCTAssertTrue(app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'session-row-'")).firstMatch.waitForExistence(timeout: 3), "\(item) settles on rows")
            closeFilter(app)
        }
        for _ in 0..<12 { list(app).swipeUp(velocity: .fast) }
        shot(app, "S-big-scrolled")
        for _ in 0..<4 { list(app).swipeDown(velocity: .fast) }
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(strip(app).exists, "the strip is still there")
    }
}
