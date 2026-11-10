// skin-list-cards: a row that picks its own press colour is left alone (owner 2026-11-04, "weird glitch when you hold
// down on a bot": the held Bots row lifted solid blue, the tint a nil background colour draws).

import Testing
import UIKit
@testable import HermesHQNative

@MainActor @Suite struct SkinListCardsTests {
    /// The Bots row's own background while pressed (`BotsViewController.configureDataSource`).
    private func pressedRow() -> UIBackgroundConfiguration {
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = HQPalette.cellPressed
        return background
    }

    @Test func aRowsOwnPressColourIsLeftAloneInTheStandardLook() {
        let cell = UICollectionViewListCell(frame: CGRect(x: 0, y: 0, width: 400, height: 74))
        #expect(!SkinListCards.skinned(cell.traitCollection), "the standard look paints no page of its own")
        #expect(SkinListCards.adjusted(pressedRow(), cell: cell, pressed: true) == nil, "pressed: no change")
        #expect(SkinListCards.adjusted(pressedRow(), cell: cell, pressed: false) == nil, "nor while the state settles")
    }

    @Test func aRowsOwnPressColourIsNeverMadeNil() {
        // Through the cell's layout too (the hook that put nil there): the colour stays the row's grey, never the tint.
        SkinListCards.install()
        let cell = UICollectionViewListCell(frame: CGRect(x: 0, y: 0, width: 400, height: 74))
        cell.configurationUpdateHandler = { cell, state in
            var background = UIBackgroundConfiguration.clear()
            background.backgroundColor = state.isHighlighted ? HQPalette.cellPressed : .clear
            cell.backgroundConfiguration = background
        }
        cell.isHighlighted = true
        cell.setNeedsUpdateConfiguration()
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        #expect(cell.backgroundConfiguration?.backgroundColor === HQPalette.cellPressed)
    }
}
