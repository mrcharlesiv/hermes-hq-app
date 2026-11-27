// Phone Calls (Beta) acceptance against loopback fakes only (scripts/e2e-phone-simulation.sh): the app talks to a
// fake samplehost (scripts/fixtures/fake-samplehost.py) through the DEBUG-only HQ_SAMPLEHOST_BASE_URL. No provider, no real key
// (the synthetic KEYTEST), no real calls. The gateway serves chats and two logins only; it has no phone routes.
import XCTest

extension SessionsTests {
    func phoneFixtureAccount(_ name: String) throws -> FixtureAccount {
        let env = ProcessInfo.processInfo.environment
        let url = try XCTUnwrap(env["HQN_PHONE_GATEWAY"])
        XCTAssertEqual(URL(string: url)?.host, "127.0.0.1")
        return FixtureAccount(url: url, username: "phone-simulation-" + name.lowercased(),
                              password: try XCTUnwrap(env["HQN_PHONE_" + name]))
    }

    /// The fake samplehost's base (TEST_RUNNER_HQN_SAMPLEHOST_URL), reached for its `/__fixture/…` hooks.
    func samplehostFixture() throws -> FixtureAccount {
        guard let url = ProcessInfo.processInfo.environment["HQN_SAMPLEHOST_URL"], !url.isEmpty else {
            throw XCTSkip("Run scripts/e2e-phone-simulation.sh (it starts the fake samplehost).")
        }
        return FixtureAccount(url: url, username: "", password: "")
    }

    func samplehostRequests(_ samplehost: FixtureAccount) throws -> [[String: Any]] {
        try samplehost.control("/__fixture/state")["requests"] as? [[String: Any]] ?? []
    }

    /// Every request carried the key in its header only.
    func assertKeyOnlyInHeader(_ samplehost: FixtureAccount, file: StaticString = #filePath, line: UInt = #line) throws {
        for request in try samplehostRequests(samplehost) {
            XCTAssertEqual(request["auth_ok"] as? Bool, true, "\(request)", file: file, line: line)
            XCTAssertEqual(request["key_in_url"] as? Bool, false, "\(request)", file: file, line: line)
            XCTAssertEqual(request["key_in_body"] as? Bool, false, "\(request)", file: file, line: line)
        }
    }

    /// More › Settings › Phone Calls (Beta), from wherever the More tab was left (a second tap on More pops it to its
    /// first page, so a page another account left open is never reused).
    @MainActor func openPhoneSettings(_ app: XCUIApplication) {
        let more = app.tabButton(id: "tab-more", label: "More")
        more.tap()
        let settings = app.cells["more-row-settings"]
        for _ in 0..<3 where !settings.waitForExistence(timeout: 3) { more.tap() }
        if !settings.exists { shot(app, "phone-more-not-found") }
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        let phoneSettings = app.buttons["settings.phone-calls"]
        for _ in 0..<6 where !phoneSettings.isHittable { app.swipeUp() }
        XCTAssertTrue(phoneSettings.waitForExistence(timeout: 10)); phoneSettings.tap()
        XCTAssertTrue(app.staticTexts["phone.settings.status"].waitForExistence(timeout: 10))
    }

    /// Waits for the element, then scrolls the sheet down and back up until it is in the tree: a Form drops rows it
    /// hasn't drawn, and this round's sheet is taller than one screen.
    @MainActor func revealed(_ app: XCUIApplication, _ element: XCUIElement, timeout: TimeInterval = 2) -> Bool {
        if element.waitForExistence(timeout: timeout) { return true }
        for swipe in [true, true, true, false, false, false, false, false, false] {
            if swipe { app.swipeUp() } else { app.swipeDown() }
            if element.waitForExistence(timeout: 1) { return true }
        }
        return false
    }

    /// Types the synthetic key and connects. The fake account has one number (preselected) and no AI Assistant, so the
    /// page offers Create Assistant; one tap makes it, selects it and saves (the owner's 2026-11-20 "I can't select an agent").
    @MainActor func connectsamplehost(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Not connected"].waitForExistence(timeout: 10))
        let key = app.secureTextFields["samplehost API key"]
        XCTAssertTrue(key.waitForExistence(timeout: 15)); key.tap(); key.typeText("KEYTEST")
        XCTAssertFalse((key.value as? String ?? "").contains("KEYTEST"), "the key stays masked")
        shot(app, "phone-masked-key")
        app.buttons["Connect"].tap()
        XCTAssertTrue(app.staticTexts["Connected, choose a number and assistant"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.secureTextFields["samplehost API key"].exists, "the key is never shown again")
        XCTAssertTrue(app.buttons["From number, +12125550100"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Voice connection, Simulated connection"].exists)
        let create = app.buttons["phone.settings.create-assistant"]
        if !create.waitForExistence(timeout: 5) { app.swipeUp() }   // a long footer can push it under the fold
        XCTAssertTrue(create.waitForExistence(timeout: 10), "an account with no assistant is offered one")
        shot(app, "phone-no-assistant")
        create.tap()
        if !app.staticTexts["Ready"].waitForExistence(timeout: 5) { app.swipeDown() }
        XCTAssertTrue(app.staticTexts["Ready"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Disconnect"].exists)
        shot(app, "phone-ready")
    }

    /// Opens the chat's ⋯ and answers whether Phone Call is in it (owner 2026-11-21: in the ⋯, not its own bar button).
    /// With `open`, taps it; otherwise closes the menu.
    @MainActor @discardableResult func phoneCallInMenu(_ app: XCUIApplication, open: Bool = false, timeout: TimeInterval = 5) -> Bool {
        let more = app.buttons["chat.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 20)); more.tap()
        let item = app.buttons["chat.phone-calls"]
        let found = item.waitForExistence(timeout: timeout)
        if found { shot(app, "phone-more-menu") }
        if found && open { item.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82)).tap() }
        return found
    }

    /// From a chat: ⋯ › Phone Call, fill the confirm form, check nothing dialed before confirming, confirm.
    @MainActor func placeSimulatedCall(_ app: XCUIApplication, _ samplehost: FixtureAccount, to number: String = "+12125550142",
                                       shotForm: Bool = false, goal: String = "Discuss simulated appointment",
                                       name: String? = nil, previousCalls: Int = 0) throws {
        let to = app.textFields["phone.to"]
        for _ in 0..<3 where !to.exists {
            phoneCallInMenu(app, open: true, timeout: 10); if to.waitForExistence(timeout: 4) { break }
        }
        XCTAssertTrue(to.waitForExistence(timeout: 10)); to.tap(); to.typeText(number)
        let purpose = app.textFields["phone.purpose"].exists ? app.textFields["phone.purpose"] : app.textViews["phone.purpose"]
        if let name {
            let field = app.textFields["phone.name"]
            field.tap(); field.typeText(name)
        }
        purpose.tap(); purpose.typeText(goal)
        if shotForm { shot(app, "phone-call-form") }
        app.buttons["Review call"].tap()
        let confirm = app.buttons["phone.place"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertEqual((try samplehost.control("/__fixture/state")["calls"] as? [[String: Any]])?.count, previousCalls, "review alone must not dial")
        shot(app, "phone-confirm")
        confirm.tap()
    }

    @MainActor func testPhoneCallsSimulatedAcceptance() throws {
        let samplehost = try samplehostFixture()
        try samplehost.control("/__fixture/reset", [:])
        try account.control("/__fixture/mode", ["prompts": "reply"])
        let app = launch(fresh: true, environment: ["HQ_SAMPLEHOST_BASE_URL": samplehost.url + "/v2"])
        let garden = row(app, "s-garden")
        XCTAssertTrue(garden.waitForExistence(timeout: 20)); garden.tap()
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 20))
        XCTAssertFalse(phoneCallInMenu(app, timeout: 3), "no key: no Phone Call in the ⋯")
        shot(app, "phone-no-key")
        XCTAssertTrue(try samplehostRequests(samplehost).isEmpty, "nothing talks to samplehost before a key is connected")
        app.navigationBars.buttons["BackButton"].firstMatch.tap()

        openPhoneSettings(app)
        connectsamplehost(app)
        _ = waitUntil(10) {
            (try? samplehostRequests(samplehost).contains { ($0["method"] as? String) == "GET" && ($0["path"] as? String) == "/v2/ai/assistants/assistant-sim" }) == true
        }
        let setupRequests = try samplehostRequests(samplehost).map { "\($0["method"] ?? "") \($0["path"] ?? "")" }
        XCTAssertEqual(Set(setupRequests), ["GET /v2/phone_numbers", "GET /v2/ai/assistants", "POST /v2/ai/assistants",
                                            "GET /v2/ai/assistants/assistant-sim"],
                       "setup reads, creates the assistant with recording off by default, and confirms it")
        XCTAssertEqual(setupRequests.filter { $0 == "POST /v2/ai/assistants" }.count, 1, "one assistant made")
        let telephony = try XCTUnwrap(try samplehost.control("/__fixture/state")["telephony"] as? [String: Any])
        XCTAssertEqual((telephony["recording_settings"] as? [String: Any])?["enabled"] as? Bool, false, "Record calls is off by default")

        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(garden.waitForExistence(timeout: 15)); garden.tap()
        XCTAssertFalse(app.navigationBars.buttons["Phone Calls"].exists, "no phone button in the bar")
        try placeSimulatedCall(app, samplehost, shotForm: true)

        XCTAssertTrue(app.staticTexts["Which simulated time works?"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Hello from the simulated agent."].exists, "no emotion tag")
        XCTAssertTrue(app.staticTexts["The simulated recipient has a question."].exists)
        XCTAssertTrue(app.staticTexts["Waiting on you"].exists)
        XCTAssertFalse(app.staticTexts["Request failed"].exists, "the tool's receipt is hidden")
        XCTAssertFalse(app.staticTexts["[long silence]"].exists)
        XCTAssertTrue(app.staticTexts["They are holding"].exists)
        shot(app, "phone-question")
        let morning = app.buttons["Morning"]
        for _ in 0..<3 where !morning.isHittable { app.swipeUp() }
        XCTAssertTrue(morning.waitForExistence(timeout: 10)); morning.tap()
        XCTAssertTrue(app.staticTexts["Simulated answer received: Morning"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Which simulated time works?"].exists, "an answered question goes away")
        let answers = try XCTUnwrap(try samplehost.control("/__fixture/state")["answers"] as? [[String: Any]])
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers.first?["tool_call_id"] as? String, "call_ask_1")
        XCTAssertEqual(answers.first?["answer"] as? String, "Morning")
        XCTAssertEqual(answers.first?["roles"] as? [String], ["tool", "system"])
        shot(app, "phone-answered")

        hangUp(app)
        XCTAssertTrue(app.staticTexts["You hung up"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Hang up"].exists)
        XCTAssertTrue(statusText(app, prefix: "Finished · ").waitForExistence(timeout: 30), "settled from the event log")
        XCTAssertEqual(try samplehost.control("/__fixture/state")["hangups"] as? Int, 1)
        shot(app, "phone-ended")

        app.buttons["phone.close"].tap()
        XCTAssertTrue(app.buttons["phone.close"].waitForNonExistence(timeout: 10), "sheet must actually close before reopening")
        XCTAssertTrue(phoneCallInMenu(app, open: true, timeout: 10), "Phone Call reopens from the ⋯")
        XCTAssertTrue(app.buttons["phone.close"].waitForExistence(timeout: 10))
        let recent = app.buttons["phone.recent.row"].firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 10), "the ended call appears in Recent")
        recent.tap()
        XCTAssertTrue(statusText(app, prefix: "Finished · ").waitForExistence(timeout: 10), "the ended call opens its summary")
        app.buttons["Transcript"].tap()
        XCTAssertTrue(revealed(app, app.staticTexts["Simulated answer received: Morning"]), "the transcript is still there")
        shot(app, "phone-reopened")

        let state = try samplehost.control("/__fixture/state")
        XCTAssertEqual(state["problems"] as? [String], [], "every request matched samplehost's documented shape")
        XCTAssertEqual((state["calls"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(state["hangups"] as? Int, 1, "a reopened sheet never hangs up or dials again")
        try assertKeyOnlyInHeader(samplehost)
    }

    /// Account A's key never shows on account B: B has no call button, its settings say Not connected, and B never
    /// talks to samplehost. Back on A, calling works with A's key.
    @MainActor func testPhoneCallsAccountSwitch() throws {
        let samplehost = try samplehostFixture()
        try samplehost.control("/__fixture/reset", [:])
        try account.control("/__fixture/mode", ["prompts": "reply"])
        let original = try XCTUnwrap(account)
        let other = try phoneFixtureAccount("B")
        XCTAssertEqual(original.url, other.url, "same gateway, two independently signed-in logins")
        let app = launch(fresh: true, environment: ["HQ_SAMPLEHOST_BASE_URL": samplehost.url + "/v2"])
        let garden = row(app, "s-garden")
        XCTAssertTrue(garden.waitForExistence(timeout: 20))
        openPhoneSettings(app)
        connectsamplehost(app)

        // Sign in as B (More › Settings › gateway card › Add).
        let settingsBack = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(settingsBack.waitForExistence(timeout: 10)); settingsBack.tap()
        let gatewayCard = app.buttons["settings.gateway-card"]
        for _ in 0..<8 where !gatewayCard.exists { app.swipeDown() }
        XCTAssertTrue(gatewayCard.waitForExistence(timeout: 10)); gatewayCard.tap()
        let addGateway = app.buttons["gateway.add"]
        XCTAssertTrue(addGateway.waitForExistence(timeout: 10)); addGateway.tap()
        XCTAssertTrue(app.textFields["sign-in-address"].waitForExistence(timeout: 10))
        let before = try samplehostRequests(samplehost).count
        account = other; signIn(app); account = original
        XCTAssertTrue(app.tabBars.buttons["Sessions"].waitForExistence(timeout: 30)); app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(garden.waitForExistence(timeout: 20)); garden.tap()
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 20))
        XCTAssertFalse(phoneCallInMenu(app), "B has no key: no Phone Call in the ⋯")
        shot(app, "phone-switch-b-chat")
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        openPhoneSettings(app)
        XCTAssertTrue(app.staticTexts["Not connected"].waitForExistence(timeout: 10), "B never sees A's key")
        XCTAssertFalse(app.staticTexts["Ready"].exists)
        XCTAssertFalse(app.buttons["Disconnect"].exists)
        XCTAssertEqual((app.secureTextFields["samplehost API key"].value as? String ?? "").contains("•"), false, "the field starts empty")
        shot(app, "phone-switch-b-settings")
        XCTAssertEqual(try samplehostRequests(samplehost).count, before, "B never talks to samplehost")

        // Back to A: its key is still there and calling works.
        app.tabBars.buttons["Bots"].tap()
        let switcher = app.buttons["gateway-switcher"].firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 15)); switcher.tap()
        let items = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'gateway-menu-' AND identifier != 'gateway-menu-cloud'"))
        XCTAssertGreaterThanOrEqual(items.count, 2)
        // Saved gateways are newest first: B is the current first row, A is the second.
        items.element(boundBy: 1).tap()
        XCTAssertTrue(app.tabBars.buttons["Sessions"].waitForExistence(timeout: 20)); app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(garden.waitForExistence(timeout: 20)); garden.tap()
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 20))
        try placeSimulatedCall(app, samplehost)   // A's key is still connected: Phone Call is in its ⋯
        XCTAssertTrue(app.staticTexts["Which simulated time works?"].waitForExistence(timeout: 20))
        let morning = app.buttons["Morning"]
        for _ in 0..<3 where !morning.isHittable { app.swipeUp() }
        XCTAssertTrue(morning.waitForExistence(timeout: 10)); morning.tap()
        XCTAssertTrue(app.staticTexts["Simulated answer received: Morning"].waitForExistence(timeout: 15))
        hangUp(app)
        XCTAssertTrue(app.staticTexts["You hung up"].waitForExistence(timeout: 10))
        shot(app, "phone-switch-a-ended")
        XCTAssertEqual(try samplehost.control("/__fixture/state")["problems"] as? [String], [])
        try assertKeyOnlyInHeader(samplehost)
    }

    /// The red button, then End call: hanging up takes both taps.
    @MainActor func hangUp(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let hangup = app.buttons["Hang up"]
        let confirm = app.buttons["phone.hangup.confirm"]
        // The question answers no tap for its first half second, and goes away by itself after four: ask again then.
        for _ in 0..<3 {
            for _ in 0..<3 where !hangup.isHittable && !confirm.exists { app.swipeUp() }
            if !confirm.exists { hangup.tap() }
            XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the red button asks first", file: file, line: line)
            confirm.tap()
            if confirm.waitForNonExistence(timeout: 2), !app.staticTexts["phone.hangup.prompt"].exists { return }
        }
    }

    /// The accidental hang-up guard: a double tap, a run of taps in the same spot, Keep call and four seconds of
    /// waiting all leave the call up. Only the red button followed by End call ends it, once.
    @MainActor func testPhoneCallsHangUpTakesTwoTaps() throws {
        let samplehost = try samplehostFixture()
        let app = try phoneChat(samplehost, scenario: "live")
        try placeSimulatedCall(app, samplehost)
        XCTAssertTrue(app.textFields["phone.tell"].waitForExistence(timeout: 25), "the call is up")
        let hangup = app.buttons["Hang up"]
        let prompt = app.staticTexts["phone.hangup.prompt"]
        let tell = app.textFields["phone.tell"]
        for _ in 0..<3 where !hangup.isHittable { app.swipeUp() }
        func hangUps() throws -> Int { try XCTUnwrap(try samplehost.control("/__fixture/state")["hangups"] as? Int) }

        // 1. A double tap on the red button: the question comes up and stays up; nothing was hung up.
        hangup.doubleTap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 5), "the question shows")
        XCTAssertTrue(app.buttons["phone.hangup.confirm"].isHittable && app.buttons["phone.hangup.cancel"].isHittable)
        XCTAssertGreaterThanOrEqual(app.buttons["phone.hangup.confirm"].frame.height, 44)
        XCTAssertGreaterThanOrEqual(app.buttons["phone.hangup.cancel"].frame.height, 44)
        shot(app, "phone-hangup-question")
        XCTAssertEqual(try hangUps(), 0, "a double tap never ends the call")

        // 2. Keep call puts the dock back.
        app.buttons["phone.hangup.cancel"].tap()
        XCTAssertTrue(tell.waitForExistence(timeout: 5) && hangup.waitForExistence(timeout: 5), "Keep call brings the dock back")
        XCTAssertFalse(prompt.exists)
        XCTAssertEqual(try hangUps(), 0)

        // 3. Taps that keep landing where the red button is: what comes up under the finger is Keep call.
        let red = hangup.frame   // a place on the screen: the red button itself is gone while the question is up
        let spot = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: red.midX, dy: red.midY))
        for _ in 0..<6 { spot.tap() }
        XCTAssertEqual(try hangUps(), 0, "six taps in the red button's spot never end the call")
        XCTAssertTrue(statusText(app, prefix: "Finished").exists == false && !app.staticTexts["You hung up"].exists)
        if prompt.exists { app.buttons["phone.hangup.cancel"].tap() }
        XCTAssertTrue(hangup.waitForExistence(timeout: 5))

        // 4. The question goes away by itself.
        hangup.tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 8), "four seconds without an answer: back to the dock")
        XCTAssertTrue(tell.waitForExistence(timeout: 5))
        XCTAssertEqual(try hangUps(), 0)

        // 5. The red button, then End call: one hang-up.
        hangUp(app)
        XCTAssertTrue(app.staticTexts["You hung up"].waitForExistence(timeout: 10))
        XCTAssertFalse(hangup.exists || prompt.exists)
        XCTAssertEqual(try hangUps(), 1)
        XCTAssertEqual(try samplehost.control("/__fixture/state")["problems"] as? [String], [])
        try assertKeyOnlyInHeader(samplehost)
    }

    /// A call's status line (`phone.call.status`) that starts with these words.
    @MainActor func statusText(_ app: XCUIApplication, prefix: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "identifier == 'phone.call.status' AND label BEGINSWITH %@", prefix)).firstMatch
    }

    /// Reset both fakes, pick the fake samplehost's scenario, launch fresh, connect, and open the Garden chat.
    @MainActor func phoneChat(_ samplehost: FixtureAccount, scenario: String, extra: [String] = []) throws -> XCUIApplication {
        try samplehost.control("/__fixture/reset", [:])
        try samplehost.control("/__fixture/scenario", ["name": scenario])
        try account.control("/__fixture/mode", ["prompts": "reply"])
        let app = launch(fresh: true, extra: extra, environment: ["HQ_SAMPLEHOST_BASE_URL": samplehost.url + "/v2"])
        openPhoneSettings(app)
        connectsamplehost(app)
        app.tabBars.buttons["Sessions"].tap()
        let garden = row(app, "s-garden")
        XCTAssertTrue(garden.waitForExistence(timeout: 15)); garden.tap()
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 20))
        return app
    }

    /// Voicemail picks up 1 second after the dial: "Went to voicemail" and the straight-to-voicemail note (item 12).
    @MainActor func testPhoneCallsVoicemailInOneSecond() throws {
        let samplehost = try samplehostFixture()
        let app = try phoneChat(samplehost, scenario: "voicemail")
        try placeSimulatedCall(app, samplehost, to: "212 555 0142")
        XCTAssertTrue(statusText(app, prefix: "Went to voicemail").waitForExistence(timeout: 40), "settled from the event log")
        let note = app.staticTexts["phone.call.voicemail-note"]
        XCTAssertTrue(revealed(app, note, timeout: 5))
        XCTAssertEqual(note.label, "Voicemail picked up in 1 second, so the phone probably never rang. That is the other phone or its carrier (Do Not Disturb or a Focus, Silence Unknown Callers, a spam filter), not your samplehost setup.")
        XCTAssertTrue(app.staticTexts["+1 212 555 0142 · picked up in 1 second"].exists)
        XCTAssertTrue(app.buttons["Leave a message"].exists)
        XCTAssertFalse(app.buttons["Hang up"].exists)
        shot(app, "phone-voicemail-note")
        app.buttons["phone.call.options"].tap()
        app.buttons["Transcript"].tap()
        XCTAssertTrue(revealed(app, app.staticTexts["The person you are calling is not available. Please record your message at the tone."]))
        app.buttons["sheet.back"].tap()
        app.buttons["Leave a message"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Leave a short message'")).firstMatch.exists)
        let state = try samplehost.control("/__fixture/state")
        XCTAssertEqual((state["dials"] as? [[String: Any]])?.first?["to"] as? String, "+12125550142", "typed without +1")
        XCTAssertEqual(state["hangups"] as? Int, 0, "the far side ended it")
        XCTAssertEqual((state["dials"] as? [[String: Any]])?.count, 1, "Leave a message only opens the pre-filled form")
        XCTAssertEqual(state["problems"] as? [String], [])
        try assertKeyOnlyInHeader(samplehost)
    }

    /// The model asks the same question twice: it shows once, and one tap answers both tool calls in one request.
    @MainActor func testPhoneCallsQuestionAskedTwice() throws {
        let samplehost = try samplehostFixture()
        let app = try phoneChat(samplehost, scenario: "asks-twice")
        try placeSimulatedCall(app, samplehost)
        let question = app.staticTexts["phone.question"]
        XCTAssertTrue(question.waitForExistence(timeout: 20))
        XCTAssertTrue(revealed(app, app.staticTexts["Let me check that for you."], timeout: 15), "the second ask has arrived")
        Thread.sleep(forTimeInterval: 2)   // a poll after the second tool call
        let shown = app.staticTexts.matching(identifier: "phone.question")
        XCTAssertTrue(revealed(app, shown.firstMatch))
        XCTAssertEqual(shown.count, 1, "shown once")
        XCTAssertEqual(shown.firstMatch.label, "Which simulated time works?")
        shot(app, "phone-live-question")
        let morning = app.buttons["Morning"]
        for _ in 0..<3 where !morning.isHittable { app.swipeUp() }
        morning.tap()
        XCTAssertTrue(revealed(app, app.staticTexts["Simulated answer received: Morning"], timeout: 15))
        XCTAssertFalse(app.staticTexts["phone.question"].exists, "both copies settled")
        let answers = try XCTUnwrap(try samplehost.control("/__fixture/state")["answers"] as? [[String: Any]])
        XCTAssertEqual(answers.count, 1, "one request")
        XCTAssertEqual(Set(answers.first?["tool_call_ids"] as? [String] ?? []), ["call_ask_1", "call_ask_2"])
        XCTAssertEqual(answers.first?["roles"] as? [String], ["tool", "tool", "system"])
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == 'You answered: Morning'")).count >= 1, true, "the You line")
        hangUp(app)
        XCTAssertTrue(app.staticTexts["You hung up"].waitForExistence(timeout: 10))
        XCTAssertEqual(try samplehost.control("/__fixture/state")["problems"] as? [String], [])
        try assertKeyOnlyInHeader(samplehost)
    }

    /// Tell the assistant: the words show as a You line at once and reach the call as the owner's message.
    @MainActor func testPhoneCallsTellTheAssistant() throws {
        let samplehost = try samplehostFixture()
        let app = try phoneChat(samplehost, scenario: "design")
        try placeSimulatedCall(app, samplehost)
        XCTAssertTrue(app.staticTexts["Hi, this is an AI assistant calling on behalf of Alex. I'd like to book a table for two tonight at 7."].waitForExistence(timeout: 20))
        XCTAssertTrue(revealed(app, app.staticTexts["phone.lag-note"]), "says once that the transcript trails the call")
        XCTAssertEqual(app.staticTexts.matching(identifier: "phone.lag-note").count, 1)
        let tell = app.textFields["phone.tell"]
        for _ in 0..<4 where !tell.isHittable { app.swipeUp() }
        tell.tap(); tell.typeText("Ask for the earliest slot.")
        XCTAssertTrue(app.buttons["phone.tell.send"].isEnabled, "Send lights up once there are words")
        tell.typeText("\n")   // the keyboard's Send key
        XCTAssertTrue(revealed(app, app.staticTexts["You told it: Ask for the earliest slot."], timeout: 5), "shown at once")
        XCTAssertTrue(revealed(app, app.staticTexts["Simulated note received: Ask for the earliest slot."], timeout: 15))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == 'You told it: Ask for the earliest slot.'")).count, 1,
                       "one You line once the conversation returns it")
        XCTAssertEqual(try samplehost.control("/__fixture/state")["told"] as? [String], ["Ask for the earliest slot."])
        shot(app, "phone-tell")
        // The chat says a call is on: closing the sheet leaves a notice above the composer, and one tap reopens it.
        app.buttons["phone.close"].tap()
        let notice = app.buttons["chat.shelf.summary"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "the chat shows the call while it is on")
        shot(app, "phone-chat-notice")
        XCTAssertTrue(notice.label.contains("On a call · "), notice.label)
        let first = notice.label
        XCTAssertTrue(waitUntil(4) { notice.label != first }, "the notice timer advances")
        XCTAssertTrue(waitUntil(35) { notice.label.contains("Call needs you") }, "the notice switches to the question")
        notice.tap()
        XCTAssertTrue(app.textFields["phone.tell"].waitForExistence(timeout: 10) || revealed(app, app.textFields["phone.tell"]),
                      "one tap on the notice opens the call sheet")
        hangUp(app)
        XCTAssertTrue(app.staticTexts["You hung up"].waitForExistence(timeout: 10))
        app.buttons["phone.close"].tap()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 10), "the notice goes when the call ends")
        XCTAssertEqual(try samplehost.control("/__fixture/state")["problems"] as? [String], [])
        try assertKeyOnlyInHeader(samplehost)
    }

    /// A busy call is still there after the app is quit and opened again: in the call sheet and in Call history.
    /// Check my setup reads the fake account and ticks every row.
    @MainActor func testPhoneCallsHistorySurvivesRelaunch() throws {
        let samplehost = try samplehostFixture()
        let app = try phoneChat(samplehost, scenario: "busy")
        try placeSimulatedCall(app, samplehost)
        XCTAssertTrue(statusText(app, prefix: "Busy").waitForExistence(timeout: 40))
        app.buttons["phone.close"].tap()
        app.terminate()

        let again = launch(environment: ["HQ_SAMPLEHOST_BASE_URL": samplehost.url + "/v2"])
        openPhoneSettings(again)
        XCTAssertTrue(again.staticTexts["Ready"].waitForExistence(timeout: 10), "the key is still there")
        let history = again.buttons["phone.settings.history"]
        for _ in 0..<4 where !history.isHittable { again.swipeUp() }
        history.tap()
        let rowEntry = again.buttons.matching(NSPredicate(format: "identifier == 'phone.history.row'")).firstMatch
        XCTAssertTrue(rowEntry.waitForExistence(timeout: 10))
        XCTAssertTrue(rowEntry.label.contains("+1 212 555 0142") && rowEntry.label.contains("Busy"), rowEntry.label)
        shot(again, "phone-history")
        rowEntry.tap()
        XCTAssertTrue(statusText(again, prefix: "Busy").waitForExistence(timeout: 10))
        again.buttons["phone.close"].tap()
        again.navigationBars.buttons.firstMatch.tap()

        let check = again.buttons["phone.settings.check"]
        for _ in 0..<4 where !check.isHittable { again.swipeUp() }
        check.tap()
        let balance = again.descendants(matching: .any)["phone.check.balance"]
        XCTAssertTrue(balance.waitForExistence(timeout: 20))
        XCTAssertTrue(balance.label.contains("$25.00"), balance.label)
        for id in ["key", "number", "connection", "profile", "country", "assistant", "model", "recording", "balance"] {
            let row = again.descendants(matching: .any)["phone.check." + id]
            XCTAssertTrue(row.exists, id)
            XCTAssertTrue(row.label.hasPrefix("OK"), "\(id): \(row.label)")
        }
        shot(again, "phone-check-setup")
        let paths = try samplehostRequests(samplehost).map { "\($0["method"] ?? "") \($0["path"] ?? "")" }
        for read in ["GET /v2/balance", "GET /v2/call_control_applications/conn-sim", "GET /v2/outbound_voice_profiles/ovp-sim"] {
            XCTAssertTrue(paths.contains(read), read)
        }
        XCTAssertEqual(try samplehost.control("/__fixture/state")["problems"] as? [String], [])
        try assertKeyOnlyInHeader(samplehost)
    }

    /// The agent proposes a call with a link in its reply. From outside the app the same link is refused; tapped in
    /// the chat it opens the call sheet filled in, nothing dials until the owner confirms, and the call's result goes
    /// back into the chat as the next message (the gateway's prompt.submit log).
    @MainActor func testPhoneCallsAgentProposal() throws {
        let samplehost = try samplehostFixture()
        let link = "phone-call?to=%2B12125550142&goal=Ask%20for%20a%20table%20for%20two%20at%207&voicemail=leave&name=Corner%20Bistro"
        try account.control("/__fixture/reset", [:])
        try account.control("/__fixture/rows", ["id": "s-garden", "set": ["messages": [
            ["role": "user", "content": "Can you call the restaurant and book a table for two at 7?"],
            ["role": "assistant", "content": "[Call +12125550142](hermes://\(link))"],
        ]]])
        let app = try phoneChat(samplehost, scenario: "busy", extra: ["-HQNDebugOpenLink", "hermeshq-native://" + link])
        // The debug hook opened the link through the system, as another app would: refused.
        let notice = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "That isn’t available on iPhone yet.")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "a call link from outside the app is refused")
        XCTAssertFalse(app.textFields["phone.to"].exists, "no sheet from outside")
        XCTAssertTrue(try samplehostRequests(samplehost).allSatisfy { ($0["path"] as? String) != "/v2/calls" })

        let proposal = app.buttons["phone.chat.proposal"]
        XCTAssertTrue(proposal.waitForExistence(timeout: 15), "drawn as a call card")
        XCTAssertTrue(proposal.label.contains("Call Corner Bistro") && proposal.label.hasSuffix("Review."))
        XCTAssertTrue(proposal.label.contains("Ask for a table for two at 7"), "the goal under it: \(proposal.label)")
        shot(app, "phone-proposal-chat")
        proposal.tap()
        let to = app.textFields["phone.to"]
        XCTAssertTrue(to.waitForExistence(timeout: 10), "the call sheet opens")
        XCTAssertTrue(app.descendants(matching: .any)["phone.suggested"].exists, "Suggested by your agent")
        XCTAssertEqual(to.value as? String, "+12125550142")
        XCTAssertEqual(app.textFields["phone.name"].value as? String, "Corner Bistro")
        let purpose = app.textFields["phone.purpose"].exists ? app.textFields["phone.purpose"] : app.textViews["phone.purpose"]
        XCTAssertEqual(purpose.value as? String, "Ask for a table for two at 7")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Leave a short message'")).firstMatch.exists)
        shot(app, "phone-proposal-sheet")
        XCTAssertTrue(try samplehostRequests(samplehost).allSatisfy { ($0["path"] as? String) != "/v2/calls" }, "a tap never dials")
        app.buttons["Review call"].tap()
        let confirm = app.buttons["phone.place"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10)); confirm.tap()
        XCTAssertTrue(statusText(app, prefix: "Busy").waitForExistence(timeout: 40))
        let dial = try XCTUnwrap((try samplehost.control("/__fixture/state")["dials"] as? [[String: Any]])?.first)
        XCTAssertEqual(dial["leaves_message"] as? Bool, true, "voicemail=leave reached the instructions")
        app.buttons["phone.close"].tap()

        // The result reaches the chat once: prompt.submit carries the whole result; the bubble shows one line.
        var submitted: [String] = []
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            let rpc = try account.control("/__fixture/state")["rpc"] as? [[String: Any]] ?? []
            submitted = rpc.filter { $0["method"] as? String == "prompt.submit" }
                .compactMap { ($0["params"] as? [String: Any])?["text"] as? String }
                .filter { $0.hasPrefix("Phone call result (sent by Hermes HQ") }
            if !submitted.isEmpty { break }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertEqual(submitted.count, 1, "the result went back to the agent")
        XCTAssertTrue(submitted.first?.contains("To: +12125550142") == true)
        XCTAssertTrue(submitted.first?.contains("Goal: Ask for a table for two at 7") == true)
        XCTAssertTrue(submitted.first?.contains("Outcome: busy") == true)
        let card = app.buttons["phone.chat.result"]
        XCTAssertTrue(card.waitForExistence(timeout: 15), "the chat shows one call result card")
        XCTAssertTrue(card.label.contains("Busy") && card.label.contains("+1 212 555 0142"))
        card.tap()
        XCTAssertTrue(statusText(app, prefix: "Busy").waitForExistence(timeout: 10), "the card opens its saved call")
        app.buttons["phone.close"].tap()
        shot(app, "phone-result-in-chat")
        Thread.sleep(forTimeInterval: 8)
        let again = (try account.control("/__fixture/state")["rpc"] as? [[String: Any]] ?? [])
            .filter { (($0["params"] as? [String: Any])?["text"] as? String)?.hasPrefix("Phone call result") == true }
        XCTAssertEqual(again.count, 1, "exactly once")
        XCTAssertEqual(try samplehost.control("/__fixture/state")["problems"] as? [String], [])
        try assertKeyOnlyInHeader(samplehost)
    }

    @MainActor func testPhoneCallsRingingCancel() throws {
        let samplehost = try samplehostFixture()
        let app = try phoneChat(samplehost, scenario: "ringing")
        try placeSimulatedCall(app, samplehost)
        let cancel = app.buttons["Cancel call"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        XCTAssertTrue(statusText(app, prefix: "Ringing").exists)
        XCTAssertGreaterThanOrEqual(cancel.frame.height, 44)
        cancel.tap()
        XCTAssertTrue(statusText(app, prefix: "No answer").waitForExistence(timeout: 20))
        XCTAssertFalse(cancel.exists)
        XCTAssertEqual(try samplehost.control("/__fixture/state")["hangups"] as? Int, 1)
        try assertKeyOnlyInHeader(samplehost)
    }

    @MainActor func testPhoneCallsDesignLight() throws { try phoneDesign(dark: false) }
    @MainActor func testPhoneCallsDesignDark() throws { try phoneDesign(dark: true) }

    @MainActor private func phoneDesign(dark: Bool) throws {
        let samplehost = try samplehostFixture()
        let mode = dark ? "dark" : "light"
        let link = "hermes://phone-call?to=%2B12125550142&goal=Book%20a%20table%20for%20two%20at%207%20tonight"
        try account.control("/__fixture/rows", ["id": "s-garden", "set": ["messages": [
            ["role": "user", "content": "Call Corner Bistro and book a table for two at 7"],
            ["role": "assistant", "content": "[Call +12125550142](\(link))"],
        ]]])
        let app = try phoneChat(samplehost, scenario: "ringing", extra: ["-HQDebugAppearance", mode])
        try placeSimulatedCall(app, samplehost, goal: "Book a table for two at 7 tonight", name: "Corner Bistro")
        XCTAssertTrue(app.buttons["Cancel call"].waitForExistence(timeout: 10))
        shot(app, "phone-1-ringing-\(mode)")
        app.buttons["Cancel call"].tap()
        XCTAssertTrue(statusText(app, prefix: "No answer").waitForExistence(timeout: 20))
        app.buttons["Call again"].tap()
        XCTAssertEqual(app.textFields["phone.to"].value as? String, "+12125550142")
        XCTAssertEqual(app.textFields["phone.name"].value as? String, "Corner Bistro")
        let purpose = app.textViews["phone.purpose"].exists ? app.textViews["phone.purpose"] : app.textFields["phone.purpose"]
        XCTAssertEqual(purpose.value as? String, "Book a table for two at 7 tonight")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Hang up'")).firstMatch.exists, "same voicemail choice")
        shot(app, "phone-new-call-\(mode)")
        try samplehost.control("/__fixture/scenario", ["name": "design", "summary_delay": 5])
        app.buttons["Review call"].tap()
        let confirm = app.buttons["phone.place"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertEqual((try samplehost.control("/__fixture/state")["dials"] as? [[String: Any]])?.count, 1)
        confirm.tap()
        XCTAssertTrue(statusText(app, prefix: "On the call").waitForExistence(timeout: 12))
        let newest = app.staticTexts["Let me check with Alex, one moment."]
        XCTAssertTrue(newest.waitForExistence(timeout: 12))
        let tell = app.textFields["phone.tell"]
        tell.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(tell.isHittable && app.buttons["Hang up"].isHittable)
        XCTAssertTrue(newest.isHittable, "the newest line stays above the keyboard")
        shot(app, "phone-keyboard-\(mode)")
        tell.typeText("Ask for a quiet table.\n")
        XCTAssertTrue(app.staticTexts["You told it: Ask for a quiet table."].waitForExistence(timeout: 10))
        if app.keyboards.firstMatch.exists { app.staticTexts["phone.call.status"].tap() }
        shot(app, "phone-2-live-\(mode)")
        let question = app.staticTexts["phone.question"]
        XCTAssertTrue(question.waitForExistence(timeout: 35))
        XCTAssertEqual(question.label, "7:15 or 8:00 tonight?")
        let choice = app.buttons["7:15"]
        XCTAssertGreaterThanOrEqual(choice.frame.height, 44)
        shot(app, "phone-3-question-\(mode)")
        choice.tap()
        XCTAssertTrue(app.staticTexts["You answered: 7:15"].waitForExistence(timeout: 10))
        XCTAssertFalse(question.exists)
        XCTAssertEqual((try samplehost.control("/__fixture/state")["answers"] as? [[String: Any]])?.count, 1, "one tap sent one answer")
        hangUp(app)
        let summary = app.staticTexts["phone.call.summary"]
        XCTAssertTrue(statusText(app, prefix: "Finished").waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil(20) { summary.exists && summary.label.contains("Corner Bistro booked a table for two at 7:15 under Alex.") })
        XCTAssertTrue(app.staticTexts["WHAT HAPPENED"].exists)
        XCTAssertTrue(try samplehostRequests(samplehost).contains { ($0["path"] as? String)?.hasSuffix("/conversations-insights") == true })
        let delivered = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS 'Sent to chat' AND label CONTAINS 'Yes'")).firstMatch
        XCTAssertTrue(delivered.waitForExistence(timeout: 20))
        shot(app, "phone-4-summary-\(mode)")
        app.buttons["Transcript"].tap()
        XCTAssertTrue(app.staticTexts["Transcript"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["You answered: 7:15"].exists)
        XCTAssertFalse(app.textFields["phone.tell"].exists)
        shot(app, "phone-transcript-\(mode)")
        app.buttons["sheet.back"].tap()
        app.buttons["phone.close"].tap()
        let result = app.buttons.matching(identifier: "phone.chat.result").matching(NSPredicate(format: "label BEGINSWITH 'Call finished'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 35))
        XCTAssertTrue(result.label.contains("Corner Bistro booked a table for two at 7:15 under Alex."))
        let proposal = app.buttons["phone.chat.proposal"]
        XCTAssertTrue(proposal.exists && proposal.label.hasSuffix("Review."))
        result.tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        app.buttons["phone.close"].tap()
        try samplehost.control("/__fixture/scenario", ["name": "live"])
        try placeSimulatedCall(app, samplehost, goal: "Book a table for two at 7 tonight", previousCalls: 2)
        XCTAssertTrue(statusText(app, prefix: "On the call").waitForExistence(timeout: 12))
        app.buttons["phone.close"].tap()
        let timer = app.buttons["chat.shelf.summary"]
        XCTAssertTrue(timer.waitForExistence(timeout: 10))
        XCTAssertTrue(timer.label.contains("On a call · "), timer.label)
        XCTAssertGreaterThan(timer.frame.width, app.frame.width * 0.8, "the notice spans the chat")
        XCTAssertGreaterThanOrEqual(timer.frame.height, 44)
        shot(app, "phone-6-chat-\(mode)")
        timer.tap()
        XCTAssertTrue(app.buttons["Hang up"].waitForExistence(timeout: 10))
        hangUp(app)
        XCTAssertTrue(app.staticTexts["You hung up"].waitForExistence(timeout: 10))
        app.buttons["phone.close"].tap()
        try samplehost.control("/__fixture/scenario", ["name": "voicemail"])
        try placeSimulatedCall(app, samplehost, goal: "Book a table for two at 7 tonight", previousCalls: 3)
        XCTAssertTrue(statusText(app, prefix: "Went to voicemail").waitForExistence(timeout: 25))
        XCTAssertTrue(app.staticTexts["WHY"].exists)
        shot(app, "phone-5-voicemail-\(mode)")
        try assertKeyOnlyInHeader(samplehost)
    }

    @MainActor func testPhoneCallsLargeText() throws {
        let samplehost = try samplehostFixture()
        let goal = "Please book a quiet table for two this weekend. Ask about the dining room away from the entrance, and check whether a later time is available if the first seating is full."
        let name = "Corner Bistro and the Quiet Dining Room on the Second Floor"
        let app = try phoneChat(samplehost, scenario: "long")
        try placeSimulatedCall(app, samplehost, goal: goal, name: name)
        XCTAssertTrue(app.staticTexts["phone.call.goal"].waitForExistence(timeout: 8))
        shot(app, "phone-long-name-goal")
        XCTAssertTrue(app.staticTexts["phone.question"].waitForExistence(timeout: 25))
        for text in ["Main room at 7:15", "Main room at 8:00", "Quiet room tomorrow", "Ask about next week"] {
            XCTAssertTrue(app.buttons[text].isHittable, text)
        }
        shot(app, "phone-long-question-four-choices")
        app.buttons["phone.close"].tap()
        app.terminate()
        let large = launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"],
                           environment: ["HQ_SAMPLEHOST_BASE_URL": samplehost.url + "/v2"])
        row(large, "s-garden").tap()
        let notice = large.buttons["chat.shelf.summary"]
        if !notice.waitForExistence(timeout: 10) { shot(large, "phone-accessibility-chat-entry") }
        XCTAssertTrue(notice.exists, "the active call is reachable from the chat shelf after relaunch")
        notice.tap()
        XCTAssertTrue(large.textFields["phone.tell"].waitForExistence(timeout: 12))
        XCTAssertTrue(waitUntil(7) { large.staticTexts["phone.question"].isHittable },
                      "the question starts in view at the largest text size")
        XCTAssertTrue(large.buttons["Hang up"].isHittable, "the dock remains reachable at the largest text size")
        shot(large, "phone-accessibility-text")
        hangUp(large)
        XCTAssertTrue(statusText(large, prefix: "Finished").waitForExistence(timeout: 30))
        try assertKeyOnlyInHeader(samplehost)
    }

}
