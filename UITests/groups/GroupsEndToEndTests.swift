// Groups-stream end-to-end checks (docs/spec/3x-groups.md §7 and §9) against the groups fixture: the real app, real
// gestures, and the fixture's `/__groups/state` as the wire evidence. Run with scripts/e2e-groups.sh <SIM_UDID>.
// This file holds the suite's set-up and helpers; the checks live in the extensions beside it:
//   +List (rooms in the Bots list, Show ›, empty states, drag), +Create (New Group Chat, Add to Group Chat…, Bot Info),
//   +Info (Group Info and its pages), +Room (the room as a chat, Stop), +Deliveries, +Stress (the stress plan).

import XCTest

final class GroupsEndToEndTests: XCTestCase {
    var a: SettingsFixture!

    static let launch = "Launch Room"
    static let launchKey = "id:rmfixture-launch"

    override func setUpWithError() throws {
        continueAfterFailure = false
        a = try SettingsFixture.load("HQN_UI_CREDENTIALS")
        try a.control("/__groups/reset", [:])
    }

    override func tearDownWithError() throws {
        // Never leave the fixture offline, slow or holding a turn for the next test.
        _ = try? a?.control("/__groups/reset", [:])
    }

    // MARK: - Fixture state

    func state(_ fixture: SettingsFixture? = nil) -> [String: Any] { (try? (fixture ?? a).control("/__groups/state")) ?? [:] }

    func control(_ path: String, _ body: [String: Any] = [:]) {
        do { try a.control("/__groups/" + path, body) } catch { XCTFail("fixture \(path): \(error)") }
    }

    func groups(of profile: String) -> [String] {
        (((state()["profiles"] as? [String: Any])?[profile] as? [String: Any])?["groups"] as? [String]) ?? []
    }

    var mirror: [String: Any] { (state()["mirror"] as? [String: Any]) ?? [:] }
    var mirrorRevision: Int { (mirror["revision"] as? Int) ?? -1 }
    func mirrorRoom(_ key: String = GroupsEndToEndTests.launchKey) -> [String: Any] {
        ((mirror["rooms"] as? [String: Any])?[key] as? [String: Any]) ?? [:]
    }
    func mirrorRoom(named name: String) -> [String: Any] {
        ((mirror["rooms"] as? [String: Any]) ?? [:]).values.compactMap { $0 as? [String: Any] }.first { $0["name"] as? String == name } ?? [:]
    }
    func mirrorTexts(_ key: String = GroupsEndToEndTests.launchKey) -> [String] { (mirrorRoom(key)["texts"] as? [String]) ?? [] }

    var prompts: [[String: Any]] { (state()["prompts"] as? [[String: Any]]) ?? [] }
    var interrupts: [[String: Any]] { (state()["interrupts"] as? [[String: Any]]) ?? [] }
    var sessions: [[String: Any]] { (state()["sessions"] as? [[String: Any]]) ?? [] }
    func calls(_ method: String) -> Int { ((state()["calls"] as? [String]) ?? []).filter { $0 == method }.count }
    func writes(_ method: String = "profiles.configure") -> [[String: Any]] {
        ((state()["writes"] as? [[String: Any]]) ?? []).filter { $0["method"] as? String == method }.compactMap { $0["params"] as? [String: Any] }
    }
    /// Writes of the room mirror (profiles.configure on the default profile carrying `hermes-bots-groups`).
    var mirrorWrites: [[String: Any]] { writes().filter { ($0["ui_meta"] as? [String: Any])?["hermes-bots-groups"] != nil } }
    /// The app must never call the gateway's hosted rooms or bot relay (D1).
    func assertNoHostedCalls(file: StaticString = #filePath, line: UInt = #line) {
        let forbidden = (state()["forbidden"] as? [[String: Any]]) ?? []
        XCTAssertTrue(forbidden.isEmpty, "groups.* / bot_relay.* were called: \(forbidden)", file: file, line: line)
        let rejected = (state()["rejected"] as? [[String: Any]]) ?? []
        XCTAssertTrue(rejected.isEmpty, "a call carried a parameter Hermes does not know: \(rejected)", file: file, line: line)
    }

    // MARK: - Launch and sign-in

    var appearanceArguments: [String] {
        (ProcessInfo.processInfo.environment["HQN_UI_DARK"] == "1" ? ["-hqn.appearance", "dark"] : [])
            + (ProcessInfo.processInfo.environment["HQN_UI_DESKTOP"] == "1" ? ["-hqn.theme.desktopLook", "<true/>"] : [])
    }

    /// HQN_UI_AX (a simctl content size name, e.g. accessibility-extra-extra-extra-large): the app's text size, as a launch
    /// argument UIKit reads. The first launch signs in at the standard size; the app is then relaunched with it.
    var sizeArguments: [String] {
        guard let size = ProcessInfo.processInfo.environment["HQN_UI_AX"], !size.isEmpty else { return [] }
        let accessibility = size.hasPrefix("accessibility-")
        let step = ["extra-small": "XS", "small": "S", "medium": "M", "large": "L", "extra-large": "XL", "extra-extra-large": "XXL",
                    "extra-extra-extra-large": "XXXL"][accessibility ? String(size.dropFirst("accessibility-".count)) : size] ?? "L"
        return ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategory" + (accessibility ? "Accessibility" : "") + step]
    }

    @MainActor func launchSignedIn(_ arguments: [String] = [], fixture: SettingsFixture? = nil, drag: Bool = false,
                                   expecting row: String? = "bot-row-ivy") -> XCUIApplication {
        let app = XCUIApplication()
        // A clean first run: no sign-in, no rooms or marks on the phone, no mutes and the first-mute tip unseen.
        app.launchArguments = ["-HQDebugResetAccounts", "YES", "-HQDebugResetBotMutes", "YES"] + appearanceArguments + arguments
            + (drag ? [] : ["-HQDebugNoDrag", "YES"])
        app.launch()
        signIn(app, fixture ?? a)
        if let row {
            let cell = app.cells[row]
            if !cell.waitForExistence(timeout: 20) {
                dismissSavePassword(app, wait: 2)
                XCTAssertTrue(appears(cell, app, "launch-\(name)", timeout: 10), "the Bots list shows")
            }
        }
        dismissSavePassword(app, wait: 2)
        if !sizeArguments.isEmpty {
            relaunch(app, arguments, drag: drag)
            if let row {
                // At the largest sizes pinned bots are rows and the list is long: any bot's cell says it is up.
                let listed = waitUntil(timeout: 25) { app.cells[row].exists || app.cells["bot-row-default"].exists || app.cells["bot-tile-default"].exists }
                if !listed { dump(app, "launch-ax-\(name)") }
                XCTAssertTrue(listed, "the Bots list shows at the run's text size")
            }
        }
        return app
    }

    /// Relaunches with the saved sign-in (and the run's text size).
    @MainActor func relaunch(_ app: XCUIApplication, _ arguments: [String] = [], drag: Bool = false) {
        app.terminate()
        app.launchArguments = appearanceArguments + sizeArguments + arguments + (drag ? [] : ["-HQDebugNoDrag", "YES"])
        app.launch()
    }

    @MainActor func signIn(_ app: XCUIApplication, _ fixture: SettingsFixture) {
        let address = app.textFields["sign-in-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 20), "the sign-in form shows")
        focus(app, address)
        if let current = address.value as? String, !current.isEmpty, current != "my-mac.tail1234.ts.net" {
            address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        address.typeText(fixture.url)
        let username = app.textFields["sign-in-username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        focus(app, username)
        username.typeText(fixture.username)
        let password = app.secureTextFields["sign-in-password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        for _ in 0..<3 {
            guard focus(app, password) else { continue }   // never typed into nothing
            password.typeText(fixture.password)
            let typed = (password.value as? String) ?? ""
            if !typed.isEmpty, typed != password.placeholderValue { break }
        }
        let button = app.buttons["sign-in-password-button"]
        for _ in 0..<5 { if button.isHittable { break }; app.swipeUp() }
        button.tap()
        dismissSavePassword(app, wait: 3)
    }

    /// Taps a field until it has the keyboard (at the largest text sizes it can sit under the keyboard: the form is
    /// scrolled up and the tap repeated).
    @discardableResult
    @MainActor func focus(_ app: XCUIApplication, _ field: XCUIElement) -> Bool {
        func focused() -> Bool { (field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false }
        for attempt in 0..<4 {
            if attempt > 0 || !field.isHittable { app.swipeUp() }
            if field.isHittable { field.tap() }
            if waitUntil(timeout: 2, focused) { return true }
        }
        return focused()
    }

    /// Types into a field once it really has the keyboard (a tap can land before the field is ready on a busy Mac).
    @MainActor func typeInto(_ field: XCUIElement, _ text: String) {
        func focused() -> Bool { (field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false }
        for _ in 0..<4 where !focused() {
            field.tap()
            _ = waitUntil(timeout: 3, focused)
        }
        field.typeText(text)
    }

    /// iOS offers to save the typed password, sometimes seconds after the sign-in: decline it so it never takes a tap.
    @MainActor func dismissSavePassword(_ app: XCUIApplication, wait: TimeInterval = 0) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(wait)
        repeat {
            for candidate in [app.buttons["Not Now"], springboard.buttons["Not Now"]] where candidate.exists {
                candidate.tap()
                return
            }
            if wait > 0 { Thread.sleep(forTimeInterval: 0.25) }
        } while Date() < deadline
    }

    // MARK: - The Bots list

    @MainActor func roomRow(_ app: XCUIApplication, _ name: String = GroupsEndToEndTests.launch) -> XCUIElement { app.cells["room-row-\(name)"] }
    @MainActor func roomTile(_ app: XCUIApplication, _ name: String = GroupsEndToEndTests.launch) -> XCUIElement { app.cells["room-tile-\(name)"] }
    /// The run is at an accessibility text size (HQN_UI_AX): pinned bots and rooms are rows at the top of the list, not tiles.
    var largeText: Bool { (ProcessInfo.processInfo.environment["HQN_UI_AX"] ?? "").hasPrefix("accessibility") }
    /// Back to the top of the Bots list (a lazy list: the pinned rows exist only when they are near the screen).
    @MainActor func toTop(_ app: XCUIApplication) {
        for _ in 0..<3 { app.collectionViews["bots.list"].swipeDown(); Thread.sleep(forTimeInterval: 0.3) }
    }
    /// A pinned room: its tile, or at an accessibility text size its row.
    @MainActor func pinnedRoom(_ app: XCUIApplication, _ name: String = GroupsEndToEndTests.launch) -> XCUIElement {
        largeText ? roomRow(app, name) : roomTile(app, name)
    }

    /// The room row's spoken label (name, second line, time, marks).
    @MainActor func roomLabel(_ app: XCUIApplication, _ name: String = GroupsEndToEndTests.launch) -> String {
        let row = roomRow(app, name).exists ? roomRow(app, name) : roomTile(app, name)
        let labelled = row.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", name + ".")).firstMatch
        if labelled.exists { return labelled.label }
        return row.label
    }

    /// What a cell says: its own label, else its first labelled button's (a list cell's content is the element).
    @MainActor func spoken(_ element: XCUIElement) -> String {
        if !element.label.isEmpty { return element.label }
        let inner = element.buttons.matching(NSPredicate(format: "label != ''")).firstMatch
        return inner.exists ? inner.label : ""
    }

    /// A short slow drag that opens a row's swipe actions without running the full swipe.
    @MainActor func swipeRow(_ cell: XCUIElement, left: Bool) {
        let start = cell.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.85 : 0.15, dy: 0.5))
        let end = cell.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.35 : 0.65, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 0.4)
    }

    /// The first mute on this iPhone explains itself in a popover over the row: close it so the next press lands.
    @MainActor func dismissMuteTip(_ app: XCUIApplication) {
        let tip = app.staticTexts["Muted on This iPhone"]
        guard tip.waitForExistence(timeout: 2) else { return }
        // Outside the tip: above it, or beside it at the largest text sizes (there it reaches the top of the screen).
        app.coordinate(withNormalizedOffset: largeText ? CGVector(dx: 0.06, dy: 0.66) : CGVector(dx: 0.5, dy: 0.08)).tap()
        _ = waitUntil(timeout: 3) { !tip.exists }
    }

    /// Brings a row on screen (the Group Chats block sits under the bots' sections).
    @MainActor func reveal(_ app: XCUIApplication, _ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let list = app.collectionViews["bots.list"]
        func scroll() {
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
            Thread.sleep(forTimeInterval: 0.4)
        }
        // A lazy list: at the largest text sizes a row far down is not made until the list is scrolled near it.
        if !element.waitForExistence(timeout: 10) {
            for _ in 0..<16 { scroll(); if element.exists { break } }
        }
        XCTAssertTrue(element.exists, "\(element) exists", file: file, line: line)
        // The floating tab bar covers the last 100 points: a row under it can be seen but not pressed.
        let floor = app.frame.height - 110
        for _ in 0..<6 {
            if element.isHittable && element.frame.maxY <= floor { break }
            scroll()
        }
    }

    @MainActor func openRoom(_ app: XCUIApplication, _ name: String = GroupsEndToEndTests.launch, file: StaticString = #filePath, line: UInt = #line) {
        // A pinned room is a tile at the top; a row may be far down a lazy list (reveal scrolls to it).
        _ = waitUntil(timeout: 6) { self.roomRow(app, name).exists || self.roomTile(app, name).exists }
        let row = roomTile(app, name).exists ? roomTile(app, name) : roomRow(app, name)
        reveal(app, row, file: file, line: line)
        for _ in 0..<3 {
            dismissSavePassword(app)
            row.tap()
            if app.tables["chat.table"].waitForExistence(timeout: 5) { break }
        }
        XCTAssertTrue(app.tables["chat.table"].exists, "the room opens", file: file, line: line)
    }

    /// Back to the Bots list from a pushed room.
    @MainActor func backToList(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if app.tables["chat.table"].exists, back.exists { back.tap() }
        _ = waitUntil(timeout: 5) { !app.tables["chat.table"].exists }
    }

    @MainActor func pullToRefresh(_ app: XCUIApplication) {
        let list = app.collectionViews["bots.list"]
        for _ in 0..<3 where list.exists {
            let top = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
            if !top.referencedElement.exists { break }
            list.swipeDown(velocity: .fast)
            if !app.cells["bot-tile-default"].exists { continue }
            break
        }
        let start = app.cells["bot-tile-default"].exists ? app.cells["bot-tile-default"] : list
        start.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        Thread.sleep(forTimeInterval: 1.0)
    }

    // MARK: - The room

    @MainActor func send(_ app: XCUIApplication, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let field = app.textViews["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 8), "the composer", file: file, line: line)
        field.tap()
        field.typeText(text)
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 3), "Send", file: file, line: line)
        send.tap()
    }

    /// A bubble (or any row of the chat) whose spoken label contains `text`.
    @MainActor func message(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.tables["chat.table"].descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor func messageCount(_ app: XCUIApplication, containing text: String) -> Int {
        // One bubble can surface as itself and as its text: count distinct frames.
        let found = app.tables["chat.table"].descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).allElementsBoundByIndex
        return Set(found.map { "\(Int($0.frame.minY))" }).count
    }

    @MainActor func openRoomMenu(_ app: XCUIApplication, showing item: String = "Group Info") {
        let more = app.buttons["chat.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), "the room's ⋯ button")
        for _ in 0..<3 {
            more.tap()
            if app.buttons[item].firstMatch.waitForExistence(timeout: 2) { return }
        }
    }

    // MARK: - Menus, alerts, waits, screenshots

    /// Long-presses until the menu shows `item`, then taps it (a press during the list's first reload can be lost).
    @MainActor func pressMenu(_ app: XCUIApplication, _ element: XCUIElement, _ item: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), file: file, line: line)
        holdMenu(app, element, showing: item)
        tapMenu(app, item, file: file, line: line)
    }

    @MainActor func holdMenu(_ app: XCUIApplication, _ element: XCUIElement, showing item: String) {
        for _ in 0..<3 {
            dismissSavePassword(app)
            element.press(forDuration: 1.0)
            if app.buttons[item].firstMatch.waitForExistence(timeout: 3) { break }
            if largeText, scrollMenu(app, to: app.buttons[item].firstMatch) { break }
        }
    }

    /// At the largest text sizes a menu shows two or three items and scrolls; it opens above or below what was held.
    @MainActor func scrollMenu(_ app: XCUIApplication, to item: XCUIElement) -> Bool {
        func found() -> Bool { item.waitForExistence(timeout: 1.2) && item.isHittable }
        for (from, to) in [(0.40, 0.16), (0.40, 0.16), (0.40, 0.16), (0.86, 0.62), (0.86, 0.62), (0.86, 0.62)] {
            if found() { return true }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)))
        }
        return found()
    }

    /// Taps a context-menu (or pull-down) item by its title.
    @MainActor func tapMenu(_ app: XCUIApplication, _ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let item = app.buttons[title].firstMatch
        if item.waitForExistence(timeout: 4) { item.tap(); return }
        if largeText, scrollMenu(app, to: item) { item.tap(); return }
        let any = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
        if !any.waitForExistence(timeout: 2) { dump(app, "menu-\(title)") }
        XCTAssertTrue(any.exists, "menu item \(title)", file: file, line: line)
        any.tap()
    }

    /// Closes an open menu without picking.
    @MainActor func closeMenu(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)).tap()
        Thread.sleep(forTimeInterval: 0.6)
    }

    /// The titles of the buttons of an open menu, top to bottom.
    @MainActor func menuTitles(_ app: XCUIApplication, among wanted: [String]) -> [String] {
        wanted.compactMap { title -> (String, CGFloat)? in
            let item = app.buttons[title].firstMatch
            return item.exists ? (title, item.frame.minY) : nil
        }.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// Taps a menu button until its menu shows `item` (a first tap right after launch can land before the bar is live).
    @MainActor func openMenu(_ app: XCUIApplication, _ button: XCUIElement, showing item: String) {
        XCTAssertTrue(button.waitForExistence(timeout: 8), "\(button)")
        for _ in 0..<3 {
            button.tap()
            if app.buttons[item].firstMatch.waitForExistence(timeout: 2) { return }
        }
    }

    /// A SwiftUI Toggle's row is a switch holding the real switch: tap that one.
    @MainActor func flip(_ element: XCUIElement) {
        let inner = element.switches.firstMatch
        (inner.exists ? inner : element).tap()
    }

    @MainActor func isOn(_ element: XCUIElement) -> Bool {
        let inner = element.switches.firstMatch
        return ((inner.exists ? inner : element).value as? String) == "1"
    }

    /// Any element with this identifier (SwiftUI rows surface as buttons, cells, texts or "other").
    @MainActor func any(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor func text(_ app: XCUIApplication, _ value: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", value)).firstMatch
    }

    @MainActor func textContaining(_ app: XCUIApplication, _ value: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    /// Scrolls a sheet's list until the element can be tapped.
    @MainActor func scrollTo(_ app: XCUIApplication, _ element: XCUIElement, in list: XCUIElement? = nil) {
        func ready() -> Bool { element.exists && element.isHittable }
        if ready() { return }   // every look at the screen is slow on a busy Mac: stop at the first that finds it
        let scroller = list ?? app.collectionViews.element(boundBy: app.collectionViews.count - 1)
        // A lazy list has no element for a row far off screen: look down the list first, then back up it.
        for _ in 0..<8 {
            if element.exists, element.frame.midY < scroller.frame.minY + 40 { scroller.swipeDown(velocity: .slow) } else { scroller.swipeUp(velocity: .slow) }
            if ready() { return }
        }
        for _ in 0..<10 {
            scroller.swipeDown(velocity: .slow)
            if ready() { return }
        }
    }

    /// Waits for an element; on failure saves the tree and a screenshot as debug-<name>.
    @MainActor @discardableResult
    func appears(_ element: XCUIElement, _ app: XCUIApplication, _ name: String, timeout: TimeInterval = 5) -> Bool {
        if element.waitForExistence(timeout: timeout) { return true }
        dump(app, name)
        return false
    }

    /// The element tree, for a failure's diagnosis (build/shots/debug-<name>.txt).
    @MainActor func dump(_ app: XCUIApplication, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["HQN_UI_SHOTS"], !dir.isEmpty else { return }
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "-")
        try? app.debugDescription.write(to: URL(fileURLWithPath: dir).appendingPathComponent("debug-\(safe).txt"), atomically: true, encoding: .utf8)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("debug-\(safe).png"))
    }

    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }

    /// Asserts, saving the tree and a screenshot when it fails.
    @MainActor func check(_ condition: @autoclosure () -> Bool, _ app: XCUIApplication, _ name: String, _ message: String,
                          file: StaticString = #filePath, line: UInt = #line) {
        let ok = condition()
        if !ok { dump(app, name) }
        XCTAssertTrue(ok, message, file: file, line: line)
    }

    /// A screenshot into build/shots (light or dark by the run) and the test's attachments.
    @MainActor func shot(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.6)
        let screenshot = app.screenshot()
        let mode = ProcessInfo.processInfo.environment["HQN_UI_DARK"] == "1" ? "dark" : "light"
        let size = (ProcessInfo.processInfo.environment["HQN_UI_AX"].flatMap { $0.isEmpty ? nil : "-ax" } ?? "")
            + (ProcessInfo.processInfo.environment["HQN_UI_DESKTOP"] == "1" ? "-desktop" : "")
        if let dir = ProcessInfo.processInfo.environment["HQN_UI_SHOTS"], !dir.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("groups-\(name)-\(mode)\(size).png"))
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "groups-\(name)-\(mode)\(size)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
