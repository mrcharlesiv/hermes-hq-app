// desktoplook end-to-end checks (docs/spec/3x-desktoplook.md §4.5, §5.7, §6, §7, §10.6) against the desktoplook
// fixture: the real app, real taps, and the fixture's `/__look/state` as the wire evidence. Run with
// scripts/e2e-desktoplook.sh <udid>.

import XCTest

final class DesktopLookEndToEndTests: XCTestCase {
    var a: SettingsFixture!
    /// iOS's "Save Password?" offer was declined after the last sign-in (see `declineSavePassword`).
    var savePasswordDeclined = false
    /// The bundled App/Resources/DesktopTheme/hermes-hq-theme.js (v9), as DesktopThemeInstall.sha256 says.
    static let themeSHA = "41c31d701da1415a9bfe0c84fa725526d63499b484bab7aea74258b8bcbb68ca", themeBytes = 187585

    override func setUpWithError() throws {
        continueAfterFailure = false
        a = try SettingsFixture.load("HQN_LOOK_A")
        try a.control("/__look/reset", [:])
    }

    /// Every test ends with the app stopped and its exit settled, so the next launch never kills a running app.
    override func tearDown() {
        MainActor.assumeIsolated { Self.stopNow(XCUIApplication()) }
        super.tearDown()
    }

    /// Stops the app and lets its exit settle before anything launches it again. On this shared Mac the harness
    /// reported the test's own stop as "Critical process HermesHQNative crashed in (null)" when the next launch began
    /// within a second of it (stress round 1, repair run 1: the simulator's log shows that exit as SIGTERM from the
    /// test's terminate, and no crash log was written). No assertion depends on this.
    @MainActor func stop(_ app: XCUIApplication) { Self.stopNow(app) }

    @MainActor static func stopNow(_ app: XCUIApplication) {
        guard app.state != .notRunning else { return }
        app.terminate()
        _ = app.wait(for: .notRunning, timeout: 15)
        Thread.sleep(forTimeInterval: 4)
    }

    // MARK: - A1–A3, B2, B4, B8, C1, D1–D3: the Theme page

    @MainActor func testL1_SkinsLookContrastScaleAndRelaunch() throws {
        let app = launchSignedIn(["-HQDebugOpenTheme", "YES"])
        let look = app.switches["theme.desktopLook"]
        XCTAssertTrue(themeOpens(app), "the Theme page opens")
        showLook(app)
        XCTAssertEqual(look.value as? String, "0", "Desktop Look is off on a fresh install")
        XCTAssertFalse(app.switches["theme.highContrast"].exists, "High Contrast shows only with the look on")
        // [density] UI Scale is in the iOS look's page too (with Density, further down), so no check here.
        XCTAssertTrue(text(app, Self.lookNote).exists, "the web's description")
        let nous = card(app, "nous")
        XCTAssertTrue(nous.isSelected, "Nous is the skin on a fresh install")
        shot(app, "theme-default")

        // A skin recolours at once and is marked selected; a one-look skin says so.
        let midnight = card(app, "midnight")
        midnight.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.card(app, "midnight").isSelected }, "Midnight is selected")
        XCTAssertFalse(card(app, "nous").isSelected)
        // Stress test #88: its card also says Dark Only (the label had stayed as it was before that tag).
        XCTAssertEqual(midnight.label, "Midnight, Dark Only, Deep blue-violet with cool accents")
        let oneLook = app.staticTexts["theme.oneLookNote"]
        for _ in 0..<4 where !oneLook.exists { app.swipeUp() }   // the note sits under the grid, below the fold
        XCTAssertTrue(oneLook.waitForExistence(timeout: 3), "a one-look skin says so")
        XCTAssertEqual(oneLook.label, "Midnight has one look, so Light and Dark draw the same.")
        shot(app, "theme-midnight-ios-look")

        // Desktop Look on: its two options appear, the docked tab bar replaces the system one. The look's own page
        // opens on the switch just used, not at the top a screen above it (UX study #110).
        showLook(app)
        flip(app, "theme.desktopLook")
        XCTAssertTrue(waitUntil(timeout: 3) { look.isHittable }, "the look's page opens on its switch")
        XCTAssertTrue(app.switches["theme.highContrast"].waitForExistence(timeout: 5), "High Contrast appears")
        XCTAssertTrue(text(app, Self.contrastNote).exists)
        let scale = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'theme.uiScale.'"))
        XCTAssertTrue(app.buttons["theme.uiScale.100"].waitForExistence(timeout: 3), "UI Scale appears")
        XCTAssertEqual(scale.count, 5, "five presets on one row")
        let rowY = Set((0..<5).map { Int(scale.element(boundBy: $0).frame.midY) })
        XCTAssertEqual(rowY.count, 1, "on one row")
        XCTAssertTrue(app.buttons["theme.uiScale.100"].isSelected, "100% by default")
        XCTAssertTrue(text(app, Self.scaleNote).exists)
        shot(app, "theme-midnight-desktop-look")
        reveal(app, app.buttons["theme.uiScale.125"])
        app.buttons["theme.uiScale.125"].tap()
        XCTAssertTrue(waitUntil(timeout: 3) { app.buttons["theme.uiScale.125"].isSelected })
        flip(app, "theme.highContrast")
        XCTAssertEqual(app.switches["theme.highContrast"].value as? String, "1")
        shot(app, "theme-midnight-contrast-125")

        app.buttons["Done"].firstMatch.tap()
        let bar = app.otherElements["desktop-tab-bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "the docked tab bar shows behind the sheet")
        shot(app, "bots-midnight-contrast-125")
        app.buttons["tab-sessions"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { app.buttons["tab-sessions"].isSelected }, "the docked bar switches tabs")
        shot(app, "sessions-midnight-contrast-125")
        app.buttons["tab-bots"].tap()
        // A chat hides the bar, Back brings it back.
        app.cells["bot-row-ivy"].tap()
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 8), "the chat opens")
        XCTAssertTrue(waitUntil(timeout: 4) { !app.buttons["tab-sessions"].isHittable }, "no tab bar under a chat")
        shot(app, "chat-midnight-contrast-125")

        // Relaunch: everything is on the first frame and still stored (A2, B6, C5, D3).
        stop(app)
        let again = XCUIApplication()
        again.launchArguments = ["-HQDebugOpenTheme", "YES"]
        again.launch()
        XCTAssertTrue(themeOpens(again, timeout: 20), "the Theme page opens, on Themes")
        showLook(again)
        XCTAssertTrue(again.switches["theme.desktopLook"].waitForExistence(timeout: 5))
        XCTAssertEqual(again.switches["theme.desktopLook"].value as? String, "1", "the look survived")
        XCTAssertEqual(again.switches["theme.highContrast"].value as? String, "1", "High Contrast survived")
        XCTAssertTrue(again.buttons["theme.uiScale.125"].isSelected, "UI Scale survived")
        XCTAssertTrue(card(again, "midnight").isSelected, "the skin survived")

        // Look off: the options leave (their choices are kept), the system tab bar is back (B8, D3).
        showLook(again)
        flip(again, "theme.desktopLook")
        XCTAssertTrue(waitUntil(timeout: 3) { again.switches["theme.desktopLook"].isHittable }, "the iOS look's page opens on the switch")
        XCTAssertTrue(waitUntil(timeout: 5) { !again.switches["theme.highContrast"].exists }, "High Contrast leaves with the look")
        flip(again, "theme.desktopLook")
        XCTAssertTrue(again.buttons["theme.uiScale.125"].waitForExistence(timeout: 5))
        XCTAssertTrue(again.buttons["theme.uiScale.125"].isSelected, "the scale choice came back with the look")
        XCTAssertEqual(again.switches["theme.highContrast"].value as? String, "1", "and the contrast choice")
        flip(again, "theme.desktopLook")
        again.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !again.otherElements["desktop-tab-bar"].exists }, "the docked bar is gone")
        XCTAssertTrue(again.tabBars.buttons["Sessions"].waitForExistence(timeout: 5), "the system tab bar is back")
        shot(again, "bots-midnight-look-off")
    }

    // MARK: - [look-off-every-tab] the look off puts back every tab, not only the one on screen

    /// Owner 2026-11-02: the look turned off in Settings (More tab) left Bots with the look's flat grey bar buttons.
    @MainActor func testL15_LookOffPutsBackTabsNotOnScreen() throws {
        let app = launchSignedIn()
        XCTAssertTrue(app.cells["bot-row-ivy"].waitForExistence(timeout: 20), "the Bots list shows")
        let before = barButtonSizes(app)
        XCTAssertFalse(before.isEmpty, "the Bots bar has buttons")
        shot(app, "look-off-tabs-1-before")

        openSettings(app)
        openTheme(app)
        flip(app, "theme.desktopLook")
        app.buttons["tab-bots"].firstMatch.tap()
        XCTAssertTrue(app.cells["bot-row-ivy"].waitForExistence(timeout: 10), "Bots in the look")
        XCTAssertTrue(waitUntil(timeout: 3) { self.barButtonSizes(app) != before }, "the look changes the Bots bar")
        shot(app, "look-off-tabs-2-look")

        app.otherElements["desktop-tab-bar"].descendants(matching: .any)["More"].firstMatch.tap()
        let themeRow = app.buttons["settings.theme-row"]
        XCTAssertTrue(themeRow.waitForExistence(timeout: 5) || app.switches["theme.desktopLook"].exists, "back on More")
        if !app.switches["theme.desktopLook"].exists { openTheme(app) }
        flip(app, "theme.desktopLook")
        XCTAssertTrue(app.tabBars.buttons["Bots"].waitForExistence(timeout: 5), "the system tab bar is back")
        app.tabBars.buttons["Bots"].tap()
        XCTAssertTrue(app.cells["bot-row-ivy"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 3) { self.barButtonSizes(app) == before },
                      "the Bots bar is as before the look: \(before) vs \(barButtonSizes(app))")
        shot(app, "look-off-tabs-3-after")
    }

    @MainActor func openTheme(_ app: XCUIApplication) {
        let row = app.buttons["settings.theme-row"]
        for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp() }
        row.tap()
        XCTAssertTrue(themeOpens(app, timeout: 8), "the Theme page opens")
        showLook(app)
    }

    /// The Bots bar's buttons, by label: their sizes (glass capsules and the look's smaller glyphs differ).
    @MainActor func barButtonSizes(_ app: XCUIApplication) -> [String] {
        app.navigationBars.firstMatch.buttons.allElementsBoundByIndex.filter(\.isHittable)
            .map { "\($0.label) \(Int($0.frame.width.rounded()))x\(Int($0.frame.height.rounded()))" }
    }

    // MARK: - B4: the Nous hand-off

    @MainActor func testL2_IOSSystemHandsOverToNousAndBack() throws {
        let app = launchSignedIn(["-HQDebugSkin", "ios", "-HQDebugOpenTheme", "YES"])
        XCTAssertTrue(themeOpens(app), "the Theme page opens")
        XCTAssertTrue(card(app, "ios").isSelected, "iOS System is selected")
        shot(app, "theme-ios-system")
        showLook(app)
        flip(app, "theme.desktopLook")
        XCTAssertTrue(waitUntil(timeout: 5) { self.card(app, "nous").isSelected }, "the look moves iOS System to Nous")
        showLook(app)
        flip(app, "theme.desktopLook")
        XCTAssertTrue(waitUntil(timeout: 5) { self.card(app, "ios").isSelected }, "and back to iOS System when it goes off")
        // A skin picked by hand while the look is on stays when it goes off.
        showLook(app)
        flip(app, "theme.desktopLook")
        card(app, "ember").tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.card(app, "ember").isSelected })
        shot(app, "theme-ember-desktop-look")
        showLook(app)
        flip(app, "theme.desktopLook")
        XCTAssertTrue(waitUntil(timeout: 5) { self.card(app, "ember").isSelected }, "Ember stays")
        XCTAssertFalse(card(app, "ios").isSelected)
    }

    // MARK: - E1, E3, E4, E5: Hermes HQ Themes for Desktop

    @MainActor func testL3_InstallDesktopThemesFailuresAndCopyLink() throws {
        let app = launchSignedIn(["-HQDebugOpenTheme", "YES", "-HQDebugTextOut", NSTemporaryDirectory() + "hqn-look-out"])
        let add = app.buttons["Add to \(a.hostPort)"]
        XCTAssertTrue(themeOpens(app), "the Theme page opens")
        reveal(app, add)       // the desktop themes card is last, under the grid and the switch
        XCTAssertTrue(add.exists, "one signed-in computer: the button sits on the title row")
        XCTAssertTrue(app.staticTexts["Hermes HQ Themes for Desktop"].exists)
        let description = app.staticTexts["theme.desktop.description"]
        XCTAssertTrue(description.label.hasPrefix("Adds two themes to the Hermes desktop app on \(a.hostPort): Hermes HQ, this app’s look"),
                      description.label)
        shot(app, "desktop-theme-idle")

        // Each failure says its own words and the button comes back.
        let cases: [(route: String, status: Any, words: String)] = [
            ("mkdir", 404, "This Hermes is too old to take files from the iPhone. Update Hermes on the computer running Hermes, then try again."),
            // 401: the app renews the session and tries once more, so the fixture refuses twice.
            ("mkdir", 401, "This iPhone isn’t signed in to Hermes anymore. Sign in again in Settings › Gateway."),
            ("mkdir", 409, "Its Hermes refused the file (HTTP 409)."),
            ("write", 500, "Its Hermes refused the file (HTTP 500)."),
            ("write", 403, "This iPhone isn’t signed in to Hermes anymore. Sign in again in Settings › Gateway."),
            ("mkdir", "drop", "The computer running Hermes didn’t answer. Check that it’s on and connected, then try again."),
            // A 200 that is not Hermes's answer never reads as Added (stress round 2).
            ("write", "html", Self.notHermesWords),
            ("write", "empty", Self.notHermesWords),
            ("write", "rpc", Self.notHermesWords),
            ("mkdir", "text", Self.notHermesWords),
        ]
        for step in cases {
            try a.control("/__look/reset", [:])
            try a.control("/__look/fail", ["route": step.route, "status": step.status, "count": (step.status as? Int) == 401 ? 2 : 1])
            add.tap()
            XCTAssertTrue(text(app, step.words).waitForExistence(timeout: 25), "\(step.route) \(step.status): \(step.words)")
            XCTAssertTrue(waitUntil(timeout: 5) { add.isEnabled && (add.value as? String ?? "") == "" }, "the button is Add again")
            XCTAssertTrue(files().isEmpty, "nothing was written after a failure")
            if step.route == "mkdir" { XCTAssertTrue(calls("write").isEmpty, "no write after a failed mkdir") }
            if (step.status as? Int) == 500 { shot(app, "desktop-theme-failed") }
        }

        // A clean install: exactly one mkdir and one write, the two bodies of §10.2, the bundled file's bytes.
        try a.control("/__look/reset", [:])
        add.tap()
        XCTAssertTrue(app.staticTexts["Added. In the desktop app, open Settings › Appearance › Theme and pick Hermes HQ or Nous High Contrast."]
            .waitForExistence(timeout: 20), "the success note")
        XCTAssertEqual(add.value as? String, "Added")
        let made = calls("mkdir"), wrote = calls("write")
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(wrote.count, 1)
        XCTAssertEqual(made.first?["path"] as? String, "~/.hermes/desktop-plugins/hermes-hq-theme")
        XCTAssertEqual((made.first?["extraKeys"] as? [String])?.count, 0, "mkdir carries only path")
        XCTAssertEqual(wrote.first?["path"] as? String, "~/.hermes/desktop-plugins/hermes-hq-theme/plugin.js")
        XCTAssertEqual((wrote.first?["extraKeys"] as? [String])?.count, 0, "write-text carries only path and content")
        XCTAssertEqual(wrote.first?["sha256"] as? String, Self.themeSHA, "the owner's plugin file, byte for byte")
        XCTAssertEqual(wrote.first?["bytes"] as? Int, Self.themeBytes)
        shot(app, "desktop-theme-added")

        // Copy Link.
        let copy = app.buttons["theme.desktop.copyLink"]
        for _ in 0..<4 where !copy.isHittable { app.swipeUp() }
        XCTAssertEqual(copy.label, "Copy Install from Git Link")
        copy.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { copy.label == "Copied" }, "the button reads Copied")
        // The app writes what it copied (DEBUG `-HQDebugTextOut`; the simulator shares the Mac's file system). The
        // pasteboard itself is read in the unit test copyLinkCopiesTheLink.
        let out = NSTemporaryDirectory() + "hqn-look-out/theme-link.txt"
        XCTAssertTrue(waitUntil(timeout: 3) { FileManager.default.fileExists(atPath: out) }, "the app recorded the copied text")
        XCTAssertEqual(try? String(contentsOfFile: out, encoding: .utf8), "https://github.com/mrcharlesiv/hermes-hq/tree/main/desktop-plugin/hermes-hq-theme")
        shot(app, "desktop-theme-copied")
    }

    // MARK: - Stress 11: the app's own file missing

    @MainActor func testL4_NoAddButtonWithoutTheBundledFile() throws {
        let app = launchSignedIn(["-HQDebugOpenTheme", "YES", "-HQDebugNoThemeFile", "YES"])
        XCTAssertTrue(themeOpens(app), "the Theme page opens")
        reveal(app, app.buttons["theme.desktop.copyLink"])     // the card's last row, at the page's foot
        XCTAssertTrue(app.staticTexts["Hermes HQ Themes for Desktop"].exists)
        XCTAssertFalse(app.buttons["Add to \(a.hostPort)"].exists, "never a button that cannot work")
        XCTAssertTrue(app.buttons["theme.desktop.copyLink"].exists, "the link is still offered")
    }

    // MARK: - Stress 1: toggling many times

    @MainActor func testL5_ToggleTheLookFortyTimes() throws {
        let app = launchSignedIn(["-HQDebugSkin", "catppuccin", "-HQDebugOpenTheme", "YES"])
        XCTAssertTrue(themeOpens(app), "the Theme page opens")
        for _ in 0..<40 { flip(app, "theme.desktopLook") }
        XCTAssertEqual(app.switches["theme.desktopLook"].value as? String, "0", "an even number of flips ends off")
        XCTAssertFalse(app.switches["theme.highContrast"].exists)
        flip(app, "theme.desktopLook")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.otherElements["desktop-tab-bar"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells["bot-row-ivy"].exists, "the list is still there")
        shot(app, "bots-catppuccin-desktop-look")
    }

    // MARK: - E2: two signed-in computers, each with its own Add

    @MainActor func testL6_TwoComputersEachGetTheirOwnAdd() throws {
        let b = try SettingsFixture.load("HQN_LOOK_B")
        try b.control("/__look/reset", [:])
        let app = launchSignedIn()
        // Sign in to the second computer from Settings › Gateway.
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 15))
        let settings = app.cells["more-row-settings"]
        for _ in 0..<4 {
            more.tap()
            if settings.waitForExistence(timeout: 2), settings.isHittable { break }
        }
        settings.tap()
        XCTAssertTrue(app.buttons["settings.gateway-card"].waitForExistence(timeout: 8), "Settings opens")
        app.buttons["settings.gateway-card"].tap()
        XCTAssertTrue(app.buttons["gateway.add"].waitForExistence(timeout: 5))
        app.buttons["gateway.add"].tap()
        signIn(app, b)
        XCTAssertTrue(waitUntil(timeout: 15) { app.descendants(matching: .any)["gateway-row-\(b.hostPort)"].exists }, "two computers listed")
        // Back to the first one, so "in use" is A and the other is reached with its saved sign-in.
        let rowA = app.descendants(matching: .any)["gateway-row-\(a.hostPort)"]
        rowA.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { rowA.exists && rowA.isSelected }, "A is in use again")
        app.navigationBars["Gateways"].buttons.element(boundBy: 0).tap()
        let themeRow = app.descendants(matching: .any)["settings.theme-row"]
        for _ in 0..<5 where !(themeRow.exists && themeRow.isHittable) { app.swipeUp() }
        themeRow.tap()
        XCTAssertTrue(themeOpens(app, timeout: 8), "the Theme page opens")

        let addA = app.buttons["Add to \(a.hostPort)"], addB = app.buttons["Add to \(b.hostPort)"]
        reveal(app, addB)      // the desktop themes card is last, under the grid and the switch
        XCTAssertTrue(app.staticTexts["Hermes HQ Themes for Desktop"].exists)
        XCTAssertTrue(addA.waitForExistence(timeout: 5), "an Add for the computer in use")
        XCTAssertTrue(addB.exists, "and one for the other computer")
        XCTAssertLessThan(addA.frame.minY, addB.frame.minY, "the one in use comes first")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'In Use'")).firstMatch.exists)
        shot(app, "desktop-theme-two-computers")

        func state(_ fixture: SettingsFixture) -> (calls: [[String: Any]], files: [String: Any]) {
            let state = (try? fixture.control("/__look/state")) ?? [:]
            let good = ((state["calls"] as? [[String: Any]]) ?? []).filter { ($0["status"] as? Int) == 200 }
            return (good, (state["files"] as? [String: Any]) ?? [:])
        }
        // The other computer: its own saved sign-in, nothing sent to the one in use.
        addB.tap()
        XCTAssertTrue(waitUntil(timeout: 20) { addB.label == "Add to \(b.hostPort)" && (addB.value as? String) == "Added" }, "B says Added")
        XCTAssertEqual(state(b).calls.map { $0["route"] as? String }, ["mkdir", "write"], "mkdir then write on B")
        XCTAssertEqual(state(b).calls.last?["sha256"] as? String, Self.themeSHA)
        XCTAssertTrue(state(a).calls.isEmpty && state(a).files.isEmpty, "nothing was sent to A")
        XCTAssertNotEqual(addA.value as? String, "Added", "A's own row did not change")
        // The computer in use.
        addA.tap()
        XCTAssertTrue(waitUntil(timeout: 20) { (addA.value as? String) == "Added" }, "A says Added")
        XCTAssertEqual(state(a).calls.map { $0["route"] as? String }, ["mkdir", "write"])
        XCTAssertEqual(state(b).calls.count, 2, "B was not written again")
        shot(app, "desktop-theme-two-added")
        // Still signed in to both after two one-off sessions.
        XCTAssertTrue(addA.exists && addB.exists)
    }

    // MARK: - The chat in the look at 150 %: sizes are scaled once, your own message keeps no room for a time

    @MainActor func testL7_ChatInTheLookAtEveryScale() throws {
        for percent in ["100", "150"] {
            let app = launchSignedIn(["-HQDebugSkin", "midnight", "-HQDebugDesktopLook", "YES", "-HQDebugUIScale", percent])
            XCTAssertTrue(app.otherElements["desktop-tab-bar"].waitForExistence(timeout: 20), "the look is on")
            shot(app, "look-bots-\(percent)")
            app.cells["bot-row-ivy"].tap()
            XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 8), "the chat opens")
            let title = app.descendants(matching: .any)["chat.title"].firstMatch
            if title.exists {
                XCTAssertLessThan(title.frame.width, app.frame.width - 100, "the title fits beside the bar buttons at \(percent)%")
            }
            shot(app, "look-chat-\(percent)")
            stop(app)
        }
    }

    // MARK: - desktoplook2: the desktop's layout with the look on, the iOS layout untouched with it off

    @MainActor func testL10_DesktopLayoutOnAndOff() throws {
        var heights: [Bool: CGFloat] = [:]
        for on in [true, false] {
            let app = launchSignedIn(["-HQDebugSkin", "midnight", "-HQDebugDesktopLook", on ? "YES" : "NO"])
            let row = app.cells["bot-row-ivy"]
            XCTAssertTrue(row.waitForExistence(timeout: 20), "the Bots list shows")
            heights[on] = row.frame.height
            if on {
                XCTAssertEqual(row.frame.height, 60, accuracy: 1.5, "Bots rows are the desktop's 60 pt in the look")
                XCTAssertTrue(app.otherElements["desktop-tab-bar"].exists, "the look is on")
            } else {
                XCTAssertGreaterThan(row.frame.height, 64, "with the look off the row keeps its iOS height")
                XCTAssertFalse(app.navigationBars.staticTexts["BOTS"].exists, "with the look off the title is not set in capitals")
            }
            shot(app, "layout-bots-look\(on ? "on" : "off")")
            row.tap()
            XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 8), "the chat opens")
            let title = app.descendants(matching: .any)["chat.title"].firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 5), "the chat title shows (look \(on ? "on" : "off"))")
            shot(app, "layout-chat-look\(on ? "on" : "off")")
            stop(app)
        }
        XCTAssertNotEqual(heights[true], heights[false], "turning the look off changes the layout back")
    }

    // MARK: - desktoplook3: no glass in the look; Back is a flat stand-in that keeps tap, swipe and the history menu

    @MainActor func testL11_FlatBackKeepsTapSwipeAndHistory() throws {
        let app = launchSignedIn(["-HQDebugSkin", "midnight", "-HQDebugDesktopLook", "YES"])
        let row = app.cells["bot-row-ivy"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the Bots list shows")
        let composer = app.textViews["composer.text"]
        let back = app.navigationBars.buttons["BackButton"]
        // A tap.
        row.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 8), "the chat opens")
        XCTAssertTrue(back.waitForExistence(timeout: 5), "the look's Back shows")
        shot(app, "look3-chat-back")
        back.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !composer.exists && row.isHittable }, "Back returns to the list")
        // The edge swipe.
        row.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 8), "the chat opens again")
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)))
        XCTAssertTrue(waitUntil(timeout: 5) { !composer.exists && row.isHittable }, "a swipe from the edge goes back")
        // The long press lists the pages under the chat.
        row.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 8), "the chat opens a third time")
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.press(forDuration: 1.2)
        let page = app.collectionViews.buttons["Bots"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 5), "a long press on Back lists the Bots page")
        shot(app, "look3-back-history")
        page.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !composer.exists && row.isHittable }, "picking it goes back there")
        stop(app)
    }

    // MARK: - Owner 2026-10-20: the docked bar never stays drawn over a chat's composer

    @MainActor func testL12_BarNeverCoversTheComposer() throws {
        let app = launchSignedIn(["-HQDebugSkin", "midnight", "-HQDebugDesktopLook", "YES"])
        let row = app.cells["bot-row-ivy"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the Bots list shows")
        let composer = app.textViews["composer.text"]
        let back = app.navigationBars.buttons["BackButton"]
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        for round in 0..<4 {
            row.tap()
            XCTAssertTrue(composer.waitForExistence(timeout: 8), "the chat opens (round \(round))")
            // A back swipe let go a third of the way: the chat stays.
            edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)))
            XCTAssertTrue(waitUntil(timeout: 4) { composer.isHittable }, "the composer is still there (round \(round))")
            // Back, and the chat opened again before the pop has landed.
            back.tap()
            if waitUntil(timeout: 2, { row.isHittable }) { row.tap() }
            XCTAssertTrue(composer.waitForExistence(timeout: 8), "the chat opens again (round \(round))")
            XCTAssertTrue(waitUntil(timeout: 4) { composer.isHittable && !app.buttons["tab-sessions"].isHittable },
                          "no tab bar under the chat (round \(round))")
            shot(app, "look-bar-composer-\(round)")
            back.tap()
            XCTAssertTrue(waitUntil(timeout: 5) { row.isHittable && app.buttons["tab-sessions"].isHittable }, "the bar is back on the list")
        }
        stop(app)
    }

    /// UX study #200: at Extra Large text with the keyboard down, the look's composer box keeps the message column's
    /// 16 pt gutter (the box is drawn 4 pt outside the row's 20 pt sides); over the keys it keeps its 11 pt.
    @MainActor func testL13_ComposerBoxMeetsTheMessageColumn() throws {
        // [desktop-composer] The box is Text Box › Desktop now; the look starts with the glass bar.
        let app = launchSignedIn(["-HQDebugSkin", "midnight", "-HQDebugDesktopLook", "YES", "-HQDebugDesktopComposer", "box",
                                  "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXL"])
        let row = app.cells["bot-row-ivy"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the Bots list shows")
        row.tap()
        let composer = app.textViews["composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 8), "the chat opens")
        shot(app, "ux-200")
        stop(app)
    }

    // MARK: - Stress round 1: a picked skin reaches the More tab, the Settings root and the Theme page

    // MARK: - Settings › Appearance › Chat Bubbles and Backgrounds (the iOS look only)

    /// The slider saves when let go (it survives a relaunch). [theme-pages] Chat Bubbles and Backgrounds are rows of
    /// their own under Appearance beside Theme (they were its tabs), not there in the Desktop Look, and the choice is
    /// still there when the look goes off again.
    @MainActor func testL14_BubbleCornersSaveOnReleaseAndStayOutOfTheLook() throws {
        let app = launchSignedIn(["-HQDebugOpenTheme", "YES", "-HQDebugThemeBubbles", "YES"])
        XCTAssertTrue(themeOpens(app), "Chat Bubbles opens")
        let slider = app.sliders["theme.bubbleCorners"]
        reveal(app, slider)
        XCTAssertTrue(slider.waitForExistence(timeout: 5), "Chat Bubbles shows in the iOS look")
        XCTAssertEqual(slider.value as? String, "12 points", "12 pt on a fresh install")
        slider.adjust(toNormalizedSliderPosition: 1)
        XCTAssertTrue(waitUntil(timeout: 3) { (slider.value as? String) == "24 points" }, "let go at the end: 24 pt")
        shot(app, "theme-bubbles-24")

        stop(app)
        let again = XCUIApplication()
        again.launchArguments = ["-HQDebugOpenTheme", "YES", "-HQDebugThemeBubbles", "YES"]
        again.launch()
        let kept = again.sliders["theme.bubbleCorners"]
        XCTAssertTrue(kept.waitForExistence(timeout: 20))
        XCTAssertEqual(kept.value as? String, "24 points", "saved, not only drawn")

        // The Desktop Look: Theme, but no Chat Bubbles or Backgrounds row beside it.
        stop(again)
        let look = XCUIApplication()
        look.launchArguments = ["-HQDebugDesktopLook", "YES", "-HQDebugOpenSettings", "YES"]
        look.launch()
        let lookTheme = look.descendants(matching: .any)["settings.theme-row"]
        XCTAssertTrue(lookTheme.waitForExistence(timeout: 20), "Settings opens")
        for _ in 0..<6 where !lookTheme.isHittable { look.swipeUp() }
        XCTAssertFalse(look.descendants(matching: .any)["settings.chat-bubbles-row"].exists, "no Chat Bubbles in the Desktop Look")
        XCTAssertFalse(look.descendants(matching: .any)["settings.backgrounds-row"].exists, "no Backgrounds in the Desktop Look")
        shot(look, "theme-pages-look")

        // The iOS look again: both rows, each opening its own page; the corners kept while the look was on.
        stop(look)
        let back = XCUIApplication()
        back.launchArguments = ["-HQDebugDesktopLook", "NO", "-HQDebugOpenSettings", "YES"]
        back.launch()
        let bubblesRow = back.buttons["settings.chat-bubbles-row"]
        XCTAssertTrue(back.buttons["settings.theme-row"].waitForExistence(timeout: 20), "Settings opens")
        for _ in 0..<6 where !(bubblesRow.exists && bubblesRow.isHittable) { back.swipeUp() }
        XCTAssertTrue(bubblesRow.exists, "Chat Bubbles beside Theme")
        XCTAssertTrue(back.buttons["settings.backgrounds-row"].exists, "Backgrounds beside it")
        shot(back, "theme-pages-appearance")
        bubblesRow.tap()
        XCTAssertTrue(back.navigationBars["Chat Bubbles"].waitForExistence(timeout: 5), "the row opens its page")
        let corners = back.sliders["theme.bubbleCorners"]
        XCTAssertTrue(corners.waitForExistence(timeout: 5))
        XCTAssertEqual(corners.value as? String, "24 points", "the choice is kept while the look is on")
        XCTAssertFalse(back.descendants(matching: .any).matching(identifier: "theme.tab").firstMatch.exists, "no tabs")
        back.navigationBars["Chat Bubbles"].buttons.firstMatch.tap()
        let backgroundsRow = back.buttons["settings.backgrounds-row"]
        XCTAssertTrue(backgroundsRow.waitForExistence(timeout: 5))
        backgroundsRow.tap()
        let appRow = back.descendants(matching: .any)["theme.background.app"]
        XCTAssertTrue(appRow.waitForExistence(timeout: 5), "App Background on Backgrounds")
        XCTAssertTrue(back.descendants(matching: .any)["theme.background.chats"].exists, "Chat Background beside it")
        shot(back, "theme-pages-backgrounds")
        appRow.tap()
        XCTAssertTrue(back.navigationBars["App Background"].waitForExistence(timeout: 5), "the row opens its page")
    }

    @MainActor func testL8_APickedSkinRecoloursMoreSettingsAndTheme() throws {
        let app = launchSignedIn()
        let dark = ProcessInfo.processInfo.environment["HQN_SHOTS_DARK"] == "1"
        // Nothing picked: iOS's own grouped page, exactly (the standard look is untouched).
        let system = dark ? "000000" : "F2F2F7"
        openSettings(app)
        XCTAssertEqual(gutter(app), system, "Settings is iOS's grouped page until a skin is picked")
        shot(app, "grouped-default-settings")

        var seen = Set<String>()
        for skin in ["everforest", "midnight"] {
            let row = app.buttons["settings.theme-row"]
            for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp() }
            row.tap()
            let picked = card(app, skin)
            XCTAssertTrue(picked.waitForExistence(timeout: 8), "the Theme page opens")
            picked.tap()
            XCTAssertTrue(waitUntil(timeout: 5) { self.card(app, skin).isSelected }, "\(skin) is selected")
            // Live, with no relaunch: the Theme page, then the Settings root behind it, then the More tab.
            XCTAssertTrue(waitUntil(timeout: 5) { self.gutter(app) != system }, "the Theme page takes \(skin)'s colour at once")
            let page = gutter(app)
            XCTAssertFalse(["F2F2F7", "000000", "FFFFFF", "1C1C1E"].contains(page), "\(skin): not a system grey, got #\(page)")
            XCTAssertTrue(seen.insert(page).inserted, "each skin has its own page colour")
            shot(app, "grouped-\(skin)-theme")
            app.navigationBars.buttons.firstMatch.tap()      // Back to Settings
            XCTAssertTrue(app.buttons["settings.gateway-card"].waitForExistence(timeout: 5) || row.waitForExistence(timeout: 5))
            XCTAssertTrue(waitUntil(timeout: 5) { self.gutter(app) == page }, "\(skin): the Settings root is #\(page), got #\(gutter(app))")
            shot(app, "grouped-\(skin)-settings")
            app.navigationBars.buttons.firstMatch.tap()      // Back to More
            XCTAssertTrue(app.cells["more-row-settings"].waitForExistence(timeout: 5))
            XCTAssertTrue(waitUntil(timeout: 5) { self.gutter(app) == page }, "\(skin): the More tab is #\(page), got #\(gutter(app))")
            shot(app, "grouped-\(skin)-more")
            app.cells["more-row-settings"].tap()
            XCTAssertTrue(row.waitForExistence(timeout: 5) || app.buttons["settings.gateway-card"].waitForExistence(timeout: 5))
        }

        // After a relaunch the skin is on the first frame of More and Settings too.
        stop(app)
        let again = XCUIApplication()
        again.launchArguments = dark ? ["-hqn.appearance", "dark"] : []
        again.launch()
        openSettings(again)
        XCTAssertTrue(seen.contains(gutter(again)), "Midnight is still on the Settings root after a relaunch, got #\(gutter(again))")

        // The buttons of the desktop themes section are full-size touch targets (stress round 1: 34 pt).
        let themeRow = again.buttons["settings.theme-row"]
        for _ in 0..<6 where !(themeRow.exists && themeRow.isHittable) { again.swipeUp() }
        themeRow.tap()
        let copy = again.buttons["theme.desktop.copyLink"]
        XCTAssertTrue(themeOpens(again, timeout: 8), "the Theme page opens")
        reveal(again, copy)    // the card's last row, at the page's foot
        XCTAssertTrue(copy.exists)
        XCTAssertGreaterThanOrEqual(copy.frame.height.rounded(), 44, "Copy Link is a 44 pt target")   // rounded: layout gives 43.99999…
        let add = again.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'theme.desktop.add.'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(add.frame.height.rounded(), 44, "Add is a 44 pt target")
    }

    // MARK: - The desktop themes card at the largest text size (stress round 2)

    /// At the accessibility sizes the title broke inside words beside a round, two-line "Add / ed" button. The button
    /// now sits under the title on one line, and Add still works.
    @MainActor func testL9_LargestTextStacksTheDesktopThemesCard() throws {
        // Signed in at the ordinary size, then opened again at the largest (the sign-in form is not this test's subject).
        let first = launchSignedIn()
        XCTAssertTrue(first.tabBars.buttons["More"].waitForExistence(timeout: 30), "signed in")
        stop(first)
        let app = XCUIApplication()
        app.launchArguments = ["-HQDebugNoDrag", "YES", "-HQDebugOpenTheme", "YES",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let add = app.buttons["Add to \(a.hostPort)"]
        // At this size the card is several screens down, and a list only builds the rows near the screen.
        XCTAssertTrue(themeOpens(app, timeout: 30), "the Theme page opens")
        let title = app.staticTexts["theme.desktop.title"]
        for _ in 0..<40 where !(add.exists && add.isHittable && title.exists) {
            if declineSavePassword(app) { continue }
            app.swipeUp()
        }
        XCTAssertTrue(add.exists && title.exists, "the desktop themes card is reached")
        let width = app.frame.width
        XCTAssertGreaterThan(title.frame.width, width * 0.7, "the title has the card's full width, got \(title.frame)")
        XCTAssertGreaterThanOrEqual(add.frame.minY, title.frame.maxY - 1, "Add sits under the title: \(add.frame) vs \(title.frame)")
        XCTAssertGreaterThanOrEqual(add.frame.height, 44)
        XCTAssertGreaterThan(add.frame.width, add.frame.height, "one line of text, not a round two-line button: \(add.frame)")
        shot(app, "desktop-theme-ax5-idle")
        add.tap()
        XCTAssertTrue(waitUntil(timeout: 20) { (add.value as? String) == "Added" }, "Add still works at this size")
        XCTAssertEqual(calls("write").first?["sha256"] as? String, Self.themeSHA)
        XCTAssertGreaterThan(add.frame.width, add.frame.height, "Added stays on one line: \(add.frame)")
        shot(app, "desktop-theme-ax5-added")
    }

    /// More › Settings. A second tap on More pops a page left open.
    @MainActor func openSettings(_ app: XCUIApplication) {
        declineSavePassword(app)
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        let row = app.cells["more-row-settings"]
        for _ in 0..<4 {
            more.tap()
            if row.waitForExistence(timeout: 2), row.isHittable { break }
        }
        for _ in 0..<3 {
            row.tap()
            if app.buttons["settings.gateway-card"].waitForExistence(timeout: 3) { return }
        }
    }

    /// The colour of the page beside the grouped cards: one pixel in the left margin, two thirds down the screen.
    @MainActor func gutter(_ app: XCUIApplication) -> String {
        guard let image = app.screenshot().image.cgImage, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return "" }
        let scale = CGFloat(image.width) / max(app.frame.width, 1)
        let x = Int(5 * scale), y = Int(CGFloat(image.height) * 0.66)
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        var parts = [bytes[offset], bytes[offset + 1], bytes[offset + 2]]
        let info = image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue
        if info == CGBitmapInfo.byteOrder32Little.rawValue { parts.reverse() }          // BGRA
        else if image.alphaInfo == .premultipliedFirst || image.alphaInfo == .first || image.alphaInfo == .noneSkipFirst {
            parts = [bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]]          // ARGB
        }
        return parts.map { String(format: "%02X", $0) }.joined()
    }

    // MARK: - Helpers

    /// A label longer than XCUITest's 128-character subscript limit is matched by predicate.
    func text(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    static let notHermesWords = "Something answered, but it wasn’t Hermes. Check the address of the computer running Hermes in Settings › Gateway, then try again."
    static let lookNote = "Draws Hermes HQ like the Hermes desktop app: your theme’s own colors on every screen, square corners and solid bars instead of glass. Set on this iPhone only."
    static let contrastNote = "Sets your messages, boxes, lines and secondary text further apart from the page, in your theme’s own colors. For themes that look flat."
    static let scaleNote = "Makes text, faces and rows larger or smaller, in both looks, on top of the text size set in iOS Settings. Set on this iPhone only."   // DeviceWord.onlyHere on the iPhone

    func calls(_ route: String) -> [[String: Any]] {
        let state = (try? a.control("/__look/state")) ?? [:]
        return ((state["calls"] as? [[String: Any]]) ?? []).filter { $0["route"] as? String == route && ($0["status"] as? Int) == 200 }
    }

    func files() -> [String: Any] { (((try? a.control("/__look/state")) ?? [:])["files"] as? [String: Any]) ?? [:] }

    /// A skin's card, scrolled into view.
    @MainActor func card(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let element = app.buttons["theme.skin.\(id)"]
        reveal(app, element)
        // The list may still be settling from the last swipe (repair run: "Failed to not hittable" on a card in view).
        _ = waitUntil(timeout: 4) { element.exists && element.isHittable }
        return element
    }

    /// The Theme page, open: the page itself, its look switch or its first skin card (at the largest text the grid can
    /// be screens below the switch's note, not yet built), or [theme-pages] Chat Bubbles' slider where a debug argument
    /// opens that page instead.
    @MainActor func themeOpens(_ app: XCUIApplication, timeout: TimeInterval = 15) -> Bool {
        let page = app.descendants(matching: .any).matching(identifier: "settings.theme").firstMatch
        let look = app.switches["theme.desktopLook"]
        let grid = app.buttons["theme.skin.nous"]
        let slider = app.sliders["theme.bubbleCorners"]
        return waitUntil(timeout: timeout) { grid.exists || slider.exists || look.exists || page.exists }
    }

    /// The Desktop Look switch, in view ([look-in-themes] the page's first row). [theme-pages] Picking a tab used to put
    /// the page back at its top; now it scrolls up, since a row far above the screen is not built at all.
    @MainActor func showLook(_ app: XCUIApplication) {
        let look = app.switches["theme.desktopLook"]
        for _ in 0..<10 where !(look.exists && look.isHittable) {
            if declineSavePassword(app) { continue }
            if look.exists, look.frame.midY > app.frame.midY { app.swipeUp() } else { app.swipeDown() }
        }
    }

    /// Scrolls until the element is on screen: down the page while it is unbuilt or below the screen (the iOS look's
    /// list builds only the rows near the screen), back up while it is above.
    @MainActor func reveal(_ app: XCUIApplication, _ element: XCUIElement) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            if declineSavePassword(app) { continue }       // the prompt was over the page: look again before swiping
            if element.exists, element.frame.midY < app.frame.midY { app.swipeDown() } else { app.swipeUp() }
        }
    }

    /// Flips a SwiftUI toggle by its switch (a tap on the row's middle does not).
    @MainActor func flip(_ app: XCUIApplication, _ id: String) {
        declineSavePassword(app)
        let toggle = app.switches[id]
        if id == "theme.desktopLook" { showLook(app) } else { reveal(app, toggle) }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), id)
        let before = toggle.value as? String
        let inner = toggle.switches.firstMatch
        (inner.exists ? inner : toggle).tap()
        if !waitUntil(timeout: 2, { (app.switches[id].value as? String) != before }) {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            _ = waitUntil(timeout: 2) { (app.switches[id].value as? String) != before }
        }
    }

    @MainActor func launchSignedIn(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        let dark = ProcessInfo.processInfo.environment["HQN_SHOTS_DARK"] == "1"
        app.launchArguments = ["-HQDebugResetAccounts", "YES", "-HQDebugNoDrag", "YES"] + (dark ? ["-hqn.appearance", "dark"] : []) + arguments
        app.launch()
        signIn(app)
        return app
    }

    @MainActor func signIn(_ app: XCUIApplication, _ fixture: SettingsFixture? = nil) {
        let a = fixture ?? self.a!
        let address = app.textFields["sign-in-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 20), "the sign-in form shows")
        address.tap()
        if let current = address.value as? String, !current.isEmpty, current != "my-mac.tail1234.ts.net" {
            address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        address.typeText(a.url)
        let username = app.textFields["sign-in-username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        // The form grew a Name field on the train (onboarding): with the address's keyboard up the username field can
        // sit under the keyboard, and the tap then lands on a key. Scroll it clear and tap until it has the focus.
        // A full swipe goes too far (the field then sits under the onboarding Back button), so it is a short drag.
        for _ in 0..<4 {
            let keyboard = app.keyboards.firstMatch
            let top: CGFloat = 130, bottom = keyboard.exists ? keyboard.frame.minY - 12 : app.frame.maxY - 40
            let field = username.frame
            let shift = field.maxY > bottom ? field.maxY - bottom + 40 : (field.minY < top ? -(top - field.minY + 40) : 0)
            if shift != 0 {
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -shift)))
            }
            username.tap()
            if (username.value(forKey: "hasKeyboardFocus") as? Bool) == true { break }
        }
        username.typeText(a.username)
        let password = app.secureTextFields["sign-in-password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        for _ in 0..<3 {
            for _ in 0..<5 where !password.isHittable { app.swipeUp() }
            password.tap()
            password.typeText(a.password)
            let typed = (password.value as? String) ?? ""
            if !typed.isEmpty, typed != password.placeholderValue { break }
        }
        let button = app.buttons["sign-in-password-button"]
        for _ in 0..<5 where !button.isHittable { app.swipeUp() }
        button.tap()       // once: a sign-in is never retried in a loop
        // iOS offers to save the typed password. Under load the offer can come many seconds after the app has moved on
        // (stress round 2: it arrived after a 4 s wait and sat over the Theme page, so a skin card could not be
        // tapped). Wait for the sign-in form to leave, then for the offer; the helpers that tap look again.
        savePasswordDeclined = false
        let left = Date().addingTimeInterval(45)
        while Date() < left, !savePasswordDeclined, address.exists {
            if !declineSavePassword(app) { Thread.sleep(forTimeInterval: 0.3) }
        }
        let offer = Date().addingTimeInterval(12)
        while Date() < offer, !savePasswordDeclined {
            if !declineSavePassword(app) { Thread.sleep(forTimeInterval: 0.3) }
        }
    }

    /// Declines iOS's "Save Password?" offer if it is up. True when it was there and was declined. Once declined it
    /// is not looked for again in this test (each sign-in brings at most one).
    @MainActor @discardableResult func declineSavePassword(_ app: XCUIApplication) -> Bool {
        guard !savePasswordDeclined else { return false }
        let hosts = [app, XCUIApplication(bundleIdentifier: "com.apple.springboard"), XCUIApplication(bundleIdentifier: "com.apple.Passwords")]
        for host in hosts {
            let notNow = host.buttons["Not Now"]
            guard notNow.exists else { continue }
            notNow.tap()
            savePasswordDeclined = waitUntil(timeout: 5) { !notNow.exists }
            if savePasswordDeclined { Thread.sleep(forTimeInterval: 0.6) }     // the sheet's own dismissal
            return savePasswordDeclined
        }
        return false
    }

    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }

    @MainActor func shot(_ app: XCUIApplication, _ name: String) {
        declineSavePassword(app)      // never a screenshot (or the taps after it) with the offer over the page
        Thread.sleep(forTimeInterval: 0.6)
        let screenshot = app.screenshot()
        let mode = ProcessInfo.processInfo.environment["HQN_SHOTS_DARK"] == "1" ? "dark" : "light"
        if let dir = ProcessInfo.processInfo.environment["HQN_SHOTS"], !dir.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(mode).png"))
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(name)-\(mode)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
