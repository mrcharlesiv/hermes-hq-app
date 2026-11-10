// Owner 2026-11-01: the top of each tab was drawn a different way (Bots a solid band with a soft bottom, Sessions, Jobs,
// Kanban and More a solid bar with a hard cut, chats and pushed pages clear with the soft edge). One picture of each tab's
// top at rest and with rows scrolled under it, in the iOS look (light and dark) and the Desktop Look. Run with
//   HQN_FIXTURE_EXTRA_BOTS=10 HQN_PAGES_SKIP_NOK=1 HQN_PAGES_ONLY=testTop1_EveryTabAtRestAndScrolled scripts/e2e-pages.sh <SIM>

import XCTest

extension PagesTests {
    @MainActor func testTop1_EveryTabAtRestAndScrolled() throws {
        let looks: [(name: String, arguments: [String])] = [
            ("ios-light", ["-HQDebugDesktopLook", "NO", "-HQDebugAppearance", "light"]),
            ("ios-dark", ["-HQDebugDesktopLook", "NO", "-HQDebugAppearance", "dark"]),
            ("desktop-light", ["-HQDebugDesktopLook", "YES", "-HQDebugAppearance", "light"]),
            ("desktop-dark", ["-HQDebugDesktopLook", "YES", "-HQDebugAppearance", "dark"]),
        ]
        // HQN_TOPBAR_LOOKS / HQN_TOPBAR_TABS: a comma list narrows a run (e.g. "ios-light" and "Sessions").
        let environment = ProcessInfo.processInfo.environment
        let onlyLooks = environment["HQN_TOPBAR_LOOKS"].map { Set($0.split(separator: ",").map(String.init)) }
        let onlyTabs = environment["HQN_TOPBAR_TABS"].map { Set($0.split(separator: ",").map(String.init)) }
        for look in looks where onlyLooks?.contains(look.name) ?? true {
            app = launchSignedIn(look.arguments)
            _ = openTab("Bots")   // the last launch may have been left on another tab or a pushed page
            XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 15), "signed in")
            Thread.sleep(forTimeInterval: 2)   // the roster and the pinned heads in
            for (tabName, list) in [("Bots", "bots.list"), ("Sessions", "sessions.list"), ("Jobs", "jobs.list"),
                                    ("Kanban", "kanban.list"), ("More", "more.list")] where onlyTabs?.contains(tabName) ?? true {
                guard openTab(tabName) else { shot("topbar-\(look.name)-\(tabName.lowercased())-no-tab"); continue }
                topShots(look.name, tabName.lowercased(), list: app.collectionViews[list])
            }
            for (row, page, list) in [("more-row-artifacts", "artifacts", "artifacts.list"), ("more-row-pinned", "pinned", "pinned.list")]
            where onlyTabs?.contains(page.capitalized) ?? true {
                _ = openTab("More")
                let cell = app.cells[row]
                guard cell.waitForExistence(timeout: 5) || scrollTo(cell, in: app.collectionViews["more.list"]) else { continue }
                cell.tap()
                topShots(look.name, page, list: app.collectionViews[list])
                let back = app.navigationBars.buttons.element(boundBy: 0)
                if back.exists { back.tap() }
            }
            app.terminate()
        }
        // With a second gateway saved, Bots and Sessions carry the gateway line under the title (the owner's phone):
        // the line rows ran through on 2026-10-30. HQN_TOPBAR_B: a second pages fixture's credentials file.
        guard let path = environment["HQN_TOPBAR_B"], !path.isEmpty,
              let data = FileManager.default.contents(atPath: path),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = object["url"] as? String, let username = object["username"] as? String,
              let password = object["password"] as? String else { return }
        app = launchSignedIn(looks[0].arguments)
        let card = app.cells["more-row-gateway"]
        for _ in 0..<4 { _ = openTab("More"); if card.waitForExistence(timeout: 2), card.isHittable { break } }
        card.tap()
        XCTAssertTrue(app.buttons["gateway.add"].waitForExistence(timeout: 5), "the Gateway page")
        app.buttons["gateway.add"].tap()
        let address = app.textFields["sign-in-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 15), "the sign-in form shows")
        address.tap()
        if let current = address.value as? String, !current.isEmpty, current != address.placeholderValue {
            address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        address.typeText(url)
        let user = app.textFields["sign-in-username"]
        XCTAssertTrue(user.waitForExistence(timeout: 10))
        user.tap()
        user.typeText(username)
        let secret = app.secureTextFields["sign-in-password"]
        XCTAssertTrue(secret.waitForExistence(timeout: 10))
        for _ in 0..<5 where !secret.isHittable { app.swipeUp() }
        secret.tap()
        secret.typeText(password)
        let button = app.buttons["sign-in-password-button"]
        for _ in 0..<5 where !button.isHittable { app.swipeUp() }
        button.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for candidate in [app.buttons["Not Now"], springboard.buttons["Not Now"]] where candidate.waitForExistence(timeout: 3) { candidate.tap() }
        Thread.sleep(forTimeInterval: 3)
        app.terminate()
        for look in looks.prefix(2) {
            app = launchSignedIn(look.arguments)
            _ = openTab("Bots")   // the last launch may have been left on another tab or a pushed page
            XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 15), "signed in")
            Thread.sleep(forTimeInterval: 2)
            for (tabName, list) in [("Bots", "bots.list"), ("Sessions", "sessions.list")] {
                _ = openTab(tabName)
                topShots(look.name + "-gateway", tabName.lowercased(), list: app.collectionViews[list])
            }
            app.terminate()
        }
    }

    /// Owner 2026-11-03: with Artifacts as a tab of its own, the soft top edge blurred its All / Images / Files / Links
    /// picker at rest. Opened from More (above) the page has no soft edge, so this needs the page as a tab.
    @MainActor func testTop2_ArtifactsAsTab() throws {
        for look in ["light", "dark"] {
            app = launchSignedIn(["-HQDebugDesktopLook", "NO", "-HQDebugAppearance", look,
                                  "-hqn.tabOrder", "(bots, sessions, jobs, page.artifacts)"])
            guard openTab("Artifacts") else { shot("topbar-ios-\(look)-artifacts-tab-no-tab"); app.terminate(); continue }
            topShots("ios-\(look)", "artifacts-tab", list: app.collectionViews["artifacts.list"])
            app.terminate()
        }
    }

    /// [top-edge] Theme › Themes › Top Edge (owner 2026-11-03, Claude's frosted band): Bots, Sessions, Jobs and a chat at
    /// rest and scrolled, Soft and Hard, light and dark. HQN_TOPBAR_EDGES ("default": nothing picked) / HQN_TOPBAR_LOOKS narrow it.
    @MainActor func testTop3_TopEdgeSoftAndHard() throws {
        let environment = ProcessInfo.processInfo.environment
        let edges = environment["HQN_TOPBAR_EDGES"].map { $0.split(separator: ",").map(String.init) } ?? ["soft", "hard"]
        let looks = environment["HQN_TOPBAR_LOOKS"].map { $0.split(separator: ",").map(String.init) } ?? ["light", "dark"]
        for edge in edges {
            for look in looks {
                // "desktop-light": the Desktop Look (its tabs have no edge; its chats do).
                let desktop = look.hasPrefix("desktop-")
                app = launchSignedIn(["-HQDebugDesktopLook", desktop ? "YES" : "NO",
                                      "-HQDebugAppearance", desktop ? String(look.dropFirst(8)) : look]
                                     + (edge == "default" ? [] : ["-hqn.theme.topEdge", edge]))
                _ = openTab("Bots")
                XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 15), "signed in")
                Thread.sleep(forTimeInterval: 2)
                let name = "edge-\(edge)-\(look)"
                for (tabName, list) in [("Bots", "bots.list"), ("Sessions", "sessions.list"), ("Jobs", "jobs.list")] {
                    guard openTab(tabName) else { continue }
                    topShots(name, tabName.lowercased(), list: app.collectionViews[list])
                }
                _ = openTab("Sessions")
                let row = app.collectionViews["sessions.list"].cells.element(boundBy: 2)
                if row.waitForExistence(timeout: 5) {
                    row.tap()
                    Thread.sleep(forTimeInterval: 3)
                    shot("topbar-\(name)-chat-rest")
                    let window = app.windows.firstMatch
                    window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                        .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
                    Thread.sleep(forTimeInterval: 1.5)
                    shot("topbar-\(name)-chat-scrolled")
                } else {
                    shot("topbar-\(name)-chat-no-row")
                }
                app.terminate()
            }
        }
        // The switch itself, on Theme › Themes, flipped while the page is open.
        app = launchSignedIn(["-HQDebugDesktopLook", "NO", "-HQDebugAppearance", "dark", "-HQDebugOpenTheme", "YES"])
        let row = app.descendants(matching: .any)["theme.topEdge"]
        for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp() }
        Thread.sleep(forTimeInterval: 1)
        shot("topbar-edge-theme-row")
        let hard = row.buttons["Hard"]
        if hard.exists { hard.tap(); Thread.sleep(forTimeInterval: 1); shot("topbar-edge-theme-row-hard") }
        app.terminate()
    }

    /// [desktop-top-bar] Owner 2026-11-05 (Messaging): in the Desktop Look a pushed page's bar showed as a band with the
    /// first card against it. More's pushed pages at rest and scrolled. HQN_TOPBAR_LOOKS / HQN_TOPBAR_ROWS narrow it.
    @MainActor func testTop4_DesktopPushedPages() throws {
        let environment = ProcessInfo.processInfo.environment
        let looks = environment["HQN_TOPBAR_LOOKS"].map { $0.split(separator: ",").map(String.init) } ?? ["desktop-dark", "desktop-light"]
        let rows = environment["HQN_TOPBAR_ROWS"].map { $0.split(separator: ",").map(String.init) }
            ?? ["marketplace", "capabilities", "profiles", "usage", "star-map", "import-sessions"]
        for look in looks {
            let desktop = look.hasPrefix("desktop-")
            app = launchSignedIn(["-HQDebugDesktopLook", desktop ? "YES" : "NO",
                                  "-HQDebugAppearance", desktop ? String(look.dropFirst(8)) : look])
            _ = openTab("Bots")
            XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 15), "signed in")
            for id in rows {
                _ = openTab("More")
                let cell = app.cells["more-row-\(id)"]
                for _ in 0..<4 where !cell.exists { app.collectionViews["more.list"].swipeDown() }
                guard cell.waitForExistence(timeout: 5) || scrollTo(cell, in: app.collectionViews["more.list"]) else {
                    shot("topbar-push-\(look)-\(id)-no-row"); continue
                }
                cell.tap()
                Thread.sleep(forTimeInterval: 2.5)
                shot("topbar-push-\(look)-\(id)-rest")
                let window = app.windows.firstMatch
                window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                    .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
                Thread.sleep(forTimeInterval: 1.5)
                shot("topbar-push-\(look)-\(id)-scrolled")
                let back = app.navigationBars.buttons.element(boundBy: 0)
                if back.exists { back.tap() }
                Thread.sleep(forTimeInterval: 0.8)
            }
            app.terminate()
        }
    }

    /// A tab by its label (the system tab bar) or its id (the Desktop Look's own bar); no failure if it isn't there.
    @MainActor private func openTab(_ name: String) -> Bool {
        let system = app.tabBars.buttons[name], own = tabButton(name)
        guard waitUntil(10, { system.exists || own.exists }) else { return false }
        let button = system.exists ? system : own
        for _ in 0..<3 where !button.isHittable { app.collectionViews.firstMatch.swipeDown() }
        button.tap()
        Thread.sleep(forTimeInterval: 0.6)
        return true
    }

    /// The page at rest, then held part-way after a slow drag (no fling), rows under the bar.
    @MainActor private func topShots(_ look: String, _ page: String, list: XCUIElement) {
        guard list.waitForExistence(timeout: 10) else { shot("topbar-\(look)-\(page)-missing"); return }
        Thread.sleep(forTimeInterval: 1.5)
        shot("topbar-\(look)-\(page)-rest")
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52)))
        Thread.sleep(forTimeInterval: 1.5)
        shot("topbar-\(look)-\(page)-scrolled")
        // Back to the top for the next look's launch (and the tab's own state).
        for _ in 0..<2 { list.swipeDown() }
    }
}
