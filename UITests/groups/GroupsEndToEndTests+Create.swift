// New Group Chat, Add to Group Chat… and Bot Info's Group Chats (docs/spec/3x-groups.md §7.5, §7.7, §7.8): the picker's
// rules on screen, the membership writes on the wire, failures that undo themselves, and the limits (2 to 6 bots).

import XCTest

extension GroupsEndToEndTests {
    func group(of profile: String) -> String? {
        ((state()["profiles"] as? [String: Any])?[profile] as? [String: Any])?["group"] as? String
    }

    /// Compose › New Group Chat, waiting for the sheet's Create button.
    @MainActor @discardableResult func openNewGroupChat(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        openMenu(app, app.buttons["bots.compose"], showing: "New Group Chat")
        tapMenu(app, "New Group Chat")
        let create = app.buttons["group-picker.save"]
        XCTAssertTrue(appears(create, app, name, timeout: 8), "the New Group Chat sheet")
        return create
    }

    /// Taps a bot's row in the picker, scrolling the sheet's list to it first.
    @MainActor func pick(_ app: XCUIApplication, _ profile: String, file: StaticString = #filePath, line: UInt = #line) {
        // The row is a button inside the sheet's list. Asking for exactly that (not for any element anywhere, which has
        // XCTest read every element of the sheet and of the Bots list behind it) keeps each look under a second
        // instead of 30 s on a busy Mac; what is asserted about the row is unchanged.
        let row = app.collectionViews["group-picker.list"].buttons["group-picker.bot.\(profile)"]
        // The sheet's list is lazy: a row far down it exists only once it is scrolled near.
        if !row.waitForExistence(timeout: 2) { scrollTo(app, row, in: app.collectionViews["group-picker.list"]) }
        check(row.exists, app, "pick-\(profile)", "the picker lists \(profile)", file: file, line: line)
        scrollTo(app, row, in: app.collectionViews["group-picker.list"])
        row.tap()
    }

    /// The sheet of a bot's row: hold › More › Add to Group Chat…
    @MainActor func openAddToGroup(_ app: XCUIApplication, _ profile: String, _ name: String) {
        let row = app.cells["bot-row-\(profile)"]
        reveal(app, row)
        pressMenu(app, row, "More")
        tapMenu(app, "Add to Group Chat…")
        XCTAssertTrue(appears(any(app, "add-to-group.list"), app, name, timeout: 8), "the Add to Group Chat sheet")
    }

    @MainActor func groupSwitch(_ app: XCUIApplication, _ room: String) -> XCUIElement { any(app, "add-to-group.switch.\(room)") }

    // MARK: - B1 New Group Chat: pick two, Create, the room opens; the wire is two membership writes (L235)

    @MainActor func testB1_NewGroupChat() throws {
        let app = launchSignedIn()
        let mirrorBefore = mirrorWrites.count
        openMenu(app, app.buttons["bots.compose"], showing: "New Group Chat")
        shot(app, "compose-menu")
        tapMenu(app, "New Group Chat")
        let create = app.buttons["group-picker.save"]
        XCTAssertTrue(appears(create, app, "b1-sheet", timeout: 8), "the New Group Chat sheet")
        XCTAssertTrue(app.navigationBars["New Group Chat"].exists, "its title")
        XCTAssertEqual(create.label, "Create")
        XCTAssertFalse(create.isEnabled, "Create is off with no bots picked")
        XCTAssertEqual(app.keyboards.count, 0, "the sheet opens without the keyboard")
        XCTAssertTrue(text(app, "Pick 2–6 bots to talk together.").exists, "the sheet says what to do")
        XCTAssertFalse(any(app, "group-picker.bot.deploys").exists, "a hidden bot is not offered")
        let name = app.textFields["group-picker.name"]
        XCTAssertEqual(name.placeholderValue, "Group name")
        shot(app, "group-picker-empty")

        pick(app, "ivy")
        XCTAssertFalse(create.isEnabled, "still off with one bot")
        XCTAssertEqual(any(app, "group-picker.bot.ivy").value as? String, "Selected")
        pick(app, "research")
        XCTAssertTrue(waitUntil(timeout: 3) { create.isEnabled }, "on with two")
        // At the largest text sizes the chips are above the picked rows, off screen in a lazy list.
        scrollTo(app, any(app, "group-picker.chip.ivy"), in: app.collectionViews["group-picker.list"])
        XCTAssertTrue(any(app, "group-picker.chip.ivy").exists && any(app, "group-picker.chip.research").exists, "the picks show as chips")
        XCTAssertEqual(name.placeholderValue, "Ivy, Research", "the name offered is the picked bots' names")
        shot(app, "group-picker-two")
        // A chip takes its bot out again.
        any(app, "group-picker.chip.research").tap()
        XCTAssertTrue(waitUntil(timeout: 3) { !create.isEnabled }, "one bot left: Create is off again")
        pick(app, "research")
        XCTAssertTrue(waitUntil(timeout: 3) { create.isEnabled })
        create.tap()

        // The sheet closes and the room opens on its empty state.
        let empty = any(app, "room.empty")
        XCTAssertTrue(appears(empty, app, "b1-room", timeout: 15), "the new room opens")
        let title = any(app, "chat.title")
        check(title.exists && title.label.contains("Ivy, Research"), app, "b1-title", "named after its bots: \(title.exists ? title.label : "missing")")
        XCTAssertEqual(any(app, "room.empty.name").label, "Ivy, Research")
        shot(app, "room-new")

        // Tester 2026-11-05: with the keys up and two lines typed, the room's name was drawn under the composer's words.
        let field = app.textViews["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 8), "the composer")
        field.tap()
        let words = "Work together to make a bot that will act as the head of the company"
        field.typeText(words)
        XCTAssertTrue(waitUntil(timeout: 5) { app.keyboards.firstMatch.exists }, "the keys are up")
        let roomName = any(app, "room.empty.name")
        let hint = any(app, "room.empty.hint")
        check(waitUntil(timeout: 3) { roomName.exists && roomName.frame.maxY <= field.frame.minY && (!hint.exists || hint.frame.maxY <= field.frame.minY) },
              app, "b1-name-above-composer", "the name stays above the composer: \(roomName.frame), hint \(hint.frame) vs \(field.frame)")
        shot(app, "room-new-typing")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: words.count))

        // The wire: `groups` on both bots, `group` left as it was, nothing on the mirror for an empty room.
        XCTAssertTrue(waitUntil(timeout: 8) { self.groups(of: "research").contains("Ivy, Research") }, "Research joined: \(groups(of: "research"))")
        XCTAssertEqual(groups(of: "ivy"), ["Launch Room", "Ivy, Research"])
        XCTAssertEqual(groups(of: "research"), ["Launch Room", "Ivy, Research"])
        XCTAssertEqual(group(of: "ivy"), "Launch Room", "the first group stays the web's `group`")
        XCTAssertEqual(groups(of: "default"), ["Launch Room"], "a bot that was not picked is not written")
        XCTAssertEqual(mirrorWrites.count, mirrorBefore, "an empty room is not published")

        // Back in the list it is a row of its own, and it survives a relaunch.
        backToList(app)
        let row = roomRow(app, "Ivy, Research")
        reveal(app, row)
        XCTAssertTrue(roomLabel(app, "Ivy, Research").contains("2 bots"), "its row counts its bots: \(roomLabel(app, "Ivy, Research"))")
        let header = spoken(app.cells["section-header-groups"])
        XCTAssertTrue(header.contains("2 group chats"), "the header counts both rooms: \(header)")
        shot(app, "bots-two-rooms")

        // The same picks again: the name is made unique.
        let again = openNewGroupChat(app, "b1-second")
        pick(app, "ivy")
        pick(app, "research")
        XCTAssertTrue(waitUntil(timeout: 3) { again.isEnabled })
        again.tap()
        XCTAssertTrue(appears(any(app, "room.empty"), app, "b1-second-room", timeout: 15), "the second room opens")
        XCTAssertEqual(any(app, "room.empty.name").label, "Ivy, Research 2")
        XCTAssertTrue(waitUntil(timeout: 8) { self.groups(of: "research") == ["Launch Room", "Ivy, Research", "Ivy, Research 2"] },
                      "a second room of the same bots gets its own name: \(groups(of: "research"))")
        assertNoHostedCalls()
    }

    // MARK: - B2 A failed write undoes the ones already made; Try Again creates (L235)

    @MainActor func testB2_CreateFailsAndUndoesItself() throws {
        let app = launchSignedIn()
        let create = openNewGroupChat(app, "b2-sheet")
        pick(app, "ivy")
        pick(app, "research")
        control("fail", ["method": "profiles.configure", "match": "research", "mode": "error", "count": 1])
        XCTAssertTrue(waitUntil(timeout: 3) { create.isEnabled })
        create.tap()
        let alert = app.alerts["Couldn’t Create Ivy, Research"]
        XCTAssertTrue(appears(alert, app, "b2-alert", timeout: 12), "the failure names the room")
        XCTAssertTrue(alert.buttons["Show Details"].exists && alert.buttons["Try Again"].exists && alert.buttons["OK"].exists)
        shot(app, "alert-couldnt-create")
        XCTAssertEqual(groups(of: "ivy"), ["Launch Room"], "Ivy's membership was taken back")
        XCTAssertEqual(groups(of: "research"), ["Launch Room"])
        XCTAssertFalse(any(app, "room.empty").exists, "no room opened")
        alert.buttons["Try Again"].tap()
        XCTAssertTrue(appears(any(app, "room.empty"), app, "b2-room", timeout: 15), "Try Again creates it")
        XCTAssertTrue(waitUntil(timeout: 8) { self.groups(of: "research") == ["Launch Room", "Ivy, Research"] }, "\(groups(of: "research"))")
        XCTAssertEqual(groups(of: "ivy"), ["Launch Room", "Ivy, Research"])
        assertNoHostedCalls()
    }

    // MARK: - B3 Six at most; search; a typed name; Cancel asks before it throws picks away (L235)
    // Three tests, so each fits its time allowance on a busy Mac (as one test it was cut off after 20 minutes with
    // nothing failed). Every assertion of the one test is in one of the three.

    @MainActor func testB3a_PickerLimitAndFreedSeat() throws {
        let app = launchSignedIn()
        let create = openNewGroupChat(app, "b3-sheet")
        // Looks by kind (a button in the sheet's list, a text): on this sheet a look for "any element" has XCTest read
        // every element one by one and runs past its own 90 s limit on a busy Mac. The footer is seen by the same
        // look once it is there, so its absence before the seventh pick means what it says.
        let list = app.collectionViews["group-picker.list"]
        let footerById = app.staticTexts["group-picker.footer"]
        let writer = list.buttons["group-picker.bot.writer"]
        for profile in ["default", "ivy", "research", "inbox", "notes", "ops"] { pick(app, profile) }
        XCTAssertTrue(waitUntil(timeout: 3) { create.isEnabled }, "six bots can be a room")
        XCTAssertFalse(footerById.exists, "no limit line before a seventh pick")
        pick(app, "writer")
        let footer = app.staticTexts["A group chat can have up to 6 bots."]
        XCTAssertTrue(appears(footer, app, "b3-limit", timeout: 4), "a seventh pick is refused, and the sheet says why")
        XCTAssertTrue(footerById.exists, "the limit line is the sheet's footer")
        XCTAssertEqual(writer.value as? String, "Not selected")
        shot(app, "group-picker-limit")
        // Taking one away clears the line and frees a seat.
        pick(app, "ops")
        XCTAssertTrue(waitUntil(timeout: 3) { !footer.exists }, "the limit line goes once a seat is free")
        pick(app, "writer")
        XCTAssertEqual(writer.value as? String, "Selected")
        assertNoHostedCalls()
    }

    @MainActor func testB3b_PickerSearch() throws {
        let app = launchSignedIn()
        openNewGroupChat(app, "b3b-sheet")
        // Search narrows the list by name; nothing found says so.
        let search = app.textFields["group-picker.search"]
        scrollTo(app, search, in: app.collectionViews["group-picker.list"])
        typeInto(search, "zzz")
        XCTAssertTrue(appears(text(app, "No bots match “zzz”."), app, "b3-none", timeout: 4), "nothing found says so")
        shot(app, "group-picker-none")
        app.buttons["Clear search"].tap()
        typeInto(search, "ops")   // clearing can take the keyboard's focus on a busy Mac
        XCTAssertTrue(any(app, "group-picker.bot.ops").waitForExistence(timeout: 4), "Ops matches")
        XCTAssertFalse(any(app, "group-picker.bot.ivy").exists, "the others are filtered out")
        app.buttons["Clear search"].tap()
        assertNoHostedCalls()
    }

    @MainActor func testB3c_CancelAsksAndATypedNameCreates() throws {
        let app = launchSignedIn()
        let create = openNewGroupChat(app, "b3c-sheet")
        pick(app, "writer")
        pick(app, "ops")
        // Cancel with picks asks first.
        app.buttons["group-picker.cancel"].tap()
        let discard = app.buttons["Discard Changes"]
        XCTAssertTrue(appears(discard, app, "b3-discard", timeout: 4), "Cancel asks before it throws the picks away")
        // (iOS 26 draws the question as a popover from the button: its Keep Editing is a tap outside, not a button.)
        shot(app, "group-picker-discard")
        discard.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !create.exists }, "the sheet closes")
        XCTAssertEqual(groups(of: "writer"), [], "nothing was written")

        // A typed name is the room's name; a bot with no group chats gets its `group` set.
        let second = openNewGroupChat(app, "b3-second")
        pick(app, "inbox")
        pick(app, "notes")
        let name = app.textFields["group-picker.name"]
        scrollTo(app, name, in: app.collectionViews["group-picker.list"])
        name.tap()
        name.typeText("Mail Desk")
        XCTAssertTrue(waitUntil(timeout: 3) { second.isEnabled })
        second.tap()
        XCTAssertTrue(appears(any(app, "room.empty"), app, "b3-room", timeout: 15), "the named room opens")
        XCTAssertEqual(any(app, "room.empty.name").label, "Mail Desk")
        XCTAssertTrue(waitUntil(timeout: 8) { self.groups(of: "notes") == ["Mail Desk"] }, "\(groups(of: "notes"))")
        XCTAssertEqual(groups(of: "inbox"), ["Mail Desk"])
        XCTAssertEqual(group(of: "inbox"), "Mail Desk", "a first group chat is also the web's `group`")
        assertNoHostedCalls()
    }

    // MARK: - C3 Add to Group Chat…: a switch per room, Create and Join, the limits, a failed write flips back (L170)

    @MainActor func testC3_AddToGroupChat() throws {
        control("seed", ["preset": "full"])
        let app = launchSignedIn()
        openAddToGroup(app, "writer", "c3-sheet")
        XCTAssertTrue(app.navigationBars["Writer · Groups"].exists, "the sheet is named after the bot")
        XCTAssertTrue(text(app, "A bot can be in several group chats.").exists)
        XCTAssertTrue(appears(text(app, "Writer isn’t in any of these group chats yet. Turn one on, or name a new one."), app, "c3-empty", timeout: 4),
                      "a bot in no room says so")
        // A full room cannot take a seventh bot.
        let full = groupSwitch(app, "Full House")
        XCTAssertTrue(full.exists && !full.isEnabled, "a full room's switch is off")
        XCTAssertTrue(text(app, "Full (6 bots)").exists, "and says it is full")
        XCTAssertTrue(text(app, "3 bots").exists, "an open room counts its bots")
        XCTAssertFalse(any(app, "add-to-group.remove-all").exists, "nothing to leave yet")
        shot(app, "add-to-group")

        // Join the Launch Room: one write, on this bot only.
        let launch = groupSwitch(app, "Launch Room")
        XCTAssertFalse(isOn(launch))
        flip(launch)
        XCTAssertTrue(waitUntil(timeout: 8) { self.groups(of: "writer") == ["Launch Room"] }, "Writer joined: \(groups(of: "writer"))")
        XCTAssertTrue(waitUntil(timeout: 5) { self.isOn(self.groupSwitch(app, "Launch Room")) }, "the switch is on")
        XCTAssertTrue(appears(text(app, "4 bots"), app, "c3-count", timeout: 5), "the room counts its new bot")
        XCTAssertEqual(group(of: "writer"), "Launch Room")
        XCTAssertTrue(any(app, "add-to-group.remove-all").waitForExistence(timeout: 4), "it can leave every room now")

        // A failed write: the alert names the bot, and the switch is back where it was.
        control("fail", ["method": "profiles.configure", "match": "writer", "mode": "error", "count": 1])
        flip(groupSwitch(app, "Launch Room"))
        let alert = app.alerts["Couldn’t Change Writer’s Group Chats"]
        XCTAssertTrue(appears(alert, app, "c3-alert", timeout: 10), "the failure names the bot")
        shot(app, "alert-couldnt-change-groups")
        alert.buttons["OK"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.isOn(self.groupSwitch(app, "Launch Room")) }, "the switch flips back on")
        XCTAssertEqual(groups(of: "writer"), ["Launch Room"])

        // A name that is taken says so and writes nothing.
        let name = app.textFields["add-to-group.name"]
        scrollTo(app, name, in: app.collectionViews["add-to-group.list"])
        let create = any(app, "add-to-group.create")
        XCTAssertFalse(create.isEnabled, "Create and Join needs a name")
        name.tap()
        name.typeText("Launch Room")
        let before = writes().count
        create.tap()
        XCTAssertTrue(appears(text(app, "A group named “Launch Room” already exists."), app, "c3-taken", timeout: 5), "a taken name says so")
        XCTAssertEqual(writes().count, before, "and nothing is written")
        shot(app, "add-to-group-taken")
        // Create and Join: a room of its own (it needs a second bot before it can talk).
        name.typeText(" Two")
        create.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.groups(of: "writer") == ["Launch Room", "Launch Room Two"] }, "\(groups(of: "writer"))")
        let solo = groupSwitch(app, "Launch Room Two")
        XCTAssertTrue(appears(solo, app, "c3-solo", timeout: 5), "the new room is listed")
        XCTAssertTrue(isOn(solo) && !solo.isEnabled, "a room of one cannot be left from here")
        XCTAssertTrue(text(app, "Needs at least 2 bots").exists)
        XCTAssertFalse(any(app, "add-to-group.remove-all").exists, "leaving all would empty a room: not offered")
        shot(app, "add-to-group-joined")
        app.buttons["add-to-group.done"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !self.any(app, "add-to-group.list").exists }, "Done closes the sheet")
        assertNoHostedCalls()
    }

    // MARK: - C4 Remove from All Group Chats asks first; Bot Info lists the bot's group chats (L218)

    @MainActor func testC4_RemoveFromAllAndBotInfo() throws {
        control("seed", ["preset": "full"])
        let app = launchSignedIn()
        // Bot Info › Group Chats: one row per room, then Add to Group Chat…
        let row = app.cells["bot-row-ivy"]
        reveal(app, row)
        pressMenu(app, row, "Bot Info")
        XCTAssertTrue(app.navigationBars["Bot Info"].waitForExistence(timeout: 10), "Bot Info opens")
        app.botInfoTab("Chats")   // [tabs] Group Chats is on Chats
        // The sheet's list is lazy: Group Chats is below the first screen.
        let first = any(app, "bot-info.group.Launch Room")
        scrollTo(app, first)
        check(first.exists, app, "c4-info", "Bot Info lists the Launch Room")
        XCTAssertTrue(any(app, "bot-info.group.Full House").exists, "and the Full House")
        let add = any(app, "bot-info.add-to-group")
        scrollTo(app, add)
        XCTAssertTrue(add.exists, "Add to Group Chat… closes the section")
        shot(app, "bot-info-group-chats")
        add.tap()
        XCTAssertTrue(appears(any(app, "add-to-group.list"), app, "c4-pushed", timeout: 8), "the page is pushed inside Bot Info")
        XCTAssertTrue(app.navigationBars["Ivy · Groups"].exists)
        XCTAssertFalse(app.buttons["add-to-group.done"].exists, "Back returns to Bot Info: no Done")
        XCTAssertTrue(isOn(groupSwitch(app, "Launch Room")) && isOn(groupSwitch(app, "Full House")), "both rooms are on")

        // Remove from All Group Chats: asked first, then one write that leaves both.
        let removeAll = any(app, "add-to-group.remove-all")
        scrollTo(app, removeAll, in: app.collectionViews["add-to-group.list"])
        XCTAssertTrue(removeAll.exists, "both rooms keep two bots without Ivy: leaving all is offered")
        removeAll.tap()
        let confirm = app.sheets.buttons["Remove from All Group Chats"]
        XCTAssertTrue(appears(confirm, app, "c4-confirm", timeout: 5), "it asks first")
        XCTAssertTrue(text(app, "Remove Ivy from all group chats?").exists)
        XCTAssertTrue(text(app, "The group chats and their history are kept.").exists)
        shot(app, "add-to-group-remove-all")
        confirm.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { self.groups(of: "ivy").isEmpty }, "Ivy left every room: \(groups(of: "ivy"))")
        XCTAssertNil(group(of: "ivy"), "and the web's `group` is cleared")
        XCTAssertTrue(waitUntil(timeout: 5) { !self.isOn(self.groupSwitch(app, "Launch Room")) }, "the switches are off")
        XCTAssertEqual(groups(of: "default"), ["Launch Room", "Full House"], "the rooms and the other bots are untouched")
        // Back in Bot Info the rows are gone.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(waitUntil(timeout: 6) { !self.any(app, "bot-info.group.Launch Room").exists }, "Bot Info follows")
        XCTAssertTrue(any(app, "bot-info.add-to-group").exists)
        assertNoHostedCalls()
    }
}
