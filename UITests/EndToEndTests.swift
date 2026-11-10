// End-to-end tests of the real app against the performance fixture (docs/spec/05-fixtures-release.md §A5, §A12).
// Run with scripts/e2e.sh: it starts the fixture, passes its credentials file as TEST_RUNNER_HQN_UI_CREDENTIALS
// (the runner sees HQN_UI_CREDENTIALS) and stops the fixture afterwards. Without that variable every test skips.
//
// Each test stands alone (it signs in when the app shows the sign-in form); the first starts from a clean phone.

import XCTest

struct FixtureAccount {
    let url: String
    let username: String
    let password: String

    static func load() throws -> FixtureAccount {
        guard let path = ProcessInfo.processInfo.environment["HQN_UI_CREDENTIALS"], !path.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_HQN_UI_CREDENTIALS to the performance fixture's credentials file (scripts/e2e.sh does).")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = object["url"] as? String, let username = object["username"] as? String,
              let password = object["password"] as? String else { throw XCTSkip("Unreadable credentials file") }
        return FixtureAccount(url: url, username: username, password: password)
    }

    /// A fixture control (`/__fixture/…`, no auth). Blocks the calling thread for at most 10 s.
    @discardableResult
    func control(_ path: String, _ body: [String: Any]? = nil) throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url + path)!, timeoutInterval: 10)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            box.data = data; box.status = (response as? HTTPURLResponse)?.statusCode; box.error = error
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 12)
        if let error = box.error { throw error }
        guard let status = box.status, (200..<300).contains(status) else {
            throw NSError(domain: "fixture", code: box.status ?? -1, userInfo: [NSLocalizedDescriptionKey: "\(path) answered \(box.status ?? -1)"])
        }
        return (box.data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    private final class ResultBox: @unchecked Sendable {
        var data: Data?
        var status: Int?
        var error: Error?
    }
}

final class EndToEndTests: XCTestCase {
    static let bigChatRows = 5000
    static let botRow = "bot-row-default"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: (a) Sign in

    /// A clean phone: type the fixture's address, the password fields appear, sign in, the Bots list shows.
    @MainActor func test1_SignInShowsBots() throws {
        let account = try FixtureAccount.load()
        let app = XCUIApplication()
        app.launchArguments = ["-HQDebugResetAccounts", "YES"]
        app.launch()
        signIn(app, account)
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 15), "the Bots list shows after sign-in")
        XCTAssertTrue(app.cells[Self.botRow].waitForExistence(timeout: 15), "the fixture's Hermes bot is listed")
        XCTAssertTrue(app.cells["bot-row-ivy"].exists, "the fixture's Ivy bot is listed")
    }

    // MARK: (b) The 5,000-row chat

    /// Opens the big chat: content in the push's first frames, a fast scroll up through several screens, then the jump
    /// button back to the newest message.
    @MainActor func test2_BigChatOpensAndScrolls() throws {
        let account = try FixtureAccount.load()
        let seeded = try account.control("/__fixture/history", ["profile": "default", "count": Self.bigChatRows, "non_dense": true])
        XCTAssertEqual(seeded["rows"] as? Int, Self.bigChatRows)
        let app = launchSignedIn(account)
        let table = openChat(app)

        let firstContent = try firstContentMilliseconds(table)
        XCTAssertLessThan(firstContent.ms, 600, "the chat shows content during the push (\(firstContent))")
        let newest = message(in: app, containing: "Synthetic history row \(Self.bigChatRows - 1).")
        XCTAssertTrue(newest.waitForExistence(timeout: 10), "the newest message shows")

        // Fast flicks up through history: older pages load as the reader nears the top.
        for _ in 0..<8 { table.swipeDown(velocity: .fast) }
        // Any row at least 20 messages older than the newest (row numbers 0…4979).
        let older = table.descendants(matching: .any).matching(NSPredicate(format: "label MATCHES %@",
            "(?s).*Synthetic history row ([0-9]{1,3}|[0-3][0-9]{3}|4[0-8][0-9]{2}|49[0-7][0-9])\\..*")).firstMatch
        XCTAssertTrue(older.waitForExistence(timeout: 10), "older history shows after scrolling up")
        XCTAssertFalse(isOnScreen(newest, in: table), "the newest message scrolled away")

        let jump = app.descendants(matching: .any)["chat.jump"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5), "the jump button shows while scrolled up")
        jump.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.isOnScreen(newest, in: table) }, "the jump brings the newest message back")
    }

    // MARK: (c) Send, stream, Stop

    /// Type, send, the reply streams and grows, Stop mid-stream stops it.
    @MainActor func test3_SendStreamsAndStops() throws {
        let account = try FixtureAccount.load()
        let app = launchSignedIn(account)
        let table = openChat(app)
        _ = table
        // The next prompt streams 400 words over ~16 s (spec 05 §A4 plans). Queued once the chat is open: a test that
        // fails before it sends leaves no plan behind for the next one (verify round 1).
        try account.control("/__fixture/plan", ["plans": [["chunks": Array(repeating: "word ", count: 400), "chunkDelay": 0.04]]])

        let text = "Hello from the UI test \(Int(Date().timeIntervalSince1970) % 100_000)"
        let field = app.textViews["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // The empty composer's circle is named for VoiceOver from the start (verify round 1: unnamed until typing).
        // [talk] It is Talk where a conversation can start (docs/spec/3x-talk.md §5.1), else the disabled Send.
        let idleTalk = app.buttons["composer.talk"], idleSend = app.buttons["composer.send"]
        if idleTalk.exists {
            XCTAssertTrue(idleTalk.label.hasPrefix("Talk with "), "Talk is named (\(idleTalk.label))")
        } else {
            XCTAssertTrue(idleSend.exists && idleSend.label == "Send", "the disabled Send is named")
        }
        field.tap()
        clearDraft(field)
        field.typeText(text)
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        send.tap()

        XCTAssertTrue(message(in: app, containing: text).waitForExistence(timeout: 5), "the sent message shows")
        let stop = app.buttons["composer.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "Stop shows while the reply runs")

        let reply = message(in: app, containing: "said: word word")
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "the reply starts streaming")
        let early = reply.label.count
        XCTAssertTrue(waitUntil(timeout: 5) { reply.label.count > early + 20 }, "the streaming reply grows")
        measured("reply grew from \(early) to \(reply.label.count) characters while streaming")

        stop.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { !stop.exists }, "Stop goes away once the turn ends")
        let state = try account.control("/__fixture/state")
        XCTAssertEqual((state["running"] as? [String: Bool])?["default"], false, "the gateway's turn was interrupted")
        let rpcs = (state["rpc"] as? [[String: Any]])?.compactMap { $0["method"] as? String } ?? []
        XCTAssertTrue(rpcs.contains("session.interrupt"), "Stop sent session.interrupt")
        // Nothing more arrives: the text stays as it is.
        let settled = message(in: app, containing: "said:").label
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(message(in: app, containing: "said:").label, settled, "the reply stopped growing")
    }

    // MARK: (d) Relaunch from cache

    /// Kill and relaunch: still signed in, and the chat reopens from the disk cache before the network answers.
    @MainActor func test4_RelaunchKeepsSignInAndCache() throws {
        let account = try FixtureAccount.load()
        var app = launchSignedIn(account)
        var table = openChat(app)
        XCTAssertTrue(table.cells.firstMatch.waitForExistence(timeout: 10))
        // Back to the list (the chat saves its tail as it leaves), then kill the app.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.cells[Self.botRow].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.0)
        app.terminate()

        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.cells[Self.botRow].waitForExistence(timeout: 10), "still signed in: the Bots list shows")
        XCTAssertFalse(app.textFields["sign-in-address"].exists, "no sign-in form")
        table = openChat(app)
        let firstContent = try firstContentMilliseconds(table)
        XCTAssertGreaterThan(firstContent.rowsAtInit, 0, "the chat was painted from the cache before the push (\(firstContent))")
        XCTAssertLessThan(firstContent.ms, 400, "cached content shows at once (\(firstContent))")
    }

    // MARK: (e) Sessions tab and Sign Out

    /// The Sessions tab lists the gateway's chats; Sign Out from Settings › Gateway returns to the sign-in form, and a
    /// relaunch stays signed out.
    @MainActor func test5_SessionsThenSignOut() throws {
        let account = try FixtureAccount.load()
        var app = launchSignedIn(account)
        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.collectionViews["sessions.list"].waitForExistence(timeout: 5), "the Sessions list shows")
        // Settings stream: Sign Out lives in Settings › Gateway (the M1 Account sheet is retired). Settings is reached
        // from More, as on the web (the Bots bar has no Settings button since 6684708).
        app.tabBars.buttons["More"].tap()
        let settingsRow = app.cells["more-row-settings"]
        XCTAssertTrue(settingsRow.waitForExistence(timeout: 5))
        settingsRow.tap()
        let card = app.buttons["settings.gateway-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), "Settings opens")
        card.tap()
        let signOut = app.buttons["gateway.sign-out"].firstMatch
        XCTAssertTrue(signOut.waitForExistence(timeout: 5), "the Gateway page shows Sign Out")
        signOut.tap()
        // The confirmation dialog's own Sign Out button (an action sheet; else the newest "Sign Out" on screen).
        let sheetButton = app.sheets.buttons["Sign Out"]
        if sheetButton.waitForExistence(timeout: 3) {
            sheetButton.tap()
        } else {
            let all = app.buttons.matching(NSPredicate(format: "label == 'Sign Out'"))
            XCTAssertTrue(waitUntil(timeout: 3) { all.count >= 2 }, "the confirmation shows")
            all.element(boundBy: all.count - 1).tap()
        }
        XCTAssertTrue(app.textFields["sign-in-address"].waitForExistence(timeout: 10), "back to the sign-in form")
        app.terminate()
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.textFields["sign-in-address"].waitForExistence(timeout: 10), "still signed out after a relaunch")
    }

    // MARK: (f) A refused send: one reason, Details and ✕ (spec 06 §5.6.1)

    @MainActor func test6_RefusedSendShowsOneCardAndDismiss() throws {
        let account = try FixtureAccount.load()
        let reason = "Model provider is out of credits. Add credits or switch models, then try again."
        let app = launchSignedIn(account)
        _ = openChat(app)
        try account.control("/__fixture/plan", ["plans": [["reject": reason, "code": 4000]]])
        let field = app.textViews["composer.text"]
        send(app, "please refuse this", account)

        // A refused send says why in the "Couldn’t Send" card at the composer (build 258), not as a card in the transcript.
        let card = app.descendants(matching: .any)["chat.sendFailure"]
        XCTAssertTrue(card.waitForExistence(timeout: 8), "the Couldn’t Send card shows")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "out of credits")).firstMatch.exists, "the card shows the reason")
        XCTAssertEqual((field.value as? String) ?? "", "please refuse this", "the words came back to the field")
        attachScreenshot(app, "refused-card")

        let close = app.buttons["chat.sendFailure.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 3), "the card has a ✕")
        close.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { !card.exists }, "✕ removes the card")
        // The refused words stay in the field as the chat's draft: leave the chat clean for the tests after this one.
        field.tap()
        clearDraft(field)
    }

    // MARK: (g) ⋯ and the title open Info (spec 06 §4.1)

    @MainActor func test7_ChatMenuAndTitleOpenInfo() throws {
        let account = try FixtureAccount.load()
        let app = launchSignedIn(account)
        _ = openChat(app)
        let more = app.navigationBars.buttons["chat.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), "the chat bar has ⋯")
        more.tap()
        let info = app.buttons["Info"].firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 3), "⋯ offers Info")
        // m2 (menus, spec 1x-menus §4.1): the ⋯ tiles are Share and Info.
        XCTAssertTrue(app.buttons["chat.more.share"].firstMatch.exists || app.buttons["Share"].firstMatch.exists, "⋯ offers Share")
        info.tap()
        XCTAssertTrue(app.staticTexts["Chat ID"].waitForExistence(timeout: 3), "Info lists the session id")
        attachScreenshot(app, "chat-info")
        app.navigationBars["Chat Info"].buttons.firstMatch.tap()   // the sheet is "Chat Info" (UX study #178; the web says "Session Info")
        XCTAssertTrue(waitUntil(timeout: 3) { !app.staticTexts["Chat ID"].exists })
    }

    // MARK: (h) A tool step opens its sheet (spec 03 §8.8, spec 06 §3.3)

    @MainActor func test8_ToolStepSheet() throws {
        let account = try FixtureAccount.load()
        // Written for Rows: One Line (the default since 7175e1b) folds the step into the reply's "Worked for…" line.
        let app = launchSignedIn(account, args: ["-hq.chat.toolCallStyle", "rows"])
        _ = openChat(app)
        try account.control("/__fixture/plan", ["plans": [["tools": 1, "chunks": ["Done."]]]])
        send(app, "run one step", account)
        let step = app.tables["chat.table"].buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ran'")).firstMatch
        XCTAssertTrue(step.waitForExistence(timeout: 10), "the tool row shows")
        XCTAssertTrue(waitUntil(timeout: 10) { !app.buttons["composer.stop"].exists }, "the turn ends")
        step.tap()
        // m2 (activity, spec 1x-activity §12): a command's step sheet is titled "Terminal" (other steps: their title).
        let sheet = app.navigationBars.matching(NSPredicate(format: "identifier IN %@", ["Terminal", "Step"])).firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 3), "the step sheet opens")
        XCTAssertTrue(app.staticTexts["Command"].waitForExistence(timeout: 3), "it labels the command block")
        attachScreenshot(app, "step-sheet")
        sheet.buttons.firstMatch.tap()
    }

    // MARK: (i) An ended session says so on the sign-in form (spec 01 §5)

    @MainActor func test9_EndedSessionSaysSo() throws {
        let account = try FixtureAccount.load()
        var app = launchSignedIn(account)
        app.terminate()
        try account.control("/__fixture/revoke", [:])
        app = XCUIApplication()
        app.launch()
        // [offline] Row L944 (docs/spec/3x-offline.md §5.2): with the saved lists already on screen the ended session
        // is said in an alert first, and "Sign in again" opens the form; while the launch screen is still up the app
        // goes straight to the form as before. Either way the form says why.
        let notice = app.alerts["Sign In Again"]
        let form = app.textFields["sign-in-address"]
        XCTAssertTrue(waitUntil(timeout: 25) { notice.exists || form.exists }, "the ended session is said")
        if notice.exists { notice.buttons["Sign In Again"].tap() }
        // UX study #127: said as a notice, not a failure.
        let error = app.descendants(matching: .any)["sign-in-notice"]
        XCTAssertTrue(app.textFields["sign-in-address"].waitForExistence(timeout: 15), "back to the sign-in form")
        XCTAssertTrue(error.waitForExistence(timeout: 5), "the form says why")
        XCTAssertTrue(error.label.contains("session on this Hermes ended"), "…in the ended-session words (\(error.label))")
        attachScreenshot(app, "session-ended")
        signIn(app, account)
        XCTAssertTrue(app.cells[Self.botRow].waitForExistence(timeout: 15), "signing in again works")
    }

    // MARK: (j) Right after a fresh sign-in, a chat still opens painted (the warm pass, spec 03 §4.1)

    @MainActor func test10_FreshSignInChatOpensPainted() throws {
        let account = try FixtureAccount.load()
        let app = XCUIApplication()
        app.launchArguments = ["-HQDebugResetAccounts", "YES"]
        app.launch()
        signIn(app, account)
        XCTAssertTrue(app.cells[Self.botRow].waitForExistence(timeout: 15), "the Bots list shows")
        // A person finds the row and taps it. HQN_UI_OPEN_WAIT changes the wait (a slow-link run through a delay proxy).
        let wait = ProcessInfo.processInfo.environment["HQN_UI_OPEN_WAIT"].flatMap(Double.init) ?? 1.5
        Thread.sleep(forTimeInterval: wait)
        // On a slow link the "Save Password?" offer comes up after the sign-in's own check has passed: decline it.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for candidate in [app.buttons["Not Now"], springboard.buttons["Not Now"]] where candidate.exists { candidate.tap() }
        let table = openChat(app)
        let firstContent = try firstContentMilliseconds(table)
        XCTAssertGreaterThan(firstContent.rowsAtInit, 0, "the warm pass saved the chat before the tap (\(firstContent))")
    }

    // MARK: (k) Verify round 3: a queued message outlives leaving the chat

    /// Queued behind a running reply, a message is still there when the chat is reopened mid-reply, and goes out when
    /// the reply ends while the chat is left (the web drains a chat in the background).
    @MainActor func test11_QueuedMessageOutlivesLeavingTheChat() throws {
        let account = try FixtureAccount.load()
        let app = launchSignedIn(account)
        _ = openChat(app)
        try account.control("/__fixture/plan", ["plans": [["chunks": Array(repeating: "slow ", count: 140), "chunkDelay": 0.1],
                                                          ["replyText": "Reply to the queued one."]]])
        let stamp = Int(Date().timeIntervalSince1970) % 100_000
        send(app, "long one \(stamp)", account)
        let stop = app.buttons["composer.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 8), "the reply runs")
        let queued = "queued then left \(stamp)"
        let field = app.textViews["composer.text"]
        if app.keyboards.count == 0 { field.tap() }
        field.typeText(queued)
        let sendButton = app.buttons["composer.send"]
        XCTAssertTrue(waitUntil(timeout: 3) { sendButton.exists && sendButton.isEnabled })
        IPad.pressReturn(app, .command)                       // ⌘Return queues; a plain send would go into the reply
        let card = app.descendants(matching: .any)["chat.queue"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), "the queue card shows")
        func back() {
            let button = app.navigationBars.buttons["BackButton"].firstMatch
            (button.exists ? button : app.navigationBars.buttons.element(boundBy: 0)).tap()
            XCTAssertTrue(app.cells[Self.botRow].waitForExistence(timeout: 5), "back on the Bots list")
        }
        back()
        _ = openChat(app)
        XCTAssertTrue(card.waitForExistence(timeout: 5), "reopened mid-reply, the queue card is still there")
        back()
        let users = { () -> [String] in
            let state = (try? account.control("/__fixture/state")) ?? [:]
            let messages = ((state["messages"] as? [String: Any])?["default"] as? [[String: Any]]) ?? []
            return messages.filter { $0["role"] as? String == "user" }.compactMap { $0["content"] as? String }
        }
        XCTAssertTrue(waitUntil(timeout: 40) { users().contains(queued) }, "it went out while the chat was left")
        _ = openChat(app)
        XCTAssertTrue(message(in: app, containing: queued).waitForExistence(timeout: 8), "reopened, it is in the chat")
        XCTAssertTrue(waitUntil(timeout: 15) { !card.exists && !stop.exists }, "no queue left, the turn over")
    }

    // MARK: - Helpers

    /// Types into the composer and taps Send; a tap the keyboard's settling swallowed is tried once more (only while
    /// the words are still in the field, so nothing is sent twice).
    @MainActor private func send(_ app: XCUIApplication, _ text: String, _ account: FixtureAccount) {
        let field = app.textViews["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        clearDraft(field)
        field.typeText(text)
        let button = app.buttons["composer.send"]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        let attempts = { ((try? account.control("/__fixture/state"))?["promptAttempts"] as? Int) ?? 0 }
        let before = attempts()
        button.tap()
        // The gateway's own count says whether the prompt went out.
        if !waitUntil(timeout: 3, { attempts() > before }) { button.tap() }
    }

    /// iOS offers to save the typed password after a sign-in: decline, so the alert never takes the next tap. It can
    /// take a few seconds to come up (verify round 1: a 2 s wait missed it and it covered the Bots list).
    @MainActor private func dismissSavePassword(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let passwords = XCUIApplication(bundleIdentifier: "com.apple.Passwords")
        let candidates = [app.buttons["Not Now"], springboard.buttons["Not Now"], passwords.buttons["Not Now"]]
        _ = waitUntil(timeout: 6) { candidates.contains { $0.exists } }
        candidates.first { $0.exists }?.tap()
    }

    /// Empties the composer of a draft an earlier test left (a refused send hands its words back to the field).
    @MainActor private func clearDraft(_ field: XCUIElement) {
        let value = (field.value as? String) ?? ""
        guard !value.isEmpty, !value.hasPrefix("Message") else { return }
        // The caret goes to the end first (a tap at the field's far end), so the deletes take the whole draft.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count + 2))
    }

    @MainActor private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor private func signIn(_ app: XCUIApplication, _ account: FixtureAccount) {
        let address = app.textFields["sign-in-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 15), "the sign-in form shows")
        address.tap()
        if let current = address.value as? String, !current.isEmpty, current != "my-mac.tail1234.ts.net" {
            address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        address.typeText(account.url)
        let username = app.textFields["sign-in-username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10), "the password fields show for the address")
        username.tap()
        if let current = username.value as? String, !current.isEmpty, current != "Username" {
            // An ended session prefills the username.
            username.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        username.typeText(account.username)
        let password = app.secureTextFields["sign-in-password"]
        password.tap()
        password.typeText(account.password)
        app.buttons["sign-in-password-button"].tap()
        dismissSavePassword(app)
    }

    /// Launches the app (with `args`); signs in when the form shows instead of the Bots list.
    @MainActor private func launchSignedIn(_ account: FixtureAccount, args: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = args
        app.launch()
        let row = app.cells[Self.botRow]
        let form = app.textFields["sign-in-address"]
        // [offline] Row L944: a saved sign-in from an earlier run of the stand-in is refused, and with saved lists on
        // screen the app says so in an alert whose "Sign in again" opens the form.
        let ended = app.alerts["Sign In Again"]
        _ = waitUntil(timeout: 15) { ended.exists || form.exists || row.exists }
        if !form.exists, ended.waitForExistence(timeout: row.exists ? 4 : 0.1) {
            ended.buttons["Sign In Again"].tap()
            _ = form.waitForExistence(timeout: 10)
        }
        if form.exists { signIn(app, account) }
        // m2 (pages, spec 1x-pages §1.3): a relaunch reopens the tab last left; these checks start on Bots.
        let botsTab = app.buttons["tab-bots"]
        if !row.waitForExistence(timeout: 3), botsTab.exists { botsTab.tap() }
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the Bots list shows")
        return app
    }

    @MainActor private func openChat(_ app: XCUIApplication) -> XCUIElement {
        let row = app.cells[Self.botRow]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let table = app.tables["chat.table"]
        if !table.waitForExistence(timeout: 4) {
            // iOS 27's "Save Password?" card (shown by the Passwords service, out of the runner's reach) can come up a
            // second after the list and take the tap that dismisses it: tap once more (verify round 1).
            dismissSavePassword(app)
            row.tap()
        }
        XCTAssertTrue(table.waitForExistence(timeout: 5), "the chat opens")
        return table
    }

    /// The app's own measure (DEBUG): milliseconds from building the chat screen to its first cell, and how many rows
    /// the cache painted before the push.
    @MainActor private func firstContentMilliseconds(_ table: XCUIElement) throws -> (ms: Double, rowsAtInit: Int) {
        var value = ""
        _ = waitUntil(timeout: 10) {
            value = (table.value as? String) ?? ""
            return value.contains("first-content-ms=")
        }
        var ms: Double?, rows: Int?
        for part in value.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            if pair[0] == "first-content-ms" { ms = Double(pair[1]) }
            if pair[0] == "rows-at-init" { rows = Int(pair[1]) }
        }
        guard let ms, let rows else {
            XCTFail("no first-content measure on the chat table (value: \(value))")
            throw XCTSkip("no measure")
        }
        measured("first content \(Int(ms)) ms after building the chat screen; \(rows) rows painted before the push")
        return (ms, rows)
    }

    /// A measurement, kept in the result bundle as a named activity (scripts/e2e.sh prints them).
    private func measured(_ text: String) {
        XCTContext.runActivity(named: "[measure] " + text) { _ in }
    }

    @MainActor private func message(in app: XCUIApplication, containing text: String) -> XCUIElement {
        app.tables["chat.table"].descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor private func isOnScreen(_ element: XCUIElement, in table: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame, bounds = table.frame
        return !frame.isEmpty && frame.intersects(bounds) && frame.maxY > bounds.minY + 80 && frame.minY < bounds.maxY - 120
    }

    @MainActor @discardableResult
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}
