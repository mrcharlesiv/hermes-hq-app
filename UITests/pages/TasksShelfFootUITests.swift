// [tasks-first] Owner 2026-11-23 ("This looks a little high"): on a task's view the chat's own message box stands
// aside and the view's one-line "Message <bot>" box sits at its foot. The shelf (here a browser chip, from the DEBUG
// HQDebugBrowserChip hook) stood on the hidden box, about 50 pt over the visible one, across the page's last lines.
// It stands just over the one-line box now, and over the chat's own box once the chat has the screen.
// Run with scripts/e2e-pages.sh (HQN_PAGES_ONLY=testTasks_ShelfOnMessageLine).

import XCTest

extension PagesTests {
    @MainActor func testTasks_ShelfOnMessageLine() throws {
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks",
                                          "-HQPagesOpenTask", "Follow up with Ivy on the contract",
                                          "-HQDebugBrowserChip", "Browsing example.test"])
        let message = app.buttons["task.message"].firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 20), "the task opens with its one-line message box")
        let pill = app.buttons["chat.shelf.summary"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "the browser chip shows on the task's view")
        XCTAssertTrue(waitUntil(5) { abs(message.frame.minY - pill.frame.maxY) < 20 }, "settled")
        shot("tasks-shelf-foot-1-task-view" + Self.lookName)
        let gap = message.frame.minY - pill.frame.maxY
        XCTAssertGreaterThanOrEqual(gap, -1, "the chip doesn't cover the message box: pill \(pill.frame) box \(message.frame)")
        XCTAssertLessThan(gap, 20, "the chip stands just over the message box, not floating over the page: gap \(gap)")

        // The page leaves room at its foot: scrolled to the end, its last row stands clear of the chip.
        for _ in 0..<4 { app.scrollViews.firstMatch.swipeUp() }
        // The page's last line: when Inbox looks again, at the foot of its teammate section.
        let checks = app.descendants(matching: .any).matching(identifier: "task.next-check")
        XCTAssertTrue(checks.firstMatch.waitForExistence(timeout: 5), "the page's last line")
        let last = checks.element(boundBy: checks.count - 1)
        XCTAssertTrue(waitUntil(5) { last.frame.maxY <= pill.frame.minY + 1 },
                      "the last line scrolls clear of the chip: line \(last.frame) pill \(pill.frame)")
        shot("tasks-shelf-foot-1b-task-view-end" + Self.lookName)

        // The chat takes the screen: the chip stands over the chat's own box again.
        message.tap()
        let field = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the chat's own box")
        XCTAssertTrue(waitUntil(5) { pill.frame.maxY <= field.frame.minY + 1 },
                      "the chip stands over the chat's box: pill \(pill.frame) box \(field.frame)")
        shot("tasks-shelf-foot-2-chat" + Self.lookName)
    }
}
