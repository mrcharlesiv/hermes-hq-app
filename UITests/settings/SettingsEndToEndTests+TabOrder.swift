// [taborder] Settings › Appearance › Tabs end to end against the settings fixture: Sessions dragged above Bots moves it
// in the bar at once, the order is kept across a relaunch, and Use Default Tabs puts it back. [customtabs] Bots and Jobs
// hidden, Capabilities added as a tab: Jobs moves into More, Capabilities leaves it, and a bot's chat opens on Sessions.
// [kanban-tab-one] S41: the one Kanban Tab picker is on this page (owner 2026-11-03: one home per page).
// Run with
//   HQN_E2E_ONLY="testS39_TabOrderPutsSessionsFirst,testS40_TabsHideBotsAndAddAPage,testS41_KanbanTabLivesOnTabs" scripts/e2e-settings.sh <SIM>

import XCTest

extension SettingsEndToEndTests {
    /// The tab bar's buttons left to right, by title.
    @MainActor func tabTitles(_ app: XCUIApplication) -> [String] {
        app.tabBars.buttons.allElementsBoundByIndex.filter(\.exists)
            .sorted { $0.frame.minX < $1.frame.minX }
            .map(\.label)
    }

    @MainActor func openTabOrder(_ app: XCUIApplication) {
        openSettings(app)
        let row = app.buttons["settings.tab-order"]
        m9ScrollTo(row, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Settings lists Tab Order")
        row.tap()
        XCTAssertTrue(app.navigationBars["Tabs"].waitForExistence(timeout: 5), "the Tabs page opens")
    }

    /// Flips a Settings › Tabs switch (the switch itself, at the row's trailing end).
    @MainActor func flipTab(_ toggle: XCUIElement, in app: XCUIApplication) {
        m9ScrollTo(toggle, in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "\(toggle) is listed")
        let inner = toggle.switches.firstMatch   // the control inside the row's element (not its label or handle)
        (inner.exists ? inner : toggle).tap()
    }

    @MainActor func testS39_TabOrderPutsSessionsFirst() throws {
        guard ProcessInfo.processInfo.environment["HQN_UI_DESKTOPLOOK"] != "1" else { throw XCTSkip("reads the system tab bar") }
        var app = launchSignedIn(["-HQDebugResetTabs", "YES"])
        openTabOrder(app)
        XCTAssertTrue(waitUntil(timeout: 3) { self.tabTitles(app).first == "Bots" }, "Bots leads by default: \(tabTitles(app))")
        let start = tabTitles(app)
        shot(app, "tab-order-default")

        // Sessions' handle dragged above Bots.
        let sessionsHandle = app.buttons["Reorder Sessions"]
        let botsRow = app.buttons["Reorder Bots"]
        XCTAssertTrue(sessionsHandle.waitForExistence(timeout: 5), "each tab has a drag handle")
        XCTAssertTrue(botsRow.exists)
        let from = sessionsHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = botsRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        // A drag the simulator drops is made again once (the list then shows the same order).
        for _ in 0..<2 where tabTitles(app).first != "Sessions" {
            from.press(forDuration: 1.0, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.5)
            _ = waitUntil(timeout: 2) { self.tabTitles(app).first == "Sessions" }
        }
        XCTAssertTrue(waitUntil(timeout: 3) { self.tabTitles(app).first == "Sessions" },
                      "the bar moved at once: \(tabTitles(app))")
        var expected = start
        expected.swapAt(0, 1)
        XCTAssertEqual(tabTitles(app), expected, "only Sessions and Bots swapped; More stays last")
        let reset = app.buttons["tab-order.default"]
        m9ScrollTo(reset, in: app)   // under the pages that can be added
        XCTAssertTrue(reset.waitForExistence(timeout: 3), "Use Default Tabs shows once moved")
        shot(app, "tab-order-sessions-first")

        // Both moved tabs still open their own lists.
        app.tabBars.buttons["Bots"].tap()
        XCTAssertTrue(app.cells["bot-row-ivy"].waitForExistence(timeout: 5), "Bots opens the Bots list")
        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 5), "Sessions opens the Sessions list")
        shot(app, "tab-order-sessions-tab")

        // Kept across a relaunch (the saved sign-in, no reset); the tab last shown reopens wherever it now sits.
        Thread.sleep(forTimeInterval: 0.5)
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = appearanceArguments + ["-HQDebugNoDrag", "YES"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Sessions"].waitForExistence(timeout: 20))
        XCTAssertEqual(tabTitles(app), expected, "the order is kept across a relaunch")
        XCTAssertTrue(waitUntil(timeout: 5) { app.tabBars.buttons["Sessions"].isSelected }, "the relaunch reopens Sessions")

        // Use Default Tabs puts Bots back first.
        openTabOrder(app)
        m9ScrollTo(app.buttons["tab-order.default"], in: app)
        app.buttons["tab-order.default"].tap()
        XCTAssertTrue(waitUntil(timeout: 3) { self.tabTitles(app) == start }, "the default order again: \(tabTitles(app))")
        XCTAssertFalse(app.buttons["tab-order.default"].exists, "nothing to reset")
    }

    @MainActor func testS40_TabsHideBotsAndAddAPage() throws {
        guard ProcessInfo.processInfo.environment["HQN_UI_DESKTOPLOOK"] != "1" else { throw XCTSkip("reads the system tab bar") }
        var app = launchSignedIn(["-HQDebugResetTabs", "YES"])
        openTabOrder(app)
        XCTAssertTrue(waitUntil(timeout: 3) { self.tabTitles(app).first == "Bots" }, "the default tabs: \(tabTitles(app))")
        let start = tabTitles(app)
        let workspace = start[3]
        shot(app, "tabs-default")

        // Bots off: Sessions leads, and can't be turned off now.
        flipTab(app.switches["tab-order.bots"], in: app)
        XCTAssertTrue(waitUntil(timeout: 3) { !self.tabTitles(app).contains("Bots") }, "Bots left the bar: \(tabTitles(app))")
        XCTAssertEqual(tabTitles(app).first, "Sessions")
        XCTAssertFalse(app.switches["tab-order.sessions"].isEnabled, "Bots or Sessions always stays")
        XCTAssertTrue(app.switches["tab-order.bots"].waitForExistence(timeout: 3), "Bots is listed under Add a Tab")

        // Jobs off, Capabilities on as a tab of its own.
        flipTab(app.switches["tab-order.jobs"], in: app)
        XCTAssertTrue(waitUntil(timeout: 3) { !self.tabTitles(app).contains("Jobs") }, "Jobs left the bar: \(tabTitles(app))")
        flipTab(app.switches["tab-order.page.capabilities"], in: app)
        XCTAssertTrue(waitUntil(timeout: 5) { self.tabTitles(app) == ["Sessions", workspace, "Capabilities", "More"] },
                      "Capabilities is a tab before More: \(tabTitles(app))")
        shot(app, "tabs-custom")

        // The page tab opens its page; More now lists Jobs and not Capabilities.
        app.tabBars.buttons["Capabilities"].tap()
        XCTAssertTrue(app.navigationBars["Capabilities"].waitForExistence(timeout: 5), "the Capabilities tab shows its page")
        shot(app, "tabs-capabilities-tab")
        let more = app.tabBars.buttons["More"]
        more.tap()
        more.tap()   // back to More's list (the Tabs page was on its stack)
        XCTAssertTrue(app.cells["more-row-jobs"].waitForExistence(timeout: 5), "a hidden Jobs tab is a More row")
        XCTAssertFalse(app.cells["more-row-capabilities"].exists, "a page that is a tab leaves More")
        shot(app, "tabs-more")
        app.cells["more-row-jobs"].tap()
        XCTAssertTrue(app.navigationBars["Jobs"].waitForExistence(timeout: 5), "More opens Jobs")

        // Kept across a relaunch; a bot's chat (as a notification or Siri opens it) lands on Sessions, Back to its list.
        Thread.sleep(forTimeInterval: 0.5)
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = appearanceArguments + ["-HQDebugNoDrag", "YES", "-HQDebugOpenBot", "ivy"]
        app.launch()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 20), "the bot's chat opens with Bots hidden")
        shot(app, "tabs-bot-chat-on-sessions")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 5), "Back goes to the Sessions list")
        XCTAssertEqual(tabTitles(app), ["Sessions", workspace, "Capabilities", "More"], "kept across a relaunch")

        // Use Default Tabs: all four back, Capabilities in More again.
        openTabOrder(app)
        m9ScrollTo(app.buttons["tab-order.default"], in: app)
        app.buttons["tab-order.default"].tap()
        XCTAssertTrue(waitUntil(timeout: 3) { self.tabTitles(app) == start }, "the default tabs again: \(tabTitles(app))")
    }

    /// [kanban-tab-one] Settings › Appearance › Tabs › Kanban Tab › `choice` (the Menu over the row).
    @MainActor func chooseKanbanTab(_ choice: String, in app: XCUIApplication) {
        let picker = app.buttons["settings.kanban"]
        m9ScrollTo(picker, in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "the Kanban Tab picker")
        picker.tap()
        let option = app.buttons[choice].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 3), "Kanban Tab › \(choice)")
        option.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { (picker.value as? String) == choice }, "the picker says \(choice): \(String(describing: picker.value))")
    }

    /// [kanban-tab-one] Owner 2026-11-03 (one home per page): the Kanban Tab picker was on Settings › Bots & Tools and,
    /// as Tabs' own choice, here; now only here. Off and On change the bar at once and the footer says where Artifacts
    /// went; "artifacts tab" in Settings' search opens Tabs at the picker; the Settings root has no Kanban row.
    @MainActor func testS41_KanbanTabLivesOnTabs() throws {
        guard ProcessInfo.processInfo.environment["HQN_UI_DESKTOPLOOK"] != "1" else { throw XCTSkip("reads the system tab bar") }
        let app = launchSignedIn(["-HQDebugResetTabs", "YES"])

        // The Settings root, top to bottom: no Kanban Tab row (Bots & Tools holds Capabilities only).
        openSettings(app)
        let rootPicker = app.buttons["settings.kanban"]
        let about = app.buttons["settings.about"]
        XCTAssertTrue(app.buttons["settings.gateway-card"].waitForExistence(timeout: 5))
        for _ in 0..<12 where !(about.exists && about.isHittable) {
            XCTAssertFalse(rootPicker.exists, "no Kanban Tab row on the Settings root")
            app.swipeUp(velocity: .slow)
        }
        XCTAssertFalse(rootPicker.exists, "no Kanban Tab row on the Settings root")
        let botsAndTools = app.buttons["settings.capabilities"]
        if botsAndTools.exists { shot(app, "kanban-root-bots-and-tools") }

        // Tabs: the picker under the bar's tabs, at Automatic.
        openTabOrder(app)
        let picker = app.buttons["settings.kanban"]
        m9ScrollTo(picker, in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 8), "the Kanban Tab picker is on Tabs")
        XCTAssertEqual(picker.value as? String, "Automatic")
        let footer = app.staticTexts["tab-order.kanban-footer"]
        XCTAssertTrue(footer.waitForExistence(timeout: 3), "the picker's footer")
        shot(app, "kanban-tab-on-tabs")

        // Off: Artifacts has the tab, and the row above names it so.
        chooseKanbanTab("Off", in: app)
        XCTAssertTrue(waitUntil(timeout: 5) { self.tabTitles(app).contains("Artifacts") && !self.tabTitles(app).contains("Kanban") },
                      "Off: Artifacts has the tab: \(tabTitles(app))")
        XCTAssertTrue(waitUntil(timeout: 3) { footer.label.contains("Turn it on to add a Kanban tab in Artifacts’ place.") }, footer.label)
        XCTAssertTrue(app.switches["tab-order.workspace"].label.contains("Artifacts") || app.staticTexts["Artifacts"].exists,
                      "the Tab Bar row names the tab as the bar does")
        shot(app, "kanban-tab-off")

        // On: Kanban has it, and Artifacts is in More › Workspace.
        chooseKanbanTab("On", in: app)
        XCTAssertTrue(waitUntil(timeout: 5) { self.tabTitles(app).contains("Kanban") && !self.tabTitles(app).contains("Artifacts") },
                      "On: Kanban has the tab: \(tabTitles(app))")
        XCTAssertTrue(waitUntil(timeout: 3) { footer.label.hasSuffix("It’s the Kanban tab, and Artifacts is in More › Workspace.") }, footer.label)
        shot(app, "kanban-tab-on")

        // Back to Automatic.
        chooseKanbanTab("Automatic", in: app)
        XCTAssertTrue(waitUntil(timeout: 3) { footer.label.contains("Automatic") }, footer.label)

        // Search: "artifacts tab" finds Kanban Tab on Tabs and opens Tabs at it.
        app.navigationBars.buttons.element(boundBy: 0).tap()   // Back to Settings
        let magnifier = app.navigationBars.buttons["settings.search"]
        XCTAssertTrue(magnifier.waitForExistence(timeout: 5), "back on Settings")
        for words in ["artifacts tab", "kanban"] {
            if !app.searchFields["settings.search"].exists { magnifier.tap() }
            let search = app.searchFields["settings.search"]
            XCTAssertTrue(search.waitForExistence(timeout: 5), "the search field")
            search.tap()
            search.typeText(words)
            let result = app.buttons["settings.result.app:kanban"]
            XCTAssertTrue(result.waitForExistence(timeout: 5), "\(words) finds Kanban Tab")
            XCTAssertTrue(result.label.contains("Kanban Tab") && result.label.contains("Tabs"), "it says which page: \(result.label)")
            shot(app, "kanban-search-\(words.replacingOccurrences(of: " ", with: "-"))")
            result.tap()
            XCTAssertTrue(app.navigationBars["Tabs"].waitForExistence(timeout: 5), "\(words): the result opens Tabs")
            XCTAssertTrue(waitUntil(timeout: 3) { picker.exists && picker.isHittable }, "\(words): scrolled to the picker")
            shot(app, "kanban-search-landed")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(magnifier.waitForExistence(timeout: 5) || app.searchFields["settings.search"].waitForExistence(timeout: 3))
        }
    }
}
