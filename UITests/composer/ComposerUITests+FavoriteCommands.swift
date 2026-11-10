// [favorite-commands] Starred commands (docs/spec/3x-composer.md §9.7) against the composer stand-in: a star in the
// Commands sheet puts the command in Favorites at the top (the tapped row holds still), and the slash drawer opens on
// them; typed, a starred match goes first.

import XCTest

extension ComposerUITests {
    @MainActor private func drawerRow(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "drawer.row.\(title)").firstMatch
    }

    /// The "Favorites" section header (a header-trait element, not a static text).
    @MainActor private func favoritesHeader(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Favorites")).firstMatch
    }

    /// The drawer's rows on screen, top to bottom ("/status", …).
    @MainActor private func drawerOrder(_ app: XCUIApplication) -> [String] {
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'drawer.row.'")).allElementsBoundByIndex
        return rows.filter { $0.exists && $0.frame.height > 0 }.sorted { $0.frame.minY < $1.frame.minY }
            .map { String($0.identifier.dropFirst("drawer.row.".count)) }
    }

    @MainActor private func fieldText(_ app: XCUIApplication) -> String {
        let v = IPad.field(app).value as? String ?? ""
        return v.hasPrefix("Message") ? "" : v
    }

    /// The Commands sheet through /help in the drawer (the ☰ button is iPhone-only).
    @MainActor private func openCommandsSheet(_ app: XCUIApplication) {
        _ = IPad.focusField(app)
        IPad.field(app).typeText("/he")
        let help = drawerRow(app, "/help")
        XCTAssertTrue(help.waitForExistence(timeout: 6))
        help.tap()
        XCTAssertTrue(app.descendants(matching: .any)["commands.sheet"].waitForExistence(timeout: 8), "the Commands sheet")
    }

    @MainActor func test26_StarredCommandsLeadTheSheetAndTheDrawer() throws {
        let (_, app) = try start()
        openCommandsSheet(app)
        let status = app.cells["commands.row./status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10), "rows load")
        XCTAssertFalse(favoritesHeader(app).exists, "no Favorites before a star")
        let star = app.buttons["commands.star./status"]
        XCTAssertTrue(star.exists)
        XCTAssertFalse(star.isSelected)
        let before = status.frame.minY
        star.tap()
        XCTAssertTrue(app.cells["commands.row.fav./status"].waitForExistence(timeout: 3), "/status joins Favorites")
        XCTAssertTrue(favoritesHeader(app).exists)
        XCTAssertTrue(star.isSelected, "its star is filled")
        XCTAssertEqual(status.frame.minY, before, accuracy: 2, "the starred row held still")
        app.buttons["commands.star./usage"].firstMatch.tap()
        XCTAssertTrue(app.cells["commands.row.fav./usage"].waitForExistence(timeout: 3))
        IPad.shot(app, "favorites-sheet", in: self)
        // Searching finds the rows in their own sections; Favorites steps aside.
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("usage")
        XCTAssertTrue(IPad.waitUntil(timeout: 3) { !app.cells["commands.row.fav./usage"].exists }, "no Favorites while searching")
        XCTAssertTrue(app.cells["commands.row./usage"].exists)
        app.buttons["sheet.cancel"].tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { !app.descendants(matching: .any)["commands.sheet"].exists })

        // A bare "/" opens the drawer on them, in starred order.
        _ = IPad.focusField(app)
        if !fieldText(app).isEmpty { IPad.field(app).typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: fieldText(app).count + 1)) }
        IPad.field(app).typeText("/")
        XCTAssertTrue(favoritesHeader(app).waitForExistence(timeout: 6), "the drawer opens on Favorites")
        XCTAssertTrue(IPad.waitUntil(timeout: 3) { self.drawerOrder(app).prefix(2) == ["/status", "/usage"] },
                      "in starred order (\(drawerOrder(app)))")
        XCTAssertLessThan(favoritesHeader(app).frame.minY, drawerRow(app, "/status").frame.minY)
        IPad.shot(app, "favorites-drawer", in: self)

        // Typed, the starred match goes first ("/st": /status before /stop).
        IPad.field(app).typeText("st")
        XCTAssertTrue(IPad.waitUntil(timeout: 6) { self.drawerOrder(app).first == "/status" && self.drawerOrder(app).contains("/stop") },
                      "the starred match leads (\(drawerOrder(app)))")
        IPad.field(app).typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3))
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { self.fieldText(app).isEmpty })

        // Unstarred in Favorites, the row leaves it (and stays in its own section).
        openCommandsSheet(app)
        let starred = app.buttons["commands.star.fav./status"]
        XCTAssertTrue(starred.waitForExistence(timeout: 10))
        XCTAssertTrue(starred.isSelected)
        IPad.shot(app, "favorites-sheet-top", in: self)
        starred.tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 3) { !app.cells["commands.row.fav./status"].exists }, "/status left Favorites")
        XCTAssertTrue(app.cells["commands.row.fav./usage"].exists, "/usage is still there")
        XCTAssertFalse(app.buttons["commands.star./status"].isSelected, "its star is empty again")
    }
}
