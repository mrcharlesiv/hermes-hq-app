// [manual-order] Hand-picked orders on the Sessions list (tester and the owner, Nous Discord 2026-10-29): a
// project header's hold menu moves it (Home too) and makes it a Favorite (on top, with a star); Group By › Reorder
// Projects… opens the Reorder page; Group By Bot draws a group per bot; Sort By Manual keeps the chats where the row
// menu's Move Up / Move Down (or a drag) put them, across launches.

import XCTest

extension SessionsTests {
    /// Holds a header until its menu shows, then picks `item` (its title: SwiftUI's menu rows don't carry identifiers).
    @MainActor func headerMenu(_ app: XCUIApplication, _ title: String, _ item: String, file: StaticString = #filePath, line: UInt = #line) {
        let target = header(app, title)
        XCTAssertTrue(target.waitForExistence(timeout: 8), "the \(title) header", file: file, line: line)
        reveal(app, target)
        let button = app.buttons[item].firstMatch
        for _ in 0..<3 where !button.exists {
            target.press(forDuration: 1.2)
            _ = button.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(button.exists, "\(item) in the \(title) header's menu", file: file, line: line)
        button.tap()
    }

    /// Holds `row` and drags it onto the top of `onto`. A straight, slow drag never lifts a row out of its hold menu
    /// under XCUITest (the finger slides into the menu); a sideways part at the default speed does (as the Bots tests).
    @MainActor func dragRow(_ app: XCUIApplication, _ row: XCUIElement, onto: XCUIElement) {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let from = origin.withOffset(CGVector(dx: row.frame.midX, dy: row.frame.midY))
        let to = origin.withOffset(CGVector(dx: onto.frame.midX + 90, dy: onto.frame.minY + onto.frame.height * 0.2))
        from.press(forDuration: 0.6, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 1.0)
    }

    /// The headers after New for You and Pinned, top to bottom (titles only; a closed one adds its count).
    @MainActor func groupTitles(_ app: XCUIApplication) -> [String] {
        headers(app).filter { $0 != "Pinned" && $0 != "New for You" }.map { $0.components(separatedBy: ",")[0] }
    }

    @MainActor func test99a_DeleteEmptyProjectFromReorder() throws {
        fixture("/__fixture/rows", ["id": "s-budget", "delete": true])
        fixture("/__fixture/mode", ["projects": "found"])
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openFilter(app)
        tapFilter(app, "group", "group.project")
        closeFilter(app)
        XCTAssertFalse(groupTitles(app).contains("Website"), "the project has no visible chat")
        openFilter(app)
        tapFilter(app, "group", "group.reorder")
        XCTAssertTrue(app.navigationBars["Reorder Projects"].waitForExistence(timeout: 6))
        let delete = app.buttons["group-order.delete.Website"]
        XCTAssertTrue(delete.waitForExistence(timeout: 6), "the empty saved project can be deleted")
        XCTAssertFalse(app.buttons["group-order.delete.Home"].exists, "Home cannot be deleted")
        let autoRow = app.descendants(matching: .any)["group-order.checkout"].firstMatch
        XCTAssertTrue(autoRow.exists, "the discovered folder is listed")
        XCTAssertFalse(app.buttons["group-order.delete.checkout"].exists, "an automatically discovered folder cannot be deleted")
        delete.tap()
        let alert = app.alerts["Delete “Website”?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS 'kept'")).firstMatch.exists)
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS '/home/hermes/site'")).firstMatch.exists,
                      "the folder identifies the project")
        XCTAssertTrue(rpc("projects.delete").isEmpty, "nothing deleted before confirmation")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(rpc("projects.delete").isEmpty)
        openFilter(app)
        tapFilter(app, "group", "group.reorder")
        XCTAssertTrue(delete.waitForExistence(timeout: 6), "cancel keeps the project")
        delete.tap()
        fixture("/__fixture/fail", ["rpc": "projects.delete", "message": "try again", "count": 1])
        press(app.alerts["Delete “Website”?"].buttons["Delete Project"])
        let failure = app.alerts["Couldn’t Delete Project"]
        XCTAssertTrue(failure.waitForExistence(timeout: 8), "failure is shown")
        failure.buttons["OK"].tap()
        openFilter(app)
        tapFilter(app, "group", "group.reorder")
        XCTAssertTrue(delete.waitForExistence(timeout: 6), "failure keeps the project")
        delete.tap()
        press(app.alerts["Delete “Website”?"].buttons["Delete Project"])
        XCTAssertTrue(waitUntil(8) { self.rpc("projects.delete").filter {
            $0["profile"] as? String == "default" && $0["id"] as? String == "p_site"
        }.count == 2 }, "the saved project is retried")
        XCTAssertTrue(waitUntil(8) { app.descendants(matching: .any)["menus.hud"].exists }, "deletion completes")
        openFilter(app)
        tapFilter(app, "group", "group.reorder")
        XCTAssertFalse(app.buttons["group-order.delete.Website"].exists, "deleted project is no longer offered")
    }

    @MainActor func test99_ProjectOrderFavoritesBotGroupsAndManualSort() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openFilter(app)
        tapFilter(app, "group", "group.project")
        closeFilter(app)

        // The default: [project-pills] what needs you first (Website's unread reply), then the project with the newest
        // chat first, Home last.
        XCTAssertTrue(waitUntil(8) { self.groupTitles(app) == ["Website", "App", "Reading", "Home"] }, "\(groupTitles(app))")

        // Home moves like any project.
        headerMenu(app, "Home", "Move Up")
        XCTAssertTrue(waitUntil(6) { self.groupTitles(app) == ["Website", "App", "Home", "Reading"] }, "Home up: \(groupTitles(app))")

        // A favorite goes on top of its kind (the quiet ones here) and says so.
        headerMenu(app, "Reading", "Add to Favorites")
        XCTAssertTrue(waitUntil(6) { self.groupTitles(app) == ["Website", "Reading", "App", "Home"] }, "Reading a favorite: \(groupTitles(app))")
        XCTAssertTrue(headers(app).contains { $0.hasPrefix("Reading, Favorite") }, "\(headers(app))")
        shot(app, "order-favorite-project")

        // The Reorder page lists them in the list's order, the favorite under Favorites.
        openFilter(app)
        tapFilter(app, "group", "group.reorder")
        let sheet = app.navigationBars["Reorder Projects"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 6), "the Reorder Projects page")
        XCTAssertTrue(app.staticTexts["Favorites"].exists || app.staticTexts["FAVORITES"].exists)
        XCTAssertTrue(app.buttons["group-order.default"].exists, "Use Default Order (an order is in place)")
        shot(app, "order-reorder-page")
        app.buttons["group-order.default"].tap()
        app.buttons["sheet.close"].firstMatch.tap()
        XCTAssertTrue(waitUntil(6) { self.groupTitles(app) == ["Website", "Reading", "App", "Home"] }, "default again, the favorite on top of the quiet ones")

        // Kept across launches.
        app.terminate()
        var again = launch(keepView: true, drag: true)
        XCTAssertTrue(waitUntil(15) { self.groupTitles(again) == ["Website", "Reading", "App", "Home"] }, "after relaunch: \(groupTitles(again))")

        // Group By Bot: one group per bot (Deploys' chat is pinned), the bot with the newest chat first; a bot moves.
        openFilter(again)
        tapFilter(again, "group", "group.bot")
        closeFilter(again)
        XCTAssertTrue(waitUntil(8) { self.groupTitles(again) == ["Hermes", "Research"] }, "\(groupTitles(again))")
        headerMenu(again, "Research", "Move Up")
        XCTAssertTrue(waitUntil(6) { self.groupTitles(again) == ["Research", "Hermes"] }, "\(groupTitles(again))")
        shot(again, "order-group-by-bot")

        // Sort By Manual (Group By Recent): a row's menu moves it inside Recent.
        // [sessions-fresh] Pinned stays first; unread chats remain in Recent, not a New for You section.
        openFilter(again)
        tapFilter(again, "group", "group.date")
        closeFilter(again)
        openFilter(again)
        tapFilter(again, "sort", "sort.manual")
        closeFilter(again)
        XCTAssertTrue(waitUntil(8) { Array(self.order(again).prefix(4)) == ["s-release", "s-garden", "s-trip", "s-budget"] }, "\(order(again))")
        openMenu(again, row(again, "s-trip"), until: "Move Up")
        again.buttons["Move Up"].firstMatch.tap()
        XCTAssertTrue(waitUntil(6) { Array(self.order(again).prefix(4)) == ["s-release", "s-trip", "s-garden", "s-budget"] }, "\(order(again))")
        shot(again, "order-manual-moved")

        // A drag puts it back (hold, then drag over the other row).
        dragRow(again, row(again, "s-garden"), onto: row(again, "s-trip"))
        XCTAssertTrue(waitUntil(6) { Array(self.order(again).prefix(4)) == ["s-release", "s-garden", "s-trip", "s-budget"] }, "dragged: \(order(again))")

        // Manual and the order are kept across launches.
        openMenu(again, row(again, "s-garden"), until: "Move Down")
        again.buttons["Move Down"].firstMatch.tap()
        XCTAssertTrue(waitUntil(6) { Array(self.order(again).prefix(4)) == ["s-release", "s-trip", "s-garden", "s-budget"] }, "\(order(again))")
        again.terminate()
        again = launch(keepView: true)
        XCTAssertTrue(waitUntil(15) { Array(self.order(again).prefix(4)) == ["s-release", "s-trip", "s-garden", "s-budget"] }, "after relaunch: \(order(again))")
        openFilter(again)
        XCTAssertTrue(filterWords(again, "sort").contains("Manual"), filterWords(again, "sort"))
        closeFilter(again)
    }

    @MainActor func test99b_DragAChat() throws {
        let app = launch(drag: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        dragRow(app, row(app, "s-trip"), onto: row(app, "s-garden"))
        XCTAssertTrue(waitUntil(6) { Array(self.order(app).prefix(4)) == ["s-release", "s-trip", "s-garden", "s-budget"] }, "dragged: \(order(app))")
        shot(app, "order-dragged")
        openFilter(app)
        XCTAssertTrue(filterWords(app, "sort").contains("Manual"), filterWords(app, "sort"))
        closeFilter(app)
    }

    /// The same screens under Desktop Look: a favorite's star, the header menu, the Reorder page, Group By Bot.
    @MainActor func test99c_OrderInDesktopLook() throws {
        let app = launch(extra: ["-HQDebugDesktopLook", "YES"])
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openFilter(app)
        tapFilter(app, "group", "group.project")
        closeFilter(app)
        XCTAssertTrue(waitUntil(8) { self.groupTitles(app).count == 4 }, "\(groupTitles(app))")
        headerMenu(app, "Website", "Add to Favorites")
        XCTAssertTrue(waitUntil(6) { self.groupTitles(app).first == "Website" }, "\(groupTitles(app))")
        shot(app, "order-favorite-project-desktoplook")
        let target = header(app, "Home")
        for _ in 0..<3 where !app.buttons["Move Up"].exists {
            target.press(forDuration: 1.2)
            _ = app.buttons["Move Up"].waitForExistence(timeout: 3)
        }
        shot(app, "order-header-menu-desktoplook")
        app.buttons["Move Up"].firstMatch.tap()
        openFilter(app)
        tapFilter(app, "group", "group.reorder")
        XCTAssertTrue(app.navigationBars["Reorder Projects"].waitForExistence(timeout: 6))
        shot(app, "order-reorder-page-desktoplook")
        app.buttons["sheet.close"].firstMatch.tap()
        openFilter(app)
        tapFilter(app, "group", "group.bot")
        closeFilter(app)
        XCTAssertTrue(waitUntil(8) { self.groupTitles(app) == ["Hermes", "Research"] }, "\(groupTitles(app))")
        shot(app, "order-group-by-bot-desktoplook")
    }

    /// [drag-to-project] Under Group By Project a chat dragged onto another project moves there (owner 2026-10-30): its
    /// own bot's project (`session.workspace.move` to its folder), or, for a bot without that project, the project given
    /// to the bot first (`projects.create`, same name and folder). Home and the chat's own project take no drop.
    @MainActor func test99d_DragAChatToAnotherProject() throws {
        let app = launch(drag: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        openFilter(app)
        tapFilter(app, "group", "group.project")
        closeFilter(app)
        XCTAssertTrue(waitUntil(8) { self.groupTitles(app) == ["Website", "App", "Reading", "Home"] }, "\(groupTitles(app))")
        // [sessions-layout] Projects start folded: open the ones the drags read. [project-pills] Website (first now, as
        // it holds an unread reply) opens only for its drop, so Home's header stays on screen for the first drag.
        for project in ["App", "Reading"] { openProject(app, project) }
        shot(app, "drag-project-before")

        // Onto Home: nothing moves (a chat leaves a project only by its folder).
        dragRow(app, row(app, "s-trip"), ontoHeader: header(app, "Home"))
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(rpc("session.workspace.move").isEmpty, "Home takes no drop")

        // Research's Trip to Lisbon (in Reading) onto App, which Research has no project for: Research is given App
        // first (same name and folder), then the chat moves into it.
        dragRow(app, row(app, "s-trip"), ontoHeader: header(app, "App"))
        XCTAssertTrue(waitUntil(6) { self.rpc("projects.create").contains {
            $0["profile"] as? String == "research" && ($0["folders"] as? [String]) == ["/home/hermes/app"] && $0["name"] as? String == "App" } },
            "\(rpc("projects.create"))")
        XCTAssertTrue(waitUntil(6) { self.rpc("session.workspace.move").contains {
            $0["session_key"] as? String == "s-trip" && $0["cwd"] as? String == "/home/hermes/app" } }, "\(rpc("session.workspace.move"))")
        XCTAssertTrue(waitUntil(6) { self.rows(under: "App", app).contains("s-trip") }, "listed under App: \(order(app))")
        shot(app, "drag-project-other-bot")

        // Hermes's Garden plan (in App) onto Website's header: its own bot's project.
        openProject(app, "Website")
        dragRow(app, row(app, "s-garden"), ontoHeader: header(app, "Website"))
        XCTAssertTrue(waitUntil(6) { self.rpc("session.workspace.move").contains {
            $0["session_key"] as? String == "s-garden" && $0["cwd"] as? String == "/home/hermes/site" } }, "\(rpc("session.workspace.move"))")
        XCTAssertTrue(app.descendants(matching: .any)["menus.hud"].waitForExistence(timeout: 4), "Moved to Website")
        XCTAssertTrue(waitUntil(6) { self.rows(under: "Website", app).contains("s-garden") }, "listed under Website: \(order(app))")
        XCTAssertEqual(rpc("projects.create").count, 1, "Hermes already has Website: nothing is made")
        shot(app, "drag-project-moved")
    }

    /// The same two under Desktop Look: More's pull-down, and a chat dragged onto another project.
    @MainActor func test99e_MoreAndDragInDesktopLook() throws {
        let app = launch(drag: true, extra: ["-HQDebugDesktopLook", "YES"])
        let garden = row(app, "s-garden")
        XCTAssertTrue(garden.waitForExistence(timeout: 15))
        openFilter(app)
        tapFilter(app, "group", "group.project")
        closeFilter(app)
        XCTAssertTrue(waitUntil(8) { self.groupTitles(app).count == 4 }, "\(groupTitles(app))")
        openProject(app, "App")                            // [sessions-layout] projects start folded
        XCTAssertTrue(garden.waitForExistence(timeout: 6))
        swipe(garden, left: true)
        let more = app.buttons.matching(NSPredicate(format: "label == 'More'")).allElementsBoundByIndex
            .first { abs($0.frame.midY - garden.frame.midY) < 30 }
        XCTAssertNotNil(more, "the swipe's More")
        more?.tap()
        XCTAssertTrue(app.buttons["Rename…"].firstMatch.waitForExistence(timeout: 4), "More opens the row's menu")
        XCTAssertFalse(app.sheets.firstMatch.exists, "a menu, not an action sheet")
        shot(app, "more-swipe-menu-desktoplook")
        // Outside the menu, beside it (it opens up or down with the row's place on screen).
        let item = app.buttons["Rename…"].firstMatch.frame
        let side: CGFloat = item.maxX < app.frame.width * 0.8 ? 0.92 : 0.08
        app.coordinate(withNormalizedOffset: CGVector(dx: side, dy: item.midY / app.frame.height)).tap()
        XCTAssertTrue(waitUntil(3) { !app.buttons["Rename…"].firstMatch.exists })

        dragRow(app, garden, ontoHeader: header(app, "Website"))
        XCTAssertTrue(waitUntil(6) { self.rpc("session.workspace.move").contains {
            $0["session_key"] as? String == "s-garden" && $0["cwd"] as? String == "/home/hermes/site" } }, "\(rpc("session.workspace.move"))")
        shot(app, "drag-project-moved-desktoplook")
    }

    /// Drags `row` and holds it over a group's header (its title, clear of the + at its end).
    @MainActor func dragRow(_ app: XCUIApplication, _ row: XCUIElement, ontoHeader header: XCUIElement) {
        XCTAssertTrue(header.waitForExistence(timeout: 5), "the header to drop on")
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let from = origin.withOffset(CGVector(dx: row.frame.midX, dy: row.frame.midY))
        let to = origin.withOffset(CGVector(dx: header.frame.minX + 60, dy: header.frame.midY))
        from.press(forDuration: 0.6, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 1.5)
    }

    /// The row ids drawn under the header titled `title`, up to the next header.
    @MainActor func rows(under title: String, _ app: XCUIApplication) -> [String] {
        let top = header(app, title)
        guard top.exists else { return [] }
        let below = app.descendants(matching: .any).matching(identifier: "sessions.header").allElementsBoundByIndex
            .map(\.frame.minY).filter { $0 > top.frame.maxY + 1 }.min() ?? .greatestFiniteMagnitude
        return app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'session-row-'")).allElementsBoundByIndex
            .filter { $0.frame.minY >= top.frame.maxY - 1 && $0.frame.minY < below }
            .map { String($0.identifier.dropFirst("session-row-".count)) }
    }
}
