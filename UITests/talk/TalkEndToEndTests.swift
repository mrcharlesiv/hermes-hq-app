// Live voice end to end (docs/spec/3x-talk.md §14.2, E01…E25) against the voice stand-in gateway
// (scripts/fixtures/voice-gateway.py), run by scripts/e2e-talk.sh on 127.0.0.1:9901. Real touches only. The
// simulator's microphone is the app's stand-in (`-HQDebugTalkFixture`, scripted with `-HQDebugTalkScript`) and its
// speaker the stand-in that makes no sound (`-HQDebugTalkSpeaker fixture`); what went over the wire is read from the
// fixture's ledger (`/__fixture/voice-state`) and what the app's audio pieces think from the probe (`talk.debug`).
// Without TEST_RUNNER_HQN_UI_CREDENTIALS every test skips. Helpers are in TalkEndToEndTests+Support.swift.

import XCTest

final class TalkEndToEndTests: XCTestCase {
    var account: FixtureAccount!

    override func setUpWithError() throws {
        continueAfterFailure = false
        account = try FixtureAccount.load()
        try account.control("/__fixture/voice", ["reset": true, "resetChats": true])
    }

    // MARK: E01b The Talk tip is in nothing's way

    /// The tip is a card in the chat, not a popover: every touch around it does what it did before, the newest message
    /// is not under it, and it steps aside while the circle is not Talk. (The voice memo suite caught the popover it
    /// first was taking the first touch after a chat opened: Back, a memo's play disc, a notice's Close.)
    @MainActor func testE01b_TheTalkTipTakesNoTouch() throws {
        try account.control("/__fixture/voice", ["streamStartDelay": 1.5])
        var app = launch(tips: true)
        openChat(app, "ivy")
        let words = "Tap the waveform button to talk out loud with Ivy. Hold the mic to send a voice memo."
        var tip = app.staticTexts[words]
        XCTAssertTrue(tip.waitForExistence(timeout: 8), "the Talk tip shows")
        var card = app.descendants(matching: .any)["memo.tip"]
        XCTAssertTrue(card.exists && app.staticTexts["Talk with Ivy"].exists, "with the bot's name")
        XCTAssertEqual(app.popovers.count, 0, "it is not a popover")
        // Above the circle, and the newest reply's action row ends above it.
        XCTAssertLessThanOrEqual(card.frame.maxY, talk(app).frame.minY + 1, "above the circle")
        let read = app.buttons["chat.read-reply"]
        XCTAssertTrue(read.waitForExistence(timeout: 8) && read.isHittable, "the newest reply's actions are not under the tip")
        XCTAssertLessThanOrEqual(read.frame.maxY, card.frame.minY + 1, "the transcript ends above the tip")
        shot(app, "E01b-tip-in-place")

        // A tap in the transcript goes to the transcript, and the strip sits above the tip.
        // A reading long enough to still be going when Stop is tapped, however slow the Mac (stress round 1: the short
        // reply's reading had finished by then).
        try account.control("/__fixture/voice", ["streamScript": [["json": ["type": "start", "sample_rate": 24_000, "channels": 1]], ["toneMs": 60_000]]])
        read.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { (self.probe(app)["reading"] as? String ?? "idle") != "idle" }, "Read Aloud took the first tap")
        let strip = app.descendants(matching: .any)["read.strip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 6), "the reading strip shows")
        XCTAssertTrue(tip.exists, "with the tip still there")
        XCTAssertLessThanOrEqual(strip.frame.maxY, card.frame.minY + 1, "the strip sits above the tip")
        shot(app, "E01b-tip-under-the-reading-strip")
        app.buttons["read.strip.stop"].tap()
        XCTAssertTrue(waitUntil(timeout: 6) { self.probe(app)["reading"] as? String == "idle" }, "Stop took its tap too")

        // Words in the field: the circle is Send and the tip steps aside. Without them it returns, above the keyboard.
        let field = app.textViews["composer.text"]
        field.tap()
        field.typeText("Hi")
        XCTAssertTrue(waitUntil(timeout: 5) { !tip.exists }, "the tip steps aside while the circle is Send")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2))
        XCTAssertTrue(tip.waitForExistence(timeout: 8), "and returns when the circle is Talk again")
        XCTAssertTrue(waitUntil(timeout: 4) { card.frame.maxY <= self.talk(app).frame.minY + 1 }, "above the composer over the keyboard")
        XCTAssertGreaterThan(card.frame.minY, 100, "on screen")
        shot(app, "E01b-tip-over-the-keyboard")

        // [ui-sizing 2026-11-09] Owner: "option B", the tip shows in the first chat only. One tap on Back leaves the
        // chat, and the tip doesn't come back in it, or in another chat.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.cells["bot-row-default"].waitForExistence(timeout: 5), "Back works at the first tap")
        XCTAssertFalse(tip.exists, "the tip left with its chat")
        openChat(app, "ivy")
        XCTAssertFalse(tip.waitForExistence(timeout: 3), "leaving its first chat retired it")

        // Close retires it too, in the chat it shows in.
        app = launch(tips: true)
        openChat(app, "ivy")
        tip = app.staticTexts[words]
        XCTAssertTrue(tip.waitForExistence(timeout: 8), "a fresh start shows it again")
        app.buttons["memo.tip.close"].tap()
        XCTAssertTrue(waitUntil(timeout: 4) { !tip.exists }, "Close removes it")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(tip.exists, "and it does not come back")
        app = launch(reset: false, introSeen: nil, tips: true)
        openChat(app, "ivy")
        tip = app.staticTexts[words]
        card = app.descendants(matching: .any)["memo.tip"]
        XCTAssertFalse(tip.waitForExistence(timeout: 3), "not after a relaunch either")
        XCTAssertFalse(card.exists)
        XCTAssertEqual(prompts().count, 0, "nothing was sent")
    }

    // MARK: E01 The intro, once

    @MainActor func testE01_IntroOnceThenStraightToTheDock() throws {
        let app = launch(introSeen: false, tips: true)
        openChat(app, "ivy")
        // The Talk tip shows once, at the circle.
        let tip = app.staticTexts["Tap the waveform button to talk out loud with Ivy. Hold the mic to send a voice memo."]
        XCTAssertTrue(tip.waitForExistence(timeout: 8), "the Talk tip shows")
        shot(app, "E01-talk-tip")
        talk(app).tap()
        let title = app.staticTexts["talk.intro.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 6), "the first tap shows the intro")
        XCTAssertEqual(title.label, "Talk with Ivy")
        XCTAssertFalse(tip.exists, "tapping Talk retires its tip")
        for row in ["Just talk. Pause when you’re done, and Ivy answers out loud.",
                    "Interrupt anytime. Start talking or tap Interrupt to cut in.",
                    "It’s all in the chat. What you say and what Ivy answers appear in the chat as messages."] {
            XCTAssertTrue(labelled(app, row).exists, "the row “\(row)”")
        }
        let keep = app.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH 'Keeps going in the background. Lock your iPhone or switch apps and the conversation carries on. Quitting ' AND label ENDSWITH ' ends it.'")).firstMatch
        XCTAssertTrue(keep.exists, "the fourth row names the app")
        XCTAssertFalse(keep.label.contains("Dispatch"))
        XCTAssertTrue(app.buttons["talk.intro.start"].exists && app.buttons["talk.intro.not-now"].exists)
        XCTAssertEqual(app.buttons["talk.intro.start"].label, "Start Talking")
        XCTAssertEqual(app.buttons["talk.intro.not-now"].label, "Not Now")
        shot(app, "E01-intro")

        // Not Now starts nothing, and the sheet is offered again.
        app.buttons["talk.intro.not-now"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !title.exists }, "the sheet leaves")
        XCTAssertFalse(dockTitle(app).exists, "nothing started")
        XCTAssertEqual(probe(app)["started"] as? Int, 0)
        talk(app).tap()
        XCTAssertTrue(title.waitForExistence(timeout: 6), "offered again after Not Now")
        app.buttons["talk.intro.start"].tap()
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 12), "Start Talking starts the conversation (\(dockTitle(app).label))")
        end(app)

        // The second launch goes straight to the dock.
        let again = launch(reset: false, introSeen: nil)
        openChat(again, "ivy")
        talk(again).tap()
        XCTAssertTrue(waitForTitle(again, "Listening", timeout: 12), "no sheet the second time")
        XCTAssertFalse(again.staticTexts["talk.intro.title"].exists)
        end(again)
    }

    // MARK: E02 One full spoken turn

    @MainActor func testE02_AFullSpokenTurn() throws {
        let said = "What is the plan for today"
        let reply = "Here is the plan for today. First we check the build, then we walk through the open items one by one."
        try account.control("/__fixture/voice", ["transcript": said, "transcribeDelay": 1.5])
        try account.control("/__fixture/plan", ["plans": [["replyDelay": 2.0, "replyText": reply]]])
        let app = launch(script: "say:2", speaks: true)
        openChat(app, "ivy")
        talk(app).tap()
        XCTAssertTrue(dockTitle(app).waitForExistence(timeout: 8), "the dock takes the composer's place")
        let seen = titles(app, until: "Ivy is speaking", timeout: 30)
        XCTAssertTrue(inOrder(seen, ["Listening", "Transcribing…", "Thinking…", "Ivy is speaking"]), "the dock's states in order (\(seen))")
        // Status and hint read together: the short reply can finish speaking between two separate reads.
        let speakingProbe = probe(app)
        if speakingProbe["status"] as? String == "speaking" {
            XCTAssertEqual(speakingProbe["hint"] as? String, "Start talking or tap Interrupt to cut in.")
        }
        XCTAssertFalse(dockNotice(app).exists, "one row: no line above it in a normal state")
        XCTAssertEqual(app.buttons["talk.dock.center"].label, "Interrupt")
        shot(app, "E02-speaking")
        // Every part of the dock is there.
        XCTAssertTrue(app.descendants(matching: .any)["talk.dock"].exists)
        XCTAssertTrue(app.buttons["talk.dock.mute"].exists && app.buttons["talk.dock.end"].exists)
        XCTAssertEqual(app.buttons["talk.dock.end"].label, "End Voice Conversation")
        XCTAssertFalse(app.buttons["talk.dock.route"].exists, "the simulator's built-in speaker is not shown in the row")
        let composer = app.textViews["composer.text"]
        XCTAssertTrue(!composer.exists || !composer.isHittable, "the composer is covered")

        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 25), "back to Listening after the answer (\(dockTitle(app).label))")
        // The hint's words can land a beat after the title (a full-suite run read the speaking hint once).
        XCTAssertTrue(waitUntil(timeout: 3) { self.dockHint(app) == "Go ahead. It sends when you pause." }, "\(dockHint(app))")
        let first = app.staticTexts["talk.dock.elapsed"].label
        XCTAssertTrue(first.hasPrefix("Elapsed 0:"), first)
        XCTAssertTrue(waitUntil(timeout: 4) { app.staticTexts["talk.dock.elapsed"].label != first }, "the time counts up")
        XCTAssertEqual(app.buttons["talk.dock.center"].label, "Stop Listening and Send")
        shot(app, "E02-listening")

        let state = try voiceState()
        let transcribes = state["transcribes"] as? [[String: Any]] ?? []
        XCTAssertEqual(transcribes.count, 1, "one transcription")
        XCTAssertEqual(transcribes.first?["mime"] as? String, "audio/wav")
        XCTAssertEqual(transcribes.first?["sampleRate"] as? Int, 16_000)
        XCTAssertEqual(transcribes.first?["channels"] as? Int, 1)
        XCTAssertEqual(transcribes.first?["profile"] as? String, "ivy")
        let sent = prompts()
        XCTAssertEqual(sent.count, 1, "one prompt")
        XCTAssertEqual(sent.first?["text"] as? String, said)
        XCTAssertEqual(Set(sent.first?["keys"] as? [String] ?? []).subtracting(["profile"]), ["session_id", "text"], "prompt.submit keys")
        let streams = state["streams"] as? [[String: Any]] ?? []
        XCTAssertEqual(streams.count, 1, "one speech stream")
        XCTAssertEqual(streams.first?["done"] as? Bool, true)
        XCTAssertEqual(streams.first?["stopped"] as? Bool, false)
        XCTAssertEqual(streams.first?["spoken"] as? String, reply, "the reply's own words were spoken")
        XCTAssertEqual((state["forbidden"] as? [Any])?.count, 0, "none of the never-called routes")
        // Both sides are in the chat as messages.
        XCTAssertTrue(inChat(app, said).exists, "what was said is a bubble")
        XCTAssertTrue(inChat(app, "First we check the build").exists, "the answer is a bubble")
        XCTAssertGreaterThan(probe(app)["spokenBytes"] as? Int ?? 0, 0, "audio reached the speaker")
        end(app)
        XCTAssertTrue(talk(app).waitForExistence(timeout: 5), "the composer is back")
    }

    /// Read Replies Aloud off (the default): the conversation is speech to text only. The answer stays text and the
    /// microphone is back when the turn ends.
    @MainActor func testE02b_ReadRepliesOffIsSpeechToTextOnly() throws {
        try account.control("/__fixture/voice", ["transcripts": ["First question", "Second question"]])
        // Each reply takes six seconds, so "Thinking…" is on screen long enough for a slow Mac to read it (with two
        // seconds a loaded run polled past the second one: the app was right, the test was slow).
        try account.control("/__fixture/plan", ["plans": [["replyText": "The first answer stays text.", "replyDelay": 6.0],
                                                             ["replyText": "So does the second.", "replyDelay": 6.0]]])
        let app = launch(script: "say:1.5;say:1.5")
        openChat(app, "ivy")
        XCTAssertEqual(probe(app)["readReplies"] as? Bool, false)
        talk(app).tap()
        XCTAssertTrue(dockTitle(app).waitForExistence(timeout: 8))
        var seen: [String] = []
        let title = dockTitle(app)
        XCTAssertTrue(waitUntil(timeout: 90) {
            if title.exists { let now = title.label; if seen.last != now { seen.append(now) } }
            return self.prompts().count == 2 && self.inChat(app, "So does the second.").exists
        }, "both turns ran (\(seen), \(prompts().count) prompts)")
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 15), "and it listens again (\(title.label))")
        XCTAssertFalse(seen.contains("Ivy is speaking"), "nothing is spoken (\(seen))")
        XCTAssertTrue(inOrder(seen, ["Listening", "Thinking…", "Listening", "Thinking…"]), "\(seen)")
        XCTAssertEqual(ledger("streams").count, 0, "no speech stream")
        XCTAssertEqual(ledger("speaks").count, 0, "no clip either")
        XCTAssertEqual(probe(app)["spokenBytes"] as? Int ?? 0, 0)
        XCTAssertTrue(inChat(app, "The first answer stays text.").exists)
        end(app)
    }

    // MARK: E03 Barge-in while the bot speaks

    @MainActor func testE03_BargeInWhileSpeaking() throws {
        let long = Array(repeating: "This answer goes on for a while so there is time to cut in.", count: 4).joined(separator: " ")
        try account.control("/__fixture/voice", ["transcripts": ["Tell me everything", "Actually stop there"]])
        try account.control("/__fixture/plan", ["plans": [["replyText": long]]])
        let app = launch(script: "say:1.5;barge-speaking:1.5", speaks: true)
        openChat(app, "ivy")
        talk(app).tap()
        XCTAssertTrue(waitForTitle(app, "Ivy is speaking", timeout: 30), "the bot speaks (\(dockTitle(app).label))")
        // The stand-in microphone hears speech while the bot speaks: the speech stops and the words are sent.
        XCTAssertTrue(waitUntil(timeout: 25) { self.prompts().count == 2 }, "the interruption was sent (\(prompts().count) prompts)")
        let sent = prompts()
        XCTAssertEqual(sent.last?["text"] as? String, "Actually stop there")
        XCTAssertEqual(sent.last?["interrupted"] as? Bool, true, "the second prompt says it interrupted")
        XCTAssertNotEqual(sent.first?["interrupted"] as? Bool, true, "the first did not")
        let streams = try voiceState()["streams"] as? [[String: Any]] ?? []
        XCTAssertEqual(streams.first?["stopped"] as? Bool, true, "the first answer's speech was stopped")
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 25), "the loop carries on (\(dockTitle(app).label))")
        XCTAssertEqual(probe(app)["conversations"] as? Int, 1)
        end(app)
    }

    // MARK: E04 Stop while thinking, Interrupt while speaking

    @MainActor func testE04_StopWhileThinkingInterruptWhileSpeaking() throws {
        let long = Array(repeating: "A long answer that would take a while to say out loud.", count: 4).joined(separator: " ")
        try account.control("/__fixture/voice", ["transcripts": ["Think about it", "Now answer"]])
        try account.control("/__fixture/plan", ["plans": [["replyDelay": 20.0, "replyText": "Never said."], ["replyText": long]]])
        let app = launch(script: "say:1.5;say:1.5", speaks: true)
        openChat(app, "ivy")
        talk(app).tap()
        XCTAssertTrue(waitForTitle(app, "Thinking…", timeout: 25), "thinking (\(dockTitle(app).label))")
        XCTAssertEqual(dockHint(app), "Ivy is working on it. Talking now interrupts.")
        let center = app.buttons["talk.dock.center"]
        XCTAssertEqual(center.label, "Stop")
        shot(app, "E04-thinking")
        center.tap()
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 10), "Stop goes back to Listening (\(dockTitle(app).label))")
        XCTAssertEqual((try voiceState()["streams"] as? [Any])?.count, 0, "nothing was spoken for the stopped turn")

        XCTAssertTrue(waitForTitle(app, "Ivy is speaking", timeout: 30), "the next turn speaks (\(dockTitle(app).label))")
        XCTAssertEqual(center.label, "Interrupt")
        center.tap()
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 8), "Interrupt goes back to Listening (\(dockTitle(app).label))")
        XCTAssertTrue(waitUntil(timeout: 8) { ((try? self.voiceState())?["streams"] as? [[String: Any]])?.last?["stopped"] as? Bool == true },
                      "the speech stream was told to stop")
        XCTAssertEqual(prompts().count, 2)
        XCTAssertEqual(probe(app)["speech"] as? String, "idle")
        end(app)
    }

    // MARK: E05 Send Now, Mute, Unmute

    @MainActor func testE05_SendNowMuteUnmute() throws {
        try account.control("/__fixture/voice", ["transcript": "Send this now"])
        let app = launch(script: "hold")
        openChat(app, "ivy")
        talk(app).tap()
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 12))
        let center = app.buttons["talk.dock.center"]
        // Speech that never pauses: nothing is sent until Send Now.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(prompts().count, 0, "nothing sent while the person is still talking")
        XCTAssertEqual(center.label, "Stop Listening and Send")   // the desktop's Stop: sends what was heard
        XCTAssertTrue(center.isEnabled)
        center.tap()
        XCTAssertTrue(waitUntil(timeout: 15) { self.prompts().count == 1 }, "Send Now sends what was said")
        XCTAssertEqual(prompts().first?["text"] as? String, "Send this now")
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 25), "listening again after the answer (\(dockTitle(app).label))")

        let mute = app.buttons["talk.dock.mute"]
        XCTAssertEqual(mute.label, "Mute Microphone")
        XCTAssertFalse(mute.isSelected)
        mute.tap()
        XCTAssertTrue(waitForTitle(app, "Muted", timeout: 5))
        XCTAssertEqual(dockHint(app), "Ivy can’t hear you. Tap Mute to talk again.")
        XCTAssertFalse(dockNotice(app).exists)
        XCTAssertTrue(mute.isSelected, "Mute reads as selected")
        XCTAssertFalse(center.exists && center.isEnabled, "Stop waits while muted")
        XCTAssertEqual(probe(app)["muted"] as? Bool, true)
        shot(app, "E05-muted")
        mute.tap()
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 8), "Unmute listens again (\(dockTitle(app).label))")
        XCTAssertEqual(probe(app)["muted"] as? Bool, false)
        XCTAssertEqual(prompts().count, 1, "muting sent nothing")

        // The speaker button: on (the loudspeaker) when a conversation starts; a tap switches to the earpiece and back.
        // A toggle (UIAccessibilityTraits.toggleButton), so XCUITest types it as a switch, not a button.
        let speaker = app.descendants(matching: .any)["talk.dock.speaker"]
        XCTAssertTrue(speaker.exists, "the speaker button is in the row")
        XCTAssertEqual(speaker.label, "Speaker")
        XCTAssertTrue(["On", "1"].contains(speaker.value as? String ?? ""), "and starts on (\(String(describing: speaker.value)))")
        speaker.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { ["Off", "0"].contains(speaker.value as? String ?? "") }, "a tap: the earpiece")
        speaker.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { ["On", "1"].contains(speaker.value as? String ?? "") }, "and back")
        // A long press on the bar: Speak Replies, the routes (the simulator has only its speaker) and the system's picker.
        XCTAssertFalse(app.buttons["talk.dock.route"].exists)
        dockTitle(app).press(forDuration: 1.2)
        let other = app.buttons["Other Outputs…"]
        XCTAssertTrue(other.waitForExistence(timeout: 5), "the route menu opens")
        XCTAssertTrue(app.buttons["Speak Replies"].exists, "with Speak Replies")
        XCTAssertTrue(app.buttons["Speaker"].waitForExistence(timeout: 3), "with the built-in route as Speaker")
        shot(app, "E05-route-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(waitUntil(timeout: 4) { !other.exists }, "the menu closes")
        XCTAssertEqual(probe(app)["conversations"] as? Int, 1, "and the conversation goes on")
        end(app)
    }

    // MARK: E06 Saying "stop", End, the ended caption, the kept draft

    @MainActor func testE06_SayingStopEndTheCaptionAndTheDraft() throws {
        try account.control("/__fixture/voice", ["transcript": "Stop."])
        let app = launch(script: "say:1")
        openChat(app, "ivy")
        talk(app).tap()
        XCTAssertTrue(dockTitle(app).waitForExistence(timeout: 8))
        // Saying a bare "stop" ends the conversation and is not sent.
        let caption = app.staticTexts["talk.ended"]
        XCTAssertTrue(caption.waitForExistence(timeout: 20), "the ended caption shows")
        XCTAssertTrue(caption.label.hasPrefix("Voice chat ended · 0:"), caption.label)
        XCTAssertFalse(dockTitle(app).exists, "the dock left")
        XCTAssertEqual(prompts().count, 0, "the stop phrase was not sent")
        XCTAssertEqual((try voiceState()["transcribes"] as? [Any])?.count, 1)
        XCTAssertEqual(probe(app)["conversations"] as? Int, 0)
        shot(app, "E06-ended-caption")

        // A draft typed before a conversation is back after End.
        let field = app.textViews["composer.text"]
        field.tap()
        field.typeText("Draft to keep")
        plus(app).tap()
        let item = app.buttons["composer.plus.talk"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "+ has Talk with Ivy")
        item.tap()
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 12), "the conversation starts over the draft (\(dockTitle(app).label))")
        XCTAssertEqual(app.keyboards.count, 0, "the keyboard went away")
        Thread.sleep(forTimeInterval: 1.2)
        app.buttons["talk.dock.end"].tap()
        XCTAssertTrue(caption.waitForExistence(timeout: 6), "End shows the caption")
        XCTAssertTrue(caption.label.hasPrefix("Voice chat ended · 0:"), caption.label)
        XCTAssertEqual(field.value as? String, "Draft to keep", "the draft is still in the field")
        XCTAssertTrue(app.buttons["composer.send"].exists, "with Send as the circle")
        XCTAssertEqual(prompts().count, 0)
        XCTAssertEqual(probe(app)["takes"] as? Int, 0, "no take files are left behind")
    }

    // MARK: E07 Reconnecting: what was said is dropped, never sent late

    @MainActor func testE07_ReconnectingDropsTheTake() throws {
        try account.control("/__fixture/voice", ["transcripts": ["Second try"]])
        let app = launch(script: "say:9;say:13;quiet")
        openChat(app, "ivy")
        talk(app).tap()
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 12))
        Thread.sleep(forTimeInterval: 2.5)                      // in the middle of the first take
        try account.control("/__fixture/voice", ["refuseSocketFor": 4, "dropSocket": true])
        XCTAssertTrue(waitForTitle(app, "Reconnecting…", timeout: 15), "the dock says Reconnecting… (\(dockTitle(app).label))")
        // The probe refreshes four times a second, so give it a moment to catch up with the title.
        XCTAssertTrue(waitUntil(timeout: 2) { self.dockHint(app) == "Waiting for your gateway." }, "the advice (\(dockHint(app)))")
        XCTAssertFalse(app.buttons["talk.dock.center"].exists, "Stop shows only when it does something")
        shot(app, "E07-reconnecting")
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 45), "listening again after the reconnect (\(dockTitle(app).label))")
        // The take that was running when the gateway went away is thrown away when it ends, and the dock says so
        // then (the web's guard speaks at the take's end too: conversation-guard.ts).
        let hint = dockNotice(app)
        let lost = "Didn’t send what you said while reconnecting. Say it again."
        XCTAssertTrue(waitUntil(timeout: 25) { hint.exists && hint.label == lost }, "the dock says the speech was dropped (\(hint.label))")
        XCTAssertEqual(dockTitle(app).label, "Listening")
        shot(app, "E07-lost-speech")
        var state = try voiceState()
        XCTAssertEqual((state["transcribes"] as? [Any])?.count, 0, "the dropped take was not transcribed")
        XCTAssertEqual(prompts().count, 0, "and not sent")
        // Still nothing ten seconds later (the next take, 13 s long, is being said); then that take goes out
        // normally and the hint clears.
        Thread.sleep(forTimeInterval: 10)
        state = try voiceState()
        XCTAssertEqual((state["transcribes"] as? [Any])?.count, 0, "never sent late")
        XCTAssertEqual(prompts().count, 0)
        XCTAssertEqual(hint.label, lost, "the hint stays until something is sent")
        XCTAssertTrue(waitUntil(timeout: 30) { self.prompts().count == 1 }, "the next take is sent")
        XCTAssertEqual(prompts().first?["text"] as? String, "Second try")
        XCTAssertEqual(ledger("transcribes").count, 1, "one take was transcribed: the second")
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 25))
        XCTAssertTrue(waitUntil(timeout: 3) { !hint.exists }, "the line went")
        XCTAssertEqual(dockHint(app), "Go ahead. It sends when you pause.")
        XCTAssertEqual(state["socketDrops"] as? Int, 1)
        end(app)
    }

    // MARK: E08 The silence pause and the notice's buttons

    @MainActor func testE08_SilencePauseAndTheNotice() throws {
        let app = launch(["-HQDebugTalkClock", "20"])          // 30 s is 1.5 s, 2 minutes are 6 s
        openChat(app, "ivy")
        talk(app).tap()
        XCTAssertTrue(dockTitle(app).waitForExistence(timeout: 8))
        let seen = titles(app, until: "Still Listening", timeout: 8)
        XCTAssertEqual(seen.last, "Still Listening", "30 s without speech (\(seen))")
        XCTAssertEqual(dockHint(app), "Talk when you’re ready, or tap End.")
        let title = app.staticTexts["talk.notice.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15), "2 minutes of silence pause it")
        XCTAssertEqual(title.label, "Voice Paused")
        let message = app.staticTexts["talk.notice.message"]
        XCTAssertEqual(message.label, "Paused after 2 minutes of silence. Your chat with Ivy is saved.")
        XCTAssertEqual(app.buttons["talk.notice.primary"].label, "Resume")
        XCTAssertEqual(app.buttons["talk.notice.copy"].label, "Copy Details")
        XCTAssertEqual(app.buttons["talk.notice.done"].label, "Done")
        XCTAssertEqual(probe(app)["conversations"] as? Int, 0, "the microphone is off")
        XCTAssertEqual(probe(app)["owner"] as? String, "")
        shot(app, "E08-paused")

        // It is kept for its chat: the list shows the orange pill, and the chat still has the notice.
        back(app)
        let pill = app.buttons["talk.pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 6), "the paused pill shows off the chat")
        XCTAssertTrue(pill.label.hasPrefix("Ivy · Voice Paused · Tap for details"), pill.label)
        XCTAssertFalse(app.buttons["talk.pill.end"].exists, "no End on a paused pill")
        shot(app, "E08-paused-pill")
        pill.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 8), "the pill opens the chat, and the notice is still there")
        XCTAssertTrue(waitUntil(timeout: 4) { !pill.exists }, "the pill leaves")

        let copy = app.buttons["talk.notice.copy"]
        copy.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { copy.label == "Copied" }, "Copy Details reads Copied (\(copy.label))")
        // The recent voice events follow the notice's words (spec §6.4).
        XCTAssertTrue((probe(app)["copied"] as? String ?? "")
            .hasPrefix("Voice Paused\nPaused after 2 minutes of silence. Your chat with Ivy is saved.\nRecent voice events:"))

        app.buttons["talk.notice.primary"].tap()
        XCTAssertTrue(dockTitle(app).waitForExistence(timeout: 8), "Resume starts a conversation")
        XCTAssertFalse(title.exists)
        XCTAssertEqual(probe(app)["notices"] as? Int, 0)
        XCTAssertTrue(title.waitForExistence(timeout: 15), "it pauses again")
        app.buttons["talk.notice.done"].tap()
        XCTAssertTrue(talk(app).waitForExistence(timeout: 5), "Done brings the composer back")
        XCTAssertFalse(title.exists)
        XCTAssertEqual(probe(app)["notices"] as? Int, 0)
        XCTAssertEqual(prompts().count, 0, "silence sent nothing")
    }

    // MARK: E09 Interruptions and leaving the app

    @MainActor func testE09a_ACallThenLeavingTheApp() throws {
        let app = launch(["-HQDebugTalkInterruptAfter", "2", "-HQDebugTalkInterruptReason", "interrupted"])
        openChat(app, "ivy")
        talk(app).tap()
        let title = app.staticTexts["talk.notice.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15), "the interruption pauses the conversation")
        XCTAssertEqual(title.label, "Voice Paused")
        XCTAssertEqual(app.staticTexts["talk.notice.message"].label, "A call or Siri took the microphone. Your chat with Ivy is saved.")
        shot(app, "E09-paused-interrupted")
        app.buttons["talk.notice.primary"].tap()
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 12), "Resume listens again (\(dockTitle(app).label))")

        // [talk-background] Home: the conversation goes on with the app away, past the socket's 25 s background grace,
        // with its Live Activity in the Dynamic Island; back in the app it is still listening, with no notice.
        XCTAssertTrue((probe(app)["activity"] as? String ?? "").lowercased().hasSuffix("listening"), "\(probe(app)["activity"] ?? "none")")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        let island = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        island.name = "E09-away-home-screen"
        island.lifetime = .keepAlways
        add(island)
        Thread.sleep(forTimeInterval: 30)
        app.activate()
        // "Still Listening" is the dock's word for a long quiet stretch: the conversation is live either way.
        XCTAssertTrue(waitUntil(timeout: 12) { self.dockTitle(app).label.hasSuffix("Listening") },
                      "still listening after 33 s away (\(dockTitle(app).label))")
        XCTAssertFalse(title.exists, "leaving the app no longer pauses it")
        XCTAssertEqual(probe(app)["conversations"] as? Int, 1)
        XCTAssertTrue((probe(app)["activity"] as? String ?? "").lowercased().hasSuffix("listening"), "\(probe(app)["activity"] ?? "none")")
        let events = (probe(app)["events"] as? [String]) ?? []
        XCTAssertTrue(events.contains("conversation goes on with the app away"), "\(events)")
        shot(app, "E09-back-still-listening")
        app.buttons["talk.dock.end"].tap()
        XCTAssertTrue(talk(app).waitForExistence(timeout: 10))
        XCTAssertEqual(probe(app)["activity"] as? String, "")
    }

    /// [talk-background] The Lock Screen draws the activity: the bot's name and the status, not a blank black card
    /// (owner, build 404). Needs the original identity (the extension is embedded only there).
    @MainActor func testE09c_TheLockScreenShowsTheConversation() throws {
        let app = launch()
        openChat(app, "ivy")
        talk(app).tap()
        XCTAssertTrue(waitUntil(timeout: 15) { self.dockTitle(app).label.hasSuffix("Listening") }, "listening (\(dockTitle(app).label))")
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        Thread.sleep(forTimeInterval: 2)
        // Wakes the screen without unlocking it: the Lock Screen with the activity.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // The first activity asks once whether the app may show them ("Allow"); a later one, whether to go on
        // ("Always Allow", under the card).
        for answer in ["Allow", "Always Allow"] where springboard.buttons[answer].waitForExistence(timeout: 3) {
            let ask = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            ask.name = "E09-lock-screen-allow"
            ask.lifetime = .keepAlways
            add(ask)
            springboard.buttons[answer].tap()
            Thread.sleep(forTimeInterval: 2)
        }
        let lock = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        lock.name = "E09-lock-screen"
        lock.lifetime = .keepAlways
        add(lock)
        XCTAssertTrue(springboard.staticTexts["Ivy"].waitForExistence(timeout: 5), "the activity shows the bot's name")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(waitUntil(timeout: 12) { self.dockTitle(app).label.hasSuffix("Listening") }, "still listening (\(dockTitle(app).label))")
        app.buttons["talk.dock.end"].tap()
    }

    @MainActor func testE09b_RouteLostAndAnAudioReset() throws {
        var app = launch(["-HQDebugTalkInterruptAfter", "2", "-HQDebugTalkInterruptReason", "route-lost"])
        openChat(app, "ivy")
        talk(app).tap()
        var title = app.staticTexts["talk.notice.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(title.label, "Voice Paused")
        XCTAssertEqual(app.staticTexts["talk.notice.message"].label, "The headset or microphone disconnected. Your chat with Ivy is saved.")
        shot(app, "E09-paused-route")
        app.buttons["talk.notice.done"].tap()
        XCTAssertTrue(talk(app).waitForExistence(timeout: 5), "Done brings the composer back")

        app = launch(["-HQDebugTalkInterruptAfter", "2", "-HQDebugTalkInterruptReason", "reset"], reset: false)
        openChat(app, "ivy")
        talk(app).tap()
        title = app.staticTexts["talk.notice.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["talk.notice.message"].label, "A call or Siri took the microphone. Your chat with Ivy is saved.")
        let detail = app.descendants(matching: .any)["talk.notice.detail"]
        XCTAssertTrue(detail.exists, "the detail shows")
        XCTAssertEqual(detail.value as? String ?? detail.label, "iOS reset its audio services")
        app.buttons["talk.notice.copy"].tap()
        // The notice's words and its detail, then the recent voice events (spec §6.4).
        XCTAssertTrue(waitUntil(timeout: 3) { (self.probe(app)["copied"] as? String ?? "").contains("iOS reset its audio services") })
        XCTAssertTrue((probe(app)["copied"] as? String ?? "").hasPrefix(
            "Voice Paused\nA call or Siri took the microphone. Your chat with Ivy is saved.\niOS reset its audio services\nRecent voice events:"))
        shot(app, "E09-paused-reset-detail")
    }

    // MARK: E10 The away pill

    @MainActor func testE10_AwayPill() throws {
        let app = launch()
        openChat(app, "ivy")
        talk(app).tap()
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 12))
        back(app)
        let pill = app.buttons["talk.pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 4), "the pill shows on the list")
        XCTAssertTrue(pill.label.hasPrefix("Ivy · Listening · 0:"), pill.label)
        XCTAssertTrue(pill.label.hasSuffix("Return to the conversation"), pill.label)
        let endButton = app.buttons["talk.pill.end"]
        XCTAssertTrue(endButton.exists, "with End")
        XCTAssertEqual(endButton.label, "End Voice Conversation")
        let bar = app.tabBars.firstMatch
        XCTAssertLessThanOrEqual(pill.frame.maxY, bar.frame.minY, "above the tab bar")
        XCTAssertEqual(probe(app)["conversations"] as? Int, 1, "the conversation goes on")
        XCTAssertEqual(probe(app)["keepAwake"] as? Int, 1, "and keeps the screen awake on the list too")
        XCTAssertEqual(probe(app)["pill"] as? Bool, true, "TalkAwayPill.isShowing says so (what the Undo pill asks)")
        shot(app, "E10-pill-on-list")

        // In another bot's chat it sits above that composer.
        openChat(app, "default")
        XCTAssertTrue(pill.waitForExistence(timeout: 4))
        XCTAssertLessThanOrEqual(pill.frame.maxY, app.textViews["composer.text"].frame.minY, "above the other chat's composer")
        shot(app, "E10-pill-over-another-chat")
        pill.tap()
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 10), "the pill opens Ivy's chat with its dock (\(dockTitle(app).label))")
        XCTAssertTrue(waitUntil(timeout: 4) { !pill.exists }, "the pill leaves in its own chat")
        XCTAssertTrue(waitUntil(timeout: 3) { self.probe(app)["pill"] as? Bool == false }, "and TalkAwayPill.isShowing is false again")
        XCTAssertTrue(app.descendants(matching: .any)["talk.dock"].label.contains("Ivy"))

        // End on the pill ends it.
        back(app)
        if !app.cells["bot-row-default"].isHittable { back(app) }
        XCTAssertTrue(endButton.waitForExistence(timeout: 5))
        endButton.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !pill.exists }, "the pill leaves")
        XCTAssertEqual(probe(app)["conversations"] as? Int, 0)
        XCTAssertEqual(probe(app)["keepAwake"] as? Int, 0)
    }

    // MARK: E11 One microphone

    @MainActor func testE11_OneMicrophone() throws {
        let app = launch()
        openChat(app, "ivy")
        talk(app).tap()
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 12))
        back(app)
        XCTAssertTrue(app.buttons["talk.pill"].waitForExistence(timeout: 4))
        // Talk in another chat ends Ivy's first.
        openChat(app, "default")
        talk(app).tap()
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 12), "Hermes's dock is live (\(dockTitle(app).label))")
        XCTAssertTrue(app.descendants(matching: .any)["talk.dock"].label.contains("Hermes"))
        var now = probe(app)
        XCTAssertEqual(now["conversations"] as? Int, 1, "one conversation")
        XCTAssertEqual(now["started"] as? Int, 2)
        XCTAssertEqual(now["owner"] as? String, "conversation")
        XCTAssertFalse(app.buttons["talk.pill"].exists, "no pill for Ivy")
        XCTAssertTrue(waitUntil(timeout: 8) {
            let leases = (try? self.voiceState())?["leases"] as? [String: [Any]] ?? [:]
            return leases["tts"]?.count == 1 && leases["stt"]?.count == 1
        }, "the gateway holds one warm-up lease of each kind (\((try? voiceState())?["leases"] ?? "nil"))")
        back(app)
        let pill = app.buttons["talk.pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 4))
        XCTAssertTrue(pill.label.hasPrefix("Hermes · "), "the pill is Hermes's (\(pill.label))")

        // The memo mic in another chat ends the conversation first, then records.
        openChat(app, "ivy")
        XCTAssertFalse(app.staticTexts["talk.notice.title"].exists, "Ivy's chat shows nothing of the ended conversation")
        let sent = prompts().count
        app.buttons["composer.mic"].press(forDuration: 2.0)
        XCTAssertTrue(waitUntil(timeout: 15) { self.prompts().count == sent + 1 }, "the memo was recorded and sent")
        now = probe(app)
        XCTAssertEqual(now["conversations"] as? Int, 0, "the conversation ended for the memo")
        XCTAssertFalse(pill.exists)
        XCTAssertTrue(prompts().last?["text"] as? String ?? "" != "", "the memo's prompt")
        XCTAssertTrue(waitUntil(timeout: 8) {
            let leases = (try? self.voiceState())?["leases"] as? [String: [Any]] ?? [:]
            return (leases["tts"]?.count ?? 0) == 0 && (leases["stt"]?.count ?? 0) == 0
        }, "the leases were given back")
    }

    // MARK: E12 The ways in

    @MainActor func testE12a_BotRowTalkTile() throws {
        let app = launch()
        let row = app.cells["bot-row-ivy"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let tile = holdMenu(app, row, "Talk")
        let memo = app.buttons["Memo"].firstMatch, pin = app.buttons["Pin"].firstMatch
        XCTAssertTrue(memo.exists && pin.exists, "Talk, Memo and Pin are the tiles")
        XCTAssertLessThan(tile.frame.midX, memo.frame.midX, "Talk comes first")
        XCTAssertLessThan(memo.frame.midX, pin.frame.midX, "then Memo, then Pin")
        XCTAssertTrue(tile.isEnabled)
        shot(app, "E12a-row-menu")
        tile.tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 8), "the chat opens")
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 15), "and the conversation starts (\(dockTitle(app).label))")
        shot(app, "E12a-started-from-the-row")
        // E12f: nothing was recorded before the chat was on screen.
        let events = probe(app)["events"] as? [String] ?? []
        let onScreen = events.firstIndex(of: "debug: chat on screen")
        let microphone = events.firstIndex(of: "audio session: conversation acquired")
        let started = events.firstIndex(of: "conversation started")
        XCTAssertNotNil(onScreen, "\(events)")
        XCTAssertNotNil(microphone, "\(events)")
        if let onScreen, let microphone, let started {
            XCTAssertLessThan(onScreen, started, "the chat was on screen before the conversation started (\(events))")
            XCTAssertLessThan(onScreen, microphone, "and before the microphone was taken (\(events))")
        }
        end(app)
    }

    @MainActor func testE12b_UnreachableBotDisablesTheTiles() throws {
        let app = launch()
        let row = app.cells["bot-row-ivy"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        try account.control("/__fixture/voice", ["refuseSocketFor": 40, "dropSocket": true])
        Thread.sleep(forTimeInterval: 4)
        let tile = holdMenu(app, row, "Talk", prefix: true)
        XCTAssertFalse(tile.isEnabled, "Talk waits while the bot cannot be reached")
        XCTAssertEqual(tile.label, "Talk, Can’t reach this bot", "and says why")
        let memo = menuItem(app, "Memo", prefix: true)
        XCTAssertTrue(memo.exists && !memo.isEnabled, "Memo waits too (\(memo.label))")
        shot(app, "E12b-row-menu-unreachable")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        XCTAssertEqual(probe(app)["started"] as? Int, 0)
        try account.control("/__fixture/voice", ["refuseSocketFor": 0])
    }

    @MainActor func testE12c_EmptyChatCapsules() throws {
        try account.control("/__fixture/voice", ["emptyChat": "ivy"])       // the stand-in gateway cannot start a new chat
        let app = launch()
        openChat(app, "ivy")
        let capsule = app.buttons["chat.intro.talk"]
        XCTAssertTrue(capsule.waitForExistence(timeout: 10), "an empty chat offers Talk")
        XCTAssertEqual(capsule.label, "Talk with Ivy")
        let info = app.buttons["chat.intro.info"]
        XCTAssertTrue(info.exists, "and Bot Info")
        XCTAssertEqual(capsule.frame.midY, info.frame.midY, accuracy: 1, "side by side")
        XCTAssertGreaterThanOrEqual(capsule.frame.height, 44)
        shot(app, "E12c-empty-chat")
        info.tap()
        XCTAssertTrue(app.staticTexts["bot-info.name"].waitForExistence(timeout: 6), "Bot Info opens")
        app.buttons["bot-info.close"].tap()
        XCTAssertTrue(capsule.waitForExistence(timeout: 5))
        capsule.tap()
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 15), "Talk starts a conversation (\(dockTitle(app).label))")
        end(app)
    }

    @MainActor func testE12d_BotInfoTalkTile() throws {
        let app = launch()
        let row = app.cells["bot-row-ivy"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        holdMenu(app, row, "Bot Info").tap()
        XCTAssertTrue(app.staticTexts["bot-info.name"].waitForExistence(timeout: 6), "Bot Info opens")
        let talkTile = app.buttons["bot-info.tile.talk"], memo = app.buttons["bot-info.tile.memo"], mute = app.buttons["bot-info.tile.mute"]
        let screen = app.buttons["bot-info.tile.screen"]   // the screen stream's tile, between Memo and Mute
        XCTAssertTrue(talkTile.waitForExistence(timeout: 4) && memo.exists && screen.exists && mute.exists, "Talk, Memo, Screen and Mute")
        XCTAssertLessThan(talkTile.frame.midX, memo.frame.midX)
        XCTAssertLessThan(memo.frame.midX, screen.frame.midX)
        XCTAssertLessThan(screen.frame.midX, mute.frame.midX)
        XCTAssertEqual(memo.frame.minX - talkTile.frame.maxX, screen.frame.minX - memo.frame.maxX, accuracy: 1, "evenly spaced")
        XCTAssertEqual(screen.frame.minX - memo.frame.maxX, mute.frame.minX - screen.frame.maxX, accuracy: 1, "evenly spaced")
        XCTAssertEqual(talkTile.frame.width, memo.frame.width, accuracy: 1)
        XCTAssertTrue(talkTile.isEnabled)
        shot(app, "E12d-bot-info-tiles")
        talkTile.tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 8), "the sheet closes and the chat opens")
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 15), "and the conversation starts (\(dockTitle(app).label))")
        XCTAssertFalse(app.staticTexts["bot-info.name"].exists)
        end(app)
    }

    /// Four tiles (Talk, Memo, Screen, Mute) at the default size and at AX3: a row, on screen, in the
    /// web's order, with screenshots to look at for clipped words.
    /// `grid`: from AX1 the shared quick-action tiles are two to a row (3x-morepages §8): Talk, Memo / Screen, Mute.
    @MainActor private func fourTiles(_ extra: [String], _ name: String, grid: Bool = false) {
        let app = launch(extra)
        let row = app.cells["bot-row-ivy"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        holdMenu(app, row, "Bot Info").tap()
        let ids = ["bot-info.tile.talk", "bot-info.tile.memo", "bot-info.tile.screen", "bot-info.tile.mute"]
        let tiles = ids.map { app.buttons[$0] }
        XCTAssertTrue(tiles[0].waitForExistence(timeout: 6), "Bot Info opens")
        let window = app.windows.firstMatch.frame
        for (index, tile) in tiles.enumerated() {
            XCTAssertTrue(tile.exists, ids[index])
            XCTAssertTrue(window.contains(tile.frame), "\(ids[index]) is on screen (\(tile.frame))")
            XCTAssertGreaterThanOrEqual(tile.frame.height, 44)
            XCTAssertEqual(tile.frame.width, tiles[0].frame.width, accuracy: 1, "every tile is as wide as the first")
            if grid {
                XCTAssertEqual(tile.frame.minX, tiles[index % 2].frame.minX, accuracy: 1, "two columns")
                XCTAssertEqual(tile.frame.midY, tiles[index - index % 2].frame.midY, accuracy: 1, "two to a row")
                if index % 2 == 1 { XCTAssertGreaterThanOrEqual(tile.frame.minX, tiles[index - 1].frame.maxX, "Talk, Memo / Screen, Mute") }
                if index >= 2 { XCTAssertGreaterThanOrEqual(tile.frame.minY, tiles[index - 2].frame.maxY, "the second row is below the first") }
            } else {
                XCTAssertEqual(tile.frame.midY, tiles[0].frame.midY, accuracy: 1, "in one row")
                if index > 0 { XCTAssertGreaterThanOrEqual(tile.frame.minX, tiles[index - 1].frame.maxX, "Talk, Memo, Screen, Mute") }
            }
        }
        XCTAssertGreaterThanOrEqual(tiles[0].frame.width, 60, "wide enough for its word (\(tiles[0].frame.width))")
        shot(app, "E12g-four-tiles-\(name)")
    }

    @MainActor func testE12g_FourBotInfoTilesFit() throws {
        fourTiles([], "default")
        XCUIApplication().terminate()
        fourTiles(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"], "AX3", grid: true)
        XCUIApplication().terminate()
        fourTiles(["-hqn.appearance", "dark"], "dark")
    }

    @MainActor func testE12e_PlusMenu() throws {
        let app = launch()
        openChat(app, "ivy")
        plus(app).tap()
        let memo = app.buttons["composer.plus.memo"], item = app.buttons["composer.plus.talk"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "+ has Talk with Ivy")
        XCTAssertEqual(item.label, "Talk with Ivy")
        XCTAssertEqual(memo.label, "Voice Memo")
        // The order on screen: Camera, Photos, Files, Voice Memo, Talk with Ivy (whichever way the menu opens).
        let order = ["composer.plus.camera", "composer.plus.photos", "composer.plus.files", "composer.plus.memo", "composer.plus.talk"]
            .map { app.buttons[$0].frame.midY }
        XCTAssertTrue(order == order.sorted() || order == order.sorted(by: >), "Camera, Photos, Files, Voice Memo, Talk in order (\(order))")
        shot(app, "E12e-plus-menu")
        // Voice Memo opens the locked, hands-free recorder.
        memo.tap()
        XCTAssertTrue(app.buttons["memo.stop"].waitForExistence(timeout: 6), "Voice Memo records hands-free")
        XCTAssertEqual(probe(app)["keepAwake"] as? Int, 1, "a memo take keeps the screen awake")
        app.buttons["memo.delete"].tap()
        if app.alerts.firstMatch.waitForExistence(timeout: 1.5) { app.alerts.firstMatch.buttons["Delete"].tap() }
        XCTAssertTrue(talk(app).waitForExistence(timeout: 6), "the recorder is gone")
        XCTAssertTrue(waitUntil(timeout: 4) { self.probe(app)["keepAwake"] as? Int == 0 }, "and so is its hold")
        // Talk with Ivy starts a conversation.
        plus(app).tap()
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 12), "Talk with Ivy starts (\(dockTitle(app).label))")
        end(app)
    }

    // MARK: E13 The voice options menu

    @MainActor func testE13_VoiceOptionsMenu() throws {
        let app = launch()
        openChat(app, "ivy")
        openOptions(app)
        XCTAssertTrue(app.staticTexts["Voice with Ivy"].exists, "the menu's title")
        let ids = ["voice.options.start", "voice.options.read-replies", "voice.options.dictate", "voice.options.how", "voice.options.settings"]
        let titles = ["Start Voice Conversation", "Read Replies Aloud", "Dictate with Hermes", "How Voice Works", "Voice Settings…"]
        for (id, title) in zip(ids, titles) {
            XCTAssertTrue(app.buttons[id].exists, id)
            XCTAssertTrue(app.buttons[id].label.hasPrefix(title), "\(id) reads \(app.buttons[id].label)")
        }
        let order = ids.map { app.buttons[$0].frame.midY }
        XCTAssertTrue(order == order.sorted() || order == order.sorted(by: >), "the five items in order (\(order))")
        XCTAssertTrue(app.buttons["voice.options.dictate"].isEnabled)
        shot(app, "E13-voice-options")

        // Read Replies Aloud toggles with the menu still open.
        XCTAssertEqual(probe(app)["readReplies"] as? Bool, false)
        app.buttons["voice.options.read-replies"].tap()
        XCTAssertTrue(waitUntil(timeout: 4) { self.probe(app)["readReplies"] as? Bool == true }, "the switch turned on")
        XCTAssertTrue(app.buttons["voice.options.start"].exists, "the menu stays open")
        shot(app, "E13-voice-options-read-on")
        app.buttons["voice.options.read-replies"].tap()
        XCTAssertTrue(waitUntil(timeout: 4) { self.probe(app)["readReplies"] as? Bool == false })

        // How Voice Works: six rows and Done.
        app.buttons["voice.options.how"].tap()
        let title = app.staticTexts["talk.intro.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 6), "How Voice Works opens")
        XCTAssertTrue(labelled(app, "Voice memos. Hold the mic and talk, then let go to send. A quick tap records hands-free; tap Send when you’re done.").exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'If a conversation pauses. A call, Siri, leaving '")).firstMatch.exists)
        XCTAssertTrue(app.buttons["talk.intro.done"].exists)
        XCTAssertFalse(app.buttons["talk.intro.start"].exists, "the info form has one button")
        shot(app, "E13-how-voice-works")
        app.buttons["talk.intro.done"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !title.exists })
        XCTAssertEqual(probe(app)["started"] as? Int, 0, "reading about voice starts nothing")

        // Voice Settings… lands on Settings › Voice.
        openOptions(app)
        app.buttons["voice.options.settings"].tap()
        XCTAssertTrue(app.buttons["config-page.voice.conversation"].waitForExistence(timeout: 10), "Settings opens on its Voice section")
        XCTAssertTrue(app.buttons["config-page.voice.transcription"].exists && app.buttons["config-page.voice.speech"].exists)
        shot(app, "E13-voice-settings-from-the-menu")
    }

    @MainActor func testE13b_DictateIsOffWhenSpeechToTextIsOff() throws {
        try account.control("/__fixture/voice", ["stt": ["default": false]])
        let app = launch()
        openChat(app, "ivy")
        Thread.sleep(forTimeInterval: 2)                        // the bot's settings arrive
        openOptions(app)
        let dictate = app.buttons["voice.options.dictate"]
        XCTAssertTrue(dictate.exists)
        XCTAssertFalse(dictate.isEnabled, "Dictate with Hermes waits")
        XCTAssertTrue(labelled(app, "Speech to Text is off", contains: true).exists, "and says why")
        shot(app, "E13-dictate-off")
    }
}
