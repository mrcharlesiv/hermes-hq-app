// Where a chat came from, drawn: the platform's mark on a soft tint of its colour (the desktop's `PlatformAvatar`),
// and the Sessions list's Other Apps row (`OtherAppsRowView`). The page it opens is `OtherAppsViewController`.

import SwiftUI

/// A platform's mark: its brand glyph (or symbol, or letter) in its colour on a 15% tint, corners like the desktop's.
struct PlatformMark: View {
    var source: String
    var size: CGFloat = 16
    @Environment(\.colorScheme) private var scheme

    private var color: Color {
        let value = ChatSource.mark(source).color
        // Matrix's mark is black: it reads as the label colour instead (white in dark mode).
        if value == 0x000000 { return Color.hqLabel }
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(color.opacity(scheme == .dark ? 0.22 : 0.14))
            .frame(width: size, height: size)
            .overlay { glyph.foregroundStyle(color) }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var glyph: some View {
        switch ChatSource.mark(source).mark {
        case .brand(let name):
            Image("Platforms/" + name).renderingMode(.template).resizable().scaledToFit().frame(width: size * 0.62, height: size * 0.62)
        case .symbol(let name):
            Image(systemName: name).resizable().scaledToFit().fontWeight(.semibold).frame(width: size * 0.58, height: size * 0.58)
        case .letter(let letter):
            Text(letter).font(.system(size: size * 0.6, weight: .bold, design: .rounded))
        }
    }
}

/// The Sessions list's Other Apps row: the platforms' marks overlapping, "Other Apps", which platforms, and when the
/// newest of their chats was. It opens the Other Apps page (`OtherAppsViewController`). It is drawn as the chat rows
/// around it are in each look (the face's size, the fonts, the row's height), and wears their orange needs-you dot
/// while one of its chats waits on the user.
struct OtherAppsRowView: View {
    var platforms: [String]
    var total: Int
    var time: String
    var waiting = false
    @Environment(\.dynamicTypeSize) private var typeSize
    private var large: Bool { typeSize.isAccessibilitySize }
    /// [desktoplook2] As `SessionRowView`'s: the look's 32 pt face, 60 pt row and smaller type.
    private var desk: Bool { Theme.isDesktop && !large }
    private var face: CGFloat { desk ? DesktopRows.face : Density.ios(40, 32) }

    private var names: String {
        let labels = platforms.map(ChatSource.folderLabel)
        return labels.count <= 3 ? labels.joined(separator: ", ") : labels.prefix(3).joined(separator: ", ") + " and \(labels.count - 3) more"
    }

    private var count: String { total == 1 ? "1 chat" : "\(total) chats" }

    var body: some View {
        HStack(spacing: desk ? DesktopRows.gap : ProjectCard.columnGap) {
            marks
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Other Apps")
                        .font(desk ? Font.hq(.callout).weight(.semibold) : Font.hq(Density.compact ? .callout : .body))
                        .foregroundStyle(Color.hqLabel)
                        .lineLimit(large ? 3 : 1)
                    Spacer(minLength: 4)
                    Text(time).font(Font.hq(desk ? .caption2 : .subheadline)).foregroundStyle(Color.hqLabel2).monospacedDigit()
                }
                secondLine
                    .font(Font.hq(desk ? .footnote : .subheadline))
                    .lineLimit(large ? 3 : 1)
            }
            SettingsChevron()
                .frame(width: 24)
        }
        .padding(.leading, 20)
        .padding(.trailing, desk ? 16 : 14)
        .padding(.vertical, desk ? 0 : Density.ios(13, 7))
        .frame(minHeight: large ? 0 : desk ? DesktopRows.height : Density.ios(72, 50))
        .frame(height: desk ? DesktopRows.height : nil)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Other Apps. \(names). \(count). \(waiting ? "Needs your input. " : "")\(time)")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var secondLine: some View {
        if waiting {
            Text("\(Text("Needs your input").foregroundStyle(Color.hqOrange))\(Text(" · \(names) · \(count)").foregroundStyle(Color.hqLabel2))")
        } else {
            Text("\(names) · \(count)").foregroundStyle(Color.hqLabel2)
        }
    }

    /// Up to four marks, stacked in the face's square, each ringed in the page colour where they overlap.
    private var marks: some View {
        let shown = Array(platforms.prefix(4))
        let scale = face / 40
        return ZStack {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, platform in
                PlatformMark(source: platform, size: shown.count == 1 ? face : 22 * scale)
                    .background(RoundedRectangle(cornerRadius: 6 * scale, style: .continuous).fill(Color.hqPage).padding(-1.5))
                    .offset(Self.offset(index, of: shown.count, scale: scale))
            }
        }
        .frame(width: face, height: face)
        .overlay(alignment: .topTrailing) {
            if waiting {
                // The chat rows' needs-you badge (`SessionRowView.face`).
                Circle().fill(Color.hqOrange)
                    .frame(width: desk ? 10 : 17, height: desk ? 10 : 17)
                    .background(Circle().fill(Color.hqPage).padding(-2))
                    .offset(x: 3, y: -3)
            }
        }
    }

    /// Two marks on a diagonal; three in a triangle; four in a square.
    private static func offset(_ index: Int, of count: Int, scale: CGFloat) -> CGSize {
        let base: CGSize
        switch count {
        case 2: base = index == 0 ? CGSize(width: -7, height: -7) : CGSize(width: 7, height: 7)
        case 3: base = [CGSize(width: 0, height: -8), CGSize(width: -9, height: 8), CGSize(width: 9, height: 8)][index]
        case 4: base = [CGSize(width: -9, height: -9), CGSize(width: 9, height: -9), CGSize(width: -9, height: 9), CGSize(width: 9, height: 9)][index]
        default: base = .zero
        }
        return CGSize(width: base.width * scale, height: base.height * scale)
    }
}
