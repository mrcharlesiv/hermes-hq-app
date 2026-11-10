// [tabs] Bot Info's tabs (About, Brain, Chats, Artifacts, Settings; tester feedback and owner, 2026-11-01): a test picks
// one by its name, in whichever form the tabs take (the segments, two rows of two, the Desktop Look's strip, or the
// pull-down at the accessibility sizes or when they don't fit). [theme-pages] Theme has no tabs since 2026-11-03.

import XCTest

extension XCUIApplication {
    @MainActor func botInfoTab(_ title: String) { pageTab(title, identifier: "bot-info.tab", bar: "Bot Info") }

    @MainActor func pageTab(_ title: String, identifier: String, bar barTitle: String) {
        let tabs = descendants(matching: .any).matching(identifier: identifier).firstMatch
        // A long tab scrolled the tabs away or under the sheet's bar (the largest text sizes): drag back to them, a
        // short drag at a time and only while they're out of sight, so it never pulls the sheet down (a sheet just
        // opened gets its moment to draw them first).
        _ = tabs.waitForExistence(timeout: 2)
        let bar = navigationBars[barTitle]
        func inSight() -> Bool { tabs.exists && tabs.isHittable && (!bar.exists || tabs.frame.minY >= bar.frame.maxY) }
        for _ in 0..<10 where !inSight() {
            let middle = coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: 160)), withVelocity: .slow,
                         thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(tabs.waitForExistence(timeout: 5), "\(barTitle)'s tabs")
        let segment = tabs.buttons[title].firstMatch
        if segment.exists {
            segment.tap()
        } else {
            tabs.tap()   // the pull-down
            buttons[title].firstMatch.tap()
        }
    }

    /// Swipes a tab up until `element` shows (the largest text sizes start its rows below the fold).
    @MainActor func botInfoReveal(_ element: XCUIElement) -> Bool {
        _ = element.waitForExistence(timeout: 3)
        for _ in 0..<6 where !(element.exists && element.isHittable) { swipeUp() }
        return element.exists
    }
}
