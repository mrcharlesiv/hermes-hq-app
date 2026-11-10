// [sessions-m9] Helpers for the Filter and Sort, chips, row, Session Info and probe tests
// (docs/spec/3x-sessions.md §5-§11, §14): the fixture's hooks, the Filter menu by its identifiers, the list's order
// and headers, the chips and the strip, a chat's composer.

import XCTest

extension SessionsTests {
    // MARK: Fixture

    func fixture(_ path: String, _ body: [String: Any] = [:], file: StaticString = #filePath, line: UInt = #line) {
        do { try account.control(path, body) } catch { XCTFail("\(path): \(error)", file: file, line: line) }
    }

    /// Creates or patches a chat on the fixture (`event`: it also says the list changed).
    func setRow(_ id: String, _ fields: [String: Any], event: Bool = false) {
        fixture("/__fixture/rows", ["id": id, "set": fields, "event": event])
    }

    /// The sidebar reads the fixture has answered: limit 1, limit 50, limit 300.
    func sidebarReads() -> (probe: Int, full: Int, deep: Int, top: Int) {
        let sidebar = ((try? account.control("/__fixture/stats")) ?? [:])["sidebar"] as? [String: Any] ?? [:]
        return (sidebar["probe"] as? Int ?? 0, sidebar["full"] as? Int ?? 0, sidebar["deep"] as? Int ?? 0, sidebar["top"] as? Int ?? 0)
    }

    /// `sessions.changed` events of a `/__fixture/burst` still to be sent.
    func burstLeft() -> Int { ((try? account.control("/__fixture/stats")) ?? [:])["burst"] as? Int ?? 0 }

    /// Reads the fixture is holding unanswered right now (`sidebarHold`, `projectsHold`).
    func heldReads() -> (sidebar: Int, projects: Int) {
        let held = ((try? account.control("/__fixture/stats")) ?? [:])["held"] as? [String: Any] ?? [:]
        return (held["sidebar"] as? Int ?? 0, held["projects"] as? Int ?? 0)
    }

    var nowSeconds: Double { Date().timeIntervalSince1970 }

    /// The fixture was started with `--seed big` (scripts/e2e-sessions.sh, HQN_SESSIONS_SEED=big).
    static var bigSeed: Bool { ProcessInfo.processInfo.environment["HQN_SESSIONS_SEED"] == "big" }

    /// Every RPC the fixture logged, in order.
    func rpcLog() -> [(method: String, params: [String: Any])] {
        let state = (try? account.control("/__fixture/state")) ?? [:]
        return (state["rpc"] as? [[String: Any]] ?? []).map { ($0["method"] as? String ?? "", $0["params"] as? [String: Any] ?? [:]) }
    }

    /// Every PATCH to a chat that set `unread`, as (path, value).
    func unreadWrites() -> [(path: String, unread: Bool)] {
        let state = (try? account.control("/__fixture/state")) ?? [:]
        return (state["rest"] as? [[String: Any]] ?? []).compactMap { call in
            guard call["method"] as? String == "PATCH", let path = call["path"] as? String,
                  let unread = (call["body"] as? [String: Any])?["unread"] as? Bool else { return nil }
            return (path, unread)
        }
    }

    // MARK: The Filter and Sort menu

    static let filterTitles: [String: String] = [
        "sort": "Sort By", "sort.updated": "Updated", "sort.created": "Created", "sort.status": "Status", "sort.tokens": "Tokens",
        "sort.cost": "Cost", "group": "Group By", "group.date": "Date", "group.project": "Project", "group.status": "Status",
        "detail": "Row Detail", "detail.time": "Time", "detail.preview": "Preview", "detail.tokens": "Tokens", "detail.cost": "Cost",
        "status": "Status", "status.needs-input": "Needs Input", "status.working": "Working", "status.unread": "Unread",
        "status.draft": "Draft", "status.idle": "Idle", "project": "Project", "project.new": "New Project…", "allbots": "All Bots",
        "show": "Show", "runs": "Background Runs", "archived": "Archived", "clear": "Clear Filters", "readall": "Mark All as Read",
    ]

    /// A Filter and Sort menu element by its key ("sort", "sort.created", "runs", "project.0"): identifier
    /// `sessions.filter.<key>`.
    /// Every row of the menu is a button. (An any-kind search reads every element on screen one by one: seconds on
    /// a busy Mac, with the app's main thread held the whole time, which XCTest then reports as the app having
    /// "crashed in (null)" though its process lives on.)
    @MainActor func filterItem(_ app: XCUIApplication, _ key: String) -> XCUIElement {
        app.buttons["sessions.filter." + key]
    }

    /// Opens the menu from the bar's Filter button (a tap during a reload can be lost).
    @MainActor func openFilter(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<3 {
            if filterItem(app, "sort").exists { return }
            app.buttons["sessions.filter"].tap()
            if filterItem(app, "sort").waitForExistence(timeout: 4) { return }
        }
        XCTFail("the Filter and Sort menu did not open", file: file, line: line)
    }

    /// Taps menu elements in turn, waiting for each to show.
    @MainActor func tapFilter(_ app: XCUIApplication, _ keys: String..., file: StaticString = #filePath, line: UInt = #line) {
        for key in keys {
            let item = filterItem(app, key)
            XCTAssertTrue(item.waitForExistence(timeout: 5), "menu item \(key)", file: file, line: line)
            item.tap()
            Thread.sleep(forTimeInterval: 0.45)
        }
    }

    /// Closes the menu (and a submenu over it) by tapping outside it: on the large title (nothing to press there),
    /// else, at the largest text sizes where the menu covers the title, wherever the menu's rows are not.
    @MainActor func closeFilter(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let items = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.filter.'"))
        // The same three checks as before, the quick one (buttons only) first.
        func open() -> Bool { items.firstMatch.exists || filterItem(app, "sort").exists || filterItem(app, "show").exists }
        let screen = app.frame
        // The large title; else the Sessions tab's own button (the tab already showing); else the screen's edge.
        let places = [CGVector(dx: 0.08, dy: 0.105), CGVector(dx: 0.33, dy: 0.955), CGVector(dx: 0.02, dy: 0.5)]
        var tries = 0
        for _ in 0..<6 where open() {
            // The menu's rows, with room for its glass around them. A submenu shows only its own rows while the menu
            // behind it still covers more, so a place that did not close it is not tried twice running.
            let rows = items.allElementsBoundByIndex.filter(\.exists).map(\.frame).filter { !$0.isEmpty }
            let menu = rows.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -28, dy: -28)
            let clear = places.filter { !menu.contains(CGPoint(x: $0.dx * screen.width, y: $0.dy * screen.height)) }
            let from = clear.isEmpty ? places : clear
            app.coordinate(withNormalizedOffset: from[tries % from.count]).tap()
            tries += 1
            _ = waitUntil(1.5) { !open() }
        }
        XCTAssertFalse(open(), "the Filter menu closes", file: file, line: line)
    }

    /// Every row's id, top to bottom: the list is scrolled to its end and back (a row below the fold is not in the
    /// tree until it scrolls in).
    @MainActor func everyRow(_ app: XCUIApplication, swipes: Int = 16) -> [String] {
        let list = app.collectionViews["sessions.list"]
        var seen: [String] = [], last: [String] = []
        for _ in 0..<swipes {
            let now = order(app)
            for id in now where !seen.contains(id) { seen.append(id) }
            if now == last { break }
            last = now
            list.swipeUp(velocity: .slow)
        }
        for _ in 0..<swipes where order(app).first != seen.first { list.swipeDown(velocity: .fast) }
        return seen
    }

    /// Scrolls the list down until a row is on screen. False when it never comes.
    @MainActor func reveal(_ app: XCUIApplication, _ id: String, swipes: Int = 16) -> Bool {
        let target = row(app, id)
        for _ in 0..<swipes where !target.exists { app.collectionViews["sessions.list"].swipeUp(velocity: .slow) }
        return target.exists
    }

    /// The first place on screen, between two heights (points), whose colour is not the band's own; nil when the whole
    /// band is one colour. (A row showing through a gap above the chips is found by this, a pixel line at a time.)
    @MainActor func oddPixel(_ app: XCUIApplication, from top: CGFloat, to bottom: CGFloat) -> String? {
        guard let image = app.screenshot().image.cgImage, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return "no screenshot" }
        let scale = CGFloat(image.width) / max(app.frame.width, 1)
        let first = Int((top * scale).rounded(.up)), last = min(Int((bottom * scale).rounded(.down)), image.height)
        guard last > first, first >= 0 else { return "no band (\(top) to \(bottom))" }
        let step = image.bitsPerPixel / 8, row = image.bytesPerRow
        func colour(_ x: Int, _ y: Int) -> [Int] { (0..<3).map { Int(bytes[y * row + x * step + $0]) } }
        let own = colour(image.width / 2, first)
        for y in first..<last {
            for x in stride(from: 6, to: image.width - 6, by: 2) where zip(colour(x, y), own).contains(where: { abs($0 - $1) > 10 }) {
                return "x \(CGFloat(x) / scale), y \(CGFloat(y) / scale)"
            }
        }
        return nil
    }

    /// Presses an alert's button at its place on screen. `tap()` on the element first asks XCTest whether an alert is
    /// in its way, and after typing in the alert's own fields XCTest answers that the alert is in the way of its own
    /// button ("Handler claimed to have handled the alert but it's still interrupting"); a press by place skips that.
    @MainActor func press(_ button: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(button.waitForExistence(timeout: 4), "the alert's button", file: file, line: line)
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// Types into one of an alert's fields, tapping it at its place for the same reason as `press`: under load XCTest
    /// judges the alert to be in the way of its own field and fails the tap.
    @MainActor func fill(_ field: XCUIElement, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(field.waitForExistence(timeout: 4), "the alert's field", file: file, line: line)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 0.4)
        field.typeText(text)
    }

    /// Everything VoiceOver would say for a menu element: its label and its value (a submenu's subtitle).
    @MainActor func filterWords(_ app: XCUIApplication, _ key: String) -> String {
        let item = filterItem(app, key)
        guard item.exists else { return "" }
        return [item.label, item.value as? String ?? ""].filter { !$0.isEmpty }.joined(separator: " | ")
    }

    /// What an open submenu's own header says: its parent's title and subtitle. (UIKit draws that header itself, so it
    /// does not carry the parent's identifier; it is found by its title.)
    @MainActor func submenuHeader(_ app: XCUIApplication, _ title: String) -> String {
        let found = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title)).allElementsBoundByIndex
        return found.map { [$0.label, $0.value as? String ?? ""].filter { !$0.isEmpty }.joined(separator: " | ") }.joined(separator: " ; ")
    }

    /// A checkmark shows on the element.
    @MainActor func filterChecked(_ app: XCUIApplication, _ key: String) -> Bool {
        let item = filterItem(app, key)
        guard item.exists else { return false }
        return item.isSelected || (item.value as? String) == "1" || (item.value as? String)?.lowercased() == "selected"
    }

    // MARK: The list

    /// The rows on screen, top to bottom, by stored id.
    @MainActor func order(_ app: XCUIApplication) -> [String] {
        // One snapshot of the list instead of three questions per row (seconds each on a busy Mac): the same rows,
        // top to bottom.
        if let found = listSnapshot(app, type: .cell, prefix: "session-row-"), !found.isEmpty {
            return found.sorted { $0.frame.minY < $1.frame.minY }.map { String($0.identifier.dropFirst("session-row-".count)) }
        }
        return app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'session-row-'")).allElementsBoundByIndex
            .filter { $0.exists }.sorted { $0.frame.minY < $1.frame.minY }
            .map { String($0.identifier.dropFirst("session-row-".count)) }
    }

    /// The list's elements of one kind whose identifier starts with `prefix`, read in a single snapshot; nil when the
    /// list is not there or the snapshot fails (the caller then asks element by element).
    @MainActor func listSnapshot(_ app: XCUIApplication, type: XCUIElement.ElementType, prefix: String) -> [(identifier: String, label: String, frame: CGRect)]? {
        let list = app.collectionViews["sessions.list"]
        guard list.exists, let root = try? list.snapshot() else { return nil }
        var found: [(identifier: String, label: String, frame: CGRect)] = []
        func walk(_ node: any XCUIElementSnapshot) {
            if node.elementType == type, node.identifier.hasPrefix(prefix) { found.append((node.identifier, node.label, node.frame)) }
            for child in node.children { walk(child) }
        }
        walk(root)
        return found
    }

    /// The list's section headers, top to bottom. A header that folds is a button (its label the title while open);
    /// one that does not is text.
    @MainActor func headers(_ app: XCUIApplication) -> [String] {
        let snapshot = [XCUIElement.ElementType.staticText, .button].compactMap { listSnapshot(app, type: $0, prefix: "sessions.header") }
        let found = snapshot.flatMap { $0 }.filter { $0.identifier == "sessions.header" }
        if !found.isEmpty { return found.sorted { $0.frame.minY < $1.frame.minY }.map(\.label) }
        return (app.staticTexts.matching(identifier: "sessions.header").allElementsBoundByIndex
                + app.buttons.matching(identifier: "sessions.header").allElementsBoundByIndex)
            .filter { $0.exists }.sorted { $0.frame.minY < $1.frame.minY }.map(\.label)
    }

    /// A bot's chip (nil: All).
    @MainActor func chip(_ app: XCUIApplication, _ profile: String?) -> XCUIElement {
        app.buttons["sessions.chip." + (profile ?? "all")]
    }

    @MainActor func strip(_ app: XCUIApplication) -> XCUIElement { app.buttons["sessions.filter-strip"] }

    /// The Sessions tab's badge, as VoiceOver says it ("" for none).
    @MainActor func sessionsBadge(_ app: XCUIApplication) -> String {
        app.tabBars.buttons["Sessions"].value as? String ?? ""
    }

    // MARK: A chat

    @MainActor func openChat(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let cell = row(app, id)
        XCTAssertTrue(cell.waitForExistence(timeout: 15), "row \(id)", file: file, line: line)
        cell.tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 10), "the chat opens", file: file, line: line)
        Thread.sleep(forTimeInterval: 1.0)             // resume and the first page settle
    }

    @MainActor func backToList(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        if app.keyboards.count > 0 { app.tables["chat.table"].tap(); Thread.sleep(forTimeInterval: 0.4) }
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(app.collectionViews["sessions.list"].waitForExistence(timeout: 8), "back on the list", file: file, line: line)
        Thread.sleep(forTimeInterval: 0.6)
    }

    @MainActor func type(_ app: XCUIApplication, _ text: String, send: Bool) {
        let field = app.textViews["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 8), "the composer")
        field.tap()
        field.typeText(text)
        guard send else { return }
        let button = app.buttons["composer.send"]
        XCTAssertTrue(button.waitForExistence(timeout: 3), "Send")
        button.tap()
    }

    /// Chat › ⋯ › Info: the Session Info sheet.
    @MainActor func openSessionInfo(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let more = app.buttons["chat.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 8), "the chat's ⋯", file: file, line: line)
        for _ in 0..<3 {
            more.tap()
            if app.buttons["chat.more.info"].waitForExistence(timeout: 4) { break }
        }
        app.buttons["chat.more.info"].tap()
        XCTAssertTrue(app.tables["info.list"].waitForExistence(timeout: 6), "Session Info", file: file, line: line)
    }

    /// A Session Info row as VoiceOver says it: "value" or "value, note" ("" when the row is absent).
    @MainActor func infoRow(_ app: XCUIApplication, _ label: String) -> String {
        let id = "info.row." + label.lowercased().replacingOccurrences(of: " ", with: "-")
        let cell = app.cells[id]
        guard cell.exists else { return "" }
        if let value = cell.value as? String, !value.isEmpty { return value }
        let texts = cell.staticTexts.allElementsBoundByIndex.map(\.label).filter { $0 != label }
        return texts.joined(separator: ", ")
    }

    @MainActor func hasInfoRow(_ app: XCUIApplication, _ label: String) -> Bool {
        app.cells["info.row." + label.lowercased().replacingOccurrences(of: " ", with: "-")].exists
    }

    /// Text the app wrote for the tests (`-HQDebugTextOut`), read fresh.
    func readTextOut(_ name: String) -> String? {
        guard let folder = Self.textOutFolder else { return nil }
        return try? String(contentsOfFile: (folder as NSString).appendingPathComponent(name), encoding: .utf8)
    }

    func removeTextOut(_ name: String) {
        guard let folder = Self.textOutFolder else { return }
        try? FileManager.default.removeItem(atPath: (folder as NSString).appendingPathComponent(name))
    }
}
