// [m9/ipad] The two-pane layout on an iPad simulator (docs/spec/3x-ipad.md §9, §10). Run with scripts/e2e-ipad.sh.
// On an iPhone simulator every test here skips (the phone's root is unchanged; the phone suites cover it).

import XCTest

final class IPadLayoutTests: IPadTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .portrait }
    }

    @MainActor private func padOnly() throws {
        guard IPad.isPad else { throw XCTSkip("iPad only") }
    }

    /// Two panes: the list and the placeholder side by side; a tapped bot opens on the right while the list stays;
    /// its row is marked; switching tabs on the left leaves the chat.
    @MainActor func test1_TwoPanesOpenAChatBesideTheList() throws {
        try padOnly()
        let account = try IPad.account(.perf)
        let app = IPad.launch(account)
        let list = app.collectionViews["bots.list"]
        let placeholder = IPad.placeholder(app)
        XCTAssertTrue(placeholder.waitForExistence(timeout: 5), "the right pane shows its placeholder")
        XCTAssertEqual(placeholder.label, "Nothing Selected. Choose an item from the list.")
        XCTAssertTrue(IPad.shows(list), "the list shows beside it")
        XCTAssertGreaterThan(placeholder.frame.minX, list.frame.maxX - 1, "the placeholder is to the right of the list")
        XCTAssertTrue(app.tabBars.buttons["tab-bots"].exists || app.buttons["tab-bots"].exists, "the left pane has the tab bar")
        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.exists && bar.frame.minY > app.windows.firstMatch.frame.height * 0.8, "the tab bar is at the bottom")
        XCTAssertLessThanOrEqual(bar.frame.maxX, list.frame.maxX + 1, "the tab bar stays inside the left pane")
        IPad.shot(app, "ipad-two-panes-empty", in: self)

        let table = IPad.openBot(app)
        XCTAssertTrue(IPad.shows(list), "the list is still there beside the chat")
        XCTAssertGreaterThan(table.frame.minX, list.frame.maxX - 1, "the chat is in the right pane")
        XCTAssertFalse(placeholder.exists, "the placeholder is gone")
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { app.cells["bot-row-default"].isSelected }, "the open chat's row is marked")
        XCTAssertFalse(app.navigationBars.buttons["Bots"].exists, "no Back button on the right pane's first screen")
        IPad.shot(app, "ipad-two-panes-chat", in: self)

        app.buttons["tab-sessions"].tap()
        XCTAssertTrue(app.collectionViews["sessions.list"].waitForExistence(timeout: 8))
        XCTAssertTrue(table.exists, "switching tabs on the left leaves the chat on the right")
        IPad.shot(app, "ipad-two-panes-sessions-tab", in: self)
        app.buttons["tab-bots"].tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { app.cells["bot-row-default"].isSelected }, "back on Bots the row is still marked")

        // Opening the chat already on show builds nothing new.
        Thread.sleep(forTimeInterval: 1.5)
        let before = IPad.rpcs(account)
        app.cells["bot-row-default"].tap()
        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertEqual(IPad.rpcs(account), before, "tapping the open chat's row sends nothing at all to the gateway")
        XCTAssertTrue(table.exists && app.cells["bot-row-default"].isSelected, "and the chat stays as it was")

        // The other bot replaces it.
        app.cells["bot-row-ivy"].tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 8) { app.cells["bot-row-ivy"].isSelected && !app.cells["bot-row-default"].isSelected },
                      "the mark follows the chat on show")
    }

    /// Rotation keeps the same chat, its draft and the two panes; a layout change sends nothing to the gateway.
    @MainActor func test2_RotationKeepsTheChatAndItsDraft() throws {
        try padOnly()
        let account = try IPad.account(.perf)
        let app = IPad.launch(account)
        IPad.openBot(app)
        let field = IPad.focusField(app)
        field.typeText("a draft that must survive")
        let resumes = IPad.count("session.resume", account), submits = IPad.count("prompt.submit", account)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(IPad.waitUntil(timeout: 8) { app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height })
        XCTAssertTrue(IPad.table(app).exists && IPad.shows(app.collectionViews["bots.list"]), "two panes in landscape")
        XCTAssertEqual(IPad.field(app).value as? String, "a draft that must survive")
        IPad.shot(app, "ipad-landscape-chat", in: self)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(IPad.waitUntil(timeout: 8) { app.windows.firstMatch.frame.width < app.windows.firstMatch.frame.height })
        XCTAssertEqual(IPad.field(app).value as? String, "a draft that must survive")
        XCTAssertTrue(IPad.table(app).exists)
        XCTAssertEqual(IPad.count("session.resume", account), resumes, "rotating opens nothing again")
        XCTAssertEqual(IPad.count("prompt.submit", account), submits, "rotating sends nothing")
    }

    /// A narrow window is the phone layout: the chat is pushed over the list and Back returns to it.
    @MainActor func test3_NarrowWindowIsThePhoneLayout() throws {
        try padOnly()
        let account = try IPad.account(.perf)
        let app = IPad.launch(account, arguments: ["-HQDebugPaneWidth", "420"])
        XCTAssertFalse(IPad.placeholder(app).exists, "no right pane in a narrow window")
        let list = app.collectionViews["bots.list"]
        XCTAssertLessThanOrEqual(list.frame.width, 421)
        IPad.shot(app, "ipad-narrow-list", in: self)
        IPad.openBot(app)
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { !IPad.shows(list) }, "the chat covers the list")
        XCTAssertLessThanOrEqual(IPad.table(app).frame.width, 421)
        IPad.shot(app, "ipad-narrow-chat", in: self)
        IPad.back(app)
        XCTAssertTrue(IPad.waitUntil(timeout: 6) { IPad.shows(list) }, "Back returns to the list")
    }

    /// Crossing the threshold with a chat open, both ways, keeps the same chat, its draft and a running reply.
    @MainActor func test4_CrossingTheThresholdKeepsEverything() throws {
        try padOnly()
        let account = try IPad.account(.perf)
        let app = IPad.launch(account)
        IPad.openBot(app)
        // Ten minutes of reply: a crossing can wait out XCUITest's 60 s idle timeout (the keyboard's suggestions bar
        // never settles), and three rounds of that outlasted a shorter reply. The test stops it at the end.
        try IPad.plan(account, [["chunks": Array(repeating: "word ", count: 15000), "chunkDelay": 0.04]])
        // The stand-in gateway is shared by the tests of one run, so the counts are taken from here.
        let sentBefore = IPad.count("prompt.submit", account), stoppedBefore = IPad.count("session.interrupt", account)
        var field = IPad.focusField(app)
        field.typeText("keep streaming please")
        IPad.send(app)
        let reply = IPad.message(app, containing: "said: word word")
        XCTAssertTrue(reply.waitForExistence(timeout: 12), "the reply streams")
        field = IPad.field(app)
        field.tap()
        field.typeText("draft across")
        let list = app.collectionViews["bots.list"]
        func fieldOnKeys(_ what: String) { IPad.fieldOnKeys(app, what) }
        fieldOnKeys("before any crossing")

        for round in 1...3 {
            let early = reply.label.count
            IPad.toggleNarrow(app)      // DEBUG: the window becomes 420 pt wide
            XCTAssertTrue(IPad.waitUntil(timeout: 6) { !IPad.placeholder(app).exists && !IPad.shows(list) },
                          "round \(round): the phone layout shows the chat over its list")
            XCTAssertTrue(IPad.table(app).exists, "round \(round): the same chat is on show")
            XCTAssertLessThanOrEqual(IPad.table(app).frame.width, 421)
            XCTAssertEqual(IPad.field(app).value as? String, "draft across", "round \(round): the draft crossed")
            XCTAssertTrue(IPad.waitUntil(timeout: 6) { reply.label.count > early + 10 }, "round \(round): the reply keeps streaming")
            if round == 1 { IPad.shot(app, "ipad-collapsed-streaming", in: self) }
            fieldOnKeys("round \(round), phone layout")
            let mid = reply.label.count
            IPad.toggleNarrow(app)      // back to the real window
            XCTAssertTrue(IPad.waitUntil(timeout: 6) { IPad.shows(list) && IPad.table(app).exists },
                          "round \(round): two panes again with the chat on the right")
            XCTAssertEqual(IPad.field(app).value as? String, "draft across")
            XCTAssertTrue(IPad.waitUntil(timeout: 6) { reply.label.count > mid + 10 }, "round \(round): still streaming")
            if round == 1 { IPad.shot(app, "ipad-expanded-streaming", in: self) }
            fieldOnKeys("round \(round), two panes again")
        }
        XCTAssertEqual(IPad.count("prompt.submit", account) - sentBefore, 1, "one send, whatever the layout did")
        XCTAssertEqual(IPad.count("session.interrupt", account) - stoppedBefore, 0, "crossing never stops the reply")
        let stop = app.buttons["composer.stop"].firstMatch
        if stop.exists { stop.tap() }
    }

    /// More › Settings opens on the right; its pages push there with a Back button; the More list stays.
    @MainActor func test5_SettingsOpensInTheRightPane() throws {
        try padOnly()
        let account = try IPad.account(.perf)
        let app = IPad.launch(account)
        app.buttons["tab-more"].tap()
        let more = app.collectionViews["more.list"]
        XCTAssertTrue(more.waitForExistence(timeout: 8))
        app.cells["more-row-settings"].tap()
        let settings = app.descendants(matching: .any)["settings.list"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8), "Settings shows")
        XCTAssertTrue(IPad.shows(more), "the More list stays on the left")
        XCTAssertGreaterThan(settings.frame.minX, more.frame.maxX - 1, "Settings is in the right pane")
        IPad.shot(app, "ipad-settings-right", in: self)
        let page = app.descendants(matching: .any)["settings.notifications"]
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        page.tap()
        let back = app.navigationBars.buttons["Settings"]
        XCTAssertTrue(back.waitForExistence(timeout: 6), "a Settings page pushes in the right pane with Back")
        XCTAssertTrue(IPad.shows(more), "the More list is still on the left")
        IPad.shot(app, "ipad-settings-page-right", in: self)
        back.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 6))
        // The other pages of More open on the right too.
        if app.cells["more-row-capabilities"].exists {
            app.cells["more-row-capabilities"].tap()
            XCTAssertTrue(IPad.waitUntil(timeout: 6) { !settings.exists }, "Capabilities replaces Settings on the right")
            XCTAssertTrue(IPad.shows(more))
            IPad.shot(app, "ipad-capabilities-right", in: self)
        }
    }

    /// A relaunch reopens the last chat in the right pane; a relaunch into a narrow window reopens it over its list.
    @MainActor func test6_RelaunchReopensTheChatInEitherLayout() throws {
        try padOnly()
        let account = try IPad.account(.perf)
        var app = IPad.launch(account)
        IPad.openBot(app)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1.5)
        app.terminate()
        app = IPad.launch(account, reset: false)
        XCTAssertTrue(IPad.table(app).waitForExistence(timeout: 10), "the chat is back")
        XCTAssertTrue(IPad.shows(app.collectionViews["bots.list"]), "beside its list")
        XCTAssertFalse(IPad.placeholder(app).exists)
        XCTAssertTrue(IPad.waitUntil(timeout: 8) { app.cells["bot-row-default"].isSelected }, "its row is marked after the relaunch")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1.5)
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-HQDebugPaneWidth", "420"]
        app.launch()
        IPadTestCase.launchedPid = (app.value(forKey: "processID") as? Int32) ?? 0
        XCTAssertTrue(IPad.table(app).waitForExistence(timeout: 20), "the chat is back in the narrow window")
        XCTAssertLessThanOrEqual(IPad.table(app).frame.width, 421)
        IPad.back(app)
        XCTAssertTrue(IPad.waitUntil(timeout: 6) { IPad.shows(app.collectionViews["bots.list"]) }, "Back returns to its list")
    }

    /// The chat's ⋯ menu, a sheet and an action sheet open anchored on iPad (an unanchored one crashes there).
    @MainActor func test7_MenusAndSheetsOpenAnchored() throws {
        try padOnly()
        let account = try IPad.account(.perf)
        let app = IPad.launch(account)
        IPad.openBot(app)
        let more = app.buttons["chat.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 6))
        more.tap()
        XCTAssertTrue(app.buttons["Mark as Unread"].waitForExistence(timeout: 5) || app.collectionViews.buttons.firstMatch.waitForExistence(timeout: 2),
                      "the ⋯ menu opens")
        IPad.shot(app, "ipad-chat-menu", in: self)
        // Below the menu, which reaches about a third of the way down the pane: a tap at 0.3 lands on its More row and
        // opens the submenu instead (that hides Mark as Unread too, so the check also looks for the submenu's Export Chat).
        IPad.table(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 4) { !app.buttons["Mark as Unread"].exists && !app.buttons["Export Chat…"].exists },
                      "a tap outside closes the menu")
        // ☰ shows on iPad too and opens the commands sheet.
        let commands = app.buttons["composer.commands"]
        XCTAssertTrue(commands.waitForExistence(timeout: 5), "the commands button shows on iPad")
        commands.tap()
        let sheet = app.navigationBars["Commands"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 8), "the commands sheet opens")
        IPad.shot(app, "ipad-commands-sheet", in: self)
        XCTAssertTrue(IPad.stopOrClose(app, "commands sheet") { !sheet.exists }, "Stop or Close closes the sheet")
        XCTAssertTrue(IPad.table(app).exists, "the chat is still there")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// A Sessions row's Share sheet and its Delete action sheet open anchored on iPad; deleting the chat that is on
    /// show in the right pane gives the pane back to the placeholder (§6).
    @MainActor func test8_ShareAndDeleteFromTheListBesideTheOpenChat() throws {
        try padOnly()
        let account = try IPad.account(.sessions)
        try account.control("/__fixture/reset", [:])
        let app = IPad.launch(account)
        app.buttons["tab-sessions"].tap()
        let garden = app.cells["session-row-s-garden"]
        XCTAssertTrue(garden.waitForExistence(timeout: 15), "the Sessions list shows its rows")
        garden.tap()
        XCTAssertTrue(IPad.table(app).waitForExistence(timeout: 10), "the session opens on the right")
        XCTAssertTrue(IPad.shows(app.collectionViews["sessions.list"]), "beside the list")
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { garden.isSelected }, "its row is marked")
        IPad.shot(app, "ipad-session-open", in: self)

        // Share from the row's menu: an anchored share sheet.
        var menu = false
        for _ in 0..<3 where !menu { garden.press(forDuration: 1.0); menu = app.buttons["Share"].firstMatch.waitForExistence(timeout: 3) }
        XCTAssertTrue(menu, "the row's menu opens")
        IPad.shot(app, "ipad-session-row-menu", in: self)
        app.buttons["Share"].firstMatch.tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 8) { app.otherElements["ActivityListView"].exists || app.navigationBars["UIActivityContentView"].exists
            || app.buttons["Copy"].exists }, "the share sheet opens")
        IPad.shot(app, "ipad-share-sheet", in: self)
        XCTAssertEqual(app.state, .runningForeground, "an unanchored share sheet would have crashed here")
        let dismiss = app.otherElements["PopoverDismissRegion"].firstMatch
        if dismiss.exists { dismiss.tap() } else if app.buttons["Close"].firstMatch.exists { app.buttons["Close"].firstMatch.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.05)).tap() }
        XCTAssertTrue(IPad.waitUntil(timeout: 6) { !app.otherElements["ActivityListView"].exists }, "the share sheet closes")

        // Delete from the row: the anchored action sheet, then the right pane empties.
        garden.swipeLeft()
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 4), "the swipe shows Delete")
        app.buttons["Delete"].tap()
        let confirm = app.buttons["Delete Chat"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 4), "Delete asks in an action sheet")
        IPad.shot(app, "ipad-delete-action-sheet", in: self)
        XCTAssertEqual(app.state, .runningForeground)
        confirm.tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 10) { !garden.exists }, "the row goes")
        XCTAssertTrue(IPad.placeholder(app).waitForExistence(timeout: 6), "the deleted chat leaves the right pane: the placeholder shows")
        XCTAssertFalse(IPad.table(app).exists)
        IPad.shot(app, "ipad-deleted-chat-pane-empty", in: self)
    }

    /// A real crossing with no stand-in window: an iPad mini is 744 pt wide in portrait (phone layout) and 1,133 pt in
    /// landscape (two panes). Rotating with the keyboard up keeps the chat, the draft and the field on the keys.
    @MainActor func test10_MiniRotationCrossesWithTheKeyboardUp() throws {
        try padOnly()
        let account = try IPad.account(.perf)
        let app = IPad.launch(account)
        guard app.windows.firstMatch.frame.width < 768 else { throw XCTSkip("needs an iPad narrower than 768 pt in portrait (iPad mini)") }
        let list = app.collectionViews["bots.list"]
        XCTAssertFalse(IPad.placeholder(app).exists, "portrait on the mini is the phone layout")
        IPad.openBot(app)
        IPad.focusField(app).typeText("mini draft")
        IPad.fieldOnKeys(app, "mini portrait")
        IPad.shot(app, "mini-portrait-chat-keyboard", in: self)
        let submits = IPad.count("prompt.submit", account), resumes = IPad.count("session.resume", account)
        for round in 1...2 {
            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertTrue(IPad.waitUntil(timeout: 10) { app.windows.firstMatch.frame.width > 1000 && IPad.shows(list) && IPad.table(app).exists },
                          "round \(round): landscape is two panes with the chat on the right")
            XCTAssertGreaterThan(IPad.table(app).frame.minX, list.frame.maxX - 1)
            XCTAssertEqual(IPad.field(app).value as? String, "mini draft")
            IPad.fieldOnKeys(app, "mini landscape, round \(round)")
            if round == 1 { IPad.shot(app, "mini-landscape-chat-keyboard", in: self) }
            XCUIDevice.shared.orientation = .portrait
            XCTAssertTrue(IPad.waitUntil(timeout: 10) { app.windows.firstMatch.frame.width < 768 && !IPad.shows(list) && IPad.table(app).exists },
                          "round \(round): portrait is the phone layout with the chat over its list")
            XCTAssertEqual(IPad.field(app).value as? String, "mini draft")
            IPad.fieldOnKeys(app, "mini portrait again, round \(round)")
            if round == 1 { IPad.shot(app, "mini-portrait-again-chat-keyboard", in: self) }
        }
        XCTAssertEqual(IPad.count("prompt.submit", account), submits)
        XCTAssertEqual(IPad.count("session.resume", account), resumes, "rotating opens nothing again")
    }

    /// A window 500 pt tall or less is the phone layout however wide it is (the web's phone query).
    @MainActor func test9_ShortWindowIsThePhoneLayout() throws {
        try padOnly()
        let account = try IPad.account(.perf)
        let app = IPad.launch(account, arguments: ["-HQDebugPaneHeight", "480"])
        let list = app.collectionViews["bots.list"]
        XCTAssertFalse(IPad.placeholder(app).exists, "no right pane in a short window")
        XCTAssertGreaterThan(list.frame.width, 700, "the list takes the whole width")
        XCTAssertLessThanOrEqual(list.frame.height, 481)
        IPad.shot(app, "ipad-short-window-list", in: self)
        IPad.openBot(app)
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { !IPad.shows(list) }, "the chat covers the list")
        IPad.shot(app, "ipad-short-window-chat", in: self)
    }

    /// Opening a chat at an accessibility text size, in whichever layout the device gives (two panes on iPad). At
    /// these sizes the bar caps its title's text size while it seats the title; the chat used to take its title out
    /// of the bar at that very moment and the app died on an uncaught layout exception (stress round 2: 3 of 3 at
    /// the largest size in the iPad's right pane). Largest size and the first accessibility size, then a second
    /// chat, a title tap and a trip through the narrow layout and back (each one seats the title again).
    @MainActor func test11_OpeningAChatAtAccessibilityTextSizes() throws {
        let account = try IPad.account(.perf)
        for size in ["UICTContentSizeCategoryAccessibilityXXXL", "UICTContentSizeCategoryAccessibilityM"] {
            let app = IPad.launch(account, arguments: ["-UIPreferredContentSizeCategoryName", size])
            let table = IPad.openBot(app)
            let title = app.descendants(matching: .any)["chat.title"].firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 8), "\(size): the chat's title shows")
            XCTAssertEqual(app.state, .runningForeground, "\(size): the app is still running with the chat open")
            XCTAssertGreaterThan(title.frame.width, 40, "\(size): the title has a real size")
            XCTAssertLessThanOrEqual(title.frame.maxX, app.windows.firstMatch.frame.maxX, "\(size): and stays inside the window")
            if IPad.isPad {
                XCTAssertTrue(IPad.shows(app.collectionViews["bots.list"]), "\(size): two panes, the list beside the chat")
                XCTAssertGreaterThan(title.frame.minX, app.collectionViews["bots.list"].frame.maxX - 1, "\(size): the title is in the right pane's bar")
            }
            IPad.shot(app, "ipad-text-\(size.hasSuffix("XXXL") ? "largest" : "ax-medium")-chat", in: self)
            guard IPad.isPad else {
                XCTAssertTrue(table.exists)
                continue
            }
            app.cells["bot-row-ivy"].tap()
            XCTAssertTrue(IPad.waitUntil(timeout: 10) { app.cells["bot-row-ivy"].isSelected }, "\(size): a second chat opens")
            XCTAssertTrue(title.waitForExistence(timeout: 8), "\(size): with its title")
            IPad.toggleNarrow(app)
            XCTAssertTrue(IPad.waitUntil(timeout: 8) { !IPad.shows(app.collectionViews["bots.list"]) }, "\(size): narrow, the chat covers the list")
            XCTAssertTrue(title.waitForExistence(timeout: 8), "\(size): the title shows in the phone layout")
            IPad.toggleNarrow(app)
            XCTAssertTrue(IPad.waitUntil(timeout: 8) { IPad.shows(app.collectionViews["bots.list"]) }, "\(size): wide again, two panes")
            XCTAssertTrue(title.waitForExistence(timeout: 8) && IPad.table(app).exists, "\(size): the chat and its title came back")
            XCTAssertEqual(app.state, .runningForeground, "\(size): the app is still running")
            IPad.shot(app, "ipad-text-\(size.hasSuffix("XXXL") ? "largest" : "ax-medium")-after", in: self)
        }
    }
}
