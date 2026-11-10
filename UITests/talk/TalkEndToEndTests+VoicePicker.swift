// [voice picker] E30: Settings › Voice › Voice Conversation lists the live engine's voices with a sample each, a pick is
// saved for every bot, and the chat's Voice with … › Voice changes that bot's alone.

import XCTest

extension TalkEndToEndTests {
    @MainActor func testE30_PickAVoice() throws {
        try account.control("/__fixture/voice", ["grokAvailable": true, "liveAvailable": true, "schemaVoice": true])
        // The engine is picked with a tap: a launch argument would pin it (the argument domain wins over a save).
        var app = launch(["-HQDebugOpenVoice", "conversation"])
        let grok = app.buttons["voice.settings.engine.grok-live"]
        XCTAssertTrue(grok.waitForExistence(timeout: 15), "Voice Conversation opens")
        grok.tap()
        let eve = app.buttons["voice.settings.voice.eve"]
        XCTAssertTrue(eve.waitForExistence(timeout: 15), "Grok Live's voices are listed")
        XCTAssertTrue(eve.isSelected, "Eve, the add-on's default, is ticked")
        shot(app, "E30-grok-voices")
        app.swipeUp()
        Thread.sleep(forTimeInterval: 0.6)
        let rex = app.buttons["voice.settings.voice.rex"]
        XCTAssertTrue(rex.waitForExistence(timeout: 4), "the list goes on to Rex")
        shot(app, "E30-grok-voices-all")

        // A pick saves for every bot.
        rex.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { rex.isSelected }, "Rex is ticked")
        var profiles: [String] = []
        _ = waitUntil(timeout: 10) {
            profiles = (try? self.voiceState())?["configPutProfiles"] as? [String] ?? []
            return Set(profiles).isSuperset(of: ["default", "ivy"])
        }
        XCTAssertTrue(Set(profiles).isSuperset(of: ["default", "ivy"]), "saved on every bot: \(profiles)")
        let puts = (try? voiceState())?["configPuts"] as? [[String: Any]] ?? []
        let voices = puts.compactMap { (($0["voice"] as? [String: Any])?["grok_live"] as? [String: Any])?["voice"] as? String }
        XCTAssertFalse(voices.isEmpty, "the voice was written")
        XCTAssertTrue(voices.allSatisfy { $0 == "rex" }, "only Rex was written: \(voices)")
        XCTAssertEqual(puts.count, voices.count, "nothing but the voice was written")

        // ▶ plays a sample without picking it.
        let play = app.buttons["voice.settings.voice.leo.play"]
        play.tap()
        XCTAssertTrue(waitUntil(timeout: 4) { play.label == "Stop Leo" }, "the sample plays")
        shot(app, "E30-sample-playing")
        XCTAssertTrue(rex.isSelected, "listening did not change the pick")

        // GPT-Live has its own list.
        app.swipeDown()
        app.swipeDown()
        app.buttons["voice.settings.engine.gpt-live"].tap()
        XCTAssertTrue(app.buttons["voice.settings.voice.delta"].waitForExistence(timeout: 5), "GPT-Live's voices are listed")
        shot(app, "E30-gpt-voices")
        app.swipeUp()
        Thread.sleep(forTimeInterval: 0.6)
        shot(app, "E30-gpt-voices-all")

        // The chat's menu (GPT-Live, as picked above): this bot only.
        try account.control("/__fixture/voice", ["reset": true])
        try account.control("/__fixture/voice", ["liveAvailable": true, "schemaVoice": true,
                                                 "voiceConfig": ["voice": ["gpt_live": ["voice": "cedar"]]]])
        app = launch(reset: false, opens: "ivy")
        openOptions(app)
        Thread.sleep(forTimeInterval: 0.5)
        shot(app, "E30-chat-options")
        let voice = app.buttons.matching(NSPredicate(format: "identifier == 'voice.options.voice' OR label BEGINSWITH 'Voice,' OR label == 'Voice'")).firstMatch
        if !voice.exists { print(app.debugDescription) }
        XCTAssertTrue(voice.waitForExistence(timeout: 4), "Voice is in the voice options")
        voice.tap()
        let quartz = app.buttons["voice.options.voice.quartz"]
        XCTAssertTrue(quartz.waitForExistence(timeout: 6), "the voices load")
        XCTAssertFalse(quartz.isSelected)
        XCTAssertFalse(app.buttons["voice.options.voice.custom"].exists, "Cedar is on the list")
        quartz.swipeDown()
        Thread.sleep(forTimeInterval: 0.6)
        let cedar = app.buttons["voice.options.voice.cedar"]
        XCTAssertTrue(cedar.waitForExistence(timeout: 3) && cedar.isSelected, "Ivy's voice now is ticked")
        shot(app, "E30-chat-voices")
        quartz.tap()
        _ = waitUntil(timeout: 6) { !((try? self.voiceState())?["configPutProfiles"] as? [String] ?? []).isEmpty }
        Thread.sleep(forTimeInterval: 0.3)
        shot(app, "E30-chat-picked")
        XCTAssertEqual((try? voiceState())?["configPutProfiles"] as? [String], ["ivy"], "only Ivy's voice changed")
    }
}
