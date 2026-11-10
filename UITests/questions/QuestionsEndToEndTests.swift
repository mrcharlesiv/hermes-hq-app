// Stream "questions" UI checks 16–21 (docs/spec/1x-questions.md §7.3) against the questions fixture:
//   HQN_E2E_FIXTURE=questions HQN_E2E_PORT=9721 scripts/e2e.sh <udid>
// scripts/e2e.sh starts scripts/fixtures/questions-gateway.py and passes its credentials (TEST_RUNNER_HQN_UI_CREDENTIALS)
// and TEST_RUNNER_HQN_UI_QUESTIONS=1; without them every test here skips. Screens are attached to the result bundle
// (`xcresulttool export attachments`) for the look checks.

import XCTest

final class QuestionsEndToEndTests: XCTestCase {
    var account: FixtureAccount!
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["HQN_UI_QUESTIONS"] == "1" else {
            throw XCTSkip("Run with HQN_E2E_FIXTURE=questions scripts/e2e.sh (the questions fixture).")
        }
        account = try FixtureAccount.load()
        try account.control("/__fixture/reset", [:])
    }

    // MARK: 16. Approval card: Reject, Run, More… › Allow for This Chat, Always Allow… › confirm

    @MainActor func test16_ApprovalCardAnswersEachChoiceOnce() throws {
        launch()
        openChat()
        let choices: [(String, (XCUIApplication) -> Void)] = [
            ("deny", { $0.buttons["approval.reject"].tap() }),
            ("once", { $0.buttons["approval.run"].tap() }),
            ("session", { app in
                app.buttons["approval.more"].tap()
                let item = app.buttons["Allow for This Chat"]
                XCTAssertTrue(item.waitForExistence(timeout: 5), "More… opens its menu")
                self.attach("approval-more-menu")
                item.tap()
            }),
            ("always", { app in
                app.buttons["approval.more"].tap()
                let item = app.buttons["Always Allow…"]
                XCTAssertTrue(item.waitForExistence(timeout: 5))
                item.tap()
                let alert = app.alerts["Always Allow This Command?"]
                XCTAssertTrue(alert.waitForExistence(timeout: 5), "Always allow asks first")
                self.attach("approval-always-confirm")
                alert.buttons["Always Allow"].tap()
            }),
        ]
        for (index, (choice, act)) in choices.enumerated() {
            send("please approve \(index)")
            XCTAssertTrue(app.buttons["approval.run"].waitForExistence(timeout: 15), "the approval card shows")
            XCTAssertTrue(status("Waiting for your approval").waitForExistence(timeout: 5), "the header says it waits")
            if index == 0 { attach("approval-card") }
            act(app)
            XCTAssertTrue(waitUntil(timeout: 10) { !self.app.buttons["approval.run"].exists }, "the card goes after \(choice)")
            XCTAssertTrue(waitUntil(timeout: 10) {
                (try? self.ledger("approval").last?["outcome"] as? String) == "answered"
            }, "the gateway got the \(choice) answer")
            let request = try XCTUnwrap(try ledger("approval").last)
            let answers = request["answers"] as? [[String: Any]] ?? []
            XCTAssertEqual(answers.count, 1, "answered exactly once")
            XCTAssertEqual((answers.first?["result"] as? [String: Any])?["choice"] as? String, choice)
            XCTAssertTrue(waitUntil(timeout: 10) { !self.status("Waiting for your approval").exists }, "the waiting words go")
            XCTAssertTrue(waitUntil(timeout: 15) { !self.app.buttons["composer.stop"].exists }, "the turn ends")
        }
    }

    // MARK: 16b. Verify round 3: the Always allow confirm goes when another client answers first

    /// The confirm for a permanent allowlist rule closes as soon as the approval is answered elsewhere, so nothing can
    /// be "allowed" (with the success tap) after the fact; this phone sends nothing.
    @MainActor func test16b_AlwaysAllowConfirmClosesWhenAnsweredElsewhere() throws {
        launch()
        openChat()
        send("please approve elsewhere")
        XCTAssertTrue(app.buttons["approval.run"].waitForExistence(timeout: 15), "the approval card shows")
        app.buttons["approval.more"].tap()
        let item = app.buttons["Always Allow…"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        let alert = app.alerts["Always Allow This Command?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Always allow asks first")
        let open = try account.control("/__fixture/requests")["open"] as? [String] ?? []
        let id = try XCTUnwrap(open.first, "the approval is open on the gateway")
        try account.control("/__fixture/answer", ["id": id, "result": ["choice": "deny"]])
        XCTAssertTrue(waitUntil(timeout: 6) { !alert.exists }, "the confirm closes once another client answered")
        XCTAssertTrue(waitUntil(timeout: 6) { !self.app.buttons["approval.run"].exists }, "and the card goes")
        attach("always-confirm-after-other-answer")
        let request = try XCTUnwrap(try ledger("approval").last)
        XCTAssertEqual((request["answers"] as? [[String: Any]] ?? []).count, 1, "only the other client's answer")
        XCTAssertTrue(waitUntil(timeout: 15) { !self.app.buttons["composer.stop"].exists }, "the turn ends")
    }

    // MARK: 17. The question dock

    @MainActor func test17_DockPagesWithoutMovingAndSends() throws {
        launch()
        openChat()
        send("ask me")
        let dock = app.otherElements["question.dock"]
        XCTAssertTrue(dock.waitForExistence(timeout: 15), "the dock shows")
        XCTAssertTrue(waitUntil(timeout: 5) {
            let composer = self.app.textViews["composer.text"]
            return !composer.exists || !composer.isHittable
        }, "the dock is in the composer's place")
        XCTAssertTrue(status("Waiting for your reply").waitForExistence(timeout: 5))
        attach("dock-page-1")
        let dockFrame = settledFrame(dock)
        let row = firstVisibleRow()
        let rowToDock = row.map { $0.frame.maxY - dockFrame.minY }

        // Owner 2026-10-30: each page fits its own content (a short question had a band of empty card under it). The
        // dock's bottom stays put, its top moves to the new page's height, and the transcript rides along with it.
        app.buttons["question.choice.0"].firstMatch.tap()          // "main (Recommended)"
        app.buttons["question.primary"].tap()                        // Next
        XCTAssertTrue(app.staticTexts["Question 2 of 3"].waitForExistence(timeout: 5))
        let page2 = settledFrame(dock)
        XCTAssertEqual(page2.maxY, dockFrame.maxY, accuracy: 0.5, "Next keeps the dock's bottom")
        XCTAssertGreaterThan(page2.height, dockFrame.height, "page 2 (a hint and three choices) is taller than page 1")
        attach("dock-page-2")
        if let rowToDock, let row { XCTAssertEqual(row.frame.maxY - page2.minY, rowToDock, accuracy: 1, "the transcript moves with the dock") }
        app.buttons["question.back"].tap()
        XCTAssertTrue(app.staticTexts["Question 1 of 3"].waitForExistence(timeout: 5))
        XCTAssertEqual(settledFrame(dock), dockFrame, "Back returns to page 1's frame")
        app.buttons["question.primary"].tap()

        // Page 2 (multi): a pick and "Something else…", which opens a field with the keyboard up.
        app.descendants(matching: .any)["question.page.1"].buttons["question.choice.1"].tap()   // "Lint"
        app.descendants(matching: .any)["question.page.1"].buttons["question.other"].tap()
        let other = app.textViews["question.otherField"]
        XCTAssertTrue(other.waitForExistence(timeout: 5), "Something else opens a field")
        XCTAssertTrue(waitUntil(timeout: 5) { self.app.keyboards.count > 0 }, "the keyboard rises")
        XCTAssertTrue(keyboardStaysUp(for: 1), "the keyboard rises once (it never drops while the field opens)")
        other.typeText("changelog")
        attach("dock-something-else-keyboard")
        let next = app.buttons["question.primary"]
        var restingTop = next.frame.minY
        for _ in 0..<15 {                                            // the dock at rest above the keys first
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            let now = next.frame.minY
            if abs(now - restingTop) < 0.5 { break }
            restingTop = now
        }
        tapWhenSettled(next)                                         // Next → the open question keeps the keyboard
        // Verify round 1: the keyboard dipped (down and up again) and the dock rode it, 487 → 573 → 487 pt. The capsule
        // stays where it was for the whole move.
        var lowest = restingTop
        let watchUntil = Date().addingTimeInterval(1.2)
        while Date() < watchUntil {
            lowest = max(lowest, app.buttons["question.primary"].frame.minY)
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        XCTAssertLessThan(lowest - restingTop, 12, "the dock never drops while Next moves the focus (rested at \(restingTop), lowest \(lowest))")
        let field = app.textViews["question.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 3) { self.app.keyboards.count > 0 }, "the keyboard stays up")
        field.typeText("v2.4")
        attach("dock-open-question")
        tapWhenSettled(app.buttons["question.primary"])              // Send

        XCTAssertTrue(waitUntil(timeout: 10) { !dock.exists }, "the dock goes after Send")
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 5))
        let settled = noteCard()
        XCTAssertTrue(waitUntil(timeout: 15) { settled.label.contains("main") && settled.label.contains("Lint, changelog") },
                      "the sent answers, then the settled card, show (\(settled.label))")
        attach("dock-settled")
        let request = try XCTUnwrap(try ledger("clarify").last)
        XCTAssertEqual(request["outcome"] as? String, "submitted")

        // Skip: {} and "Skipped" rows.
        XCTAssertTrue(waitUntil(timeout: 15) { !self.app.buttons["composer.stop"].exists })
        send("ask again")
        XCTAssertTrue(dock.waitForExistence(timeout: 15))
        app.buttons["question.skip"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !dock.exists })
        XCTAssertTrue(waitUntil(timeout: 10) {
            ((try? self.ledger("clarify").last?["answers"] as? [[String: Any]])??.first?["result"] as? [String: Any])?.isEmpty == true
        }, "Skip answered {}")
        // The sent note reads "Skipped"; the settled card then shows Hermes' own statuses (a cancel-all leaves every
        // question "unanswered": "No answer").
        XCTAssertTrue(waitUntil(timeout: 15) {
            let label = self.noteCard().label
            return label.contains("Skipped") || label.contains("No answer")
        }, "the rows read Skipped / No answer")
        attach("dock-skipped")
    }

    // MARK: 18. Sudo: tuck into the chip, keep the text, Don't Send, Send

    @MainActor func test18_SudoSheetTucksIntoTheChipAndKeepsText() throws {
        launch()
        openChat()
        send("sudo now")
        let sheet = app.otherElements["prompt.sheet.sudo"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 15), "the sudo sheet appears")
        XCTAssertTrue(status("Waiting for your approval").waitForExistence(timeout: 5))
        let secure = app.secureTextFields["prompt.secure"]
        XCTAssertTrue(secure.waitForExistence(timeout: 5))
        secure.tap()
        secure.typeText("x")
        attach("sudo-sheet")
        // Swipe the sheet away (with the keyboard up the first swipe may only lower it): it tucks, nothing is sent.
        for _ in 0..<3 where sheet.exists {
            let title = app.staticTexts["Administrator Password"]
            let from = title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: 700)), withVelocity: .fast,
                       thenHoldForDuration: 0)
            _ = waitUntil(timeout: 2) { !sheet.exists }
        }
        let chip = app.descendants(matching: .any)["prompt.chip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "the chip shows")
        XCTAssertTrue(waitUntil(timeout: 5) { !sheet.exists })
        XCTAssertEqual(chip.label, "Password requested. Opens the request.")
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(chip.frame.midX, window.midX, accuracy: 1, "the chip is centred")
        attach("sudo-chip")
        XCTAssertTrue((try ledger("sudo").last?["answers"] as? [Any])?.isEmpty == true, "a tuck sends nothing")
        chip.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "the chip brings the sheet back")
        XCTAssertEqual((secure.value as? String)?.count, 1, "the typed character is still there")
        tapWhenSettled(app.buttons["prompt.decline"])
        XCTAssertTrue(waitUntil(timeout: 10) {
            ((try? self.ledger("sudo").last?["answers"] as? [[String: Any]])??.first?["result"] as? [String: String])?["value"] == "<0 chars>"
        }, "Don't Send answers \"\"")
        XCTAssertTrue(waitUntil(timeout: 5) { !sheet.exists && !chip.exists })
        XCTAssertTrue(waitUntil(timeout: 15) { !self.app.buttons["composer.stop"].exists })

        send("sudo again")
        XCTAssertTrue(sheet.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["prompt.primary"].isEnabled, "Send waits for a password")
        secure.tap()
        secure.typeText("x")
        tapUntil(app.buttons["prompt.primary"]) {
            ((try? self.ledger("sudo").last?["answers"] as? [[String: Any]])??.first?["result"] as? [String: String])?["value"] == "<1 chars>"
        }
        XCTAssertEqual((try ledger("sudo").last?["answers"] as? [Any])?.count, 1, "Send answers the password, once")
        XCTAssertTrue(waitUntil(timeout: 5) { !sheet.exists })
    }

    // MARK: 19. Save login: AutoFill fields, valid only with both, a JSON string with both keys

    @MainActor func test19_SaveLoginNeedsBothFields() throws {
        launch()
        openChat()
        send("login please")
        XCTAssertTrue(app.otherElements["prompt.sheet.vault.save_login"].waitForExistence(timeout: 15))
        let user = app.textFields["prompt.username"], password = app.secureTextFields["prompt.password"]
        XCTAssertTrue(user.exists && password.exists, "an identifier and a password field")
        XCTAssertEqual(user.placeholderValue, "you@example.com")
        let primary = app.buttons["prompt.primary"]
        XCTAssertFalse(primary.isEnabled)
        user.tap()
        user.typeText("me@example.com")
        XCTAssertFalse(primary.isEnabled, "the identifier alone is not enough")
        password.tap()
        password.typeText("pw1")
        attach("save-login-sheet")
        XCTAssertTrue(primary.isEnabled)
        tapUntil(primary) {
            let result = (try? self.ledger("vault.save_login").last?["answers"] as? [[String: Any]])??.first?["result"] as? [String: Any]
            return (result?["value_keys"] as? [String]) == ["identifier", "password"]
        }
        XCTAssertEqual((try ledger("vault.save_login").last?["answers"] as? [Any])?.count, 1, "answered exactly once")
    }

    // MARK: 20. A withdrawn request closes its sheet with no chip

    @MainActor func test20_CancelClosesTheSheetWithoutAChip() throws {
        launch()
        openChat()
        send("secret please")
        let sheet = app.otherElements["prompt.sheet.secret"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 15))
        attach("secret-sheet")
        let id = try XCTUnwrap(try ledger("secret").last?["id"] as? String)
        try account.control("/__fixture/cancel", ["id": id, "reason": "interrupted"])
        XCTAssertTrue(waitUntil(timeout: 5) { !sheet.exists }, "the sheet goes")
        XCTAssertFalse(app.descendants(matching: .any)["prompt.chip"].exists, "no chip")
    }

    // MARK: 21. The Bots row says it waits

    @MainActor func test21_BotsRowSaysWaiting() throws {
        launch()
        openChat()
        send("please approve")
        XCTAssertTrue(app.buttons["approval.run"].waitForExistence(timeout: 15))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let row = app.cells["bot-row-default"]
        XCTAssertTrue(waitUntil(timeout: 10) { self.rowSays(row, "Waiting for your approval") }, "the row says it waits")
        attach("bots-row-approval")
        row.tap()
        XCTAssertTrue(app.buttons["approval.run"].waitForExistence(timeout: 10))
        app.buttons["approval.run"].tap()
        XCTAssertTrue(waitUntil(timeout: 15) { !self.app.buttons["composer.stop"].exists })
        send("ask me")
        XCTAssertTrue(app.otherElements["question.dock"].waitForExistence(timeout: 15))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(waitUntil(timeout: 10) { self.rowSays(row, "Waiting for your reply") }, "the row says it waits")
        attach("bots-row-reply")
    }

    // MARK: 22. Verify round 1: a question arriving during a hands-free memo

    /// The dock replaces the composer, recorder and all: the take must not go on recording out of sight. It is kept as
    /// the chat's draft chip (as when the chat is left), which shows above the field once the dock goes.
    @MainActor func test22_QuestionDuringALockedMemoKeepsItAsADraft() throws {
        launch(["-HQDebugMemoFixture", "granted", "-HQDebugResetVoice", "YES"])
        openChat()
        let mic = app.buttons["composer.mic"]
        XCTAssertTrue(mic.waitForExistence(timeout: 8), "the mic shows")
        mic.press(forDuration: 0.3)
        XCTAssertTrue(app.buttons["memo.stop"].waitForExistence(timeout: 5), "the locked recorder shows")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        try account.control("/__fixture/ask", ["kind": "one", "profile": "default"])
        let dock = app.otherElements["question.dock"]
        XCTAssertTrue(dock.waitForExistence(timeout: 15), "the dock shows")
        XCTAssertFalse(app.buttons["memo.stop"].exists, "nothing records behind the dock")
        attach("dock-over-memo")
        app.buttons["question.skip"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !dock.exists }, "the dock goes")
        let chip = app.descendants(matching: .any)["memo.chip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "the take waits as the draft chip")
        XCTAssertFalse(app.buttons["memo.stop"].exists, "and the recorder is gone")
        attach("memo-draft-after-dock")
    }

    // MARK: 23. Tasks, Ask First: the bot offers what it could do; nothing is added without a yes

    /// Owner 2026-11-04: "when Hermes picks up that there's a task … ask some questions about some things that it could
    /// do so that the user can decide what it goes out and does", without the list "flooded". hermes-hq-push 0.9.34's
    /// Ask First: one multi-select card, then tasks_add for what was picked; Skip adds nothing. Every look:
    /// TEST_RUNNER_HQN_TASKS_LOOK=dark | desktop | desktop-dark.
    @MainActor func test23_TaskOfferAsksBeforeAdding() throws {
        let look = ProcessInfo.processInfo.environment["HQN_TASKS_LOOK"]
        let name = look.map { "-" + $0 } ?? ""
        let arguments: [String] = switch look {
        case "dark": ["-hqn.appearance", "dark"]
        case "desktop": ["-hqn.appearance", "light", "-hqn.theme.desktopLook", "<true/>"]
        case "desktop-dark": ["-hqn.appearance", "dark", "-hqn.theme.desktopLook", "<true/>"]
        default: ["-hqn.appearance", "light"]
        }
        // The voice tips are first-run help, not part of this picture.
        launch(arguments + ["-hq.voice.tip.talk", "YES", "-hq.voice.tip.holdToRecord", "YES", "-hq.voice.tip.nowHold", "YES"])
        openChat()
        send("I need to go through the job applications by Friday")
        let dock = app.otherElements["question.dock"]
        XCTAssertTrue(dock.waitForExistence(timeout: 15), "Hermes asks before it adds anything")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Want help with")).firstMatch.exists)
        XCTAssertTrue(app.buttons["question.choice.3"].firstMatch.label.contains("Just add it to my list"))
        attach("offer-card" + name)

        app.buttons["question.choice.0"].firstMatch.tap()
        app.buttons["question.choice.1"].firstMatch.tap()
        attach("offer-picked" + name)
        tapWhenSettled(app.buttons["question.primary"])
        XCTAssertTrue(waitUntil(timeout: 10) { !dock.exists }, "the card goes after Send")

        let card = app.descendants(matching: .any)["chat.tasks-added"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "what was picked goes on the list")
        let first = app.descendants(matching: .any)["chat.tasks.row.0"].firstMatch
        XCTAssertTrue(waitUntil(timeout: 5) { first.label.contains("Rank them") }, first.label)
        XCTAssertTrue(waitUntil(timeout: 10) { !self.app.buttons["composer.stop"].exists })
        app.tables["chat.table"].swipeUp(velocity: .slow)
        attach("offer-added" + name)

        // Skip: nothing goes on the list.
        send("Also the job applications for the spring program")
        XCTAssertTrue(dock.waitForExistence(timeout: 15))
        app.buttons["question.skip"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !dock.exists })
        XCTAssertTrue(waitUntil(timeout: 15) {
            self.app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "I won’t add it")).firstMatch.exists
        }, "skipped: nothing added")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "chat.tasks-added").count, 1, "still one card")
        attach("offer-skipped" + name)
    }

    // MARK: Helpers

    @MainActor private func launch(_ arguments: [String] = []) {
        let app = XCUIApplication()
        app.launchArguments = ["-HQDebugResetAccounts", "YES"] + arguments
        app.launchEnvironment = ["HQN_SIGNIN_URL": account.url, "HQN_SIGNIN_USERNAME": account.username,
                                 "HQN_SIGNIN_PASSWORD": account.password]
        app.launch()
        self.app = app
        XCTAssertTrue(app.cells["bot-row-default"].waitForExistence(timeout: 20), "signed in: the Bots list shows")
    }

    @MainActor private func openChat() {
        app.cells["bot-row-default"].tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 10), "the chat opens")
    }

    @MainActor private func send(_ text: String) {
        let field = app.textViews["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 10) { field.isHittable })
        field.tap()
        field.typeText(text)
        let button = app.buttons["composer.send"]
        // The keyboard is still rising: tap Send once it rests, again if the words are still in the field.
        for _ in 0..<3 {
            XCTAssertTrue(waitUntil(timeout: 5) { button.exists && button.isEnabled && button.isHittable })
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            button.tap()
            if waitUntil(timeout: 3, {
                !field.exists || ((field.value as? String) ?? "").isEmpty || (field.value as? String) == "Message Hermes"
            }) { return }
        }
        XCTFail("the message didn't send")
    }

    /// Taps once the element rests. The first keystroke into a field (typeText goes the hardware-keyboard path) can
    /// drop the simulator's software keyboard, and the sheet then animates .large → .medium → .large: a tap
    /// mid-animation misses (reviewer: test19 flaked so). Two reads 200 ms apart must agree, and it must be hittable.
    @MainActor private func tapWhenSettled(_ element: XCUIElement, timeout: TimeInterval = 5) {
        var last = CGRect.null
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.isHittable {
                let frame = element.frame
                if frame == last { break }
                last = frame
            } else {
                last = .null
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        element.tap()
    }

    /// The element's frame once two reads 150 ms apart agree (the dock's resize after Next or Back has finished).
    @MainActor private func settledFrame(_ element: XCUIElement, timeout: TimeInterval = 3) -> CGRect {
        var last = element.frame
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            let now = element.frame
            if now == last { return now }
            last = now
        }
        return last
    }

    /// `tapWhenSettled`, then once more if `done` hasn't happened in 3 s and the button is still there and enabled
    /// (the app answers exactly once whatever the taps; the callers check the count).
    @MainActor private func tapUntil(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line,
                                     _ done: @escaping () -> Bool) {
        tapWhenSettled(element)
        if waitUntil(timeout: 3, done) { return }
        if element.exists && element.isEnabled && element.isHittable { tapWhenSettled(element) }
        XCTAssertTrue(waitUntil(timeout: 10, done), "the answer reached the gateway", file: file, line: line)
    }

    /// Once the keyboard is up it must not go down within `seconds` (it rises once).
    @MainActor private func keyboardStaysUp(for seconds: TimeInterval) -> Bool {
        var seenUp = false
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if app.keyboards.count > 0 { seenUp = true } else if seenUp { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return seenUp
    }

    @MainActor private func status(_ words: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", words)).firstMatch
    }

    @MainActor private func rowSays(_ row: XCUIElement, _ words: String) -> Bool {
        row.label.contains(words)
            || row.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch.exists
    }

    @MainActor private func noteCard() -> XCUIElement {
        app.tables["chat.table"].descendants(matching: .any)["clarify.note"].firstMatch
    }

    @MainActor private func firstVisibleRow() -> XCUIElement? {
        let cells = app.tables["chat.table"].cells.allElementsBoundByIndex.filter { $0.isHittable }
        return cells.first
    }

    private func ledger(_ method: String) throws -> [[String: Any]] {
        let state = try account.control("/__fixture/requests")
        return (state["requests"] as? [[String: Any]] ?? []).filter { $0["method"] as? String == method }
    }

    @MainActor private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
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
