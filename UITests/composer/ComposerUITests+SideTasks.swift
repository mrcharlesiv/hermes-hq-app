// /btw and /bg (docs/spec/3x-composer.md §8.4, §8.5 checks 5 and 6) against the composer stand-in
// (scripts/fixtures/composer-gateway.py `side` mode: a task id at once, the result 2.5 s later, 6 s with `slow`).
// A result's line shows only the words before its colon ("By the way", "Background task finished"; owner 2026-10-27,
// BackgroundResults.split); what was asked leads the opened card.

import XCTest

extension ComposerUITests {
    @MainActor private func line(_ app: XCUIApplication, _ words: String) -> XCUIElement {
        IPad.message(app, containing: words)
    }

    @MainActor private func opened(_ app: XCUIApplication) -> XCUIElement {
        app.tables["chat.table"].descendants(matching: .any)["chat.tool.opened"]
    }

    @MainActor private func run(_ app: XCUIApplication, _ text: String) {
        let field = IPad.focusField(app)
        field.typeText(text)
        XCTAssertTrue(IPad.waitUntil(timeout: 10) { (field.value as? String) == text }, "\(text.debugDescription) is in the field")
        IPad.pressReturn(app)
    }

    /// §8.5 5: /btw during a slow reply starts at once, the reply keeps going, and the answer lands opened beside it.
    @MainActor func test23_BtwAnswersBesideARunningReply() throws {
        let (account, app) = try start()
        try account.control("/__fixture/plan", ["plans": [["replyDelay": 120]]])
        run(app, "hold this reply")
        XCTAssertTrue(app.buttons["composer.stop"].waitForExistence(timeout: 20), "the reply runs")
        run(app, "/btw what's the port?")
        let started = line(app, "Asking on the side")
        XCTAssertTrue(started.waitForExistence(timeout: 5), "the start line shows at once")
        XCTAssertEqual(calls(account, "prompt.btw").first?["text"] as? String, "what's the port?")
        XCTAssertEqual(texts(account), ["hold this reply"], "the question is not sent as a message")
        let answer = app.buttons["By the way"]
        XCTAssertTrue(answer.waitForExistence(timeout: 10), "the answer's row lands")
        XCTAssertEqual(answer.value as? String, "Expanded", "a /btw answer lands opened")
        XCTAssertTrue(opened(app).waitForExistence(timeout: 3))
        XCTAssertTrue(opened(app).label.hasPrefix("what's the port?"), "the question leads the card (\(opened(app).label))")
        XCTAssertTrue(opened(app).label.contains("port 8080"), "the answer reads (\(opened(app).label))")
        XCTAssertTrue(IPad.waitUntil(timeout: 3) { !started.exists }, "the start line went")
        XCTAssertTrue(app.buttons["composer.stop"].exists, "the reply is still running")
        IPad.shot(app, "side-btw-answer", in: self)
        _ = try? account.control("/__fixture/finish", ["profile": "default", "text": "Done."])
    }

    /// §8.5 6 and the usage lines: /bg's result is one line that opens on the report; a bare /btw says how.
    @MainActor func test24_BackgroundResultOpensOnTheReport() throws {
        let (account, app) = try start()
        run(app, "/btw")
        XCTAssertTrue(line(app, "Type a question after /btw").waitForExistence(timeout: 5), "a bare /btw says how")
        XCTAssertTrue(calls(account, "prompt.btw").isEmpty, "and asks nothing")
        run(app, "/bg run the tests")
        XCTAssertTrue(line(app, "Started in the background").waitForExistence(timeout: 5))
        XCTAssertEqual(calls(account, "prompt.background").first?["text"] as? String, "run the tests")
        let result = app.buttons["Background task finished"]
        XCTAssertTrue(result.waitForExistence(timeout: 10), "the result's row lands")
        XCTAssertEqual(result.value as? String, "Collapsed", "a background result stays one line")
        IPad.shot(app, "side-bg-folded", in: self)
        result.tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { result.value as? String == "Expanded" })
        XCTAssertTrue(opened(app).waitForExistence(timeout: 3))
        XCTAssertTrue(opened(app).label.hasPrefix("run the tests"), "the prompt leads the card (\(opened(app).label))")
        XCTAssertTrue(opened(app).label.contains("42 passed"), "the report reads (\(opened(app).label))")
        IPad.shot(app, "side-bg-opened", in: self)
    }

    /// §8.4 ⚑ DECISION: a result that lands while the chat is closed shows when it opens again, in the same launch.
    @MainActor func test25_AResultThatLandsWhileAwayIsThereOnReturn() throws {
        let (account, app) = try start()
        try account.control("/__composer/mode", ["side": "slow"])
        defer { _ = try? account.control("/__composer/mode", ["side": "ok"]) }
        run(app, "/btw where are the logs?")
        XCTAssertTrue(line(app, "Asking on the side").waitForExistence(timeout: 5))
        IPad.back(app)
        XCTAssertTrue(app.cells["bot-row-default"].waitForExistence(timeout: 8), "back on the Bots list")
        Thread.sleep(forTimeInterval: 8)   // the answer lands (6 s) while the chat is closed
        IPad.openBot(app)
        let answer = app.buttons["By the way"]
        XCTAssertTrue(answer.waitForExistence(timeout: 10), "the answer is there")
        XCTAssertTrue(opened(app).waitForExistence(timeout: 3))
        XCTAssertTrue(opened(app).label.hasPrefix("where are the logs?"), "its question leads the card (\(opened(app).label))")
        XCTAssertFalse(line(app, "Asking on the side").exists, "and the start line is gone")
    }
}
