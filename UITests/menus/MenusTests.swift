// End-to-end checks of the menus stream (docs/spec/1x-menus.md §14.2–14.3) against the menus fixture
// (scripts/fixtures/menus-gateway.py). Run with scripts/e2e-menus.sh: it starts the fixture (and an old-gateway
// instance), passes the credentials files as TEST_RUNNER_HQN_UI_CREDENTIALS / TEST_RUNNER_HQN_UI_OLD_CREDENTIALS and the
// screenshot folder as TEST_RUNNER_HQN_UI_SHOTS. Without the credentials every test skips.
//
// Every test resets the fixture and starts from a clean phone (one sign-in each), so each stands alone.

import XCTest

final class MenusTests: XCTestCase {
    static let botRow = "bot-row-default"
    static let trip = "20261005_090000_menus001"
    /// Methods whose params the wire checks look at (spec 1x §14.2).
    static let menusMethods: Set<String> = ["model.options", "config.set", "config.get", "commands.catalog", "slash.exec",
                                            "command.dispatch", "session.status", "session.save", "process.stop", "session.title"]

    /// The app under test, for the failure snapshot.
    nonisolated(unsafe) private var current: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// A failure leaves a screenshot and the accessibility tree in the shots folder ("fail-<test>").
    override func record(_ issue: XCTIssue) {
        nonisolated(unsafe) let test = self
        let label = "fail-" + (name.components(separatedBy: " ").last?.trimmingCharacters(in: CharacterSet(charactersIn: "]")) ?? "test")
        // Integration: never re-enter. A snapshot that can't find the app records an issue of its own, which came back
        // here and snapshotted again — a loop that held the runner for the whole 7-minute allowance ("Stall on main thread").
        // Warnings (XCTest's own notes, e.g. a slow main thread) don't fail the test: no failure snapshot for them, and
        // never during tear down, when the app element can have an empty frame. They are listed in warnings.txt.
        if !issue.isFailure {
            if let dir = ProcessInfo.processInfo.environment["HQN_UI_SHOTS"] {
                let line = "\(label): \(issue.compactDescription)\n"
                let url = URL(fileURLWithPath: dir).appending(path: "warnings.txt")
                if let handle = try? FileHandle(forWritingTo: url) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
                else { try? Data(line.utf8).write(to: url) }
            }
            super.record(issue)
            return
        }
        if Thread.isMainThread, !snapshotting {
            snapshotting = true
            MainActor.assumeIsolated { test.snapshotFailure(label) }
            snapshotting = false
        }
        super.record(issue)
    }

    nonisolated(unsafe) private var snapshotting = false

    @MainActor private func snapshotFailure(_ label: String) {
        guard let app = current else { return }
        shot(app, label)
        dump(app, label)
    }

    // MARK: 14–15 · The ⋯ menu and its warm-up

    @MainActor func test01_MoreMenuAndWarmUp() throws {
        let (account, app) = try start()
        openBotChat(app)
        XCTAssertEqual(calls(account, "model.options").count, 0, "no catalog read before the first ⋯ open")
        openMore(app)
        XCTAssertTrue(app.buttons["chat.more.share"].exists, "Share tile")
        XCTAssertTrue(app.buttons["chat.more.info"].exists, "Info tile")
        let model = app.buttons["chat.more.model"]
        XCTAssertTrue(model.waitForExistence(timeout: 3))
        XCTAssertEqual(model.label, "Model, Sonnet 5 · Medium")
        XCTAssertFalse(app.buttons["chat.more.rename"].exists, "a bot's own chat has no Rename")
        shot(app, "more-menu")
        // One background catalog read after the first open; none on the next open within 30 s.
        XCTAssertTrue(waitUntil(timeout: 5) { self.calls(account, "model.options").count == 1 }, "one warm-up read")
        Thread.sleep(forTimeInterval: 0.5)
        // ⋯ › Model opens the model panel, the one place for the model, its thinking and Fast (owner 2026-11-01).
        model.tap()
        XCTAssertTrue(app.descendants(matching: .any)["model.panel"].waitForExistence(timeout: 5), "the model panel opens")
        XCTAssertTrue(thinkingValue(app).hasPrefix("Medium"), "thinking at Medium (\(thinkingValue(app)))")
        XCTAssertTrue(app.switches["model.panel.fast"].exists, "Fast (Sonnet has its own tier)")
        XCTAssertTrue(app.buttons["model.panel.approvals"].exists && app.switches["model.panel.skip"].exists)
        shot(app, "model-panel")
        openSwitchMenu(app)
        XCTAssertTrue(menuItem(app, "Anthropic").waitForExistence(timeout: 5), "the catalog by provider")
        shot(app, "model-switch-menu")
        closeSwitchMenu(app)
        closePanel(app)
        openMore(app)
        dismissMenu(app)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(calls(account, "model.options").count, 1, "no second warm-up within 30 s")
        // The Trip planning chat (not a bot's own) offers Rename.
        goBack(app)
        openTrip(app)
        openMore(app)
        XCTAssertTrue(app.buttons["chat.more.rename"].waitForExistence(timeout: 3), "Rename… in a session chat")
        shot(app, "more-menu-session")
        dismissMenu(app)
        try assertWireClean(account)
    }

    // MARK: 16 · More Models… and favourites

    @MainActor func test02_ModelSheetFavourites() throws {
        let (account, app) = try start()
        openBotChat(app)
        openModelSheet(app)
        XCTAssertTrue(app.cells["models.row.anthropic::claude-sonnet-5"].waitForExistence(timeout: 10), "rows load")
        XCTAssertTrue(app.cells["models.row.anthropic::claude-sonnet-5"].descendants(matching: .any)
            .matching(NSPredicate(format: "value == 'Current'")).firstMatch.exists, "the current model is checked")
        let headers = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Anthropic", "ChatGPT or Codex Subscription", "OpenRouter", "Favorites"]))
        XCTAssertEqual(headers.firstMatch.label, "Anthropic", "Anthropic leads with no favourites")
        XCTAssertFalse(labelled(app, "Favorites").exists)
        // [model-scope] Owner 2026-11-03: a pick is this chat's; the bot's own default is in its Bot Info.
        let scope = app.staticTexts["models.scope"]
        XCTAssertTrue(scope.exists && scope.label.hasPrefix("Applies to this chat only."), scope.label)
        shot(app, "models-sheet")
        let gptRow = app.cells.matching(identifier: "models.row.openai-codex::gpt-5.5")
        let before = gptRow.element(boundBy: 0).frame.minY
        app.buttons.matching(identifier: "models.star.openai-codex::gpt-5.5").element(boundBy: 0).tap()
        XCTAssertTrue(labelled(app, "Favorites").waitForExistence(timeout: 3), "a Favorites section appears")
        XCTAssertEqual(gptRow.count, 2, "the starred row stays in its provider's section too")
        XCTAssertEqual(gptRow.element(boundBy: 1).frame.minY, before, accuracy: 1, "the starred row didn't move under the finger")
        shot(app, "models-sheet-favorites")
        app.buttons["sheet.cancel"].tap()
        openModelPanel(app)
        openSwitchMenu(app)
        XCTAssertEqual(firstPick(app), "model.panel.pick.openai-codex::gpt-5.5", "the favourite leads Switch Model")
        // [model-scope] The menu's title says what a pick changes; at the AX sizes it has none (it filled the menu).
        let switchScope = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Applies to this chat only.")).firstMatch
        if ProcessInfo.processInfo.environment["HQN_UI_AX3"] == "1" {
            XCTAssertFalse(switchScope.exists, "no title over the picks at AX3")
        } else {
            XCTAssertTrue(switchScope.exists, "Switch Model says it applies to this chat")
        }
        shot(app, "model-switch-favorite")
        closeSwitchMenu(app)
        closePanel(app)
        // Leave the phone as it was: unstar.
        openModelSheet(app)
        XCTAssertTrue(labelled(app, "Favorites").waitForExistence(timeout: 5))
        app.buttons.matching(identifier: "models.star.openai-codex::gpt-5.5").element(boundBy: 0).tap()
        XCTAssertTrue(waitUntil(timeout: 3) { !labelled(app, "Favorites").exists })
        app.buttons["sheet.cancel"].tap()
        try assertWireClean(account)
    }

    /// [model-fold] Tester 2026-11-09: a provider's heading folds its models away; the fold is kept the next
    /// time the sheet opens, a search still finds a folded provider's models, and the hold menu opens them all.
    @MainActor func test02c_ModelSheetFoldsProviders() throws {
        let (account, app) = try start()
        openBotChat(app)
        openModelSheet(app)
        let sonnet = app.cells["models.row.anthropic::claude-sonnet-5"]
        XCTAssertTrue(sonnet.waitForExistence(timeout: 10), "rows load")
        let anthropic = app.buttons["models.provider.anthropic"]
        XCTAssertTrue(anthropic.exists, "Anthropic's heading")
        XCTAssertEqual(anthropic.value as? String, "Expanded")
        anthropic.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { !sonnet.exists }, "folded: its models are gone")
        XCTAssertTrue((anthropic.value as? String ?? "").hasPrefix("Collapsed, "), "\(anthropic.value ?? "")")
        XCTAssertTrue(app.cells["models.row.openai-codex::gpt-5.5"].exists, "the other providers stay open")
        shot(app, "models-sheet-folded")
        app.buttons["sheet.cancel"].tap()
        openModelSheet(app)
        XCTAssertTrue(app.cells["models.row.openai-codex::gpt-5.5"].waitForExistence(timeout: 10))
        XCTAssertFalse(sonnet.exists, "the fold is kept")
        // A search shows every match, folded or not.
        let field = app.searchFields.firstMatch
        field.tap()
        field.typeText("sonnet")
        XCTAssertTrue(sonnet.waitForExistence(timeout: 3), "a search finds a folded provider's model")
        field.buttons["Clear text"].tap()
        XCTAssertTrue(waitUntil(timeout: 3) { !sonnet.exists }, "folded again once the search is cleared")
        // Hold a heading: Collapse All, then Expand All.
        app.buttons["models.provider.openai-codex"].press(forDuration: 1)
        app.buttons["Collapse All"].tap()
        XCTAssertTrue(waitUntil(timeout: 3) { !app.cells["models.row.openai-codex::gpt-5.5"].exists }, "every provider folds")
        shot(app, "models-sheet-all-folded")
        anthropic.press(forDuration: 1)
        app.buttons["Expand All"].tap()
        XCTAssertTrue(sonnet.waitForExistence(timeout: 3), "every provider opens")
        app.buttons["sheet.cancel"].tap()
        try assertWireClean(account)
    }

    /// [menu-stars] Tester 2026-11-06: the chat's model is starred from Switch Model itself, with no trip to the sheet.
    /// With nothing starred Favorites is that one row; once starred the model leads Favorites and the row unstars it.
    /// Stars stay on the device: nothing goes to the gateway.
    @MainActor func test02b_SwitchModelStarsTheChatsModel() throws {
        let (account, app) = try start()
        openBotChat(app)
        openModelPanel(app)
        openSwitchMenu(app)
        let star = app.buttons["model.panel.star"]
        XCTAssertTrue(star.waitForExistence(timeout: 5), "Favorites' star row")
        XCTAssertTrue(star.label.hasPrefix("Add ") && star.label.contains("to Favorites"), star.label)
        let hint = "Or star any model in Search All Models"
        XCTAssertTrue(star.label.contains(hint) || labelled(app, hint).exists, "it says where the rest are starred")
        shot(app, "model-switch-star-empty")
        star.tap()
        openSwitchMenu(app)
        XCTAssertEqual(firstPick(app), "model.panel.pick.anthropic::claude-sonnet-5", "the chat's model leads Favorites")
        XCTAssertTrue(star.waitForExistence(timeout: 5))
        XCTAssertTrue(star.label.hasPrefix("Remove ") && star.label.contains("from Favorites"), star.label)
        shot(app, "model-switch-star-starred")
        // Leave the phone as it was: unstar.
        star.tap()
        openSwitchMenu(app)
        XCTAssertTrue(star.waitForExistence(timeout: 5))
        XCTAssertTrue(star.label.hasPrefix("Add "), star.label)
        closeSwitchMenu(app)
        closePanel(app)
        try assertWireClean(account)
    }

    // MARK: 17 · Switching from the quick list

    @MainActor func test03_SwitchModel() throws {
        let (account, app) = try start()
        // The profile's config.yaml says high: a model with no saved effort gets high, not Hermes' medium.
        try account.control("/__menus/mode", ["profileReasoning": "high"])
        openBotChat(app)
        openModelSheet(app)
        let gpt = app.cells["models.row.openai-codex::gpt-5.5"]
        XCTAssertTrue(gpt.waitForExistence(timeout: 10))
        gpt.tap()
        XCTAssertTrue(app.staticTexts["Model changed to GPT-5.5."].waitForExistence(timeout: 8), "the switch's notice")
        XCTAssertEqual(try modelState(account)["model"] as? String, "gpt-5.5")
        XCTAssertTrue(waitUntil(timeout: 5) { self.calls(account, "config.set").contains { ($0["key"] as? String) == "reasoning" } },
                      "the preset's reasoning follows the switch")
        XCTAssertEqual(calls(account, "config.set").last { ($0["key"] as? String) == "reasoning" }?["value"] as? String, "high",
                       "the profile's default, not medium")
        XCTAssertTrue(calls(account, "config.get").contains { $0["key"] as? String == "reasoning" && $0["session_id"] == nil },
                      "the default is read without a session")
        openMore(app)
        XCTAssertTrue(menuItem(app, "Model, GPT-5.5").exists, "the ⋯ shows the new model")
        app.buttons["chat.more.model"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["model.panel"].waitForExistence(timeout: 5))
        openSwitchMenu(app)
        XCTAssertTrue(app.buttons["model.panel.pick.anthropic::claude-sonnet-5"].firstMatch.exists, "the previous model is a recent")
        shot(app, "model-switch-recent")
        closeSwitchMenu(app)
        closePanel(app)
        // The stored "model changed" row folds into a notice on the next history read.
        goBack(app)
        openBotChat(app)
        XCTAssertTrue(message(app, containing: "Model changed to GPT-5.5").waitForExistence(timeout: 8), "the model-changed notice (the name, verify round 3)")
        // Switch back from Switch Model's recents.
        openModelPanel(app)
        openSwitchMenu(app)
        app.buttons["model.panel.pick.anthropic::claude-sonnet-5"].firstMatch.tap()
        // The notice shows above the open panel for 5 s, but the panel is modal (VoiceOver hears it read out instead), so
        // the panel closes first: waiting on the fixture before that could outlast the notice.
        closePanel(app)
        XCTAssertTrue(app.staticTexts["Model changed to Sonnet 5."].waitForExistence(timeout: 8))
        XCTAssertTrue(waitUntil(timeout: 8) { (try? self.modelState(account)["model"] as? String) == "claude-sonnet-5" })
        XCTAssertEqual(try modelState(account)["model"] as? String, "claude-sonnet-5")
        try assertWireClean(account)
    }

    // MARK: 18–19 · Confirm and failure

    @MainActor func test04_ConfirmAndFailure() throws {
        let (account, app) = try start()
        openBotChat(app)
        openModelSheet(app)
        let opus = app.cells["models.row.anthropic::claude-opus-4-5-20251101"]
        XCTAssertTrue(opus.waitForExistence(timeout: 10))
        opus.tap()
        let alert = app.alerts["Change Model?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 8), "the confirm")
        XCTAssertTrue(alert.staticTexts["Opus 4.5 costs about 5× more per token than Sonnet 5.\n\nSwitch anyway?"].exists, "the gateway's words")
        shot(app, "change-model-alert")
        alert.buttons["Cancel"].tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(calls(account, "config.set").filter { ($0["key"] as? String) == "model" }.count, 1, "Cancel sends nothing more")
        XCTAssertEqual(try modelState(account)["model"] as? String, "claude-sonnet-5")
        openModelSheet(app)
        XCTAssertTrue(opus.waitForExistence(timeout: 10))
        opus.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 8))
        alert.buttons["Change Model"].tap()
        XCTAssertTrue(app.staticTexts["Model changed to Opus 4.5."].waitForExistence(timeout: 8))
        XCTAssertEqual(try modelState(account)["model"] as? String, "claude-opus-4-5-20251101")
        let confirmed = calls(account, "config.set").filter { ($0["key"] as? String) == "model" }
        XCTAssertEqual(confirmed.last?["confirm_expensive_model"] as? Bool, true)
        // broken-model fails and leaves the model alone.
        openModelSheet(app)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("broken")
        let broken = app.cells["models.row.openrouter::broken-model"]
        XCTAssertTrue(broken.waitForExistence(timeout: 5))
        shot(app, "models-sheet-search")
        broken.tap()
        let failure = app.alerts["Couldn’t Change Model"]
        XCTAssertTrue(failure.waitForExistence(timeout: 8))
        XCTAssertTrue(failure.staticTexts["Model switch to broken-model failed (fixture provider refused); staying on claude-opus-4-5-20251101."].exists)
        shot(app, "change-model-failed")
        failure.buttons["OK"].tap()
        XCTAssertEqual(try modelState(account)["model"] as? String, "claude-opus-4-5-20251101")
        try assertWireClean(account)
    }

    // MARK: 20 · A switch while a reply runs is parked

    @MainActor func test05_DeferredSwitch() throws {
        let (account, app) = try start()
        try account.control("/__fixture/plan", ["plans": [["chunks": Array(repeating: "word ", count: 60), "chunkDelay": 0.5]]])
        openBotChat(app)
        send(app, "Tell me a long story")
        XCTAssertTrue(app.buttons["composer.stop"].waitForExistence(timeout: 8), "the reply runs")
        openModelSheet(app)
        let haiku = app.cells["models.row.anthropic::claude-haiku-4-5"]
        XCTAssertTrue(haiku.waitForExistence(timeout: 10))
        haiku.tap()
        XCTAssertTrue(app.staticTexts["Haiku 4.5 will be used for your next message."].waitForExistence(timeout: 8))
        shot(app, "deferred-notice")
        let state = try modelState(account)
        XCTAssertEqual(state["model"] as? String, "claude-sonnet-5", "the gateway parked it")
        XCTAssertEqual((state["pending"] as? [String: Any])?["model"] as? String, "claude-haiku-4-5")
        // Haiku can't reason: the panel's thinking bar says so.
        openMore(app)
        let model = menuItem(app, "Model, Haiku 4.5")
        XCTAssertTrue(model.waitForExistence(timeout: 3))
        model.tap()
        XCTAssertTrue(app.descendants(matching: .any)["model.panel"].waitForExistence(timeout: 5))
        XCTAssertEqual(thinkingValue(app), "This model answers without a thinking step", "no thinking for Haiku")
        closePanel(app)
        try account.control("/__fixture/finish", ["profile": "default"])
        try assertWireClean(account)
    }

    // MARK: 21 · Reasoning and Fast

    @MainActor func test06_ReasoningAndFast() throws {
        let (account, app) = try start()
        openBotChat(app)
        openModelPanel(app)
        // Off, Minimal, Low, Medium, High, Extra High, Max, Ultra: a tap on the bar at High's place.
        let bar = app.descendants(matching: .any)["model.panel.thinking"]
        bar.coordinate(withNormalizedOffset: CGVector(dx: 4.0 / 7.0, dy: 1)).withOffset(CGVector(dx: 0, dy: -17)).tap()
        XCTAssertTrue(waitUntil(timeout: 5) {
            self.calls(account, "config.set").contains { ($0["key"] as? String) == "reasoning" && ($0["value"] as? String) == "high" }
        }, "config.set reasoning high (\(thinkingValue(app)))")
        closePanel(app)
        openMore(app)
        XCTAssertTrue(menuItem(app, "Model, Sonnet 5 · High").waitForExistence(timeout: 3))
        app.buttons["chat.more.model"].tap()
        let fast = app.switches["model.panel.fast"]
        XCTAssertTrue(fast.waitForExistence(timeout: 5))
        fast.tap()
        XCTAssertTrue(waitUntil(timeout: 5) {
            self.calls(account, "config.set").contains { ($0["key"] as? String) == "fast" && ($0["value"] as? String) == "fast" }
        }, "config.set fast fast")
        XCTAssertEqual(try modelState(account)["fast"] as? Bool, true)
        closePanel(app)
        openModelPanel(app)
        XCTAssertTrue(["1", "On"].contains(app.switches["model.panel.fast"].value as? String ?? ""), "Fast is on")
        shot(app, "model-panel-fast-on")
        closePanel(app)
        let preset = calls(account, "config.set").filter { ($0["key"] as? String) == "reasoning" }.last
        XCTAssertEqual(preset?["value"] as? String, "high")
        XCTAssertNil(preset?["scope"], "the menu never sends scope")
        try assertWireClean(account)
    }

    // MARK: 22 · Offline

    @MainActor func test07_Offline() throws {
        let (account, app) = try start()
        openBotChat(app)
        openModelSheet(app)
        XCTAssertTrue(app.cells["models.row.anthropic::claude-sonnet-5"].waitForExistence(timeout: 10), "the catalog is cached")
        try account.control("/__menus/mode", ["offline": true])
        XCTAssertTrue(labelled(app, "You’re offline. Models can be changed when you reconnect.").waitForExistence(timeout: 15), "the sheet says it is offline")
        let star = app.buttons.matching(identifier: "models.star.anthropic::claude-haiku-4-5").element(boundBy: 0)
        star.tap()
        XCTAssertTrue(labelled(app, "Favorites").waitForExistence(timeout: 3), "stars still toggle offline")
        shot(app, "models-sheet-offline")
        app.cells.matching(identifier: "models.row.anthropic::claude-haiku-4-5").element(boundBy: 0).tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(app.navigationBars["Models"].exists, "a row does nothing offline")
        app.buttons.matching(identifier: "models.star.anthropic::claude-haiku-4-5").element(boundBy: 0).tap()
        app.buttons["sheet.cancel"].tap()
        openMore(app)
        XCTAssertTrue(menuItem(app, "Model, Offline").waitForExistence(timeout: 3))
        app.buttons["chat.more.model"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["model.panel"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["model.panel.approvals"].isEnabled, "nothing to change offline")
        XCTAssertFalse(app.switches["model.panel.skip"].isEnabled)
        XCTAssertFalse(app.descendants(matching: .any)["model.panel.thinking"].isEnabled)
        shot(app, "model-panel-offline")
        closePanel(app)
        try account.control("/__menus/mode", ["offline": false])
        XCTAssertTrue(waitUntil(timeout: 30) { (app.textViews["composer.text"].placeholderValue ?? "").hasPrefix("Message")
            || app.staticTexts["Message Hermes"].exists }, "back online")
        try assertWireClean(account)
    }

    // MARK: 23–25 · The commands sheet

    @MainActor func test08_CommandsSheet() throws {
        let (account, app) = try start()
        openBotChat(app)
        let field = app.textViews["composer.text"]
        field.tap()
        field.typeText("hello draft")
        app.buttons["composer.commands"].tap()
        XCTAssertTrue(app.navigationBars["Commands"].waitForExistence(timeout: 5), "the Commands sheet")
        XCTAssertTrue(app.cells["commands.row./status"].waitForExistence(timeout: 10), "rows load")
        XCTAssertTrue(waitUntil(timeout: 3) { app.keyboards.count == 0 }, "the keyboard went down for the sheet")
        XCTAssertTrue(labelled(app, "Session").exists, "the first section")
        // /help only reopens this sheet; /title in the bot's own chat only says it keeps its name.
        for hidden in ["/new", "/model", "/config", "/debug", "/resume", "/fast", "/help", "/title"] {
            XCTAssertFalse(app.cells["commands.row.\(hidden)"].exists, "\(hidden) isn't listed")
        }
        shot(app, "commands-sheet")
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("usage")
        XCTAssertTrue(waitUntil(timeout: 3) { app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'commands.row.'")).count == 1 })
        XCTAssertTrue(app.cells["commands.row./usage"].exists)
        shot(app, "commands-sheet-search")
        search.typeText(" zzz")
        XCTAssertTrue(labelled(app, "No Results for “usage zzz”").waitForExistence(timeout: 3))
        shot(app, "commands-sheet-empty")
        app.buttons["sheet.cancel"].tap()
        XCTAssertEqual(field.value as? String, "hello draft", "Cancel leaves the draft")
        // A command that stands alone sends: the sheet closes, the draft stays, a "Running…" row, then its output.
        try account.control("/__menus/mode", ["slowExec": 2])
        app.buttons["composer.commands"].tap()
        let status = app.cells["commands.row./status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        try account.control("/__menus/mode", ["slowExec": 0])
        // /status goes to session.status (no slow path): make the exec path slow instead with /version.
        try account.control("/__menus/mode", ["slowExec": 2])
        app.cells["commands.row./version"].tap()
        XCTAssertTrue(message(app, containing: "/version · Running…").waitForExistence(timeout: 5), "Running… first")
        shot(app, "slash-running")
        XCTAssertTrue(message(app, containing: "/version · Hermes Agent v0.9.0 (fixture)").waitForExistence(timeout: 8))
        XCTAssertEqual(field.value as? String, "hello draft", "the draft is untouched")
        try account.control("/__menus/mode", ["slowExec": 0])
        app.buttons["composer.commands"].tap()
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        status.tap()
        XCTAssertTrue(message(app, containing: "/status · Session 5cc537d1 · idle · claude-sonnet-5").waitForExistence(timeout: 8))
        XCTAssertFalse(message(app, containing: "You said: /status").exists, "no bubble for a command")
        shot(app, "slash-output")
        // A command that takes more goes ahead of the draft, the keyboard up.
        app.buttons["composer.commands"].tap()
        let plan = app.cells["commands.row./plan"]
        XCTAssertTrue(plan.waitForExistence(timeout: 10))
        plan.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { (field.value as? String) == "/plan hello draft" }, "\"/plan \" ahead of the draft")
        XCTAssertTrue(waitUntil(timeout: 5) { app.keyboards.count > 0 }, "the keyboard came up")
        shot(app, "commands-insert")
        try assertWireClean(account)
    }

    // MARK: 26 · Typed commands

    @MainActor func test09_TypedCommands() throws {
        let (account, app) = try start()
        openBotChat(app)
        // The catalog is read once (the sheet), so typed commands know the gateway's own reasons.
        app.buttons["composer.commands"].tap()
        XCTAssertTrue(app.cells["commands.row./status"].waitForExistence(timeout: 10))
        app.buttons["sheet.cancel"].tap()
        send(app, "/usage")
        XCTAssertTrue(message(app, containing: "Usage: 12 calls").waitForExistence(timeout: 8), "the usage output")
        XCTAssertTrue(message(app, containing: "Context: 31% of 200K tokens").exists)
        shot(app, "slash-multiline")
        send(app, "plain hello")
        XCTAssertTrue(message(app, containing: "said: Synthetic").waitForExistence(timeout: 10), "a reply")
        XCTAssertTrue(waitUntil(timeout: 10) { !app.buttons["composer.stop"].exists })
        send(app, "/undo", expectCleared: false)
        XCTAssertTrue(waitUntil(timeout: 8) { (app.textViews["composer.text"].value as? String) == "plain hello" }, "/undo prefills")
        clearField(app)
        send(app, "/release-notes v2")
        XCTAssertTrue(message(app, containing: "You said: /release-notes v2").waitForExistence(timeout: 8), "the skill's invocation bubble")
        XCTAssertTrue(waitUntil(timeout: 15) { !app.buttons["composer.stop"].exists })
        send(app, "/gif-search cats")
        XCTAssertTrue(message(app, containing: "You said: /gif-search cats").waitForExistence(timeout: 8))
        XCTAssertTrue(waitUntil(timeout: 15) { !app.buttons["composer.stop"].exists })
        send(app, "/branch")
        XCTAssertTrue(message(app, containing: "/branch isn't available in Hermes HQ yet.").waitForExistence(timeout: 5))
        send(app, "/config")
        XCTAssertTrue(message(app, containing: "/config is only available in the terminal interface.").waitForExistence(timeout: 5))
        send(app, "/yolo")
        XCTAssertTrue(message(app, containing: "YOLO on for this session").waitForExistence(timeout: 5))
        shot(app, "slash-typed")
        // /new (3x-composer §8.2): a new chat with this bot opens in this one's place, the words after it in its field.
        send(app, "/new hello", expectCleared: false)
        XCTAssertTrue(waitUntil(timeout: 10) { (app.textViews["composer.text"].value as? String) == "hello" }, "the new chat's field holds the words")
        XCTAssertFalse(message(app, containing: "YOLO on for this session").exists, "the old chat is gone from the screen")
        shot(app, "slash-new")
        let submitted = calls(account, "prompt.submit").map { $0["text"] as? String ?? "" }
        XCTAssertTrue(submitted.contains { $0.hasPrefix("[IMPORTANT: The user has invoked the \"release-notes\" skill") }, "the wire carries the skill body")
        XCTAssertFalse(submitted.contains("/usage"), "commands never go out as messages")
        try assertWireClean(account)
    }

    // MARK: 27 · Commands while a reply runs

    @MainActor func test10_CommandsWhileReplying() throws {
        let (account, app) = try start()
        try account.control("/__fixture/plan", ["plans": [["chunks": Array(repeating: "word ", count: 60), "chunkDelay": 0.4]]])
        openBotChat(app)
        send(app, "Keep talking")
        XCTAssertTrue(app.buttons["composer.stop"].waitForExistence(timeout: 8))
        send(app, "/status")
        XCTAssertTrue(message(app, containing: "/status · Session 5cc537d1 · running").waitForExistence(timeout: 5), "runs at once, not queued")
        send(app, "/plan x")
        XCTAssertTrue(message(app, containing: "session busy — message queued to send when the current turn finishes").waitForExistence(timeout: 8))
        shot(app, "slash-busy")
        try account.control("/__fixture/finish", ["profile": "default"])
        XCTAssertTrue(message(app, containing: "You said: /plan x").waitForExistence(timeout: 15), "the queued plan goes out after the turn")
        try assertWireClean(account)
    }

    // MARK: 28 · Rename

    @MainActor func test11_Rename() throws {
        keepAppAlerts()
        let (account, app) = try start()
        openTrip(app)
        openMore(app)
        app.buttons["chat.more.rename"].tap()
        let alert = app.alerts["Rename Chat"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let field = alert.textFields["rename.field"]
        XCTAssertEqual(field.value as? String, "Trip planning")
        XCTAssertFalse(alert.buttons["Save"].isEnabled, "Save waits for a change")
        shot(app, "rename-alert")
        field.tap()
        field.menusReplaceText("Trip to Lisbon")
        XCTAssertTrue(alert.buttons["Save"].isEnabled)
        submit(alert, field)
        XCTAssertTrue(barTitle(app, "Trip to Lisbon").waitForExistence(timeout: 5), "the bar shows it at once")
        XCTAssertTrue(waitUntil(timeout: 5) { self.calls(account, "session.title").contains { ($0["title"] as? String) == "Trip to Lisbon" } })
        // The RPC refused twice (stale runtime): the REST PATCH stores it.
        // (A few more than the two the rename uses: a background read may take one.)
        try account.control("/__menus/mode", ["staleRuntime": 6])
        rename(app, to: "Lisbon long weekend")
        let patched = waitUntil(timeout: 8) { self.patches(account).contains { (($0["body"] as? [String: Any])?["title"] as? String) == "Lisbon long weekend" } }
        if !patched, let data = try? JSONSerialization.data(withJSONObject: try state(account), options: .prettyPrinted),
           let dir = ProcessInfo.processInfo.environment["HQN_UI_SHOTS"] {
            try? data.write(to: URL(fileURLWithPath: dir).deletingLastPathComponent().appending(path: "ui-dumps/rename-state.json"))
        }
        XCTAssertTrue(patched, "the REST fallback")
        try account.control("/__menus/mode", ["staleRuntime": 0])
        let patch = patches(account).last
        XCTAssertEqual((patch?["body"] as? [String: Any])?["profile"] as? String, "default")
        XCTAssertTrue((patch?["query"] as? String ?? "").contains("profile=default"))
        XCTAssertTrue(waitUntil(timeout: 5) { ((try? self.state(account)["titles"] as? [String: String]) ?? [:])?[Self.trip] == "Lisbon long weekend" })
        // A taken title fails, rolls back, and offers Try Again.
        rename(app, to: "Taken")
        let failure = app.alerts["Couldn’t Rename Chat"]
        XCTAssertTrue(failure.waitForExistence(timeout: 8))
        XCTAssertTrue(failure.buttons["Try Again"].exists)
        shot(app, "rename-failed")
        failure.buttons["OK"].tap()
        XCTAssertTrue(barTitle(app, "Lisbon long weekend").waitForExistence(timeout: 5), "rolled back")
        goBack(app)
        XCTAssertTrue(app.cells["session-row-\(Self.trip)"].staticTexts.matching(NSPredicate(format: "label CONTAINS 'Lisbon long weekend'")).firstMatch
            .waitForExistence(timeout: 5) || app.cells["session-row-\(Self.trip)"].label.contains("Lisbon long weekend"), "the Sessions row")
        try assertWireClean(account)
    }

    // MARK: 29 · Share the whole chat

    @MainActor func test12_ShareWholeChat() throws {
        XCUIDevice.shared.appearance = Self.darkRun ? .dark : .light
        clearTextOut()
        let account = try FixtureAccount.load()
        try account.control("/__menus/reset", [:])
        let seeded = try account.control("/__fixture/history", ["profile": "default", "count": 1200])
        XCTAssertEqual(seeded["rows"] as? Int, 1200)
        let app = launch(account, reset: true)
        openBotChat(app)
        openMore(app)
        app.buttons["chat.more.share"].tap()
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 15) || app.navigationBars["UIActivityContentView"].exists
                      || app.buttons["Copy"].waitForExistence(timeout: 2), "the share sheet")
        shot(app, "share-sheet")
        let pages = try (state(account)["rest"] as? [[String: Any]] ?? []).filter { row in
            (row["path"] as? String ?? "").hasSuffix("/messages") && (row["query"] as? String ?? "").contains("order=oldest")
        }.map { $0["query"] as? String ?? "" }
        XCTAssertEqual(pages.count, 3, "three pages of 500: \(pages)")
        for (i, offset) in [0, 500, 1000].enumerated() where i < pages.count {
            XCTAssertTrue(pages[i].contains("limit=500") && pages[i].contains("offset=\(offset)"), pages[i])
        }
        // The shared text: the title line, a blank line, then the first seeded row (spec 1x §14.3 check 29).
        if let shared = textOut("share.txt") {
            let lines = shared.components(separatedBy: "\n")
            XCTAssertEqual(lines.first, "Hermes", "the title line")
            XCTAssertEqual(lines.dropFirst().first, "", "a blank line under the title")
            XCTAssertEqual(lines.dropFirst(2).first, "You:")
            XCTAssertTrue(lines.dropFirst(3).first?.hasPrefix("Synthetic history row 0. ") == true, "the first seeded row")
            XCTAssertTrue(shared.contains("Synthetic history row 1199. "), "the last seeded row")
        } else {
            XCTFail("the share sheet's text (HQN_UI_SHOTS unset?)")
        }
        try assertWireClean(account)
    }

    // MARK: 30 · Hold menus

    @MainActor func test13_HoldMenus() throws {
        clearTextOut()
        let (account, app) = try start()
        let markdown = "**Synthetic** reply with `code` and a [link](https://example.com)."
        try account.control("/__fixture/plan", ["plans": [["replyText": markdown]]])
        openBotChat(app)
        send(app, "Hello there")
        // (The bubble's VoiceOver label is its raw Markdown today, an M1 chat-cell matter: match plain words only.)
        let reply = message(app, containing: "reply with")
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 10) { !app.buttons["composer.stop"].exists })
        reply.press(forDuration: 0.9)
        XCTAssertTrue(app.buttons["message.copy"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["message.share"].exists)
        XCTAssertTrue(app.buttons["message.select"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Hermes · '")).firstMatch.exists, "the menu's title")
        shot(app, "hold-menu-reply")
        app.buttons["message.copy"].tap()
        // The HUD lasts 1.5 s: look it up by identifier (a whole-tree label search can take longer than that).
        XCTAssertTrue(app.otherElements["menus.hud"].waitForExistence(timeout: 2), "the HUD")
        XCTAssertEqual(app.otherElements["menus.hud"].label, "Copied")
        // What Copy left on the pasteboard is the reply's Markdown (spec 1x §14.3 check 30).
        if let copied = textOut("copy.txt") {
            XCTAssertEqual(copied, markdown, "the pasteboard holds the Markdown")
        } else {
            XCTFail("the pasteboard's text (HQN_UI_SHOTS unset?)")
        }
        reply.press(forDuration: 0.9)
        XCTAssertTrue(app.buttons["message.select"].waitForExistence(timeout: 5))
        app.buttons["message.select"].tap()
        XCTAssertTrue(app.navigationBars["Select Text"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews["select.text"].exists)
        shot(app, "select-text")
        app.buttons["select.copy-all"].tap()
        XCTAssertTrue(app.otherElements["menus.hud"].waitForExistence(timeout: 2), "the HUD over the sheet")
        shot(app, "select-text-copied")
        app.buttons["select.done"].tap()
        let mine = message(app, containing: "You said: Hello there")
        XCTAssertTrue(mine.waitForExistence(timeout: 5))
        mine.press(forDuration: 0.9)
        XCTAssertTrue(app.buttons["message.copy"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["message.select"].exists)
        XCTAssertFalse(app.buttons["message.share"].exists, "your bubble has no Share")
        shot(app, "hold-menu-mine")
        dismissMenu(app)
        // A reply still streaming: Share waits ("Still Replying").
        try account.control("/__fixture/plan", ["plans": [["chunks": Array(repeating: "word ", count: 80), "chunkDelay": 0.3]]])
        send(app, "One more")
        let live = message(app, containing: "said: word word")
        XCTAssertTrue(live.waitForExistence(timeout: 10))
        live.press(forDuration: 0.9)
        let share = app.buttons["message.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        XCTAssertFalse(share.isEnabled, "Share is off while it streams")
        XCTAssertTrue(share.label.contains("Still Replying") || app.staticTexts["Still Replying"].exists)
        shot(app, "hold-menu-streaming")
        dismissMenu(app)
        try account.control("/__fixture/finish", ["profile": "default"])
        try assertWireClean(account)
    }

    // MARK: Loading and error states (screenshots)

    @MainActor func test14_SheetStates() throws {
        let (account, app) = try start()
        openBotChat(app)
        try account.control("/__menus/mode", ["catalogFail": true, "optionsFail": true])
        app.buttons["composer.commands"].tap()
        XCTAssertTrue(labelled(app, "Couldn’t Load Commands").waitForExistence(timeout: 10))
        shot(app, "commands-error")
        try account.control("/__menus/mode", ["catalogFail": false])
        app.buttons["Try Again"].tap()
        XCTAssertTrue(app.cells["commands.row./status"].waitForExistence(timeout: 10), "Try Again reads it")
        app.buttons["sheet.cancel"].tap()
        openModelSheet(app)
        XCTAssertTrue(labelled(app, "Couldn’t Load Models").waitForExistence(timeout: 10))
        shot(app, "models-error")
        try account.control("/__menus/mode", ["optionsFail": false, "optionsDelay": 3])
        app.buttons["Try Again"].tap()
        Thread.sleep(forTimeInterval: 0.6)
        shot(app, "models-loading")
        XCTAssertTrue(app.cells["models.row.anthropic::claude-sonnet-5"].waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(try state(account)["optionsRefreshes"] as? Int ?? 0, 1, "Try Again refreshes")
        app.buttons["sheet.cancel"].tap()
        try account.control("/__menus/mode", ["optionsDelay": 0])
        // Info: the model's name, its provider under it, Reasoning.
        openMore(app)
        app.buttons["chat.more.info"].tap()
        // The provider as the Models sheet names it (the catalog's "Anthropic").
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Model' AND value == 'Sonnet 5, Anthropic'")).firstMatch
            .waitForExistence(timeout: 5), "the model's name with its provider under it")
        shot(app, "info-sheet")
        try assertWireClean(account)
    }

    // MARK: Dark appearance (screenshots of the new surfaces)

    @MainActor func test15_DarkTour() throws {
        defer { XCUIDevice.shared.appearance = Self.darkRun ? .dark : .light }
        let (account, app) = try start(dark: true)
        openBotChat(app)
        openMore(app)
        shot(app, "more-menu")
        app.buttons["chat.more.model"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["model.panel"].waitForExistence(timeout: 5))
        shot(app, "model-panel")
        openSwitchMenu(app)
        app.buttons["model.panel.search"].tap()
        XCTAssertTrue(app.cells["models.row.anthropic::claude-sonnet-5"].waitForExistence(timeout: 10))
        app.buttons.matching(identifier: "models.star.openai-codex::gpt-5.5").element(boundBy: 0).tap()
        XCTAssertTrue(labelled(app, "Favorites").waitForExistence(timeout: 3))
        shot(app, "models-sheet-favorites")
        app.buttons.matching(identifier: "models.star.openai-codex::gpt-5.5").element(boundBy: 0).tap()
        app.buttons["sheet.cancel"].tap()
        app.buttons["composer.commands"].tap()
        XCTAssertTrue(app.cells["commands.row./status"].waitForExistence(timeout: 10))
        shot(app, "commands-sheet")
        app.cells["commands.row./status"].tap()
        XCTAssertTrue(message(app, containing: "/status · Session").waitForExistence(timeout: 8))
        send(app, "/usage")
        XCTAssertTrue(message(app, containing: "Usage: 12 calls").waitForExistence(timeout: 8))
        shot(app, "slash-output")
        send(app, "Hello there")
        let reply = message(app, containing: "Hermes said: Synthetic")
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 10) { !app.buttons["composer.stop"].exists })
        reply.press(forDuration: 0.9)
        XCTAssertTrue(app.buttons["message.select"].waitForExistence(timeout: 5))
        shot(app, "hold-menu-reply")
        app.buttons["message.select"].tap()
        XCTAssertTrue(app.navigationBars["Select Text"].waitForExistence(timeout: 5))
        shot(app, "select-text")
        app.buttons["select.done"].tap()
        openModelSheet(app)
        let opus = app.cells["models.row.anthropic::claude-opus-4-5-20251101"]
        XCTAssertTrue(opus.waitForExistence(timeout: 10))
        opus.tap()
        XCTAssertTrue(app.alerts["Change Model?"].waitForExistence(timeout: 8))
        shot(app, "change-model-alert")
        app.alerts["Change Model?"].buttons["Cancel"].tap()
        goBack(app)
        openTrip(app)
        openMore(app)
        app.buttons["chat.more.rename"].tap()
        XCTAssertTrue(app.alerts["Rename Chat"].waitForExistence(timeout: 5))
        shot(app, "rename-alert")
        app.alerts["Rename Chat"].buttons["Cancel"].tap()
        try assertWireClean(account)
    }

    // MARK: 33 · Accessibility text sizes (screenshots; scripts/e2e-menus.sh with HQN_MENUS_AX3=1 sets AX3 first)

    @MainActor func test16_LargeTextTour() throws {
        guard ProcessInfo.processInfo.environment["HQN_UI_AX3"] == "1" else {
            throw XCTSkip("Runs with HQN_MENUS_AX3=1 (the simulator's text size is set to AX3 around it).")
        }
        let (account, app) = try start()
        openBotChat(app)
        openMore(app)
        shot(app, "ax3-more-menu")
        app.buttons["chat.more.model"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["model.panel"].waitForExistence(timeout: 5))
        shot(app, "ax3-model-panel")
        openSwitchMenu(app)
        app.buttons["model.panel.search"].tap()
        XCTAssertTrue(app.cells["models.row.anthropic::claude-sonnet-5"].waitForExistence(timeout: 10))
        shot(app, "ax3-models-sheet")
        app.buttons["sheet.cancel"].tap()
        app.buttons["composer.commands"].tap()
        XCTAssertTrue(app.cells["commands.row./status"].waitForExistence(timeout: 10))
        shot(app, "ax3-commands-sheet")
        app.cells["commands.row./status"].tap()
        XCTAssertTrue(message(app, containing: "/status · Session").waitForExistence(timeout: 8))
        send(app, "/usage")
        XCTAssertTrue(message(app, containing: "Usage: 12 calls").waitForExistence(timeout: 8))
        app.tables["chat.table"].swipeDown()
        shot(app, "ax3-slash-output")
        // Info: the Model row's value and its provider stack under the label, nothing clipped.
        openMore(app)
        app.buttons["chat.more.info"].tap()
        let model = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Model' AND value == 'Sonnet 5, Anthropic'")).firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 5), "Info's Model row")
        shot(app, "ax3-info-sheet")
        try assertWireClean(account)
    }

    // MARK: 31 · An older gateway

    @MainActor func test99_OldGateway() throws {
        guard let path = ProcessInfo.processInfo.environment["HQN_UI_OLD_CREDENTIALS"], !path.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_HQN_UI_OLD_CREDENTIALS (scripts/e2e-menus.sh does).")
        }
        XCUIDevice.shared.appearance = Self.darkRun ? .dark : .light
        let account = try FixtureAccount.load(path: path)
        try account.control("/__menus/reset", [:])
        try account.control("/__menus/mode", ["oldGateway": true])
        try account.control("/__fixture/plan", ["plans": [["chunks": Array(repeating: "word ", count: 60), "chunkDelay": 0.4]]])
        let app = launch(account, reset: true)
        openBotChat(app)
        send(app, "A long one please")
        XCTAssertTrue(app.buttons["composer.stop"].waitForExistence(timeout: 8))
        openModelSheet(app)
        let gpt = app.cells["models.row.openai-codex::gpt-5.5"]
        XCTAssertTrue(gpt.waitForExistence(timeout: 10))
        gpt.tap()
        XCTAssertTrue(app.staticTexts["GPT-5.5 will be used for your next message."].waitForExistence(timeout: 8), "4009 reads as parked")
        XCTAssertFalse(app.alerts["Couldn’t Change Model"].exists)
        try account.control("/__fixture/finish", ["profile": "default"])
        XCTAssertTrue(waitUntil(timeout: 10) { !app.buttons["composer.stop"].exists })
        send(app, "/status")
        XCTAssertTrue(message(app, containing: "/status · (no output)").waitForExistence(timeout: 8), "-32601 falls back to slash.exec")
        XCTAssertTrue(calls(account, "slash.exec").contains { ($0["command"] as? String) == "status" })
        try account.control("/__menus/mode", ["oldGateway": true])
        try assertWireClean(account)
    }

    // MARK: - Wire checks (spec 1x §14.2 checks 12–13)

    /// No call answered 4000; every menus call named its profile; REST renames carried it in the query and the body.
    @MainActor func assertWireClean(_ account: FixtureAccount) throws {
        let s = try state(account)
        let rejected = s["rejected"] as? [[String: Any]] ?? []
        XCTAssertTrue(rejected.isEmpty, "calls refused with 4000: \(rejected)")
        for call in s["calls"] as? [[String: Any]] ?? [] {
            guard let method = call["method"] as? String, Self.menusMethods.contains(method) else { continue }
            let params = call["params"] as? [String: Any] ?? [:]
            XCTAssertEqual(params["profile"] as? String, "default", "\(method) names its profile: \(params)")
        }
    }

    // MARK: - Helpers

    /// `HQN_UI_DARK=1` (scripts/e2e-menus.sh with HQN_MENUS_DARK=1) runs every test in dark appearance.
    static var darkRun: Bool { ProcessInfo.processInfo.environment["HQN_UI_DARK"] == "1" }

    @MainActor func start(dark: Bool = false) throws -> (FixtureAccount, XCUIApplication) {
        XCUIDevice.shared.appearance = dark || Self.darkRun ? .dark : .light
        let account = try FixtureAccount.load()
        try account.control("/__menus/reset", [:])
        return (account, launch(account, reset: true))
    }

    /// Launches the app (a clean phone when `reset`) and signs in when the form shows.
    @MainActor func launch(_ account: FixtureAccount, reset: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (reset ? ["-HQDebugResetAccounts", "YES"] : []) + ["-HQDebugHUDSeconds", "6"]
            + (Self.textOutFolder.map { ["-HQDebugTextOut", $0] } ?? [])
            + (ProcessInfo.processInfo.environment["HQN_UI_DESKTOPLOOK"] == "1" ? ["-HQDebugDesktopLook", "YES"] : [])
            + (ProcessInfo.processInfo.environment["HQN_UI_SKIN"].flatMap { $0.isEmpty ? nil : ["-HQDebugSkin", $0] } ?? [])
        app.launch()
        current = app
        let row = app.cells[Self.botRow]
        let form = app.textFields["sign-in-address"]
        _ = waitUntil(timeout: 15) { row.exists || form.exists }
        if !row.exists && form.exists { signIn(app, account) }
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the Bots list shows")
        return app
    }

    @MainActor func signIn(_ app: XCUIApplication, _ account: FixtureAccount) {
        let address = app.textFields["sign-in-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 15), "the sign-in form shows")
        address.tap()
        if let current = address.value as? String, !current.isEmpty, current != "my-mac.tail1234.ts.net" {
            address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        address.typeText(account.url)
        let username = app.textFields["sign-in-username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10), "the password fields show for the address")
        username.tap()
        if let current = username.value as? String, !current.isEmpty, current != "Username" {
            username.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        username.typeText(account.username)
        let password = app.secureTextFields["sign-in-password"]
        password.tap()
        password.typeText(account.password)
        app.buttons["sign-in-password-button"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for candidate in [app.buttons["Not Now"], springboard.buttons["Not Now"]] where candidate.waitForExistence(timeout: 2) {
            candidate.tap()
            break
        }
    }

    @MainActor @discardableResult
    func openBotChat(_ app: XCUIApplication) -> XCUIElement {
        let row = app.cells[Self.botRow]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1.0)
        row.tap()
        // A tap that landed while the list settled after sign-in is tried once more.
        if !app.tables["chat.table"].waitForExistence(timeout: 6), row.exists { row.tap() }
        return awaitChat(app)
    }

    @MainActor @discardableResult
    func openTrip(_ app: XCUIApplication) -> XCUIElement {
        let tab = app.buttons["tab-sessions"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()
        let row = app.cells["session-row-\(Self.trip)"]
        // A tap that landed while the tab bar settled is tried once more.
        if !row.waitForExistence(timeout: 6) { tab.tap() }
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the Trip planning row")
        Thread.sleep(forTimeInterval: 0.8)
        row.tap()
        return awaitChat(app)
    }

    @MainActor private func awaitChat(_ app: XCUIApplication) -> XCUIElement {
        let table = app.tables["chat.table"]
        if !table.waitForExistence(timeout: 8) {
            shot(app, "fail-open-chat")
            dump(app, "fail-open-chat")
        }
        XCTAssertTrue(table.exists, "the chat opens")
        XCTAssertTrue(app.buttons["chat.more"].waitForExistence(timeout: 5))
        // Let the open settle (resume + fresh history) before acting on it.
        Thread.sleep(forTimeInterval: 1.0)
        return table
    }

    @MainActor func goBack(_ app: XCUIApplication) {
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 0.6)
    }

    @MainActor func openMore(_ app: XCUIApplication) {
        let more = app.buttons["chat.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        XCTAssertTrue(app.buttons["chat.more.info"].waitForExistence(timeout: 5), "the ⋯ menu opens")
    }

    /// ⋯ › Model: the model panel (owner 2026-11-01, one place for the model, its thinking and Fast).
    @MainActor func openModelPanel(_ app: XCUIApplication) {
        openMore(app)
        let row = app.buttons["chat.more.model"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the ⋯'s Model row")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["model.panel"].waitForExistence(timeout: 5), "the model panel opens")
    }

    /// The panel's name opens Switch Model.
    @MainActor func openSwitchMenu(_ app: XCUIApplication) {
        let name = app.buttons["model.panel.switch"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        XCTAssertTrue(app.buttons["model.panel.search"].waitForExistence(timeout: 5), "Switch Model opens")
    }

    /// A tap outside the card: above it, or beside it when it reaches the top. Never where a menu over the card may be.
    @MainActor func tapOutsidePanel(_ app: XCUIApplication) {
        let card = app.descendants(matching: .any)["model.panel"]
        guard card.exists else { return }
        let top = app.navigationBars.firstMatch.frame.maxY
        let above = card.frame.minY - 24 > top + 8
        let point = above ? CGVector(dx: card.frame.midX, dy: card.frame.minY - 24) : CGVector(dx: max(2, card.frame.minX / 2), dy: card.frame.midY)
        app.coordinate(withNormalizedOffset: .zero).withOffset(point).tap()
    }

    /// The first tap outside closes Switch Model's menu (and only the menu).
    @MainActor func closeSwitchMenu(_ app: XCUIApplication) {
        let search = app.buttons["model.panel.search"]
        tapOutsidePanel(app)
        XCTAssertTrue(waitUntil(timeout: 3) { !search.exists }, "Switch Model closes")
        Thread.sleep(forTimeInterval: 0.4)
    }

    /// A tap outside the card closes the panel.
    @MainActor func closePanel(_ app: XCUIApplication) {
        let card = app.descendants(matching: .any)["model.panel"]
        guard card.exists else { return }
        tapOutsidePanel(app)
        XCTAssertTrue(waitUntil(timeout: 3) { !card.exists }, "the panel closes")
    }

    /// What the panel's thinking bar says ("Medium, Thinks …").
    @MainActor func thinkingValue(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)["model.panel.thinking"].value as? String ?? ""
    }

    /// The first model Switch Model lists.
    @MainActor func firstPick(_ app: XCUIApplication) -> String {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'model.panel.pick.'")).firstMatch.identifier
    }

    /// Switch Model › Search All Models: the Models sheet.
    @MainActor func openModelSheet(_ app: XCUIApplication) {
        openModelPanel(app)
        openSwitchMenu(app)
        app.buttons["model.panel.search"].tap()
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 5), "the Models sheet")
    }

    /// A menu row by the start of its label ("Model, Sonnet 5 · Medium": title, then subtitle).
    @MainActor func menuItem(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    @MainActor func dismissMenu(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.55)).tap()
        Thread.sleep(forTimeInterval: 0.5)
    }

    @MainActor func send(_ app: XCUIApplication, _ text: String, expectCleared: Bool = true) {
        let field = app.textViews["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
        let button = app.buttons["composer.send"]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        button.tap()
        guard expectCleared else { return }
        XCTAssertTrue(waitUntil(timeout: 3) { (field.value as? String ?? "").isEmpty || (field.value as? String) == "Message" },
                      "the field cleared")
    }

    @MainActor func clearField(_ app: XCUIApplication) {
        let field = app.textViews["composer.text"]
        guard let text = field.value as? String, !text.isEmpty else { return }
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count + 2))
    }

    @MainActor func rename(_ app: XCUIApplication, to title: String) {
        openMore(app)
        app.buttons["chat.more.rename"].tap()
        let alert = app.alerts["Rename Chat"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let field = alert.textFields["rename.field"]
        field.tap()
        field.menusReplaceText(title)
        submit(alert, field)
    }

    /// Saves the Rename alert with Return (Save is its preferred action): a tap on Save can miss while the keyboard and
    /// its suggestion bar settle and move the alert. Taps Save only if Return didn't close it.
    @MainActor func submit(_ alert: XCUIElement, _ field: XCUIElement) {
        field.typeText("\n")
        if !waitUntil(timeout: 5, { !alert.exists }) { tapUntilGone(alert, alert.buttons["Save"]) }
        XCTAssertFalse(alert.exists, "the alert closed")
    }

    /// The app's own alerts (Rename Chat, Couldn't Rename Chat) are never cancelled by XCTest's default interruption
    /// handling when a tap on one of their buttons misses (an invalid hit point while the alert moves): this monitor
    /// claims them as handled and leaves them showing, so XCTest retries the tap instead of pressing Cancel.
    @MainActor func keepAppAlerts() {
        addUIInterruptionMonitor(withDescription: "the app's own alerts") { alert in
            ["Rename Chat", "Couldn’t Rename Chat", "Change Model?"].contains(alert.label)
        }
    }

    /// Taps a button until its alert goes (a first tap can land while the keyboard settles); at most three times.
    @MainActor func tapUntilGone(_ alert: XCUIElement, _ button: XCUIElement) {
        for _ in 0..<3 where alert.exists && button.exists {
            button.tap()
            _ = waitUntil(timeout: 5) { !alert.exists }
        }
        XCTAssertFalse(alert.exists, "the alert closed")
    }

    /// The chat's title in the bar (head + name, the bot's name under a session's title).
    @MainActor func barTitle(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.navigationBars.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Any element with exactly this label (section headers, notices).
    @MainActor func labelled(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    @MainActor func message(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.tables["chat.table"].descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    // MARK: Fixture state

    @MainActor func state(_ account: FixtureAccount) throws -> [String: Any] { try account.control("/__menus/state") }

    @MainActor func calls(_ account: FixtureAccount, _ method: String) -> [[String: Any]] {
        ((try? state(account))?["calls"] as? [[String: Any]] ?? []).filter { $0["method"] as? String == method }
            .map { $0["params"] as? [String: Any] ?? [:] }
    }

    @MainActor func patches(_ account: FixtureAccount) -> [[String: Any]] {
        ((try? state(account))?["rest"] as? [[String: Any]] ?? []).filter { $0["method"] as? String == "PATCH" }
    }

    @MainActor func modelState(_ account: FixtureAccount) throws -> [String: Any] {
        ((try state(account))["modelState"] as? [String: Any])?["default"] as? [String: Any] ?? [:]
    }

    // MARK: Text the app hands over (DEBUG `-HQDebugTextOut`)

    /// Next to the shots folder: the app writes what it shared (share.txt) and copied (copy.txt) there.
    static var textOutFolder: String? {
        guard let dir = ProcessInfo.processInfo.environment["HQN_UI_SHOTS"], !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: dir).deletingLastPathComponent().appending(path: "ui-text").path
    }

    func clearTextOut() {
        guard let folder = Self.textOutFolder else { return }
        for name in ["share.txt", "copy.txt"] { try? FileManager.default.removeItem(atPath: (folder as NSString).appendingPathComponent(name)) }
    }

    /// The file's text once the app has written it (waits up to 5 s).
    @MainActor func textOut(_ name: String) -> String? {
        guard let folder = Self.textOutFolder else { return nil }
        let path = (folder as NSString).appendingPathComponent(name)
        _ = waitUntil(timeout: 5) { FileManager.default.fileExists(atPath: path) }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    // MARK: Screens

    /// Saves a screenshot to the shots folder (and the result bundle), named for the appearance.
    @MainActor func shot(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.4)
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let dir = ProcessInfo.processInfo.environment["HQN_UI_SHOTS"], !dir.isEmpty else { return }
        let mode = XCUIDevice.shared.appearance == .dark ? "dark" : "light"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "\(name)-\(mode).png"))
    }

    /// Writes the accessibility tree next to the shots folder (debugging a query).
    @MainActor func dump(_ app: XCUIApplication, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["HQN_UI_SHOTS"], !dir.isEmpty else { return }
        let folder = URL(fileURLWithPath: dir).deletingLastPathComponent().appending(path: "ui-dumps")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? app.debugDescription.write(to: folder.appending(path: "\(name).txt"), atomically: true, encoding: .utf8)
    }

    @MainActor @discardableResult
    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}

extension FixtureAccount {
    static func load(path: String) throws -> FixtureAccount {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = object["url"] as? String, let username = object["username"] as? String,
              let password = object["password"] as? String else { throw XCTSkip("Unreadable credentials file") }
        return FixtureAccount(url: url, username: username, password: password)
    }
}

extension XCUIElement {
    /// Replaces a text field's text.
    func menusReplaceText(_ text: String) {
        if let current = value as? String, !current.isEmpty, current != placeholderValue {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 1))
        }
        typeText(text)
    }
}
