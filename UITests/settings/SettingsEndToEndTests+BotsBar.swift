// The Bots page's bar and pinned tiles end to end, against the settings fixture: the trailing capsule (Filter, Search,
// and the + that makes bots, group chats and sections), the folding search, the filter menu, rearranging pinned tiles
// by drag (kept across a relaunch), and the long-press menu of a row and of a tile (screenshots: nothing may draw over
// the lifted preview). Run with
//   HQN_SETTINGS_PORTS="9900 9901 9902" HQN_E2E_ONLY="testBB1_…" scripts/e2e-settings.sh <SIM>

import XCTest

extension SettingsEndToEndTests {
    // MARK: - BB1 Long-press menus: the lifted row and tile sit over a blurred page

    @MainActor func testBB1_LongPressRowAndTileMenus() throws {
        for dark in [false, true] {
            let app = launchSignedIn((dark ? ["-hqn.appearance", "dark"] : ["-hqn.appearance", "light"]) + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXL"])
            let mode = dark ? "dark" : "light"
            let row = app.cells["bot-row-ivy"]
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            for _ in 0..<3 {
                row.press(forDuration: 1.0)
                if app.buttons["Bot Info"].firstMatch.waitForExistence(timeout: 3) { break }
            }
            XCTAssertTrue(app.buttons["Bot Info"].firstMatch.exists, "the row's menu shows")
            Thread.sleep(forTimeInterval: 0.8)
            shot(app, "bots-row-menu-\(mode)")
            // The page behind the menu is out of reach (blurred, dimmed): the tiles can't be hit through it.
            XCTAssertFalse(app.cells["bot-tile-default"].isHittable, "the tiles sit behind the menu's backdrop")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.95)).tap()
            XCTAssertTrue(waitUntil(timeout: 3) { !app.buttons["Bot Info"].firstMatch.exists }, "the menu closes")

            let tile = app.cells["bot-tile-default"]
            for _ in 0..<3 {
                tile.press(forDuration: 1.0)
                if app.buttons["Bot Info"].firstMatch.waitForExistence(timeout: 3) { break }
            }
            XCTAssertTrue(app.buttons["Bot Info"].firstMatch.exists, "the tile's menu shows")
            Thread.sleep(forTimeInterval: 0.8)
            shot(app, "bots-tile-menu-\(mode)")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.95)).tap()
            XCTAssertTrue(waitUntil(timeout: 3) { !app.buttons["Bot Info"].firstMatch.exists })
            app.terminate()
        }
    }

    // MARK: - BB2 The capsule: Search unfolds, filters, keeps its query across tabs, folds away

    @MainActor func searchButton(_ app: XCUIApplication) -> XCUIElement {
        let byID = app.buttons["bots.search"]
        return byID.exists ? byID : app.navigationBars.buttons["Search"].firstMatch
    }

    @MainActor func testBB2_SearchBehindTheMagnifier() throws {
        let app = launchSignedIn()
        XCTAssertFalse(app.searchFields.firstMatch.exists, "no search field until the magnifier opens it")
        XCTAssertFalse(app.buttons["bots.settings"].exists, "Settings lives in More")
        let magnifier = searchButton(app)
        XCTAssertTrue(magnifier.waitForExistence(timeout: 5), "the magnifier")
        XCTAssertTrue(app.buttons["bots.compose"].exists, "the + beside it")   // [bots-plus] its id stays "compose"
        shot(app, "bots-bar-capsule")
        magnifier.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3), "the field unfolds")
        field.typeText("ivy")
        XCTAssertTrue(waitUntil(timeout: 3) { !app.cells["bot-row-research"].exists }, "typing filters")
        XCTAssertTrue(app.cells["bot-row-ivy"].exists)
        shot(app, "bots-search-typed")

        // Another tab and back: the query stays.
        app.tabBars.buttons["Sessions"].tap()
        Thread.sleep(forTimeInterval: 0.8)
        app.tabBars.buttons["Bots"].tap()
        XCTAssertTrue(waitUntil(timeout: 3) { app.cells["bot-row-ivy"].exists && !app.cells["bot-row-research"].exists },
                      "still searching after a tab change")
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "ivy")

        // Cancel folds it away and the whole list is back.
        let field2 = app.searchFields.firstMatch
        if !field2.hasFocus { field2.tap() }
        let cancel = [app.buttons["close"], app.buttons["Close"], app.buttons["Cancel"]].first { $0.exists }
        if let cancel { cancel.tap() } else { dump(app, "search-cancel"); XCTFail("no Cancel") }
        XCTAssertTrue(waitUntil(timeout: 3) { app.cells["bot-row-research"].exists }, "the list is whole again")
        XCTAssertTrue(waitUntil(timeout: 3) { !app.searchFields.firstMatch.exists || !app.searchFields.firstMatch.isHittable },
                      "the field folds away")
        shot(app, "bots-search-folded")

        // Opened and left empty (keyboard down by a scroll), it folds away by itself.
        searchButton(app).tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 3))
        app.collectionViews["bots.list"].swipeDown()
        XCTAssertTrue(waitUntil(timeout: 3) { !app.searchFields.firstMatch.exists || !app.searchFields.firstMatch.isHittable },
                      "an empty search folds away when left")
    }

    // MARK: - BB3 The + menu (New Bot, New Group Chat, New Section…)

    // [bots-plus] Bots' create menu sits behind a + (its id is still "bots.compose"); the pencil, Sessions' button, only
    // ever starts a new chat (owner 2026-11-03, menu review #3). The glyph itself is checked in unit `BotsPlusTests`.
    @MainActor func testBB3_ComposeMenu() throws {
        let app = launchSignedIn()
        let plus = app.buttons["bots.compose"]
        XCTAssertTrue(plus.waitForExistence(timeout: 10), "the +")
        XCTAssertEqual(plus.label, "New Bot, Group Chat or Section", "VoiceOver says what the + makes")
        shot(app, "bots-plus")
        openMenu(app, plus, showing: "New Bot")
        XCTAssertTrue(app.buttons["New Section…"].firstMatch.exists, "New Section…")
        // [groups] New Group Chat sits between New Bot and New Section… (enabled: this fixture has more than one bot).
        let room = app.buttons["New Group Chat"].firstMatch
        XCTAssertTrue(room.exists && room.isEnabled, "New Group Chat")
        XCTAssertLessThan(app.buttons["New Bot"].firstMatch.frame.minY, room.frame.minY, "New Bot first")
        XCTAssertLessThan(room.frame.minY, app.buttons["New Section…"].firstMatch.frame.minY, "New Section… last")
        shot(app, "bots-compose-menu")
        tapMenu(app, "New Section…")
        XCTAssertTrue(app.textFields["section.name"].waitForExistence(timeout: 3), "New Section asks for a name")
        confirmAlert(app, "Cancel")

        // Sessions keeps the pencil, and it is a new chat (no menu).
        app.tabButton(id: "tab-sessions", label: "Sessions").tap()
        let pencil = app.buttons["sessions.compose"]
        XCTAssertTrue(pencil.waitForExistence(timeout: 10), "Sessions' pencil")
        XCTAssertEqual(pencil.label, "New Chat")
        shot(app, "sessions-pencil")
    }

    // MARK: - BB4 Filter: Show Hidden Bots; Activity and its token

    @MainActor func testBB4_FilterMenuAndToken() throws {
        let app = launchSignedIn()
        let filter = app.buttons["bots.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5), "Filter (always on the bar: [filters-only])")
        openMenu(app, filter, showing: "Show Hidden Bots (1)")
        shot(app, "bots-filter-menu")
        tapMenu(app, "Show Hidden Bots (1)")
        let deploys = app.cells["bot-row-deploys"]
        XCTAssertTrue(appears(deploys, app, "show-hidden"), "the hidden bot shows")
        let activity = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Activity'")).firstMatch
        for _ in 0..<3 where !activity.exists {
            filter.tap()
            _ = activity.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(activity.exists, "Activity ›")
        activity.tap()
        tapMenu(app, "Recently Active")
        let token = app.buttons["page.filter-token"]
        XCTAssertTrue(appears(token, app, "filter-token"), "the token names the filter")
        XCTAssertTrue(token.label.contains("Recently Active"), token.label)
        XCTAssertTrue(app.cells["bot-row-ivy"].exists, "a recent bot stays")
        XCTAssertFalse(app.cells["section-header-Work"].exists, "a filtered list is flat")
        shot(app, "bots-filter-token")
        token.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { !token.exists }, "the token clears the filter")
        XCTAssertTrue(app.cells["section-header-Work"].waitForExistence(timeout: 3), "sections are back")
    }

    // MARK: - BB5 Rearrange pinned tiles by drag; kept across a relaunch

    @MainActor func testBB5_DragPinnedTileKeepsOrder() throws {
        let app = launchSignedIn(drag: true)
        let hermes = app.cells["bot-tile-default"], inbox = app.cells["bot-tile-inbox"]
        XCTAssertTrue(hermes.waitForExistence(timeout: 10) && inbox.exists)
        XCTAssertLessThan(hermes.frame.midX, inbox.frame.midX, "Hermes first")
        hermes.press(forDuration: 0.8, thenDragTo: inbox, withVelocity: .slow, thenHoldForDuration: 0.8)
        let moved = waitUntil(timeout: 5) { hermes.frame.midX > inbox.frame.midX }
        if !moved { dump(app, "tile-drag") }
        XCTAssertTrue(moved, "Inbox first after the drop")
        XCTAssertEqual(a.writes("profiles.configure").count, 0, "the order is this device's own: nothing is sent")
        shot(app, "bots-tiles-rearranged")

        // A relaunch with the saved sign-in: the order is kept.
        app.terminate()
        app.launchArguments = ["-HQDebugNoDrag", "YES"] + appearanceArguments
        app.launch()
        XCTAssertTrue(app.cells["bot-tile-default"].waitForExistence(timeout: 20), "signed in still")
        XCTAssertTrue(waitUntil(timeout: 5) { app.cells["bot-tile-default"].frame.midX > app.cells["bot-tile-inbox"].frame.midX },
                      "Inbox still first after a relaunch")
        shot(app, "bots-tiles-after-relaunch")
    }
}
