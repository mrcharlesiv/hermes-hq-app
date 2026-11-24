// [threads] Words a busy bot chat cannot take go on in a thread (docs/spec/3x-threads.md §9), in the app itself: the
// stand-in gateway holds the bot's chat as a scheduled job does (`{"owned":true}`) and answers in threads.

import XCTest

extension SessionsTests {
    /// The `prompt.submit` and `session.create` calls the stand-in has taken, in order.
    private func rpcCalls(_ method: String) -> [[String: Any]] {
        let rpc = ((try? account.control("/__fixture/state")) ?? [:])["rpc"] as? [[String: Any]] ?? []
        return rpc.filter { $0["method"] as? String == method }.compactMap { $0["params"] as? [String: Any] }
    }

    /// The chats (runtime ids) a `prompt.submit` with these words went to.
    private func chatsSent(_ text: String) -> Set<String> {
        Set(rpcCalls("prompt.submit").filter { $0["text"] as? String == text }.compactMap { $0["session_id"] as? String })
    }

    @MainActor func test111_WordsABusyBotChatCannotTakeGoOnInAThread() throws {
        let question = "What time is the flight?"
        let answer = "The flight leaves at 9:40."
        fixture("/__fixture/mode", ["prompts": "hold", "threads": "reply", "owned": true, "answer": answer])
        let app = launch()
        app.buttons["Bots"].firstMatch.tap()
        let bot = app.cells["bot-row-research"]
        XCTAssertTrue(bot.waitForExistence(timeout: 15), "the Research row")
        bot.tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 10), "the bot's chat opens")
        Thread.sleep(forTimeInterval: 1.0)
        type(app, question, send: true)

        // It waits for the chat first, under the card it always had…
        XCTAssertTrue(app.descendants(matching: .any)["chat.ownerWait"].waitForExistence(timeout: 8), "the waiting card")
        shot(app, "busy-thread-waiting")
        // …then a thread takes it and answers, beside whatever holds the chat.
        let thread = app.descendants(matching: .any).matching(identifier: "chat.thread").firstMatch
        XCTAssertTrue(thread.waitForExistence(timeout: 20), "the thread is drawn in the bot's chat")
        // The stand-in answers within a second of taking the words. The open thread's row speaks its name and count
        // (its bubbles are silent: the row is the button), so the answer itself is checked in the screenshot; a thread
        // that had folded would be another kind of row by now (the walk's first run: it folded as it finished).
        XCTAssertTrue(waitUntil(10) { self.chatsSent(question).count == 2 }, "the thread took the words")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(thread.exists, "the thread stays open under the newest message once it has answered")
        XCTAssertFalse(app.descendants(matching: .any)["chat.sendFailure"].exists, "no Couldn’t Send card")
        XCTAssertFalse(app.descendants(matching: .any)["chat.ownerWait"].exists, "the waiting card is gone")
        XCTAssertEqual(app.textViews["composer.text"].value as? String ?? "", "", "nothing came back to the message box")
        shot(app, "busy-thread-answered")

        // On the wire: the thread was made under the bot's chat, its seed without the question, the question its message.
        let made = try XCTUnwrap(rpcCalls("session.create").last { $0["parent_session_id"] != nil }, "a thread was made")
        let seed = (made["messages"] as? [[String: Any]] ?? []).compactMap { $0["content"] as? String }
        XCTAssertFalse(seed.contains { $0.contains(question) }, "the seed leaves the question out: \(seed)")
        let first = chatsSent(question)
        // Proactive routing strip is now shown above the composer so follow-ups go straight into this thread (0 ms).
        XCTAssertTrue(app.descendants(matching: .any)["composer.busyThread"].waitForExistence(timeout: 5),
                      "the proactive routing banner shows above the composer")

        // The next words go directly into the same thread with zero main-chat round-trip, not a second thread.
        fixture("/__fixture/mode", ["answer": "Gate B12, boarding at 9:10."])
        type(app, "And the gate?", send: true)
        XCTAssertTrue(waitUntil(15) { self.chatsSent("And the gate?").count == 1 }, "the second message went straight to the thread")
        XCTAssertTrue(chatsSent("And the gate?").isSubset(of: first), "it went to the exact same thread, skipping the busy main chat")
        XCTAssertFalse(app.descendants(matching: .any)["chat.ownerWait"].exists, "no second waiting card")
        XCTAssertEqual(rpcCalls("session.create").filter { $0["parent_session_id"] != nil }.count, 1, "one thread for both")
        // One thread on screen. (Read once the rows settle: mid-update the accessibility tree has counted the
        // thread's row three times while the screen drew one.)
        Thread.sleep(forTimeInterval: 3)               // its answer lands in the same thread (the demo recording ends on it)
        let drawn = app.descendants(matching: .any).matching(identifier: "chat.thread")
        XCTAssertTrue(waitUntil(5) { drawn.count == 1 }, "one thread drawn, not \(drawn.count)")
        shot(app, "busy-thread-second")

        // The background task in the main chat finishes: it writes its finished reply and releases the chat.
        // The proactive routing banner clears by itself, the auto-thread folds cleanly, and the next message goes
        // straight back into the main chat carrying the side-thread context note on the wire.
        let parentId = try XCTUnwrap(made["parent_session_id"] as? String)
        let now = Int(Date().timeIntervalSince1970)
        fixture("/__fixture/mode", ["owned": false, "prompts": "reply",
                                    "answer": "Reminder set for 9:10 AM at Gate B12."])
        fixture("/__fixture/rows", ["id": parentId, "event": true, "set": [
            "last_active": now,
            "messages": [
                ["id": 1, "role": "user", "content": "Morning. Anything for me?", "timestamp": now - 7200],
                ["id": 2, "role": "assistant", "content": "Morning. Research here: nothing urgent today.", "timestamp": now - 7195],
                ["id": 3, "role": "assistant", "content": "Background summary finished — all sources checked.", "timestamp": now],
            ],
        ]])
        let banner = app.descendants(matching: .any)["composer.busyThread"]
        XCTAssertTrue(waitUntil(15) { !banner.exists }, "the proactive routing banner clears once the main chat is free")
        // Send a follow-up: goes directly into the main chat with the hidden side-thread context summary.
        type(app, "Set a boarding reminder.", send: true)
        XCTAssertTrue(waitUntil(15) {
            self.rpcCalls("prompt.submit").contains { params in
                let text = params["text"] as? String ?? ""
                return text.hasPrefix("Set a boarding reminder.") && text.contains("Gate B12")
            }
        }, "the next main-chat send carries the side-thread context summary on the wire")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(drawn.count, 0, "the auto-thread folded to a compact line once the main chat moved on")
        shot(app, "busy-thread-back-in-main")
    }
}
