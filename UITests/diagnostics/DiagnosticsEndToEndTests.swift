// Diagnostics-stream end-to-end checks (docs/spec/3x-diagnostics.md §15) against scripts/fixtures/diagnostics-gateway.py:
// the settings fixture with the performance-log routes answered by the real sink code. They share the settings
// suite's helpers (sign-in, Settings, screenshots) and skip when the gateway under test is the plain settings fixture.
// Run with scripts/e2e-diagnostics.sh <SIM_UDID>.

import XCTest
import notify

extension SettingsEndToEndTests {
    /// The diagnostics fixture's record, or a skip when this run's gateway is not that fixture.
    func sinkState() throws -> [String: Any] {
        // The plain settings fixture answers the path too, with nothing in it: only the sink's record names its log folder.
        guard let state = try? a.control("/__diagnostics/state"), state["log_dir"] != nil else {
            throw XCTSkip("Run scripts/e2e-diagnostics.sh (it starts the diagnostics fixture).")
        }
        return state
    }

    @MainActor func openDiagnostics(_ app: XCUIApplication) {
        openSettings(app)
        let about = app.buttons["settings.about"]
        scrollTo(about, app, max: 12)
        about.tap()
        let row = app.buttons["about.diagnostics"]
        XCTAssertTrue(appears(row, app, "about-row", timeout: 5))
        row.tap()
        XCTAssertTrue(appears(app.descendants(matching: .any)["diagnostics.intro"], app, "diagnostics", timeout: 8), "the page opens")
    }

    @MainActor func text(_ app: XCUIApplication, containing part: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", part)).firstMatch
    }

    /// Scrolls the page down until `element` exists (rows of a List are made as they come on screen).
    @MainActor func reach(_ element: XCUIElement, _ app: XCUIApplication, swipes: Int = 14) -> Bool {
        for _ in 0..<swipes where !element.exists { app.swipeUp(velocity: .slow) }
        return element.exists
    }

    /// What the app copied. iOS asks before another app (this test runner) reads it, and the read waits for the
    /// answer: the read runs off the main thread while "Allow Paste" is tapped here.
    @MainActor func clipboard(_ app: XCUIApplication) -> String {
        final class Box: @unchecked Sendable { var text: String? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { box.text = UIPasteboard.general.string; done.signal() }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<20 {
            if done.wait(timeout: .now() + 0.5) == .success { return box.text ?? "" }
            for target in [springboard, app] {
                let allow = target.buttons["Allow Paste"]
                if allow.exists { allow.tap(); break }
            }
        }
        _ = done.wait(timeout: .now() + 5)
        return box.text ?? ""
    }

    private static let plantedTicket = "abc123DEF456ghi789JKL012"
    private static let plantedKey = "sk-live-0123456789abcdef"

    // MARK: - D1 / D5 / D6 / D7: the page, an error folded and redacted, Copy, and what the next launch keeps

    @MainActor func testD1_PageSectionsFoldedRedactedErrorCopyAndTheNextLaunch() throws {
        _ = try sinkState()
        let app = launchSignedIn(["-HQDebugPlantError", "5", "-HQDebugFieldFixture", "week"])
        Thread.sleep(forTimeInterval: 2.5)          // the planted error is logged two seconds after launch
        openDiagnostics(app)
        shot(app, "diagnostics-top")
        XCTAssertTrue(text(app, containing: "Passwords, tokens, cookies").exists, "the page says what is removed")
        for label in ["Version", "Address", "Open connections", "Connection attempts"] {
            XCTAssertTrue(reach(text(app, containing: label), app, swipes: 6), "the \(label) row")
        }
        XCTAssertTrue(text(app, containing: a.hostPort).exists, "the gateway's address without its scheme")
        XCTAssertTrue(reach(text(app, containing: "App ready"), app), "Startup: the time to a usable app")
        XCTAssertTrue(reach(text(app, containing: "Connection handshake"), app), "Startup: the first connection")
        shot(app, "diagnostics-startup")
        XCTAssertTrue(reach(text(app, containing: "Crashes reported by iOS"), app), "Stability, this build")
        XCTAssertTrue(reach(text(app, containing: "Peak memory"), app), "Field metrics: the made-up week's newest summary")
        shot(app, "diagnostics-field")
        XCTAssertTrue(reach(text(app, containing: "Kept daily reports"), app), "the kept days")

        let error = text(app, containing: "x.example/a?[redacted]")
        XCTAssertTrue(reach(error, app, swipes: 20), "the planted error, with its web-address details removed")
        XCTAssertTrue(error.label.contains("Authorization: [redacted]"), error.label)
        XCTAssertTrue(reach(text(app, containing: "×5"), app, swipes: 2), "five repeats fold into one row with a count")
        // One row, not five. A second row is what an earlier launch on this simulator kept, under its own heading.
        let carrying = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "x.example/a?[redacted]")).allElementsBoundByIndex
        let rows = Set(carrying.map { Int($0.frame.minY.rounded()) }).count
        XCTAssertTrue(rows == 1 || (rows == 2 && text(app, containing: "Before the last launch").exists), "one row, not five: \(carrying.map(\.frame))")
        shot(app, "diagnostics-errors")
        for secret in [Self.plantedTicket, Self.plantedKey] {
            XCTAssertFalse(text(app, containing: secret).exists, "nothing on the page shows the planted secret")
        }

        // Copy Diagnostics sits under the intro (UX study 2026-10-21 #114): back up to it.
        let copy = app.buttons["diagnostics.copy"]
        for _ in 0..<20 where !(copy.exists && copy.isHittable) { app.swipeDown(velocity: .slow) }
        XCTAssertTrue(copy.exists)
        scrollTo(copy, app, max: 3)
        XCTAssertEqual(copy.label, "Copy Diagnostics")
        copy.tap()
        XCTAssertTrue(waitUntil(timeout: 1.5) { copy.label == "Copied" }, "the button says Copied")
        shot(app, "diagnostics-copied")
        let started = Date()
        XCTAssertTrue(waitUntil(timeout: 6) { copy.label == "Copy Diagnostics" }, "and is itself again")
        XCTAssertLessThan(Date().timeIntervalSince(started), 4.5, "after about two seconds")
        let copiedText = clipboard(app)
        XCTAssertTrue(copiedText.hasPrefix("Hermes HQ diagnostics\n"), "the report is on the clipboard: \(copiedText.prefix(80))")
        for part in ["\nApp\n", "\nGateway\n", "\nStartup\n", "\nStability, this build\n", "\nField metrics, from iOS\n", "Recent errors (5)",
                     "  POST https://x.example/a?[redacted] Authorization: [redacted]", "[attempts]", "iOS report: "] {
            XCTAssertTrue(copiedText.contains(part), "the copied report has \(part)")
        }
        // (A line that names a header is masked to its end when the report is guarded line by line, as on the web: the
        // count of that one error shows on the page and in "Recent errors (5)".)
        for secret in [Self.plantedTicket, Self.plantedKey, a.password] {
            XCTAssertFalse(copiedText.contains(secret), "the copied report holds no secret")
        }
        XCTAssertFalse(copiedText.contains("Dispatch"))

        // The next launch keeps what the last one logged, under its own heading.
        closeSettings(app)
        Thread.sleep(forTimeInterval: 1.0)
        app.terminate()
        app.launchArguments = ["-HQDebugNoDrag", "YES"]
        app.launch()
        XCTAssertTrue(app.cells["bot-row-ivy"].waitForExistence(timeout: 20), "signed in still")
        openSettings(app)
        if !app.buttons["about.diagnostics"].exists, !app.descendants(matching: .any)["diagnostics.intro"].exists {
            let about = app.buttons["settings.about"]
            scrollTo(about, app, max: 12)
            about.tap()
        }
        if app.buttons["about.diagnostics"].waitForExistence(timeout: 3) { app.buttons["about.diagnostics"].tap() }
        XCTAssertTrue(appears(app.descendants(matching: .any)["diagnostics.intro"], app, "diagnostics-relaunch", timeout: 8))
        XCTAssertTrue(reach(text(app, containing: "Before the last launch"), app, swipes: 20), "the earlier launch's errors have their heading")
        let earlier = text(app, containing: "x.example/a?[redacted]")
        XCTAssertTrue(reach(earlier, app, swipes: 4), "and are still redacted")
        XCTAssertFalse(text(app, containing: Self.plantedTicket).exists)
        shot(app, "diagnostics-earlier")
    }

    // MARK: - L1…L4, M2, P3: the performance log reaches the real sink clean; memory warnings and power changes are in it

    @MainActor func testD2_PerformanceLogReachesTheRealSinkWithMemoryAndPowerEvents() throws {
        let base = (try sinkState()["events"] as? [String: Int]) ?? [:]
        let app = launchSignedIn(["-HQDebugExposeStatus", "YES"])
        let probe = app.descendants(matching: .any)["debug.diag"]
        XCTAssertTrue(probe.waitForExistence(timeout: 8), "the DEBUG probe")
        func value(_ key: String) -> Int {
            let parts = ((probe.value as? String) ?? "").split(separator: " ")
            return parts.first { $0.hasPrefix(key + "=") }.flatMap { Int($0.dropFirst(key.count + 1)) } ?? -1
        }
        XCTAssertTrue(waitUntil(timeout: 5) { value("power") >= 1 }, "the launch's power reading is logged once")
        let powerAtLaunch = value("power")
        XCTAssertEqual(value("saving"), 0)

        // A memory warning runs the trims once.
        let trims = value("trims")
        notify_post("hqn.memory.warn")
        XCTAssertTrue(waitUntil(timeout: 8) { value("trims") == trims + 1 }, "one trim per warning: \(probe.value ?? "")")
        XCTAssertTrue(app.cells["bot-row-ivy"].exists, "the list is still drawn after the trim")

        // The power saver's own switch: one event when it turns on, one when it turns off, none in between.
        notify_post("hqn.power.toggle")
        XCTAssertTrue(waitUntil(timeout: 8) { value("saving") == 1 }, "\(probe.value ?? "")")
        XCTAssertTrue(waitUntil(timeout: 5) { value("power") == powerAtLaunch + 1 })
        notify_post("hqn.power.toggle")
        XCTAssertTrue(waitUntil(timeout: 8) { value("saving") == 0 })
        XCTAssertTrue(waitUntil(timeout: 5) { value("power") == powerAtLaunch + 2 })
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(value("power"), powerAtLaunch + 2, "nothing more is logged while nothing changes")

        // Mark a Janky Moment sends what is waiting straight away.
        openSettings(app)
        let about = app.buttons["settings.about"]
        scrollTo(about, app, max: 12)
        about.tap()
        let perf = app.switches["about.perf-log"]
        XCTAssertTrue(appears(perf, app, "about", timeout: 5))
        if perf.value as? String == "0" { flip(perf) }
        let mark = app.buttons["about.mark"]
        XCTAssertTrue(mark.waitForExistence(timeout: 3))
        mark.tap()

        func events() -> [String: Int] { ((try? self.sinkState())?["events"] as? [String: Int]) ?? [:] }
        XCTAssertTrue(waitUntil(timeout: 25) { (events()["mark"] ?? 0) > (base["mark"] ?? 0) }, "the mark is written on the computer: \(events())")
        let state = try sinkState()
        let written = events()
        XCTAssertGreaterThan(written["upload"] ?? 0, base["upload"] ?? 0, "each upload has the sink's own header line")
        XCTAssertGreaterThanOrEqual((written["mem.trim"] ?? 0) - (base["mem.trim"] ?? 0), 1, "the memory trim is in the log: \(written)")
        XCTAssertGreaterThanOrEqual((written["power"] ?? 0) - (base["power"] ?? 0), 3, "launch, on and off: \(written)")
        let uploads = (state["uploads"] as? [[String: Any]]) ?? []
        XCTAssertFalse(uploads.isEmpty)
        for upload in uploads {
            XCTAssertEqual(upload["status"] as? Int, 200, "\(upload)")
            XCTAssertEqual(upload["dropped"] as? Int, 0, "the sink keeps every line the app sent: \(upload)")
            XCTAssertTrue(((upload["device"] as? String) ?? "").hasPrefix("HQN_"), "\(upload)")
            XCTAssertTrue(((upload["app"] as? String) ?? "").hasPrefix("HQN "), "\(upload)")
        }
        XCTAssertEqual((state["dirty"] as? [Any])?.count, 0, "no written event carries a blocked field or a long string")
        XCTAssertEqual((state["files"] as? [String: Any])?.keys.allSatisfy { $0.hasPrefix("HQN_") && $0.hasSuffix(".jsonl") }, true,
                       "one folder for this phone, one file a day: \(state["files"] ?? "")")
    }

    // MARK: - N1: a number pad has no return key, so it gets a Done bar

    @MainActor func testD3_NumberPadHasDoneAndOtherKeyboardsDoNot() throws {
        _ = try sinkState()
        let app = launchSignedIn()
        openSettings(app)
        let sessions = app.buttons["settings.sessions"]
        scrollTo(sessions, app)
        sessions.tap()
        let archive = app.switches["sessions.auto-archive"]
        XCTAssertTrue(appears(archive, app, "sessions", timeout: 8))
        if archive.value as? String == "0" { flip(archive) }
        let days = app.textFields["sessions.auto-archive-days"]
        XCTAssertTrue(days.waitForExistence(timeout: 5))
        let done = app.buttons["numberpad.done"]
        XCTAssertFalse(done.exists, "no bar before the field is being edited")
        days.tap()
        XCTAssertTrue(appears(done, app, "numberpad", timeout: 5), "Done sits above the number pad")
        XCTAssertEqual(done.label, "Done")
        shot(app, "numberpad-done")
        days.typeText("5")
        done.tap()
        let away = waitUntil(timeout: 10) { !done.exists && app.keyboards.count == 0 }
        if !away { dump(app, "numberpad-stays") }
        XCTAssertTrue(away, "Done puts the number pad away")
        XCTAssertTrue(waitUntil(timeout: 8) { (self.fixtureConfig("sessions.auto_archive_days") as? Int).map { $0 != 30 } ?? false
            || !self.configPatches().isEmpty }, "and saves the number: \(configPatches())")
        shot(app, "numberpad-dismissed")
    }

    // MARK: - S1: a screen that fell back is one row in Recent errors and one `page.crash` in the log

    @MainActor func testD4_ScreenProblemIsOneRowAndOneLogEvent() throws {
        _ = try sinkState()
        let app = launchSignedIn(["-HQDebugScreenFault", "jobs|list did not decode: missing key|JobsViewController,JobRowView"])
        Thread.sleep(forTimeInterval: 4.5)          // reported 3 s after launch and again 1 s later
        openDiagnostics(app)
        let row = text(app, containing: "Screen problem in jobs: list did not decode: missing key · at JobsViewController › JobRowView")
        XCTAssertTrue(reach(row, app, swipes: 20), "the problem is in Recent errors")
        XCTAssertFalse(row.label.contains("×"), "two reports within five seconds are one entry: \(row.label)")
        shot(app, "diagnostics-screen-problem")
        back(app)
        let mark = app.buttons["about.mark"]
        scrollTo(mark, app, max: 6)
        XCTAssertTrue(mark.waitForExistence(timeout: 3))
        mark.tap()
        func events() -> [String: Int] { ((try? self.sinkState())?["events"] as? [String: Int]) ?? [:] }
        // The events on the computer for this problem (the sink keeps `what` as the app sent it, cut to 120 characters).
        func written() -> [String] { (((try? self.sinkState())?["page_crashes"] as? [String]) ?? []).filter { $0.hasPrefix("Screen problem in jobs: list did not decode") } }
        XCTAssertTrue(waitUntil(timeout: 25) { !written().isEmpty }, "\(events())")
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(written().count, 1, "one event on the computer, not two: \(written())")
    }
}
