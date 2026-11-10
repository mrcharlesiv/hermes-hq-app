// More search, the phone's command palette (docs/spec/3x-morepages.md §18, U17), against the morepages stand-in.
// Run: HQN_MOREPAGES_ONLY="MoreSearchUITests" scripts/e2e-morepages.sh <udid>

import XCTest

final class MoreSearchUITests: MorePagesCase {
    @MainActor private var field: XCUIElement { app.searchFields["more.search.field"] }
    @MainActor private var results: XCUIElement { app.collectionViews["more.results"] }
    /// The first result row (section headers are cells too).
    @MainActor private var firstResult: XCUIElement {
        results.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'more.result.'")).element(boundBy: 0)
    }
    @MainActor private func result(_ id: String) -> XCUIElement { app.cells["more.result.\(id)"] }

    @MainActor private func openSearch() {
        tab("More")
        let magnifier = app.buttons["more.search"]
        XCTAssertTrue(magnifier.waitForExistence(timeout: 10), "More's bar has the magnifier")
        XCTAssertEqual(magnifier.label, "Search Sessions, Pages and Actions")
        XCTAssertFalse(field.exists, "no field at rest")
        magnifier.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
    }

    /// Replaces the query. Keys go to the app: XCUITest stops seeing the search field as focused once it holds text.
    @MainActor private func type(_ text: String) {
        if !app.keyboards.firstMatch.exists { field.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the keyboard is up")
        let clear = field.buttons["Clear text"]
        if clear.exists { clear.tap() }
        if !text.isEmpty { app.typeText(text) }
    }

    @MainActor private var cancel: XCUIElement {
        let close = app.buttons["Close"].firstMatch
        return close.exists ? close : app.buttons["Cancel"].firstMatch
    }

    /// §18 acceptance 2: pages, actions, bots and settings are found and open; Back shows the results again; Cancel
    /// returns More.
    @MainActor func testU17_MoreSearch() throws {
        launchSignedIn()
        openSearch()
        XCTAssertTrue(app.cells["more-row-settings"].exists, "an empty query leaves More as it is")
        shot("more-search-empty")

        type("web")
        XCTAssertTrue(results.waitForExistence(timeout: 5))
        let webhooks = result("goTo.webhooks")
        XCTAssertTrue(webhooks.waitForExistence(timeout: 5), "Go To finds Webhooks")
        XCTAssertEqual(firstResult.identifier, "more.result.goTo.webhooks", "Webhooks is the first result")
        XCTAssertTrue(results.staticTexts["Go To"].exists)
        shot("more-search-results")
        webhooks.tap()
        XCTAssertTrue(app.navigationBars["Webhooks"].waitForExistence(timeout: 10), "the result opens its page")
        back()
        XCTAssertTrue(webhooks.waitForExistence(timeout: 8), "Back shows the same results")
        XCTAssertEqual(field.value as? String, "web", "the query stayed")

        // An action: Restart Gateway jumps to Status & Maintenance, where the confirmation lives.
        type("rest")
        let restart = result("actions.restart-gateway")
        XCTAssertTrue(restart.waitForExistence(timeout: 5), "Actions offers Restart Gateway")
        restart.tap()
        XCTAssertTrue(app.navigationBars["Status & Maintenance"].waitForExistence(timeout: 10))
        XCTAssertTrue(try rpc("gateway.restart").isEmpty && (try rest("POST", "/api/gateway/restart")).isEmpty, "nothing restarts without the confirmation")
        back()
        XCTAssertTrue(restart.waitForExistence(timeout: 8))

        // A bot's name opens its chat.
        type("research")
        let bot = result("bots.research")
        XCTAssertTrue(bot.waitForExistence(timeout: 5), "Bots finds Research")
        bot.tap()
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 10), "the bot's chat opens")
        back()
        XCTAssertTrue(bot.waitForExistence(timeout: 8))

        // A setting's name opens its page.
        type("licenses")
        let miss = app.descendants(matching: .any)["more.results.miss"]
        type("about")
        let setting = results.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'more.result.settings.'")).firstMatch
        XCTAssertTrue(setting.waitForExistence(timeout: 5), "Settings finds About")
        XCTAssertFalse(miss.exists)
        setting.tap()
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 10), "the setting's page opens")
        back()                                   // Settings
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 8))
        back()                                   // More, with its results
        XCTAssertTrue(setting.waitForExistence(timeout: 8))

        // Nothing matches: the system's search miss.
        type("zzqqxx")
        XCTAssertTrue(miss.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No Results for “zzqqxx”"].exists)
        shot("more-search-miss")

        // Cancel returns More.
        cancel.tap()
        XCTAssertTrue(waitUntil(8) { !self.results.exists || !self.results.isHittable }, "the results go")
        XCTAssertTrue(app.cells["more-row-settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["more.search"].waitForExistence(timeout: 5))
        XCTAssertFalse(field.exists, "the field folded")
    }

    /// Return opens the first result; a tab result selects that tab; Sessions show six and offer the rest.
    @MainActor func testU17_ReturnTabsAndSessions() throws {
        launchSignedIn()
        openSearch()
        type("job")
        XCTAssertTrue(results.waitForExistence(timeout: 5))
        XCTAssertTrue(firstResult.waitForExistence(timeout: 5))
        XCTAssertTrue(firstResult.identifier.hasPrefix("more.result.goTo.tab-"), "the Jobs tab is first")
        app.typeText("\n")
        XCTAssertTrue(waitUntil(8) { self.app.tabBars.buttons["Jobs"].isSelected }, "Return opened the first result: the Jobs tab")
        tab("More")
        XCTAssertTrue(results.waitForExistence(timeout: 8), "More kept its results")

        // Rapid typing and clearing never leaves a stale list.
        for word in ["a", "ab", "", "we", "web", "", "se"] {
            type(word)
        }
        XCTAssertTrue(waitUntil(5) { self.results.cells.count > 0 })
        type("")
        XCTAssertTrue(waitUntil(5) { !self.results.exists || !self.results.isHittable }, "an emptied field brings More back")
        XCTAssertTrue(app.cells["more-row-settings"].exists)

        // Read-only: no write actions are offered.
        _ = relaunch(["-HQPagesReadOnly", "YES"])
        openSearch()
        type("new")
        XCTAssertFalse(result("actions.new-chat").waitForExistence(timeout: 3), "a read-only gateway offers no New Chat")
        XCTAssertFalse(result("actions.new-bot").exists)
        type("rest")
        XCTAssertFalse(result("actions.restart-gateway").waitForExistence(timeout: 2))
    }
}
