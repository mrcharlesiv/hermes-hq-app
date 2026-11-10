// The model panel's thinking bar under a real finger (docs/spec/06-native-feel-and-design.md, Model panel ›
// Thinking). Owner 2026-10-31, on the ring before it: "The effort selector is hard to use and when you try to drag it to
// the right it ends up trying to pull the entire page off to go back." The panel shows the sample model
// (-HQDebugModelPanelSample: Off then minimal … ultra, at High); the level a drag settles on reaches the stand-in as
// config.set reasoning.

import XCTest

extension ComposerUITests {
    /// The `config.set reasoning` values sent since the reset, in order.
    @MainActor private func reasoningSent(_ account: FixtureAccount) -> [String] {
        calls(account, "config.set").filter { $0["key"] as? String == "reasoning" }.compactMap { $0["value"] as? String }
    }

    /// A drag along the thinking bar sets the level (right harder, left softer) and the page stays put.
    @MainActor func test29_ADragAlongTheThinkingBarKeepsThePage() throws {
        let (account, app) = try start(arguments: ["-HQDebugModelPanelSample", "YES"])
        _ = IPad.focusField(app)
        let bubble = app.buttons["composer.model"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 10), "the model bubble shows in the two-row bar")
        bubble.tap()
        let bar = app.descendants(matching: .any)["model.panel.thinking"]
        XCTAssertTrue(bar.waitForExistence(timeout: 8), "the panel opens with the thinking bar")
        XCTAssertTrue(IPad.waitUntil(timeout: 3) { (bar.value as? String ?? "").hasPrefix("High") }, "it opens at High (\(bar.value ?? "nil"))")
        // The bar runs along the row's foot (its centre 17 pt up); High sits just past its middle.
        let middle = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1)).withOffset(CGVector(dx: 0, dy: -17))
        middle.press(forDuration: 0.1, thenDragTo: middle.withOffset(CGVector(dx: 200, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(IPad.waitUntil(timeout: 8) { self.reasoningSent(account).last == "ultra" },
                      "a drag right settles on the top level (sent \(reasoningSent(account)))")
        XCTAssertTrue(app.descendants(matching: .any)["model.panel"].exists, "the panel is still open")
        XCTAssertTrue(bubble.exists && !app.cells["bot-row-default"].isHittable, "the chat is still on screen: no swipe back")
        IPad.shot(app, "thinking-bar-drag-right", in: self)

        // The sample panel reads High again; a drag left runs it down to Off.
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { (bar.value as? String ?? "").hasPrefix("High") })
        middle.press(forDuration: 0.1, thenDragTo: middle.withOffset(CGVector(dx: -200, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(IPad.waitUntil(timeout: 8) { self.reasoningSent(account).last == "none" },
                      "a drag left settles on Off (sent \(reasoningSent(account)))")
        XCTAssertEqual(reasoningSent(account).count, 2, "one config.set per drag")
        XCTAssertTrue(app.descendants(matching: .any)["model.panel"].exists, "the panel is still open")
    }

    /// Approvals from the model panel (owner 2026-10-31: "The pop-up for the model needs to also have your approval
    /// settings on it and fast mode"): Manual for the bot through config.set approvals.mode, then the YOLO
    /// switch for this chat through config.set yolo. Owner 2026-11-01 ("Do the weak points"): the two reaches are two
    /// rows, each saying how far it goes. Fast sits above them.
    @MainActor func test31_ApprovalsFromTheModelPanel() throws {
        let (account, app) = try start(arguments: ["-HQDebugModelPanelSample", "YES"])
        _ = IPad.focusField(app)
        let bubble = app.buttons["composer.model"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 10), "the model bubble shows in the two-row bar")
        bubble.tap()
        let tile = app.buttons["model.panel.approvals"]
        XCTAssertTrue(tile.waitForExistence(timeout: 8), "the panel opens with an Approval Mode row")
        XCTAssertEqual(tile.value as? String, "Smart", "the sample bot asks smartly")
        XCTAssertTrue(tile.label.hasPrefix("Approval Mode, Every chat with "), "it says it is the bot's rule (\(tile.label))")
        let skip = app.switches["model.panel.skip"]
        XCTAssertTrue(skip.exists && skip.isHittable, "YOLO under it")
        XCTAssertEqual(skip.label, "YOLO, No prompts in this chat")
        let fast = app.switches["model.panel.fast"]   // a row with a switch: XCUITest lists it as one
        XCTAssertTrue(fast.exists && fast.isHittable, "Fast sits with it")
        XCTAssertTrue(["Off", "0"].contains(fast.value as? String ?? ""), "Fast is off (\(fast.value ?? "nil"))")
        IPad.shot(app, "approvals-tile", in: self)

        tile.tap()
        let manual = app.buttons["model.panel.approvals.manual"]
        XCTAssertTrue(manual.waitForExistence(timeout: 5), "the menu lists the modes")
        IPad.shot(app, "approvals-menu", in: self)
        manual.tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 8) {
            self.calls(account, "config.set").contains { $0["key"] as? String == "approvals.mode" && $0["value"] as? String == "manual" }
        }, "Manual reaches the gateway (sent \(calls(account, "config.set")))")
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { tile.value as? String == "Manual" }, "the tile says Manual (\(tile.value ?? "nil"))")

        skip.tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 8) {
            self.calls(account, "config.set").contains { $0["key"] as? String == "yolo" && $0["value"] as? String == "1" }
        }, "this chat skips approvals (sent \(calls(account, "config.set")))")
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { ["1", "On"].contains(skip.value as? String ?? "") }, "the switch is on (\(skip.value ?? "nil"))")
        XCTAssertEqual(tile.value as? String, "Manual", "the bot's rule stays as it was")
        XCTAssertTrue(app.descendants(matching: .any)["model.panel"].exists, "the panel is still open")
        IPad.shot(app, "approvals-skipped", in: self)
    }

    /// The panel's ways out (owner 2026-11-01: "it all needs to be in the right places"): the bot's face opens Bot Info
    /// (the bot's own models), the Price fact opens Model Prices, and the name opens Switch Model. Each closes the panel
    /// first. No Prompts and no chat actions in it: those are the ⋯'s.
    @MainActor func test32_TheWaysOutOfTheModelPanel() throws {
        let (_, app) = try start(arguments: ["-HQDebugModelPanelSample", "YES"])
        _ = IPad.focusField(app)
        let bubble = app.buttons["composer.model"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 10))
        bubble.tap()
        let panel = app.descendants(matching: .any)["model.panel"]
        let face = app.buttons["model.panel.face"]
        XCTAssertTrue(face.waitForExistence(timeout: 8) && face.isHittable, "the face shows at the top")
        for gone in ["prompts", "chat", "usage", "prices"] {
            XCTAssertFalse(app.buttons["model.panel.\(gone)"].exists, "no \(gone) tile")
        }
        for id in ["model.panel.switch", "model.panel.fact.price", "model.panel.fact.plan", "model.panel.fast", "model.panel.approvals"] {
            let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
            XCTAssertTrue(element.exists && element.isHittable, "\(id) shows without scrolling")
        }
        IPad.shot(app, "panel-ways-out", in: self)

        face.tap()
        XCTAssertTrue(app.staticTexts["bot-info.name"].waitForExistence(timeout: 8), "the face opens Bot Info")
        app.botInfoTab("Brain")   // [page-tabs] the bot's Default Model is on Brain
        XCTAssertTrue(app.buttons["bot-info.default-model"].waitForExistence(timeout: 5), "with the bot's Default Model")
        XCTAssertFalse(panel.exists, "the panel closed for it")
        IPad.shot(app, "face-bot-info", in: self)
        app.buttons["bot-info.close"].tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { !app.buttons["bot-info.default-model"].exists }, "Bot Info closes")

        XCTAssertTrue(bubble.waitForExistence(timeout: 8), "the bar is back")
        bubble.tap()
        let price = app.buttons["model.panel.fact.price"]
        XCTAssertTrue(price.waitForExistence(timeout: 8))
        price.tap()
        XCTAssertTrue(app.descendants(matching: .any)["prices.page"].waitForExistence(timeout: 8), "Price opens Model Prices")
        XCTAssertFalse(panel.exists, "the panel closed before it")
        IPad.shot(app, "price-model-prices", in: self)
        app.buttons["sheet.close"].firstMatch.tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { !app.descendants(matching: .any)["prices.page"].exists }, "Model Prices closes")

        XCTAssertTrue(bubble.waitForExistence(timeout: 8))
        bubble.tap()
        let name = app.buttons["model.panel.switch"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.tap()
        let pick = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'model.panel.pick.'")).firstMatch
        let opened = pick.waitForExistence(timeout: 5)
        IPad.shot(app, "name-switch-menu", in: self)
        XCTAssertTrue(opened, "the name opens Switch Model with its models (Search All Models is further down)")
    }

    /// ⋯ › Model opens the same panel (owner 2026-11-01, "Do the weak points": the ⋯ had its own copy of the picker,
    /// and the panel was out of reach with the keys down). The iOS look's bar is two rows from the start (owner
    /// 2026-11-01), its bubble there with the keys down and after the panel closes; the card rests above it. The
    /// Desktop Look has no bubble: the card rises in place.
    @MainActor func test33_TheMoreMenuOpensTheModelPanel() throws {
        for (look, arguments) in [("ios", ["-HQDebugDesktopLook", "NO"]), ("desktop", ["-HQDebugDesktopLook", "YES"])] {
            // Not start(): it puts the caret in the field, and nothing here takes the keys away again.
            let account = try FixtureAccount.load()
            try account.control("/__composer/reset", [:])
            let app = IPad.launch(account, arguments: ["-HQDebugModelPanelSample", "YES"] + arguments)
            IPad.openBot(app)
            let bubble = app.buttons["composer.model"]
            XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 8))
            let twoRows = look == "ios"
            XCTAssertTrue(IPad.waitUntil(timeout: 5) { bubble.exists == twoRows }, "\(look): the bubble \(twoRows ? "is there" : "isn't") with the keys down")
            IPad.shot(app, "more-model-closed-bar-\(look)", in: self)
            let more = app.buttons["chat.more"]
            XCTAssertTrue(more.waitForExistence(timeout: 8))
            more.tap()
            let row = app.buttons["chat.more.model"]
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(look): the ⋯'s Model row")
            XCTAssertTrue(row.label.hasPrefix("Model, "), "with the model and its thinking under it (\(row.label))")
            IPad.shot(app, "more-model-row-\(look)", in: self)
            row.tap()
            let panel = app.descendants(matching: .any)["model.panel"]
            XCTAssertTrue(panel.waitForExistence(timeout: 8), "\(look): the ⋯ opens the panel")
            XCTAssertTrue(app.descendants(matching: .any)["model.panel.thinking"].exists)
            let field = app.textViews["composer.text"]
            if field.exists { XCTAssertLessThanOrEqual(panel.frame.maxY, field.frame.minY, "\(look): the card rests above the field") }
            IPad.shot(app, "more-model-panel-\(look)", in: self)
            let top = app.navigationBars.firstMatch.frame.maxY
            let above = panel.frame.minY - 24 > top + 8
            let point = above ? CGVector(dx: panel.frame.midX, dy: panel.frame.minY - 24) : CGVector(dx: max(2, panel.frame.minX / 2), dy: panel.frame.midY)
            app.coordinate(withNormalizedOffset: .zero).withOffset(point).tap()
            XCTAssertTrue(IPad.waitUntil(timeout: 5) { !panel.exists }, "\(look): a tap outside closes it")
            XCTAssertTrue(IPad.waitUntil(timeout: 5) { bubble.exists == twoRows }, "\(look): the bar is as it was")
            app.terminate()
        }
    }

    /// The panel left open from before the first message closes on its send (tester, 2026-11-06: "when I
    /// send the message I'd like this to close automatically").
    @MainActor func test34_SendingClosesTheModelPanel() throws {
        let (_, app) = try start(arguments: ["-HQDebugModelPanelSample", "YES"])
        // Typed first, then the panel for the thinking level (it takes the keys' place), then Send under it.
        IPad.focusField(app).typeText("Hello from under the panel")
        let bubble = app.buttons["composer.model"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 10))
        bubble.tap()
        let panel = app.descendants(matching: .any)["model.panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 8), "the panel opens")
        IPad.shot(app, "send-closes-panel-before", in: self)
        app.buttons["composer.send"].tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { !panel.exists }, "the send closes it")
        let field = IPad.field(app)
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { !((field.value as? String) ?? "").hasPrefix("Hello") }, "and the message went")
        IPad.shot(app, "send-closes-panel-after", in: self)
    }

    /// A running reply's Stop is glass too (label-tinted, the square in the page colour): a shot for the eye.
    @MainActor func test30_StopOnARunningReply() throws {
        let (account, app) = try start()
        try account.control("/__fixture/plan", ["plans": [["replyDelay": 120]]])
        let field = IPad.focusField(app)
        field.typeText("hold this reply")
        IPad.pressReturn(app)
        XCTAssertTrue(app.buttons["composer.stop"].waitForExistence(timeout: 20), "the reply runs: Stop shows")
        IPad.shot(app, "composer-stop-glass", in: self)
        _ = try? account.control("/__fixture/finish", ["profile": "default", "text": "Done."])
    }
}
