// [sessions-m9] Session Info (docs/spec/3x-sessions.md §10; acceptance F1-F8), against
// scripts/fixtures/sessions-gateway.py. A row with a note reads "value, note"; one without reads its value.

import XCTest

extension SessionsTests {
    /// The gateway as the sheet names it: host and port.
    var gatewayHost: String {
        guard let url = URL(string: account.url), let host = url.host else { return account.url }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    @MainActor func closeSheet(_ app: XCUIApplication) {
        app.buttons["sheet.close"].firstMatch.tap()
        XCTAssertTrue(waitUntil(5) { !app.tables["info.list"].exists }, "the sheet closes")
    }

    /// F1, F2, F7: the sheet's title and head, the model with its provider, the usage rows, then Messages, Folder with
    /// its branch, the bot's name, the gateway and the id. One `session.usage` ask, with only its two keys.
    @MainActor func test60_SessionInfoRows() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openChat(app, "s-trip")
        openSessionInfo(app)
        XCTAssertTrue(app.navigationBars["Chat Info"].exists, "the title is Chat Info")
        XCTAssertEqual(app.staticTexts["info.title"].label, "Trip to Lisbon", "the chat's title under the head")
        let model = infoRow(app, "Model")
        XCTAssertTrue(model.lowercased().contains("hermes") && model.lowercased().contains("nous"), "the model with its provider under it (\(model))")
        XCTAssertTrue(waitUntil(6) { self.infoRow(app, "Context") == "24%, 48.2K of 200K · 151.8K left" }, "Context (\(infoRow(app, "Context")))")
        XCTAssertEqual(infoRow(app, "Tokens"), "15.4K, 14.2K in · 1.2K out")
        XCTAssertEqual(infoRow(app, "Speed"), "64 tokens/s, 1.6 s a call · 9 calls")
        XCTAssertEqual(infoRow(app, "Cost"), "$0.34, Estimated")
        XCTAssertEqual(infoRow(app, "Messages"), "2")
        XCTAssertEqual(infoRow(app, "Folder"), "/home/hermes/reading, main", "the folder with its branch under it")
        XCTAssertEqual(infoRow(app, "Bot"), "Research", "the bot's name, not its id")
        XCTAssertEqual(infoRow(app, "Gateway"), "\(gatewayHost), Connected")
        XCTAssertEqual(infoRow(app, "Chat ID"), "s-trip")
        XCTAssertFalse(hasInfoRow(app, "Source"), "an app chat has no Source row")
        XCTAssertFalse(hasInfoRow(app, "Answered By"))
        // The rows in the web's order.
        let order = app.tables["info.list"].cells.allElementsBoundByIndex.map(\.identifier).filter { $0.hasPrefix("info.row.") }
        let expected = ["model", "context", "tokens", "speed", "cost", "messages", "folder", "bot", "gateway", "chat-id"].map { "info.row." + $0 }
        XCTAssertEqual(order.filter { expected.contains($0) }, expected, "the web's order (\(order))")
        shot(app, "F1-session-info")
        app.tables["info.list"].swipeUp()
        XCTAssertTrue(app.cells["info.copy-all"].waitForExistence(timeout: 4), "Copy Session Info closes the list")
        shot(app, "F2-session-info-end")
        // F7: one ask, two keys.
        let asks = rpc("session.usage")
        XCTAssertEqual(asks.count, 1, "one session.usage ask")
        XCTAssertTrue(Set(asks.first?.keys.map { $0 } ?? []).isSubset(of: ["session_id", "profile"]), "only session_id and profile (\(asks))")
        closeSheet(app)
        backToList(app)

        // Garden plan: an actual cost has no note.
        openChat(app, "s-garden")
        openSessionInfo(app)
        XCTAssertEqual(app.staticTexts["info.title"].label, "Garden plan")
        XCTAssertTrue(waitUntil(6) { self.infoRow(app, "Tokens") == "1.2K, 1K in · 230 out" }, infoRow(app, "Tokens"))
        XCTAssertEqual(infoRow(app, "Cost"), "$0.02", "an actual cost carries no note")
        XCTAssertEqual(infoRow(app, "Context"), "2%, 3.1K of 200K · 196.9K left")
        XCTAssertEqual(infoRow(app, "Calls"), "2", "no timings: the calls alone")
        XCTAssertEqual(infoRow(app, "Bot"), "Hermes")
        XCTAssertEqual(infoRow(app, "Folder"), "/home/hermes/app, main")
        shot(app, "F1-session-info-actual-cost")
    }

    /// F3, F4: a usage tick changes Tokens while the sheet is open; a fallback line adds "Answered By" and relabels
    /// the model "Chat Model"; "Primary model restored:" takes both back.
    @MainActor func test61_SessionInfoFollowsTheChat() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openChat(app, "s-trip")
        openSessionInfo(app)
        XCTAssertTrue(waitUntil(6) { self.infoRow(app, "Tokens") == "15.4K, 14.2K in · 1.2K out" }, infoRow(app, "Tokens"))
        fixture("/__fixture/emit", ["type": "session.usage", "session_id": "s-trip", "payload": ["usage": [
            "input": 20000, "output": 2000, "total": 22000, "context_used": 60000, "context_max": 200000, "context_percent": 30,
            "context_estimated": true, "cost_usd": 0.5]]])
        XCTAssertTrue(waitUntil(6) { self.infoRow(app, "Tokens") == "22K, 20K in · 2K out" }, "Tokens follows without reopening (\(infoRow(app, "Tokens")))")
        XCTAssertEqual(infoRow(app, "Context"), "~30%, 60K of 200K · 140K left", "an estimated context carries the ~")
        XCTAssertEqual(infoRow(app, "Cost"), "$0.50", "the live cost wins, with no Estimated note")
        shot(app, "F3-usage-tick")

        fixture("/__fixture/emit", ["type": "status.update", "session_id": "s-trip", "payload": [
            "kind": "fallback", "text": "Model fallback: hermes-4 via nous unavailable (rate limited); using hermes-3 via nous."]])
        XCTAssertTrue(waitUntil(6) { self.hasInfoRow(app, "Answered By") }, "Answered by appears")
        let answered = infoRow(app, "Answered By")
        XCTAssertTrue(answered.lowercased().contains("hermes") && answered.contains("is unavailable on the gateway (rate limited)"), answered)
        XCTAssertTrue(hasInfoRow(app, "Chat Model"), "the model row is relabelled")
        XCTAssertFalse(hasInfoRow(app, "Model"))
        let cells = app.tables["info.list"].cells.allElementsBoundByIndex.map(\.identifier).filter { $0.hasPrefix("info.row.") }
        XCTAssertEqual(Array(cells.prefix(2)), ["info.row.answered-by", "info.row.chat-model"], "Answered by comes first (\(cells))")
        shot(app, "F4-answered-by")
        fixture("/__fixture/emit", ["type": "status.update", "session_id": "s-trip", "payload": [
            "kind": "status", "text": "Primary model restored: hermes-4 via nous."]])
        XCTAssertTrue(waitUntil(6) { !self.hasInfoRow(app, "Answered By") }, "restored: Answered by goes")
        XCTAssertTrue(hasInfoRow(app, "Model") && !hasInfoRow(app, "Chat Model"))
        shot(app, "F4-restored")
    }

    /// F5: a chat that came from Telegram says so, and a chat with a reasoning effort names it. (A chat handed over from Telegram: it is listed with the app's
    /// chats and its `handoff_platform` names where it came from. Telegram's own threads are not in this list.)
    @MainActor func test62_SessionInfoSource() throws {
        setRow("s-tg", ["profile": "default", "title": "Dinner plans", "source": "desktop", "handoff_platform": "telegram", "last_active": nowSeconds - 300,
                        "reasoning_effort": "xhigh", "fast": true,
                        "messages": [["role": "user", "content": "Where shall we eat?"], ["role": "assistant", "content": "The place by the canal has a table at eight."]]])
        let app = launch()
        XCTAssertTrue(row(app, "s-tg").waitForExistence(timeout: 15), "the Telegram chat is listed")
        shot(app, "F5-telegram-row")
        openChat(app, "s-tg")
        openSessionInfo(app)
        XCTAssertEqual(infoRow(app, "Source"), "Telegram")
        XCTAssertEqual(infoRow(app, "Reasoning"), "Extra High · Fast", "the chat's reasoning effort, as the app names it")
        shot(app, "F5-reasoning")
        XCTAssertEqual(infoRow(app, "Chat ID"), "s-tg")
        app.tables["info.list"].swipeUp()                                // the Source row is below the fold
        XCTAssertTrue(app.cells["info.row.source"].isHittable, "the Source row scrolls in")
        shot(app, "F5-source-telegram")
    }

    /// F6: Copy Session Info copies every row with the raw ids and says "Copied"; a row's hold menu copies that row;
    /// a tap on Chat ID copies the id.
    @MainActor func test63_SessionInfoCopy() throws {
        removeTextOut("info-copy.txt")
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openChat(app, "s-trip")
        openSessionInfo(app)
        XCTAssertTrue(waitUntil(6) { self.infoRow(app, "Tokens") == "15.4K, 14.2K in · 1.2K out" })
        let list = app.tables["info.list"]
        list.swipeUp()
        let copyAll = app.cells["info.copy-all"]
        XCTAssertTrue(copyAll.waitForExistence(timeout: 4))
        copyAll.tap()
        XCTAssertTrue(app.descendants(matching: .any)["menus.hud"].waitForExistence(timeout: 4), "the HUD")
        XCTAssertEqual(app.descendants(matching: .any)["menus.hud"].label, "Copied")
        shot(app, "F6-copied")
        let copied = try XCTUnwrap(textOut("info-copy.txt"), "what went to the pasteboard")
        let lines = copied.components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("Model: hermes-4 (nous)"), "the raw model and provider ids (\(lines))")
        XCTAssertTrue(lines.contains("Context: 24% (48.2K of 200K · 151.8K left)"), copied)
        XCTAssertTrue(lines.contains("Speed: 64 tokens/s (1.6 s a call · 9 calls)"), copied)
        XCTAssertTrue(lines.contains("Tokens: 15.4K (14.2K in · 1.2K out)"), copied)
        XCTAssertTrue(lines.contains("Cost: $0.34 (Estimated)"), copied)
        XCTAssertTrue(lines.contains("Bot: Research (research)"), "the bot's name with its id (\(copied))")
        XCTAssertTrue(lines.contains("Chat ID: s-trip"), copied)
        XCTAssertTrue(lines.contains("Gateway: \(gatewayHost) (Connected)"), copied)

        // A tap on Chat ID copies the id.
        removeTextOut("info-copy.txt")
        app.cells["info.row.chat-id"].tap()
        XCTAssertEqual(textOut("info-copy.txt"), "s-trip")
        // A row's hold menu › Copy copies that row.
        removeTextOut("info-copy.txt")
        list.swipeDown()
        let tokens = app.cells["info.row.tokens"]
        XCTAssertTrue(tokens.waitForExistence(timeout: 4))
        tokens.press(forDuration: 1.0)
        let copy = app.buttons["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "the row's hold menu")
        shot(app, "F6-row-hold-menu")
        copy.tap()
        XCTAssertEqual(textOut("info-copy.txt"), "Tokens: 15.4K (14.2K in · 1.2K out)")
    }

    /// F8: with the gateway gone the Gateway row's note says so while the sheet is open, and "Connected" when it is back.
    @MainActor func test64_SessionInfoGatewayNote() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openChat(app, "s-trip")
        openSessionInfo(app)
        XCTAssertTrue(waitUntil(6) { self.infoRow(app, "Gateway") == "\(self.gatewayHost), Connected" }, infoRow(app, "Gateway"))
        fixture("/__fixture/mode", ["down": 900])                       // away until the test brings it back (no race with a clock)
        let away = ["Offline", "Reconnecting…", "Connecting…"].map { "\(gatewayHost), \($0)" }
        let wentAway = waitUntil(30) { away.contains(self.infoRow(app, "Gateway")) }
        if !wentAway { shot(app, "F8-FAILED-note-did-not-follow") }
        XCTAssertTrue(wentAway, "the note follows the link (\(infoRow(app, "Gateway")))")
        let said = infoRow(app, "Gateway")
        shot(app, "F8-gateway-away")
        XCTAssertEqual(infoRow(app, "Tokens"), "15.4K, 14.2K in · 1.2K out", "the live rows keep their last values")
        XCTAssertFalse(app.alerts.firstMatch.exists, "no alert of its own")
        XCTAssertTrue(away.contains(infoRow(app, "Gateway")), "still away while the gateway is (\(infoRow(app, "Gateway")))")
        fixture("/__fixture/mode", ["down": 0])
        XCTAssertTrue(waitUntil(90) { self.infoRow(app, "Gateway") == "\(self.gatewayHost), Connected" },
                      "Connected again once the gateway is back (was \(said), now \(infoRow(app, "Gateway")))")
        shot(app, "F8-gateway-back")
    }

    /// Tester 2026-10-27: the usage card with every figure Hermes sends (their mockup's numbers): Context with
    /// what is left and a bar, Tokens counting the cache reads, Cache with a bar, Speed, Cost with the model's price.
    /// iOS look, then Desktop Look.
    @MainActor func test66_SessionInfoUsageCard() throws {
        for (look, extra) in [("ios", [String]()), ("desktop", ["-HQDebugDesktopLook", "YES"])] {
            let app = launch(extra: extra)
            XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
            openChat(app, "s-trip")
            openSessionInfo(app)
            XCTAssertTrue(waitUntil(6) { self.hasInfoRow(app, "Speed") })
            fixture("/__fixture/emit", ["type": "session.usage", "session_id": "s-trip", "payload": ["usage": [
                "input": 342000, "prompt": 17100000, "output": 84800, "total": 17184800, "reasoning": 12400, "calls": 96,
                "compressions": 2, "context_used": 264000, "context_max": 1000000, "context_percent": 26,
                "context_estimated": false, "cache_hit_pct": 98, "avg_tps": 82.4, "avg_latency_s": 1.24, "cost_usd": 0.037]]])
            XCTAssertTrue(waitUntil(6) { self.hasInfoRow(app, "Cache") }, "Cache appears with the tick")
            XCTAssertEqual(infoRow(app, "Context"), "26%, 264K of 1M · 736K left · compressed 2×")
            XCTAssertEqual(infoRow(app, "Tokens"), "17.2M, 17.1M in · 84.8K out · 12.4K reasoning")
            XCTAssertEqual(infoRow(app, "Cache"), "98%, ~16.8M from cache · 342K new")
            XCTAssertEqual(infoRow(app, "Speed"), "82 tokens/s, 1.2 s a call · 96 calls")
            XCTAssertTrue(infoRow(app, "Cost").hasPrefix("$0.04"), infoRow(app, "Cost"))
            let order = app.tables["info.list"].cells.allElementsBoundByIndex.map(\.identifier).filter { $0.hasPrefix("info.row.") }
            let expected = ["context", "tokens", "cache", "speed", "cost"].map { "info.row." + $0 }
            XCTAssertEqual(order.filter { expected.contains($0) }, expected, "the card's order (\(order))")
            shot(app, "F-usage-card-\(look)")
            app.tables["info.list"].swipeUp()
            XCTAssertTrue(app.cells["info.row.cost"].waitForExistence(timeout: 4))
            shot(app, "F-usage-card-\(look)-2")
            closeSheet(app)
            app.terminate()
        }
    }

    /// §10.4: a new chat with nothing sent shows what it has; a chat on an older gateway opens without its usage rows.
    @MainActor func test65_SessionInfoStates() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        chip(app, "research").tap()
        app.buttons["sessions.compose"].tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 8), "the new chat")
        Thread.sleep(forTimeInterval: 1.0)
        openSessionInfo(app)
        XCTAssertEqual(app.staticTexts["info.title"].label, "New Chat", "the name the chat's own header gives it")
        XCTAssertTrue(hasInfoRow(app, "Model") && hasInfoRow(app, "Gateway") && hasInfoRow(app, "Chat ID"))
        XCTAssertEqual(infoRow(app, "Bot"), "Research")
        XCTAssertFalse(hasInfoRow(app, "Messages"), "nothing sent: no Messages row")
        XCTAssertFalse(hasInfoRow(app, "Cost"))
        shot(app, "F-new-chat-info")
        closeSheet(app)
        backToList(app)
        chip(app, nil).tap()

        // The largest text size: value and note stack under the label.
        app.terminate()
        let large = launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(row(large, "s-release").waitForExistence(timeout: 15))
        chip(large, "research").tap()
        openChat(large, "s-trip")
        openSessionInfo(large)
        XCTAssertTrue(waitUntil(6) { self.hasInfoRow(large, "Context") })
        shot(large, "F-ax5-session-info")
        large.tables["info.list"].swipeUp()
        shot(large, "F-ax5-session-info-2")
    }
}
