// The base of the More pages' end-to-end tests (docs/spec/3x-morepages.md §20). Run with scripts/e2e-morepages.sh: it
// starts the stand-in gateways (scripts/fixtures/morepages-gateway.py) on 10050-10053 and passes their credentials as
// HQN_UI_CREDENTIALS (main), HQN_MORE_SETTINGS, HQN_MORE_OLD (--old-gateway) and HQN_MORE_WH (--webhooks-off).
// Each test resets the main fixture first and may read its request log (`state()`) to check exactly what was sent.
// Screenshots go to HQN_SHOTS_DIR as <name>-light.png / <name>-dark.png.

import XCTest

class MorePagesCase: XCTestCase {
    var account: FixtureAccount!
    var app: XCUIApplication!

    /// Which stand-in this class signs in to: "main" (default), "old", "wh", "settings".
    class var gateway: String { "main" }

    /// One sign-in per gateway per run: the first launch against a gateway starts from a clean phone.
    nonisolated(unsafe) private static var signedInTo: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        account = try Self.account(Self.gateway)
        if Self.gateway != "settings" { try account.control("/__fixture/reset", [:]) }
    }

    static func account(_ name: String) throws -> FixtureAccount {
        let variable = ["main": "HQN_UI_CREDENTIALS", "old": "HQN_MORE_OLD", "wh": "HQN_MORE_WH", "settings": "HQN_MORE_SETTINGS"][name] ?? ""
        guard let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty else {
            throw XCTSkip("Run with scripts/e2e-morepages.sh (it sets \(variable)).")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = object["url"] as? String, let username = object["username"] as? String,
              let password = object["password"] as? String else { throw XCTSkip("Unreadable credentials file") }
        return FixtureAccount(url: url, username: username, password: password)
    }

    // MARK: Launch

    @MainActor @discardableResult
    func launchSignedIn(_ arguments: [String] = [], fresh: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HQPagesHUDSeconds", "6"] + arguments
        if let size = ProcessInfo.processInfo.environment["HQN_TEXT_SIZE"], !size.isEmpty {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", size]
        }
        if fresh || Self.signedInTo != Self.gateway {
            Self.signedInTo = Self.gateway
            app.launchArguments += ["-HQDebugResetAccounts", "YES"]
        }
        app.launch()
        self.app = app
        let bots = app.tabBars.buttons["Bots"]
        let form = app.textFields["sign-in-address"]
        waitUntil(15) { bots.exists || form.exists }
        if !bots.exists && form.exists { signIn(app) }
        XCTAssertTrue(bots.waitForExistence(timeout: 15), "signed in")
        return app
    }

    /// Launches again without resetting anything (a relaunch mid-edit, a cold-launch restore).
    @MainActor @discardableResult
    func relaunch(_ arguments: [String] = []) -> XCUIApplication {
        app?.terminate()
        let app = XCUIApplication()
        app.launchArguments = ["-HQPagesHUDSeconds", "6"] + arguments
        app.launch()
        self.app = app
        return app
    }

    @MainActor func signIn(_ app: XCUIApplication) {
        let address = app.textFields["sign-in-address"]
        address.tap()
        if let current = address.value as? String, !current.isEmpty, current != "my-mac.tail1234.ts.net" {
            address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        address.typeText(account.url)
        let username = app.textFields["sign-in-username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap()
        if let current = username.value as? String, !current.isEmpty, current != "Username" {
            username.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        username.typeText(account.username)
        let password = app.secureTextFields["sign-in-password"]
        password.tap()
        password.typeText(account.password)
        app.buttons["sign-in-password-button"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let notNow = [app.buttons["Not Now"], springboard.buttons["Not Now"]]
        if waitUntil(5, { notNow.contains { $0.exists } }), let candidate = notNow.first(where: { $0.exists }) {
            candidate.tap()
        }
    }

    // MARK: Navigation

    @MainActor func tab(_ name: String) {
        let button = app.tabBars.buttons[name]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the \(name) tab")
        button.tap()
        if !waitUntil(2, { button.isSelected }) { button.tap() }
        XCTAssertTrue(waitUntil(3, { button.isSelected }), "the \(name) tab is selected")
    }

    /// More › the row with this id (`more-row-<id>`), scrolled into reach first.
    @MainActor func openMore(_ row: String, file: StaticString = #filePath, line: UInt = #line) {
        tab("More")
        let cell = app.cells["more-row-\(row)"]
        // The whole More list (every page merged) is taller than the screen: a row below it is not made until
        // scrolled to.
        if !cell.waitForExistence(timeout: 8) {
            for _ in 0..<10 where !cell.exists { app.swipeUp(velocity: .slow) }
            for _ in 0..<10 where !cell.exists { app.swipeDown(velocity: .slow) }
        }
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "More lists \(row)", file: file, line: line)
        reach(cell)
        cell.tap()
    }

    /// More's row with this id, scrolled to until it is made (nil-safe: check `.exists`).
    @MainActor func revealMore(_ row: String, timeout: TimeInterval = 8) -> XCUIElement {
        tab("More")
        let cell = app.cells["more-row-\(row)"]
        if !cell.waitForExistence(timeout: timeout) {
            for _ in 0..<10 where !cell.exists { app.swipeUp(velocity: .slow) }
            for _ in 0..<10 where !cell.exists { app.swipeDown(velocity: .slow) }
        }
        reach(cell)
        return cell
    }

    /// Back on the bar of the page showing.
    @MainActor func back() { app.navigationBars.buttons.element(boundBy: 0).tap() }

    /// Scrolls until the element is clear of the floating tab bar (a tap there would land on the bar).
    @MainActor func reach(_ element: XCUIElement) {
        let limit = app.windows.firstMatch.frame.height - 130
        for _ in 0..<8 where !element.isHittable || element.frame.midY > limit {
            app.swipeUp(velocity: .slow)
        }
    }

    // MARK: Fixture

    /// `GET /__fixture/state`: {"rest":[{method,path,query,body}],"rpc":[{method,params}],"writes":[…], "<module>":{…}}.
    func state() throws -> [String: Any] { try account.control("/__fixture/state") }

    func restLog() throws -> [[String: Any]] { (try state()["rest"] as? [[String: Any]]) ?? [] }
    func rpcLog() throws -> [[String: Any]] { (try state()["rpc"] as? [[String: Any]]) ?? [] }

    /// The logged REST calls with this method whose path starts with `prefix`.
    func rest(_ method: String, _ prefix: String) throws -> [[String: Any]] {
        try restLog().filter { ($0["method"] as? String) == method && (($0["path"] as? String) ?? "").hasPrefix(prefix) }
    }

    func rpc(_ method: String) throws -> [[String: Any]] {
        try rpcLog().filter { ($0["method"] as? String) == method }
    }

    /// The next matching request answers `status` with `detail` (`count` times), or after `delay` seconds.
    func fail(_ method: String, _ path: String, status: Int = 500, detail: String = "boom", count: Int = 1) throws {
        try account.control("/__fixture/fail", ["method": method, "path": path, "status": status, "detail": detail, "count": count])
    }

    func delay(_ method: String, _ path: String, seconds: Double) throws {
        try account.control("/__fixture/fail", ["method": method, "path": path, "delay": seconds])
    }

    // MARK: Waiting and screenshots

    @discardableResult
    func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        return condition()
    }

    func measured(_ text: String) { XCTContext.runActivity(named: "[measure] " + text) { _ in } }

    static var dark: Bool { ProcessInfo.processInfo.environment["HQN_SHOTS_DARK"] == "1" }

    /// A screenshot kept in the result bundle and written to HQN_SHOTS_DIR as `<name>-light.png` / `<name>-dark.png`.
    @MainActor func shot(_ name: String) {
        Thread.sleep(forTimeInterval: 0.6)
        let screenshot = XCUIScreen.main.screenshot()
        var suffix = Self.dark ? "dark" : "light"
        if let size = ProcessInfo.processInfo.environment["HQN_TEXT_SIZE"], !size.isEmpty {
            suffix += "-" + size.replacingOccurrences(of: "UICTContentSizeCategory", with: "").lowercased()
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(name)-\(suffix)"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["HQN_SHOTS_DIR"], !dir.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("morepages-\(name)-\(suffix).png"))
        }
    }
}
