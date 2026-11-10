import CoreGraphics
import Testing
@testable import HermesHQNative

/// UX study 2026-10-19 #76: the gateway subtitle under the Bots and Sessions titles takes a 44 pt touch, not 20.
struct TallTouchButtonTests {
    @Test func shortButtonsGrowUpwardToFortyFourPoints() {
        // The bottom edge stays put: the bar ends just under the subtitle, so the extra height goes over the title.
        let rect = TallTouchButton.touchRect(CGRect(x: 0, y: 0, width: 120, height: 20))
        #expect(rect == CGRect(x: 0, y: -24, width: 120, height: 44))
    }

    @Test func tallButtonsKeepTheirBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 60)
        #expect(TallTouchButton.touchRect(bounds) == bounds)
    }
}
