// [botslist] The m9 Bots-list rows end to end (docs/spec/3x-botslist.md), against the Bots-list fixture
// (scripts/fixtures/botslist-gateway.py: the settings fixture plus "fail:" and "drop:" turns). An extension of
// SettingsEndToEndTests so the sign-in and helpers are the settings suite's own. Run with
//   scripts/e2e-botslist.sh <SIM>            (HQN_E2E_ONLY="testL05_SwipePeekPlaysOnce" for one)

import XCTest

extension SettingsEndToEndTests {
    private func needsBotsListFixture() throws {
        guard ProcessInfo.processInfo.environment["HQN_BOTSLIST"] == "1" else {
            throw XCTSkip("Run scripts/e2e-botslist.sh (the Bots-list fixture answers \"fail:\" and \"drop:\" turns).")
        }
    }

    @MainActor private func says(_ app: XCUIApplication, _ words: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    }

    @MainActor private func openChat(_ app: XCUIApplication, _ id: String) {
        let row = app.cells["bot-row-\(id)"].exists ? app.cells["bot-row-\(id)"] : app.cells["bot-tile-\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(appears(app.tables["chat.table"], app, "open-\(id)", timeout: 15), "\(id)'s chat opens")
    }

    @MainActor private func send(_ app: XCUIApplication, _ text: String, send: Bool = true) {
        let field = app.textViews["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText(text)
        if send {
            let button = app.buttons["composer.send"]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            button.tap()
        }
    }

    @MainActor private func backToBots(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        for _ in 0..<3 where !app.cells["bot-row-research"].isHittable {
            if back.exists { back.tap() }
            _ = app.cells["bot-row-research"].waitForExistence(timeout: 3)
        }
    }

    // MARK: - L152 Delete a section: asked on the section's ⋯, Cancel keeps it

    @MainActor func testL03_DeleteSectionAsksAndCancelKeeps() throws {
        let app = launchSignedIn()
        // [bots-hold-only] The section's menu is a hold on its header (no ⋯, owner 2026-11-04).
        pressMenu(app, app.cells["section-header-Work"], "Delete Section")
        let question = says(app, "Its 2 bots move to Unassigned.")
        XCTAssertTrue(appears(question, app, "delete-section-question"), "it asks, saying where the bots go")
        XCTAssertTrue(says(app, "Delete “Work”?").exists, "named for the section")
        XCTAssertFalse(app.alerts.firstMatch.exists, "an anchored sheet, not a centred alert")
        shot(app, "L152-delete-section-sheet")
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists, cancel.isHittable { cancel.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap() }
        XCTAssertTrue(waitUntil(timeout: 4) { !question.exists }, "the question goes")
        XCTAssertTrue(app.cells["section-header-Work"].exists, "Work stays")
        XCTAssertEqual(a.writes("profiles.configure").count, 0, "nothing was written")
        XCTAssertFalse(app.otherElements["undo-pill"].exists, "and no Undo pill")
    }

    // MARK: - Owner 2026-10-30: rows ran through the clear bar's title and buttons

    @MainActor func testL18_BarBackingComesInWhenRowsScrollUnder() throws {
        for desktop in [false, true] {
            // Run with HQN_FIXTURE_EXTRA_BOTS=8 so the list is long enough to stay where the drag leaves it.
            let app = launchSignedIn(desktop ? ["-hqn.theme.desktopLook", "<true/>"] : [])
            XCTAssertTrue(app.cells["bot-row-ivy"].waitForExistence(timeout: 20), "signed in")
            let look = desktop ? "desktop" : "ios"
            shot(app, "L18-bar-rest-\(look)")
            let list = app.collectionViews["bots.list"]
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            start.press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
            Thread.sleep(forTimeInterval: 1.5)
            shot(app, "L18-bar-scrolled-\(look)")
            app.terminate()
        }
    }

    // MARK: - L161 The one-time swipe peek

    @MainActor func testL05_SwipePeekPlaysOnce() throws {
        let app = launchSignedIn(["-HQDebugResetSwipePeek", "YES", "-HQDebugPeekHold", "20"])
        let peek = app.otherElements["bots.peek"]
        XCTAssertTrue(appears(peek, app, "bots-peek", timeout: 20), "the first row peeks its trailing action")
        Thread.sleep(forTimeInterval: 2.5)                                  // past any redraw of the row
        shot(app, "L161-bots-peek")
        // A touch on the list ends it at once.
        app.collectionViews["bots.list"].swipeUp()
        XCTAssertTrue(waitUntil(timeout: 6) { !peek.exists }, "a scroll puts the row back")
        app.terminate()
        app.launchArguments = ["-HQDebugNoDrag", "YES", "-HQDebugPeekHold", "6"] + appearanceArguments
        app.launch()
        XCTAssertTrue(app.cells["bot-row-ivy"].waitForExistence(timeout: 20), "signed in still")
        XCTAssertFalse(app.descendants(matching: .any)["bots.peek"].waitForExistence(timeout: 5), "only once per install")
    }

    // MARK: - L173 A tap on the hold menu's lifted row opens the chat

    @MainActor func testL06_TapOnTheLiftedRowOpensItsChat() throws {
        let app = launchSignedIn()
        let row = app.cells["bot-row-ivy"]
        let place = row.frame
        var info = app.buttons["Bot Info"].firstMatch
        for _ in 0..<3 {
            row.press(forDuration: 1.0)
            info = app.buttons["Bot Info"].firstMatch
            if info.waitForExistence(timeout: 3) { break }
        }
        XCTAssertTrue(info.exists, "the hold menu shows")
        Thread.sleep(forTimeInterval: 0.8)
        // The lifted row is UIKit's "Preview" platter: a tall menu (the bot's name over Talk, Memo and Pin) moves it up
        // from the row's place, so the tap goes to where it is drawn (the cell inside it still reports the old frame).
        let preview = app.otherElements["Preview"]
        if preview.exists {
            preview.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: place.midX, dy: place.midY)).tap()
        }
        XCTAssertTrue(appears(app.tables["chat.table"], app, "L173-preview-tap", timeout: 10), "the tap opens Ivy's chat")
        XCTAssertTrue(app.navigationBars.staticTexts["Ivy"].exists || says(app, "Ivy").exists)
        XCTAssertFalse(app.buttons["Bot Info"].firstMatch.isHittable && app.buttons["Pin"].firstMatch.exists, "and the menu is gone")
        shot(app, "L173-chat-after-preview-tap")
    }

    // MARK: - L174 A pick from search closes the search

    @MainActor func testL07_PickFromSearchClosesTheSearch() throws {
        let app = launchSignedIn()
        let magnifier = searchButton(app)
        XCTAssertTrue(magnifier.waitForExistence(timeout: 5))
        magnifier.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("Research")
        XCTAssertTrue(waitUntil(timeout: 5) { !app.cells["bot-row-ivy"].exists && app.cells["bot-row-research"].exists }, "the search narrows")
        app.cells["bot-row-research"].tap()
        XCTAssertTrue(appears(app.tables["chat.table"], app, "L174-pick", timeout: 15), "the pick opens the chat")
        let back = app.navigationBars.buttons.element(boundBy: 0)
        back.tap()
        XCTAssertTrue(appears(app.cells["bot-row-ivy"], app, "L174-back", timeout: 8), "back on the whole list")
        XCTAssertFalse(app.searchFields.firstMatch.exists, "the search closed with the pick")
        shot(app, "L174-list-after-pick")
    }

    // MARK: - L185 A standing failure in orange; L189 Not Delivered ahead of Draft

    @MainActor func testL09_StandingFailureShowsOnTheRowUntilAGoodTurn() throws {
        try needsBotsListFixture()
        let app = launchSignedIn()
        openChat(app, "ivy")
        send(app, "fail:429 Too Many Requests")
        Thread.sleep(forTimeInterval: 2.5)
        backToBots(app)
        XCTAssertFalse(says(app, "Sign in again for this bot").exists || says(app, "Quota or balance exhausted").exists,
                       "a passing failure says nothing on the row")
        openChat(app, "ivy")
        send(app, "fail:401 Unauthorized")
        Thread.sleep(forTimeInterval: 2.5)
        backToBots(app)
        let line = says(app, "Ivy. Sign in again for this bot")
        XCTAssertTrue(appears(line, app, "L185-attention", timeout: 8), "the row names the standing problem")
        shot(app, "L185-standing-failure")
        openChat(app, "ivy")
        send(app, "hello again")
        XCTAssertTrue(says(app, "Hi! I'm Ivy.").waitForExistence(timeout: 15), "the bot answers")
        backToBots(app)
        XCTAssertTrue(waitUntil(timeout: 8) { !line.exists }, "a good turn clears it")
    }

    @MainActor func testL10_NotDeliveredComesBeforeDraft() throws {
        try needsBotsListFixture()
        let app = launchSignedIn()
        openChat(app, "research")
        send(app, "drop: Order the cedar boards")
        let mark = app.tables["chat.table"].descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Delivery Unconfirmed' OR label CONTAINS 'Not Delivered'")).firstMatch
        XCTAssertTrue(appears(mark, app, "L189-mark", timeout: 60), "the send is marked once the app is back on the gateway")
        send(app, "and nails", send: false)                                // a draft as well
        let back = app.navigationBars.buttons.element(boundBy: 0)
        back.tap()
        let line = says(app, "Not Delivered: drop: Order the cedar boards")
        XCTAssertTrue(appears(line, app, "L189-row", timeout: 10), "the row says Not Delivered, ahead of the draft")
        XCTAssertFalse(says(app, "Draft: and nails").exists)
        shot(app, "L189-not-delivered")
    }

    // MARK: - L147 A desktop pin is filed under Pinned

    @MainActor func testL02_DesktopPinIsFiledUnderPinned() throws {
        let app = launchSignedIn()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(a.writes("profiles.configure").count, 0, "a roster that agrees writes nothing")
        // Desktop "Pin to top": only the flag changes; the bot still sits in Work.
        try a.control("/__settings/desktop-edit", ["profile": "ivy", "key": "hermes-bots",
                                                    "value": ["sectionId": "sec-work", "sectionName": "Work", "created": 1790000000001, "pinned": true]])
        let list = app.collectionViews["bots.list"]
        let filed = waitUntil(timeout: 90) {
            if same(self.a.botsMeta("ivy")["sectionId"], "hermes-hq-pinned") { return true }
            list.swipeDown()                                                // pull to refresh: the next full roster
            Thread.sleep(forTimeInterval: 3)
            return false
        }
        XCTAssertTrue(filed, "the phone files it under Pinned: \(a.botsMeta("ivy"))")
        let meta = a.botsMeta("ivy")
        XCTAssertTrue(same(meta["sectionName"], "Pinned") && same(meta["pinned"], true))
        XCTAssertTrue(same((meta["pinnedFrom"] as? [String: Any])?["id"], "sec-work") && same((meta["pinnedFrom"] as? [String: Any])?["name"], "Work"),
                      "its section is kept as the home to go back to")
        XCTAssertTrue(app.cells["bot-tile-ivy"].waitForExistence(timeout: 10), "and it is a tile")
        list.swipeDown()
        Thread.sleep(forTimeInterval: 4)
        XCTAssertEqual(a.writes("profiles.configure").count, 1, "one write, not one per roster")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        shot(app, "L147-desktop-pin")
    }

    // MARK: - L213 Bot Info's header

    @MainActor func testL13_BotInfoHeaderSaysWhenTheBotWasActive() throws {
        let app = launchSignedIn()
        openBotInfo(app, "ivy")
        let status = app.descendants(matching: .any)["bot-info.status"]
        XCTAssertTrue(appears(status, app, "L213-status"), "the status line")
        XCTAssertTrue(status.label.hasPrefix("Active 2 hr ago") || says(app, "Active 2 hr ago").exists, "last active two hours ago (\(status.label))")
        XCTAssertTrue(app.staticTexts["bot-info.name"].exists)
        shot(app, "L213-bot-info-header")
    }

    // MARK: - n20 revisit: Bot Info's Brain reads Instructions, not the developer's SOUL.md

    @MainActor func testL14_BotInfoInstructionsRow() throws { try instructionsRound(desktop: false) }

    @MainActor func testL14b_BotInfoInstructionsRowInTheDesktopLook() throws { try instructionsRound(desktop: true) }

    /// Extra Large text, both looks (the screenshots are the check: nothing wraps over the chevron or clips).
    @MainActor func testL14c_BotInfoInstructionsRowAtExtraLargeText() throws {
        try instructionsRound(desktop: false, text: "UICTContentSizeCategoryXL")
        try instructionsRound(desktop: true, text: "UICTContentSizeCategoryXL")
    }

    @MainActor func instructionsRound(desktop: Bool, text: String? = nil) throws {
        let look = (desktop ? "desktop" : "standard") + (text == nil ? "" : "-xl")
        // Both ways, always: `-HQDebugDesktopLook` is saved, so a Desktop Look round would otherwise carry into the next.
        let app = launchSignedIn(["-HQDebugDesktopLook", desktop ? "YES" : "NO"] + (text.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? []))
        openBotInfo(app, "ivy")
        app.botInfoTab("Brain")   // [page-tabs]
        let row = app.buttons["bot-info.soul"]
        let list = app.collectionViews["bot-info.list"]
        for _ in 0..<6 where !row.isHittable { list.swipeUp() }   // Brain sits low on the sheet (PresenceStressTests' own pattern)
        XCTAssertTrue(appears(row, app, "L14-instructions-row-\(look)"), "the row is there (not hidden for a missing context)")
        XCTAssertTrue(row.label.contains("Instructions"), "plain words (\(row.label))")
        XCTAssertFalse(row.label.localizedCaseInsensitiveContains("soul"), "not the developer's SOUL.md (\(row.label))")
        let footer = says(app, "What Ivy is told about who it is and how to work.")
        for _ in 0..<4 where !footer.exists { list.swipeUp() }
        XCTAssertTrue(appears(footer, app, "L14-instructions-footer-\(look)"), "the footer names the bot")
        shot(app, "L14-bot-info-instructions-row-\(look)")
        row.tap()
        XCTAssertTrue(app.navigationBars["Instructions"].waitForExistence(timeout: 10), "the editor opens, titled Instructions")
        XCTAssertTrue(app.textViews["soul.text"].waitForExistence(timeout: 10), "the text loads")
        XCTAssertFalse(says(app, "SOUL.md").exists, "no developer word on screen")
        shot(app, "L14-bot-info-instructions-page-\(look)")
    }

    // MARK: - L227 A bot opens although the Bots page was never shown

    @MainActor func testL15_OpensABotBeforeTheBotsPageWasShown() throws {
        let app = launchSignedIn()
        app.terminate()
        app.launchArguments = ["-HQDebugNoDrag", "YES", "-HQDebugSessionsTab", "YES", "-HQDebugOpenBot", "research"] + appearanceArguments
        app.launch()
        XCTAssertTrue(appears(app.tables["chat.table"], app, "L227-open", timeout: 30), "Research's chat opens from the Sessions tab")
        XCTAssertTrue(says(app, "Three papers to read.").waitForExistence(timeout: 10), "its own chat")
        shot(app, "L227-opened-without-bots-page")
    }

    // MARK: - L237 The Undo pill

    @MainActor func testL16_UndoPillNamesItselfAndGoes() throws {
        let app = launchSignedIn(["-HQDebugUndoSeconds", "10"])
        pressMenu(app, app.cells["bot-row-research"], "More")
        tapMenu(app, "Hide from Bots")
        let pill = app.otherElements["undo-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 8), "the Undo pill")
        let undo = app.buttons["undo-pill.undo"]
        XCTAssertTrue(undo.label.hasSuffix("Undo") && undo.label.count > "Undo".count, "the button says what it undoes (\(undo.label))")
        XCTAssertFalse(undo.label.contains("Dispatch"))
        shot(app, "L237-undo-pill")
        XCTAssertTrue(waitUntil(timeout: 25) { !pill.exists }, "it leaves on its own")
        XCTAssertTrue(same(a.botsMeta("research")["hidden"], true), "and the change stays")
    }

    /// In the Desktop Look the system tab bar is hidden: the pill sits above the docked bar, not over its tabs.
    @MainActor func testL16b_UndoPillClearsTheDockedBar() throws {
        let app = launchSignedIn(["-HQDebugUndoSeconds", "10", "-hqn.theme.desktopLook", "<true/>"])
        let bar = app.otherElements["desktop-tab-bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "the docked bar")
        // The docked bar has a More tab of its own: the menu's More is the other one (a tap on the tab closes the menu).
        let row = app.cells["bot-row-research"], more = app.buttons.matching(NSPredicate(
            format: "label == 'More' AND NOT (identifier IN %@)", ["tab-more", "ellipsis", "ellipsis.circle.fill"])).firstMatch
        for _ in 0..<3 where !more.exists {
            row.press(forDuration: 1.0)
            _ = more.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(more.exists, "the row's menu")
        more.tap()
        tapMenu(app, "Hide from Bots")
        let pill = app.otherElements["undo-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 8), "the Undo pill")
        XCTAssertLessThanOrEqual(pill.frame.maxY, bar.frame.minY + 1, "above the docked bar (\(pill.frame), \(bar.frame))")
        shot(app, "L237-undo-pill-desktop")
        XCTAssertTrue(waitUntil(timeout: 25) { !pill.exists }, "it leaves on its own")
    }

    // MARK: - L128 / L240 The switcher's spoken label; switching from the title

    @MainActor func testL17_SwitcherLabelAndGatewaySwitch() throws {
        guard ProcessInfo.processInfo.environment["HQN_SETTINGS_CONFIG"] != "C" else { throw XCTSkip("config B only") }
        let b = try SettingsFixture.load("HQN_SETTINGS_B")
        try b.control("/__settings/reset", [:])
        let app = launchSignedIn()
        // One gateway: the switcher is not a button yet; nothing to read twice.
        openSettings(app)
        app.buttons["settings.gateway-card"].tap()
        XCTAssertTrue(app.buttons["gateway.add"].waitForExistence(timeout: 5))
        app.buttons["gateway.add"].tap()
        signIn(app, b)
        XCTAssertTrue(waitUntil(timeout: 15) { app.descendants(matching: .any)["gateway-row-\(b.hostPort)"].exists }, "two gateways")
        app.navigationBars["Gateways"].buttons.element(boundBy: 0).tap()
        closeSettings(app)
        XCTAssertTrue(says(app, "Beta Ivy").waitForExistence(timeout: 15), "on Beta now")

        let switcher = app.buttons["gateway-switcher"].firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 8))
        XCTAssertTrue(switcher.label.hasPrefix("On "), "the switcher says where you are (\(switcher.label))")
        XCTAssertFalse(switcher.label.hasPrefix("Bots"), "the page name is the title's own, never read twice")
        try a.control("/__settings/bump", ["profile": "ivy"])
        openTitleMenu(app)                                                 // opening the menu checks the other gateways
        XCTAssertTrue(appears(app.buttons["gateway-menu-\(a.hostPort)"].firstMatch, app, "L128-menu"))
        _ = says(app, "1 New").waitForExistence(timeout: 10)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        XCTAssertTrue(waitUntil(timeout: 10) { switcher.label.contains("1 new on other gateways") }, "and what is new elsewhere (\(switcher.label))")
        shot(app, "L128-switcher")

        // L240 [filters-only]: Filter holds filters only (owner 2026-11-03), no Switch Gateway; the title's switcher lists
        // both gateways, the one in use checked, and a filter set in Filter is still on after a switch made there.
        let filter = app.buttons["bots.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5), "Filter")
        let activity = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Activity'")).firstMatch
        for _ in 0..<3 where !activity.exists { filter.tap(); _ = activity.waitForExistence(timeout: 2) }
        XCTAssertTrue(activity.exists, "Activity ›")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Switch Gateway'")).firstMatch.exists,
                       "no gateways in Filter")
        shot(app, "L240-filter-no-gateway")
        activity.tap()
        tapMenu(app, "Recently Active")
        let token = app.buttons["page.filter-token"]
        XCTAssertTrue(appears(token, app, "L240-token"))
        openTitleMenu(app)
        let other = app.buttons["gateway-menu-\(a.hostPort)"].firstMatch
        XCTAssertTrue(appears(other, app, "L240-gateways"), "the title lists the other gateway")
        XCTAssertTrue(app.buttons["gateway-menu-\(b.hostPort)"].firstMatch.exists, "and the one in use")
        XCTAssertTrue(app.buttons["Manage Gateways…"].firstMatch.exists, "and Manage Gateways…")
        XCTAssertFalse(says(app, "All Gateways").exists, "no All Gateways: a list shows one gateway")
        shot(app, "L240-title-gateways")
        other.tap()
        XCTAssertTrue(waitUntil(timeout: 20) { !self.says(app, "Beta Ivy").exists && app.cells["bot-row-ivy"].exists }, "switched")
        XCTAssertTrue(token.waitForExistence(timeout: 5) && token.label.contains("Recently Active"), "the filter came along")
        XCTAssertTrue(waitUntil(timeout: 10) { switcher.exists && switcher.label.hasPrefix("On ") })
        shot(app, "L240-after-switch")
    }

    // MARK: - [filters-only] Filter with one bot and one gateway

    /// [filters-only] Owner 2026-11-03: Filter is on the bar whatever the list, so Sort By › Manual is there with one bot
    /// on one gateway too (it used to wait for 8 bots, a second gateway or a hidden bot); its menu holds no gateways.
    @MainActor func testL19_FilterIsThereWithOneBot() throws {
        try a.control("/__settings/only", ["profiles": ["default"]])
        try a.control("/__settings/desktop-edit", ["profile": "default", "key": "hermes-bots", "value": [String: Any]()])   // a row, not a tile
        let app = launchSignedIn(row: "default")
        XCTAssertFalse(app.cells["bot-row-ivy"].exists, "one bot")
        XCTAssertFalse(app.buttons["gateway-switcher"].exists, "one gateway: no switcher")
        shot(app, "L19-one-bot-bar")
        let filter = app.buttons["bots.filter"]
        XCTAssertTrue(appears(filter, app, "L19-filter"), "Filter is on the bar")
        let sortBy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sort By'")).firstMatch
        for _ in 0..<3 where !sortBy.exists { filter.tap(); _ = sortBy.waitForExistence(timeout: 2) }
        XCTAssertTrue(sortBy.exists, "Sort By ›")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Activity'")).firstMatch.exists, "Activity ›")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Switch Gateway'")).firstMatch.exists,
                       "no gateways in Filter")
        shot(app, "L19-one-bot-filter-menu")
        sortBy.tap()
        tapMenu(app, "Manual")
        XCTAssertTrue(filter.waitForExistence(timeout: 3), "Filter stays")
        for _ in 0..<3 where !sortBy.exists { filter.tap(); _ = sortBy.waitForExistence(timeout: 2) }
        XCTAssertTrue(sortBy.label.contains("Manual"), "Sort By says Manual (\(sortBy.label))")
        shot(app, "L19-one-bot-sort-manual")
    }
}

// MARK: - [bots-hold-only] A section's menu is a hold

extension SettingsEndToEndTests {
    /// [bots-hold-only] Owner 2026-11-04: no ⋯ on a Bots section's header ("we decided to keep it very simple, where
    /// you just hold to see the extra stuff"; it reverses build 742's ⋯ there). A hold on the header opens its menu
    /// (Rename…, Move Up, Move Down, Delete Section), and a tap on it still folds the section. Both looks.
    @MainActor func testL20_SectionMenuIsAHoldWithNoButton() throws {
        let app = launchSignedIn()
        for look in ["ios", "desktop"] {
            if look == "desktop" {
                app.terminate()
                app.launchArguments = ["-HQDebugNoDrag", "YES"] + appearanceArguments + ["-HQDebugDesktopLook", "YES"]
                app.launch()
                XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 20), "signed in still (\(look))")
            }
            let header = app.cells["section-header-Work"]
            XCTAssertTrue(header.waitForExistence(timeout: 10), "Work's header (\(look))")
            Thread.sleep(forTimeInterval: 1)
            shot(app, "L20-section-header-\(look)")
            XCTAssertFalse(app.buttons["section-menu-Work"].exists, "no ⋯ on the header (\(look))")
            for _ in 0..<3 where !app.buttons["Delete Section"].firstMatch.exists {
                header.press(forDuration: 1.0)
                _ = app.buttons["Delete Section"].firstMatch.waitForExistence(timeout: 3)
            }
            for item in ["Rename…", "Move Up", "Move Down", "Delete Section"] {
                XCTAssertTrue(app.buttons[item].firstMatch.exists, "\(item) in the hold menu (\(look))")
            }
            shot(app, "L20-section-hold-menu-\(look)")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.75)).tap()   // the menu goes with a tap off it
            XCTAssertTrue(waitUntil(timeout: 4) { !app.buttons["Delete Section"].exists }, "the menu closes (\(look))")
            if look == "ios" {
                // A tap on the name still folds the section, and again opens it.
                let ivy = app.cells["bot-row-ivy"]
                XCTAssertTrue(ivy.exists, "Ivy is under Work")
                header.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.6)).tap()
                XCTAssertTrue(waitUntil(timeout: 5) { !ivy.exists }, "the name's tap folds Work")
                XCTAssertFalse(app.buttons["Delete Section"].exists, "and opens no menu")
                header.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.6)).tap()
                XCTAssertTrue(ivy.waitForExistence(timeout: 5), "and opens it again")
            }
        }
        app.terminate()
    }
}
