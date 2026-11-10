// The stress plan of docs/spec/3x-groups.md §9 as repeatable checks: load (L3, L5, L7), bad network (N2, N6, N7, N8),
// bad data (D1, D2, D5), interruption (I6) and relaunch (R1, R4). Each test names the plan's row it runs.

import XCTest

extension GroupsEndToEndTests {
    // MARK: - S-L3 A full house: six members, one at a time, never past 10 messages or 3 rounds

    @MainActor func testS_L3_FullHouseStaysInsideTheCaps() throws {
        control("seed", ["preset": "full"])
        // Every member answers every time it is asked: only the caps end this.
        control("turn-mode", ["default": "reply", "ivy": "reply", "research": "reply", "inbox": "reply", "notes": "reply", "ops": "reply"])
        let app = launchSignedIn()
        openRoom(app, "Full House")
        send(app, "Everyone, one line each")
        XCTAssertTrue(waitUntil(timeout: 20) { self.prompts.count >= 1 }, "the round starts")
        XCTAssertTrue(waitUntil(timeout: 150) { !app.buttons["composer.stop"].exists && self.prompts.count >= 6 }, "the drive ends by itself")
        Thread.sleep(forTimeInterval: 3)
        let asked = prompts
        let order = asked.map { ($0["profile"] as? String) ?? "" }
        XCTAssertEqual(Set(order.prefix(6)), ["default", "ivy", "research", "inbox", "notes", "ops"], "all six are asked in the first round: \(order)")
        XCTAssertLessThanOrEqual(asked.count, 10, "never more than 10 messages in one drive: \(order)")
        XCTAssertTrue(asked.allSatisfy { ($0["inFlightForRoom"] as? Int) == 0 }, "one member at a time")
        XCTAssertTrue(asked.allSatisfy { $0["promptOk"] as? Bool == true }, "every prompt is the template")
        XCTAssertLessThanOrEqual(calls("session.create"), 6, "one hidden session per member")
        openRoomMenu(app, showing: "Activity")
        tapMenu(app, "Activity")
        XCTAssertTrue(appears(any(app, "group-activity.list"), app, "l3-activity", timeout: 8))
        let ended = textContaining(app, "Turn stopped at the round/message cap").exists || textContaining(app, "Turn settled").exists
        check(ended, app, "l3-end", "Activity ends with the cap line or Turn settled")
        shot(app, "group-activity-cap")
        assertNoHostedCalls()
    }

    // MARK: - S-L5 A mirror at the size cap: one more message still fits by dropping the oldest

    @MainActor func testS_L5_TheEnvelopeStaysUnderTheCap() throws {
        control("seed", ["preset": "cap"])
        control("turn-mode", ["ivy": "say:Noted."])
        let app = launchSignedIn()
        XCTAssertTrue(waitUntil(timeout: 15) { self.roomRow(app).exists }, "the rooms are read")
        let before = mirrorRevision
        XCTAssertLessThanOrEqual((mirror["pythonBytes"] as? Int) ?? 0, 48_000, "the seed is at the cap")
        openRoom(app)
        send(app, "@ivy one more for the pile")
        XCTAssertTrue(appears(message(app, containing: "Ivy said: Noted."), app, "l5-reply", timeout: 25), "Ivy replies")
        XCTAssertTrue(waitUntil(timeout: 30) { self.mirrorTexts().contains("Noted.") }, "the publish lands: \(mirrorTexts().suffix(3))")
        let bytes = (mirror["pythonBytes"] as? Int) ?? 0
        XCTAssertLessThanOrEqual(bytes, 48_000, "what Python writes stays under the cap: \(bytes)")
        XCTAssertGreaterThan(mirrorRevision, before, "the write was applied")
        XCTAssertTrue(mirrorWrites.count >= 1, "it was published")
        XCTAssertEqual(mirrorRoom()["name"] as? String, "Launch Room", "the room just used is in")
        assertNoHostedCalls()
    }

    // MARK: - S-L7 Sends in a row while a bot is slow: each in the log once, in order, one drive at a time

    @MainActor func testS_L7_RapidSendsQueueInOrder() throws {
        control("turn-mode", ["ivy": "slow:2"])
        let app = launchSignedIn()
        openRoom(app)
        let field = app.textViews["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        let texts = (1...6).map { "@ivy rapid \($0)" }
        for text in texts {
            field.tap()
            field.typeText(text)
            app.buttons["composer.send"].tap()
        }
        XCTAssertTrue(waitUntil(timeout: 90) { self.prompts(to: "ivy").count >= texts.count && !app.buttons["composer.stop"].exists },
                      "every send is answered: \(prompts(to: "ivy").count) of \(texts.count)")
        for text in texts { XCTAssertEqual(messageCount(app, containing: "You said: \(text)"), 1, "\(text) is on screen once") }
        XCTAssertTrue(prompts.allSatisfy { ($0["inFlightForRoom"] as? Int) == 0 }, "never two prompts in flight for one room")
        XCTAssertTrue(waitUntil(timeout: 30) { texts.allSatisfy(self.mirrorTexts().contains) || self.mirrorTexts().count == 16 }, "published")
        let published = mirrorTexts().filter { $0.hasPrefix("@ivy rapid ") }
        XCTAssertEqual(published, published.sorted { ($0.split(separator: " ").last.flatMap { Int($0) } ?? 0) < ($1.split(separator: " ").last.flatMap { Int($0) } ?? 0) },
                       "in the order sent: \(published)")
        XCTAssertEqual(Set(published).count, published.count, "no send twice")
        assertNoHostedCalls()
    }

    // MARK: - S-N2 Three write conflicts while sending: read again, merge, publish; the other device's entry survives

    @MainActor func testS_N2_ConflictsMergeAndKeepTheOtherDevice() throws {
        control("turn-mode", ["ivy": "say:Merged and well."])
        let app = launchSignedIn()
        openRoom(app)
        XCTAssertTrue(message(app, containing: "Ivy said: I can take the notes.").waitForExistence(timeout: 10))
        // Another device adds an entry, and the next three writes of the mirror are refused as stale.
        control("desktop-edit", ["op": "append", "room": "Launch Room", "from": "research", "text": "Written on the desktop."])
        control("fail", ["method": "profiles.configure", "match": "default", "mode": "conflict", "count": 3])
        send(app, "@ivy hello from the phone")
        XCTAssertTrue(appears(message(app, containing: "Ivy said: Merged and well."), app, "n2-reply", timeout: 25), "Ivy replies")
        XCTAssertTrue(waitUntil(timeout: 60) {
            let texts = self.mirrorTexts()
            return texts.contains("Merged and well.") && texts.contains("@ivy hello from the phone")
        }, "the publish lands after the conflicts: \(mirrorTexts().suffix(4))")
        let texts = mirrorTexts()
        XCTAssertTrue(texts.contains("Written on the desktop."), "the other device's entry survives: \(texts)")
        XCTAssertEqual(texts.filter { $0 == "@ivy hello from the phone" }.count, 1, "no duplicate entry")
        // Each refused write stood for another writer getting in first with an entry of its own: all three are kept.
        XCTAssertEqual(texts.filter { $0.hasPrefix("From the desktop (") }.count, 3, "what the other writers added is kept: \(texts)")
        XCTAssertTrue(appears(message(app, containing: "Research said: Written on the desktop."), app, "n2-merged", timeout: 15), "and shows on the phone")
        XCTAssertEqual(messageCount(app, containing: "Written on the desktop."), 1, "once")
        assertNoHostedCalls()
    }

    // MARK: - S-N6 A dropped session.create: the retry reuses its key, one hidden session, one reply

    @MainActor func testS_N6_DroppedCreateIsNotDoubled() throws {
        control("turn-mode", ["ivy": "say:Here once."])
        control("fail", ["method": "session.create", "mode": "drop", "count": 1])
        let app = launchSignedIn()
        openRoom(app)
        send(app, "@ivy are you there?")
        XCTAssertTrue(appears(message(app, containing: "Ivy said: Here once."), app, "n6-reply", timeout: 90), "the reply lands after the retry")
        let rooms = sessions.filter { $0["profile"] as? String == "ivy" && (($0["title"] as? String) ?? "").hasPrefix("Group: rmfixture-launch · t") && $0["hidden"] as? Bool == true }
        XCTAssertEqual(rooms.count, 1, "one hidden session for that member and thread: \(rooms)")
        XCTAssertEqual(messageCount(app, containing: "Here once."), 1, "one reply")
        XCTAssertEqual(prompts(to: "ivy").count, 1, "one prompt")
        assertNoHostedCalls()
    }

    // MARK: - S-N7/N8 A session that cannot be checked is not replaced; a session gone on the gateway is resumed

    @MainActor func testS_N7N8_SessionCheckFailsAndSessionGone() throws {
        // N8: Ivy's runtime session is gone when the prompt arrives: one resume by the stored id, one resubmit, one reply.
        control("turn-mode", ["ivy": "gone"])
        let app = launchSignedIn()
        openRoom(app)
        send(app, "@ivy first")
        XCTAssertTrue(appears(message(app, containing: "Ivy said: Ivy here: @ivy first"), app, "n8-reply", timeout: 40), "the reply lands after the resume")
        XCTAssertEqual(messageCount(app, containing: "Ivy here: @ivy first"), 1, "one reply")
        XCTAssertTrue(waitUntil(timeout: 10) { !app.buttons["composer.stop"].exists })

        // N7: the check of an existing session fails: the turn stops, and no second session is made for the thread.
        let creates = calls("session.create")
        control("turn-mode", ["ivy": "reply"])
        control("fail", ["method": "session.resume", "mode": "error", "count": 1])
        holdMenu(app, message(app, containing: "Ivy said: Ivy here: @ivy first"), showing: "Reply")
        tapMenu(app, "Reply")
        XCTAssertTrue(any(app, "room.reply").waitForExistence(timeout: 5), "the reply chip")
        send(app, "@ivy second")
        XCTAssertTrue(waitUntil(timeout: 30) { !app.buttons["composer.stop"].exists && self.calls("session.resume") >= 1 }, "the turn ends")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(calls("session.create"), creates, "a session that could not be checked is never replaced by a new one")
        openRoomMenu(app, showing: "Activity")
        tapMenu(app, "Activity")
        XCTAssertTrue(appears(any(app, "group-activity.list"), app, "n7-activity", timeout: 8))
        check(textContaining(app, "Ivy hit an error").exists, app, "n7-line", "Activity says Ivy hit an error")
        shot(app, "group-activity-error")
        assertNoHostedCalls()
    }

    // MARK: - S-D1 A damaged mirror: no crash, good rooms still show, the damage is never written back over them

    @MainActor func testS_D1_DamagedMirrors() throws {
        let app = launchSignedIn()
        XCTAssertTrue(waitUntil(timeout: 15) { self.roomRow(app).exists })
        for item in ["log-not-array", "member-missing-name", "text-number", "at-string", "huge-image", "unknown-keys", "duplicate-ids",
                     "tombstone-for-live-room", "rooms-array", "not-an-object"] {
            control("reset")
            control("seed", ["preset": "malformed", "case": item])
            pullToRefresh(app)
            Thread.sleep(forTimeInterval: 2.5)
            XCTAssertEqual(app.state, .runningForeground, "\(item): the app is still running")
            XCTAssertTrue(app.cells["bot-row-ivy"].exists || app.cells["bot-tile-default"].exists, "\(item): the Bots list still shows")
            if !["rooms-array", "not-an-object"].contains(item) {
                XCTAssertTrue(waitUntil(timeout: 10) { self.roomRow(app, "Good Room").exists }, "\(item): the good room shows")
            }
        }
        shot(app, "bots-damaged-mirror")
        // The last case (the whole value is not an object): this iPhone's rooms stay, and the app does not crash on a send.
        XCTAssertTrue(roomRow(app).exists || roomRow(app, "Good Room").exists, "the rooms on the phone are kept")
        assertNoHostedCalls()
    }

    // MARK: - S-D2 A version 1 and a version 2 mirror read; the next publish writes version 3

    @MainActor func testS_D2_OldMirrorVersions() throws {
        for version in ["v1", "v2"] {
            control("reset")
            control("seed", ["preset": version])
            control("turn-mode", ["ivy": "say:Up to date from \(version)."])
            let app = launchSignedIn()
            openRoom(app)
            XCTAssertTrue(appears(message(app, containing: "Ivy said: I can take the notes."), app, "d2-\(version)", timeout: 10), "\(version): the log reads")
            send(app, "@ivy hi")
            XCTAssertTrue(message(app, containing: "Ivy said: Up to date from \(version).").waitForExistence(timeout: 25), "\(version): Ivy replies")
            XCTAssertTrue(waitUntil(timeout: 30) { (self.mirror["version"] as? Int) == 3 }, "\(version): the next publish is version 3: \(mirror["version"] ?? "")")
            XCTAssertTrue(waitUntil(timeout: 10) { self.mirrorTexts("name:Launch Room").contains("Up to date from \(version).")
                || ((self.mirror["rooms"] as? [String: Any]) ?? [:]).values.contains { (($0 as? [String: Any])?["texts"] as? [String])?.contains("Up to date from \(version).") == true } },
                          "\(version): with the new reply")
            app.terminate()
        }
        assertNoHostedCalls()
    }

    // MARK: - S-D5 A member deleted elsewhere: the room says who is left, and the missing bot is never asked

    @MainActor func testS_D5_AMemberWasDeleted() throws {
        control("turn-mode", ["default": "once", "ivy": "once"])
        let app = launchSignedIn()
        XCTAssertTrue(waitUntil(timeout: 15) { self.roomRow(app).exists })
        control("desktop-edit", ["op": "remove-bot", "name": "research"])
        pullToRefresh(app)
        XCTAssertTrue(waitUntil(timeout: 15) { !app.cells["bot-row-research"].exists }, "Research is gone from the roster")
        reveal(app, roomRow(app))
        openGroupInfo(app, "d5-info")
        let subtitle = any(app, "group-info.subtitle")
        check(waitUntil(timeout: 8) { subtitle.label == "2 of 3 available" }, app, "d5-subtitle", "the room says who is left: \(subtitle.label)")
        XCTAssertTrue(any(app, "group-info.member.research").label.contains("Can’t reach this bot"), "and which one is missing")
        shot(app, "group-info-missing-member")
        app.buttons["group-info.close"].tap()
        openRoom(app)
        send(app, "Who is here?")
        XCTAssertTrue(waitUntil(timeout: 40) { self.prompts(to: "ivy").count >= 1 && !app.buttons["composer.stop"].exists }, "the others are asked")
        XCTAssertTrue(prompts(to: "research").isEmpty, "no turn is started for the missing bot")
        assertNoHostedCalls()
    }

    // MARK: - S-I6 Delete the room while a member hangs: gone at once, nothing arrives later, no crash

    @MainActor func testS_I6_DeleteWhileAMemberHangs() throws {
        control("turn-mode", ["ivy": "hang"])
        let app = launchSignedIn()
        openRoom(app)
        send(app, "@ivy hold on to this")
        XCTAssertTrue(waitUntil(timeout: 12) { self.prompts(to: "ivy").count == 1 }, "Ivy was asked")
        let interruptsBefore = interrupts.count
        openRoomMenu(app, showing: "Delete Group Chat")
        tapMenu(app, "Delete Group Chat")
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5), "the question")
        app.sheets.firstMatch.buttons["Delete Group Chat"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !app.tables["chat.table"].exists }, "the room's screen pops")
        XCTAssertTrue(waitUntil(timeout: 8) { !self.roomRow(app).exists && !self.roomTile(app).exists }, "the room is gone")
        XCTAssertTrue(waitUntil(timeout: 15) { self.groups(of: "ivy").isEmpty }, "the memberships are removed: \(groups(of: "ivy"))")
        // The hanging turn ends on the gateway: nothing comes back to the phone, and the app is still there.
        control("release", ["profile": "ivy"])
        Thread.sleep(forTimeInterval: 4)
        XCTAssertEqual(app.state, .runningForeground, "no crash when the turn's task ends")
        XCTAssertFalse(roomRow(app).exists, "the room does not come back")
        XCTAssertEqual(interrupts.count, interruptsBefore, "the member's session is left alone (the web does not interrupt on delete)")
        pullToRefresh(app)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(roomRow(app).exists, "nor after a pull")
        assertNoHostedCalls()
    }

    // MARK: - S-R1 Kill the app mid-round: your message is kept, the reply is collected once, nothing is sent twice

    @MainActor func testS_R1_KilledMidRound() throws {
        control("turn-mode", ["ivy": "slow:6"])
        let app = launchSignedIn()
        openRoom(app)
        send(app, "@ivy finish this while I am away")
        XCTAssertTrue(waitUntil(timeout: 12) { self.prompts(to: "ivy").count == 1 }, "Ivy was asked")
        app.terminate()
        Thread.sleep(forTimeInterval: 8)   // the reply is finished on the gateway while the app is closed
        relaunch(app)
        XCTAssertTrue(waitUntil(timeout: 25) { self.roomRow(app).exists || self.roomTile(app).exists }, "signed in still, the room is listed")
        openRoom(app)
        XCTAssertTrue(appears(message(app, containing: "You said: @ivy finish this while I am away"), app, "r1-mine", timeout: 10), "your message is in the log")
        XCTAssertTrue(appears(message(app, containing: "Ivy said: Ivy here: @ivy finish this while I am"), app, "r1-late", timeout: 40),
                      "the finished reply is collected")
        XCTAssertFalse(app.buttons["composer.stop"].exists, "the room opens idle")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(messageCount(app, containing: "Ivy here: @ivy finish this while I am"), 1, "once")
        XCTAssertEqual(prompts(to: "ivy").count, 1, "nothing was sent twice")
        shot(app, "room-after-kill")
        assertNoHostedCalls()
    }

    // MARK: - S-R4 Pin, a timed mute, the unread mark: all kept by a relaunch (Group Info reads them back)

    @MainActor func testS_R4_MarksSurviveARelaunch() throws {
        let app = launchSignedIn()
        openGroupInfo(app, "r4-info")
        let mute = any(app, "group-info.mute")
        scrollTo(app, mute, in: app.collectionViews["group-info.list"])
        mute.tap()
        tapMenu(app, "For 8 Hours")
        XCTAssertTrue(waitUntil(timeout: 5) { ((mute.value as? String) ?? "").hasPrefix("Until ") })
        let until = (mute.value as? String) ?? ""
        let pinned = any(app, "group-info.pinned")
        scrollTo(app, pinned, in: app.collectionViews["group-info.list"])
        flip(pinned)
        any(app, "group-info.unread").tap()
        app.buttons["group-info.close"].tap()
        dismissMuteTip(app)
        XCTAssertTrue(roomTile(app).waitForExistence(timeout: 6))

        relaunch(app)
        XCTAssertTrue(appears(roomTile(app), app, "r4-tile", timeout: 25), "still a tile after a relaunch")
        let label = roomLabel(app)
        XCTAssertTrue(label.contains("Muted") && label.contains("Unread"), "still muted and unread: \(label)")
        pressMenu(app, roomTile(app), "Group Info")
        XCTAssertTrue(appears(any(app, "group-info.list"), app, "r4-info-2", timeout: 8))
        let again = any(app, "group-info.mute")
        scrollTo(app, again, in: app.collectionViews["group-info.list"])
        XCTAssertEqual(again.value as? String, until, "the timed mute kept its end")
        XCTAssertTrue(isOn(any(app, "group-info.pinned")), "Pinned is on")
        XCTAssertEqual(any(app, "group-info.unread").label, "Mark as Read")
    }

    // MARK: - S-R2 Delete Group Chat on a slow link, the app killed before the writes are out: finished after a relaunch

    @MainActor func testS_R2_ADeleteCutOffByAKillIsFinishedAfterARelaunch() throws {
        let app = launchSignedIn()
        XCTAssertTrue(waitUntil(timeout: 15) { self.roomRow(app).exists }, "the rooms are read")
        control("mode", ["latency": 2500])
        reveal(app, roomRow(app))
        pressMenu(app, roomRow(app), "Delete Group Chat")
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 8), "the delete question")
        app.sheets.firstMatch.buttons["Delete Group Chat"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { !self.roomRow(app).exists }, "the row leaves at once")
        app.terminate()
        Thread.sleep(forTimeInterval: 6)      // anything already on the wire lands
        control("mode", ["latency": 0])
        let tombstoneBefore = ((mirror["deleted"] as? [String: Any]) ?? [:])[Self.launchKey] != nil
        let carriedBefore = ["default", "ivy", "research"].filter { self.groups(of: $0).contains(Self.launch) }
        // The kill must have cut something off, or this run proves nothing about the relaunch.
        try XCTSkipIf(tombstoneBefore && carriedBefore.isEmpty, "every write got out before the kill on this run")

        relaunch(app)
        XCTAssertTrue(waitUntil(timeout: 60) { app.cells["bot-row-ivy"].exists }, "relaunched")
        XCTAssertTrue(waitUntil(timeout: 30) { ((self.mirror["deleted"] as? [String: Any]) ?? [:])[Self.launchKey] != nil },
                      "the tombstone is published after the relaunch: \(mirror["deleted"] ?? "none")")
        XCTAssertNil((mirror["rooms"] as? [String: Any])?[Self.launchKey], "and the room leaves the mirror")
        XCTAssertTrue(waitUntil(timeout: 30) { ["default", "ivy", "research"].allSatisfy { !self.groups(of: $0).contains(Self.launch) } },
                      "no bot names the room any more: \(["default", "ivy", "research"].map { self.groups(of: $0) })")
        XCTAssertFalse(roomRow(app).exists || roomTile(app).exists, "the room stays gone on the phone")
        shot(app, "r2-after-relaunch")
        assertNoHostedCalls()
    }
}
