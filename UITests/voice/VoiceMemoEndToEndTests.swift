// Voice memos end to end (docs/spec/1x-voice.md §9 E-1…E-20) against the voice stand-in gateway
// (scripts/fixtures/voice-gateway.py), run by scripts/e2e-voice.sh on 127.0.0.1:9727. Real touches only:
// `press(forDuration:)` and `press(forDuration:thenDragTo:…)` (never synthesised events: MEM voice-memo-bugs). The
// simulator's microphone is replaced by the app's fixture recorder (`-HQDebugMemoFixture`), which writes a WAV.
// Without TEST_RUNNER_HQN_UI_CREDENTIALS every test skips.

import XCTest

final class VoiceMemoEndToEndTests: XCTestCase {
    private var account: FixtureAccount!

    override func setUpWithError() throws {
        continueAfterFailure = false
        account = try FixtureAccount.load()
        try account.control("/__fixture/voice", ["reset": true])
    }

    // MARK: E-1 Hold and release sends

    @MainActor func testE01_HoldTwoSecondsSends() throws {
        let app = launch()
        openChat(app, "default")
        let before = prompts()
        mic(app).press(forDuration: 2.0)
        XCTAssertTrue(waitUntil(timeout: 15) { self.prompts().count == before.count + 1 }, "one prompt went out")
        let prompt = try XCTUnwrap(prompts().last)
        let text = prompt["text"] as? String ?? ""
        XCTAssertTrue(text.hasPrefix("MEDIA:\""), "the memo's directive leads (\(text))")
        XCTAssertTrue(text.contains("Voice memo transcript: Synthetic transcript of a 2 s voice memo."), text)
        XCTAssertEqual(prompt["profile"] as? String, "default")
        let words = transcript(app, containing: "Synthetic transcript of a 2 s voice memo.")
        XCTAssertTrue(words.waitForExistence(timeout: 10), "the bubble shows the transcript")
        XCTAssertTrue(app.buttons["memo.play"].firstMatch.exists, "the bubble has its play disc")
        // The bubble's length: a 2.0 s hold reads 0:02 (its rounded total), as Telegram shows it.
        let sent = try XCTUnwrap(bubbles(app, containing: "Synthetic transcript of a 2 s voice memo.").last)
        let wave = sent.descendants(matching: .any)["memo.wave"]
        XCTAssertTrue(wave.waitForExistence(timeout: 5))
        XCTAssertTrue((wave.value as? String ?? "").hasSuffix("of 0:02"), "the bubble's length is 0:02 (\(wave.value ?? "nil"))")
        XCTAssertEqual(app.keyboards.count, 0, "the keyboard did not come up")
        let state = try voiceState()
        XCTAssertEqual(state["filesReads"] as? Int, 1)
        XCTAssertEqual((state["uploads"] as? [Any])?.count, 1)
        XCTAssertEqual((state["attaches"] as? [[String: Any]])?.count, 1)
        let attach = try XCTUnwrap((state["attaches"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(attach.keys).subtracting(["result", "stored"]), ["session_id", "profile", "name", "path"], "file.attach keys")
        XCTAssertEqual((state["transcribes"] as? [Any])?.count, 1)
        XCTAssertTrue(waitUntil(timeout: 5) { ((try? self.voiceState())?["deletes"] as? [Any])?.count == 1 }, "the staging folder was removed")
        attachScreenshot(app, "E01-sent-memo")
    }

    // MARK: E-2 Tap locks; Stop → review; Play; Send; the tip

    @MainActor func testE02_TapLocksThenReviewAndSend() throws {
        let app = launch()
        openChat(app, "default")
        let before = prompts().count
        mic(app).press(forDuration: 0.3)
        let stop = app.buttons["memo.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "the locked row shows")
        XCTAssertTrue(app.buttons["memo.delete"].exists, "with its trash")
        XCTAssertTrue(app.buttons["composer.send"].exists, "and Send")
        attachScreenshot(app, "E02-locked")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(stop.exists, "still recording after 3 s")
        XCTAssertEqual(prompts().count, before, "nothing was sent")
        stop.tap()
        let play = app.buttons["memo.review.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 5), "Stop opens review")
        let status = app.descendants(matching: .any)["memo.status"]
        // Verify round 1: the recorder takes the whole row (☰ and + give way), and review's pill — waveform and time —
        // ends before Send (it had run 40 bars under the time and past the field, under Send).
        XCTAssertFalse(app.descendants(matching: .any)["composer.commands"].firstMatch.isHittable, "☰ gives way to the recorder")
        XCTAssertLessThan(status.frame.maxX, app.buttons["composer.send"].frame.minX, "review's pill ends before Send")
        attachScreenshot(app, "E02-review")
        play.tap()
        XCTAssertTrue(waitUntil(timeout: 4) { app.buttons["Pause Voice Memo"].exists }, "it plays")
        Thread.sleep(forTimeInterval: 1.2)
        attachScreenshot(app, "E02-review-playing")
        _ = status
        app.buttons["composer.send"].tap()
        XCTAssertTrue(waitUntil(timeout: 15) { self.prompts().count == before + 1 }, "Send sends one prompt")
        let tip = app.staticTexts["Hold to Record"]
        XCTAssertTrue(tip.waitForExistence(timeout: 8), "the Hold to Record tip shows once")
        attachScreenshot(app, "E02-tip")
    }

    // MARK: E-3 A still finger's release is heard

    @MainActor func testE03_StillHoldAndReleaseIsHeard() throws {
        let app = launch()
        openChat(app, "default")
        let before = prompts().count
        mic(app).press(forDuration: 1.5)
        XCTAssertTrue(waitUntil(timeout: 15) { self.prompts().count == before + 1 }, "the release sent it")
    }

    // MARK: E-4 Slide left cancels
    // ("Release to Cancel" itself is checked in MemoViewTests: the finger owns the hold row, hidden from the
    // accessibility tree, and XCUITest can't look while a press is held.)

    @MainActor func testE04_SlideLeftCancels() throws {
        let app = launch()
        openChat(app, "default")
        let before = prompts().count
        let start = center(mic(app))
        start.press(forDuration: 0.6, thenDragTo: start.withOffset(CGVector(dx: -150, dy: 0)))
        Thread.sleep(forTimeInterval: 2)
        let state = try voiceState()
        XCTAssertEqual((state["uploads"] as? [Any])?.count, 0, "no upload")
        XCTAssertEqual(prompts().count, before, "no prompt")
        XCTAssertFalse(app.descendants(matching: .any)["memo.chip"].exists, "no draft")
        XCTAssertTrue(mic(app).exists, "the mic is back")
    }

    // MARK: E-5 Slide up locks

    @MainActor func testE05_SlideUpLocks() throws {
        let app = launch()
        openChat(app, "default")
        let start = center(mic(app))
        start.press(forDuration: 0.6, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -100)), withVelocity: .default, thenHoldForDuration: 0.3)
        let stop = app.buttons["memo.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "locked")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(stop.exists, "release keeps it recording")
        app.buttons["memo.delete"].tap()
    }

    // MARK: E-6 Delete a long take asks first

    @MainActor func testE06_DeleteLongTakeAsks() throws {
        let app = launch()
        openChat(app, "default")
        let before = prompts().count
        mic(app).press(forDuration: 0.3)
        let trash = app.buttons["memo.delete"]
        XCTAssertTrue(trash.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 12.3)
        trash.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 4), "it asks first")
        XCTAssertTrue(alert.label.hasPrefix("Delete This 0:1"), "the alert names the length, title case (audit 10-7) (\(alert.label))")
        attachScreenshot(app, "E06-confirm-delete")
        alert.buttons["Keep Recording"].tap()
        XCTAssertTrue(app.buttons["memo.stop"].waitForExistence(timeout: 3), "Keep Recording continues")
        trash.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 4))
        alert.buttons["Delete"].tap()
        XCTAssertTrue(mic(app).waitForExistence(timeout: 4), "back to idle")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(prompts().count, before, "nothing was sent")
    }

    // MARK: E-7 The permission prompt's touch records nothing

    @MainActor func testE07_PermissionPromptTeachesHold() throws {
        let app = launch(permission: "undetermined")
        openChat(app, "default")
        mic(app).press(forDuration: 0.4)
        let tip = app.staticTexts["Now Hold to Record"]
        XCTAssertTrue(tip.waitForExistence(timeout: 5), "the Now Hold to Record tip shows")
        XCTAssertFalse(app.buttons["memo.stop"].exists, "nothing records")
        XCTAssertEqual((try voiceState()["uploads"] as? [Any])?.count, 0)
        attachScreenshot(app, "E07-now-hold-tip")
        let before = prompts().count
        mic(app).press(forDuration: 1.6)
        XCTAssertTrue(waitUntil(timeout: 15) { self.prompts().count == before + 1 }, "the next hold records and sends")
    }

    // MARK: E-8 Microphone off

    @MainActor func testE08_DeniedShowsTheCard() throws {
        let app = launch(permission: "denied")
        openChat(app, "default")
        mic(app).press(forDuration: 0.3)
        let title = app.staticTexts["memo.notice.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the notice card shows")
        XCTAssertEqual(title.label, "Microphone Access Is Off")
        XCTAssertTrue(app.buttons["memo.notice.action"].exists && app.buttons["memo.notice.action"].label == "Open Settings")
        XCTAssertFalse(app.buttons["memo.notice.copy"].exists, "nothing technical to copy")
        attachScreenshot(app, "E08-mic-off")
        Thread.sleep(forTimeInterval: 4)
        XCTAssertTrue(title.exists, "it stays until closed")
        app.buttons["memo.notice.close"].tap()
        XCTAssertTrue(waitUntil(timeout: 3) { !title.exists }, "Close removes it")
    }

    // MARK: E-9 A take left behind is a draft in its own chat

    @MainActor func testE09_DraftStaysInItsChat() throws {
        let app = launch()
        openChat(app, "default")
        mic(app).press(forDuration: 0.3)
        XCTAssertTrue(app.buttons["memo.stop"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2.2)
        back(app)
        openChat(app, "ivy")
        XCTAssertFalse(app.descendants(matching: .any)["memo.chip"].waitForExistence(timeout: 2), "Ivy's composer has no chip")
        back(app)
        openChat(app, "default", expectMic: false)
        let chip = app.staticTexts["memo.chip.title"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "Hermes's composer has the chip")
        XCTAssertTrue(chip.label.hasPrefix("Voice Memo 0:0"), chip.label)
        attachScreenshot(app, "E09-draft-chip")
        let before = prompts()
        app.buttons["composer.send"].tap()
        XCTAssertTrue(waitUntil(timeout: 15) { self.prompts().count == before.count + 1 }, "one prompt")
        XCTAssertEqual(prompts().last?["profile"] as? String, "default", "into Hermes's chat only")
    }

    // MARK: E-10 A call or Siri mid-hold leaves a draft

    @MainActor func testE10_InterruptionLeavesADraft() throws {
        let app = launch(["-HQDebugMemoInterruptAfter", "2"])
        openChat(app, "default")
        let before = prompts().count
        mic(app).press(forDuration: 3.0)
        let title = app.staticTexts["memo.notice.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the notice shows")
        XCTAssertEqual(title.label, "Recording Stopped")
        let message = app.textViews["memo.notice.message"]
        XCTAssertTrue((message.value as? String ?? message.label).contains("A call or Siri took the microphone. Your 0:02 memo is waiting in the message field."),
                      "\(message.value ?? message.label)")
        XCTAssertTrue(app.staticTexts["memo.chip.title"].waitForExistence(timeout: 3), "the chip appears")
        XCTAssertEqual(prompts().count, before, "nothing was sent")
        attachScreenshot(app, "E10-recording-stopped")
    }

    // MARK: E-11 Speech-to-text off

    @MainActor func testE11_SttOffSaysSo() throws {
        try account.control("/__fixture/voice", ["stt": ["default": false]])
        let app = launch()
        openChat(app, "default")
        let before = prompts().count
        mic(app).press(forDuration: 1.6)
        XCTAssertTrue(waitUntil(timeout: 15) { self.prompts().count == before + 1 })
        XCTAssertTrue((prompts().last?["text"] as? String ?? "").hasSuffix("Voice memo transcript: (unavailable: speech-to-text is off on the gateway)"))
        XCTAssertTrue(transcript(app, containing: "No transcript: speech-to-text is off on your gateway.").waitForExistence(timeout: 8))
        XCTAssertEqual((try voiceState()["transcribes"] as? [Any])?.count, 0, "no transcription call")
    }

    // MARK: E-12 Transcription fails, the memo still goes

    @MainActor func testE12_TranscriptionFailureStillSends() throws {
        try account.control("/__fixture/voice", ["transcribeFail": ["status": 500, "detail": "Transcription failed"]])
        let app = launch()
        openChat(app, "default")
        let before = prompts().count
        mic(app).press(forDuration: 1.6)
        XCTAssertTrue(waitUntil(timeout: 15) { self.prompts().count == before + 1 })
        XCTAssertTrue((prompts().last?["text"] as? String ?? "").hasSuffix("Voice memo transcript: (unavailable)"))
        let title = app.staticTexts["memo.notice.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "No Transcript for This Voice Memo")
        XCTAssertTrue(transcript(app, containing: "No transcript").waitForExistence(timeout: 5))
        attachScreenshot(app, "E12-no-transcript")
    }

    // MARK: E-13 A memo that can't go out comes back as the chip; a retry stages and pays once

    @MainActor func testE13_UploadFailureReturnsTheDraft() throws {
        try account.control("/__fixture/voice", ["filesStatus": 500])
        let app = launch()
        openChat(app, "default")
        let before = prompts().count
        // The files root fails: nothing sent, an error card, the chip back.
        mic(app).press(forDuration: 1.6)
        // The "Couldn’t Send" card docked above the composer says why (3x-transcript §6.3), not a transcript row.
        let failure = app.staticTexts.matching(identifier: "chat.sendFailure.body")
        let card = failure.matching(NSPredicate(format: "label CONTAINS %@", "upload the voice memo")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "an error card says why")
        XCTAssertTrue(app.staticTexts["memo.chip.title"].waitForExistence(timeout: 5), "the chip is back")
        XCTAssertEqual(prompts().count, before, "no prompt")
        attachScreenshot(app, "E13-upload-failed")
        // The gateway refuses the submit: the memo was uploaded and transcribed (paid) once; the chip comes back again.
        try account.control("/__fixture/voice", ["filesStatus": NSNull(), "submitRefuse": 1])
        app.buttons["composer.send"].tap()
        XCTAssertTrue(waitUntil(timeout: 15) { self.refusedPrompts() == 1 }, "the submit was refused")
        let refusal = failure.matching(NSPredicate(format: "label CONTAINS %@", "out of credits")).firstMatch
        XCTAssertTrue(refusal.waitForExistence(timeout: 10), "an error card says why")
        XCTAssertTrue(app.staticTexts["memo.chip.title"].waitForExistence(timeout: 5), "the chip is back")
        XCTAssertEqual((try voiceState()["transcribes"] as? [Any])?.count, 1, "transcribed once")
        attachScreenshot(app, "E13-submit-refused")
        // Send again: it goes, reusing what was staged: one upload, one attach, one paid transcription in all.
        app.buttons["composer.send"].tap()
        XCTAssertTrue(waitUntil(timeout: 15) { self.prompts().count == before + 1 }, "one prompt")
        let state = try voiceState()
        XCTAssertEqual((state["uploads"] as? [Any])?.count, 1, "uploaded once")
        XCTAssertEqual((state["attaches"] as? [Any])?.count, 1, "attached once")
        XCTAssertEqual((state["transcribes"] as? [Any])?.count, 1, "the transcript was paid for once")
        XCTAssertTrue((prompts().last?["text"] as? String ?? "").contains("Voice memo transcript: Synthetic transcript"))
    }

    // MARK: E-14 While a reply runs, a memo queues

    @MainActor func testE14_MemoQueuesBehindAReply() throws {
        try account.control("/__fixture/plan", ["plans": [["chunks": Array(repeating: "word ", count: 120), "chunkDelay": 0.05]]])
        let app = launch()
        openChat(app, "default")
        let field = app.textViews["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("A slow one please")
        let sendButton = app.buttons["composer.send"]
        let sent = prompts().count
        sendButton.tap()
        // A tap the keyboard's settling swallowed is tried once more (only while the words are still unsent).
        if !waitUntil(timeout: 3, { self.prompts().count > sent }) { sendButton.tap() }
        let running = app.buttons["composer.stop"].waitForExistence(timeout: 8)
        if !running { attachScreenshot(app, "E14-failure-no-stop") }
        XCTAssertTrue(running, "the reply runs")
        app.tables["chat.table"].tap()      // the keyboard goes; the mic shows on the empty field
        let before = prompts().count
        mic(app).press(forDuration: 2.2)
        let queued = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Voice Memo 0:02")).firstMatch
        XCTAssertTrue(queued.waitForExistence(timeout: 5), "the queue card lists the memo")
        attachScreenshot(app, "E14-queued-memo")
        XCTAssertTrue(waitUntil(timeout: 30) { self.prompts().count == before + 1 }, "it sends after the reply")
        XCTAssertEqual(prompts().last?["queued"] as? Bool, true, "with queued:true")
    }

    // MARK: E-15 History memos: play, speed, one at a time, a missing file

    @MainActor func testE15_HistoryPlaybackAndSpeed() throws {
        let tag = Int(Date().timeIntervalSince1970) % 100_000
        try account.control("/__fixture/memo-history", ["profile": "default", "memos": [
            ["seconds": 24, "transcript": "First seeded memo \(tag)."], ["seconds": 8, "off": true],
            ["seconds": 4, "missing": true, "transcript": "Missing seeded memo \(tag)."]]])
        var app = launch()
        openChat(app, "default")
        let first = bubble(app, containing: "First seeded memo \(tag).")
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.buttons["memo.play"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { first.buttons["Pause Voice Memo"].exists }, "it plays")
        let speed = first.buttons["memo.speed"]
        XCTAssertTrue(speed.waitForExistence(timeout: 3), "the speed shows while playing")
        speed.tap()
        XCTAssertTrue(waitUntil(timeout: 2) { speed.label.contains("1.5×") }, speed.label)
        attachScreenshot(app, "E15-playing-1-5x")
        let missing = bubble(app, containing: "Missing seeded memo \(tag).")
        XCTAssertTrue(missing.staticTexts["Couldn’t load audio"].waitForExistence(timeout: 8), "the missing memo says so")
        XCTAssertTrue(missing.buttons["memo.retry"].exists, "with Retry")
        speed.tap()
        XCTAssertTrue(waitUntil(timeout: 2) { speed.label.contains("2×") })
        speed.tap()
        XCTAssertTrue(waitUntil(timeout: 2) { speed.label.contains("1×") })
        speed.tap()
        XCTAssertTrue(waitUntil(timeout: 2) { speed.label.contains("1.5×") })
        let second = bubble(app, containing: "speech-to-text is off")
        second.buttons["memo.play"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { second.buttons["Pause Voice Memo"].exists }, "memo 2 plays")
        XCTAssertTrue(first.buttons["Play Voice Memo"].exists, "memo 1 paused")
        app.terminate()
        app = launch(reset: false)
        openChat(app, "default")
        let again = bubble(app, containing: "First seeded memo \(tag).")
        XCTAssertTrue(again.waitForExistence(timeout: 10))
        XCTAssertTrue(again.buttons["memo.speed"].waitForExistence(timeout: 3), "the speed stays shown (not 1×)")
        XCTAssertTrue(again.buttons["memo.speed"].label.contains("1.5×"), "1.5× is still set after the relaunch")
    }

    // MARK: E-16 The length limit
    // (The timer's orange in the last 10 s is checked in MemoViewTests: XCUITest can't look while a press is held.)

    @MainActor func testE16_LimitSendsHeldAndReviewsLocked() throws {
        let app = launch(["-HQDebugMemoLimit", "12"])
        openChat(app, "default")
        let before = prompts().count
        mic(app).press(forDuration: 13)
        XCTAssertTrue(waitUntil(timeout: 15) { self.prompts().count == before + 1 }, "the held take sends at the limit")
        mic(app).press(forDuration: 0.3)
        XCTAssertTrue(app.buttons["memo.stop"].waitForExistence(timeout: 5))
        attachScreenshot(app, "E16-locked-near-limit")
        XCTAssertTrue(app.buttons["memo.review.play"].waitForExistence(timeout: 16), "the locked take goes to review at the limit")
        app.buttons["memo.delete"].tap()
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 3) { alert.buttons["Delete"].tap() }
    }

    // MARK: E-17 Leaving mid-upload still lands in that chat

    @MainActor func testE17_LeavingMidUploadFinishesInItsChat() throws {
        try account.control("/__fixture/voice", ["uploadDelay": 4])
        let app = launch()
        openChat(app, "ivy")
        let before = prompts().count
        mic(app).press(forDuration: 1.6)
        Thread.sleep(forTimeInterval: 0.6)
        back(app)
        XCTAssertTrue(app.cells["bot-row-default"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 20) { self.prompts().count == before + 1 }, "the prompt still went out")
        XCTAssertEqual(prompts().last?["profile"] as? String, "ivy", "into Ivy's chat")
    }

    // MARK: E-18 A vertical drag that starts on a memo scrolls the chat

    @MainActor func testE18_VerticalDragOnAMemoScrollsTheChat() throws {
        let tag = Int(Date().timeIntervalSince1970) % 100_000
        try account.control("/__fixture/memo-history", ["profile": "default", "memos": (1...10).map {
            ["seconds": 3 + $0 % 4, "transcript": "Scroll memo \($0) \(tag)."] as [String: Any] }])
        let app = launch()
        openChat(app, "default")
        let memo = bubble(app, containing: "Scroll memo 9 \(tag).")
        XCTAssertTrue(memo.waitForExistence(timeout: 10))
        let wave = memo.descendants(matching: .any)["memo.wave"]
        XCTAssertTrue(wave.waitForExistence(timeout: 5) && wave.isHittable, "the memo's waveform is on screen")
        let before = memo.frame.minY
        let start = wave.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 260)))
        Thread.sleep(forTimeInterval: 1)
        let moved = memo.frame.minY - before
        attachScreenshot(app, "E18-dragged-from-memo")
        XCTAssertGreaterThan(moved, 120, "the chat scrolled with the finger (\(moved) pt)")
        XCTAssertFalse(app.buttons["Pause Voice Memo"].exists, "the drag didn't play the memo")
    }

    // MARK: E-19 A locked take past a minute keeps a live waveform

    @MainActor func testE19_LongLockedTakeKeepsItsWaveform() throws {
        let app = launch(["-HQDebugMemoProbe", "YES"])
        openChat(app, "default")
        let before = prompts().count
        mic(app).press(forDuration: 0.3)
        let live = app.descendants(matching: .any)["memo.live"]
        XCTAssertTrue(live.waitForExistence(timeout: 5), "the locked recorder's live waveform")
        Thread.sleep(forTimeInterval: 20)
        let early = Self.distinct(live)
        Thread.sleep(forTimeInterval: 56)
        let late = Self.distinct(live)
        attachScreenshot(app, "E19-locked-1m16")
        XCTAssertGreaterThan(early, 5, "varied bars at 0:20 (\(live.value ?? "nil"))")
        XCTAssertGreaterThan(late, 5, "still varied bars at 1:16, not a flat or solid block (\(live.value ?? "nil"))")
        app.buttons["memo.delete"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 4))
        alert.buttons["Delete"].tap()
        XCTAssertTrue(mic(app).waitForExistence(timeout: 4), "back to idle")
        XCTAssertEqual(prompts().count, before, "nothing was sent")
    }

    // MARK: E-20 Leaving a chat with a memo still queued sends it when the reply ends

    /// [live words] The memo rides the queue like typed words (spec 3x-live-words §3.1.2): build 573 handed it back as a
    /// draft on Back, where it sat until the owner came back to the chat.
    @MainActor func testE20_LeavingWithAQueuedMemoStillSendsIt() throws {
        try account.control("/__fixture/plan", ["plans": [["chunks": Array(repeating: "word ", count: 240), "chunkDelay": 0.05]]])
        let app = launch()
        openChat(app, "default")
        let field = app.textViews["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("A slow one please")
        let sendButton = app.buttons["composer.send"]
        let sent = prompts().count
        sendButton.tap()
        if !waitUntil(timeout: 3, { self.prompts().count > sent }) { sendButton.tap() }
        XCTAssertTrue(app.buttons["composer.stop"].waitForExistence(timeout: 8), "the reply runs")
        app.tables["chat.table"].tap()
        mic(app).press(forDuration: 2.2)
        let queued = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Voice Memo 0:02")).firstMatch
        XCTAssertTrue(queued.waitForExistence(timeout: 5), "the queue card lists the memo")
        back(app)
        XCTAssertTrue(app.cells["bot-row-default"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 45) { self.prompts().count == sent + 2 }, "the memo went out off screen once the reply ended")
        XCTAssertEqual((try voiceState()["uploads"] as? [Any])?.count, 1, "the memo was uploaded")
        openChat(app, "default", expectMic: false)
        XCTAssertFalse(app.staticTexts["memo.chip.title"].waitForExistence(timeout: 3), "no draft left behind")
        XCTAssertFalse(app.staticTexts["memo.notice.title"].exists, "no \"Memo Saved as a Draft\"")
        attachScreenshot(app, "E20-queued-memo-sent")
    }

    // MARK: E-21 Recording leaves the page behind the bar alone

    /// Owner 2026-11-01: while a memo recorded, a solid page-colour band filled the whole bottom of the chat, white over
    /// the chat background. The bar's surroundings must look the same before and during a take.
    @MainActor func testE21_RecordingKeepsThePageBehindTheBar() throws {
        let picture = FileManager.default.temporaryDirectory.appendingPathComponent("e21-background.png")
        let orange = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 120)).image { context in
            UIColor(red: 0.95, green: 0.45, blue: 0.1, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 120))
        }
        try XCTUnwrap(orange.pngData()).write(to: picture)
        // With live words, so the bar is the two-row one (the words above the recorder row) people see on a phone.
        let app = launch(["-HQDebugChatBackground", picture.path, "-HQDebugChatBackgroundDim", "0",
                          "-HQDebugLiveWords", "Checking the page behind the bar while I talk"])
        openChat(app, "default")
        let window = app.windows.firstMatch.frame
        let row = mic(app).frame
        // Beside the bar (left of its glass) and under it, above the home indicator's corner.
        let points = [CGPoint(x: 3, y: row.midY), CGPoint(x: 6, y: window.maxY - 4)]
        let idle = app.screenshot()
        mic(app).press(forDuration: 0.3)
        XCTAssertTrue(app.buttons["memo.stop"].waitForExistence(timeout: 5), "the locked row shows")
        XCTAssertTrue(app.descendants(matching: .any)["voice.words"].waitForExistence(timeout: 5), "the words row shows")
        Thread.sleep(forTimeInterval: 1.5)   // the words in and past the old band's 0.2 s fade
        let recording = app.screenshot()
        attachScreenshot(app, "E21-locked-over-background")
        for point in points {
            let before = Self.pixel(idle, at: point), during = Self.pixel(recording, at: point)
            XCTAssertLessThan(Self.distance(before, during), 0.08, "the page at \(point) stays as it was (\(before) → \(during))")
        }
        app.buttons["memo.delete"].tap()
        XCTAssertTrue(mic(app).waitForExistence(timeout: 4), "back to idle")
    }

    // MARK: E-22 Fixing the heard words in review

    /// [live words] Spec 3x-live-words §3.1.1: in review a tap on the words opens them for editing where they are; Send
    /// sends the fixed words as the memo's transcript, and the fix is kept (Settings › Voice › Word Fixes). The words as
    /// heard are tidied first (§2.1): no "Uh", TestFlight written as a name. Both looks.
    @MainActor func testE22_FixingTheWordsInReview() throws {
        for look in ["ios", "desktop"] {
            let app = launch(["-HQDebugLiveWords", "Uh, ask the test flight team about Kua",
                              "-HQDebugDesktopLook", look == "desktop" ? "YES" : "NO"])
            openChat(app, "default")
            let before = prompts().count
            mic(app).press(forDuration: 0.3)
            let stop = app.buttons["memo.stop"]
            XCTAssertTrue(stop.waitForExistence(timeout: 5), "the locked row shows")
            let words = app.descendants(matching: .any)["voice.words"]
            XCTAssertTrue(waitUntil(timeout: 10) { (words.value as? String ?? "").hasSuffix("about Kua") }, "the words show as heard")
            stop.tap()
            XCTAssertTrue(app.buttons["memo.review.play"].waitForExistence(timeout: 5), "Stop opens review")
            XCTAssertEqual(words.value as? String, "Ask the TestFlight team about Kua", "no Uh, TestFlight as a name")
            Thread.sleep(forTimeInterval: 0.6)
            attachScreenshot(app, "E22-\(look)-1-review")
            words.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
            let editor = app.textViews["voice.words.editor"]
            XCTAssertTrue(editor.waitForExistence(timeout: 4), "a tap opens the words for editing")
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4), "with the keyboard")
            Thread.sleep(forTimeInterval: 0.8)
            attachScreenshot(app, "E22-\(look)-2-editing")
            editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "CUA")
            Thread.sleep(forTimeInterval: 0.4)
            attachScreenshot(app, "E22-\(look)-3-fixed")
            editor.typeText("\n")   // Return: done
            XCTAssertTrue(waitUntil(timeout: 3) { !editor.exists }, "Return ends the editing")
            XCTAssertEqual(words.value as? String, "Ask the TestFlight team about CUA")
            Thread.sleep(forTimeInterval: 0.6)
            attachScreenshot(app, "E22-\(look)-4-ready-to-send")
            app.buttons["composer.send"].tap()
            XCTAssertTrue(waitUntil(timeout: 15) { self.prompts().count == before + 1 }, "Send sends one prompt")
            let text = prompts().last?["text"] as? String ?? ""
            XCTAssertTrue(text.contains("Voice memo transcript: Ask the TestFlight team about CUA"), text)
            // The fix is kept: Settings › Voice › Voice Conversation › Word Fixes lists it. (The first send asks about
            // notifications: "Know When a Bot Replies?")
            let ask = app.alerts.buttons["Not Now"]
            if ask.waitForExistence(timeout: 3) { ask.tap() }
            back(app)
            openVoiceConversation(app)
            let fixes = app.buttons["voice.settings.word-fixes"]
            for _ in 0..<6 where !(fixes.exists && fixes.isHittable) { app.swipeUp(velocity: .slow) }
            XCTAssertTrue(fixes.exists, "Voice Conversation has Word Fixes")
            attachScreenshot(app, "E22-\(look)-5-voice-settings")
            fixes.tap()
            let row = app.descendants(matching: .any)["voice.word-fixes.Kua"]
            XCTAssertTrue(row.waitForExistence(timeout: 5), "the fix learned from the memo")
            Thread.sleep(forTimeInterval: 0.6)
            attachScreenshot(app, "E22-\(look)-6-word-fixes")
            app.terminate()
        }
    }

    /// More › Settings › Voice › Voice Conversation.
    @MainActor private func openVoiceConversation(_ app: XCUIApplication) {
        let more = app.buttons["tab-more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        let row = app.cells["more-row-settings"]
        for _ in 0..<4 {
            more.tap()
            if row.waitForExistence(timeout: 2), row.isHittable { break }
        }
        row.tap()
        let voice = app.buttons["settings.config.voice"]
        let limit = app.windows.firstMatch.frame.height - 150
        for _ in 0..<10 where !(voice.exists && voice.isHittable && voice.frame.maxY < limit) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(voice.exists, "Settings has a Voice row")
        voice.tap()
        let conversation = app.buttons["config-page.voice.conversation"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 8), "the Voice section opens")
        conversation.tap()
        XCTAssertTrue(app.descendants(matching: .any)["voice.settings.live-words"].waitForExistence(timeout: 5))
    }

    // MARK: - Helpers

    /// The colour at a point (in points) of a screenshot, as RGB 0…1.
    private static func pixel(_ shot: XCUIScreenshot, at point: CGPoint) -> [CGFloat] {
        let image = shot.image
        guard let cg = image.cgImage else { return [0, 0, 0] }
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let x = point.x * image.scale, y = point.y * image.scale
        context.draw(cg, in: CGRect(x: -x, y: y - CGFloat(cg.height) + 1, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return bytes.prefix(3).map { CGFloat($0) / 255 }
    }

    private static func distance(_ a: [CGFloat], _ b: [CGFloat]) -> CGFloat {
        zip(a, b).map { abs($0 - $1) }.max() ?? 1
    }

    /// The distinct bar heights the live waveform shows (its DEBUG probe value "bars=<n>;distinct=<k>").
    private static func distinct(_ live: XCUIElement) -> Int {
        let value = live.value as? String ?? ""
        return Int(value.components(separatedBy: "distinct=").last ?? "") ?? 0
    }

    @MainActor private func launch(_ extra: [String] = [], reset: Bool = true, permission: String = "granted") -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-HQDebugMemoFixture", permission]
        if reset { arguments += ["-HQDebugResetAccounts", "YES", "-HQDebugResetVoice", "YES"] }
        app.launchArguments = arguments + extra
        // One sign-in per launch, from the fixture's invented credentials (DEBUG simulator builds only).
        app.launchEnvironment = ["HQN_SIGNIN_URL": account.url, "HQN_SIGNIN_USERNAME": account.username,
                                 "HQN_SIGNIN_PASSWORD": account.password]
        app.launch()
        XCTAssertTrue(app.cells["bot-row-default"].waitForExistence(timeout: 25), "the Bots list shows")
        return app
    }

    @MainActor private func openChat(_ app: XCUIApplication, _ profile: String, expectMic: Bool = true) {
        let row = app.cells["bot-row-\(profile)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 8), "the chat opens")
        if expectMic { XCTAssertTrue(mic(app).waitForExistence(timeout: 8), "the mic shows") }
        Thread.sleep(forTimeInterval: 0.8)
    }


    @MainActor private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        _ = app.cells["bot-row-default"].waitForExistence(timeout: 5)
    }

    @MainActor private func mic(_ app: XCUIApplication) -> XCUIElement { app.buttons["composer.mic"] }

    @MainActor private func center(_ element: XCUIElement) -> XCUICoordinate {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }

    @MainActor private func transcript(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.tables["chat.table"].descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor private func bubble(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.tables["chat.table"].cells.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor private func bubbles(_ app: XCUIApplication, containing text: String) -> [XCUIElement] {
        app.tables["chat.table"].cells.containing(NSPredicate(format: "label CONTAINS %@", text)).allElementsBoundByIndex
    }

    private func voiceState() throws -> [String: Any] { try account.control("/__fixture/voice-state") }

    /// The prompts the gateway admitted (strict keys passed, not refused by `submitRefuse`).
    private func prompts() -> [[String: Any]] {
        ((try? voiceState())?["prompts"] as? [[String: Any]] ?? []).filter { ($0["refused"] as? Bool) != true }
    }

    private func refusedPrompts() -> Int {
        ((try? voiceState())?["prompts"] as? [[String: Any]] ?? []).filter { ($0["refused"] as? Bool) == true }.count
    }

    @MainActor private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor @discardableResult
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        return condition()
    }
}
