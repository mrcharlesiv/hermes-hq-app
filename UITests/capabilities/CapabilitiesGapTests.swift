// Capabilities-stream end-to-end checks added by spec revision 3 (docs/spec/3x-capabilities.md §17.5, §17.4): the
// pieces the first pass built but never drove, and the ones revision 3 asked for. Same stand-ins, same helpers.

import XCTest

extension CapabilitiesEndToEndTests {
    // MARK: - 17.5 a: image model picker and the one-time install (L716)

    @MainActor func testC14_ImageModelAndOneTimeInstall() throws {
        var app = launch()
        openCapabilities(app, tab: "Tools")
        let image = app.descendants(matching: .any)["toolset-row-image_gen"]
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        image.tap()
        let pro = app.buttons["toolset-model-flux-pro"]
        for _ in 0..<5 where !pro.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(pro.waitForExistence(timeout: 8), "the image tool lists its models")
        reach(app, pro)
        shot(app, "toolset-image-models")
        pro.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { self.toolModel("image_gen") == "flux-pro" }, "the gateway has the new model: \(toolModel("image_gen"))")
        XCTAssertTrue(waitUntil(timeout: 8) { pro.label.contains("In use") }, "the row shows the choice: \(pro.label)")
        // [model-scope] Owner 2026-11-03: the model section says whose a pick is (the page's footer says new chats).
        let scope = app.descendants(matching: .any)["toolset-model-scope"]
        for _ in 0..<4 where !scope.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(scope.waitForExistence(timeout: 5), "the tool's model says whose it is")
        XCTAssertEqual(scope.label, "Applies to Hermes only.")
        reach(app, scope)
        shot(app, "toolset-model-scope")
        let puts = ((state()["log"] as? [[String: Any]]) ?? []).filter { $0["name"] as? String == "PUT /api/tools/toolsets/image_gen/model" }
        XCTAssertEqual(puts.count, 1, "one write")
        // A relaunch still shows it.
        app.terminate()
        app = launch()
        openCapabilities(app, tab: "Tools")
        app.descendants(matching: .any)["toolset-row-image_gen"].tap()
        let again = app.buttons["toolset-model-flux-pro"]
        for _ in 0..<5 where !again.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(again.waitForExistence(timeout: 8))
        XCTAssertTrue(waitUntil(timeout: 8) { again.label.contains("In use") }, "the choice survives a relaunch: \(again.label)")
        shot(app, "toolset-image-model-picked")
        // The one-time install: Web › DuckDuckGo.
        app.navigationBars.buttons.firstMatch.tap()
        let web = app.descendants(matching: .any)["toolset-row-web"]
        for _ in 0..<4 where !web.exists || !web.isHittable { app.swipeDown(velocity: .slow) }
        web.tap()
        let duck = app.buttons["toolset-provider-DuckDuckGo"]
        XCTAssertTrue(duck.waitForExistence(timeout: 8))
        reach(app, duck)
        duck.tap()
        let run = app.buttons["toolset-post-setup"]
        for _ in 0..<5 where !run.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(run.waitForExistence(timeout: 8), "a backend that needs an install offers Run Setup")
        reach(app, run)
        shot(app, "toolset-install-offer")
        run.tap()
        XCTAssertTrue(app.staticTexts["Installing…"].waitForExistence(timeout: 8), "a progress row follows")
        shot(app, "toolset-install-running")
        XCTAssertTrue(app.descendants(matching: .any)["toolset-setup-done"].waitForExistence(timeout: 30), "and it finishes")
        shot(app, "toolset-install-done")
        let texts = app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertFalse(texts.contains("ghp_"), "no secret from the install's output on screen")
    }

    // MARK: - 17.5 f: leaving with unsaved tool changes asks (L718)

    @MainActor func testC15_UnsavedToolChangesAsk() throws {
        let entryBefore = server("github")["_entry"] as? NSDictionary
        let app = launch()
        openCapabilities(app, tab: "Connectors")
        let github = app.descendants(matching: .any)["connector-row-github"]
        XCTAssertTrue(github.waitForExistence(timeout: 10))
        github.tap()
        XCTAssertTrue(app.switches["mcp-tool-switch-create_issue"].waitForExistence(timeout: 10), "the tools load")
        // Nothing changed: Back just goes back.
        app.navigationBars["GitHub"].buttons.firstMatch.tap()
        XCTAssertTrue(github.waitForExistence(timeout: 8), "an untouched page leaves without a question")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        github.tap()
        XCTAssertTrue(app.switches["mcp-tool-switch-create_issue"].waitForExistence(timeout: 10))
        flip(app, "mcp-tool-switch-create_issue")
        XCTAssertTrue(app.buttons["mcp-tools-save"].waitForExistence(timeout: 5))
        app.navigationBars["GitHub"].buttons.firstMatch.tap()
        let ask = app.alerts["Discard Changes?"]
        XCTAssertTrue(ask.waitForExistence(timeout: 5), "Back with unsaved changes asks")
        XCTAssertTrue(ask.staticTexts["Your changes to github’s tools haven’t been saved."].exists, "and says what is at stake")
        shot(app, "connector-discard-ask")
        ask.buttons["Keep Editing"].tap()
        XCTAssertTrue(app.buttons["mcp-tools-save"].waitForExistence(timeout: 5), "Keep Editing keeps the change")
        XCTAssertTrue(app.descendants(matching: .any)["connector-page"].exists)
        app.navigationBars["GitHub"].buttons.firstMatch.tap()
        XCTAssertTrue(ask.waitForExistence(timeout: 5))
        ask.buttons["Discard Changes"].tap()
        XCTAssertTrue(github.waitForExistence(timeout: 8), "Discard Changes leaves")
        let log = (state()["log"] as? [[String: Any]]) ?? []
        XCTAssertFalse(log.contains { ["mcp.servers.add", "mcp.servers.remove"].contains($0["name"] as? String ?? "") }, "the gateway saw no write")
        XCTAssertEqual(server("github")["_entry"] as? NSDictionary, entryBefore)
        // Coming back shows the saved rules, not the dropped draft.
        github.tap()
        XCTAssertTrue(app.switches["mcp-tool-switch-create_issue"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["mcp-tools-save"].exists, "the draft is gone")
    }

    // MARK: - 17.5 g: Vision › Choose Vision Model (L716)

    @MainActor func testC16_ChooseVisionModel() throws {
        let app = launch()
        openCapabilities(app, tab: "Tools")
        let vision = app.descendants(matching: .any)["toolset-row-vision"]
        XCTAssertTrue(vision.waitForExistence(timeout: 10))
        reach(app, vision)
        vision.tap()
        let choose = app.buttons["toolset-vision-model"]
        for _ in 0..<4 where !choose.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(choose.waitForExistence(timeout: 10), "Vision offers the way to its model")
        reach(app, choose)
        shot(app, "toolset-vision")
        choose.tap()
        XCTAssertTrue(app.navigationBars["Auxiliary Models"].waitForExistence(timeout: 8), "the helper models page opens")
        let row = app.buttons["aux-task.vision"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "with Vision as a row")
        shot(app, "vision-auxiliary-models")
        row.tap()
        let provider = app.descendants(matching: .any)["model-chooser.provider"]
        XCTAssertTrue(provider.waitForExistence(timeout: 10), "the model page for Vision")
        provider.tap()
        let anthropic = app.buttons["Anthropic"]
        XCTAssertTrue(anthropic.waitForExistence(timeout: 5), "the providers")
        anthropic.tap()
        let option = app.descendants(matching: .any)["model-option.claude-sonnet-5"]
        for _ in 0..<5 where !option.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(option.waitForExistence(timeout: 10), "the model list")
        shot(app, "vision-model-chooser")
        option.tap()
        XCTAssertTrue(waitUntil(timeout: 10) {
            self.writes("POST /api/model/set").contains { ($0["params"] as? [String: Any])?["scope"] as? String == "auxiliary"
                && ($0["params"] as? [String: Any])?["task"] as? String == "vision" }
        }, "the gateway got the vision model")
        XCTAssertEqual(writes("POST /api/model/set").count, 1, "one write")
        let aux = (state()["aux"] as? [String: [String: Any]])?["vision"]
        XCTAssertEqual(aux?["model"] as? String, "claude-sonnet-5")
        XCTAssertTrue(waitUntil(timeout: 8) { app.buttons["aux-task.vision"].exists }, "back on the helper models")
        shot(app, "vision-model-picked")
    }

    // MARK: - 17.5 e: an issue opens Connectors on the failing connector, however long the list (L721)

    @MainActor func testC17_IssueScrollsToTheFailingConnector() throws {
        try control(gateway.url, "/__seed", ["servers": 30])
        try control(gateway.url, "/__seed", ["status": ["profile": "default", "name": "server-030", "status": "failed", "tools": 0]])
        let app = launch()
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let row = app.cells["more-row-capabilities"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertTrue(waitUntil(timeout: 45) { row.label.contains("Issue") || row.staticTexts["1 Issue"].exists }, "More says there is an issue: \(row.label)")
        row.tap()
        openList(app, "Connectors")   // [cap-pages] the issue's row on Capabilities
        let failing = app.descendants(matching: .any)["connector-row-server-030"]
        XCTAssertTrue(waitUntil(timeout: 12) { failing.exists && failing.isHittable }, "the failing connector, last of 34, is on screen without a scroll")
        shot(app, "connectors-issue-scrolled")
        XCTAssertFalse(app.descendants(matching: .any)["connector-row-github"].isHittable, "the list really moved")
        failing.tap()
        XCTAssertTrue(app.navigationBars["Server 030"].waitForExistence(timeout: 8), "and it opens")
    }

    // MARK: - 17.5 h: the real system sign-in sheet opens on the stand-in's page (L718, L996, L725)

    @MainActor func testC18_RealSignInSheetOpensAndCancelIsQuiet() throws {
        try control(gateway.url, "/__seed", ["status": ["profile": "default", "name": "linear", "enabled": true, "status": "configured"]])
        let app = launch()   // no HQN_CAP_AUTH: the system sheet itself
        openCapabilities(app, tab: "Connectors")
        app.descendants(matching: .any)["connector-row-linear"].tap()
        let signIn = app.buttons["connector-signin"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 8))
        signIn.tap()
        // The system asks first ("…Wants to Use “127.0.0.1” to Sign In").
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let consent = springboard.alerts.firstMatch
        if consent.waitForExistence(timeout: 10) {
            shot(app, "connector-signin-system-ask")
            consent.buttons["Continue"].tap()
        }
        let page = app.webViews.staticTexts["Stand-in sign-in"]
        let shown = page.waitForExistence(timeout: 20)
        Thread.sleep(forTimeInterval: 1)
        let whole = XCUIScreen.main.screenshot()
        let mode = ProcessInfo.processInfo.environment["HQN_SHOTS_DARK"] == "1" ? "dark" : "light"
        if let dir = ProcessInfo.processInfo.environment["HQN_SHOTS"], !dir.isEmpty {
            try? whole.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("connector-signin-real-sheet-\(mode).png"))
        }
        XCTAssertTrue(shown, "the system sign-in sheet shows the stand-in's page")
        let start = ((state()["oauth"] as? [String: [String: Any]]) ?? [:]).values.first
        XCTAssertTrue((start?["redirect"] as? String ?? "").hasPrefix("http://127.0.0.1:"), "the provider returns to this phone's own listener")
        // Allow on the real page: the redirect lands on the app's loopback listener, the sheet closes, the gateway holds the sign-in.
        let allow = app.webViews.links["Allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        allow.tap()
        XCTAssertTrue(waitUntil(timeout: 25) { self.server("linear")["oauth_tokens_present"] as? Bool == true }, "the gateway holds the sign-in")
        XCTAssertTrue(waitUntil(timeout: 15) { !app.webViews.firstMatch.exists && !app.buttons["connector-signin"].exists }, "the sheet closes and Sign In goes")
        shot(app, "connector-signed-in-real-sheet")
    }

    @MainActor func testC19_RealSignInSheetCancelIsQuiet() throws {
        try control(gateway.url, "/__seed", ["status": ["profile": "default", "name": "linear", "enabled": true, "status": "configured"]])
        let app = launch()
        openCapabilities(app, tab: "Connectors")
        app.descendants(matching: .any)["connector-row-linear"].tap()
        let signIn = app.buttons["connector-signin"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 8))
        signIn.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let consent = springboard.alerts.firstMatch
        XCTAssertTrue(consent.waitForExistence(timeout: 10), "the system asks before opening the sheet")
        consent.buttons["Cancel"].tap()
        XCTAssertTrue(waitUntil(timeout: 20) { signIn.exists && signIn.isEnabled && signIn.label == "Sign In" }, "cancelling ends the flow")
        XCTAssertFalse(app.alerts.firstMatch.exists, "quietly: no alert")
        XCTAssertFalse(server("linear")["oauth_tokens_present"] as? Bool == true, "nothing was saved")
    }

    // MARK: - 17.4: a read that fails once is asked again; the page never shows the failure (L716, L722)

    @MainActor func testC20_OneFailedReadIsRetried() throws {
        try control(gateway.url, "/__fail", ["target": "rest:GET /api/tools/toolsets", "mode": "error", "count": 1])
        try control(gateway.url, "/__fail", ["target": "rpc:plugins.manage", "mode": "error", "count": 1])
        let app = launch()
        openCapabilities(app, tab: "Tools")
        XCTAssertTrue(app.descendants(matching: .any)["toolset-row-web"].waitForExistence(timeout: 12), "Tools loads after one failed read")
        XCTAssertFalse(app.staticTexts["Couldn’t Load Tools"].exists)
        let reads = ((state()["log"] as? [[String: Any]]) ?? []).filter { $0["name"] as? String == "GET /api/tools/toolsets" }
        XCTAssertEqual(reads.count, 2, "asked twice: the failure and one retry")
        switchList(app, to: "Plugins")
        XCTAssertTrue(app.descendants(matching: .any)["plugin-row-web-clipper"].waitForExistence(timeout: 12), "Plugins loads after one failed read")
    }

    // MARK: - 17.5 b, c: Use the Key on Your Gateway, and per-bot Try Again (L724, L727)

    @MainActor func testD2_UseGatewayKeyAndRetryOneBot() throws {
        try XCTSkipIf(composio.isEmpty, "needs the Composio stand-in")
        // Ivy already has Connect Apps from another device: the server and the key in its env.
        let row: [String: Any] = ["name": "composio", "transport": "http", "url": "https://mcp.composio.example/s/abc", "command": NSNull(), "args": [],
                                  "env": [], "auth": "header", "oauth_tokens_present": NSNull(), "enabled": true, "tools": NSNull(), "source": "config",
                                  "plugin": NSNull(), "_status": "connected", "_tools": 3, "_names": [],
                                  "_entry": ["url": "https://mcp.composio.example/s/abc", "headers": ["x-api-key": "${COMPOSIO_API_KEY}"]]]
        try control(gateway.url, "/__seed", ["mcp": ["ivy": [row]]])
        try control(gateway.url, "/__seed", ["env": ["profile": "ivy", "key": "COMPOSIO_API_KEY", "value": "ak_mock_dispatch"]])
        let app = launch(["-HQDebugResetConnectApps", "YES"], environment: ["HQN_CAP_AUTH": "allow", "HQN_COMPOSIO_BASE": composio])
        openConnectApps(app)
        let use = app.buttons["connect-apps.use-gateway-key"]
        for _ in 0..<3 where !use.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(use.waitForExistence(timeout: 15), "a gateway that already holds a key offers it")
        reach(app, use)
        shot(app, "connect-setup-gateway-key")
        // The gateway's limit on showing keys: said plainly, nothing saved. Seeded here, as the stand-in's limit lasts thirty seconds.
        try control(gateway.url, "/__seed", ["reveal_limit": true])
        use.tap()
        let notice = app.descendants(matching: .any)["connect-apps.notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "a refused reveal says so")
        let words = app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
        XCTAssertTrue(words.contains("Your gateway is busy. Wait half a minute, then try again."), "in plain words: \(words)")
        shot(app, "connect-setup-gateway-busy")
        XCTAssertTrue(app.secureTextFields["connect-apps.key"].exists, "still on setup")
        XCTAssertEqual(state()["reveals"] as? Int, 0, "no key left the gateway")
        try control(gateway.url, "/__seed", ["reveal_limit": false])
        reach(app, use)
        use.tap()
        if !app.descendants(matching: .any)["connect-app-tile-gmail"].waitForExistence(timeout: 20) { shot(app, "debug-gateway-key-home") }
        XCTAssertTrue(app.descendants(matching: .any)["connect-app-tile-gmail"].exists, "Home opens with the gateway's key")
        XCTAssertEqual(state()["reveals"] as? Int, 1, "the key was shown to the phone exactly once")
        // The key went to Composio as a header and nowhere else.
        let log = (try mock("/__state")["log"] as? [[String: Any]]) ?? []
        XCTAssertFalse(log.filter { ($0["path"] as? String ?? "").hasPrefix("/api/") }.contains { $0["key"] as? String == "none" })
        // It is saved: a relaunch opens Home, not setup.
        app.terminate()
        let again = launch(environment: ["HQN_CAP_AUTH": "allow", "HQN_COMPOSIO_BASE": composio])
        openConnectApps(again)
        XCTAssertTrue(again.descendants(matching: .any)["connect-app-tile-gmail"].waitForExistence(timeout: 20), "the key is in the Keychain")
        XCTAssertFalse(again.secureTextFields["connect-apps.key"].exists)
        // Bots: Hermes fails once, its own row says so and offers Try Again; one tap, one more write, done.
        again.descendants(matching: .any)["connect-apps.bots-row"].tap()
        XCTAssertTrue(again.descendants(matching: .any)["connect-bot-switch-default"].waitForExistence(timeout: 15))
        try control(gateway.url, "/__fail", ["target": "rpc:mcp.servers.add", "mode": "error", "count": 1])
        flip(again, "connect-bot-switch-default")
        let retry = again.buttons["connect-bot-retry-default"]
        XCTAssertTrue(retry.waitForExistence(timeout: 15), "the bot that failed offers Try Again on its own row")
        shot(again, "connect-bots-retry")
        XCTAssertFalse(again.alerts.firstMatch.exists, "no alert: the failure stays on its row")
        XCTAssertEqual(adds("default"), 1)
        XCTAssertFalse(mcp("default").contains { $0["name"] as? String == "composio" })
        retry.tap()
        XCTAssertTrue(waitUntil(timeout: 15) { self.mcp("default").contains { $0["name"] as? String == "composio" } }, "Try Again turns it on")
        XCTAssertTrue(waitUntil(timeout: 8) { !retry.exists }, "the row settles")
        XCTAssertEqual(adds("default"), 2, "exactly one more write")
        XCTAssertTrue(mcp("ivy").contains { $0["name"] as? String == "composio" }, "Ivy is untouched")
        shot(again, "connect-bots-retry-done")
    }

    // MARK: - Helpers

    func toolModel(_ toolset: String) -> String {
        (((state()["toolcfg"] as? [String: Any])?["default"] as? [String: Any])?[toolset] as? [String: Any])?["model"] as? String ?? ""
    }

    func adds(_ profile: String) -> Int {
        ((state()["log"] as? [[String: Any]]) ?? []).filter { $0["name"] as? String == "mcp.servers.add" && $0["profile"] as? String == profile }.count
    }
}
