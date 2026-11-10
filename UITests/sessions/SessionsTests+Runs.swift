// Sessions › Other Apps with Show › Background Runs: the scheduled job runs (`source = "cron"`) get a "Scheduled Runs"
// section and the one-off runs (`oneshot`, a script's "Reply with exactly OK" probe) a "One-off Runs" section on the
// Other Apps page. Both are hidden by default and never in the dated list (n20-sessions B4, F1).

import XCTest

extension SessionsTests {
    /// Two runs of a scheduled job and a one-off probe on the fixture (its default seed has none).
    func addRuns() {
        let now = nowSeconds
        setRow("cron_standup_2", ["profile": "default", "title": "Daily standup", "source": "cron", "last_active": now - 120])
        setRow("cron_standup_1", ["profile": "default", "title": "Daily standup", "source": "cron", "last_active": now - 86_400])
        setRow("s-probe", ["profile": "research", "title": "Reply with exactly OK", "source": "oneshot", "last_active": now - 600],
               event: true)
    }

    @MainActor func test98_RunsSectionsWithBackgroundRuns() throws { try runsRound(desktop: false) }

    @MainActor func test99_RunsSectionsInTheDesktopLook() throws { try runsRound(desktop: true) }

    /// Extra Large text, both looks (the screenshots are the check: names wrap, nothing is cut).
    @MainActor func test100_RunsSectionsAtExtraLargeText() throws {
        try runsRound(desktop: false, text: "UICTContentSizeCategoryXL")
        try runsRound(desktop: true, text: "UICTContentSizeCategoryXL")
    }

    @MainActor func runsRound(desktop: Bool, text: String? = nil) throws {
        addRuns()
        let app = launch(extra: (desktop ? ["-HQDebugDesktopLook", "YES"] : [])
                         + (text.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? []))
        let look = (desktop ? "desktop" : "standard") + (text == nil ? "" : "-xl")
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        let apps = app.cells["sessions.otherApps"]
        XCTAssertFalse(apps.exists, "runs are hidden by default")
        XCTAssertFalse(row(app, "cron_standup_2").exists || row(app, "s-probe").exists)
        openFilter(app)
        tapFilter(app, "show", "runs")
        closeFilter(app)
        XCTAssertTrue(apps.waitForExistence(timeout: 8), "the Other Apps row holds the runs")
        XCTAssertFalse(row(app, "cron_standup_2").exists, "a scheduled run is never among the dated rows")
        let words = labelOf(apps)
        XCTAssertTrue(words.contains("Scheduled Runs") && words.contains("One-off Runs") && words.contains("3 chats"), words)
        shot(app, "runs-row-\(look)")

        apps.tap()
        let page = app.collectionViews["otherApps.list"]
        XCTAssertTrue(page.waitForExistence(timeout: 6), "the Other Apps page")
        let newest = page.cells["session-row-cron_standup_2"]
        XCTAssertTrue(newest.waitForExistence(timeout: 6))
        XCTAssertTrue(page.cells["session-row-cron_standup_1"].exists && page.cells["session-row-s-probe"].exists)
        for title in ["Scheduled Runs", "One-off Runs"] {
            XCTAssertTrue(page.staticTexts.matching(NSPredicate(format: "label ==[c] %@", title)).firstMatch.exists, "the \(title) section")
        }
        // Newest first: the scheduled runs (2 minutes ago) above the probe (10 minutes ago), the older run below the newer.
        XCTAssertLessThan(newest.frame.minY, page.cells["session-row-s-probe"].frame.minY)
        XCTAssertLessThan(newest.frame.minY, page.cells["session-row-cron_standup_1"].frame.minY)
        XCTAssertFalse(labelOf(newest).contains("Unread"), "a run is never unread")
        shot(app, "runs-page-\(look)")

        // A run opens its chat; Back comes back to the page.
        newest.tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 8), "the run's chat opens")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(page.waitForExistence(timeout: 6), "back on the page")
    }
}
