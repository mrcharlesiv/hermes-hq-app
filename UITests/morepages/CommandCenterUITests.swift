// More › Status & Maintenance and More › Usage, end to end against the stand-in gateway (docs/spec/3x-morepages.md §15
// acceptance, §21): scripts/fixtures/morepages/actions.py answers the status, logs, usage and the actions; its knobs
// (`POST /__fixture/actions`) script the failures.
// [status-page] One page, status then Maintenance, no tabs; Usage a More page of its own (owner 2026-11-03: one home per
// page). The class keeps the page's old name, as its ids do.

import XCTest

final class CommandCenterUITests: MorePagesCase {
    private func knob(_ body: [String: Any]) throws { _ = try account.control("/__fixture/actions", body) }

    /// Anything on screen whose label holds `words`.
    @MainActor private func words(_ words: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    }

    private static let page = "Status & Maintenance"

    @MainActor private var chart: XCUIElement { app.descendants(matching: .any)["more-usage.chart"] }

    @MainActor private func openCommandCenter(_ arguments: [String] = []) {
        launchSignedIn(arguments)
        // At a large text size More's list makes this row only once it scrolls into view.
        tab("More")
        let cell = app.cells["more-row-command-center"]
        for _ in 0..<6 where !cell.waitForExistence(timeout: 3) { app.swipeUp(velocity: .slow) }
        openMore("command-center")
        XCTAssertTrue(app.navigationBars[Self.page].waitForExistence(timeout: 10), "the page's small title")
    }

    /// More › Usage, from More's list (callers go Back to it first).
    @MainActor private func openUsage() {
        openMore("usage")
        XCTAssertTrue(app.navigationBars["Usage"].waitForExistence(timeout: 10), "the Usage page's small title")
    }

    /// Scrolls the page down until `element` is clear of the tab bar (`reach` alone stops at a row not yet made).
    @MainActor private func scrollTo(_ element: XCUIElement) {
        for _ in 0..<8 where !element.exists { app.swipeUp(velocity: .slow) }
        reach(element)
    }

    private func queries(_ path: String) throws -> [[String: Any]] {
        try rest("GET", path).compactMap { $0["query"] as? [String: Any] }
    }

    // MARK: Acceptance

    @MainActor func testU14_CommandCenter() throws {
        openCommandCenter()
        // System: version and gateway state.
        XCTAssertTrue(words("Hermes 0.21.5").waitForExistence(timeout: 15), "the gateway's Hermes version")
        XCTAssertTrue(words("Running").exists, "Messaging: Running")
        XCTAssertTrue(words("Login failed: the bot token was refused.").exists, "a platform's error")
        XCTAssertTrue(words("3 Updates Available").waitForExistence(timeout: 10), "the update check")
        shot("command-center-system")

        // Restart Gateway asks, shows "Restarting…", ends "Gateway Restarted" while the app reconnects by itself.
        let restart = app.buttons["command-center.restart"]
        XCTAssertTrue(restart.waitForExistence(timeout: 5))
        restart.tap()
        let alert = app.alerts["Restart Your Gateway?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "the confirmation")
        shot("command-center-restart-confirm")
        alert.buttons["Cancel"].tap()
        XCTAssertEqual(try rest("POST", "/api/gateway/restart").count, 0, "Cancel restarts nothing")
        restart.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Restart"].tap()
        XCTAssertTrue(words("Restarting…").waitForExistence(timeout: 10), "the progress line")
        shot("command-center-restarting")
        XCTAssertTrue(words("Gateway Restarted").waitForExistence(timeout: 40), "the restart's end, read from the action status")
        shot("command-center-restarted")
        XCTAssertEqual(try rest("POST", "/api/gateway/restart").count, 1)
        XCTAssertFalse(try rest("GET", "/api/actions/gateway-restart/status").isEmpty, "progress came from the action status")
        XCTAssertTrue(words("Running").waitForExistence(timeout: 20), "the status was read again")

        // Recent Logs: lines, and the Errors filter sends level=ERROR.
        app.buttons["command-center.logs"].tap()
        XCTAssertTrue(app.navigationBars["Recent Logs"].waitForExistence(timeout: 10))
        XCTAssertTrue(words("[500]").waitForExistence(timeout: 15), "the newest line is first")
        shot("command-center-logs")
        let first = try XCTUnwrap(try queries("/api/logs").first)
        XCTAssertEqual(first["file"] as? String, "agent")
        XCTAssertEqual(first["lines"] as? String, "200")
        XCTAssertNil(first["level"], "All sends no level")
        let level = app.navigationBars.buttons["command-center.logs.level"]
        level.tap()
        XCTAssertTrue(app.buttons["Errors"].waitForExistence(timeout: 5), "the level menu")
        shot("command-center-logs-level-menu")
        app.buttons["Errors"].tap()
        XCTAssertTrue(waitUntil(10) { ((try? self.queries("/api/logs")) ?? []).contains { ($0["level"] as? String) == "ERROR" } }, "level=ERROR")
        XCTAssertTrue(words(" ERROR ").waitForExistence(timeout: 10))
        shot("command-center-logs-errors")
        level.tap()
        app.buttons["Warnings"].tap()
        XCTAssertTrue(waitUntil(10) { ((try? self.queries("/api/logs")) ?? []).contains { ($0["level"] as? String) == "WARNING" } }, "level=WARNING")
        XCTAssertTrue(app.navigationBars.buttons["command-center.logs.share"].exists, "Share")
        back()

        // Maintenance, under the status on the same page: Run Doctor shows its output.
        let doctor = app.buttons["command-center.maintenance.doctor"]
        scrollTo(doctor)
        XCTAssertTrue(doctor.waitForExistence(timeout: 5))
        shot("command-center-maintenance")
        doctor.tap()
        XCTAssertTrue(app.navigationBars["Doctor"].waitForExistence(timeout: 10), "the output page")
        XCTAssertTrue(words("Found 1 issue(s) to address.").waitForExistence(timeout: 30), "the doctor's output")
        XCTAssertTrue(words("Finished with Problems").waitForExistence(timeout: 10), "a failing check is said")
        shot("command-center-doctor-output")
        XCTAssertEqual(try rest("POST", "/api/ops/doctor").count, 1)
        back()
        XCTAssertTrue(app.buttons["command-center.maintenance.output"].waitForExistence(timeout: 5), "the output stays reachable")
    }

    /// [status-page] One page: no tabs (no segmented control anywhere on it), the status first, Maintenance under it
    /// with its own header, and Usage as its own row in More (owner 2026-11-03: one home per page).
    @MainActor func testOnePageWithoutTabs() throws {
        openCommandCenter()
        XCTAssertTrue(words("Hermes 0.21.5").waitForExistence(timeout: 15), "the status is first")
        XCTAssertEqual(app.segmentedControls.count, 0, "no tabs on the page")
        XCTAssertFalse(app.descendants(matching: .any)["command-center.segments"].exists, "no tab strip")
        shot("status-page-top")
        let logs = app.buttons["command-center.logs"]
        scrollTo(logs)   // at a large text size the row is made only once scrolled to
        XCTAssertTrue(logs.exists, "Recent Logs is in the status part")
        let header = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Maintenance")).firstMatch
        scrollTo(header)
        XCTAssertTrue(header.exists, "Maintenance has its own header on the same page")
        let doctor = app.buttons["command-center.maintenance.doctor"]
        scrollTo(doctor)
        XCTAssertTrue(doctor.exists, "Maintenance's actions sit under it")
        XCTAssertTrue(app.navigationBars[Self.page].exists, "still the same page: nothing was opened to get here")
        XCTAssertEqual(app.segmentedControls.count, 0, "no tabs further down either")
        shot("status-page-maintenance")

        // Usage is a page of its own, listed in More beside it.
        back()
        let usageRow = app.cells["more-row-usage"]
        XCTAssertTrue(usageRow.waitForExistence(timeout: 10), "More lists Usage")
        reach(usageRow)
        shot("more-list-rows")
        openUsage()
        XCTAssertTrue(chart.waitForExistence(timeout: 15), "the Daily Tokens chart")
        XCTAssertEqual(app.segmentedControls.count, 0, "Usage has no tabs either")
        XCTAssertFalse(app.buttons["command-center.restart"].exists, "Usage holds no status rows")
        shot("usage-page")

        // Settings › Gateway's row says the same name and opens the same page.
        back()
        openMore("settings")
        let card = app.buttons["settings.gateway-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Settings shows the gateway card")
        card.tap()
        let row = app.descendants(matching: .any)["gateway.command-center"]
        scrollTo(row)
        XCTAssertTrue(row.exists, "the Gateway page links to it")
        XCTAssertTrue(row.label.contains(Self.page), "by the same name: \(row.label)")
        shot("gateway-page-row")
        row.tap()
        XCTAssertTrue(app.navigationBars[Self.page].waitForExistence(timeout: 10), "the same page")
        XCTAssertTrue(words("Hermes 0.21.5").waitForExistence(timeout: 15))
        XCTAssertEqual(app.segmentedControls.count, 0)
    }

    // MARK: Usage

    @MainActor func testU14_Usage() throws {
        launchSignedIn()
        openUsage()
        // The chart for 30 days; 7 re-reads with days=7.
        XCTAssertTrue(chart.waitForExistence(timeout: 15), "the Daily Tokens chart")
        XCTAssertTrue(chart.label.hasPrefix("Daily tokens, 30 days"), "VoiceOver summary: \(chart.label)")
        XCTAssertTrue(app.staticTexts["Est. Cost"].exists || words("Estimated cost").exists)
        XCTAssertEqual(try queries("/api/analytics/usage").last?["days"] as? String, "30")
        shot("usage-30")
        app.swipeUp()
        XCTAssertTrue(words("By Model").waitForExistence(timeout: 5) || words("BY MODEL").exists)
        shot("usage-lists")
        app.swipeDown()
        app.descendants(matching: .any)["more-usage.period"].firstMatch.tap()
        XCTAssertTrue(app.buttons["7 Days"].waitForExistence(timeout: 5), "the period menu")
        app.buttons["7 Days"].tap()
        XCTAssertTrue(waitUntil(10) { ((try? self.queries("/api/analytics/usage")) ?? []).last?["days"] as? String == "7" }, "days=7")
        XCTAssertTrue(waitUntil(10) { self.chart.exists && self.chart.label.hasPrefix("Daily tokens, 7 days") }, "the chart follows: \(chart.label)")
        shot("usage-7")
    }

    // MARK: Update

    // [update-flow] The one Update sheet: it asks with the gateway's name, then steps, then a named ending.
    @MainActor func testUpdateFlow() throws {
        openCommandCenter()
        let update = app.buttons["command-center.update"]
        XCTAssertTrue(update.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(10) { update.label.contains("3 Updates Available") }, update.label)
        reach(update)
        update.tap()
        let go = app.buttons["hermes-update.go"]
        XCTAssertTrue(go.waitForExistence(timeout: 15), "the sheet asks first")
        XCTAssertTrue(app.descendants(matching: .any)["hermes-update.step.drain"].exists, "Wait for Bots is a step")
        shot("command-center-update-confirm")
        tapUpdateInSheet()
        XCTAssertTrue(app.descendants(matching: .any)["hermes-update.step.install"].waitForExistence(timeout: 10))
        shot("command-center-updating")
        let headline = app.descendants(matching: .any)["hermes-update.headline"]
        XCTAssertTrue(waitUntil(90) { headline.label == "Updated to 0.22.0" }, "only once the version changed: \(headline.label)")
        shot("command-center-updated")
        XCTAssertEqual(try rest("POST", "/api/hermes/update").count, 1)
        let output = app.buttons["hermes-update.output"]
        XCTAssertTrue(output.waitForExistence(timeout: 5), "the whole output stays reachable")
        output.tap()
        XCTAssertTrue(app.navigationBars["Update Output"].waitForExistence(timeout: 10))
        XCTAssertTrue(words("✓ Hermes updated to 0.22.0").waitForExistence(timeout: 10))
        shot("command-center-update-output")
        app.navigationBars["Update Output"].buttons["Done"].tap()
        app.buttons["hermes-update.close"].tap()
        app.swipeDown()
        XCTAssertTrue(words("Hermes 0.22.0").waitForExistence(timeout: 30), "the new version is read")
    }

    @MainActor func testUpdateThatFails() throws {
        try knob(["update": "fail"])
        openCommandCenter()
        let update = app.buttons["command-center.update"]
        XCTAssertTrue(update.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(10) { update.label.contains("Updates Available") })
        reach(update)
        update.tap()
        tapUpdateInSheet()
        let headline = app.descendants(matching: .any)["hermes-update.headline"]
        XCTAssertTrue(waitUntil(40) { headline.label == "The Update Didn’t Finish" }, headline.label)
        XCTAssertTrue(words("Update failed. Nothing was changed.").exists, "Hermes's own reason")
        let copy = app.buttons["hermes-update.copy"]
        for _ in 0..<2 { app.descendants(matching: .any)["hermes-update.step.check"].swipeUp(velocity: .slow) }
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "Copy Details")
        XCTAssertTrue(app.buttons["hermes-update.output"].exists, "Update Output")
        shot("command-center-update-failed")
        copy.tap()
        app.buttons["hermes-update.close"].tap()
        XCTAssertTrue(app.buttons["command-center.update"].waitForExistence(timeout: 10), "it can be tried again")
        app.swipeDown()
        XCTAssertTrue(words("Hermes 0.21.5").waitForExistence(timeout: 10), "nothing changed")
    }

    @MainActor func testUpdateRefusedAndNotAppliable() throws {
        try knob(["update": "refused"])
        openCommandCenter()
        let update = app.buttons["command-center.update"]
        XCTAssertTrue(update.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(10) { update.label.contains("Updates Available") })
        reach(update)
        update.tap()
        tapUpdateInSheet()
        let headline = app.descendants(matching: .any)["hermes-update.headline"]
        XCTAssertTrue(waitUntil(20) { headline.label.hasSuffix("Can’t Update Itself") }, headline.label)
        XCTAssertTrue(app.buttons["hermes-update.copy-command"].exists, "what to run instead, with Copy")
        app.buttons["hermes-update.close"].tap()
        // [update-flow] A gateway that can't update in place still offers Update: the sheet says so from its check,
        // with what to run instead, and never posts an update it knows would be refused.
        try knob(["update": "", "can_apply": false, "update_message": "Hermes runs in Docker here. Pull the new image on your gateway computer."])
        back()
        openMore("command-center")
        XCTAssertTrue(words("Hermes 0.21.5").waitForExistence(timeout: 15))
        app.swipeUp()
        XCTAssertTrue(words("Pull the new image on your gateway computer.").waitForExistence(timeout: 15))
        let again = app.buttons["command-center.update"]
        XCTAssertTrue(again.waitForExistence(timeout: 10))
        reach(again)
        again.tap()
        XCTAssertTrue(waitUntil(20) { headline.label.hasSuffix("Can’t Update Itself") }, headline.label)
        XCTAssertFalse(app.buttons["hermes-update.go"].exists, "no Update that would be refused")
        XCTAssertEqual(try rest("POST", "/api/hermes/update").count, 1, "only the first, refused, post")
        shot("command-center-update-not-here")
    }

    /// The sheet's Update, once its fit-height move has settled; it must leave the asking state.
    private func tapUpdateInSheet() {
        let go = app.buttons["hermes-update.go"]
        XCTAssertTrue(go.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(10) { go.isHittable }, "Update is on screen")
        Thread.sleep(forTimeInterval: 0.6)
        go.tap()
        XCTAssertTrue(waitUntil(10) { !go.exists }, "the update started")
    }

    // MARK: Stress

    @MainActor func testRestartWhileTheSocketDropsAndStatusFails() throws {
        try knob(["restart_seconds": 7, "drop_seconds": 5, "blackout": true])
        openCommandCenter()
        let restart = app.buttons["command-center.restart"]
        XCTAssertTrue(restart.waitForExistence(timeout: 15))
        restart.tap()
        app.alerts.buttons["Restart"].tap()
        XCTAssertTrue(words("Restarting…").waitForExistence(timeout: 10))
        // Mid-drop: the page still says so, the button is not offered twice.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(words("Restarting…").exists, "the state survives the link dropping and failed status reads")
        XCTAssertFalse(app.buttons["command-center.restart"].exists, "no second restart while one runs")
        XCTAssertTrue(words("Gateway Restarted").waitForExistence(timeout: 60))
        XCTAssertEqual(try rest("POST", "/api/gateway/restart").count, 1)
        // The app is back by itself: another page reads.
        back()
        openUsage()
        XCTAssertTrue(chart.waitForExistence(timeout: 30))
    }

    @MainActor func testRestartThatFails() throws {
        try knob(["restart": "fail"])
        openCommandCenter()
        let restart = app.buttons["command-center.restart"]
        XCTAssertTrue(restart.waitForExistence(timeout: 15))
        restart.tap()
        app.alerts.buttons["Restart"].tap()
        XCTAssertTrue(words("Failed to restart gateway").waitForExistence(timeout: 20), "the gateway's reason")
        shot("command-center-restart-failed")
        XCTAssertTrue(app.buttons["command-center.restart"].isEnabled, "it can be tried again")
        try knob(["restart": "exit1", "restart_seconds": 2, "drop_seconds": 1])
        app.buttons["command-center.restart"].tap()
        app.alerts.buttons["Restart"].tap()
        XCTAssertTrue(words("Gateway did not come back").waitForExistence(timeout: 40), "a restart that ends badly shows its last line")
    }

    @MainActor func testHugeLogs() throws {
        try knob(["logs": "huge"])
        openCommandCenter()
        XCTAssertTrue(app.buttons["command-center.logs"].waitForExistence(timeout: 15))
        let start = Date()
        app.buttons["command-center.logs"].tap()
        XCTAssertTrue(words("line 5000 ").waitForExistence(timeout: 30), "5,000 lines of 4,000 characters load")
        measured("5,000 long log lines: \(String(format: "%.2f", Date().timeIntervalSince(start))) s from tap to the first rows")
        shot("command-center-logs-huge")
        for _ in 0..<6 { app.swipeUp(velocity: .fast) }
        for _ in 0..<2 { app.swipeDown(velocity: .fast) }
        XCTAssertTrue(app.navigationBars["Recent Logs"].exists, "still here after fast scrolling")
        app.navigationBars.buttons["command-center.logs.level"].tap()
        app.buttons["Errors"].tap()
        XCTAssertTrue(words(" ERROR ").waitForExistence(timeout: 30))
        back()
        XCTAssertTrue(app.navigationBars[Self.page].waitForExistence(timeout: 10))
    }

    @MainActor func testEmptyLogsAndLogsFailure() throws {
        try knob(["logs": "empty"])
        openCommandCenter()
        XCTAssertTrue(app.buttons["command-center.logs"].waitForExistence(timeout: 15))
        app.buttons["command-center.logs"].tap()
        XCTAssertTrue(words("The gateway’s log is empty.").waitForExistence(timeout: 15), "audit 08d-11: says there are none")
        shot("command-center-logs-empty")
        back()
        try knob(["logs": ""])
        try fail("GET", "/api/logs", status: 500, detail: "The log file could not be read.")
        app.buttons["command-center.logs"].tap()
        XCTAssertTrue(words("Couldn’t Load Logs").waitForExistence(timeout: 15))
        XCTAssertTrue(words("The log file could not be read.").exists)
        app.buttons["Try Again"].tap()
        XCTAssertTrue(words("[500]").waitForExistence(timeout: 15), "Try Again reads the lines")
    }

    /// [status-page] A status that can't be read leaves the reason and Try Again in its place, and Maintenance under it
    /// (the Maintenance tab opened without the status).
    @MainActor func testFailedStatusKeepsMaintenance() throws {
        launchSignedIn()
        try knob(["status_fail": 40])
        openMore("command-center")
        XCTAssertTrue(words("Couldn’t Load Status").waitForExistence(timeout: 30), "the status read fails")
        XCTAssertTrue(app.buttons["command-center.maintenance.doctor"].waitForExistence(timeout: 5), "Maintenance is still there")
        XCTAssertFalse(words("Couldn’t Load Status & Maintenance").exists, "the page isn't one error")
        shot("command-center-status-failed")
        try knob(["status_fail": 0])
        app.buttons["Try Again"].tap()
        XCTAssertTrue(words("Hermes 0.21.5").waitForExistence(timeout: 30), "Try Again loads the status")
        let doctor = app.buttons["command-center.maintenance.doctor"]
        scrollTo(doctor)   // under the status now, below the first screen
        XCTAssertTrue(doctor.waitForExistence(timeout: 5), "with Maintenance under it")
    }

    @MainActor func testDelayedFirstReadThenFailureThenTryAgain() throws {
        launchSignedIn()
        try knob(["status_delay": 4, "status_fail": 1])
        openMore("command-center")
        XCTAssertTrue(app.descendants(matching: .any)["more.page.loading"].waitForExistence(timeout: 3), "the skeleton shows while the read is slow")
        shot("command-center-loading")
        let retry = app.buttons["Try Again"]
        let version = words("Hermes 0.21.5")
        XCTAssertTrue(waitUntil(30) { retry.exists || version.exists }, "the slow read ends")
        if retry.exists {
            XCTAssertTrue(words("Couldn’t Load Status").exists)
            // [status-page] Maintenance stays under the failed status (its tab opened without it).
            XCTAssertTrue(app.buttons["command-center.maintenance.doctor"].exists, "Maintenance is still there")
            shot("command-center-error")
            try knob(["status_delay": 0, "status_fail": 0])
            retry.tap()
        }
        try knob(["status_delay": 0, "status_fail": 0])
        XCTAssertTrue(version.waitForExistence(timeout: 30), "Try Again loads the page")

        // Usage: a failed first read, then Try Again.
        try fail("GET", "/api/analytics/usage", status: 500, detail: "The session store is busy.")
        back()
        openUsage()
        XCTAssertTrue(words("Couldn’t Load Usage").waitForExistence(timeout: 15))
        XCTAssertTrue(words("The session store is busy.").exists)
        shot("usage-error")
        app.buttons["Try Again"].tap()
        XCTAssertTrue(chart.waitForExistence(timeout: 15))
    }

    /// Opening and leaving the two pages quickly: each read happens, none is sent again and again.
    @MainActor func testRapidPageSwitching() throws {
        openCommandCenter()
        XCTAssertTrue(words("Hermes 0.21.5").waitForExistence(timeout: 15))
        for _ in 0..<4 {
            back()
            openUsage()
            back()
            openMore("command-center")
        }
        XCTAssertTrue(app.navigationBars[Self.page].waitForExistence(timeout: 10))
        XCTAssertTrue(words("Hermes 0.21.5").waitForExistence(timeout: 15))
        XCTAssertLessThanOrEqual(try rest("GET", "/api/analytics/usage").count, 5, "one read per opening of Usage")
        let doctor = app.buttons["command-center.maintenance.doctor"]
        scrollTo(doctor)
        XCTAssertTrue(doctor.waitForExistence(timeout: 5))
        // Rapid taps on an action start it once.
        let audit = app.buttons["command-center.maintenance.securityAudit"]
        scrollTo(audit)
        audit.tap()
        XCTAssertTrue(app.navigationBars["Security Audit"].waitForExistence(timeout: 10))
        XCTAssertTrue(words("Audit finished: 0 critical, 1 note.").waitForExistence(timeout: 30))
        XCTAssertTrue(words("Finished").exists)
        shot("command-center-audit-output")
        back()
        let backup = app.buttons["command-center.maintenance.backup"]
        scrollTo(backup)
        backup.tap()
        XCTAssertTrue(words("Backup written to").waitForExistence(timeout: 30))
        XCTAssertEqual(try rest("POST", "/api/ops/security-audit").count, 1)
        XCTAssertEqual(try rest("POST", "/api/ops/backup").count, 1)
        XCTAssertEqual(try rest("POST", "/api/ops/backup").first?["body"] as? [String: String], [:], "the backup takes every default")
    }

    @MainActor func testOldGatewayShapeAndEmptyUsage() throws {
        try knob(["old": true, "behind": NSNull()])
        openCommandCenter()
        XCTAssertTrue(words("Hermes 0.21.5").waitForExistence(timeout: 15))
        XCTAssertTrue(words("Couldn’t Check").waitForExistence(timeout: 15), "an update check that could not run")
        XCTAssertFalse(app.buttons["command-center.update"].exists, "nothing to update to, so no button")
        shot("command-center-old-gateway-system")
        back()
        openUsage()
        XCTAssertTrue(chart.waitForExistence(timeout: 15), "a trimmed answer still draws")
        shot("usage-old-gateway")
        try knob(["old": false, "usage": "empty"])
        app.descendants(matching: .any)["more-usage.period"].firstMatch.tap()
        app.buttons["90 Days"].tap()
        XCTAssertTrue(words("No Usage Yet").waitForExistence(timeout: 15))
        XCTAssertTrue(words("Usage shows up after your bots have worked.").exists)
        shot("usage-empty")
    }

    @MainActor func testReadOnlyGatewayHidesEveryAction() throws {
        openCommandCenter(["-HQPagesReadOnly", "YES", "-HQDebugReadOnly", "YES"])
        XCTAssertTrue(words("Hermes 0.21.5").waitForExistence(timeout: 15))
        XCTAssertTrue(words("3 Updates Available").waitForExistence(timeout: 15), "the check still reads")
        XCTAssertFalse(app.buttons["command-center.restart"].exists, "no Restart Gateway")
        XCTAssertFalse(app.buttons["command-center.update"].exists, "no Update button")
        XCTAssertTrue(app.buttons["command-center.logs"].exists, "Recent Logs still reads")
        for _ in 0..<4 { app.swipeUp(velocity: .slow) }
        XCTAssertFalse(app.buttons["command-center.maintenance.doctor"].exists, "no Maintenance section: every row in it is an action")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Maintenance")).firstMatch.exists, "nor its header")
        shot("command-center-read-only")
        back()
        openUsage()
        XCTAssertTrue(chart.waitForExistence(timeout: 15), "Usage reads on a read-only gateway too")
        XCTAssertEqual(try restLog().filter { ($0["method"] as? String) == "POST" && !(($0["path"] as? String) ?? "").hasPrefix("/api/plugins") }.count, 0,
                       "a read-only gateway is only read")
    }

    @MainActor func testRelaunchOnThePage() throws {
        openCommandCenter()
        XCTAssertTrue(words("Hermes 0.21.5").waitForExistence(timeout: 15))
        relaunch()
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 20), "the tab bar shows after a relaunch")
        // Either the page is restored over More or More's root shows: never a page without a way back.
        if app.navigationBars[Self.page].waitForExistence(timeout: 5) {
            back()
            XCTAssertTrue(app.cells["more-row-command-center"].waitForExistence(timeout: 10), "Back leads to More")
        }
        openMore("command-center")
        XCTAssertTrue(words("Hermes 0.21.5").waitForExistence(timeout: 15), "the page opens again")
        shot("command-center-after-relaunch")
    }

    /// The page at any text size: nothing here depends on what fits on one screen (the pass at a large size uses it).
    @MainActor func testLooksAtAnyTextSize() throws {
        openCommandCenter()
        XCTAssertTrue(words("Hermes 0.21.5").waitForExistence(timeout: 15))
        XCTAssertEqual(app.segmentedControls.count, 0, "no tabs to fit")
        shot("command-center-size-system")
        app.swipeUp()
        shot("command-center-size-system-2")
        app.swipeUp()
        shot("command-center-size-system-3")
        app.swipeDown(); app.swipeDown()
        let restart = app.buttons["command-center.restart"]
        for _ in 0..<4 where !restart.exists { app.swipeUp(velocity: .slow) }
        reach(restart)
        restart.tap()
        XCTAssertTrue(app.alerts["Restart Your Gateway?"].waitForExistence(timeout: 5))
        shot("command-center-size-restart-confirm")
        app.alerts.buttons["Restart"].tap()
        XCTAssertTrue(words("Restarting…").waitForExistence(timeout: 10))
        shot("command-center-size-restarting")
        XCTAssertTrue(words("Gateway Restarted").waitForExistence(timeout: 40))
        let logs = app.buttons["command-center.logs"]
        reach(logs)
        logs.tap()
        XCTAssertTrue(words("[500]").waitForExistence(timeout: 15))
        shot("command-center-size-logs")
        back()
        let doctor = app.buttons["command-center.maintenance.doctor"]
        scrollTo(doctor)
        XCTAssertTrue(doctor.waitForExistence(timeout: 5))
        shot("command-center-size-maintenance")
        doctor.tap()
        XCTAssertTrue(words("Finished with Problems").waitForExistence(timeout: 30))
        shot("command-center-size-doctor-output")
        back()
        back()
        openUsage()
        XCTAssertTrue(words("Tokens").waitForExistence(timeout: 15))
        shot("usage-size")
        app.swipeUp()
        shot("usage-size-2")
    }
}
