// Bots row and Bot Info extras end to end (docs/parity-240.md §3) against the settings fixture: the row menu's Mute,
// New Chat, Duplicate and Delete Bot; the swipes; Bot Info's Conversations, Model, Notifications, Duplicate and Delete.
// The fixture's `/__settings/state` is the wire evidence. Run with
//   HQN_SETTINGS_PORTS="9860 9861 9862" HQN_E2E_ONLY="testB1_…,testB2_…" scripts/e2e-settings.sh <SIM>

import XCTest

extension SettingsEndToEndTests {
    /// A bot's row element (its VoiceOver label starts with the name), for reading its states ("Muted", "Unread").
    @MainActor func rowLabel(_ app: XCUIApplication, _ name: String) -> String {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", name + ". ")).firstMatch
        return element.exists ? element.label : ""
    }

    @MainActor func launchExtras() -> XCUIApplication { launchSignedIn(["-HQDebugResetBotMutes", "YES"]) }

    /// Drags a row sideways by `dx` points (short of a full swipe): its swipe actions show.
    /// Bot Info's first recent chat (scrolled to; the list draws its rows lazily).
    @MainActor func recentRow(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let row = app.buttons.matching(NSPredicate(format: "identifier == 'bot-info.recent' AND label CONTAINS %@", title)).firstMatch
        for _ in 0..<5 where !(row.waitForExistence(timeout: 2) && row.isHittable) { app.swipeUp() }
        return row
    }

    @MainActor func reveal(_ row: XCUIElement, dx: CGFloat) {
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: dx > 0 ? 0.15 : 0.85, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: dx, dy: 0)))
    }

    // MARK: - B1 Row menu: Mute (tip), Unmute, New Chat, Duplicate

    @MainActor func testB1_RowMenuMuteNewChatDuplicate() throws {
        let app = launchExtras()
        let row = app.cells["bot-row-ivy"]
        pressMenu(app, row, "Mute")
        tapMenu(app, "Always")   // the row menu's Mute offers its durations
        XCTAssertTrue(waitUntil(timeout: 5) { self.rowLabel(app, "Ivy").contains("Muted") }, "the row says Muted")
        let tip = app.staticTexts["Muted on This iPhone"]
        XCTAssertTrue(appears(tip, app, "mute-tip"), "the first mute explains itself once")
        shot(app, "bots-mute-tip")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        XCTAssertTrue(waitUntil(timeout: 3) { !tip.exists }, "the tip closes")

        pressMenu(app, row, "Unmute")
        XCTAssertTrue(waitUntil(timeout: 5) { !self.rowLabel(app, "Ivy").contains("Muted") }, "unmuted")
        pressMenu(app, row, "Mute")
        tapMenu(app, "Always")   // the row menu's Mute offers its durations
        XCTAssertFalse(tip.waitForExistence(timeout: 1.5), "the tip shows only once")
        XCTAssertEqual(a.writes("profiles.configure").count, 0, "a mute is this iPhone's own: nothing is sent")

        // New Chat: a fresh session in Ivy's profile, not its Bot Chat.
        pressMenu(app, row, "New Chat")
        XCTAssertTrue(waitUntil(timeout: 10) { self.a.writes("session.create").contains { same($0["profile"], "ivy") } }, "session.create for Ivy")
        let create = a.writes("session.create").last ?? [:]
        XCTAssertNil(create["title"], "untitled: the gateway titles it from the first message")
        XCTAssertNil(create["hidden"], "a chat that lists in Sessions")
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 5))
        shot(app, "bots-new-chat")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "back on Bots")

        // More › Duplicate: profiles.create with clone_from, then the look.
        pressMenu(app, row, "More")
        tapMenu(app, "Duplicate Bot")
        XCTAssertTrue(waitUntil(timeout: 10) { self.a.writes("profiles.create").count == 1 })
        let duplicate = a.writes("profiles.create")[0]
        XCTAssertTrue(same(duplicate["name"], "ivy-2") && same(duplicate["clone_from"], "ivy"), "\(duplicate)")
        XCTAssertEqual(Set(duplicate.keys), ["name", "clone_from", "description"])
        XCTAssertTrue(same(a.profile("ivy-2")["cloned_from"], "ivy"))
        XCTAssertTrue(waitUntil(timeout: 10) {
            let meta = self.a.botsMeta("ivy-2")
            return same(meta["sectionId"], "sec-work") && meta["created"] == nil && meta["title"] != nil
        }, "the duplicate has Ivy's look and section: \(a.botsMeta("ivy-2"))")
        XCTAssertTrue(app.cells["bot-row-ivy-2"].waitForExistence(timeout: 10), "the duplicate shows")
        shot(app, "bots-duplicated")
    }

    // MARK: - B2 Delete Bot (confirmed; never Hermes)

    @MainActor func testB2_DeleteBotConfirmedNeverHermes() throws {
        let app = launchExtras()
        let hermes = app.cells["bot-tile-default"]
        XCTAssertTrue(hermes.waitForExistence(timeout: 10))
        hermes.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Bot Info"].firstMatch.waitForExistence(timeout: 4), "Hermes's menu")
        XCTAssertFalse(app.buttons["Delete Bot"].exists, "Hermes can't be deleted")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()

        // Research mutes first: its mute goes with it.
        let row = app.cells["bot-row-research"]
        pressMenu(app, row, "Mute")
        tapMenu(app, "Always")   // the row menu's Mute offers its durations
        XCTAssertTrue(waitUntil(timeout: 5) { self.rowLabel(app, "Research").contains("Muted") })
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        pressMenu(app, row, "Delete Bot")
        let sheet = app.sheets["Delete “Research”?"]
        XCTAssertTrue(appears(sheet, app, "delete-sheet"), "an action sheet asks first")
        XCTAssertTrue(sheet.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "can’t be undone")).firstMatch.exists)
        shot(app, "bots-delete-sheet")
        // An iPhone action sheet's Cancel is a tap outside it.
        if sheet.buttons["Cancel"].exists { sheet.buttons["Cancel"].tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap() }
        XCTAssertTrue(waitUntil(timeout: 3) { !sheet.exists })
        XCTAssertEqual(a.writes("DELETE /api/profiles/research").count, 0, "Cancel deletes nothing")

        pressMenu(app, row, "Delete Bot")
        XCTAssertTrue(sheet.waitForExistence(timeout: 4))
        sheet.buttons["Delete Bot"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { self.a.writes("DELETE /api/profiles/research").count == 1 }, "the REST delete")
        XCTAssertTrue(waitUntil(timeout: 5) { !row.exists }, "the row goes")
        XCTAssertTrue(a.profile("research").isEmpty, "gone on the gateway")
        XCTAssertEqual(a.writes("DELETE /api/profiles/default").count, 0)
        shot(app, "bots-deleted")
    }

    // MARK: - B3 Swipes: Unread + Pin leading, Mute + More trailing

    @MainActor func testB3_Swipes() throws {
        let app = launchExtras()
        let row = app.cells["bot-row-ivy"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        reveal(row, dx: 150)
        XCTAssertTrue(app.buttons["Unread"].waitForExistence(timeout: 3) || app.buttons["Mark as Unread"].exists, "leading Unread")
        XCTAssertTrue(app.buttons["Pin"].exists, "leading Pin")
        shot(app, "bots-swipe-leading")
        (app.buttons["Unread"].exists ? app.buttons["Unread"] : app.buttons["Mark as Unread"]).tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.rowLabel(app, "Ivy").contains("Unread") }, "marked unread")

        reveal(row, dx: -150)
        XCTAssertTrue(app.buttons["Mute"].waitForExistence(timeout: 3), "trailing Mute")
        let list = app.collectionViews["bots.list"]
        XCTAssertTrue(list.buttons["More"].exists, "trailing More")
        shot(app, "bots-swipe-trailing")
        app.buttons["Mute"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.rowLabel(app, "Ivy").contains("Muted") }, "muted from the swipe")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()   // the tip

        reveal(row, dx: -150)
        XCTAssertTrue(list.buttons["More"].waitForExistence(timeout: 3))
        list.buttons["More"].tap()
        // More: the row's hold menu as a pull-down from the row (owner 2026-10-30: not the action sheet's glass popover).
        XCTAssertTrue(appears(app.buttons["Bot Info"].firstMatch, app, "more-menu"), "More: the row menu")
        XCTAssertFalse(app.sheets.firstMatch.exists, "a menu, not an action sheet")
        XCTAssertTrue(app.buttons["Unmute"].firstMatch.exists && app.buttons["New Chat"].firstMatch.exists)
        shot(app, "bots-more-menu")
        app.buttons["Bot Info"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["bot-info.name"].waitForExistence(timeout: 5), "Info stays reachable")
    }

    // MARK: - B4 Bot Info: Conversations, Model, Notifications, Duplicate, Delete

    @MainActor func testB4_BotInfoExtras() throws {
        let app = launchExtras()
        openBotInfo(app, "ivy")
        XCTAssertTrue(app.buttons["bot-info.tile.mute"].exists, "the Mute tile")
        shot(app, "bot-info-top")
        app.botInfoTab("Brain")   // [main-e2e] the Model group is on Brain since Bot Info's tabs (dd8aba36)
        let provider = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Provider")).firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 3), "the Model group")
        app.botInfoTab("Chats")   // [tabs]
        XCTAssertTrue(recentRow(app, "Trip ideas").exists, "a recent chat lists")
        XCTAssertTrue(app.buttons["bot-info.bot-chat"].exists && app.buttons["bot-info.new-chat"].exists)
        shot(app, "bot-info-conversations")

        app.botInfoTab("Settings")   // [tabs]
        let mute = app.buttons["bot-info.mute"]
        for _ in 0..<5 where !(mute.exists && mute.isHittable) { app.swipeUp() }
        mute.tap()
        tapMenu(app, "For 1 Hour")
        XCTAssertTrue(waitUntil(timeout: 4) { (mute.value as? String ?? "").hasPrefix("Until") }, "Until <time>: \(String(describing: mute.value))")
        XCTAssertTrue(app.staticTexts["Only on this iPhone. Approval requests still notify you."].exists, "the footer")
        shot(app, "bot-info-muted")
        mute.tap()
        tapMenu(app, "Off")
        XCTAssertTrue(waitUntil(timeout: 4) { same(mute.value, "Off") })

        let duplicate = app.buttons["bot-info.duplicate"]
        for _ in 0..<5 where !(duplicate.exists && duplicate.isHittable) { app.swipeUp() }
        let ivyDelete = app.buttons["bot-info.delete"]
        for _ in 0..<3 where !ivyDelete.exists { app.swipeUp() }
        XCTAssertTrue(ivyDelete.exists, "Ivy can be deleted")
        shot(app, "bot-info-organize")
        duplicate.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { self.a.writes("profiles.create").contains { same($0["clone_from"], "ivy") } }, "Duplicate Bot")
        app.buttons["bot-info.close"].tap()

        // Hermes has no Delete Bot.
        openBotInfo(app, "default")
        app.botInfoTab("Settings")   // [tabs]
        for _ in 0..<5 { app.swipeUp() }
        XCTAssertTrue(app.buttons["bot-info.duplicate"].exists)
        XCTAssertFalse(app.buttons["bot-info.delete"].exists, "never for the default bot")
        app.buttons["bot-info.close"].tap()

        // Delete from Info: confirmed, the sheet closes, the row goes.
        openBotInfo(app, "notes")
        app.botInfoTab("Settings")   // [tabs]
        let delete = app.buttons["bot-info.delete"]
        for _ in 0..<5 where !(delete.exists && delete.isHittable) { app.swipeUp() }
        delete.tap()
        let sheet = app.sheets["Delete “Notes”?"]
        XCTAssertTrue(appears(sheet, app, "info-delete-sheet"))
        sheet.buttons["Delete Bot"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { self.a.writes("DELETE /api/profiles/notes").count == 1 })
        XCTAssertTrue(waitUntil(timeout: 5) { !app.staticTexts["bot-info.name"].exists }, "Info closes")
        XCTAssertTrue(waitUntil(timeout: 5) { !app.cells["bot-row-notes"].exists }, "the row goes")
    }

    // MARK: - B5 Bot Info's New Chat and a recent chat open over Bots

    @MainActor func testB5_InfoOpensChats() throws {
        let app = launchExtras()
        openBotInfo(app, "ivy")
        app.botInfoTab("Chats")   // [tabs]
        let recent = recentRow(app, "Trip ideas")
        XCTAssertTrue(recent.exists)
        recent.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { !app.staticTexts["bot-info.name"].exists }, "Info closes")
        let reply = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Three hotels look good")).firstMatch
        XCTAssertTrue(appears(reply, app, "recent-chat", timeout: 10), "the recent chat opens")
        shot(app, "bot-info-recent-chat")
        app.navigationBars.buttons.firstMatch.tap()
        openBotInfo(app, "ivy")
        app.botInfoTab("Chats")   // [tabs]
        let newChat = app.buttons["bot-info.new-chat"]
        for _ in 0..<5 where !(newChat.exists && newChat.isHittable) { app.swipeUp() }
        newChat.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { self.a.writes("session.create").contains { same($0["profile"], "ivy") } }, "a new chat")
    }

    // MARK: - B6 Bot Info's Chats rows: where each one goes, and what Mark as Read acts on

    /// [botinfo-chats] Owner 2026-11-03 (menu/nav review): the rows close the sheet, so they no longer look like pages
    /// pushed inside it; All Chats says it lands on Sessions; the read row names the chat it acts on (the Bot Chat).
    /// HQN_BOTINFO_SIZE=<content size category> takes the pictures at that text size and stops there.
    @MainActor func testB6_InfoChatsRowsSayWhereTheyGo() throws {
        try a.control("/__settings/chats", ["profile": "ivy", "titles": ["Packing list", "Visa forms", "Restaurant picks"]])
        let environment = ProcessInfo.processInfo.environment
        let size = environment["HQN_BOTINFO_SIZE"].flatMap { $0.isEmpty ? nil : $0 }
        let look = (environment["HQN_UI_DESKTOPLOOK"] == "1" ? "desktop" : "ios") + (size == nil ? "" : "-large")
        let app = launchExtras()
        if let size {
            // The sign-in form is driven at the standard size; then the app comes back signed in at the large one.
            app.terminate()
            app.launchArguments = appearanceArguments + ["-HQDebugNoDrag", "YES", "-UIPreferredContentSizeCategoryName", size]
            app.launch()
            XCTAssertTrue(waitUntil(timeout: 25) { app.cells["bot-row-ivy"].exists }, "the Bots list shows at \(size)")
        }
        openBotInfo(app, "ivy")
        app.botInfoTab("Chats")
        XCTAssertTrue(app.botInfoReveal(app.buttons["bot-info.bot-chat"]), "Bot Chat")
        shot(app, "bot-info-chats-\(look)")
        let all = app.buttons["bot-info.all-chats"]
        let read = app.buttons["bot-info.unread"]
        XCTAssertTrue(app.botInfoReveal(read), "the read row")
        app.swipeUp()   // the section's end, clear of the home indicator
        shot(app, "bot-info-chats-end-\(look)")
        XCTAssertTrue(app.botInfoReveal(all), "a full three recents: All Chats with Ivy")
        XCTAssertTrue(all.label.contains("Opens in Sessions"), "All Chats says where it lands: \(all.label)")
        XCTAssertEqual(read.label, "Mark Bot Chat as Unread", "the row names the chat it marks")
        guard size == nil else { return }   // the large-text run is for the pictures

        // The Bot Chat's dot, as the Bots row's Mark as Unread sets it; the row's words follow.
        XCTAssertTrue(app.botInfoReveal(read))
        read.tap()
        XCTAssertTrue(waitUntil(timeout: 4) { read.label == "Mark Bot Chat as Read" }, "now it offers Read: \(read.label)")
        read.tap()
        XCTAssertTrue(waitUntil(timeout: 4) { read.label == "Mark Bot Chat as Unread" }, "and back")

        // All Chats: the sheet closes and Sessions shows Ivy's chats, its chip picked.
        XCTAssertTrue(app.botInfoReveal(all))
        all.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { !app.staticTexts["bot-info.name"].exists }, "Info closes")
        XCTAssertTrue(app.collectionViews["sessions.list"].waitForExistence(timeout: 8), "Sessions shows")
        let chip = app.buttons["sessions.chip.ivy"]
        XCTAssertTrue(chip.waitForExistence(timeout: 8) && waitUntil(timeout: 5) { chip.isSelected }, "Ivy's chip is picked")
        shot(app, "bot-info-all-chats-sessions-\(look)")
    }
}
