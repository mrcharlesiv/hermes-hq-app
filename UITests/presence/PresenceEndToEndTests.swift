// Presence end to end (docs/spec/3x-presence.md §13) against the presence fixture: a Bots row saying "Using its
// computer" and "Browsing …", Bot Info's Computer group and its switch, the "<bot> is using its browser / screen" notice
// with Watch, chat ⋯ › Watch Browser while offline, "Ask Hermes to Install It" queued in the main bot's chat, and the
// viewer coming back with the link. Run: scripts/e2e-presence.sh <UDID>. Screenshots go to build/shots (light and dark).

import XCTest

final class PresenceEndToEndTests: PresenceUITestCase {
    // MARK: 1. "Using its computer" on the bot's row (L211: A1, A2, A4, A5)

    @MainActor func test1_RowSaysUsingItsComputer() throws {
        launch()
        bind("ivy")
        XCTAssertFalse(rowSays("ivy", "Using its computer"))

        // A4: a tool that is not a screen tool changes nothing.
        toolStart("ivy", "terminal")
        // A5: a start in a chat nobody opened this run (Hermes's) is nobody's: ignored.
        toolStart("default", "computer_use_click")
        pause(2)
        XCTAssertFalse(rowSays("ivy", "Using its computer"), "terminal is not a screen tool")
        XCTAssertFalse(rowSays("default", "Using its computer"), "an event from a chat nobody opened is ignored")

        // A1: a screen tool in Ivy's chat.
        toolStart("ivy", "computer_use_click")
        let seen = secondsUntil(timeout: 5) { self.rowSays("ivy", "Using its computer") }
        XCTAssertNotNil(seen, "Ivy's row says Using its computer")
        measure("tool.start → row says Using its computer: \(String(format: "%.2f", seen ?? -1)) s (includes the test's own polling)")
        XCTAssertFalse(rowSays("default", "Using its computer"), "Hermes's row does not change")
        XCTAssertTrue(rowLabel("ivy").contains("Using its computer"), "VoiceOver reads the line: \(rowLabel("ivy"))")
        // [ship, m9] The Screen viewer is in this build, so the screen notice is offered (before the merge there was
        // none to open and this line asserted that no notice showed, DECISION D6).
        XCTAssertTrue(waitUntil(timeout: 5) { self.notice.exists && self.notice.label == "Ivy is using its screen" }, "the screen notice shows")
        shots("row-using-computer")

        // A2: the reply finished.
        try account.control("/__fixture/finish", ["profile": "ivy", "text": "Done on the computer."])
        let gone = secondsUntil(timeout: 5) { !self.rowSays("ivy", "Using its computer") }
        XCTAssertNotNil(gone, "the line goes back when the reply finishes")
        measure("message.complete → line gone: \(String(format: "%.2f", gone ?? -1)) s")

        // A4: a browser tool is a screen tool too; with no plugin row the line is the computer one…
        toolStart("ivy", "browser_navigate")
        XCTAssertTrue(waitUntil(timeout: 5) { self.rowSays("ivy", "Using its computer") }, "browser_navigate counts")
        // …and with a plugin row, where it is browsing wins.
        presence(["browsers": [["profile": "ivy", "active": true, "url": "https://example.test/sign-in"]]])
        XCTAssertTrue(waitUntil(timeout: 6) { self.rowSays("ivy", "Browsing example.test") }, "the browser line outranks it")
        XCTAssertFalse(rowSays("ivy", "Using its computer"))
        shot("row-browsing-over-computer")
    }

    // MARK: 2. "Browsing example.test" from the plugin's list (L504: B1–B7)

    @MainActor func test2_RowSaysBrowsing() throws {
        launch()
        XCTAssertFalse(rowSays("ivy", "Browsing"))
        presence(["browsers": [["profile": "ivy", "active": true, "url": "https://example.test/sign-in"]]])
        let seen = secondsUntil(timeout: 6) { self.rowSays("ivy", "Browsing example.test") }
        XCTAssertNotNil(seen, "B1: Ivy's row says where it is browsing")
        measure("plugin list frame → row says Browsing example.test: \(String(format: "%.2f", seen ?? -1)) s (includes the test's own polling)")
        XCTAssertFalse(rowSays("default", "Browsing"), "B1: Hermes's row is unchanged")
        // B7: VoiceOver reads the name, then the line.
        let label = rowLabel("ivy")
        XCTAssertTrue(label.hasPrefix("Ivy") && label.contains("Browsing example.test"), "B7: \(label)")
        shots("row-browsing")

        // B2: the bot asks for the person.
        presence(["browsers": [["profile": "ivy", "active": true, "url": "https://example.test/", "ask": "Sign in to Example"]]])
        XCTAssertTrue(waitUntil(timeout: 6) { self.rowSays("ivy", "Needs you in its browser") }, "B2")
        shots("row-needs-you")
        // B4: a page with no address to show.
        presence(["browsers": [["profile": "ivy", "active": true, "url": "about:blank"]]])
        XCTAssertTrue(waitUntil(timeout: 6) { self.rowSays("ivy", "Using its browser") }, "B4")
        // Two bots at once, each its own line.
        presence(["browsers": [["profile": "ivy", "active": true, "url": "https://news.example.test/a"],
                               ["profile": "default", "active": true, "url": "https://docs.example.test/b"]]])
        XCTAssertTrue(waitUntil(timeout: 6) { self.rowSays("ivy", "Browsing news.example.test") && self.rowSays("default", "Browsing docs.example.test") })
        shot("rows-two-bots-browsing")
        // B3: idle again.
        presence(["browsers": [["profile": "ivy", "active": false, "url": "https://example.test/"]]])
        XCTAssertTrue(waitUntil(timeout: 6) { !self.rowSays("ivy", "rowsing") && !self.rowSays("ivy", "its browser") && !self.rowSays("default", "Browsing") }, "B3")

        // B5: the list is read only while something shows it.
        presence(["browsers": [["profile": "ivy", "active": true, "url": "https://example.test/sign-in"]]])
        XCTAssertTrue(waitUntil(timeout: 6) { self.rowSays("ivy", "Browsing example.test") })
        XCTAssertEqual(count("activity_sockets"), 1, "one list socket for the Bots list")
        openChat("default")
        pause(4)                                 // past the 3 s linger: the chat's own card holds the socket
        XCTAssertEqual(count("activity_sockets"), 1, "B5: the chat's card keeps the one socket")
        goBack()
        app.tabBars.buttons["Sessions"].tap()
        pause(4)                                 // UX study #135: Sessions hears browser asks, on the same one socket
        XCTAssertEqual(count("activity_sockets"), 1, "B5: Sessions keeps the one socket for asks")
        app.tabBars.buttons["Jobs"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { self.count("activity_sockets") == 0 }, "B5: nothing shows the list: the socket closes")
        app.tabBars.buttons["Bots"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.count("activity_sockets") == 1 }, "B5: back on Bots it opens again")
        XCTAssertTrue(waitUntil(timeout: 6) { self.rowSays("ivy", "Browsing example.test") }, "B5: and the line is right")
        XCTAssertLessThanOrEqual(count("max_activity_sockets"), 1, "never two list sockets")

        // B6: a gateway without the plugin: no line, no socket, no retry loop.
        app.terminate()
        try account.control("/__fixture/presence/reset", [:])
        try account.control("/__fixture/browser", ["plugin": "missing"])
        launch()
        pause(4)
        let asked = count("health_calls")
        pause(8)
        XCTAssertFalse(rowSays("ivy", "rowsing"))
        XCTAssertEqual(count("activity_sockets"), 0, "B6: no list socket without the plugin")
        XCTAssertEqual(count("activity_opens"), 0, "B6: none was even tried")
        XCTAssertEqual(count("health_calls"), asked, "B6: the plugin is not asked for again and again (\(asked) looks at launch)")
        XCTAssertLessThanOrEqual(asked, 4, "B6: one look per name, per subscribe")
    }

    // MARK: 3. Bot Info › Computer and its switch (L216, L507: C1–C3, D1–D4)

    @MainActor func test3_BotInfoComputerGroupAndSwitch() throws {
        launch()
        openBotInfo("ivy")
        // C1: the group, with its rows; no "Browser" group remains.
        let header = app.staticTexts.matching(NSPredicate(format: "label ==[c] 'Computer'")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5), "C1: the group is called Computer")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label ==[c] 'Browser'")).firstMatch.exists, "C1: no Browser group")
        let watch = app.buttons["bot-info.browser.watch"]
        XCTAssertTrue(watch.exists && watch.label.contains("Watch Browser") && watch.label.contains("See its browser live, or take it over"), "C1: \(watch.label)")
        XCTAssertTrue(app.buttons["bot-info.browser.choice"].waitForExistence(timeout: 8), "C1: Profile and Window sits in the group")
        let toggle = app.switches["bot-info.computer.alert"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "C1: the switch")
        XCTAssertTrue(toggle.label.contains("Alert When It Uses Its Computer"), toggle.label)
        XCTAssertLessThan(watch.frame.minY, app.buttons["bot-info.browser.choice"].frame.minY)
        XCTAssertLessThan(app.buttons["bot-info.browser.choice"].frame.minY, toggle.frame.minY, "C1: Watch Browser, Profile and Window, the switch")
        // D1: on by default, and reading the default wrote nothing.
        XCTAssertTrue(switchIsOn("bot-info.computer.alert"), "D1: on by default")
        XCTAssertTrue(configureCalls().isEmpty, "D1: nothing written")
        shots("bot-info-computer")

        // D2: off writes the bot's whole record plus the flag.
        tapSwitch("bot-info.computer.alert")
        XCTAssertTrue(waitUntil(timeout: 8) { self.configureCalls().count == 1 }, "D2: one write")
        let call = configureCalls()[0]
        XCTAssertEqual(call["name"] as? String, "ivy")
        let sent = ((call["ui_meta"] as? [String: Any])?["hermes-bots"] as? [String: Any]) ?? [:]
        XCTAssertEqual(sent["display_name"] as? String, "Ivy", "D2: the old record is kept")
        XCTAssertEqual(sent["screenAutoOpen"] as? Bool, false, "D2: plus the flag")
        XCTAssertEqual(sent.count, 2, "D2: and nothing else: \(sent)")
        XCTAssertTrue(waitUntil(timeout: 5) { !self.switchIsOn("bot-info.computer.alert") })
        XCTAssertEqual(storedMeta("ivy")["screenAutoOpen"] as? Bool, false)
        shots("bot-info-alert-off")

        // D2: relaunch: still off.
        app.terminate()
        launch()
        openBotInfo("ivy")
        XCTAssertTrue(app.switches["bot-info.computer.alert"].waitForExistence(timeout: 8))
        XCTAssertFalse(switchIsOn("bot-info.computer.alert"), "D2: off after a relaunch")
        XCTAssertEqual(configureCalls().count, 1, "reading it wrote nothing")

        // D4: the gateway did not save it: said, and the switch goes back.
        presence(["configure": "applied-false"])
        tapSwitch("bot-info.computer.alert")
        let failed = app.alerts["Couldn’t Change the Alert"]
        XCTAssertTrue(failed.waitForExistence(timeout: 10), "D4: the failure is said")
        XCTAssertTrue(failed.staticTexts["Your gateway didn’t save the change."].exists, "D4: in the app's words")
        XCTAssertTrue(failed.buttons["Try Again"].exists && failed.buttons["OK"].exists)
        shots("bot-info-alert-refused")
        failed.buttons["OK"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !self.switchIsOn("bot-info.computer.alert") }, "D4: back off")
        XCTAssertEqual(storedMeta("ivy")["screenAutoOpen"] as? Bool, false, "D4: the stored flag is unchanged")
        // An older gateway.
        presence(["configure": "old-gateway"])
        tapSwitch("bot-info.computer.alert")
        XCTAssertTrue(failed.waitForExistence(timeout: 10))
        XCTAssertTrue(failed.staticTexts["This gateway can’t save bot settings yet. Update Hermes on the computer running Hermes, then try again."].exists, "D4: the older-gateway words")
        failed.buttons["OK"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !self.switchIsOn("bot-info.computer.alert") })
        // Refused once, then Try Again saves it.
        presence(["configure": ["mode": "refuse", "count": 2]])      // the flip and its best-effort undo
        tapSwitch("bot-info.computer.alert")
        XCTAssertTrue(failed.waitForExistence(timeout: 10))
        XCTAssertTrue(failed.staticTexts["Synthetic refusal"].exists, "the gateway's own reason is shown")
        XCTAssertTrue(waitUntil(timeout: 8) { (self.presenceState()["configure"] as? String) == "ok" }, "the undo went out")
        failed.buttons["Try Again"].tap()
        // D3: on again is an explicit true.
        XCTAssertTrue(waitUntil(timeout: 10) { self.storedMeta("ivy")["screenAutoOpen"] as? Bool == true }, "D3: Try Again saved it")
        XCTAssertTrue(waitUntil(timeout: 5) { self.switchIsOn("bot-info.computer.alert") }, "D3: on")
        XCTAssertEqual(storedMeta("ivy")["display_name"] as? String, "Ivy", "the rest of the record survives every write")

        // C2: Watch Browser opens the viewer over the sheet; closing returns to Bot Info.
        app.buttons["bot-info.browser.watch"].tap()
        XCTAssertTrue(app.buttons["browser.close"].waitForExistence(timeout: 10), "C2: the viewer opens")
        XCTAssertTrue(app.navigationBars["Ivy’s Browser"].exists, "C2: for this bot")
        app.buttons["browser.close"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { !self.app.buttons["browser.close"].exists && self.app.collectionViews["bot-info.list"].exists }, "C2: back on Bot Info")

        // C3: the link is down: the rows dim and do nothing; back up they work again without reopening.
        presence(["gateway": "down"])
        let dimmed = secondsUntil(timeout: 20) { !self.app.switches["bot-info.computer.alert"].isEnabled && !self.app.buttons["bot-info.browser.watch"].isEnabled }
        XCTAssertNotNil(dimmed, "C3: Watch Browser and the switch are off while the gateway is away")
        measure("gateway down → Computer rows dimmed: \(String(format: "%.1f", dimmed ?? -1)) s")
        shots("bot-info-computer-offline")
        let infoList = app.collectionViews["bot-info.list"]
        let footer = app.staticTexts["You can change this bot again once its gateway is back."]
        // On screen, not only loaded below the fold: the screenshot is of the words.
        let screenBottom = app.windows.firstMatch.frame.maxY
        func footerShows() -> Bool { footer.exists && footer.frame.minY > 100 && footer.frame.maxY < screenBottom - 40 }
        for _ in 0..<14 where !footerShows() { nudge(infoList, up: true) }
        XCTAssertTrue(footer.waitForExistence(timeout: 5) && footerShows(), "C3: the footer says why")
        shot("bot-info-offline-footer")
        let dimmedWatch = app.buttons["bot-info.browser.watch"]
        for _ in 0..<16 where !(dimmedWatch.exists && dimmedWatch.isHittable) { nudge(infoList, up: false) }
        let writes = configureCalls().count
        dimmedWatch.tap()
        pause(1.5)
        XCTAssertFalse(app.buttons["browser.close"].exists, "C3: a dimmed Watch Browser opens nothing")
        XCTAssertEqual(configureCalls().count, writes)
        presence(["gateway": "up"])
        XCTAssertTrue(waitUntil(timeout: 45) { self.app.switches["bot-info.computer.alert"].isEnabled && self.app.buttons["bot-info.browser.watch"].isEnabled },
                      "C3: they work again when the gateway is back")
        tapSwitch("bot-info.computer.alert")
        XCTAssertTrue(waitUntil(timeout: 10) { self.storedMeta("ivy")["screenAutoOpen"] as? Bool == false }, "C3: the switch writes again")
        closeBotInfo()
    }

    // MARK: 4. The notice, Watch, and when it stays away (L506: E1–E6, E8's swipe)

    @MainActor func test4_NoticeWatchAndSkips() throws {
        presence(["browsers": [["profile": "ivy", "active": true, "url": "https://example.test/sign-in"],
                               ["profile": "default", "active": true, "url": "https://docs.example.test/guide"]]])
        launch()
        bind("ivy")
        bind("default")

        // E1: Ivy starts a browser tool while the Bots list is on screen.
        toolStart("ivy", "browser_navigate")
        let seen = secondsUntil(timeout: 6) { self.notice.exists }
        let first = Date()
        XCTAssertNotNil(seen, "E1: the notice shows")
        measure("tool.start → notice on screen: \(String(format: "%.2f", seen ?? -1)) s (includes the test's own polling)")
        XCTAssertEqual(notice.label, "Ivy is using its browser", "E1: the web app's words")
        XCTAssertEqual(notice.value as? String, "Watch")
        let frame = notice.frame
        XCTAssertGreaterThanOrEqual(frame.height, 64, "at least the peek's height")
        XCTAssertLessThan(frame.maxY, 200, "under the status bar, not over the list's middle")
        XCTAssertFalse(peek.exists, "one banner at a time")
        shots("notice-browser")
        // E3: the same again 5 s later: no second notice, the first stays as it is.
        pause(4)
        toolStart("ivy", "browser_click")
        pause(1)
        XCTAssertEqual(notice.label, "Ivy is using its browser")

        // E2: Watch opens Ivy's viewer.
        notice.tap()
        XCTAssertTrue(stage.waitForExistence(timeout: 10), "E2: Watch opens the viewer")
        XCTAssertTrue(app.navigationBars["Ivy’s Browser"].exists, "E2: Ivy's")
        XCTAssertTrue(waitUntil(timeout: 15) { self.framesShown() >= 10 }, "E2: frames draw (\(stageValue()))")
        XCTAssertTrue(waitUntil(timeout: 5) { !self.notice.exists }, "E2: the notice left")
        shots("notice-watch-opened-viewer")

        // E5: with Ivy's viewer open, Hermes starts browsing: the notice shows over the viewer, and its Watch closes
        // Ivy's viewer and opens Hermes's.
        toolStart("default", "browser_navigate")
        XCTAssertTrue(waitUntil(timeout: 6) { self.notice.exists && self.notice.label == "Hermes is using its browser" }, "E5: another bot still notifies")
        shots("notice-over-viewer")
        notice.tap()
        XCTAssertTrue(waitUntil(timeout: 12) { self.app.navigationBars["Hermes’s Browser"].exists }, "E5: Watch swaps to Hermes's browser")
        XCTAssertFalse(app.navigationBars["Ivy’s Browser"].exists)
        XCTAssertTrue(waitUntil(timeout: 15) { self.framesRising(within: 3) }, "E5: Hermes's frames draw")
        XCTAssertTrue(waitUntil(timeout: 8) { (self.app.textFields["browser.address"].value as? String) == "docs.example.test" }, "E5: its own page")
        XCTAssertLessThanOrEqual(count("max_watch_sockets"), 1, "E5: one viewer socket at a time")
        app.buttons["browser.close"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.stage.exists }, "the viewer closes")

        // E4: with Ivy's chat on screen there is no notice: the chat's own browser card says it.
        openChat("ivy")
        XCTAssertTrue(app.buttons["chat.shelf.browser"].waitForExistence(timeout: 10), "E4: the chat's card shows")
        let wait = 31 - Date().timeIntervalSince(first)
        if wait > 0 { pause(wait) }                 // past Ivy's 30 s: only the chat on screen can be the reason now
        toolStart("ivy", "browser_navigate")
        pause(3)
        XCTAssertFalse(notice.exists, "E4: no notice for the chat on screen")
        shots("chat-card-no-notice")
        goBack()

        // E3: 31 s after the first one, a notice again.
        toolStart("ivy", "browser_navigate")
        XCTAssertTrue(waitUntil(timeout: 6) { self.notice.exists && self.notice.label == "Ivy is using its browser" }, "E3: again after 30 s")
        let second = Date()
        // E8: a swipe up sends it away at once.
        notice.swipeUp()
        XCTAssertTrue(waitUntil(timeout: 3) { !self.notice.exists }, "E8: swiped away")

        // E6 / D6: Ivy's switch off: no notice for Ivy, Hermes still notifies.
        openBotInfo("ivy")
        tapSwitch("bot-info.computer.alert")
        XCTAssertTrue(waitUntil(timeout: 8) { self.storedMeta("ivy")["screenAutoOpen"] as? Bool == false })
        closeBotInfo()
        let rest = 31 - Date().timeIntervalSince(second)
        if rest > 0 { pause(rest) }                 // past the 30 s again, so the switch is the only reason
        toolStart("ivy", "browser_navigate")
        pause(3)
        XCTAssertFalse(notice.exists, "E6: off for Ivy")
        XCTAssertTrue(rowSays("ivy", "Browsing example.test"), "E6: its row still says what it does")
        toolStart("default", "browser_click")
        XCTAssertTrue(waitUntil(timeout: 6) { self.notice.exists && self.notice.label == "Hermes is using its browser" }, "E6: Hermes still notifies")
        shot("notice-hermes-after-ivy-off")
    }

    // MARK: 5. Chat ⋯ › Watch Browser, greyed with "Offline" while the link is down (L477: F1–F3)

    @MainActor func test5_ChatMenuOffline() throws {
        launch()
        openChat("default")
        // F1: enabled while the link is ready.
        var item = openMoreMenu()
        XCTAssertTrue(item.waitForExistence(timeout: 5), "F1: ⋯ has Watch Browser")
        XCTAssertTrue(item.isEnabled, "F1: enabled")
        XCTAssertFalse(item.label.contains("Offline"), item.label)
        shots("chat-menu-watch-browser")
        dismissMenu()

        // F2: the link is down.
        presence(["gateway": "down"])
        var offline = false
        for _ in 0..<15 where !offline {
            item = openMoreMenu()
            offline = item.waitForExistence(timeout: 3) && !item.isEnabled && item.label.contains("Offline")
            if !offline { dismissMenu(); pause(1) }
        }
        XCTAssertTrue(offline, "F2: greyed, with Offline under it: \(item.label)")
        XCTAssertTrue(item.label.hasPrefix("Watch Browser"), item.label)
        shots("chat-menu-watch-browser-offline")
        item.tap()
        pause(1.5)
        XCTAssertFalse(app.buttons["browser.close"].exists, "F2: a greyed item opens nothing")
        if item.exists { dismissMenu() }

        // F3: back up: enabled again, and it opens the viewer.
        presence(["gateway": "up"])
        var online = false
        for _ in 0..<30 where !online {
            item = openMoreMenu()
            online = item.waitForExistence(timeout: 3) && item.isEnabled && !item.label.contains("Offline")
            if !online { dismissMenu(); pause(1) }
        }
        XCTAssertTrue(online, "F3: enabled again once the link is back: \(item.label)")
        item.tap()
        XCTAssertTrue(app.buttons["browser.close"].waitForExistence(timeout: 10), "F1: it opens the viewer")
        app.buttons["browser.close"].tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 8))
    }

    // MARK: 6. "Ask Hermes to Install It" sends or queues the request in the main bot's chat (L480: G1–G3)

    @MainActor func test6_AskHermesQueues() throws {
        try account.control("/__fixture/browser", ["plugin": "missing"])
        launch()

        // G1: from Ivy's chat, with the main bot free: its chat opens and the request is sent at once.
        openChat("ivy")
        var item = openMoreMenu()
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        XCTAssertTrue(app.staticTexts["Watch Your Bots Browse"].waitForExistence(timeout: 10), "the setup screen shows")
        let ask = app.buttons["browser.empty.action"]
        XCTAssertTrue(ask.exists && ask.label.contains("Ask Hermes to Install It"), ask.label)
        shots("viewer-setup")
        ask.tap()
        let opened = secondsUntil(timeout: 10) { self.chatTitle().contains("Hermes") && self.chatSays(Self.installTitle) }
        XCTAssertNotNil(opened, "G1: the main bot's chat shows the request as a bubble (title: \(chatTitle()))")
        measure("Ask Hermes to Install It → request in the main bot's chat: \(String(format: "%.2f", opened ?? -1)) s")
        dismissOffer(wait: 3)                       // the app's offer after a first message sent
        XCTAssertFalse(app.buttons["browser.close"].exists, "G1: the viewer closed")
        XCTAssertTrue(waitUntil(timeout: 8) { self.installSubmits().count == 1 }, "G1: exactly one prompt went to the gateway")
        let field = app.textViews["composer.text"]
        let typed = (field.value as? String) ?? ""
        XCTAssertFalse(typed.contains("install") || typed.contains("Install"), "G1: nothing is left in the field for the person to send: \(typed)")
        XCTAssertFalse(chatSays(Self.installPrefix), "G1: the bubble shows the short title, not the long prompt")
        shots("ask-hermes-sent")
        XCTAssertTrue(waitUntil(timeout: 15) { ((try? self.account.control("/__fixture/state"))?["running"] as? [String: Any])?["default"] as? Bool == false }, "its reply ends")
        // The reply ended and the chat read its transcript again: the bubble still shows the title.
        pause(5)
        XCTAssertTrue(chatSays(Self.installTitle), "G1: the title stays after the reply")
        XCTAssertFalse(chatSays(Self.installPrefix), "G1: the stored prompt does not replace it")
        shot("ask-hermes-after-reply")

        // G2: with a reply running, the request waits in the chat's queue.
        try account.control("/__fixture/plan", ["plans": [["replyDelay": 90]]])
        send("Keep working on something long")
        XCTAssertTrue(waitUntil(timeout: 10) { ((try? self.account.control("/__fixture/state"))?["running"] as? [String: Any])?["default"] as? Bool == true }, "a reply runs")
        goBack()
        openChat("ivy")
        item = openMoreMenu()
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        XCTAssertTrue(ask.waitForExistence(timeout: 10))
        ask.tap()
        let queue = app.descendants(matching: .any)["chat.queue"]
        XCTAssertTrue(queue.waitForExistence(timeout: 10), "G2: the queue card shows")
        XCTAssertTrue(chatTitle().contains("Hermes"), "G2: in the main bot's chat: \(chatTitle())")
        let rows = app.descendants(matching: .any).matching(identifier: "chat.queue.item")
        XCTAssertEqual(rows.count, 1, "G2: one queued row")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", Self.installTitle)).firstMatch.exists, "G2: it shows the title")
        XCTAssertEqual(installSubmits().count, 1, "G2: nothing more was sent yet")
        shots("ask-hermes-queued")

        // G3: asked again while it waits: still one.
        goBack()
        openChat("ivy")
        item = openMoreMenu()
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        XCTAssertTrue(ask.waitForExistence(timeout: 10))
        ask.tap()
        XCTAssertTrue(queue.waitForExistence(timeout: 10))
        pause(1.5)
        XCTAssertEqual(rows.count, 1, "G3: asked twice, queued once")
        XCTAssertEqual(installSubmits().count, 1)

        // The reply finishes: the queue sends it, once.
        try account.control("/__fixture/finish", ["profile": "default", "text": "Long work finished."])
        XCTAssertTrue(waitUntil(timeout: 15) { self.installSubmits().count == 2 }, "G2: the queued request goes out after the reply")
        pause(3)
        XCTAssertEqual(installSubmits().count, 2, "G3: once, not twice")
        XCTAssertTrue(waitUntil(timeout: 8) { !queue.exists }, "the queue card is gone")
    }

    // MARK: 7. The viewer comes back by itself when the link returns (L485: H3, H4)

    @MainActor func test7_ViewerComesBackWithTheLink() throws {
        try account.control("/__fixture/browser", ["active": true])
        launch()
        openChat("default")
        let chip = app.buttons["chat.shelf.browser"]
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "the chat's browser card shows")
        chip.tap()
        XCTAssertTrue(stage.waitForExistence(timeout: 10), "the viewer opens")
        XCTAssertTrue(waitUntil(timeout: 15) { self.framesShown() >= 20 }, "frames draw (\(stageValue()))")

        // H3: 25 s without the gateway, so the viewer's back-off has grown to 8–10 s.
        presence(["gateway": "down"])
        pause(25)
        XCTAssertEqual(count("watch_sockets"), 0)
        XCTAssertTrue(stage.exists, "the viewer stays open through the outage")
        shots("viewer-reconnecting")
        presence(["gateway": "up"])
        let up = Date()
        XCTAssertTrue(waitUntil(timeout: 60) { self.count("ws_clients") >= 1 }, "the app's own link comes back")
        let ready = Date()
        let back = secondsUntil(timeout: 20) { self.count("watch_sockets") == 1 }
        XCTAssertNotNil(back, "H3: the viewer's socket is back")
        measure("link ready → viewer socket open: \(String(format: "%.2f", back ?? -1)) s (link ready \(String(format: "%.1f", ready.timeIntervalSince(up))) s after the gateway came up)")
        XCTAssertLessThan(back ?? 99, 3.5, "H3: at once, not after the rest of a 10 s back-off")
        XCTAssertTrue(framesRising(within: 6), "H3: frames draw again (\(stageValue()))")
        XCTAssertLessThanOrEqual(count("max_watch_sockets"), 1, "H3: never two viewer sockets")
        shot("viewer-back-live")

        // H4: the app goes to the background and returns: one socket.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(waitUntil(timeout: 10) { self.count("watch_sockets") == 0 }, "H4: hidden, the socket closes")
        app.activate()
        XCTAssertTrue(waitUntil(timeout: 15) { self.count("watch_sockets") == 1 }, "H4: back, one socket")
        XCTAssertTrue(framesRising(within: 8), "H4: frames again")
        XCTAssertLessThanOrEqual(count("max_watch_sockets"), 1, "H4: never two")
        app.buttons["browser.close"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { self.count("watch_sockets") == 0 }, "closing ends it")
    }

    // MARK: 8. The screen stream's hook: its row in the Computer group and the screen notice (C4, E7)

    /// [ship, m9] With the screen stream merged this runs against the real Bot Screen viewer, not the stand-in
    /// (`-HQDebugScreenRow` is no longer passed): the notice's Watch and Bot Info's Screen row both open it.
    @MainActor func test8_ScreenHookRowAndNotice() throws {
        launch()
        bind("default")
        bind("ivy")
        // E7: with a screen viewer to open, a computer_use start notifies.
        toolStart("ivy", "computer_use_click")
        XCTAssertTrue(waitUntil(timeout: 6) { self.notice.exists }, "E7: the screen notice shows")
        XCTAssertEqual(notice.label, "Ivy is using its screen", "E7: the web app's words")
        XCTAssertTrue(waitUntil(timeout: 5) { self.rowSays("ivy", "Using its computer") }, "and its row says so")
        shots("notice-screen")
        notice.tap()
        let close = app.buttons["screen.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "E7: Watch opens Ivy's Screen")
        XCTAssertTrue(app.navigationBars["Ivy’s Screen"].exists, "and it is Ivy's")
        shots("notice-watch-opens-screen")
        // While a Screen is up no notice shows (the web's gate), for any bot.
        toolStart("default", "computer_use_click")
        pause(3)
        XCTAssertFalse(notice.exists, "no notice while a Screen is open")
        close.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !close.exists }, "the Screen closes")

        // C4: the screen stream's row comes first in the one Computer group.
        openBotInfo("ivy")
        let screen = app.buttons["bot-info.screen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 5), "C4: the Screen row shows")
        XCTAssertLessThan(screen.frame.minY, app.buttons["bot-info.browser.watch"].frame.minY, "C4: above Watch Browser")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label ==[c] 'Computer'")).count, 1, "one Computer group, not two")
        shots("bot-info-computer-with-screen-row")
        screen.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 10), "the row opens the Screen over Bot Info")
        close.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !close.exists }, "the Screen closes")
        XCTAssertTrue(app.collectionViews["bot-info.list"].waitForExistence(timeout: 8), "Bot Info is there again")
    }

    // MARK: 9. The notice and the reply peek share the banner spot (E9)

    @MainActor func test9_PeekAndNoticeShareTheSpot() throws {
        try account.control("/__fixture/plan", ["plans": [["replyDelay": 90]]])
        launch()
        openChat("ivy")
        send("A question for Ivy")
        goBack()
        bind("default")

        toolStart("default", "browser_navigate")
        XCTAssertTrue(waitUntil(timeout: 6) { self.notice.exists && self.notice.label == "Hermes is using its browser" })
        // Ivy's reply lands: the peek takes the spot.
        try account.control("/__fixture/finish", ["profile": "ivy", "text": "Ivy's fixture reply is ready."])
        XCTAssertTrue(peek.waitForExistence(timeout: 15), "E9: the reply peek shows")
        XCTAssertTrue(waitUntil(timeout: 3) { !self.notice.exists }, "E9: and the notice left: never two banners")
        shots("peek-replaced-notice")
        // Ivy starts browsing: the notice takes it back.
        toolStart("ivy", "browser_navigate")
        XCTAssertTrue(waitUntil(timeout: 6) { self.notice.exists && self.notice.label == "Ivy is using its browser" }, "E9: the notice shows")
        XCTAssertTrue(waitUntil(timeout: 3) { !self.peek.exists }, "E9: and the peek left")
        shots("notice-replaced-peek")
    }
}
