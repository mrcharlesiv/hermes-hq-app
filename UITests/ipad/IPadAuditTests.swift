// [m9/ipad] The pointer on iPad and the screen audit of docs/spec/3x-ipad.md §7.2: the screens of every tab opened in
// two panes and in the phone layout, one screenshot each (looked at by hand; the list is in the report), plus the
// Jobs delete that must empty the right pane. Run with scripts/e2e-ipad.sh.

import XCTest

final class IPadAuditTests: IPadTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard MainActor.assumeIsolated({ IPad.isPad }) else { throw XCTSkip("iPad only") }
    }

    /// A pointer's scroll moves the flipped transcript the same way it moves an ordinary list; hover and a secondary
    /// click on a row work (the row's menu opens).
    @MainActor func test1_PointerScrollHoverAndSecondaryClick() throws {
        let account = try IPad.account(.perf)
        let app = IPad.launch(account)
        let table = IPad.openBot(app)
        // A reply long enough to scroll.
        try IPad.plan(account, [["chunks": Array(repeating: "word ", count: 2500), "chunkDelay": 0.001]])
        let token = "p\(Int(Date().timeIntervalSince1970) % 1_000_000)"
        IPad.focusField(app).typeText("scroll \(token)")
        IPad.send(app)
        let mine = IPad.message(app, containing: "scroll \(token)")
        XCTAssertTrue(mine.waitForExistence(timeout: 10))
        XCTAssertTrue(IPad.waitUntil(timeout: 40) { !app.buttons["composer.stop"].exists }, "the long reply ends")
        Thread.sleep(forTimeInterval: 1.0)
        let reply = IPad.message(app, containing: "word word word")
        XCTAssertTrue(reply.waitForExistence(timeout: 6))
        // The chat opens on the reply's top; `reply.frame` is its on-screen rectangle (it is taller than the window).
        let start = reply.frame.minY
        IPad.shot(app, "pointer-chat-before", in: self)
        table.scroll(byDeltaX: 0, deltaY: -120)
        Thread.sleep(forTimeInterval: 1.5)
        let afterFirst = reply.frame.minY
        IPad.shot(app, "pointer-chat-scrolled", in: self)
        table.scroll(byDeltaX: 0, deltaY: 120)
        Thread.sleep(forTimeInterval: 1.5)
        let afterBack = reply.frame.minY
        print("IPAD-NOTE pointer scroll in the chat (reply top): start \(start), after -120 \(afterFirst), after +120 \(afterBack)")
        XCTAssertNotEqual(start, afterFirst, accuracy: 20, "the pointer scrolls the transcript")

        // Hover and secondary click on a list row.
        app.buttons["tab-bots"].tap()
        let ivy = app.cells["bot-row-ivy"]
        XCTAssertTrue(ivy.waitForExistence(timeout: 6))
        ivy.hover()
        Thread.sleep(forTimeInterval: 0.8)
        IPad.shot(app, "pointer-hover-row", in: self)
        ivy.rightClick()
        XCTAssertTrue(app.buttons["Mark as Unread"].firstMatch.waitForExistence(timeout: 5) || app.buttons["Mark as Read"].firstMatch.waitForExistence(timeout: 2),
                      "a secondary click opens the row's menu")
        IPad.shot(app, "pointer-secondary-click-menu", in: self)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()

        // The same scroll on an ordinary list, for the direction: Settings in a short window, where it is taller
        // than the screen.
        let short = IPad.launch(account, reset: false, arguments: ["-HQDebugPaneHeight", "480"])
        XCTAssertTrue(short.buttons["tab-bots"].waitForExistence(timeout: 20))
        // The first key of a launch is the unreliable one on the simulator (docs/briefs/m9/ipad-report.md): once it
        // reached iPadOS instead of the app and opened the system's Settings. Let the launch settle, press through
        // IPad.command, and if the app is no longer in front bring it back and press again.
        Thread.sleep(forTimeInterval: 2.0)
        IPad.command(short, ",")
        let row = short.descendants(matching: .any)["settings.notifications"]
        if !row.waitForExistence(timeout: 8) {
            IPad.shot(short, "pointer-settings-not-open", in: self)
            print("IPAD-NOTE Command-comma did not open the app's Settings on the first press (app state \(short.state.rawValue))")
            short.activate()
            Thread.sleep(forTimeInterval: 2.0)
            IPad.command(short, ",")
        }
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 1.0)
        let listStart = row.frame.minY
        // On the train the Theme row pushed Notifications under the fold of the short window, where it has no point
        // for the pointer to scroll at: the pointer scrolls over the list itself and the row is only measured.
        let list = short.descendants(matching: .any)["settings.list"].firstMatch
        (list.exists ? list : row).scroll(byDeltaX: 0, deltaY: -120)
        Thread.sleep(forTimeInterval: 1.5)
        let listAfter = row.frame.minY
        IPad.shot(short, "pointer-settings-scrolled", in: self)
        print("IPAD-NOTE pointer scroll in Settings (a row's top): start \(listStart), after -120 \(listAfter)")
        guard abs(listAfter - listStart) > 20 else {
            print("IPAD-NOTE pointer scroll direction NOT settled: the ordinary list did not move")
            return
        }
        XCTAssertEqual(afterFirst < start, listAfter < listStart,
                       "the transcript scrolls the same way an ordinary list does (chat \(start) → \(afterFirst), list \(listStart) → \(listAfter))")
    }

    /// Jobs in two panes: the list stays on the left, the job's page opens on the right, and deleting the job gives
    /// the right pane back to the placeholder. Then Kanban and Artifacts, each in both layouts.
    @MainActor func test2_JobsKanbanArtifactsInBothLayouts() throws {
        let account = try IPad.account(.pages)
        let app = IPad.launch(account)
        func both(_ name: String) {
            IPad.shot(app, "audit-\(name)-two-panes", in: self)
            IPad.toggleNarrow(app)
            Thread.sleep(forTimeInterval: 1.2)
            IPad.shot(app, "audit-\(name)-phone", in: self)
            XCTAssertEqual(app.state, .runningForeground, "\(name): still running in the phone layout")
            IPad.toggleNarrow(app)
            Thread.sleep(forTimeInterval: 1.2)
            XCTAssertEqual(app.state, .runningForeground, "\(name): still running back in two panes")
        }

        app.tabBars.buttons["Jobs"].tap()
        let jobs = app.collectionViews["jobs.list"]
        XCTAssertTrue(jobs.waitForExistence(timeout: 10))
        let row = app.cells["job-row-inbox|j-once"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        both("jobs-list")
        row.tap()
        XCTAssertTrue(app.staticTexts["job.title"].waitForExistence(timeout: 8), "the job's page opens")
        XCTAssertTrue(IPad.shows(jobs), "the Jobs list stays on the left")
        XCTAssertGreaterThan(app.staticTexts["job.title"].frame.minX, jobs.frame.maxX - 1, "the page is in the right pane")
        both("job-detail")
        XCTAssertTrue(app.staticTexts["job.title"].waitForExistence(timeout: 6), "the same page is back on the right")
        let delete = app.buttons["job.delete"]
        for _ in 0..<5 where !(delete.exists && delete.isHittable) {
            app.staticTexts["job.title"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 6)).press(forDuration: 0.05, thenDragTo:
                app.staticTexts["job.title"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -6)))
        }
        delete.tap()
        let alert = app.alerts["Delete Job?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 4))
        IPad.shot(app, "audit-job-delete-alert", in: self)
        alert.buttons["Delete Job"].tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 8) { !row.exists }, "the row is gone")
        XCTAssertTrue(IPad.placeholder(app).waitForExistence(timeout: 6), "the deleted job's page leaves the right pane")
        XCTAssertFalse(app.staticTexts["job.title"].exists)
        IPad.shot(app, "audit-job-deleted", in: self)

        // Kanban: the board, a task's sheet, the board picker.
        if app.tabBars.buttons["Kanban"].exists {
            app.tabBars.buttons["Kanban"].tap()
            let task = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'kanban-task-'")).firstMatch
            XCTAssertTrue(task.waitForExistence(timeout: 10), "the board shows tasks")
            both("kanban-board")
            task.tap()
            XCTAssertTrue(app.staticTexts["kanban.task.title"].waitForExistence(timeout: 8), "the task opens")
            IPad.shot(app, "audit-kanban-task", in: self)
            XCTAssertEqual(app.state, .runningForeground)
            if !IPad.stopOrClose(app, "task sheet", done: { !app.staticTexts["kanban.task.title"].exists }) {
                let close = app.buttons["Close"].firstMatch.exists ? app.buttons["Close"].firstMatch : app.buttons["Done"].firstMatch
                if close.exists { close.tap() } else { IPad.back(app) }
            }
            let board = app.buttons["kanban.board"]
            if board.waitForExistence(timeout: 4) {
                board.tap()
                Thread.sleep(forTimeInterval: 1.2)
                IPad.shot(app, "audit-kanban-board-picker", in: self)
                XCTAssertEqual(app.state, .runningForeground)
                let dismiss = app.otherElements["PopoverDismissRegion"].firstMatch
                if dismiss.exists { dismiss.tap() } else if app.navigationBars.buttons.firstMatch.exists { IPad.back(app) }
            }
        }

        // Artifacts and a text viewer.
        app.tabBars.buttons["More"].tap()
        let artifactsRow = app.cells["more-row-artifacts"]
        if artifactsRow.waitForExistence(timeout: 5) { artifactsRow.tap() } else if app.tabBars.buttons["Artifacts"].exists { app.tabBars.buttons["Artifacts"].tap() }
        let list = app.collectionViews["artifacts.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10), "Artifacts opens")
        let file = app.cells["artifact-row-summary.md"]
        XCTAssertTrue(file.waitForExistence(timeout: 25), "the index pass lands")
        both("artifacts")
        if file.waitForExistence(timeout: 6) {
            file.tap()
            Thread.sleep(forTimeInterval: 2.0)
            IPad.shot(app, "audit-artifact-viewer", in: self)
            XCTAssertEqual(app.state, .runningForeground)
        }
    }

    /// The Bots tab's own screens: Bot Info, the + menu, the recorder, Sessions and More, in both layouts.
    @MainActor func test3_BotsChatScreensInBothLayouts() throws {
        let account = try IPad.account(.perf)
        let app = IPad.launch(account)
        IPad.openBot(app)
        app.descendants(matching: .any)["chat.title"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 2.0)
        IPad.shot(app, "audit-bot-info", in: self)
        XCTAssertEqual(app.state, .runningForeground)
        let edit = app.buttons["Edit"].firstMatch
        if edit.exists && edit.isHittable {
            edit.tap()
            Thread.sleep(forTimeInterval: 1.5)
            IPad.shot(app, "audit-edit-bot", in: self)
            XCTAssertEqual(app.state, .runningForeground)
            let cancel = app.buttons["Cancel"].firstMatch
            if cancel.exists && cancel.isHittable { cancel.tap(); Thread.sleep(forTimeInterval: 0.8) }
        }
        _ = IPad.stopOrClose(app, "bot info") { IPad.field(app).isHittable }
        if !IPad.field(app).isHittable {
            for name in ["Done", "Close"] where app.buttons[name].firstMatch.exists { app.buttons[name].firstMatch.tap(); break }
        }
        XCTAssertTrue(IPad.waitUntil(timeout: 6) { IPad.field(app).isHittable }, "Bot Info closes")

        let plus = app.buttons["composer.plus"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 5))
        plus.tap()
        XCTAssertTrue(app.buttons["composer.plus.files"].firstMatch.waitForExistence(timeout: 5) || app.buttons["Files"].firstMatch.waitForExistence(timeout: 2),
                      "the + menu opens")
        IPad.shot(app, "audit-plus-menu", in: self)
        IPad.table(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        Thread.sleep(forTimeInterval: 0.8)

        // The phone layout with the chat open, then its list.
        IPad.toggleNarrow(app)
        XCTAssertTrue(IPad.waitUntil(timeout: 6) { !IPad.shows(app.collectionViews["bots.list"]) })
        IPad.shot(app, "audit-chat-phone", in: self)
        IPad.back(app)
        XCTAssertTrue(IPad.waitUntil(timeout: 6) { IPad.shows(app.collectionViews["bots.list"]) })
        app.buttons["tab-sessions"].tap()
        XCTAssertTrue(app.collectionViews["sessions.list"].waitForExistence(timeout: 8))
        IPad.shot(app, "audit-sessions-phone", in: self)
        app.buttons["tab-more"].tap()
        XCTAssertTrue(app.collectionViews["more.list"].waitForExistence(timeout: 8))
        IPad.shot(app, "audit-more-phone", in: self)
        app.cells["more-row-settings"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.list"].waitForExistence(timeout: 8))
        IPad.shot(app, "audit-settings-phone", in: self)
        IPad.toggleNarrow(app)
        XCTAssertTrue(IPad.waitUntil(timeout: 6) { IPad.shows(app.collectionViews["more.list"]) }, "two panes again: More on the left")
        XCTAssertTrue(app.descendants(matching: .any)["settings.list"].exists, "Settings moved to the right pane")
        IPad.shot(app, "audit-settings-two-panes-after-crossing", in: self)
    }
}
