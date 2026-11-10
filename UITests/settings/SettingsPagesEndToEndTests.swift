// Gateway Settings pages end to end (docs/parity-240.md §19) against the settings fixture's config schema, env, model,
// vault and billing stand-ins: the real app, real taps, and the fixture's recorded writes (`/__settings/state`) as the
// wire evidence. Run with scripts/e2e-settings.sh (HQN_E2E_ONLY="testG1_…" for one).

import XCTest

extension SettingsEndToEndTests {
    /// The `config` patches the app PUT to /api/config, oldest first.
    func configPatches() -> [[String: Any]] {
        a.writes("PUT /api/config").compactMap { $0["config"] as? [String: Any] }
    }

    func fixtureConfig(_ path: String) -> Any? {
        var current: Any? = a.state()["config"]
        for part in path.split(separator: ".") { current = (current as? [String: Any])?[String(part)] }
        return current
    }

    @MainActor func openSection(_ app: XCUIApplication, _ id: String) {
        openSettings(app)
        let row = app.buttons["settings.config.\(id)"]
        scrollTo(row, app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the \(id) row")
        row.tap()
    }

    @MainActor func openPage(_ app: XCUIApplication, _ section: String, _ page: String) {
        openSection(app, section)
        let row = app.buttons["config-page.\(section).\(page)"]
        XCTAssertTrue(appears(row, app, "page-\(page)"), "the \(page) page row")
        row.tap()
    }

    @MainActor func back(_ app: XCUIApplication) {
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
    }

    /// Scrolls until the element is on screen and clear of the bottom search bar.
    /// [model-scope] Checks a footer under a group that large text can push below the fold: swipes up to it when it
    /// isn't there yet, runs `check`, then swipes back so the rows above are where the test left them.
    @MainActor func belowFold(_ element: XCUIElement, _ app: XCUIApplication, _ name: String, _ check: () -> Void) {
        var swipes = 0
        while !element.waitForExistence(timeout: swipes == 0 ? 5 : 2) && swipes < 4 { app.swipeUp(velocity: .slow); swipes += 1 }
        XCTAssertTrue(appears(element, app, name, timeout: 1), "\(name) is on the page")
        check()
        for _ in 0..<swipes { app.swipeDown(velocity: .slow) }
    }

    @MainActor func scrollTo(_ element: XCUIElement, _ app: XCUIApplication, max: Int = 8) {
        let limit = app.windows.firstMatch.frame.height - 150
        for _ in 0..<max where !(element.exists && element.isHittable && element.frame.maxY < limit) {
            app.swipeUp(velocity: .slow)
        }
    }

    // MARK: - G1 a schema page: picker, switch, Reset to Default

    @MainActor func testG1_ApprovalsPickerSwitchAndResetSaveSparsePatches() throws {
        let app = launchSignedIn()
        openPage(app, "safety", "approvals")
        let mode = app.buttons["config-field.approvals.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10), "the schema's fields draw")
        XCTAssertTrue(mode.label.contains("Smart"), "the gateway's value: \(mode.label)")
        XCTAssertTrue(app.buttons["config-field.command_allowlist"].exists, "a list field")
        XCTAssertTrue(app.staticTexts["How Hermes handles commands that need your approval."].exists, "its description")
        shot(app, "config-approvals")

        mode.tap()
        let off = app.buttons["config-option.off"]
        XCTAssertTrue(off.waitForExistence(timeout: 5))
        shot(app, "config-picker")
        off.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.configPatches().count == 1 }, "one save")
        XCTAssertTrue(same(configPatches()[0] as NSDictionary, ["approvals": ["mode": "off"]] as NSDictionary), "sparse: \(configPatches())")

        // Reset to Default writes Hermes' default (manual).
        let reset = app.buttons["config-editor.reset"]
        XCTAssertTrue(reset.waitForExistence(timeout: 3))
        reset.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.configPatches().count == 2 })
        XCTAssertTrue(same(configPatches()[1] as NSDictionary, ["approvals": ["mode": "manual"]] as NSDictionary), "\(configPatches())")
        back(app)
        XCTAssertTrue(waitUntil(timeout: 5) { app.buttons["config-field.approvals.mode"].label.contains("Manual") }, "the row shows it")

        let confirm = app.switches["config-field.approvals.mcp_reload_confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertEqual(confirm.value as? String, "1")
        flip(confirm)
        XCTAssertTrue(waitUntil(timeout: 8) { self.configPatches().count == 3 })
        XCTAssertTrue(same(configPatches()[2] as NSDictionary, ["approvals": ["mcp_reload_confirm": false]] as NSDictionary), "\(configPatches())")
        XCTAssertTrue(same(fixtureConfig("approvals.mcp_reload_confirm"), false))
    }

    // MARK: - G2 a refused save: banner, the saved value back, Try Again

    @MainActor func testG2_RefusedSaveShowsBannerAndTryAgainResends() throws {
        try a.control("/__settings/fail", ["method": "PUT /api/config", "mode": "error", "count": 1])
        let app = launchSignedIn()
        openPage(app, "safety", "privacy")
        let redact = app.switches["config-field.security.redact_secrets"]
        XCTAssertTrue(redact.waitForExistence(timeout: 10))
        flip(redact)
        let banner = app.descendants(matching: .any)["settings.save-failure"]
        XCTAssertTrue(banner.waitForExistence(timeout: 8), "the failure shows on the page")
        XCTAssertTrue(app.staticTexts["disk full"].exists, "with the gateway's reason")
        XCTAssertTrue(waitUntil(timeout: 3) { redact.value as? String == "1" }, "the switch shows the saved value again")
        shot(app, "config-save-failure")
        app.buttons["settings.save-failure.retry"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.same(self.fixtureConfig("security.redact_secrets"), false) }, "Try Again saves it")
        XCTAssertFalse(banner.exists)
        XCTAssertEqual(redact.value as? String, "0")
    }

    // MARK: - G3 number and inferred fields

    @MainActor func testG3_NumberFieldAndAFieldTheSchemaLeftOut() throws {
        let app = launchSignedIn()
        openPage(app, "advanced", "runtime")
        let turns = app.buttons["config-field.agent.max_turns"]
        XCTAssertTrue(turns.waitForExistence(timeout: 10))
        XCTAssertTrue(turns.label.contains("120"))
        turns.tap()
        let field = app.textFields["config-editor.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.clearAndType("150")
        shot(app, "config-number")
        back(app)
        XCTAssertTrue(waitUntil(timeout: 8) { self.same(self.fixtureConfig("agent.max_turns"), 150) }, "\(configPatches())")
        XCTAssertTrue(same(configPatches().last as NSDictionary?, ["agent": ["max_turns": 150]] as NSDictionary))
        back(app)
        // Output Limits: checkpoints.max_snapshots isn't in the schema; the record's number draws a number row.
        app.buttons["config-page.advanced.output"].tap()
        XCTAssertTrue(app.buttons["config-field.checkpoints.max_snapshots"].waitForExistence(timeout: 8), "inferred from the record")
        shot(app, "config-output-limits")
    }

    // MARK: - G4 Main Model: an expensive model asks first; Fast Mode

    @MainActor func testG4_MainModelConfirmsAnExpensiveModelAndFastModeSaves() throws {
        let app = launchSignedIn()
        openPage(app, "model", "main")
        let row = app.buttons["main-model.model"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 8) { row.label.contains("Anthropic") }, "the main model: \(row.label)")
        shot(app, "model-main")
        row.tap()
        let ultra = app.buttons["model-option.claude-opus-ultra"]
        XCTAssertTrue(ultra.waitForExistence(timeout: 8), "Anthropic's models")
        // [model-scope] Owner 2026-11-03: the chooser says whose model it changes.
        let note = app.staticTexts["model-chooser.note"]
        XCTAssertTrue(note.exists && note.label.hasPrefix("Applies to Hermes only."), note.label)
        shot(app, "model-chooser")
        ultra.tap()
        let use = app.alerts.buttons["Use It"]
        XCTAssertTrue(use.waitForExistence(timeout: 8), "the gateway asked first")
        shot(app, "model-confirm")
        use.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { (self.a.state()["model"] as? [String: Any])?["model"] as? String == "claude-opus-ultra" })
        let sets = a.writes("POST /api/model/set")
        XCTAssertEqual(sets.count, 2, "asked, then confirmed")
        XCTAssertTrue(same(sets.last?["confirm_expensive_model"], true) && same(sets.last?["scope"], "main"))

        let fast = app.switches["main-model.fast"]
        XCTAssertTrue(fast.waitForExistence(timeout: 5))
        flip(fast)
        XCTAssertTrue(waitUntil(timeout: 8) { self.same(self.fixtureConfig("agent.service_tier"), "fast") }, "\(configPatches())")
        // [model-scope] Reasoning Effort and Fast Mode are the default bot's too.
        let defaults = app.staticTexts["main-model.defaults-footer"]
        XCTAssertTrue(defaults.exists && defaults.label.hasSuffix("Applies to Hermes only. A chat can still change its own."), defaults.label)
        shot(app, "model-main-defaults-scope")
    }

    // MARK: - G5 Auxiliary, Fallbacks and Mixture of Agents

    @MainActor func testG5_AuxiliaryFallbacksAndMixtureOfAgents() throws {
        let app = launchSignedIn()
        openPage(app, "model", "auxiliary")
        let titles = app.buttons["aux-task.title_generation"]
        XCTAssertTrue(titles.waitForExistence(timeout: 10))
        XCTAssertTrue(titles.label.contains("OpenRouter"), "pinned to OpenRouter: \(titles.label)")
        // [model-scope] Settings' own helper models are the default bot's.
        XCTAssertTrue(app.staticTexts["aux.footer"].label.contains("Applies to Hermes only."), app.staticTexts["aux.footer"].label)
        shot(app, "model-auxiliary")
        titles.tap()
        let useMain = app.buttons["aux.use-main"]
        XCTAssertTrue(useMain.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["model-chooser.note"].label.hasPrefix("Applies to Hermes only."), "the job's chooser says whose")
        XCTAssertTrue(waitUntil(timeout: 5) { useMain.isEnabled })
        useMain.tap()
        XCTAssertTrue(waitUntil(timeout: 8) {
            ((self.a.state()["aux"] as? [String: Any])?["title_generation"] as? [String: Any])?["provider"] as? String == "auto"
        }, "back on the main model")
        let set = a.writes("POST /api/model/set").last
        XCTAssertTrue(same(set?["scope"], "auxiliary") && same(set?["task"], "title_generation"))
        XCTAssertTrue(waitUntil(timeout: 5) { app.buttons["aux-task.title_generation"].label.contains("Main Model") })
        back(app)

        app.buttons["config-page.model.fallbacks"].tap()
        let first = app.descendants(matching: .any)["fallback-row-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 8), "the gateway's fallback list")
        XCTAssertTrue(app.staticTexts["fallbacks.footer"].label.contains("Applies to Hermes only."), app.staticTexts["fallbacks.footer"].label)   // [model-scope]
        shot(app, "model-fallbacks")
        back(app)

        app.buttons["config-page.model.moa"].tap()
        let enabled = app.switches["moa.enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["moa.footer"].label.hasSuffix("Applies to Hermes only."), app.staticTexts["moa.footer"].label)   // [model-scope]
        shot(app, "model-moa")
        flip(enabled)
        XCTAssertTrue(waitUntil(timeout: 8) {
            ((((self.a.state()["moa"] as? [String: Any])?["presets"] as? [String: Any])?["balanced"] as? [String: Any])?["enabled"] as? Bool) == true
        }, "PUT /api/model/moa with the preset on")
        XCTAssertTrue(same((a.state()["moa"] as? [String: Any])?["enabled"], true), "mirrored onto the default preset's top level")
    }

    // MARK: - G6 Keys: Show, a switch; Providers

    @MainActor func testG6_KeysShowARedactedKeyAndWriteASwitch() throws {
        let app = launchSignedIn()
        openSettings(app)
        let keys = app.buttons["settings.keys"]
        scrollTo(keys, app)
        keys.tap()
        let firecrawl = app.buttons["env-key.FIRECRAWL_API_KEY"]
        XCTAssertTrue(firecrawl.waitForExistence(timeout: 10))
        XCTAssertTrue(firecrawl.label.contains("fc-f...0000"), "the redacted preview: \(firecrawl.label)")
        XCTAssertFalse(app.descendants(matching: .any)["env-key.PORCUPINE_ACCESS_KEY"].exists, "the wake word's key never shows")
        XCTAssertFalse(app.descendants(matching: .any)["env-key.TELEGRAM_BOT_TOKEN"].exists, "messaging credentials stay on their page")
        shot(app, "keys")
        firecrawl.tap()
        let show = app.buttons["env-editor.show"]
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        show.tap()
        XCTAssertTrue(app.staticTexts["env-editor.value"].waitForExistence(timeout: 8), "Show reads it from the gateway")
        // [main-e2e] The page also reads its set number and switch keys when it opens (stress test #84): Show is one more.
        XCTAssertEqual(a.writes("POST /api/env/reveal").filter { self.same($0["key"], "FIRECRAWL_API_KEY") }.count, 1)
        back(app)

        // A switch whose state is known (not set: its default, off): on writes "true".
        let server = app.switches["API Server Enabled"].exists ? app.switches["API Server Enabled"] : app.switches.matching(identifier: "env-switch.API_SERVER_ENABLED").firstMatch
        scrollTo(server, app)
        XCTAssertTrue(server.waitForExistence(timeout: 5))
        flip(server)
        XCTAssertTrue(waitUntil(timeout: 8) { self.a.writes("PUT /api/env").contains { self.same($0["key"], "API_SERVER_ENABLED") && self.same($0["value"], "true") } })
        // Telegram: Allow All Users isn't set and defers to config.yaml: Not Set with an On/Off menu.
        XCTAssertTrue(app.descendants(matching: .any)["env-switch.menu.TELEGRAM_ALLOW_ALL_USERS"].exists)
        shot(app, "keys-switches")
        back(app)

        let providers = app.buttons["settings.providers"]
        scrollTo(providers, app)
        providers.tap()
        // [provider-manager] One list of the providers you have: a signed-in account and a built-in with its key.
        XCTAssertTrue(app.buttons["provider.anthropic"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["provider.nous"].waitForExistence(timeout: 8))
        shot(app, "providers")
    }

    // MARK: - G7 Vault and Billing

    @MainActor func testG7_VaultAddAndBillingReadOnly() throws {
        let app = launchSignedIn()
        openSettings(app)
        let vault = app.buttons["settings.vault"]
        scrollTo(vault, app)
        vault.tap()
        XCTAssertTrue(app.descendants(matching: .any)["vault-item.Fixture Bank"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["vault-source.bitwarden"].exists, "password managers")
        shot(app, "vault")
        app.buttons["vault.add"].tap()
        let label = app.textFields["vault-add.label"]
        XCTAssertTrue(appears(label, app, "vault-add-form"))
        label.tap(); label.typeText("Fixture Shop")
        let origin = app.textFields["vault-add.origin"]
        origin.tap(); origin.typeText("shop.example.invalid")
        let identifier = app.textFields["vault-add.identifier"]
        identifier.tap(); identifier.typeText("ivy@example.invalid")
        let password = app.secureTextFields["vault-add.password"]
        password.tap(); password.typeText("fixture-pass-0000")
        app.buttons["vault-add.save"].tap()
        let added = waitUntil(timeout: 8) { self.a.writes("vault.add").count == 1 }
        if !added { dump(app, "vault-add") }
        XCTAssertTrue(added, "vault.add sent")
        let add = a.writes("vault.add")[0]
        XCTAssertTrue(same(add["kind"], "login") && same(add["label"], "Fixture Shop") && same(add["origin"], "https://shop.example.invalid"))
        XCTAssertTrue(same(add["secret"], ["identifier", "identifier_type", "password"]), "the secret's fields: \(String(describing: add["secret"]))")
        XCTAssertTrue(appears(app.descendants(matching: .any)["vault-item.Fixture Shop"], app, "vault-after-add", timeout: 8), "listed after saving")
        back(app)

        let billing = app.buttons["settings.billing"]
        scrollTo(billing, app)
        billing.tap()
        let balance = app.descendants(matching: .any)["billing.balance"]
        XCTAssertTrue(balance.waitForExistence(timeout: 10))
        XCTAssertTrue(balance.label.contains("$1,000.00"), "one currency format: \(balance.label)")
        shot(app, "billing")
        XCTAssertTrue(app.descendants(matching: .any)["billing.card"].label.contains("4242"))
    }

    // MARK: - G8 Search, Reset to Defaults, Export

    @MainActor func testG8_SearchLandsOnAFieldAndResetWritesDefaults() throws {
        let app = launchSignedIn()
        openSettings(app)
        let magnifier = app.navigationBars.buttons["settings.search"]
        XCTAssertTrue(magnifier.waitForExistence(timeout: 5), "the magnifier (the field folds away)")
        magnifier.tap()
        let search = app.searchFields["settings.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "the search field")
        search.typeText("approval timeout")
        let result = app.buttons["settings.result.field:approvals.timeout"]
        XCTAssertTrue(result.waitForExistence(timeout: 5), "one result")
        shot(app, "settings-search")
        result.tap()
        XCTAssertTrue(appears(app.textFields["config-editor.field"], app, "search-editor", timeout: 8), "the field's own editor")
        XCTAssertEqual(app.textFields["config-editor.field"].value as? String, "60")
        back(app)
        XCTAssertTrue(appears(app.buttons["config-field.approvals.timeout"], app, "search-landed-page"), "its page under it")
        back(app)
        XCTAssertTrue(appears(magnifier, app, "search-after-back"), "back on Settings")

        magnifier.tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("zzzz")
        XCTAssertTrue(app.staticTexts["settings.search-empty"].waitForExistence(timeout: 3) || app.descendants(matching: .any)["settings.search-empty"].exists)
        shot(app, "settings-search-empty")
        // The ✕ beside the field ends the search.
        let frame = search.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.maxX + 34, dy: frame.midY)).tap()
        XCTAssertTrue(appears(app.buttons["settings.gateway-card"], app, "search-ended"), "the list is back")

        let reset = app.buttons["settings.reset"]
        scrollTo(reset, app, max: 14)
        XCTAssertTrue(appears(reset, app, "reset-row"))
        shot(app, "settings-file-actions")
        reset.tap()
        confirmAlert(app, "Reset to Defaults")
        XCTAssertTrue(waitUntil(timeout: 10) { self.same(self.fixtureConfig("approvals.mode"), "manual") }, "defaults written")
        XCTAssertTrue(same(fixtureConfig("agent.max_turns"), 90))
        XCTAssertTrue(app.descendants(matching: .any)["settings.file-status"].waitForExistence(timeout: 5))

        let export = app.buttons["settings.export"]
        export.tap()
        let sheet = app.otherElements["ActivityListView"].exists ? app.otherElements["ActivityListView"] : app.navigationBars["UIActivityContentView"]
        XCTAssertTrue(waitUntil(timeout: 8) { sheet.exists || app.buttons["Save to Files"].exists || app.cells["Save to Files"].exists },
                      "the share sheet offers the file")
        shot(app, "settings-export")
    }

    // MARK: - G9 Reopen Last Chat, Sessions, Diagnostics, performance logs

    @MainActor func testG9_ResumeSessionsDiagnosticsAndJankyMark() throws {
        let app = launchSignedIn()
        openSettings(app)
        let resume = app.switches["settings.resume-last-chat"]
        scrollTo(resume, app)
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 5) { resume.value as? String == "1" }, "on by default")
        flip(resume)
        XCTAssertTrue(waitUntil(timeout: 8) { self.same(self.fixtureConfig("display.resume_last_session"), false) }, "\(configPatches())")
        XCTAssertTrue(app.switches["settings.tips"].exists, "In-App Tips")
        shot(app, "settings-chat")

        let sessions = app.buttons["settings.sessions"]
        scrollTo(sessions, app)
        sessions.tap()
        let archive = app.switches["sessions.auto-archive"]
        XCTAssertTrue(appears(archive, app, "sessions", timeout: 8))
        flip(archive)
        let archived = waitUntil(timeout: 8) { self.same(self.fixtureConfig("sessions.auto_archive"), true) }
        if !archived { dump(app, "sessions-write") }
        XCTAssertTrue(archived, "auto_archive saved: \(configPatches())")
        XCTAssertTrue(app.textFields["sessions.auto-archive-days"].waitForExistence(timeout: 3))
        shot(app, "settings-sessions")
        back(app)

        let about = app.buttons["settings.about"]
        scrollTo(about, app, max: 12)
        about.tap()
        let perf = app.switches["about.perf-log"]
        XCTAssertTrue(appears(perf, app, "about", timeout: 5))
        if perf.value as? String == "0" { flip(perf) }
        let mark = app.buttons["about.mark"]
        XCTAssertTrue(mark.waitForExistence(timeout: 3))
        shot(app, "about-diagnostics")
        mark.tap()
        XCTAssertTrue(waitUntil(timeout: 15) {
            ((self.a.state()["logs"] as? [[String: Any]]) ?? []).contains { ($0["kinds"] as? [Any])?.contains { $0 as? String == "mark" } == true }
        }, "the marker reached the computer")
        app.buttons["about.diagnostics"].tap()
        // [diagnostics] The page is the web app's now (docs/spec/3x-diagnostics.md §2): its rows read in sentence case
        // and Copy Diagnostics sits under the intro (UITests/diagnostics covers the page itself).
        XCTAssertTrue(app.descendants(matching: .any)["diagnostics.intro"].waitForExistence(timeout: 5))
        let reconnects = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Reconnects since launch")).firstMatch
        for _ in 0..<6 where !reconnects.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(reconnects.exists, "Gateway › Reconnects since launch")
        shot(app, "diagnostics")
        back(app)
        // Off: nothing more is sent, and Mark goes away.
        flip(perf)
        XCTAssertTrue(waitUntil(timeout: 3) { !app.buttons["about.mark"].exists })
        flip(perf)
    }

    // MARK: - G10 a bot's own Default Model (tester batch 3: "Changing the model in Settings only changes it for default")

    @MainActor func testG10_BotInfoChangesThatBotsOwnDefaultModel() throws {
        let app = launchSignedIn()
        openBotInfo(app, "ivy")
        app.botInfoTab("Brain")   // [page-tabs]
        let row = app.buttons["bot-info.default-model"]
        XCTAssertTrue(appears(row, app, "bot-model-row", timeout: 8), "Brain › Default Model")
        XCTAssertTrue(waitUntil(timeout: 8) { row.label.contains("Sonnet") }, "Ivy's own model, not Hermes's: \(row.label)")
        // [model-scope] Owner 2026-11-03 (menu review #2): Brain says whose models these are.
        let brainScope = app.staticTexts["bot-info.model-scope"]
        belowFold(brainScope, app, "bot-info-model-scope") {
            XCTAssertEqual(brainScope.label, "Applies to Ivy only. A chat can still switch its own model.")
            shot(app, "bot-info-default-model")
        }
        // Ivy's catalog is read after the chooser opens: one that can't be read says why, with Try Again, rather than
        // leaving a blank page.
        try a.control("/__settings/fail", ["method": "GET /api/model/options", "mode": "error", "count": 1])
        row.tap()
        let retry = app.buttons["settings.load-retry"]
        XCTAssertTrue(appears(retry, app, "bot-model-chooser-failed", timeout: 8), "the chooser says it couldn't read the models")
        XCTAssertTrue(app.staticTexts["Couldn’t Load Models"].exists, "and says what failed")
        XCTAssertFalse(app.descendants(matching: .any)["model-chooser.provider"].exists, "no empty Provider picker under it")
        shot(app, "bot-model-chooser-failed")
        retry.tap()
        let ultra = app.buttons["model-option.claude-opus-ultra"]
        XCTAssertTrue(appears(ultra, app, "bot-model-chooser", timeout: 8), "Ivy's catalog, read again")
        XCTAssertFalse(retry.exists, "the failure card goes")
        XCTAssertEqual(app.staticTexts["model-chooser.note"].label, "Applies to Ivy only. A chat can still switch its own model.", "whose model it is")
        XCTAssertTrue(((a.state()["rest"] as? [[String: Any]]) ?? []).contains {
            ($0["path"] as? String).map { $0.hasPrefix("/api/model/options") && $0.contains("profile=ivy") } == true
        }, "the chooser read Ivy's options")
        shot(app, "bot-model-chooser")

        // An expensive model asks first, and the confirmed write is Ivy's alone.
        ultra.tap()
        let use = app.alerts.buttons["Use It"]
        XCTAssertTrue(appears(use, app, "bot-model-confirm", timeout: 8), "the gateway asked first")
        use.tap()
        let ivyModel = { ((self.a.state()["models"] as? [String: Any])?["ivy"] as? [String: Any])?["model"] as? String }
        XCTAssertTrue(waitUntil(timeout: 8) { ivyModel() == "claude-opus-ultra" }, "\(a.writes("POST /api/model/set"))")
        var sets = a.writes("POST /api/model/set")
        XCTAssertEqual(sets.count, 2, "asked, then confirmed")
        XCTAssertTrue(sets.allSatisfy { same($0["query_profile"], "ivy") && same($0["scope"], "main") }, "scoped to Ivy: \(sets)")
        XCTAssertTrue(same(sets.last?["confirm_expensive_model"], true))
        XCTAssertTrue(same((a.state()["model"] as? [String: Any])?["model"], "claude-opus-5.5"), "Hermes keeps its own")
        XCTAssertTrue(waitUntil(timeout: 8) { row.label.contains("Ultra") }, "the row names the new model: \(row.label)")

        // A plain pick saves at once.
        row.tap()
        let haiku = app.buttons["model-option.claude-haiku-5"]
        XCTAssertTrue(haiku.waitForExistence(timeout: 8))
        haiku.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { ivyModel() == "claude-haiku-5" }, "\(a.writes("POST /api/model/set"))")
        sets = a.writes("POST /api/model/set")
        XCTAssertEqual(sets.count, 3)
        XCTAssertTrue(same(sets.last?["query_profile"], "ivy"))
        XCTAssertTrue(waitUntil(timeout: 8) { row.label.contains("Haiku") }, "\(row.label)")
        shot(app, "bot-info-default-model-saved")
        app.buttons["bot-info.close"].tap()

        // Settings › Model says whose models it changes, and where every other bot's is.
        openSection(app, "model")
        let sectionFooter = app.staticTexts["config-section.model.footer"]
        XCTAssertTrue(appears(sectionFooter, app, "model-section-footer", timeout: 8))
        XCTAssertTrue(sectionFooter.label.hasPrefix("Hermes’s models"), sectionFooter.label)
        XCTAssertTrue(sectionFooter.label.contains("change them in each bot’s Bot Info › Brain"), sectionFooter.label)
        app.buttons["config-page.model.main"].tap()
        let header = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Hermes’s Default Model")).firstMatch
        XCTAssertTrue(appears(header, app, "main-model-header", timeout: 8), "whose Main Model this is")
        XCTAssertEqual(app.staticTexts["main-model.footer"].label,
                       "Applies to Hermes only. Other bots keep their own in Bot Info › Brain. A chat can still switch its own model.")
        shot(app, "model-main-whose")
    }

    // MARK: - G11 a bot's own Fallback Models and Auxiliary Models (tester 2026-10-30: "I can't change some important
    // settings for individual profiles other than default … like auxiliary model selection and fallback models")

    @MainActor func testG11_BotInfoChangesThatBotsOwnFallbacksAndAuxiliaryModels() throws {
        let app = launchSignedIn()
        openBotInfo(app, "ivy")
        app.botInfoTab("Brain")   // [page-tabs]
        let fallbacks = app.buttons["bot-info.fallbacks"]
        XCTAssertTrue(appears(fallbacks, app, "bot-fallbacks-row", timeout: 8), "Brain › Fallback Models")
        XCTAssertTrue(app.buttons["bot-info.auxiliary"].exists, "Brain › Auxiliary Models")
        shot(app, "bot-info-brain-rows")

        // Fallback Models: Ivy's own list (empty), and an added one is Ivy's alone.
        fallbacks.tap()
        let add = app.buttons["fallback.add"]
        XCTAssertTrue(appears(add, app, "bot-fallbacks", timeout: 8), "Ivy's Fallback Models page")
        XCTAssertFalse(app.descendants(matching: .any)["fallback-row-0"].exists, "Ivy has none (Hermes's list isn't shown)")
        let whose = app.staticTexts["fallbacks.footer"]
        XCTAssertTrue(whose.exists && whose.label.hasSuffix("Applies to Ivy only."), "the footer says whose they are: \(whose.label)")
        XCTAssertTrue(((a.state()["rest"] as? [[String: Any]]) ?? []).contains {
            ($0["path"] as? String).map { $0.hasPrefix("/api/config") && $0.contains("profile=ivy") } == true
        }, "the page read Ivy's config")
        shot(app, "bot-fallbacks-empty")
        add.tap()
        let provider = app.descendants(matching: .any)["model-chooser.provider"]
        XCTAssertTrue(appears(provider, app, "bot-fallback-chooser", timeout: 8))
        XCTAssertEqual(app.staticTexts["model-chooser.note"].label, "Applies to Ivy only.", "the chooser says whose")   // [model-scope]
        provider.tap()
        let anthropic = app.buttons["Anthropic"]
        XCTAssertTrue(anthropic.waitForExistence(timeout: 5), "the providers")
        anthropic.tap()
        let haiku = app.buttons["model-option.claude-haiku-5"]
        XCTAssertTrue(appears(haiku, app, "bot-fallback-models", timeout: 5))
        haiku.tap()
        let ivyFallbacks = { ((self.a.state()["configs"] as? [String: Any])?["ivy"] as? [String: Any])?["fallback_providers"] as? [[String: Any]] }
        XCTAssertTrue(waitUntil(timeout: 8) { ivyFallbacks()?.first.map { self.same($0["model"], "claude-haiku-5") } == true },
                      "saved in Ivy's config: \(a.writes("PUT /api/config"))")
        XCTAssertTrue(a.writes("PUT /api/config").allSatisfy { same($0["profile"], "ivy") }, "every write was Ivy's")
        let hermesList = (fixtureConfig("fallback_providers") as? [[String: Any]]) ?? []
        XCTAssertTrue(hermesList.count == 1 && same(hermesList.first?["model"], "deepseek/deepseek-v3.2"),
                      "Hermes's own list (its one DeepSeek) is untouched: \(hermesList)")
        XCTAssertTrue(appears(app.descendants(matching: .any)["fallback-row-0"], app, "bot-fallback-added", timeout: 5), "the row shows")
        shot(app, "bot-fallbacks-added")
        back(app)

        // Auxiliary Models: Ivy's own assignments; a pick is Ivy's alone.
        app.buttons["bot-info.auxiliary"].tap()
        let vision = app.buttons["aux-task.vision"]
        XCTAssertTrue(appears(vision, app, "bot-auxiliary", timeout: 8), "Ivy's Auxiliary Models page")
        let ivyAux = app.staticTexts["aux.footer"]   // [model-scope]
        belowFold(ivyAux, app, "bot-aux-footer") {
            XCTAssertTrue(ivyAux.label.hasSuffix("Applies to Ivy only."), "whose: \(ivyAux.label)")
        }
        XCTAssertTrue(((a.state()["rest"] as? [[String: Any]]) ?? []).contains {
            ($0["path"] as? String).map { $0.hasPrefix("/api/model/auxiliary") && $0.contains("profile=ivy") } == true
        }, "the page read Ivy's assignments")
        shot(app, "bot-auxiliary")
        vision.tap()
        let auxProvider = app.descendants(matching: .any)["model-chooser.provider"]
        XCTAssertTrue(appears(auxProvider, app, "bot-aux-chooser", timeout: 8))
        XCTAssertEqual(app.staticTexts["model-chooser.note"].label, "Applies to Ivy only.", "the job's chooser says whose")   // [model-scope]
        auxProvider.tap()
        XCTAssertTrue(app.buttons["Anthropic"].waitForExistence(timeout: 5))
        app.buttons["Anthropic"].tap()
        let opus = app.buttons["model-option.claude-opus-5.5"]
        XCTAssertTrue(appears(opus, app, "bot-aux-models", timeout: 5))
        opus.tap()
        let ivyVision = { (((self.a.state()["auxes"] as? [String: Any])?["ivy"] as? [String: Any])?["vision"] as? [String: Any])?["model"] as? String }
        XCTAssertTrue(waitUntil(timeout: 8) { ivyVision() == "claude-opus-5.5" }, "\(a.writes("POST /api/model/set"))")
        let set = a.writes("POST /api/model/set").last
        XCTAssertTrue(same(set?["query_profile"], "ivy") && same(set?["scope"], "auxiliary") && same(set?["task"], "vision"), "\(String(describing: set))")
        XCTAssertTrue(same(((a.state()["aux"] as? [String: Any])?["vision"] as? [String: Any])?["provider"], "auto"), "Hermes's own is untouched")
        XCTAssertTrue(waitUntil(timeout: 8) { app.buttons["aux-task.vision"].label.contains("Opus") }, "the row names it")
        shot(app, "bot-auxiliary-saved")
        back(app)
        app.buttons["bot-info.close"].tap()

        // The default bot's rows open Settings' own lists, which say they are Hermes's ([model-scope]).
        openBotInfo(app, "default")
        app.botInfoTab("Brain")   // [page-tabs]
        let hermesFallbacks = app.buttons["bot-info.fallbacks"]
        XCTAssertTrue(appears(hermesFallbacks, app, "default-fallbacks-row", timeout: 8))
        // [model-scope] The default bot's Default Model is Settings › Model's: Brain says so.
        let hermesScope = app.staticTexts["bot-info.model-scope"]
        belowFold(hermesScope, app, "default-model-scope") {
            XCTAssertEqual(hermesScope.label, "Applies to Hermes only, the same as Settings › Model. A chat can still switch its own model.")
            shot(app, "default-bot-info-brain")
        }
        hermesFallbacks.tap()
        XCTAssertTrue(appears(app.buttons["fallback.add"], app, "default-fallbacks", timeout: 8))
        let hermesWhose = app.staticTexts["fallbacks.footer"]   // [model-scope]
        belowFold(hermesWhose, app, "default-fallbacks-footer") {
            XCTAssertTrue(hermesWhose.label.hasSuffix("Applies to Hermes only. Other bots keep their own in Bot Info › Brain."),
                          "Settings' list, the default bot's: \(hermesWhose.label)")
        }
        let hermesRow = app.descendants(matching: .any)["fallback-row-0"]
        XCTAssertTrue(appears(hermesRow, app, "default-fallback-row", timeout: 5), "Hermes's own DeepSeek")
        XCTAssertTrue(hermesRow.label.contains("DeepSeek") || hermesRow.label.contains("deepseek"), hermesRow.label)
        XCTAssertFalse(app.descendants(matching: .any)["fallback-row-1"].exists, "Ivy's fallback didn't land on Hermes")
        shot(app, "default-fallbacks")
        back(app)
        app.buttons["bot-info.close"].tap()

        // More › Bot Profiles › Ivy has the same two rows, on Ivy's own lists.
        // Desktop Look docks its own tab bar, with the tabs' ids; the standard look has the system one.
        let moreTab = app.tabBars.buttons["More"].exists ? app.tabBars.buttons["More"] : app.buttons["tab-more"]
        XCTAssertTrue(appears(moreTab, app, "more-tab", timeout: 5))
        moreTab.tap()
        let profiles = app.cells["more-row-profiles"]
        for _ in 0..<10 where !profiles.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(appears(profiles, app, "more-profiles", timeout: 8), "More › Bot Profiles")
        profiles.tap()
        let ivyRow = app.buttons["profiles.row.ivy"]
        XCTAssertTrue(appears(ivyRow, app, "profiles-list", timeout: 10))
        ivyRow.tap()
        let profileFallbacks = app.buttons["profiles.detail.fallbacks"]
        XCTAssertTrue(appears(profileFallbacks, app, "profile-fallbacks-row", timeout: 10), "Bot Profiles › Ivy › Fallback Models")
        XCTAssertTrue(app.buttons["profiles.detail.auxiliary"].exists, "and Auxiliary Models")
        let profileScope = app.staticTexts["profiles.detail.model-scope"]   // [model-scope]
        belowFold(profileScope, app, "profile-model-scope") {
            XCTAssertEqual(profileScope.label, "Applies to Ivy only. A chat can still switch its own model.")
            shot(app, "profile-detail-rows")
        }
        profileFallbacks.tap()
        let ivyRow0 = app.descendants(matching: .any)["fallback-row-0"]
        XCTAssertTrue(appears(ivyRow0, app, "profile-fallbacks", timeout: 8))
        XCTAssertTrue(ivyRow0.label.contains("Haiku"), "Ivy's own list: \(ivyRow0.label)")
        back(app)
        app.buttons["profiles.detail.auxiliary"].tap()
        let ivyVisionRow = app.buttons["aux-task.vision"]
        XCTAssertTrue(appears(ivyVisionRow, app, "profile-auxiliary", timeout: 8))
        XCTAssertTrue(waitUntil(timeout: 8) { ivyVisionRow.label.contains("Opus") }, "Ivy's own: \(ivyVisionRow.label)")
        shot(app, "profile-auxiliary")
    }

    func same(_ a: Any?, _ b: Any?) -> Bool { HermesHQNativeUITests.same(a, b) }
}
