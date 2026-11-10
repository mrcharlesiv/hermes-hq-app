// [groups] A voice memo in a room (a tester, 2026-11-05: "group chat doesn't have voice memo"). The simulator's
// microphone is the app's fixture recorder (`-HQDebugMemoFixture`); the groups fixture keeps the files folder, the
// upload and the transcript (`/__groups/memos`).

import XCTest

extension GroupsEndToEndTests {

    // MARK: - D14 Hold the mic in a room: a memo bubble you can play, and the bots read its words

    @MainActor func testD14_VoiceMemoInARoom() throws {
        let app = launchSignedIn(["-HQDebugMemoFixture", "granted"])
        openRoom(app)
        let mic = app.buttons["composer.mic"]
        XCTAssertTrue(mic.waitForExistence(timeout: 8), "the microphone in a room")
        shot(app, "room-mic")
        let before = prompts.count
        mic.press(forDuration: 2.0)

        let words = "Synthetic transcript of a group memo."
        let bubble = app.tables["chat.table"].descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
        check(bubble.waitForExistence(timeout: 15), app, "d14-bubble", "the memo's bubble shows its words")
        XCTAssertTrue(app.buttons["memo.play"].firstMatch.exists, "the bubble has its play disc")
        let memos = (try? a.control("/__groups/memos")) ?? [:]
        XCTAssertEqual((memos["uploads"] as? [Any])?.count, 1, "one upload: \(memos)")
        XCTAssertEqual(memos["transcribes"] as? Int, 1, "one transcript")
        XCTAssertEqual(calls("file.attach"), 0, "no member's session attaches it")

        // Every member is asked with the memo's words, never the file directive.
        XCTAssertTrue(waitUntil(timeout: 20) { self.prompts.count > before }, "the room's members are asked")
        let asked = prompts.dropFirst(before).compactMap { $0["text"] as? String }
        XCTAssertTrue(asked.allSatisfy { $0.contains("(user): Voice Memo: \(words)") }, "each prompt carries the words: \(asked)")
        XCTAssertFalse(asked.contains { $0.contains("MEDIA:\"") }, "no file directive reaches a bot")
        // The room's record (the mirror other devices read) keeps the memo as a bot chat's memo reads.
        XCTAssertTrue(waitUntil(timeout: 20) { self.mirrorTexts().contains { $0.hasPrefix("MEDIA:\"") && $0.contains(words) } },
                      "the mirror keeps the memo: \(mirrorTexts().suffix(2))")
        shot(app, "room-memo")

        // It plays from the gateway's copy.
        // The members' replies can push the bubble up under the room's title bar: bring it back down first.
        let play = app.buttons["memo.play"].firstMatch
        for _ in 0..<4 where play.frame.minY < 220 { app.tables["chat.table"].swipeDown(velocity: .slow) }
        play.tap()
        check(waitUntil(timeout: 10) { app.buttons["memo.play"].firstMatch.label == "Pause Voice Memo" }, app, "d14-play", "it plays")
        assertNoHostedCalls()
    }
}

extension GroupsEndToEndTests {

    // MARK: - D15 An upload that fails keeps the memo as the room's draft; Send then delivers it once

    @MainActor func testD15_FailedMemoUploadKeepsADraft() throws {
        let app = launchSignedIn(["-HQDebugMemoFixture", "granted"])
        openRoom(app)
        control("memo", ["uploadStatus": 500])
        let before = prompts.count
        let mic = app.buttons["composer.mic"]
        XCTAssertTrue(mic.waitForExistence(timeout: 8))
        mic.press(forDuration: 2.0)

        let title = app.staticTexts["memo.notice.title"]
        check(title.waitForExistence(timeout: 15) && title.label == "Memo Saved as a Draft", app, "d15-notice",
              "the room says the memo waits: \(title.exists ? title.label : "missing")")
        XCTAssertTrue(any(app, "memo.chip").waitForExistence(timeout: 5), "the memo is the draft chip")
        XCTAssertFalse(app.tables["chat.table"].buttons["memo.play"].exists, "its bubble went away")
        sleep(2)
        XCTAssertEqual(prompts.count, before, "no bot was asked")
        XCTAssertFalse(mirrorTexts().contains { $0.hasPrefix("MEDIA:\"") }, "nothing reached the room's record")
        shot(app, "room-memo-draft")

        // The gateway takes uploads again: Send delivers the draft, once.
        control("memo", ["uploadStatus": 0])
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5) && send.isEnabled, "Send for the draft")
        send.tap()
        let words = "Synthetic transcript of a group memo."
        let bubble = app.tables["chat.table"].descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
        check(bubble.waitForExistence(timeout: 15), app, "d15-sent", "the draft went as a memo")
        XCTAssertFalse(any(app, "memo.chip").exists, "the chip is gone")
        XCTAssertFalse(app.staticTexts["memo.notice.title"].exists, "the draft card went with the draft")
        XCTAssertTrue(waitUntil(timeout: 20) { self.prompts.count > before }, "the members are asked")
        XCTAssertTrue(waitUntil(timeout: 20) { self.mirrorTexts().filter { $0.hasPrefix("MEDIA:\"") }.count == 1 }, "one memo in the room")
        let memos = (try? a.control("/__groups/memos")) ?? [:]
        XCTAssertEqual((memos["uploads"] as? [Any])?.count, 1, "one upload that landed: \(memos)")
        shot(app, "room-memo-draft-sent")
        assertNoHostedCalls()
    }
}
