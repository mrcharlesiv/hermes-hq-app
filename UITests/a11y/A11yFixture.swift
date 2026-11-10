// [a11y] What the accessibility UI tests share (docs/spec/3x-a11y.md §8.2): launching with a text size and the DEBUG
// setting overrides, reading the in-app audit (`debug.a11y`) and the announcement log (`debug.announce`), screenshots.

import XCTest

enum A11ySize: String {
    case xs = "UICTContentSizeCategoryXS", large = "UICTContentSizeCategoryL", xxxl = "UICTContentSizeCategoryXXXL"
    case ax1 = "UICTContentSizeCategoryAccessibilityM", ax2 = "UICTContentSizeCategoryAccessibilityL"
    case ax3 = "UICTContentSizeCategoryAccessibilityXL", ax5 = "UICTContentSizeCategoryAccessibilityXXXL"
}

enum A11yOverride: String, CaseIterable {
    case reduceMotion = "HQA11yReduceMotion", reduceTransparency = "HQA11yReduceTransparency", boldText = "HQA11yBoldText"
    case buttonShapes = "HQA11yButtonShapes", voiceOver = "HQA11yVoiceOver", contrast = "HQA11yContrast"
}

struct A11yFinding: Decodable, CustomStringConvertible {
    let code: String, what: String, `where`: String
    var description: String { "\(code) [\(`where`)] \(what)" }
}

struct A11yReport: Decodable {
    let findings: [A11yFinding]
    let elements: Int
    let actions: [String: [String]]
    let settings: [String: String]
    let hints: [String: String]
    func findings(_ codes: String...) -> [A11yFinding] { findings.filter { codes.contains($0.code) } }
}

struct A11yGateway {
    let url: String, username: String, password: String

    static func load(_ variable: String) throws -> A11yGateway {
        guard let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty else {
            throw XCTSkip("Run scripts/e2e-a11y.sh (it starts the stand-in gateway and sets \(variable)).")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let url = object["url"] as? String else {
            throw XCTSkip("Unreadable credentials file")
        }
        return A11yGateway(url: url, username: object["username"] as? String ?? "", password: object["password"] as? String ?? "")
    }
}

extension XCTestCase {
    /// Launch arguments for a size, a set of overrides and an appearance. `-HQA11yAudit YES` adds the audit element.
    func a11yArguments(size: A11ySize = .large, overrides: Set<A11yOverride> = [], dark: Bool = false) -> [String] {
        var arguments = ["-HQA11yAudit", "YES", "-UIPreferredContentSizeCategoryName", size.rawValue, "-HQDebugNoDrag", "YES",
                         "-hqn.appearance", dark ? "dark" : "light", "-HQDebugNoSwipePeek", "YES", "-HQUITestCleanQuit", "YES"]
        for override in overrides { arguments += ["-\(override.rawValue)", "YES"] }
        return arguments
    }

    @MainActor func a11yLaunch(_ extra: [String] = [], size: A11ySize = .large, overrides: Set<A11yOverride> = [], dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = a11yArguments(size: size, overrides: overrides, dark: dark) + extra
        app.launch()
        return app
    }

    /// Asks the app to end itself with an ordinary exit and waits until it is gone (DEBUG hook `HQTestQuit`, armed by
    /// `-HQUITestCleanQuit YES`). Called from the suite's tear-down so that the next test's launch has nothing left to
    /// terminate: stress round 3 showed the harness booking its own SIGTERM of the previous test's app as "Critical
    /// process HermesHQNative crashed in (null)" on a loaded Mac. The wait is long because the simulator can take ten
    /// seconds and more to tell the harness that a process has gone. Returns whether the app is gone.
    @MainActor @discardableResult func a11yQuit(_ app: XCUIApplication = XCUIApplication(), timeout: TimeInterval = 30) -> Bool {
        guard app.state != .notRunning && app.state != .unknown else { return true }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName("ai.hermes.hqnative.uitest.quit" as CFString), nil, nil, true)
        // `app.state` can stay "running" long after a process that ended itself is gone (seen: 90 s), so the Home
        // Screen coming back counts as well: its icons can only be touched when no app is in front.
        let home = XCUIApplication(bundleIdentifier: "com.apple.springboard").icons.firstMatch
        return a11yWait(timeout) { app.state == .notRunning || home.isHittable }
    }

    /// The in-app audit of what is on screen now.
    @MainActor func a11yAudit(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> A11yReport {
        let probe = app.staticTexts["debug.a11y"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10), "the audit element is there (-HQA11yAudit YES)", file: file, line: line)
        let text = (probe.value as? String) ?? "{}"
        guard let report = try? JSONDecoder().decode(A11yReport.self, from: Data(text.utf8)) else {
            XCTFail("unreadable audit: \(text.prefix(200))", file: file, line: line)
            return A11yReport(findings: [], elements: 0, actions: [:], settings: [:], hints: [:])
        }
        return report
    }

    /// What the app asked VoiceOver to say so far, oldest first.
    @MainActor func a11yAnnouncements(_ app: XCUIApplication) -> [String] {
        let probe = app.staticTexts["debug.announce"]
        guard probe.waitForExistence(timeout: 3), let value = probe.value as? String, !value.isEmpty else { return [] }
        return value.components(separatedBy: " | ")
    }

    @MainActor func a11yShot(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.5)
        let screenshot = app.screenshot()
        if let dir = ProcessInfo.processInfo.environment["HQN_SHOTS"], !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("a11y-\(name).png"))
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func a11yWait(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }

    @MainActor func a11yDismissSavePassword(_ app: XCUIApplication, wait: TimeInterval = 0) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(wait)
        repeat {
            for candidate in [app.buttons["Not Now"], springboard.buttons["Not Now"]] where candidate.exists {
                candidate.tap()
                return
            }
            if wait > 0 { Thread.sleep(forTimeInterval: 0.25) }
        } while Date() < deadline
    }

    @MainActor func a11yHasKeyboard(_ field: XCUIElement) -> Bool {
        (field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }

    /// Puts the keyboard in `field` the way a person would when the keyboard is already up: the part of the field
    /// above the keyboard is tapped, after scrolling it clear when the keyboard covers it. (Stress round 2: at the
    /// largest text size the password field is 141 pt tall and its middle sat under the keyboard the username field
    /// had raised, so a tap on the middle hit a key instead of the field. `isHittable` does not see the keyboard.)
    @MainActor @discardableResult func a11yFocus(_ app: XCUIApplication, _ field: XCUIElement) -> Bool {
        let window = app.windows.firstMatch
        for _ in 0..<6 {
            if a11yHasKeyboard(field) { return true }
            let keyboard = app.keyboards.firstMatch
            let bottom = keyboard.exists ? keyboard.frame.minY : window.frame.maxY
            let frame = field.frame
            let top = max(frame.minY, 110)
            if frame.isEmpty || min(frame.maxY, bottom) - top < 24 {
                // Less than 24 pt of the field is in the clear: move the page by a drag that starts above the keyboard.
                let up = frame.minY > bottom - 60
                let from = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.frame.midX, dy: up ? bottom - 50 : 200))
                let to = from.withOffset(CGVector(dx: 0, dy: up ? -140 : 140))
                from.press(forDuration: 0.05, thenDragTo: to)
                continue
            }
            let y = (top + min(frame.maxY, bottom - 8)) / 2
            window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: y)).tap()
            if a11yWait(4, { self.a11yHasKeyboard(field) }) { return true }
        }
        return a11yHasKeyboard(field)
    }

    /// Signs in to the stand-in gateway through the form (works at accessibility sizes: scrolls to each field).
    @MainActor func a11ySignIn(_ app: XCUIApplication, _ gateway: A11yGateway) {
        let address = app.textFields["sign-in-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 30), "the sign-in form shows")
        address.tap()
        address.typeText(gateway.url)
        let username = app.textFields["sign-in-username"]
        XCTAssertTrue(username.waitForExistence(timeout: 15), "the address is checked and the password form shows")
        XCTAssertTrue(a11yFocus(app, username), "the keyboard is in the username field")
        username.typeText(gateway.username)
        let password = app.secureTextFields["sign-in-password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        // The keyboard's Next key moves on to the password (the form's own path, at every text size); if the field
        // did not take the keyboard that way it is tapped where it shows above the keyboard.
        username.typeText("\n")
        if !a11yWait(5, { self.a11yHasKeyboard(password) }) { a11yFocus(app, password) }
        XCTAssertTrue(a11yHasKeyboard(password), "the keyboard is in the password field before anything is typed")
        password.typeText(gateway.password)
        let button = app.buttons["sign-in-password-button"]
        for _ in 0..<6 where !button.isHittable { app.swipeUp() }
        button.tap()
        a11yDismissSavePassword(app, wait: 3)
    }
}
