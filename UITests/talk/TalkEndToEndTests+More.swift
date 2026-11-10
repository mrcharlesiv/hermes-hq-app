// Live voice end to end, second half (docs/spec/3x-talk.md §14.2): dictation (E14), Read Aloud (E15), Read Replies
// Aloud (E16), Settings › Voice (E17), Voice Diagnostics (E18), failures (E19), a question during a conversation
// (E20), keep awake (E21), the audio preview (E22), accessibility sizes (E23), relaunch (E24), the hidden engine and
// wake word (E25), and the entries again in the dark appearance (E26).

import XCTest

extension TalkEndToEndTests {
    // MARK: E14 Dictation

    /// Starts "Dictate with Hermes" from the voice options and waits for the row.
    @MainActor private func startDictation(_ app: XCUIApplication) {
        openOptions(app)
        app.buttons["voice.options.dictate"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["dictation.status"].waitForExistence(timeout: 8), "the dictation row shows")
    }

    @MainActor private func dictationStatus(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)["dictation.status"].label
    }

    @MainActor func testE14a_DictationStopTypesTheWords() throws {
        try account.control("/__fixture/voice", ["transcript": "Words typed by voice", "transcribeDelay": 1.5])
        let app = launch()
        openChat(app, "ivy")
        startDictation(app)
        XCTAssertTrue(waitUntil(timeout: 5) { self.dictationStatus(app).hasPrefix("Dictating, 0:0") }, dictationStatus(app))
        let stop = app.buttons["composer.stop-dictation"]
        XCTAssertTrue(stop.exists, "the circle is Stop Dictation")
        XCTAssertEqual(stop.label, "Stop Dictation")
        XCTAssertEqual(probe(app)["dictation"] as? String, "recording")
        XCTAssertEqual(probe(app)["owner"] as? String, "dictation")
        XCTAssertEqual(probe(app)["keepAwake"] as? Int, 1, "dictation keeps the screen awake")
        Thread.sleep(forTimeInterval: 2)
        shot(app, "E14a-dictating")
        stop.tap()
        XCTAssertTrue(waitUntil(timeout: 4) { self.dictationStatus(app) == "Transcribing" }, "Stop → Transcribing (\(dictationStatus(app)))")
        shot(app, "E14a-transcribing")
        let field = app.textViews["composer.text"]
        XCTAssertTrue(waitUntil(timeout: 12) { (field.value as? String) == "Words typed by voice" }, "the words are in the field (\(field.value ?? "nil"))")
        XCTAssertTrue(waitUntil(timeout: 5) { app.keyboards.count > 0 }, "with the keyboard up")
        XCTAssertFalse(app.descendants(matching: .any)["dictation.status"].exists, "the row left")
        XCTAssertTrue(app.buttons["composer.send"].exists, "Send is the circle now")
        let state = try voiceState()
        let transcribes = state["transcribes"] as? [[String: Any]] ?? []
        XCTAssertEqual(transcribes.count, 1, "one transcription")
        XCTAssertEqual(transcribes.first?["mime"] as? String, "audio/x-m4a")
        XCTAssertEqual(prompts().count, 0, "nothing was sent")
        XCTAssertEqual(probe(app)["keepAwake"] as? Int, 0)
        XCTAssertEqual(probe(app)["owner"] as? String, "")
        shot(app, "E14a-typed")
    }

    @MainActor func testE14b_DictationCancelLeavesTheFieldAlone() throws {
        let app = launch()
        openChat(app, "ivy")
        startDictation(app)
        Thread.sleep(forTimeInterval: 1.5)
        app.buttons["dictation.cancel"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !app.descendants(matching: .any)["dictation.status"].exists }, "× closes the row")
        XCTAssertTrue(talk(app).waitForExistence(timeout: 5), "the field is as it was: empty, with Talk")
        let value = app.textViews["composer.text"].value as? String ?? ""
        XCTAssertTrue(value.isEmpty || value == app.textViews["composer.text"].placeholderValue, "nothing was typed (\(value))")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual((try voiceState()["transcribes"] as? [Any])?.count, 0, "nothing was transcribed")
        XCTAssertEqual(probe(app)["dictation"] as? String, "idle")
        XCTAssertEqual(probe(app)["keepAwake"] as? Int, 0)
    }

    @MainActor func testE14c_DictationDoneDoesWhatStopDoes() throws {
        try account.control("/__fixture/voice", ["transcript": "Done sends it for typing"])
        let app = launch()
        openChat(app, "ivy")
        startDictation(app)
        Thread.sleep(forTimeInterval: 1.5)
        let done = app.buttons["dictation.done"]
        XCTAssertTrue(done.exists)
        XCTAssertEqual(done.label, "Done")
        done.tap()
        let field = app.textViews["composer.text"]
        XCTAssertTrue(waitUntil(timeout: 12) { (field.value as? String) == "Done sends it for typing" }, "\(field.value ?? "nil")")
        XCTAssertEqual((try voiceState()["transcribes"] as? [Any])?.count, 1)
        XCTAssertEqual(prompts().count, 0)
    }

    @MainActor func testE14d_DictationStopsAtItsLimit() throws {
        try account.control("/__fixture/voice", ["voiceConfig": ["voice": ["max_recording_seconds": 2]], "transcript": "Two seconds of words"])
        let app = launch()
        openChat(app, "ivy")
        startDictation(app)
        // The limit is read from the app's own events: the probe's `dictationLimit` is the running take's, and on a
        // slow machine the two seconds can be over before the probe is read.
        XCTAssertTrue(waitUntil(timeout: 5) { (self.probe(app)["events"] as? [String] ?? []).contains("dictation: recording (limit 2 s)") },
                      "the gateway's limit is used (\(probe(app)["events"] ?? "nil"))")
        let field = app.textViews["composer.text"]
        // No tap: it stops by itself at 2 s and transcribes.
        XCTAssertTrue(waitUntil(timeout: 14) { (field.value as? String) == "Two seconds of words" }, "it stopped at the limit (\(field.value ?? "nil"))")
        let seconds = ((try voiceState()["transcribes"] as? [[String: Any]])?.first?["seconds"] as? Double) ?? 0
        XCTAssertEqual(seconds, 2, accuracy: 0.6, "about two seconds were recorded")
    }

    @MainActor func testE14e_DictationHeardNothing() throws {
        try account.control("/__fixture/voice", ["transcribeEmpty": true])
        let app = launch()
        openChat(app, "ivy")
        startDictation(app)
        Thread.sleep(forTimeInterval: 1.2)
        app.buttons["composer.stop-dictation"].tap()
        let title = app.staticTexts["memo.notice.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "a card above the field says so")
        XCTAssertEqual(title.label, "No Speech Detected")
        XCTAssertEqual(noticeMessage(app), "Try recording again.")
        XCTAssertEqual(app.buttons["memo.notice.action"].label, "Try Again", "recording again is one tap")
        XCTAssertFalse(app.buttons["memo.notice.copy"].exists, "nothing behind the words to copy")
        XCTAssertTrue(talk(app).exists, "the field is still empty")
        shot(app, "E14e-no-speech")
    }

    @MainActor func testE14f_DictationFailureSaysWhy() throws {
        try account.control("/__fixture/voice", ["transcribeFail": ["status": 500, "detail": "The speech model crashed while loading."]])
        let app = launch()
        openChat(app, "ivy")
        startDictation(app)
        Thread.sleep(forTimeInterval: 1.2)
        app.buttons["composer.stop-dictation"].tap()
        let title = app.staticTexts["memo.notice.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.label, "Voice Transcription Failed")
        XCTAssertEqual(noticeMessage(app), "The speech model crashed while loading.", "the gateway's own reason")
        XCTAssertEqual(app.buttons["memo.notice.action"].label, "Try Again")
        shot(app, "E14f-failed")
        // Copy has the whole of it, status included.
        app.buttons["memo.notice.copy"].tap()
        XCTAssertTrue(waitUntil(timeout: 3) { (self.probe(app)["copied"] as? String ?? "").contains("HTTP 500") }, "\(probe(app)["copied"] ?? "nil")")
        XCTAssertTrue((probe(app)["copied"] as? String ?? "").contains("The speech model crashed while loading."))
    }

    /// Owner 2026-11-01: "I added a picture to the text box … did the voice transcription … it did not show my words,
    /// but then when I clicked send, it only sent the picture." With a picture in the tray the mic is Dictate. While it
    /// runs the circle is Stop Dictation (it was Send), the words show as they are said, Stop types them, and Send takes
    /// both (docs/spec/3x-live-words.md §3.3).
    @MainActor func testE14g_DictationBesideAPictureSendsBoth() throws {
        let picture = FileManager.default.temporaryDirectory.appendingPathComponent("e14g-picture.png")
        let blue = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { context in
            UIColor(red: 0.2, green: 0.55, blue: 0.85, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
        try XCTUnwrap(blue.pngData()).write(to: picture)
        let words = "Make this picture brighter please"
        let app = launch(["-HQDebugAttach", picture.path, "-HQDebugLiveWords", words], opens: "ivy")
        let dictate = app.buttons["composer.dictate"]
        XCTAssertTrue(dictate.waitForExistence(timeout: 15), "with a picture in the tray the mic is Dictate")
        XCTAssertTrue(app.buttons["composer.send"].waitForExistence(timeout: 10), "and the circle is Send")
        dictate.tap()
        XCTAssertTrue(app.descendants(matching: .any)["dictation.status"].waitForExistence(timeout: 8), "the dictation row shows")
        let stop = app.buttons["composer.stop-dictation"]
        XCTAssertTrue(stop.waitForExistence(timeout: 3), "while it records the circle is Stop Dictation")
        XCTAssertFalse(app.buttons["composer.send"].exists, "not Send: the words aren't in the field yet")
        let heard = app.descendants(matching: .any)["voice.words"]
        XCTAssertTrue(waitUntil(timeout: 8) { (heard.value as? String) == words }, "the words show as they're said (\(heard.value ?? "nil"))")
        shot(app, "E14g-dictating-beside-a-picture")
        stop.tap()
        let field = app.textViews["composer.text"]
        XCTAssertTrue(waitUntil(timeout: 8) { (field.value as? String) == words }, "the words are typed (\(field.value ?? "nil"))")
        XCTAssertEqual(ledger("transcribes").count, 0, "heard on the phone: no speech to text on the gateway")
        XCTAssertEqual(prompts().count, 0, "nothing sent yet")
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 3), "Send is back")
        send.tap()
        XCTAssertTrue(waitUntil(timeout: 20) { self.prompts().count == 1 }, "one message")
        let text = prompts().first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains(words), "the words went (\(text))")
        XCTAssertEqual(ledger("imageAttaches").filter { ($0["result"] as? String) == "ok" }.count, 1, "with the picture")
        shot(app, "E14g-sent")
    }

    @MainActor private func noticeMessage(_ app: XCUIApplication) -> String {
        let message = app.descendants(matching: .any)["memo.notice.message"]
        return (message.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? message.label
    }

    // MARK: E15 Read Aloud

    @MainActor func testE15a_ReadAloudFromTheActionRow() throws {
        try account.control("/__fixture/voice", ["streamStartDelay": 1.5])
        let app = launch()
        openChat(app, "ivy")
        let read = app.buttons["chat.read-reply"]
        XCTAssertTrue(read.waitForExistence(timeout: 8), "the newest reply has its action row")
        let ids = ["chat.copy-reply", "chat.read-reply", "chat.regenerate-reply", "chat.reply-more"]
        let frames = ids.map { app.buttons[$0].frame }
        XCTAssertEqual(frames.map(\.minX), frames.map(\.minX).sorted(), "Copy, Read Aloud, Regenerate, More in order")
        for frame in frames { XCTAssertGreaterThanOrEqual(min(frame.width, frame.height), 44, "each is 44 pt") }
        XCTAssertEqual(read.label, "Read Aloud")
        shot(app, "E15a-action-row")
        read.tap()
        var seen: [String] = []
        _ = waitUntil(timeout: 20) {
            let now = read.label
            if seen.last != now { seen.append(now) }
            return seen.count >= 3 && now == "Read Aloud"
        }
        XCTAssertTrue(inOrder(seen, ["Preparing audio", "Stop reading", "Read Aloud"]), "idle → Preparing audio → Stop reading → idle (\(seen))")
        let streams = ledger("streams")
        XCTAssertEqual(streams.count, 1, "one speech stream")
        XCTAssertEqual(streams.first?["profile"] as? String, "ivy")
        XCTAssertEqual(streams.first?["done"] as? Bool, true)
        let spoken = (streams.first?["texts"] as? [String] ?? []).joined()
        XCTAssertTrue(inChat(app, spoken.trimmingCharacters(in: .whitespacesAndNewlines)).exists, "what was spoken is the reply's text (\(spoken))")
        XCTAssertFalse(spoken.isEmpty)
        XCTAssertEqual(prompts().count, 0, "reading sends nothing")
    }

    @MainActor func testE15b_ReadAloudFromTheHoldMenu() throws {
        let long = Array(repeating: "A long reply to read out loud, sentence after sentence.", count: 5).joined(separator: " ")
        try account.control("/__fixture/plan", ["plans": [["replyText": long]]])
        let app = launch()
        openChat(app, "ivy")
        send(app, "Tell me a long story")
        app.tables["chat.table"].tap()                          // the keyboard goes
        let reply = inChat(app, "A long reply to read out loud")
        XCTAssertTrue(reply.waitForExistence(timeout: 15), "the reply arrives")
        XCTAssertTrue(app.buttons["chat.read-reply"].waitForExistence(timeout: 10), "and finishes")
        let tile = holdMenu(app, reply, "Read Aloud")
        XCTAssertEqual(tile.identifier, "message.readAloud")
        let copy = menuItem(app, "Copy"), share = menuItem(app, "Share")
        XCTAssertTrue(copy.exists && share.exists, "Copy, Read Aloud and Share are the tiles")
        XCTAssertEqual(copy.frame.midY, tile.frame.midY, accuracy: 2, "in one row")
        XCTAssertLessThan(copy.frame.midX, tile.frame.midX)
        XCTAssertLessThan(tile.frame.midX, share.frame.midX)
        shot(app, "E15b-hold-menu")
        tile.tap()
        let label = app.staticTexts["read.strip.label"]
        XCTAssertTrue(waitUntil(timeout: 10) { label.exists && label.label == "Reading aloud" }, "the strip says Reading aloud")
        XCTAssertEqual(ledger("streams").count, 1)
        shot(app, "E15b-reading")
        // Held again while it reads: Stop Reading.
        let stop = app.buttons["message.readAloud"]            // the same tile; its two words are on two lines
        for _ in 0..<3 {
            reply.press(forDuration: 1.0)
            if stop.waitForExistence(timeout: 4) { break }
        }
        XCTAssertEqual(stop.label.replacingOccurrences(of: "\n", with: " "), "Stop Reading", "the tile is Stop Reading now")
        shot(app, "E15b-hold-menu-reading")
        stop.tap()
        XCTAssertTrue(waitUntil(timeout: 6) { !label.exists }, "the strip leaves")
        XCTAssertTrue(waitUntil(timeout: 6) { self.ledger("streams").first?["stopped"] as? Bool == true }, "the stream was told to stop")
        // Your own bubble has no Read Aloud.
        let mine = inChat(app, "Tell me a long story")
        mine.press(forDuration: 1.0)
        XCTAssertTrue(menuItem(app, "Copy").waitForExistence(timeout: 4), "your bubble's menu opens")
        XCTAssertFalse(menuItem(app, "Read Aloud").exists, "with no Read Aloud")
        XCTAssertFalse(menuItem(app, "Stop Reading").exists)
        dismissMenu(app)
    }

    @MainActor func testE15c_TheReadingStripAndStop() throws {
        let long = Array(repeating: "Another long reply so the strip stays a while.", count: 6).joined(separator: " ")
        try account.control("/__fixture/voice", ["streamStartDelay": 2.0])
        try account.control("/__fixture/plan", ["plans": [["replyText": long]]])
        let app = launch()
        openChat(app, "ivy")
        send(app, "Read this one")
        app.tables["chat.table"].tap()
        let read = app.buttons["chat.read-reply"]
        XCTAssertTrue(waitUntil(timeout: 20) { read.exists && self.inChat(app, "Another long reply").exists }, "the reply is done")
        read.tap()
        let label = app.staticTexts["read.strip.label"]
        XCTAssertTrue(waitUntil(timeout: 5) { label.exists && label.label == "Preparing audio" }, "Preparing audio first")
        shot(app, "E15c-preparing")
        XCTAssertTrue(waitUntil(timeout: 10) { label.label == "Reading aloud" }, "then Reading aloud (\(label.label))")
        XCTAssertEqual(probe(app)["reading"] as? String, "speaking")
        XCTAssertEqual(probe(app)["owner"] as? String, "speech")
        XCTAssertEqual(probe(app)["keepAwake"] as? Int, 0, "reading aloud does not keep the screen awake by itself")
        shot(app, "E15c-reading-aloud")
        let stop = app.buttons["read.strip.stop"]
        XCTAssertEqual(stop.label, "Stop reading")
        stop.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !label.exists }, "Stop closes the strip")
        XCTAssertEqual(read.label, "Read Aloud")
        XCTAssertTrue(waitUntil(timeout: 6) { self.ledger("streams").first?["stopped"] as? Bool == true })
        XCTAssertEqual(probe(app)["reading"] as? String, "idle")
        XCTAssertEqual(probe(app)["owner"] as? String, "")
    }

    @MainActor func testE15d_ReadAloudFailureSaysWhy() throws {
        try account.control("/__fixture/voice", ["streamMode": "fallback", "speakFail": ["status": 503, "detail": "The voice provider is down for maintenance."]])
        // §7.7: the iPhone's voice takes over a failing computer voice (E30); only when it fails too does the reading
        // end with the computer's reason.
        let app = launch(["-HQDebugPhoneVoice", "fails"])
        openChat(app, "ivy")
        let read = app.buttons["chat.read-reply"]
        XCTAssertTrue(read.waitForExistence(timeout: 8))
        read.tap()
        let alert = app.alerts["Couldn’t Read Aloud"]
        XCTAssertTrue(alert.waitForExistence(timeout: 12), "the failure is an alert")
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "The voice provider is down for maintenance.")).firstMatch.exists,
                      "with the gateway's reason")
        shot(app, "E15d-read-aloud-failed")
        alert.buttons.matching(NSPredicate(format: "label == 'OK' OR label == 'Done' OR label == 'Close'")).firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { read.label == "Read Aloud" }, "the button is idle again")
        XCTAssertEqual(ledger("speaks").count, 1, "the clip was asked for once")
    }

    // MARK: E16 Read Replies Aloud

    @MainActor private func openMore(_ app: XCUIApplication) {
        let more = app.buttons["chat.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 6))
        let item = app.buttons["chat.menu.read-replies"]
        for _ in 0..<3 {
            more.tap()
            if item.waitForExistence(timeout: 4) { break }
        }
        XCTAssertTrue(item.exists, "⋯ has Read Replies Aloud")
    }

    @MainActor func testE16a_TheSwitchInThreePlaces() throws {
        var app = launch()
        openChat(app, "ivy")
        XCTAssertEqual(probe(app)["readReplies"] as? Bool, false, "off after a reset")
        openMore(app)
        let item = app.buttons["chat.menu.read-replies"]
        XCTAssertTrue(item.label.hasPrefix("Read Replies Aloud"), item.label)
        XCTAssertFalse(item.isSelected, "no checkmark")
        let rename = app.buttons["chat.more.rename"]
        // After Rename… (a bot's main chat on the stand-in gateway has no Rename… row: the item sits in its place,
        // after Mark as Unread and before More; the screenshot shows it).
        if rename.exists { XCTAssertGreaterThan(item.frame.midY, rename.frame.midY, "after Rename…") }
        let unread = app.buttons["chat.more.unread"]
        if unread.exists { XCTAssertGreaterThan(item.frame.midY, unread.frame.midY, "after Mark as Unread") }
        shot(app, "E16a-more-menu-off")
        item.tap()
        XCTAssertTrue(waitUntil(timeout: 4) { self.probe(app)["readReplies"] as? Bool == true }, "tapping turns it on")
        XCTAssertTrue(item.exists, "the menu stays open")
        XCTAssertTrue(waitUntil(timeout: 3) { item.isSelected }, "with its checkmark")
        shot(app, "E16a-more-menu-on")
        dismissMenu(app)
        // The voice options show the same switch.
        openOptions(app)
        XCTAssertTrue(app.buttons["voice.options.read-replies"].isSelected, "checked in the voice options too")
        // And Settings › Voice › Text to Speech.
        app.buttons["voice.options.settings"].tap()
        let page = app.buttons["config-page.voice.speech"]
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        page.tap()
        let toggle = app.switches["voice.settings.read-replies"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        XCTAssertEqual(toggle.value as? String, "1", "on in Settings")
        shot(app, "E16a-settings-on")

        // A relaunch keeps it.
        app = launch(reset: false, introSeen: nil)
        XCTAssertEqual(probe(app)["readReplies"] as? Bool, true, "still on after a relaunch")
    }

    @MainActor func testE16b_ReadsTheReplyThatCompletesOnScreen() throws {
        let long = Array(repeating: "This reply is read out loud as soon as it is finished.", count: 5).joined(separator: " ")
        try account.control("/__fixture/plan", ["plans": [["replyText": long]]])
        let app = launch(["-HQDebugReadRepliesAloud", "YES"])
        openChat(app, "ivy")
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertEqual(ledger("streams").count, 0, "the reply that was already there is not read")
        send(app, "Say something long")
        app.tables["chat.table"].tap()
        XCTAssertTrue(waitUntil(timeout: 25) { self.ledger("streams").count == 1 }, "the new reply is read")
        let label = app.staticTexts["read.strip.label"]
        XCTAssertTrue(waitUntil(timeout: 8) { label.exists && label.label == "Reading aloud" }, "the strip shows")
        XCTAssertEqual((ledger("streams").first?["texts"] as? [String] ?? []).joined().trimmingCharacters(in: .whitespaces), long)
        shot(app, "E16b-reading-the-new-reply")
        // Leaving the chat stops the reading.
        back(app)
        XCTAssertTrue(waitUntil(timeout: 6) { self.ledger("streams").first?["stopped"] as? Bool == true }, "leaving the chat stops it")
        XCTAssertEqual(probe(app)["reading"] as? String, "idle")
        XCTAssertFalse(app.buttons["talk.pill"].exists, "reading aloud has no pill")
    }

    @MainActor func testE16c_NeverReadsAReplyOfAChatThatIsNotOnScreen() throws {
        try account.control("/__fixture/plan", ["plans": [["replyDelay": 4.0, "replyText": "This one finishes while the list is on screen."]]])
        let app = launch(["-HQDebugReadRepliesAloud", "YES"])
        openChat(app, "ivy")
        send(app, "Answer while I am away")
        back(app)
        Thread.sleep(forTimeInterval: 9)                        // the reply completes off screen
        XCTAssertEqual(ledger("streams").count, 0, "nothing is read off screen")
        XCTAssertEqual(ledger("speaks").count, 0)
        openChat(app, "ivy")
        XCTAssertTrue(inChat(app, "This one finishes while the list is on screen.").waitForExistence(timeout: 10), "the reply is there")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(ledger("streams").count, 0, "and it is not read when its chat opens either")
        XCTAssertFalse(app.staticTexts["read.strip.label"].exists)
    }

    // MARK: E17 Settings › Voice

    /// Settings from the More tab, then its Voice row.
    @MainActor private func openVoiceSettings(_ app: XCUIApplication) {
        let more = app.tabBars.buttons["More"]
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
        shot(app, "E17-settings-root-voice-row")
        voice.tap()
        XCTAssertTrue(app.buttons["config-page.voice.conversation"].waitForExistence(timeout: 8), "the Voice section opens")
    }

    @MainActor private func settingsBack(_ app: XCUIApplication) {
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        Thread.sleep(forTimeInterval: 0.6)
    }

    @MainActor func testE17a_VoiceSettingsPages() throws {
        let app = launch()
        openVoiceSettings(app)
        for (id, title) in [("conversation", "Voice Conversation"), ("transcription", "Speech to Text"), ("speech", "Text to Speech")] {
            let row = app.buttons["config-page.voice.\(id)"]
            XCTAssertTrue(row.exists, id)
            XCTAssertTrue(row.label.contains(title), row.label)
        }
        shot(app, "E17a-voice-section")

        // Speech to Text.
        app.buttons["config-page.voice.transcription"].tap()
        let enabled = app.switches["config-field.stt.enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 10), "Speech to Text's switch")
        XCTAssertEqual(enabled.value as? String, "1")
        let provider = app.buttons["config-field.stt.provider"]
        XCTAssertTrue(provider.label.contains("Speech to Text Provider") && provider.label.contains("Local"), provider.label)
        XCTAssertTrue(app.buttons["config-field.stt.local.model"].label.contains("Local Transcription Model"))
        XCTAssertTrue(app.buttons["config-field.stt.local.language"].exists)
        XCTAssertFalse(app.buttons["config-field.stt.openai.model"].exists, "only the chosen provider's fields show")
        XCTAssertTrue(app.switches["config-field.stt.echo_transcripts"].exists)
        let length = app.buttons["config-field.voice.max_recording_seconds"]
        XCTAssertTrue(length.label.contains("Max Dictation Length") && length.label.contains("120"), length.label)
        shot(app, "E17a-speech-to-text")
        // Max Dictation Length refuses 0 and 601.
        length.tap()
        let field = app.textFields["config-editor.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        for bad in ["0", "601"] {
            field.clearAndType(bad)
            app.buttons["Done"].firstMatch.tap()                 // the number pad's Done commits what was typed
            XCTAssertTrue(labelled(app, "Type a whole number from 1 to 600.").waitForExistence(timeout: 3), "\(bad) is refused")
            field.tap()
        }
        shot(app, "E17a-dictation-length-refused")
        settingsBack(app)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(length.label.contains("120"), "the saved value is unchanged (\(length.label))")
        XCTAssertFalse(configPuts().contains { ($0["voice"] as? [String: Any])?["max_recording_seconds"] != nil }, "nothing was saved (\(configPuts()))")
        // A good value saves.
        length.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.clearAndType("300")
        settingsBack(app)
        XCTAssertTrue(waitUntil(timeout: 8) { self.configPuts().contains { (($0["voice"] as? [String: Any])?["max_recording_seconds"] as? Int) == 300 } },
                      "300 was saved (\(configPuts()))")
        // A refused save shows the page's banner.
        try account.control("/__fixture/voice", ["configPutFail": ["status": 500, "detail": "Synthetic save failure"]])
        let echo = app.switches["config-field.stt.echo_transcripts"]
        echo.switches.firstMatch.exists ? echo.switches.firstMatch.tap() : echo.tap()     // the row's own switch
        let banner = app.descendants(matching: .any)["settings.save-failure"]
        XCTAssertTrue(banner.waitForExistence(timeout: 8), "a failed save says so on the page")
        shot(app, "E17a-save-failed")
        try account.control("/__fixture/voice", ["configPutFail": NSNull()])
        settingsBack(app)

        // Text to Speech: choosing ElevenLabs swaps in its voice and model.
        app.buttons["config-page.voice.speech"].tap()
        let tts = app.buttons["config-field.tts.provider"]
        XCTAssertTrue(tts.waitForExistence(timeout: 10))
        XCTAssertTrue(tts.label.contains("Microsoft Edge"), tts.label)
        XCTAssertTrue(app.buttons["config-field.tts.edge.voice"].exists)
        XCTAssertFalse(app.buttons["config-field.tts.elevenlabs.voice_id"].exists)
        XCTAssertTrue(app.switches["voice.settings.read-replies"].exists, "Read Replies Aloud is on this page")
        XCTAssertTrue(app.switches["config-field.voice.auto_tts"].exists, "Voice Replies on Messaging Apps")
        tts.tap()
        let eleven = app.buttons["config-option.elevenlabs"]
        XCTAssertTrue(eleven.waitForExistence(timeout: 5))
        XCTAssertTrue(eleven.label.contains("ElevenLabs"))
        XCTAssertTrue(app.buttons["config-option.openai"].label.contains("OpenAI"))
        shot(app, "E17a-tts-providers")
        eleven.tap()
        let voiceRow = app.buttons["config-field.tts.elevenlabs.voice_id"]
        if !voiceRow.waitForExistence(timeout: 3) { settingsBack(app) }
        XCTAssertTrue(voiceRow.waitForExistence(timeout: 8), "ElevenLabs Voice is on the page")
        XCTAssertTrue(app.buttons["config-field.tts.elevenlabs.model_id"].exists, "and ElevenLabs Model")
        XCTAssertFalse(app.buttons["config-field.tts.edge.voice"].exists, "Edge's voice left")
        XCTAssertTrue(waitUntil(timeout: 8) { self.configPuts().contains { (($0["tts"] as? [String: Any])?["provider"] as? String) == "elevenlabs" } },
                      "the provider was saved (\(configPuts()))")
        shot(app, "E17a-tts-elevenlabs")
        voiceRow.tap()
        XCTAssertTrue(app.buttons["config-option.21m00Tcm4TlvDq8ikWAM"].waitForExistence(timeout: 8) || labelled(app, "Rachel", contains: true).waitForExistence(timeout: 2),
                      "the gateway's voices are listed")
        XCTAssertTrue(labelled(app, "Adam", contains: true).exists)
        shot(app, "E17a-elevenlabs-voices")
        XCTAssertEqual((try voiceState()["voiceLists"] as? Int), 1, "the voices were asked for once")
    }

    func configPuts() -> [[String: Any]] {
        ((try? voiceState())?["configPuts"] as? [[String: Any]] ?? []).map { ($0["config"] as? [String: Any]) ?? $0 }
    }

    @MainActor func testE17b_SendMemoOnRelease() throws {
        var app = launch()
        openVoiceSettings(app)
        app.buttons["config-page.voice.conversation"].tap()
        let toggle = app.switches["voice.settings.send-on-release"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        XCTAssertEqual(toggle.value as? String, "1", "on after a reset")
        let note = app.staticTexts["voice.settings.memo-note"]
        XCTAssertTrue(note.label.contains("let go to send"), note.label)
        shot(app, "E17b-conversation-page")
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        XCTAssertTrue(waitUntil(timeout: 4) { toggle.value as? String == "0" }, "the switch turns off")
        XCTAssertTrue(waitUntil(timeout: 4) { note.label.contains("play it back before you send") }, "the note follows (\(note.label))")
        shot(app, "E17b-send-on-release-off")

        // A relaunch keeps the choice, and a held memo now stops into review.
        app = launch(reset: false, introSeen: nil)
        openChat(app, "ivy")
        let before = prompts().count
        app.buttons["composer.mic"].press(forDuration: 2.0)
        XCTAssertTrue(app.buttons["memo.review.play"].waitForExistence(timeout: 6), "letting go stops into review")
        XCTAssertEqual(prompts().count, before, "nothing was sent")
        shot(app, "E17b-held-memo-in-review")
        app.buttons["memo.delete"].tap()
        if app.alerts.firstMatch.waitForExistence(timeout: 1.5) { app.alerts.firstMatch.buttons["Delete"].tap() }
        // On again: a held memo sends on release.
        XCTAssertTrue(talk(app).waitForExistence(timeout: 6))
        openOptions(app)
        app.buttons["voice.options.settings"].tap()
        XCTAssertTrue(app.buttons["config-page.voice.conversation"].waitForExistence(timeout: 10))
        app.buttons["config-page.voice.conversation"].tap()
        let again = app.switches["voice.settings.send-on-release"]
        XCTAssertTrue(again.waitForExistence(timeout: 8))
        XCTAssertEqual(again.value as? String, "0", "still off after the relaunch")
        again.switches.firstMatch.exists ? again.switches.firstMatch.tap() : again.tap()
        XCTAssertTrue(waitUntil(timeout: 4) { again.value as? String == "1" })
        app.terminate()
        app = launch(reset: false, introSeen: nil)
        openChat(app, "ivy")
        app.buttons["composer.mic"].press(forDuration: 2.0)
        XCTAssertTrue(waitUntil(timeout: 15) { self.prompts().count == before + 1 }, "a held memo sends on release")
    }

    // MARK: E18 Voice Diagnostics

    @MainActor private func openDiagnostics(_ app: XCUIApplication) {
        openVoiceSettings(app)
        app.buttons["config-page.voice.conversation"].tap()
        let row = app.buttons["voice.settings.diagnostics"]
        XCTAssertTrue(app.navigationBars["Voice Conversation"].waitForExistence(timeout: 8), "Voice Conversation opens")
        for _ in 0..<14 where !(row.exists && row.isHittable) { app.swipeUp() }     // the last row: below the fold at large sizes
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        XCTAssertTrue(app.buttons["voice.diag.record"].waitForExistence(timeout: 8), "Voice Diagnostics opens")
    }

    @MainActor private func diagStatus(_ app: XCUIApplication) -> String {
        let status = app.descendants(matching: .any)["voice.diag.status"]
        return status.exists ? status.label : ""
    }

    /// The ten rows as "name: value" (a row's label is its name and its value is what it says).
    @MainActor private func diagRows(_ app: XCUIApplication, only: ClosedRange<Int> = 0...9) -> [String] {
        (0..<10).map { only.contains($0) ? app.descendants(matching: .any)["voice.diag.row.\($0)"] : nil }
            .map { row in row.map { $0.exists ? "\($0.label): \($0.value as? String ?? "")" : "" } ?? "" }
    }

    @MainActor func testE18_VoiceDiagnostics() throws {
        let app = launch()
        openDiagnostics(app)
        let record = app.buttons["voice.diag.record"], play = app.buttons["voice.diag.play"], transcribe = app.buttons["voice.diag.transcribe"]
        XCTAssertEqual(record.label, "Record 3 s")
        XCTAssertFalse(play.isEnabled, "nothing to play yet")
        XCTAssertFalse(transcribe.isEnabled)
        XCTAssertEqual(diagStatus(app), "Transcribe sends the test recording to your Speech to Text provider.")
        // The page's names; the copied report keeps its own (`names`).
        let shownNames = ["Microphone Access", "Audio Session", "Audio In Use By", "Microphone On", "Echo Cancellation",
                          "Voice Paused", "Input", "Output", "Screen Kept Awake", "Recording a Memo"]
        let names = ["Microphone permission", "Audio session", "Audio in use by", "Microphone running", "Voice processing",
                     "Voice paused", "Input route", "Output route", "Screen kept awake", "Voice memo recording"]
        var rows = diagRows(app)
        for (index, name) in shownNames.enumerated() where index < 8 { XCTAssertTrue(rows[index].contains(name), "row \(index) is \(name) (\(rows[index]))") }
        XCTAssertTrue(rows[0].contains("Allowed"))
        XCTAssertTrue(rows[1].contains("Not Active"))
        XCTAssertTrue(rows[2].contains("Nothing"))
        shot(app, "E18-diagnostics")

        // The rows are read while the take runs. A take lasts three seconds; when reading the screen took longer than
        // that (a loaded Mac), what was read is thrown away and another take is made, three times at most.
        // One snapshot of the screen holds the status, the button and the rows of the same moment.
        var readWhileRecording = false, wasDisabled = false
        for _ in 0..<3 where !readWhileRecording {
            XCTAssertTrue(waitUntil(timeout: 12) { record.isEnabled }, "Record is ready")
            record.tap()
            var seen: [String: (label: String, value: String, enabled: Bool)] = [:]
            func walk(_ node: XCUIElementSnapshot) {
                if node.identifier.hasPrefix("voice.diag.") { seen[node.identifier] = (node.label, node.value as? String ?? "", node.isEnabled) }
                node.children.forEach(walk)
            }
            for _ in 0..<4 where seen["voice.diag.status"]?.label != "Recording 3 seconds…" {
                seen = [:]
                if let snapshot = try? app.snapshot() { walk(snapshot) }
                if seen["voice.diag.status"]?.label.hasPrefix("Recorded ") == true { break }
            }
            readWhileRecording = seen["voice.diag.status"]?.label == "Recording 3 seconds…"
            if readWhileRecording {
                wasDisabled = seen["voice.diag.record"]?.enabled == false
                rows = (0..<10).map { index in seen["voice.diag.row.\(index)"].map { "\($0.label): \($0.value)" } ?? "" }
            } else {
                XCTAssertTrue(waitUntil(timeout: 10) { self.diagStatus(app).hasPrefix("Recorded ") }, diagStatus(app))
            }
        }
        XCTAssertTrue(readWhileRecording, "the rows were read during a take")
        XCTAssertTrue(wasDisabled, "Record is off while it records")
        XCTAssertTrue(rows[1].contains("playAndRecord, default"), rows[1])
        XCTAssertTrue(rows[2].contains("Diagnostics"), rows[2])
        XCTAssertTrue(rows[3].contains("Yes"), rows[3])
        XCTAssertTrue(waitUntil(timeout: 10) { self.diagStatus(app).hasPrefix("Recorded ") }, "the take ends by itself (\(diagStatus(app)))")
        XCTAssertNotNil(diagStatus(app).range(of: #"^Recorded \d+ KB \(audio/wav\) from “.+”\.$"#, options: .regularExpression), diagStatus(app))
        XCTAssertTrue(play.isEnabled && transcribe.isEnabled)
        shot(app, "E18-recorded")

        play.tap()
        XCTAssertTrue(waitUntil(timeout: 12) { self.diagStatus(app).hasPrefix("Played ") }, "it plays to the end (\(diagStatus(app)))")
        XCTAssertNotNil(diagStatus(app).range(of: #"^Played [23]\.\d s\.$"#, options: .regularExpression), diagStatus(app))
        transcribe.tap()
        XCTAssertTrue(waitUntil(timeout: 12) { self.diagStatus(app).hasPrefix("Transcribed: “") }, diagStatus(app))
        XCTAssertEqual(ledger("transcribes").count, 1, "the take went to the gateway once")
        XCTAssertEqual(ledger("transcribes").first?["mime"] as? String, "audio/wav")
        shot(app, "E18-transcribed")

        // The last two rows and the events are further down.
        app.swipeUp()
        rows = diagRows(app)
        XCTAssertTrue(rows[8].contains("Screen Kept Awake") && rows[8].hasSuffix("No"), rows[8])
        XCTAssertTrue(rows[9].contains("Recording a Memo") && rows[9].hasSuffix("No"), rows[9])
        XCTAssertTrue(labelled(app, "diagnostics: test take began", contains: true).exists, "the events list has what just happened")
        XCTAssertTrue(labelled(app, "diagnostics: transcription answered", contains: true).exists)
        shot(app, "E18-events")
        let copy = app.buttons["voice.diag.copy"]
        for _ in 0..<4 where !(copy.exists && copy.isHittable) { app.swipeUp() }
        copy.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { copy.label == "Copied" }, copy.label)
        let report = probe(app)["copied"] as? String ?? ""
        let lines = report.components(separatedBy: "\n")
        XCTAssertTrue(lines.first?.hasSuffix(" voice diagnostics") == true, "the first line names the app (\(lines.first ?? ""))")
        XCTAssertFalse(report.contains("Dispatch"))
        for name in names { XCTAssertTrue(report.contains("\(name): "), "the report has \(name)") }
        XCTAssertTrue(report.contains("Test: Transcribed: “"), "and the test line")
        XCTAssertFalse(report.contains("127.0.0.1"), "never the gateway's address")
        XCTAssertFalse(report.contains(account.username), "nor the account")
    }

    // MARK: E19 Failures

    @MainActor func testE19a_SpeechToTextOff() throws {
        try account.control("/__fixture/voice", ["stt": ["default": false]])
        let app = launch()
        openChat(app, "ivy")
        talk(app).tap()
        let title = app.staticTexts["memo.notice.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "a card above the field says why")
        XCTAssertEqual(title.label, "Voice Unavailable")
        XCTAssertEqual(noticeMessage(app), "Speech to Text is off on your gateway. Turn it on in Settings › Voice › Speech to Text, then try again.")
        XCTAssertEqual(app.buttons["memo.notice.action"].label, "Voice Settings…")
        XCTAssertFalse(dockTitle(app).exists, "no conversation")
        XCTAssertEqual(probe(app)["conversations"] as? Int, 0)
        XCTAssertEqual(probe(app)["keepAwake"] as? Int, 0)
        XCTAssertEqual(ledger("transcribes").count, 0)
        shot(app, "E19a-speech-to-text-off")
        app.buttons["memo.notice.action"].tap()
        XCTAssertTrue(app.buttons["config-page.voice.transcription"].waitForExistence(timeout: 10), "Voice Settings… opens Settings › Voice")
    }

    /// The card says "turn it on, then try again": once it is on, the very next Talk works (no minute-long memory of "off").
    @MainActor func testE19a2_SpeechToTextTurnedOnThenTalkWorks() throws {
        try account.control("/__fixture/voice", ["stt": ["default": false]])
        let app = launch()
        openChat(app, "ivy")
        talk(app).tap()
        let title = app.staticTexts["memo.notice.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "a card above the field says why")
        XCTAssertEqual(title.label, "Voice Unavailable")
        XCTAssertEqual(probe(app)["conversations"] as? Int, 0)
        // Turned on (Settings › Voice saves it; here the stand-in gateway is told directly).
        try account.control("/__fixture/voice", ["stt": ["default": true]])
        app.buttons["memo.notice.close"].tap()
        XCTAssertTrue(waitUntil(timeout: 4) { !title.exists })
        talk(app).tap()
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 15), "Talk works at once after Speech to Text is turned on (\(dockTitle(app).exists ? dockTitle(app).label : "no dock"))")
        XCTAssertEqual(probe(app)["conversations"] as? Int, 1)
        shot(app, "E19a2-speech-to-text-on-again")
        end(app)
    }

    @MainActor func testE19b_MicrophoneDenied() throws {
        let app = launch(permission: "denied")
        openChat(app, "ivy")
        talk(app).tap()
        let title = app.staticTexts["memo.notice.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.label, "Microphone Access Is Off")
        let message = noticeMessage(app)
        XCTAssertTrue(message.hasPrefix("Turn on Microphone for ") && message.hasSuffix(" in Settings to talk with Ivy."), message)
        XCTAssertFalse(message.contains("Dispatch"))
        XCTAssertEqual(app.buttons["memo.notice.action"].label, "Open Settings")
        XCTAssertFalse(dockTitle(app).exists)
        XCTAssertEqual(probe(app)["conversations"] as? Int, 0)
        XCTAssertEqual(probe(app)["owner"] as? String, "")
        shot(app, "E19b-microphone-denied")
        app.buttons["memo.notice.close"].tap()
        XCTAssertTrue(waitUntil(timeout: 4) { !title.exists }, "closing the card dismisses it")
    }

    @MainActor func testE19c_ThreeFailedTranscriptionsStopIt() throws {
        let reason = "The speech model crashed while loading."
        try account.control("/__fixture/voice", ["transcribeFail": ["status": 500, "detail": reason]])
        let app = launch(script: "say:1;say:1;say:1;say:1")
        openChat(app, "ivy")
        talk(app).tap()
        XCTAssertTrue(dockTitle(app).waitForExistence(timeout: 8))
        // One failure does not stop it: the dock says why and listens on.
        let hint = dockNotice(app)
        XCTAssertTrue(waitUntil(timeout: 20) { hint.exists && hint.label == "Voice Transcription Failed. \(reason)" }, "the dock says why (\(hint.exists ? hint.label : ""))")
        shot(app, "E19c-one-failure")
        let title = app.staticTexts["talk.notice.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 40), "three in a row stop the conversation")
        XCTAssertEqual(title.label, "Voice Transcription Failed")
        XCTAssertEqual(app.staticTexts["talk.notice.message"].label, reason, "the gateway’s whole reason")
        let detail = app.descendants(matching: .any)["talk.notice.detail"]
        XCTAssertTrue((detail.value as? String ?? detail.label).contains("HTTP 500"), "with the status as the detail")
        XCTAssertEqual(app.buttons["talk.notice.primary"].label, "Try Again")
        XCTAssertEqual(ledger("transcribes").count, 3, "three tries")
        XCTAssertEqual(prompts().count, 0, "nothing was sent")
        shot(app, "E19c-voice-stopped")
        back(app)
        let pill = app.buttons["talk.pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 6))
        XCTAssertTrue(pill.label.hasPrefix("Ivy · Voice Stopped · Tap for details"), pill.label)
        shot(app, "E19c-stopped-pill")
        pill.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 8), "the notice is still in its chat")
        try account.control("/__fixture/voice", ["transcribeFail": NSNull(), "transcript": "It works again"])
        app.buttons["talk.notice.primary"].tap()
        XCTAssertTrue(dockTitle(app).waitForExistence(timeout: 8), "Try Again starts a conversation")
        XCTAssertTrue(waitUntil(timeout: 25) { self.prompts().count == 1 }, "and this time the words go out")
        end(app)
    }

    @MainActor func testE19d_AVoiceThisPhoneCannotPlay() throws {
        try account.control("/__fixture/voice", ["streamMode": "fallback", "speakMime": "audio/ogg", "transcript": "Say something"])
        // §7.7: unplayable audio hands over to the iPhone's voice; with that failing too the conversation stops and says why.
        let app = launch(["-HQDebugPhoneVoice", "fails"], script: "say:1.5", speaks: true)
        openChat(app, "ivy")
        talk(app).tap()
        let title = app.staticTexts["talk.notice.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 40), "speech that cannot be played stops the conversation")
        XCTAssertEqual(title.label, "Voice Playback Failed")
        XCTAssertEqual(app.staticTexts["talk.notice.message"].label,
                       "Your gateway’s voice uses a format iPhone can’t play (audio/ogg). Pick another Text to Speech provider in Settings › Voice.")
        XCTAssertEqual(prompts().count, 1, "the words were sent")
        XCTAssertTrue(inChat(app, "Synthetic performance reply.").exists, "and the answer is in the chat as text")
        shot(app, "E19d-unplayable-voice")
        app.buttons["talk.notice.done"].tap()
        XCTAssertTrue(talk(app).waitForExistence(timeout: 5))
    }

    // MARK: E20 A question during a conversation

    @MainActor func testE20_AQuestionDuringAConversation() throws {
        let app = launch()
        openChat(app, "ivy")
        talk(app).tap()
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 12))
        try account.control("/__fixture/voice", ["ask": ["profile": "ivy"]])
        let question = app.otherElements["question.dock"]
        XCTAssertTrue(question.waitForExistence(timeout: 12), "the question takes the dock's place")
        XCTAssertTrue(waitUntil(timeout: 5) { self.probe(app)["muted"] as? Bool == true }, "the conversation mutes itself while a question waits")
        XCTAssertEqual(probe(app)["conversations"] as? Int, 1, "and stays alive")
        XCTAssertTrue(!dockTitle(app).exists || !dockTitle(app).isHittable, "the voice dock is not in front")
        shot(app, "E20-question-over-the-conversation")
        app.buttons["question.choice.0"].firstMatch.tap()
        let primary = app.buttons["question.primary"]
        if primary.exists, primary.isEnabled { primary.tap() }
        if !waitUntil(timeout: 4, { !question.exists }) { try account.control("/__fixture/voice", ["cancelAsk": ["profile": "ivy"]]) }
        XCTAssertTrue(waitUntil(timeout: 8) { !question.exists }, "the answer closes the question")
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 10), "the voice dock is back, listening (\(dockTitle(app).exists ? dockTitle(app).label : "no dock"))")
        XCTAssertEqual(probe(app)["muted"] as? Bool, false, "and unmuted")
        shot(app, "E20-back-to-listening")
        end(app)
    }

    // MARK: E21 Keep awake

    @MainActor func testE21_KeepAwake() throws {
        try account.control("/__fixture/plan", ["plans": [["chunks": Array(repeating: "word ", count: 120), "chunkDelay": 0.1]]])
        let app = launch()
        XCTAssertEqual(probe(app)["keepAwake"] as? Int, 0, "nothing holds the screen at rest")
        XCTAssertEqual(probe(app)["idleTimerOff"] as? Bool, false)
        openChat(app, "ivy")
        // A conversation: one hold, also on the list.
        talk(app).tap()
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 12))
        XCTAssertEqual(probe(app)["keepAwake"] as? Int, 1)
        XCTAssertEqual(probe(app)["idleTimerOff"] as? Bool, true)
        back(app)
        XCTAssertEqual(probe(app)["keepAwake"] as? Int, 1, "the conversation still holds it on the list")
        app.buttons["talk.pill.end"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.probe(app)["keepAwake"] as? Int == 0 }, "ending it lets go")
        XCTAssertEqual(probe(app)["idleTimerOff"] as? Bool, false)

        // A reply that runs with its chat on screen: one hold; none after leaving that chat.
        openChat(app, "ivy")
        send(app, "A slow one please")
        XCTAssertTrue(app.buttons["composer.stop"].waitForExistence(timeout: 8), "the reply runs")
        XCTAssertTrue(waitUntil(timeout: 4) { self.probe(app)["keepAwake"] as? Int == 1 }, "a running reply keeps the screen awake")
        back(app)
        XCTAssertTrue(waitUntil(timeout: 4) { self.probe(app)["keepAwake"] as? Int == 0 }, "not after leaving its chat")
        openChat(app, "ivy")
        if app.buttons["composer.stop"].exists {
            XCTAssertTrue(waitUntil(timeout: 4) { self.probe(app)["keepAwake"] as? Int == 1 }, "and again when the chat is back")
            app.buttons["composer.stop"].tap()
        }
        XCTAssertTrue(waitUntil(timeout: 10) { self.probe(app)["keepAwake"] as? Int == 0 }, "the hold ends with the reply")

        // Dictation.
        app.tables["chat.table"].tap()
        XCTAssertTrue(talk(app).waitForExistence(timeout: 8))
        openOptions(app)
        app.buttons["voice.options.dictate"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.probe(app)["dictation"] as? String == "recording" })
        XCTAssertEqual(probe(app)["keepAwake"] as? Int, 1, "dictation holds it")
        app.buttons["dictation.cancel"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.probe(app)["keepAwake"] as? Int == 0 })

        // Home and back with nothing running.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1.5)
        app.activate()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 8))
        XCTAssertEqual(probe(app)["keepAwake"] as? Int, 0)
        XCTAssertEqual(probe(app)["idleTimerOff"] as? Bool, false)
    }

    @MainActor func testE21b_DiagnosticsDuringAConversation() throws {
        // The long windows are ten times longer here: on a loaded Mac the walk to the last Diagnostics row used to
        // outlast the conversation's own 2-minute silence pause (stress round 1), and this test is about a live one.
        let app = launch(["-HQDebugTalkClock", "0.1"])
        openChat(app, "ivy")
        talk(app).tap()
        XCTAssertTrue(waitForTitle(app, "Listening", timeout: 12))
        back(app)
        XCTAssertTrue(app.buttons["talk.pill"].waitForExistence(timeout: 4))
        openDiagnostics(app)
        XCTAssertEqual(probe(app)["conversations"] as? Int, 1, "Settings over the app does not end the conversation")
        var rows = diagRows(app)
        XCTAssertTrue(rows[1].contains("playAndRecord, default"), rows[1])
        XCTAssertTrue(rows[2].contains("Conversation"), rows[2])
        XCTAssertTrue(rows[3].hasSuffix("Yes"), rows[3])
        XCTAssertFalse(app.buttons["voice.diag.record"].isEnabled, "no test while voice is in use")
        XCTAssertEqual(diagStatus(app), "Voice is in use. End the conversation, memo or dictation to run a test.")
        shot(app, "E21-diagnostics-during-a-conversation")
        app.swipeUp()
        rows = diagRows(app)
        XCTAssertTrue(rows[8].contains("Yes (1 hold)"), "Screen Kept Awake: Yes (1 hold) (\(rows[8]))")
        shot(app, "E21-diagnostics-kept-awake")
    }

    // MARK: E22 The audio preview

    @MainActor func testE22_AudioPreview() throws {
        let app = launch(["-HQDebugTrayAudio", "12"], opens: "ivy")
        let tile = app.descendants(matching: .any)["composer.tray.tile.0"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "the recording is in the tray")
        tile.tap()
        let title = app.staticTexts["audio.preview.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 6), "audio opens in the preview sheet")
        XCTAssertEqual(title.label, "Field recording.m4a")
        XCTAssertNotNil(app.staticTexts["audio.preview.detail"].label.range(of: #"^\d+ KB · M4A audio$"#, options: .regularExpression),
                        app.staticTexts["audio.preview.detail"].label)
        let play = app.buttons["audio.preview.play"]
        XCTAssertTrue(waitUntil(timeout: 6) { play.isEnabled && play.label == "Play" }, "the player is ready and does not start by itself")
        let time = app.staticTexts["audio.preview.time"]
        XCTAssertEqual(time.label, "0 seconds of 12 seconds")
        XCTAssertEqual(probe(app)["owner"] as? String, "", "nothing plays yet")
        shot(app, "E22-audio-preview")
        play.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { play.label == "Pause" }, "Play becomes Pause")
        XCTAssertTrue(waitUntil(timeout: 6) { time.label != "0 seconds of 12 seconds" }, "the time moves (\(time.label))")
        shot(app, "E22-audio-preview-playing")
        play.tap()
        XCTAssertTrue(waitUntil(timeout: 4) { play.label == "Play" }, "Pause pauses")
        let paused = time.label
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertEqual(time.label, paused, "and the time stands still")
        play.tap()
        XCTAssertTrue(waitUntil(timeout: 4) { play.label == "Pause" })
        app.buttons["audio.preview.close"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !title.exists }, "Done closes the sheet")
        XCTAssertTrue(waitUntil(timeout: 5) { (self.probe(app)["owner"] as? String) == "" && (self.probe(app)["borrower"] as? String) == "" },
                      "and stops the playback (\(probe(app)["owner"] ?? "nil"))")
        XCTAssertTrue(tile.exists, "the recording is still in the tray")
    }

    @MainActor func testE22b_ACorruptRecordingSaysSo() throws {
        let app = launch(["-HQDebugTrayAudio", "0"], opens: "ivy")
        let tile = app.descendants(matching: .any)["composer.tray.tile.0"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        tile.tap()
        let status = app.staticTexts["audio.preview.status"]
        XCTAssertTrue(waitUntil(timeout: 8) { status.exists && status.label == "Couldn’t load this recording." }, "a file that is not audio says so")
        XCTAssertEqual(app.buttons["audio.preview.play"].label, "Try Again")
        shot(app, "E22-audio-preview-failed")
        app.buttons["audio.preview.close"].tap()
    }

    // MARK: E23 Accessibility sizes

    @MainActor private func sizes(_ category: String, _ name: String) throws {
        let app = launch(["-UIPreferredContentSizeCategoryName", category, "-HQDebugTalkClock", "8"], introSeen: false)
        openChat(app, "ivy")
        talk(app).tap()
        // The intro: only large, scrolling, with both buttons reachable.
        let start = app.buttons["talk.intro.start"]
        XCTAssertTrue(app.staticTexts["talk.intro.title"].waitForExistence(timeout: 6))
        shot(app, "E23-\(name)-intro")
        for _ in 0..<6 where !(start.exists && start.isHittable) { app.swipeUp() }
        XCTAssertTrue(start.isHittable, "Start Talking can be reached")
        shot(app, "E23-\(name)-intro-end")
        start.tap()
        XCTAssertTrue(dockTitle(app).waitForExistence(timeout: 10))
        let window = app.windows.firstMatch.frame
        let dock = app.descendants(matching: .any)["talk.dock"]
        XCTAssertLessThanOrEqual(dock.frame.height, window.height * 0.6 + 1, "the dock is at most 60 % of the screen")
        // Stop shows only while it does something (the desktop's conversation controls); Mute and End always.
        for id in ["talk.dock.mute", "talk.dock.center", "talk.dock.end"] {
            let button = app.buttons[id]
            if id == "talk.dock.center" && !button.exists { continue }
            XCTAssertTrue(button.exists, id)
            XCTAssertTrue(window.contains(button.frame), "\(id) is on screen (\(button.frame))")
        }
        let title = dockTitle(app)
        XCTAssertTrue(title.exists)
        XCTAssertLessThanOrEqual(title.frame.maxX, window.maxX)
        XCTAssertFalse(dockNotice(app).exists, "no line above the bar in a normal state")
        // The controls sit under the status at this size, every one inside the bar and the screen.
        let end = app.buttons["talk.dock.end"]
        XCTAssertGreaterThanOrEqual(end.frame.minY, title.frame.maxY - 1, "the controls are under the status")
        XCTAssertTrue(dock.frame.insetBy(dx: -5, dy: -4).contains(end.frame), "End is inside the bar (\(end.frame) in \(dock.frame))")
        shot(app, "E23-\(name)-dock")
        // The paused notice: Resume and Done stack, Copy Details sits beside the title, and all can be reached.
        let notice = app.staticTexts["talk.notice.title"]
        XCTAssertTrue(notice.waitForExistence(timeout: 30), "the silence pause (15 s on this clock)")
        let buttons = ["talk.notice.primary", "talk.notice.copy", "talk.notice.done"].map { app.buttons[$0] }
        XCTAssertTrue(buttons.allSatisfy { $0.exists })
        XCTAssertLessThan(buttons[0].frame.maxY, buttons[2].frame.minY + 1, "stacked at this size")
        XCTAssertLessThan(buttons[1].frame.maxY, buttons[0].frame.minY + 1, "Copy Details is up by the title")
        let message = app.staticTexts["talk.notice.message"]
        XCTAssertEqual(message.label, "Paused after 2 minutes of silence. Your chat with Ivy is saved.")
        shot(app, "E23-\(name)-paused")
        buttons[2].tap()
        XCTAssertTrue(talk(app).waitForExistence(timeout: 6))
        // Dictation's row.
        openOptions(app)
        shot(app, "E23-\(name)-voice-options")
        app.buttons["voice.options.dictate"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["dictation.status"].waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(app.buttons["dictation.cancel"].isHittable && app.buttons["composer.stop-dictation"].isHittable)
        shot(app, "E23-\(name)-dictating")
        app.buttons["dictation.cancel"].tap()
    }

    @MainActor func testE23a_AccessibilitySizeAX3() throws { try sizes("UICTContentSizeCategoryAccessibilityL", "AX3") }
    @MainActor func testE23b_AccessibilitySizeAX5() throws { try sizes("UICTContentSizeCategoryAccessibilityXXXL", "AX5") }

    @MainActor func testE23c_SettingsAndDiagnosticsAtAX5() throws {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        openDiagnostics(app)
        let record = app.buttons["voice.diag.record"], play = app.buttons["voice.diag.play"], transcribe = app.buttons["voice.diag.transcribe"]
        XCTAssertLessThan(record.frame.maxY, play.frame.minY + 1, "the three buttons stack at this size")
        XCTAssertLessThan(play.frame.maxY, transcribe.frame.minY + 1)
        shot(app, "E23-AX5-diagnostics")
        app.swipeUp()
        shot(app, "E23-AX5-diagnostics-rows")
        settingsBack(app)
        shot(app, "E23-AX5-voice-conversation")
        settingsBack(app)
        shot(app, "E23-AX5-voice-section")
    }

    @MainActor func testE23d_EntriesAtAX3() throws {
        try account.control("/__fixture/voice", ["emptyChat": "ivy"])
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        let row = app.cells["bot-row-ivy"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        holdMenu(app, row, "Talk", prefix: true)
        shot(app, "E23-AX3-row-menu")
        menuItem(app, "Bot Info").tap()
        let tiles = ["bot-info.tile.talk", "bot-info.tile.memo", "bot-info.tile.mute"].map { app.buttons[$0] }
        XCTAssertTrue(tiles[0].waitForExistence(timeout: 6))
        let window = app.windows.firstMatch.frame
        for tile in tiles {
            XCTAssertTrue(window.contains(tile.frame), "\(tile.identifier) is on screen (\(tile.frame))")
            XCTAssertGreaterThanOrEqual(tile.frame.height, 44)
        }
        // At this size the tiles are two to a row (3x-morepages §8): Talk and Memo side by side, Mute below.
        XCTAssertEqual(tiles[0].frame.midY, tiles[1].frame.midY, accuracy: 1, "Talk and Memo share a row")
        XCTAssertLessThanOrEqual(tiles[0].frame.maxX, tiles[1].frame.minX)
        XCTAssertLessThanOrEqual(tiles[1].frame.maxY, tiles[2].frame.minY, "Mute is on the next row")
        shot(app, "E23-AX3-bot-info-tiles")
        app.buttons["bot-info.close"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        openChat(app, "ivy")                                    // emptied before the launch
        let capsule = app.buttons["chat.intro.talk"], info = app.buttons["chat.intro.info"]
        XCTAssertTrue(capsule.waitForExistence(timeout: 10))
        XCTAssertTrue(info.exists)
        XCTAssertLessThanOrEqual(capsule.frame.maxY, info.frame.minY + 1, "at this size the two capsules stack")
        XCTAssertTrue(window.contains(capsule.frame) && window.contains(info.frame), "both are on screen")
        shot(app, "E23-AX3-empty-chat")
    }

    @MainActor func testE23e_ALongReasonIsReadableAtAX5() throws {
        let reason = Array(repeating: "The speech model on the gateway computer stopped answering while it was loading its weights.", count: 6).joined(separator: " ")
        XCTAssertGreaterThan(reason.count, 540)
        try account.control("/__fixture/voice", ["transcribeFail": ["status": 500, "detail": reason]])
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"], script: "say:1;say:1;say:1;say:1")
        openChat(app, "ivy")
        talk(app).tap()
        let title = app.staticTexts["talk.notice.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 60), "three failures stop the conversation")
        let message = app.staticTexts["talk.notice.message"]
        // A reason too long for one line is not shown (build 305: it pushed the controls off the screen); the plain
        // message is, and the whole reason is under Copy Details (§6.4).
        XCTAssertEqual(message.label, "The computer running Hermes couldn’t turn speech into text.", "the plain message")
        shot(app, "E23-AX5-long-reason")
        // The card scrolls: its last button can be reached, and the title again.
        let done = app.buttons["talk.notice.done"]
        for _ in 0..<8 where !(done.exists && done.isHittable) { message.swipeUp() }
        XCTAssertTrue(done.isHittable, "Done can be reached")
        XCTAssertTrue(app.buttons["talk.notice.primary"].exists && app.buttons["talk.notice.copy"].exists)
        shot(app, "E23-AX5-long-reason-end")
        app.buttons["talk.notice.copy"].tap()
        XCTAssertTrue(waitUntil(timeout: 3) { (self.probe(app)["copied"] as? String ?? "").contains(reason) }, "Copy Details has the whole reason")
        done.tap()
        XCTAssertTrue(waitUntil(timeout: 6) { !title.exists })
    }

    // MARK: E24 Relaunch

    @MainActor func testE24_ARelaunchKeepsNothingOfAConversation() throws {
        var app = launch(["-HQDebugTalkClock", "20", "-HQDebugReadRepliesAloud", "YES"])
        openChat(app, "ivy")
        talk(app).tap()
        XCTAssertTrue(app.staticTexts["talk.notice.title"].waitForExistence(timeout: 20), "a paused notice waits in Ivy's chat")
        back(app)
        openChat(app, "default")
        talk(app).tap()
        XCTAssertTrue(dockTitle(app).waitForExistence(timeout: 8), "and a conversation is live with Hermes")
        XCTAssertEqual(probe(app)["keepAwake"] as? Int, 1)
        app.terminate()

        app = launch(reset: false, introSeen: nil)
        var now = probe(app)
        XCTAssertEqual(now["conversations"] as? Int, 0, "no conversation after a relaunch")
        XCTAssertEqual(now["notices"] as? Int, 0, "no notice either")
        XCTAssertEqual(now["keepAwake"] as? Int, 0)
        XCTAssertEqual(now["takes"] as? Int, 0, "no take files are left")
        XCTAssertEqual(now["owner"] as? String, "")
        XCTAssertEqual(now["readReplies"] as? Bool, true, "Read Replies Aloud is kept")
        XCTAssertFalse(app.buttons["talk.pill"].exists, "no pill")
        openChat(app, "ivy")
        XCTAssertFalse(app.staticTexts["talk.notice.title"].exists, "Ivy's chat has its composer")
        XCTAssertTrue(talk(app).waitForExistence(timeout: 6), "with Talk as the circle")
        back(app)
        openChat(app, "default")
        XCTAssertFalse(dockTitle(app).exists)
        XCTAssertTrue(talk(app).waitForExistence(timeout: 6))
        // The intro stays seen: Talk goes straight to the dock.
        talk(app).tap()
        XCTAssertTrue(dockTitle(app).waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["talk.intro.title"].exists)
        now = probe(app)
        XCTAssertEqual(now["conversations"] as? Int, 1)
        end(app)
        XCTAssertTrue(waitUntil(timeout: 8) { self.talkLeases() == (0, 0) },
                      "the lease the kill left behind is released (\((try? voiceState())?["leases"] ?? "nil"))")
    }

    // MARK: E25 The hidden engine and wake word

    @MainActor func testE25_HiddenEngineAndWakeWord() throws {
        let app = launch()
        openVoiceSettings(app)
        let hidden = ["voice.voice_chat_mode", "voice.client_direct", "voice.gpt_live.voice", "voice.gpt_live.instructions",
                      "voice.wake_word.enabled", "voice.wake_word.phrase"]
        var dump = ""
        func look(_ where: String) {
            for key in hidden {
                XCTAssertFalse(app.buttons["config-field.\(key)"].exists || app.switches["config-field.\(key)"].exists, "\(key) is not on \(`where`)")
            }
            dump += "\n" + app.debugDescription
        }
        look("the Voice section")
        for page in ["conversation", "transcription", "speech"] {
            app.buttons["config-page.voice.\(page)"].tap()
            Thread.sleep(forTimeInterval: 1.5)
            look(page)
            app.swipeUp()
            look(page + ", further down")
            settingsBack(app)
            XCTAssertTrue(app.buttons["config-page.voice.conversation"].waitForExistence(timeout: 6))
        }
        // The probe's own line is not something a person reads.
        let shown = dump.components(separatedBy: "\n").filter { !$0.contains("talk.debug") }.joined(separator: "\n")
        for pattern in [#"\bGPT\b"#, #"(?i)live voice"#, #"(?i)\bwake\b"#, #"(?i)hey hermes"#, #"(?i)dispatch"#] {
            XCTAssertNil(shown.range(of: pattern, options: .regularExpression), "no Voice screen says \(pattern)")
        }
        // Settings search finds none of them either.
        settingsBack(app)
        let magnifier = app.navigationBars.buttons["settings.search"]
        XCTAssertTrue(magnifier.waitForExistence(timeout: 6))
        let search = app.searchFields["settings.search"]
        for word in ["wake", "gpt", "voice chat mode", "client direct"] {
            if !search.exists { magnifier.tap() }
            XCTAssertTrue(search.waitForExistence(timeout: 4))
            search.tap()
            search.clearAndType(word)
            Thread.sleep(forTimeInterval: 1.2)
            for key in hidden {
                XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier CONTAINS %@", key)).firstMatch.exists,
                               "searching “\(word)” does not find \(key)")
            }
            let found = app.debugDescription
            XCTAssertNil(found.components(separatedBy: "\n").filter { !$0.contains("talk.debug") && !$0.contains("settings.search") }.joined(separator: "\n")
                .range(of: #"(?i)wake word|gpt.?live|voice chat mode|client direct"#, options: .regularExpression), "searching “\(word)”")
        }
        shot(app, "E25-search-finds-nothing-hidden")
        XCTAssertEqual((try voiceState()["forbidden"] as? [Any])?.count, 0, "none of the never-called routes was called")
    }

    // MARK: E26 The ways in, in the dark appearance (screenshots to look at)

    @MainActor func testE26_EntriesInDark() throws {
        try account.control("/__fixture/voice", ["emptyChat": "default"])
        let app = launch(["-hqn.appearance", "dark"])
        let row = app.cells["bot-row-ivy"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        holdMenu(app, row, "Talk", prefix: true)
        shot(app, "E26-dark-row-menu")
        menuItem(app, "Bot Info").tap()
        XCTAssertTrue(app.buttons["bot-info.tile.talk"].waitForExistence(timeout: 6))
        shot(app, "E26-dark-bot-info-tiles")
        app.buttons["bot-info.close"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        openChat(app, "default")                                // emptied before the launch
        XCTAssertTrue(app.buttons["chat.intro.talk"].waitForExistence(timeout: 10))
        shot(app, "E26-dark-empty-chat")
        back(app)
        openChat(app, "ivy")
        plus(app).tap()
        XCTAssertTrue(app.buttons["composer.plus.talk"].waitForExistence(timeout: 5))
        shot(app, "E26-dark-plus-menu")
        dismissMenu(app)
        openOptions(app)
        shot(app, "E26-dark-voice-options")
        dismissMenu(app)
        let reply = app.buttons["chat.read-reply"]
        XCTAssertTrue(reply.waitForExistence(timeout: 6))
        openMore(app)
        shot(app, "E26-dark-more-menu")
    }
}
