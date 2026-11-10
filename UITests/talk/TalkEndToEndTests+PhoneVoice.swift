// E30 Reading aloud always works (docs/spec/3x-talk.md §7.7): the stand-in gateway's voice fails as Edge did on the
// owner's phone (the stream says `fallback`, the clip route answers 500 with Hermes' words). The reply is read by the
// iPhone's own voice (the real AVSpeechSynthesizer writing into the stand-in speaker), one quiet notice says so with
// Fix…, Fix… opens the bot's Text to Speech provider, and the next reading goes straight to the iPhone's voice.

import XCTest

extension TalkEndToEndTests {
    static let edgeRefusal = "TTS chunk 1 failed (edge): TTS generation failed (edge): 403, message='Invalid response status', "
        + "url='wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=6A5AA1D4EAFF4E9FB37E23D68491D6F4&ConnectionId=a1b2'"

    @MainActor func testE30_ReadAloudFallsBackToTheIPhoneVoice() throws {
        try account.control("/__fixture/voice", ["streamMode": "fallback", "speakFail": ["status": 500, "detail": Self.edgeRefusal]])
        let app = launch()
        openChat(app, "ivy")
        let read = app.buttons["chat.read-reply"]
        XCTAssertTrue(read.waitForExistence(timeout: 8), "the newest reply has its action row")
        read.tap()

        // One quiet line under the title, with Fix…: no alert, no provider words.
        let notice = app.descendants(matching: .any)["chat.notice"]
        XCTAssertTrue(waitUntil(timeout: 15) { notice.exists && notice.label.hasPrefix("Using the iPhone’s voice") }, "the notice shows (\(notice.label))")
        XCTAssertEqual(notice.label, "Using the iPhone’s voice. Ivy’s voice on the computer running Hermes isn’t working.")
        XCTAssertTrue(app.buttons["chat.notice.action"].exists, "with Fix…")
        XCTAssertFalse(app.alerts.firstMatch.exists, "not an error alert")
        shot(app, "E30-notice")

        // The iPhone's voice read it; the computer's failure is in the log, scrubbed.
        XCTAssertTrue(waitUntil(timeout: 15) {
            (self.probe(app)["events"] as? [String] ?? []).contains { $0.contains("reading with the iPhone voice") }
        }, "the iPhone's voice reads (\(probe(app)["events"] ?? []))")
        let events = probe(app)["events"] as? [String] ?? []
        XCTAssertTrue(events.contains { $0.contains("computer voice failed: TTS chunk 1 failed (edge)") }, "\(events)")
        XCTAssertFalse(events.joined().contains("bing.com") || events.joined().contains("TrustedClientToken=6A"), "scrubbed: \(events)")
        XCTAssertTrue(waitUntil(timeout: 30) { read.label == "Read Aloud" }, "and finishes (\(read.label))")
        XCTAssertFalse(app.alerts.firstMatch.exists, "without an alert")
        let speaks = ledger("speaks").count, streams = ledger("streams").count
        XCTAssertGreaterThanOrEqual(speaks, 1, "the computer was asked first")
        XCTAssertEqual(streams, 1)

        // Read again: straight to the iPhone's voice, no failing round trip, no second notice. The first notice stays
        // 8 s and a short reading can end sooner, so it goes first (else "told once" would see the first one).
        let shown = { notice.exists && notice.label.hasPrefix("Using the iPhone’s voice") && notice.isHittable }
        XCTAssertTrue(waitUntil(timeout: 12) { !shown() }, "the first notice goes by itself")
        read.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { read.label == "Stop reading" }, "it reads at once (\(read.label))")
        XCTAssertTrue(waitUntil(timeout: 30) { read.label == "Read Aloud" }, "and finishes")
        XCTAssertEqual(ledger("speaks").count, speaks, "the computer's voice is skipped for now")
        XCTAssertEqual(ledger("streams").count, streams)
        XCTAssertFalse(shown(), "told once")

        // Fix… on a fresh notice (a relaunch forgets): the bot's own Text to Speech page, provider on top.
        let again = launch(reset: false)
        openChat(again, "ivy")
        again.buttons["chat.read-reply"].tap()
        let fix = again.buttons["chat.notice.action"]
        XCTAssertTrue(fix.waitForExistence(timeout: 15), "the notice comes back after a relaunch")
        fix.tap()
        let provider = again.descendants(matching: .any)["config-editor.tts.provider"]
        XCTAssertTrue(provider.waitForExistence(timeout: 10) || again.navigationBars["Text to Speech Provider"].waitForExistence(timeout: 2),
                      "Fix… opens the provider picker")
        Thread.sleep(forTimeInterval: 1)
        shot(again, "E30-fix-provider")
        again.navigationBars.buttons.element(boundBy: 0).tap()
        let page = again.descendants(matching: .any)["voice.settings.reply-voice.iphone"]
        XCTAssertTrue(page.waitForExistence(timeout: 6), "Back is the Text to Speech page with the Voice choice")
        XCTAssertTrue(again.descendants(matching: .any)["voice.settings.bot-scope"].exists, "it says whose settings these are")
        shot(again, "E30-text-to-speech-page")
    }
}
