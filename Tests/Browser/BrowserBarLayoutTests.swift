import CoreGraphics
import Testing
@testable import HermesHQNative

/// UX study 2026-10-19 #84: Give Back takes its own row whenever the one row would not fit, not only at AX sizes.
@Suite struct BrowserBarLayoutTests {
    @Test func accessibilitySizesAlwaysStack() {
        #expect(BrowserBarLayout.stacks(accessibility: true, icons: 100, give: 60, width: 430))
        #expect(BrowserBarLayout.stacks(accessibility: true, icons: 100, give: 60, width: 0))
    }

    @Test func aRowThatFitsStaysOneRow() {
        // 260 + 8 + 90 = 358 fits the 361 pt between a 393 pt phone's margins.
        #expect(!BrowserBarLayout.stacks(accessibility: false, icons: 260, give: 90, width: 393))
    }

    @Test func aRowPastTheMarginsStacks() {
        // Extra Large on a 375 pt phone: 290 + 8 + 100 = 398 is past the 343 pt between the margins.
        #expect(BrowserBarLayout.stacks(accessibility: false, icons: 290, give: 100, width: 375))
        // Exactly at the margins still fits.
        #expect(!BrowserBarLayout.stacks(accessibility: false, icons: 235, give: 100, width: 375))
    }

    @Test func notLaidOutYetDecidesByTextSize() {
        #expect(!BrowserBarLayout.stacks(accessibility: false, icons: 400, give: 100, width: 0))
    }
}
