// [quick-actions] How a Quick Actions tile looks (docs/spec/3x-morepages.md §25 Q2): a coloured icon square, a bold
// name and a grey line under it. The same face draws on the page, in the setup form's preview and in Add Action.

import SwiftUI
import UIKit

enum QuickTileLook {
    /// The colours a tile can take, in the setup form's order. Accent, red, orange and green are the theme's own.
    static func color(_ color: QuickTileColor) -> UIColor {
        switch color {
        case .accent: HQPalette.tint
        case .red: HQPalette.red
        case .orange: HQPalette.orange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .teal: .systemTeal
        case .indigo: .systemIndigo
        case .pink: .systemPink
        case .gray: .systemGray
        }
    }

    static func colorName(_ color: QuickTileColor) -> String {
        switch color {
        case .accent: "Theme"
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .teal: "Teal"
        case .indigo: "Indigo"
        case .pink: "Pink"
        case .gray: "Grey"
        }
    }

    /// The icons the setup form offers (curated: each reads at 18 pt on a coloured square).
    static let symbols = [
        "square.and.pencil", "mic.fill", "waveform", "paperplane.fill", "bubble.left.fill", "bubble.left.and.bubble.right.fill",
        "checklist", "bolt.fill", "magnifyingglass", "square.grid.2x2.fill", "star.fill", "heart.fill",
        "house.fill", "briefcase.fill", "calendar", "envelope.fill", "bell.fill", "doc.text.fill",
        "folder.fill", "chart.bar.fill", "terminal.fill", "globe", "lightbulb.fill", "sparkles",
        "clock.fill", "cart.fill", "airplane", "car.fill", "book.fill", "camera.fill",
    ]

    /// An icon this system can draw, else the page square (a newer build's symbol on an older system).
    static func symbol(_ name: String) -> String { UIImage(systemName: name) != nil ? name : "square.grid.2x2.fill" }
}

/// The coloured square with the tile's icon.
struct QuickTileIcon: View {
    var symbol: String
    var color: UIColor
    var side: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.26, style: .continuous)
            .fill(Color(uiColor: color))
            .frame(width: side, height: side)
            .overlay {
                Image(systemName: QuickTileLook.symbol(symbol))
                    .font(.system(size: side * 0.48, weight: .semibold))   // a11y-font-ok: symbol sized to its square tile
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// A tile's face: icon at the top, name and subtitle under it (beside it when `stacked`, from AX3).
struct QuickTileFace: View {
    var name: String
    var subtitle: String
    var symbol: String
    var color: UIColor
    var stacked = false
    var dimmed = false
    /// [quick-actions] A Short tile (3x-morepages Q13): one line high, the icon beside the words.
    var short = false
    /// [favorites-live-tiles] Beside a Dashboard tile the row is the tile's height: the icon stays at the top and the
    /// words go to the foot, as a widget's (3x-morepages Q19).
    var fills = false

    var body: some View {
        let side = HQFont.scaled(short ? 28 : 34)
        Group {
            if short {
                HStack(alignment: .center, spacing: 10) {
                    QuickTileIcon(symbol: symbol, color: color, side: side)
                    lines(name: name.isEmpty ? " " : name, subtitle: subtitle, limit: 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if stacked {
                HStack(alignment: .center, spacing: 12) {
                    QuickTileIcon(symbol: symbol, color: color, side: side)
                    words(reserve: false)
                    Spacer(minLength: 0)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    QuickTileIcon(symbol: symbol, color: color, side: side)
                    if fills { Spacer(minLength: 0) }
                    words(reserve: true)
                }
                .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .leading)
            }
        }
        .padding(.horizontal, short ? 12 : 14)
        .padding(.vertical, short ? 9 : 12)
        .opacity(dimmed ? 0.4 : 1)
    }

    /// The name and subtitle together. `reserve`: a block two name lines and a subtitle tall, the words at its foot,
    /// so every tile in the grid is the same height and a one-line name sits on its subtitle (the gap goes above it).
    @ViewBuilder private func words(reserve: Bool) -> some View {
        if reserve {
            ZStack(alignment: .bottomLeading) {
                lines(name: "A\nA", subtitle: "A").hidden().accessibilityHidden(true)
                lines(name: name.isEmpty ? " " : name, subtitle: subtitle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            lines(name: name.isEmpty ? " " : name, subtitle: subtitle, limit: 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func lines(name: String, subtitle: String, limit: Int = 2) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(Font.hq(.headline))
                .foregroundStyle(Color.hqLabel)
                .lineLimit(limit)
                .multilineTextAlignment(.leading)
            Text(subtitle)
                .font(Font.hq(.subheadline))
                .foregroundStyle(Color.hqLabel2)
                .lineLimit(limit <= 2 ? 1 : nil)
        }
    }
}
