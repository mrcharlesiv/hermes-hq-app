// Rooms in the Bots list (docs/spec/3x-groups.md §7.1, §7.3, §7.4, §7.9–§7.11): the row and its menu, Pin, Mute, the
// device-local unread mark, Delete Group Chat and its tombstone, renames, Show ›, the empty states and drag.

import XCTest

extension GroupsEndToEndTests {
    // MARK: - A1 The row, its menu, Pin, Mute, Mark as Unread (L232, L234)

    @MainActor func testA1_RoomRowMenuPinMuteUnread() throws {
        let app = launchSignedIn()
        let row = roomRow(app)
        reveal(app, row)
        let header = app.cells["section-header-groups"]
        XCTAssertTrue(header.exists, "the Group Chats header")
        let heading = spoken(header)
        check(heading.contains("Group Chats") && heading.contains("1 group chat"), app, "a1-header", "its count: \(heading)")
        let label = roomLabel(app)
        check(label.hasPrefix("Launch Room. Ivy: I can take the notes."), app, "a1-label", "the row reads name, sender and text: \(label)")
        shot(app, "bots-rooms")

        // The menu: exactly the six items, in order (Hide: UX study #254).
        holdMenu(app, row, showing: "Group Info")
        let wanted = ["Group Info", "Pin", "Mute", "Mark as Unread", "Hide", "Delete Group Chat"]
        check(menuTitles(app, among: wanted + ["Unpin", "Unmute", "Mark as Read", "Show in Bots", "Bot Info", "Edit Bot"]) == wanted, app, "a1-menu",
              "Group Info, Pin, Mute, Mark as Unread, Hide, Delete Group Chat")
        shot(app, "room-row-menu")

        // Pin: a tile in the grid; Unpin: a row again. No network call (this iPhone's own).
        let before = writes().count
        tapMenu(app, "Pin")
        // Tiles do not fit the largest text sizes: there a pinned room is a row among the pinned bots at the top of
        // the list (its menu saying Unpin, below, is the proof).
        if largeText { toTop(app) }
        let tile = pinnedRoom(app)
        XCTAssertTrue(appears(tile, app, "a1-pin", timeout: 5), "Pin makes the room a tile")
        if !largeText { XCTAssertFalse(roomRow(app).exists, "and it leaves the Group Chats block") }
        app.collectionViews["bots.list"].swipeDown()
        shot(app, "room-tile")
        pressMenu(app, tile, "Unpin")
        reveal(app, roomRow(app))
        XCTAssertFalse(roomTile(app).exists, "Unpin returns it to a row")

        // Mute: the row says so, and a relaunch keeps it.
        pressMenu(app, roomRow(app), "Mute")
        tapMenu(app, "Always")   // the row menu's Mute offers its durations
        XCTAssertTrue(waitUntil(timeout: 5) { self.roomLabel(app).contains("Muted") }, "the row is muted: \(roomLabel(app))")
        XCTAssertTrue(app.staticTexts["Muted on This iPhone"].waitForExistence(timeout: 3), "the first mute explains itself")
        shot(app, "room-mute-tip")
        dismissMuteTip(app)
        // Mark as Unread: this iPhone's own mark, no network call.
        pressMenu(app, roomRow(app), "Mark as Unread")
        XCTAssertTrue(waitUntil(timeout: 5) { self.roomLabel(app).contains("Unread") }, "the row is unread: \(roomLabel(app))")
        shot(app, "room-row-muted-unread")
        XCTAssertEqual(writes().count, before, "Pin, Mute and Mark as Unread write nothing to the gateway")

        relaunch(app)
        reveal(app, roomRow(app))
        let kept = roomLabel(app)
        check(kept.contains("Muted") && kept.contains("Unread"), app, "a1-relaunch", "a relaunch keeps the mute and the mark: \(kept)")

        // Opening the room clears the mark.
        openRoom(app)
        backToList(app)
        reveal(app, roomRow(app))
        XCTAssertTrue(waitUntil(timeout: 5) { !self.roomLabel(app).contains("Unread") }, "opening the room reads it: \(roomLabel(app))")
        XCTAssertTrue(roomLabel(app).contains("Muted"), "still muted")
        holdMenu(app, roomRow(app), showing: "Unmute")
        XCTAssertTrue(app.buttons["Unmute"].firstMatch.exists && app.buttons["Mark as Unread"].firstMatch.exists, "the menu follows the state")
        closeMenu(app)

        assertNoHostedCalls()
    }

    // MARK: - A1b Hide and Show in Bots (UX study #254)

    @MainActor func testA1b_HideAndShowInBots() throws {
        let app = launchSignedIn()
        reveal(app, roomRow(app))
        // UX study #254: Hide moves the room under Hidden (folded), with no network call; Show in Bots brings it back.
        let writesBeforeHide = writes().count
        pressMenu(app, roomRow(app), "Hide")
        XCTAssertTrue(waitUntil(timeout: 5) { !self.roomRow(app).exists }, "Hide takes the room out of Group Chats")
        let hidden = app.cells["section-header-hidden"]
        reveal(app, hidden)
        hidden.tap()
        reveal(app, roomRow(app))
        shot(app, "room-hidden")
        pressMenu(app, roomRow(app), "Show in Bots")
        reveal(app, roomRow(app))
        holdMenu(app, roomRow(app), showing: "Hide")       // back in Group Chats, offering Hide again
        closeMenu(app)
        XCTAssertEqual(writes().count, writesBeforeHide, "Hide writes nothing to the gateway")
        assertNoHostedCalls()
    }

    // MARK: - A2 Delete Group Chat: the question, the writes, and a tombstone that holds (L232)

    @MainActor func testA2_DeleteRoomAndTombstone() throws {
        let app = launchSignedIn()
        reveal(app, roomRow(app))
        pressMenu(app, roomRow(app), "Delete Group Chat")
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(appears(sheet, app, "a2-sheet", timeout: 5), "the delete question")
        check(text(app, "Delete “Launch Room”?").exists, app, "a2-title", "its title")
        XCTAssertTrue(text(app, "The group chat and its messages are removed. The bots and their own chats are kept. This can’t be undone.").exists, "its message")
        shot(app, "room-delete-question")
        // The system draws the question from the row (iOS 26): Cancel is a tap outside it, so only the action is a button.
        check(sheet.buttons["Delete Group Chat"].exists, app, "a2-buttons", "its Delete Group Chat button")
        sheet.buttons["Delete Group Chat"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { !self.roomRow(app).exists }, "the row leaves")
        XCTAssertTrue(waitUntil(timeout: 10) {
            ["default", "ivy", "research"].allSatisfy { !self.groups(of: $0).contains("Launch Room") }
        }, "no bot names the room any more")
        XCTAssertTrue(waitUntil(timeout: 10) { ((self.mirror["deleted"] as? [String: Any]) ?? [:])[Self.launchKey] != nil }, "the mirror holds its tombstone")
        XCTAssertTrue(((mirror["rooms"] as? [String: Any]) ?? [:]).isEmpty, "and no room")
        XCTAssertFalse(app.cells["section-header-groups"].exists, "the Group Chats block goes with its last room")

        // Another device writes the room back without a higher revision: a pull does not bring it back.
        let now = Date().timeIntervalSince1970 * 1000
        control("desktop-edit", ["op": "raw", "value": [
            "version": 3, "updatedAt": now, "deleted": [String: Any](),
            "rooms": [Self.launchKey: ["name": "Launch Room", "roomId": "rmfixture-launch", "holdDetection": true, "revision": 1, "omitted": 0,
                                       "members": [["name": "ivy", "handle": "ivy"], ["name": "research", "handle": "research"]],
                                       "log": [["id": "back-1", "from": ["kind": "user", "name": "You"], "text": "Am I back?", "at": now, "thread": "tback"]]]],
        ]])
        pullToRefresh(app)
        Thread.sleep(forTimeInterval: 3)
        check(!roomRow(app).exists && !roomTile(app).exists, app, "a2-back", "a deleted room stays deleted")
        assertNoHostedCalls()
    }

    // MARK: - A3 A rename on another device keeps the mute and the unread mark (L195)

    @MainActor func testA3_RenamedElsewhereKeepsMuteAndMark() throws {
        let app = launchSignedIn()
        reveal(app, roomRow(app))
        pressMenu(app, roomRow(app), "Mute")
        tapMenu(app, "Always")   // the row menu's Mute offers its durations
        XCTAssertTrue(waitUntil(timeout: 5) { self.roomLabel(app).contains("Muted") })
        dismissMuteTip(app)
        pressMenu(app, roomRow(app), "Mark as Unread")
        XCTAssertTrue(waitUntil(timeout: 5) { self.roomLabel(app).contains("Unread") })
        control("desktop-edit", ["op": "rename", "room": "Launch Room", "to": "Release Room"])
        pullToRefresh(app)
        let renamed = roomRow(app, "Release Room")
        XCTAssertTrue(appears(renamed, app, "a3-renamed", timeout: 15), "the room shows under its new name")
        XCTAssertFalse(roomRow(app).exists, "and not under the old one")
        reveal(app, renamed)
        let label = roomLabel(app, "Release Room")
        check(label.contains("Muted") && label.contains("Unread"), app, "a3-marks", "still muted and unread: \(label)")
        shot(app, "room-renamed-elsewhere")
    }

    // MARK: - A4 The row says who is replying; offline rows still open, Delete is disabled (L232)

    @MainActor func testA4_RowWhileReplyingAndOffline() throws {
        control("turn-mode", ["ivy": "slow:20"])
        let app = launchSignedIn()
        openRoom(app)
        send(app, "@ivy are you there?")
        XCTAssertTrue(waitUntil(timeout: 10) { self.prompts.count == 1 }, "Ivy was asked")
        backToList(app)
        reveal(app, roomRow(app))
        XCTAssertTrue(waitUntil(timeout: 8) { self.roomLabel(app).contains("Ivy is replying…") }, "the row says who is replying: \(roomLabel(app))")
        shot(app, "room-row-replying")
        // The reply lands with the room off screen: the app's own notice names who spoke (it leaves after 4.5 s).
        let peek = any(app, "reply-peek")
        let peeked = peek.waitForExistence(timeout: 35)
        if peeked { shot(app, "room-reply-peek") } else { dump(app, "a4-peek") }
        XCTAssertTrue(peeked, "a reply that lands while the room is off screen peeks")
        XCTAssertTrue(waitUntil(timeout: 25) { self.roomLabel(app).contains("Ivy: Ivy here") }, "then Ivy's reply: \(roomLabel(app))")

        // Offline: the row still opens (its log is on the device); Pin and Unread work; Delete is disabled.
        control("mode", ["offline": true])
        // The app notices on its own (the socket drops, then its reconnect is refused): look until the menu says so.
        var disabled = false
        for _ in 0..<10 where !disabled {
            holdMenu(app, roomRow(app), showing: "Group Info")
            // Offline, the item's subtitle gives the reason ("Delete Group Chat, Your gateway is offline"): found by its id.
            let delete = app.buttons["room.delete"].firstMatch
            disabled = delete.exists && !delete.isEnabled
            if !disabled { closeMenu(app); Thread.sleep(forTimeInterval: 3) }
        }
        check(disabled, app, "a4-offline-menu", "Delete Group Chat is disabled offline")
        XCTAssertTrue(app.buttons["room.delete"].firstMatch.label.contains("Your gateway is offline"), "and says why")
        shot(app, "room-row-menu-offline")
        // Ivy's reply landed while the list was showing, so the room is unread: the mark is this iPhone's own and
        // goes and comes back with nothing reachable.
        check(app.buttons["Mark as Read"].firstMatch.exists, app, "a4-unread", "a reply that lands off screen marks the room unread")
        tapMenu(app, "Mark as Read")
        XCTAssertTrue(waitUntil(timeout: 5) { !self.roomLabel(app).contains("Unread") }, "the mark clears offline: \(roomLabel(app))")
        pressMenu(app, roomRow(app), "Mark as Unread")
        XCTAssertTrue(waitUntil(timeout: 5) { self.roomLabel(app).contains("Unread") }, "and is set again offline: \(roomLabel(app))")
        openRoom(app)
        XCTAssertTrue(message(app, containing: "I can take the notes.").waitForExistence(timeout: 5), "the log reads offline")
        shot(app, "room-offline")
        control("mode", ["offline": false])
    }

    // MARK: - A5 The row's swipes: Unread then Pin from the leading edge, More then Mute from the trailing edge (L232)

    @MainActor func testA5_RoomRowSwipes() throws {
        let app = launchSignedIn()
        let list = app.collectionViews["bots.list"]
        reveal(app, roomRow(app))
        let before = writes().count

        // Leading: Mark as Unread, then Pin.
        swipeRow(roomRow(app), left: false)
        check(list.buttons["Mark as Unread"].waitForExistence(timeout: 4) && list.buttons["Pin"].exists, app, "a5-leading",
              "the leading swipe offers Mark as Unread and Pin")
        XCTAssertLessThan(list.buttons["Mark as Unread"].frame.minX, list.buttons["Pin"].frame.minX, "Unread first")
        shot(app, "room-row-swipe-leading")
        list.buttons["Mark as Unread"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.roomLabel(app).contains("Unread") }, "the row is unread: \(roomLabel(app))")
        swipeRow(roomRow(app), left: false)
        check(list.buttons["Mark as Read"].waitForExistence(timeout: 4), app, "a5-read", "an unread room's swipe says Mark as Read")
        list.buttons["Pin"].tap()
        if largeText { toTop(app) }
        XCTAssertTrue(appears(pinnedRoom(app), app, "a5-pin", timeout: 5), "Pin makes the room a tile")
        pressMenu(app, pinnedRoom(app), "Unpin")
        reveal(app, roomRow(app))

        // Trailing: More, then Mute at the edge.
        swipeRow(roomRow(app), left: true)
        check(list.buttons["Mute"].waitForExistence(timeout: 4) && list.buttons["More"].exists, app, "a5-trailing",
              "the trailing swipe offers More and Mute")
        XCTAssertLessThan(list.buttons["More"].frame.minX, list.buttons["Mute"].frame.minX, "Mute at the edge")
        XCTAssertFalse(list.buttons["Delete"].exists || list.buttons["Delete Group Chat"].exists, "nothing destructive is a swipe")
        shot(app, "room-row-swipe-trailing")
        list.buttons["Mute"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.roomLabel(app).contains("Muted") }, "the row is muted: \(roomLabel(app))")
        dismissMuteTip(app)
        swipeRow(roomRow(app), left: true)
        check(list.buttons["Unmute"].waitForExistence(timeout: 4), app, "a5-unmute", "a muted room's swipe says Unmute")
        // More opens the room's own menu (a pull-down from the row).
        list.buttons["More"].tap()
        check(app.buttons["Delete Group Chat"].firstMatch.waitForExistence(timeout: 5) && app.buttons["Group Info"].firstMatch.exists, app,
              "a5-more", "More lists the room's menu")
        XCTAssertFalse(app.sheets.firstMatch.exists, "a menu, not an action sheet")
        shot(app, "room-row-more-menu")
        app.buttons["Group Info"].firstMatch.tap()
        XCTAssertTrue(appears(any(app, "group-info.list"), app, "a5-info", timeout: 8), "and its Group Info opens")
        XCTAssertEqual(writes().count, before, "the swipes are this iPhone's own: nothing is written")
    }

    // MARK: - B4 Show › and the empty states (L196, L207)

    @MainActor func testB4_ShowFilterAndNoGroupChats() throws {
        let app = launchSignedIn()
        let filter = app.buttons["bots.filter"]
        openMenu(app, filter, showing: "Show Hidden Bots (1)")
        let show = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show' AND NOT label BEGINSWITH 'Show Hidden'")).firstMatch
        check(show.exists && show.label.contains("All"), app, "b4-show", "Show › names the current choice: \(show.exists ? show.label : "missing")")
        shot(app, "filter-menu-show")
        show.tap()
        XCTAssertTrue(app.buttons["Group Chats"].firstMatch.waitForExistence(timeout: 3), "All, Bots, Group Chats")
        XCTAssertTrue(app.buttons["Bots"].firstMatch.exists && app.buttons["All"].firstMatch.exists)
        shot(app, "filter-show-choices")
        tapMenu(app, "Group Chats")
        // Only rooms: no bot rows, no tiles; the token names the filter.
        XCTAssertTrue(waitUntil(timeout: 5) { !app.cells["bot-row-ivy"].exists && !app.cells["bot-tile-default"].exists }, "the bots are left out")
        XCTAssertTrue(roomRow(app).waitForExistence(timeout: 5), "the room stays")
        let token = app.buttons["page.filter-token"]
        check(token.waitForExistence(timeout: 3) && token.label.contains("Group Chats"), app, "b4-token", "the token reads Group Chats")
        shot(app, "filter-group-chats")
        // The submenu's subtitle follows.
        openMenu(app, filter, showing: "Show Hidden Bots (1)")
        let showNow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show' AND NOT label BEGINSWITH 'Show Hidden'")).firstMatch
        XCTAssertTrue(showNow.label.contains("Group Chats"), "the subtitle names the choice: \(showNow.label)")
        // A bar button's menu closes on a tap in the page under it (the status bar's strip does not reach it).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        check(waitUntil(timeout: 5) { !app.buttons["Show Hidden Bots (1)"].exists }, app, "b4-menu-open", "the menu closes")
        XCTAssertTrue(token.isHittable, "the token can be tapped")
        token.tap()
        check(waitUntil(timeout: 5) { app.cells["bot-row-ivy"].exists && !token.exists }, app, "b4-token-clear", "tapping the token clears it")

        // Show › Bots hides the Group Chats block.
        openMenu(app, filter, showing: "Show Hidden Bots (1)")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show' AND NOT label BEGINSWITH 'Show Hidden'")).firstMatch.tap()
        tapMenu(app, "Bots")
        XCTAssertTrue(waitUntil(timeout: 5) { !self.roomRow(app).exists && !app.cells["section-header-groups"].exists }, "no Group Chats block")
        XCTAssertTrue(app.cells["bot-row-ivy"].exists)
        XCTAssertTrue(app.buttons["page.filter-token"].label.contains("Bots"))
        shot(app, "filter-bots")

        // Show › Group Chats, then delete the only room: No Group Chats, with its button; the Filter button stays.
        openMenu(app, filter, showing: "Show Hidden Bots (1)")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show' AND NOT label BEGINSWITH 'Show Hidden'")).firstMatch.tap()
        tapMenu(app, "Group Chats")
        XCTAssertTrue(roomRow(app).waitForExistence(timeout: 5))
        pressMenu(app, roomRow(app), "Delete Group Chat")
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        app.sheets.firstMatch.buttons["Delete Group Chat"].tap()
        let title = text(app, "No Group Chats")
        check(title.waitForExistence(timeout: 8), app, "b4-empty", "No Group Chats")
        XCTAssertTrue(text(app, "A group chat lets 2 to 6 bots talk together.").exists, "its description")
        XCTAssertTrue(filter.exists, "the Filter button stays while a filter is on")
        shot(app, "empty-no-group-chats")
        let make = app.buttons["New Group Chat"].firstMatch
        XCTAssertTrue(make.exists, "the button")
        make.tap()
        XCTAssertTrue(app.navigationBars["New Group Chat"].waitForExistence(timeout: 5), "it opens New Group Chat")
        app.buttons["group-picker.cancel"].tap()

        // Only Hermes and a hidden bot are left: the state shows without the button.
        // The pull starts on the bot rows: the empty state covers the list (a drag there lands on its button).
        control("seed", ["preset": "one-bot"])
        token.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !token.exists }, "the filter clears")
        pullToRefresh(app)
        openMenu(app, filter, showing: "Show Hidden Bots (1)")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show' AND NOT label BEGINSWITH 'Show Hidden'")).firstMatch.tap()
        tapMenu(app, "Group Chats")
        XCTAssertTrue(waitUntil(timeout: 15) { title.exists && !app.buttons["New Group Chat"].firstMatch.exists }, "no button with fewer than 2 bots")
        shot(app, "empty-no-group-chats-one-bot")
    }

    // MARK: - B5 Compose menu: New Group Chat and its disabled state (L202)

    @MainActor func testB5_ComposeMenuStates() throws {
        let app = launchSignedIn()
        let compose = app.buttons["bots.compose"]
        XCTAssertEqual(compose.label, "New Bot, Group Chat or Section")
        openMenu(app, compose, showing: "New Bot")
        let order = menuTitles(app, among: ["New Bot", "New Group Chat", "New Section…"])
        check(order == ["New Bot", "New Group Chat", "New Section…"], app, "b5-order", "New Bot, New Group Chat, New Section…: \(order)")
        XCTAssertTrue(app.buttons["New Group Chat"].firstMatch.isEnabled)
        shot(app, "compose-menu")
        closeMenu(app)

        // Fewer than 2 bots: disabled, with the reason.
        control("seed", ["preset": "one-bot"])
        pullToRefresh(app)
        XCTAssertTrue(waitUntil(timeout: 15) { !app.cells["bot-row-ivy"].exists }, "only Hermes is left")
        openMenu(app, compose, showing: "New Bot")
        let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New Group Chat'")).firstMatch
        check(item.exists && !item.isEnabled, app, "b5-disabled", "New Group Chat is disabled with one bot")
        XCTAssertTrue(item.label.contains("Needs at least 2 bots") || text(app, "Needs at least 2 bots").exists, "and says why: \(item.label)")
        shot(app, "compose-menu-one-bot")
        closeMenu(app)

        // Offline: disabled, with that reason.
        control("reset")
        pullToRefresh(app)
        XCTAssertTrue(app.cells["bot-row-ivy"].waitForExistence(timeout: 15))
        control("mode", ["offline": true])
        let offline = waitUntil(timeout: 40) {
            compose.tap()
            let found = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New Group Chat'")).firstMatch
            let ok = found.waitForExistence(timeout: 2) && !found.isEnabled
            if !ok { self.closeMenu(app) }
            return ok
        }
        check(offline, app, "b5-offline", "New Group Chat is disabled offline")
        let reason = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New Group Chat'")).firstMatch.label
        XCTAssertTrue(reason.contains("Your gateway is offline") || text(app, "Your gateway is offline").exists, "and says why: \(reason)")
        shot(app, "compose-menu-offline")
        closeMenu(app)
        control("mode", ["offline": false])
    }

    // MARK: - H1 Hidden room sessions stay out of the Sessions lists (§7.15)

    @MainActor func testH1_RoomSessionsStayOutOfSessions() throws {
        let app = launchSignedIn()
        openRoom(app)
        send(app, "@ivy hello")
        XCTAssertTrue(message(app, containing: "Ivy here: @ivy hello").waitForExistence(timeout: 15), "Ivy replies")
        backToList(app)
        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'session-row-'")).firstMatch.waitForExistence(timeout: 10), "the Sessions list")
        Thread.sleep(forTimeInterval: 1.5)
        let plumbing = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Group: '")).firstMatch
        check(!plumbing.exists, app, "h1-sessions", "no row titled Group: … in Sessions")
        XCTAssertTrue(textContaining(app, "Trip ideas").exists, "an ordinary session is listed")
        shot(app, "sessions-no-room-plumbing")
    }
}
