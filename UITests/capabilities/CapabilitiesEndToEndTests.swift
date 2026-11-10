// Capabilities-stream end-to-end checks (docs/spec/3x-capabilities.md §12) against the capabilities stand-in gateway
// and the Composio stand-in: the real app, real taps, and the stand-ins' `/__state` as the wire evidence.
// Run with scripts/e2e-capabilities.sh <UDID>.

import XCTest

final class CapabilitiesEndToEndTests: XCTestCase {
    var gateway: SettingsFixture!
    var composio: String = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        gateway = try SettingsFixture.load("HQN_CAP_A")
        composio = ProcessInfo.processInfo.environment["HQN_CAP_COMPOSIO"] ?? ""
        // Two control posts in a row on one kept-alive connection can be answered 501 by the stand-in: ask again once.
        do { try control(gateway.url, "/__seed", ["reset": true, "clear_fail": true, "clear_log": true]) }
        catch { try control(gateway.url, "/__seed", ["reset": true, "clear_fail": true, "clear_log": true]) }
        if !composio.isEmpty { try mock("/__seed", ["reset": true]) }
    }

    // MARK: - Four rows, each its own page ([cap-pages] owner 2026-11-03)

    @MainActor func testC0_FourRowsEachItsOwnPage() throws {
        let app = launch()
        openMoreRow(app, "capabilities")
        XCTAssertTrue(app.navigationBars["Capabilities"].waitForExistence(timeout: 10), "More › Capabilities")
        for name in ["Skills", "Tools", "Connectors", "Plugins"] {
            XCTAssertTrue(app.descendants(matching: .any)["capabilities.row.\(name.lowercased())"].exists, "Capabilities lists \(name)")
        }
        XCTAssertFalse(app.buttons["capabilities.tab"].exists, "no tab control")
        shot(app, "capabilities-rows")
        for name in ["Skills", "Tools", "Connectors", "Plugins"] {
            openList(app, name)
            XCTAssertFalse(app.buttons["capabilities.tab"].exists, "\(name) has no tab control")
            if name == "Plugins" { shot(app, "capabilities-plugins-page") }
            app.navigationBars.buttons["Capabilities"].firstMatch.tap()
            XCTAssertTrue(app.descendants(matching: .any)["capabilities.row.skills"].waitForExistence(timeout: 5), "Back goes to the four rows")
        }
    }

    // MARK: - Tools (L715, L716)

    @MainActor func testC1_ToolsListToggleAndPage() throws {
        let app = launch()
        openCapabilities(app, tab: "Tools")
        XCTAssertTrue(app.descendants(matching: .any)["toolset-row-web"].waitForExistence(timeout: 10), "the Web toolset shows")
        XCTAssertFalse(app.descendants(matching: .any)["toolset-row-discord"].exists, "messaging toolsets stay off the phone")
        XCTAssertFalse(app.descendants(matching: .any)["toolset-row-moa"].exists)
        shot(app, "tools-list")
        flip(app, "toolset-switch-image_gen")
        shot(app, "tools-after-flip")
        XCTAssertTrue(waitUntil(timeout: 8) { self.toolset("image_gen")["enabled"] as? Bool == true }, "the gateway turned Image Generation on")
        // A refused change goes back and says why.
        try control(gateway.url, "/__fail", ["target": "rest:PUT /api/tools/toolsets/vision", "mode": "error", "count": 1])
        flip(app, "toolset-switch-vision")
        XCTAssertTrue(app.descendants(matching: .any)["toolset-notice"].waitForExistence(timeout: 8)
                      || app.alerts.firstMatch.waitForExistence(timeout: 2), "a refused change is reported")
        shot(app, "tools-refused")
        if app.alerts.firstMatch.exists { app.alerts.firstMatch.buttons.firstMatch.tap() }
        XCTAssertTrue(toolset("vision")["enabled"] as? Bool == true, "the gateway still has Vision on")
        // The toolset page: keys and where it runs.
        app.descendants(matching: .any)["toolset-row-web"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["toolset-page"].waitForExistence(timeout: 8), "the Web page opens")
        shot(app, "toolset-web")
        app.swipeUp()
        shot(app, "toolset-web-lower")
    }

    // MARK: - Connectors (L718–L722, L996)

    @MainActor func testC2_ConnectorsToggleToolsAdvancedLogs() throws {
        let app = launch()
        openCapabilities(app, tab: "Connectors")
        let github = app.descendants(matching: .any)["connector-row-github"]
        XCTAssertTrue(github.waitForExistence(timeout: 10))
        shot(app, "connectors-list")
        flip(app, "mcp-switch-files")
        XCTAssertTrue(waitUntil(timeout: 8) { self.server("files")["enabled"] as? Bool == true }, "the gateway turned files on")
        github.tap()
        XCTAssertTrue(app.descendants(matching: .any)["connector-page"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.switches["mcp-tool-switch-create_issue"].waitForExistence(timeout: 10), "the tools load")
        shot(app, "connector-github")
        // Turn one tool off and save: the gateway's entry gets the exclusion.
        flip(app, "mcp-tool-switch-create_issue")
        let save = app.buttons["mcp-tools-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "an unsaved change shows Save")
        shot(app, "connector-tools-draft")
        save.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !(self.writes("mcp.add").isEmpty) || self.entryText("github").contains("create_issue") },
                      "the tool rule reached the gateway: \(entryText("github"))")
        // Advanced: the configuration with secrets hidden, Logs, Remove.
        reach(app, app.descendants(matching: .any)["connector-advanced"])
        app.descendants(matching: .any)["connector-advanced"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["connector-config-text"].waitForExistence(timeout: 8), "the configuration shows")
        let config = app.descendants(matching: .any)["connector-config-text"].label + ((app.descendants(matching: .any)["connector-config-text"].value as? String) ?? "")
        XCTAssertFalse(config.contains("ghp_"), "no secret in the configuration")
        shot(app, "connector-advanced")
        try control(gateway.url, "/__log", ["file": "mcp", "line": "2026-10-13 10:00:00 [github] connected with token ghp_abcdefghijklmnopqrstuvwxyz0123456789"])
        app.descendants(matching: .any)["connector-logs"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["connector-logs-text"].waitForExistence(timeout: 8)
                      || app.descendants(matching: .any)["connector-logs-message"].waitForExistence(timeout: 2), "the Logs page opens")
        shot(app, "connector-logs")
    }

    @MainActor func testC3_AddAndRemoveConnector() throws {
        let app = launch()
        openCapabilities(app, tab: "Connectors")
        XCTAssertTrue(app.descendants(matching: .any)["connector-row-github"].waitForExistence(timeout: 10))
        tapAdd(app)
        let name = app.textFields["add-connector.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 8), "the Add Connector sheet")
        shot(app, "add-connector-empty")
        name.tap(); name.typeText("github")
        XCTAssertTrue(app.descendants(matching: .any)["add-connector.name-taken"].waitForExistence(timeout: 3), "a name in use is refused")
        name.clearAndType("weather")
        let url = app.textFields["add-connector.url"]
        url.tap(); url.typeText("https://mcp.weather.example/mcp")
        shot(app, "add-connector-filled")
        app.buttons["add-connector.add"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.server("weather").isEmpty }, "the gateway has the new connector")
        // The new connector's own page opens; remove it from Advanced.
        XCTAssertTrue(app.navigationBars["Weather"].waitForExistence(timeout: 10), "the new connector's page opens")
        shot(app, "connector-new")
        reach(app, app.descendants(matching: .any)["connector-advanced"])
        app.descendants(matching: .any)["connector-advanced"].tap()
        let remove = app.descendants(matching: .any)["connector-remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 8))
        reach(app, remove)
        remove.tap()
        shot(app, "connector-remove-confirm")
        let confirm = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Remove")).allElementsBoundByIndex.last
        confirm?.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { self.server("weather").isEmpty }, "the gateway no longer has it")
        XCTAssertTrue(app.descendants(matching: .any)["connector-row-github"].waitForExistence(timeout: 10), "back on the list")
        XCTAssertFalse(app.descendants(matching: .any)["connector-row-weather"].exists)
    }

    @MainActor func testC4_OAuthSignInAllow() throws {
        try control(gateway.url, "/__seed", ["status": ["profile": "default", "name": "linear", "enabled": true, "status": "configured"]])
        let app = launch(environment: ["HQN_CAP_AUTH": "allow"])
        openCapabilities(app, tab: "Connectors")
        let linear = app.descendants(matching: .any)["connector-row-linear"]
        XCTAssertTrue(linear.waitForExistence(timeout: 10))
        linear.tap()
        let signIn = app.buttons["connector-signin"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 8), "a connector that needs a sign-in offers one")
        shot(app, "connector-needs-signin")
        signIn.tap()
        XCTAssertTrue(waitUntil(timeout: 25) { self.server("linear")["oauth_tokens_present"] as? Bool == true }, "the gateway holds the sign-in")
        XCTAssertTrue(waitUntil(timeout: 10) { !app.buttons["connector-signin"].exists }, "Sign In goes away")
        shot(app, "connector-signed-in")
        let log = (state()["log"] as? [[String: Any]]) ?? []
        XCTAssertTrue(log.contains { ($0["name"] as? String ?? "").contains("oauth") }, "the gateway's OAuth calls were used")
        // Row L996: the provider was told to return to a listener on this phone (loopback, a port the system chose).
        let redirect = ((state()["oauth"] as? [String: [String: Any]]) ?? [:]).values.first?["redirect"] as? String ?? ""
        XCTAssertTrue(redirect.hasPrefix("http://127.0.0.1:") && redirect.hasSuffix("/callback") && !gateway.url.isEmpty && !redirect.hasPrefix(gateway.url),
                      "the sign-in returns to the phone's own loopback listener: \(redirect)")
    }

    @MainActor func testC5_OAuthSignInDeniedAndClosed() throws {
        try control(gateway.url, "/__seed", ["status": ["profile": "default", "name": "linear", "enabled": true, "status": "configured"]])
        var app = launch(environment: ["HQN_CAP_AUTH": "deny"])
        openCapabilities(app, tab: "Connectors")
        app.descendants(matching: .any)["connector-row-linear"].tap()
        XCTAssertTrue(app.buttons["connector-signin"].waitForExistence(timeout: 8))
        app.buttons["connector-signin"].tap()
        XCTAssertTrue(waitUntil(timeout: 25) { app.alerts.firstMatch.exists || app.descendants(matching: .any)["connector-page-status"].label.lowercased().contains("sign") },
                      "a declined sign-in is reported")
        shot(app, "connector-signin-denied")
        XCTAssertFalse(server("linear")["oauth_tokens_present"] as? Bool == true, "nothing was saved")
        app.terminate()
        try control(gateway.url, "/__seed", ["status": ["profile": "default", "name": "linear", "enabled": true, "status": "configured"]])
        app = launch(environment: ["HQN_CAP_AUTH": "close"])
        openCapabilities(app, tab: "Connectors")
        app.descendants(matching: .any)["connector-row-linear"].tap()
        XCTAssertTrue(app.buttons["connector-signin"].waitForExistence(timeout: 8))
        app.buttons["connector-signin"].tap()
        XCTAssertTrue(waitUntil(timeout: 20) { app.buttons["connector-signin"].isEnabled }, "closing the sheet ends the flow")
        XCTAssertFalse(app.alerts.firstMatch.exists, "closing is quiet: no alert")
        XCTAssertFalse(server("linear")["oauth_tokens_present"] as? Bool == true)
    }

    // MARK: - Plugins (L723–L729, L997)

    @MainActor func testC6_PluginsListTogglePageInstall() throws {
        let app = launch()
        openCapabilities(app, tab: "Plugins")
        let clipper = app.descendants(matching: .any)["plugin-row-web-clipper"]
        XCTAssertTrue(clipper.waitForExistence(timeout: 10), "the plugins list shows")
        XCTAssertTrue(app.descendants(matching: .any)["plugin-kanban-show"].exists || app.descendants(matching: .any)["plugin-row-kanban"].exists, "Kanban's row")
        shot(app, "plugins-list")
        flip(app, "plugin-switch-catalog:web-clipper")
        XCTAssertTrue(waitUntil(timeout: 10) { self.plugin("web-clipper")["status"] as? String == "enabled" }, "the gateway enabled it")
        clipper.tap()
        XCTAssertTrue(app.descendants(matching: .any)["plugin-page"].waitForExistence(timeout: 8))
        shot(app, "plugin-page")
        app.navigationBars.buttons.firstMatch.tap()
        app.descendants(matching: .any)["plugin-row-local-vision"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["plugin-page"].waitForExistence(timeout: 8))
        shot(app, "plugin-page-servers")
        app.navigationBars.buttons.firstMatch.tap()
        // Install from a repository: the address is checked before anything is sent.
        let install = app.buttons["plugins.install"]
        for _ in 0..<5 where !install.exists || !install.isHittable { app.swipeUp(velocity: .slow) }
        reach(app, install)
        install.tap()
        let repo = app.textFields["plugins.install.repo"]
        XCTAssertTrue(repo.waitForExistence(timeout: 8), "the Install Plugin sheet")
        repo.tap(); repo.typeText("not a repo")
        shot(app, "plugin-install-invalid")
        XCTAssertFalse(app.buttons["plugins.install.go"].isEnabled, "an address that isn't a repository can't be sent")
        repo.clearAndType("acme/notes-plugin")
        XCTAssertTrue(waitUntil(timeout: 3) { app.buttons["plugins.install.go"].isEnabled })
        shot(app, "plugin-install-ready")
        app.buttons["plugins.install.go"].tap()
        let confirm = app.alerts["Install This Plugin?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "installing asks first")
        shot(app, "plugin-install-confirm")
        confirm.buttons["Install"].tap()
        XCTAssertTrue(waitUntil(timeout: 15) { !self.plugin("notes-plugin").isEmpty }, "the gateway installed it: \(pluginNames())")
        shot(app, "plugin-installed")
    }

    // MARK: - Issues on More (L853, L875)

    @MainActor func testC7_ConnectorIssueShowsOnMore() throws {
        _ = try? control(gateway.url, "/__state")
        try control(gateway.url, "/__seed", ["status": ["profile": "default", "name": "github", "status": "failed", "tools": 0]])
        let app = launch()
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let row = app.cells["more-row-capabilities"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        // Two reads at least ten seconds apart make an issue (a blip never does).
        XCTAssertTrue(waitUntil(timeout: 45) { row.label.contains("Issue") || row.staticTexts["1 Issue"].exists }, "More says there is an issue: \(row.label)")
        shot(app, "more-issue")
        row.tap()
        // [cap-pages] Capabilities' four rows: the issue is on Connectors, which opens on it.
        let connectors = app.descendants(matching: .any)["capabilities.row.connectors"]
        XCTAssertTrue(connectors.waitForExistence(timeout: 10), "Capabilities lists Connectors")
        XCTAssertTrue(app.staticTexts["1 Issue"].exists, "the issue is on the Connectors row")
        shot(app, "capabilities-issue")
        connectors.tap()
        XCTAssertTrue(app.descendants(matching: .any)["connector-row-github"].waitForExistence(timeout: 10), "it opens on Connectors")
        shot(app, "connectors-issue")
        // Fixed on the gateway: the issue clears.
        try control(gateway.url, "/__seed", ["status": ["profile": "default", "name": "github", "status": "connected", "tools": 5]])
        tapAdd(app, item: "Refresh")
        Thread.sleep(forTimeInterval: 2)
        app.navigationBars.buttons["Capabilities"].firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 30) { !app.staticTexts["1 Issue"].exists }, "the Connectors row clears")
        app.navigationBars.buttons.firstMatch.tap()
        let cleared = waitUntil(timeout: 30) { !row.label.contains("unreachable") && !((row.value as? String) ?? "").contains("Issue") }
        shot(app, "more-no-issue")
        XCTAssertTrue(cleared, "the issue clears: \(row.label) / \(String(describing: row.value)) / \(app.staticTexts.allElementsBoundByIndex.map(\.label))")
    }

    // MARK: - Skills notices (L711, L714)

    @MainActor func testC8_SkillsDisableUnusedAndTabs() throws {
        let app = launch()
        openCapabilities(app, tab: "Skills")
        XCTAssertTrue(app.descendants(matching: .any)["skill-row-web-search"].waitForExistence(timeout: 10), "Skills is the first tab")
        shot(app, "skills-list")
        tapAdd(app, item: nil)
        shot(app, "capabilities-menu")
        let unused = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Disable Unused")).firstMatch
        if unused.waitForExistence(timeout: 3) {
            unused.tap()
            shot(app, "disable-unused-confirm")
            let go = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Disable")).allElementsBoundByIndex.last
            go?.tap()
            XCTAssertTrue(waitUntil(timeout: 15) { self.installedSkills().contains { $0["usage"] as? Int == 0 && $0["enabled"] as? Bool == false }
                || !self.installedSkills().contains { $0["usage"] as? Int == 0 }}, "unused skills are off on the gateway")
            shot(app, "disable-unused-done")
        } else {
            XCTFail("Disable Unused Skills is missing from the menu")
        }
    }

    // MARK: - Installing an official skill (L714)

    @MainActor func testC10_InstallOfficialSkillAsksAndShowsProgress() throws {
        let app = launch()
        openCapabilities(app, tab: "Skills")
        let get = app.buttons["skill-get-blender-mcp"]
        XCTAssertTrue(app.descendants(matching: .any)["skill-row-web-search"].waitForExistence(timeout: 10))
        // "Available from Hermes" sits under the installed skills; rows are made as they scroll in.
        for _ in 0..<6 where !get.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(get.waitForExistence(timeout: 5), "an official skill that is not installed offers Get")
        reach(app, get)
        get.tap()
        let ask = app.alerts.firstMatch
        XCTAssertTrue(ask.waitForExistence(timeout: 5), "Get asks first")
        XCTAssertTrue(ask.label.hasPrefix("Install blender-mcp for "), "the question names the skill and the bot: \(ask.label)")
        shot(app, "skill-install-confirm")
        ask.buttons["Cancel"].tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(installedSkills().contains { $0["name"] as? String == "blender-mcp" }, "Cancel changes nothing")
        get.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.firstMatch.buttons["Install"].tap()
        let notice = app.descendants(matching: .any)["skill-install-progress-blender-mcp"]
        XCTAssertTrue(notice.waitForExistence(timeout: 8), "a progress row follows the install")
        shot(app, "skill-install-progress")
        XCTAssertTrue(waitUntil(timeout: 30) { self.installedSkills().contains { $0["name"] as? String == "blender-mcp" } }, "the gateway installed it")
        for _ in 0..<6 where !app.descendants(matching: .any)["skill-row-blender-mcp"].exists { app.swipeDown(velocity: .slow) }
        XCTAssertTrue(waitUntil(timeout: 15) { app.descendants(matching: .any)["skill-row-blender-mcp"].exists }, "it moves to Installed")
        shot(app, "skill-install-done")
    }

    // MARK: - A tool rule whose save fails half way puts the connector back (stress I9)

    @MainActor func testC11_ToolRuleSaveRollsBack() throws {
        let entryBefore = server("github")["_entry"] as? NSDictionary
        XCTAssertNotNil(entryBefore)
        let app = launch()
        openCapabilities(app, tab: "Connectors")
        let github = app.descendants(matching: .any)["connector-row-github"]
        XCTAssertTrue(github.waitForExistence(timeout: 10))
        github.tap()
        XCTAssertTrue(app.switches["mcp-tool-switch-list_issues"].waitForExistence(timeout: 10), "the tools load")
        try control(gateway.url, "/__fail", ["target": "rpc:mcp.servers.add", "mode": "error", "count": 1])
        flip(app, "mcp-tool-switch-list_issues")
        let save = app.buttons["mcp-tools-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10), "a failed save says so")
        shot(app, "connector-tools-save-failed")
        XCTAssertFalse(server("github").isEmpty, "the connector is still on the gateway")
        XCTAssertEqual(server("github")["_entry"] as? NSDictionary, entryBefore, "with the entry it had")
    }

    // MARK: - Plugin update and uninstall (L722), terminal backend and web provider (L716 setup)

    @MainActor func testC12_PluginUpdateAndUninstall() throws {
        let app = launch()
        openCapabilities(app, tab: "Plugins")
        let row = app.descendants(matching: .any)["plugin-row-web-clipper"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let update = app.buttons["plugin.update"]
        XCTAssertTrue(update.waitForExistence(timeout: 8), "an update is offered")
        update.tap()
        // The update asks for more than the plugin had: the phone shows what and asks.
        let ask = app.alerts.firstMatch
        XCTAssertTrue(ask.waitForExistence(timeout: 8), "new permissions are asked for")
        shot(app, "plugin-update-consent")
        ask.buttons.allElementsBoundByIndex.last?.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { self.plugin("web-clipper")["update_available"] as? Bool == false }, "the gateway updated it")
        XCTAssertTrue(waitUntil(timeout: 8) { !update.exists }, "the Update button goes")
        shot(app, "plugin-updated")
        // A catalog plugin is not removed from the phone; one installed from Git is.
        XCTAssertFalse(app.buttons["plugin.uninstall"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        let mine = app.descendants(matching: .any)["plugin-row-my-plugin"]
        XCTAssertTrue(mine.waitForExistence(timeout: 8))
        reach(app, mine)
        mine.tap()
        let uninstall = app.buttons["plugin.uninstall"]
        XCTAssertTrue(uninstall.waitForExistence(timeout: 5))
        uninstall.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5), "Uninstall asks first")
        shot(app, "plugin-uninstall-confirm")
        app.alerts.firstMatch.buttons["Uninstall"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.pluginNames().contains("my-plugin") }, "the gateway removed it")
    }

    @MainActor func testC13_TerminalBackendAndWebProvider() throws {
        let app = launch()
        openCapabilities(app, tab: "Tools")
        let terminal = app.descendants(matching: .any)["toolset-row-terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        terminal.tap()
        let docker = app.descendants(matching: .any)["terminal-backend-docker"]
        for _ in 0..<5 where !docker.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(docker.waitForExistence(timeout: 8), "the Execution Backend section lists Docker")
        reach(app, docker)
        shot(app, "toolset-terminal-backends")
        docker.tap()
        let anyway = app.buttons["Select Anyway"]
        XCTAssertTrue(anyway.waitForExistence(timeout: 5), "a backend that is not set up asks first")
        shot(app, "toolset-terminal-confirm")
        anyway.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { ((self.state()["backends"] as? [String: Any])?["default"] as? [String: Any])?["active"] as? String == "docker" },
                      "the gateway switched the backend")
        Thread.sleep(forTimeInterval: 1)
        shot(app, "toolset-terminal-docker")
        let local = app.buttons["terminal-use-local"]
        for _ in 0..<3 where !local.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(local.waitForExistence(timeout: 5), "a backend that is not set up offers the way back")
        local.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { ((self.state()["backends"] as? [String: Any])?["default"] as? [String: Any])?["active"] as? String == "local" })
    }

    // MARK: - Connect Apps (§10)

    // MARK: - Hermes' app catalog on More › Connectors ([directory])

    @MainActor func testE1_CatalogDirectoryInstall() throws {
        let app = launch()
        openMoreRow(app, "connectors")
        XCTAssertTrue(app.navigationBars["Connectors"].waitForExistence(timeout: 10), "More › Connectors opens its own page")
        XCTAssertFalse(app.buttons["Skills"].exists, "no tab control on the Connectors page")
        XCTAssertTrue(app.descendants(matching: .any)["connector-row-github"].waitForExistence(timeout: 10), "what the bot has shows as Connected")
        let tile = app.descendants(matching: .any)["catalog-tile-notion"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "the Popular grid shows Hermes' catalog")
        XCTAssertFalse(app.descendants(matching: .any)["catalog-tile-linear"].exists, "an app the bot already has isn't offered")
        shot(app, "directory-top")
        app.swipeUp()
        shot(app, "directory-ways")
        app.swipeUp()
        shot(app, "directory-all-apps")
        // Search reaches the whole catalog.
        app.swipeDown(); app.swipeDown()
        tile.tap()
        XCTAssertTrue(app.descendants(matching: .any)["catalog-app.page"].waitForExistence(timeout: 8), "the app page opens")
        shot(app, "catalog-notion")
        app.buttons["catalog-app.install"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.server("notion").isEmpty }, "the gateway installed Notion for the bot")
        XCTAssertEqual((writes("POST /api/mcp/catalog/install").last?["params"] as? [String: Any])?["name"] as? String, "notion")
        XCTAssertTrue(app.descendants(matching: .any)["connector-page"].waitForExistence(timeout: 10), "the new connector's own page follows")
        shot(app, "catalog-notion-installed")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.descendants(matching: .any)["connector-row-notion"].waitForExistence(timeout: 10), "Notion shows under Connected")
        XCTAssertFalse(app.descendants(matching: .any)["catalog-tile-notion"].exists, "and leaves Popular")
        shot(app, "directory-after-install")
    }

    @MainActor func testE2_CatalogKeyRequired() throws {
        let app = launch()
        openMoreRow(app, "connectors")
        XCTAssertTrue(app.descendants(matching: .any)["capabilities.list"].waitForExistence(timeout: 10))
        // [connectors-ux] the whole catalog is Popular › See All Apps, its own page
        let all = app.descendants(matching: .any)["connectors.all-apps"]
        for _ in 0..<6 where !(all.exists && all.isHittable) { app.swipeUp() }
        all.tap()
        let row = app.descendants(matching: .any)["catalog-row-n8n-official"]
        XCTAssertTrue(app.descendants(matching: .any)["catalog.all"].waitForExistence(timeout: 10))
        for _ in 0..<14 where !(row.exists && row.isHittable) { app.swipeUp() }
        row.tap()
        let install = app.buttons["catalog-app.install"]
        XCTAssertTrue(install.waitForExistence(timeout: 8))
        XCTAssertFalse(install.isEnabled, "Install waits for the required key")
        let field = app.textFields["catalog-key-N8N_MCP_SERVER_URL"]
        XCTAssertTrue(field.exists, "an address is typed in the open, not as a password")
        field.tap()
        field.typeText("https://n8n.example/mcp-server/http")
        XCTAssertTrue(install.isEnabled)
        shot(app, "catalog-n8n-key")
        install.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.server("n8n-official").isEmpty }, "installed with its key")
        XCTAssertEqual((writes("POST /api/mcp/catalog/install").last?["params"] as? [String: Any])?["env"] as? [String], ["N8N_MCP_SERVER_URL"])
    }

    @MainActor func testC9_ConnectAppsSetupConnectBotsRemove() throws {
        try XCTSkipIf(composio.isEmpty, "needs the Composio stand-in")
        let app = launch(["-HQDebugResetConnectApps", "YES"], environment: ["HQN_CAP_AUTH": "allow", "HQN_COMPOSIO_BASE": composio])
        openConnectApps(app)
        let key = app.secureTextFields["connect-apps.key"]
        if !key.waitForExistence(timeout: 10) {   // below the fold at large text sizes
            for _ in 0..<4 where !key.exists { app.swipeUp() }
            if !key.exists { shot(app, "debug-no-key-field") }
        }
        XCTAssertTrue(key.exists, "setup shows without a key")
        shot(app, "connect-setup")
        // A wrong key is refused by Composio and never saved.
        key.tap(); key.typeText("ak_wrong_key_123")
        app.buttons["connect-apps.continue"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["connect-apps.notice"].waitForExistence(timeout: 10), "a refused key says so")
        shot(app, "connect-setup-refused")
        key.tap(); key.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + "ak_mock_dispatch")
        app.buttons["connect-apps.continue"].tap()
        if !app.descendants(matching: .any)["connect-app-tile-gmail"].waitForExistence(timeout: 15) { shot(app, "debug-connect-home") }
        XCTAssertTrue(app.descendants(matching: .any)["connect-app-tile-gmail"].exists, "Home shows popular apps")
        XCTAssertTrue(mcp("default").allSatisfy { $0["name"] as? String != "composio" }, "setup wrote nothing to the gateway")
        shot(app, "connect-home-empty")
        // Connect Gmail.
        app.descendants(matching: .any)["connect-app-tile-gmail"].tap()
        let connect = app.buttons["connect-app.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 8))
        shot(app, "connect-app-gmail")
        connect.tap()
        XCTAssertTrue(app.descendants(matching: .any)["connect-app.connected"].waitForExistence(timeout: 30), "Gmail connects")
        shot(app, "connect-app-connected")
        let links = (try mock("/__state")["links"] as? [String: [String: Any]]) ?? [:]
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.values.first?["opens"] as? Int, 1, "the single-use link was opened exactly once")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["connect-app-row-gmail"].waitForExistence(timeout: 10), "Gmail is under Connected")
        shot(app, "connect-home-connected")
        // Bots: turn Ivy on.
        app.descendants(matching: .any)["connect-apps.bots-row"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["connect-bot-switch-ivy"].waitForExistence(timeout: 15))
        shot(app, "connect-bots")
        flip(app, "connect-bot-switch-ivy")
        XCTAssertTrue(waitUntil(timeout: 15) { self.mcp("ivy").contains { $0["name"] as? String == "composio" } }, "Ivy has the composio server")
        XCTAssertTrue(((state()["env"] as? [String: [String]])?["ivy"] ?? []).contains("COMPOSIO_API_KEY"), "and the key in its env")
        XCTAssertFalse(entryText("composio", profile: "ivy").contains("ak_mock_dispatch"), "the server entry holds a reference, not the key")
        XCTAssertFalse(mcp("default").contains { $0["name"] as? String == "composio" }, "other bots are untouched")
        shot(app, "connect-bots-ivy-on")
        // Every Composio call carried the key; nothing else did.
        let log = (try mock("/__state")["log"] as? [[String: Any]]) ?? []
        XCTAssertFalse(log.filter { ($0["path"] as? String ?? "").hasPrefix("/api/") }.contains { $0["key"] as? String == "none" })
        XCTAssertFalse(log.filter { !($0["path"] as? String ?? "").hasPrefix("/api/") }.contains { $0["key"] as? String != "none" },
                       "the logo and sign-in pages never saw the key")
        // Try It opens Ivy's chat with the words in the composer, unsent.
        app.navigationBars.buttons.firstMatch.tap()
        app.descendants(matching: .any)["connect-app-row-gmail"].tap()
        let tryIt = app.descendants(matching: .any)["connect-app.try-0"]
        XCTAssertTrue(tryIt.waitForExistence(timeout: 10), "Try It shows once a bot is on")
        shot(app, "connect-app-try-it")
        tryIt.tap()
        let composer = app.textViews["composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 12), "the chat opens")
        XCTAssertTrue(waitUntil(timeout: 5) { !((composer.value as? String) ?? "").isEmpty }, "with the words in the composer")
        shot(app, "connect-try-it-chat")
        XCTAssertTrue(writes("prompt.submit").isEmpty && ((state()["prompts"] as? [Any]) ?? []).isEmpty, "nothing was sent")
    }

    /// A page's search field rides away as the list scrolls down and comes back at the top (owner 2026-11-03: pinned,
    /// "it just feels like it's in the way when I'm scrolling down"). Connect Apps' home and its All Apps page.
    @MainActor func testC9b_ConnectAppsSearchHidesOnScroll() throws {
        try XCTSkipIf(composio.isEmpty, "needs the Composio stand-in")
        let app = launch(["-HQDebugResetConnectApps", "YES"], environment: ["HQN_CAP_AUTH": "allow", "HQN_COMPOSIO_BASE": composio])
        openConnectApps(app)
        let key = app.secureTextFields["connect-apps.key"]
        if !key.waitForExistence(timeout: 10) { for _ in 0..<4 where !key.exists { app.swipeUp() } }
        key.tap(); key.typeText("ak_mock_dispatch")
        app.buttons["connect-apps.continue"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["connect-app-tile-gmail"].waitForExistence(timeout: 15), "Home shows")
        func check(_ page: String) {
            let field = app.searchFields.firstMatch
            _ = waitUntil(timeout: 4) { field.exists && field.isHittable }
            shot(app, "search-\(page)-top")
            XCTAssertTrue(field.exists && field.isHittable, "\(page): the field is there at the top")
            app.swipeUp(); app.swipeUp()
            shot(app, "search-\(page)-scrolled")
            XCTAssertTrue(waitUntil(timeout: 3) { !field.exists || !field.isHittable || field.frame.height < 4 },
                          "\(page): scrolled down, the field is out of the way (\(field.frame))")
            for _ in 0..<4 { app.swipeDown() }
            XCTAssertTrue(waitUntil(timeout: 3) { field.exists && field.isHittable }, "\(page): back at the top, it is back")
        }
        check("connect-home")
        let all = app.descendants(matching: .any)["connect-apps.all"]
        for _ in 0..<6 where !all.isHittable { app.swipeUp() }
        all.tap()
        XCTAssertTrue(app.navigationBars["All Apps"].waitForExistence(timeout: 8))
        check("connect-all")
    }

    @MainActor func testD1_ConnectAppsRemoveAndNeedsSignIn() throws {
        try XCTSkipIf(composio.isEmpty, "needs the Composio stand-in")
        try mock("/__seed", ["accounts": [["toolkit": "github", "status": "ACTIVE"], ["toolkit": "slack", "status": "EXPIRED", "reason": "The token expired."]]])
        let app = launch(["-HQDebugResetConnectApps", "YES"], environment: ["HQN_CAP_AUTH": "allow", "HQN_COMPOSIO_BASE": composio])
        openConnectApps(app)
        let key = app.secureTextFields["connect-apps.key"]
        XCTAssertTrue(key.waitForExistence(timeout: 10))
        key.tap(); key.typeText("ak_mock_dispatch")
        app.buttons["connect-apps.continue"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["connect-app-row-slack"].waitForExistence(timeout: 15), "connected apps list")
        shot(app, "connect-home-needs-signin")
        app.descendants(matching: .any)["connect-app-row-slack"].tap()
        XCTAssertTrue(app.buttons["connect-app.connect"].waitForExistence(timeout: 8))
        shot(app, "connect-app-needs-signin")
        app.navigationBars.buttons.firstMatch.tap()
        // Disconnect GitHub.
        app.descendants(matching: .any)["connect-app-row-github"].tap()
        let disconnect = app.buttons["connect-app.disconnect"]
        XCTAssertTrue(disconnect.waitForExistence(timeout: 8))
        reach(app, disconnect)
        disconnect.tap()
        shot(app, "connect-disconnect-confirm")
        app.buttons.matching(NSPredicate(format: "label == %@", "Disconnect")).allElementsBoundByIndex.last?.tap()
        XCTAssertTrue(waitUntil(timeout: 10) {
            let accounts = ((try? self.mock("/__state"))?["accounts"] as? [String: [String: Any]]) ?? [:]
            return accounts.values.contains { $0["toolkit"] as? String == "github" && $0["status"] as? String == "DELETED" }
        }, "Composio dropped the account")
        app.navigationBars.buttons.firstMatch.tap()
        // Search.
        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 5) {
            search.tap(); search.typeText("lin")
            XCTAssertTrue(app.descendants(matching: .any)["connect-app-row-linear"].waitForExistence(timeout: 10), "search finds Linear")
            shot(app, "connect-search")
            for label in ["Cancel", "Close", "close"] where app.buttons[label].firstMatch.exists { app.buttons[label].firstMatch.tap(); break }
            if app.searchFields.firstMatch.buttons["Clear text"].exists { app.searchFields.firstMatch.buttons["Clear text"].tap() }
            if app.keyboards.firstMatch.exists { app.swipeDown() }
        }
        // Remove Composio: this iPhone forgets the key and setup shows again.
        app.buttons["connect-apps.account"].tap()
        shot(app, "connect-account-menu")
        app.buttons["Remove Composio"].tap()
        app.buttons.matching(NSPredicate(format: "label == %@", "Remove")).allElementsBoundByIndex.last?.tap()
        XCTAssertTrue(app.secureTextFields["connect-apps.key"].waitForExistence(timeout: 20), "setup shows again")
        shot(app, "connect-removed")
    }

    /// §10.11: a second Google Drive account under its own name. The first was connected on a session made before
    /// multi-account (the stand-in ignores the setting while `single_account` is on), so adding moves Ivy to a new
    /// multi-account session for the same user and the gateway record names it; then the page lists both by name.
    @MainActor func testD2_ConnectAppsSecondAccount() throws {
        try XCTSkipIf(composio.isEmpty, "needs the Composio stand-in")
        try mock("/__seed", ["single_account": true])
        let app = launch(["-HQDebugResetConnectApps", "YES"], environment: ["HQN_CAP_AUTH": "allow", "HQN_COMPOSIO_BASE": composio])
        openConnectApps(app)
        let key = app.secureTextFields["connect-apps.key"]
        XCTAssertTrue(key.waitForExistence(timeout: 10))
        key.tap(); key.typeText("ak_mock_dispatch")
        app.buttons["connect-apps.continue"].tap()
        let tile = app.descendants(matching: .any)["connect-app-tile-googledrive"]
        XCTAssertTrue(tile.waitForExistence(timeout: 15), "Home shows Google Drive")
        tile.tap()
        XCTAssertTrue(app.buttons["connect-app.connect"].waitForExistence(timeout: 8))
        app.buttons["connect-app.connect"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["connect-app.connected"].waitForExistence(timeout: 30), "the first account connects")
        app.navigationBars.buttons.firstMatch.tap()
        app.descendants(matching: .any)["connect-apps.bots-row"].tap()
        flip(app, "connect-bot-switch-ivy")
        XCTAssertTrue(waitUntil(timeout: 15) { self.mcp("ivy").contains { $0["name"] as? String == "composio" } }, "Ivy has the composio server")
        let sessions = { ((try? self.mock("/__state"))?["sessions"] as? [String: [String: Any]]) ?? [:] }
        XCTAssertEqual(sessions().count, 1)
        let old = try XCTUnwrap(sessions().keys.first)
        XCTAssertTrue(entryText("composio", profile: "ivy").contains(old))
        try mock("/__seed", ["single_account": false])

        // The app's page: one account, and Add Another Account.
        app.navigationBars.buttons.firstMatch.tap()
        app.descendants(matching: .any)["connect-app-row-googledrive"].tap()
        let first = app.descendants(matching: .any)["connect-app.account-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 10), "the page lists the account")
        // §10.12: an unnamed account is titled by its address, from the app's who-am-I tool.
        XCTAssertTrue(waitUntil(timeout: 10) { first.label.contains("jordan.lee@gmail.com") }, first.label)
        let add = app.buttons["connect-app.add-account"]
        reach(app, add)
        shot(app, "connect-app-one-account")
        add.tap()
        let field = app.textFields["connect-app.alias"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "asks for a name")
        field.typeText("Work")
        shot(app, "connect-app-name-prompt")
        app.alerts.buttons["Continue"].tap()
        let second = app.descendants(matching: .any)["connect-app.account-2"]
        if !second.waitForExistence(timeout: 30) { shot(app, "debug-no-second-account") }
        XCTAssertTrue(second.exists, "the second account is listed")
        XCTAssertTrue(second.label.contains("Work"), second.label)
        XCTAssertTrue(waitUntil(timeout: 10) { second.label.contains("jordan@work.com") }, "the address under the name: \(second.label)")
        reach(app, second)
        shot(app, "connect-app-two-accounts")

        // The wire: a new multi-account session for the same user, Ivy moved to it, the record names it.
        let now = sessions()
        XCTAssertEqual(now.count, 2)
        let new = try XCTUnwrap(now.keys.first { $0 != old })
        XCTAssertEqual((now[new]?["multi"] as? [String: Any])?["enable"] as? Bool, true)
        XCTAssertEqual(now[new]?["user"] as? String, now[old]?["user"] as? String, "the same Composio user")
        XCTAssertTrue(entryText("composio", profile: "ivy").contains(new), "Ivy uses the new session")
        let record = ((state()["ui_meta"] as? [String: Any])?["default"] as? [String: Any])?["dispatch-composio"] as? [String: Any]
        XCTAssertEqual(record?["sessionId"] as? String, new, "the gateway record names the new session")
        let accounts = ((try mock("/__state"))["accounts"] as? [String: [String: Any]] ?? [:]).values.filter {
            $0["toolkit"] as? String == "googledrive" && $0["status"] as? String == "ACTIVE"
        }
        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(accounts.compactMap { $0["alias"] as? String }, ["work"])

        // Name the first one.
        app.buttons["connect-app.account-menu-1"].tap()
        app.buttons["Name This Account…"].tap()
        let rename = app.textFields["connect-app.alias"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        XCTAssertEqual(rename.value as? String, "personal", "an unnamed account's prompt offers a name from its address")
        shot(app, "connect-app-name-suggestion")
        rename.typeText("Home")
        shot(app, "connect-app-rename-prompt")
        app.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { first.label.contains("Home") }, first.label)
        shot(app, "connect-app-accounts-named")

        // The account's own page: its name, address, person, date and Composio's code; a rename there shows on both.
        first.tap()
        let email = app.descendants(matching: .any)["connect-account.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 8), "the account page opens")
        XCTAssertTrue(email.label.contains("jordan.lee@gmail.com"), email.label)
        XCTAssertTrue(app.descendants(matching: .any)["connect-account.person"].label.contains("Jordan Lee"))
        XCTAssertTrue(app.staticTexts["connect-account.title"].label.contains("Home"))
        XCTAssertTrue(app.descendants(matching: .any)["connect-account.code"].label.contains("googledrive_"))
        shot(app, "connect-account-page")
        app.buttons["connect-account.rename"].tap()
        let again = app.textFields["connect-app.alias"]
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        XCTAssertEqual(again.value as? String, "home", "a named account's prompt starts with its name")
        again.typeText("Personal")   // the name starts selected: typing replaces it
        app.alerts.buttons["Save"].tap()
        if !waitUntil(timeout: 10, { app.staticTexts["connect-account.title"].label.contains("Personal") }) { shot(app, "debug-account-rename") }
        XCTAssertTrue(app.staticTexts["connect-account.title"].label.contains("Personal"), app.staticTexts["connect-account.title"].label)
        reach(app, app.buttons["connect-account.disconnect"])
        shot(app, "connect-account-page-bottom")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { first.label.contains("Personal") }, first.label)
    }

    // MARK: - Helpers

    @discardableResult func mock(_ path: String, _ body: [String: Any]? = nil) throws -> [String: Any] {
        try control(composio, path, body)
    }

    /// One control call on its own connection (the gateway stand-in mishandles control posts on a reused one).
    @discardableResult func control(_ base: String, _ path: String, _ body: [String: Any]? = nil) throws -> [String: Any] {
        var request = URLRequest(url: URL(string: base + path)!, timeoutInterval: 10)
        request.setValue("close", forHTTPHeaderField: "Connection")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request) { data, response, error in
            box.data = data; box.status = (response as? HTTPURLResponse)?.statusCode; box.error = error
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 12)
        session.finishTasksAndInvalidate()
        if let error = box.error { throw error }
        guard let status = box.status, (200..<300).contains(status) else {
            throw NSError(domain: "fixture", code: box.status ?? -1, userInfo: [NSLocalizedDescriptionKey: "\(path) answered \(box.status ?? -1)"])
        }
        return (box.data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    private final class Box: @unchecked Sendable {
        var data: Data?
        var status: Int?
        var error: Error?
    }

    /// Writes of one RPC method the gateway saw, oldest first.
    func writes(_ method: String) -> [[String: Any]] {
        ((state()["writes"] as? [[String: Any]]) ?? []).filter { $0["method"] as? String == method }
    }

    func state() -> [String: Any] { (try? control(gateway.url, "/__state")) ?? [:] }
    func rows(_ key: String, _ profile: String) -> [[String: Any]] { ((state()[key] as? [String: Any])?[profile] as? [[String: Any]]) ?? [] }
    func mcp(_ profile: String) -> [[String: Any]] { rows("mcp", profile) }
    func server(_ name: String, profile: String = "default") -> [String: Any] { mcp(profile).first { $0["name"] as? String == name } ?? [:] }
    func toolset(_ name: String) -> [String: Any] { rows("toolsets", "default").first { $0["name"] as? String == name } ?? [:] }
    func plugin(_ name: String) -> [String: Any] { rows("plugins", "default").first { $0["name"] as? String == name } ?? [:] }
    func pluginNames() -> [String] { rows("plugins", "default").compactMap { $0["name"] as? String } }
    func installedSkills() -> [[String: Any]] {
        (((state()["skills"] as? [String: Any])?["default"] as? [String: Any])?["installed"] as? [[String: Any]]) ?? []
    }
    func entryText(_ name: String, profile: String = "default") -> String {
        guard let entry = server(name, profile: profile)["_entry"], let data = try? JSONSerialization.data(withJSONObject: entry) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor func launch(_ arguments: [String] = [], environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        let dark = ProcessInfo.processInfo.environment["HQN_SHOTS_DARK"] == "1"
        app.launchArguments = ["-HQDebugResetAccounts", "YES", "-HQDebugNoDrag", "YES"] + (dark ? ["-hqn.appearance", "dark"] : []) + arguments
        // HQN_TEXT_SIZE (e.g. UICTContentSizeCategoryAccessibilityL): the same tests at a larger text size.
        if let size = ProcessInfo.processInfo.environment["HQN_TEXT_SIZE"], !size.isEmpty { app.launchArguments += ["-UIPreferredContentSizeCategoryName", size] }
        // HQN_UI_DESKTOPLOOK=1: the same tests with Desktop Look on.
        if ProcessInfo.processInfo.environment["HQN_UI_DESKTOPLOOK"] == "1" { app.launchArguments += ["-HQDebugDesktopLook", "YES"] }
        app.launchEnvironment = ["HQN_SIGNIN_URL": gateway.url, "HQN_SIGNIN_USERNAME": gateway.username, "HQN_SIGNIN_PASSWORD": gateway.password]
            .merging(environment) { _, new in new }
        app.launch()
        XCTAssertTrue(app.cells["bot-row-ivy"].waitForExistence(timeout: 30), "the Bots list shows")
        return app
    }

    @MainActor func openMoreRow(_ app: XCUIApplication, _ id: String) {
        // The tab bar's in the iOS look, the Desktop Look's own bar otherwise.
        var more = app.tabBars.buttons["More"]
        if !more.waitForExistence(timeout: 10) { more = app.buttons["More"].firstMatch }
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        let row = app.cells["more-row-\(id)"]
        for _ in 0..<4 {
            more.tap()
            if row.waitForExistence(timeout: 2), row.isHittable { break }
        }
        // More has grown: rows past the first screen need a scroll.
        for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.exists, "More lists \(id)")
        row.tap()
    }

    /// [cap-pages] More › Capabilities is four rows; `tab` opens that list's own page (Skills when nil).
    @MainActor func openCapabilities(_ app: XCUIApplication, tab: String?) {
        openMoreRow(app, "capabilities")
        openList(app, tab ?? "Skills")
    }

    /// On Capabilities' four rows: that list's page.
    @MainActor func openList(_ app: XCUIApplication, _ name: String) {
        let row = app.descendants(matching: .any)["capabilities.row.\(name.lowercased())"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Capabilities lists \(name)")
        row.tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 10), "\(name) opens as its own page")
        XCTAssertTrue(app.descendants(matching: .any)["capabilities.list"].waitForExistence(timeout: 10), "\(name) lists")
    }

    /// From one list's page: Back to Capabilities, then another list.
    @MainActor func switchList(_ app: XCUIApplication, to name: String) {
        app.navigationBars.buttons["Capabilities"].firstMatch.tap()
        openList(app, name)
    }

    @MainActor func openConnectApps(_ app: XCUIApplication) {
        // [directory] Connect Apps lives inside More › Connectors now, under More Ways to Connect.
        openMoreRow(app, "connectors")
        let row = app.descendants(matching: .any)["connectors.connect-apps"]
        XCTAssertTrue(app.descendants(matching: .any)["capabilities.list"].waitForExistence(timeout: 10), "Connectors opens")
        for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.exists, "Connectors offers Connect Apps")
        row.tap()
        XCTAssertTrue(app.navigationBars["Connect Apps"].waitForExistence(timeout: 10), "Connect Apps opens")
    }

    /// The page's + / ⋯ button; with an item, the menu entry of that name.
    @MainActor func tapAdd(_ app: XCUIApplication, item: String? = "") {
        let direct = app.buttons["connectors.add"].exists ? app.buttons["connectors.add"] : app.buttons["plugins.install"]
        if item == "", direct.exists { direct.tap(); return }
        let more = app.buttons["capabilities.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), "the page's menu button")
        more.tap()
        guard let item else { return }
        let wanted = item.isEmpty ? "Add Your Own" : item
        let entry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", wanted)).firstMatch
        // A tap that lands while an alert is still leaving opens nothing: ask once more.
        if !entry.waitForExistence(timeout: 4) { more.tap() }
        if !entry.waitForExistence(timeout: 4) { shot(app, "debug-menu") }
        XCTAssertTrue(entry.exists, "the menu offers \(wanted)")
        entry.tap()
    }

    /// Flips a switch by its identifier, scrolling it into reach first.
    @MainActor func flip(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let toggle = app.switches[id].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "switch \(id)", file: file, line: line)
        reach(app, toggle)
        let inner = toggle.switches.firstMatch
        (inner.exists ? inner : toggle).tap()
    }

    /// Scrolls until the element is clear of the floating tab bar (a tap there would land on the bar).
    @MainActor func reach(_ app: XCUIApplication, _ element: XCUIElement) {
        let limit = app.windows.firstMatch.frame.height - 130
        for _ in 0..<6 where !element.isHittable || element.frame.midY > limit {
            app.swipeUp(velocity: .slow)
        }
    }

    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }

    @MainActor func shot(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.6)
        let screenshot = app.screenshot()
        let mode = (ProcessInfo.processInfo.environment["HQN_SHOTS_DARK"] == "1" ? "dark" : "light")
            + (ProcessInfo.processInfo.environment["HQN_UI_DESKTOPLOOK"] == "1" ? "-desktop" : "")
        if let dir = ProcessInfo.processInfo.environment["HQN_SHOTS"], !dir.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(mode).png"))
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(name)-\(mode)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
