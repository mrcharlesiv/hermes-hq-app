// Capabilities-stream stress checks (docs/spec/3x-capabilities.md §14) as repeatable UI tests against the stand-ins:
// a long list, fast repeated taps, a gateway that stalls or fails in the middle, and a relaunch in the middle.

import XCTest

extension CapabilitiesEndToEndTests {
    // MARK: - Load: hundreds of connectors

    @MainActor func testS1_ThreeHundredConnectors() throws {
        try control(gateway.url, "/__seed", ["servers": 300])
        let app = launch()
        let opened = Date()
        openCapabilities(app, tab: "Connectors")
        XCTAssertTrue(app.descendants(matching: .any)["connector-row-github"].waitForExistence(timeout: 15), "the list shows")
        XCTAssertLessThan(Date().timeIntervalSince(opened), 25, "and opens in reasonable time with 304 connectors")
        // Search finds one deep in the list.
        // The field folds behind the bar's magnifier (3x-morepages §5).
        let search = app.searchFields.firstMatch
        if !search.exists, app.buttons["capabilities.search"].exists { app.buttons["capabilities.search"].tap() }
        XCTAssertTrue(search.waitForExistence(timeout: 5), "the search field")
        search.tap(); search.typeText("server-287")
        let deep = app.descendants(matching: .any)["connector-row-server-287"]
        XCTAssertTrue(deep.waitForExistence(timeout: 8), "search reaches row 291")
        XCTAssertFalse(app.descendants(matching: .any)["connector-row-github"].exists, "and hides the rest")
        shot(app, "stress-connectors-search")
        // Its switch works from the filtered list.
        flip(app, "mcp-switch-server-287")
        XCTAssertTrue(waitUntil(timeout: 10) { self.server("server-287")["enabled"] as? Bool == false }, "the gateway turned it off")
        deep.tap()
        XCTAssertTrue(app.navigationBars["Server 287"].waitForExistence(timeout: 8), "and its page opens")
    }

    // MARK: - Fast repeated taps: the gateway ends where the switch ends

    @MainActor func testS2_RapidSwitchTapsSettle() throws {
        let app = launch()
        openCapabilities(app, tab: "Tools")
        let toggle = app.switches["toolset-switch-image_gen"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        reach(app, toggle)
        let target = toggle.switches.firstMatch.exists ? toggle.switches.firstMatch : toggle
        for _ in 0..<7 { target.tap() }
        Thread.sleep(forTimeInterval: 6)
        let shown = (toggle.value as? String) == "1"
        XCTAssertTrue(waitUntil(timeout: 10) { (self.toolset("image_gen")["enabled"] as? Bool) == ((toggle.value as? String) == "1") },
                      "the gateway and the switch agree after seven fast taps (switch \(shown), gateway \(String(describing: toolset("image_gen")["enabled"])))")
        XCTAssertFalse(app.alerts.firstMatch.exists, "no error came of it")
        // The same on a connector.
        switchList(app, to: "Connectors")
        let files = app.switches["mcp-switch-files"].firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        let inner = files.switches.firstMatch.exists ? files.switches.firstMatch : files
        for _ in 0..<7 { inner.tap() }
        Thread.sleep(forTimeInterval: 6)
        XCTAssertTrue(waitUntil(timeout: 10) { (self.server("files")["enabled"] as? Bool) == ((files.value as? String) == "1") },
                      "the gateway and the connector switch agree")
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    // MARK: - A slow save: Back waits for it, then leaves; nothing is lost or doubled

    @MainActor func testS3_BackDuringASlowSaveWaits() throws {
        let app = launch()
        openCapabilities(app, tab: "Connectors")
        let github = app.descendants(matching: .any)["connector-row-github"]
        XCTAssertTrue(github.waitForExistence(timeout: 10))
        github.tap()
        XCTAssertTrue(app.switches["mcp-tool-switch-list_issues"].waitForExistence(timeout: 10))
        flip(app, "mcp-tool-switch-list_issues")
        try control(gateway.url, "/__fail", ["target": "rpc:mcp.servers.add", "mode": "slow:4000", "count": 1])
        let save = app.buttons["mcp-tools-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        save.tap()   // a second tap while it saves does nothing
        app.navigationBars["GitHub"].buttons.firstMatch.tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(app.alerts.firstMatch.exists, "no discard question while a save is on its way")
        XCTAssertTrue(app.descendants(matching: .any)["connector-page"].exists, "the page holds until the gateway answers")
        XCTAssertTrue(waitUntil(timeout: 20) { github.exists && github.isHittable }, "then it leaves by itself")
        XCTAssertTrue(entryText("github").contains("list_issues"), "the rule was saved: \(entryText("github"))")
        let adds = ((state()["log"] as? [[String: Any]]) ?? []).filter { $0["name"] as? String == "mcp.servers.add" }
        XCTAssertEqual(adds.count, 1, "saved once")
        XCTAssertFalse(server("github").isEmpty)
    }

    // MARK: - The gateway stops answering in the middle of a switch: it goes back, says why, and works again after

    @MainActor func testS4_GatewayFailsMidWriteThenRecovers() throws {
        let app = launch()
        openCapabilities(app, tab: "Plugins")
        XCTAssertTrue(app.descendants(matching: .any)["plugin-row-web-clipper"].waitForExistence(timeout: 10))
        try control(gateway.url, "/__fail", ["target": "rpc:plugins.manage", "mode": "error", "count": 1])
        flip(app, "plugin-switch-catalog:web-clipper")
        XCTAssertTrue(waitUntil(timeout: 12) { app.alerts.firstMatch.exists || app.descendants(matching: .any)["plugins.notice"].exists
            || (app.switches["plugin-switch-catalog:web-clipper"].firstMatch.value as? String) == "0" }, "the failure is handled")
        shot(app, "stress-plugin-write-failed")
        if app.alerts.firstMatch.exists { app.alerts.firstMatch.buttons.allElementsBoundByIndex.last?.tap() }
        XCTAssertTrue(waitUntil(timeout: 8) { (app.switches["plugin-switch-catalog:web-clipper"].firstMatch.value as? String) == "0" }, "the switch went back")
        XCTAssertNotEqual(plugin("web-clipper")["status"] as? String, "enabled", "the gateway did not change")
        // Three failed list reads in a row: the page keeps its rows.
        try control(gateway.url, "/__fail", ["target": "rpc:plugins.manage", "mode": "error", "count": 3])
        Thread.sleep(forTimeInterval: 1.5)
        tapAdd(app, item: "Refresh")
        Thread.sleep(forTimeInterval: 4)
        XCTAssertTrue(app.descendants(matching: .any)["plugin-row-web-clipper"].exists, "a failed refresh keeps the last list")
        shot(app, "stress-plugins-refresh-failed")
        try control(gateway.url, "/__seed", ["clear_fail": true])
        flip(app, "plugin-switch-catalog:web-clipper")
        XCTAssertTrue(waitUntil(timeout: 12) { self.plugin("web-clipper")["status"] as? String == "enabled" }, "and the switch works once the gateway is back")
    }

    // MARK: - Relaunch in the middle of an install: the next launch shows what the gateway did

    @MainActor func testS5_RelaunchDuringSkillInstall() throws {
        var app = launch()
        openCapabilities(app, tab: "Skills")
        let get = app.buttons["skill-get-blender-mcp"]
        XCTAssertTrue(app.descendants(matching: .any)["skill-row-web-search"].waitForExistence(timeout: 10))
        for _ in 0..<6 where !get.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(get.waitForExistence(timeout: 5))
        reach(app, get)
        get.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.firstMatch.buttons["Install"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["skill-install-progress-blender-mcp"].waitForExistence(timeout: 8))
        app.terminate()
        // The stand-in's install only moves when it is asked how it is going, so the kill may leave it finished or
        // not. Either way the next launch must show the truth, with no stuck "Installing…" row, and Get must still work.
        app = launch()
        openCapabilities(app, tab: "Skills")
        XCTAssertTrue(app.descendants(matching: .any)["skill-row-web-search"].waitForExistence(timeout: 10))
        let done = installedSkills().contains { $0["name"] as? String == "blender-mcp" }
        let row = app.descendants(matching: .any)["skill-row-blender-mcp"]
        let again = app.buttons["skill-get-blender-mcp"]
        if done {
            XCTAssertTrue(waitUntil(timeout: 15) { row.exists }, "after a relaunch the skill is under Installed")
        } else {
            for _ in 0..<6 where !again.exists { app.swipeUp(velocity: .slow) }
            XCTAssertTrue(again.waitForExistence(timeout: 5), "an install the gateway has not finished is offered again, not shown as running")
            XCTAssertFalse(app.descendants(matching: .any)["skill-install-progress-blender-mcp"].exists, "no stuck progress row")
            reach(app, again)
            again.tap()
            XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
            app.alerts.firstMatch.buttons["Install"].tap()
            XCTAssertTrue(waitUntil(timeout: 30) { self.installedSkills().contains { $0["name"] as? String == "blender-mcp" } }, "and installs")
            for _ in 0..<6 where !row.exists { app.swipeDown(velocity: .slow) }
            XCTAssertTrue(waitUntil(timeout: 15) { row.exists }, "it moves to Installed")
        }
        XCTAssertEqual(installedSkills().filter { $0["name"] as? String == "blender-mcp" }.count, 1, "installed once, not twice")
    }

    // MARK: - Relaunch in the middle of a Connect Apps bot switch: no half state is shown as done

    @MainActor func testS6_ConnectAppsRelaunchMidSwitch() throws {
        try XCTSkipIf(composio.isEmpty, "needs the Composio stand-in")
        var app = launch(["-HQDebugResetConnectApps", "YES"], environment: ["HQN_CAP_AUTH": "allow", "HQN_COMPOSIO_BASE": composio])
        openConnectApps(app)
        let key = app.secureTextFields["connect-apps.key"]
        XCTAssertTrue(key.waitForExistence(timeout: 10))
        key.tap(); key.typeText("ak_mock_dispatch")
        app.buttons["connect-apps.continue"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["connect-apps.bots-row"].waitForExistence(timeout: 20))
        app.descendants(matching: .any)["connect-apps.bots-row"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["connect-bot-switch-ivy"].waitForExistence(timeout: 15))
        try control(gateway.url, "/__fail", ["target": "rpc:mcp.servers.add", "mode": "slow:5000", "count": 1])
        flip(app, "connect-bot-switch-ivy")
        Thread.sleep(forTimeInterval: 1.5)
        app.terminate()
        Thread.sleep(forTimeInterval: 6)
        app = launch(environment: ["HQN_CAP_AUTH": "allow", "HQN_COMPOSIO_BASE": composio])
        openConnectApps(app)
        XCTAssertTrue(app.descendants(matching: .any)["connect-apps.bots-row"].waitForExistence(timeout: 20), "the key survived the relaunch")
        app.descendants(matching: .any)["connect-apps.bots-row"].tap()
        let toggle = app.switches["connect-bot-switch-ivy"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        let onGateway = mcp("ivy").contains { $0["name"] as? String == "composio" }
        XCTAssertTrue(waitUntil(timeout: 8) { ((toggle.value as? String) == "1") == onGateway }, "the switch shows what the gateway has (\(onGateway))")
        // Whatever state the kill left, one more tap ends in a clean "on".
        if !onGateway { flip(app, "connect-bot-switch-ivy") }
        XCTAssertTrue(waitUntil(timeout: 15) { self.mcp("ivy").filter { $0["name"] as? String == "composio" }.count == 1 }, "Ivy has exactly one composio server")
        XCTAssertTrue(((state()["env"] as? [String: [String]])?["ivy"] ?? []).contains("COMPOSIO_API_KEY"))
    }
}
