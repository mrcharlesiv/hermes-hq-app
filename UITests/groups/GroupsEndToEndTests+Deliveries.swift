// Deliveries from other bots in a bot's own chat (docs/spec/3x-groups.md §7.12, one line each), filing a room by drag (§7.11), and
// rooms on a gateway without revisions and with a member on another gateway (§9, N10 and D4).

import XCTest

extension GroupsEndToEndTests {
    // MARK: - E1 A delivery is one line under its sender's name that opens on the message; no "Message from" prefix (L301)

    @MainActor func testE1_DeliveriesReadAsTheirSender() throws {
        let app = launchSignedIn()
        // Pinned bots are tiles; at the largest text sizes they are rows.
        XCTAssertTrue(waitUntil(timeout: 10) { app.cells["bot-tile-default"].exists || app.cells["bot-row-default"].exists }, "Hermes' tile")
        let tile = app.cells["bot-tile-default"].exists ? app.cells["bot-tile-default"] : app.cells["bot-row-default"]
        for _ in 0..<3 {
            dismissSavePassword(app)
            tile.tap()
            if app.tables["chat.table"].waitForExistence(timeout: 6) { break }
        }
        // Each delivery is a one-line row (as a finished subagent's), named after its sender (owner, 2026-10-18).
        XCTAssertTrue(appears(message(app, containing: "Inbox: Three new emails need a reply."), app, "e1-inbox", timeout: 15),
                      "a delivery reads as Inbox's own line")
        XCTAssertTrue(message(app, containing: "Inbox: The invoice from Northwind is overdue.").exists, "the second")
        XCTAssertTrue(message(app, containing: "Inbox: Lunch moved to 1 pm.").exists, "and the third")
        XCTAssertTrue(message(app, containing: "Research: Findings are in the doc.").exists, "the bracket form names the bot too")
        XCTAssertTrue(message(app, containing: "Billing Bot: Invoice sent.").exists, "a sender this gateway does not know keeps its name")
        XCTAssertTrue(message(app, containing: "Thanks, I will reply to the three emails first.").exists, "Hermes' own reply is untouched")
        XCTAssertFalse(textContaining(app, "Message from").exists, "the prefix is never shown")
        XCTAssertFalse(textContaining(app, "Nothing to report").exists, "a delivery taken in silently has no note under it")
        XCTAssertFalse(message(app, containing: "You said: Three new emails").exists, "and a delivery is not read as yours")
        shot(app, "deliveries")

        // Tapped, the line opens on the whole message; tapped again it closes.
        let lunch = app.tables["chat.table"].buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Inbox: Lunch moved")).firstMatch
        lunch.tap()
        XCTAssertTrue(waitUntil(timeout: 4) { lunch.value as? String == "Expanded" }, "the delivery opens in place")
        shot(app, "delivery-open")
        lunch.tap()
        XCTAssertTrue(waitUntil(timeout: 4) { lunch.value as? String == "Collapsed" }, "and closes again")
    }

    // MARK: - F1 With sections, rooms are filed among the bots; the rest sit under Unassigned (tester 2026-11-05)

    @MainActor func testF1_DragARoomIntoASection() throws {
        control("seed", ["preset": "section"])
        let app = launchSignedIn(drag: true)
        // [bots-groupby] A section is in use: the unfiled room sits under Unassigned with the unfiled bots; no Group Chats block.
        let unassigned = app.cells["section-header-unassigned"]
        reveal(app, roomRow(app))
        XCTAssertTrue(appears(unassigned, app, "f1-unassigned", timeout: 8), "Unassigned heads the unfiled chats")
        XCTAssertFalse(app.cells["section-header-groups"].exists, "no separate Group Chats block once sections are in use")
        check(unassigned.frame.minY < roomRow(app).frame.minY, app, "f1-under", "the room is under Unassigned")
        shot(app, "bots-unassigned")
        let before = writes().count

        // Its menu files it: Move to Section › Work.
        roomRow(app).press(forDuration: 1.2)
        tapMenu(app, "Move to Section")
        tapMenu(app, "Work")
        let work = app.cells["section-header-Work"]
        check(waitUntil(timeout: 6) {
            self.roomRow(app).exists && work.exists && work.frame.minY < self.roomRow(app).frame.minY
                && self.roomRow(app).frame.minY < unassigned.frame.minY
        }, app, "f1-filed", "the room sits in Work, among its bots")
        XCTAssertEqual(writes().count, before, "a room's section is this iPhone's own: nothing is written")
        shot(app, "bots-room-in-section")

        // A relaunch keeps it.
        relaunch(app, drag: true)
        XCTAssertTrue(appears(app.cells["bot-row-ivy"], app, "f1-relaunch", timeout: 20), "signed in still")
        reveal(app, roomRow(app))
        check(work.exists && work.frame.minY < roomRow(app).frame.minY && roomRow(app).frame.minY < unassigned.frame.minY,
              app, "f1-kept", "the room is still in Work after a relaunch")

        // Unassigned folds like any section.
        reveal(app, unassigned)
        let loose = app.cells["bot-row-ops"]
        XCTAssertTrue(loose.exists)
        unassigned.tap()
        XCTAssertTrue(waitUntil(timeout: 4) { !loose.exists }, "folded, its chats go")
        shot(app, "bots-unassigned-folded")
        unassigned.tap()
        XCTAssertTrue(loose.waitForExistence(timeout: 4), "and come back")

        // Group By › None: one list by activity, no section names.
        openMenu(app, app.buttons["bots.filter"], showing: "Show Hidden Bots (1)")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Group By'")).firstMatch.tap()   // "Group By, Sections"
        tapMenu(app, "None")
        XCTAssertTrue(waitUntil(timeout: 4) { !work.exists && !unassigned.exists }, "no section names")
        XCTAssertTrue(app.cells["bot-row-ivy"].exists, "the bots are all there")
        reveal(app, roomRow(app))
        shot(app, "bots-group-by-none")
        openMenu(app, app.buttons["bots.filter"], showing: "Show Hidden Bots (1)")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Group By'")).firstMatch.tap()   // "Group By, Sections"
        tapMenu(app, "Sections")
        XCTAssertTrue(work.waitForExistence(timeout: 4), "Sections again")

        // Dragged onto Unassigned's name it is in no section again.
        reveal(app, roomRow(app))
        roomRow(app).press(forDuration: 0.55, thenDragTo: unassigned, withVelocity: .slow, thenHoldForDuration: 1.2)
        check(waitUntil(timeout: 8) { self.roomRow(app).exists && unassigned.frame.minY < self.roomRow(app).frame.minY },
              app, "f1-unfiled", "back under Unassigned")
        XCTAssertEqual(writes().count, before)
    }

    // MARK: - G1 A gateway without revisions: rooms work and publishes carry no expected revision (§9 N10)

    @MainActor func testG1_OldGatewayWithoutRevisions() throws {
        let old = try SettingsFixture.load("HQN_UI_OLD_CREDENTIALS")
        try old.control("/__groups/reset", [:])
        a = old   // every helper now reads the old gateway's state
        control("turn-mode", ["ivy": "say:Old gateway, still here."])
        let app = launchSignedIn()
        openRoom(app)
        XCTAssertTrue(appears(message(app, containing: "Ivy said: I can take the notes."), app, "g1-seed", timeout: 10), "the mirror is read")
        send(app, "@ivy are you there?")
        XCTAssertTrue(appears(message(app, containing: "Ivy said: Old gateway, still here."), app, "g1-reply", timeout: 25), "Ivy replies")
        XCTAssertTrue(waitUntil(timeout: 25) { self.mirrorTexts().contains("Old gateway, still here.") }, "the publish lands: \(mirrorTexts())")
        XCTAssertTrue(mirrorWrites.allSatisfy { $0["ui_meta_expected_revisions"] == nil }, "no expected revision is sent to a gateway without them")
        assertNoHostedCalls()
        shot(app, "room-old-gateway")
    }

    // MARK: - G2 A member on another gateway is named with its place and never asked from here (§9 D4)

    @MainActor func testG2_MemberOnAnotherGateway() throws {
        control("seed", ["preset": "other-gateway"])
        control("turn-mode", ["default": "once", "ivy": "once", "research": "once"])
        let app = launchSignedIn()
        XCTAssertTrue(waitUntil(timeout: 10) { self.roomRow(app).exists || self.roomTile(app).exists })
        openGroupInfo(app, "g2-info")
        let remote = any(app, "group-info.member.remote")
        XCTAssertTrue(appears(remote, app, "g2-member", timeout: 6), "the member on the other gateway is listed")
        XCTAssertTrue(remote.label.contains("On Office Mac"), "with where it lives: \(remote.label)")
        XCTAssertFalse(remote.isEnabled, "its Bot Info is not on this gateway")
        XCTAssertEqual(any(app, "group-info.subtitle").label, "4 bots")
        shot(app, "group-info-other-gateway")
        app.buttons["group-info.close"].tap()

        openRoom(app)
        send(app, "Hello everyone")
        XCTAssertTrue(waitUntil(timeout: 40) { self.prompts(to: "research").count >= 1 }, "this gateway's bots are asked")
        XCTAssertTrue(waitUntil(timeout: 40) { !app.buttons["composer.stop"].exists }, "the round ends")
        XCTAssertTrue(prompts(to: "remote").isEmpty, "the remote member is never asked from here")
        let first = (prompts.first?["text"] as? String) ?? ""
        XCTAssertTrue(first.contains("[on Office Mac]"), "the others are told where it is: \(first.prefix(260))")
        // The mirror keeps the remote member's row as it was.
        XCTAssertTrue(waitUntil(timeout: 20) { self.mirrorTexts().contains("Hello everyone") }, "published")
        let rows = (mirrorRoom()["memberRows"] as? [[String: Any]]) ?? []
        let kept = rows.first { $0["name"] as? String == "remote" }
        XCTAssertEqual(kept?["connectionLabel"] as? String, "Office Mac", "the remote row is kept: \(rows)")
        XCTAssertEqual(kept?["sourceScoped"] as? Bool, true)
        XCTAssertEqual(kept?["connectionId"] as? String, "conn-studio")
        assertNoHostedCalls()
    }
}
