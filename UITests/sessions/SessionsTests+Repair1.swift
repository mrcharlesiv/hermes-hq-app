// [sessions-m9] Regression tests for stress round 1 (docs/briefs/m9/sessions-report.md §10): the chips and the strip
// under an empty state, the plain words for a create that never answers, hostile Session Info values.

import XCTest

extension SessionsTests {
    /// A finger at the middle of an element (no accessibility activation: what a hand does).
    @MainActor private func touch(_ app: XCUIApplication, _ element: XCUIElement) {
        let frame = element.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
    }

    /// R1: with "No Matching Chats" showing, the chips and the strip still take a finger.
    @MainActor func testA1_ChipsAndStripOverNoMatchingChats() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openFilter(app)
        tapFilter(app, "status", "status.working")
        closeFilter(app)
        XCTAssertTrue(app.staticTexts["No Matching Chats"].waitForExistence(timeout: 5))
        XCTAssertTrue(strip(app).waitForExistence(timeout: 5))
        XCTAssertTrue(strip(app).isHittable, "the strip is not covered")
        XCTAssertTrue(chip(app, "default").isHittable, "a chip is not covered")
        touch(app, chip(app, "default"))
        XCTAssertTrue(waitUntil(5) { self.chip(app, "default").isSelected }, "a chip can be picked over the empty state")
        XCTAssertTrue(app.staticTexts["No Matching Chats"].exists, "still nothing matches")
        shot(app, "R1-chip-over-empty")
        touch(app, chip(app, "research"))
        XCTAssertTrue(waitUntil(5) { self.chip(app, "research").isSelected && !self.chip(app, "default").isSelected }, "and another")
        touch(app, strip(app))
        XCTAssertTrue(waitUntil(6) { !self.strip(app).exists }, "the strip clears over the empty state")
        XCTAssertTrue(waitUntil(6) { !app.staticTexts["No Matching Chats"].exists }, "the chats are back")
        XCTAssertTrue(chip(app, "research").isSelected, "the strip leaves the chip alone")
        shot(app, "R1-strip-cleared")
    }

    /// R1: a bot with no chats picked, then another chip tapped straight away (no Clear Filters in between).
    @MainActor func testA2_AnotherChipAfterABotWithNoChats() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        setRow("s-release", ["archived": true], event: true)
        XCTAssertTrue(waitUntil(15) { !self.row(app, "s-release").exists })
        chip(app, "deploys").tap()
        XCTAssertTrue(app.staticTexts["Deploys Has No Chats Yet"].waitForExistence(timeout: 5))
        touch(app, chip(app, "default"))
        XCTAssertTrue(waitUntil(5) { self.chip(app, "default").isSelected }, "another chip answers")
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 6), "and its chats show")
        touch(app, chip(app, "deploys"))
        XCTAssertTrue(app.staticTexts["Deploys Has No Chats Yet"].waitForExistence(timeout: 5))
        touch(app, chip(app, nil))
        XCTAssertTrue(waitUntil(5) { self.chip(app, nil).isSelected }, "All answers")
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 6))
    }

    /// R1: the other empty state (a search with no results) leaves the chips alive too. (Show › Archived had its own
    /// "No Archived Chats" until 2026-10-24; it adds rows to the list now, so it has none.)
    @MainActor func testA3_ChipsOverTheOtherEmptyStates() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        // A search that finds nothing.
        app.buttons["sessions.search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("zzqqxx")
        XCTAssertTrue(app.staticTexts["No Results for “zzqqxx”"].waitForExistence(timeout: 15))
        if chip(app, "default").exists {
            XCTAssertTrue(chip(app, "default").isHittable, "a chip is not covered by the search's empty state")
            touch(app, chip(app, "default"))
            XCTAssertTrue(waitUntil(5) { self.chip(app, "default").isSelected }, "a chip can be picked over a search miss")
        }
        shot(app, "R1-chip-over-search-miss")
    }

    /// R1: a New Project the gateway never answers ends in plain words; the transport's line is under Show Details.
    @MainActor func testA4_NewProjectNeverAnswersInPlainWords() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        chip(app, "default").tap()
        fixture("/__fixture/fail", ["rpc": "projects.create", "delay": 40, "count": 1])
        openFilter(app)
        tapFilter(app, "project", "project.new")
        let alert = app.alerts["New Project"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "the New Project alert")
        fill(alert.textFields["project.name"], "Slow")
        fill(alert.textFields["project.folder"], "~/Projects/slow")
        press(alert.buttons["Create"])
        let failed = app.alerts["Couldn’t Create Project"]
        XCTAssertTrue(failed.waitForExistence(timeout: 60), "the failure, after the 30 s the call is given")
        let words = failed.staticTexts.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(words.contains("Your gateway didn’t answer in time. Try again in a moment."), "plain words (\(words))")
        XCTAssertFalse(words.contains { $0.contains("timed out") || $0.contains("projects.create") }, "no transport words (\(words))")
        XCTAssertTrue(failed.buttons["Try Again"].exists)
        shot(app, "R1-create-no-answer")
        failed.buttons["Show Details"].tap()
        let raw = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'projects.create'")).firstMatch
        let rawText = app.textViews.containing(NSPredicate(format: "value CONTAINS 'projects.create'")).firstMatch
        XCTAssertTrue(waitUntil(8) { raw.exists || rawText.exists }, "Show Details keeps the transport's own line")
        shot(app, "R1-create-no-answer-details")
    }

    /// R1: a very long title keeps Session Info's rows on the first screen; an absurd token figure is capped.
    @MainActor func testA5_HostileSessionInfoStaysReadable() throws {
        setRow("s-trip", ["title": "Lisbon " + String(repeating: "W", count: 400),
                          "usage": ["total": 1e18, "input": 5_000_000_000, "output": 2_500_000_000_000]])
        let app = launch()
        XCTAssertTrue(row(app, "s-trip").waitForExistence(timeout: 15))
        openChat(app, "s-trip")
        openSessionInfo(app)
        let title = app.staticTexts["info.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let list = app.tables["info.list"].frame
        XCTAssertLessThan(title.frame.height, 130, "the title stops at three lines (\(title.frame.height))")
        XCTAssertTrue(title.label.hasPrefix("Lisbon WWW") && title.label.count > 400, "VoiceOver still has the whole title")
        let first = app.tables["info.list"].cells.firstMatch
        XCTAssertTrue(first.exists && first.frame.minY < list.maxY - 44, "the first row is on the first screen (\(first.frame) in \(list))")
        shot(app, "R1-info-long-title")
        if hasInfoRow(app, "Tokens") {
            let tokens = infoRow(app, "Tokens")
            XCTAssertFalse(tokens.contains("0000"), "no run of zeros (\(tokens))")
            XCTAssertTrue(tokens.contains("999T+"), "the cap (\(tokens))")
        }
    }
}
