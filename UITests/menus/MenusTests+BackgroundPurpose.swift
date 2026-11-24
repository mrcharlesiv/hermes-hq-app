// [background] A Background row says what the job is FOR (owner 2026-11-22: "claude -p 'Read .goals-bri…" over "No output
// yet" for 1h 22m — "Is this what you thought would count as success?"). Three jobs against the menus fixture: one the
// bot introduced in its own words, a coding agent it didn't, and one named by a # comment that writes to a log.
// Run with HQN_MENUS_ONLY=test33b_BackgroundRowsSayWhatTheJobIsFor scripts/e2e-menus.sh <sim>.

import XCTest

extension MenusTests {
    @MainActor func test33b_BackgroundRowsSayWhatTheJobIsFor() throws {
        let (account, app) = try start()
        let worker = "cd ~/Projects/app-wt/goals-2 && claude -p 'Read .goals-brief.md in this directory and carry it out completely, then write artifacts/goals/REPORT-6.md. Never commit, never push.' --permission-mode acceptEdits --max-turns 200"
        let agent = "cd ~/Projects/app-wt/site && codex exec --full-auto 'Fix the flaky checkout test and explain the cause in NOTES.md'"
        let archive = "# Archiving the Mac build\ncd ~/Projects/app-wt/ship-mac && BUILD=42 python3 scripts/ship.py archive > /tmp/evidence/archive.log 2>&1"
        try account.control("/__menus/mode", [
            "jobTurns": [["text": "Here are the four screens.\n\nI'm starting a worker on the **four goal set-up fixes** from your review.", "command": worker]],
            "processes": [
                ["session_id": "proc_w", "command": worker, "cwd": "/Users/me/Projects/app-wt/goals-2", "status": "running", "uptime_seconds": 4920, "output_tail": ""],
                ["session_id": "proc_c", "command": agent, "status": "running", "uptime_seconds": 610, "output_tail": ""],
                ["session_id": "proc_a", "command": archive, "status": "running", "uptime_seconds": 1500, "output_tail": ""],
            ],
        ])
        openBotChat(app)
        let chip = app.activityCategory("background")
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        chip.tap()

        let titles = app.descendants(matching: .any).matching(identifier: "chat.background.title")
        XCTAssertTrue(titles.firstMatch.waitForExistence(timeout: 5))
        let names = (0..<titles.count).map { titles.element(boundBy: $0).label }
        XCTAssertTrue(names.contains { $0.hasPrefix("The four goal set-up fixes from your review, running") }, "\(names)")
        XCTAssertTrue(names.contains { $0.hasPrefix("Fix the flaky checkout test and explain the cause in NOTES.md, running") }, "\(names)")
        XCTAssertTrue(names.contains { $0.hasPrefix("Archiving the Mac build, running") }, "\(names)")

        let details = app.descendants(matching: .any).matching(identifier: "chat.background.detail")
        let detailWords = (0..<details.count).map { details.element(boundBy: $0).label }
        XCTAssertTrue(detailWords.contains("Claude Code · goals-2"), "\(detailWords)")
        XCTAssertTrue(detailWords.contains("Codex · site"), "\(detailWords)")
        XCTAssertTrue(detailWords.contains("python3 scripts/ship.py archive · ship-mac"), "\(detailWords)")

        let outputs = app.descendants(matching: .any).matching(identifier: "chat.background.output")
        let quiet = (0..<outputs.count).map { outputs.element(boundBy: $0).label }
        XCTAssertFalse(quiet.contains("No output yet"), "\(quiet)")
        XCTAssertTrue(quiet.contains("Quiet until it's done"), "\(quiet)")
        XCTAssertTrue(quiet.contains("Writing to archive.log"), "\(quiet)")
        shot(app, "background-purpose")
    }

    @MainActor func test33c_BackgroundDetailShowsLiveOutputAndCommand() throws {
        let (account, app) = try start()
        let script = """
        # Shipping the beta invite to public TestFlight
        cd ~/Projects/app-wt/release-job && python3 - <<'PY'
        import time
        while True:
            print("checking")
            time.sleep(300)
        PY
        """
        let lines = (1...15).map { "[05:\(String(format: "%02d", $0))] Build 1246 still waiting for review (check \($0)/15)" }
            + ["Waiting for earlier builds to clear before submitting build 1254"]
        try account.control("/__menus/mode", [
            "jobTurns": [["text": "Build 1246 is still in review, so this watcher checks Apple every five minutes and submits 1254 as soon as it clears. Starting the public beta release watcher.", "command": script]],
            "processes": [[
                "session_id": "proc_rel",
                "command": String(script.prefix(200)),
                "cwd": "/Users/me/Projects/app-wt/release-job",
                "pid": 4211,
                "status": "running",
                "uptime_seconds": 28740,
                "started_at": "2026-10-13T02:14:26Z",
                "watch_patterns": ["READY_FOR_SALE", "INVALID_BINARY"],
                "output_tail": lines.joined(separator: "\n") + "\n",
            ]],
        ])
        openBotChat(app)
        let chip = app.activityCategory("background")
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        chip.tap()

        let title = app.descendants(matching: .any)["chat.background.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(title.label.hasPrefix("Shipping the beta invite to public TestFlight, running"), title.label)
        let detail = app.descendants(matching: .any)["chat.background.detail"].firstMatch
        XCTAssertEqual(detail.label, "Python script · release-job")
        let rowOutput = app.descendants(matching: .any)["chat.background.output"].firstMatch
        XCTAssertEqual(rowOutput.label, "Waiting for earlier builds to clear before submitting build 1254")
        shot(app, "background-list-improved")

        // Tap the row to drill into the full detail page.
        title.tap()
        let detailTitle = app.descendants(matching: .any)["chat.background.detail.title"].firstMatch
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 5), "tapping a row opens its detail page")
        XCTAssertEqual(detailTitle.label, "Shipping the beta invite to public TestFlight")
        let detailOutput = app.descendants(matching: .any)["chat.background.detail.output"].firstMatch
        XCTAssertTrue(detailOutput.label.contains("Build 1246 still waiting for review"), detailOutput.label)
        XCTAssertTrue(detailOutput.label.contains("Waiting for earlier builds to clear"), detailOutput.label)
        let meta = app.descendants(matching: .any)["chat.background.detail.meta"].firstMatch
        XCTAssertTrue(meta.label.contains("PID 4211"), meta.label)
        XCTAssertTrue(meta.label.contains("Started"), meta.label)
        XCTAssertTrue(app.buttons["chat.background.copy-output"].exists)
        XCTAssertTrue(app.buttons["chat.background.copy-command"].exists)
        XCTAssertTrue(app.buttons["chat.background.output-toggle"].exists, "long output offers Show All")
        shot(app, "background-detail-view")

        // Back returns to the list; tapping again and stopping sends process.kill.
        let back = app.buttons["chat.background.back"]
        XCTAssertTrue(back.exists)
        back.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        let stop = app.buttons["chat.background.detail.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
        XCTAssertTrue(waitUntil(timeout: 8) {
            self.calls(account, "process.kill").contains { ($0["process_id"] as? String) == "proc_rel" }
        }, "Stop from detail sends process.kill")
    }
}
