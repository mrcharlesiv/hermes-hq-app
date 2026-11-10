// 3x-morepages §8 (U7): how quick-action tiles lay out at each text size.

import SwiftUI
import Testing
@testable import HermesHQNative

struct QuickActionLayoutTests {
    @Test func oneRowAtStandardSizesTwoColumnsFromAX1FullWidthFromAX3() {
        let standard: [DynamicTypeSize] = [.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge]
        for size in standard { #expect(QuickActionLayout.layout(for: size) == .row) }
        #expect(QuickActionLayout.layout(for: .accessibility1) == .grid)
        #expect(QuickActionLayout.layout(for: .accessibility2) == .grid)
        for size in [DynamicTypeSize.accessibility3, .accessibility4, .accessibility5] { #expect(QuickActionLayout.layout(for: size) == .stacked) }
    }

    @Test func tilesInARowHaveEqualWidthsThatFillIt() {
        for count in 2...4 {
            let width = QuickActionLayout.row.tileWidth(count: count, in: 350)
            #expect(abs(width * CGFloat(count) + QuickActionLayout.gap * CGFloat(count - 1) - 350) < 0.001)
            #expect(QuickActionLayout.row.rows(count) == [Array(0..<count)])
        }
        #expect(QuickActionLayout.row.tileWidth(count: 4, in: 350) == 81.5)
    }

    @Test func theGridIsTwoColumnsAndTheStackOne() {
        #expect(QuickActionLayout.grid.rows(4) == [[0, 1], [2, 3]])
        #expect(QuickActionLayout.grid.rows(3) == [[0, 1], [2]])
        #expect(QuickActionLayout.grid.rows(2) == [[0, 1]])
        #expect(QuickActionLayout.grid.tileWidth(count: 3, in: 350) == 171)
        #expect(QuickActionLayout.grid.columns(1) == 1)
        #expect(QuickActionLayout.stacked.rows(3) == [[0], [1], [2]])
        #expect(QuickActionLayout.stacked.tileWidth(count: 4, in: 350) == 350)
        #expect(QuickActionLayout.row.rows(0).isEmpty)
    }

    @Test func theSpacingIsTheWebs() {
        #expect(QuickActionLayout.minHeight == 60)
        #expect(QuickActionLayout.gap == 8)
    }
}
