// Sessions › Other Apps (Show › Outside Chats): the one row under Pinned in Date and Project grouping, and the page it
// opens (a section per platform, rows with the list's ⋯ and swipes, Back naming Sessions, a row opening its chat).
// Polish 2026-10-24: 367 shipped with the row missing under Group By Project and no test caught it.

import XCTest

extension SessionsTests {
    /// Telegram and Discord chats on the fixture (its default seed has none).
    func addOutsideChats() {
        let now = nowSeconds
        setRow("s-tg1", ["profile": "default", "title": "Telegram chat with a fairly long title about the garden beds",
                         "source": "telegram", "last_active": now - 300])
        setRow("s-tg2", ["profile": "default", "title": "Telegram groceries", "source": "telegram", "last_active": now - 4_000])
        setRow("s-dc1", ["profile": "research", "title": "Discord reading club", "source": "discord", "last_active": now - 900],
               event: true)
    }

    @MainActor func test97_OtherAppsRowAndPage() throws {
        addOutsideChats()
        let app = launch()
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        let apps = app.cells["sessions.otherApps"]
        XCTAssertFalse(apps.exists, "Outside Chats is off by default")
        openFilter(app)
        tapFilter(app, "show", "outside")
        closeFilter(app)
        XCTAssertTrue(apps.waitForExistence(timeout: 8), "the Other Apps row")
        XCTAssertFalse(row(app, "s-tg1").exists, "its chats are folded into it")
        let words = labelOf(apps)
        XCTAssertTrue(words.contains("Telegram") && words.contains("Discord") && words.contains("3 chats"), words)
        // Under Pinned: below the pinned chat, above the dated rows.
        XCTAssertGreaterThan(apps.frame.minY, row(app, "s-release").frame.minY)
        XCTAssertLessThan(apps.frame.minY, row(app, "s-garden").frame.minY)
        shot(app, "other-apps-row")

        // Group By Project keeps it, under Pinned.
        openFilter(app)
        tapFilter(app, "group", "group.project")
        closeFilter(app)
        XCTAssertTrue(apps.waitForExistence(timeout: 6), "the row under Group By Project")
        XCTAssertGreaterThan(apps.frame.minY, row(app, "s-release").frame.minY)
        shot(app, "other-apps-row-by-project")

        // The page: a section per platform, Back naming the list, the list's row actions.
        apps.tap()
        let page = app.collectionViews["otherApps.list"]
        XCTAssertTrue(page.waitForExistence(timeout: 6), "the Other Apps page")
        let telegram = page.cells["session-row-s-tg1"]
        XCTAssertTrue(telegram.waitForExistence(timeout: 6))
        XCTAssertTrue(page.cells["session-row-s-dc1"].exists && page.cells["session-row-s-tg2"].exists)
        XCTAssertTrue(app.navigationBars.buttons["Sessions"].exists, "Back names Sessions, not the unread count")
        XCTAssertFalse(page.buttons["session-menu-s-tg1"].exists, "no ⋯, as on the list")
        shot(app, "other-apps-page")
        swipe(telegram, left: true)
        XCTAssertTrue(app.buttons["Archive"].waitForExistence(timeout: 3), "the list's trailing swipes")
        shot(app, "other-apps-page-swipe")
        telegram.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()     // slides the actions shut
        XCTAssertTrue(waitUntil(3) { !app.buttons["Archive"].exists })

        // A row opens its chat; Back comes back to the page.
        telegram.tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 8), "the chat opens")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(page.waitForExistence(timeout: 6), "back on the page")
    }
}
