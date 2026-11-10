// [live] A job run from Jobs on the Lock Screen and in the Dynamic Island (a Live Activity), and its link, end to end
// against the pages fixture. The app's "debug.live" probe (`-HQDebugLiveProbe YES`) says what is on show. Two builds:
//   HQ_ORIGINAL=YES TEST_RUNNER_HQN_LIVE=1 HQN_PAGES_ONLY="testJob13_…" scripts/e2e-pages.sh <SIM>   the widget extension is in
//   HQN_PAGES_ONLY="testJob13_…" scripts/e2e-pages.sh <SIM>                                       a shipping-like (native identity) build
// The widget extension is HermesHQTalkActivity — the same one Talk's own Live Activity already ships in — so the
// original identity is what carries it now, not a separate HQ_LIVE_ACTIVITY flag.
// Screens: e2e-live-job-lock.png, e2e-live-job-island.png (HQN_SHOTS_DIR; LiveGlance, SettingsEndToEndTests+Live.swift).

import XCTest

extension PagesTests {
    var liveBuild: Bool { ProcessInfo.processInfo.environment["HQN_LIVE"] == "1" }

    /// Run Now: Running from the tap (so locking the phone straight after works), on the Lock Screen while the app is away,
    /// and Done once the run's Jobs read comes.
    @MainActor func testJob13_RunNowShowsOnTheLockScreen() throws {
        // The run answers after 12 s: time to leave the app while it is out.
        try account.control("/__fixture/fail", ["method": "POST", "path": "/api/cron/jobs/j-triage/trigger", "delay": 12])
        app = launchSignedIn(["-HQDebugLiveProbe", "YES", "-HQDebugLiveReset", "YES"])
        tab("Jobs")
        let row = jobRow("inbox|j-triage")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        holdMenu(of: row)
        app.buttons["Run Now"].firstMatch.tap()
        let alert = app.alerts["Run “Morning inbox triage” Now?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["Run"].tap()
        let probe = app.descendants(matching: .any)["debug.live"]
        if liveBuild {
            XCTAssertTrue(waitUntil(5) { (probe.value as? String) == "job:inbox|j-triage=running" },
                          "Running from the tap (\(probe.exists ? "\(probe.value ?? "-")" : "no probe"))")
        } else {
            Thread.sleep(forTimeInterval: 1)
            XCTAssertTrue(!probe.exists || (probe.value as? String) == "none", "nothing starts without the extension")
        }
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(XCUIApplication(bundleIdentifier: "com.apple.springboard").wait(for: .runningForeground, timeout: 5))
        Thread.sleep(forTimeInterval: 2)
        LiveGlance.look(lock: { shot(liveBuild ? "live-job-lock" : "live-job-lock-absent") },
                        island: { shot(liveBuild ? "live-job-island" : "live-job-island-absent") })
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        guard liveBuild else { return }
        XCTAssertTrue(waitUntil(40) { probe.label == "job:inbox|j-triage=done" && (probe.value as? String) == "none" },
                      "Done once the run's read comes (\(probe.value ?? "-"), \(probe.label))")
    }

    /// A run that never begins (the gateway says it is already running) takes its Running away at once.
    @MainActor func testJob13b_ARunThatNeverBeganGoesAtOnce() throws {
        try XCTSkipUnless(liveBuild, "the probe only lists activities in a build with the extension (testJob13 covers the other)")
        try account.control("/__fixture/fail", ["method": "POST", "path": "/api/cron/jobs/j-triage/trigger", "status": 409,
                                                "detail": "Job is already running", "count": 1])
        app = launchSignedIn(["-HQDebugLiveProbe", "YES", "-HQDebugLiveReset", "YES"])
        tab("Jobs")
        let row = jobRow("inbox|j-triage")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        holdMenu(of: row)
        app.buttons["Run Now"].firstMatch.tap()
        app.alerts["Run “Morning inbox triage” Now?"].buttons["Run"].tap()
        let probe = app.descendants(matching: .any)["debug.live"]
        XCTAssertTrue(waitUntil(10) { probe.label == "job:inbox|j-triage=removed" && (probe.value as? String) == "none" },
                      "taken away, not Failed (\(probe.value ?? "-"), \(probe.label))")
        let ok = app.alerts.buttons["OK"].firstMatch
        if ok.waitForExistence(timeout: 3) { ok.tap() }
    }

    /// The Live Activity's link, `<scheme>://job/<owner|id>`, opens Jobs on that job's page (from another tab too).
    @MainActor func testJob14_JobLinkOpensItsPage() throws {
        app = launchSignedIn()
        tab("Jobs")
        XCTAssertTrue(jobRow("inbox|j-triage").waitForExistence(timeout: 10), "the list has the job")
        tab("Bots")
        let scheme = ProcessInfo.processInfo.environment["HQN_URL_SCHEME"].flatMap { $0.isEmpty ? nil : $0 } ?? "hermeshq-native"
        // The system opens it (as tapping the Lock Screen does); `app.open` would relaunch the app with its launch arguments.
        XCUIDevice.shared.system.open(URL(string: "\(scheme)://job/inbox%7Cj-triage")!)
        // iOS may ask first ("Open in “Hermes HQ”?").
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if open.waitForExistence(timeout: 3) { open.tap() }
        XCTAssertTrue(app.staticTexts["job.title"].waitForExistence(timeout: 10), "the job's page opens")
        XCTAssertEqual(app.staticTexts["job.title"].label, "Morning inbox triage")
        XCTAssertTrue(app.tabBars.buttons["Jobs"].isSelected, "on the Jobs tab")
        shot("live-job-link")
        back()
    }
}
