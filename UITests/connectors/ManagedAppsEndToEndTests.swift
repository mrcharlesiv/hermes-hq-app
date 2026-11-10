// Managed apps (Capabilities › Connectors › Managed Apps: the apps reached through a bot's Nous account) against
// scripts/fixtures/connectors-gateway.py: the real app, real taps, and the stand-in's `/__connectors` as the wire
// evidence. Run with scripts/e2e-connectors.sh <UDID>.

import XCTest

final class ManagedAppsEndToEndTests: XCTestCase {
    var gateway: SettingsFixture!

    override func setUpWithError() throws {
        continueAfterFailure = false
        gateway = try SettingsFixture.load("HQN_CONN_A")
        do { try control("/__connectors", ["reset": true]) } catch { try control("/__connectors", ["reset": true]) }
    }

    // MARK: - Browse and search

    @MainActor func testM1_BrowseAndSearch() throws {
        let app = launch()
        openConnectors(app)
        XCTAssertTrue(element(app, "managed-row-github").waitForExistence(timeout: 15), "the bot's connected apps show")
        XCTAssertTrue(element(app, "managed-row-slack").exists, "an expired sign-in is listed too")
        XCTAssertTrue(app.staticTexts["Managed Apps"].exists, "the managed section is named")
        shot(app, "connectors-tab")
        XCTAssertTrue(words(app).contains("Access expired"), "Slack says its access expired: \(words(app))")
        let browse = element(app, "managed.browse")
        reach(app, browse)
        browse.tap()
        XCTAssertTrue(element(app, "managed.catalog").waitForExistence(timeout: 10), "the catalog opens")
        XCTAssertTrue(element(app, "managed-row-airtable").waitForExistence(timeout: 5), "apps not yet connected are offered")
        XCTAssertTrue(element(app, "managed-connect-airtable").exists, "with a Connect button")
        shot(app, "catalog")
        // Search by name and by description.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("calendar")
        XCTAssertTrue(element(app, "managed-row-google_calendar").waitForExistence(timeout: 5), "Google Calendar matches")
        XCTAssertTrue(waitUntil(timeout: 4) { !self.element(app, "managed-row-airtable").exists }, "Airtable does not")
        shot(app, "catalog-search")
        search.clearAndType("zzqx")
        XCTAssertTrue(element(app, "managed.catalog.empty").waitForExistence(timeout: 5), "an honest empty state")
        shot(app, "catalog-no-match")
        app.buttons["managed.catalog.clear"].tap()
        XCTAssertTrue(element(app, "managed-row-airtable").waitForExistence(timeout: 5), "clearing brings every app back")
        // A category.
        // Leave the search so the category menu shows.
        for label in ["Cancel", "Close"] where app.buttons[label].firstMatch.exists { app.buttons[label].firstMatch.tap(); break }
        app.buttons["managed.catalog.category"].tap()
        let files = app.buttons["Files"].firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 5), "the categories are offered")
        files.tap()
        XCTAssertTrue(element(app, "managed-row-dropbox").waitForExistence(timeout: 5), "Files shows Dropbox")
        XCTAssertFalse(element(app, "managed-row-airtable").exists, "and not Airtable")
        shot(app, "catalog-category")
        // Jira is off by the organisation: listed once, under Turned Off.
        app.buttons["managed.catalog.clear-category"].tap()
        let jira = app.descendants(matching: .any).matching(identifier: "managed-row-jira")
        reach(app, jira.firstMatch)
        XCTAssertEqual(jira.count, 1, "an app turned off shows once")
        let sent = rpc("connectors.list")
        XCTAssertFalse(sent.isEmpty)
        XCTAssertEqual(Set((sent.last?["params"] as? [String: Any] ?? [:]).keys), ["profile", "owner"], "only the contract's params")
    }

    // MARK: - [accounts] Named accounts and [hub] the Skills Hub

    @MainActor func testM20_NamedAccounts() throws {
        try control("/__connectors", ["multi_accounts": ["profile": "default"]])
        let app = launch()
        openConnectors(app)
        let gmail = element(app, "managed-row-gmail")
        XCTAssertTrue(gmail.waitForExistence(timeout: 15))
        reach(app, gmail)
        gmail.tap()
        let work = element(app, "managed-account-work")
        XCTAssertTrue(work.waitForExistence(timeout: 10), "every account shows by its name")
        reach(app, work)
        XCTAssertTrue(element(app, "managed-account-home").exists)
        XCTAssertTrue(words(app).contains("Access expired"), "home's status shows: \(words(app))")
        shot(app, "accounts")
        // Rename work → office.
        element(app, "managed-account-menu-work").tap()
        let rename = app.buttons["Rename…"].firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.tap()
        let field = app.textFields["managed-account-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "home")
        shot(app, "accounts-rename")
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 5)); app.buttons["Save"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { app.staticTexts["That name is already used."].exists }, "a taken name asks again with the reason")
        shot(app, "accounts-rename-taken")
        let again = app.textFields["managed-account-name"]
        again.tap()
        again.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "office")
        shot(app, "accounts-rename-office")
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 5)); app.buttons["Save"].tap()
        XCTAssertTrue(element(app, "managed-account-office").waitForExistence(timeout: 10), "the new name shows")
        let renamed = rpc("connectors.accounts.rename").last?["params"] as? [String: Any]
        XCTAssertEqual(renamed?["alias"] as? String, "office")
        // Add Another Account names it and opens the sign-in.
        let add = element(app, "managed-account-add")
        reach(app, add)
        add.tap()
        XCTAssertTrue(app.textFields["managed-account-name"].waitForExistence(timeout: 5))
        app.textFields["managed-account-name"].typeText("side")
        shot(app, "accounts-add")
        XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 5)); app.buttons["Connect"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { (self.rpc("connectors.connect").last?["params"] as? [String: Any])?["alias"] as? String == "side" },
                      "the connect names the account")
    }

    @MainActor func testM21_SkillsHubSearch() throws {
        let app = launch()
        let more = moreTab(app)
        let row = app.cells["more-row-capabilities"]
        for _ in 0..<4 {
            more.tap()
            if row.waitForExistence(timeout: 2), row.isHittable { break }
        }
        row.tap()
        let skills = element(app, "capabilities.row.skills")   // [cap-pages] Capabilities' four rows
        XCTAssertTrue(skills.waitForExistence(timeout: 10))
        skills.tap()
        XCTAssertTrue(element(app, "capabilities.list").waitForExistence(timeout: 10))
        let search = app.searchFields.firstMatch
        if !search.waitForExistence(timeout: 2), app.buttons["capabilities.search"].exists { app.buttons["capabilities.search"].tap() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("pdf")
        let hub = element(app, "skills.hub.search")
        reach(app, hub)
        XCTAssertTrue(hub.waitForExistence(timeout: 5), "Search the Skills Hub is offered")
        shot(app, "hub-offer")
        hub.tap()
        let redact = element(app, "skill-hub-get-pdf-redact")
        XCTAssertTrue(redact.waitForExistence(timeout: 15), "hub results show")
        reach(app, redact)
        XCTAssertTrue(words(app).contains("Community"), "community skills are marked: \(words(app))")
        shot(app, "hub-results")
        redact.tap()
        XCTAssertTrue(app.buttons["Install"].waitForExistence(timeout: 5))
        shot(app, "hub-confirm")
        app.buttons["Install"].tap()
        XCTAssertTrue(element(app, "skill-hub-installed-pdf-redact").waitForExistence(timeout: 30), "it installs")
        shot(app, "hub-installed")
    }

    // MARK: - Connect

    @MainActor func testM2_ConnectSucceeds() throws {
        let app = launch(environment: ["HQN_CAP_AUTH": "allow"])
        openCatalog(app, search: "notion")
        let connect = app.buttons["managed-connect-notion"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()
        XCTAssertTrue(element(app, "managed.app").waitForExistence(timeout: 10), "Notion's page opens")
        shot(app, "connect-waiting")
        XCTAssertTrue(waitUntil(timeout: 20) { self.account("notion", profile: "default")?["status"] as? String == "active" }, "Nous holds the sign-in")
        let state = element(app, "managed-app-state")
        XCTAssertTrue(waitUntil(timeout: 15) { state.label.contains("Connected") }, "the page says Connected: \(state.label)")
        XCTAssertFalse(element(app, "managed-connecting").exists, "nothing is left waiting")
        XCTAssertTrue(element(app, "managed-disconnect").waitForExistence(timeout: 5) || { reach(app, element(app, "managed-disconnect")); return element(app, "managed-disconnect").exists }(),
                      "the account and Disconnect show")
        shot(app, "connect-done")
        let connects = rpc("connectors.connect")
        XCTAssertEqual(connects.count, 1, "one connect")
        let params = connects.first?["params"] as? [String: Any] ?? [:]
        XCTAssertEqual(Set(params.keys), ["profile", "owner", "connectors", "reconnect"])
        XCTAssertEqual(params["connectors"] as? [String], ["notion"])
        // The operation moved by broadcasts, not by polling.
        XCTAssertLessThanOrEqual(rpc("connectors.operation.status").count, 3, "no busy polling: \(rpc("connectors.operation.status").count) status reads")
    }

    @MainActor func testM3_ConnectDeclined() throws {
        let app = launch(environment: ["HQN_CAP_AUTH": "deny"])
        openCatalog(app, search: "linear")
        XCTAssertTrue(app.buttons["managed-connect-linear"].waitForExistence(timeout: 10))
        app.buttons["managed-connect-linear"].tap()
        let ended = element(app, "managed-connect-ended")
        XCTAssertTrue(ended.waitForExistence(timeout: 20), "a declined sign-in says so")
        XCTAssertTrue(ended.label.contains("did not finish"), ended.label)
        XCTAssertTrue(app.buttons["managed-try-again"].exists, "and offers Try Again")
        shot(app, "connect-declined")
        XCTAssertNotEqual(account("linear", profile: "default")?["status"] as? String, "active")
    }

    @MainActor func testM4_LinkExpiresThenTryAgainAndStopWaiting() throws {
        let app = launch(environment: ["HQN_CAP_AUTH": "close"])
        openCatalog(app, search: "asana")
        XCTAssertTrue(app.buttons["managed-connect-asana"].waitForExistence(timeout: 10))
        app.buttons["managed-connect-asana"].tap()
        XCTAssertTrue(element(app, "managed-connecting").waitForExistence(timeout: 10), "waiting for the browser")
        XCTAssertTrue(app.buttons["managed-open-again"].waitForExistence(timeout: 5), "the link can be opened again")
        XCTAssertTrue(waitUntil(timeout: 8) { !((self.connectors()["wakes"] as? [Any]) ?? []).isEmpty }, "closing the sheet woke the operation")
        shot(app, "connect-sheet-closed")
        try control("/__connectors", ["expire": ["op": NSNull()]])
        let ended = element(app, "managed-connect-ended")
        XCTAssertTrue(ended.waitForExistence(timeout: 10), "the broadcast reached the page")
        XCTAssertTrue(ended.label.contains("expired"), ended.label)
        shot(app, "connect-expired")
        app.buttons["managed-try-again"].tap()
        XCTAssertTrue(element(app, "managed-connecting").waitForExistence(timeout: 10), "a new link")
        XCTAssertEqual(rpc("connectors.connect").count, 2, "Try Again asked Nous for a new link")
        app.buttons["managed-stop-waiting"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.element(app, "managed-connecting").exists }, "Stop Waiting ends the wait")
        let respond = rpc("connection.respond").last?["params"] as? [String: Any] ?? [:]
        XCTAssertEqual((respond["result"] as? [String: Any])?["settled_by"] as? String, "continue", "the operation was given up: \(respond)")
        XCTAssertTrue(app.buttons["managed-verb"].waitForExistence(timeout: 8), "Connect is offered again")
        shot(app, "connect-stopped")
    }

    // MARK: - Remove

    @MainActor func testM5_Disconnect() throws {
        let app = launch()
        openConnectors(app)
        let gmail = element(app, "managed-row-gmail")
        XCTAssertTrue(gmail.waitForExistence(timeout: 15))
        reach(app, gmail)   // [connectors-ux] the shorter list leaves Gmail's row under the tab bar
        gmail.tap()
        let disconnect = element(app, "managed-disconnect")
        XCTAssertTrue(disconnect.waitForExistence(timeout: 10))
        reach(app, disconnect)
        shot(app, "app-gmail")
        disconnect.tap()
        let alert = app.alerts["Disconnect Gmail?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "disconnecting asks first")
        shot(app, "disconnect-confirm")
        alert.buttons["Disconnect"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { self.account("gmail", profile: "default") == nil }, "Nous no longer holds the Gmail sign-in")
        XCTAssertTrue(app.buttons["managed-verb"].waitForExistence(timeout: 10), "Connect is offered again")
        let params = rpc("connectors.accounts.remove").last?["params"] as? [String: Any] ?? [:]
        XCTAssertEqual(Set(params.keys), ["profile", "connection_id"])
    }

    // MARK: - Per bot: access and tools

    @MainActor func testM6_AccessAndToolsPerBot() throws {
        let app = launch()
        openConnectors(app)
        let github = element(app, "managed-row-github")
        XCTAssertTrue(github.waitForExistence(timeout: 15))
        github.tap()
        XCTAssertTrue(app.switches["managed-access-switch"].waitForExistence(timeout: 10))
        shot(app, "app-github")
        flip(app, "managed-access-switch")
        XCTAssertTrue(waitUntil(timeout: 10) { self.memberOff("default").contains("github") }, "Nous turned GitHub off for this account")
        XCTAssertFalse(memberOff("ivy").contains("github"), "Ivy's account is untouched")
        let set = rpc("connectors.policy.set").last?["params"] as? [String: Any] ?? [:]
        XCTAssertEqual(Set(set.keys), ["profile", "change", "expected_revision"])
        flip(app, "managed-access-switch")
        XCTAssertTrue(waitUntil(timeout: 10) { !self.memberOff("default").contains("github") }, "and back on")
        // One tool off, saved.
        let tool = app.switches["managed-tool-switch-github_create_issue"]
        _ = app.descendants(matching: .any)["managed-tools-search"].waitForExistence(timeout: 10)
        reach(app, tool)
        XCTAssertTrue(tool.waitForExistence(timeout: 10), "GitHub's tools load")
        flip(app, "managed-tool-switch-github_create_issue")
        let save = app.buttons["managed-tools-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "an unsaved change offers Save")
        shot(app, "tools-draft")
        save.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { self.memberTools("default", "github").contains("github_create_issue") }, "the rule reached Nous")
        XCTAssertTrue(memberTools("default", "github").contains("github_delete_repo"), "the tool already off stays off")
        // Ivy: a different Nous account, nothing connected.
        app.navigationBars.buttons.firstMatch.tap()
        pickBot(app, "Ivy")
        XCTAssertTrue(waitUntil(timeout: 15) { self.words(app).contains("No apps connected yet") }, "Ivy has no apps: \(words(app))")
        XCTAssertFalse(element(app, "managed-row-github").exists)
        XCTAssertTrue(rpc("connectors.list").contains { $0["profile"] as? String == "ivy" }, "Ivy's own account was read")
        shot(app, "connectors-ivy")
    }

    // MARK: - An account without managed apps

    @MainActor func testM7_SignedOutAndUnavailable() throws {
        try control("/__connectors", ["mode": ["profile": "ivy", "mode": "signed_out"]])
        try control("/__connectors", ["mode": ["profile": "research", "mode": "unavailable"]])
        let app = launch()
        openConnectors(app)
        XCTAssertTrue(element(app, "managed-row-github").waitForExistence(timeout: 15))
        pickBot(app, "Ivy")
        let box = element(app, "managed.nous")
        XCTAssertTrue(box.waitForExistence(timeout: 15), "a bot without a Nous sign-in says so")
        XCTAssertTrue(app.buttons["nous.sign-in"].waitForExistence(timeout: 8), "and offers Sign In to Nous")
        XCTAssertFalse(element(app, "managed.browse").exists, "no Browse button that could do nothing")
        shot(app, "signed-out")
        pickBot(app, "Research")
        // Signed in, but Nous hasn't turned managed apps on for the account: no button, the reason in words, as a footer
        // line below More Ways to Connect with no Managed Apps header (UX study #96).
        XCTAssertTrue(waitUntil(timeout: 15) { self.element(app, "nous.unavailable").exists || { app.swipeUp(); return false }() },
                      "an account without managed apps says so")
        XCTAssertFalse(app.staticTexts["Managed Apps"].exists, "no header over a sentence with nothing to tap")
        XCTAssertFalse(app.buttons["nous.sign-in"].exists)
        XCTAssertFalse(element(app, "managed.browse").exists)
        shot(app, "unavailable")
    }

    // [nous-sign-in] The owner's case: Hermes signed out of Nous (the apps read as unavailable); Sign In to Nous from
    // the phone, approve on the Nous page, and the managed apps appear.
    @MainActor func testM8_SignInToNousFromThePhone() throws {
        try control("/__connectors", ["mode": ["profile": "ivy", "mode": "unavailable"]])
        try control("/__connectors", ["signed_in": ["profile": "ivy", "value": false]])
        let app = launch(environment: ["HQN_CAP_AUTH": "allow"])
        openConnectors(app)
        XCTAssertTrue(element(app, "managed-row-github").waitForExistence(timeout: 15))
        pickBot(app, "Ivy")
        let button = app.buttons["nous.sign-in"]
        XCTAssertTrue(button.waitForExistence(timeout: 15), "signed out of Nous: Sign In to Nous")
        shot(app, "nous-sign-in")
        try control("/__connectors", ["mode": ["profile": "ivy", "mode": "ok"]])   // Nous has managed apps for this account
        reach(app, button)
        button.tap()
        XCTAssertTrue(waitUntil(timeout: 20) { !self.element(app, "managed.nous").exists }, "the box leaves once Hermes is signed in")
        let browse = element(app, "managed.browse")   // Ivy's account has no apps yet: the catalog to connect them
        XCTAssertTrue(waitUntil(timeout: 20) {
            self.reach(app, browse)
            return browse.exists
        }, "and the managed apps show")
        let log = (connectors()["log"] as? [[String: Any]]) ?? []
        XCTAssertTrue(log.contains { $0["path"] as? String == "/api/providers/oauth/nous/start" && $0["profile"] as? String == "ivy" }, "signed in for Ivy's profile")
        XCTAssertTrue(log.contains { $0["kind"] as? String == "nous-page" && $0["choice"] as? String == "allow" }, "the Nous page was approved")
        shot(app, "nous-signed-in")
    }

    @MainActor func testM9_NousSignInDeclined() throws {
        try control("/__connectors", ["mode": ["profile": "ivy", "mode": "signed_out"]])
        let app = launch(environment: ["HQN_CAP_AUTH": "deny"])
        openConnectors(app)
        XCTAssertTrue(element(app, "managed-row-github").waitForExistence(timeout: 15))
        pickBot(app, "Ivy")
        let button = app.buttons["nous.sign-in"]
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        reach(app, button)
        button.tap()
        XCTAssertTrue(element(app, "nous.failed").waitForExistence(timeout: 20), "a declined sign-in says so")
        XCTAssertTrue(button.exists, "and Sign In to Nous is offered again")
        shot(app, "nous-declined")
    }

    // MARK: - Helpers

    @MainActor func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    @MainActor func words(_ app: XCUIApplication) -> String { app.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " | ") }

    /// More: the tab bar's in the iOS look, the Desktop Look's own bar otherwise.
    @MainActor func moreTab(_ app: XCUIApplication) -> XCUIElement {
        let tab = app.tabBars.buttons["More"]
        if tab.waitForExistence(timeout: 5) { return tab }
        let any = app.buttons["More"].firstMatch
        XCTAssertTrue(any.waitForExistence(timeout: 5), "More")
        return any
    }

    @MainActor func openConnectors(_ app: XCUIApplication) {
        let more = moreTab(app)
        let row = app.cells["more-row-capabilities"]
        for _ in 0..<4 {
            more.tap()
            if row.waitForExistence(timeout: 2), row.isHittable { break }
        }
        row.tap()
        let connectors = element(app, "capabilities.row.connectors")   // [cap-pages] Capabilities' four rows
        XCTAssertTrue(connectors.waitForExistence(timeout: 10), "Capabilities opens")
        connectors.tap()
        XCTAssertTrue(element(app, "capabilities.list").waitForExistence(timeout: 10), "Connectors opens")
    }

    @MainActor func openCatalog(_ app: XCUIApplication, search text: String? = nil) {
        openConnectors(app)
        let browse = element(app, "managed.browse")
        // Managed Apps sits below Connected (build 280): the list only makes the button once it's scrolled to.
        XCTAssertTrue(waitUntil(timeout: 20) {
            self.reach(app, browse)
            return browse.exists && browse.isHittable
        }, "Browse Apps")
        browse.tap()
        XCTAssertTrue(element(app, "managed.catalog").waitForExistence(timeout: 10))
        guard let text else { return }
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText(text)
    }

    @MainActor func pickBot(_ app: XCUIApplication, _ name: String) {
        let picker = app.buttons["capabilities.bot"]
        for _ in 0..<4 where !picker.isHittable { app.swipeDown(velocity: .fast) }
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "the bot picker")
        picker.tap()
        let entry = app.buttons[name].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "the picker offers \(name)")
        entry.tap()
    }

    @MainActor func launch(environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        let dark = ProcessInfo.processInfo.environment["HQN_SHOTS_DARK"] == "1"
        let desktop = ProcessInfo.processInfo.environment["HQN_DESKTOP_LOOK"] == "1"
        app.launchArguments = ["-HQDebugResetAccounts", "YES", "-HQDebugNoDrag", "YES"] + (dark ? ["-hqn.appearance", "dark"] : [])
            + ["-HQDebugDesktopLook", desktop ? "YES" : "NO"]
        app.launchEnvironment = ["HQN_SIGNIN_URL": gateway.url, "HQN_SIGNIN_USERNAME": gateway.username, "HQN_SIGNIN_PASSWORD": gateway.password]
            .merging(environment) { _, new in new }
        app.launch()
        XCTAssertTrue(app.cells["bot-row-ivy"].waitForExistence(timeout: 30), "the Bots list shows")
        return app
    }

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
        for _ in 0..<8 where !element.exists || !element.isHittable || element.frame.midY > limit {
            app.swipeUp(velocity: .slow)
        }
    }

    @MainActor func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
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
            + (ProcessInfo.processInfo.environment["HQN_DESKTOP_LOOK"] == "1" ? "-desktop" : "")
        if let dir = ProcessInfo.processInfo.environment["HQN_SHOTS"], !dir.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(mode).png"))
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(name)-\(mode)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: The stand-in's state

    @discardableResult func control(_ path: String, _ body: [String: Any]? = nil) throws -> [String: Any] {
        var request = URLRequest(url: URL(string: gateway.url + path)!, timeoutInterval: 10)
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

    func connectors() -> [String: Any] { (try? control("/__connectors")) ?? [:] }
    func nous(_ profile: String) -> [String: Any] { ((connectors()["nous"] as? [String: Any])?[profile] as? [String: Any]) ?? [:] }
    func account(_ slug: String, profile: String) -> [String: Any]? {
        ((nous(profile)["accounts"] as? [[String: Any]]) ?? []).first { $0["connector"] as? String == slug && $0["status"] as? String != "pending" }
    }
    func memberOff(_ profile: String) -> [String] { ((nous(profile)["member"] as? [String: Any])?["disabled_connectors"] as? [String]) ?? [] }
    func memberTools(_ profile: String, _ slug: String) -> [String] {
        (((nous(profile)["member"] as? [String: Any])?["tools"] as? [String: Any])?[slug] as? [String]) ?? []
    }
    /// Every call of one method the stand-in answered, oldest first.
    func rpc(_ method: String) -> [[String: Any]] {
        ((connectors()["log"] as? [[String: Any]]) ?? []).filter { $0["kind"] as? String == "rpc" && $0["method"] as? String == method }
    }
}
