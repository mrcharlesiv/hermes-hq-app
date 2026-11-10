// Sessions groups that fold (tester ivy, Nous Research Discord, 2026-10-26): under Group By Project a project draws its
// newest five chats and "Show More (X)", which opens it in place ("Show Less" after); a tap on a header (Pinned, a project,
// a date) closes the group to its name, count and chevron, kept across launches; a status filter shows every match anyway.
// [sessions-layout] A project starts folded to its summary row and opens on a tap (owner, 2026-10-31).

import XCTest

extension SessionsTests {
    /// Seven more chats in Website (with Quarterly budget, eight): the newest five show, three wait behind Show More.
    func addWebsiteChats() {
        let now = nowSeconds
        for index in 1...7 {
            setRow("s-w\(index)", ["profile": "default", "title": "Website page \(index)", "cwd": "/home/hermes/site",
                                   "last_active": now - Double(index) * 400], event: index == 7)
        }
    }

    /// The header of the group titled `title` (it folds: a button with the header's identifier).
    @MainActor func header(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'sessions.header' AND label BEGINSWITH %@", title)).firstMatch
    }

    /// [sessions-layout] Group By Project: a project starts folded to its summary row; this opens it (a tap on the row)
    /// and waits for its chats.
    @MainActor func openProject(_ app: XCUIApplication, _ title: String) {
        let project = header(app, title)
        XCTAssertTrue(project.waitForExistence(timeout: 6), "\(title)'s row")
        reveal(app, project)
        if (project.value as? String)?.hasPrefix("Collapsed") == true { project.tap() }
        XCTAssertTrue(waitUntil(6) { (project.value as? String)?.hasPrefix("Expanded") == true }, "\(title) opens")
    }

    /// Scrolls the list a little at a time until `element` sits clear of the tab bar.
    @MainActor func reveal(_ app: XCUIApplication, _ element: XCUIElement) {
        let list = app.collectionViews["sessions.list"]
        for _ in 0..<8 {
            if element.exists, element.frame.maxY < app.frame.height * 0.86, element.isHittable { return }
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    @MainActor func test98_GroupsFoldAndShowMore() throws {
        addWebsiteChats()
        let app = launch()
        XCTAssertTrue(row(app, "s-w1").waitForExistence(timeout: 15))
        openFilter(app)
        tapFilter(app, "group", "group.project")
        closeFilter(app)

        // [sessions-layout] Website starts folded to its row, counting all eight (the unread budget chat is in New for
        // You above, and counted here too). Open, it draws its newest five, then Show More (3). [project-cards] The
        // budget chat, its oldest, waits there: a chat in New for You is in its project too.
        let website = header(app, "Website")
        XCTAssertTrue(website.waitForExistence(timeout: 8), "the Website header")
        XCTAssertTrue((website.value as? String)?.hasPrefix("Collapsed") == true, "\(website.value ?? "")")
        XCTAssertTrue(((website.value as? String) ?? "").contains("8 chats, 1 unread"), "\(website.value ?? "")")
        XCTAssertFalse(row(app, "s-w1").exists, "a folded project draws no rows")
        openProject(app, "Website")
        let more = app.cells["sessions.showMore"].firstMatch
        reveal(app, more)                                  // below the newest five
        XCTAssertTrue(more.waitForExistence(timeout: 6), "Show More under Website")
        XCTAssertTrue(labelOf(more).contains("3 more"), labelOf(more))
        for index in 1...5 { XCTAssertTrue(row(app, "s-w\(index)").exists, "s-w\(index) among the newest five") }
        XCTAssertFalse(row(app, "s-w6").exists)
        // The budget chat stays in New for You, above Pinned; its second row is under Website's Show More.
        XCTAssertTrue(waitUntil(4) {
            let shown = self.order(app)
            return (shown.firstIndex(of: "s-budget") ?? .max) < (shown.firstIndex(of: "s-release") ?? -1)
                && !self.rows(under: "Website", app).contains { $0.hasSuffix("s-budget") }
        }, "the budget chat stays in New for You (\(order(app)))")
        reveal(app, more)
        shot(app, "groups-project")

        // Show More opens it in place; Show Less closes it to five again.
        more.tap()
        XCTAssertTrue(row(app, "s-w6").waitForExistence(timeout: 5), "the rest of Website")
        XCTAssertTrue(row(app, "s-w7").exists)
        XCTAssertTrue(app.cells["session-row-also-s-budget"].exists, "and the budget chat, in New for You too")
        let less = app.cells["sessions.showMore"].firstMatch
        reveal(app, less)
        XCTAssertTrue(waitUntil(5) { self.labelOf(less).contains("fewer") }, "Show Less (\(labelOf(less)))")
        let shown = order(app)
        XCTAssertEqual(Set(shown).count, shown.count, "no row listed twice (\(shown))")
        shot(app, "groups-show-more")
        less.tap()
        XCTAssertTrue(waitUntil(5) { !self.row(app, "s-w6").exists }, "back to five")
        app.swipeDown()

        // A header folds its group again; Pinned closes to its name, the count and the chevron.
        header(app, "Website").tap()
        XCTAssertTrue(waitUntil(5) { !self.row(app, "s-w1").exists }, "Website folded")
        XCTAssertFalse(app.cells["sessions.showMore"].exists, "no Show More under a folded project")
        XCTAssertTrue((header(app, "Website").value as? String)?.hasPrefix("Collapsed") == true)
        header(app, "Pinned").tap()
        XCTAssertTrue(waitUntil(5) { !self.row(app, "s-release").exists }, "Pinned closed")
        XCTAssertEqual(header(app, "Pinned").value as? String, "Collapsed")
        XCTAssertTrue((header(app, "App").value as? String)?.hasPrefix("Collapsed") == true, "the other projects stay folded")
        shot(app, "groups-collapsed")

        // Kept across launches.
        app.terminate()
        let again = launch(keepView: true)
        XCTAssertTrue(row(again, "s-budget").waitForExistence(timeout: 15))
        XCTAssertTrue((header(again, "Website").value as? String)?.hasPrefix("Collapsed") == true)
        XCTAssertEqual(header(again, "Pinned").value as? String, "Collapsed")
        XCTAssertFalse(row(again, "s-w1").exists)
        XCTAssertFalse(row(again, "s-release").exists)

        // A status filter shows its matches inside folded groups (no New for You under it); clearing it folds them again.
        openFilter(again)
        tapFilter(again, "status", "status.unread")
        closeFilter(again)
        XCTAssertTrue(waitUntil(6) { self.rows(under: "Website", again) == ["s-budget"] }, "the unread chat in folded Website shows (\(order(again)))")
        shot(again, "groups-filter-opens")
        openFilter(again)
        tapFilter(again, "status", "status.unread")
        closeFilter(again)
        XCTAssertTrue(waitUntil(6) { self.rows(under: "New for You", again) == ["s-budget"] && !self.row(again, "s-w1").exists },
                      "folded again without the filter (\(order(again)))")

        // Search finds a chat in a closed group.
        again.buttons["sessions.search"].tap()
        let field = again.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("release")
        XCTAssertTrue(row(again, "s-release").waitForExistence(timeout: 6), "search reaches into closed Pinned")
        if again.buttons["Cancel"].firstMatch.exists { again.buttons["Cancel"].firstMatch.tap() } else { field.buttons["Clear text"].firstMatch.tap() }
        XCTAssertTrue(waitUntil(6) { !self.row(again, "s-release").exists }, "closed again after the search")

        // Open again.
        XCTAssertTrue(header(again, "Pinned").waitForExistence(timeout: 6))
        header(again, "Pinned").tap()
        XCTAssertTrue(row(again, "s-release").waitForExistence(timeout: 5))
        openProject(again, "Website")
        XCTAssertTrue(row(again, "s-w1").waitForExistence(timeout: 5))
    }

    /// Every group closed (owner, 2026-10-29): the headers stay and "No Chats Yet" is not drawn behind them.
    @MainActor func test99_EveryGroupClosedIsNotEmpty() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openFilter(app)
        tapFilter(app, "group", "group.project")
        closeFilter(app)
        let open = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'sessions.header' AND value == 'Expanded'"))
        XCTAssertTrue(open.firstMatch.waitForExistence(timeout: 8), "an open header")
        for _ in 0..<12 where open.firstMatch.exists {
            open.firstMatch.tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertFalse(open.firstMatch.exists, "every group closed")
        XCTAssertFalse(app.staticTexts["No Chats Yet"].exists, "no empty state behind closed groups")
        XCTAssertGreaterThan(headers(app).count, 1, "the closed headers stay")
        shot(app, "groups-all-closed")
    }
}
