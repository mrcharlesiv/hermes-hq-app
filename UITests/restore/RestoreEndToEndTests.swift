// [restore] The last chat reopened on launch, end to end against the restore fixture (scripts/e2e-restore.sh starts
// scripts/fixtures/restore-gateway.py and passes TEST_RUNNER_HQN_UI_CREDENTIALS + TEST_RUNNER_HQN_UI_RESTORE=1; without
// them every test here skips). "Leaving" the app is a trip to the Home Screen and then the end of the process, as iOS
// ends a backgrounded app; ending it in the foreground counts as a crash there. All values are invented.

import XCTest

final class RestoreEndToEndTests: XCTestCase {
    var account: FixtureAccount!
    var app: XCUIApplication!
    /// R4 crashes the app on purpose: XCTest's "<app> crashed" issue is expected then (any other issue still counts).
    private var crashExpected = false

    override func record(_ issue: XCTIssue) {
        if crashExpected, issue.compactDescription.contains("crashed") { return }
        super.record(issue)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["HQN_UI_RESTORE"] == "1" else {
            throw XCTSkip("Run with scripts/e2e-restore.sh (the restore fixture).")
        }
        account = try FixtureAccount.load()
        try account.control("/__restore/reset", [:])
    }

    // MARK: R1. A bot's chat comes back over Bots, at once, and Back returns to Bots

    @MainActor func testR1_BotChatReopensOverBots() throws {
        launch(reset: true)
        openBot("deploys")
        leaveAndRelaunch()
        // On screen with the first frames of the tabs: no list first, no push.
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 5), "the chat is back")
        XCTAssertTrue(chatTitle().contains("Deploys"), "Deploys' chat: \(chatTitle())")
        XCTAssertFalse(app.tabBars.firstMatch.isHittable, "the chat hides the tab bar as a tapped open does")
        shot("restore-bot-chat")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 5), "Back returns to Bots")
        XCTAssertTrue(app.tabBars.buttons["Bots"].isSelected)
        // Left on the list: the next launch shows the list.
        leaveAndRelaunch()
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tables["chat.table"].waitForExistence(timeout: 3), "a list left on show is not a chat")
    }

    // MARK: R2. A chat opened from Sessions comes back over Sessions

    @MainActor func testR2_SessionChatReopensOverSessions() throws {
        launch(reset: true)
        openSession("s-reading")
        leaveAndRelaunch()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 5), "the chat is back")
        XCTAssertTrue(waitUntil(timeout: 5) { self.chatTitle().contains("worth reading") }, "the session's chat: \(chatTitle())")
        shot("restore-session-chat")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.collectionViews["sessions.list"].waitForExistence(timeout: 5), "Back returns to Sessions")
        XCTAssertTrue(app.tabBars.buttons["Sessions"].isSelected)
    }

    // MARK: R3. "Reopen last chat on launch" off on the gateway

    @MainActor func testR3_PreferenceOffShowsTheList() throws {
        try account.control("/__restore/config", ["resume": false])
        launch(reset: true)
        Thread.sleep(forTimeInterval: 5)   // the preference is read a moment after the link is ready
        openBot("deploys")
        leaveAndRelaunch()
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tables["chat.table"].waitForExistence(timeout: 3), "no chat reopens with the preference off")
        // Turned on again (absent counts as on): read by the next launch, the launch after it reopens.
        try account.control("/__restore/config", ["resume": NSNull()])
        leaveAndRelaunch()
        Thread.sleep(forTimeInterval: 5)
        openBot("deploys")
        leaveAndRelaunch()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 5), "on again: the chat reopens")
    }

    // MARK: R4. A crash with the chat on screen: the next launch shows the list

    @MainActor func testR4_CrashedChatIsNotReopened() throws {
        launch(reset: true)
        openBot("deploys")
        leaveAndRelaunch()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 5), "reopened")
        goHome()
        app.terminate()
        // This launch reopens the chat and then crashes (`-HQCrashTest`: an exception 6 s in) with it on screen.
        crashExpected = true
        launch(reset: false, arguments: ["-HQCrashTest", "-HQCrashTestDelay", "6"], waitForTabs: false)
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 5), "reopened before the crash")
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "the crash ended the app")
        launch(reset: false)
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tables["chat.table"].waitForExistence(timeout: 3), "the crashed chat is not reopened")
        shot("restore-after-crash")
        // A foreground end counts too (iOS ending the app there).
        openBot("deploys")
        app.terminate()
        launch(reset: false)
        XCTAssertFalse(app.tables["chat.table"].waitForExistence(timeout: 3), "ended in the foreground: not reopened")
    }

    // MARK: R5. A deleted chat and a removed bot go back to their list quietly

    @MainActor func testR5_DeletedChatFallsBackToSessions() throws {
        launch(reset: true)
        openSession("s-reading")
        goHome()
        app.terminate()
        try account.control("/__restore/delete", ["session_id": "s-reading"])
        launch(reset: false, waitForTabs: false)
        // Painted from the cached list it may show for a moment; the gateway's answer closes it.
        XCTAssertTrue(waitUntil(timeout: 20) { self.app.collectionViews["sessions.list"].isHittable && !self.app.tables["chat.table"].exists },
                      "back on Sessions without the deleted chat")
        XCTAssertFalse(app.alerts.firstMatch.exists, "quietly: no alert")
        XCTAssertFalse(app.cells["session-row-s-reading"].exists)
        leaveAndRelaunch()
        XCTAssertFalse(app.tables["chat.table"].waitForExistence(timeout: 3), "and it stays closed")
    }

    @MainActor func testR6_RemovedBotFallsBackToBots() throws {
        launch(reset: true)
        openBot("finance")
        goHome()
        app.terminate()
        try account.control("/__restore/remove-bot", ["profile": "finance"])
        launch(reset: false, waitForTabs: false)
        XCTAssertTrue(waitUntil(timeout: 20) { self.app.collectionViews["bots.list"].isHittable && !self.app.tables["chat.table"].exists },
                      "back on Bots without the removed bot's chat")
        XCTAssertFalse(app.alerts.firstMatch.exists, "quietly: no alert")
    }

    // MARK: Helpers

    @MainActor private func launch(reset: Bool, arguments: [String] = [], waitForTabs: Bool = true) {
        let app = XCUIApplication()
        app.launchArguments = (reset ? ["-HQDebugResetAccounts", "YES"] : []) + arguments
        app.launchEnvironment = ["HQN_SIGNIN_URL": account.url, "HQN_SIGNIN_USERNAME": account.username,
                                 "HQN_SIGNIN_PASSWORD": account.password]
        app.launch()
        self.app = app
        guard waitForTabs else { return }
        XCTAssertTrue(app.tabBars.buttons["Bots"].waitForExistence(timeout: 20), "signed in")
        dismissAlerts()
    }

    /// A launch-time offer (notifications setup) may come; close it.
    @MainActor private func dismissAlerts() {
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 2), alert.buttons["Not Now"].exists { alert.buttons["Not Now"].tap() }
    }

    @MainActor private func goHome() {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.wait(for: .runningBackgroundSuspended, timeout: 5))
    }

    /// To the Home Screen (the screen on show is kept), the process ended, a cold launch.
    @MainActor private func leaveAndRelaunch() {
        goHome()
        app.terminate()
        launch(reset: false, waitForTabs: false)
        XCTAssertTrue(waitUntil(timeout: 20) { self.app.tabBars.buttons["Bots"].exists || self.app.tables["chat.table"].exists },
                      "the app is up")
    }

    @MainActor private func openBot(_ id: String) {
        if !app.collectionViews["bots.list"].isHittable { app.tabBars.buttons["Bots"].tap() }
        let row = app.cells["bot-row-\(id)"].exists ? app.cells["bot-row-\(id)"] : app.cells["bot-tile-\(id)"]
        XCTAssertTrue(waitUntil(timeout: 15) { self.app.cells["bot-row-\(id)"].exists || self.app.cells["bot-tile-\(id)"].exists },
                      "the \(id) bot is listed")
        (row.exists ? row : app.cells["bot-tile-\(id)"]).tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 10), "the chat opens")
        Thread.sleep(forTimeInterval: 1)
    }

    @MainActor private func openSession(_ id: String) {
        app.tabBars.buttons["Sessions"].tap()
        let row = app.cells["session-row-\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the \(id) chat is listed")
        row.tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 10), "the chat opens")
        Thread.sleep(forTimeInterval: 1)
    }

    @MainActor private func chatTitle() -> String {
        let title = app.descendants(matching: .any)["chat.title"]
        return title.exists ? title.label : ""
    }

    @MainActor private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["HQN_SHOTS_DIR"], !dir.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("e2e-\(name).png"))
        }
    }

    @MainActor private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        return condition()
    }
}
