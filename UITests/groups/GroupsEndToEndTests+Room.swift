// The room as a chat (docs/spec/3x-groups.md §6, §7.13, §7.14): who is asked, the prompt and the hidden session on the
// wire, typing, pass, holds, Stop, failures, late replies, questions, what another device does, and the menus.

import XCTest

extension GroupsEndToEndTests {
    /// The room session the fixture holds for `profile` (the newest one).
    func roomSession(_ profile: String) -> [String: Any]? {
        sessions.last { $0["profile"] as? String == profile && (($0["title"] as? String) ?? "").hasPrefix("Group: ") }
    }

    func prompts(to profile: String) -> [[String: Any]] { prompts.filter { $0["profile"] as? String == profile } }

    // MARK: - D1 An @mention asks one bot; its reply lands; the wire is the web's (L372)

    @MainActor func testD1_MentionAsksOneBotAndItsReplyLands() throws {
        let app = launchSignedIn()
        openRoom(app)
        // The log this device got from the mirror, with who said what.
        XCTAssertTrue(appears(message(app, containing: "Ivy said: I can take the notes."), app, "d1-seed", timeout: 10), "Ivy's seeded message")
        XCTAssertTrue(message(app, containing: "Research said: The list is ready: 14 changes.").exists, "Research's")
        XCTAssertTrue(message(app, containing: "Hermes said: I will draft the summary once the list is in.").exists
                      || message(app, containing: "Who can take the release notes?").exists, "the earlier thread is above")
        XCTAssertTrue(message(app, containing: "Thanks. Who writes them up?").exists, "your own message")
        let title = any(app, "chat.title")
        check(title.exists && title.label.contains("Launch Room"), app, "d1-title", "the title names the room: \(title.exists ? title.label : "missing")")
        // A room's composer has no attachments (§7.13); voice memos it has (tester 2026-11-05, D14).
        XCTAssertFalse(app.buttons["composer.plus"].exists, "no attach button in a room")
        XCTAssertTrue(app.buttons["composer.mic"].exists, "the microphone, for a voice memo")
        XCTAssertEqual(app.buttons["chat.more"].label, "Group chat actions")
        shot(app, "room")

        // A reply long enough to be seen in the making even when every look at the screen takes seconds (a busy Mac).
        control("turn-mode", ["ivy": "slow:45"])
        send(app, "@ivy what's next?")
        XCTAssertTrue(message(app, containing: "You said: @ivy what's next?").waitForExistence(timeout: 8), "your bubble")
        XCTAssertTrue(waitUntil(timeout: 12) { self.prompts.count == 1 }, "one bot was asked")
        let typing = any(app, "chat.typing")
        let typingWords = typing.waitForExistence(timeout: 6) ? typing.label : "missing"
        check(typingWords.contains("Ivy is replying"), app, "d1-typing", "the typing row names Ivy: \(typingWords)")
        XCTAssertTrue(app.buttons["composer.stop"].exists, "Stop shows while a bot replies")
        shot(app, "room-replying")
        XCTAssertTrue(appears(message(app, containing: "Ivy said: Ivy here: @ivy what's next?"), app, "d1-reply", timeout: 120), "Ivy's reply")
        XCTAssertTrue(waitUntil(timeout: 8) { !app.buttons["composer.stop"].exists && !typing.exists }, "the round ended")
        shot(app, "room-replied")

        // The wire: one prompt, to Ivy only, the template byte for byte, sent to a hidden room session by its runtime id.
        Thread.sleep(forTimeInterval: 2)
        let asked = prompts
        XCTAssertEqual(asked.map { $0["profile"] as? String }, ["ivy"], "only the mentioned bot is asked")
        XCTAssertEqual(asked.first?["promptOk"] as? Bool, true, "the prompt is the template: \(asked.first?["problems"] ?? "")")
        XCTAssertEqual(asked.first?["by"] as? String, "runtime")
        let text = (asked.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.hasPrefix("[Group chat: \"Launch Room\"] You are @ivy, one participant in a group chat with "), text)
        XCTAssertTrue(text.contains("\n  You (user): @ivy what's next?\n"), "the window holds your message")
        XCTAssertFalse(text.contains("I can take the notes."), "another thread's messages are not in the window")
        let session = try XCTUnwrap(roomSession("ivy"))
        XCTAssertEqual(session["plumbingOk"] as? Bool, true, "hidden + room_plumbing: \(session)")
        XCTAssertEqual(session["follow_profile_config"] as? Bool, true)
        XCTAssertTrue(((session["title"] as? String) ?? "").hasPrefix("Group: rmfixture-launch · t"), "\(session["title"] ?? "")")
        XCTAssertNotEqual(session["stored"] as? String, session["runtime"] as? String)
        XCTAssertEqual(calls("session.create"), 1, "one session for the one member asked")
        // The mirror carries both new entries for the other devices.
        XCTAssertTrue(waitUntil(timeout: 20) {
            let texts = self.mirrorTexts()
            return texts.contains("@ivy what's next?") && texts.contains("Ivy here: @ivy what's next?")
        }, "the mirror has the send and the reply: \(mirrorTexts())")
        assertNoHostedCalls()
    }

    // MARK: - D2 No mention: everyone is asked in roster order; (pass) is silence; the round settles (L372)

    @MainActor func testD2_EveryoneIsAskedAndAPassIsSilent() throws {
        control("turn-mode", ["default": "once:Hermes will draft it.", "ivy": "once:Ivy can review.", "research": "pass"])
        let app = launchSignedIn()
        openRoom(app)
        send(app, "Who has time today?")
        XCTAssertTrue(appears(message(app, containing: "Hermes said: Hermes will draft it."), app, "d2-hermes", timeout: 25), "Hermes replies")
        XCTAssertTrue(message(app, containing: "Ivy said: Ivy can review.").waitForExistence(timeout: 20), "Ivy replies")
        // The room on screen shows the reply itself: nothing peeks over its title.
        check(!any(app, "reply-peek").exists, app, "d2-peek", "no alert peeks over the room that is on screen")
        XCTAssertTrue(waitUntil(timeout: 40) { !app.buttons["composer.stop"].exists }, "the round settles by itself")
        XCTAssertFalse(message(app, containing: "(pass)").exists, "a pass is never shown")
        XCTAssertEqual(messageCount(app, containing: "Hermes will draft it."), 1, "each reply once")
        let order = prompts.map { ($0["profile"] as? String) ?? "" }
        XCTAssertEqual(Array(order.prefix(3)), ["default", "ivy", "research"], "asked in the roster's order: \(order)")
        XCTAssertTrue(order.count <= 9, "never past three rounds: \(order)")
        XCTAssertTrue(prompts.allSatisfy { $0["promptOk"] as? Bool == true }, "every prompt is the template")
        XCTAssertTrue(prompts.allSatisfy { ($0["inFlightForRoom"] as? Int) == 0 }, "one member at a time")
        // Ivy's window names Hermes's reply with its label, and only its own line would say (you).
        let ivy = try XCTUnwrap(prompts(to: "ivy").first?["text"] as? String)
        XCTAssertTrue(ivy.contains("  You (user): Who has time today?\n  Hermes: Hermes will draft it.\n"), ivy)
        shot(app, "room-round")

        // Activity lists the round, newest first.
        openRoomMenu(app, showing: "Activity")
        tapMenu(app, "Activity")
        let list = any(app, "group-activity.list")
        XCTAssertTrue(appears(list, app, "d2-activity", timeout: 8), "the Activity page")
        XCTAssertTrue(textContaining(app, "Turn settled").waitForExistence(timeout: 4), "Activity says: Turn settled (newest first)")
        shot(app, "group-activity")
        // Newest first, so the send is the last line of a lazy list: read down it.
        for line in ["Research passed", "Ivy replied", "Hermes replied", "You sent a message"] {
            let row = textContaining(app, line)
            scrollTo(app, row, in: list)
            check(row.exists, app, "d2-activity-\(line)", "Activity says: \(line)")
        }
        assertNoHostedCalls()
    }

    // MARK: - D3 "@ivy stop" holds Ivy; the capsule says so; Resume releases (L372)

    @MainActor func testD3_StopWordHoldsAMemberAndResumeReleases() throws {
        control("turn-mode", ["default": "once", "ivy": "once", "research": "once"])
        let app = launchSignedIn()
        openRoom(app)
        send(app, "@ivy stop")
        let paused = any(app, "room.paused")
        check(paused.waitForExistence(timeout: 10) && paused.label.contains("Ivy is paused"), app, "d3-paused",
              "the capsule says Ivy is paused: \(paused.exists ? paused.label : "missing")")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(prompts.isEmpty, "a held bot is not asked: \(prompts.map { $0["profile"] ?? "" })")
        shot(app, "room-paused")
        // A held bot is skipped by a later round too, and says so in Activity.
        send(app, "Anything else?")
        XCTAssertTrue(waitUntil(timeout: 30) { self.prompts(to: "research").count >= 1 }, "the others are asked")
        XCTAssertTrue(waitUntil(timeout: 30) { !app.buttons["composer.stop"].exists })
        XCTAssertTrue(prompts(to: "ivy").isEmpty, "Ivy stays held")
        XCTAssertTrue(paused.exists, "still paused")

        // Resume: "@all resume" goes into the room and Ivy is asked what it missed.
        let resume = app.buttons["room.resume"]
        XCTAssertTrue(resume.exists, "Resume")
        resume.tap()
        XCTAssertTrue(message(app, containing: "You said: @all resume").waitForExistence(timeout: 8), "Resume posts @all resume")
        XCTAssertTrue(waitUntil(timeout: 10) { !paused.exists }, "the capsule goes")
        XCTAssertTrue(waitUntil(timeout: 30) { self.prompts(to: "ivy").count >= 1 }, "Ivy is asked again")
        let text = (prompts(to: "ivy").first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("@all resume"), "its window has the resume: \(text.prefix(400))")
        XCTAssertTrue(waitUntil(timeout: 40) { !app.buttons["composer.stop"].exists })
        shot(app, "room-resumed")
        assertNoHostedCalls()
    }

    // MARK: - D4 Stop interrupts the reply in flight by its runtime id; a gateway that cannot confirm says so (L467)

    @MainActor func testD4_StopInterruptsByRuntimeId() throws {
        control("turn-mode", ["ivy": "hang"])
        let app = launchSignedIn()
        openRoom(app)
        send(app, "@ivy a long job please")
        XCTAssertTrue(waitUntil(timeout: 15) { self.prompts.count == 1 && self.prompts.first?["accepted"] as? Bool == true }, "Ivy took the turn")
        let stop = app.buttons["composer.stop"]
        XCTAssertTrue(appears(stop, app, "d4-stop", timeout: 8), "the composer's Stop")
        shot(app, "room-stop")
        stop.tap()
        XCTAssertTrue(waitUntil(timeout: 15) { !self.interrupts.isEmpty }, "the gateway was asked to stop")
        XCTAssertTrue(waitUntil(timeout: 10) { !stop.exists }, "Stop goes at once")
        let paused = any(app, "room.paused")
        check(paused.waitForExistence(timeout: 8) && paused.label.contains("3 bots paused"), app, "d4-paused",
              "the room is paused: \(paused.exists ? paused.label : "missing")")
        Thread.sleep(forTimeInterval: 2)
        let asked = interrupts
        XCTAssertEqual(asked.count, 1, "one interrupt: \(asked)")
        XCTAssertEqual(asked.first?["by"] as? String, "runtime", "by the runtime id, not the stored one: \(asked)")
        XCTAssertEqual(asked.first?["status"] as? String, "interrupted")
        XCTAssertNotEqual(asked.first?["session_id"] as? String, asked.first?["stored"] as? String)
        XCTAssertEqual(asked.first?["profile"] as? String, "ivy")
        XCTAssertFalse(app.alerts.firstMatch.exists, "a confirmed stop shows no alert")
        XCTAssertFalse(message(app, containing: "Ivy here").exists, "the stopped reply never lands")
        shot(app, "room-stopped")

        // The paused capsule lists who is paused.
        paused.tap()
        let list = app.alerts["Paused Bots"]
        XCTAssertTrue(list.waitForExistence(timeout: 5), "Paused Bots")
        XCTAssertTrue(list.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Ivy'")).firstMatch.exists)
        shot(app, "room-paused-list")
        list.buttons["Done"].tap()

        // Resume, then a gateway that cannot confirm the stop: the room still stops here and says so.
        openRoomMenu(app, showing: "Resume All")
        shot(app, "room-more-paused")
        tapMenu(app, "Resume All")
        XCTAssertTrue(waitUntil(timeout: 20) { self.prompts(to: "ivy").count >= 2 }, "Ivy is asked again after the resume")
        XCTAssertTrue(stop.waitForExistence(timeout: 8))
        control("fail", ["method": "session.interrupt", "mode": "error", "count": 5])
        openRoomMenu(app, showing: "Stop All")
        shot(app, "room-more-running")
        tapMenu(app, "Stop All")
        let alert = app.alerts["Couldn’t Confirm Stop"]
        check(alert.waitForExistence(timeout: 20), app, "d4-alert", "Couldn’t Confirm Stop")
        XCTAssertTrue(alert.staticTexts["The group chat is paused, but the computer running Hermes couldn’t confirm that the current reply stopped."].exists)
        shot(app, "room-stop-unconfirmed")
        alert.buttons["OK"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !stop.exists }, "stopped here all the same")
        control("release", ["profile": "ivy"])
        assertNoHostedCalls()
    }

    // MARK: - D5 No bot took the send: Not Delivered, Try Again, the alert on a second failure, Delete (L372)

    @MainActor func testD5_NotDeliveredTryAgainAndDelete() throws {
        control("turn-mode", ["default": "fail", "ivy": "fail", "research": "fail"])
        let app = launchSignedIn()
        openRoom(app)
        send(app, "Is anyone there?")
        let line = textContaining(app, "Not Delivered")
        check(line.waitForExistence(timeout: 40), app, "d5-line", "Not Delivered under your bubble")
        shot(app, "room-not-delivered")
        // Try Again while the bots still fail: the alert gives the reason.
        line.tap()
        let alert = app.alerts["Couldn’t Deliver"]
        check(alert.waitForExistence(timeout: 40), app, "d5-alert", "Couldn’t Deliver")
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'model unavailable'")).firstMatch.exists, "with the reason")
        shot(app, "room-couldnt-deliver")
        // The bots are back: Try Again from the alert delivers the same message (not a second copy).
        control("turn-mode", ["default": "once", "ivy": "pass", "research": "pass"])
        alert.buttons["Try Again"].tap()
        XCTAssertTrue(message(app, containing: "Hermes said: Hermes here: Is anyone there?").waitForExistence(timeout: 40), "delivered on the retry")
        XCTAssertTrue(waitUntil(timeout: 10) { !self.textContaining(app, "Not Delivered").exists }, "the line goes")
        XCTAssertEqual(messageCount(app, containing: "You said: Is anyone there?"), 1, "your message is there once")

        // A send nobody takes can be deleted from its hold menu.
        control("turn-mode", ["default": "fail", "ivy": "fail", "research": "fail"])
        XCTAssertTrue(waitUntil(timeout: 40) { !app.buttons["composer.stop"].exists })
        send(app, "Delete me")
        XCTAssertTrue(textContaining(app, "Not Delivered").waitForExistence(timeout: 40))
        let mine = message(app, containing: "You said: Delete me")
        holdMenu(app, mine, showing: "Send Again")
        let titles = menuTitles(app, among: ["Copy", "Reply", "Mention", "Send Again", "Delete"])
        check(titles == ["Copy", "Reply", "Send Again", "Delete"], app, "d5-menu", "Copy, Reply, Send Again, Delete: \(titles)")
        shot(app, "room-undelivered-menu")
        tapMenu(app, "Delete")
        check(waitUntil(timeout: 8) { !mine.exists }, app, "d5-deleted", "the message leaves")
        XCTAssertTrue(waitUntil(timeout: 20) { !self.mirrorTexts().contains("Delete me") }, "and leaves the mirror: \(mirrorTexts())")
        // The copy the mirror had is not merged back in: it stays gone here and there.
        Thread.sleep(forTimeInterval: 6)
        XCTAssertFalse(mine.exists, "the deleted message does not come back")
        XCTAssertFalse(mirrorTexts().contains("Delete me"), "nor does its mirror copy")
        XCTAssertEqual(messageCount(app, containing: "You said: Is anyone there?"), 1, "the delivered message is untouched")
        assertNoHostedCalls()
    }

    // MARK: - D6 Slash commands are refused with a notice; nothing is sent (L372)

    @MainActor func testD6_SlashCommandsAreRefused() throws {
        let app = launchSignedIn()
        openRoom(app)
        let before = mirrorRevision
        send(app, "/model")
        let notice = textContaining(app, "Slash commands are not supported in group chats.")
        check(notice.waitForExistence(timeout: 6), app, "d6-notice", "the notice")
        XCTAssertEqual(app.textViews["composer.text"].value as? String, "/model", "the words stay in the field")
        XCTAssertFalse(message(app, containing: "You said: /model").exists, "nothing joins the room")
        shot(app, "room-slash-notice")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(prompts.isEmpty && mirrorRevision == before, "nothing was sent or written")
        XCTAssertFalse(any(app, "commands.sheet").exists, "no command list in a room")
    }

    // MARK: - D7 A member's question and approval come to you in the room (L372)

    @MainActor func testD7_QuestionsAndApprovalsFromAMember() throws {
        control("turn-mode", ["ivy": "clarify"])
        let app = launchSignedIn()
        openRoom(app)
        send(app, "@ivy book the trip")
        let dock = any(app, "question.dock")
        check(dock.waitForExistence(timeout: 25), app, "d7-dock", "Ivy's question shows")
        XCTAssertTrue(textContaining(app, "Which city should I book?").exists, "its text")
        XCTAssertTrue(text(app, "Ivy asks").exists || textContaining(app, "Ivy asks").exists, "the note over it names the member who asks")
        shot(app, "room-question")
        backToList(app)
        reveal(app, roomRow(app))
        XCTAssertTrue(waitUntil(timeout: 10) { self.roomLabel(app).contains("Waiting for your reply") }, "the row says so: \(roomLabel(app))")
        shot(app, "room-row-waiting")
        openRoom(app)
        XCTAssertTrue(dock.waitForExistence(timeout: 10), "the question is still there")
        let choice = any(app, "question.choice.0")
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
        let primary = app.buttons["question.primary"]
        if primary.waitForExistence(timeout: 2), primary.isEnabled { primary.tap() }
        XCTAssertTrue(appears(message(app, containing: "Ivy said: Thanks: Lisbon"), app, "d7-answer", timeout: 25), "Ivy goes on with the answer")
        XCTAssertTrue(waitUntil(timeout: 8) { !dock.exists }, "the dock goes")

        // An approval: the card, Allow Once, the member goes on.
        control("turn-mode", ["ivy": "approval"])
        send(app, "@ivy push it")
        let card = any(app, "approval.card")
        check(card.waitForExistence(timeout: 25), app, "d7-card", "the approval card")
        XCTAssertTrue(textContaining(app, "git push origin main").exists, "its command")
        check(textContaining(app, "Ivy wants to run: git push origin main").exists, app, "d7-asker", "the card's heading names the member and the command")
        shot(app, "room-approval")
        let once = app.buttons["approval.run"]
        check(once.waitForExistence(timeout: 5), app, "d7-run", "the card's Run button")
        once.tap()
        XCTAssertTrue(appears(message(app, containing: "Ivy said: Approved (once): pushed."), app, "d7-approved", timeout: 25), "Ivy goes on")
        assertNoHostedCalls()
    }

    // MARK: - D8 Another device: a message appears once; a rename follows; a delete closes the room (L372, L195)

    @MainActor func testD8_AnotherDeviceAppendsRenamesAndDeletes() throws {
        let app = launchSignedIn()
        openRoom(app)
        XCTAssertTrue(message(app, containing: "I can take the notes.").waitForExistence(timeout: 10))
        control("desktop-edit", ["op": "append", "room": "Launch Room", "from": "research", "text": "Posted from the desktop."])
        XCTAssertTrue(appears(message(app, containing: "Research said: Posted from the desktop."), app, "d8-append", timeout: 45),
                      "a message from another device shows without leaving the room")
        Thread.sleep(forTimeInterval: 6)
        XCTAssertEqual(messageCount(app, containing: "Posted from the desktop."), 1, "once")
        XCTAssertEqual(messageCount(app, containing: "Ivy said: I can take the notes."), 1, "and nothing is doubled")
        control("desktop-edit", ["op": "rename", "room": "Launch Room", "to": "Release Room"])
        let title = any(app, "chat.title")
        XCTAssertTrue(waitUntil(timeout: 45) { title.exists && title.label.contains("Release Room") }, "the title follows a rename elsewhere: \(title.label)")
        shot(app, "room-renamed")
        control("desktop-edit", ["op": "delete", "room": "Release Room"])
        XCTAssertTrue(waitUntil(timeout: 45) { !app.tables["chat.table"].exists }, "a room deleted elsewhere closes")
        let pill = textContaining(app, "was deleted")
        check(pill.waitForExistence(timeout: 6), app, "d8-pill", "and says it was deleted")
        shot(app, "room-deleted-elsewhere")
        XCTAssertTrue(waitUntil(timeout: 10) { !self.roomRow(app, "Release Room").exists && !self.roomRow(app).exists }, "its row is gone")
    }

    // MARK: - D9 A bot that takes too long is skipped, and its late reply still lands (L372)

    @MainActor func testD9_TooLongThenALateReply() throws {
        control("turn-mode", ["ivy": "late:Sorry, that took a while.", "research": "once"])
        let app = launchSignedIn(["-HQGroupsTurnLimit", "6"])
        openRoom(app)
        send(app, "@ivy @research status?")
        // Ivy is skipped after the limit and Research is asked.
        XCTAssertTrue(appears(message(app, containing: "Research said: Research here: @ivy @research status?"), app, "d9-research", timeout: 60),
                      "the round goes on without Ivy")
        XCTAssertTrue(waitUntil(timeout: 30) { !app.buttons["composer.stop"].exists })
        XCTAssertFalse(message(app, containing: "Ivy said: Sorry, that took a while.").exists, "nothing from Ivy yet")
        // The reply arrives after all: it joins the room as a late reply, once.
        control("release", ["profile": "ivy"])
        XCTAssertTrue(appears(message(app, containing: "Ivy said: Sorry, that took a while."), app, "d9-late", timeout: 40), "the late reply lands")
        Thread.sleep(forTimeInterval: 4)
        XCTAssertEqual(messageCount(app, containing: "Sorry, that took a while."), 1)
        XCTAssertEqual(prompts(to: "ivy").count, 1, "Ivy was asked once")
        shot(app, "room-late-reply")
        // Activity tells both halves.
        openRoomMenu(app, showing: "Activity")
        tapMenu(app, "Activity")
        let list = any(app, "group-activity.list")
        XCTAssertTrue(appears(list, app, "d9-activity", timeout: 8), "the Activity page")
        for line in ["Ivy delivered a late reply", "Ivy took too long"] {
            let row = textContaining(app, line)
            scrollTo(app, row, in: list)
            check(row.exists, app, "d9-activity-\(line)", "Activity says: \(line)")
        }
        shot(app, "group-activity-too-long")
        assertNoHostedCalls()
    }

    // MARK: - D10 The ⋯ menu, Find in Chat, Group Info and Delete from the room (L372, L233)

    @MainActor func testD10_RoomMoreMenu() throws {
        let app = launchSignedIn()
        openRoom(app)
        openRoomMenu(app)
        let idle = menuTitles(app, among: ["Find in Chat", "Group Info", "Add Bots…", "Activity", "Stop All", "Resume All", "Delete Group Chat"])
        check(idle == ["Find in Chat", "Group Info", "Add Bots…", "Activity", "Delete Group Chat"], app, "d10-menu", "the idle room's menu: \(idle)")
        shot(app, "room-more")
        tapMenu(app, "Find in Chat")
        let field = any(app, "chat.find.field")
        XCTAssertTrue(appears(field, app, "d10-find", timeout: 5), "Find in Chat")
        field.typeText("notes")
        XCTAssertTrue(waitUntil(timeout: 5) { self.any(app, "chat.find.count").exists }, "it counts matches")
        shot(app, "room-find")
        any(app, "chat.find.done").tap()

        openRoomMenu(app)
        tapMenu(app, "Group Info")
        XCTAssertTrue(appears(any(app, "group-info.list"), app, "d10-info", timeout: 8), "Group Info opens")
        any(app, "group-info.close").tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !self.any(app, "group-info.list").exists })

        // Offline: what needs the gateway leaves the menu; the rest stays.
        control("mode", ["offline": true])
        let offline = waitUntil(timeout: 45) {
            self.openRoomMenu(app, showing: "Activity")
            let gone = !app.buttons["Delete Group Chat"].firstMatch.exists && !app.buttons["Add Bots…"].firstMatch.exists
            if !gone { self.closeMenu(app) }
            return gone
        }
        check(offline, app, "d10-offline", "offline: no Add Bots… and no Delete Group Chat")
        XCTAssertTrue(app.buttons["Group Info"].firstMatch.exists && app.buttons["Activity"].firstMatch.exists)
        shot(app, "room-more-offline")
        closeMenu(app)
        control("mode", ["offline": false])

        // Delete from the room: the same question, then back to the list.
        let online = waitUntil(timeout: 45) {
            self.openRoomMenu(app, showing: "Activity")
            let back = app.buttons["Delete Group Chat"].firstMatch.exists
            if !back { self.closeMenu(app) }
            return back
        }
        XCTAssertTrue(online, "Delete Group Chat is back when the gateway is")
        tapMenu(app, "Delete Group Chat")
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5) && text(app, "Delete “Launch Room”?").exists, "the delete question")
        sheet.buttons["Delete Group Chat"].tap()
        XCTAssertTrue(waitUntil(timeout: 15) { !app.tables["chat.table"].exists }, "the room closes")
        XCTAssertTrue(waitUntil(timeout: 15) { !self.groups(of: "ivy").contains("Launch Room") })
    }

    // MARK: - D11 Reply answers in the message's thread; Mention adds the sender's tag (L372)

    @MainActor func testD11_ReplyInThreadAndMention() throws {
        let app = launchSignedIn()
        openRoom(app)
        let seeded = message(app, containing: "Ivy said: I can take the notes.")
        XCTAssertTrue(seeded.waitForExistence(timeout: 10))
        holdMenu(app, seeded, showing: "Reply")
        let titles = menuTitles(app, among: ["Copy", "Reply", "Mention", "Send Again", "Delete", "Regenerate", "Branch in New Chat", "Read Aloud"])
        check(titles == ["Copy", "Reply", "Mention"], app, "d11-menu", "a member's message: Copy, Reply, Mention: \(titles)")
        shot(app, "room-message-menu")
        tapMenu(app, "Reply")
        let chip = any(app, "room.reply")
        check(chip.waitForExistence(timeout: 5) && chip.label.contains("Ivy") && chip.label.contains("I can take the notes."), app, "d11-chip",
              "the reply chip: \(chip.exists ? chip.label : "missing")")
        shot(app, "room-reply-chip")
        // Cancel, then reply for real.
        app.buttons["room.reply.cancel"].tap()
        XCTAssertTrue(waitUntil(timeout: 4) { !chip.exists }, "the chip can be closed")
        holdMenu(app, seeded, showing: "Reply")
        tapMenu(app, "Reply")
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        control("turn-mode", ["default": "pass", "ivy": "once", "research": "pass"])
        let field = app.textViews["composer.text"]
        field.typeText("Thanks Ivy")
        app.buttons["composer.send"].tap()
        check(waitUntil(timeout: 30) { self.prompts(to: "ivy").count == 1 }, app, "d11-asked",
              "Ivy is asked: \(prompts.map { "\($0["profile"] ?? "")/\($0["title"] ?? "")" })")
        XCTAssertTrue(waitUntil(timeout: 6) { !chip.exists }, "the chip goes with the send")
        // The reply went into the seeded thread: its session title ends with that thread, and the window has the thread's earlier lines.
        let title = (prompts(to: "ivy").first?["title"] as? String) ?? ""
        XCTAssertEqual(title, "Group: rmfixture-launch · tfixture-two", "the reply stays in the message's thread")
        let window = (prompts(to: "ivy").first?["text"] as? String) ?? ""
        XCTAssertTrue(window.contains("  You (user): Thanks. Who writes them up?") && window.contains("  You (user): Thanks Ivy"), window)
        XCTAssertTrue(window.contains("  Ivy (you): I can take the notes."), "its own earlier line is marked (you)")
        XCTAssertTrue(waitUntil(timeout: 40) { !app.buttons["composer.stop"].exists })

        // Mention puts the sender's tag in the field.
        let research = message(app, containing: "Research said: The list is ready: 14 changes.")
        holdMenu(app, research, showing: "Mention")
        tapMenu(app, "Mention")
        XCTAssertTrue(waitUntil(timeout: 5) { (field.value as? String) == "@research " }, "the field holds @research: \(field.value ?? "")")
        shot(app, "room-mention-inserted")
    }

    // MARK: - D12 Typing @ suggests the members; picking one completes it (L372)

    @MainActor func testD12_MentionSuggestions() throws {
        let app = launchSignedIn()
        openRoom(app)
        let field = app.textViews["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText("@")
        let list = any(app, "room.mentions")
        check(list.waitForExistence(timeout: 5), app, "d12-list", "the suggestions")
        for tag in ["everyone", "hermes", "ivy", "research"] {
            XCTAssertTrue(any(app, "room.mention.\(tag)").exists, "@\(tag) is offered")
        }
        shot(app, "room-mentions")
        field.typeText("re")
        XCTAssertTrue(waitUntil(timeout: 4) { !self.any(app, "room.mention.ivy").exists && self.any(app, "room.mention.research").exists }, "typing narrows the list")
        any(app, "room.mention.research").tap()
        XCTAssertTrue(waitUntil(timeout: 4) { (field.value as? String) == "@research " }, "picking completes the tag: \(field.value ?? "")")
        XCTAssertTrue(waitUntil(timeout: 4) { !list.exists }, "and the list closes")
        field.typeText("and mail a@")
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertFalse(list.exists, "an @ inside a word suggests nothing")
    }

    // MARK: - D13 A new room is empty until you write; the sessions it makes never show as chats (L372, §7.15)

    @MainActor func testD13_EmptyRoomAndFirstMessage() throws {
        control("seed", ["preset": "standup"])
        let app = launchSignedIn()
        let row = roomRow(app, "Standup")
        if !row.waitForExistence(timeout: 10) { pullToRefresh(app) }
        openRoom(app, "Standup")
        let empty = any(app, "room.empty")
        check(empty.waitForExistence(timeout: 8), app, "d13-empty", "the empty room")
        XCTAssertEqual(any(app, "room.empty.name").label, "Standup")
        XCTAssertTrue(any(app, "room.empty.hint").label.contains("Type @ to ask one bot."), "its hint")
        shot(app, "room-empty")
        control("turn-mode", ["inbox": "once", "notes": "pass", "ops": "pass", "writer": "pass", "ivy": "pass", "research": "pass", "default": "pass"])
        send(app, "Good morning")
        XCTAssertTrue(waitUntil(timeout: 8) { !empty.exists }, "the empty state goes with the first message")
        XCTAssertTrue(waitUntil(timeout: 40) { !self.prompts.isEmpty }, "its members are asked")
        XCTAssertTrue(waitUntil(timeout: 60) { !app.buttons["composer.stop"].exists })
        XCTAssertTrue(waitUntil(timeout: 20) { !(self.mirrorRoom(named: "Standup")["texts"] as? [String] ?? []).isEmpty }, "the room joins the mirror with its first message")
        assertNoHostedCalls()
    }
}
