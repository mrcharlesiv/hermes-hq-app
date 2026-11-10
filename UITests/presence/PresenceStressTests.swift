// The presence stream's stress plan as repeatable UI tests (docs/spec/3x-presence.md §14), against the presence fixture:
//   HQN_PRESENCE_CLASS=PresenceStressTests HQN_PRESENCE_PORT=9930 scripts/e2e-presence.sh <UDID>
//   HQN_PRESENCE_CLASS=PresenceTimingTests … for the two timed waits (A3: the 90 s fall-back, E8: the notice's 8 s).
// stress1 needs more bots: add HQN_PRESENCE_BOTS=50 (it skips without them). HQN_PRESENCE_LONG=1 runs the outage
// and flap tests at the plan's full length. The unit side of the plan is Tests/Presence/PresenceLoadTests.swift.

import XCTest

final class PresenceStressTests: PresenceUITestCase {
    private var long: Bool { ProcessInfo.processInfo.environment["HQN_UI_LONG"] == "1" }

    // MARK: Load

    /// S1: 50 bots, the plugin's list changing 20 times a second, with the Bots list on screen and being scrolled.
    @MainActor func test01_ListFloodWithManyBots() throws {
        launch()
        guard row("bot-01").waitForExistence(timeout: 3) else { throw XCTSkip("needs HQN_PRESENCE_BOTS=50") }
        let seconds = long ? 30.0 : 12.0
        presence(["flood": ["bots": 50, "rate": 20, "seconds": seconds]])
        XCTAssertTrue(waitUntil(timeout: 6) { self.rowSays("bot-01", "Browsing site-") }, "lines show during the flood")
        let list = app.collectionViews["bots.list"]
        let end = Date().addingTimeInterval(seconds)
        var swipes = 0
        while Date() < end {
            swipes % 2 == 0 ? list.swipeUp() : list.swipeDown()
            swipes += 1
        }
        XCTAssertEqual(app.state, .runningForeground, "S1: the app is still running")
        measure("list flood: \(swipes) scroll gestures answered in \(Int(seconds)) s of 20 frames/s for 50 bots")
        // The flood stopped: every row shows the last frame's line.
        pause(2)
        list.swipeDown(); list.swipeDown()
        let last = ((presenceState()["browsers"] as? [[String: Any]]) ?? []).first { $0["profile"] as? String == "bot-01" }
        let host = URL(string: (last?["url"] as? String) ?? "")?.host ?? "?"
        XCTAssertTrue(waitUntil(timeout: 6) { self.rowSays("bot-01", "Browsing \(host)") }, "S1: the last line stands: \(rowLabel("bot-01")) vs \(host)")
        XCTAssertLessThanOrEqual(count("max_activity_sockets"), 1, "S1: one list socket")
        shot("stress-flood-settled")
    }

    /// S2: 500 tool starts in five seconds: one notice, a steady row, an app that still answers.
    @MainActor func test02_ToolBurstRaisesOneNotice() throws {
        launch()
        bind("ivy")
        presence(["burst": ["profile": "ivy", "name": "browser_click", "count": 500, "interval_ms": 10]])
        XCTAssertTrue(waitUntil(timeout: 6) { self.notice.exists }, "S2: the notice shows")
        XCTAssertTrue(waitUntil(timeout: 6) { self.rowSays("ivy", "Using its computer") })
        var flickers = 0
        let end = Date().addingTimeInterval(6)
        while Date() < end {
            if !rowSays("ivy", "Using its computer") { flickers += 1 }
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "presence-notice").count, 1, "S2: exactly one notice")
        }
        XCTAssertEqual(flickers, 0, "S2: the row's line is steady through the burst")
        // Touches still land: another tab and back.
        app.buttons["tab-sessions"].tap()
        app.buttons["tab-bots"].tap()
        XCTAssertTrue(row("ivy").waitForExistence(timeout: 5), "S2: the app answers touches")
        XCTAssertEqual(notice.label, "Ivy is using its browser")
        shot("stress-burst")
    }

    /// S3 (two bots on this fixture; ten in the unit test): both rows say it, one capsule, ending on the later bot.
    @MainActor func test03_TwoBotsWithinASecond() throws {
        launch()
        bind("ivy")
        bind("default")
        toolStart("default", "browser_navigate")
        toolStart("ivy", "browser_navigate")
        XCTAssertTrue(waitUntil(timeout: 6) { self.rowSays("ivy", "Using its computer") && self.rowSays("default", "Using its computer") }, "S3: both rows")
        XCTAssertTrue(waitUntil(timeout: 6) { self.notice.exists && self.notice.label == "Ivy is using its browser" }, "S3: the capsule ends on the later bot: \(notice.label)")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "presence-notice").count, 1, "S3: one capsule")
        shot("stress-two-bots")
    }

    /// S4: the switch flipped twenty times as fast as taps register.
    @MainActor func test04_SwitchHammering() throws {
        launch()
        openBotInfo("ivy")
        XCTAssertTrue(app.switches["bot-info.computer.alert"].waitForExistence(timeout: 8))
        for _ in 0..<20 { tapSwitch("bot-info.computer.alert") }
        // Settled: the calls stop arriving.
        var seen = -1
        XCTAssertTrue(waitUntil(timeout: 40) {
            let now = self.configureCalls().count
            defer { seen = now }
            self.pause(1.5)
            return now == seen
        }, "S4: the writes settle")
        XCTAssertFalse(app.alerts.firstMatch.exists, "S4: no alert")
        let stored = storedMeta("ivy")["screenAutoOpen"] as? Bool ?? true
        XCTAssertTrue(waitUntil(timeout: 5) { self.switchIsOn("bot-info.computer.alert") == stored },
                      "S4: the switch ends where the gateway does (stored \(stored))")
        // In order: each write is the opposite of the one before it.
        let flags = configureCalls().compactMap { ((($0["ui_meta"] as? [String: Any])?["hermes-bots"] as? [String: Any])?["screenAutoOpen"] as? Bool) }
        XCTAssertFalse(flags.isEmpty)
        XCTAssertEqual(flags.first, false, "the first flip turns it off")
        for (a, b) in zip(flags, flags.dropFirst()) { XCTAssertNotEqual(a, b, "S4: the writes arrive in order: \(flags)") }
        measure("switch hammering: 20 taps → \(flags.count) writes, final \(stored)")
        closeBotInfo()
    }

    // MARK: Bad network

    /// S9: the gateway away with lines showing; back, the lines are right again with no dial storm.
    @MainActor func test05_OutageOnTheBotsList() throws {
        presence(["browsers": [["profile": "ivy", "active": true, "url": "https://example.test/sign-in"]]])
        launch()
        XCTAssertTrue(waitUntil(timeout: 8) { self.rowSays("ivy", "Browsing example.test") })
        presence(["gateway": "down"])
        let end = Date().addingTimeInterval(long ? 60 : 20)
        while Date() < end {
            XCTAssertEqual(app.state, .runningForeground, "S9: no crash")
            // The line may stay (stale) or go; it never turns into something else.
            let label = rowLabel("ivy")
            XCTAssertFalse(label.contains("Needs you") || label.contains("You’re using") || label.contains("Handing you"), "S9: never a wrong line: \(label)")
            pause(2)
        }
        shot("stress-outage-bots-list")
        // What the bot is doing changed meanwhile.
        presence(["browsers": [["profile": "ivy", "active": true, "url": "https://later.example.test/"]], "gateway": "up"])
        XCTAssertTrue(waitUntil(timeout: 60) { self.count("ws_clients") >= 1 }, "the link comes back")
        let right = secondsUntil(timeout: 12) { self.rowSays("ivy", "Browsing later.example.test") }
        XCTAssertNotNil(right, "S9: the line is right again")
        measure("link ready → Bots row line right again: \(String(format: "%.2f", right ?? -1)) s")
        XCTAssertLessThanOrEqual(count("max_activity_sockets"), 1, "S9: never two list sockets")
        XCTAssertLessThanOrEqual(count("activity_opens"), 3, "S9: no dial storm (\(count("activity_opens")) dials)")
    }

    /// S10: the gateway flapping with the viewer open.
    @MainActor func test06_FlapWithTheViewerOpen() throws {
        try account.control("/__fixture/browser", ["active": true])
        launch()
        openChat("default")
        let chip = app.buttons["chat.shelf.browser"]
        XCTAssertTrue(chip.waitForExistence(timeout: 15))
        chip.tap()
        XCTAssertTrue(stage.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 15) { self.framesShown() >= 10 })
        let flaps = long ? 20 : 8
        for _ in 0..<flaps {
            presence(["gateway": "down"])
            pause(2)
            presence(["gateway": "up"])
            pause(2)
            XCTAssertLessThanOrEqual(count("watch_sockets"), 1)
        }
        XCTAssertEqual(app.state, .runningForeground, "S10: no crash")
        XCTAssertTrue(stage.exists, "S10: the viewer is still open")
        XCTAssertTrue(waitUntil(timeout: 60) { self.count("watch_sockets") == 1 }, "S10: the viewer ends connected")
        XCTAssertTrue(framesRising(within: 10), "S10: and live (\(stageValue()))")
        XCTAssertLessThanOrEqual(count("max_watch_sockets"), 1, "S10: at most one watch socket at any time")
        measure("flap ×\(flaps): \(count("watch_opens")) watch dials, max \(count("max_watch_sockets")) at once")
        app.buttons["browser.close"].tap()
    }

    /// S11: the list socket dropped again and again: the lines survive and the socket returns.
    @MainActor func test07_ListSocketDrops() throws {
        presence(["browsers": [["profile": "ivy", "active": true, "url": "https://example.test/sign-in"]]])
        launch()
        XCTAssertTrue(waitUntil(timeout: 8) { self.rowSays("ivy", "Browsing example.test") })
        for round in 0..<(long ? 20 : 5) {
            presence(["activity": "drop"])
            pause(0.5)
            XCTAssertTrue(rowSays("ivy", "Browsing example.test"), "S11: the line survives drop \(round)")
            XCTAssertTrue(waitUntil(timeout: 14) { self.count("activity_sockets") == 1 }, "S11: the socket returns after drop \(round)")
        }
        // A change after the last return still arrives.
        presence(["browsers": [["profile": "ivy", "active": true, "url": "https://after.example.test/"]]])
        XCTAssertTrue(waitUntil(timeout: 8) { self.rowSays("ivy", "Browsing after.example.test") }, "S11: and the list is live")
        XCTAssertLessThanOrEqual(count("max_activity_sockets"), 1)
    }

    /// S12: a write the gateway never answers, and Bot Info left at once.
    @MainActor func test08_HangingWriteAndLeaving() throws {
        launch()
        openBotInfo("ivy")
        presence(["configure": ["mode": "hang", "count": 1]])
        tapSwitch("bot-info.computer.alert")
        XCTAssertTrue(waitUntil(timeout: 8) { self.configureCalls().count == 1 }, "the write went out")
        closeBotInfo()
        // The gateway's time limit passes: no alert appears over the Bots list for a sheet that is gone.
        pause(36)
        XCTAssertEqual(app.state, .runningForeground, "S12: no crash")
        XCTAssertFalse(app.alerts.firstMatch.exists, "S12: nothing is said over a sheet that is gone")
        // The store's undo puts back "no value" as the web's does, with a null: never a real true (the Mac's opt-in)
        // and never a real false (off).
        let flag = storedMeta("ivy")["screenAutoOpen"]
        XCTAssertTrue(flag == nil || flag is NSNull, "S12: the flag is unchanged (\(String(describing: flag)))")
        // The next flip works.
        openBotInfo("ivy")
        XCTAssertTrue(waitUntil(timeout: 8) { self.switchIsOn("bot-info.computer.alert") }, "S12: the switch shows what is stored (on)")
        tapSwitch("bot-info.computer.alert")
        XCTAssertTrue(waitUntil(timeout: 10) { self.storedMeta("ivy")["screenAutoOpen"] as? Bool == false }, "S12: the next flip saves")
        closeBotInfo()
    }

    /// S12, staying on the sheet: the time limit's words, and the switch goes back.
    @MainActor func test09_HangingWriteSaysSo() throws {
        launch()
        openBotInfo("ivy")
        presence(["configure": ["mode": "hang", "count": 1]])
        tapSwitch("bot-info.computer.alert")
        let failed = app.alerts["Couldn’t Change the Alert"]
        XCTAssertTrue(failed.waitForExistence(timeout: 45), "D4: after the time limit the failure is said")
        XCTAssertTrue(failed.staticTexts["The computer running Hermes didn’t answer in time."].exists, "D4: in plain words: \(failed.staticTexts.allElementsBoundByIndex.map(\.label))")
        shot("stress-write-timed-out")
        failed.buttons["OK"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.switchIsOn("bot-info.computer.alert") }, "D4: the switch goes back")
        closeBotInfo()
    }

    /// S13: Ask Hermes to Install It with the gateway away. The request is in the main bot's chat under its title (its
    /// bubble, or its row in the queue card), nothing of the long prompt is typed into the field, and when the gateway
    /// is back it goes out by itself, once.
    @MainActor func test10_AskWhileTheGatewayIsAway() throws {
        try account.control("/__fixture/browser", ["plugin": "missing"])
        launch()
        openChat("ivy")
        let item = openMoreMenu()
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        let ask = app.buttons["browser.empty.action"]
        XCTAssertTrue(ask.waitForExistence(timeout: 10))
        presence(["gateway": "down"])
        pause(1)
        ask.tap()
        let queued = app.descendants(matching: .any).matching(identifier: "chat.queue.item")
        func inTheChat() -> Bool {
            chatSays(Self.installTitle)
                || queued.matching(NSPredicate(format: "label CONTAINS %@", Self.installTitle)).firstMatch.exists
                || app.descendants(matching: .any)["chat.queue"].descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS %@", Self.installTitle)).firstMatch.exists
        }
        XCTAssertTrue(waitUntil(timeout: 10) { self.chatTitle().contains("Hermes") && inTheChat() },
                      "S13: the request is in the main bot's chat under its title (chat: \(chatTitle()))")
        XCTAssertFalse(ask.exists, "S13: the viewer closed")
        pause(8)
        XCTAssertEqual(app.state, .runningForeground, "S13: no crash")
        XCTAssertEqual(installSubmits().count, 0, "S13: nothing can have gone out yet")
        XCTAssertTrue(inTheChat(), "S13: still there after 8 s without the gateway")
        let field = app.textViews["composer.text"]
        XCTAssertFalse(((field.value as? String) ?? "").contains("Please install"), "S13: the long prompt is never typed into the field")
        shot("stress-ask-while-away")

        presence(["gateway": "up"])
        XCTAssertTrue(waitUntil(timeout: 60) { self.installSubmits().count == 1 }, "S13: it goes out by itself when the gateway is back (\(installSubmits().count) sent)")
        dismissOffer(wait: 3)
        XCTAssertTrue(waitUntil(timeout: 10) { self.chatSays(Self.installTitle) }, "S13: as a bubble with its title")
        let typed = (field.value as? String) ?? ""
        XCTAssertFalse(typed.localizedCaseInsensitiveContains("install"), "S13: the field is left empty: \(typed)")
        XCTAssertEqual(queued.count, 0, "S13: nothing left in the queue")
        pause(4)
        XCTAssertEqual(installSubmits().count, 1, "S13: once, not twice")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'dispatch'")).firstMatch.exists,
                       "S13: the plugin's old name is nowhere on screen")
        shot("stress-ask-after-the-gateway-is-back")
    }

    // MARK: Bad data

    /// S14, S16: frames that are not a list, a frame too big, and rows that make no sense.
    @MainActor func test11_BadListFrames() throws {
        presence(["browsers": [["profile": "ivy", "active": true, "url": "https://example.test/sign-in"]]])
        launch()
        XCTAssertTrue(waitUntil(timeout: 8) { self.rowSays("ivy", "Browsing example.test") })
        presence(["activity": "garbage"])
        presence(["activity": "huge"])
        pause(1.5)
        XCTAssertEqual(app.state, .runningForeground, "S14: no crash")
        XCTAssertTrue(rowSays("ivy", "Browsing example.test"), "S14: the line stays through bad frames")
        XCTAssertEqual(count("activity_sockets"), 1, "S14: the socket is kept")

        // S16: a profile that is no bot, two rows for one bot (the newest use wins), an address that is none.
        let now = Date().timeIntervalSince1970
        presence(["browsers": [
            ["profile": "nobody-here", "active": true, "url": "https://ghost.example.test/"],
            ["profile": "ivy", "id": String(repeating: "a", count: 24), "active": true, "url": "https://older.example.test/", "agent_at": now - 50],
            ["profile": "ivy", "id": String(repeating: "b", count: 24), "active": true, "url": "https://newer.example.test/", "agent_at": now],
            ["profile": "default", "active": true, "url": "not a url at all"],
        ]])
        XCTAssertTrue(waitUntil(timeout: 8) { self.rowSays("ivy", "Browsing newer.example.test") }, "S16: the newest browser wins: \(rowLabel("ivy"))")
        // (After stress round 1: an address that names no web site is not repeated raw.)
        XCTAssertTrue(waitUntil(timeout: 5) { self.rowSays("default", "Using its browser") }, "S16: an odd address gets the plain line: \(rowLabel("default"))")
        XCTAssertFalse(rowSays("default", "not a url"), "S16: and is not repeated raw")
        // A host no web site can have (4,800 letters): the plain line again, not 4,800 letters.
        presence(["browsers": [["profile": "ivy", "active": true, "url": "https://" + String(repeating: "verylonghostname", count: 300) + ".example.test/"]]])
        XCTAssertTrue(waitUntil(timeout: 8) { self.rowSays("ivy", "Using its browser") }, "S16: an impossible host is not shown: \(rowLabel("ivy"))")
        // A very long host that is a real one (four 48-letter labels): it shows, truncated by the row.
        let label = String(repeating: "verylonghostname", count: 3)
        presence(["browsers": [["profile": "ivy", "active": true, "url": "https://\(label).\(label).\(label).\(label).example.test/"]]])
        XCTAssertTrue(waitUntil(timeout: 8) { self.rowSays("ivy", "Browsing verylonghostname") }, "S16: a long host shows, truncated by the row: \(rowLabel("ivy"))")
        XCTAssertEqual(app.state, .runningForeground, "S16: no crash")
        XCTAssertLessThanOrEqual(row("ivy").frame.height, 140, "S16: the row keeps its height (two lines)")
        shot("stress-odd-rows")
    }

    /// S15: tool starts that make no sense.
    @MainActor func test12_BadToolEvents() throws {
        launch()
        bind("ivy")
        event("ivy", "tool.start", ["tool_id": "x1"])                                              // no name
        event("ivy", "tool.start", ["tool_id": "x2", "name": 42])                                  // a number
        event("ivy", "tool.start", ["tool_id": "x3", "name": String(repeating: "z", count: 10_000)])
        event("ivy", "tool.start", ["tool_id": "x4", "name": ["browser_navigate"]])                // a list
        event("ivy", "tool.start", [:])                                                            // no payload
        event("default", "tool.start", ["tool_id": "x5", "name": "browser_navigate"])              // a chat nobody opened
        pause(3)
        XCTAssertEqual(app.state, .runningForeground, "S15: no crash")
        XCTAssertFalse(notice.exists, "S15: no notice")
        XCTAssertFalse(rowSays("ivy", "Using its computer") || rowSays("default", "Using its computer"), "S15: no row change")
        // A 10 000-character name that does start like a screen tool is still just a screen tool.
        toolStart("ivy", "browser_" + String(repeating: "z", count: 10_000))
        XCTAssertTrue(waitUntil(timeout: 6) { self.rowSays("ivy", "Using its computer") }, "S15: a long screen-tool name still counts")
        XCTAssertTrue(waitUntil(timeout: 6) { self.notice.exists && self.notice.label == "Ivy is using its browser" })
    }

    /// S17: only a real `false` is off.
    @MainActor func test13_StoredFlagShapes() throws {
        presence(["edit": ["profile": "ivy", "screenAutoOpen": "false"]])
        presence(["edit": ["profile": "default", "screenAutoOpen": 0]])
        launch()
        openBotInfo("ivy")
        XCTAssertTrue(app.switches["bot-info.computer.alert"].waitForExistence(timeout: 8))
        XCTAssertTrue(switchIsOn("bot-info.computer.alert"), "S17: the string \"false\" is not off")
        closeBotInfo()
        openBotInfo("default")
        XCTAssertTrue(app.switches["bot-info.computer.alert"].waitForExistence(timeout: 8))
        XCTAssertTrue(switchIsOn("bot-info.computer.alert"), "S17: 0 is not off")
        closeBotInfo()
        XCTAssertTrue(configureCalls().isEmpty, "reading odd values wrote nothing")
        // A real false, set by another device, shows after the roster is read again.
        app.terminate()
        presence(["edit": ["profile": "ivy", "screenAutoOpen": false]])
        launch()
        openBotInfo("ivy")
        XCTAssertTrue(app.switches["bot-info.computer.alert"].waitForExistence(timeout: 8))
        XCTAssertFalse(switchIsOn("bot-info.computer.alert"), "S17: false is off")
        closeBotInfo()
    }

    /// S18: long, emoji and right-to-left names in the notice.
    @MainActor func test14_LongAndOddNames() throws {
        presence(["rename": ["profile": "ivy", "display_name": "Samantha the Extraordinarily Long Named Research Assistant Bot"]])
        presence(["rename": ["profile": "default", "display_name": "מסייע 🤖 هيرميس"]])
        launch()
        bind("ivy")
        bind("default")
        toolStart("ivy", "browser_navigate")
        XCTAssertTrue(waitUntil(timeout: 6) { self.notice.exists })
        XCTAssertTrue(notice.label.hasPrefix("Samantha the Extraordinarily"), notice.label)
        let screen = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(notice.frame.minX, 0)
        XCTAssertLessThanOrEqual(notice.frame.maxX, screen.maxX, "S18: inside the screen")
        XCTAssertLessThanOrEqual(notice.frame.height, 110, "S18: two lines at most")
        shots("stress-notice-long-name")
        notice.swipeUp()
        XCTAssertTrue(waitUntil(timeout: 3) { !self.notice.exists })
        toolStart("default", "browser_navigate")
        XCTAssertTrue(waitUntil(timeout: 6) { self.notice.exists && self.notice.label.contains("is using its browser") })
        shots("stress-notice-rtl-emoji-name")
        XCTAssertTrue(rowSays("ivy", "Using its computer"), "S18: the rows still say it")
    }

    /// Stress round 1: a swipe up on the notice opened the viewer (2 of 5 suite runs) and a 12 pt nudge counted as a
    /// tap. Four notices, each nudged sideways, pulled down, then sent away by a swipe or a slow drag up: Watch never
    /// runs, the nudges leave the notice where it is, and the swipe always sends it away.
    @MainActor func test26_ASwipeOrANudgeNeverOpensWatch() throws {
        presence(["browsers": [["profile": "ivy", "active": true, "url": "https://example.test/sign-in"],
                               ["profile": "default", "active": true, "url": "https://docs.example.test/guide"]]])
        launch()
        bind("ivy")
        bind("default")
        let began = Date()
        for (round, bot) in ["ivy", "default", "ivy", "default"].enumerated() {
            if round == 2 { pause(max(0, 31 - Date().timeIntervalSince(began))) }       // past each bot's 30 s
            toolStart(bot, round < 2 ? "browser_navigate" : "browser_click")
            XCTAssertTrue(waitUntil(timeout: 8) { self.notice.exists }, "round \(round): the notice shows")
            let frame = notice.frame
            let middle = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY))
            // A nudge sideways: more than a tap's own jitter, so it is not a tap; the notice stays.
            middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 16, dy: 0)), withVelocity: 240, thenHoldForDuration: 0)
            pause(0.8)
            XCTAssertFalse(stage.exists, "round \(round): a sideways nudge is not Watch")
            XCTAssertTrue(notice.exists, "round \(round): a sideways nudge leaves the notice")
            // A short nudge up: never Watch (it may send the notice away when it is quick enough to be a flick).
            if round % 2 == 1 {
                middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: -12)), withVelocity: 200, thenHoldForDuration: 0)
                pause(0.8)
                XCTAssertFalse(stage.exists, "round \(round): a 12 pt nudge up is not Watch")
            }
            // Pulled down and let go: it springs back and stays.
            if notice.exists {
                middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: 50)))
                pause(0.8)
                XCTAssertFalse(stage.exists, "round \(round): a pull down is not Watch")
                XCTAssertTrue(notice.exists, "round \(round): pulled down, it stays")
                // Away: the element's own swipe, or a slow drag up by 40 pt.
                if round < 2 { notice.swipeUp() }
                else { middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: -40)), withVelocity: 120, thenHoldForDuration: 0.1) }
            }
            XCTAssertTrue(waitUntil(timeout: 4) { !self.notice.exists }, "round \(round): sent away")
            pause(1.5)
            XCTAssertFalse(stage.exists, "round \(round): sending it away is not Watch")
            XCTAssertTrue(row(bot).isHittable, "round \(round): the Bots list is what shows")
        }
        XCTAssertEqual(count("max_watch_sockets"), 0, "no viewer was ever opened")
    }

    // MARK: Interruption

    /// S19: the app goes to the background while a notice shows.
    @MainActor func test15_BackgroundWhileTheNoticeShows() throws {
        launch(hold: false)
        bind("ivy")
        bind("default")
        toolStart("ivy", "browser_navigate")
        XCTAssertTrue(waitUntil(timeout: 6) { self.notice.exists })
        XCUIDevice.shared.press(.home)
        pause(2)
        // What happens meanwhile is old news by the time the app is back.
        for _ in 0..<5 { toolStart("default", "browser_navigate"); toolStart("ivy", "browser_click") }
        pause(8)
        app.activate()
        XCTAssertTrue(row("ivy").waitForExistence(timeout: 10))
        pause(1)
        XCTAssertLessThanOrEqual(app.descendants(matching: .any).matching(identifier: "presence-notice").count, 1, "S19: no burst of notices")
        XCTAssertTrue(waitUntil(timeout: 12) { !self.notice.exists }, "S19: no frozen capsule: it is gone or leaves on time")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// S23: Watch tapped while Bot Info is up: the viewer opens on top, and closing it returns to Bot Info.
    @MainActor func test16_WatchOverBotInfo() throws {
        presence(["browsers": [["profile": "ivy", "active": true, "url": "https://example.test/sign-in"]]])
        launch()
        bind("ivy")
        openBotInfo("default")
        toolStart("ivy", "browser_navigate")
        XCTAssertTrue(waitUntil(timeout: 6) { self.notice.exists }, "the notice shows over the sheet")
        shot("stress-notice-over-bot-info")
        notice.tap()
        XCTAssertTrue(stage.waitForExistence(timeout: 10), "S23: the viewer opens on top")
        XCTAssertTrue(app.navigationBars["Ivy’s Browser"].exists)
        app.buttons["browser.close"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { !self.stage.exists && self.app.collectionViews["bot-info.list"].exists }, "S23: closing returns to Bot Info")
        closeBotInfo()
    }

    /// S24: the Ask button tapped twice quickly.
    @MainActor func test17_AskTappedTwice() throws {
        try account.control("/__fixture/browser", ["plugin": "missing"])
        launch()
        openChat("ivy")
        let item = openMoreMenu()
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        let ask = app.buttons["browser.empty.action"]
        XCTAssertTrue(ask.waitForExistence(timeout: 10))
        // Two taps at the same place on the screen (the button is gone after the first).
        let frame = ask.frame
        let spot = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY))
        spot.tap(); spot.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { self.chatTitle().contains("Hermes") && self.chatSays(Self.installTitle) })
        dismissOffer(wait: 3)
        pause(2)
        XCTAssertEqual(installSubmits().count, 1, "S24: one request")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "chat.queue.item").count, 0, "S24: none left over in the queue")
    }

    /// L480 from Bot Info: Bot Info › Computer › Watch Browser › Ask Hermes to Install It. Bot Info closes too, so the
    /// main bot's chat and the request are seen (they used to open, and be sent, underneath the sheet).
    @MainActor func test22_AskFromBotInfoClosesTheSheet() throws {
        try account.control("/__fixture/browser", ["plugin": "missing"])
        launch()
        openBotInfo("ivy")
        let watch = app.buttons["bot-info.browser.watch"]
        XCTAssertTrue(watch.waitForExistence(timeout: 5), "Bot Info has Watch Browser")
        watch.tap()
        XCTAssertTrue(app.staticTexts["Watch Your Bots Browse"].waitForExistence(timeout: 10), "the setup screen shows over Bot Info")
        let ask = app.buttons["browser.empty.action"]
        XCTAssertTrue(ask.exists && ask.label.contains("Ask Hermes to Install It"), ask.label)
        ask.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.app.collectionViews["bot-info.list"].exists }, "Bot Info closes with the viewer")
        let opened = secondsUntil(timeout: 10) { self.chatTitle().contains("Hermes") && self.chatSays(Self.installTitle) }
        XCTAssertNotNil(opened, "the main bot's chat is on screen with the request as a bubble (title: \(chatTitle()))")
        measure("Bot Info › Watch Browser › Ask Hermes to Install It → request in the main bot's chat: \(String(format: "%.2f", opened ?? -1)) s")
        dismissOffer(wait: 3)
        XCTAssertFalse(app.buttons["browser.close"].exists, "the viewer closed")
        XCTAssertTrue(app.textViews["composer.text"].isHittable, "the chat is on top: its field can be tapped")
        XCTAssertTrue(waitUntil(timeout: 8) { self.installSubmits().count == 1 }, "exactly one prompt went to the gateway")
        let typed = (app.textViews["composer.text"].value as? String) ?? ""
        XCTAssertFalse(typed.localizedCaseInsensitiveContains("install"), "nothing is left in the field: \(typed)")
        shots("ask-hermes-from-bot-info")
        pause(3)
        XCTAssertEqual(installSubmits().count, 1, "once")
    }

    /// S23, with an alert in the way: Ivy's viewer is open with an alert over it when Hermes starts browsing. Watch
    /// waits for the alert (it is the person's to answer), offers itself again when the wait runs out, and once the
    /// alert is answered swaps to Hermes's viewer: one viewer, and its ✕ returns to the page underneath.
    @MainActor func test23_WatchWithAnAlertOverAnotherViewer() throws {
        presence(["browsers": [["profile": "ivy", "active": true, "url": "https://example.test/sign-in"],
                               ["profile": "default", "active": true, "url": "https://docs.example.test/guide"]]])
        launch(["-HQDebugScreenRow", "YES"])
        bind("ivy")
        bind("default")
        toolStart("ivy", "browser_navigate")
        XCTAssertTrue(waitUntil(timeout: 6) { self.notice.exists && self.notice.label == "Ivy is using its browser" })
        notice.tap()
        XCTAssertTrue(stage.waitForExistence(timeout: 10), "Ivy's viewer opens")
        XCTAssertTrue(app.navigationBars["Ivy’s Browser"].exists)
        XCTAssertTrue(waitUntil(timeout: 15) { self.framesShown() >= 5 }, "and draws (\(stageValue()))")

        // An alert over Ivy's viewer: the stand-in screen opener's, from Hermes's screen notice.
        toolStart("default", "computer_use_click")
        XCTAssertTrue(waitUntil(timeout: 6) { self.notice.exists && self.notice.label == "Hermes is using its screen" })
        let stamped = Date()
        notice.tap()
        let alert = app.alerts["Screen"]
        XCTAssertTrue(alert.waitForExistence(timeout: 8), "an alert sits over Ivy's viewer")

        // Hermes's 30 s pass; it starts browsing. Its notice shows over the alert.
        let wait = 31 - Date().timeIntervalSince(stamped)
        if wait > 0 { pause(wait) }
        toolStart("default", "browser_navigate")
        XCTAssertTrue(waitUntil(timeout: 6) { self.notice.exists && self.notice.label == "Hermes is using its browser" }, "the notice shows with the alert up")
        shot("stress-notice-over-alert-over-viewer")
        // XCTest answers an alert that is in the way of a tap by itself (its default handler taps Cancel), which would
        // do for the person exactly what the app must not. A monitor that claims the alert and leaves it alone keeps it
        // up, as a finger on the notice does.
        let leaveIt = addUIInterruptionMonitor(withDescription: "the person's alert stays") { _ in true }
        defer { removeUIInterruptionMonitor(leaveIt) }
        tapNoticeByPoint()
        XCTAssertTrue(waitUntil(timeout: 3) { !self.notice.exists }, "the tap took the notice")
        // The alert is not answered for the person, and Ivy's viewer is not torn down under it.
        pause(2)
        XCTAssertTrue(alert.exists, "D22: the alert is still there")
        XCTAssertTrue(app.navigationBars["Ivy’s Browser"].exists, "and so is Ivy's viewer")
        XCTAssertFalse(app.navigationBars["Hermes’s Browser"].exists)
        // The wait runs out (about 5 s): Watch is on offer again, not dropped.
        XCTAssertTrue(waitUntil(timeout: 8) { self.notice.exists && self.notice.label == "Hermes is using its browser" }, "Watch is offered again when the wait runs out")
        XCTAssertTrue(alert.exists, "the alert is still the person's")
        tapNoticeByPoint()
        pause(1)
        XCTAssertTrue(alert.exists)
        alert.buttons["OK"].tap()

        XCTAssertTrue(waitUntil(timeout: 12) { self.app.navigationBars["Hermes’s Browser"].exists }, "answered: Watch swaps to Hermes's browser")
        XCTAssertTrue(waitUntil(timeout: 5) { !self.app.navigationBars["Ivy’s Browser"].exists }, "Ivy's viewer is gone")
        XCTAssertEqual(app.buttons.matching(identifier: "browser.close").count, 1, "exactly one viewer")
        XCTAssertTrue(waitUntil(timeout: 15) { self.framesRising(within: 3) }, "Hermes's frames draw")
        XCTAssertTrue(waitUntil(timeout: 8) { (self.app.textFields["browser.address"].value as? String) == "docs.example.test" }, "its own page")
        XCTAssertLessThanOrEqual(count("max_watch_sockets"), 1, "one viewer socket at a time")
        // ✕ works and returns to the page underneath: no frozen viewer left behind.
        app.buttons["browser.close"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.stage.exists && !self.app.buttons["browser.close"].exists }, "✕ closes it")
        XCTAssertTrue(waitUntil(timeout: 5) { self.row("ivy").isHittable }, "back on the Bots list")
        XCTAssertTrue(waitUntil(timeout: 10) { self.count("watch_sockets") == 0 }, "no socket left open")
        openChat("ivy")
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 8), "and the app answers")
    }

    /// L480 from a viewer the notice's Watch opened over a sheet (Bot Info for another bot): Ask Hermes to Install It
    /// closes the viewer and the sheet under it, and the request is seen in the main bot's chat, sent once.
    @MainActor func test24_AskFromAViewerOpenedOverASheet() throws {
        try account.control("/__fixture/browser", ["plugin": "missing"])
        launch()
        bind("ivy")
        openBotInfo("default")
        toolStart("ivy", "browser_navigate")
        XCTAssertTrue(waitUntil(timeout: 6) { self.notice.exists }, "the notice shows over Bot Info")
        notice.tap()
        let ask = app.buttons["browser.empty.action"]
        XCTAssertTrue(ask.waitForExistence(timeout: 10), "Watch opens the setup screen over the sheet")
        ask.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.app.collectionViews["bot-info.list"].exists }, "the sheet under the viewer closes too")
        XCTAssertTrue(waitUntil(timeout: 10) { self.chatTitle().contains("Hermes") && self.chatSays(Self.installTitle) }, "the request is seen in the main bot's chat")
        dismissOffer(wait: 3)
        XCTAssertTrue(waitUntil(timeout: 8) { self.installSubmits().count == 1 })
        pause(2)
        XCTAssertEqual(installSubmits().count, 1)
    }

    // MARK: Relaunch

    /// S25, S26: nothing about presence is stored: a relaunch starts clean and fills in again.
    @MainActor func test18_RelaunchStartsClean() throws {
        launch()
        bind("ivy")
        toolStart("ivy", "computer_use_click")
        XCTAssertTrue(waitUntil(timeout: 6) { self.rowSays("ivy", "Using its computer") })
        app.terminate()
        launch()
        pause(2)
        XCTAssertFalse(rowSays("ivy", "Using its computer"), "S25: the line is not stored")
        bind("ivy")
        toolStart("ivy", "computer_use_click")
        XCTAssertTrue(waitUntil(timeout: 6) { self.rowSays("ivy", "Using its computer") }, "S25: a new start brings it back")

        presence(["browsers": [["profile": "ivy", "active": true, "url": "https://example.test/sign-in"]]])
        XCTAssertTrue(waitUntil(timeout: 8) { self.rowSays("ivy", "Browsing example.test") })
        app.terminate()
        launch()
        let back = secondsUntil(timeout: 8) { self.rowSays("ivy", "Browsing example.test") }
        XCTAssertNotNil(back, "S26: the browser line is back after a relaunch")
        measure("relaunch: Bots list on screen → Browsing line: \(String(format: "%.2f", back ?? -1)) s")
    }

    /// D29: the install request keeps its short title after a relaunch (the gateway stores the whole prompt, which names
    /// the plugin's old wire name): the main bot's chat shows the title and that name is nowhere on screen.
    @MainActor func test25_TheRequestKeepsItsTitleAfterARelaunch() throws {
        try account.control("/__fixture/browser", ["plugin": "missing"])
        launch()
        openChat("ivy")
        let item = openMoreMenu()
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        let ask = app.buttons["browser.empty.action"]
        XCTAssertTrue(ask.waitForExistence(timeout: 10))
        ask.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { self.chatTitle().contains("Hermes") && self.chatSays(Self.installTitle) })
        dismissOffer(wait: 3)
        XCTAssertTrue(waitUntil(timeout: 8) { self.installSubmits().count == 1 })
        XCTAssertTrue(waitUntil(timeout: 20) { ((try? self.account.control("/__fixture/state"))?["running"] as? [String: Any])?["default"] as? Bool == false }, "its reply ends")
        pause(3)

        app.terminate()
        launch()
        openChat("default")
        XCTAssertTrue(waitUntil(timeout: 10) { self.chatSays(Self.installTitle) }, "D29: the title after a relaunch")
        pause(3)                                    // past the first paint from the cache and the read that follows it
        XCTAssertTrue(chatSays(Self.installTitle), "D29: and it stays once the gateway's rows are in")
        XCTAssertFalse(chatSays(Self.installPrefix), "D29: the stored prompt never shows")
        let old = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'dispatch' OR value CONTAINS[c] 'dispatch'")).firstMatch
        XCTAssertFalse(old.exists, "D29: the plugin's old name is nowhere on screen: \(old.exists ? old.label : "")")
        shots("ask-hermes-after-relaunch")
        XCTAssertEqual(installSubmits().count, 1, "reading it back sent nothing")
    }

    /// S27: the switch off survives a kill and a relaunch (no notice), and on again brings the notices back.
    @MainActor func test20_SwitchOffSurvivesARelaunch() throws {
        launch()
        openBotInfo("ivy")
        tapSwitch("bot-info.computer.alert")
        XCTAssertTrue(waitUntil(timeout: 10) { self.storedMeta("ivy")["screenAutoOpen"] as? Bool == false }, "off is saved")
        closeBotInfo()
        app.terminate()
        launch()
        openBotInfo("ivy")
        XCTAssertFalse(switchIsOn("bot-info.computer.alert"), "S27: still off after a relaunch")
        closeBotInfo()
        bind("ivy")
        toolStart("ivy", "browser_navigate")
        XCTAssertTrue(waitUntil(timeout: 6) { self.rowSays("ivy", "Using its computer") }, "the row still says it")
        pause(2)
        XCTAssertFalse(notice.exists, "S27: no notice while it is off")
        openBotInfo("ivy")
        tapSwitch("bot-info.computer.alert")
        XCTAssertTrue(waitUntil(timeout: 10) { self.storedMeta("ivy")["screenAutoOpen"] as? Bool == true }, "S27: on is saved")
        closeBotInfo()
        toolStart("ivy", "browser_click")
        XCTAssertTrue(waitUntil(timeout: 6) { self.notice.exists }, "S27: notices again once it is on")
    }

    /// S8: a gateway with no browser plugin costs the Bots list its first question and nothing after it.
    @MainActor func test21_NoPluginNoChatter() throws {
        try account.control("/__fixture/browser", ["plugin": "missing"])
        launch()
        pause(6)
        let asked = count("health_calls"), dials = count("activity_opens")
        let watch: TimeInterval = long ? 180 : 60
        pause(watch)
        XCTAssertEqual(app.state, .runningForeground)
        let after = count("health_calls")
        measure("no plugin, Bots list on screen \(Int(watch)) s: \(after - asked) more health questions (\(asked) at the start), \(count("activity_opens") - dials) list dials")
        XCTAssertEqual(after, asked, "S8: no polling for a plugin that is not there")
        XCTAssertEqual(count("activity_opens"), dials, "S8: no list dials")
        XCTAssertEqual(count("activity_sockets"), 0)
    }

    // MARK: Accessibility sizes

    /// S30–S32: the largest and the smallest text sizes.
    @MainActor func test19_TextSizes() throws {
        presence(["browsers": [["profile": "ivy", "active": true, "url": "https://a-rather-long-host-name.example.test/sign-in"]]])
        launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        bind("default")
        XCTAssertTrue(waitUntil(timeout: 8) { self.rowSays("ivy", "Browsing a-rather-long-host-name.example.test") }, "S30: the line shows at the largest size")
        shots("stress-ax5-bots-rows")
        toolStart("default", "browser_navigate")
        XCTAssertTrue(waitUntil(timeout: 6) { self.notice.exists })
        let screen = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(notice.frame.height, 64)
        XCTAssertGreaterThanOrEqual(notice.frame.minX, 0)
        XCTAssertLessThanOrEqual(notice.frame.maxX, screen.maxX, "S32: inside the screen at the largest size")
        XCTAssertLessThanOrEqual(notice.frame.height, 160, "S32: the text is capped, the capsule stays a banner")
        shots("stress-ax5-notice")
        notice.swipeUp()
        openBotInfo("ivy")
        let toggle = app.switches["bot-info.computer.alert"]
        for _ in 0..<4 where !toggle.isHittable { app.collectionViews["bot-info.list"].swipeUp() }
        XCTAssertTrue(toggle.exists, "S31: the switch shows")
        XCTAssertLessThanOrEqual(toggle.frame.maxX, screen.maxX, "S31: the switch is not pushed off screen")
        shots("stress-ax5-bot-info-computer")
        closeBotInfo()

        app.terminate()
        launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXS"])
        bind("default")
        toolStart("default", "browser_navigate")
        XCTAssertTrue(waitUntil(timeout: 6) { self.notice.exists })
        XCTAssertGreaterThanOrEqual(notice.frame.height, 64, "S32: still 64 pt tall at the smallest size")
        shots("stress-xs-notice")
        notice.tap()
        XCTAssertTrue(app.buttons["browser.close"].waitForExistence(timeout: 10), "S32: and tappable")
        app.buttons["browser.close"].tap()
    }
}

/// The two waits the spec times once (A3 and E8). Slow by nature: about two and a half minutes.
final class PresenceTimingTests: PresenceUITestCase {
    /// E8: left alone, the notice leaves after 8 s.
    @MainActor func test1_TheNoticeLeavesAfterEightSeconds() throws {
        launch(hold: false)
        bind("ivy")
        toolStart("ivy", "browser_navigate")
        XCTAssertTrue(waitUntil(timeout: 6) { self.notice.exists })
        let shown = Date()
        XCTAssertTrue(waitUntil(timeout: 14) { !self.notice.exists }, "E8: it leaves by itself")
        let stayed = Date().timeIntervalSince(shown)
        measure("the notice stayed \(String(format: "%.1f", stayed)) s (8 s, plus its exit and the test's polling)")
        XCTAssertGreaterThan(stayed, 6.5, "E8: not early")
        XCTAssertLessThan(stayed, 10.5, "E8: not late")
    }

    /// §8.3: a resting finger holds the notice past its 8 s, and lifting it is still a tap on Watch.
    @MainActor func test3_AFingerOnTheNoticeHoldsIt() throws {
        presence(["browsers": [["profile": "ivy", "active": true, "url": "https://example.test/sign-in"]]])
        launch(hold: false)
        bind("ivy")
        toolStart("ivy", "browser_navigate")
        XCTAssertTrue(waitUntil(timeout: 6) { self.notice.exists })
        let down = Date()
        notice.press(forDuration: 11)               // well past the 8 s
        let held = Date().timeIntervalSince(down)
        XCTAssertGreaterThan(held, 10, "the press lasted past the notice's own time")
        // The lift found the notice still there: Watch ran.
        XCTAssertTrue(stage.waitForExistence(timeout: 10), "§8.3: held past 8 s, the lift still opens the viewer")
        XCTAssertTrue(app.navigationBars["Ivy’s Browser"].exists)
        measure("a finger held the notice \(String(format: "%.1f", held)) s (it leaves by itself after 8 s) and the lift opened the viewer")
        app.buttons["browser.close"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { !self.stage.exists })

        // A drag that springs back (pulled down a little, let go) is not a tap, and the notice starts its 8 s again.
        pause(31 - min(31, Date().timeIntervalSince(down)))
        toolStart("ivy", "browser_click")
        XCTAssertTrue(waitUntil(timeout: 6) { self.notice.exists })
        let from = notice.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: 0, dy: 60)))
        pause(1.5)
        XCTAssertFalse(stage.exists, "a drag is not a tap on Watch")
        XCTAssertTrue(notice.exists, "pulled down, it springs back and stays")
        XCTAssertTrue(waitUntil(timeout: 12) { !self.notice.exists }, "and then leaves on its own time")
    }

    /// A3: with no reply finishing, the row falls back 90 s after the last screen tool; a second one moves the end.
    @MainActor func test2_TheRowFallsBackAfterNinetySeconds() throws {
        launch()
        bind("ivy")
        toolStart("ivy", "computer_use_click")
        XCTAssertTrue(waitUntil(timeout: 6) { self.rowSays("ivy", "Using its computer") })
        pause(20)
        toolStart("ivy", "computer_use_click")
        let last = Date()
        pause(80)
        XCTAssertTrue(rowSays("ivy", "Using its computer"), "A3: still there 80 s after the last tool (100 s after the first)")
        // Each look at the row is an accessibility query, and on a busy Mac one look takes seconds (stress round 1
        // read 95.3 s, the repair 96.9 s and 99.1 s, with the line gone by hand at 92 s). So the test brackets the
        // moment instead of taking the end of a slow look for it: the line was last seen at `seenAt` (the start of
        // the last look that found it) and was gone by `after` (the end of the first look that did not). The
        // fall-back happened between the two; both ends are asserted, and neither limit moved.
        var seenAt = 80.0
        var looks = 0
        XCTAssertTrue(waitUntil(timeout: 30) {
            let began = Date().timeIntervalSince(last)
            let there = self.rowSays("ivy", "Using its computer")
            looks += 1
            if there { seenAt = began }
            return !there
        }, "A3: it falls back by itself")
        let after = Date().timeIntervalSince(last)
        measure("the row fell back between \(String(format: "%.1f", seenAt)) s and \(String(format: "%.1f", after)) s after the last screen tool (90 s; \(looks) looks)")
        XCTAssertGreaterThan(after, 89, "A3: not early")
        XCTAssertLessThan(seenAt, 94, "A3: not late: the line was still there \(seenAt) s after the last tool")
    }
}
