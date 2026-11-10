// [settings] m9 "settings" stream end to end against the settings fixture (docs/spec/3x-settings.md):
// M9A the Haptics switch mutes the app's cues and is kept across a relaunch (§1), M9B Intro Splash (§7),
// M9C saving power while the app runs (§3). Run with
//   HQN_SETTINGS_PORTS="10060 10061 10062" HQN_E2E_ONLY="testM9A_…" scripts/e2e-settings.sh <SIM>

import XCTest

extension SettingsEndToEndTests {
    /// The DEBUG probe's count of cues that would have played (`-HQDebugHapticsProbe YES`).
    @MainActor func hapticCount(_ app: XCUIApplication) -> Int {
        let probe = app.descendants(matching: .any)["debug.haptics"]
        guard probe.waitForExistence(timeout: 5), let value = probe.value as? String,
              let count = value.split(separator: " ").first?.split(separator: "=").last.flatMap({ Int($0) }) else { return -1 }
        return count
    }

    @MainActor func m9ScrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeUp(velocity: .slow) }
    }

    @MainActor func m9IsOn(_ toggle: XCUIElement) -> Bool { (toggle.value as? String) == "1" }

    /// Flips a switch and waits for it to say so.
    @MainActor func m9Flip(_ toggle: XCUIElement) {
        let before = m9IsOn(toggle)
        flip(toggle)
        _ = waitUntil(timeout: 3) { self.m9IsOn(toggle) != before }
    }

    // MARK: - M9A Haptics switch

    @MainActor func testM9A_HapticsSwitchMutesEveryCueAndIsKept() throws {
        let app = launchSignedIn(["-HQDebugHapticsProbe", "YES"])
        XCTAssertGreaterThanOrEqual(hapticCount(app), 0, "the probe is up")

        // On (default): opening a bot's chat gives its soft tap; a Settings switch of ours gives a selection tick.
        let ivy = app.cells["bot-row-ivy"]
        let start = hapticCount(app)
        ivy.tap()
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 8), "the chat opens")
        XCTAssertTrue(waitUntil(timeout: 3) { self.hapticCount(app) > start }, "opening a chat plays a cue while Haptics is on")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(ivy.waitForExistence(timeout: 5))

        openSettings(app)
        let haptics = app.switches["settings.haptics"]
        m9ScrollTo(haptics, in: app)
        XCTAssertTrue(appears(haptics, app, "m9a-haptics-row"), "Settings shows Haptics")
        XCTAssertTrue(m9IsOn(haptics), "on by default")
        XCTAssertTrue(app.staticTexts["Sounds & Haptics"].exists || app.staticTexts["SOUNDS & HAPTICS"].exists || app.staticTexts["Haptics"].exists)
        shot(app, "m9-settings-haptics-on")

        m9Flip(haptics)
        XCTAssertFalse(m9IsOn(haptics), "turned off")
        shot(app, "m9-settings-haptics-off")
        let muted = hapticCount(app)
        // Our own cues are silent now: the In-App Tips switch's tick, then opening a chat.
        let tips = app.switches["settings.tips"]
        for _ in 0..<4 where !(tips.exists && tips.isHittable) { app.swipeDown(velocity: .slow) }
        m9Flip(tips); m9Flip(tips)
        closeSettings(app)
        XCTAssertTrue(ivy.waitForExistence(timeout: 5))
        ivy.tap()
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(hapticCount(app), muted, "no cue anywhere while Haptics is off")

        // Kept across a relaunch (saved sign-in), and still silent.
        app.terminate()
        app.launchArguments = ["-HQDebugNoDrag", "YES", "-HQDebugHapticsProbe", "YES"] + appearanceArguments
        app.launch()
        if !ivy.waitForExistence(timeout: 20), app.navigationBars.buttons.firstMatch.exists { app.navigationBars.buttons.firstMatch.tap() }
        XCTAssertTrue(ivy.waitForExistence(timeout: 10), "signed in still")
        let relaunched = hapticCount(app)
        ivy.tap()
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(hapticCount(app), relaunched, "still silent after a relaunch")
        app.navigationBars.buttons.firstMatch.tap()
        openSettings(app)
        m9ScrollTo(haptics, in: app)
        XCTAssertFalse(m9IsOn(haptics), "the switch is still off after a relaunch")

        // Back on: cues return.
        m9Flip(haptics)
        XCTAssertTrue(m9IsOn(haptics))
        closeSettings(app)
        let before = hapticCount(app)
        ivy.tap()
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 8))
        XCTAssertTrue(waitUntil(timeout: 3) { self.hapticCount(app) > before }, "cues play again")
    }

    // MARK: - M9B Intro Splash

    @MainActor func testM9B_IntroSplashOffLeavesAnEmptyChatBlank() throws {
        let app = launchSignedIn()
        let notes = app.cells["bot-row-notes"]
        m9ScrollTo(notes, in: app)
        XCTAssertTrue(appears(notes, app, "m9b-notes-row"), "Notes has never been talked to")
        let greeting = app.staticTexts["No messages yet. Say hello."]
        let blank = app.descendants(matching: .any)["chat.intro.off"]

        notes.tap()
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 8), "the chat opens")
        XCTAssertTrue(appears(greeting, app, "m9b-intro-on", timeout: 8), "on by default: the bot's face and greeting")
        XCTAssertFalse(blank.exists)
        shot(app, "m9-intro-splash-on")
        app.navigationBars.buttons.firstMatch.tap()

        openSettings(app)
        let toggle = app.switches["settings.intro-splash"]
        m9ScrollTo(toggle, in: app)
        XCTAssertTrue(appears(toggle, app, "m9b-intro-row"), "Settings › Chat shows Intro Splash")
        XCTAssertTrue(m9IsOn(toggle), "on by default")
        shot(app, "m9-settings-chat-intro-splash")
        m9Flip(toggle)
        XCTAssertFalse(m9IsOn(toggle))
        closeSettings(app)

        m9ScrollTo(notes, in: app)
        notes.tap()
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 8), "the message bar is still there")
        XCTAssertTrue(appears(blank, app, "m9b-intro-off", timeout: 8), "off: the empty chat is blank")
        XCTAssertEqual(blank.label, "No messages yet", "VoiceOver still hears that the chat is empty")
        XCTAssertFalse(greeting.exists, "no greeting")
        XCTAssertFalse(app.buttons["chat.intro.info"].exists, "no intro capsules")
        shot(app, "m9-intro-splash-off")
        app.navigationBars.buttons.firstMatch.tap()

        // Kept across a relaunch, then back on without one.
        app.terminate()
        app.launchArguments = ["-HQDebugNoDrag", "YES"] + appearanceArguments
        app.launch()
        if !notes.waitForExistence(timeout: 20), app.navigationBars.buttons.firstMatch.exists { app.navigationBars.buttons.firstMatch.tap() }
        m9ScrollTo(notes, in: app)
        notes.tap()
        XCTAssertTrue(appears(blank, app, "m9b-intro-off-relaunch", timeout: 10), "still off after a relaunch")
        app.navigationBars.buttons.firstMatch.tap()
        openSettings(app)
        m9ScrollTo(toggle, in: app)
        XCTAssertFalse(m9IsOn(toggle))
        m9Flip(toggle)
        closeSettings(app)
        m9ScrollTo(notes, in: app)
        notes.tap()
        XCTAssertTrue(appears(greeting, app, "m9b-intro-back", timeout: 8), "on again: the intro is back")
    }

    // MARK: - M9C Saving power while the app runs

    /// Low Power Mode cannot be switched in the Simulator: the DEBUG build flips its own reading on the Darwin
    /// notification `hqn.power.toggle` (the same one `xcrun simctl spawn <UDID> notifyutil -p hqn.power.toggle` posts).
    @MainActor func testM9C_SavingPowerStillsDecorationAndLetsItMoveAgain() throws {
        let app = launchSignedIn(["-HQDebugExposeStatus", "YES", "-HQDebugPowerSaving", "NO"])
        let power = app.descendants(matching: .any)["debug.power"]
        XCTAssertTrue(appears(power, app, "m9c-power", timeout: 8), "the probe is up")
        XCTAssertEqual(power.value as? String, "normal moving", "heads and skeletons may move")
        func toggle() {
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 CFNotificationName("hqn.power.toggle" as CFString), nil, nil, true)
        }
        toggle()
        XCTAssertTrue(waitUntil(timeout: 5) { (power.value as? String) == "saving still" }, "saving power holds them still: \(String(describing: power.value))")
        shot(app, "m9-power-saving-bots")
        // The app still works as before: a chat opens and Settings shows no switch for it (the web has none).
        app.cells["bot-row-ivy"].tap()
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 8))
        app.navigationBars.buttons.firstMatch.tap()
        toggle()
        XCTAssertTrue(waitUntil(timeout: 5) { (power.value as? String) == "normal moving" }, "and they move again when saving ends, without a relaunch")
        // Twenty flips in a burst settle in the state of the last one (stress I5).
        for _ in 0..<21 { toggle() }
        XCTAssertTrue(waitUntil(timeout: 5) { (power.value as? String) == "saving still" })
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(power.value as? String, "saving still")
        XCTAssertTrue(app.cells["bot-row-ivy"].isHittable, "the list is still live")
    }

    // MARK: - M9D Largest Attachment

    @MainActor func testM9D_LargestAttachmentStepsIsKeptAndReturnsToDefault() throws {
        let app = launchSignedIn()
        openSettings(app)
        let row = app.buttons["settings.attachment-limit"]
        m9ScrollTo(row, in: app)
        XCTAssertTrue(appears(row, app, "m9d-row"), "Settings › Chat shows Largest Attachment")
        XCTAssertTrue(row.label.contains("100 MB"), "100 MB by default: \(row.label)")
        shot(app, "m9-settings-largest-attachment-row")
        row.tap()
        let value = app.staticTexts["attachment-limit.value"]
        XCTAssertTrue(appears(value, app, "m9d-page"), "the page opens")
        XCTAssertEqual(value.label, "100 MB")
        XCTAssertFalse(app.buttons["attachment-limit.default"].exists, "no Use Default at the default")
        let down = app.buttons["attachment-limit.stepper-Decrement"], up = app.buttons["attachment-limit.stepper-Increment"]
        XCTAssertTrue(appears(down, app, "m9d-stepper", timeout: 3))
        XCTAssertFalse(up.isEnabled, "100 is the most")
        for _ in 0..<3 { down.tap() }
        XCTAssertTrue(waitUntil(timeout: 3) { value.label == "97 MB" }, "three steps down: \(value.label)")
        XCTAssertTrue(app.buttons["attachment-limit.default"].waitForExistence(timeout: 3), "Use Default shows once it is not 100")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'attaches or previews, in MB. Up to 100, which is the default.'")).firstMatch.exists, "the web's sentence")
        shot(app, "m9-largest-attachment-page")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 3) { row.label.contains("97 MB") }, "the row follows: \(row.label)")

        app.terminate()
        app.launchArguments = ["-HQDebugNoDrag", "YES"] + appearanceArguments
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["More"].waitForExistence(timeout: 20))
        if !app.tabBars.buttons["More"].isHittable, app.navigationBars.buttons.firstMatch.exists { app.navigationBars.buttons.firstMatch.tap() }
        openSettings(app)
        m9ScrollTo(row, in: app)
        XCTAssertTrue(row.label.contains("97 MB"), "kept across a relaunch: \(row.label)")
        row.tap()
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        // Down to the floor: the stepper cannot go under 1.
        for _ in 0..<100 where down.isEnabled { down.tap() }
        XCTAssertTrue(waitUntil(timeout: 3) { value.label == "1 MB" }, "1 is the least: \(value.label)")
        XCTAssertFalse(down.isEnabled)
        app.buttons["attachment-limit.default"].tap()
        XCTAssertTrue(waitUntil(timeout: 3) { value.label == "100 MB" }, "Use Default returns to 100")
        XCTAssertTrue(waitUntil(timeout: 3) { !app.buttons["attachment-limit.default"].exists }, "and hides itself")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { row.exists && row.label.contains("100 MB") })
    }

    // MARK: - M9E File Browser

    @MainActor func testM9E_FileBrowserPutsFilesInTheChatBarOnlyWhereThereIsAFolder() throws {
        // Research's chats have no project folder; Ivy's are in /fixture.
        try a.control("/__settings/cwd", ["profile": "research", "cwd": NSNull()])
        let app = launchSignedIn()
        let ivy = app.cells["bot-row-ivy"], research = app.cells["bot-row-research"]
        let files = app.buttons["chat.files"], more = app.buttons["chat.more"]

        // Off (default): no button; Files is still under ⋯ › More.
        ivy.tap()
        XCTAssertTrue(appears(more, app, "m9e-chat", timeout: 10), "the chat's ⋯")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(files.exists, "off: no Files button in the bar")
        app.navigationBars.buttons.firstMatch.tap()

        openSettings(app)
        let toggle = app.switches["settings.file-browser"]
        m9ScrollTo(toggle, in: app)
        XCTAssertTrue(appears(toggle, app, "m9e-row"), "Settings › Chat shows File Browser")
        XCTAssertFalse(m9IsOn(toggle), "off by default")
        m9Flip(toggle)
        XCTAssertTrue(m9IsOn(toggle))
        shot(app, "m9-settings-file-browser-on")
        closeSettings(app)

        // On, a chat with a folder: the button, and it opens Files at that folder.
        ivy.tap()
        XCTAssertTrue(appears(files, app, "m9e-files-button", timeout: 10), "on: Files sits in the chat's bar")
        XCTAssertEqual(files.label, "Files")
        XCTAssertTrue(more.exists, "beside the ⋯, which stays")
        shot(app, "m9-chat-files-button")
        files.tap()
        let list = app.tables["workspace.files"]
        XCTAssertTrue(appears(list, app, "m9e-files-sheet", timeout: 8), "the Files sheet")
        XCTAssertTrue(app.staticTexts["README.md"].waitForExistence(timeout: 8), "lists the chat's folder")
        XCTAssertTrue(app.staticTexts["src"].exists)
        shot(app, "m9-chat-files-sheet")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !list.exists }, "the sheet closes")
        app.navigationBars.buttons.firstMatch.tap()

        // On, a chat without a folder: never a dead button.
        XCTAssertTrue(research.waitForExistence(timeout: 5))
        research.tap()
        XCTAssertTrue(appears(more, app, "m9e-research", timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(files.exists, "no folder, no button")
        shot(app, "m9-chat-no-folder")
        app.navigationBars.buttons.firstMatch.tap()

        // Kept across a relaunch.
        app.terminate()
        app.launchArguments = ["-HQDebugNoDrag", "YES"] + appearanceArguments
        app.launch()
        if !ivy.waitForExistence(timeout: 20), app.navigationBars.buttons.firstMatch.exists { app.navigationBars.buttons.firstMatch.tap() }
        XCTAssertTrue(ivy.waitForExistence(timeout: 10))
        ivy.tap()
        XCTAssertTrue(appears(files, app, "m9e-files-relaunch", timeout: 10), "still on after a relaunch")
        app.navigationBars.buttons.firstMatch.tap()
        openSettings(app)
        m9ScrollTo(toggle, in: app)
        m9Flip(toggle)
        closeSettings(app)
        ivy.tap()
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(files.exists, "off again: the button is gone")
    }

    // MARK: - M9F Default Project Folder

    /// New chats the fixture was asked to make, oldest first: [profile, cwd or "", cwd_explicit].
    @MainActor func m9Created() -> [[String]] {
        a.writes("session.create").map { [($0["profile"] as? String) ?? "", ($0["cwd"] as? String) ?? "", ($0["cwd_explicit"] as? Bool).map { $0 ? "true" : "false" } ?? ""] }
    }

    /// Sessions › compose; picks the bot when the chooser shows; waits for the chat's composer.
    @MainActor func m9NewSessionChat(_ app: XCUIApplication, bot: String = "ivy") {
        app.tabBars.buttons["Sessions"].tap()
        let compose = app.buttons["sessions.compose"]
        XCTAssertTrue(compose.waitForExistence(timeout: 10), "Sessions compose")
        compose.tap()
        let choice = app.buttons["choose-bot-\(bot)"]
        if choice.waitForExistence(timeout: 4) { choice.tap() }
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 12), "the new chat opens")
        app.navigationBars.buttons.firstMatch.tap()
    }

    @MainActor func testM9F_DefaultProjectFolderIsCheckedKeptAndSentWithNewChats() throws {
        try a.control("/__settings/fs", ["missing": []])
        let app = launchSignedIn()
        // Nothing set: a new chat carries no folder, and no null keys.
        m9NewSessionChat(app)
        XCTAssertEqual(m9Created().last?[1], "", "no folder set: no cwd on session.create: \(m9Created())")
        XCTAssertEqual(m9Created().last?[2], "")

        openSettings(app)
        let sessions = app.buttons["settings.sessions"]
        scrollTo(sessions, app)
        sessions.tap()
        let value = app.staticTexts["sessions.default-folder"]
        XCTAssertTrue(appears(value, app, "m9f-row", timeout: 8), "Sessions shows Default Project Folder")
        XCTAssertEqual(value.label, "Not Set")
        value.tap()
        let field = app.textFields["sessions.default-folder.field"]
        XCTAssertTrue(appears(field, app, "m9f-page"), "the page opens")
        let save = app.buttons["sessions.default-folder.save"]
        XCTAssertFalse(save.isEnabled, "Save waits for a path")

        // A folder the gateway does not have: said so, nothing kept.
        field.tap(); field.typeText("/nope")
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let problem = app.staticTexts["sessions.default-folder.problem"]
        XCTAssertTrue(appears(problem, app, "m9f-problem", timeout: 8))
        XCTAssertEqual(problem.label, "Couldn’t open the folder.")
        shot(app, "m9-default-folder-problem")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertEqual(value.label, "Not Set", "nothing stored")
        value.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.clearAndType("/Users/fixture/Projects/app")
        save.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { value.exists && value.label == "/Users/fixture/Projects/app" }, "the row shows the folder: \(value.label)")
        shot(app, "m9-default-folder-set")
        closeSettings(app)

        // New chats carry it.
        m9NewSessionChat(app)
        XCTAssertEqual(m9Created().last?[1], "/Users/fixture/Projects/app", "\(m9Created())")
        XCTAssertEqual(m9Created().last?[2], "true")

        // The folder vanishes: the chat still starts, without it.
        try a.control("/__settings/fs", ["missing": ["/Users/fixture/Projects/app"]])
        let before = m9Created().count
        m9NewSessionChat(app)
        XCTAssertEqual(m9Created().count, before + 2, "the refused try with the folder, then the retry: \(m9Created())")
        XCTAssertEqual(m9Created().dropLast().last?[1], "/Users/fixture/Projects/app")
        XCTAssertEqual(m9Created().last?[1], "", "retried without the folder")
        try a.control("/__settings/fs", ["missing": []])

        // Kept across a relaunch; Clear removes it.
        app.terminate()
        app.launchArguments = ["-HQDebugNoDrag", "YES"] + appearanceArguments
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["More"].waitForExistence(timeout: 20))
        openSettings(app)
        scrollTo(sessions, app)
        sessions.tap()
        XCTAssertTrue(value.waitForExistence(timeout: 8))
        XCTAssertEqual(value.label, "/Users/fixture/Projects/app", "kept across a relaunch")
        value.tap()
        let clear = app.buttons["sessions.default-folder.clear"]
        XCTAssertTrue(appears(clear, app, "m9f-clear"))
        clear.tap()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { value.label == "Not Set" })
    }
}
