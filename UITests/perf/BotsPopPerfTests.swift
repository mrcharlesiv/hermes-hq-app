// [perf] Build 297, "Smooth back to Bots": drives the moment the owner's FrameMeter records showed stuttering (every pop
// from a chat back to the Bots list, ~80–90 ms of hitch a second) against the back-to-Bots fixture
// (scripts/fixtures/botspop-gateway.py: twelve bots, six pinned faces, one kept working by a "slow:" turn). The app's
// own FrameMeter measures; scripts/perf-botspop.sh reads its `frames` records out of the app's log outbox. Phases are
// cut by sending the app home (FrameMeter sends every bucket when the app leaves the screen):
//   1. setup: open Inbox, start its slow turn, back
//   2. Back button: 8 pops, alternating a row (Ivy) and a tile (Writer)
//   3. edge swipe: 8 pops, the same chats
// An extension of SettingsEndToEndTests (same sign-in and helpers). Run with scripts/perf-botspop.sh <SIM>.

import XCTest

extension SettingsEndToEndTests {
    @MainActor private func popOpen(_ app: XCUIApplication, _ id: String) {
        let row = app.cells["bot-row-\(id)"].exists ? app.cells["bot-row-\(id)"] : app.cells["bot-tile-\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(id) is on the list")
        row.tap()
        Thread.sleep(forTimeInterval: 1.5)   // the push runs unwatched, then the chat settles (fill, reveal)
        XCTAssertTrue(appears(app.tables["chat.table"], app, "pop-open-\(id)", timeout: 15), "\(id)'s chat opens")
        Thread.sleep(forTimeInterval: 0.5)
    }

    @MainActor private func popBack(_ app: XCUIApplication, swipe: Bool) {
        if swipe {
            // An edge swipe from the left edge, released past the middle (the interactive pop).
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
            // Nothing is asked of the app while the pop runs: a query walks its accessibility tree on the main thread.
            Thread.sleep(forTimeInterval: 1.5)
            // A swipe the system took for something else: once more (the missed one is not a pop, so it is not measured).
            if app.tables["chat.table"].exists {
                start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
                Thread.sleep(forTimeInterval: 1.5)
            }
        } else {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            back.tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
        XCTAssertTrue(waitUntil(timeout: 6) { !app.tables["chat.table"].exists }, "back on the Bots list")
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// FrameMeter sends its buckets when the app leaves the screen: home and back cuts a phase.
    @MainActor private func cutPhase(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1.5)
        app.activate()
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1.0)
    }

    @MainActor func testP01_BackToBotsFrames() throws {
        guard ProcessInfo.processInfo.environment["HQN_BOTSPOP"] == "1" else {
            throw XCTSkip("Run scripts/perf-botspop.sh (it starts the back-to-Bots fixture and reads the frames records).")
        }
        let app = launchSignedIn()
        XCTAssertTrue(app.cells["bot-tile-writer"].waitForExistence(timeout: 15), "the pinned faces show")
        // 1. Inbox starts a long turn: its face rings and its row changes while other chats are open.
        popOpen(app, "inbox")
        let field = app.textViews["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText("slow: keep working")
        app.buttons["composer.send"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        popBack(app, swipe: false)
        cutPhase(app)
        // Room for a profiler to attach (scripts/perf-botspop.sh with HQN_BOTSPOP_TRACE).
        if let pause = ProcessInfo.processInfo.environment["HQN_BOTSPOP_PAUSE"].flatMap(Double.init) { Thread.sleep(forTimeInterval: pause) }
        // 2. The Back button.
        for n in 0..<8 {
            popOpen(app, n % 2 == 0 ? "ivy" : "writer")
            popBack(app, swipe: false)
        }
        cutPhase(app)
        // 3. The edge swipe.
        for n in 0..<8 {
            popOpen(app, n % 2 == 0 ? "ivy" : "writer")
            popBack(app, swipe: true)
        }
        cutPhase(app)
    }

    /// A slow swipe back held under the finger, let go early (the chat stays) and then let go late (back to Bots):
    /// the tab bar stays out of sight while the finger holds the page and comes in whole when it lets go
    /// (`HeldSwipeTabBar`). What the bar looks like mid-swipe is judged on film: run with HQN_BOTSPOP=held against the
    /// back-to-Bots fixture while `xcrun simctl io <SIM> recordVideo` films the simulator.
    @MainActor func testP02_HeldSwipeBack() throws {
        guard ProcessInfo.processInfo.environment["HQN_BOTSPOP"] == "held" else {
            throw XCTSkip("Run with HQN_BOTSPOP=held against the back-to-Bots fixture, filming the simulator.")
        }
        let app = launchSignedIn()
        popOpen(app, "ivy")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        let half = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: half, withVelocity: .slow, thenHoldForDuration: 3)
        Thread.sleep(forTimeInterval: 1.5)   // let go under the middle: the chat comes back
        XCTAssertTrue(app.tables["chat.table"].exists, "a swipe let go before the middle keeps the chat")
        let far = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: far, withVelocity: .slow, thenHoldForDuration: 3)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(waitUntil(timeout: 6) { !app.tables["chat.table"].exists }, "back on the Bots list")
        XCTAssertTrue(app.buttons["tab-bots"].isHittable, "the tab bar is back")
        // A quick flick, and the Back button: the bar is there after each.
        popOpen(app, "ivy")
        popBack(app, swipe: true)
        XCTAssertTrue(app.buttons["tab-bots"].isHittable, "the tab bar is back after a flick")
        popOpen(app, "ivy")
        popBack(app, swipe: false)
        XCTAssertTrue(app.buttons["tab-bots"].isHittable, "the tab bar is back after the Back button")
    }
}
