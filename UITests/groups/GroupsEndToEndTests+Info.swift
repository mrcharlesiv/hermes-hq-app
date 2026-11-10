// Group Info and its pages (docs/spec/3x-groups.md §7.2, §7.5 edit mode, §7.6): members, Mute, Pinned, Name & Photo,
// Edit Bots…, Activity, and what the sheet does offline.

import XCTest

extension GroupsEndToEndTests {
    /// Group Info from the room's row menu.
    @MainActor func openGroupInfo(_ app: XCUIApplication, _ name: String, room: String = GroupsEndToEndTests.launch) {
        let row = roomRow(app, room)
        reveal(app, row)
        pressMenu(app, row, "Group Info")
        XCTAssertTrue(appears(any(app, "group-info.list"), app, name, timeout: 8), "Group Info opens")
    }

    /// Replaces a text field's text (the caret is put at the end first).
    @MainActor func retype(_ field: XCUIElement, _ text: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let current = (field.value as? String) ?? ""
        if !current.isEmpty, current != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
        field.typeText(text)
    }

    // MARK: - C1 Group Info: who is here, Mute, Pinned, Mark as Unread; all on this iPhone only (L233, L234)

    @MainActor func testC1_GroupInfo() throws {
        let app = launchSignedIn()
        let before = writes().count
        openGroupInfo(app, "c1-info")
        XCTAssertTrue(app.navigationBars["Group Info"].exists, "the sheet's title")
        XCTAssertEqual(any(app, "group-info.name").label, "Launch Room")
        XCTAssertEqual(any(app, "group-info.subtitle").label, "3 bots")
        // Members in the roster's order, each opening its own Bot Info.
        let members = ["default", "ivy", "research"].map { any(app, "group-info.member.\($0)") }
        XCTAssertTrue(members.allSatisfy(\.exists), "the three members")
        XCTAssertTrue(members[0].frame.minY < members[1].frame.minY && members[1].frame.minY < members[2].frame.minY, "in the roster's order")
        XCTAssertTrue(members[0].label.contains("Hermes") && members[2].label.contains("Research"), "by their names: \(members.map(\.label))")
        XCTAssertTrue(text(app, "Edit Bots…").exists, "three bots: one can be removed")
        XCTAssertFalse(any(app, "group-info.floor").exists, "no floor line above two bots")
        shot(app, "group-info")

        members[1].tap()
        XCTAssertTrue(appears(app.navigationBars["Bot Info"], app, "c1-bot-info", timeout: 8), "a member's Bot Info is pushed")
        XCTAssertFalse(app.buttons["bot-info.close"].exists, "Back returns to Group Info: no ✕ of its own")
        shot(app, "group-info-member")
        app.navigationBars["Bot Info"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(appears(app.navigationBars["Group Info"], app, "c1-back", timeout: 6), "Back returns to Group Info")

        // Mute For 1 Hour: the row's value and the tile follow.
        let mute = any(app, "group-info.mute")
        scrollTo(app, mute, in: app.collectionViews["group-info.list"])
        XCTAssertEqual(mute.value as? String, "Off")
        mute.tap()
        for choice in ["Off", "For 1 Hour", "For 8 Hours", "For 1 Week", "Always"] {
            XCTAssertTrue(app.buttons[choice].firstMatch.waitForExistence(timeout: 3), "Mute offers \(choice)")
        }
        shot(app, "group-info-mute-menu")
        tapMenu(app, "For 1 Hour")
        XCTAssertTrue(waitUntil(timeout: 5) { ((mute.value as? String) ?? "").hasPrefix("Until ") }, "muted until a time: \(mute.value ?? "")")
        XCTAssertTrue(text(app, "Only on this iPhone. Approval requests still notify you.").exists, "the footer says where it applies")

        // Pinned and Mark as Unread.
        let pinned = any(app, "group-info.pinned")
        scrollTo(app, pinned, in: app.collectionViews["group-info.list"])
        XCTAssertFalse(isOn(pinned))
        flip(pinned)
        XCTAssertTrue(waitUntil(timeout: 4) { self.isOn(pinned) }, "Pinned turns on")
        let unread = any(app, "group-info.unread")
        XCTAssertEqual(unread.label, "Mark as Unread")
        unread.tap()
        XCTAssertTrue(waitUntil(timeout: 4) { unread.label == "Mark as Read" }, "the row turns into Mark as Read")
        shot(app, "group-info-marked")
        XCTAssertEqual(writes().count, before, "Mute, Pinned and the mark are this iPhone's own: nothing is written")

        app.buttons["group-info.close"].tap()
        dismissMuteTip(app)
        let tile = roomTile(app)
        XCTAssertTrue(appears(tile, app, "c1-tile", timeout: 6), "the room is a tile now")
        let label = roomLabel(app)
        check(label.contains("Muted") && label.contains("Unread"), app, "c1-label", "the tile says muted and unread: \(label)")
    }

    // MARK: - C2 Name & Photo: rename on every bot, a taken name, a failed write undone (L233)

    @MainActor func testC2_RenameTheRoom() throws {
        control("seed", ["preset": "standup"])
        let app = launchSignedIn()
        openGroupInfo(app, "c2-info")
        let row = any(app, "group-info.name-photo")
        scrollTo(app, row, in: app.collectionViews["group-info.list"])
        row.tap()
        let save = app.buttons["group-settings.save"]
        XCTAssertTrue(appears(save, app, "c2-settings", timeout: 6), "the Name & Photo page")
        XCTAssertTrue(app.navigationBars["Name & Photo"].exists)
        XCTAssertTrue(text(app, "Rename the group chat or change its group photo. Members and history are kept.").exists)
        XCTAssertTrue(app.buttons["group-settings.choose-photo"].exists, "Choose Photo")
        XCTAssertFalse(app.buttons["group-settings.remove-photo"].exists, "no Remove Photo without a photo")
        XCTAssertFalse(save.isEnabled, "nothing to save yet")
        let name = app.textFields["group-settings.name"]
        XCTAssertEqual(name.value as? String, "Launch Room")
        shot(app, "group-settings")

        // A name another room has: said under the field, nothing written.
        let before = writes().count
        retype(name, "Standup")
        XCTAssertTrue(waitUntil(timeout: 3) { save.isEnabled })
        save.tap()
        XCTAssertTrue(appears(text(app, "A group named “Standup” already exists."), app, "c2-taken", timeout: 6), "a taken name says so")
        XCTAssertEqual(writes().count, before, "and nothing is written")
        shot(app, "group-settings-taken")

        // A failed write: the alert names the room, and the bots already renamed are put back.
        retype(name, "Release Room")
        control("fail", ["method": "profiles.configure", "match": "research", "mode": "error", "count": 1])
        save.tap()
        let alert = app.alerts["Couldn’t Rename Launch Room"]
        XCTAssertTrue(appears(alert, app, "c2-alert", timeout: 12), "the failure names the room")
        shot(app, "alert-couldnt-rename")
        XCTAssertEqual(groups(of: "ivy"), ["Launch Room", "Standup"], "Ivy's rename was undone")
        XCTAssertEqual(groups(of: "default"), ["Launch Room"])
        alert.buttons["Try Again"].tap()
        XCTAssertTrue(appears(app.navigationBars["Group Info"], app, "c2-saved", timeout: 12), "saved: back on Group Info")
        XCTAssertEqual(any(app, "group-info.name").label, "Release Room")
        XCTAssertTrue(waitUntil(timeout: 8) { self.groups(of: "research") == ["Release Room"] }, "\(groups(of: "research"))")
        XCTAssertEqual(groups(of: "ivy"), ["Release Room", "Standup"], "renamed in place, the other room untouched")
        XCTAssertEqual(groups(of: "default"), ["Release Room"])
        // The other devices learn the new name from the mirror, under the room's own id.
        XCTAssertTrue(waitUntil(timeout: 20) { self.mirrorRoom()["name"] as? String == "Release Room" }, "the mirror: \(mirrorRoom()["name"] ?? "")")
        XCTAssertEqual(mirrorTexts().last, "I can take the notes.", "its log is kept")

        app.buttons["group-info.close"].tap()
        XCTAssertTrue(appears(roomRow(app, "Release Room"), app, "c2-row", timeout: 6), "the list shows the new name")
        XCTAssertFalse(roomRow(app).exists)
        assertNoHostedCalls()
    }

    // MARK: - C5 Edit Bots…: the room's bots change, two is the floor (L233)

    @MainActor func testC5_AddOrRemoveBots() throws {
        let app = launchSignedIn()
        openGroupInfo(app, "c5-info")
        let edit = any(app, "group-info.members-edit")
        scrollTo(app, edit, in: app.collectionViews["group-info.list"])
        edit.tap()
        let save = app.buttons["group-picker.save"]
        XCTAssertTrue(appears(save, app, "c5-picker", timeout: 6), "the picker is pushed")
        XCTAssertEqual(save.label, "Save")
        XCTAssertTrue(app.navigationBars["Launch Room"].exists, "titled with the room")
        XCTAssertTrue(textContaining(app, "Pick 2–6 bots for “Launch Room”.").exists, "it says what stays")
        XCTAssertFalse(save.isEnabled, "nothing changed yet")
        XCTAssertFalse(app.textFields["group-picker.name"].exists, "no name field when changing bots")
        for profile in ["default", "ivy", "research"] {
            XCTAssertEqual(any(app, "group-picker.bot.\(profile)").value as? String, "Selected", "\(profile) is in")
        }
        shot(app, "group-picker-edit")

        // Out goes Research, in comes Inbox.
        pick(app, "research")
        pick(app, "inbox")
        XCTAssertTrue(waitUntil(timeout: 3) { save.isEnabled })
        save.tap()
        XCTAssertTrue(appears(app.navigationBars["Group Info"], app, "c5-saved", timeout: 12), "saved: back on Group Info")
        XCTAssertTrue(any(app, "group-info.member.inbox").waitForExistence(timeout: 5), "Inbox is a member")
        XCTAssertFalse(any(app, "group-info.member.research").exists, "Research is not")
        XCTAssertTrue(waitUntil(timeout: 8) { self.groups(of: "inbox") == ["Launch Room"] && self.groups(of: "research").isEmpty },
                      "the wire: \(groups(of: "inbox")) / \(groups(of: "research"))")
        XCTAssertNil(group(of: "research"), "a bot in no room has no `group`")
        XCTAssertEqual(groups(of: "ivy"), ["Launch Room"], "a bot that stayed is not written")
        XCTAssertTrue(waitUntil(timeout: 20) { (self.mirrorRoom()["members"] as? [String]) == ["default", "ivy", "inbox"] },
                      "the mirror's members follow: \(mirrorRoom()["members"] ?? "")")

        // Down to two: the floor. No pick can be taken away, and the page says why.
        scrollTo(app, edit, in: app.collectionViews["group-info.list"])
        edit.tap()
        XCTAssertTrue(appears(save, app, "c5-picker-2", timeout: 6))
        pick(app, "inbox")
        XCTAssertTrue(appears(text(app, "A group chat needs at least 2 bots, so none can be removed."), app, "c5-floor", timeout: 4),
                      "two left: the picker says none can be removed")
        XCTAssertEqual(any(app, "group-picker.bot.ivy").value as? String, "Selected, can’t be removed")
        pick(app, "ivy")
        XCTAssertEqual(any(app, "group-picker.bot.ivy").value as? String, "Selected, can’t be removed", "a locked pick stays")
        shot(app, "group-picker-floor")
        save.tap()
        XCTAssertTrue(appears(app.navigationBars["Group Info"], app, "c5-saved-2", timeout: 12))
        XCTAssertTrue(waitUntil(timeout: 8) { self.groups(of: "inbox").isEmpty }, "Inbox left: \(groups(of: "inbox"))")
        XCTAssertTrue(appears(text(app, "Add Bots…"), app, "c5-add-bots", timeout: 5), "at the floor the row only adds")
        XCTAssertTrue(any(app, "group-info.floor").exists, "and the section says why")
        XCTAssertEqual(any(app, "group-info.subtitle").label, "2 bots")
        shot(app, "group-info-floor")
        assertNoHostedCalls()
    }

    // MARK: - C6 Group Info offline: reading works, changing waits for the gateway (L233)

    @MainActor func testC6_GroupInfoOffline() throws {
        let app = launchSignedIn()
        openGroupInfo(app, "c6-info")
        control("mode", ["offline": true])
        let offline = any(app, "group-info.offline")
        for _ in 0..<12 {
            if offline.exists { break }
            app.collectionViews["group-info.list"].swipeUp(velocity: .slow)
            Thread.sleep(forTimeInterval: 2)
        }
        XCTAssertTrue(appears(offline, app, "c6-offline", timeout: 20), "the sheet says changes wait for the gateway")
        XCTAssertEqual(offline.label, "You can change this group chat again once your gateway is back.")
        XCTAssertFalse(any(app, "group-info.delete").isEnabled, "Delete Group Chat waits")
        shot(app, "group-info-offline")
        let list = app.collectionViews["group-info.list"]
        let edit = any(app, "group-info.members-edit")
        scrollTo(app, edit, in: list)
        check(edit.exists && !edit.isEnabled, app, "c6-members", "so does Edit Bots…")
        let namePhoto = any(app, "group-info.name-photo")
        scrollTo(app, namePhoto, in: list)
        check(namePhoto.exists && !namePhoto.isEnabled, app, "c6-name", "and Name & Photo")
        let activity = any(app, "group-info.activity")
        scrollTo(app, activity, in: list)
        check(activity.exists && activity.isEnabled, app, "c6-activity-row", "Activity still reads")
        activity.tap()
        XCTAssertTrue(appears(any(app, "group-activity.list"), app, "c6-activity", timeout: 6), "the Activity page")
        XCTAssertTrue(text(app, "No activity in this turn yet.").exists, "nothing has run in this launch")
        shot(app, "group-activity-empty")
        control("mode", ["offline": false])
    }
}
