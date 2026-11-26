// skin-list-cards: a row that picks its own press colour is left alone (owner 2026-11-04, "weird glitch when you hold
// down on a bot": the held Bots row lifted solid blue, the tint a nil background colour draws).

import SwiftUI
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

    @Test func bareRowsInInsetGroupedListDropCornerClipWhileCardsKeepTheirs() async throws {
        SkinListCards.install()
        struct ProbeList: View {
            var body: some View {
                List {
                    Section {
                        Color.red
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                    Section {
                        Text("Normal card row")
                    }
                    Section {
                        Text("Sheet card row")
                            .listRowBackground(Color(uiColor: HQPalette.sheetCard))
                    }
                }
                .listStyle(.insetGrouped)
            }
        }

        let host = UIHostingController(rootView: ProbeList())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        host.view.layoutIfNeeded()
        // Wait a few run-loop turns for SwiftUI's collection view layout and BareRowCorners' deferred pass to settle.
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(30))
            host.view.layoutIfNeeded()
        }

        func findCollectionView(in view: UIView) -> UICollectionView? {
            if let cv = view as? UICollectionView { return cv }
            for sub in view.subviews { if let found = findCollectionView(in: sub) { return found } }
            return nil
        }

        let list = try #require(findCollectionView(in: host.view))
        let bareCell = try #require(list.cellForItem(at: IndexPath(item: 0, section: 0)) as? UICollectionViewListCell)
        let cardCell = try #require(list.cellForItem(at: IndexPath(item: 0, section: 1)) as? UICollectionViewListCell)
        let sheetCardCell = try #require(list.cellForItem(at: IndexPath(item: 0, section: 2)) as? UICollectionViewListCell)

        // Force another layout pass to verify UIKit layoutSubviews never re-clips the bare row.
        bareCell.setNeedsLayout(); bareCell.layoutIfNeeded()
        list.setNeedsLayout(); list.layoutIfNeeded()

        #expect(SkinListCards.isBareRow(bareCell), "clear-background SwiftUI row should be detected as bare")
        #expect(!SkinListCards.isBareRow(cardCell), "default grouped card row must not be detected as bare")
        #expect(!SkinListCards.isBareRow(sheetCardCell), "painted listRowBackground card must not be detected as bare")

        #expect(!bareCell.clipsToBounds, "bare row should disable clipsToBounds so 26 pt cell corners do not clip content")
        #expect(cardCell.clipsToBounds, "normal grouped card row should stay clipped to its rounded corners")
        #expect(sheetCardCell.clipsToBounds, "painted custom-background card row should stay clipped to its rounded corners")

        // Pixel-level check: solid red content at (2, 2) inside the bare row renders unclipped, while normal cards clip (2, 2).
        func cornerAlpha(of view: UIView) -> CGFloat {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20))
            let image = renderer.image { ctx in view.layer.render(in: ctx.cgContext) }
            guard let cg = image.cgImage, let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return -1 }
            let scale = Int(image.scale), bpp = cg.bitsPerPixel / 8
            let offset = (2 * scale) * cg.bytesPerRow + (2 * scale) * bpp
            return CGFloat(ptr[offset + 3]) / 255.0
        }
        #expect(cornerAlpha(of: bareCell) > 0.9, "top-left corner pixel of bare row must not be clipped")
        #expect(cornerAlpha(of: cardCell) < 0.1, "top-left corner pixel of normal card row should remain rounded/clipped")
        #expect(cornerAlpha(of: sheetCardCell) < 0.1, "top-left corner pixel of painted sheet card should remain rounded/clipped")
    }

    @Test func softCardListCellWithClearBackgroundIsNotTreatedAsBare() {
        let cell = SoftCardListCell(frame: CGRect(x: 0, y: 0, width: 350, height: 60))
        var bg = UIBackgroundConfiguration.listCell()
        bg.backgroundColor = .clear
        cell.backgroundConfiguration = bg
        #expect(!SkinListCards.isBareRow(cell),
                "UIKit SoftCardListCell (Kanban card row) must keep its card corner clip for press highlights")
    }

    @Test func bareRowCornersRestoreOnPrepareForReuse() {
        let cell = UICollectionViewListCell(frame: CGRect(x: 0, y: 0, width: 350, height: 60))
        cell.clipsToBounds = true
        var bg = UIBackgroundConfiguration.clear()
        bg.backgroundColor = .clear
        cell.backgroundConfiguration = bg
        cell.hqBareRow = true

        BareRowCorners.apply(cell)
        #expect(!cell.clipsToBounds, "apply should disable clipsToBounds on bare cell")

        BareRowCorners.resetOnReuse(cell)
        #expect(!cell.hqBareRow, "prepareForReuse should clear stale hqBareRow flag")
        #expect(cell.clipsToBounds, "prepareForReuse should restore clipsToBounds for reused card cells")
    }

    @Test func bareRowCornersRestoreWhenRowBecomesPaintedCardInPlace() {
        let cell = UICollectionViewListCell(frame: CGRect(x: 0, y: 0, width: 350, height: 60))
        cell.clipsToBounds = true
        let clearHost = UIView(frame: cell.bounds)
        var bg = UIBackgroundConfiguration.clear()
        bg.customView = clearHost
        cell.backgroundConfiguration = bg

        BareRowCorners.apply(cell)
        #expect(!cell.clipsToBounds, "unpainted customView row should disable clipsToBounds")

        clearHost.backgroundColor = HQPalette.sheetCard
        BareRowCorners.apply(cell)
        #expect(cell.clipsToBounds, "row whose customView paints a card should restore clipsToBounds")
    }
}
