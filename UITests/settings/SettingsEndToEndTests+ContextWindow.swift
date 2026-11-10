// [context-window] Context Window (owner 2026-11-01, after asking where max context was set: "If I have to ask you, then
// I'm sure others may not ever even find it"): its own page under Settings › Model with its size on the row, the sizes
// Hermes takes, a typed size, and each bot's own from Bot Info. Run with scripts/e2e-settings.sh
// (HQN_E2E_ONLY="testG12_ContextWindowHasItsOwnPageAndEachBotsRow").

import XCTest

extension SettingsEndToEndTests {
    @objc @MainActor func testG12_ContextWindowHasItsOwnPageAndEachBotsRow() throws {
        let app = launchSignedIn()
        openSection(app, "model")
        let row = app.buttons["config-page.model.context"]
        XCTAssertTrue(appears(row, app, "context-window-row", timeout: 8), "Settings › Model › Context Window")
        XCTAssertTrue(waitUntil(timeout: 8) { row.label.contains("Automatic") }, "its size on the row: \(row.label)")
        shot(app, "context-window-row")
        row.tap()

        let automatic = app.buttons["context-window.automatic"]
        XCTAssertTrue(appears(automatic, app, "context-window-page", timeout: 8), "the page")
        XCTAssertTrue(automatic.isSelected, "Automatic while Hermes has 0")
        XCTAssertTrue(waitUntil(timeout: 8) { !app.buttons["context-window.1000000"].exists && app.buttons["context-window.400000"].exists },
                      "the model's own 1M is Automatic, not a second row")
        shot(app, "context-window-page")

        app.buttons["context-window.200000"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { (self.fixtureConfig("model_context_length") as? NSNumber)?.intValue == 200_000 },
                      "saved: \(a.writes("PUT /api/config"))")
        XCTAssertTrue(app.buttons["context-window.200000"].isSelected)

        // A typed size: under Hermes' 64K says why and saves nothing; 300K saves.
        let custom = app.textFields["context-window.custom"]
        XCTAssertTrue(custom.waitForExistence(timeout: 3))
        custom.tap()
        custom.typeText("32K\n")
        let why = app.staticTexts.matching(NSPredicate(format: "label == %@", "Hermes needs at least 64K.")).firstMatch
        XCTAssertTrue(appears(why, app, "context-window-problem", timeout: 3), "says why")
        XCTAssertEqual((fixtureConfig("model_context_length") as? NSNumber)?.intValue, 200_000, "nothing saved")
        shot(app, "context-window-too-small")
        // Back in the field the refused size is chosen, so typing replaces it.
        custom.tap()
        Thread.sleep(forTimeInterval: 0.5)
        custom.typeText("300K\n")
        XCTAssertTrue(waitUntil(timeout: 8) { (self.fixtureConfig("model_context_length") as? NSNumber)?.intValue == 300_000 },
                      "saved: \(a.writes("PUT /api/config"))")
        XCTAssertFalse(why.exists, "the problem went with it")
        shot(app, "context-window-custom")
        back(app)
        XCTAssertTrue(waitUntil(timeout: 5) { row.label.contains("300K") }, "the row says it: \(row.label)")

        // Bot Info: Ivy's own window, not Hermes's.
        app.terminate()
        let again = launchSignedIn()
        openBotInfo(again, "ivy")
        again.botInfoTab("Brain")   // [page-tabs]
        let ivyRow = again.buttons["bot-info.context-window"]
        XCTAssertTrue(appears(ivyRow, again, "bot-context-row", timeout: 8), "Brain › Context Window")
        XCTAssertTrue(waitUntil(timeout: 8) { ivyRow.label.contains("Automatic") }, "Ivy's own size, not Hermes's 300K: \(ivyRow.label)")
        shot(again, "bot-info-context-row")
        ivyRow.tap()
        let ivyAutomatic = again.buttons["context-window.automatic"]
        XCTAssertTrue(appears(ivyAutomatic, again, "bot-context-page", timeout: 8))
        let whose = again.staticTexts.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Ivy’s Default Model")).firstMatch
        XCTAssertTrue(whose.waitForExistence(timeout: 5), "whose window this is")
        XCTAssertTrue(((a.state()["rest"] as? [[String: Any]]) ?? []).contains {
            ($0["path"] as? String).map { $0.hasPrefix("/api/config") && $0.contains("profile=ivy") } == true
        }, "the page read Ivy's config")
        again.buttons["context-window.128000"].tap()
        let ivyWindow = { ((self.a.state()["configs"] as? [String: Any])?["ivy"] as? [String: Any])?["model_context_length"] as? NSNumber }
        XCTAssertTrue(waitUntil(timeout: 8) { ivyWindow()?.intValue == 128_000 }, "saved in Ivy's config: \(a.writes("PUT /api/config"))")
        XCTAssertEqual((fixtureConfig("model_context_length") as? NSNumber)?.intValue, 300_000, "Hermes's own stays 300K")
        shot(again, "bot-context-page")
        back(again)
        XCTAssertTrue(waitUntil(timeout: 5) { ivyRow.label.contains("128K") }, "the row says it: \(ivyRow.label)")
    }
}
