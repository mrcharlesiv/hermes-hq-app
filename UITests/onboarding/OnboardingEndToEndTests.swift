// [onboarding] End-to-end checks for docs/spec/3x-onboarding.md §9.2 (O01–O25): the real app, real taps, and the
// stand-in gateway's ledger (scripts/fixtures/onboarding-gateway.py) as the wire evidence. Run with
// scripts/e2e-onboarding.sh <SIM_UDID>.

import XCTest

final class OnboardingEndToEndTests: XCTestCase {
    var a: SettingsFixture!
    var app: XCUIApplication!

    static let environment = ProcessInfo.processInfo.environment
    static var dark: Bool { environment["HQN_SHOTS_DARK"] == "1" }
    static var scheme: String { environment["HQN_UI_SCHEME"] ?? "hermeshq-native" }
    static var shotsFolder: String? { environment["HQN_SHOTS"].flatMap { $0.isEmpty ? nil : $0 } }

    override func setUpWithError() throws {
        continueAfterFailure = false
        a = try SettingsFixture.load("HQN_ONBOARDING_A")
        try a.control("/__settings/reset", [:])
        try a.control("/__onboarding/reset", [:])
    }

    // MARK: - O01 Welcome

    @MainActor func testO01_WelcomeAndFirstSteps() throws {
        launch()
        XCTAssertTrue(app.staticTexts["onboarding.welcome"].waitForExistence(timeout: 15), "a clean first run starts on the welcome")
        XCTAssertEqual(app.staticTexts["onboarding.welcome"].label, "Your Hermes, wherever you are.")
        for text in ["Hermes stays on your computer.", "Hermes HQ connects your iPhone to it.", "Only you can get in.", "Hermes HQ never stores your password."] {
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists, text)
        }
        XCTAssertFalse(app.textFields["sign-in-address"].exists, "no form yet")
        XCTAssertFalse(app.navigationBars.buttons.firstMatch.exists, "nothing to go back to")
        XCTAssertEqual(app.buttons["onboarding.welcome.start"].label, "Get Started")
        XCTAssertEqual(app.buttons["onboarding.welcome.address"].label, "I Already Have an Address")
        shot("01-welcome")

        // Get Started asks one plain question: a row per answer, nothing else.
        app.buttons["onboarding.welcome.start"].tap()
        XCTAssertTrue(heading("onboarding.start").waitForExistence(timeout: 5))
        XCTAssertEqual(heading("onboarding.start").label, "Where is your Hermes?")
        for (id, title) in [("computer", "On my computer"), ("cloud", "On Hermes Cloud"), ("none", "I don’t have Hermes yet")] {
            XCTAssertTrue(app.buttons["onboarding.start.\(id)"].label.hasPrefix(title), "\(id): \(app.buttons["onboarding.start.\(id)"].label)")
        }
        XCTAssertFalse(text(containing: "Tailscale").exists, "no jargon before a path is picked")
        shot("01-start")
        tap("onboarding.start.computer")
        XCTAssertTrue(heading("onboarding.hermes").waitForExistence(timeout: 5))
        XCTAssertEqual(heading("onboarding.hermes").label, "Let Hermes set it up.")
        XCTAssertTrue(app.buttons["onboarding.hermes.copy"].isHittable && app.buttons["onboarding.hermes.have-address"].isHittable
                      && app.buttons["onboarding.hermes.myself"].isHittable, "the message and both ways on show without scrolling")
        back()
        XCTAssertTrue(heading("onboarding.start").waitForExistence(timeout: 5), "Back returns to the question")
        back()
        XCTAssertTrue(app.buttons["onboarding.welcome.start"].waitForExistence(timeout: 5), "Back returns to the welcome")

        app.buttons["onboarding.welcome.address"].tap()
        XCTAssertTrue(app.textFields["sign-in-address"].waitForExistence(timeout: 5), "the form")
        XCTAssertEqual(app.buttons["sign-in-help"].label, "Need help connecting?")
        back()
        XCTAssertTrue(app.buttons["onboarding.welcome.start"].waitForExistence(timeout: 5))
        assertNothingForbidden()
    }

    // MARK: - O02 the back stack

    @MainActor func testO02_BackStackLoops() throws {
        launch()
        start()
        tap("onboarding.hermes.have-address")
        XCTAssertTrue(app.textFields["sign-in-address"].waitForExistence(timeout: 5))
        tap("sign-in-help")                                           // pops back to "Let Hermes set it up"
        XCTAssertTrue(heading("onboarding.hermes").waitForExistence(timeout: 5))
        back(); back()
        XCTAssertTrue(app.buttons["onboarding.welcome.start"].waitForExistence(timeout: 5), "two Backs from the message: the question, the welcome")

        // The long way: hermes → where → mac 1, 2, 3 → form → help → hermes; two Backs are the welcome (no duplicates under it).
        start(); tap("onboarding.hermes.myself"); tap("onboarding.where.mac")
        tap("onboarding.mac-1.next"); tap("onboarding.mac-2.next"); tap("onboarding.mac-3.type-address")
        XCTAssertTrue(app.textFields["sign-in-address"].waitForExistence(timeout: 5))
        tap("sign-in-help")
        XCTAssertTrue(heading("onboarding.hermes").waitForExistence(timeout: 5))
        back(); back()
        XCTAssertTrue(app.buttons["onboarding.welcome.start"].waitForExistence(timeout: 5))

        // The edge swipe goes back one screen, like Back.
        start(); tap("onboarding.hermes.myself")
        XCTAssertTrue(heading("onboarding.where").waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.5)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        XCTAssertTrue(heading("onboarding.hermes").waitForExistence(timeout: 5), "swipe back")
        XCTAssertFalse(heading("onboarding.where").exists)

        // STRESS 4: a double tap is one push. Two fast taps on "Set It Up Myself", then one Back is "Let Hermes".
        app.buttons["onboarding.hermes.myself"].doubleTap()
        XCTAssertTrue(heading("onboarding.where").waitForExistence(timeout: 5))
        back()
        XCTAssertTrue(heading("onboarding.hermes").waitForExistence(timeout: 5), "one push, not two")

        // STRESS 2 (short): the loop ten times, fast; the welcome is always two Backs from "Let Hermes".
        for _ in 0..<10 {
            tap("onboarding.hermes.have-address")
            tap("sign-in-help")
        }
        back(); back()
        XCTAssertTrue(app.buttons["onboarding.welcome.start"].waitForExistence(timeout: 5), "no leaked screens under the guide")
    }

    // MARK: - O03 Where does Hermes run?

    @MainActor func testO03_WhereAndInstallLink() throws {
        let out = guideOut()
        launch(["-HQDebugGuideOut", out, "-HQDebugGuideFail", "open"])
        start(); tap("onboarding.hermes.myself")
        XCTAssertEqual(heading("onboarding.where").label, "Which computer runs Hermes?")
        XCTAssertEqual(app.navigationBars.staticTexts.firstMatch.label, "Set it up yourself", "the small title on the bar row")
        let rows = ["mac": "On a Mac", "linux": "On Linux or a server", "windows": "On Windows"]
        for (id, title) in rows {
            XCTAssertTrue(app.buttons["onboarding.where.\(id)"].label.hasPrefix(title), "\(id): \(app.buttons["onboarding.where.\(id)"].label)")
        }
        XCTAssertFalse(app.buttons["onboarding.where.address"].exists || app.buttons["onboarding.where.cloud"].exists, "only the computers")
        shot("03-where")
        for (id, next) in [("mac", "onboarding.mac-1"), ("linux", "onboarding.linux-1"), ("windows", "onboarding.other-1")] {
            tap("onboarding.where.\(id)")
            XCTAssertTrue(heading(next).waitForExistence(timeout: 5), next)
            back()
            XCTAssertTrue(heading("onboarding.where").waitForExistence(timeout: 5))
        }
        // No Hermes yet: its own row on the first question, and a screen with the two ways to get one. Install asks for
        // the docs; with opening made to fail, the line says where to go by hand.
        back(); back()
        tap("onboarding.start.none")
        XCTAssertEqual(heading("onboarding.get-hermes").label, "Get Hermes first.")
        XCTAssertTrue(app.buttons["onboarding.get-hermes.cloud"].label.hasPrefix("Start one on Hermes Cloud"))
        XCTAssertTrue(app.buttons["onboarding.get-hermes.install"].label.hasPrefix("Install it on a computer"))
        shot("03-get-hermes")
        tap("onboarding.get-hermes.install")
        XCTAssertTrue(waitUntil(timeout: 5) { self.read(out, "open.txt") == "https://hermes-agent.nousresearch.com/docs/" }, "the row asked for the docs")
        let error = app.descendants(matching: .any)["onboarding.get-hermes.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(error.label, "Couldn’t open the guide. Open this address in Safari: https://hermes-agent.nousresearch.com/docs/")
        shot("03-get-hermes-link-error")
        // Installed: the way on is a button here, not a trip back.
        XCTAssertTrue(text(containing: "Nous credit").exists || text(containing: "Nous account").exists || app.buttons["onboarding.get-hermes.cloud"].label.contains("Nous"), "the cost is said on the row")
        XCTAssertEqual(app.buttons["onboarding.get-hermes.installed"].label, "I’ve Installed Hermes")
        tap("onboarding.get-hermes.installed")
        XCTAssertTrue(heading("onboarding.hermes").waitForExistence(timeout: 5), "on to the setup message")
        back(); back()
        XCTAssertTrue(heading("onboarding.start").waitForExistence(timeout: 5))
    }

    // MARK: - O04 Let Hermes set it up: Copy and Send…

    @MainActor func testO04_LetHermesCopyAndShare() throws {
        let out = guideOut()
        launch(["-HQDebugGuideOut", out])
        start()
        XCTAssertTrue(heading("onboarding.hermes").waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["onboarding.hermes.status"].exists, "no line before a tap")
        shot("04-hermes")
        tap("onboarding.hermes.copy")
        let status = app.staticTexts["onboarding.hermes.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "Copied. Paste it into your chat with Hermes.")
        let copied = read(out, "copy.txt") ?? ""
        XCTAssertTrue(copied.hasPrefix("Please connect this computer to Hermes HQ, the iPhone app for Hermes"), copied)
        XCTAssertTrue(copied.contains("curl -fsSL https://raw.githubusercontent.com/mrcharlesiv/hermes-hq/main/connect.sh | sh -s -- --agent"))
        XCTAssertTrue(copied.contains("my phone doesn't need Tailscale"))
        shot("04-hermes-copied")

        // Show the message: the same text, on the page.
        let disclosure = app.buttons["onboarding.hermes.show-message"]
        XCTAssertEqual(disclosure.value as? String, "Collapsed")
        disclosure.tap()
        let message = app.staticTexts["onboarding.hermes.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertEqual(message.label, copied, "what is shown is what is copied")
        XCTAssertEqual(disclosure.value as? String, "Expanded")
        shot("04-hermes-message")

        // Send…: the system share sheet with the same text; the line clears.
        reveal(app.buttons["onboarding.hermes.share"])
        app.buttons["onboarding.hermes.share"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.read(out, "share.txt") == copied }, "the share sheet got the message")
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 8) || app.navigationBars["UIActivityContentView"].exists, "the share sheet")
        shot("04-hermes-share-sheet")
        closeShareSheet()
        XCTAssertTrue(waitUntil(timeout: 5) { !self.app.staticTexts["onboarding.hermes.status"].exists }, "a share that opened leaves no line")

        // STRESS 3 (short): Copy twenty times fast: one line, the pasteboard text unchanged.
        reveal(app.buttons["onboarding.hermes.copy"])
        for _ in 0..<20 { app.buttons["onboarding.hermes.copy"].tap() }
        XCTAssertEqual(app.staticTexts["onboarding.hermes.status"].label, "Copied. Paste it into your chat with Hermes.")
        XCTAssertEqual(read(out, "copy.txt"), copied)
        XCTAssertEqual(app.staticTexts.matching(identifier: "onboarding.hermes.status").count, 1)
    }

    // MARK: - O05 / O06 the Mac and Linux guides

    @MainActor func testO05_MacGuide() throws {
        let out = guideOut()
        launch(["-HQDebugGuideOut", out])
        start(); tap("onboarding.hermes.myself"); tap("onboarding.where.mac")
        XCTAssertEqual(heading("onboarding.mac-1").label, "Get the setup command onto your Mac.")
        XCTAssertEqual(app.navigationBars.staticTexts.firstMatch.label, "Step 1 of 3")
        let command = "curl -fsSL https://raw.githubusercontent.com/mrcharlesiv/hermes-hq/main/connect.sh | sh"
        XCTAssertEqual(app.staticTexts["onboarding.mac-1.command"].label, command)
        XCTAssertEqual(app.buttons["onboarding.mac-1.share"].label, "Send to Your Mac…")
        shot("05-mac-1")
        tap("onboarding.mac-1.copy")
        XCTAssertTrue(app.staticTexts["onboarding.mac-1.status"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["onboarding.mac-1.status"].label,
                       "Copied. If this iPhone and your Mac use the same Apple Account, press ⌘V in Terminal on your Mac to paste it.")
        XCTAssertEqual(read(out, "copy.txt"), command)
        shot("05-mac-1-copied")

        tap("onboarding.mac-1.next")
        XCTAssertEqual(heading("onboarding.mac-2").label, "Run it in Terminal on your Mac.")
        XCTAssertTrue(text(containing: "Tailscale runs only on your Mac: your iPhone doesn’t need it").exists)
        shot("05-mac-2")
        // R7: the troubleshooting list is closed at first and opens in place.
        let trouble = app.buttons["onboarding.mac-2.trouble"]
        reveal(trouble)
        XCTAssertEqual(trouble.label, "If Terminal shows a problem")
        XCTAssertFalse(app.descendants(matching: .any)["onboarding.mac-2.trouble.0"].exists, "closed at first")
        trouble.tap()
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.mac-2.trouble.0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.mac-2.trouble.5"].exists, "six problems on the Mac")
        XCTAssertFalse(app.descendants(matching: .any)["onboarding.mac-2.trouble.6"].exists)
        XCTAssertTrue(text(containing: "Needs Node.js 20 or newer").exists)
        shot("05-mac-2-trouble")
        app.swipeUp()
        shot("05-mac-2-trouble-end")
        tap("onboarding.mac-2.next")
        XCTAssertEqual(heading("onboarding.mac-3").label, "Scan the QR code with this iPhone.")
        shot("05-mac-3")
        // The screen kept its state while it stayed on the stack: Back shows the list still open.
        back()
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.mac-2.trouble.0"].waitForExistence(timeout: 5), "still open after Back")
        tap("onboarding.mac-2.next"); tap("onboarding.mac-3.type-address")
        XCTAssertTrue(app.textFields["sign-in-address"].waitForExistence(timeout: 5), "Type the Address Instead → the form")
        assertNothingForbidden()
    }

    @MainActor func testO06_LinuxGuide() throws {
        let out = guideOut()
        launch(["-HQDebugGuideOut", out])
        start(); tap("onboarding.hermes.myself"); tap("onboarding.where.linux")
        XCTAssertEqual(heading("onboarding.linux-1").label, "Get the setup command onto that computer.")
        XCTAssertEqual(app.buttons["onboarding.linux-1.share"].label, "Send…")
        shot("06-linux-1")
        tap("onboarding.linux-1.copy")
        XCTAssertTrue(app.staticTexts["onboarding.linux-1.status"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["onboarding.linux-1.status"].label, "Copied. Paste it into the terminal on that computer, or your SSH session to it.")
        XCTAssertEqual(read(out, "copy.txt"), "curl -fsSL https://raw.githubusercontent.com/mrcharlesiv/hermes-hq/main/connect.sh | sh")
        tap("onboarding.linux-1.next")
        XCTAssertTrue(heading("onboarding.linux-2").waitForExistence(timeout: 5))
        XCTAssertFalse(text(containing: "your Mac").exists, "no Mac words on the Linux path")
        XCTAssertTrue(text(containing: "Tailscale runs only on that computer: your iPhone doesn’t need it").exists)
        shot("06-linux-2")
        let trouble = app.buttons["onboarding.linux-2.trouble"]
        reveal(trouble)
        trouble.tap()
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.linux-2.trouble.6"].waitForExistence(timeout: 5), "seven problems on Linux")
        XCTAssertTrue(text(containing: "Tailscale is installed but not signed in").exists)
        shot("06-linux-2-trouble")
        tap("onboarding.linux-2.next")
        XCTAssertTrue(heading("onboarding.linux-3").waitForExistence(timeout: 5))
        shot("06-linux-3")
        tap("onboarding.linux-3.type-address")
        XCTAssertTrue(app.textFields["sign-in-address"].waitForExistence(timeout: 5))
    }

    // MARK: - O07 Windows and the manual page

    @MainActor func testO07_WindowsAndManual() throws {
        let out = guideOut()
        launch(["-HQDebugGuideOut", out])
        start(); tap("onboarding.hermes.myself"); tap("onboarding.where.windows")
        XCTAssertEqual(heading("onboarding.other-1").label, "Install Tailscale on both.")
        XCTAssertEqual(app.navigationBars.staticTexts.firstMatch.label, "Step 1 of 2")
        XCTAssertTrue(text(containing: "Tailscale is a free app that privately links this iPhone and the computer running Hermes").exists)
        XCTAssertEqual(app.buttons["onboarding.other-1.get-tailscale"].label, "Get Tailscale")
        shot("07-other-1")
        tap("onboarding.other-1.next")
        XCTAssertEqual(heading("onboarding.other-2").label, "Let Hermes do the setup.")
        shot("07-other-2")
        tap("onboarding.other-2.copy")
        XCTAssertTrue(app.staticTexts["onboarding.other-2.status"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["onboarding.other-2.status"].label, "Copied. Paste it into a chat with Hermes on that computer.")
        let prompt = read(out, "copy.txt") ?? ""
        XCTAssertTrue(prompt.contains("HERMES_DASHBOARD_BASIC_AUTH_USERNAME=") && prompt.contains("tailscale serve --bg 9119"), prompt)
        let show = app.buttons["onboarding.other-2.show-message"]
        reveal(show)
        show.tap()
        XCTAssertTrue(app.staticTexts["onboarding.other-2.message"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["onboarding.other-2.message"].label, prompt)
        shot("07-other-2-message")

        let myself = app.descendants(matching: .any)["onboarding.other-2.myself"]
        reveal(myself)
        myself.tap()
        XCTAssertEqual(heading("onboarding.manual").label, "Set it up yourself.")
        XCTAssertEqual(app.navigationBars.staticTexts.firstMatch.label, "Without Hermes’s help")
        shot("07-manual")
        tap("onboarding.manual.copy-all")
        XCTAssertTrue(app.staticTexts["onboarding.manual.status"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["onboarding.manual.status"].label, "Copied. Paste them on your computer, or into a note or message to yourself.")
        let steps = read(out, "copy.txt") ?? ""
        XCTAssertTrue(steps.hasSuffix("web-dashboard\n"), "the steps end as the web's do")
        for line in ["tailscale serve --bg 9119", "openssl rand -base64 32", "HERMES_DASHBOARD_BASIC_AUTH_USERNAME=", "HERMES_DASHBOARD_PUBLIC_URL=", "hermes dashboard --no-open"] {
            XCTAssertTrue(steps.contains(line), line)
        }
        XCTAssertEqual(app.staticTexts["onboarding.manual.serve"].label, "tailscale serve --bg 9119")
        app.swipeUp()
        shot("07-manual-middle")
        app.swipeUp()
        XCTAssertEqual(app.staticTexts["onboarding.manual.start"].label, "hermes dashboard --no-open")
        shot("07-manual-end")
        tap("onboarding.manual.next")
        XCTAssertTrue(app.textFields["sign-in-address"].waitForExistence(timeout: 5), "Next: Sign In → the form")
        tap("sign-in-help")
        XCTAssertTrue(heading("onboarding.hermes").waitForExistence(timeout: 5))
        assertNothingForbidden()
    }

    // MARK: - O08 the failure lines

    @MainActor func testO08_FailureLines() throws {
        let out = guideOut()
        launch(["-HQDebugGuideOut", out, "-HQDebugGuideFail", "copy,share,open"])
        start()
        tap("onboarding.hermes.copy")
        let status = app.staticTexts["onboarding.hermes.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "Couldn’t copy. Tap Send… or Show the message instead.")
        shot("08-hermes-could-not-copy")
        tap("onboarding.hermes.share")
        XCTAssertTrue(waitUntil(timeout: 5) { status.label == "Couldn’t open sharing. Tap Copy instead." }, status.label)
        XCTAssertFalse(app.otherElements["ActivityListView"].exists, "no sheet")
        shot("08-hermes-could-not-share")

        tap("onboarding.hermes.myself"); tap("onboarding.where.mac"); tap("onboarding.mac-1.copy")
        XCTAssertTrue(app.staticTexts["onboarding.mac-1.status"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["onboarding.mac-1.status"].label, "Couldn’t copy. Tap Send to Your Mac… instead.")
        back()
        tap("onboarding.where.linux"); tap("onboarding.linux-1.copy")
        XCTAssertEqual(app.staticTexts["onboarding.linux-1.status"].label, "Couldn’t copy. Tap Send… instead.")
        back()
        tap("onboarding.where.windows")
        tap("onboarding.other-1.get-tailscale")
        let error = app.descendants(matching: .any)["onboarding.other-1.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(error.label, "Couldn’t open it. Open this address in Safari: https://apps.apple.com/app/tailscale/id1470499037")
        XCTAssertEqual(read(out, "open.txt"), "https://apps.apple.com/app/tailscale/id1470499037")
        shot("08-other-1-could-not-open")
        tap("onboarding.other-1.next"); tap("onboarding.other-2.copy")
        XCTAssertEqual(app.staticTexts["onboarding.other-2.status"].label, "Couldn’t copy. Tap Show the message to select it.")
        let myself = app.descendants(matching: .any)["onboarding.other-2.myself"]
        reveal(myself)
        myself.tap()
        tap("onboarding.manual.copy-all")
        XCTAssertEqual(app.staticTexts["onboarding.manual.status"].label, "Couldn’t copy. The steps are listed below.")
        shot("08-manual-could-not-copy")
    }

    // MARK: - O09 "Need help connecting?" at the root and in the Add Gateway sheet

    @MainActor func testO09_HelpLinkFromForm() throws {
        launch()
        tap("onboarding.welcome.address")
        let help = app.buttons["sign-in-help"]
        XCTAssertTrue(help.waitForExistence(timeout: 5))
        XCTAssertEqual(help.label, "Need help connecting?")
        // The web's heading and first lead for the form inside the flow (D36).
        XCTAssertEqual(app.staticTexts["sign-in-heading"].label, "Sign in to Hermes.")
        XCTAssertTrue(app.staticTexts["Paste or type the address of your Hermes, then sign in."].exists, "the lead before an address is typed")
        shot("09-form-first-run")
        XCTAssertTrue(app.buttons["sign-in-paste"].exists, "Paste, while the address is empty")
        help.tap()
        XCTAssertTrue(heading("onboarding.start").waitForExistence(timeout: 5), "help from a form that came first opens the question")
        tap("onboarding.start.computer")
        // DECISION D7: what was typed survives a trip to the guide.
        tap("onboarding.hermes.have-address")
        let address = app.textFields["sign-in-address"]
        address.tap(); address.typeText("kept.example.com")
        XCTAssertFalse(app.buttons["sign-in-paste"].exists, "Paste makes way for what was typed")
        tap("sign-in-help")                                           // back to the message it came from
        tap("onboarding.hermes.have-address")
        XCTAssertEqual(app.textFields["sign-in-address"].value as? String, "kept.example.com", "the address is kept")
        // Sign in, then the same link in the Add Gateway sheet, where every guide page also has Cancel.
        signIn(a)
        XCTAssertTrue(botsShow(), "signed in")
        openAddGateway()
        XCTAssertTrue(app.buttons["add-gateway.cancel"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["onboarding.welcome.start"].exists, "the sheet has no welcome")
        XCTAssertEqual(app.staticTexts["sign-in-heading"].label, "Add another Hermes.", "the heading when adding one (UX study #24)")
        let sheetHelp = app.buttons["sign-in-help"]
        reveal(sheetHelp)
        shot("09-add-gateway-form")
        sheetHelp.tap()
        XCTAssertTrue(heading("onboarding.start").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["add-gateway.cancel"].exists, "Cancel on a guide page of the sheet")
        shot("09-add-gateway-guide")
        tap("onboarding.start.computer"); tap("onboarding.hermes.myself"); tap("onboarding.where.mac")
        XCTAssertTrue(heading("onboarding.mac-1").waitForExistence(timeout: 5))
        app.buttons["add-gateway.cancel"].tap()
        XCTAssertTrue(app.buttons["gateway.add"].waitForExistence(timeout: 8), "Cancel closes the whole sheet")
        // Reopened, the sheet starts over on the form.
        app.buttons["gateway.add"].tap()
        XCTAssertTrue(app.textFields["sign-in-address"].waitForExistence(timeout: 8))
        XCTAssertFalse(heading("onboarding.mac-1").exists)
    }

    // MARK: - O10 Name at sign-in

    @MainActor func testO10_NameAtSignIn() throws {
        launch()
        tap("onboarding.welcome.address")
        fillSignIn(a)
        let name = app.textFields["sign-in-name"]
        reveal(name)
        XCTAssertEqual(name.placeholderValue, "Optional, like Home Mac")
        name.tap()
        name.typeText("  Office Mac " + String(repeating: "x", count: 70))
        XCTAssertEqual((name.value as? String)?.count, 60, "the field stops at sixty")
        shot("10-form-name")
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 47))    // back to "  Office Mac "
        name.typeText("\n")                                                                  // Return signs in
        XCTAssertTrue(botsShow(), "Return in the Name field signs in")
        // The login carried only what a login needs: the Name never goes to the gateway.
        let bodies = (state()["login_bodies"] as? [[String]]) ?? []
        XCTAssertEqual(bodies.count, 1, "one sign-in")
        XCTAssertFalse(bodies.joined().contains { $0.lowercased().contains("label") || $0.lowercased().contains("name") && $0 != "username" },
                       "the Name stays on the phone: \(bodies)")
        // …and it names the gateway in Settings › Gateway.
        openSettings()
        let named = app.staticTexts.matching(NSPredicate(format: "label == %@", "Office Mac")).firstMatch
        let anywhere = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Office Mac")).firstMatch
        XCTAssertTrue(named.waitForExistence(timeout: 5) || anywhere.exists, "the gateway is called by its Name, trimmed")
        shot("10-settings-named-gateway")
    }

    // MARK: - O11 the Update screen

    @MainActor func testO11_OutdatedScreen() throws {
        try a.control("/__onboarding/status", ["release_date": "2026.9.20", "version": "0.13.0"])
        launch()
        tap("onboarding.welcome.address")
        signIn(a)
        let title = app.staticTexts["update-hermes.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), "an older gateway shows the Update screen before the app")
        XCTAssertEqual(title.label, "Update Hermes")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "the app is not on show yet")
        XCTAssertEqual(app.staticTexts["update-hermes.recovery"].label,
                       "Hermes HQ needs a newer version of Hermes than the computer running Hermes has, and parts of the app won’t work until it’s updated. On the computer running Hermes, run “hermes update”, then check again.")
        XCTAssertEqual(app.staticTexts["update-hermes.release"].label, "Hermes 0.13.0 · released 2026.9.20")
        XCTAssertEqual(app.staticTexts["update-hermes.name"].label, "Your Gateway")
        XCTAssertEqual(app.buttons["update-hermes.check"].label, "Check Again")
        XCTAssertEqual(app.buttons["update-hermes.continue"].label, "Continue Anyway")
        XCTAssertFalse(app.navigationBars.buttons.firstMatch.exists, "no Back")
        // The system's "Save Password?" sheet arrives seconds after the sign-in on a busy Mac (seen 5 s and more): wait
        // for it and clear it before anything is tapped or photographed, so no tap or shot lands on it.
        dismissSavePassword(wait: 15)
        XCTAssertTrue(waitUntil(timeout: 5) { self.app.buttons["update-hermes.check"].isHittable },
                      "Check Again can be tapped (nothing of the system's is over the screen)")
        shot("11-update")
        XCTAssertEqual((state()["status_reads"] as? [String: Any])?["authed"] as? Int, 1, "one read of the version")

        // Check Again while it is still older: the line says so and the card shows what the gateway reports now.
        try a.control("/__onboarding/status", ["version": "0.13.1", "can_update_hermes": false, "mode": "slow", "delay_ms": 3000, "count": 1])
        let status = app.staticTexts["update-hermes.status"]
        // A tap the system sheet took reads nothing (the fixture's count is untouched), so tapping once more after
        // clearing the sheet is the same single check.
        var said = false
        for _ in 0..<3 where !said {
            dismissSavePassword()
            app.buttons["update-hermes.check"].tap()
            said = status.waitForExistence(timeout: 3)
        }
        if !said { shot("11-update-no-status") }
        XCTAssertTrue(said, "Check Again shows its status line at once")
        XCTAssertEqual(status.label, "Checking…", "the line while the gateway is asked")
        XCTAssertFalse(app.buttons["update-hermes.check"].isEnabled && app.buttons["update-hermes.continue"].isEnabled, "both off while checking")
        shot("11-update-checking")
        XCTAssertTrue(waitUntil(timeout: 12) { status.label == "Still the older version. An update can take a few minutes." }, status.label)
        XCTAssertEqual(app.staticTexts["update-hermes.release"].label, "Hermes 0.13.1 · released 2026.9.20", "the card shows what the gateway reports now")
        XCTAssertTrue(app.staticTexts["update-hermes.recovery"].label.hasSuffix("Update Hermes on the computer running Hermes the way it was installed, then check again."),
                      "the recovery line for a gateway that cannot update itself: \(app.staticTexts["update-hermes.recovery"].label)")
        shot("11-update-still-older")

        // STRESS 5: taps as fast as the test can make them while each answer takes 800 ms. XCUITest waits for the app
        // to settle between taps, so this proves only that reads never outnumber taps and the screen ends steady; that
        // taps during one check start no second read is UpdateHermesModelTests.oneCheckAtATimeAndContinueWaitsForIt.
        try a.control("/__onboarding/status", ["mode": "slow", "delay_ms": 800])
        let before = ((state()["status_reads"] as? [String: Any])?["authed"] as? Int) ?? 0
        let check = app.buttons["update-hermes.check"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        for _ in 0..<12 { check.tap() }
        XCTAssertTrue(waitUntil(timeout: 8) { status.label.hasPrefix("Still the older version") && self.app.buttons["update-hermes.check"].isEnabled },
                      "the screen ends steady after the burst: \(status.label)")
        let after = ((state()["status_reads"] as? [String: Any])?["authed"] as? Int) ?? 0
        XCTAssertLessThanOrEqual(after - before, 12, "never more reads than taps (\(after - before) for 12 taps)")
        XCTAssertGreaterThanOrEqual(after - before, 1, "the burst read the version at least once")
        XCTAssertTrue(app.staticTexts["update-hermes.title"].exists, "an older gateway never lets a check through")

        // Updated: Check Again enters the app.
        try a.control("/__onboarding/status", ["release_date": "2026.10.01", "version": "0.21.5", "mode": "ok"])
        leaveUpdate("update-hermes.check")
        XCTAssertTrue(botsShow(), "a new enough gateway enters")
        XCTAssertFalse(app.staticTexts["update-hermes.title"].exists, "the Update screen is gone once the app shows")
    }

    // MARK: - O12 Continue Anyway, relaunch, and the sheet

    @MainActor func testO12_OutdatedRelaunchAndSheet() throws {
        let b = try SettingsFixture.load("HQN_ONBOARDING_B")
        try b.control("/__settings/reset", [:])
        try b.control("/__onboarding/reset", [:])
        try b.control("/__onboarding/status", ["release_date": "2026.9.10", "version": "0.12.0"])
        try a.control("/__onboarding/status", ["release_date": "2026.9.20", "version": NSNull()])
        launch()
        tap("onboarding.welcome.address")
        signIn(a)
        XCTAssertTrue(app.staticTexts["update-hermes.title"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts["update-hermes.release"].label, "Hermes · released 2026.9.20", "no version reported: just Hermes")
        dismissSavePassword(wait: 2)
        leaveUpdate("update-hermes.continue")
        XCTAssertTrue(botsShow(), "Continue Anyway enters")

        // A relaunch with the saved sign-in goes straight to the app: the screen belongs to a typed sign-in only.
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-HQDebugWelcome", "YES", "-HQDebugNoDrag", "YES"] + appearance
        app.launch()
        XCTAssertTrue(botsShow(), "a saved sign-in is never held at the Update screen")
        XCTAssertFalse(app.staticTexts["update-hermes.title"].exists)

        // Add Gateway to an older gateway: the Update screen takes over the sheet, with no Cancel and no swipe down.
        openAddGateway()
        signIn(b)
        XCTAssertTrue(app.staticTexts["update-hermes.title"].waitForExistence(timeout: 20), "the Update screen in the sheet")
        XCTAssertEqual(app.staticTexts["update-hermes.release"].label, "Hermes 0.12.0 · released 2026.9.10")
        // (No count of status reads here: the app under the sheet is already on this gateway, and Settings, which is
        // open under it, reads the same endpoint once per run for its version line. O11 and O19 count, before the app.)
        XCTAssertFalse(app.buttons["add-gateway.cancel"].exists, "no Cancel on it")
        // (the page under the sheet still has its own bar: only a button that can be tapped counts)
        XCTAssertFalse(app.navigationBars.buttons.allElementsBoundByIndex.contains { $0.isHittable }, "and no Back")
        dismissSavePassword(wait: 2)
        shot("12-update-in-sheet")
        app.staticTexts["update-hermes.title"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(app.staticTexts["update-hermes.title"].waitForExistence(timeout: 2), "the sheet does not swipe away")
        // Neither swipe back leaves it: from the left edge, and iOS 26's from anywhere in the content.
        for (from, to) in [(0.0, 0.8), (0.3, 0.9)] {
            app.coordinate(withNormalizedOffset: CGVector(dx: from, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: to, dy: 0.5)))
            Thread.sleep(forTimeInterval: 0.8)
            XCTAssertTrue(app.staticTexts["update-hermes.title"].exists, "a swipe back from \(from) does not leave the Update screen")
            XCTAssertFalse(app.textFields["sign-in-address"].exists, "…and the form is not back")
        }
        leaveUpdate("update-hermes.continue")
        XCTAssertTrue(waitUntil(timeout: 15) { !self.app.staticTexts["update-hermes.title"].exists }, "Continue Anyway closes the sheet")
        let listed = waitUntil(timeout: 15) { self.app.descendants(matching: .any)["gateway-row-\(b.hostPort)"].exists }
        XCTAssertTrue(listed, "the second gateway is saved")
        shot("12-two-gateways")
    }

    // MARK: - O13 a slow or broken status never blocks

    @MainActor func testO13_SlowAndBrokenStatus() throws {
        // STRESS 7, 8: each of these must go straight in; the slow one at the four-second cap.
        let cases: [(String, [String: Any])] = [
            ("slow", ["release_date": "2026.9.20", "mode": "slow", "delay_ms": 10000]),
            ("500", ["release_date": "2026.9.20", "mode": "500"]),
            ("garbage", ["release_date": "2026.9.20", "mode": "garbage"]),
            ("drop", ["release_date": "2026.9.20", "mode": "drop"]),
            ("array", ["raw": "[]"]),
            ("null", ["raw": "null"]),
            ("text", ["raw": "\"2026.9.20\""]),
            ("odd-date", ["release_date": "٢٠٢٦.٩.٢٠"]),
            ("number-date", ["release_date": 20260920]),
            ("big", ["release_date": "2026.10.01", "pad_bytes": 2_000_000]),
        ]
        for (index, (name, control)) in cases.enumerated() {
            try a.control("/__onboarding/reset", [:])
            try a.control("/__onboarding/status", control)
            launch()
            tap("onboarding.welcome.address")
            fillSignIn(a)
            let started = Date()
            tapSignIn()
            if name == "slow" {
                // While the form is busy (signed in, the check still out), a swipe back from the content moves nothing.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
                XCTAssertFalse(app.buttons["onboarding.welcome.start"].exists, "a busy form is not swiped back to the welcome")
                XCTAssertTrue(app.textFields["sign-in-address"].exists || app.cells["bot-row-ivy"].exists, "the form stays until the app shows")
            }
            XCTAssertTrue(botsShow(timeout: 25), "\(name): straight into the app")
            let took = Date().timeIntervalSince(started)
            XCTAssertFalse(app.staticTexts["update-hermes.title"].exists, "\(name): never the Update screen on a guess")
            if name == "slow" {
                XCTAssertGreaterThan(took, 3.5, "the form waited for the check")
                XCTAssertLessThan(took, 9.5, "…but only to the cap, not the 10 s answer (\(took))")
                // The late answer (10 s) must not bring the Update screen up over the app.
                Thread.sleep(forTimeInterval: 8)
                XCTAssertFalse(app.staticTexts["update-hermes.title"].exists, "a late answer is dropped")
                XCTAssertTrue(app.cells["bot-row-ivy"].exists)
            }
            if index < cases.count - 1 { app.terminate() }
        }
    }

    // MARK: - O14 an unreadable saved sign-in

    @MainActor func testO14_UnreadableSignIn() throws {
        launch()
        tap("onboarding.welcome.address")
        signIn(a)
        XCTAssertTrue(botsShow())
        // A draft typed under this sign-in (spec §5.16 acceptance 4).
        let draft = "half a thought \(Int(Date().timeIntervalSince1970) % 100_000)"
        let composer = app.textViews["composer.text"]
        app.cells["bot-row-ivy"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 8), "the chat opens")
        dismissSavePassword(wait: 2)
        clearDraft(composer)
        composer.tap()
        composer.typeText(draft)
        XCTAssertEqual(composer.value as? String, draft)
        back()
        XCTAssertTrue(app.cells["bot-row-ivy"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2)   // the draft is written a moment after typing stops
        app.terminate()

        app = XCUIApplication()
        app.launchArguments = ["-HQDebugCorruptSignIn", "YES", "-HQDebugNoDrag", "YES"] + appearance
        app.launch()
        // After the merge this is the offline screen (spec D27): the same words, its own retry line and buttons.
        let title = el("offline.title")
        XCTAssertTrue(title.waitForExistence(timeout: 15), "the problem is said, not hidden")
        XCTAssertEqual(title.label, "Can’t Read Your Saved Sign-In")
        XCTAssertEqual(el("offline.recovery").label, "Sign in again to continue. Drafts on this iPhone are kept aside, not moved to the account you sign in with.")
        XCTAssertTrue(app.buttons["offline.try-again"].exists && app.buttons["offline.sign-in-again"].exists)
        XCTAssertEqual(app.buttons["offline.sign-in-again"].label, "Sign In Again")
        XCTAssertFalse(app.textFields["sign-in-address"].exists, "never a silent sign-in form")
        assertNothingForbidden()
        shot("14-unreadable")
        tapOffline("offline.try-again")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(title.exists && title.label == "Can’t Read Your Saved Sign-In", "Try Again reads it again; still unreadable")

        tapOffline("offline.sign-in-again")
        let alert = app.alerts["Sign In Again?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts["Hermes HQ couldn’t read your saved sign-in. Drafts on this iPhone are kept aside and won’t move to the account you sign in with."].exists)
        shot("14-unreadable-confirm")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Cancel changes nothing")
        // STRESS 38: away and back on the alert: it is still there, alone, and nothing was discarded.
        tapOffline("offline.sign-in-again")
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        awayAndBack()
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "the alert survives a trip away")
        XCTAssertEqual(app.alerts.count, 1, "never two alerts")
        alert.buttons["Sign In Again"].tap()
        XCTAssertTrue(app.textFields["sign-in-address"].waitForExistence(timeout: 10), "the sign-in form, in a sheet over the screen")
        XCTAssertTrue(app.buttons["offline.sign-in.cancel"].exists, "with Cancel")
        // DECISION D29: the form's error sentences name this link, so it is here too.
        XCTAssertTrue(app.buttons["sign-in-help"].exists, "Need help connecting? in the sheet")
        shot("14-unreadable-form")
        // Cancel returns to the screen, which never stopped; then the sheet again, away and back on it.
        app.buttons["offline.sign-in.cancel"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !self.app.textFields["sign-in-address"].exists }, "Cancel closes the sheet")
        XCTAssertEqual(title.label, "Can’t Read Your Saved Sign-In", "still unreadable: Cancel discarded nothing")
        tapOffline("offline.sign-in-again")
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Sign In Again"].tap()
        XCTAssertTrue(app.textFields["sign-in-address"].waitForExistence(timeout: 10))
        awayAndBack()
        XCTAssertTrue(app.textFields["sign-in-address"].waitForExistence(timeout: 5), "the sheet survives a trip away")
        XCTAssertFalse(app.alerts.firstMatch.exists, "and no alert came back over it")
        signIn(a)
        XCTAssertTrue(botsShow(), "signing in again works")
        // The same address and username: the same account, and its draft is back in the chat.
        app.cells["bot-row-ivy"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        dismissSavePassword(wait: 2)
        XCTAssertTrue(waitUntil(timeout: 5) { (composer.value as? String) == draft }, "the draft came back: \(String(describing: composer.value))")
        shot("14-unreadable-draft-back")
        clearDraft(composer)
        back()
        XCTAssertTrue(app.cells["bot-row-ivy"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2)

        // The next launch reads the new sign-in: the problem is gone for good.
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-HQDebugNoDrag", "YES"] + appearance
        app.launch()
        XCTAssertTrue(botsShow())
    }

    // MARK: - O15 a connect link while the guide is up

    @MainActor func testO15_ConnectLinkDuringGuide() throws {
        launch()
        start(); tap("onboarding.hermes.myself"); tap("onboarding.where.mac")
        tap("onboarding.mac-1.next"); tap("onboarding.mac-2.next")
        XCTAssertTrue(heading("onboarding.mac-3").waitForExistence(timeout: 5))
        // The setup's QR code is this link (an invented address on the documentation domain).
        open("\(Self.scheme)://connect?url=https%3A%2F%2Fexample-mac.example.com")
        let address = app.textFields["sign-in-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10), "the link moves to the form")
        XCTAssertEqual(address.value as? String, "https://example-mac.example.com")
        shot("15-link-form")
        back()
        XCTAssertTrue(heading("onboarding.mac-3").waitForExistence(timeout: 5), "the guide is still under the form")
        // STRESS 16: a bad link is ignored; the guide stays where it was.
        open("\(Self.scheme)://connect?url=javascript%3Aalert(1)")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(heading("onboarding.mac-3").exists && !address.exists, "a bad link changes nothing")
        // …and good links in a row show the form once, with the last address.
        for n in 1...3 { open("\(Self.scheme)://connect?url=https%3A%2F%2Fmac-\(n).example.com") }
        XCTAssertTrue(waitUntil(timeout: 15) { address.exists && (address.value as? String) == "https://mac-3.example.com" }, "the form shows the link's address")
        back()
        XCTAssertTrue(heading("onboarding.mac-3").waitForExistence(timeout: 5), "one form on the stack, not three")

        // A password typed for one address never rides a link to another address. (Connect links are https only, so the
        // stand-in's own http address cannot come by link: an invented host stands in; nothing is signed in to.)
        let own = "https://mac-3.example.com"
        let ownLink = "\(Self.scheme)://connect?url=https%3A%2F%2Fmac-3.example.com"
        open(ownLink)
        XCTAssertTrue(waitUntil(timeout: 15) { address.exists && (address.value as? String) == own }, "the form shows the link's address")
        let password = app.secureTextFields["sign-in-password"]
        XCTAssertTrue(password.waitForExistence(timeout: 15), "an address that does not answer shows both ways in")
        settle(password)
        password.tap()
        password.typeText("not-a-real-password")
        let filled: () -> Bool = { let v = (password.value as? String) ?? ""; return !v.isEmpty && v != password.placeholderValue }
        XCTAssertTrue(filled(), "a password is typed")
        open(ownLink)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(filled(), "the same address again keeps what was typed")
        open("\(Self.scheme)://connect?url=https%3A%2F%2Fother-host.example.com")
        XCTAssertTrue(waitUntil(timeout: 15) { address.exists && (address.value as? String) == "https://other-host.example.com" })
        open(ownLink)
        XCTAssertTrue(waitUntil(timeout: 15) { address.exists && (address.value as? String) == own })
        XCTAssertTrue(password.waitForExistence(timeout: 15))
        XCTAssertFalse(filled(), "the password did not follow the link to another host and back")
    }

    // MARK: - O16 every screen at the largest type

    @MainActor func testO16_LargestTypeWalk() throws {
        launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(app.buttons["onboarding.welcome.start"].waitForExistence(timeout: 15))
        shot("16-xxxl-welcome")
        reach("onboarding.welcome.start")
        shot("16-xxxl-welcome-end")
        tap("onboarding.welcome.start")
        shot("16-xxxl-start")
        reach("onboarding.start.none")
        shot("16-xxxl-start-end")
        reach("onboarding.start.computer"); tap("onboarding.start.computer")
        shot("16-xxxl-hermes")
        reach("onboarding.hermes.myself")
        shot("16-xxxl-hermes-end")
        tap("onboarding.hermes.myself")
        shot("16-xxxl-where")
        reach("onboarding.where.mac"); tap("onboarding.where.mac")
        shot("16-xxxl-mac-1")
        reach("onboarding.mac-1.next"); tap("onboarding.mac-1.next")
        shot("16-xxxl-mac-2")
        reach("onboarding.mac-2.next"); tap("onboarding.mac-2.next")
        shot("16-xxxl-mac-3")
        reach("onboarding.mac-3.type-address"); tap("onboarding.mac-3.type-address")
        XCTAssertTrue(app.textFields["sign-in-address"].waitForExistence(timeout: 5))
        shot("16-xxxl-form")
        reach("sign-in-help")
        shot("16-xxxl-form-end")
        tap("sign-in-help")                                           // back to the message
        reach("onboarding.hermes.myself"); tap("onboarding.hermes.myself")
        reach("onboarding.where.windows"); tap("onboarding.where.windows")
        shot("16-xxxl-other-1")
        reach("onboarding.other-1.next"); tap("onboarding.other-1.next")
        shot("16-xxxl-other-2")
        reach("onboarding.other-2.myself")
        app.descendants(matching: .any)["onboarding.other-2.myself"].tap()
        shot("16-xxxl-manual")
        reach("onboarding.manual.next")
        shot("16-xxxl-manual-end")
        // The Update screen at this size.
        try a.control("/__onboarding/status", ["release_date": "2026.9.20", "version": "0.13.0"])
        tap("onboarding.manual.next")
        signIn(a)
        XCTAssertTrue(app.staticTexts["update-hermes.title"].waitForExistence(timeout: 20))
        dismissSavePassword(wait: 2)
        shot("16-xxxl-update")
        reach("update-hermes.continue")
        shot("16-xxxl-update-end")
        XCTAssertTrue(app.buttons["update-hermes.check"].exists && app.buttons["update-hermes.continue"].isHittable, "both buttons reachable")
    }

    // MARK: - O26 already on Tailscale (native only): the --private command and message

    @MainActor func testO26_TailnetOnlyChoice() throws {
        let out = guideOut()
        launch(["-HQDebugGuideOut", out])
        start()
        let toggle = app.switches["onboarding.hermes.tailnet"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0", "off at first")
        XCTAssertTrue(text(containing: "Tailscale runs only on that computer").exists)
        XCTAssertTrue(text(containing: "Hermes on Windows? Tap Set It Up Myself.").exists)
        reveal(toggle)                                                // last on the page: for the few who need it
        app.swipeUp(velocity: .slow)                                  // clear of the pinned buttons
        toggle.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { toggle.value as? String == "1" })
        XCTAssertTrue(text(containing: "Leave Tailscale connected on this iPhone").waitForExistence(timeout: 5))
        XCTAssertFalse(text(containing: "Tailscale runs only on that computer").exists)
        shot("26-hermes-tailnet")
        for _ in 0..<6 where !app.buttons["onboarding.hermes.copy"].isHittable { app.swipeDown(velocity: .slow) }
        tap("onboarding.hermes.copy")
        XCTAssertTrue(app.staticTexts["onboarding.hermes.status"].waitForExistence(timeout: 5))
        let copied = read(out, "copy.txt") ?? ""
        XCTAssertTrue(copied.contains("connect.sh | sh -s -- --agent --private"), copied)
        XCTAssertFalse(copied.contains("doesn't need Tailscale"), copied)

        // The choice carries to the Mac guide: the private command, and the phone's Tailscale asked for.
        tap("onboarding.hermes.myself"); tap("onboarding.where.mac")
        XCTAssertEqual(app.switches["onboarding.mac-1.tailnet"].value as? String, "1", "still on")
        let command = "curl -fsSL https://raw.githubusercontent.com/mrcharlesiv/hermes-hq/main/connect.sh | sh -s -- --private"
        XCTAssertEqual(app.staticTexts["onboarding.mac-1.command"].label, command)
        shot("26-mac-1-tailnet")
        tap("onboarding.mac-1.copy")
        XCTAssertTrue(waitUntil(timeout: 5) { self.read(out, "copy.txt") == command })
        tap("onboarding.mac-1.next")
        XCTAssertTrue(text(containing: "Sign in to Tailscale there with the same account as this iPhone").waitForExistence(timeout: 5))
        XCTAssertFalse(text(containing: "your iPhone doesn’t need it").exists)
        shot("26-mac-2-tailnet")
        reach("onboarding.mac-2.next"); tap("onboarding.mac-2.next")
        XCTAssertTrue(text(containing: "Leave Tailscale connected on this iPhone too").waitForExistence(timeout: 5))
        shot("26-mac-3-tailnet")

        // Off again on the way back: the plain command.
        back(); back()
        reveal(app.switches["onboarding.mac-1.tailnet"])
        app.switches["onboarding.mac-1.tailnet"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.app.staticTexts["onboarding.mac-1.command"].label == "curl -fsSL https://raw.githubusercontent.com/mrcharlesiv/hermes-hq/main/connect.sh | sh" })
        assertNothingForbidden()
    }

    @MainActor func testO26b_TailnetOnlyChoiceAtLargestType() throws {
        launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        start()
        let toggle = app.switches["onboarding.hermes.tailnet"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        reveal(toggle)
        app.swipeUp(velocity: .slow)   // off the bottom edge, where a tap lands on the Home indicator
        shot("26b-xxxl-hermes-toggle")
        toggle.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { toggle.value as? String == "1" }, "the switch is reachable and works at the largest size")
        shot("26b-xxxl-hermes-toggle-on")
    }

    // MARK: - O17 a returning start (no -HQDebugWelcome)

    @MainActor func testO17_ReturningStartsOnForm() throws {
        app = XCUIApplication()
        app.launchArguments = ["-HQDebugResetAccounts", "YES", "-HQDebugNoDrag", "YES"] + appearance
        app.launch()
        XCTAssertTrue(app.textFields["sign-in-address"].waitForExistence(timeout: 15), "plain launch: the form, as every other suite expects")
        XCTAssertTrue(app.buttons["sign-in-help"].exists)
        XCTAssertEqual(app.staticTexts["sign-in-heading"].label, "Sign in to Hermes.")
        back()
        XCTAssertTrue(app.buttons["onboarding.welcome.start"].waitForExistence(timeout: 5), "the welcome is one Back away")
        tap("onboarding.welcome.address")
        signIn(a)
        XCTAssertTrue(botsShow())
        // Signed out later, this phone has signed in before: the form shows, not the welcome, even when asked for it.
        try a.control("/__settings/reset", [:])
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-HQDebugWelcome", "YES", "-HQDebugNoDrag", "YES"] + appearance
        app.launch()
        XCTAssertTrue(botsShow(timeout: 20) || app.textFields["sign-in-address"].waitForExistence(timeout: 5), "never the welcome again")
        XCTAssertFalse(app.buttons["onboarding.welcome.start"].exists)
    }

    // MARK: - O18 the guide opens at once

    @MainActor func testO18_GuideOpensAtOnce() throws {
        launch()
        XCTAssertTrue(app.buttons["onboarding.welcome.start"].waitForExistence(timeout: 15))
        // No loading state between a tap and the next screen: the heading is there on the first look after the push.
        let steps: [(String, String)] = [("onboarding.welcome.start", "onboarding.start"), ("onboarding.start.computer", "onboarding.hermes"),
                                         ("onboarding.hermes.myself", "onboarding.where"),
                                         ("onboarding.where.linux", "onboarding.linux-1"), ("onboarding.linux-1.next", "onboarding.linux-2"),
                                         ("onboarding.linux-2.next", "onboarding.linux-3")]
        var slowest = 0.0
        for (button, next) in steps {
            reveal(app.buttons[button])
            let started = Date()
            app.buttons[button].tap()
            XCTAssertTrue(heading(next).waitForExistence(timeout: 3), next)
            slowest = max(slowest, Date().timeIntervalSince(started))
            XCTAssertFalse(app.activityIndicators.firstMatch.exists, "no spinner on \(next)")
            XCTAssertFalse(text(containing: "Loading").exists, "no loading text on \(next)")
        }
        XCTAssertLessThan(slowest, 3.0, "tap to heading, including the test's own overhead")
    }

    // MARK: - O19 the offline screen's sign-in sheet: the guide, and the Update screen locked in it

    @MainActor func testO19_DifferentGatewaySheet() throws {
        let b = try SettingsFixture.load("HQN_ONBOARDING_B")
        try b.control("/__settings/reset", [:])
        try b.control("/__onboarding/reset", [:])
        try b.control("/__onboarding/status", ["release_date": "2026.9.10", "version": "0.12.0"])
        launch()
        tap("onboarding.welcome.address")
        signIn(a)
        XCTAssertTrue(botsShow())
        app.terminate()

        // The saved sign-in cannot be opened: the offline screen, which offers another gateway.
        app = XCUIApplication()
        app.launchArguments = ["-HQDebugRestoreFailure", "keychain-unavailable", "-HQDebugNoDrag", "YES"] + appearance
        app.launch()
        XCTAssertTrue(el("offline.title").waitForExistence(timeout: 15))
        XCTAssertEqual(el("offline.title").label, "Can’t Open Your Saved Sign-In")
        tapOffline("offline.different-gateway")
        let address = app.textFields["sign-in-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 8), "the form in a sheet")
        XCTAssertEqual(address.value as? String, a.url, "the last gateway's address is filled in")
        XCTAssertTrue(app.buttons["offline.sign-in.cancel"].exists)
        XCTAssertFalse(app.buttons["onboarding.welcome.start"].exists, "the sheet has no welcome")
        shot("19-offline-sheet-form")

        // The guide inside the sheet, with the sheet's Cancel on every page; a walk and back, twenty times (STRESS 37).
        let help = app.buttons["sign-in-help"]
        reveal(help)
        help.tap()
        XCTAssertTrue(heading("onboarding.start").waitForExistence(timeout: 5), "help opens the guide in the sheet")
        tap("onboarding.start.computer")
        XCTAssertTrue(heading("onboarding.hermes").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["offline.sign-in.cancel"].exists, "Cancel on a guide page")
        shot("19-offline-sheet-guide")
        tap("onboarding.hermes.have-address")
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        for round in 0..<20 {
            tap("sign-in-help")
            XCTAssertTrue(heading("onboarding.hermes").waitForExistence(timeout: 5), "round \(round)")
            if round % 5 == 0 {
                tap("onboarding.hermes.myself"); tap("onboarding.where.mac")
                XCTAssertTrue(heading("onboarding.mac-1").waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["offline.sign-in.cancel"].exists, "Cancel beside Back, three pages in")
                back(); back()
                XCTAssertTrue(heading("onboarding.hermes").waitForExistence(timeout: 5))
            }
            tap("onboarding.hermes.have-address")
            XCTAssertTrue(address.waitForExistence(timeout: 5), "round \(round): the form again")
        }
        XCTAssertEqual(address.value as? String, a.url, "the address is kept across the trips")
        // STRESS 39: a connect link while a guide page of the sheet is up goes into the sheet's form; one sheet, same screen.
        tap("sign-in-help")
        XCTAssertTrue(heading("onboarding.hermes").waitForExistence(timeout: 5))
        open("\(Self.scheme)://connect?url=https%3A%2F%2Fexample-mac.example.com")
        XCTAssertTrue(waitUntil(timeout: 10) { address.exists && (address.value as? String) == "https://example-mac.example.com" },
                      "the link lands in the sheet's form: \(String(describing: address.exists ? address.value : nil))")
        XCTAssertTrue(app.buttons["offline.sign-in.cancel"].exists, "still the sheet")
        XCTAssertFalse(app.buttons["onboarding.welcome.start"].exists, "no rebuilt root")
        shot("19-offline-sheet-link")
        XCTAssertEqual(el("offline.title").label, "Can’t Open Your Saved Sign-In", "one sheet, the same screen underneath")

        // An older gateway: the Update screen takes the sheet over. No Cancel, no Back, no swipe down.
        signIn(b)
        let title = app.staticTexts["update-hermes.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), "the Update screen in the offline screen's sheet")
        XCTAssertEqual(app.staticTexts["update-hermes.release"].label, "Hermes 0.12.0 · released 2026.9.10")
        XCTAssertFalse(app.buttons["offline.sign-in.cancel"].exists, "no Cancel on it")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "the app is not on show yet")
        dismissSavePassword(wait: 12)
        shot("19-offline-sheet-update")
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(title.waitForExistence(timeout: 2), "the sheet does not swipe away")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(title.exists && !address.exists, "a swipe back does not leave it")
        // Away and back: it is still there. (This launch's saved sign-in "cannot be opened" for good, so the screen
        // underneath could never read the new one: that it stands down is O24's and O25's proof, not this one's.)
        awayAndBack()
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(title.exists, "the Update screen survives a trip away")
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertEqual(((try? b.control("/__onboarding/state"))?["status_reads"] as? [String: Any])?["authed"] as? Int, 1, "one read of the version")
        leaveUpdate("update-hermes.continue")
        XCTAssertTrue(botsShow(timeout: 30), "Continue Anyway enters the app")
        XCTAssertFalse(title.exists)
        XCTAssertTrue(waitUntil(timeout: 20) { self.text(containing: "Beta Ivy").exists }, "on the new gateway: its own bots show")
        assertNothingForbidden()
    }

    // MARK: - O20 a typed sign-in enters through the launch screen

    @MainActor func testO20_EntersThroughLaunch() throws {
        // The first lists are held back 6 s: the launch screen covers the wait, never a second form or the welcome.
        try a.control("/__onboarding/lists", ["delay_ms": 6000])
        launch()
        tap("onboarding.welcome.address")
        signIn(a)
        XCTAssertTrue(el("launch.icon").waitForExistence(timeout: 15), "the launch screen after Sign In")
        shot("20-launch-after-sign-in")
        var sawForm = false
        let shown = waitUntil(timeout: 40) {
            self.dismissSavePassword()
            if self.app.textFields["sign-in-address"].exists || self.app.buttons["onboarding.welcome.start"].exists { sawForm = true }
            return self.app.cells["bot-row-ivy"].exists
        }
        XCTAssertTrue(shown, "then the app")
        XCTAssertFalse(sawForm, "no form or welcome flashed between the launch screen and the app")
        app.terminate()

        // The same from Continue Anyway on the Update screen.
        try a.control("/__onboarding/reset", [:])
        try a.control("/__onboarding/status", ["release_date": "2026.9.20", "version": "0.13.0"])
        try a.control("/__onboarding/lists", ["delay_ms": 6000])
        launch()
        tap("onboarding.welcome.address")
        signIn(a)
        XCTAssertTrue(app.staticTexts["update-hermes.title"].waitForExistence(timeout: 20))
        dismissSavePassword(wait: 2)
        XCTAssertEqual((state()["status_reads"] as? [String: Any])?["authed"] as? Int, 1, "the version was read once, before the app")
        leaveUpdate("update-hermes.continue")
        XCTAssertTrue(el("launch.icon").waitForExistence(timeout: 10), "the launch screen after Continue Anyway")
        XCTAssertTrue(botsShow(timeout: 40), "then the app")
        XCTAssertFalse(app.staticTexts["update-hermes.title"].exists)
        app.terminate()

        // STRESS 35: the app killed on that launch screen is signed in at the next start (saved before the wait).
        try a.control("/__onboarding/reset", [:])
        try a.control("/__onboarding/lists", ["delay_ms": -1])
        launch()
        tap("onboarding.welcome.address")
        signIn(a)
        XCTAssertTrue(el("launch.icon").waitForExistence(timeout: 15))
        dismissSavePassword(wait: 2)
        app.terminate()
        try a.control("/__onboarding/lists", ["delay_ms": 0])
        app = XCUIApplication()
        app.launchArguments = ["-HQDebugNoDrag", "YES"] + appearance
        app.launch()
        XCTAssertTrue(botsShow(timeout: 40), "signed in at the next launch")
        XCTAssertFalse(app.textFields["sign-in-address"].exists)
    }

    // MARK: - O21 an iPad (run with an iPad simulator's UDID: HQN_E2E_ONLY=testO21_PadWalk scripts/e2e-onboarding.sh <PAD>)

    @MainActor func testO21_PadWalk() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "an iPad simulator only")
        launch()
        XCTAssertTrue(app.buttons["onboarding.welcome.start"].waitForExistence(timeout: 20))
        let window = app.windows.firstMatch.frame
        func column(_ element: XCUIElement, _ what: String) {
            XCTAssertLessThanOrEqual(element.frame.width, 441, "\(what): the column is capped at 440 pt")
            XCTAssertEqual(element.frame.midX, window.midX, accuracy: 2, "\(what): centred")
        }
        column(app.buttons["onboarding.welcome.start"], "welcome")
        XCTAssertTrue(text(containing: "your iPad").exists, "the welcome says iPad")
        XCTAssertFalse(text(containing: "your iPhone").exists)
        shot("21-pad-welcome")
        start()
        XCTAssertTrue(heading("onboarding.hermes").waitForExistence(timeout: 5))
        XCTAssertTrue(text(containing: "this iPad").exists, "the Tailscale line says iPad")
        shot("21-pad-hermes")
        // The share sheet opens anchored (a popover on iPad): it shows, and closing it leaves the page.
        tap("onboarding.hermes.share")
        XCTAssertTrue(waitUntil(timeout: 10) { self.app.otherElements["ActivityListView"].exists || self.app.navigationBars["UIActivityContentView"].exists },
                      "the share sheet")
        shot("21-pad-share")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.95)).tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !self.app.otherElements["ActivityListView"].exists }, "the popover closes")
        tap("onboarding.hermes.myself")
        XCTAssertTrue(app.buttons["onboarding.where.mac"].waitForExistence(timeout: 5))
        column(app.buttons["onboarding.where.mac"], "chooser")
        XCTAssertTrue(text(containing: "this iPad").exists, "the chooser says iPad")
        shot("21-pad-where")
        tap("onboarding.where.mac")
        XCTAssertTrue(heading("onboarding.mac-1").waitForExistence(timeout: 5))
        shot("21-pad-mac-1")
        tap("onboarding.mac-1.next")
        XCTAssertTrue(text(containing: "your iPad").exists || text(containing: "this iPad").exists, "Mac step 2 says iPad")
        shot("21-pad-mac-2")
        tap("onboarding.mac-2.next")
        XCTAssertTrue(text(containing: "with this iPad").exists, "Scan the QR code with this iPad.")
        tap("onboarding.mac-3.type-address")
        XCTAssertTrue(app.textFields["sign-in-address"].waitForExistence(timeout: 5))
        column(app.textFields["sign-in-address"], "form")
        shot("21-pad-form")
        try a.control("/__onboarding/status", ["release_date": "2026.9.20", "version": "0.13.0"])
        signIn(a)
        XCTAssertTrue(app.staticTexts["update-hermes.title"].waitForExistence(timeout: 20))
        dismissSavePassword(wait: 2)
        column(app.buttons["update-hermes.check"], "Update screen")
        shot("21-pad-update")
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(app.buttons["update-hermes.check"].isHittable && app.buttons["update-hermes.continue"].exists, "landscape: the buttons are there")
        shot("21-pad-update-landscape")
        XCUIDevice.shared.orientation = .portrait
        leaveUpdate("update-hermes.continue")
        XCTAssertTrue(waitUntil(timeout: 40) { self.dismissSavePassword(); return self.app.cells["bot-row-ivy"].exists }, "the app, in the two-pane root")
        assertNothingForbidden()
    }

    // MARK: - O22 the phone's storage refuses the account after a typed sign-in (STRESS 36)

    @MainActor func testO22_StorageFailureAfterSignIn() throws {
        let sentence = "couldn’t switch this iPhone’s saved app data"
        launch(["-HQDebugStorageFailure", "YES"])
        tap("onboarding.welcome.address")
        signIn(a)
        XCTAssertTrue(waitUntil(timeout: 20) { self.el("launch.caption").exists && self.el("launch.caption").label.contains(sentence) },
                      "the launch screen says why it stopped: \(el("launch.caption").label)")
        dismissSavePassword(wait: 5)
        XCTAssertFalse(app.tabBars.firstMatch.exists, "not the app")
        XCTAssertFalse(app.staticTexts["update-hermes.title"].exists, "not the Update screen")
        XCTAssertTrue(app.buttons["launch.try-again"].exists)
        assertNothingForbidden()
        shot("22-storage-after-sign-in")
        app.terminate()

        // From the Update screen's Continue Anyway the same.
        try a.control("/__onboarding/status", ["release_date": "2026.9.20", "version": "0.13.0"])
        launch(["-HQDebugStorageFailure", "YES"])
        tap("onboarding.welcome.address")
        signIn(a)
        XCTAssertTrue(app.staticTexts["update-hermes.title"].waitForExistence(timeout: 20))
        dismissSavePassword(wait: 2)
        leaveUpdate("update-hermes.continue")
        XCTAssertTrue(waitUntil(timeout: 20) { self.el("launch.caption").exists && self.el("launch.caption").label.contains(sentence) },
                      "the storage sentence after Continue Anyway")
        XCTAssertFalse(app.tabBars.firstMatch.exists)
    }

    // MARK: - O23 Reduce Motion, Increase Contrast, Bold Text, and a Desktop Look skin (STRESS 40, 42; spec I5, I6)

    @MainActor func testO23_AccessibilityAndSkinLooks() throws {
        launch(["-HQA11yReduceMotion", "YES", "-HQA11yContrast", "YES", "-HQA11yBoldText", "YES"])
        XCTAssertTrue(app.buttons["onboarding.welcome.start"].waitForExistence(timeout: 15))
        shot("23-a11y-welcome")
        start(); tap("onboarding.hermes.myself"); tap("onboarding.where.mac")
        shot("23-a11y-mac-1")
        // The copied line appears (a fade, not a slide) and the disclosure opens at once.
        tap("onboarding.mac-1.copy")
        XCTAssertTrue(app.staticTexts["onboarding.mac-1.status"].waitForExistence(timeout: 3), "the Copied line")
        tap("onboarding.mac-1.next")
        let trouble = app.buttons["onboarding.mac-2.trouble"]
        reveal(trouble)
        trouble.tap()
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.mac-2.trouble.0"].waitForExistence(timeout: 2), "open")
        shot("23-a11y-mac-2-trouble")
        for _ in 0..<10 { trouble.tap() }   // ten quick toggles end where they began: open
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.mac-2.trouble.0"].waitForExistence(timeout: 2), "an even count of taps leaves it open")
        try a.control("/__onboarding/status", ["release_date": "2026.9.20", "version": "0.13.0"])
        back(); back(); back(); back(); back()
        tap("onboarding.welcome.address")
        signIn(a)
        XCTAssertTrue(app.staticTexts["update-hermes.title"].waitForExistence(timeout: 20))
        dismissSavePassword(wait: 3)
        shot("23-a11y-update")
        app.terminate()

        // A Desktop Look skin: the welcome, the guide and the form take its colours and typeface like the rest of the app.
        try a.control("/__onboarding/reset", [:])
        launch(["-HQDebugSkin", "midnight", "-HQDebugDesktopLook", "YES"])
        XCTAssertTrue(app.buttons["onboarding.welcome.start"].waitForExistence(timeout: 15))
        shot("23-skin-welcome")
        start(); tap("onboarding.hermes.myself"); tap("onboarding.where.mac"); tap("onboarding.mac-1.next")
        XCTAssertTrue(heading("onboarding.mac-2").waitForExistence(timeout: 5))
        shot("23-skin-mac-2")
        tap("onboarding.mac-2.next"); tap("onboarding.mac-3.type-address")
        XCTAssertTrue(app.textFields["sign-in-address"].waitForExistence(timeout: 5))
        shot("23-skin-form")
        assertNothingForbidden()
    }

    // MARK: - O24 the offline screen stands down under the locked Update screen (D32, D34): the real unreadable item

    /// Signs in to A, quits, and relaunches with the saved sign-in made unreadable; returns on the form of the offline
    /// screen's sheet. From here the screen underneath reads the Keychain for real on its timer and on every return.
    @MainActor func unreadableThenSheet() {
        launch()
        tap("onboarding.welcome.address")
        signIn(a)
        XCTAssertTrue(botsShow(), "signed in to the first gateway")
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-HQDebugCorruptSignIn", "YES", "-HQDebugNoDrag", "YES"] + appearance
        app.launch()
        XCTAssertTrue(el("offline.title").waitForExistence(timeout: 15), "the offline screen for the unreadable sign-in")
        XCTAssertEqual(el("offline.title").label, "Can’t Read Your Saved Sign-In")
        tapOffline("offline.sign-in-again")
        let alert = app.alerts["Sign In Again?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "the confirm")
        alert.buttons["Sign In Again"].tap()
        XCTAssertTrue(app.textFields["sign-in-address"].waitForExistence(timeout: 10), "the form in the sheet")
    }

    @MainActor func testO24_OfflineStandsDownUnderUpdate() throws {
        let b = try SettingsFixture.load("HQN_ONBOARDING_B")
        try b.control("/__settings/reset", [:])
        try b.control("/__onboarding/reset", [:])
        try b.control("/__onboarding/status", ["release_date": "2026.9.10", "version": "0.12.0"])
        unreadableThenSheet()
        signIn(b)
        let title = app.staticTexts["update-hermes.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), "the Update screen locked in the sheet")
        dismissSavePassword(wait: 12)
        // The new sign-in is saved and readable now. A return forces the screen underneath to read, and its own retry
        // ladder's longest step is 30 s: neither may enter the app under the locked screen.
        awayAndBack()
        XCTAssertTrue(title.exists, "a return did not replace the Update screen")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "the app did not show under it")
        let deadline = Date().addingTimeInterval(35)
        while Date() < deadline {
            XCTAssertTrue(title.exists, "the Update screen stays through the screen's own retries")
            XCTAssertFalse(app.tabBars.firstMatch.exists, "the app never shows under it")
            Thread.sleep(forTimeInterval: 2.5)
        }
        awayAndBack()
        XCTAssertTrue(title.exists && !app.tabBars.firstMatch.exists, "still locked after a second return")
        XCTAssertEqual(((try? b.control("/__onboarding/state"))?["status_reads"] as? [String: Any])?["authed"] as? Int, 1, "one read of the version")
        shot("24-update-held")
        leaveUpdate("update-hermes.continue")
        XCTAssertTrue(botsShow(timeout: 30), "Continue Anyway enters the app")
        XCTAssertTrue(waitUntil(timeout: 20) { self.text(containing: "Beta Ivy").exists }, "on the new gateway: its own bots show")
    }

    // MARK: - O25 a slow version read after the sheet's sign-in: nothing underneath enters the app first (D34)

    @MainActor func testO25_SlowVersionReadInOfflineSheet() throws {
        let b = try SettingsFixture.load("HQN_ONBOARDING_B")
        try b.control("/__settings/reset", [:])
        try b.control("/__onboarding/reset", [:])
        try b.control("/__onboarding/status", ["release_date": "2026.9.10", "version": "0.12.0", "mode": "slow", "delay_ms": 3500])
        unreadableThenSheet()
        fillSignIn(b)
        tapSignIn()
        // The sign-in is saved within a moment; the form stays busy for the 3.5 s the version takes. A return in that
        // window forces the screen underneath to read the Keychain, which now holds the new sign-in.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 0.6)
        app.activate()
        let title = app.staticTexts["update-hermes.title"]
        var sawApp = false
        let shown = waitUntil(timeout: 25) {
            if self.app.tabBars.firstMatch.exists { sawApp = true }
            self.dismissSavePassword()
            return title.exists
        }
        XCTAssertFalse(sawApp, "the app showed before the Update screen: a read underneath took the window")
        XCTAssertTrue(shown, "the Update screen shows after the slow read")
        XCTAssertEqual(app.staticTexts["update-hermes.release"].label, "Hermes 0.12.0 · released 2026.9.10")
        dismissSavePassword(wait: 8)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(title.exists && !app.tabBars.firstMatch.exists, "and holds")
        shot("25-update-after-slow-read")
        try b.control("/__onboarding/status", ["mode": "ok"])
        leaveUpdate("update-hermes.continue")
        XCTAssertTrue(botsShow(timeout: 30), "Continue Anyway enters the app")
        XCTAssertTrue(waitUntil(timeout: 20) { self.text(containing: "Beta Ivy").exists }, "on the new gateway")
        XCTAssertEqual(((try? b.control("/__onboarding/state"))?["logins"] as? Int), 1, "one sign-in, never retried")
    }

    // MARK: - O27 Hermes Cloud from a first run

    /// A Hermes that Nous hosts has nothing to set up (tester 2026-11-07): "Let Hermes set it up." and "Where does
    /// Hermes run?" both open Hermes Cloud, and closing it leaves the guide where it was.
    @MainActor func testO27_HermesCloudFromTheGuide() throws {
        launch()
        tap("onboarding.welcome.start")
        XCTAssertTrue(heading("onboarding.start").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onboarding.start.cloud"].label.hasPrefix("On Hermes Cloud"), app.buttons["onboarding.start.cloud"].label)
        shot("27-start-cloud-row")
        tap("onboarding.start.cloud")
        XCTAssertTrue(app.buttons["Continue with Nous"].waitForExistence(timeout: 10), "Hermes Cloud, at Continue with Nous")
        shot("27-hermes-cloud-sheet")
        tap("cloud-gateway.cancel")
        XCTAssertTrue(heading("onboarding.start").waitForExistence(timeout: 5), "closing it leaves the guide")

        // Someone with no Hermes can start one there too.
        tap("onboarding.start.none")
        tap("onboarding.get-hermes.cloud")
        XCTAssertTrue(app.buttons["Continue with Nous"].waitForExistence(timeout: 10))
        tap("cloud-gateway.cancel")
        XCTAssertTrue(heading("onboarding.get-hermes").waitForExistence(timeout: 5))

        // One place for it: the setup message's screen and the computers' list don't repeat the row.
        back(); tap("onboarding.start.computer")
        XCTAssertFalse(app.buttons["onboarding.hermes.cloud"].exists)
        tap("onboarding.hermes.myself")
        XCTAssertTrue(heading("onboarding.where").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["onboarding.where.cloud"].exists)
    }

    // MARK: - Helpers

    @MainActor func el(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    /// Taps an offline-screen button between its attempts: during "Connecting…" the buttons are off by design.
    @MainActor func tapOffline(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: 15), "\(id) shows", file: file, line: line)
        for _ in 0..<5 {
            XCTAssertTrue(waitUntil(timeout: 45) { button.isEnabled && button.isHittable }, "\(id) can be tapped", file: file, line: line)
            button.tap()
            if id == "offline.try-again" { return }
            if waitUntil(timeout: 2, { self.app.alerts.firstMatch.exists || self.app.textFields["sign-in-address"].exists }) { return }
        }
    }

    /// Home, then back to the app (the return forces the offline screen's Keychain read).
    @MainActor func awayAndBack() {
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1.5)
        app.activate()
        Thread.sleep(forTimeInterval: 1.5)
    }

    var appearance: [String] { Self.dark ? ["-hqn.appearance", "dark"] : [] }

    @MainActor func launch(_ arguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-HQDebugResetAccounts", "YES", "-HQDebugWelcome", "YES", "-HQDebugNoDrag", "YES"] + appearance + arguments
        app.launch()
    }

    @MainActor func heading(_ id: String) -> XCUIElement { app.staticTexts[id] }

    @MainActor func text(containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Taps a button by identifier, scrolling it into reach first.
    @MainActor func tap(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: 8), "\(id) shows", file: file, line: line)
        reveal(button)
        button.tap()
    }

    /// Get Started, then "On my computer": the first question (docs/spec/3x-onboarding.md §19) on the way to
    /// "Let Hermes set it up."
    @MainActor func start(file: StaticString = #filePath, line: UInt = #line) {
        tap("onboarding.welcome.start", file: file, line: line)
        tap("onboarding.start.computer", file: file, line: line)
    }

    @MainActor func reveal(_ element: XCUIElement) {
        for _ in 0..<12 where !(element.exists && element.isHittable) { app.swipeUp(velocity: .slow) }
    }

    /// Scrolls until the element is on screen (largest type: the last button is far down).
    @MainActor func reach(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.descendants(matching: .any)[id]
        XCTAssertTrue(element.waitForExistence(timeout: 8), "\(id) exists", file: file, line: line)
        for _ in 0..<40 where !element.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(element.isHittable, "\(id) can be reached by scrolling", file: file, line: line)
    }

    @MainActor func back() {
        let button = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(button.waitForExistence(timeout: 5), "a Back button")
        button.tap()
    }

    /// Empties the composer of a draft (an earlier run's, or this test's own before it ends).
    @MainActor func clearDraft(_ field: XCUIElement) {
        let value = (field.value as? String) ?? ""
        guard !value.isEmpty, !value.hasPrefix("Message") else { return }
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count + 2))
    }

    @MainActor func botsShow(timeout: TimeInterval = 20) -> Bool {
        let ivy = app.cells["bot-row-ivy"]
        if ivy.waitForExistence(timeout: timeout) { dismissSavePassword(wait: 1.5); return true }
        dismissSavePassword(wait: 2)
        return ivy.waitForExistence(timeout: 5)
    }

    @MainActor func fillSignIn(_ fixture: SettingsFixture) {
        let address = app.textFields["sign-in-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 15), "the sign-in form shows")
        // At the right edge, so the caret is after the last character whatever is filled in already.
        address.tap()
        if let current = address.value as? String, !current.isEmpty, current != address.placeholderValue {
            // Focused already: a tap near the right edge puts the caret after the last character of a long address.
            address.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        address.typeText(fixture.url)
        let username = app.textFields["sign-in-username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10), "the fixture offers a username and password")
        username.tap()
        // The offline screen's sheet fills in the saved username: replace it, never add to it.
        if let current = username.value as? String, !current.isEmpty, current != username.placeholderValue {
            username.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        username.typeText(fixture.username)
        let password = app.secureTextFields["sign-in-password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        for _ in 0..<3 {
            settle(password)
            password.tap()
            password.typeText(fixture.password)
            let typed = (password.value as? String) ?? ""
            if !typed.isEmpty, typed != password.placeholderValue { break }
        }
    }

    /// Taps a button of the Update screen that leaves it. The system's "Save Password?" sheet can arrive late and take
    /// the tap; it is cleared and the button tapped once more (the model ignores a second tap after it has left).
    @MainActor func leaveUpdate(_ id: String) {
        let title = app.staticTexts["update-hermes.title"]
        for _ in 0..<3 where title.exists {
            dismissSavePassword(wait: 1)
            if app.buttons[id].exists, app.buttons[id].isHittable { app.buttons[id].tap() }
            if waitUntil(timeout: 6, { !title.exists }) { return }
        }
    }

    /// Brings a field clear of the bar and the keyboard before it is tapped (at the largest type it can sit under them).
    @MainActor func settle(_ field: XCUIElement) {
        for _ in 0..<6 where !field.isHittable { app.swipeUp(velocity: .slow) }
        let keyboard = app.keyboards.firstMatch
        for _ in 0..<6 {
            if field.frame.minY < 110 {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
            } else if keyboard.exists, field.frame.midY > keyboard.frame.minY - 20 {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
            } else { break }
        }
    }

    @MainActor func tapSignIn() {
        let button = app.buttons["sign-in-password-button"]
        for _ in 0..<6 where !button.isHittable { app.swipeUp(velocity: .slow) }
        button.tap()
    }

    /// One typed sign-in (never retried).
    @MainActor func signIn(_ fixture: SettingsFixture) {
        fillSignIn(fixture)
        tapSignIn()
    }

    @MainActor func dismissSavePassword(wait: TimeInterval = 0) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(wait)
        repeat {
            for candidate in [app.buttons["Not Now"], springboard.buttons["Not Now"]] where candidate.exists {
                // The sheet is still rising when it first exists, and takes a moment to go: tap once it has settled,
                // and wait until it has gone (a tap or a screenshot before then lands on it, not on the app).
                for _ in 0..<4 where candidate.exists {
                    _ = waitUntil(timeout: 2) { candidate.isHittable }
                    Thread.sleep(forTimeInterval: 0.4)
                    if candidate.exists { candidate.tap() }
                    if waitUntil(timeout: 3, { !candidate.exists }) { break }
                }
                return
            }
            if wait > 0 { Thread.sleep(forTimeInterval: 0.25) }
        } while Date() < deadline
    }

    @MainActor func openSettings() {
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        let row = app.cells["more-row-settings"]
        for _ in 0..<4 {
            dismissSavePassword()
            more.tap()
            if row.waitForExistence(timeout: 2), row.isHittable { break }
        }
        for _ in 0..<3 {
            row.tap()
            if app.buttons["settings.gateway-card"].waitForExistence(timeout: 3) { return }
        }
        XCTFail("Settings did not open")
    }

    @MainActor func openAddGateway() {
        openSettings()
        app.buttons["settings.gateway-card"].tap()
        XCTAssertTrue(app.buttons["gateway.add"].waitForExistence(timeout: 5))
        app.buttons["gateway.add"].tap()
        XCTAssertTrue(app.textFields["sign-in-address"].waitForExistence(timeout: 8), "the Add Gateway form")
    }

    @MainActor func closeShareSheet() {
        for _ in 0..<3 {
            let close = app.buttons["Close"].exists ? app.buttons["Close"] : app.navigationBars["UIActivityContentView"].buttons.firstMatch
            if close.exists { close.tap() } else { app.swipeDown(velocity: .fast) }
            if waitUntil(timeout: 3, { !self.app.otherElements["ActivityListView"].exists }) { return }
        }
    }

    /// Opens a link as the system would (the running app gets it; `XCUIApplication.open` would relaunch).
    @MainActor func open(_ link: String) {
        XCUIDevice.shared.system.open(URL(string: link)!)
        let ask = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if ask.waitForExistence(timeout: 2) { ask.tap() }
    }

    func state() -> [String: Any] { (try? a.control("/__onboarding/state")) ?? [:] }

    /// A fresh folder the app writes what Copy, Send… and links handed over (`-HQDebugGuideOut`).
    func guideOut() -> String {
        let base = Self.shotsFolder ?? NSTemporaryDirectory()
        let folder = (base as NSString).appendingPathComponent("guide-out/\(name.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression))")
        try? FileManager.default.removeItem(atPath: folder)
        return folder
    }

    func read(_ folder: String, _ file: String) -> String? {
        try? String(contentsOfFile: (folder as NSString).appendingPathComponent(file), encoding: .utf8)
    }

    /// The owner's rule: the forbidden word is on no screen.
    @MainActor func assertNothingForbidden(file: StaticString = #filePath, line: UInt = #line) {
        let found = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "dispatch", "dispatch")).count
        XCTAssertEqual(found, 0, "a forbidden word is on screen", file: file, line: line)
    }

    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }

    /// `onboarding-<name>-{light,dark}.png` in the shots folder, and the test's attachments.
    @MainActor func shot(_ name: String) {
        Thread.sleep(forTimeInterval: 0.6)
        let screenshot = app.screenshot()
        let mode = Self.dark ? "dark" : "light"
        if let dir = Self.shotsFolder {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("onboarding-\(name)-\(mode).png"))
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "onboarding-\(name)-\(mode)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
