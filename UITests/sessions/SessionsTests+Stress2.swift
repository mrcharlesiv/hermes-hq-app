// [sessions-m9] More of the stress plan (docs/spec/3x-sessions.md §14) as repeatable tests, against
// scripts/fixtures/sessions-gateway.py: a flood of usage events under the open sheet, the app going to the background
// and back with each new surface open, a launch with the gateway away, and (on the big seed) the app killed in the
// middle of Mark All as Read.

import XCTest

extension SessionsTests {
    /// The app leaves for the Home Screen and comes back.
    @MainActor func awayAndBack(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2.0)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "the app is back", file: file, line: line)
        Thread.sleep(forTimeInterval: 1.0)
    }

    /// `session.usage` again and again under the open sheet: the sheet shows the last one and still answers.
    @MainActor func test93_UsageFloodUnderTheSheet() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openChat(app, "s-trip")
        openSessionInfo(app)
        XCTAssertTrue(waitUntil(6) { self.infoRow(app, "Tokens") == "15.4K, 14.2K in · 1.2K out" }, infoRow(app, "Tokens"))
        let started = Date()
        for step in 1...150 {
            fixture("/__fixture/emit", ["type": "session.usage", "session_id": "s-trip", "payload": ["usage": [
                "input": 20000 + step * 100, "output": 2000, "total": 22000 + step * 100, "context_used": 60000, "context_max": 200000,
                "context_percent": 30, "cost_usd": 0.5 + Double(step) / 100]]])
        }
        print("USAGE-FLOOD 150 events in \(Date().timeIntervalSince(started)) s")
        XCTAssertTrue(waitUntil(6) { self.infoRow(app, "Tokens") == "37K, 35K in · 2K out" }, "the last tick shows (\(infoRow(app, "Tokens")))")
        XCTAssertEqual(infoRow(app, "Cost"), "$2.00", "and its cost")
        shot(app, "S-usage-flood")
        let closing = Date()
        closeSheet(app)
        XCTAssertLessThan(Date().timeIntervalSince(closing), 6, "the sheet still answers")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Background and foreground with the Filter menu open, with the New Project alert open (typed words kept) and
    /// with Session Info open.
    @MainActor func test94_BackgroundAndForeground() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        // The Filter menu. (The system may close a menu when the app leaves; either way it works afterwards.)
        openFilter(app)
        awayAndBack(app)
        if filterItem(app, "sort").exists { closeFilter(app) }
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 8), "the list is there")
        openFilter(app)
        tapFilter(app, "status", "status.unread")
        closeFilter(app)
        XCTAssertTrue(strip(app).waitForExistence(timeout: 4), "the menu still filters")
        strip(app).tap()
        // The New Project alert, with words typed.
        chip(app, "default").tap()
        openFilter(app)
        tapFilter(app, "project", "project.new")
        let alert = app.alerts["New Project"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "the New Project alert")
        let name = alert.textFields["project.name"]
        fill(name, "Site")
        awayAndBack(app)
        XCTAssertTrue(alert.waitForExistence(timeout: 6), "the alert is still up")
        XCTAssertEqual(alert.textFields["project.name"].value as? String, "Site", "with the words as typed")
        shot(app, "S-back-with-the-alert")
        press(alert.buttons["Cancel"])
        XCTAssertTrue(waitUntil(5) { !alert.exists })
        XCTAssertTrue(rpc("projects.create").isEmpty, "nothing was created")
        chip(app, nil).tap()
        // Session Info.
        openChat(app, "s-trip")
        openSessionInfo(app)
        XCTAssertTrue(waitUntil(6) { self.infoRow(app, "Tokens") == "15.4K, 14.2K in · 1.2K out" }, infoRow(app, "Tokens"))
        awayAndBack(app)
        XCTAssertTrue(app.tables["info.list"].waitForExistence(timeout: 6), "the sheet is still open")
        XCTAssertTrue(waitUntil(30) { self.infoRow(app, "Gateway") == "\(self.gatewayHost), Connected" }, "Connected again (\(infoRow(app, "Gateway")))")
        XCTAssertEqual(infoRow(app, "Tokens"), "15.4K, 14.2K in · 1.2K out", "the rows keep their values")
        shot(app, "S-back-with-session-info")
        closeSheet(app)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    /// A launch with the gateway away: the cached rows and the strip at first paint, filters and chips working, no
    /// alert of its own; when the gateway is back, what changed meanwhile arrives.
    @MainActor func test96_LaunchWithTheGatewayAway() throws {
        var app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openFilter(app)
        tapFilter(app, "status", "status.unread")
        closeFilter(app)
        XCTAssertTrue(strip(app).waitForExistence(timeout: 4))
        Thread.sleep(forTimeInterval: 2.0)                              // the view and the rows are saved
        app.terminate()
        fixture("/__fixture/mode", ["down": 900])                       // away until the test brings it back (no race with a clock)
        setRow("s-garden", ["title": "Garden plan, back online"])       // no event reaches anyone: the gateway is away
        app = launch(keepView: true)
        XCTAssertTrue(strip(app).waitForExistence(timeout: 6), "the strip at first paint")
        XCTAssertTrue(row(app, "s-budget").waitForExistence(timeout: 6), "the cached unread chat")
        XCTAssertFalse(app.alerts.firstMatch.exists, "no alert of its own")
        shot(app, "S-launch-gateway-away")
        strip(app).tap()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 6), "the filter clears on the cached rows")
        XCTAssertTrue(labelOf(row(app, "s-garden")).hasPrefix("Garden plan. "), "the cached title (\(labelOf(row(app, "s-garden"))))")
        chip(app, "research").tap()
        XCTAssertTrue(waitUntil(5) { let now = self.order(app); return now.contains("s-trip") && !now.contains("s-garden") }, "a chip filters the cached rows (\(order(app)))")
        chip(app, nil).tap()
        XCTAssertTrue(labelOf(row(app, "s-garden")).hasPrefix("Garden plan. "), "still the cached title while the gateway is away")
        fixture("/__fixture/mode", ["down": 0])
        XCTAssertTrue(waitUntil(120) { self.labelOf(self.row(app, "s-garden")).hasPrefix("Garden plan, back online. ") },
                      "back online, the new title arrives (\(labelOf(row(app, "s-garden"))))")
        XCTAssertFalse(app.alerts.firstMatch.exists, "still no alert")
        shot(app, "S-launch-gateway-back")
    }

    /// The app is killed in the middle of Mark All as Read (big seed, each write slowed): after relaunch the list
    /// matches the gateway (some read, some not), and a second Mark All as Read writes only the chats still unread.
    @MainActor func test95_Big_KilledDuringMarkAllAsRead() throws {
        try XCTSkipUnless(Self.bigSeed, "needs HQN_SESSIONS_SEED=big")
        func badge(_ app: XCUIApplication) -> Int { Int(String(sessionsBadge(app).prefix { $0.isNumber })) ?? 0 }
        var app = launch()
        XCTAssertTrue(waitUntil(30) { !self.order(app).isEmpty }, "the list")
        openFilter(app)
        tapFilter(app, "status", "status.unread")                          // a filter on: the deeper read holds all 200
        closeFilter(app)
        XCTAssertTrue(waitUntil(20) { badge(app) == 200 }, "200 unread chats held (\(sessionsBadge(app)))")
        strip(app).tap()
        fixture("/__fixture/fail", ["method": "PATCH", "path": "/api/sessions/", "prefix": true, "delay": 0.4, "count": 60])
        openFilter(app)
        tapFilter(app, "readall")
        XCTAssertTrue(waitUntil(30) { self.unreadWrites().count >= 20 }, "the writes are going out (\(unreadWrites().count))")
        app.terminate()
        Thread.sleep(forTimeInterval: 3.0)                              // whatever was in the air has landed
        let first = unreadWrites()
        XCTAssertLessThan(first.count, 200, "the app was stopped part-way (\(first.count))")
        XCTAssertEqual(Set(first.map(\.path)).count, first.count, "none repeated")
        app = launch()
        XCTAssertTrue(waitUntil(30) { !self.order(app).isEmpty }, "the list")
        openFilter(app)
        tapFilter(app, "status", "status.unread")
        closeFilter(app)
        XCTAssertTrue(waitUntil(25) { badge(app) == 200 - first.count }, "the list matches the gateway: \(200 - first.count) still unread (\(sessionsBadge(app)))")
        shot(app, "S-big-killed-mid-read")
        strip(app).tap()
        openFilter(app)
        XCTAssertTrue(filterItem(app, "readall").isEnabled)
        tapFilter(app, "readall")
        XCTAssertTrue(waitUntil(90) { self.unreadWrites().count >= 200 }, "the rest go out (\(unreadWrites().count))")
        Thread.sleep(forTimeInterval: 3.0)
        let all = unreadWrites()
        XCTAssertEqual(all.count, 200, "exactly the chats that were still unread")
        XCTAssertEqual(Set(all.map(\.path)).count, 200, "none repeated")
        XCTAssertTrue(waitUntil(15) { self.sessionsBadge(app).isEmpty }, "the badge reaches zero (\(sessionsBadge(app)))")
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }
}
