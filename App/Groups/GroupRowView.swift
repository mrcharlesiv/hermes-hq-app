// [groups] A room in the Bots list (docs/spec/3x-groups.md §7.1): the group avatar, the name and time, the second
// line, and the same ⋯ button, marks and metrics as a bot's row (`BotRowView`); and a pinned room's tile.

import SwiftUI
import UIKit

/// Room photos decoded once (the mirror carries them as data URLs of at most 24,000 characters).
@MainActor final class GroupPhotoCache {
    static let shared = GroupPhotoCache()
    private let cache = NSCache<NSString, UIImage>()

    func image(_ dataURL: String?) -> UIImage? {
        guard let dataURL, !dataURL.isEmpty else { return nil }
        let key = dataURL as NSString
        if let known = cache.object(forKey: key) { return known }
        guard let data = GroupAvatarLayout.imageData(dataURL), let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// The group avatar in SwiftUI: the room photo, one face, or two or three faces at the web's placements.
struct GroupAvatar: View {
    var image: String?
    var faces: [GroupRowModel.Face]
    var size: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let photo = GroupPhotoCache.shared.image(image) {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else if faces.isEmpty {
                Image(systemName: "person.2.fill")
                    .font(Font.hqSystem(size: size * 0.4))
                    .foregroundStyle(Color.hqLabel3)
                    .frame(width: size, height: size)
            } else {
                let shown = Array(faces.prefix(3))
                let places = GroupAvatarLayout.placements(shown.count)
                ForEach(Array(shown.enumerated()), id: \.offset) { index, face in
                    let place = places[index]
                    HeadImage(raw: face.head, profile: face.profile, size: (size * place.scale).rounded())
                        .frame(width: (size * place.scale).rounded(), height: (size * place.scale).rounded())
                        .offset(x: (size * place.x).rounded(), y: (size * place.y).rounded())
                }
            }
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

struct GroupRowView: View {
    var room: GroupRowModel
    var time: String
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var previewLine: CGFloat = 20
    @ScaledMetric(relativeTo: .footnote) private var glyph: CGFloat = 13

    private var large: Bool { typeSize.isAccessibilitySize }
    /// [desktoplook2] The desktop roster's metrics (as `BotRowView`'s desktop row): 32 pt face, one-line preview, 60 pt.
    private var desk: Bool { Theme.isDesktop && !large }

    var body: some View {
        HStack(alignment: large ? .top : .center, spacing: 0) {
            HStack(alignment: large ? .top : .center, spacing: desk ? DesktopRows.gap : BotRowMetrics.gap) {
                // [compact] A bot row's metrics (BotRowMetrics): the face, gap, padding and height match the rows around it.
                GroupAvatar(image: room.image, faces: room.faces, size: desk ? DesktopRows.face : BotRowMetrics.face)
                    .padding(.top, large ? 4 : 0)
                VStack(alignment: .leading, spacing: desk || Density.compact ? 1 : 4) {   // [ui-sizing] Compact, as a bot row
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(room.name)
                                .font(Font.hq(desk || Density.compact ? .callout : .body).weight(.semibold))
                                .foregroundStyle(Color.hqLabel)
                                .lineLimit(large ? nil : 1)
                            // Hidden, as a hidden bot's row says (audit 05-10).
                            if room.hidden {
                                Image(systemName: "eye.slash")
                                    .font(desk ? Font.hq(.caption2) : Font.hqSystem(size: min(glyph, 26)))
                                    .foregroundStyle(Color.hqLabel2)
                            }
                        }
                        Spacer(minLength: 0)
                        if !large { timeText }
                    }
                    bottomLine
                    // [a11y] At accessibility sizes the bell, pin and unread dot sit on the time's line, as a bot row's
                    // do, so the second line keeps the row's whole width (audit 05-8).
                    if large {
                        HStack(alignment: .center, spacing: 8) {
                            timeText
                            Spacer(minLength: 0)
                            marks(topPadded: false)
                        }
                    }
                }
                .frame(minHeight: desk ? 0 : Density.ios(52, 34))
            }
            .padding(.vertical, desk ? 0 : BotRowMetrics.padV)
            .padding(.horizontal, desk ? DesktopRows.gutter : 20)   // [botsminimal] no ⋯: the time meets the edge
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(GroupRowWords.accessibilityLabel(name: room.name, line: room.line, time: time, unread: room.unread,
                                                                 pinned: room.pinned, muted: room.muted, hidden: room.hidden))
            .accessibilityAddTraits(.isButton)

        }
        .frame(minHeight: large ? 0 : desk ? DesktopRows.height : BotRowMetrics.minHeight)
        .frame(height: desk ? DesktopRows.height : nil)
    }

    private var timeText: some View {
        Text(time)
            .font(Font.hq(desk ? .caption2 : .caption))
            .monospacedDigit()
            .foregroundStyle(room.unread ? Color.hqTintText : Color.hqLabel2)
            .lineLimit(1)
            .fixedSize()
    }

    private var lineColor: Color {
        switch room.tone {
        case .tint: Color.hqTint
        case .orange: Color.hqOrange
        case .secondary: Color.hqLabel2
        }
    }

    private var bottomLine: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(room.line)
                .font(Font.hq(desk || Density.compact ? .footnote : .subheadline))
                .foregroundStyle(lineColor)
                .lineLimit(large ? 3 : desk || Density.compact ? 1 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !large { marks(topPadded: true) }
        }
    }

    /// The bell (muted here), the pin and the unread dot (grey when muted).
    @ViewBuilder private func marks(topPadded: Bool) -> some View {
        if room.muted {
            Image(systemName: "bell.slash.fill")
                .font(Font.hqSystem(size: min(glyph, 26) * 0.9))
                .foregroundStyle(Color.hqLabel2)
                .padding(.top, topPadded ? max(0, (previewLine - min(glyph, 26)) / 2) : 0)
                .accessibilityHidden(true)
        }
        if room.pinned {
            Image(systemName: "pin.fill")
                .font(Font.hqSystem(size: min(glyph, 26) * 0.9))
                .foregroundStyle(Color.hqLabel2)
                .padding(.top, topPadded ? max(0, (previewLine - min(glyph, 26)) / 2) : 0)
        }
        if room.unread {
            let dot = desk ? 8 : Density.ios(16, 10)   // [ui-sizing] a bot row's dot, Compact's too
            Circle()
                .fill(room.muted ? Color.hqLabel3 : Color.hqTint)
                .frame(width: dot, height: dot)
                .padding(.top, !topPadded ? 0 : desk ? 5 : max(0, (previewLine - dot) / 2))
        }
    }
}

/// A pinned room's tile: the group avatar (a bot tile's size) over the name, as a bot's tile.
struct GroupTileView: View {
    var room: GroupRowModel
    var press: TilePress

    var body: some View {
        VStack(spacing: Theme.isDesktop ? 8 : PinnedTileView.gap) {
            GroupAvatar(image: room.image, faces: room.faces, size: Theme.isDesktop ? HQFont.scaled(48) : PinnedTileView.face)   // [desktoplook2]
                .modifier(TileHalo(press: press))
            HStack(alignment: .top, spacing: 4) {
                Text(room.name)
                    .font(Font.hq(.footnote).weight(.medium))
                    .foregroundStyle(Color.hqLabel)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if room.muted {
                    Image(systemName: "bell.slash.fill")
                        .font(Font.hq(.caption2))
                        .foregroundStyle(Color.hqLabel2)
                        .padding(.top, 2)
                        .accessibilityHidden(true)
                }
                if room.unread {
                    Circle().fill(room.muted ? Color.hqLabel3 : Color.hqTint).frame(width: 10, height: 10).padding(.top, 4)
                }
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GroupRowWords.accessibilityLabel(name: room.name, line: room.line, time: "", unread: room.unread,
                                                             pinned: room.pinned, muted: room.muted))
        .accessibilityAddTraits(.isButton)
    }
}

/// A room sub-block's empty drop target while a room is dragged.
struct GroupSectionHintView: View {
    var body: some View {
        Text(GroupList.dropHint)
            .font(Font.hq(.footnote))
            .foregroundStyle(Color.hqLabel2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .accessibilityIdentifier("group-section-hint")
    }
}
