// [a11y] Accessibility end-to-end tests (docs/spec/3x-a11y.md §8). Demo roots need no gateway; the signed-in tour
// runs against the settings stand-in gateway (scripts/e2e-a11y.sh starts it and sets HQN_A11Y_SETTINGS).
//
// What these can and cannot prove: VoiceOver's speech is not audible in the simulator. Labels, traits, values,
// custom action names and announcements are read from the accessibility tree VoiceOver itself reads, plus the app's
// DEBUG announcement log.

import XCTest

final class A11yEndToEndTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    /// The app leaves by an ordinary exit before the test ends (see `a11yQuit`).
    @MainActor override func tearDown() async throws { a11yQuit() }

    /// The clean-quit hook itself: the app is gone within seconds of being asked, and a new launch starts fresh.
    @MainActor func testA0_appQuitsCleanlyWhenTheTestAsks() {
        let app = a11yLaunch(["-HQDemoLists"])
        XCTAssertTrue(a11yWait(30) { app.state == .runningForeground }, "the app is up")
        XCTAssertTrue(a11yQuit(app), "the app ended itself when asked")
        let again = a11yLaunch(["-HQDemoLists"])
        XCTAssertTrue(a11yWait(30) { again.state == .runningForeground }, "the app starts again after a clean quit")
    }

    /// Codes that must be zero on every screen visited: an unnamed control, a symbol name read aloud, the banned word.
    private let hard = ["no-label", "raw-symbol", "banned-word"]

    @MainActor private func assertClean(_ app: XCUIApplication, _ screen: String, sizes: Bool = false,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let report = a11yAudit(app, file: file, line: line)
        XCTAssertGreaterThan(report.elements, 0, "\(screen): the audit saw elements", file: file, line: line)
        let bad = report.findings.filter { hard.contains($0.code) }
        XCTAssertTrue(bad.isEmpty, "\(screen): \(bad)", file: file, line: line)
        if sizes {
            // Both checks see UIKit labels only: SwiftUI rows and the drawn transcript are judged from screenshots.
            let fixed = report.findings("fixed-font")
            XCTAssertTrue(fixed.isEmpty, "\(screen): text that ignores the text size: \(fixed)", file: file, line: line)
            let cut = report.findings("truncated")
            XCTAssertTrue(cut.isEmpty, "\(screen): text cut off at an accessibility size (outside the allow-list): \(cut)", file: file, line: line)
        }
        let soft = report.findings.filter { !hard.contains($0.code) && $0.code != "fixed-font" && !(sizes && $0.code == "truncated") }
        if !soft.isEmpty {
            // Reported, not failed: small targets (and truncation at the ordinary sizes) need a per-screen pass.
            let attachment = XCTAttachment(string: "\(screen)\n" + soft.map(\.description).joined(separator: "\n"))
            attachment.name = "audit-soft-\(screen)"
            attachment.lifetime = .keepAlways
            add(attachment)
            print("[a11y-soft] \(screen): \(soft.count) — \(soft.prefix(12))")
        }
    }

    /// The system's own audit. Exemptions, each with its reason (the report lists this table):
    ///  - elements inside a system bar or the keyboard: the system draws and names them;
    ///  - the DEBUG probes (`debug.*`): one-point test elements, not part of the app.
    @MainActor private func systemAudit(_ app: XCUIApplication, _ screen: String, _ types: XCUIAccessibilityAuditType) {
        do {
            try app.performAccessibilityAudit(for: types) { issue in
                guard let element = issue.element else { return true }
                if element.identifier.hasPrefix("debug.") { return true }
                if element.elementType == .key || element.elementType == .keyboard { return true }
                let frame = element.frame, screenFrame = app.frame
                if frame.maxY <= 110 || frame.minY >= screenFrame.maxY - 100 { return true }   // navigation bar, tab bar
                return false
            }
        } catch {
            XCTFail("\(screen): the system audit could not run: \(error)")
        }
    }

    // MARK: D4 — field validity

    @MainActor func testD4_signInFieldValidity() throws {
        let app = a11yLaunch(["-HQDemoSignIn"], overrides: [.voiceOver])
        let address = app.textFields["sign-in-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 30))
        XCTAssertEqual(address.label, "Hermes address", "the field is named by its visible title, not its placeholder")
        address.tap()
        address.typeText("fleet.example")
        let username = app.textFields["sign-in-username"]
        XCTAssertTrue(username.waitForExistence(timeout: 15), "the address is checked and the password form shows")
        username.tap(); username.typeText("fleet")
        let password = app.secureTextFields["sign-in-password"]
        password.tap(); password.typeText("wrong")
        let button = app.buttons["sign-in-password-button"]
        for _ in 0..<4 where !button.isHittable { app.swipeUp() }
        XCTAssertEqual(button.label, "Sign In")
        button.tap()
        let error = app.staticTexts["sign-in-error"].firstMatch.exists ? app.staticTexts["sign-in-error"].firstMatch
                                                                       : app.descendants(matching: .any)["sign-in-error"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 15), "the refusal shows")
        let message = error.label
        XCTAssertFalse(message.isEmpty)
        // Once: either VoiceOver was moved to the field (whose hint carries the words; logged as "focus: …") or, when
        // the move did not take, one announcement. Never both. The decision is made 0.35 s after the error shows.
        XCTAssertTrue(a11yWait(6) { self.a11yAnnouncements(app).contains { $0 == message || $0 == "focus: " + message } }, "the message reaches VoiceOver")
        Thread.sleep(forTimeInterval: 1)
        let spoken = a11yAnnouncements(app)
        XCTAssertEqual(spoken.filter { $0 == message || $0 == "focus: " + message }.count, 1, "the message is spoken exactly once: \(spoken)")
        XCTAssertTrue(spoken.contains("Checking the address"), "the check is spoken: \(spoken)")
        a11yDismissSavePassword(app, wait: 4)
        let hints = a11yAudit(app).hints
        XCTAssertEqual(hints["sign-in-password"], "Invalid. \(message)", "the password is marked for VoiceOver: \(hints)")
        XCTAssertNil(hints["sign-in-address"], "the address is not marked")
        a11yShot(app, "signin-invalid-light")
        assertClean(app, "sign-in (error)")
        // Correcting it: the mark clears on the first character and the field must stay the same field (keyboard up,
        // both characters land). A secure field empties itself on the first key after it is focused again, so the
        // value is either two characters, or two more than before.
        let before = ((password.value as? String) ?? "").count
        password.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        password.typeText("xy")
        XCTAssertTrue(a11yWait(5) { self.a11yAudit(app).hints["sign-in-password"] == nil }, "typing clears the mark")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard stays up: the field was not rebuilt when the mark cleared")
        let after = ((password.value as? String) ?? "").count
        XCTAssertTrue(after == 2 || after == before + 2, "both characters landed in the field (\(before) → \(after))")
        XCTAssertTrue(password.exists && app.textFields["sign-in-username"].exists, "the password form is still there (no extra address check tore it down)")
    }

    /// The same for an address the gateway check turns down: marked, then corrected without losing the keyboard.
    @MainActor func testD4c_invalidAddressKeepsTheKeyboardWhileCorrecting() throws {
        let app = a11yLaunch(["-HQDemoSignIn"], overrides: [.voiceOver])
        let address = app.textFields["sign-in-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 30))
        address.tap()
        address.typeText("unreachable-fleet.example")
        let username = app.textFields["sign-in-username"]
        XCTAssertTrue(username.waitForExistence(timeout: 15))
        username.tap(); username.typeText("fleet")
        let password = app.secureTextFields["sign-in-password"]
        password.tap(); password.typeText("fleet")
        let button = app.buttons["sign-in-password-button"]
        for _ in 0..<4 where !button.isHittable { app.swipeUp() }
        button.tap()
        let error = app.descendants(matching: .any)["sign-in-error"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 15), "the refusal shows")
        a11yDismissSavePassword(app, wait: 3)
        let message = error.label
        XCTAssertTrue(a11yWait(6) { self.a11yAudit(app).hints["sign-in-address"] == "Invalid. \(message)" }, "the address is marked: \(a11yAudit(app).hints)")
        XCTAssertNil(a11yAudit(app).hints["sign-in-password"], "the password is not")
        Thread.sleep(forTimeInterval: 1)
        let spoken = a11yAnnouncements(app)
        XCTAssertEqual(spoken.filter { $0 == message || $0 == "focus: " + message }.count, 1, "spoken exactly once: \(spoken)")
        a11yShot(app, "signin-invalid-address-light")
        for _ in 0..<4 where !address.isHittable { app.swipeDown() }
        let before = ((address.value as? String) ?? "").count
        address.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        address.typeText("xy")
        XCTAssertTrue(a11yWait(5) { self.a11yAudit(app).hints["sign-in-address"] == nil }, "typing clears the mark")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard stays up while correcting the address")
        XCTAssertEqual(((address.value as? String) ?? "").count, before + 2, "both characters landed in the address field")
    }

    @MainActor func testD4b_signInAtAX5ScrollsAndKeepsEverythingReachable() throws {
        let app = a11yLaunch(["-HQDemoSignIn", "-HQDemoAddress", "fleet.example"], size: .ax5, dark: true)
        let username = app.textFields["sign-in-username"]
        XCTAssertTrue(username.waitForExistence(timeout: 30))
        a11yShot(app, "signin-ax5-dark")
        let button = app.buttons["sign-in-password-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        for _ in 0..<6 where !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.isHittable, "Sign In is reachable by scrolling at the largest text size")
        XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        a11yShot(app, "signin-ax5-dark-scrolled")
        assertClean(app, "sign-in AX5", sizes: true)
        // Stress round 2: with the keyboard up the tall password field sits half under it. Next on the username
        // moves the keyboard to the password, and what is typed lands there (no tap on a covered field needed).
        XCTAssertTrue(a11yFocus(app, username), "the username takes the keyboard at the largest text size")
        username.typeText("fleet\n")
        let password = app.secureTextFields["sign-in-password"]
        XCTAssertTrue(a11yWait(8) { self.a11yHasKeyboard(password) }, "Next moves the keyboard to the password field")
        password.typeText("abc")
        XCTAssertTrue(a11yWait(5) { ((password.value as? String) ?? "").count == 3 }, "three characters landed in the password: \(String(describing: password.value))")
        // And by touch: back to the username, then the password tapped where it shows above the keyboard.
        XCTAssertTrue(a11yFocus(app, username), "the username takes the keyboard back")
        XCTAssertTrue(a11yFocus(app, password), "the password takes the keyboard by a tap on its visible part")
    }

    // MARK: B4 — the launch problem scrolls

    @MainActor func testB4_launchProblemScrollsAtAX5() throws {
        // Ship (build 253): the launch screen this test opened ("Can’t Open Your Sign-In" on the old
        // App/Root/LaunchViewController) was replaced by the offline stream's launch and offline screens, which scroll
        // at the largest text size themselves; that is checked by UITests/offline testO24 (launch, AX5) and testO27.
        throw XCTSkip("the old launch problem screen is gone; see OfflineEndToEndTests testO24 / testO27")
        let app = a11yLaunch(["-HQA11yLaunchProblem", "YES"], size: .ax5)
        let retry = app.buttons["Try Again"]
        XCTAssertTrue(retry.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Can’t Open Your Sign-In"].exists)
        a11yShot(app, "launch-problem-ax5-light")
        for _ in 0..<3 where !retry.isHittable { app.swipeUp() }
        XCTAssertTrue(retry.isHittable, "Try Again is on screen after at most three swipes")
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
        a11yShot(app, "launch-problem-ax5-light-scrolled")
        assertClean(app, "launch problem AX5")

        let standard = a11yLaunch(["-HQA11yLaunchProblem", "YES"], size: .large, dark: true)
        let button = standard.buttons["Try Again"]
        XCTAssertTrue(button.waitForExistence(timeout: 30))
        XCTAssertTrue(button.isHittable, "at the standard size it fits without scrolling")
        let middle = standard.frame.midY
        XCTAssertLessThan(abs(standard.staticTexts["Can’t Open Your Sign-In"].frame.midY - middle), 160, "and sits around the middle, as before")
        a11yShot(standard, "launch-problem-large-dark")
    }

    // MARK: D1 / A2 — lists (demo data, no gateway)

    @MainActor func testD1_demoListsLabelsTraitsAndAudit() throws {
        let app = a11yLaunch(["-HQDemoLists"])
        let bots = app.tabBars.buttons["Bots"]
        XCTAssertTrue(bots.waitForExistence(timeout: 30))
        XCTAssertTrue(bots.isSelected, "the chosen tab carries the selected trait")
        let list = app.collectionViews["bots.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let row = list.cells.element(boundBy: 0)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        assertClean(app, "bots (demo)")
        let report = a11yAudit(app)
        print("[a11y-soft] bots (demo): custom actions seen by the in-app walker: \(report.actions)")   // see the report: not proven
        a11yShot(app, "bots-large-light")
        systemAudit(app, "bots (demo)", [.sufficientElementDescription, .elementDetection])

        let sessions = app.tabBars.buttons["Sessions"]
        sessions.tap()
        XCTAssertTrue(a11yWait(5) { sessions.isSelected })
        XCTAssertTrue(app.collectionViews["sessions.list"].waitForExistence(timeout: 10))
        assertClean(app, "sessions (demo)")
        a11yShot(app, "sessions-large-light")
        systemAudit(app, "sessions (demo)", [.sufficientElementDescription])
    }

    @MainActor func testA2_demoListsFollowTheTextSize() throws {
        func rowHeight(_ size: A11ySize, dark: Bool, name: String) -> CGFloat {
            let app = a11yLaunch(["-HQDemoLists", "-HQDemoTab", "1"], size: size, dark: dark)
            let list = app.collectionViews["sessions.list"]
            XCTAssertTrue(list.waitForExistence(timeout: 30))
            let row = list.cells.element(boundBy: 0)
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            a11yShot(app, "sessions-\(name)")
            assertClean(app, "sessions \(name)", sizes: true)
            let report = a11yAudit(app)
            XCTAssertEqual(report.settings["size"], size.rawValue, "the app runs at the size asked for")
            // The first cell can be a section header ("Earlier today"): measure the tallest of the first three cells.
            let height = (0..<min(3, list.cells.count)).map { list.cells.element(boundBy: $0).frame.height }.max() ?? row.frame.height
            app.tabBars.buttons["Bots"].tap()
            XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 10))
            a11yShot(app, "bots-\(name)")
            assertClean(app, "bots \(name)", sizes: true)
            return height
        }
        let small = rowHeight(.xs, dark: false, name: "xs-light")
        let standard = rowHeight(.large, dark: true, name: "large-dark")
        let ax3 = rowHeight(.ax3, dark: true, name: "ax3-dark")
        let ax5 = rowHeight(.ax5, dark: false, name: "ax5-light")
        XCTAssertLessThanOrEqual(small, standard)
        XCTAssertGreaterThan(ax3, standard * 1.3, "rows grow with the text")
        XCTAssertGreaterThan(ax5, standard * 1.8, "and keep growing to the largest size")
    }

    // MARK: C — Bold Text, Increase Contrast, the overrides

    /// Rendered facts, not the launch flags read back: the font the lowest visible message is really drawn with, its
    /// natural width, and the bubbles' edges. Bold Text here is the DEBUG switch (the simulator's command line cannot
    /// set the real one); the real setting is covered by `HQAccessibility.stepsDrawnWeights` and its unit test.
    /// Reduce Transparency is NOT asserted: at rest the chat's bars are the system's glass, which only the real
    /// setting changes.
    @MainActor func testC3_chatBoldTextAndContrast() throws {
        let plain = a11yLaunch(["-HQDemoChat", "40", "-HQDemoAutoOpen"])
        XCTAssertTrue(plain.textViews["composer.text"].waitForExistence(timeout: 40) || plain.otherElements["chat.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(a11yWait(10) { (Int(self.a11yAudit(plain).settings["bubbles"] ?? "0") ?? 0) > 0 }, "bubbles are on screen")
        var report = a11yAudit(plain)
        let plainWeight = Double(report.settings["textWeight"] ?? "") ?? .nan
        let plainWidth = Double(report.settings["textWidth"] ?? "") ?? .nan
        XCTAssertFalse(plainWeight.isNaN, "the audit found a drawn message text: \(report.settings)")
        XCTAssertLessThan(plainWeight, 0.1, "plain message text is drawn at the regular weight")
        XCTAssertEqual(report.settings["bubblesEdged"], "0", "no bubble edge without Increase Contrast")
        a11yShot(plain, "chat-plain-light")
        assertClean(plain, "chat (demo)")

        let bold = a11yLaunch(["-HQDemoChat", "40", "-HQDemoAutoOpen"], overrides: [.boldText, .contrast, .buttonShapes])
        XCTAssertTrue(bold.textViews["composer.text"].waitForExistence(timeout: 40) || bold.otherElements["chat.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(a11yWait(10) { (Int(self.a11yAudit(bold).settings["bubbles"] ?? "0") ?? 0) > 0 }, "bubbles are on screen")
        report = a11yAudit(bold)
        let boldWeight = Double(report.settings["textWeight"] ?? "") ?? .nan
        let boldWidth = Double(report.settings["textWidth"] ?? "") ?? .nan
        XCTAssertGreaterThan(boldWeight, plainWeight + 0.15, "the same message is drawn one step heavier: \(report.settings)")
        XCTAssertGreaterThan(boldWidth, plainWidth, "and is wider, so it was measured again")
        let bubbles = Int(report.settings["bubbles"] ?? "0") ?? 0, edged = Int(report.settings["bubblesEdged"] ?? "0") ?? 0
        XCTAssertGreaterThan(bubbles, 0)
        XCTAssertEqual(edged, bubbles, "every bubble on screen has its 1 pt edge under Increase Contrast")
        a11yShot(bold, "chat-bold-contrast-light")
        assertClean(bold, "chat (demo, bold + contrast)")
    }

    @MainActor func testC3b_chatAtAX5DarkWithEverythingOn() throws {
        let app = a11yLaunch(["-HQDemoChat", "40", "-HQDemoAutoOpen"], size: .ax5, overrides: Set(A11yOverride.allCases), dark: true)
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 40) || app.otherElements["chat.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(a11yWait(10) { (Int(self.a11yAudit(app).settings["bubbles"] ?? "0") ?? 0) > 0 }, "bubbles are on screen")
        let report = a11yAudit(app)
        XCTAssertEqual(report.settings["size"], A11ySize.ax5.rawValue)
        XCTAssertGreaterThan(Double(report.settings["textPointSize"] ?? "0") ?? 0, 40, "message text is really drawn uncapped at the largest size: \(report.settings)")
        XCTAssertGreaterThan(Double(report.settings["textWeight"] ?? "0") ?? 0, 0.15, "and heavier under Bold Text")
        a11yShot(app, "chat-ax5-all-dark")
        assertClean(app, "chat AX5, every setting on")
        // The Send circle is 40 pt drawn with a 44 pt hit box by design (ComposerView.PrimaryButton.point(inside:)):
        // the in-app walker measures the hit box, which is what a finger gets.
        let small = report.findings("small-target").filter { $0.where.hasPrefix("composer.") }
        XCTAssertTrue(small.isEmpty, "every composer control has a 44 pt hit area: \(small)")
    }

    // MARK: C5 — the REAL settings (written into the simulator by scripts/e2e-a11y.sh with HQN_A11Y_REAL=1)

    /// Runs only in the script's real-settings pass: Bold Text, Reduce Transparency, Reduce Motion and Button Shapes
    /// are switched on in the simulator itself (no DEBUG override). Checks that the app sees them and that the
    /// transcript is one step heavier, not two (the system already hands out heavier fonts under the real setting).
    @MainActor func testC5_realSettingsAreSeenAndBoldIsNotDoubled() throws {
        guard ProcessInfo.processInfo.environment["HQN_A11Y_REAL"] == "1" else {
            throw XCTSkip("Run HQN_A11Y_REAL=1 scripts/e2e-a11y.sh: it switches the simulator's own settings on first.")
        }
        let app = a11yLaunch(["-HQDemoChat", "40", "-HQDemoAutoOpen"])
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 40) || app.otherElements["chat.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(a11yWait(10) { (Int(self.a11yAudit(app).settings["bubbles"] ?? "0") ?? 0) > 0 }, "bubbles are on screen")
        let settings = a11yAudit(app).settings
        print("[measure] real settings: \(settings.sorted { $0.key < $1.key })")
        XCTContext.runActivity(named: "[measure] real settings: \(settings.sorted { $0.key < $1.key })") { _ in }
        a11yShot(app, "chat-real-settings-light")
        XCTAssertEqual(settings["bold"], "1", "the app sees the real Bold Text setting")
        XCTAssertEqual(settings["reduceTransparency"], "1", "and Reduce Transparency")
        XCTAssertEqual(settings["reduceMotion"], "1", "and Reduce Motion")
        let weight = Double(settings["textWeight"] ?? "") ?? .nan
        XCTAssertGreaterThan(weight, 0.15, "message text is heavier under the real Bold Text")
        XCTAssertLessThan(weight, 0.36, "but only one step (semibold at most), not doubled: system-bold=\(settings["systemBoldsFonts"] ?? "?") app-step=\(settings["chatBold"] ?? "?")")
        if settings["systemBoldsFonts"] == "1" { XCTAssertEqual(settings["chatBold"], "0", "the app does not step the weights when the system already has") }
        assertClean(app, "chat (real settings)")
        let dark = a11yLaunch(["-HQDemoChat", "40", "-HQDemoAutoOpen"], size: .ax3, dark: true)
        XCTAssertTrue(dark.textViews["composer.text"].waitForExistence(timeout: 40) || dark.otherElements["chat.title"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2)
        a11yShot(dark, "chat-real-settings-ax3-dark")
    }

    // MARK: E1 — the jump lands at once under Reduce Motion

    @MainActor func testE1_jumpLandsAtOnceUnderReduceMotion() throws {
        func run(reduced: Bool) -> TimeInterval {
            let app = a11yLaunch(["-HQDemoChat", "400", "-HQDemoAutoOpen"], overrides: reduced ? [.reduceMotion] : [])
            let composer = app.textViews["composer.text"]
            XCTAssertTrue(composer.waitForExistence(timeout: 40))
            let report = a11yAudit(app)
            XCTAssertEqual(report.settings["reduceMotion"], reduced ? "1" : "0")
            let table = app.tables.firstMatch.exists ? app.tables.firstMatch : app.otherElements.firstMatch
            for _ in 0..<3 { table.swipeDown(velocity: .fast) }
            let jump = app.buttons["chat.jump"]
            XCTAssertTrue(jump.waitForExistence(timeout: 10), "scrolled away from the end, the jump button shows")
            XCTAssertEqual(jump.label, "Jump to Latest")
            XCTAssertGreaterThanOrEqual(jump.frame.width, 43.5)
            jump.tap()
            // Measured inside the app, from the tap to the chat being at the end (polling from here is too coarse
            // on a loaded Mac to tell 0 ms from 320 ms).
            var settle: Double?
            XCTAssertTrue(a11yWait(10) { settle = Double(self.a11yAudit(app).settings["jumpSettleMs"] ?? ""); return settle != nil },
                          "the chat is back at the latest message")
            XCTAssertTrue(a11yWait(5) { !jump.exists || !jump.isHittable }, "and the jump button has gone")
            a11yShot(app, reduced ? "chat-jump-reduced" : "chat-jump-motion")
            return settle ?? -1
        }
        let reduced = run(reduced: true)
        let moving = run(reduced: false)
        print("[measure] jump settle reduced=\(String(format: "%.1f", reduced)) ms motion=\(String(format: "%.1f", moving)) ms")
        XCTContext.runActivity(named: "[measure] jump settle reduced=\(String(format: "%.1f", reduced)) ms motion=\(String(format: "%.1f", moving)) ms") { _ in }
        XCTAssertGreaterThanOrEqual(reduced, 0)
        XCTAssertLessThan(reduced, 100, "under Reduce Motion the chat is at the end at once (no glide)")
        XCTAssertGreaterThan(moving, 250, "without it the 320 ms glide plays")
    }

    // MARK: D1 / B1 — the signed-in tour against the stand-in gateway

    @MainActor private func tour(size: A11ySize, dark: Bool, overrides: Set<A11yOverride>, tag: String) throws {
        let gateway = try A11yGateway.load("HQN_A11Y_SETTINGS")
        let app = a11yLaunch(["-HQDebugResetAccounts", "YES"], size: size, overrides: overrides, dark: dark)
        a11ySignIn(app, gateway)
        let bots = app.tabBars.buttons["Bots"]
        XCTAssertTrue(bots.waitForExistence(timeout: 40), "signed in")
        a11yDismissSavePassword(app, wait: 2)
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 20))
        XCTAssertTrue(a11yWait(20) { app.collectionViews["bots.list"].cells.count > 0 })
        let checksSizes = size != .large
        XCTAssertTrue(bots.isSelected)
        a11yShot(app, "tour-bots-\(tag)")
        assertClean(app, "Bots \(tag)", sizes: checksSizes)

        let sessions = app.tabBars.buttons["Sessions"]
        sessions.tap()
        XCTAssertTrue(app.collectionViews["sessions.list"].waitForExistence(timeout: 15))
        XCTAssertTrue(sessions.isSelected)
        a11yShot(app, "tour-sessions-\(tag)")
        assertClean(app, "Sessions \(tag)", sizes: checksSizes)

        let more = app.tabBars.buttons["More"]
        more.tap()
        let settingsRow = app.cells["more-row-settings"]
        XCTAssertTrue(settingsRow.waitForExistence(timeout: 15))
        XCTAssertTrue(more.isSelected)
        a11yShot(app, "tour-more-\(tag)")
        assertClean(app, "More \(tag)", sizes: checksSizes)

        for _ in 0..<4 where !settingsRow.isHittable { app.swipeUp() }
        settingsRow.tap()
        let card = app.buttons["settings.gateway-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 15), "Settings opens")
        a11yShot(app, "tour-settings-\(tag)")
        assertClean(app, "Settings \(tag)", sizes: checksSizes)

        for (identifier, name) in [("settings.appearance", "Appearance"), ("settings.notifications", "Notifications"), ("settings.about", "About")] {
            let row = app.descendants(matching: .any)[identifier].firstMatch
            var found = row.waitForExistence(timeout: 3) && row.isHittable
            for _ in 0..<12 where !found { app.swipeUp(); found = row.exists && row.isHittable }
            guard found else { XCTFail("\(name) row not reachable at \(tag)"); continue }
            XCTAssertFalse(row.label.isEmpty, "\(name) row is named")
            row.tap()
            XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 10) || app.staticTexts[name].waitForExistence(timeout: 3), "\(name) opens")
            a11yShot(app, "tour-\(name.lowercased())-\(tag)")
            assertClean(app, "\(name) \(tag)", sizes: checksSizes)
            let back = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(back.exists)
            back.tap()
            XCTAssertTrue(card.waitForExistence(timeout: 10) || row.waitForExistence(timeout: 5))
            for _ in 0..<12 where !card.isHittable { app.swipeDown() }
        }
    }

    // MARK: D1c — the pages (Jobs, Artifacts, Kanban), an open chat and Bot Info against the pages stand-in

    @MainActor private func pagesTour(size: A11ySize, dark: Bool, overrides: Set<A11yOverride>, tag: String) throws {
        let gateway = try A11yGateway.load("HQN_A11Y_PAGES")
        let app = a11yLaunch(["-HQDebugResetAccounts", "YES"], size: size, overrides: overrides, dark: dark)
        a11ySignIn(app, gateway)
        let bots = app.tabBars.buttons["Bots"]
        XCTAssertTrue(bots.waitForExistence(timeout: 40), "signed in")
        a11yDismissSavePassword(app, wait: 2)
        let sizes = size != .large
        var visited: [String] = []

        let jobs = app.tabBars.buttons["Jobs"]
        if jobs.waitForExistence(timeout: 10) {
            jobs.tap()
            XCTAssertTrue(app.collectionViews["jobs.list"].waitForExistence(timeout: 20), "Jobs opens")
            _ = a11yWait(10) { app.collectionViews["jobs.list"].cells.count > 0 }
            a11yShot(app, "pages-jobs-\(tag)")
            assertClean(app, "Jobs \(tag)", sizes: sizes)
            visited.append("Jobs")
            let row = app.collectionViews["jobs.list"].cells.matching(NSPredicate(format: "identifier BEGINSWITH 'job-row-'")).firstMatch
            if row.exists {
                for _ in 0..<3 where !row.isHittable { app.swipeUp() }
                row.tap()
                if app.descendants(matching: .any)["job.detail"].firstMatch.waitForExistence(timeout: 15) {
                    a11yShot(app, "pages-job-detail-\(tag)")
                    assertClean(app, "Job detail \(tag)", sizes: sizes)
                    visited.append("Job detail")
                    app.navigationBars.buttons.element(boundBy: 0).tap()
                }
            }
        }

        // Kanban and Artifacts: one of them is the fourth tab (Kanban when the gateway has the plugin), the other a
        // row under More.
        let more = app.tabBars.buttons["More"]
        for (row, list, name) in [("more-row-artifacts", "artifacts.list", "Artifacts"), ("more-row-kanban", "kanban.list", "Kanban")] {
            let tab = app.tabBars.buttons[name]
            var fromMore = false
            if tab.exists {
                tab.tap()
            } else {
                more.tap()
                XCTAssertTrue(app.collectionViews["more.list"].waitForExistence(timeout: 15))
                let cell = app.cells[row]
                // A collection view only makes the cells that are on screen: at AX5 this row is far down the list,
                // so the list is scrolled until the row exists (stress round 1: Artifacts was never reached).
                let moreList = app.collectionViews["more.list"]
                var found = cell.waitForExistence(timeout: 4)
                for _ in 0..<14 where !(found && cell.isHittable) { moreList.swipeUp(velocity: .slow); found = cell.waitForExistence(timeout: 1) }
                guard found else { XCTFail("\(name) is neither a tab nor a More row at \(tag)"); continue }
                for _ in 0..<4 where !cell.isHittable { moreList.swipeDown(velocity: .slow) }
                XCTAssertFalse(cell.label.isEmpty, "\(name) row is named")
                cell.tap()
                fromMore = true
            }
            XCTAssertTrue(app.collectionViews[list].waitForExistence(timeout: 20), "\(name) opens")
            _ = a11yWait(8) { app.collectionViews[list].cells.count > 0 }
            a11yShot(app, "pages-\(name.lowercased())-\(tag)")
            assertClean(app, "\(name) \(tag)", sizes: sizes)
            visited.append(name)
            if fromMore {
                app.navigationBars.buttons.element(boundBy: 0).tap()
                XCTAssertTrue(app.collectionViews["more.list"].waitForExistence(timeout: 10))
            }
        }

        // An open chat with a real (stand-in) bot, then Bot Info from its title.
        bots.tap()
        let list = app.collectionViews["bots.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 15))
        let bot = list.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'bot-row-' OR identifier BEGINSWITH 'bot-tile-'")).firstMatch
        if bot.waitForExistence(timeout: 15) {
            bot.tap()
            let title = app.descendants(matching: .any)["chat.title"].firstMatch
            if title.waitForExistence(timeout: 20) {
                Thread.sleep(forTimeInterval: 1.5)
                a11yShot(app, "pages-chat-\(tag)")
                assertClean(app, "Chat \(tag)", sizes: sizes)
                visited.append("Chat")
                title.tap()
                if app.buttons["bot-info.close"].waitForExistence(timeout: 10) {
                    Thread.sleep(forTimeInterval: 1)
                    a11yShot(app, "pages-botinfo-\(tag)")
                    assertClean(app, "Bot Info \(tag)", sizes: sizes)
                    visited.append("Bot Info")
                }
            }
        }
        print("[a11y-visited] \(tag): \(visited.joined(separator: ", "))")
        XCTContext.runActivity(named: "[a11y-visited] \(tag): \(visited.joined(separator: ", "))") { _ in }
        for needed in ["Jobs", "Artifacts", "Kanban", "Chat", "Bot Info"] {
            XCTAssertTrue(visited.contains(needed), "\(needed) was reached and audited at \(tag) (visited: \(visited))")
        }
    }

    @MainActor func testD1c_pagesTourLabelsAndTraits() throws {
        try pagesTour(size: .large, dark: false, overrides: [], tag: "large-light")
    }

    @MainActor func testB1c_pagesTourAtAX5DarkWithEverySettingOn() throws {
        try pagesTour(size: .ax5, dark: true, overrides: Set(A11yOverride.allCases), tag: "ax5-all-dark")
    }

    @MainActor func testD1_signedInTourLabelsAndTraits() throws {
        try tour(size: .large, dark: false, overrides: [], tag: "large-light")
    }

    @MainActor func testB1_signedInTourAtAX5DarkWithEverySettingOn() throws {
        try tour(size: .ax5, dark: true, overrides: Set(A11yOverride.allCases), tag: "ax5-all-dark")
    }

    @MainActor func testB1b_signedInTourAtAX3Light() throws {
        try tour(size: .ax3, dark: false, overrides: [.boldText], tag: "ax3-bold-light")
    }
}
