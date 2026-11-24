// [first-run] The redrawn first run end to end (build/first-run/BRIEF.md): hello → where → the note (Copy) → the
// connect link → Found → sign in (Use a Password Instead: the stand-in gateway takes a password only) → Hermes is here →
// Say Hello → the bot's chat. Real taps against scripts/fixtures/onboarding-gateway.py; light and dark screenshots,
// taken once each screen has settled, go to build/first-run/shots/<light|dark>-<n>-<name>.png beside the mock's.
// `testFilm` walks the same path at a person's pace (the runner can film it). Run with
// scripts/e2e-first-run.sh <SIM_UDID>.

import XCTest

final class FirstRunArrivalEndToEndTests: XCTestCase {
    var a: SettingsFixture!
    var app: XCUIApplication!

    static let environment = ProcessInfo.processInfo.environment
    static var dark: Bool { environment["HQN_SHOTS_DARK"] == "1" }
    static var scheme: String { environment["HQN_UI_SCHEME"] ?? "hermeshq-native" }
    static var shotsFolder: String? { environment["HQN_SHOTS"].flatMap { $0.isEmpty ? nil : $0 } }

    override func setUpWithError() throws {
        continueAfterFailure = false
        a = try SettingsFixture.load("HQN_ONBOARDING_A")
        _ = try a.control("/__settings/reset", [:])
        _ = try a.control("/__onboarding/reset", [:])
    }

    // MARK: - The path

    @MainActor func testPath() throws {
        let out = guideOut()
        launch(["-HQDebugGuideOut", out])

        // Hello: the dots gather into a globe turned to the clock's longitude, the words rise in.
        let hello = any("onboarding.welcome")
        XCTAssertTrue(hello.waitForExistence(timeout: 15), "a clean first run starts on Hello")
        XCTAssertEqual(hello.label, "Your Hermes, wherever you are.")
        XCTAssertTrue(app.buttons["onboarding.welcome.start"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["onboarding.welcome.start"].label, "Get Started")
        XCTAssertEqual(app.buttons["onboarding.welcome.address"].label, "I Already Have an Address")
        XCTAssertTrue(text(containing: "It stays on your computer.").exists)
        XCTAssertFalse(app.navigationBars.firstMatch.exists && app.navigationBars.firstMatch.isHittable, "no bar over the stage")
        settle(3.6)
        shot("0-hello")

        // Where: Step 1 of 3, three rows and the quiet Cloudflare line.
        tap("onboarding.welcome.start")
        XCTAssertTrue(heading("onboarding.start").waitForExistence(timeout: 5))
        XCTAssertEqual(heading("onboarding.start").label, "Where is your Hermes?")
        XCTAssertTrue(text(containing: "STEP 1 OF 3").exists)
        for (id, title) in [("computer", "On my computer"), ("cloud", "On Hermes Cloud"), ("none", "I don’t have one yet")] {
            let row = app.buttons["onboarding.start.\(id)"]
            if id == "cloud", !row.exists { continue } // the Hermes Cloud row shows only where today's does
            XCTAssertTrue(row.label.hasPrefix(title), "\(id): \(row.label)")
        }
        XCTAssertEqual(app.buttons["onboarding.start.cloudflare"].label, "Behind Cloudflare Access?")
        XCTAssertTrue(app.buttons["onboarding.arrival.back"].exists, "the round Back")
        settle(1.6)
        shot("1-where")

        // The note: Copy It Instead hands over today's message; the card flies and the words change.
        tap("onboarding.start.computer")
        XCTAssertTrue(heading("onboarding.hermes").waitForExistence(timeout: 5))
        XCTAssertEqual(heading("onboarding.hermes").label, "Send your Hermes this note.")
        XCTAssertTrue(app.buttons["onboarding.hermes.share"].label.contains("Send to My Hermes"))
        XCTAssertTrue(app.buttons["onboarding.hermes.copy"].label.contains("Copy It Instead"))
        XCTAssertTrue(text(containing: "“Please connect this computer to Hermes HQ").exists, "the note's start")
        settle(1.6)
        shot("2a-note")
        tap("onboarding.hermes.show-message")
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.hermes.message"].waitForExistence(timeout: 5), "Read it all")
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.hermes.message"].label.contains("connect.sh"))
        tap("onboarding.hermes.message.done")
        XCTAssertTrue(waitUntil(timeout: 5) { !self.app.descendants(matching: .any)["onboarding.hermes.message"].exists })
        tap("onboarding.hermes.copy")
        XCTAssertTrue(waitUntil(timeout: 5) { self.read(out, "copy.txt")?.hasPrefix("Please connect this computer to Hermes HQ") == true },
                      "Copy went through GuideActions (-HQDebugGuideOut)")
        XCTAssertTrue(waitUntil(timeout: 5) { self.heading("onboarding.hermes").label == "Sent. Hermes is on it." })
        XCTAssertTrue(app.buttons["onboarding.hermes.have-address"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onboarding.hermes.myself"].exists)
        XCTAssertTrue(any("onboarding.hermes.next").exists, "three lines on what happens now")
        settle(2.2)
        shot("2b-waiting")

        // The link comes back: Found, with the address in and nothing to type.
        open("\(Self.scheme)://debug-found?url=\(a.url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? a.url)")   // the stand-in is http: see AppDelegate's debug-found
        XCTAssertTrue(heading("onboarding.found").waitForExistence(timeout: 10), "Found")
        XCTAssertEqual(heading("onboarding.found").label, "Found your Hermes.")
        let pill = any("onboarding.found.address")
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 8) { pill.label.contains("Reachable") }, "the probe found Hermes there: \(pill.label)")
        XCTAssertTrue(pill.label.contains("127.0.0.1"), pill.label)
        XCTAssertFalse(app.buttons["onboarding.found.nous"].exists, "this Hermes takes a password only")
        XCTAssertTrue(app.buttons["onboarding.found.password"].exists)
        settle(3.0)
        shot("3-found")

        // Use a Password Instead: today's whole form, the address already in.
        tap("onboarding.found.password")
        signInWithPassword()

        // Hermes is here: it lights, wakes, and Say Hello comes on.
        XCTAssertTrue(heading("onboarding.here").waitForExistence(timeout: 20), "Hermes is here")
        let hello2 = app.buttons["onboarding.here.hello"]
        XCTAssertTrue(waitUntil(timeout: 15) { hello2.exists && hello2.isEnabled }, "Say Hello comes on once it's awake")
        dismissSavePassword(wait: 1)
        XCTAssertEqual(heading("onboarding.here").label, "Hermes is here.")
        let others = any("onboarding.here.others")
        if others.exists {
            XCTAssertTrue(others.label.range(of: #"^and \d+ more agents? came with it$"#, options: .regularExpression) != nil, others.label)
        }
        settle(1.2)
        shot(others.exists ? "4-several" : "4-here")

        hello2.tap()
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 20), "Say Hello opens the bot's chat")
        dismissSavePassword(wait: 1)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "the keyboard stays down")

        // First words: their own Hermes writes the first message (the stand-in answers any prompt "Hi! I'm Hermes."),
        // and what the app asked it shows no bubble.
        XCTAssertTrue(says("Hi! I'm Hermes.").waitForExistence(timeout: 25), "Hermes writes the first message")
        XCTAssertFalse(says("I've just connected you").exists, "the ask is a hidden turn: no bubble")
        let asked = (try? a.control("/__settings/state"))?["prompts"] as? [[String: Any]] ?? []
        XCTAssertEqual(asked.last?["display_kind"] as? String, "hidden", "it went out as a hidden turn")
        settle(1.0)
        shot("5-chat")

        // The pings card, only while iOS has never been asked (a simulator that has answered goes straight on).
        let ping = any("chat.firstRun.ping"), starters = any("chat.firstRun.starters")
        XCTAssertTrue(waitUntil(timeout: 10) { ping.exists || starters.exists }, "the pings card, or the starters")
        if ping.exists {
            XCTAssertEqual(any("chat.firstRun.ping.title").label, "Get a Ping When It’s Done")
            settle(0.6)
            shot("5a-ping")
            app.buttons["chat.firstRun.ping.action"].tap()
            let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
            if allow.waitForExistence(timeout: 6) { allow.tap() }
        }

        // Three starters; one goes out as a typed message would, and Hermes answers.
        XCTAssertTrue(starters.waitForExistence(timeout: 10), "three starter questions")
        let first = app.buttons["chat.firstRun.starter.0"]
        XCTAssertEqual(first.label, "What can you do for me?")
        XCTAssertTrue(app.buttons["chat.firstRun.starter.2"].exists)
        XCTAssertGreaterThanOrEqual(first.frame.height, 44)
        settle(0.6)
        shot("5b-starters")
        first.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !starters.exists }, "a pick takes the starters away")
        XCTAssertTrue(says("What can you do for me?").waitForExistence(timeout: 5), "it shows as their own message")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "the keyboard still down")
        settle(2.0)
        shot("5c-asked")
    }

    // MARK: - A person's pace

    /// The same path, unhurried: a look at each screen, a spin of the globe, a tap on the face. The runner films it
    /// (HQN_FIRST_RUN_FILM=1); the moments around the light are saved as film-moment-<n>.
    @MainActor func testFilm() throws {
        launch([])
        XCTAssertTrue(any("onboarding.welcome").waitForExistence(timeout: 15))
        settle(4.0)
        // A spin of the globe, then it comes back.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.28)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.28)))
        settle(2.5)
        tap("onboarding.welcome.start")
        settle(2.5)
        tap("onboarding.start.computer")
        settle(3.0)
        tap("onboarding.hermes.copy")
        settle(5.0)
        open("\(Self.scheme)://debug-found?url=\(a.url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? a.url)")   // the stand-in is http: see AppDelegate's debug-found
        XCTAssertTrue(heading("onboarding.found").waitForExistence(timeout: 10))
        settle(3.5)
        tap("onboarding.found.password")
        signInWithPassword(pace: 0.6)
        XCTAssertTrue(heading("onboarding.here").waitForExistence(timeout: 20))
        for n in 1...6 {
            Thread.sleep(forTimeInterval: 0.45)
            shot("film-moment-\(n)", settle: false)
        }
        let hello = app.buttons["onboarding.here.hello"]
        XCTAssertTrue(waitUntil(timeout: 15) { hello.exists && hello.isEnabled })
        dismissSavePassword(wait: 1)
        settle(1.5)
        // A finger to watch, then a tap on the face: it hops.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.2)).press(forDuration: 0.6, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.2)))
        settle(1.0)
        let face = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.33))
        face.tap()
        settle(1.5)
        face.tap()
        settle(2.0)
        hello.tap()
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 20))
        // First words, at a person's pace: the greeting, the pings card (when iOS has never been asked), a starter.
        XCTAssertTrue(says("Hi! I'm Hermes.").waitForExistence(timeout: 25))
        let ping = any("chat.firstRun.ping"), starters = any("chat.firstRun.starters")
        XCTAssertTrue(waitUntil(timeout: 10) { ping.exists || starters.exists })
        settle(2.5)
        if ping.exists {
            app.buttons["chat.firstRun.ping.action"].tap()
            let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
            if allow.waitForExistence(timeout: 6) { settle(1.5); allow.tap() }
        }
        XCTAssertTrue(starters.waitForExistence(timeout: 10))
        settle(2.5)
        app.buttons["chat.firstRun.starter.0"].tap()
        settle(4.0)
    }

    // MARK: - Helpers

    var appearance: [String] { Self.dark ? ["-hqn.appearance", "dark"] : [] }

    @MainActor func launch(_ arguments: [String]) {
        app = XCUIApplication()
        app.launchArguments = ["-HQDebugResetAccounts", "YES", "-HQDebugWelcome", "YES", "-HQDebugNoDrag", "YES",
                               "-HQFirstRunArrival", "YES"] + appearance + arguments
        app.launch()
    }

    @MainActor func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
    @MainActor func heading(_ id: String) -> XCUIElement { app.staticTexts[id].exists ? app.staticTexts[id] : any(id) }

    @MainActor func text(containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor func tap(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: 8), "\(id) shows", file: file, line: line)
        _ = waitUntil(timeout: 4) { button.isHittable }
        button.tap()
    }

    /// The form after Use a Password Instead: the address is in; the username and password are typed.
    @MainActor func signInWithPassword(pace: TimeInterval = 0) {
        let address = app.textFields["sign-in-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10), "today's form")
        XCTAssertEqual(address.value as? String, a.url, "the link's address is in")
        let username = app.textFields["sign-in-username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap()
        username.typeText(a.username)
        if pace > 0 { Thread.sleep(forTimeInterval: pace) }
        let password = app.secureTextFields["sign-in-password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        for _ in 0..<3 {
            password.tap()
            password.typeText(a.password)
            let typed = (password.value as? String) ?? ""
            if !typed.isEmpty, typed != password.placeholderValue { break }
        }
        if pace > 0 { Thread.sleep(forTimeInterval: pace) }
        let button = app.buttons["sign-in-password-button"]
        for _ in 0..<6 where !button.isHittable { app.swipeUp(velocity: .slow) }
        button.tap()
    }

    @MainActor func dismissSavePassword(wait: TimeInterval = 0) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(wait)
        repeat {
            for candidate in [app.buttons["Not Now"], springboard.buttons["Not Now"]] where candidate.exists {
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

    /// Opens a link as the system would (the running app gets it).
    @MainActor func open(_ link: String) {
        XCUIDevice.shared.system.open(URL(string: link)!)
        let ask = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if ask.waitForExistence(timeout: 8) { ask.tap() }   // slow to come up on a busy Mac
    }

    func guideOut() -> String {
        let base = Self.shotsFolder ?? NSTemporaryDirectory()
        let folder = (base as NSString).appendingPathComponent("guide-out/\(name.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression))")
        try? FileManager.default.removeItem(atPath: folder)
        return folder
    }

    func read(_ folder: String, _ file: String) -> String? {
        try? String(contentsOfFile: (folder as NSString).appendingPathComponent(file), encoding: .utf8)
    }

    /// Anything on screen whose words hold `text` (a bubble in the chat).
    @MainActor func says(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }

    /// Lets the stage finish its beat (its dots travel for up to ~3 s after a screen comes on).
    func settle(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    /// `<light|dark>-<name>.png` in the shots folder, as the mock's are named, and the test's attachments.
    @MainActor func shot(_ name: String, settle: Bool = true) {
        if settle { Thread.sleep(forTimeInterval: 0.4) }
        let screenshot = app.screenshot()
        let mode = Self.dark ? "dark" : "light"
        if let dir = Self.shotsFolder {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(mode)-\(name).png"))
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(mode)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
