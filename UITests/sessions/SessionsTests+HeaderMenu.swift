// [header-menus] A header's ⋯ on the Sessions list (owner 2026-11-03, menu review "Actions you can only reach by
// long-press"): Rename Project…, Delete Project… and the order rows were only a hold on a project's header away. The ⋯
// opens the same menu; a tap on the row still opens and closes the project.

import XCTest

extension SessionsTests {
    /// The ⋯ on a header (a project's, Home's, a bot's under Group By Bot), by the header's title.
    @MainActor func headerMenuButton(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'sessions.header.menu' AND label == %@", "Actions for \(title)")).firstMatch
    }

    /// Taps a header's ⋯ until its menu shows `item`.
    @MainActor func openHeaderMenu(_ app: XCUIApplication, _ title: String, until item: String) {
        let button = headerMenuButton(app, title)
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(title)'s ⋯")
        for _ in 0..<3 where !app.buttons[item].firstMatch.exists {
            button.tap()
            _ = app.buttons[item].firstMatch.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(app.buttons[item].firstMatch.exists, "\(item) in \(title)'s ⋯ menu")
    }

    @MainActor func test23e_ProjectHeaderMenuButton() throws {
        // The iOS look, the largest text size and Desktop Look (the screenshots check the ⋯ never crowds the name).
        for look in ["ios", "ax5", "desktoplook"] {
            let desktop = look == "desktoplook"
            let extra: [String] = switch look {
            case "desktoplook": ["-HQDebugDesktopLook", "YES"]
            case "ax5": ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            default: []
            }
            let app = launch(extra: extra)
            XCTAssertTrue(row(app, "s-release").waitForExistence(timeout: 15), "the first row (\(look))")   // at AX5 the garden chat is below the fold
            Thread.sleep(forTimeInterval: 1)
            shot(app, "header-menu-recent-\(look)")                // as it opens: Recent, the projects under "Projects"
            var offered = false
            for _ in 0..<4 where !offered {
                openFilter(app)
                tapFilter(app, "group")
                offered = filterItem(app, "group.project").waitForExistence(timeout: 3)
                if !offered { closeFilter(app) }
            }
            XCTAssertTrue(offered, "Group By offers Project")
            tapFilter(app, "group.project")
            if look != "ax5" {   // at AX5 the projects start below the fold: reveal scrolls to Website
                XCTAssertTrue(waitUntil(6) { self.headers(app).contains { $0.hasPrefix("Website") } }, "project headers (\(headers(app)))")
            }
            closeFilter(app)
            let site = header(app, "Website")
            reveal(app, site)
            XCTAssertTrue(site.exists, "Website's header (\(look)): \(headers(app))")
            Thread.sleep(forTimeInterval: 0.5)
            shot(app, "header-menu-projects-\(look)")
            let button = headerMenuButton(app, "Website")
            XCTAssertTrue(button.waitForExistence(timeout: 5), "Website's header has its ⋯ (\(look))")
            XCTAssertGreaterThanOrEqual(button.frame.width, 44, "a 44 pt target across (\(look))")
            XCTAssertGreaterThanOrEqual(button.frame.height, desktop ? 34 : 44, "and down (\(look))")
            XCTAssertGreaterThan(button.frame.minX, site.frame.midX, "at the trailing edge (\(look))")
            openHeaderMenu(app, "Website", until: "Rename Project…")
            // At AX5 the menu scrolls: the items past its first screen aren't there to find.
            let items = look == "ax5" ? ["New Chat"] : ["New Chat", "Add to Favorites", "Move Up", "Reorder Projects…", "Delete Project…"]
            for item in items {
                XCTAssertTrue(app.buttons[item].firstMatch.exists, "\(item) in the ⋯ menu, as in the hold menu (\(look))")
            }
            shot(app, "header-menu-open-\(look)")
            guard look == "ios" else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.15)).tap()
                XCTAssertTrue(waitUntil(4) { !app.buttons["Rename Project…"].exists }, "the menu closes")
                app.terminate()
                continue
            }
            // Its Rename Project… is the hold menu's: the rename prompt; Cancel sends nothing.
            app.buttons["Rename Project…"].firstMatch.tap()
            let field = app.textFields["project.rename"]
            XCTAssertTrue(field.waitForExistence(timeout: 3), "the rename prompt")
            press(app.alerts["Rename Project"].buttons["Cancel"])
            XCTAssertTrue(waitUntil(3) { !field.exists }, "the prompt goes")
            XCTAssertTrue(rpc("projects.update").isEmpty, "nothing renamed")
            // Delete Project… asks first, from the ⋯ too.
            openHeaderMenu(app, "Website", until: "Delete Project…")
            app.buttons["Delete Project…"].firstMatch.tap()
            let alert = app.alerts["Delete “Website”?"]
            XCTAssertTrue(alert.waitForExistence(timeout: 3), "asked first")
            press(alert.buttons["Cancel"])
            XCTAssertTrue(waitUntil(3) { !alert.exists })
            XCTAssertTrue(rpc("projects.delete").isEmpty, "nothing deleted")
            // Home's ⋯ holds its order rows only, as its hold menu.
            let home = header(app, "Home")
            reveal(app, home)
            openHeaderMenu(app, "Home", until: "Add to Favorites")
            XCTAssertFalse(app.buttons["Rename Project…"].exists, "Home can't be renamed")
            XCTAssertFalse(app.buttons["Delete Project…"].exists, "or deleted")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.15)).tap()
            XCTAssertTrue(waitUntil(4) { !app.buttons["Add to Favorites"].exists }, "Home's menu closed")
            // A tap on the row (not its ⋯) still opens the project; the open card keeps the ⋯.
            reveal(app, site)
            openProject(app, "Website")
            XCTAssertFalse(app.buttons["Rename Project…"].exists, "the row's tap opens no menu")
            XCTAssertTrue(headerMenuButton(app, "Website").exists, "the open card's header keeps its ⋯")
            Thread.sleep(forTimeInterval: 0.6)
            shot(app, "header-menu-open-card-ios")
            // Group By Bot: a bot's header has the ⋯ for its order rows.
            openFilter(app)
            tapFilter(app, "group", "group.bot")
            closeFilter(app)
            XCTAssertTrue(waitUntil(8) { self.headerMenuButton(app, "Hermes").exists }, "Hermes's header has its ⋯")
            openHeaderMenu(app, "Hermes", until: "Reorder Bots…")
            shot(app, "header-menu-bot-group-ios")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.15)).tap()
            app.terminate()
        }
    }
}
