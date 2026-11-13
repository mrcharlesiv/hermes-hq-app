// [soft-cards] Theme › Backgrounds › App Background › Soft Cards: a tour of the whole app on a picture, for looking at
// (owner 2026-11-12: "make it ALL right"). It walks the tabs (at rest, scrolled, a row held, a row swiped, a section
// folded), then every row of More and of Settings, one level deep, with a picture of each page at rest and scrolled.
// Run against any stand-in gateway:
//   TEST_RUNNER_HQN_UI_CREDENTIALS=<creds.json> TEST_RUNNER_HQN_SHOTS_DIR=<dir> xcodebuild … test
//     -only-testing:HermesHQNativeUITests/SoftCardsTourTests
// TEST_RUNNER_HQN_SOFT_MODE (dark|light), _PIC (a picture id), _SKIN, _CARDS (YES|NO), _ONLY (a word a row must hold).

import XCTest

final class SoftCardsTourTests: XCTestCase {
    private var app: XCUIApplication!
    private var account: FixtureAccount!
    private let environment = ProcessInfo.processInfo.environment
    /// Rows a tour must not press.
    private static let skipped = ["Sign Out", "Delete", "Remove", "Reset", "Restart", "Erase", "Clear", "Forget", "Update Hermes", "Log Out"]

    override func setUpWithError() throws {
        continueAfterFailure = true
        account = try FixtureAccount.load()
    }

    @MainActor private func launch() {
        let app = XCUIApplication()
        let mode = environment["HQN_SOFT_MODE"] ?? "dark"
        app.launchEnvironment["HQN_SIGNIN_URL"] = account.url
        app.launchEnvironment["HQN_SIGNIN_USERNAME"] = account.username
        app.launchEnvironment["HQN_SIGNIN_PASSWORD"] = account.password
        app.launchArguments = ["-HQDebugNoSwipePeek", "YES", "-HQDebugTalkIntroSeen", "YES", "-HQDebugResetTheme", "YES",
                               "-HQDebugSkin", environment["HQN_SOFT_SKIN"] ?? "nous", "-HQDebugDesktopLook", "NO",
                               "-HQDebugAppearance", mode, "-hqn.appearance", mode,
                               "-HQDebugAppBackground", environment["HQN_SOFT_PIC"] ?? "doodleTravel",
                               "-HQDebugAppBackgroundCards", environment["HQN_SOFT_CARDS"] ?? "YES"]
        app.launch()
        self.app = app
        XCTAssertTrue(tab("Bots").waitForExistence(timeout: 30), "signed in")
        Thread.sleep(forTimeInterval: 2)
    }

    @MainActor private func tab(_ name: String) -> XCUIElement {
        let system = app.tabBars.buttons[name]
        return system.exists ? system : app.tabButton(id: "tab-\(name.lowercased())", label: name)
    }

    @MainActor private func open(_ name: String) -> Bool {
        let button = tab(name)
        guard button.waitForExistence(timeout: 8) else { return false }
        button.tap()
        Thread.sleep(forTimeInterval: 1.0)
        return true
    }

    @MainActor private func shot(_ name: String) {
        let safe = name.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        let screenshot = XCUIScreen.main.screenshot()
        if let dir = environment["HQN_SHOTS_DIR"], !dir.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(String(safe.prefix(60)) + ".png"))
        }
    }

    /// A picture taken off the main thread, while the test's own thread is holding a finger down.
    nonisolated private static func shotNow(_ name: String, dir: String) {
        guard !dir.isEmpty else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    /// The rows on screen, clear of the bars.
    @MainActor private func rows() -> [XCUIElement] {
        let floor = app.windows.firstMatch.frame.maxY - 100   // the floating tab bar
        return app.cells.allElementsBoundByIndex.filter { cell in
            guard cell.exists else { return false }
            let frame = cell.frame
            return frame.minY > 110 && frame.maxY < floor && frame.height < 200 && frame.height > 20 && cell.isHittable
        }
    }

    // MARK: The tabs

    @MainActor func testSoft1_Tabs() throws {
        launch()
        for name in ["Bots", "Sessions", "Jobs", "Kanban", "Artifacts"] {
            guard open(name) else { continue }
            let key = name.lowercased()
            shot("tab-\(key)-1-rest")
            // A row held down (its press colour, then its menu), then swiped. By place, not by row: quick, and any list.
            let spot = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.47))
            let pressedName = "tab-\(key)-2-pressed", dir = environment["HQN_SHOTS_DIR"] ?? ""
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { Self.shotNow(pressedName, dir: dir) }
            spot.press(forDuration: 0.4)
            Thread.sleep(forTimeInterval: 0.8)
            if !tab(name).isHittable { back() }   // the press opened the row
            spot.press(forDuration: 1.2)
            Thread.sleep(forTimeInterval: 0.7)
            shot("tab-\(key)-3-held")
            for _ in 0..<2 where !tab(name).isHittable {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.52)).tap()
                Thread.sleep(forTimeInterval: 0.7)
            }
            if !tab(name).isHittable { back() }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.47))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.47)))
            Thread.sleep(forTimeInterval: 0.6)
            shot("tab-\(key)-4-swiped")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.47)).tap()
            Thread.sleep(forTimeInterval: 0.7)
            if !tab(name).isHittable { back() }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.8)
            shot("tab-\(key)-5-scrolled")
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.8)
            shot("tab-\(key)-6-end")
            app.swipeDown(); app.swipeDown()
        }
        // Search on Bots and Sessions.
        for name in ["Bots", "Sessions"] where open(name) {
            let search = app.buttons["Search"].firstMatch
            guard search.exists, search.isHittable else { continue }
            search.tap()
            Thread.sleep(forTimeInterval: 1.0)
            shot("tab-\(name.lowercased())-7-search")
            app.typeText("re")
            Thread.sleep(forTimeInterval: 1.0)
            shot("tab-\(name.lowercased())-8-search-typed")
            for label in ["Cancel", "Close"] where app.buttons[label].firstMatch.exists { app.buttons[label].firstMatch.tap(); break }
            Thread.sleep(forTimeInterval: 0.6)
        }
    }

    // MARK: More and Settings

    @MainActor func testSoft2_More() throws {
        launch()
        XCTAssertTrue(open("More"))
        shot("more-0-rest")
        crawl(prefix: "more", root: { [self] in app.collectionViews["more.list"].exists && tab("More").isHittable && app.cells["more-row-settings"].exists })
    }

    @MainActor func testSoft3_Settings() throws {
        launch()
        XCTAssertTrue(open("More"))
        let settings = app.cells["more-row-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        settings.tap()
        Thread.sleep(forTimeInterval: 1.2)
        shot("settings-0-rest")
        crawl(prefix: "settings", root: { [self] in app.navigationBars["Settings"].exists })
    }

    /// Every row of the page on show, once: in, a picture, scrolled, a picture, and back.
    @MainActor private func crawl(prefix: String, root: () -> Bool) {
        var seen = Set<String>()
        var stalls = 0
        var count = 0
        let only = environment["HQN_SOFT_ONLY"].flatMap { $0.isEmpty ? nil : $0 }
        while stalls < 3 && count < 70 {
            var pressed = false
            for row in rows() {
                let key = row.identifier.isEmpty ? row.label : row.identifier
                guard !key.isEmpty, !seen.contains(key) else { continue }
                seen.insert(key)
                guard !Self.skipped.contains(where: key.localizedCaseInsensitiveContains) else { continue }
                if let only, !key.localizedCaseInsensitiveContains(only) { continue }
                count += 1
                let name = "\(prefix)-\(String(format: "%02d", count))-\(key.replacingOccurrences(of: "more-row-", with: ""))"
                row.tap()
                Thread.sleep(forTimeInterval: 1.6)
                shot(name + "-a")
                if !root() {
                    app.swipeUp()
                    Thread.sleep(forTimeInterval: 0.8)
                    shot(name + "-b")
                }
                for _ in 0..<5 where !root() { back() }
                pressed = true
                break
            }
            if pressed { stalls = 0; continue }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.7)
            stalls += 1
        }
    }

    // MARK: The top bar at rest

    /// Owner 2026-11-13 (a recording of Tasks, build 975): "Check the glitch on the top bar." The bar wore a frosted
    /// band with a hard line at rest and dropped it the moment the list was pulled. Each page is pulled down twice and
    /// let go, as in the recording, with a picture at rest before and after each pull; film it with
    /// `xcrun simctl io <sim> recordVideo` to see the frames between (build/tools/barband.py reads the pictures).
    @MainActor func testSoft4_PullDown() throws {
        launch()
        XCTAssertTrue(open("More"))
        for row in ["more-row-tasks", "more-row-settings", "more-row-files"] {
            let cell = app.cells[row]
            for _ in 0..<4 where !(cell.exists && cell.isHittable) { app.swipeUp(); Thread.sleep(forTimeInterval: 0.6) }
            guard cell.exists, cell.isHittable else { continue }
            cell.tap()
            Thread.sleep(forTimeInterval: 2.0)
            pullTwice(row.replacingOccurrences(of: "more-row-", with: "pull-"))
            back()
            for _ in 0..<3 { app.swipeDown(); Thread.sleep(forTimeInterval: 0.4) }
        }
        for name in ["Tasks", "Sessions", "Bots"] where tab(name).exists {
            _ = open(name)
            pullTwice("pull-tab-" + name.lowercased())
        }
    }

    @MainActor private func pullTwice(_ name: String) {
        shot(name + "-1-rest")
        for round in 1...2 {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
            from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.6)
            Thread.sleep(forTimeInterval: 1.5)
            shot("\(name)-\(round + 1)-rest")
        }
    }

    /// One step back: the bar's back button, a sheet's own way out, or a tap off a menu.
    @MainActor private func back() {
        let button = app.navigationBars.buttons.element(boundBy: 0)
        if button.exists, button.isHittable, button.frame.minX < 80 {
            button.tap()
        } else if let way = ["Close", "Done", "Cancel", "Not Now", "OK"].map({ app.buttons[$0].firstMatch }).first(where: { $0.exists && $0.isHittable }) {
            way.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.07)).tap()
            Thread.sleep(forTimeInterval: 0.4)
            if app.sheets.firstMatch.exists || app.otherElements["PopoverDismissRegion"].exists { app.swipeDown(velocity: .fast) }
        }
        Thread.sleep(forTimeInterval: 0.8)
    }
}
