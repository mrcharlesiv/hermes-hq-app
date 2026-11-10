// More › Import Sessions (docs/spec/3x-morepages.md §14 acceptance, §21 stress lines for this page), against the
// stand-in's invented foreign sessions (scripts/fixtures/morepages/foreign.py). Run:
//   HQN_MOREPAGES_GATEWAYS="main" HQN_MOREPAGES_PORTS="10053" HQN_MOREPAGES_ONLY="ImportSessionsUITests" scripts/e2e-morepages.sh <udid>

import XCTest

final class ImportSessionsUITests: MorePagesCase {
    // MARK: Helpers

    @MainActor private func row(_ index: Int) -> XCUIElement { app.buttons[String(format: "import-sessions.row.fs-%04d", index)] }

    @MainActor private func openPage(file: StaticString = #filePath, line: UInt = #line) {
        // At large text More's list is long and the row starts below the screen.
        tab("More")
        let cell = app.cells["more-row-import-sessions"]
        for _ in 0..<10 where !cell.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(cell.exists, "More lists Import Sessions", file: file, line: line)
        reach(cell)
        cell.tap()
        XCTAssertTrue(app.navigationBars["Import Sessions"].waitForExistence(timeout: 10), file: file, line: line)
    }

    /// The row, scrolled to (the list builds its rows as they come on screen) and clear of the tab bar.
    @MainActor private func bringRow(_ index: Int, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let element = row(index)
        let floor = app.windows.firstMatch.frame.height - 130
        for _ in 0..<30 where !element.exists || !element.isHittable || element.frame.midY > floor || element.frame.minY < 110 {
            if element.exists && element.frame.minY < 110 { app.swipeDown(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
        }
        XCTAssertTrue(element.exists, "row \(index)", file: file, line: line)
        return element
    }

    /// The page's own list calls (More's availability probe asks with `limit: 1`).
    private func listCalls() throws -> [[String: Any]] {
        try rpc("session.foreign.list").compactMap { $0["params"] as? [String: Any] }.filter { ($0["limit"] as? Int) == 50 }
    }

    /// Scrolls to the Load More row and taps it; false when the list has ended (the closing count is on screen).
    @MainActor @discardableResult
    private func loadMore(taps: Int = 1) -> Bool {
        let more = app.buttons["import-sessions.more"]
        let count = app.staticTexts["import-sessions.count"]
        let height = app.windows.firstMatch.frame.height
        for _ in 0..<60 {
            if more.exists {
                if more.frame.midY < height - 130 && more.isHittable { break }
                app.swipeUp(velocity: .slow)
            } else if count.exists && count.label.hasSuffix("sessions.") {
                return false
            } else {
                app.swipeUp(velocity: .fast)
            }
        }
        guard more.exists, more.isHittable else { return false }
        // A point on the window, not on the row: the row moves away as soon as its page lands.
        let frame = more.frame
        let spot = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.minX + frame.width * 0.3, dy: frame.midY))
        for _ in 0..<taps { spot.tap() }
        return true
    }

    /// Waits until the page has asked for `pages` pages and the last one has landed.
    @MainActor private func waitForPages(_ pages: Int, timeout: TimeInterval = 20) -> Bool {
        waitUntil(timeout) { ((try? self.listCalls().count) ?? 0) >= pages }
    }

    /// The count under the list ("100 sessions loaded." / "120 sessions."), scrolled to.
    @MainActor private func closingCount() -> String {
        let count = app.staticTexts["import-sessions.count"]
        for _ in 0..<60 where !count.exists { app.swipeUp(velocity: .fast) }
        return count.exists ? count.label : ""
    }

    private func foreign() throws -> [String: Any] { (try state()["foreign"] as? [String: Any]) ?? [:] }

    /// A relaunch that keeps the run's text size (the shared `relaunch` starts at the default size).
    @MainActor private func again(_ arguments: [String] = []) {
        var all = arguments
        if let size = ProcessInfo.processInfo.environment["HQN_TEXT_SIZE"], !size.isEmpty {
            all += ["-UIPreferredContentSizeCategoryName", size]
        }
        relaunch(all)
    }

    // MARK: Acceptance

    @MainActor func testU13_ImportSessions() throws {
        launchSignedIn(["-HQImportForgetBot", "YES"])
        openPage()
        XCTAssertTrue(row(0).waitForExistence(timeout: 20), "the first page")
        XCTAssertTrue(app.staticTexts["Bring a conversation into Hermes and pick up where you left off."].exists)
        XCTAssertTrue(app.staticTexts["Reading from Robin’s Mac mini"].exists)
        XCTAssertTrue(app.segmentedControls.buttons["All"].isSelected)
        XCTAssertTrue(app.segmentedControls.buttons["Claude Code"].exists && app.segmentedControls.buttons["Codex"].exists)
        XCTAssertEqual(try listCalls().count, 1)
        XCTAssertEqual(try listCalls().first?.keys.sorted(), ["limit"], "the first page sends only its size")
        shot("import-list")

        // 50, then Load More reaches 120.
        XCTAssertTrue(loadMore())
        XCTAssertTrue(waitForPages(2))
        XCTAssertEqual(closingCount(), "100 sessions loaded.", "100 after the second page")
        shot("import-load-more")
        XCTAssertTrue(loadMore())
        XCTAssertTrue(waitForPages(3))
        XCTAssertEqual(closingCount(), "120 sessions.", "120 and no more")
        XCTAssertTrue(app.staticTexts["import-sessions.skipped"].exists, "the skipped logs are mentioned")
        XCTAssertEqual(app.staticTexts["import-sessions.skipped"].label, "Some logs were empty, unreadable, or too large to preview.")
        XCTAssertFalse(app.buttons["import-sessions.more"].exists)
        XCTAssertEqual(try listCalls().map { ($0["offset"] as? Int) ?? 0 }, [0, 50, 100])

        // The Codex segment sends source: "codex".
        for _ in 0..<60 where !app.segmentedControls.buttons["Codex"].isHittable { app.swipeDown(velocity: .fast) }
        app.segmentedControls.buttons["Codex"].tap()
        XCTAssertTrue(row(1).waitForExistence(timeout: 15))
        XCTAssertFalse(row(0).exists, "Claude Code sessions are gone from the Codex list")
        let codex = try XCTUnwrap(try listCalls().last)
        XCTAssertEqual(codex["source"] as? String, "codex")
        XCTAssertEqual(codex.keys.sorted(), ["limit", "source"])
        shot("import-codex")
        app.segmentedControls.buttons["All"].tap()
        XCTAssertTrue(row(0).waitForExistence(timeout: 15))

        // The preview shows the turns and the footnote.
        let target = row(7)
        for _ in 0..<10 where !target.exists || !target.isHittable { app.swipeUp(velocity: .slow) }
        target.tap()
        XCTAssertTrue(app.buttons["import-sessions.import"].waitForExistence(timeout: 15), "Import in the bar")
        XCTAssertEqual(app.buttons["import-sessions.import"].label, "Import")
        XCTAssertTrue(app.otherElements["import-sessions.turn.user"].firstMatch.exists || app.staticTexts["You"].firstMatch.exists, "the turns show")
        XCTAssertTrue(app.staticTexts["You"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Codex"].firstMatch.exists, "the assistant's turns are named by the app they came from")
        XCTAssertFalse(app.descendants(matching: .any)["import-sessions.preview.already"].exists)
        shot("import-preview")
        let footnote = app.staticTexts["import-sessions.preview.footnote"]
        for _ in 0..<12 where !footnote.exists || !footnote.isHittable { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(footnote.exists)
        XCTAssertEqual(footnote.label, "Copies conversation text. Source files stay unchanged. Tool output and reasoning are not carried over.")
        XCTAssertEqual((try rpc("session.foreign.preview").last?["params"] as? [String: Any])?.keys.sorted(), ["id"])

        // Import lands in the chat titled as the session.
        app.buttons["import-sessions.import"].tap()
        let title = "Clean up the CSS (7)"
        XCTAssertTrue(waitUntil(20) { self.app.staticTexts[title].exists || self.app.navigationBars[title].exists || self.app.buttons[title].exists },
                      "the imported chat opens, titled as the session")
        XCTAssertTrue(waitUntil(10) { !self.app.tabBars.buttons["More"].isHittable }, "a chat is on screen")
        shot("import-landed")
        XCTAssertEqual(try foreign()["imports"] as? Int, 1)
        let imports = try rpc("session.foreign.import")
        XCTAssertEqual(imports.count, 1)
        XCTAssertEqual((imports.first?["params"] as? [String: Any]) as? [String: String], ["id": "fs-0007"])
        let writes = (try state()["writes"] as? [[String: Any]]) ?? []
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?["session_id"] as? String, "imported-fs-0007")

        // Back on the preview it now reads Open in Hermes.
        back()
        XCTAssertTrue(waitUntil(10) { self.app.buttons["import-sessions.import"].exists && self.app.buttons["import-sessions.import"].label == "Open in Hermes" })
        back()

        // The already-imported one opens the existing chat without a second import call.
        for _ in 0..<10 where !row(2).exists || !row(2).isHittable { app.swipeDown(velocity: .slow) }
        row(2).tap()
        let open = app.buttons["import-sessions.import"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        XCTAssertEqual(open.label, "Open in Hermes")
        XCTAssertTrue(app.descendants(matching: .any)["import-sessions.preview.already"].exists)
        XCTAssertTrue(app.staticTexts["This conversation is already in Hermes. Open your existing copy to continue."].exists
                      || app.descendants(matching: .any)["import-sessions.preview.already"].label.contains("already in Hermes"))
        shot("import-preview-already")
        open.tap()
        XCTAssertTrue(waitUntil(20) { !self.app.tabBars.buttons["More"].isHittable && !self.app.buttons["import-sessions.import"].exists },
                      "the existing chat opens")
        XCTAssertEqual(try rpc("session.foreign.import").count, 1, "no second import call")
        XCTAssertEqual(try foreign()["imports"] as? Int, 1)
    }

    @MainActor func testImport_PreviewShortenedAndEmpty() throws {
        launchSignedIn(["-HQImportForgetBot", "YES"])
        openPage()
        XCTAssertTrue(row(0).waitForExistence(timeout: 20))
        bringRow(3).tap()
        XCTAssertTrue(app.descendants(matching: .any)["import-sessions.preview.shortened"].waitForExistence(timeout: 15), "a 90-turn chat's preview is shortened")
        shot("import-preview-shortened")
        back()
        // A conversation with no turns still previews (and says so).
        bringRow(5).tap()
        XCTAssertTrue(app.staticTexts["import-sessions.preview.empty"].waitForExistence(timeout: 15))
        back()
        // A preview that fails says so and can be tried again.
        try account.control("/__fixture/foreign", ["error": "the log moved", "error_method": "preview"])
        bringRow(4).tap()
        XCTAssertTrue(app.staticTexts["Preview Unavailable"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["import-sessions.import"].exists, "nothing to import without a preview")
        shot("import-preview-error")
        app.buttons["Try Again"].firstMatch.tap()
        XCTAssertTrue(app.buttons["import-sessions.import"].waitForExistence(timeout: 15))
        // An import that fails: the alert with the reason, Try Again imports.
        try account.control("/__fixture/foreign", ["error": "the disk is full", "error_method": "import"])
        app.buttons["import-sessions.import"].tap()
        XCTAssertTrue(app.alerts["Couldn’t Import This Conversation"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.alerts.staticTexts["the disk is full"].exists)
        shot("import-failed")
        app.alerts.buttons["Try Again"].tap()
        XCTAssertTrue(waitUntil(20) { ((try? self.foreign()["imports"] as? Int) ?? 0) == 1 }, "Try Again imports")
        XCTAssertTrue(waitUntil(15) { !self.app.tabBars.buttons["More"].isHittable })
    }

    @MainActor func testImport_EmptyErrorSearchAndBot() throws {
        try account.control("/__fixture/foreign", ["empty": true])
        launchSignedIn(["-HQImportForgetBot", "YES"])
        openPage()
        XCTAssertTrue(app.staticTexts["No Conversations Found"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Claude Code and Codex sessions on the computer running Hermes will appear here."].exists)
        XCTAssertTrue(app.segmentedControls.buttons["Codex"].exists, "the source can still be changed")
        shot("import-empty")
        back()

        // A slow first read that then fails: the skeleton, then the error state; Try Again works.
        try account.control("/__fixture/foreign", ["empty": false, "delay": 4, "error": "the scan broke", "error_method": "list"])
        openPage()
        XCTAssertTrue(app.otherElements["more.page.loading"].waitForExistence(timeout: 3) || app.staticTexts["Finding Conversations…"].exists,
                      "the skeleton shows while the scan is slow")
        shot("import-loading")
        XCTAssertTrue(app.staticTexts["Couldn’t Find Sessions"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'An older Hermes may need an update. (the scan broke)'")).firstMatch.exists)
        shot("import-error")
        app.buttons["Try Again"].firstMatch.tap()
        XCTAssertTrue(row(0).waitForExistence(timeout: 20), "Try Again reads the list")

        // Search over the loaded rows, behind the magnifier.
        app.buttons["import-sessions.search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.placeholderValue, "Search Loaded Sessions")
        field.typeText("pricing")
        XCTAssertTrue(waitUntil(10) { self.row(1).exists && !self.row(0).exists }, "only matching rows stay")
        shot("import-search")
        field.typeText(" zzzz")
        XCTAssertTrue(app.staticTexts["No Matching Conversations"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Try another title or folder, or load more sessions."].exists)
        shot("import-search-miss")
        let listsBefore = try listCalls().count
        let close = app.navigationBars.buttons["Close"]
        if close.exists { close.tap() }
        else { app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.905, dy: 0.073)).tap() }
        XCTAssertTrue(row(0).waitForExistence(timeout: 10))
        XCTAssertEqual(try listCalls().count, listsBefore, "search never asks the gateway")

        // Import Into another bot: the list is read for it, and the import goes to it.
        let picker = app.buttons["more.bot-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "more than one bot: Import Into")
        picker.tap()
        XCTAssertTrue(app.buttons["Inbox"].waitForExistence(timeout: 8))
        shot("import-bot-menu")
        app.buttons["Inbox"].tap()
        XCTAssertTrue(waitUntil(15) { ((try? self.listCalls().last?["profile"] as? String) ?? nil) == "inbox" })
        XCTAssertTrue(row(0).waitForExistence(timeout: 15))
        row(0).tap()
        XCTAssertTrue(app.buttons["import-sessions.import"].waitForExistence(timeout: 15))
        app.buttons["import-sessions.import"].tap()
        XCTAssertTrue(waitUntil(20) { ((try? self.foreign()["imports"] as? Int) ?? 0) == 1 })
        XCTAssertEqual((try rpc("session.foreign.import").last?["params"] as? [String: Any]) as? [String: String], ["id": "fs-0000", "profile": "inbox"])
        XCTAssertEqual(((try state()["writes"] as? [[String: Any]]) ?? []).first?["profile"] as? String, "inbox")
    }

    // MARK: Stress

    @MainActor func testImport_RapidLoadMoreAndBadRows() throws {
        try account.control("/__fixture/foreign", ["duplicates": true, "bad_rows": true, "delay": 2, "delay_count": 4])
        launchSignedIn(["-HQImportForgetBot", "YES"])
        openPage()
        XCTAssertTrue(row(0).waitForExistence(timeout: 25), "rows of the wrong shape are skipped, the rest list")
        // Three quick taps while the page is slow: one request.
        XCTAssertTrue(loadMore(taps: 3))
        XCTAssertTrue(waitForPages(2))
        XCTAssertEqual(closingCount(), "100 sessions loaded.", "the overlapping row is not listed twice")
        XCTAssertEqual(try listCalls().filter { ($0["offset"] as? Int) == 50 }.count, 1, "rapid taps ask once")
        XCTAssertTrue(loadMore(taps: 3))
        XCTAssertTrue(waitForPages(3))
        XCTAssertEqual(closingCount(), "120 sessions.")
        XCTAssertEqual(try listCalls().filter { ($0["offset"] as? Int) == 100 }.count, 1)
    }

    @MainActor func testImport_TwoThousandRowsPaged() throws {
        try account.control("/__fixture/foreign", ["rows": 2000])
        launchSignedIn(["-HQImportForgetBot", "YES"])
        openPage()
        XCTAssertTrue(row(0).waitForExistence(timeout: 20))
        let started = Date()
        var pages = 1
        while pages < 45, loadMore() {
            pages += 1
            XCTAssertTrue(waitForPages(pages), "page \(pages) is asked for")
        }
        XCTAssertEqual(pages, 40)
        XCTAssertEqual(closingCount(), "2,000 sessions.")
        measured("Import Sessions: 2,000 rows paged in \(String(format: "%.0f", Date().timeIntervalSince(started))) s")
        XCTAssertEqual(try listCalls().count, 40)
        // The list still answers: the last row opens its preview.
        let last = row(1999)
        for _ in 0..<6 where !last.exists || !last.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(last.exists)
        last.tap()
        XCTAssertTrue(app.buttons["import-sessions.import"].waitForExistence(timeout: 15))
    }

    @MainActor func testImport_RelaunchAndReadOnly() throws {
        launchSignedIn(["-HQImportForgetBot", "YES"])
        openPage()
        XCTAssertTrue(row(0).waitForExistence(timeout: 20))
        row(0).tap()
        XCTAssertTrue(app.buttons["import-sessions.import"].waitForExistence(timeout: 15))
        again()
        XCTAssertTrue(waitUntil(20) { self.app.tabBars.buttons["More"].exists || self.app.navigationBars.buttons.firstMatch.exists })
        openPage()
        XCTAssertTrue(row(0).waitForExistence(timeout: 20), "the page reads again after a relaunch")

        // A read-only gateway: the list and the preview read; Import is not offered.
        again(["-HQDebugReadOnly", "YES"])
        openPage()
        XCTAssertTrue(row(0).waitForExistence(timeout: 20))
        row(0).tap()
        XCTAssertTrue(app.staticTexts["You"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["import-sessions.import"].exists, "no Import on a read-only gateway")
        back()
        bringRow(2).tap()
        XCTAssertTrue(app.buttons["import-sessions.import"].waitForExistence(timeout: 15), "an existing copy can still be opened")
        XCTAssertEqual(app.buttons["import-sessions.import"].label, "Open in Hermes")
        XCTAssertEqual(try rpc("session.foreign.import").count, 0)
    }
}
