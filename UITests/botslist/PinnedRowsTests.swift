// [pinned-rows] Filter › Pinned Bots › Rows end to end against the Sessions fixture's demo list (Hermes and Inbox
// pinned; scripts/fixtures/sessions-gateway.py --seed demo): the pins become rows at the top with no header, a third pin
// joins them, a drag puts it first without touching Sort By, and the faces follow the same order. Run with
// scripts/e2e-pinned-rows.sh <SIM>.

import XCTest

final class PinnedRowsTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        guard env["HQN_PINNED_ROWS"] == "1" else { throw XCTSkip("Run scripts/e2e-pinned-rows.sh (the demo Sessions fixture).") }
        continueAfterFailure = false
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HQDebugAppearance", env["HQN_SHOTS_DARK"] == "1" ? "dark" : "light"]
        if let path = env["HQN_PINNED_CRED"], let data = FileManager.default.contents(atPath: path),
           let cred = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            app.launchEnvironment["HQN_SIGNIN_URL"] = cred["url"] as? String
            app.launchEnvironment["HQN_SIGNIN_USERNAME"] = cred["username"] as? String
            app.launchEnvironment["HQN_SIGNIN_PASSWORD"] = cred["password"] as? String
        }
        app.launch()
        let bots = app.buttons["tab-bots"]
        if bots.waitForExistence(timeout: 15) { bots.tap() }
        XCTAssertTrue(waitUntil(timeout: 20) { app.cells["bot-row-research"].exists }, "the Bots list shows")
        return app
    }

    @MainActor private func shot(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.8)
        let screenshot = app.screenshot()
        if let dir = env["HQN_SHOTS"], !dir.isEmpty {
            let mode = env["HQN_SHOTS_DARK"] == "1" ? "dark" : "light"
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(mode).png"))
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A menu item by its title (its label may carry its subtitle after a comma).
    @MainActor private func item(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")).firstMatch
    }

    /// Filter › Pinned Bots, open (its two choices showing).
    @MainActor private func openPinnedBots(_ app: XCUIApplication) {
        let filter = app.buttons["bots.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        let entry = item(app, "Pinned Bots")
        for _ in 0..<3 where !entry.exists {
            filter.tap()
            _ = entry.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(entry.exists, "Filter has Pinned Bots")
        entry.tap()
        XCTAssertTrue(app.buttons["filter.pinned.rows"].waitForExistence(timeout: 5), "its choices open")
    }

    @MainActor private func pick(_ app: XCUIApplication, _ look: String) {
        openPinnedBots(app)
        app.buttons["filter.pinned.\(look)"].tap()
    }

    /// The bots' rows above the first section header, top first.
    @MainActor private func topRows(_ app: XCUIApplication) -> [String] {
        let header = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'section-header-'")).firstMatch
        let limit = header.exists ? header.frame.minY : .greatestFiniteMagnitude
        return app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'bot-row-'")).allElementsBoundByIndex
            .filter { $0.exists && $0.frame.midY < limit }
            .sorted { $0.frame.midY < $1.frame.midY }
            .map { String($0.identifier.dropFirst("bot-row-".count)) }
    }

    @MainActor private func tiles(_ app: XCUIApplication) -> [String] {
        app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'bot-tile-'")).allElementsBoundByIndex
            .filter(\.exists)
            .sorted { $0.frame.minY != $1.frame.minY ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX }
            .map { String($0.identifier.dropFirst("bot-tile-".count)) }
    }

    @MainActor private func holdMenu(_ app: XCUIApplication, _ id: String, _ title: String) {
        let row = app.cells["bot-row-\(id)"]
        for _ in 0..<3 where !item(app, title).exists {
            row.press(forDuration: 1.0)
            _ = item(app, title).waitForExistence(timeout: 3)
        }
        XCTAssertTrue(item(app, title).exists, "\(id)'s menu has \(title)")
        shot(app, "menu-\(id)")
        item(app, title).tap()
    }

    @MainActor func testPinnedRows() throws {
        let app = launch()
        // Faces, as everyone starts.
        pick(app, "faces")
        XCTAssertTrue(app.cells["bot-tile-default"].waitForExistence(timeout: 5) && app.cells["bot-tile-inbox"].exists, "Hermes and Inbox are faces")
        shot(app, "1-faces")

        openPinnedBots(app)
        shot(app, "2-pinned-bots-menu")
        app.buttons["filter.pinned.rows"].tap()

        // Rows: the pins are rows at the top, no faces and no Pinned header.
        XCTAssertTrue(waitUntil(timeout: 5) { !app.cells["bot-tile-default"].exists }, "no faces")
        XCTAssertTrue(app.cells["bot-row-default"].waitForExistence(timeout: 5) && app.cells["bot-row-inbox"].exists, "Hermes and Inbox are rows")
        XCTAssertFalse(app.cells["section-header-Pinned"].exists, "no Pinned header")
        let pins = topRows(app)
        XCTAssertEqual(Set(pins.prefix(2)), ["default", "inbox"], "the pins lead the list: \(pins)")
        shot(app, "3-rows")

        // A third pin joins the rows at the top, after the others.
        holdMenu(app, "research", "Pin")
        XCTAssertTrue(waitUntil(timeout: 8) { self.topRows(app).prefix(3).last == "research" }, "Research is the third pin: \(topRows(app))")
        shot(app, "4-third-pin")

        // Research dragged to the top: first among the pins. Points fixed before the hold (the lifted row's menu moves
        // the frames); a sideways part lifts it out of its menu under XCUITest (as testBB7).
        let first = app.cells["bot-row-\(topRows(app)[0])"], research = app.cells["bot-row-research"]
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let from = origin.withOffset(CGVector(dx: research.frame.midX, dy: research.frame.midY))
        let to = origin.withOffset(CGVector(dx: first.frame.midX + 90, dy: first.frame.minY + first.frame.height * 0.2))
        from.press(forDuration: 0.6, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 1.0)
        XCTAssertTrue(waitUntil(timeout: 6) { self.topRows(app).first == "research" }, "Research first after the drop: \(topRows(app))")
        let order = Array(topRows(app).prefix(3))
        shot(app, "5-dragged-first")

        // The pins' order, not Sort By › Manual.
        let filter = app.buttons["bots.filter"]
        filter.tap()
        let sortBy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sort By'")).firstMatch
        XCTAssertTrue(sortBy.waitForExistence(timeout: 3))
        XCTAssertTrue(sortBy.label.contains("Recent Activity"), "Sort By stays Recent Activity: \(sortBy.label)")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
        _ = waitUntil(timeout: 3) { !sortBy.exists }

        // Faces follow the same order.
        pick(app, "faces")
        XCTAssertTrue(waitUntil(timeout: 5) { self.tiles(app) == order }, "the faces in the rows' order \(order): \(tiles(app))")
        shot(app, "6-faces-same-order")

        // As it was: Research unpinned, faces.
        app.cells["bot-tile-research"].press(forDuration: 1.0)
        if item(app, "Unpin").waitForExistence(timeout: 3) { item(app, "Unpin").tap() }
        XCTAssertTrue(waitUntil(timeout: 5) { !app.cells["bot-tile-research"].exists }, "Research unpinned")
    }

    @MainActor private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }
}
