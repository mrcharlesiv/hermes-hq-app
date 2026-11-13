// [task-check-off] Ticking a task in the list (owner 2026-11-12: "a really cool animation of it going away"): the row
// leaves Today, what was under it moves up, and nothing of it is left behind. Run with scripts/e2e-pages.sh
// (HQN_PAGES_ONLY=testTasks_ZCheckOff). The Z runs it after the other Tasks tests: they share the fixture's tasks, and
// one that was ticked and unticked here answered Lists' Move To with "changed somewhere else" on the next launch.

import XCTest

extension PagesTests {
    @MainActor func testTasks_ZCheckOff() throws {
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        let cleaning = app.cells["task-row-Pick up dry cleaning"].firstMatch
        XCTAssertTrue(cleaning.waitForExistence(timeout: 20), "your own task for today")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        shot("check-off-1-before" + Self.lookName)
        // The circle at the row's lead (it is not an element of its own: the row speaks as one).
        cleaning.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 31, dy: cleaning.frame.height / 2)).tap()
        XCTAssertTrue(waitUntil(6) { !cleaning.exists }, "the ticked task leaves Today")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        shot("check-off-2-after" + Self.lookName)
        XCTAssertTrue(app.buttons["tasks.view.today"].firstMatch.isHittable, "the page still answers")

        // In Done it stands whole again (its cell was emptied for the dust), and a tap on its circle brings it back:
        // the other tests' Today has it.
        let fold = app.buttons["tasks.show-done"].firstMatch
        for _ in 0..<6 where !fold.isHittable { app.swipeUp() }
        XCTAssertTrue(fold.isHittable, "Done's Show")
        fold.tap()
        XCTAssertTrue(cleaning.waitForExistence(timeout: 5), "the ticked task is in Done")
        for _ in 0..<6 where !cleaning.isHittable { app.swipeUp() }
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        shot("check-off-3-in-done" + Self.lookName)
        cleaning.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 31, dy: cleaning.frame.height / 2)).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        for _ in 0..<6 where !fold.isHittable { app.swipeUp() }
        fold.tap()   // Hide: as the other tests find it
        for _ in 0..<6 { app.swipeDown() }
        XCTAssertTrue(waitUntil(5) { cleaning.exists && cleaning.isHittable }, "unticked, it is back in Today")
    }
}
