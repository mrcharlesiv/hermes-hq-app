// End-to-end tests of the Jobs, Kanban and Artifacts pages (docs/spec/1x-pages.md §10.2) against the stateful pages
// fixture (scripts/pages-fixture-gateway.py). Run with scripts/e2e-pages.sh: it starts the fixture on
// ${HQN_PAGES_PORT:-9735}, passes its credentials as TEST_RUNNER_HQN_UI_CREDENTIALS and stops it afterwards. Each test
// resets the fixture first (`/__fixture/reset`) and reads its request log (`/__fixture/state`) to check what was sent.
// TEST_RUNNER_HQN_SHOTS_DIR: screenshots of each screen are written there as PNGs too.

import CryptoKit
import XCTest

final class PagesTests: XCTestCase {
    var account: FixtureAccount!
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        account = try FixtureAccount.load()
        try account.control("/__fixture/reset", [:])
    }

    // MARK: Navigation

    /// P-NAV-1: Bots, Sessions, Jobs, Kanban, More; More › Workspace › Artifacts.
    @MainActor func testNav1_TabsReadInTheWebsOrder() throws {
        app = launchSignedIn()
        let labels = app.tabBars.buttons.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(waitUntil(10) { self.app.tabBars.buttons["Kanban"].exists }, "Kanban takes tab 3 (\(labels))")
        XCTAssertEqual(app.tabBars.buttons.allElementsBoundByIndex.map(\.label), ["Bots", "Sessions", "Jobs", "Kanban", "More"])
        tab("More")
        XCTAssertTrue(app.cells["more-row-artifacts"].waitForExistence(timeout: 5), "Artifacts is a More › Workspace row")
        shot("more")
    }

    /// P-NAV-2: More keeps its own stack; the tab bar stays; Back goes to More's root.
    @MainActor func testNav2_MoreKeepsItsOwnStack() throws {
        app = launchSignedIn()
        tab("More")
        app.cells["more-row-artifacts"].tap()
        XCTAssertTrue(app.collectionViews["artifacts.list"].waitForExistence(timeout: 5))
        tab("Bots")
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 5))
        tab("More")
        XCTAssertTrue(app.collectionViews["artifacts.list"].waitForExistence(timeout: 5), "More is as it was left")
        XCTAssertTrue(app.tabBars.firstMatch.isHittable, "the tab bar shows")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.cells["more-row-artifacts"].waitForExistence(timeout: 5), "Back goes to More's root")
    }

    /// P-NAV-3: a relaunch reopens the tab left (Kanban, then Jobs).
    @MainActor func testNav3_RelaunchReopensTheLastTab() throws {
        app = launchSignedIn()
        tab("Kanban")
        XCTAssertTrue(app.collectionViews["kanban.list"].waitForExistence(timeout: 5))
        app.terminate()
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.collectionViews["kanban.list"].waitForExistence(timeout: 15), "the app opens on Kanban")
        tab("Jobs")
        XCTAssertTrue(app.collectionViews["jobs.list"].waitForExistence(timeout: 5))
        app.terminate()
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.collectionViews["jobs.list"].waitForExistence(timeout: 15), "the app opens on Jobs")
        tab("Bots")
    }

    /// P-NAV-5: the large titles of Bots, Jobs, Kanban and Artifacts sit at one y (±1 pt).
    @MainActor func testNav5_TitlesShareOneY() throws {
        app = launchSignedIn()
        var heights: [String: CGFloat] = [:]
        func titleY(_ title: String) -> CGFloat {
            let text = app.navigationBars.staticTexts[title].firstMatch
            XCTAssertTrue(text.waitForExistence(timeout: 5), "\(title) title")
            heights[title] = text.frame.height
            return text.frame.midY
        }
        tab("Bots"); let bots = titleY("Bots")
        tab("Jobs"); let jobs = titleY("Jobs")
        tab("Kanban"); let kanban = titleY("Kanban")
        tab("More"); let more = titleY("More")
        // The tab roots' titles are one size too (verify round 1: a midY check alone passed a smaller title).
        for title in ["Jobs", "Kanban", "More"] {
            XCTAssertEqual(heights[title] ?? 0, heights["Bots"] ?? 0, accuracy: 1, "\(title)'s title is the size of Bots'")
        }
        app.cells["more-row-artifacts"].tap()
        XCTAssertTrue(app.collectionViews["artifacts.list"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.8)
        let artifacts = titleY("Artifacts")
        measured("title y: Bots \(bots), Jobs \(jobs), Kanban \(kanban), More \(more), Artifacts \(artifacts)")
        XCTAssertEqual(jobs, bots, accuracy: 1)
        XCTAssertEqual(kanban, bots, accuracy: 1)
        XCTAssertEqual(more, bots, accuracy: 1)
        XCTAssertEqual(artifacts, bots, accuracy: 1, "a page pushed in More keeps the tab roots' title row")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tab("Bots")
    }

    // MARK: Jobs

    /// P-JOB-1: a relaunch paints Jobs from its cache: the rows are there while the gateway's list is still on its way.
    @MainActor func testJob1_RelaunchPaintsFromCache() throws {
        app = launchSignedIn()
        tab("Jobs")
        XCTAssertTrue(jobRow("inbox|j-triage").waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1.5)   // the cache write lands
        app.terminate()
        // Every list read of the next launch answers after 6 s (one delay per read: open, gateway.ready, foreground).
        for _ in 0..<3 { try account.control("/__fixture/fail", ["method": "GET", "path": "/api/cron/jobs", "delay": 6]) }
        app = XCUIApplication()
        app.launch()
        let started = Date()
        XCTAssertTrue(app.collectionViews["jobs.list"].waitForExistence(timeout: 10), "the app opens on Jobs")
        XCTAssertTrue(jobRow("inbox|j-triage").waitForExistence(timeout: 1), "rows in the first frames, from the cache")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "before any list read could answer")
        shot("jobs-relaunch-cache")
        tab("Bots")
    }

    /// P-JOB-3: j-watch's "Next in N min" moves on with the minute clock (up to two ticks: the count is rounded).
    @MainActor func testJob3_MinuteTickMovesTheCountdown() throws {
        app = launchSignedIn()
        tab("Jobs")
        let row = jobRow("deploys|j-watch")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        // j-watch is seeded with a run the scheduler started (as Hermes says it: no "running" state, a running latest
        // attempt), and a running row drops its next-run words (UX study 2026-10-19: the lead says "Running"). The run
        // ends (the fixture's cron.changed re-reads) with its next run still T0+12 min, so the row counts down.
        XCTAssertTrue(text("Running · ", in: row).waitForExistence(timeout: 5), "j-watch is running")
        try account.control("/__fixture/finish", ["job_id": "j-watch"])
        let words = text("Next in ", in: row)
        XCTAssertTrue(words.waitForExistence(timeout: 10), "j-watch counts minutes once its run ends (\(row.label))")
        let before = words.label
        // The count is rounded (as the web's): a whole-minute tick can land on the same number once, so allow two ticks.
        XCTAssertTrue(waitUntil(128) { let now = self.text("Next in ", in: row); return now.exists && now.label != before },
                      "the countdown moved (\(before) → \(text("Next in ", in: row).label))")
    }

    /// A Bot Chat job's run ends when it hands its output over; the row says Running until the bot is done with it
    /// (owner 2026-10-25: "When a job is running, the bot is doing it, right?"; hermes-hq-push 0.9.2's cron/working).
    @MainActor func testJob12_RunningUntilTheBotIsDone() throws {
        app = launchSignedIn()
        tab("Jobs")
        let row = jobRow("deploys|j-watch")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(text("Running · ", in: row).waitForExistence(timeout: 5), "j-watch is running")
        let working = { self.requests().filter { $0.method == "GET" && $0.path == "/api/plugins/hermes-hq-push/cron/working" }.count }
        let asked = working()
        XCTAssertGreaterThan(asked, 0, "the list read asks the add-on too")
        try account.control("/__fixture/finish", ["job_id": "j-watch", "bot": "claimed"])
        XCTAssertTrue(waitUntil(10) { working() > asked }, "the run's end re-read the list and the add-on")
        // Without a bot on it the row says "Next in" within a second or so of that read (testJob3).
        XCTAssertFalse(waitUntil(4) { self.text("Next in ", in: row).exists }, "still Running while the bot works (\(row.label))")
        XCTAssertTrue(text("Running · ", in: row).exists, "the row says Running (\(row.label))")
        try account.control("/__fixture/bot-done", ["job_id": "j-watch"])
        XCTAssertTrue(text("Next in ", in: row).waitForExistence(timeout: 10), "Running ends when the bot is done (\(row.label))")
    }

    /// The Jobs tab's clock turns while a job runs or a bot works on its output, with Jobs never opened (owner
    /// 2026-10-30: "some indicator on the Jobs page icon in the bottom nav to show that jobs are currently running").
    @MainActor func testJob13_TabSpinnerWhileJobsRun() throws {
        app = launchSignedIn()
        tab("Bots")   // a cold launch reopens the last tab; the dot has to keep up with Jobs off screen
        let jobsTab = app.tabBars.buttons["Jobs"]
        XCTAssertTrue(jobsTab.waitForExistence(timeout: 10))
        let value = { (jobsTab.value as? String) ?? "" }
        XCTAssertTrue(waitUntil(10) { value().contains("1 running") }, "j-watch's run starts the spinner (value \(value()))")
        shot("jobs-tab-spinner-on")
        XCTAssertTrue(turning(jobsTab), "the ring turns")
        // It keeps turning for the whole run (owner 2026-10-30): over time, after the app was away, on Jobs and off it.
        Thread.sleep(forTimeInterval: 6)
        XCTAssertTrue(turning(jobsTab), "still turning after a while")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        XCTAssertTrue(jobsTab.waitForExistence(timeout: 5))
        XCTAssertTrue(turning(jobsTab), "turning again after the app came back")
        tab("Jobs")
        XCTAssertTrue(turning(jobsTab), "turning while Jobs is the tab on show")
        shot("jobs-tab-spinner-selected")
        tab("Bots")
        XCTAssertTrue(turning(jobsTab), "turning after leaving Jobs")
        try account.control("/__fixture/finish", ["job_id": "j-watch", "bot": "claimed"])
        XCTAssertFalse(waitUntil(4) { !value().contains("running") }, "on while the bot works (value \(value()))")
        try account.control("/__fixture/bot-done", ["job_id": "j-watch"])
        XCTAssertTrue(waitUntil(45) { !value().contains("running") }, "off once the bot is done (value \(value()))")
        XCTAssertFalse(turning(jobsTab), "the clock is back and still")
        shot("jobs-tab-spinner-off")
    }

    /// The same in the Desktop Look, whose docked bar draws the icons itself.
    @MainActor func testJob14_TabSpinnerInDesktopLook() throws {
        app = launchSignedIn()
        app.terminate()
        app.launchArguments = ["-HQPagesHUDSeconds", "6", "-HQDebugDesktopLook", "YES"]   // not the first launch's reset
        app.launch()
        // The look is saved: put it back for the tests after this one (they look for the system tab bar).
        addTeardownBlock { @MainActor in
            let app = XCUIApplication()
            app.launchArguments = ["-HQDebugDesktopLook", "NO"]
            app.launch()
            app.terminate()
        }
        let jobsTab = app.buttons["tab-jobs"].firstMatch
        XCTAssertTrue(jobsTab.waitForExistence(timeout: 10))
        let value = { (jobsTab.value as? String) ?? "" }
        XCTAssertTrue(waitUntil(10) { value().contains("1 running") }, "j-watch's run starts the spinner (value \(value()))")
        shot("jobs-tab-spinner-desktop-on")
        XCTAssertTrue(turning(jobsTab), "the ring turns")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        XCTAssertTrue(jobsTab.waitForExistence(timeout: 5))
        XCTAssertTrue(turning(jobsTab), "turning again after the app came back")
        jobsTab.tap()
        XCTAssertTrue(turning(jobsTab), "turning while Jobs is the tab on show")
        shot("jobs-tab-spinner-desktop-selected")
        app.buttons["tab-bots"].firstMatch.tap()
        try account.control("/__fixture/finish", ["job_id": "j-watch"])
        XCTAssertTrue(waitUntil(45) { !value().contains("running") }, "off once the run ends (value \(value()))")
        XCTAssertFalse(turning(jobsTab), "the clock is back and still")
        shot("jobs-tab-spinner-desktop-off")
    }

    /// P-JOB-2 / P-JOB-3: sections in the web's order, Completed folded (search opens it), the row words.
    @MainActor func testJob2_SectionsWordsAndCompleted() throws {
        app = launchSignedIn()
        tab("Jobs")
        let list = app.collectionViews["jobs.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        XCTAssertTrue(jobRow("research|j-fail").waitForExistence(timeout: 10), "the jobs load")
        let headers = ["Needs Attention", "Running", "Scheduled", "Paused"].map { list.otherElements["jobs.section.\($0)"].firstMatch }
        let ys = headers.map { $0.exists ? $0.frame.minY : -1 }
        XCTAssertEqual(ys, ys.sorted(), "sections in order (\(ys))")
        XCTAssertTrue(text("Last run failed · ", in: jobRow("research|j-fail")).exists, "j-fail says its last run failed")
        XCTAssertTrue(text("Overdue", in: jobRow("research|j-late")).exists, "j-late is overdue")
        XCTAssertTrue(text("Running", in: jobRow("deploys|j-watch")).exists, "j-watch is running")
        XCTAssertFalse(text("Next in ", in: jobRow("deploys|j-watch")).exists, "a running row drops its next-run words")
        shot("jobs-list")
        list.swipeUp()
        let fold = app.cells["jobs.show-completed"]
        XCTAssertTrue(fold.waitForExistence(timeout: 3))
        XCTAssertTrue(text("Show 1 Completed", in: fold).exists || fold.label.contains("Show 1 Completed"), "Completed is folded")
        let search = app.navigationBars.buttons["Search"].firstMatch
        if search.exists { search.tap() }
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("backup")
        XCTAssertTrue(jobRow("default|j-done").waitForExistence(timeout: 3), "searching opens Completed")
        shot("jobs-search")
    }

    /// P-JOB-4: Run Now asks first; Cancel sends nothing; Run reads the job then triggers it on its owner.
    @MainActor func testJob4_RunNowAsksThenRuns() throws {
        app = launchSignedIn()
        tab("Jobs")
        let row = jobRow("inbox|j-triage")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        holdMenu(of: row)
        app.buttons["Run Now"].firstMatch.tap()
        let alert = app.alerts["Run “Morning inbox triage” Now?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertTrue(alert.staticTexts["It delivers to Alex Rivera on Telegram. Its schedule does not change."].exists)
        shot("job-run-alert")
        alert.buttons["Cancel"].tap()
        Thread.sleep(forTimeInterval: 1)
        // [offline] The app's own diagnostic log upload (LogUploader) is not a write the person asked for.
        XCTAssertFalse(userWrites().contains { $0.method == "POST" }, "Cancel sends nothing: \(userWrites().map { $0.method + " " + $0.path })")
        holdMenu(of: row)
        app.buttons["Run Now"].firstMatch.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["Run"].tap()
        let hud = app.descendants(matching: .any)["pages.hud"]
        XCTAssertTrue(waitUntil(15) { hud.exists && hud.label == "Run Started" }, "Run Started shows")
        let sent = requests().filter { $0.path.hasPrefix("/api/cron/jobs/j-triage") }.map { "\($0.method) \($0.path) \($0.query["profile"] ?? "")" }
        XCTAssertEqual(Array(sent.prefix(2)), ["GET /api/cron/jobs/j-triage inbox", "POST /api/cron/jobs/j-triage/trigger inbox"])
    }

    /// P-JOB-4 (left page): Run Now from a job's page, then Back before the run ends: "Run Started" still shows (the
    /// result goes to the tab bar controller, not the page that was left).
    @MainActor func testJob4_RunResultShowsAfterLeavingTheJob() throws {
        app = launchSignedIn()
        tab("Jobs")
        let row = jobRow("inbox|j-triage")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.staticTexts["job.title"].waitForExistence(timeout: 5))
        let run = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Run Now")).firstMatch
        XCTAssertTrue(run.waitForExistence(timeout: 3))
        run.tap()
        let alert = app.alerts["Run “Morning inbox triage” Now?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["Run"].tap()
        back()
        XCTAssertTrue(app.collectionViews["jobs.list"].waitForExistence(timeout: 5), "back on the list while the run goes on")
        let hud = app.descendants(matching: .any)["pages.hud"]
        XCTAssertTrue(waitUntil(15) { hud.exists && hud.label == "Run Started" }, "the result shows on the page the user went to")
        shot("job-run-started-after-back")
    }

    /// P-JOB-5: Run Now on a paused job pauses it again (on activation, and once more at the end).
    @MainActor func testJob5_PausedJobIsPausedAgain() throws {
        app = launchSignedIn()
        tab("Jobs")
        let row = jobRow("finance|j-paused")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        holdMenu(of: row)
        app.buttons["Run Now"].firstMatch.tap()
        app.alerts.firstMatch.buttons["Run"].tap()
        XCTAssertTrue(waitUntil(20) { self.requests().filter { $0.method == "POST" && $0.path.hasSuffix("j-paused/pause") }.count >= 2 },
                      "paused again on activation and at the end")
        let calls = requests().filter { $0.path.hasPrefix("/api/cron/jobs/j-paused") }.map { "\($0.method) \($0.path.replacingOccurrences(of: "/api/cron/jobs/j-paused", with: ""))" }
        XCTAssertEqual(calls.first, "GET ")
        XCTAssertEqual(calls.dropFirst().first, "POST /trigger")
        XCTAssertEqual(calls.last, "POST /pause")
        XCTAssertTrue(waitUntil(10) { self.text("Paused", in: self.app.collectionViews["jobs.list"]).exists }, "the job ends paused")
    }

    /// P-JOB-7: Pause from the swipe moves the row to Paused; an injected 500 says "Couldn't Pause Job" with Try Again.
    @MainActor func testJob7_PauseFromTheSwipeAndAFailure() throws {
        app = launchSignedIn()
        tab("Jobs")
        let row = jobRow("inbox|j-once")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.swipeRight()
        app.buttons["Pause"].firstMatch.tap()
        XCTAssertTrue(waitUntil(5) { self.requests().contains { $0.method == "POST" && $0.path == "/api/cron/jobs/j-once/pause" } })
        try account.control("/__fixture/fail", ["method": "POST", "path": "/api/cron/jobs/j-triage/pause", "status": 500, "detail": "boom", "count": 1])
        let triage = jobRow("inbox|j-triage")
        triage.swipeRight()
        app.buttons["Pause"].firstMatch.tap()
        let alert = app.alerts["Couldn’t Pause Job"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts["boom"].exists, "the gateway's reason")
        XCTAssertTrue(alert.buttons["Try Again"].exists)
        shot("job-pause-failed")
        alert.buttons["OK"].tap()
    }

    /// P-JOB-8: Delete from the detail asks "Delete Job?"; Cancel sends nothing; Delete removes it and pops.
    @MainActor func testJob8_DeleteFromTheDetail() throws {
        app = launchSignedIn()
        tab("Jobs")
        let row = jobRow("inbox|j-once")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let delete = app.buttons["job.delete"]
        XCTAssertTrue(app.staticTexts["job.title"].waitForExistence(timeout: 5))
        shot("job-detail")
        for _ in 0..<4 where !delete.isHittable { app.swipeUp() }
        delete.tap()
        let alert = app.alerts["Delete Job?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["Cancel"].tap()
        XCTAssertFalse(requests().contains { $0.method == "DELETE" })
        delete.tap()
        alert.buttons["Delete Job"].tap()
        XCTAssertTrue(app.collectionViews["jobs.list"].waitForExistence(timeout: 5), "back to the list")
        XCTAssertTrue(waitUntil(5) { !self.jobRow("inbox|j-once").exists }, "the row is gone")
        let deleted = requests().filter { $0.method == "DELETE" }
        XCTAssertEqual(deleted.map { "\($0.path) \($0.query["profile"] ?? "")" }, ["/api/cron/jobs/j-once inbox"])
    }

    /// P-JOB-9: `cron.changed` while Jobs shows reads the list within 3 s.
    @MainActor func testJob9_CronChangedReadsTheList() throws {
        app = launchSignedIn()
        tab("Jobs")
        XCTAssertTrue(jobRow("inbox|j-triage").waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 3)
        let before = requests().filter { $0.method == "GET" && $0.path == "/api/cron/jobs" }.count
        try account.control("/__fixture/broadcast", ["type": "cron.changed"])
        XCTAssertTrue(waitUntil(3.5) { self.requests().filter { $0.method == "GET" && $0.path == "/api/cron/jobs" }.count > before },
                      "one list read after cron.changed")
    }

    /// P-JOB-10: a script job's detail: Script section, a document run that opens read-only with its answer first.
    @MainActor func testJob10_ScriptRunDocument() throws {
        app = launchSignedIn()
        tab("Jobs")
        let row = jobRow("deploys|j-script")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.staticTexts["Script"].firstMatch.waitForExistence(timeout: 5), "the Script capsule / section")
        let document = app.buttons["job.run-row.cron_output:j-script:2026-10-09_08-00-00"]
        for _ in 0..<5 where !document.isHittable { app.swipeUp() }
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["job.run-row.cron_output:j-script:exec:2"].isEnabled, "the exec row opens nothing")
        shot("job-script-detail")
        document.tap()
        let body = app.textViews["artifact.text.body"]
        XCTAssertTrue(body.waitForExistence(timeout: 8))
        XCTAssertTrue(waitUntil(5) { ((body.value as? String) ?? "").contains("Disk 71% used") })
        let value = (body.value as? String) ?? ""
        let response = value.range(of: "Disk 71% used"), prompt = value.range(of: "Run check_disk.sh")
        XCTAssertNotNil(response)
        if let response, let prompt { XCTAssertLessThan(response.lowerBound, prompt.lowerBound, "the answer comes first") }
        shot("job-run-document")
    }

    // MARK: Kanban

    /// P-KB-1: opens on Blocked, its count matches the board.
    @MainActor func testKB1_OpensOnBlocked() throws {
        app = launchSignedIn()
        tab("Kanban")
        let blocked = app.cells["kanban.chip.blocked"]
        XCTAssertTrue(blocked.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(5) { blocked.label.contains("Blocked, 2 tasks") || blocked.descendants(matching: .any)["Blocked, 2 tasks"].exists })
        XCTAssertTrue(app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'kanban-task-'")).count == 2, "the two blocked tasks")
        shot("kanban-board")
    }

    /// P-KB-2: swipe Unblock: the card leaves, PATCH {"status":"ready"} with no board param, one dispatcher nudge.
    @MainActor func testKB2_SwipeUnblock() throws {
        app = launchSignedIn()
        tab("Kanban")
        let task = taskRow("Approve the 2.4 release notes")
        XCTAssertTrue(task.waitForExistence(timeout: 10))
        task.swipeRight()
        app.buttons["Unblock"].firstMatch.tap()
        XCTAssertTrue(waitUntil(5) { !task.exists }, "the card leaves Blocked")
        XCTAssertTrue(waitUntil(5) { (try? self.account.control("/__fixture/state"))?["dispatch"] as? Int == 1 }, "one nudge")
        let patch = requests().first { $0.method == "PATCH" }
        XCTAssertEqual(patch?.body?["status"] as? String, "ready")
        XCTAssertNil(patch?.query["board"], "no board param on the current board")
    }

    /// P-KB-3: a move the gateway refuses (409) puts the card back and says why.
    @MainActor func testKB3_RefusedMoveComesBack() throws {
        app = launchSignedIn()
        tab("Kanban")
        chip("todo").tap()
        let task = taskRow("Publish the 2.4 changelog")
        XCTAssertTrue(task.waitForExistence(timeout: 5))
        task.swipeRight()
        app.buttons["Mark Ready"].firstMatch.tap()
        let notice = app.descendants(matching: .any)["pages.notice"]
        XCTAssertTrue(waitUntil(5) { notice.label.contains("Cannot move to 'ready'") }, "the gateway's words (\(notice.label))")
        XCTAssertTrue(task.waitForExistence(timeout: 5), "the card is back in Todo")
        shot("kanban-refused")
    }

    /// P-KB-4: Move To never offers Running, Review, Scheduled or Archived.
    @MainActor func testKB4_MoveToOffersOnlyOpenStatuses() throws {
        app = launchSignedIn()
        tab("Kanban")
        let task = taskRow("Approve the 2.4 release notes")
        XCTAssertTrue(task.waitForExistence(timeout: 10))
        task.press(forDuration: 1.0)
        app.buttons["Move To"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Ready"].firstMatch.waitForExistence(timeout: 3))
        for locked in ["Running", "Review", "Scheduled", "Archived"] { XCTAssertFalse(app.buttons[locked].exists, "\(locked) is not a target") }
        shot("kanban-move-menu")
        app.tap()
    }

    /// P-KB-5: New Task sends only what was given and the Ready chip shows it afterwards.
    @MainActor func testKB5_NewTask() throws {
        app = launchSignedIn()
        tab("Kanban")
        app.navigationBars.buttons["New Task"].tap()
        let add = app.navigationBars.buttons["kanban.new.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertFalse(add.isEnabled, "Add waits for a title")
        app.textFields["kanban.new.title"].typeText("Write the release post")
        app.buttons["kanban.new.nobody"].tap()
        app.segmentedControls["kanban.new.start"].buttons["Ready"].tap()
        shot("kanban-new-task")
        XCTAssertTrue(add.isEnabled)
        add.tap()
        XCTAssertTrue(taskRow(showing: "Write the release post").waitForExistence(timeout: 8), "the Ready chip shows the new task")
        let post = requests().first { $0.method == "POST" && $0.path == "/api/plugins/kanban/tasks" }
        let body = post?.body ?? [:]
        XCTAssertEqual(body["title"] as? String, "Write the release post")
        XCTAssertEqual(body["priority"] as? Int, 0)
        XCTAssertEqual(body["triage"] as? Bool, false)
        XCTAssertEqual(body["goal_mode"] as? Bool, false)
        XCTAssertEqual(Set(body.keys), ["title", "priority", "triage", "goal_mode"], "no assignee, body or skills")
    }

    /// P-KB-6: archive a Done task → Undo pill → Undo puts it back with PATCH {"status":"done"}.
    @MainActor func testKB6_ArchiveThenUndo() throws {
        app = launchSignedIn()
        tab("Kanban")
        chip("done").tap()
        let task = taskRow("Cut the 2.4 branch")
        XCTAssertTrue(task.waitForExistence(timeout: 5))
        task.swipeLeft()
        app.buttons["Archive"].firstMatch.tap()
        let undo = app.buttons["undo-pill.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "the Undo pill")
        XCTAssertTrue(app.staticTexts["Archived tasks are on the desktop board."].exists, "the pill says where archived tasks went")
        shot("kanban-undo")
        undo.tap()
        XCTAssertTrue(waitUntil(5) { self.requests().filter { $0.method == "PATCH" }.compactMap { $0.body?["status"] as? String } == ["archived", "done"] })
        XCTAssertTrue(task.waitForExistence(timeout: 5), "the task is back")
    }

    /// P-KB-7 / P-KB-8: Delete asks first; a comment posts as "desktop" and reads "You".
    @MainActor func testKB8_TaskSheetComment() throws {
        app = launchSignedIn()
        tab("Kanban")
        let task = taskRow("Approve the 2.4 release notes")
        XCTAssertTrue(task.waitForExistence(timeout: 10))
        task.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Delete Task"].firstMatch.waitForExistence(timeout: 3), "Delete asks first")
        XCTAssertTrue(app.staticTexts["Delete This Task?"].exists)
        dismissSheet()
        XCTAssertFalse(requests().contains { $0.method == "DELETE" }, "Cancel sends nothing")
        task.tap()
        XCTAssertTrue(app.staticTexts["kanban.task.title"].waitForExistence(timeout: 8))
        shot("kanban-task-sheet")
        let field = app.textFields["kanban.task.comment"]
        for _ in 0..<6 where !field.isHittable { app.swipeUp() }
        field.tap()
        // The field (and its Send) scroll above the keyboard once it rises (verify round 1: cut in half by the keys).
        XCTAssertTrue(waitUntil(5) { self.app.keyboards.count > 0 })
        XCTAssertTrue(waitUntil(3) { self.aboveKeyboard(self.app.buttons["kanban.task.send"]) }, "the comment's Send sits above the keyboard")
        field.typeText("Ship it as drafted.")
        // Send once it rests (the sheet re-places the field when the keyboard comes back after typing); again if the
        // tap landed while it moved.
        let send = app.buttons["kanban.task.send"]
        let posted = { self.requests().contains { $0.method == "POST" && $0.path.hasSuffix("/comments") } }
        for _ in 0..<3 where !posted() {
            var last = CGRect.null
            _ = waitUntil(3) { let f = send.frame; defer { last = f }; return send.isHittable && f == last }
            send.tap()
            _ = waitUntil(3, posted)
        }
        XCTAssertTrue(waitUntil(5, posted), "the comment posts")
        let post = requests().first { $0.method == "POST" && $0.path.hasSuffix("/comments") }
        XCTAssertEqual(post?.body?["author"] as? String, "desktop")
        XCTAssertEqual(post?.body?["body"] as? String, "Ship it as drafted.")
        XCTAssertTrue(app.staticTexts["You"].waitForExistence(timeout: 5), "the comment reads as yours")
        // The posted comment's row pushes the field down: it is brought back above the keys.
        XCTAssertTrue(waitUntil(3) { self.aboveKeyboard(field) }, "the field stays above the keyboard after Send")
    }

    /// Owner 2026-10-15: under an empty field a greyed Post and Start Over read as placeholder text. On a running task it
    /// shows only once there is a comment to post, and the history picker is not a row inside the comments box.
    @MainActor func testKB13_PostAndStartOverOnlyWithAComment() throws {
        app = launchSignedIn()
        tab("Kanban")
        chip("running").tap()
        let task = taskRow("Run the 2.4 test suite")
        XCTAssertTrue(task.waitForExistence(timeout: 10))
        task.tap()
        XCTAssertTrue(app.staticTexts["kanban.task.title"].waitForExistence(timeout: 8))
        let field = app.textFields["kanban.task.comment"]
        for _ in 0..<6 where !field.isHittable { app.swipeUp() }
        XCTAssertTrue(field.isHittable)
        XCTAssertFalse(app.buttons["kanban.task.requeue"].exists, "no Post and Start Over under an empty field")
        XCTAssertTrue(app.staticTexts["The bot reads new comments while it works."].exists, "the hint sits under the box")
        field.tap()
        XCTAssertTrue(waitUntil(5) { self.app.keyboards.count > 0 })
        field.typeText("Skip the export checks.")
        XCTAssertTrue(app.buttons["kanban.task.requeue"].waitForExistence(timeout: 3), "Post and Start Over once there is a comment")
        shot("kanban-task-requeue")
    }

    /// Verify round 1: the description editor read back a stale copy between keystrokes and dropped most of a fast
    /// typist's words ("abcdefghij klmnop" saved as "ahnp"). Every character typed is saved.
    @MainActor func testKB12_DescriptionKeepsEveryTypedCharacter() throws {
        app = launchSignedIn()
        tab("Kanban")
        let task = taskRow("Approve the 2.4 release notes")
        XCTAssertTrue(task.waitForExistence(timeout: 10))
        task.tap()
        XCTAssertTrue(app.staticTexts["kanban.task.title"].waitForExistence(timeout: 8))
        let edit = app.buttons["Edit"].firstMatch
        for _ in 0..<6 where !edit.isHittable { app.swipeUp() }
        edit.tap()
        let editor = app.textViews["Description"].exists ? app.textViews["Description"] : app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "the editor opens")
        editor.tap()
        XCTAssertTrue(waitUntil(5) { self.app.keyboards.count > 0 })
        let before = (editor.value as? String) ?? ""
        editor.typeText(" abcdefghij klmnop")
        XCTAssertTrue(waitUntil(3) { self.aboveKeyboard(editor, bottomOnly: true) }, "the line being typed is above the keyboard")
        shot("kanban-description-typing")
        app.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(waitUntil(6) { self.requests().contains { $0.method == "PATCH" && $0.body?["body"] != nil } }, "the description saved")
        let saved = requests().last { $0.method == "PATCH" && $0.body?["body"] != nil }?.body?["body"] as? String ?? ""
        XCTAssertTrue(saved.contains("abcdefghij klmnop"), "every character arrived (\(saved), was \(before))")
    }

    /// The element's bottom (or all of it) is on screen above the keyboard.
    @MainActor func aboveKeyboard(_ element: XCUIElement, bottomOnly: Bool = false) -> Bool {
        guard element.exists else { return false }
        let keys = app.keyboards.firstMatch
        let top = keys.exists ? keys.frame.minY : app.windows.firstMatch.frame.maxY
        let frame = element.frame
        return frame.maxY <= top + 1 && (bottomOnly || frame.minY >= 0)
    }

    /// P-KB-10: Assign To Research sends reassign with reclaim_first, and the row shows Research at once.
    @MainActor func testKB10_AssignToResearch() throws {
        app = launchSignedIn()
        tab("Kanban")
        let task = taskRow("Approve the 2.4 release notes")
        XCTAssertTrue(task.waitForExistence(timeout: 10))
        XCTAssertTrue(text("Deploys", in: task).exists, "assigned to Deploys first")
        task.press(forDuration: 1.0)
        app.buttons["Assign To"].firstMatch.tap()
        let research = menuItem("Research")
        XCTAssertTrue(research.waitForExistence(timeout: 3))
        research.tap()
        XCTAssertTrue(waitUntil(1.5) { self.text("Research", in: task).exists }, "the row changes at once")
        XCTAssertTrue(waitUntil(5) { self.requests().contains { $0.method == "POST" && $0.path.hasSuffix("/reassign") } })
        let post = requests().first { $0.method == "POST" && $0.path.hasSuffix("/reassign") }
        XCTAssertEqual(post?.body?["profile"] as? String, "research")
        XCTAssertEqual(post?.body?["reclaim_first"] as? Bool, true)
        shot("kanban-assigned")
    }

    /// P-KB-9: picking "Home" reads with ?board=home; back to the current board drops the param.
    @MainActor func testKB9_SwitchBoards() throws {
        app = launchSignedIn()
        tab("Kanban")
        let board = app.buttons["kanban.board"]
        XCTAssertTrue(board.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(5) { board.isEnabled })
        board.tap()
        Thread.sleep(forTimeInterval: 1)
        shot("kanban-board-menu")
        menuItem("Home").tap()
        XCTAssertTrue(waitUntil(5) { self.requests().contains { $0.path == "/api/plugins/kanban/board" && $0.query["board"] == "home" } })
        XCTAssertTrue(waitUntil(5) { board.label.contains("Home") })
        board.tap()
        menuItem("Release 2.4").tap()
        XCTAssertTrue(waitUntil(5) { board.label.contains("Release 2.4") })
        let last = requests().last { $0.path == "/api/plugins/kanban/board" }
        XCTAssertNil(last?.query["board"], "the current board needs no param")
    }

    /// P-KB-11: the board is styled in its first frames, light and dark (`MEM/kanban-css-preload.md`): chips and the
    /// grouped list are there as soon as the tab shows.
    @MainActor func testKB11_StyledInTheFirstFrameLightAndDark() throws {
        defer { XCUIDevice.shared.appearance = .light }
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            app = launchSignedIn()
            let kanban = app.tabBars.buttons["Kanban"]
            XCTAssertTrue(kanban.waitForExistence(timeout: 10))
            kanban.tap()
            shot("kanban-first-frame-\(appearance == .dark ? "dark" : "light")")
            XCTAssertTrue(app.cells["kanban.chip.blocked"].waitForExistence(timeout: 1), "chips in the first frames")
            XCTAssertTrue(app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'kanban-task-'")).firstMatch.waitForExistence(timeout: 3))
            app.terminate()
        }
    }

    // MARK: Artifacts

    /// P-ART-1 / P-ART-6: exactly the fixture's artifacts; the missing image collects under Unavailable.
    @MainActor func testArt1_IndexesTheRightFiles() throws {
        app = launchSignedIn()
        openArtifacts()
        let list = app.collectionViews["artifacts.list"]
        for label in ["summary.md", "report.pdf", "index.html", "release-notes.md", "export.csv", "log.txt", "App.swift"] {
            XCTAssertTrue(scrollTo(list.cells["artifact-row-\(label)"], in: list), "\(label) is listed")
        }
        for label in ["CHANGELOG.md", "pkg-1.0-py3-none-any.whl", "triage.md"] {
            XCTAssertFalse(list.cells["artifact-row-\(label)"].exists, "\(label) is not an artifact")
        }
        XCTAssertTrue(scrollTo(list.cells["artifacts.unavailable"], in: list), "old.png is unavailable")
        XCTAssertTrue(list.cells["artifacts.unavailable"].staticTexts["Unavailable (1)"].exists)
        list.swipeDown(); list.swipeDown()
        app.segmentedControls["artifacts.filter"].buttons["Links"].tap()
        XCTAssertTrue(list.cells["artifact-row-Open Planning"].waitForExistence(timeout: 3))
        XCTAssertTrue(list.cells["artifact-row-Long Memory"].exists)
        shot("artifacts-links")
        app.segmentedControls["artifacts.filter"].buttons["All"].tap()
    }

    /// [preview-tables] A Markdown table in the Preview is the chat's table card (it read as scattered words when wider
    /// than the page): the card shows, scrolls sideways, and Expand opens the Table page. Both looks.
    @MainActor func testArt5b_PreviewTableCard() throws {
        for (look, flag) in [("ios", "<false/>"), ("desktop", "<true/>")] {
            app = launchSignedIn(["-hqn.theme.desktopLook", flag])
            openArtifacts()
            let list = app.collectionViews["artifacts.list"]
            XCTAssertTrue(scrollTo(list.cells["artifact-row-summary.md"], in: list))
            list.cells["artifact-row-summary.md"].tap()
            let body = app.textViews["artifact.text.body"]
            XCTAssertTrue(body.waitForExistence(timeout: 8))
            let expand = app.buttons["chat.table.expand"]
            if !expand.waitForExistence(timeout: 5) { body.swipeUp() }
            XCTAssertTrue(expand.waitForExistence(timeout: 3), "the table is a card, its Expand reachable")
            body.swipeUp()
            shot("artifact-table-card-\(look)")
            // A sideways drag on the cells, above the footer.
            expand.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: -1.5))
                .press(forDuration: 0.05, thenDragTo: expand.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: -1.5)))
            shot("artifact-table-card-scrolled-\(look)")
            expand.tap()
            XCTAssertTrue(app.otherElements["table.sheet"].waitForExistence(timeout: 5), "Expand opens the Table page")
            shot("artifact-table-sheet-\(look)")
            app.terminate()
        }
    }

    /// P-ART-5: Markdown opens in the text viewer (Preview | Source); App.swift monospaced (no modes); log.txt (3 MiB) and
    /// report.pdf in Quick Look; HTML's Preview is Quick Look drawing the page, which never fetches its image.
    @MainActor func testArt5_OpensTextAndQuickLook() throws {
        app = launchSignedIn()
        openArtifacts()
        let list = app.collectionViews["artifacts.list"]
        XCTAssertTrue(scrollTo(list.cells["artifact-row-summary.md"], in: list))
        list.cells["artifact-row-summary.md"].tap()
        XCTAssertTrue(app.textViews["artifact.text.body"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.segmentedControls["artifact.text.mode"].waitForExistence(timeout: 3), "Preview | Source")
        shot("artifact-text-preview")
        app.segmentedControls["artifact.text.mode"].buttons["Source"].tap()
        shot("artifact-text-source")
        back()

        XCTAssertTrue(scrollTo(list.cells["artifact-row-App.swift"], in: list))
        list.cells["artifact-row-App.swift"].tap()
        let code = app.textViews["artifact.text.body"]
        XCTAssertTrue(code.waitForExistence(timeout: 8))
        XCTAssertTrue(waitUntil(5) { ((code.value as? String) ?? "").contains("struct ReleaseApp") }, "the code shows")
        XCTAssertFalse(app.segmentedControls["artifact.text.mode"].exists, "code has no Preview | Source")
        shot("artifact-code")
        back()

        // A slow gateway (2.5 s): "Downloading report.pdf…" with Cancel shows, and goes once Quick Look opens.
        let cancel = app.buttons["undo-pill.undo"]
        XCTAssertTrue(scrollTo(list.cells["artifact-row-report.pdf"], in: list))
        try account.control("/__fixture/fail", ["method": "GET", "path": "/api/fs/download", "delay": 2.5])
        list.cells["artifact-row-report.pdf"].tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 2), "Downloading report.pdf… with Cancel")
        let preview = app.descendants(matching: .any)["artifact.quicklook"]
        XCTAssertTrue(preview.waitForExistence(timeout: 15), "report.pdf opens in Quick Look")
        Thread.sleep(forTimeInterval: 1.5)
        shot("artifact-quicklook-pdf")
        XCTAssertFalse(cancel.exists, "no Downloading notice left over")
        closeQuickLook()
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        XCTAssertFalse(cancel.exists, "no Downloading notice after Quick Look closes")

        XCTAssertTrue(scrollTo(list.cells["artifact-row-index.html"], in: list))
        list.cells["artifact-row-index.html"].tap()
        // [safer-deletes] Since a37b2b28 (build 537) the Preview is the page drawn live, its scripts running, not Quick Look
        // (which drew a script-drawn chart blank); like the chat's page card, it loads what the page names.
        XCTAssertTrue(app.webViews["artifact.page"].waitForExistence(timeout: 10), "the live page is the Preview")
        let page = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Release 2.4")).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 15), "the page draws its heading")
        Thread.sleep(forTimeInterval: 1)
        shot("artifact-preview-html")
        app.segmentedControls["artifact.text.mode"].buttons["Source"].tap()
        let source = app.textViews["artifact.text.body"]
        XCTAssertTrue(waitUntil(5) { ((source.value as? String) ?? "").contains("<h1>Release 2.4</h1>") }, "Source reads the HTML")
        back()

        // log.txt (3 MiB) goes to Quick Look (routing: ArtifactFilesTests). Once it shows, the accessibility tree of a
        // 3 MiB text takes minutes to read, so the check is the download and a screenshot, then the app is closed.
        XCTAssertTrue(scrollTo(list.cells["artifact-row-log.txt"], in: list))
        list.cells["artifact-row-log.txt"].tap()
        XCTAssertTrue(waitUntil(10) { self.requests().contains { $0.path == "/api/fs/download" && ($0.query["path"] ?? "").hasSuffix("log.txt") } })
        Thread.sleep(forTimeInterval: 5)
        shot("artifact-quicklook-log")
        app.terminate()
    }

    /// P-ART-7: Copy Path from the row's ⋯ says "Copied".
    @MainActor func testArt7_CopyPath() throws {
        app = launchSignedIn()
        openArtifacts()
        let list = app.collectionViews["artifacts.list"]
        let row = list.cells["artifact-row-export.csv"]
        XCTAssertTrue(scrollTo(row, in: list))
        row.buttons["Actions for export.csv"].tap()
        app.buttons["Copy Path"].firstMatch.tap()
        let hud = app.descendants(matching: .any)["pages.hud"]
        XCTAssertTrue(waitUntil(3) { hud.exists && hud.label == "Copied" }, "Copied shows")
        shot("artifact-copied")
    }

    /// [pins] Pin from a row's swipe and a tile's menu: the files join the Pinned shelf on top of Artifacts and the row is
    /// marked. The Pinned page in More lists them. Show in Chat opens the chat, where the page card is marked Pinned and
    /// its menu unpins. Unpin takes a pin off everywhere.
    @MainActor func testArt8_PinsShelfAndPage() throws {
        let (arguments, shot) = pinsLook()
        app = launchSignedIn(arguments + ["-HQDebugResetPins", "YES"])
        openArtifacts()
        let list = app.collectionViews["artifacts.list"]
        XCTAssertFalse(list.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'pin-card-'")).firstMatch.exists,
                       "no pins left over from an earlier run")
        pinThree(in: list)
        Thread.sleep(forTimeInterval: 4)   // the page's picture draws
        shot("pins-shelf")
        let marked = list.cells["artifact-row-index.html"]
        XCTAssertTrue(scrollTo(marked, in: list), "index.html is listed")   // below the shelf at the largest text
        XCTAssertTrue(marked.descendants(matching: .any)["artifact-pinned"].exists, "the row is marked")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        let pinnedRow = app.cells["more-row-pinned"]
        XCTAssertTrue(scrollTo(pinnedRow, in: app.collectionViews.firstMatch), "Pinned is a More row")
        pinnedRow.tap()
        let page = app.collectionViews["pinned.list"]
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        for label in ["index.html", "results.png", "export.csv"] {
            // From the top each time: at the largest text the cards run past the screen.
            for _ in 0..<4 where !page.staticTexts["3 Items"].isHittable { page.swipeDown() }
            XCTAssertTrue(scrollTo(page.cells["pin-card-\(label)"], in: page), "\(label) on the Pinned page")
        }
        for _ in 0..<4 where !page.staticTexts["3 Items"].isHittable { page.swipeDown() }
        Thread.sleep(forTimeInterval: 2)
        shot("pins-page")

        // View As › List: the pins as rows like Today's; Cards again after.
        XCTAssertTrue(page.staticTexts["3 Items"].exists, "the header counts the pins")
        app.buttons["pins.view"].firstMatch.tap()
        app.buttons["pins.view.list"].firstMatch.tap()
        XCTAssertTrue(page.cells["pin-row-index.html"].waitForExistence(timeout: 5), "List shows rows")
        XCTAssertFalse(page.cells["pin-card-index.html"].exists, "and no cards")
        shot("pins-page-list")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(scrollTo(app.cells["more-row-artifacts"], in: app.collectionViews.firstMatch))
        app.cells["more-row-artifacts"].tap()
        let shelfList = app.collectionViews["artifacts.list"]
        XCTAssertTrue(shelfList.cells["pin-row-export.csv"].waitForExistence(timeout: 5), "Artifacts lists the pins as rows too")
        shot("pins-shelf-list")
        app.buttons["pins.view"].firstMatch.tap()
        app.buttons["pins.view.cards"].firstMatch.tap()
        XCTAssertTrue(shelfList.cells["pin-card-export.csv"].waitForExistence(timeout: 5), "Cards again")
        app.buttons["pins.view"].firstMatch.tap()
        app.buttons["pins.open-page"].firstMatch.tap()
        XCTAssertTrue(page.waitForExistence(timeout: 5), "Open Pinned pushes the Pinned page")

        // The chat links the page inline; a page alone on its line is what draws a card.
        try account.control("/__fixture/append", ["session_id": "s-report", "role": "assistant", "text": "MEDIA:/home/hermes/site/index.html"])
        page.cells["pin-card-index.html"].buttons["Actions for Index"].tap()   // [tiles] the name in words
        app.buttons["Show in Chat"].firstMatch.tap()
        let card = app.descendants(matching: .any)["chat.page-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the chat shows its page card")
        XCTAssertTrue(waitUntil(5) { (card.value as? String) == "Pinned" }, "the card is marked Pinned")
        Thread.sleep(forTimeInterval: 3)
        shot("pins-chat-card")
        card.press(forDuration: 1)
        XCTAssertTrue(app.buttons["artifact.unpin"].firstMatch.waitForExistence(timeout: 3), "the card's menu offers Unpin")
        shot("pins-chat-card-menu")
        app.buttons["artifact.unpin"].firstMatch.tap()
        XCTAssertTrue(waitUntil(5) { (card.value as? String) != "Pinned" }, "unpinned from the chat")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertTrue(page.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(5) { !page.cells["pin-card-index.html"].exists }, "gone from the Pinned page")
        for (label, name) in [("results.png", "Results"), ("export.csv", "Export")] {
            page.cells["pin-card-\(label)"].buttons["Actions for \(name)"].tap()
            app.buttons["Unpin"].firstMatch.tap()
            XCTAssertTrue(waitUntil(5) { !page.cells["pin-card-\(label)"].exists }, "\(label) unpinned")
        }
        XCTAssertTrue(app.staticTexts["No Tiles Yet"].waitForExistence(timeout: 3), "the empty page says how to pin")
        shot("pins-empty")

        // Owner 2026-11-01 on that page: "Idk how to use this page". Open Artifacts goes where things are pinned, and
        // a pin made there is on the page coming back.
        app.buttons["Open Artifacts"].firstMatch.tap()
        let artifacts = app.collectionViews["artifacts.list"]
        XCTAssertTrue(artifacts.waitForExistence(timeout: 5), "Open Artifacts pushes Artifacts")
        let row = artifacts.cells["artifact-row-export.csv"]
        XCTAssertTrue(scrollTo(row, in: artifacts), "export.csv is listed")
        row.swipeRight()
        app.buttons["Pin"].firstMatch.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(page.cells["pin-card-export.csv"].waitForExistence(timeout: 5), "pinned from there, on the page")
    }

    /// [dashboard] Edit Tiles (owner 2026-11-02, "more like widgets"): the tiles wiggle with a badge and a corner handle;
    /// dragging the page's handle down makes it Extra Large (the grid's width, three rows), back up Small; a tap doesn't
    /// open; the badge unpins; Done ends it. Grid is where a fresh install starts.
    /// [dashboard] ＋ on the Dashboard's header opens New Tile: what to show, ideas, which bot makes it.
    @MainActor func testArt12_NewTileSheet() throws {
        let (arguments, shot) = pinsLook()
        app = launchSignedIn(arguments + ["-HQDebugResetPins", "YES"])
        openArtifacts()
        let list = app.collectionViews["artifacts.list"]
        pinThree(in: list)
        app.buttons["pins.view"].firstMatch.tap()
        app.buttons["pins.view.grid"].firstMatch.tap()
        app.buttons["pins.view"].firstMatch.tap()
        app.buttons["pins.open-page"].firstMatch.tap()
        XCTAssertTrue(app.collectionViews["pinned.list"].cells["pin-card-index.html"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 3)
        shot("pins-dashboard-plus")

        let plus = app.buttons["tile.new"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 3), "＋ New Tile beside View As")
        plus.tap()
        let what = app.textViews["tile.new.what"].exists ? app.textViews["tile.new.what"] : app.textFields["tile.new.what"]
        XCTAssertTrue(what.waitForExistence(timeout: 5), "the New Tile sheet asks what to show")
        XCTAssertFalse(app.buttons["tile.new.make"].firstMatch.isEnabled, "Make waits for words")
        Thread.sleep(forTimeInterval: 1)
        shot("pins-new-tile")
        // [tiles] The bot's face chooses it, not only its name (owner 2026-11-03).
        let bots = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tile.new.bot."))
        XCTAssertGreaterThan(bots.count, 1, "more than one bot to pick from")
        let other = bots.element(boundBy: 1)
        // The bots sit under the keyboard at first: scroll them up into view.
        func inView() -> Bool {
            let keyboard = app.keyboards.firstMatch
            let bottom = keyboard.exists ? keyboard.frame.minY : app.windows.firstMatch.frame.maxY
            return other.isHittable && other.frame.maxY < bottom - 4
        }
        for _ in 0..<5 where !inView() { app.staticTexts["Ideas"].firstMatch.swipeUp() }
        XCTAssertTrue(inView(), "the bots scroll into view")
        other.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCTAssertTrue(waitUntil(3) { other.isSelected }, "a tap on the face picks the bot")
        // [tiles] More Ideas shows the rest.
        let more = app.buttons["tile.new.more-ideas"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 3), "More Ideas under the first six")
        more.tap()
        XCTAssertTrue(app.buttons["A countdown to a date that matters"].firstMatch.waitForExistence(timeout: 3), "the rest of the ideas")
        shot("pins-new-tile-more-ideas")
        what.tap()
        what.typeText("Open pull requests by repo")
        XCTAssertTrue(waitUntil(3) { self.app.buttons["tile.new.make"].firstMatch.isEnabled }, "Make once there are words")
        shot("pins-new-tile-typed")

        // [tiles] Made: the tile being made shows as a row on the page (owner 2026-11-03: "idk where to see it doing
        // anything"), and the row opens the chat.
        app.buttons["tile.new.make"].firstMatch.tap()
        let making = app.collectionViews["pinned.list"].cells["tile.making"]
        XCTAssertTrue(making.waitForExistence(timeout: 5), "the tile being made shows on the page")
        shot("pins-tile-making")
        making.tap()
        Thread.sleep(forTimeInterval: 2)
        shot("pins-tile-making-chat")
        XCTAssertTrue(app.descendants(matching: .any)["chat.table"].waitForExistence(timeout: 5), "the row opens the tile's chat")
    }

    /// [dashboard] Pages on the Dashboard (owner 2026-11-03): ＋ makes one, a tile moves there, swipe back to Main.
    @MainActor func testArt13_DashboardPages() throws {
        let (arguments, shot) = pinsLook()
        app = launchSignedIn(arguments + ["-HQDebugResetPins", "YES"])
        openArtifacts()
        let list = app.collectionViews["artifacts.list"]
        pinThree(in: list)
        app.buttons["pins.view"].firstMatch.tap()
        app.buttons["pins.view.grid"].firstMatch.tap()
        app.buttons["pins.view"].firstMatch.tap()
        app.buttons["pins.open-page"].firstMatch.tap()
        let page = app.collectionViews["pinned.list"]
        let pageTile = page.cells["pin-card-index.html"]
        XCTAssertTrue(pageTile.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["dashboard.page.main"].exists, "one page: no page names")

        // A new page (View As › New Page while there is one): shown at once, empty, the names above.
        app.buttons["pins.view"].firstMatch.tap()
        app.buttons["dashboard.page.new"].firstMatch.tap()
        let name = app.textFields["dashboard.page.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.typeText("Finance")
        app.alerts.buttons["Add"].tap()
        XCTAssertTrue(app.buttons["dashboard.page.Finance"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["dashboard.page.main"].exists, "Main leads the page names")
        XCTAssertTrue(app.staticTexts["This Page Is Empty"].waitForExistence(timeout: 3), "the new page is shown, empty")
        shot("pins-pages-new")

        // Swipe back to Main: the three tiles.
        page.swipeRight()
        XCTAssertTrue(pageTile.waitForExistence(timeout: 3), "swiped back to Main")

        // A tile moved onto Finance.
        pageTile.press(forDuration: 1)
        app.buttons["Move to Page"].firstMatch.tap()
        app.buttons["Finance"].firstMatch.tap()
        XCTAssertTrue(waitUntil(3) { !pageTile.exists }, "the tile left Main")
        XCTAssertTrue(app.staticTexts["2 Items"].waitForExistence(timeout: 3))
        app.buttons["dashboard.page.Finance"].firstMatch.tap()
        XCTAssertTrue(pageTile.waitForExistence(timeout: 3), "the tile is on Finance")
        XCTAssertTrue(app.staticTexts["1 Item"].exists)
        Thread.sleep(forTimeInterval: 3)
        shot("pins-pages-finance")

        // Deleting Finance sends its tile back to Main.
        app.buttons["dashboard.page.Finance"].firstMatch.press(forDuration: 1)
        app.buttons["dashboard.page.delete"].firstMatch.tap()
        app.alerts.buttons["Delete Page"].tap()
        XCTAssertTrue(waitUntil(3) { !self.app.buttons["dashboard.page.Finance"].exists })
        XCTAssertFalse(app.buttons["dashboard.page.main"].exists, "back to one page: the names go")
        XCTAssertTrue(app.staticTexts["3 Items"].waitForExistence(timeout: 3), "nothing unpinned")
    }

    /// [header-menus] Owner 2026-11-03 (menu review, "Actions you can only reach by long-press"): a page's Rename, Move
    /// and Delete were only a hold on its name away. The ⋯ after the page names opens the shown page's hold menu.
    @MainActor func testArt13b_DashboardPageMenuButton() throws {
        let (arguments, shot) = pinsLook()
        app = launchSignedIn(arguments + ["-HQDebugResetPins", "YES"])
        openArtifacts()
        let list = app.collectionViews["artifacts.list"]
        pinThree(in: list)
        app.buttons["pins.view"].firstMatch.tap()
        app.buttons["pins.view.grid"].firstMatch.tap()
        app.buttons["pins.view"].firstMatch.tap()
        app.buttons["pins.open-page"].firstMatch.tap()
        let page = app.collectionViews["pinned.list"]
        XCTAssertTrue(page.cells["pin-card-index.html"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["dashboard.page.menu"].exists, "one page: no names, no ⋯")
        app.buttons["pins.view"].firstMatch.tap()
        app.buttons["dashboard.page.new"].firstMatch.tap()
        let name = app.textFields["dashboard.page.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.typeText("Finance")
        app.alerts.buttons["Add"].tap()
        XCTAssertTrue(app.buttons["dashboard.page.Finance"].waitForExistence(timeout: 3))
        let more = app.buttons["dashboard.page.menu"]
        XCTAssertTrue(more.waitForExistence(timeout: 3), "the ⋯ after the page names")
        XCTAssertEqual(more.label, "Actions for Finance", "for the page shown")
        // Drawn as the ＋ (the bar's own size), just after it.
        let add = app.buttons["dashboard.page.add"]
        XCTAssertEqual(more.frame.height, add.frame.height, accuracy: 1, "as tall as the ＋")
        XCTAssertGreaterThanOrEqual(more.frame.minX, add.frame.maxX, "after the ＋")
        XCTAssertTrue(more.isHittable)
        Thread.sleep(forTimeInterval: 1)
        shot("pins-pages-menu-button")
        more.tap()
        let rename = app.buttons["dashboard.page.rename"].firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 3), "Rename, as the hold menu")
        XCTAssertTrue(app.buttons["dashboard.page.delete"].firstMatch.exists, "and Delete Page")
        shot("pins-pages-menu-open")
        rename.tap()
        let field = app.textFields["dashboard.page.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7) + "Money")
        let save = app.alerts.buttons["Rename"]
        save.tap()
        let gone = waitUntil(1.5) { !save.exists }
        if !gone, save.exists { save.tap() }   // a tap lost while the keyboard settled
        XCTAssertTrue(app.buttons["dashboard.page.Money"].waitForExistence(timeout: 3), "renamed from the ⋯")
        XCTAssertTrue(waitUntil(3) { more.label == "Actions for Money" }, more.label)
        // Main shown: its menu renames only (Main is never moved or deleted).
        app.buttons["dashboard.page.main"].firstMatch.tap()
        XCTAssertTrue(waitUntil(3) { more.label == "Actions for Main" }, more.label)
        more.tap()
        XCTAssertTrue(rename.waitForExistence(timeout: 3), "Main's Rename")
        XCTAssertFalse(app.buttons["dashboard.page.delete"].firstMatch.exists, "Main can't be deleted")
        shot("pins-pages-menu-main")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.5)).tap()   // the menu goes with a tap off it
        XCTAssertTrue(waitUntil(3) { !rename.exists }, "the menu closes")
    }

    /// [tiles] Tiles as a tab (owner 2026-11-03: "Dashboard" was too long beside Bots, Sessions, Jobs): its name and icon.
    @MainActor func testArt14_TilesTab() throws {
        let (arguments, shot) = pinsLook()
        app = launchSignedIn(arguments + ["-HQDebugResetPins", "YES", "-hqn.tabOrder", "(bots, sessions, jobs, page.pinned)"])
        let tab = app.tabBars.buttons["Tiles"].exists ? app.tabBars.buttons["Tiles"] : app.buttons["Tiles"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 8), "a Tiles tab")
        tab.tap()
        XCTAssertTrue(app.staticTexts["No Tiles Yet"].waitForExistence(timeout: 5), "the empty Tiles page")
        Thread.sleep(forTimeInterval: 2)
        shot("pins-tiles-tab")
    }

    @MainActor func testArt11_EditTiles() throws {
        let (arguments, shot) = pinsLook()
        app = launchSignedIn(arguments + ["-HQDebugResetPins", "YES"])
        openArtifacts()
        let list = app.collectionViews["artifacts.list"]
        pinThree(in: list)
        app.buttons["pins.view"].firstMatch.tap()
        app.buttons["pins.view.grid"].firstMatch.tap()
        app.buttons["pins.view"].firstMatch.tap()
        app.buttons["pins.open-page"].firstMatch.tap()
        let page = app.collectionViews["pinned.list"]
        let pageTile = page.cells["pin-card-index.html"], file = page.cells["pin-card-export.csv"]
        XCTAssertTrue(pageTile.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 3)   // the page's picture draws
        let small = pageTile.frame

        pageTile.press(forDuration: 1)
        app.buttons["pins.edit"].firstMatch.tap()
        XCTAssertTrue(app.buttons["pins.done"].waitForExistence(timeout: 3), "Done replaces View As")
        XCTAssertTrue(pageTile.buttons["pin.unpin-badge"].exists, "each tile has its unpin badge")
        shot("pins-edit")

        // The corner handle, dragged down past three rows: Extra Large across the grid.
        let corner = pageTile.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.8))
        corner.press(forDuration: 0.05, thenDragTo: corner.withOffset(CGVector(dx: small.width * 1.2, dy: small.height * 2.4)))
        XCTAssertTrue(waitUntil(5) { pageTile.frame.width > small.width * 1.8 && pageTile.frame.height > small.height * 2.6 },
                      "Extra Large: \(pageTile.frame)")
        Thread.sleep(forTimeInterval: 12)   // the page draws again in its new shape
        shot("pins-edit-xl")
        XCTAssertTrue(pageTile.label.hasSuffix("Extra Large"), pageTile.label)

        // A tap arranges, it doesn't open.
        file.tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(page.exists && app.buttons["pins.done"].exists, "still editing on the Pinned page")

        // Back to Small from its corner (scrolled up so the corner is clear of the tab bar).
        page.swipeUp()
        Thread.sleep(forTimeInterval: 1)
        let big = pageTile.frame
        let corner2 = pageTile.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.93))
        corner2.press(forDuration: 0.05, thenDragTo: corner2.withOffset(CGVector(dx: -big.width * 0.55, dy: -big.height * 0.7)))
        XCTAssertTrue(waitUntil(5) { abs(pageTile.frame.width - small.width) < 2 && abs(pageTile.frame.height - small.height) < 2 },
                      "Small again: \(pageTile.frame)")

        file.buttons["pin.unpin-badge"].tap()
        XCTAssertTrue(waitUntil(5) { !file.exists }, "the badge unpins")
        app.buttons["pins.done"].tap()
        XCTAssertTrue(app.buttons["pins.view"].waitForExistence(timeout: 3), "Done ends it")
        XCTAssertFalse(pageTile.buttons["pin.unpin-badge"].exists)
        shot("pins-edit-done")
    }

    /// [pins] Pins the page (swiped), the picture (held) and the file (swiped) from Artifacts' list.
    @MainActor private func pinThree(in list: XCUIElement) {
        for label in ["index.html", "results.png", "export.csv"] {
            if label == "results.png" {
                // Pictures sit in the Images strip as tiles: hold one and choose Pin.
                let tile = list.cells["artifact-tile-\(label)"]
                XCTAssertTrue(scrollTo(tile, in: list), "\(label) tile")
                tile.press(forDuration: 1)
                app.buttons["artifact.pin"].firstMatch.tap()
            } else {
                let row = list.cells["artifact-row-\(label)"]
                XCTAssertTrue(scrollTo(row, in: list), "\(label) is listed")
                row.swipeRight()
                app.buttons["Pin"].firstMatch.tap()
            }
            list.swipeDown(); list.swipeDown()
            for _ in 0..<6 where !app.segmentedControls["artifacts.filter"].isHittable { list.swipeDown() }   // the largest text
            XCTAssertTrue(waitUntil(5) { list.cells["pin-card-\(label)"].exists }, "\(label) is on the shelf")
        }
    }

    /// [dashboard] Grid (tester feedback, 2026-11-01: "reduce or remove footer and stack these in a grid layout"): the
    /// Pinned page as two columns of picture tiles on a phone; a tile made Large spans both; names come off; a tile
    /// dragged onto another's place takes it; Artifacts' shelf shows the grid too.
    /// [tiles] A tile opened from Tiles shows whole: it fills its window (100vh, no scrolling), and the window ran up
    /// under the sheet's title bar, hiding the headline (owner 2026-11-03, the revenue tile).
    @MainActor func testArt15_TileOpensWhole() throws {
        let (arguments, shot) = pinsLook()
        app = launchSignedIn(arguments + ["-HQDebugResetPins", "YES"])
        try account.control("/__fixture/append", ["session_id": "s-report", "role": "assistant", "text": "MEDIA:/home/hermes/site/tile.html"])
        try account.control("/__fixture/tile-job", [:])
        openArtifacts()
        let list = app.collectionViews["artifacts.list"]
        let row = list.cells["artifact-row-tile.html"]
        XCTAssertTrue(waitUntil(15) { row.exists || self.scrollTo(row, in: list) }, "tile.html is listed")
        row.swipeRight()
        app.buttons["Pin"].firstMatch.tap()
        list.swipeDown(); list.swipeDown()
        app.buttons["pins.view"].firstMatch.tap()
        app.buttons["pins.open-page"].firstMatch.tap()
        let tile = app.collectionViews["pinned.list"].cells["pin-card-tile.html"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "the tile on Tiles")
        tile.tap()
        let headline = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Revenue $12K")).firstMatch
        let footer = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Updated Tue")).firstMatch
        XCTAssertTrue(headline.waitForExistence(timeout: 15), "the tile draws")
        Thread.sleep(forTimeInterval: 1)
        shot("tile-opened-whole")
        let bar = app.navigationBars.allElementsBoundByIndex.filter { $0.frame.minY < 200 }.map(\.frame.maxY).max() ?? 0
        XCTAssertGreaterThanOrEqual(headline.frame.minY, bar - 1, "the headline starts below the title bar")
        XCTAssertLessThanOrEqual(footer.frame.maxY, app.windows.firstMatch.frame.maxY - 20, "the footer ends above the home bar")

        // [tiles] Opened as the tile: its page's own name on top, the file and its updates under it (owner 2026-11-03).
        XCTAssertTrue(app.navigationBars.staticTexts["Revenue This Week"].firstMatch.exists, "the tile's name, not tile.html")
        let subtitle = app.navigationBars.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "tile.html")).firstMatch
        XCTAssertTrue(waitUntil(10) { subtitle.label.contains("updated 5 min ago") }, "the file and when it was updated: \(subtitle.label)")
        shot("tile-opened-named")
        let clock = app.buttons["tile.updates.button"].firstMatch
        XCTAssertTrue(clock.exists, "a clock button for its updates")
        clock.tap()
        let quarter = app.buttons["Every 15 Minutes"].firstMatch
        XCTAssertTrue(quarter.waitForExistence(timeout: 5), "how often, from the opened tile")
        shot("tile-updates-menu")
        quarter.tap()
        XCTAssertTrue(waitUntil(5) {
            self.requests().contains { $0.method == "PUT" && $0.path == "/api/cron/jobs/j-tile"
                && (($0.body?["updates"] as? [String: Any])?["schedule"] as? String) == "*/15 * * * *" }
        }, "the tile's job runs every 15 minutes")
        app.buttons["sheet.close"].firstMatch.tap()

        // The tile's name on Tiles, and the same Updates in its hold menu.
        XCTAssertTrue(app.staticTexts["Revenue This Week"].firstMatch.waitForExistence(timeout: 5), "the tile's name under it")
        shot("tile-named-on-tiles")
        tile.press(forDuration: 1)
        let updates = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Updates")).firstMatch
        XCTAssertTrue(updates.waitForExistence(timeout: 5), "Updates in the tile's menu")
        XCTAssertTrue(app.buttons["Rename…"].firstMatch.exists, "Rename… in the tile's menu")
        shot("tile-hold-menu")
        updates.tap()
        let pause = app.buttons["Pause Updates"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Every 15 Minutes"].firstMatch.isSelected || app.buttons["Every 15 Minutes"].firstMatch.exists)
        shot("tile-hold-updates")
        pause.tap()
        XCTAssertTrue(waitUntil(5) { self.requests().contains { $0.method == "POST" && $0.path == "/api/cron/jobs/j-tile/pause" } },
                      "Pause Updates pauses the tile's job")
    }

    /// [tiles] A tile's health and what updates it (owner 2026-11-03): a failed update marks the tile, its menu says why
    /// and which model runs it, a run that ends draws it again at once, and Change… asks its bot in a new chat.
    @MainActor func testArt16_TileHealthAndChange() throws {
        let (arguments, shot) = pinsLook()
        app = launchSignedIn(arguments + ["-HQDebugResetPins", "YES"])
        try account.control("/__fixture/append", ["session_id": "s-report", "role": "assistant", "text": "MEDIA:/home/hermes/site/tile.html"])
        try account.control("/__fixture/tile-job", ["status": "error", "error": "Stripe timed out\nTraceback (most recent call last)",
                                                    "model": "claude-sonnet-5"])
        openArtifacts()
        let list = app.collectionViews["artifacts.list"]
        let row = list.cells["artifact-row-tile.html"]
        XCTAssertTrue(waitUntil(15) { row.exists || self.scrollTo(row, in: list) }, "tile.html is listed")
        row.swipeRight()
        app.buttons["Pin"].firstMatch.tap()
        list.swipeDown(); list.swipeDown()
        app.buttons["pins.view"].firstMatch.tap()
        app.buttons["pins.open-page"].firstMatch.tap()
        let tile = app.collectionViews["pinned.list"].cells["pin-card-tile.html"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "the tile on Tiles")

        // The failed update marks the tile.
        XCTAssertTrue(waitUntil(15) { tile.label.contains("last update failed") }, "the tile says its update failed: \(tile.label)")
        Thread.sleep(forTimeInterval: 2)
        shot("tile-health-failed")

        // Its menu: the model that updates it, and why the last update failed.
        tile.press(forDuration: 1)
        let updates = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Updates")).firstMatch
        XCTAssertTrue(updates.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Change…"].firstMatch.exists, "Change… in the tile's menu")
        updates.tap()
        let model = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Sonnet 5")).firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 5), "the model that updates it")
        let failed = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Stripe timed out")).firstMatch
        XCTAssertTrue(failed.exists, "why the last update failed")
        XCTAssertFalse(failed.label.contains("Traceback"), "only the first line of the error")
        shot("tile-health-menu")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        Thread.sleep(forTimeInterval: 1)

        // The job runs and rewrites the page: the mark goes and the page is read again, without a pull.
        func reads() -> Int { requests().filter { $0.method == "GET" && ($0.query["path"] ?? "").hasSuffix("tile.html") }.count }
        let before = reads()
        try account.control("/__fixture/tile-ran", [:])
        XCTAssertTrue(waitUntil(80) { !tile.label.contains("failed") }, "the mark goes once the job has run: \(tile.label)")
        XCTAssertTrue(waitUntil(15) { reads() > before }, "the tile's page is read again after its job ran")
        Thread.sleep(forTimeInterval: 3)
        shot("tile-health-redrawn")

        // Change…: the Change Tile sheet (owner 2026-11-10: "greatly improved"): the tile as it is, a field that grows,
        // quick changes that add to the words; then the tile's bot works on it in a new chat, shown on the tile itself.
        tile.press(forDuration: 1)
        app.buttons["Change…"].firstMatch.tap()
        let sheet = app.otherElements["tile.change.sheet"].firstMatch
        let field = app.textViews["tile.change.field"].exists ? app.textViews["tile.change.field"] : app.textFields["tile.change.field"]
        XCTAssertTrue(waitUntil(5) { field.exists }, "Change… asks what to change")
        XCTAssertTrue(app.otherElements["tile.change.tile"].firstMatch.exists || app.staticTexts["Changed by Hermes"].firstMatch.exists
                      || sheet.exists, "the sheet shows the tile")
        XCTAssertFalse(app.buttons["tile.change.send"].firstMatch.isEnabled, "Change waits for words")
        Thread.sleep(forTimeInterval: 1)
        shot("tile-change-sheet")
        app.buttons["Bar Chart"].firstMatch.tap()
        app.buttons["Vs Last Month"].firstMatch.tap()
        XCTAssertTrue(waitUntil(3) { ((field.value as? String) ?? "") == "Make it a bar chart, compare with last month" },
                      "quick changes add to the words: \(field.value ?? "")")
        XCTAssertTrue(app.buttons["Bar Chart"].firstMatch.isSelected, "a quick change in the words is marked")
        shot("tile-change-ask")
        app.buttons["Vs Last Month"].firstMatch.tap()
        XCTAssertTrue(waitUntil(3) { ((field.value as? String) ?? "") == "Make it a bar chart" }, "a second tap takes it out")
        XCTAssertTrue(app.buttons["tile.change.send"].firstMatch.isEnabled, "Change once there are words")
        app.buttons["tile.change.send"].firstMatch.tap()
        let making = app.collectionViews["pinned.list"].cells["tile.making"]
        XCTAssertTrue(making.waitForExistence(timeout: 5), "the change shows on the page while the bot works")
        XCTAssertTrue(making.label.contains("Changing a tile"), making.label)
        XCTAssertTrue(waitUntil(5) { tile.label.contains("is changing it") }, "the tile itself says it's being changed: \(tile.label)")
        let state = (try? account.control("/__fixture/state")) ?? [:]
        let asks = ((state["rpc"] as? [[String: Any]]) ?? []).filter { ($0["method"] as? String) == "prompt.submit" }
            .compactMap { ($0["params"] as? [String: Any])?["text"] as? String }
        XCTAssertTrue(asks.contains { $0.hasPrefix("Change my Hermes HQ Dashboard tile /home/hermes/site/tile.html: Make it a bar chart") },
                      "the tile's bot is asked to change that file: \(asks)")
        Thread.sleep(forTimeInterval: 1)
        shot("tile-change-working")

        // While it works, the tile's menu says so and opens the chat rather than asking a second change.
        tile.press(forDuration: 1)
        XCTAssertTrue(app.buttons["tile.change.working"].firstMatch.waitForExistence(timeout: 5), "Changing… in the tile's menu")
        shot("tile-change-menu-working")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        Thread.sleep(forTimeInterval: 1)

        // The bot says it's done: the tile is drawn again and marked, and the page says so.
        try account.control("/__fixture/tile-ran", [:])
        try account.control("/__fixture/turn-end", ["match": "Change my Hermes HQ Dashboard tile",
                                                    "text": "Done: it's a bar chart now.\n\nMEDIA:/home/hermes/site/tile.html"])
        let changed = app.descendants(matching: .any).matching(identifier: "pages.hud").firstMatch
        XCTAssertTrue(changed.waitForExistence(timeout: 15), "the page says the tile changed")
        XCTAssertTrue(changed.label.hasSuffix("Changed"), changed.label)
        shot("tile-change-done")
        XCTAssertFalse(app.alerts.firstMatch.exists, "a change that's done asks nothing")
        XCTAssertTrue(waitUntil(5) { !making.exists }, "the making row goes when the change is done")
        XCTAssertFalse(tile.label.contains("is changing it"), "the tile no longer says it's being changed")
    }

    /// [live-tiles] Tester 2026-11-05 ("more interactive like home screen widgets"): a page with its own buttons runs
    /// live on Tiles. Its button asks its bot in the page's chat, a tap elsewhere opens it, holding still gives the menu,
    /// and `hq-tile-refresh` reads it again on its own.
    @MainActor func testArt18_LiveTile() throws {
        let (arguments, shot) = pinsLook()
        app = launchSignedIn(arguments + ["-HQDebugResetPins", "YES"])
        try account.control("/__fixture/append", ["session_id": "s-report", "role": "assistant", "text": "MEDIA:/home/hermes/site/live.html"])
        openArtifacts()
        let list = app.collectionViews["artifacts.list"]
        let row = list.cells["artifact-row-live.html"]
        XCTAssertTrue(waitUntil(15) { row.exists || self.scrollTo(row, in: list) }, "live.html is listed")
        row.swipeRight()
        app.buttons["Pin"].firstMatch.tap()
        list.swipeDown(); list.swipeDown()
        app.buttons["pins.view"].firstMatch.tap()
        app.buttons["pins.view.grid"].firstMatch.tap()
        app.buttons["pins.view"].firstMatch.tap()
        app.buttons["pins.open-page"].firstMatch.tap()
        let tile = app.collectionViews["pinned.list"].cells["pin-card-live.html"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "the tile on Tiles")
        Thread.sleep(forTimeInterval: 4)   // the page loads and fades in
        shot("live-tile")

        // Its button asks the bot, in the chat the page came from.
        func asks() -> [String] {
            let state = (try? account.control("/__fixture/state")) ?? [:]
            return ((state["rpc"] as? [[String: Any]]) ?? []).filter { ($0["method"] as? String) == "prompt.submit" }
                .compactMap { ($0["params"] as? [String: Any])?["text"] as? String }
        }
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        XCTAssertTrue(waitUntil(15) { asks().contains { $0.hasPrefix("Add one more sale") && $0.contains("live.html") } },
                      "the button's words go to the bot with the page's file: \(asks())")
        XCTAssertTrue(app.collectionViews["pinned.list"].exists, "a button does not open the page")
        let working = app.collectionViews["pinned.list"].cells["tile.making"]
        if working.waitForExistence(timeout: 4) { shot("live-tile-working") }

        // Holding still: the tile's menu, as on any tile.
        tile.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Rename…"].firstMatch.waitForExistence(timeout: 5), "the tile's menu on a hold")
        shot("live-tile-menu")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        Thread.sleep(forTimeInterval: 1)

        // It reads its page again on its own (every 30 s, asked by the page).
        func reads() -> Int { requests().filter { $0.method == "GET" && ($0.query["path"] ?? "").hasSuffix("live.html") }.count }
        let before = reads()
        try account.control("/__fixture/live-bump", [:])
        XCTAssertTrue(waitUntil(50) { reads() > before }, "the page is read again without a pull")
        Thread.sleep(forTimeInterval: 2)
        shot("live-tile-refreshed")

        // A tap off the button opens the page whole.
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        let opened = app.navigationBars.staticTexts["Sales Today"].firstMatch
        XCTAssertTrue(opened.waitForExistence(timeout: 8), "a tap off its button opens the page")
        shot("live-tile-opened")
    }

    /// [safer-deletes] Owner 2026-11-03 ("destructive actions sit next to everyday ones"): Remove takes an artifact off
    /// every list in every chat that names it, so it asks first, from a tile's menu, a row's menu and a row's swipe, and
    /// Cancel keeps it. A tile's Unpin is a plain item; Remove sits alone at the menu's end. Remove Artifact takes it off.
    @MainActor func testArt17_RemoveAsksFirst() throws {
        let (arguments, shot) = pinsLook()
        app = launchSignedIn(arguments + ["-HQDebugResetPins", "YES"])
        openArtifacts()
        let list = app.collectionViews["artifacts.list"]
        let row = list.cells["artifact-row-export.csv"]
        let tile = list.cells["pin-card-export.csv"]
        let confirm = app.buttons["Remove Artifact"].firstMatch

        // A tile's ⋯: Unpin, then Remove on its own; Remove asks, and Cancel keeps the tile.
        XCTAssertTrue(scrollTo(row, in: list), "export.csv is listed")
        row.swipeRight()
        app.buttons["Pin"].firstMatch.tap()
        list.swipeDown(); list.swipeDown()
        for _ in 0..<6 where !app.segmentedControls["artifacts.filter"].isHittable { list.swipeDown() }   // the largest text
        XCTAssertTrue(waitUntil(5) { tile.exists }, "export.csv is on the shelf")
        tile.buttons["Actions for Export"].tap()
        XCTAssertTrue(app.buttons["artifact.unpin"].firstMatch.waitForExistence(timeout: 3), "the tile's menu offers Unpin")
        XCTAssertTrue(app.buttons["artifact.remove"].firstMatch.exists, "and Remove")
        shot("remove-tile-menu")
        app.buttons["artifact.remove"].firstMatch.tap()
        let asked = confirm.waitForExistence(timeout: 3)
        shot("remove-tile-asked")
        XCTAssertTrue(asked, "the tile's Remove asks first")
        XCTAssertTrue(app.staticTexts["Remove “Export”?"].exists, "the question names the tile")
        dismissSheet()
        XCTAssertTrue(waitUntil(3) { !confirm.exists }, "Cancel closes the question")
        XCTAssertTrue(tile.exists, "Cancel keeps the tile")

        // A row's ⋯: the same question, naming the file.
        XCTAssertTrue(scrollTo(row, in: list), "export.csv is listed")
        row.buttons["Actions for export.csv"].tap()
        XCTAssertTrue(app.buttons["artifact.remove"].firstMatch.waitForExistence(timeout: 3), "the row's menu offers Remove")
        app.buttons["artifact.remove"].firstMatch.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "the row's Remove asks first")
        XCTAssertTrue(app.staticTexts["Remove “export.csv”?"].exists, "the question names the file")
        shot("remove-sheet")
        dismissSheet()
        XCTAssertTrue(waitUntil(3) { !confirm.exists }, "Cancel closes the question")
        XCTAssertTrue(row.exists, "Cancel keeps the artifact")

        // Its swipe (a full swipe asks too): Cancel keeps it; Remove Artifact takes it off the list and the shelf.
        row.swipeLeft()
        if !confirm.waitForExistence(timeout: 1) { app.buttons["Remove"].firstMatch.tap() }
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "the swipe asks first")
        shot("remove-swipe-sheet")
        dismissSheet()
        XCTAssertTrue(waitUntil(3) { !confirm.exists }, "Cancel closes the question")
        XCTAssertTrue(row.exists, "Cancel keeps the artifact")
        row.swipeLeft()
        if !confirm.waitForExistence(timeout: 1) { app.buttons["Remove"].firstMatch.tap() }
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "the swipe asks again")
        confirm.tap()
        let hud = app.descendants(matching: .any)["pages.hud"]
        XCTAssertTrue(waitUntil(5) { hud.exists && hud.label == "Removed" }, "Removed shows")
        XCTAssertTrue(waitUntil(5) { !row.exists }, "off the list")
        list.swipeDown(); list.swipeDown()
        XCTAssertFalse(tile.exists, "and off the shelf")
        shot("remove-done")

        // Nothing stays removed for the tests after this one.
        app.terminate()
        app = launchSignedIn(["-HQDebugResetPins", "YES"])
    }

    @MainActor func testArt10_PinsGrid() throws {
        let (arguments, shot) = pinsLook()
        app = launchSignedIn(arguments + ["-HQDebugResetPins", "YES"])
        openArtifacts()
        let list = app.collectionViews["artifacts.list"]
        pinThree(in: list)
        app.buttons["pins.view"].firstMatch.tap()
        app.buttons["pins.view.grid"].firstMatch.tap()
        XCTAssertTrue(list.cells["pin-card-index.html"].waitForExistence(timeout: 5), "the shelf as a grid")
        Thread.sleep(forTimeInterval: 4)   // the page's picture draws
        shot("pins-grid-shelf")

        app.buttons["pins.view"].firstMatch.tap()
        app.buttons["pins.open-page"].firstMatch.tap()
        let page = app.collectionViews["pinned.list"]
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        let pageTile = page.cells["pin-card-index.html"], picture = page.cells["pin-card-results.png"], file = page.cells["pin-card-export.csv"]
        XCTAssertTrue(pageTile.waitForExistence(timeout: 5) && picture.exists && file.exists)
        // Newest first: the file, the picture, then the page; two across.
        XCTAssertEqual(file.frame.minY, picture.frame.minY, accuracy: 1, "two tiles across")
        XCTAssertLessThan(file.frame.minX, picture.frame.minX)
        XCTAssertGreaterThan(pageTile.frame.minY, file.frame.maxY, "the third starts the next row")
        XCTAssertEqual(file.frame.width, picture.frame.width, accuracy: 1)
        XCTAssertLessThan(file.frame.width, page.frame.width / 2)
        Thread.sleep(forTimeInterval: 2)
        shot("pins-grid")

        // Size › Large: the page spans both columns, twice as tall.
        let small = pageTile.frame
        pageTile.press(forDuration: 1)
        XCTAssertTrue(app.buttons["pin.size.large"].firstMatch.waitForExistence(timeout: 3), "the sizes lead the menu")
        shot("pins-grid-size-menu")
        app.buttons["pin.size.large"].firstMatch.tap()
        XCTAssertTrue(waitUntil(5) { pageTile.frame.width > small.width * 1.8 }, "Large spans two columns: \(pageTile.frame)")
        XCTAssertGreaterThan(pageTile.frame.height, small.height * 1.8, "and two rows")
        Thread.sleep(forTimeInterval: 2)
        shot("pins-grid-large")

        // Show Names off: the tiles alone, shorter by the name's line.
        let named = file.frame.height
        app.buttons["pins.view"].firstMatch.tap()
        app.buttons["pins.view.names"].firstMatch.tap()
        XCTAssertTrue(waitUntil(5) { file.frame.height < named - 8 }, "no name under the tile: \(file.frame.height) vs \(named)")
        shot("pins-grid-bare")

        // Dragged onto the picture's place, the file follows it (slowly, held over the place: a quick drag can end
        // before the grid opens a gap).
        file.press(forDuration: 1, thenDragTo: picture, withVelocity: .slow, thenHoldForDuration: 0.6)
        XCTAssertTrue(waitUntil(5) { file.frame.minX > picture.frame.minX }, "the file took the picture's place")
        shot("pins-grid-moved")

        // Back to Cards (with names) for the other tests.
        app.buttons["pins.view"].firstMatch.tap()
        app.buttons["pins.view.names"].firstMatch.tap()
        app.buttons["pins.view"].firstMatch.tap()
        app.buttons["pins.view.cards"].firstMatch.tap()
        let card = page.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'pin-card-'")).firstMatch
        XCTAssertTrue(waitUntil(5) { card.frame.width > page.frame.width * 0.8 }, "Cards: one column")
    }

    /// [pins] Bot Info › Artifacts: Deploys' page as a picture, its newest files as rows, and All Artifacts opening its
    /// artifacts alone (none of Research's) inside the sheet. [tabs] Each tab holds its own groups.
    /// HQN_PINS_LOOK: the pins tests in Desktop Look light or dark, or at the largest text (screens named pins-<look>-…).
    @MainActor private func pinsLook() -> ([String], (String) -> Void) {
        let look = ProcessInfo.processInfo.environment["HQN_PINS_LOOK"] ?? ""
        let arguments: [String] = switch look {
        case "desktop-light": ["-HQDebugDesktopLook", "YES", "-HQDebugAppearance", "light"]
        case "desktop-dark": ["-HQDebugDesktopLook", "YES", "-HQDebugAppearance", "dark"]
        case "xl": ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        default: []
        }
        return (arguments, { name in self.shot(look.isEmpty ? name : name.replacingOccurrences(of: "pins-", with: "pins-\(look)-")) })
    }

    @MainActor func testArt9_BotInfoArtifacts() throws {
        let (arguments, shot) = pinsLook()
        app = launchSignedIn(arguments)
        openArtifacts()   // the index the group reads
        tab("Bots")
        let tile = app.cells["bot-tile-deploys"], row = app.cells["bot-row-deploys"]
        XCTAssertTrue(waitUntil(10) { tile.exists || row.exists }, "Deploys is listed")
        (tile.exists ? tile : row).press(forDuration: 1)
        app.buttons["Bot Info"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["bot-info.name"].waitForExistence(timeout: 5))
        // [tabs] About first: the description is there; Brain, Conversations and Organize are not.
        shot("pins-bot-info-about")
        XCTAssertTrue(app.staticTexts["bot-info.about"].waitForExistence(timeout: 5), "About holds the description")
        XCTAssertFalse(app.buttons["bot-info.default-model"].exists, "Brain is its own tab")
        XCTAssertFalse(app.buttons["bot-info.bot-chat"].exists, "Conversations is on Chats")
        XCTAssertFalse(app.buttons["bot-info.duplicate"].exists, "Organize is on Settings")
        app.botInfoTab("Brain")   // [page-tabs]
        shot("pins-bot-info-brain")
        XCTAssertTrue(app.botInfoReveal(app.buttons["bot-info.default-model"]), "Brain holds Default Model")
        XCTAssertTrue(app.botInfoReveal(app.buttons["bot-info.skills"]), "and Skills")
        app.botInfoTab("Chats")
        shot("pins-bot-info-chats")
        XCTAssertTrue(app.botInfoReveal(app.buttons["bot-info.bot-chat"]), "Chats holds Conversations")
        XCTAssertFalse(app.buttons["bot-info.default-model"].exists)
        app.botInfoTab("Settings")
        shot("pins-bot-info-settings")
        XCTAssertTrue(app.botInfoReveal(app.buttons["bot-info.mute"]), "Settings holds Notifications")
        XCTAssertTrue(app.botInfoReveal(app.buttons["bot-info.duplicate"]), "and Organize")
        app.botInfoTab("Artifacts")
        XCTAssertTrue(app.botInfoReveal(app.buttons["bot-info.artifact-tile"].firstMatch), "the page as a picture")
        let all = app.buttons["bot-info.artifacts.all"]
        XCTAssertTrue(app.botInfoReveal(all), "All Artifacts")
        let rows = app.buttons.matching(identifier: "bot-info.artifact-row")
        if arguments.isEmpty || arguments.contains("-HQDebugDesktopLook") {
            XCTAssertEqual(rows.count, 4, "the fixture's four files and links")
        } else {
            XCTAssertGreaterThan(rows.count, 0, "files and links (the largest text draws only those on screen)")
        }
        Thread.sleep(forTimeInterval: 3)   // the page's picture draws
        shot("pins-bot-info")
        all.tap()
        let list = app.collectionViews["artifacts.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(10) { list.cells["artifact-row-report.pdf"].exists }, "Deploys' files")
        XCTAssertFalse(list.cells["artifact-row-summary.md"].exists, "none of Research's")
        XCTAssertFalse(app.buttons["pages.scope"].exists, "one bot: no scope menu")
        shot("pins-bot-info-all")
    }

    // MARK: More checks

    /// P-NAV-4: a run's chat pushes inside Jobs; Back returns to the job.
    @MainActor func testNav4_RunChatPushesInsideJobs() throws {
        app = launchSignedIn()
        tab("Jobs")
        let row = jobRow("inbox|j-triage")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.staticTexts["job.title"].waitForExistence(timeout: 5))
        let run = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'job.run-row.cron_j-triage_'")).firstMatch
        for _ in 0..<5 where !(run.exists && run.isHittable) { app.swipeUp() }
        XCTAssertTrue(run.waitForExistence(timeout: 8), "the run history lists the runs")
        run.tap()
        let table = app.tables["chat.table"]
        XCTAssertTrue(table.waitForExistence(timeout: 8), "the run's chat opens")
        let reply = table.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Drafted 3 replies")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 8), "its messages show")
        shot("job-run-chat")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(run.waitForExistence(timeout: 5), "Back returns to the job's page")
        XCTAssertTrue(app.tabBars.buttons["Jobs"].isSelected, "still the Jobs tab")
    }

    /// P-JOB-11: on a read-only gateway Run, Pause and Delete say so and send nothing.
    @MainActor func testJob11_ReadOnlySendsNothing() throws {
        app = launchSignedIn(["-HQPagesReadOnly", "YES"])
        tab("Jobs")
        let row = jobRow("inbox|j-triage")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let hud = app.descendants(matching: .any)["pages.hud"]
        holdMenu(of: row)
        app.buttons["Run Now"].firstMatch.tap()
        XCTAssertTrue(waitUntil(4) { hud.exists && hud.label == "Changes are off for this gateway." })
        row.swipeRight()
        app.buttons["Pause"].firstMatch.tap()
        row.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(app.alerts["Delete Job?"].exists, "no confirmation: nothing would be sent")
        let writes = requests().filter { $0.method != "GET" && !$0.path.hasSuffix("/hermes-hq-push/logs") }
            .map { $0.method + " " + $0.path }
        XCTAssertTrue(writes.isEmpty, "no write went out (sent: \(writes))")
    }

    /// P-ART-2: a second visit inside a minute reads no transcript; a changed session is the only one read again.
    @MainActor func testArt2_OnlyChangedSessionsAreReadAgain() throws {
        app = launchSignedIn()
        openArtifacts()
        let messages = { self.requests().filter { $0.path.hasSuffix("/messages") }.map(\.path) }
        XCTAssertTrue(waitUntil(45) { let a = messages(); Thread.sleep(forTimeInterval: 1.5); return a == messages() && !a.isEmpty }, "the pass settles")
        let first = messages().count
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.cells["more-row-artifacts"].tap()
        XCTAssertTrue(app.collectionViews["artifacts.list"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(messages().count, first, "a visit within a minute reads nothing")
        try account.control("/__fixture/append", ["session_id": "s-reading", "role": "assistant",
                                                   "text": "One more source: https://example.org/papers/tool-use"])
        let list = app.collectionViews["artifacts.list"]
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        XCTAssertTrue(waitUntil(15) { messages().count > first }, "pull to refresh reads again")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(Set(messages().dropFirst(first)), ["/api/sessions/s-reading/messages"], "only the changed session")
    }

    /// P-ART-3: scope Finance lists only Finance's chats; its empty Links say where they looked.
    @MainActor func testArt3_ScopeOneBot() throws {
        app = launchSignedIn()
        openArtifacts()
        let mark = requests().count
        app.navigationBars.buttons["pages.scope"].tap()
        menuItem("Finance").tap()
        XCTAssertTrue(waitUntil(10) { self.requests().dropFirst(mark).contains { $0.path == "/api/profiles/sessions" } })
        let listed = requests().dropFirst(mark).filter { $0.path == "/api/profiles/sessions" }.compactMap { $0.query["profile"] }
        XCTAssertEqual(Set(listed), ["finance"], "only Finance's chats are listed")
        app.segmentedControls["artifacts.filter"].buttons["Links"].tap()
        XCTAssertTrue(app.staticTexts["No Links in Finance’s Recent Chats"].waitForExistence(timeout: 10))
        shot("artifacts-empty-links")
        app.segmentedControls["artifacts.filter"].buttons["All"].tap()
        app.navigationBars.buttons["pages.scope"].tap()
        menuItem("All Bots").tap()
    }

    /// P-ART-4: an image tile opens the viewer through read-data-url with its session and profile; swipe down closes.
    @MainActor func testArt4_ImageViewer() throws {
        app = launchSignedIn()
        openArtifacts()
        let tile = app.cells["artifact-tile-results.png"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        tile.tap()
        let image = app.images["artifact.image.view"]
        XCTAssertTrue(image.waitForExistence(timeout: 8) || app.otherElements["artifact.image"].waitForExistence(timeout: 2))
        Thread.sleep(forTimeInterval: 1)
        shot("artifact-image-viewer")
        let read = requests().first { $0.path == "/api/fs/read-data-url" && ($0.query["path"] ?? "").hasSuffix("results.png") }
        XCTAssertEqual(read?.query["session_id"], "s-reading")
        XCTAssertEqual(read?.query["profile"], "research")
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(app.collectionViews["artifacts.list"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(5) { !app.otherElements["artifact.image"].exists }, "swipe down closes")
    }

    /// Owner 2026-11-01 ("Every time I open the artifacts page, it seems like it has to like reload and repopulate
    /// everything"): the page opened again shows its picture at once and reads it no more; after a relaunch the picture
    /// comes from the phone's copy, with no read either. The fixture dates its chats from its own start, so an index
    /// left by an earlier run sees every chat changed: the first visit and one return settle that before counting.
    @MainActor func testArt10_PicturesAreThereOnReturnAndRelaunch() throws {
        app = launchSignedIn()
        openArtifacts()
        let reads = { self.requests().filter { $0.path == "/api/fs/read-data-url" && ($0.query["path"] ?? "").hasSuffix("results.png") }.count }
        let messages = { self.requests().filter { $0.path.hasSuffix("/messages") }.count }
        XCTAssertTrue(app.cells["artifact-tile-results.png"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(45) { let a = messages(); Thread.sleep(forTimeInterval: 1.5); return a == messages() }, "the pass settles")
        shot("artifacts-instant-first")
        back()
        app.cells["more-row-artifacts"].tap()
        XCTAssertTrue(app.cells["artifact-tile-results.png"].waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 2)
        let settled = reads()
        XCTAssertGreaterThan(settled, 0, "the picture was read")
        back()
        app.cells["more-row-artifacts"].tap()
        XCTAssertTrue(app.cells["artifact-tile-results.png"].waitForExistence(timeout: 3))
        shot("artifacts-instant-return")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(reads(), settled, "the page opened again reads no picture")
        app.terminate()
        app = launchSignedIn()
        openArtifacts()
        XCTAssertTrue(app.cells["artifact-tile-results.png"].waitForExistence(timeout: 3))
        shot("artifacts-instant-relaunch")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(reads(), settled, "after a relaunch the picture comes from the phone")
    }

    /// P-JOB-6 (slow, HQN_PAGES_SLOW=1): a trigger answering after 130 s says "Still Running on Your Gateway", no error.
    @MainActor func testJob6_SlowRunIsStillRunning() throws {
        guard ProcessInfo.processInfo.environment["HQN_PAGES_SLOW"] == "1" else { throw XCTSkip("Set HQN_PAGES_SLOW=1 (takes over two minutes).") }
        try account.control("/__fixture/fail", ["method": "POST", "path": "/api/cron/jobs/j-triage/trigger", "delay": 130])
        app = launchSignedIn()
        tab("Jobs")
        let row = jobRow("inbox|j-triage")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        holdMenu(of: row)
        app.buttons["Run Now"].firstMatch.tap()
        app.alerts.firstMatch.buttons["Run"].tap()
        let hud = app.descendants(matching: .any)["pages.hud"]
        XCTAssertTrue(waitUntil(140) { hud.exists && hud.label == "Still Running on Your Gateway" }, "still running after 120 s")
        XCTAssertFalse(app.alerts["Couldn’t Run Job"].exists, "not an error")
    }

    // MARK: - Helpers

    struct Request { var method: String; var path: String; var query: [String: String]; var body: [String: Any]? }

    func requests() -> [Request] {
        let state = (try? account.control("/__fixture/state")) ?? [:]
        return ((state["rest"] as? [[String: Any]]) ?? []).map { row in
            var query: [String: String] = [:]
            for (key, value) in (row["query"] as? [String: Any]) ?? [:] { query[key] = "\(value)" }
            return Request(method: row["method"] as? String ?? "", path: row["path"] as? String ?? "", query: query, body: row["body"] as? [String: Any])
        }
    }

    /// [offline] Every request that is not a read, leaving out the app's own diagnostic log upload.
    func userWrites() -> [Request] {
        requests().filter { $0.method != "GET" && $0.path != "/api/plugins/hermes-hq-push/logs" }
    }

    @MainActor func jobRow(_ key: String) -> XCUIElement { app.cells["job-row-\(key)"] }

    /// The bar's Back button.
    @MainActor func back() { app.navigationBars.buttons.element(boundBy: 0).tap() }

    /// More › Settings › Appearance › Tabs › Kanban Tab › `choice`, then back to Bots. [kanban-tab-one] The picker's one
    /// home (it was a Settings › Bots & Tools row).
    @MainActor func setKanbanTab(_ choice: String) {
        // More › Settings (the Bots bar has no Settings button, as on the web); a second tap on More pops to its root.
        tab("More")
        let settingsRow = app.cells["more-row-settings"]
        if !(settingsRow.waitForExistence(timeout: 2) && settingsRow.isHittable) { app.tabBars.buttons["More"].tap() }
        XCTAssertTrue(settingsRow.waitForExistence(timeout: 5))
        settingsRow.tap()
        XCTAssertTrue(app.buttons["settings.gateway-card"].waitForExistence(timeout: 5))
        let tabs = app.buttons["settings.tab-order"]
        for _ in 0..<6 where !(tabs.exists && tabs.isHittable) { app.collectionViews.firstMatch.swipeUp() }
        tabs.tap()
        XCTAssertTrue(app.navigationBars["Tabs"].waitForExistence(timeout: 5), "Settings › Appearance › Tabs")
        let row = app.buttons["settings.kanban"]
        for _ in 0..<4 where !(row.exists && row.isHittable) { app.collectionViews.firstMatch.swipeUp() }
        row.tap()
        let option = app.buttons[choice].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 3), "Kanban Tab › \(choice)")
        option.tap()
        Thread.sleep(forTimeInterval: 0.8)
        // More back on its root (a tap on the selected tab pops its stack), then Bots.
        app.tabBars.buttons["More"].tap()
        _ = app.collectionViews["more.list"].waitForExistence(timeout: 3)
        tab("Bots")
        Thread.sleep(forTimeInterval: 0.8)
    }

    /// Verify round 2: Kanban Tab › Off while More › Artifacts is open makes tab 3 an Artifacts page; the copy on More's
    /// stack goes (one page per store: the one left behind stopped updating), and the page on show takes a pull.
    @MainActor func testArt8_KanbanTabChangeLeavesOnePagePerStore() throws {
        app = launchSignedIn()
        XCTAssertTrue(waitUntil(10) { self.app.tabBars.buttons["Kanban"].exists })
        openArtifacts()
        setKanbanTab("Off")
        XCTAssertTrue(waitUntil(5) { self.app.tabBars.buttons["Artifacts"].exists }, "tab 3 is Artifacts")
        tab("More")
        XCTAssertTrue(app.collectionViews["more.list"].waitForExistence(timeout: 5), "More is back on its root")
        XCTAssertFalse(app.collectionViews["artifacts.list"].exists, "no second Artifacts page on More's stack")
        tab("Artifacts")
        let list = app.collectionViews["artifacts.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        try account.control("/__fixture/append", ["session_id": "s-reading", "role": "assistant",
                                                  "text": "Also see https://example.org/papers/fresh-paper today."])
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        let fresh = app.cells.matching(NSPredicate(format: "identifier == 'artifact-row-Fresh Paper'")).firstMatch
        XCTAssertTrue(fresh.waitForExistence(timeout: 15), "the page on show takes the pull")
        shot("artifacts-tab-after-kanban-off")
        setKanbanTab("Automatic")
        XCTAssertTrue(waitUntil(5) { self.app.tabBars.buttons["Kanban"].exists }, "Kanban is back on tab 3")
    }

    /// [kanban-tab-one] UX study #194's one-time tip, when Automatic gives Kanban the tab Artifacts had, names the real
    /// path to change it (it said "Settings › Kanban Tab", a path that never was): Settings › Appearance › Tabs. The
    /// first launch sees no Kanban API (a 404), so the tab is Artifacts; the next finds a board with tasks.
    @MainActor func testArt18_KanbanTipNamesTheTabsPage() throws {
        try account.control("/__fixture/fail", ["method": "GET", "path": "/api/plugins/kanban/boards", "status": 404, "count": 20])
        app = launchSignedIn(["-HQDebugForgetKanbanTip", "YES", "-hqn.inAppTips", "YES"])
        XCTAssertTrue(waitUntil(15) { self.app.tabBars.buttons["Artifacts"].exists && !self.app.tabBars.buttons["Kanban"].exists },
                      "no Kanban API: Artifacts has the tab")
        Thread.sleep(forTimeInterval: 0.5)
        app.terminate()
        try account.control("/__fixture/reset", [:])   // the Kanban API answers again, with tasks
        app = launchSignedIn(["-HQDebugForgetKanbanTip", "YES", "-hqn.inAppTips", "YES"])
        let label = app.staticTexts["Kanban Took Artifacts’ Tab"]
        XCTAssertTrue(label.waitForExistence(timeout: 15), "the tip says Kanban took the tab")
        let detail = app.staticTexts["Artifacts is in More › Workspace. Change this in Settings › Appearance › Tabs."]
        XCTAssertTrue(detail.exists, "the tip names Settings › Appearance › Tabs")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Settings › Kanban Tab'")).firstMatch.exists)
        XCTAssertTrue(app.tabBars.buttons["Kanban"].exists, "Kanban has the tab")
        shot("kanban-tip")
        // How Kanban Works names the same path (it said Settings › Bots & Tools).
        tab("Kanban")
        let about = app.navigationBars.buttons["How Kanban Works"]
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        about.tap()
        let line = app.staticTexts["kanban.about.tab-setting"]
        for _ in 0..<6 where !(line.exists && line.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        XCTAssertEqual(line.label, "Kanban can have its own tab in place of Artifacts, which then moves to More. To choose, use Kanban Tab in Settings › Appearance › Tabs.")
        shot("kanban-about-tab-setting")
    }

    /// Closes a presented Quick Look (its close button).
    @MainActor func closeQuickLook() {
        let close = app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"].firstMatch
        if close.waitForExistence(timeout: 3) { close.tap() } else { app.swipeDown(velocity: .fast) }
    }

    /// A seeded task's row (the fixture's ids are "t_" + the first 8 hex of SHA-256 of the title).
    @MainActor func taskRow(_ title: String) -> XCUIElement {
        let hash = SHA256.hash(data: Data(title.utf8)).map { String(format: "%02x", $0) }.joined()
        return app.cells["kanban-task-t_\(hash.prefix(8))"]
    }

    /// A row by the words it shows (a task made during the test).
    @MainActor func taskRow(showing title: String) -> XCUIElement {
        app.cells.containing(NSPredicate(format: "label BEGINSWITH %@", title)).matching(NSPredicate(format: "identifier BEGINSWITH 'kanban-task-'")).firstMatch
    }

    @MainActor func text(_ fragment: String, in element: XCUIElement) -> XCUIElement {
        element.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    /// Two pictures of the element a moment apart differ (three tries): something in it is moving.
    @MainActor func turning(_ element: XCUIElement) -> Bool {
        for _ in 0..<3 {
            let before = element.screenshot().pngRepresentation
            Thread.sleep(forTimeInterval: 0.13)
            if element.screenshot().pngRepresentation != before { return true }
        }
        return false
    }

    /// A job row's menu (Run Now, Pause/Resume, Edit, Delete Job). Rows have had no ⋯ button since improve-24 #15; a long
    /// press holds the same menu.
    @MainActor func holdMenu(of row: XCUIElement) {
        row.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Run Now"].firstMatch.waitForExistence(timeout: 3), "the row's menu opens")
    }

    /// A menu item by its title (an item with a subtitle reads "Title, subtitle").
    @MainActor func menuItem(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")).firstMatch
    }

    /// A status chip, scrolled into view in the chips row.
    @MainActor func chip(_ status: String) -> XCUIElement {
        let chip = app.cells["kanban.chip.\(status)"]
        let first = app.cells["kanban.chip.blocked"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        for _ in 0..<4 where !(chip.exists && chip.isHittable) {
            first.exists ? first.swipeLeft() : app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'kanban.chip.'")).firstMatch.swipeLeft()
        }
        return chip
    }

    /// Cancels an action sheet (a popover-style sheet has no Cancel button: tap outside it).
    @MainActor func dismissSheet() {
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists && cancel.isHittable { cancel.tap(); return }
        let dismiss = app.otherElements["PopoverDismissRegion"].firstMatch
        if dismiss.exists { dismiss.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap() }
    }

    /// Selects a tab; a tap the app didn't take (seen on a loaded machine right after sign-in) is tried once more.
    @MainActor func tab(_ name: String) {
        let button = tabButton(name)
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the \(name) tab")
        // iOS 26 shrinks the tab bar while a list scrolls down (far more at the largest text): scrolling up brings it back.
        for _ in 0..<3 where !button.isHittable { app.collectionViews.firstMatch.swipeDown(); _ = button.waitForExistence(timeout: 1) }
        button.tap()
        guard app.tabBars.buttons[name].exists else { return }   // the Desktop Look's bar says nothing of selection
        if !waitUntil(2, { button.isSelected }) { button.tap() }
        XCTAssertTrue(waitUntil(3, { button.isSelected }), "the \(name) tab is selected")
    }

    /// A tab by its id ("tab-bots"): the system tab bar's button, or the Desktop Look's own bar's (UITests/TabButtons.swift).
    @MainActor func tabButton(_ name: String, in app: XCUIApplication? = nil) -> XCUIElement {
        (app ?? self.app).tabButton(id: "tab-\(name.lowercased())", label: name)
    }

    @MainActor func openArtifacts() {
        tab("More")
        let row = app.cells["more-row-artifacts"]
        if !row.waitForExistence(timeout: 3) { tab("More") }
        // At the largest text sizes the row is further down than one screen (and isn't made until it scrolls in).
        if row.waitForExistence(timeout: 3) || scrollTo(row, in: app.collectionViews.firstMatch) { row.tap() } else { shot("debug-more-without-artifacts") }
        if !app.collectionViews["artifacts.list"].waitForExistence(timeout: 3), row.exists, row.isHittable { row.tap() }
        XCTAssertTrue(app.collectionViews["artifacts.list"].waitForExistence(timeout: 5))
        let list = app.collectionViews["artifacts.list"], summary = app.cells["artifact-row-summary.md"]
        // At the largest text sizes the row is below the first screen: look down the list, then come back to the top.
        XCTAssertTrue(waitUntil(20) { summary.exists || list.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'artifact-row-'")).firstMatch.exists },
                      "the index pass lands")
        if !summary.exists {
            XCTAssertTrue(scrollTo(summary, in: list), "the index pass lands")
            for _ in 0..<8 where !app.segmentedControls["artifacts.filter"].isHittable { list.swipeDown() }
        }
    }

    @MainActor func scrollTo(_ element: XCUIElement, in list: XCUIElement) -> Bool {
        // [safer-deletes] Hittable isn't enough: a row half under the floating tab bar is hittable, and a swipe or tap at
        // its middle lands on the bar. Up until it is clear of the bar too.
        let bar = app.tabBars.firstMatch
        for _ in 0..<8 {
            if element.exists && element.isHittable && (!bar.exists || element.frame.maxY <= bar.frame.minY) { return true }
            list.swipeUp()
        }
        return element.exists
    }

    /// The first launch of a run forgets saved sign-ins: a session saved against an earlier fixture process ends a few
    /// seconds after launch (the fixture keeps sessions in memory), which would pull the tabs away mid-test.
    nonisolated(unsafe) static var freshThisRun = false

    @MainActor func launchSignedIn(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HQPagesHUDSeconds", "6", "-HQDebugUndoSeconds", "6"] + arguments
        if !Self.freshThisRun {
            Self.freshThisRun = true
            app.launchArguments += ["-HQDebugResetAccounts", "YES"]
        }
        app.launch()
        let bots = tabButton("Bots", in: app)
        let form = app.textFields["sign-in-address"]
        _ = waitUntil(15, app: app) { bots.exists || form.exists }
        if !bots.exists && form.exists { signIn(app) }
        XCTAssertTrue(bots.waitForExistence(timeout: 15), "signed in")
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
        // Return moves to the password, and Return there signs in: at the largest text sizes the keyboard covers the
        // password box and the button, and a tap on either lands on the keyboard.
        username.typeText(account.username + "\n")
        let password = app.secureTextFields["sign-in-password"]
        password.typeText(account.password + "\n")
        // The save-password sheet can take a few seconds to rise on a loaded machine.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let notNow = [app.buttons["Not Now"], springboard.buttons["Not Now"]]
        if waitUntil(5, app: app, { notNow.contains { $0.exists } }), let candidate = notNow.first(where: { $0.exists }) {
            candidate.tap()
        }
    }

    /// A screenshot kept in the result bundle, and written to TEST_RUNNER_HQN_SHOTS_DIR when set.
    @MainActor func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["HQN_SHOTS_DIR"], !dir.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("e2e-\(name).png"))
        }
    }

    func measured(_ text: String) { XCTContext.runActivity(named: "[measure] " + text) { _ in } }

    @MainActor @discardableResult
    func waitUntil(_ timeout: TimeInterval, app: XCUIApplication? = nil, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        return condition()
    }
}

/// P-NAV-1 on the fixture started with `--no-kanban` (scripts/e2e-pages.sh runs it against :9737): Artifacts holds
/// tab 3 and More has no Kanban row.
final class PagesNoKanbanTests: XCTestCase {
    @MainActor func testNav1_ArtifactsHoldsTabThreeWithoutKanban() throws {
        guard ProcessInfo.processInfo.environment["HQN_UI_NO_KANBAN"] == "1" else {
            throw XCTSkip("Runs against the --no-kanban fixture (scripts/e2e-pages.sh sets HQN_UI_NO_KANBAN).")
        }
        let account = try FixtureAccount.load()
        let app = XCUIApplication()
        app.launchArguments = ["-HQDebugResetAccounts", "YES"]
        app.launch()
        let pages = PagesTests()
        pages.account = account
        pages.signIn(app)
        XCTAssertTrue(app.tabBars.buttons["Bots"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.tabBars.buttons["Artifacts"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(app.tabBars.buttons["Kanban"].exists)
        if app.tabBars.buttons["More"].exists {
            // Other pages' rows may fill More; never a Kanban row without the plugin.
            app.tabBars.buttons["More"].tap()
            XCTAssertFalse(app.cells["more-row-kanban"].waitForExistence(timeout: 2), "no Kanban row")
        }
        pages.app = app
        pages.tab("Artifacts")   // a tap during the sign-in sheet's exit can be lost: tried once more
        XCTAssertTrue(app.collectionViews["artifacts.list"].waitForExistence(timeout: 5))
        pages.tab("Bots")
    }
}
