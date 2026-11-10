// Quick-action tiles (docs/spec/3x-morepages.md §8; `S/ui-kit/quick-actions.tsx`, `S/ui-kit/components.css:84-89`):
// 2 to 4 equal glass tiles, a glyph over a short label, filling the width they are given. They reflow with the text
// size: one row at the standard sizes, two columns from AX1, one full-width tile per row (glyph beside the label)
// from AX3. A disabled tile is drawn at 40 %.

import SwiftUI

struct QuickAction: Identifiable {
    var id: String
    var label: String
    var symbol: String
    var disabled = false
    /// The button's accessibility identifier; nil = `quick-action.<id>`.
    var identifier: String?
    /// What VoiceOver reads after the label (a state, e.g. "Muted"); nil: nothing.
    var value: String?
    var run: () -> Void
}

nonisolated enum QuickActionLayout: Equatable, Sendable {
    /// One row of equal tiles.
    case row
    /// Two equal columns.
    case grid
    /// One tile per row, the glyph beside the label.
    case stacked

    static let gap: CGFloat = 8
    static let minHeight: CGFloat = 60

    static func layout(for size: DynamicTypeSize) -> QuickActionLayout {
        if size >= .accessibility3 { return .stacked }
        if size >= .accessibility1 { return .grid }
        return .row
    }

    /// Tiles per row for `count` tiles.
    func columns(_ count: Int) -> Int {
        switch self {
        case .row: return max(1, count)
        case .grid: return min(2, max(1, count))
        case .stacked: return 1
        }
    }

    /// The tiles' common width in `width` points.
    func tileWidth(count: Int, in width: CGFloat) -> CGFloat {
        let columns = CGFloat(columns(count))
        return max(0, (width - Self.gap * (columns - 1)) / columns)
    }

    /// The rows the tiles fall into (indices), in order.
    func rows(_ count: Int) -> [[Int]] {
        let per = columns(count)
        return stride(from: 0, to: count, by: per).map { Array($0..<min(count, $0 + per)) }
    }
}

struct QuickActionTiles: View {
    var actions: [QuickAction]
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = QuickActionLayout.layout(for: typeSize)
        VStack(spacing: QuickActionLayout.gap) {
            ForEach(Array(layout.rows(actions.count).enumerated()), id: \.offset) { _, row in
                HStack(spacing: QuickActionLayout.gap) {
                    ForEach(row, id: \.self) { index in tile(actions[index], layout: layout) }
                    // An odd tile in the grid keeps its column's width.
                    if layout == .grid, row.count == 1, actions.count > 1 { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func tile(_ action: QuickAction, layout: QuickActionLayout) -> some View {
        Button(action: action.run) {
            Group {
                if layout == .stacked {
                    HStack(spacing: 12) {
                        Image(systemName: action.symbol).font(Font.hq(.title3)).frame(minWidth: 28)
                        Text(action.label).font(Font.hq(.caption).weight(.medium))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: action.symbol).font(Font.hq(.title3))
                        // One line; it shrinks a little before the layout reflows at the next size class.
                        Text(action.label).font(Font.hq(.caption).weight(.medium))
                            .lineLimit(1).minimumScaleFactor(layout == .row ? 0.7 : 0.85)
                    }
                    .padding(.horizontal, -6)   // the word may use some of the button's own side padding
                }
            }
            .frame(maxWidth: .infinity, minHeight: QuickActionLayout.minHeight - 14)
        }
        .hqGlassButtonStyle()
        .disabled(action.disabled)
        .opacity(action.disabled ? 0.4 : 1)
        .accessibilityLabel(action.label)
        .accessibilityValue(action.value ?? "")
        .accessibilityShowsLargeContentViewer { Label(action.label, systemImage: action.symbol) }
        .accessibilityIdentifier(action.identifier ?? "quick-action.\(action.id)")
    }
}
