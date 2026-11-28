// [mac] Shared layout math and Mac navigation chrome for horizontal card carousels in chat (Hotels, Shopping).
// On narrow phones the strip bleeds edge-to-edge so peeking cards invite a swipe. On Mac wide panes the strip fits
// exact whole tiles within the card rail so a card is never hard-clipped mid-tile, and circular/desktop prev/next
// arrows let mouse users page cleanly by whole-tile strides. Wide iPad touch panes keep an inset peeking strip so
// touch users still see that more cards lie ahead.

import UIKit

/// Pure geometry for a horizontal card carousel (safe to compute off the main thread).
nonisolated struct ChatCarouselMetrics: Sendable, Equatable {
    /// True on phone/narrow columns where the carousel spans the full row width (`0..<rowWidth`).
    var bleeds: Bool
    /// True when the strip snaps & sizes to exact whole visible tiles with no mid-card peek (Mac wide panes).
    var wholeTiles: Bool
    /// Frame of the scroll viewport in the row's coordinate space (origin.y set by caller).
    var stripX: CGFloat
    var stripWidth: CGFloat
    /// Leading and trailing content inset inside the scroll view (`side` when bleeding, `0` on wide panes).
    var contentInset: CGFloat
    /// Width of each card tile.
    var tileWidth: CGFloat
    /// Horizontal spacing between adjacent tiles.
    var spacing: CGFloat
    /// Number of whole tiles visible at once (`1+`); matches `count` when all tiles fit without scrolling.
    var visibleColumns: Int
    /// Total scrollable content width (`contentSize.width`).
    var contentWidth: CGFloat

    /// Distance between the start of one tile and the next.
    var stride: CGFloat { tileWidth + spacing }
    /// Maximum valid horizontal `contentOffset.x`.
    var maxOffset: CGFloat { max(0, contentWidth - stripWidth) }
    /// True when the strip actually overflows its viewport and needs horizontal navigation.
    var isScrollable: Bool { maxOffset > 1 }

    /// True on phone/narrow columns where the card spans the full row width so the carousel can bleed edge-to-edge.
    static func bleeds(rowWidth: CGFloat, cardWidth: CGFloat, side: CGFloat = 16) -> Bool {
        rowWidth <= cardWidth + 2 * side + 1
    }

    /// Computes clean carousel geometry for `count` items inside a row of width `rowWidth` and rail width `cardWidth`.
    /// - Parameters:
    ///   - count: Number of cards in the strip.
    ///   - rowWidth: Full width of the chat cell's content column.
    ///   - cardWidth: Left-anchored card rail width (`PromptLayout.cardWidth(for: rowWidth)`).
    ///   - side: Standard chat side inset (16 pt).
    ///   - spacing: Gap between adjacent cards.
    ///   - phoneTileWidth: Tile width to use on narrow bleeding phone columns (and wide touch peeking strips).
    ///   - minWideTile: Minimum comfortable tile width on Mac wide panes (determines how many whole columns fit).
    ///   - maxWideTile: Maximum tile width when `count` is small so tiles never stretch awkwardly wide.
    ///   - singleWideCap: Maximum width for a single-item strip on wide panes (`nil` uses `cardWidth`).
    ///   - wholeTiles: True on Mac Catalyst where prev/next arrows provide explicit paging and cards should never be clipped mid-tile; false on wide iPad touch panes so the next tile peeks as a scroll cue.
    static func compute(
        count: Int,
        rowWidth: CGFloat,
        cardWidth: CGFloat,
        side: CGFloat = 16,
        spacing: CGFloat,
        phoneTileWidth: CGFloat,
        minWideTile: CGFloat,
        maxWideTile: CGFloat,
        singleWideCap: CGFloat? = nil,
        wholeTiles: Bool = DeviceWord.isMac
    ) -> ChatCarouselMetrics {
        let safeCount = max(0, count)
        let bleeds = Self.bleeds(rowWidth: rowWidth, cardWidth: cardWidth, side: side)
        guard safeCount > 0 else {
            return ChatCarouselMetrics(
                bleeds: bleeds, wholeTiles: false, stripX: bleeds ? 0 : side, stripWidth: bleeds ? rowWidth : cardWidth,
                contentInset: bleeds ? side : 0, tileWidth: 0, spacing: spacing, visibleColumns: 0, contentWidth: 0
            )
        }
        if bleeds {
            let tileW = safeCount == 1 ? cardWidth : phoneTileWidth
            let contentW = side * 2 + CGFloat(safeCount) * tileW + CGFloat(max(0, safeCount - 1)) * spacing
            return ChatCarouselMetrics(
                bleeds: true,
                wholeTiles: false,
                stripX: 0,
                stripWidth: rowWidth,
                contentInset: side,
                tileWidth: tileW,
                spacing: spacing,
                visibleColumns: max(1, Int(floor((rowWidth - side + spacing) / max(1, tileW + spacing)))),
                contentWidth: contentW
            )
        }
        if safeCount == 1 {
            let tileW = min(cardWidth, singleWideCap ?? cardWidth)
            return ChatCarouselMetrics(
                bleeds: false, wholeTiles: wholeTiles, stripX: side, stripWidth: tileW, contentInset: 0,
                tileWidth: tileW, spacing: spacing, visibleColumns: 1, contentWidth: tileW
            )
        }
        if !wholeTiles {
            // Wide iPad touch pane: stay inset on the card rail and keep a peeking next card as a scroll affordance.
            let tileW = min(maxWideTile, phoneTileWidth)
            let contentW = CGFloat(safeCount) * tileW + CGFloat(safeCount - 1) * spacing
            let viewportW = min(cardWidth, contentW)
            let visible = max(1, Int(floor((viewportW + spacing) / max(1, tileW + spacing))))
            return ChatCarouselMetrics(
                bleeds: false,
                wholeTiles: false,
                stripX: side,
                stripWidth: viewportW,
                contentInset: 0,
                tileWidth: tileW,
                spacing: spacing,
                visibleColumns: visible,
                contentWidth: contentW
            )
        }
        // Mac wide pane: fit an exact whole number of tiles inside `cardWidth` so no card is clipped mid-tile at rest.
        let maxFit = max(1, Int(floor((cardWidth + spacing) / max(1, minWideTile + spacing))))
        let columns = min(safeCount, maxFit)
        let rawTile = floor((cardWidth - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        let tileW = min(maxWideTile, max(minWideTile, rawTile))
        let viewportW = CGFloat(columns) * tileW + CGFloat(columns - 1) * spacing
        let contentW = CGFloat(safeCount) * tileW + CGFloat(safeCount - 1) * spacing
        return ChatCarouselMetrics(
            bleeds: false,
            wholeTiles: true,
            stripX: side,
            stripWidth: min(cardWidth, viewportW),
            contentInset: 0,
            tileWidth: tileW,
            spacing: spacing,
            visibleColumns: columns,
            contentWidth: contentW
        )
    }

    /// Next horizontal offset when clicking Previous (`forward == false`) or Next (`forward == true`).
    func steppedOffset(from currentOffset: CGFloat, forward: Bool) -> CGFloat {
        guard isScrollable, stride > 0 else { return 0 }
        let clamped = min(maxOffset, max(0, currentOffset))
        if wholeTiles {
            let pageSpan = CGFloat(max(1, visibleColumns)) * stride
            let currentIndex = (clamped / stride).rounded()
            let currentAligned = min(maxOffset, max(0, currentIndex * stride))
            return forward ? min(maxOffset, currentAligned + pageSpan) : max(0, currentAligned - pageSpan)
        }
        // Narrow Mac window in bleed mode: advance/retreat by one tile stride cleanly, snapping neatly to 0 / maxOffset.
        let step = CGFloat(max(1, visibleColumns)) * stride
        if forward {
            let next = clamped + step
            return maxOffset - next < stride * 0.35 ? maxOffset : min(maxOffset, next)
        } else {
            let prev = clamped - step
            return prev < stride * 0.35 ? 0 : max(0, prev)
        }
    }

    /// Snaps a dragged/coasted or restored offset to the nearest whole tile boundary in whole-tile mode so cards never
    /// rest half-clipped. Returns the clamped offset unchanged in peeking/bleed modes.
    func snappedOffset(for proposedOffset: CGFloat) -> CGFloat {
        let clamped = min(maxOffset, max(0, proposedOffset))
        guard wholeTiles, isScrollable, stride > 0 else { return clamped }
        if clamped <= 2 { return 0 }
        if maxOffset - clamped <= 2 { return maxOffset }
        let snapped = (clamped / stride).rounded() * stride
        return min(maxOffset, max(0, snapped))
    }
}

/// [mac] Previous / next buttons overlaid on a horizontal chat carousel on Mac Catalyst so mouse users can page
/// through overflowing tiles without a trackpad swipe. Follows Desktop Look vs Liquid Glass chrome and hides
/// automatically when at the start/end or when all tiles fit. No views are created on iPhone/iPad.
@MainActor final class ChatCarouselArrows {
    private(set) var previousButton: UIButton?
    private(set) var nextButton: UIButton?
    private var metrics: ChatCarouselMetrics?
    private weak var scrollView: UIScrollView?

    init(in host: UIView, identifier: String, itemNoun: String = "items", onStep: @escaping (Bool) -> Void) {
        #if targetEnvironment(macCatalyst)
        let prev = Self.makeButton(forward: false, identifier: "\(identifier).previous", itemNoun: itemNoun) { onStep(false) }
        let next = Self.makeButton(forward: true, identifier: "\(identifier).next", itemNoun: itemNoun) { onStep(true) }
        host.addSubview(prev)
        host.addSubview(next)
        previousButton = prev
        nextButton = next
        #endif
    }

    var visibleButtons: [UIView] {
        [previousButton, nextButton].compactMap { $0 }.filter { !$0.isHidden }
    }

    /// Positions the arrows relative to `stripFrame`, vertically centered at `stripFrame.minY + yCenter`, and updates
    /// visibility for the scroll view's current offset.
    func configure(scrollView: UIScrollView, stripFrame: CGRect, yCenter: CGFloat, metrics: ChatCarouselMetrics) {
        self.scrollView = scrollView
        self.metrics = metrics
        #if targetEnvironment(macCatalyst)
        let size: CGFloat = 32
        let inset: CGFloat = 8
        let y = round(stripFrame.minY + yCenter - size / 2)
        previousButton?.frame = CGRect(x: stripFrame.minX + inset, y: y, width: size, height: size)
        nextButton?.frame = CGRect(x: stripFrame.maxX - inset - size, y: y, width: size, height: size)
        if let prev = previousButton { prev.superview?.bringSubviewToFront(prev) }
        if let next = nextButton { next.superview?.bringSubviewToFront(next) }
        restyle()
        update()
        #endif
    }

    func hide() {
        previousButton?.isHidden = true
        nextButton?.isHidden = true
    }

    @discardableResult
    func update() -> Bool {
        #if targetEnvironment(macCatalyst)
        guard let scrollView, let metrics, metrics.isScrollable else {
            let changed = previousButton?.isHidden == false || nextButton?.isHidden == false
            hide()
            return changed
        }
        let x = scrollView.contentOffset.x
        let hidePrev = !(x > 2)
        let hideNext = !(x < metrics.maxOffset - 2)
        let changed = previousButton?.isHidden != hidePrev || nextButton?.isHidden != hideNext
        previousButton?.isHidden = hidePrev
        nextButton?.isHidden = hideNext
        return changed
        #else
        return false
        #endif
    }

    func restyle() {
        #if targetEnvironment(macCatalyst)
        let desktop = Theme.isDesktop
        for button in [previousButton, nextButton].compactMap({ $0 }) {
            let traits = button.traitCollection
            button.layer.cornerRadius = desktop ? HQShape.desktopRadius(.control) : 16
            button.layer.shadowOpacity = desktop ? 0 : 0.18
            button.backgroundColor = ChatPalette.elevated.resolvedColor(with: traits).withAlphaComponent(desktop ? 1 : 0.94)
            let edge = ChatPalette.promptEdge.resolvedColor(with: traits)
            let fallback = ChatPalette.separator.resolvedColor(with: traits)
            button.layer.borderColor = (edge.cgColor.alpha > 0 ? edge : fallback).cgColor
            button.layer.borderWidth = max(HQShape.pixel(traits.displayScale), 1)
        }
        #endif
    }

    #if targetEnvironment(macCatalyst)
    private static func makeButton(forward: Bool, identifier: String, itemNoun: String, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: forward ? "chevron.right" : "chevron.left",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        )
        config.baseForegroundColor = ChatPalette.label
        config.contentInsets = .zero
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in
            Haptics.play(.selection)
            action()
        })
        button.layer.cornerRadius = Theme.isDesktop ? HQShape.desktopRadius(.control) : 16
        button.layer.cornerCurve = .continuous
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = Theme.isDesktop ? 0 : 0.18
        button.layer.shadowRadius = 6
        button.layer.shadowOffset = CGSize(width: 0, height: 2)
        button.accessibilityLabel = forward ? "Next \(itemNoun)" : "Previous \(itemNoun)"
        button.accessibilityIdentifier = identifier
        button.toolTip = button.accessibilityLabel
        button.isHidden = true
        PointerEffects.button(button)
        return button
    }
    #endif
}
