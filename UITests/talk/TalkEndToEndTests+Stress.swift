// Pieces of the stress plan (docs/spec/3x-talk.md §15) that can be repeated on a simulator with the stand-in gateway:
// S-L4 (Talk and End, Mute, as fast as taps land), S-L5 (a take that runs into its cap), S-I2 (Home and back during
// dictation and Read Aloud), S-N2 (the socket drops while muted and while reading aloud), S-R5 (launch, Talk,
// terminate, several times). The speed measurements and the rest of the plan are the stress tester's.

import XCTest

extension TalkEndToEndTests {
    @MainActor private func leases() -> (tts: Int, stt: Int) { talkLeases() }

    /// Stress round 1: a double tap on End ended the conversation and its second tap landed on the memo mic, which had
    /// come back under the same finger and started a hands-free recording. The second tap now starts nothing (no
    /// memo, no new conversation, nothing sent), and the mic works again a moment later.
    /// On a slow Mac both taps of the system double tap can reach End before the dock has left, so this passes there
    /// with or without the fix; the tests that cannot pass without it are the unit ones
    /// (`aCardLeavingTheChatScreenQuietsTheMicAndTheCircle`, `aTouchRightAfterACardLeavesReachesNeitherTheMicNorTheCircle`).
    @MainActor func testS_L4b_ADoubleTapOnEndStartsNothing() throws {
        let app = launch()
        openChat(app, "ivy")
        let endButton = app.buttons["talk.dock.end"], mic = app.descendants(matching: .any)["composer.mic"]
        for round in 1...5 {
            XCTAssertTrue(talk(app).waitForExistence(timeout: 8), "Talk is back for round \(round)")
            talk(app).tap()
            // Listening: the microphone is the conversation's, so the memo that used to start had to take it over.
            XCTAssertTrue(waitForTitle(app, "Listening", timeout: 15), "round \(round): the conversation listens")
            let frame = endButton.frame
            let spot = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY))
            spot.doubleTap()
            XCTAssertTrue(waitUntil(timeout: 8) { !endButton.exists && mic.exists }, "round \(round): the composer is back")
            Thread.sleep(forTimeInterval: 1.5)
            let now = probe(app)
            XCTAssertEqual(now["owner"] as? String, "", "round \(round): nothing holds the microphone")
            XCTAssertEqual(now["conversations"] as? Int, 0, "round \(round): the conversation ended")
            XCTAssertEqual(now["started"] as? Int, round, "round \(round): no second conversation started")
            XCTAssertEqual(now["keepAwake"] as? Int, 0, "round \(round)")
            XCTAssertFalse(app.buttons["memo.delete"].exists, "round \(round): no memo recorder shows")
            XCTAssertTrue(mic.frame.intersects(frame) || talk(app).frame.intersects(frame),
                          "round \(round): the second tap did land on a voice control (mic \(mic.frame), Talk \(talk(app).frame), End \(frame))")
        }
        shot(app, "S-L4b-after-a-double-tap-on-end")
        XCTAssertEqual(prompts().count, 0, "nothing was sent")
        XCTAssertEqual(ledger("transcribes").count, 0)
        // The mic is not left dead: a tap on it a moment later records hands-free, as before.
        mic.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.probe(app)["owner"] as? String == "memoRecording" }, "the mic records again (\(probe(app)["owner"] ?? "?"))")
        XCTAssertTrue(app.buttons["memo.delete"].waitForExistence(timeout: 6))
        app.buttons["memo.delete"].tap()
        XCTAssertTrue(waitUntil(timeout: 6) { (self.probe(app)["owner"] as? String) == "" })
    }

    /// Stress round 1: with Read Replies Aloud on, leaving the app while the bot was thinking paused the conversation,
    /// and the reply that arrived after the return was read out beside "Voice paused". It stays quiet now; Read Aloud
    /// on the reply still reads it, and Resume still works.
    @MainActor func testS_I2b_AReplyAfterVoicePausedIsNotReadOut() throws {
        try account.control("/__fixture/voice", ["transcript": "Said before leaving"])
        try account.control("/__fixture/plan", ["plans": [["replyDelay": 14.0, "replyText": "The answer that arrives after the pause."]]])
        let app = launch(script: "say:1;quiet;quiet", speaks: true)
        openChat(app, "ivy")
        talk(app).tap()
        XCTAssertTrue(waitForTitle(app, "Thinking…", timeout: 30), "the bot is thinking (\(dockTitle(app).label))")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["talk.notice.title"].waitForExistence(timeout: 10), "leaving the app paused the conversation")
        XCTAssertTrue(inChat(app, "The answer that arrives after the pause.").waitForExistence(timeout: 60), "the reply arrived")
        // Its action row shows once it is complete (the newest reply's row; an older reply's row goes when a turn starts).
        let rows = app.buttons.matching(identifier: "chat.read-reply")
        XCTAssertTrue(waitUntil(timeout: 20) { self.prompts().count == 1 && rows.count > 0 }, "the reply completed")
        let read = rows.element(boundBy: rows.count - 1)
        XCTAssertTrue(app.staticTexts["talk.notice.title"].exists, "the notice is still there")
        Thread.sleep(forTimeInterval: 3)
        var now = probe(app)
        XCTAssertEqual(now["reading"] as? String ?? "idle", "idle", "nothing is read beside Voice paused")
        XCTAssertEqual(now["spokenBytes"] as? Int ?? 0, 0, "no audio after the return")
        XCTAssertEqual(now["owner"] as? String, "", "nothing holds the audio session")
        shot(app, "S-I2b-quiet-beside-voice-paused")
        // Asked for, the reply is read.
        read.tap()
        XCTAssertTrue(waitUntil(timeout: 12) { (self.probe(app)["reading"] as? String ?? "idle") != "idle" }, "Read Aloud still reads it when asked")
        read.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { (self.probe(app)["reading"] as? String ?? "idle") == "idle" })
        app.buttons["talk.notice.primary"].tap()
        XCTAssertTrue(waitUntil(timeout: 15) { self.probe(app)["conversations"] as? Int == 1 }, "Resume starts a conversation")
        XCTAssertEqual(prompts().count, 1, "nothing was sent twice")
        end(app)
    }

    @MainActor func testS_L4_TalkAndEndAndMuteAsFastAsTapsLand() throws {
        let app = launch()
        openChat(app, "ivy")
        let endButton = app.buttons["talk.dock.end"]
        let rounds = 15
        for round in 1...rounds {
            XCTAssertTrue(talk(app).waitForExistence(timeout: 6), "Talk is back for round \(round)")
            talk(app).tap()
            XCTAssertTrue(endButton.waitForExistence(timeout: 6), "round \(round): the dock shows")
            endButton.tap()
        }
        XCTAssertTrue(talk(app).waitForExistence(timeout: 6))
        XCTAssertTrue(waitUntil(timeout: 6) { self.probe(app)["conversations"] as? Int == 0 && (self.probe(app)["owner"] as? String) == "" })
        var now = probe(app)
        XCTAssertEqual(now["started"] as? Int, rounds, "every tap started one conversation")
        XCTAssertEqual(now["keepAwake"] as? Int, 0, "no hold is left")
        XCTAssertEqual(now["idleTimerOff"] as? Bool, false)
        XCTAssertEqual(now["takes"] as? Int, 0, "no take file is left")
        XCTAssertEqual(now["notices"] as? Int, 0)
        XCTAssertEqual(prompts().count, 0, "nothing was sent")
        XCTAssertEqual(ledger("transcribes").count, 0)
        XCTAssertTrue(waitUntil(timeout: 8) { self.leases() == (0, 0) }, "the gateway holds no warm-up lease (\(leases()))")

        // One conversation, Mute tapped thirty times.
        talk(app).tap()
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 12))
        let mute = app.buttons["talk.dock.mute"]
        for _ in 0..<30 { mute.tap() }
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 8), "an even number of taps leaves it listening (\(dockTitle(app).label))")
        mute.tap()
        XCTAssertTrue(waitForTitle(app, "Muted", timeout: 5))
        now = probe(app)
        XCTAssertEqual(now["conversations"] as? Int, 1)
        XCTAssertEqual(now["keepAwake"] as? Int, 1, "one hold however often it was muted")
        XCTAssertEqual(now["owner"] as? String, "conversation")
        XCTAssertEqual(prompts().count, 0)
        end(app)
        XCTAssertTrue(waitUntil(timeout: 6) { self.probe(app)["keepAwake"] as? Int == 0 && (self.probe(app)["owner"] as? String) == "" })
        XCTAssertTrue(waitUntil(timeout: 8) { self.leases() == (0, 0) }, "\(leases())")
    }

    @MainActor func testS_L5_ATakeThatRunsIntoItsCapIsSent() throws {
        try account.control("/__fixture/voice", ["transcript": "A very long sentence"])
        let app = launch(["-HQDebugTalkClock", "10"], script: "hold")     // the 60 s cap is 6 s on this clock
        openChat(app, "ivy")
        talk(app).tap()
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 12))
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(ledger("transcribes").count, 0, "not before the cap")
        XCTAssertTrue(waitUntil(timeout: 15) { self.prompts().count == 1 }, "it is sent at the cap without a tap")
        let take = ledger("transcribes").first
        XCTAssertEqual(take?["seconds"] as? Double ?? 0, 6, accuracy: 1.5, "about the cap's length (\(take?["seconds"] ?? "nil") s)")
        XCTAssertEqual(prompts().first?["text"] as? String, "A very long sentence")
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 25), "and the loop carries on (\(dockTitle(app).label))")
        end(app)
    }

    @MainActor func testS_I2_HomeAndBackDuringDictationAndReadAloud() throws {
        let long = Array(repeating: "A long reply that is still being read when the app leaves the screen.", count: 5).joined(separator: " ")
        try account.control("/__fixture/plan", ["plans": [["replyText": long]]])
        let app = launch()
        openChat(app, "ivy")
        // Dictation: leaving the app cancels it without a word.
        openOptions(app)
        app.buttons["voice.options.dictate"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.probe(app)["dictation"] as? String == "recording" })
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 8))
        XCTAssertTrue(waitUntil(timeout: 5) { self.probe(app)["dictation"] as? String == "idle" }, "dictation was cancelled")
        XCTAssertFalse(app.descendants(matching: .any)["dictation.status"].exists, "its row left")
        XCTAssertFalse(app.staticTexts["memo.notice.title"].exists, "without a card")
        XCTAssertEqual(ledger("transcribes").count, 0, "nothing was transcribed")
        XCTAssertEqual(probe(app)["keepAwake"] as? Int, 0)
        XCTAssertEqual(probe(app)["owner"] as? String, "")
        XCTAssertTrue(talk(app).waitForExistence(timeout: 5), "Talk is the circle again")

        // Read Aloud: leaving the app stops it, and nothing plays after the return.
        send(app, "Read me something long")
        app.tables["chat.table"].tap()
        let read = app.buttons["chat.read-reply"]
        XCTAssertTrue(waitUntil(timeout: 25) { read.exists && self.inChat(app, "A long reply that is still being read").exists }, "the reply is done")
        read.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { self.probe(app)["reading"] as? String == "speaking" }, "it reads (\(probe(app)["reading"] ?? "nil"))")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 8))
        XCTAssertTrue(waitUntil(timeout: 5) { self.probe(app)["reading"] as? String == "idle" }, "the reading stopped")
        XCTAssertTrue(waitUntil(timeout: 6) { self.ledger("streams").last?["stopped"] as? Bool == true || self.ledger("streams").last?["closedBy"] as? String == "client" },
                      "the stream was closed (\(ledger("streams").last ?? [:]))")
        let bytes = probe(app)["spokenBytes"] as? Int ?? 0
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(probe(app)["spokenBytes"] as? Int ?? 0, bytes, "no audio after the return")
        XCTAssertEqual(read.label, "Read Aloud")
        XCTAssertFalse(app.staticTexts["read.strip.label"].exists)
        XCTAssertEqual(probe(app)["owner"] as? String, "")
    }

    @MainActor func testS_N2_TheSocketDropsWhileMutedAndWhileReadingAloud() throws {
        let long = Array(repeating: "A long reply that is being read while the connection drops.", count: 5).joined(separator: " ")
        try account.control("/__fixture/plan", ["plans": [["replyText": long]]])
        let app = launch()
        openChat(app, "ivy")
        // Muted: the conversation stays, says Reconnecting…, and is Muted again afterwards.
        talk(app).tap()
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 12))
        app.buttons["talk.dock.mute"].tap()
        XCTAssertTrue(waitForTitle(app, "Muted", timeout: 5))
        try account.control("/__fixture/voice", ["refuseSocketFor": 3, "dropSocket": true])
        let seen = titles(app, until: "Reconnecting…", timeout: 15)
        XCTAssertTrue(seen.contains("Reconnecting…") || seen.last == "Muted", "it says Reconnecting… or stays Muted (\(seen))")
        XCTAssertTrue(waitUntil(timeout: 40) { self.dockTitle(app).exists && self.dockTitle(app).label == "Muted" }, "Muted again after the reconnect")
        XCTAssertEqual(probe(app)["conversations"] as? Int, 1)
        XCTAssertEqual(prompts().count, 0, "nothing was sent")
        XCTAssertEqual(ledger("transcribes").count, 0)
        end(app)

        // Reading aloud: the speech has its own socket; a dropped chat socket does not leave "Stop reading" stuck.
        XCTAssertTrue(talk(app).waitForExistence(timeout: 6))
        send(app, "Read me something long")
        app.tables["chat.table"].tap()
        let read = app.buttons["chat.read-reply"]
        XCTAssertTrue(waitUntil(timeout: 25) { read.exists && self.inChat(app, "A long reply that is being read").exists }, "the reply is done")
        read.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { self.probe(app)["reading"] as? String == "speaking" }, "it reads (\(probe(app)["reading"] ?? "nil"))")
        try account.control("/__fixture/voice", ["refuseSocketFor": 2, "dropSocket": true])
        XCTAssertTrue(waitUntil(timeout: 45) { self.probe(app)["reading"] as? String == "idle" }, "the reading ends by itself (\(probe(app)["reading"] ?? "nil"))")
        if app.alerts.firstMatch.exists { app.alerts.firstMatch.buttons["OK"].tap() }
        XCTAssertTrue(waitUntil(timeout: 5) { read.exists && read.label == "Read Aloud" }, "the button is idle again")
        XCTAssertEqual(probe(app)["owner"] as? String, "")
        XCTAssertEqual(prompts().count, 1, "the one typed message, never a second")
    }

    @MainActor func testS_R5_LaunchTalkTerminateFiveTimes() throws {
        var app = launch()
        for cycle in 1...5 {
            openChat(app, cycle % 2 == 0 ? "default" : "ivy")
            talk(app).tap()
            XCTAssertTrue(waitForTitle(app, "Listening", timeout: 12), "cycle \(cycle): listening")
            if cycle == 3 { back(app); XCTAssertTrue(app.buttons["talk.pill"].waitForExistence(timeout: 4)) }
            app.terminate()
            app = launch(reset: false, introSeen: nil)
            let now = probe(app)
            XCTAssertEqual(now["conversations"] as? Int, 0, "cycle \(cycle): no conversation after the relaunch")
            XCTAssertEqual(now["notices"] as? Int, 0)
            XCTAssertEqual(now["keepAwake"] as? Int, 0)
            XCTAssertEqual(now["takes"] as? Int, 0, "cycle \(cycle): no orphan take")
            XCTAssertEqual(now["owner"] as? String, "")
            XCTAssertFalse(app.buttons["talk.pill"].exists, "cycle \(cycle): no pill")
        }
        // A lease a kill left behind is released by the next conversation's end (same name).
        openChat(app, "ivy")
        talk(app).tap()
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 12))
        end(app)
        XCTAssertTrue(waitUntil(timeout: 8) { self.leases() == (0, 0) }, "no lease is left (\(leases()))")
        XCTAssertEqual(prompts().count, 0)
        XCTAssertEqual((try voiceState()["forbidden"] as? [Any])?.count, 0)
    }
}
