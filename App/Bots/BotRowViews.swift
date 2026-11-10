// The Bots tab's cells, drawn in SwiftUI inside UIKit list cells (UIHostingConfiguration). Metrics: spec 06 §6.

import SwiftUI

/// A bot's head with its status badge (bottom-right, 2 pt outside, ringed in the page colour; spec 06 §6.1).
struct BotAvatar: View {
    @Environment(\.hqBadgeRing) private var ring
    var bot: Bot
    var size: CGFloat
    /// [botslist] A pinned tile has no second line: its standing problem (an orange dot) and "Waking up…" (a small
    /// spinner) show in the badge's place instead (docs/spec/3x-botslist.md §8, §9).
    var tile = false
    /// The working arc round the face: a pinned tile only (a row rings the whole row).
    var faceArc = false
    /// The unread dot on the face's corner (rows and pinned tiles; not Bot Info's header).
    var presence = true

    var body: some View {
        // [perf] The face's ring shape (a head resolve and a photo lookup) only when the ring is drawn: a row never is.
        let arc = faceArc && BotList.showsArc(bot)
        HeadImage(raw: bot.head, profile: bot.id, size: size, working: bot.isWorking, moods: true)
            .workingArc(arc, shape: arc ? WorkingArc.faceShape(raw: bot.head, profile: bot.id, size: size) : .circle,
                        lineWidth: WorkingArc.faceLine, outset: WorkingArc.faceOutset)
            .overlay(alignment: .bottomTrailing) {
                let status = tile ? BotList.rowStatus(bot) : .idle
                if status == .attention {
                    AttentionBadge(height: Self.badgeSize(size)).offset(x: 2, y: 2)
                } else if status == .waking {
                    ProgressView().controlSize(.small)
                        .frame(width: Self.badgeSize(size), height: Self.badgeSize(size))
                        .background(Circle().fill(ring ?? Color.hqPage).padding(-2))
                        .offset(x: 2, y: 2)
                        .accessibilityHidden(true)
                } else {
                    // [presence] The display for "Using its computer", the dots for a running turn or browser use.
                    switch BotList.rowBadge(bot) {
                    case .working: WorkingBadge(height: Self.badgeSize(size)).offset(x: 2, y: 2)
                    case .computer: ComputerBadge(height: Self.badgeSize(size)).offset(x: 2, y: 2)
                    case nil:
                        if presence, bot.unread { PresenceDot(height: Self.presenceSize(size)).offset(x: 1, y: 1) }
                    }
                }
            }
    }

    /// `clamp(14, 0.36 × head, 22)`: 20 pt on a 56 pt head.
    static func badgeSize(_ size: CGFloat) -> CGFloat { (min(22, max(14, size * 0.36))).rounded() }

    /// `clamp(8, 0.24 × head, 16)`: 12 pt on a 50 pt head.
    static func presenceSize(_ size: CGFloat) -> CGFloat { (min(16, max(8, size * 0.24))).rounded() }
}

/// [heads] Unread: a small round dot on the face's corner (the dot-matrix head's presence badge), white on a dark
/// page and black on a light one, with the other badges' 2 pt page-colour ring. The row's unread circle stays.
struct PresenceDot: View {
    var height: CGFloat
    @Environment(\.hqBadgeRing) private var ring
    var body: some View {
        Circle()
            .fill(Color.hqLabel)
            .frame(width: height, height: height)
            .background(Circle().fill(ring ?? Color.hqPage).padding(-2))
            .accessibilityHidden(true)
    }
}

/// Working: a tint circle with three white dots and a 2 pt page-colour ring (`bot-avatar.css`; spec 06 §6.1: 20 pt on
/// a 56 pt head, not the 32 pt capsule round 2 found). The dots brighten in turn, as the chat's typing dots do (0.2 s
/// apart, every 1.2 s, on the same clock); they stood still, so a working bot read as stuck (owner, 2026-10-28; the web
/// pulses them, `bot-avatar.css:17`). Still under Reduce Motion: typing dots aren't decoration.
struct WorkingBadge: View {
    var height: CGFloat
    @Environment(\.hqBadgeRing) private var ring
    var body: some View {
        if HQMotion.reduced {
            dots { _ in 1 }
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let now = context.date.timeIntervalSinceReferenceDate
                dots { index in Self.wave(now - Double(index) * 0.2) }
            }
        }
    }

    /// The chat's typing wave (`ChatWaitingCell.animate`): 30 % → 100 % over the first quarter, back by half, then rest.
    static func wave(_ time: TimeInterval) -> Double {
        let t = (time.truncatingRemainder(dividingBy: 1.2) + 1.2).truncatingRemainder(dividingBy: 1.2) / 1.2
        guard t < 0.5 else { return 0.3 }
        let half = t < 0.25 ? t / 0.25 : 1 - (t - 0.25) / 0.25
        return 0.3 + 0.7 * (0.5 - cos(half * .pi) / 2)
    }

    private func dots(_ opacity: @escaping (Int) -> Double) -> some View {
        let dot = max(2, (height * 0.15).rounded())
        return HStack(spacing: max(1, (height * 0.1).rounded())) {
            ForEach(0..<3, id: \.self) { index in Circle().fill(Color.hqOnTint).frame(width: dot, height: dot).opacity(opacity(index)) }
        }
        .frame(width: height, height: height)
        .background(Circle().fill(Color.hqTint))
        .background(Circle().fill(ring ?? Color.hqPage).padding(-2))
        .accessibilityHidden(true)
    }
}

/// [botslist] A standing problem on a pinned tile: an orange circle with the working badge's 2 pt page-colour ring.
struct AttentionBadge: View {
    var height: CGFloat
    @Environment(\.hqBadgeRing) private var ring
    var body: some View {
        Image(systemName: "exclamationmark")
            .font(Font.hqSystem(size: height * 0.55, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: height, height: height)
            .background(Circle().fill(Color.hqOrange))
            .background(Circle().fill(ring ?? Color.hqPage).padding(-2))
            .accessibilityHidden(true)
    }
}

/// [presence] Using its computer: a tint circle with a white display and the working badge's 2 pt page-colour ring
/// (R:src/ui-kit/bot-avatar.tsx:14-29; spec 3x-presence §4.2).
struct ComputerBadge: View {
    var height: CGFloat
    @Environment(\.hqBadgeRing) private var ring
    var body: some View {
        Image(systemName: "display")
            .font(Font.hqSystem(size: height * 0.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: height, height: height)
            .background(Circle().fill(Color.hqTint))
            .background(Circle().fill(ring ?? Color.hqPage).padding(-2))
            .accessibilityHidden(true)
    }
}

private struct BadgeRingKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    /// What a face's badges (the unread dot, working dots, attention, computer) are ringed in: the page by default
    /// (nil). [mac] Mac polish #55: the Mac's sidebar gives its panel's, where a page-white ring showed on the iOS look's
    /// grey panel as a halo round every unread dot.
    var hqBadgeRing: Color? {
        get { self[BadgeRingKey.self] }
        set { self[BadgeRingKey.self] = newValue }
    }
}

/// The row's ⋯ menu actions (M1: open and mark read; the rest needs gateway writes that come later).
struct BotRowActions {
    var open: () -> Void
    var markRead: () -> Void
    /// [a11y] Named actions on the row (a pinned bot's Move Earlier / Move Later at accessibility sizes).
    var moves: [BotAccessibilityAction] = []
}

/// [a11y] A named accessibility action: what a drag does, for VoiceOver and Switch Control.
struct BotAccessibilityAction {
    var name: String
    var run: () -> Void
}

extension View {
    func botAccessibilityActions(_ actions: [BotAccessibilityAction]) -> some View {
        accessibilityActions {
            ForEach(actions.indices, id: \.self) { index in
                Button(actions[index].name, action: actions[index].run)
            }
        }
    }
}

/// The iOS bot row's geometry (owner 2026-10-16: a touch more compact; was 56 pt faces, 14 pt padding, 88 pt rows).
enum BotRowMetrics {
    static var face: CGFloat { Density.ios(50, 34) }
    static var gap: CGFloat { Density.ios(12, 10) }
    static let leading: CGFloat = 20
    static var padV: CGFloat { Density.ios(10, 6) }
    static var minHeight: CGFloat { Density.ios(74, 50) }
    /// Where the separator starts: under the text.
    static var textLeading: CGFloat { leading + face + gap }
}

/// One bot row: 50 pt head, name + time, two-line preview, unread circle at the trailing edge. [botsminimal] No ⋯: a
/// long press holds the row's menu (owner, 2026-10-27).
struct BotRowView: View {
    var bot: Bot
    var time: String
    var actions: BotRowActions
    /// Muted on this iPhone: a bell.slash beside the pin (parity §3).
    var muted = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var previewLine: CGFloat = 20
    @ScaledMetric(relativeTo: .footnote) private var glyph: CGFloat = 13

    private var large: Bool { typeSize.isAccessibilitySize }
    /// The live mute, so VoiceOver reads a timed one's end ("Muted until 6:30 PM").
    private var muteForVoiceOver: BotMute? { muted ? BotMuteCenter.shared.mute(of: bot.id) : nil }

    var body: some View {
        if Theme.isDesktop && !large { desktopBody } else { iosBody }   // [desktoplook2]
    }

    /// [desktoplook2] The desktop roster's row (phone-ui-desktop.css:193-203, 272-276): a 32 pt face, the name and its
    /// time on one line, one line of preview, 60 pt tall. No separators (the list hides them in the look); the press is
    /// the list's inset box. At the accessibility sizes the iOS row is kept (it grows).
    private var desktopBody: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(alignment: .center, spacing: DesktopRows.gap) {
                BotAvatar(bot: bot, size: DesktopRows.face)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(bot.name)
                                .font(Font.hq(.callout).weight(.semibold))
                                .foregroundStyle(Color.hqLabel)
                                .lineLimit(1)
                            if bot.hidden {
                                Image(systemName: "eye.slash").font(Font.hq(.caption2)).foregroundStyle(Color.hqLabel2)
                            }
                        }
                        Spacer(minLength: 0)
                        Text(time)
                            .font(Font.hq(.caption2))
                            .monospacedDigit()
                            .foregroundStyle(BotList.showsUnread(bot) ? Color.hqTintText : Color.hqLabel2)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    let line = BotList.secondLine(bot)
                    HStack(alignment: .center, spacing: 5) {
                        previewText(line)
                            .font(Font.hq(.footnote))
                            .foregroundStyle(line.tone == .tint ? Color.hqTintText : line.tone == .attention ? Color.hqOrange : Color.hqLabel2)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if muted { Image(systemName: "bell.slash.fill").font(Font.hq(.caption2)).foregroundStyle(Color.hqLabel2).accessibilityHidden(true) }
                        if bot.pinned { Image(systemName: "pin.fill").font(Font.hq(.caption2)).foregroundStyle(Color.hqLabel2) }
                        if BotList.showsUnread(bot) { Circle().fill(muted ? Color.hqLabel3 : Color.hqTint).frame(width: 8, height: 8) }
                    }
                }
            }
            .padding(.horizontal, DesktopRows.gutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(BotList.accessibilityLabel(bot, time: time, muted: muted, mute: muteForVoiceOver))
            .accessibilityAddTraits(.isButton)
            .botAccessibilityActions(actions.moves)
        }
        .frame(height: DesktopRows.height)
        .rowArc(BotList.showsArc(bot))
    }

    private var iosBody: some View {
        HStack(alignment: large ? .top : .center, spacing: 0) {
            HStack(alignment: large ? .top : .center, spacing: BotRowMetrics.gap) {
                BotAvatar(bot: bot, size: BotRowMetrics.face)
                    .padding(.top, large ? 4 : 0)
                VStack(alignment: .leading, spacing: Density.compact ? 1 : 4) {
                    topLine
                    bottomLine
                    // [a11y] At accessibility sizes the pin, bell and unread dot sit on the time's line, so the
                    // preview keeps the row's whole width (stress round 1: it was squeezed into a narrow column).
                    if large {
                        HStack(alignment: .center, spacing: 8) {
                            timeText
                            Spacer(minLength: 0)
                            marks(topPadded: false)
                        }
                    }
                }
                .frame(minHeight: Density.ios(52, 34))
            }
            .padding(.vertical, BotRowMetrics.padV)
            .padding(.horizontal, BotRowMetrics.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(BotList.accessibilityLabel(bot, time: time, muted: muted, mute: muteForVoiceOver))
            .accessibilityAddTraits(.isButton)
            .botAccessibilityActions(actions.moves)
        }
        .frame(minHeight: large ? 0 : BotRowMetrics.minHeight)
        .rowArc(BotList.showsArc(bot))
    }

    private var topLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(bot.name)
                    .font(Font.hq(Density.compact ? .callout : .body).weight(.semibold))
                    .foregroundStyle(Color.hqLabel)
                    .lineLimit(large ? nil : 1)
                if bot.hidden {
                    Image(systemName: "eye.slash")
                        .font(Font.hqSystem(size: min(glyph, 26)))
                        .foregroundStyle(Color.hqLabel2)
                }
            }
            Spacer(minLength: 0)
            if !large { timeText }
        }
    }

    private var timeText: some View {
        Text(time)
            .font(Font.hq(.caption))
            .monospacedDigit()
            .foregroundStyle(BotList.showsUnread(bot) ? Color.hqTintText : Color.hqLabel2)
            .lineLimit(1)
            .fixedSize()
    }

    /// The preview with its lead ("Draft:", "From Inbox:") in the label colour (spec 02 §6.4 item 4; verify round 3).
    private func previewText(_ line: (text: String, tone: BotList.Tone)) -> Text {
        guard line.tone == .secondary, !bot.waking, let prefix = bot.previewPrefix, line.text.hasPrefix(prefix + " ") else { return Text(line.text) }
        let rest = String(line.text.dropFirst(prefix.count))
        // [botslist] "Not Delivered:" is red and semibold, as the Sessions row draws it (parity §3 L189).
        if prefix == RosterPreview.notDeliveredPrefix {
            return Text("\(Text(prefix).fontWeight(.semibold).foregroundStyle(Color.hqRed))\(rest)")
        }
        return Text("\(Text(prefix).foregroundStyle(Color.hqLabel))\(rest)")
    }

    private var bottomLine: some View {
        let line = BotList.secondLine(bot)
        return HStack(alignment: .top, spacing: 6) {
            // [botslist] "Waking up…" has a small spinner before the words (`bot-row.tsx:198`).
            if BotList.rowStatus(bot) == .waking {
                ProgressView().controlSize(.mini).frame(height: previewLine).accessibilityHidden(true)
            }
            previewText(line)
                .font(Font.hq(Density.compact ? .footnote : .subheadline))
                .foregroundStyle(line.tone == .tint ? Color.hqTint : line.tone == .attention ? Color.hqOrange : Color.hqLabel2)
                // [mac] Stress test 2026-10-28: one line in both looks. [toolnow] A step's line too: the row keeps its
                // height as the steps change.
                .lineLimit(large ? 3 : DeviceWord.isMac || Density.compact || (bot.step != nil && BotList.rowStatus(bot) == .working) ? 1 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !large { marks(topPadded: true) }
        }
    }

    /// The bell (muted here), the pin and the unread dot (grey when muted, as a muted group chat's).
    @ViewBuilder private func marks(topPadded: Bool) -> some View {
        if muted {
            Image(systemName: "bell.slash.fill")
                .font(Font.hqSystem(size: min(glyph, 26) * 0.9))
                .foregroundStyle(Color.hqLabel2)
                .padding(.top, topPadded ? max(0, (previewLine - min(glyph, 26)) / 2) : 0)
                .accessibilityHidden(true)
        }
        if bot.pinned {
            Image(systemName: "pin.fill")
                .font(Font.hqSystem(size: min(glyph, 26) * 0.9))
                .foregroundStyle(Color.hqLabel2)
                .padding(.top, topPadded ? max(0, (previewLine - min(glyph, 26)) / 2) : 0)
        }
        if BotList.showsUnread(bot) {
            let dot = Density.ios(16, 10)   // [density] the one-line preview's size in Compact
            Circle()
                .fill(muted ? Color.hqLabel3 : Color.hqTint)
                .frame(width: dot, height: dot)
                .padding(.top, topPadded ? max(0, (previewLine - dot) / 2) : 0)
        }
    }
}

/// A pinned tile: 60 pt head over the name (Footnote medium, two lines), 10 pt unread circle beside the name.
/// A press dims the head to 72 % (not a row rectangle).
struct PinnedTileView: View {
    var bot: Bot
    var press: TilePress
    var muted = false
    /// [a11y] Move Earlier / Move Later: the tile drag's path for VoiceOver and Switch Control.
    var moves: [BotAccessibilityAction] = []
    /// [compact] 60 pt (was 72): the pinned row was the tallest thing on the Bots tab (owner 2026-10-17: too big).
    static var face: CGFloat { Density.ios(60, 44) }
    static let gap: CGFloat = 6

    var body: some View {
        VStack(spacing: Theme.isDesktop ? 8 : Self.gap) {
            // Unread shows once, as the circle beside the name: the face's corner dot made it two (owner, 2026-10-28).
            BotAvatar(bot: bot, size: Theme.isDesktop ? HQFont.scaled(48) : Self.face, tile: true, faceArc: true, presence: false)
                .modifier(TileHalo(press: press, shape: WorkingArc.faceShape(raw: bot.head, profile: bot.id,
                                                       size: Theme.isDesktop ? HQFont.scaled(48) : Self.face)))
            HStack(alignment: .top, spacing: 4) {
                Text(bot.name)
                    .font(Font.hq(.footnote).weight(.medium))
                    .foregroundStyle(Color.hqLabel)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if muted {
                    Image(systemName: "bell.slash.fill")
                        .font(Font.hq(.caption2))
                        .foregroundStyle(Color.hqLabel2)
                        .padding(.top, 2)
                        .accessibilityHidden(true)
                }
                if BotList.showsUnread(bot) {
                    Circle().fill(muted ? Color.hqLabel3 : Color.hqTint).frame(width: 10, height: 10).padding(.top, 4)
                }
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BotList.accessibilityLabel(bot, time: "", muted: muted, mute: muted ? BotMuteCenter.shared.mute(of: bot.id) : nil))
        .accessibilityAddTraits(.isButton)
        .botAccessibilityActions(moves)
    }
}

/// [perf] A tile's pressed state, flipped by its cell's `configurationUpdateHandler`, so a press dims the face without
/// building the tile's hosting content again. One per registration pass: a reused cell starts from its own state.
@Observable final class TilePress {
    private(set) var pressed: Bool
    /// [mac] Stress test 2026-10-28 #6: the tile of the chat open beside the list (two panes). Dimmed like a press it
    /// read as an offline bot (and a dot-matrix head barely changed), so it gets a mark of its own (`TileHalo`).
    private(set) var marked = false
    /// [mac] The pointer is over the tile (`MacHover.ownsHover`): the halo, never the rows' square fill.
    private(set) var hovered = false

    init(_ state: UICellConfigurationState, marks: Bool = false) {
        pressed = state.isHighlighted || (state.isSelected && !marks)
        marked = marks && state.isSelected && !state.isHighlighted
    }

    /// `marks`: the list keeps the open chat's row selected (two panes); a selection is then a mark, not a press.
    func update(_ state: UICellConfigurationState, marks: Bool = false) {
        let now = state.isHighlighted || (state.isSelected && !marks)
        if now != pressed { pressed = now }
        let mark = marks && state.isSelected && !state.isHighlighted
        if mark != marked { marked = mark }
        #if targetEnvironment(macCatalyst)
        let accent = MacSelection.focus == .list
        if accent != focused { focused = accent }
        #endif
    }

    func hover(_ on: Bool) { if on != hovered { hovered = on } }

    #if targetEnvironment(macCatalyst)
    /// [mac] Stress test 2026-10-28 #54: the list has the focus, so the mark is the accent (`MacSelection`).
    private(set) var focused = MacSelection.focus == .list
    #endif
}

/// The tile's face answers for the whole tile (owner 2026-10-28: "only the bot itself" shows hover and press, no square
/// behind the tile): a soft round halo the shape of the head, 5 pt round it. On the Mac hover, press and "this bot's
/// chat is open" are all that halo: faint under the pointer, the selection grey on a press, and the rows' mark (the
/// accent while the list has the focus, grey otherwise) for the open chat. On the iPhone and iPad a press still dims
/// the face to 72 %, and the open chat (iPad, two panes) gets the halo in the rows' pressed grey.
/// Its own view, so only it reads `press` and runs again when it flips.
struct TileHalo: ViewModifier {
    var press: TilePress
    /// [mac] Stress test 2026-10-28 round 2: the face's own edge: a tile's rounded square gets a rounded ring, every other
    /// head (round, dot-matrix, shaped) a round one.
    var shape: WorkingArc.Shape = .circle
    /// [mac] Stress test 2026-10-28 round 6: 2 pt further out on the Mac, where the ring is the open chat's mark. On a
    /// dot-matrix face (Inbox) the ring sat about 1 pt from the outer dots; now about 3.
    static let spread: CGFloat = DeviceWord.isMac ? 7 : 5
    /// The ring's width: wide enough to read as the mark, outside the face so nothing fills behind it.
    static let ring: CGFloat = 2.5

    func body(content: Content) -> some View {
        content
            .opacity(dims ? 0.72 : 1)
            // [mac] Stress test 2026-10-28 round 2: a ring round the face, not a disc behind it: the disc filled the gaps of
            // a dot-matrix head and showed through it as a coloured face.
            .overlay {
                GeometryReader { box in
                    ringShape(side: max(box.size.width, box.size.height) + Self.spread * 2)
                        .padding(-Self.spread)
                }
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            }
            .animation(.easeOut(duration: 0.18), value: press.pressed)   // motion-ok: opacity and colour only
            .animation(.easeOut(duration: 0.06), value: press.hovered)   // motion-ok: colour only
    }

    @ViewBuilder private func ringShape(side: CGFloat) -> some View {
        let color = halo.map { Color(uiColor: $0) } ?? Color.clear
        if case .rounded = shape {
            RoundedRectangle(cornerRadius: side * BotFaces.cornerShare, style: .continuous).strokeBorder(color, lineWidth: Self.ring)
        } else {
            Circle().strokeBorder(color, lineWidth: Self.ring)
        }
    }

    private var dims: Bool {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        return press.pressed
        #endif
    }

    private var halo: UIColor? {
        #if targetEnvironment(macCatalyst)
        // A thin ring needs more colour than the disc had: the accent itself while its pane has the focus.
        if press.marked { return press.focused ? HQPalette.tint : HQPalette.label3 }
        if press.pressed { return HQPalette.label3 }
        return press.hovered ? MacHover.buttonFill : nil
        #else
        return press.marked ? HQPalette.cellPressed : nil
        #endif
    }
}

/// A section header: the name in Subheadline semibold label-2 (the Desktop Look's tracked capitals), and at the trailing
/// edge a caret, down while the section is open and right while it's folded. [botscaret] A folded section shows its
/// count just before the caret; an open one drops it. Both sit softer than the name (owner, 2026-10-27; reverses the
/// [botsminimal] no-chevron call and its fade of a folded name). A tap anywhere on the header still folds it.
struct BotSectionHeaderView: View {
    /// [botsminimal] One of the hold menu's items, offered to VoiceOver as an action.
    struct Action {
        var name: String
        var run: () -> Void
    }

    var title: String
    var count: Int
    var collapsed: Bool
    /// [groups] What the count counts, for VoiceOver ("Group Chats, 2 group chats").
    var unit: (one: String, many: String) = ("bot", "bots")
    /// [botsminimal] A user section's menu items (Rename…, Move Up, Move Down, Delete Section).
    var actions: [Action] = []
    @Environment(\.dynamicTypeSize) private var typeSize   // [groups]

    /// [botscaret] The count and caret: label-3, faded further so they fall behind the name and the rows.
    private static let softOpacity = 0.6

    var body: some View {
        if Theme.isDesktop { desktopBody } else { iosBody }   // [desktoplook2]
    }

    /// [desktoplook2] The desktop's section label (WORK): tracked capitals, 36 pt, 10 pt above
    /// (phone-ui-desktop.css:277-281).
    private var desktopBody: some View {
        HStack(spacing: 8) {
            Text(title)
                .hqDesktopLabel()
                .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
            Spacer(minLength: 0)
            trailing(font: Font.hqSystem(size: DesktopRows.labelSize * HQFont.dynamicRatio(nil)))
        }
        .padding(.horizontal, DesktopRows.gutter)
        .frame(minHeight: 36)
        .padding(.top, 10)
        .contentShape(Rectangle())
        .modifier(SectionHeaderAccessibility(label: spokenLabel, collapsed: collapsed, actions: actions))
    }

    private var spokenLabel: String { "\(title), \(count) \(count == 1 ? unit.one : unit.many)" }

    private var iosBody: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Font.hq(.subheadline).weight(.semibold))
                .foregroundStyle(Color.hqLabel2)
                .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
            Spacer(minLength: 0)
            trailing(font: Font.hq(.subheadline))
        }
        .padding(.leading, 20)
        .padding(.trailing, 20)
        .frame(minHeight: Density.ios(44, 34))   // [density]
        .padding(.top, Density.compact ? 4 : 8)
        .contentShape(Rectangle())
        .modifier(SectionHeaderAccessibility(label: spokenLabel, collapsed: collapsed, actions: actions))
    }

    /// [botscaret] "4 ›" while folded, "⌄" while open: one chevron that turns, the count fading in beside it.
    private func trailing(font: Font) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if collapsed {
                Text("\(count)")
                    .font(font)
                    .monospacedDigit()
                    .fixedSize()   // [groups] the count keeps its width at the largest text sizes
                    .transition(.opacity)
            }
            Image(systemName: "chevron.right")
                .font(font.weight(.semibold))
                .imageScale(.small)
                .rotationEffect(.degrees(collapsed ? 0 : 90))
        }
        .foregroundStyle(Color.hqLabel3)
        .opacity(Self.softOpacity)
        .animation(HQMotion.swiftUI(.easeInOut(duration: 0.2)), value: collapsed)
        .accessibilityHidden(true)
    }
}

/// One VoiceOver element for a section header: a button that folds it, with the hold menu's items as actions.
private struct SectionHeaderAccessibility: ViewModifier {
    var label: String
    var collapsed: Bool
    var actions: [BotSectionHeaderView.Action]

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(.isHeader)
            .accessibilityActions {
                ForEach(actions.indices, id: \.self) { index in
                    Button(actions[index].name, action: actions[index].run)
                }
            }
    }
}

/// Cold-load placeholder at the rows' own metrics: a 50 pt circle (a drawn head's shape) and two lines at 40 % and 78 %
/// width.
struct BotSkeletonRowView: View {
    @State private var dim = false

    /// [settings] The decorative pulse: off under Reduce Motion and while the phone saves power.
    private func pulse() {
        if HQMotion.decorativeStill {
            var still = Transaction(); still.disablesAnimations = true
            withTransaction(still) { dim = false }
        } else if !dim {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { dim = true }   // motion-ok: decorativeStill above
        }
    }
    var body: some View {
        // [ui-sizing 2026-11-09] The real row's gap and padding (12/10, Compact 10/6): at 14/14 the placeholders stood
        // 4-12 pt taller than the rows that replaced them, so the list jumped as it loaded.
        HStack(spacing: BotRowMetrics.gap) {
            Circle().fill(Color.hqFill3).frame(width: BotRowMetrics.face, height: BotRowMetrics.face)
            GeometryReader { geo in
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 6).fill(Color.hqFill3).frame(width: geo.size.width * 0.4, height: 15)
                    RoundedRectangle(cornerRadius: 6).fill(Color.hqFill3).frame(width: geo.size.width * 0.78, height: 12)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(height: BotRowMetrics.face)
        .padding(.vertical, BotRowMetrics.padV)
        .padding(.horizontal, BotRowMetrics.leading)
        .frame(minHeight: BotRowMetrics.minHeight)
        .opacity(dim ? 0.45 : 1)
        .onAppear { pulse() }
        // [settings] Saving power stops the pulse; it starts again when saving ends (3x-settings §3).
        .onReceive(NotificationCenter.default.publisher(for: PowerState.changed)) { _ in pulse() }
        .accessibilityHidden(true)
    }
}
