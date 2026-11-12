// [terminal] The Terminal page end to end against scripts/fixtures/terminal-gateway.py (scripts/e2e-terminal.sh starts
// it and passes TEST_RUNNER_HQN_UI_CREDENTIALS + TEST_RUNNER_HQN_UI_TERMINAL=1; without them every test here skips).
// The fixture runs the add-on's own terminal.py: the shells are real, on this Mac, in a scratch HOME.

import XCTest

final class TerminalEndToEndTests: XCTestCase {
    var account: FixtureAccount!
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["HQN_UI_TERMINAL"] == "1" else {
            throw XCTSkip("Run with scripts/e2e-terminal.sh (the terminal fixture).")
        }
        account = try FixtureAccount.load()
        try account.control("/__fixture/terminal", ["plugin": "ready", "off": false, "supported": true])
    }

    // MARK: 1. Turn on, type, Select Text, paste (bracketed and asked), Copy All, leave and come back, End / New Shell

    @MainActor func test1_TypeCopyPasteAndComeBack() throws {
        launch(reset: true, extra: ["-HQDebugResetTerminal", "YES"])
        openTerminal(expectQuestion: true)
        waitLive()
        attach("1-live")

        app.typeText("echo hello-$((40+2))\n")
        XCTAssertTrue(waitForText("hello-42"), "the shell ran what was typed: \(screenText())")
        attach("2-typed")

        // Paste into zsh (bracketed paste: the lines wait in the line editor, Return runs them).
        UIPasteboard.general.string = "echo pasted-$((2*3))\necho second-line\n"
        pasteFromHold()
        XCTAssertTrue(waitForText("echo second-line"), "the paste is in zsh's line editor: \(screenText())")
        app.typeText("\n")
        XCTAssertTrue(waitForText("pasted-6") && waitForText("second-line"), "both pasted lines ran: \(screenText())")

        // bash 3.2 has no bracketed paste: several lines ask first.
        app.typeText("/bin/bash --norc --noprofile\n")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        UIPasteboard.general.string = "echo two-$((1+1))\necho lines-ok\n"
        pasteFromHold()
        let ask = app.alerts["Paste 2 Lines?"]
        XCTAssertTrue(ask.waitForExistence(timeout: 5), "several lines into a shell without bracketed paste ask first")
        attach("3-paste-asks")
        ask.buttons["Paste"].tap()
        XCTAssertTrue(waitForText("two-2") && waitForText("lines-ok"), "the asked paste ran: \(screenText())")
        app.typeText("exit\n")

        // The key bar: Up recalls the last command.
        XCTAssertTrue(app.buttons["terminal.key.up"].waitForExistence(timeout: 5), "the key bar is over the keyboard")
        app.typeText("echo arrow-$((5+5))\n")
        XCTAssertTrue(waitForText("arrow-10"))
        app.buttons["terminal.key.up"].tap()
        app.typeText("\n")
        XCTAssertTrue(waitUntil(timeout: 8) { self.screenText().components(separatedBy: "arrow-10").count >= 3 },
                      "Up brought the command back (typed twice, printed twice): \(screenText())")
        attach("4-keys")

        // Copy All puts the whole screen on the clipboard.
        menu("Copy All")
        // Checked by pasting it back: on iOS 27 the test runner's own read of the clipboard comes back nil.
        let shown = screenText().components(separatedBy: "hello-42").count
        pasteFromHold()
        XCTAssertTrue(waitUntil(timeout: 15) { self.screenText().components(separatedBy: "hello-42").count > shown },
                      "Copy All copied the screen (pasted back into the line): \(screenText())")
        app.buttons["terminal.key.ctrl"].tap()
        app.typeText("c")

        // Leave and come back: the same shell, its output replayed, no question.
        let dialsBefore = dials()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.cells["more-row-terminal"].waitForExistence(timeout: 5))
        openTerminal(expectQuestion: false)
        waitLive()
        XCTAssertTrue(waitForText("hello-42"), "what the shell printed before is back: \(screenText())")
        XCTAssertEqual(sessions().count, 1, "the same shell, not a second one")
        XCTAssertGreaterThan(dials(), dialsBefore)
        attach("5-came-back")

        // End Shell, then New Shell.
        menu("End Shell")
        let end = app.alerts["End This Shell?"]
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        end.buttons["End Shell"].tap()
        XCTAssertTrue(app.staticTexts["Shell Ended"].waitForExistence(timeout: 10), "the page says the shell ended")
        XCTAssertTrue(app.staticTexts["You ended this shell."].exists, "not the hang-up's exit code")
        attach("6-ended")
        app.buttons["New Shell"].tap()
        waitLive()
        XCTAssertFalse(screenText().contains("hello-42"), "a new shell starts on a clean screen")
        attach("7-new-shell")
    }

    // MARK: 2. Every look: iOS and Desktop, light and dark, with and without the keyboard (screenshots)

    @MainActor func test2_Looks() throws {
        for (desktop, dark) in [(false, false), (false, true), (true, false), (true, true)] {
            launch(reset: true, extra: ["-HQDebugDesktopLook", desktop ? "YES" : "NO", "-hqn.appearance", dark ? "dark" : "light"])
            openTerminal(expectQuestion: nil)
            waitLive()
            app.typeText("clear; printf '\\e[1mHermes HQ\\e[0m  \\e[31mred \\e[32mgreen \\e[33myellow \\e[34mblue \\e[35mmagenta\\e[0m\\n'; ls -G; echo $SHELL\n")
            XCTAssertTrue(waitForText("notes.txt"))
            let name = (desktop ? "desktop" : "ios") + (dark ? "-dark" : "-light")
            attach("look-\(name)-keyboard")
            hideKeyboard()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            // Owner 2026-11-11: the tab bar showed through the glass keyboard; it's away while typing, back after.
            XCTAssertTrue(moreTab().isHittable, "the tab bar is back once the keyboard goes")
            attach("look-\(name)")
            app.navigationBars.buttons["terminal.more"].tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            attach("look-\(name)-menu")
            app.terminate()
        }
    }

    // MARK: 3. Bot Info › Computer › Terminal, shown over Bot Info

    @MainActor func test3_BotInfoRow() throws {
        launch(reset: true)
        let cell = app.cells["bot-row-default"]
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        cell.press(forDuration: 1.0)
        let info = app.buttons["Bot Info"]
        XCTAssertTrue(info.waitForExistence(timeout: 5))
        info.tap()
        let list = app.collectionViews["bot-info.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let row = app.buttons["bot-info.terminal"]
        for _ in 0..<6 where !(row.exists && row.isHittable) { list.swipeUp() }
        XCTAssertTrue(row.isHittable, "Bot Info › Computer has the Terminal row")
        attach("botinfo-row")
        row.tap()
        let question = app.alerts.firstMatch
        if question.waitForExistence(timeout: 5), question.buttons["Turn On"].exists { question.buttons["Turn On"].tap() }
        waitLive()
        attach("botinfo-terminal")
        app.buttons["terminal.close"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "✕ goes back to Bot Info")
    }

    // MARK: 4. What the page says when it can't open a shell

    @MainActor func test4_CantOpen() throws {
        let cases: [(String, [String: Any], String)] = [
            ("old-addon", ["plugin": "outdated"], "Update the Add-on"),
            ("unsupported", ["plugin": "ready", "supported": false], "No Terminal Here"),
            ("turned-off", ["plugin": "ready", "supported": true, "off": true], "Turned Off on"),
            // 2026-11-02: the Hermes HQ edge answered the socket 404 and the page spun on "Opening a shell…" for good.
            ("blocked", ["plugin": "ready", "supported": true, "off": false, "blocked": true], "Terminal Blocked on the Way"),
        ]
        launch(reset: true)
        for (name, control, title) in cases {
            try account.control("/__fixture/terminal", control)
            openTerminal(expectQuestion: nil)
            let shown = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
            XCTAssertTrue(shown.waitForExistence(timeout: 10), "\(name): the page says \(title)")
            attach("cant-\(name)")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.cells["more-row-terminal"].waitForExistence(timeout: 5))
        }
        let dials = state()["dials"] as? Int ?? 0
        sleep(2)
        XCTAssertEqual(state()["dials"] as? Int, dials, "a blocked socket isn't dialled again")
        try account.control("/__fixture/terminal", ["plugin": "ready", "off": false, "supported": true, "blocked": false])
    }

    /// The blocked card in every look (screenshots): its text is the longest the page shows.
    @MainActor func test5_BlockedLooks() throws {
        try account.control("/__fixture/terminal", ["plugin": "ready", "supported": true, "off": false, "blocked": true])
        for (desktop, dark) in [(false, false), (false, true), (true, false), (true, true)] {
            launch(reset: true, extra: ["-HQDebugDesktopLook", desktop ? "YES" : "NO", "-hqn.appearance", dark ? "dark" : "light"])
            openTerminal(expectQuestion: nil)
            let shown = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Terminal Blocked on the Way")).firstMatch
            XCTAssertTrue(shown.waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["Try Again"].isHittable, "Try Again is on screen")
            attach("blocked-" + (desktop ? "desktop" : "ios") + (dark ? "-dark" : "-light"))
            app.terminate()
        }
        try account.control("/__fixture/terminal", ["plugin": "ready", "off": false, "supported": true, "blocked": false])
    }

    // MARK: 6. A tester and the owner (2026-11-04): esc, ctrl, tab and the arrows always at hand (layout A), and tabs

    @MainActor func test6_KeyBarAndTabs() throws {
        launch(reset: true, extra: ["-HQDebugResetTerminal", "YES"])
        openTerminal(expectQuestion: true)
        waitLive()
        XCTAssertTrue(app.buttons["terminal.key.left"].waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        attach("keys-0")
        let tree = XCTAttachment(string: app.debugDescription)
        tree.lifetime = .keepAlways
        add(tree)
        for key in ["left", "up", "down", "right", "esc", "ctrl", "tab"] {
            XCTAssertTrue(app.descendants(matching: .any)["terminal.key.\(key)"].firstMatch.isHittable, "\(key) shows")
        }
        // Layout A (owner 2026-11-04): only those; the rest live elsewhere.
        for key in ["paste", "hide", "pipe", "tilde", "slash", "dash"] {
            XCTAssertFalse(app.descendants(matching: .any)["terminal.key.\(key)"].firstMatch.exists, "no \(key) key")
        }
        attach("keys-1-arrows")
        app.typeText("echo ab")
        app.buttons["terminal.key.left"].tap()
        app.typeText("X\n")
        XCTAssertTrue(waitForText("aXb"), "← moved the cursor: \(screenText())")
        app.typeText("echo up-$((2+3))\n")
        XCTAssertTrue(waitForText("up-5"))
        app.buttons["terminal.key.up"].tap()
        app.typeText("\n")
        XCTAssertTrue(waitUntil(timeout: 10) { self.screenText().components(separatedBy: "up-5").count > 2 }, "↑ brought the last line back: \(screenText())")

        // a tester 2026-11-05 ("Backspace"): a held delete clears a line the shell brought back (↑), which SwiftTerm's own
        // copy of what was typed doesn't hold.
        app.buttons["terminal.key.up"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let delete = app.keys["delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "the keyboard's delete key")
        delete.press(forDuration: 4)
        app.typeText("echo held-ok\n")
        XCTAssertTrue(waitUntil(timeout: 10) { self.screenText().components(separatedBy: "\n").contains("held-ok") },
                      "holding delete cleared the recalled line: \(screenText())")
        attach("keys-2-delete")

        // The keyboard hides with a drag of the screen down. a tester 2026-11-05: it comes back only from ⌨, not a tap.
        hideKeyboard()
        attach("keys-3-hidden")
        app.descendants(matching: .any)["terminal.screen"].firstMatch.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(app.buttons["terminal.key.esc"].exists, "a tap on the screen leaves the keyboard away")
        let keyboard = app.buttons["terminal.keyboard"]
        XCTAssertTrue(keyboard.isHittable, "⌨ shows while the keyboard is away")
        keyboard.tap()
        XCTAssertTrue(app.buttons["terminal.key.esc"].waitForExistence(timeout: 5), "⌨ brings the keyboard back")
        XCTAssertFalse(keyboard.exists && keyboard.isHittable, "⌨ goes while the keyboard is up")

        // + opens a second shell in a tab; each tab keeps its own screen.
        app.navigationBars.buttons["terminal.newTab"].tap()
        XCTAssertTrue(app.buttons["terminal.tab.2"].waitForExistence(timeout: 5), "the strip shows with two tabs")
        XCTAssertTrue(waitUntil(timeout: 20) { self.sessions().filter { $0["viewer"] as? Bool == true }.count >= 2 }, "two shells: \(sessions())")
        XCTAssertTrue(app.buttons["terminal.key.esc"].waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.typeText("echo in-tab-$((1+1))\n")
        XCTAssertTrue(waitForText("in-tab-2"))
        XCTAssertFalse(screenText().contains("aXb"), "the second tab is its own shell")
        attach("tabs-1-second")
        app.buttons["terminal.tab.1"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let first = screenText()
        XCTAssertTrue(first.contains("aXb") && !first.contains("in-tab-2"), "the first tab is as it was: \(first)")
        XCTAssertTrue(app.buttons["terminal.key.esc"].exists, "the keyboard stays up from tab to tab")
        attach("tabs-2-first")

        // a tester 2026-11-05: name a tab (hold › Rename Tab…), then move it (hold › Move Left, then Move Right).
        app.buttons["terminal.tab.2"].press(forDuration: 1.0)
        let rename = app.buttons["Rename Tab…"].firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "holding a tab offers Rename Tab…")
        attach("tabs-3-hold")
        rename.tap()
        let name = app.alerts["Rename Tab"].textFields["terminal.tab.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("build")
        app.alerts["Rename Tab"].buttons["Rename"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.app.buttons["terminal.tab.2"].label == "build" }, "the tab shows its name: \(app.buttons["terminal.tab.2"].label)")
        app.buttons["terminal.tab.2"].press(forDuration: 1.0)
        let left = app.buttons["Move Left"].firstMatch
        XCTAssertTrue(left.waitForExistence(timeout: 5))
        left.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.app.buttons["terminal.tab.1"].label == "build" }, "build moved to the front of the strip")
        XCTAssertTrue(waitForText("aXb"), "the tab in front is still the first shell, now second in the strip")
        XCTAssertTrue(app.buttons["terminal.key.esc"].waitForExistence(timeout: 5), "the keyboard comes back after a tab's menu")
        attach("tabs-4-moved")
        app.buttons["terminal.tab.1"].press(forDuration: 1.0)
        let right = app.buttons["Move Right"].firstMatch
        XCTAssertTrue(right.waitForExistence(timeout: 5))
        right.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.app.buttons["terminal.tab.2"].label == "build" }, "build moved back to second")
        XCTAssertTrue(app.buttons["terminal.tab.2"].isHittable)

        // ⋯ › Font › Hack Nerd Font: a powerline arrow and a Nerd Font icon draw (screenshot). In the second tab, so
        // the first keeps its lines for the close below.
        app.buttons["terminal.tab.2"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        menu("Font")
        let hack = app.buttons["Hack Nerd Font"].firstMatch
        XCTAssertTrue(hack.waitForExistence(timeout: 5), "⋯ › Font lists Hack Nerd Font")
        hack.tap()
        app.typeText("clear; printf '\\e[44m ~/hermes \\e[0;34m\\ue0b0\\e[0m \\uf418 main \\uf0e7 fast\\n'\n")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        attach("font-hack")
        hideKeyboard()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        attach("font-hack-full-screen")
        app.buttons["terminal.keyboard"].tap()
        XCTAssertTrue(app.buttons["terminal.key.esc"].waitForExistence(timeout: 5))
        app.buttons["terminal.tab.1"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        // ✕ on the tab in front closes it (asked first: its shell ends).
        app.buttons["terminal.tab.2"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.buttons["terminal.tab.close"].tap()
        let ask = app.alerts["Close This Tab?"]
        XCTAssertTrue(ask.waitForExistence(timeout: 5))
        ask.buttons["Close Tab"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { !self.app.buttons["terminal.tab.1"].exists }, "one tab left: the strip goes")
        XCTAssertTrue(waitForText("aXb"), "the first tab is in front again")
        attach("tabs-5-closed")
        app.terminate()

        // The strip in the Desktop Look, light.
        launch(reset: false, extra: ["-HQDebugDesktopLook", "YES", "-hqn.appearance", "light"])
        openTerminal(expectQuestion: nil)
        waitLive()
        app.navigationBars.buttons["terminal.newTab"].tap()
        XCTAssertTrue(app.buttons["terminal.tab.2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["terminal.key.esc"].waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        attach("tabs-6-desktop")
        hideKeyboard()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        attach("tabs-7-desktop-keyboard-away")
    }

    // MARK: Helpers

    @MainActor private func launch(reset: Bool, extra: [String] = []) {
        let app = XCUIApplication()
        app.launchArguments = (reset ? ["-HQDebugResetAccounts", "YES"] : []) + ["-HQTerminalNoLock", "YES", "-HQDebugPushAnyTopic", "YES", "-HQDebugAnimationWatch", "YES", "-HQDebugNoPushOffer", "YES"] + extra
        app.launchEnvironment = ["HQN_SIGNIN_URL": account.url, "HQN_SIGNIN_USERNAME": account.username, "HQN_SIGNIN_PASSWORD": account.password]
        app.launch()
        self.app = app
        XCTAssertTrue(moreTab(timeout: 30).exists, "signed in: the tabs show")
    }

    /// More: the tab bar's in the iOS look, the Desktop Look's own bar otherwise.
    @MainActor private func moreTab(timeout: TimeInterval = 5) -> XCUIElement {
        let tab = app.tabBars.buttons["More"]
        let any = app.buttons["More"].firstMatch
        _ = waitUntil(timeout: timeout) { tab.exists || any.exists }
        return tab.exists ? tab : any
    }

    /// More › Terminal. `expectQuestion`: true, the first-time question must show (Turn On); nil, it may.
    @MainActor private func openTerminal(expectQuestion: Bool?) {
        let more = moreTab()
        let row = app.cells["more-row-terminal"]
        for _ in 0..<4 {
            more.tap()
            if row.waitForExistence(timeout: 2), row.isHittable { break }
            app.collectionViews.firstMatch.swipeUp()
            if row.isHittable { break }
        }
        XCTAssertTrue(row.isHittable, "More lists Terminal")
        row.tap()
        // The first-time question: a card on the page (it was an alert).
        let question = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Open a Terminal on")).firstMatch
        let turnOn = app.buttons["Turn On"].firstMatch
        switch expectQuestion {
        case true?:
            XCTAssertTrue(question.waitForExistence(timeout: 10), "the first open asks")
            attach("0-question")
            turnOn.tap()
        case nil:
            if question.waitForExistence(timeout: 3) { turnOn.tap() }
        case false?:
            XCTAssertFalse(question.waitForExistence(timeout: 2), "asked only once")
        }
    }

    /// The shell is open, full screen (a tester 2026-11-05: the keyboard doesn't come up by itself), then ⌨ for typing.
    @MainActor private func waitLive() {
        XCTAssertTrue(waitUntil(timeout: 20) { self.sessions().contains { $0["viewer"] as? Bool == true } }, "a shell is open: \(sessions())")
        let keyboard = app.buttons["terminal.keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10), "⌨ shows once the shell is open")
        XCTAssertFalse(app.buttons["terminal.key.esc"].exists, "the keyboard waits to be asked for")
        keyboard.tap()
        XCTAssertTrue(app.buttons["terminal.key.esc"].waitForExistence(timeout: 10), "typing: the keyboard and key bar are up")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    }

    /// A ⋯ item. Tried again when the tap didn't open the menu: for a moment after a paste, iOS's "… pasted from …"
    /// banner sits over the page's bar and takes the tap.
    @MainActor @discardableResult private func menu(_ title: String) -> Bool {
        for _ in 0..<3 {
            waitForPasteBanner()
            app.navigationBars.buttons["terminal.more"].tap()
            // A submenu carries its choice after its title ("Font, SF Mono").
            let named = NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")
            let inMenu = app.collectionViews.buttons.matching(named).firstMatch
            let anywhere = app.buttons.matching(named).firstMatch
            if waitUntil(timeout: 3, { inMenu.exists || anywhere.exists }) {
                (inMenu.exists ? inMenu : anywhere).tap()
                return true
            }
        }
        XCTFail("⋯ has \(title)")
        return false
    }

    @MainActor private func waitForPasteBanner() {
        let banner = XCUIApplication(bundleIdentifier: "com.apple.springboard").staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "pasted from")).firstMatch
        waitUntil(timeout: 8) { !banner.exists }
    }

    /// Hold the screen, then the menu's Paste: iOS's own edit menu, so no "Allow Paste?" (⋯ › Paste reads the
    /// pasteboard itself, so iOS asks first, and that question holds the app's main thread where a UI test can't
    /// answer it).
    @MainActor private func pasteFromHold() {
        let screen = app.descendants(matching: .any)["terminal.screen"].firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(forDuration: 0.8)
        let paste = app.menuItems["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "holding the screen offers Paste")
        paste.tap()
    }

    /// Drag the screen down into the keyboard, which hides it (layout A has no Hide Keyboard key).
    @MainActor private func hideKeyboard() {
        let screen = app.descendants(matching: .any)["terminal.screen"].firstMatch
        let start = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(waitUntil(timeout: 5) { !self.app.buttons["terminal.key.esc"].exists }, "the drag hid the keyboard")
    }

    /// ⋯ › Select Text's plain text (then closed).
    @MainActor private func screenText() -> String {
        guard menu("Select Text…") else { return "" }
        let text = app.textViews["terminal.text"]
        guard text.waitForExistence(timeout: 5) else { return "" }
        let value = text.value as? String ?? ""
        app.buttons["terminal.text.done"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        return value
    }

    @MainActor private func waitForText(_ text: String) -> Bool {
        waitUntil(timeout: 10) { self.screenText().contains(text) }
    }

    private func state() -> [String: Any] { (try? account.control("/__fixture/terminal")) ?? [:] }
    private func sessions() -> [[String: Any]] { state()["sessions"] as? [[String: Any]] ?? [] }
    private func dials() -> Int { state()["dials"] as? Int ?? 0 }

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
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return condition()
    }
}
