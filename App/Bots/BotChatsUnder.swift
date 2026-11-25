// [chats-under] Each bot's own chats, listed under its row on the Bots page (owner 2026-11-08: "the feel of the bot
// page we have with the simplicity of the sessions page"). Filter › Chats Under Bots picks what shows for every bot:
// Off (the default, so the page stays as it was), Active (working, waiting for an answer, or unread: tester
// 2026-11-08, "I create a lot of sessions so favorites won't scale well"), Pinned Only, or Pinned + Recent with 1, 2, 3
// or 5 recent chats; a bot's hold menu can set its own, and has View Sessions. "N more" opens Sessions with the bot's
// chip picked.

import SwiftUI
import UIKit

/// What a bot lists under its row.
nonisolated enum BotChatsMode: String, CaseIterable, Sendable {
    case off, active, pinned, recent

    var title: String {
        switch self {
        case .off: "Off"
        case .active: "Active"
        case .pinned: "Pinned Only"
        case .recent: "Pinned + Recent"
        }
    }

    /// The menu's second line.
    var detail: String? {
        switch self {
        case .off: "Only chats you choose to show under a bot"
        case .active: "Working, waiting for you, or unread"
        case .pinned: "Chats you pin"
        default: nil
        }
    }
}

/// A mode and, for Pinned + Recent, how many recent chats.
nonisolated struct BotChatsChoice: Hashable, Sendable {
    var mode: BotChatsMode
    var count: Int

    static let counts = [1, 2, 3, 5]
    static let standard = BotChatsChoice(mode: .recent, count: 2)
    /// Until it's chosen: off, so nobody's page changes on its own.
    static let initial = BotChatsChoice(mode: .off, count: 2)

    /// The Filter menu's subtitle: "Off", "Pinned only", "Pinned + 2 recent".
    var summary: String {
        switch mode {
        case .off: "Off"
        case .active: "Active chats"
        case .pinned: "Pinned only"
        case .recent: "Pinned + \(count) recent"
        }
    }

    /// Stored as "off", "pinned" or "recent:2".
    var stored: String { mode == .recent ? "recent:\(count)" : mode.rawValue }

    init(mode: BotChatsMode, count: Int) {
        self.mode = mode
        self.count = Self.counts.contains(count) ? count : Self.standard.count
    }

    init?(stored: String) {
        let parts = stored.split(separator: ":", maxSplits: 1).map(String.init)
        guard let mode = parts.first.flatMap(BotChatsMode.init(rawValue:)) else { return nil }
        self.init(mode: mode, count: parts.count > 1 ? Int(parts[1]) ?? Self.standard.count : Self.standard.count)
    }
}

/// The choices, kept on this device: one for every bot, and any bot's own.
@MainActor enum BotChatsPrefs {
    static let key = "hq.bots.chatsUnder"
    static let botsKey = "hq.bots.chatsUnder.bots"
    /// [mac] Posted when a choice changes: the Mac's sidebar, which lists the bots there, draws their chats again.
    static let changed = Notification.Name("BotChatsPrefs.changed")

    static var all: BotChatsChoice {
        get { UserDefaults.standard.string(forKey: key).flatMap(BotChatsChoice.init(stored:)) ?? .initial }
        set {
            UserDefaults.standard.set(newValue.stored, forKey: key)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Any bot lists chats: all bots' choice, or one bot's own.
    static var inUse: Bool {
        all.mode != .off || (UserDefaults.standard.dictionary(forKey: botsKey)?.values.contains { ($0 as? String) != BotChatsMode.off.rawValue } ?? false)
    }

    /// A bot's own choice; nil follows `all`.
    static func own(_ bot: String) -> BotChatsChoice? {
        (UserDefaults.standard.dictionary(forKey: botsKey)?[bot] as? String).flatMap(BotChatsChoice.init(stored:))
    }

    static func setOwn(_ choice: BotChatsChoice?, for bot: String) {
        var stored = UserDefaults.standard.dictionary(forKey: botsKey) as? [String: String] ?? [:]
        stored[bot] = choice?.stored
        UserDefaults.standard.set(stored, forKey: botsKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func choice(for bot: String) -> BotChatsChoice { own(bot) ?? all }
}

/// Which chats a bot lists, and how many it leaves for Sessions.
nonisolated enum BotChatsUnder {
    /// Pinned (or active) chats shown at most, so one bot doesn't take the page.
    static let maxPinned = 5

    /// Only another chat under this bot calls for a pin icon; the “N more” link isn't a chat.
    static func showsPin(for session: SessionSummary, among shown: [SessionSummary]) -> Bool {
        session.pinned && shown.count > 1
    }

    /// Working, waiting for an answer, or unread.
    static func isActive(_ session: SessionSummary) -> Bool {
        session.isRunning || session.unread || session.status == .needsInput || session.status == .working
    }

    /// `sessions` is the Sessions list's recents (pinned first, then newest first): the bot's pinned chats (up to
    /// `maxPinned`), then for Pinned + Recent its newest others, `count` of them. `more`: its chats not shown.
    static func pick(_ sessions: [SessionSummary], bot: String, choice: BotChatsChoice,
                     shortcuts: [SessionSummary] = []) -> (shown: [SessionSummary], more: Int) {
        // `sessions` honours Keep Chats in This Project; `shortcuts` is the separate, hand-picked exception.
        var chosen = Set<String>()
        let manual = shortcuts.filter { $0.profile == bot && !$0.archived && chosen.insert($0.id).inserted }
        guard choice.mode != .off else { return (manual, 0) }
        let own = sessions.filter { $0.profile == bot && !$0.archived && !chosen.contains($0.id) }
        if choice.mode == .active {
            // Waiting for you first, then working, then unread; newest first within each.
            let active = own.filter(isActive).sorted {
                let a = rank($0), b = rank($1)
                return a != b ? a < b : ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast)
            }
            let shown = Array(active.prefix(maxPinned))
            return (manual + shown, own.count - shown.count)
        }
        let pinned = own.filter(\.pinned).prefix(maxPinned)
        var shown = Array(pinned)
        if choice.mode == .recent {
            let recent = own.filter { !$0.pinned }
                .sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
            shown += recent.prefix(choice.count)
        }
        return (manual + shown, own.count - shown.count)
    }

    /// One menu action shared by Sessions (including a project's page), the Bots list and the open Mac sidebar.
    @MainActor static func shortcutNode(_ session: SessionSummary, services: any AppServices) -> BotMenuNode? {
        guard let store = (services as? SessionsServices)?.sessionStore else { return nil }
        let shown = store.hasBotShortcut(session)
        let bot = services.bots.first { $0.id == session.profile }
        guard shown || (bot?.hidden != true && store.canAddBotShortcut(session)) else { return nil }
        let name = bot?.name ?? store.ownerName(for: session)
        var node = BotMenuNode.action(shown ? "Remove Shortcut Under \(name)" : "Show Under \(name)",
                                      shown ? "minus.circle" : "arrow.turn.down.right") { [weak store] in
            Haptics.play(.selection)
            store?.setBotShortcut(session, !shown)
        }
        node.identifier = "sessions.row.botShortcut"
        return node
    }

    private static func rank(_ session: SessionSummary) -> Int {
        session.status == .needsInput ? 0 : session.isRunning || session.status == .working ? 1 : 2
    }
}

/// Where the line and the titles sit, under the bot row's face (both looks).
enum BotChatsMetrics {
    static var leading: CGFloat { Theme.isDesktop ? DesktopRows.gutter : BotRowMetrics.leading }
    static var lineX: CGFloat {
        Theme.isDesktop ? DesktopRows.gutter + DesktopRows.face / 2 : BotRowMetrics.leading + BotRowMetrics.face / 2
    }
    static var textX: CGFloat { lineX + 19 }
    static var rowHeight: CGFloat { Theme.isDesktop ? 34 : Density.ios(34, 28) }
    /// Under the last row, before the next bot.
    static let tail: CGFloat = 6

    /// The hover, press and selection box for a chat row (or "N more"): starts beside the title column so the
    /// connector line stays whole outside it (as `MacSidebarChat` does), and stops above the last row's `tail` so the
    /// text and branch arm sit centred in the box.
    static func highlightInsets(last: Bool) -> NSDirectionalEdgeInsets {
        var inset = DesktopRows.pressInset
        inset.leading = max(inset.leading, textX - 6)
        if last { inset.bottom += tail }
        return inset
    }
}

/// How the connector down a bot's chats looks: curved elbows (the default), swept arrows, spline fan, tapered quill,
/// metro track, soft rail with return arrows, a plain line, dividers, or nothing. Settings › Appearance › Chats Under
/// Bots, kept on this device.
nonisolated enum BotChatsStyle: String, CaseIterable, Sendable {
    case branch, arrows, splines, quill, dots, rail, line, dividers, none

    static let key = "hq.bots.chatsUnder.style"
    /// Posted when the style changes: the Bots list redraws its chats.
    static let changed = Notification.Name("BotChatsStyle.changed")
    static var saved: BotChatsStyle {
        get { UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .branch }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    var title: String {
        switch self {
        case .branch: "Curved Elbows"
        case .arrows: "Swept Arrows"
        case .splines: "Spline Fan"
        case .quill: "Tapered Quill"
        case .dots: "Metro Track"
        case .rail: "Soft Rail"
        case .line: "Line"
        case .dividers: "Dividers"
        case .none: "No Line"
        }
    }

    /// The menu's picture for it.
    var symbol: String {
        switch self {
        case .branch: "arrow.turn.down.right"
        case .arrows: "arrow.uturn.right"
        case .splines: "point.topleft.down.to.point.bottomright.curvepath"
        case .quill: "pencil.tip"
        case .dots: "circle.dotted"
        case .rail: "sidebar.leading"
        case .line: "line.3.horizontal"
        case .dividers: "rectangle.split.1x2"
        case .none: "minus"
        }
    }

    /// The line ends at the last row's mark instead of short of its foot.
    var marksRows: Bool {
        switch self {
        case .branch, .arrows, .splines, .quill, .dots, .rail: true
        case .line, .dividers, .none: false
        }
    }
}

/// The connector down a bot's chats, in the bot's own colour, drawn in the chosen style with unified-opacity vector
/// geometry (no overlapping corner dark spots) and a soft top fade on the first row beneath the bot's face.
/// [mac] The Mac's sidebar draws it under its bot rows too (`MacSidebarChat`).
struct BotChatsLine: View {
    enum NodeStatus: Hashable, Sendable {
        case quiet, unread, waiting, working
    }

    var first = false
    var last: Bool
    var tint: Color
    var lineX: CGFloat
    /// Horizontal reach from `lineX` to the connector tip. Defaults to `Self.branch` (clears `highlightInsets`).
    var reach: CGFloat = BotChatsLine.branch
    var style: BotChatsStyle
    /// "N more" gets a gentle tail or curved hook rather than an arrowhead or status node.
    var more = false
    /// Session state for status-aware styles (`splines`, `dots`, `rail`).
    var status: NodeStatus = .quiet
    /// Hovered or selected row brightens its own connector.
    var emphasized = false

    static let width: CGFloat = 1.5
    static let branch: CGFloat = 11.5

    static func status(of session: SessionSummary) -> NodeStatus {
        if session.status == .needsInput { return .waiting }
        if session.isRunning || session.status == .working { return .working }
        if session.unread { return .unread }
        return .quiet
    }

    var body: some View {
        if style != .none {
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                draw(in: &context, size: size)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let h = size.height
        guard h > 0 else { return }
        let content = max(1, h - (last ? BotChatsMetrics.tail : 0))
        let middle = content / 2
        let endX = lineX + reach
        let fadeTop = min(7, middle * 0.55)

        switch style {
        case .none:
            return

        case .branch:
            let r = min(8.5, reach * 0.72, max(2, middle - 1))
            let tipX = more ? endX - 2 : endX
            let alpha: Double = emphasized ? 0.94 : 0.64
            drawUnified(in: &context, opacity: alpha) { layer in
                let shade = topFadeShading(height: h, fadeTop: fadeTop, opacity: 1)
                let trunkEnd = last ? max(0, middle - r) : h
                if trunkEnd > 0 {
                    var trunk = Path()
                    trunk.move(to: CGPoint(x: lineX, y: 0))
                    trunk.addLine(to: CGPoint(x: lineX, y: trunkEnd))
                    layer.stroke(trunk, with: shade, style: StrokeStyle(lineWidth: Self.width, lineCap: .butt))
                }
                let sy = max(0, middle - r)
                let cr = middle - sy
                var arm = Path()
                arm.move(to: CGPoint(x: lineX, y: sy))
                arm.addQuadCurve(to: CGPoint(x: lineX + cr, y: middle), control: CGPoint(x: lineX, y: middle))
                arm.addLine(to: CGPoint(x: tipX, y: middle))
                layer.stroke(arm, with: shade, style: StrokeStyle(lineWidth: Self.width, lineCap: .round, lineJoin: .round))
            }

        case .arrows:
            let r = min(8.5, reach * 0.66, max(2, middle - 1))
            let tipX = more ? endX - 2.5 : endX
            let baseAlpha: Double = emphasized ? 0.92 : 0.56
            let lineW: CGFloat = emphasized ? 1.6 : 1.4
            drawUnified(in: &context, opacity: baseAlpha) { layer in
                let shade = topFadeShading(height: h, fadeTop: fadeTop, opacity: 1)
                let trunkEnd = last ? max(0, middle - r) : h
                if trunkEnd > 0 {
                    var trunk = Path()
                    trunk.move(to: CGPoint(x: lineX, y: 0))
                    trunk.addLine(to: CGPoint(x: lineX, y: trunkEnd))
                    layer.stroke(trunk, with: shade, style: StrokeStyle(lineWidth: lineW, lineCap: .butt))
                }
                let sy = max(0, middle - r)
                let cr = middle - sy
                var arm = Path()
                arm.move(to: CGPoint(x: lineX, y: sy))
                arm.addQuadCurve(to: CGPoint(x: lineX + cr, y: middle), control: CGPoint(x: lineX, y: middle))
                arm.addLine(to: CGPoint(x: tipX, y: middle))
                layer.stroke(arm, with: shade, style: StrokeStyle(lineWidth: lineW, lineCap: .round, lineJoin: .round))
            }
            if !more {
                let aw: CGFloat = 3.4, ah: CGFloat = 2.9
                var chevron = Path()
                chevron.move(to: CGPoint(x: tipX - aw, y: middle - ah))
                chevron.addLine(to: CGPoint(x: tipX, y: middle))
                chevron.addLine(to: CGPoint(x: tipX - aw, y: middle + ah))
                context.stroke(chevron, with: .color(tint.opacity(emphasized ? 1 : 0.88)),
                               style: StrokeStyle(lineWidth: emphasized ? 1.7 : 1.45, lineCap: .round, lineJoin: .round))
            }

        case .splines:
            let sy = max(0, middle - min(12, middle - 1))
            let tipX = endX - 2
            let spineEnd = last ? sy : h
            if spineEnd > 0 {
                var spine = Path()
                spine.move(to: CGPoint(x: lineX, y: 0))
                spine.addLine(to: CGPoint(x: lineX, y: spineEnd))
                context.stroke(spine, with: topFadeShading(height: h, fadeTop: fadeTop, opacity: 0.4),
                               style: StrokeStyle(lineWidth: 1.3, lineCap: .butt))
            }
            var curve = Path()
            curve.move(to: CGPoint(x: lineX, y: sy))
            curve.addCurve(to: CGPoint(x: tipX, y: middle),
                           control1: CGPoint(x: lineX, y: sy + (middle - sy) * 0.72),
                           control2: CGPoint(x: lineX + (tipX - lineX) * 0.22, y: middle))
            let curveOp: Double = emphasized ? 0.96 : more ? 0.44 : 0.62
            context.stroke(curve, with: .color(tint.opacity(curveOp)),
                           style: StrokeStyle(lineWidth: emphasized ? 1.7 : 1.35, lineCap: .round))
            if !more {
                let isHot = emphasized || status == .unread || status == .waiting
                let dotColor: Color = status == .waiting ? .hqOrange : tint
                let rDot: CGFloat = isHot ? 2.5 : 2.0
                if isHot {
                    let halo = rDot + 2.2
                    context.fill(Path(ellipseIn: CGRect(x: tipX - halo, y: middle - halo, width: halo * 2, height: halo * 2)),
                                 with: .color(dotColor.opacity(0.22)))
                }
                context.fill(Path(ellipseIn: CGRect(x: tipX - rDot, y: middle - rDot, width: rDot * 2, height: rDot * 2)),
                             with: .color(dotColor.opacity(isHot ? 0.98 : 0.78)))
            }

        case .quill:
            let r = min(9.5, reach * 0.74, max(2, middle - 1))
            let sy = max(0, middle - r)
            let cr = middle - sy
            let tipX = more ? endX - 2 : endX + 0.5
            let alpha: Double = emphasized ? 0.94 : more ? 0.56 : 0.74
            drawUnified(in: &context, opacity: alpha) { layer in
                let shade = topFadeShading(height: h, fadeTop: fadeTop, opacity: 1)
                let trunkEnd = last ? max(0, sy + 1.5) : h
                if trunkEnd > 0 {
                    let topW: CGFloat = first ? 1.1 : 0.72
                    let botW: CGFloat = 0.72
                    var spine = Path()
                    spine.move(to: CGPoint(x: lineX - topW, y: 0))
                    spine.addLine(to: CGPoint(x: lineX + topW, y: 0))
                    spine.addLine(to: CGPoint(x: lineX + botW, y: trunkEnd))
                    spine.addLine(to: CGPoint(x: lineX - botW, y: trunkEnd))
                    spine.closeSubpath()
                    layer.fill(spine, with: shade)
                }
                let wStart: CGFloat = 0.86
                let tipR: CGFloat = 0.35
                let midTailX = lineX + cr + (tipX - (lineX + cr)) * 0.55
                var nib = Path()
                nib.move(to: CGPoint(x: lineX - wStart * 0.78, y: sy))
                nib.addCurve(to: CGPoint(x: lineX + cr, y: middle + wStart * 0.72),
                             control1: CGPoint(x: lineX - wStart * 0.78, y: sy + cr * 0.68),
                             control2: CGPoint(x: lineX + cr * 0.32, y: middle + wStart * 0.92))
                nib.addQuadCurve(to: CGPoint(x: tipX, y: middle + tipR),
                                 control: CGPoint(x: midTailX, y: middle + wStart * 0.52))
                nib.addArc(center: CGPoint(x: tipX, y: middle), radius: tipR,
                           startAngle: .degrees(90), endAngle: .degrees(-90), clockwise: true)
                nib.addQuadCurve(to: CGPoint(x: lineX + cr, y: middle - wStart * 0.62),
                                 control: CGPoint(x: midTailX, y: middle - wStart * 0.52))
                nib.addCurve(to: CGPoint(x: lineX + wStart * 0.72, y: sy),
                             control1: CGPoint(x: lineX + cr * 0.45, y: middle - wStart * 0.64),
                             control2: CGPoint(x: lineX + wStart * 0.72, y: sy + cr * 0.55))
                nib.closeSubpath()
                layer.fill(nib, with: shade)
            }

        case .dots:
            if more {
                let stubEnd = max(0, middle - 6)
                if !first, stubEnd > 0 {
                    var stub = Path()
                    stub.move(to: CGPoint(x: lineX, y: 0))
                    stub.addLine(to: CGPoint(x: lineX, y: stubEnd))
                    context.stroke(stub, with: .color(tint.opacity(0.42)), style: StrokeStyle(lineWidth: 1.5, lineCap: .butt))
                }
                let offsets: [(CGFloat, Double)] = [(-3, 0.55), (0.5, 0.38), (4, 0.22)]
                for (dy, op) in offsets {
                    let r: CGFloat = 1.15
                    context.fill(Path(ellipseIn: CGRect(x: lineX - r, y: middle + dy - r, width: r * 2, height: r * 2)),
                                 with: .color(tint.opacity(op)))
                }
            } else {
                let isSolid = emphasized || status == .unread || status == .waiting
                let gapR: CGFloat = isSolid ? 5.0 : 4.2
                let upperEnd = max(0, middle - gapR)
                if upperEnd > 0 {
                    var upper = Path()
                    upper.move(to: CGPoint(x: lineX, y: 0))
                    upper.addLine(to: CGPoint(x: lineX, y: upperEnd))
                    context.stroke(upper, with: topFadeShading(height: h, fadeTop: fadeTop, opacity: 0.44),
                                   style: StrokeStyle(lineWidth: 1.5, lineCap: .butt))
                }
                if !last {
                    let lowerStart = min(h, middle + gapR)
                    if lowerStart < h {
                        var lower = Path()
                        lower.move(to: CGPoint(x: lineX, y: lowerStart))
                        lower.addLine(to: CGPoint(x: lineX, y: h))
                        context.stroke(lower, with: .color(tint.opacity(0.44)),
                                       style: StrokeStyle(lineWidth: 1.5, lineCap: .butt))
                    }
                }
                let nodeColor: Color = status == .waiting ? .hqOrange : tint
                if isSolid {
                    let r: CGFloat = 3.2
                    context.fill(Path(ellipseIn: CGRect(x: lineX - r, y: middle - r, width: r * 2, height: r * 2)),
                                 with: .color(nodeColor.opacity(emphasized ? 1 : 0.94)))
                } else {
                    let r: CGFloat = 3.2
                    context.stroke(Path(ellipseIn: CGRect(x: lineX - r, y: middle - r, width: r * 2, height: r * 2)),
                                   with: .color(tint.opacity(0.82)), lineWidth: 1.6)
                }
                let cx = lineX + reach * 0.72
                var tick = Path()
                tick.move(to: CGPoint(x: cx - 2.1, y: middle - 2.5))
                tick.addLine(to: CGPoint(x: cx + 0.9, y: middle))
                tick.addLine(to: CGPoint(x: cx - 2.1, y: middle + 2.5))
                context.stroke(tick, with: .color(tint.opacity(emphasized ? 0.96 : 0.55)),
                               style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
            }

        case .rail:
            let barTop: CGFloat = first ? 3 : 0
            let barBot: CGFloat = last ? min(content, middle + 5) : h
            if barBot > barTop {
                let rect = CGRect(x: lineX - 1, y: barTop, width: 2, height: barBot - barTop)
                let radii = RectangleCornerRadii(topLeading: first ? 1 : 0, bottomLeading: last ? 1 : 0,
                                                 bottomTrailing: last ? 1 : 0, topTrailing: first ? 1 : 0)
                let barShade: GraphicsContext.Shading = last
                    ? .linearGradient(Gradient(colors: [tint.opacity(0.46), tint.opacity(0.18)]),
                                      startPoint: CGPoint(x: lineX, y: barTop), endPoint: CGPoint(x: lineX, y: barBot))
                    : .color(tint.opacity(0.46))
                context.fill(Path(roundedRect: rect, cornerRadii: radii), with: barShade)
            }
            if emphasized {
                let pill = CGRect(x: lineX - 1.15, y: max(barTop, middle - 7), width: 2.3, height: min(14, content))
                context.fill(Path(roundedRect: pill, cornerRadius: 1.15), with: .color(tint.opacity(0.95)))
            }
            let gx = lineX + max(4.2, min(5.5, reach - 7))
            if more {
                let r: CGFloat = 1.3
                context.fill(Path(ellipseIn: CGRect(x: gx + 2.8 - r, y: middle - r, width: r * 2, height: r * 2)),
                             with: .color(tint.opacity(0.52)))
            } else {
                let op: Double = emphasized ? 0.98 : (status == .unread || status == .waiting) ? 0.82 : 0.54
                drawUnified(in: &context, opacity: op) { layer in
                    var stem = Path()
                    stem.move(to: CGPoint(x: gx, y: middle - 4.2))
                    stem.addLine(to: CGPoint(x: gx, y: middle - 1.5))
                    stem.addQuadCurve(to: CGPoint(x: gx + 2.1, y: middle + 0.6), control: CGPoint(x: gx, y: middle + 0.6))
                    stem.addLine(to: CGPoint(x: gx + 6.4, y: middle + 0.6))
                    var head = Path()
                    head.move(to: CGPoint(x: gx + 4.2, y: middle - 1.6))
                    head.addLine(to: CGPoint(x: gx + 6.7, y: middle + 0.6))
                    head.addLine(to: CGPoint(x: gx + 4.2, y: middle + 2.8))
                    let stroke = StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round)
                    layer.stroke(stem, with: .color(tint), style: stroke)
                    layer.stroke(head, with: .color(tint), style: stroke)
                }
            }

        case .line, .dividers:
            let end = last ? max(0, content - 7) : h
            if end > 0 {
                var trunk = Path()
                trunk.move(to: CGPoint(x: lineX, y: 0))
                trunk.addLine(to: CGPoint(x: lineX, y: end))
                context.stroke(trunk, with: topFadeShading(height: end, fadeTop: fadeTop, opacity: emphasized ? 0.88 : 0.58),
                               style: StrokeStyle(lineWidth: Self.width, lineCap: last ? .round : .butt))
            }
        }
    }

    private func drawUnified(in context: inout GraphicsContext, opacity: Double, _ body: (inout GraphicsContext) -> Void) {
        context.drawLayer { layer in
            layer.opacity = opacity
            body(&layer)
        }
    }

    private func topFadeShading(height: CGFloat, fadeTop: CGFloat, opacity: Double) -> GraphicsContext.Shading {
        guard first, height > 0 else { return .color(tint.opacity(opacity)) }
        let stop = min(1, max(0.05, fadeTop / height))
        return .linearGradient(
            Gradient(stops: [
                .init(color: tint.opacity(0), location: 0),
                .init(color: tint.opacity(opacity), location: stop),
                .init(color: tint.opacity(opacity), location: 1),
            ]),
            startPoint: CGPoint(x: lineX, y: 0),
            endPoint: CGPoint(x: lineX, y: height)
        )
    }
}

/// Miniature 2x vector glyph representing each `BotChatsStyle` in Settings.
struct BotChatsStyleGlyph: View {
    var style: BotChatsStyle
    var tint: Color

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let w = size.width, h = size.height
            let lx: CGFloat = 8
            let mid = h / 2
            let ex = w - 4

            switch style {
            case .none:
                var dash = Path()
                dash.move(to: CGPoint(x: lx + 2, y: mid))
                dash.addLine(to: CGPoint(x: ex - 4, y: mid))
                context.stroke(dash, with: .color(tint.opacity(0.45)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

            case .branch:
                context.drawLayer { layer in
                    layer.opacity = 0.85
                    var p = Path()
                    p.move(to: CGPoint(x: lx, y: 1))
                    p.addLine(to: CGPoint(x: lx, y: h - 1))
                    p.move(to: CGPoint(x: lx, y: mid - 6))
                    p.addQuadCurve(to: CGPoint(x: lx + 6, y: mid), control: CGPoint(x: lx, y: mid))
                    p.addLine(to: CGPoint(x: ex, y: mid))
                    layer.stroke(p, with: .color(tint), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                }

            case .arrows:
                context.drawLayer { layer in
                    layer.opacity = 0.7
                    var p = Path()
                    p.move(to: CGPoint(x: lx, y: 1))
                    p.addLine(to: CGPoint(x: lx, y: h - 1))
                    p.move(to: CGPoint(x: lx, y: mid - 6))
                    p.addQuadCurve(to: CGPoint(x: lx + 6, y: mid), control: CGPoint(x: lx, y: mid))
                    p.addLine(to: CGPoint(x: ex - 1, y: mid))
                    layer.stroke(p, with: .color(tint), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
                var arrow = Path()
                arrow.move(to: CGPoint(x: ex - 4.8, y: mid - 3.5))
                arrow.addLine(to: CGPoint(x: ex - 0.8, y: mid))
                arrow.addLine(to: CGPoint(x: ex - 4.8, y: mid + 3.5))
                context.stroke(arrow, with: .color(tint), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))

            case .splines:
                var spine = Path()
                spine.move(to: CGPoint(x: lx, y: 1))
                spine.addLine(to: CGPoint(x: lx, y: h - 1))
                context.stroke(spine, with: .color(tint.opacity(0.4)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                var curve = Path()
                curve.move(to: CGPoint(x: lx, y: 2))
                curve.addCurve(to: CGPoint(x: ex - 3, y: mid), control1: CGPoint(x: lx, y: mid - 1), control2: CGPoint(x: lx + 5, y: mid))
                context.stroke(curve, with: .color(tint.opacity(0.8)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                context.fill(Path(ellipseIn: CGRect(x: ex - 6, y: mid - 3, width: 6, height: 6)), with: .color(tint))

            case .quill:
                context.drawLayer { layer in
                    layer.opacity = 0.85
                    var trunk = Path()
                    trunk.move(to: CGPoint(x: lx - 1.2, y: 1))
                    trunk.addLine(to: CGPoint(x: lx + 1.2, y: 1))
                    trunk.addLine(to: CGPoint(x: lx + 0.8, y: h - 1))
                    trunk.addLine(to: CGPoint(x: lx - 0.8, y: h - 1))
                    trunk.closeSubpath()
                    layer.fill(trunk, with: .color(tint))
                    var nib = Path()
                    nib.move(to: CGPoint(x: lx - 0.9, y: 2))
                    nib.addCurve(to: CGPoint(x: lx + 7, y: mid + 1.2), control1: CGPoint(x: lx - 0.9, y: mid), control2: CGPoint(x: lx + 2.5, y: mid + 1.5))
                    nib.addQuadCurve(to: CGPoint(x: ex, y: mid + 0.4), control: CGPoint(x: ex - 5, y: mid + 0.9))
                    nib.addArc(center: CGPoint(x: ex, y: mid), radius: 0.4, startAngle: .degrees(90), endAngle: .degrees(-90), clockwise: true)
                    nib.addQuadCurve(to: CGPoint(x: lx + 7, y: mid - 1.0), control: CGPoint(x: ex - 5, y: mid - 0.9))
                    nib.addCurve(to: CGPoint(x: lx + 0.9, y: 2), control1: CGPoint(x: lx + 3.2, y: mid - 1.1), control2: CGPoint(x: lx + 0.9, y: mid - 2))
                    nib.closeSubpath()
                    layer.fill(nib, with: .color(tint))
                }

            case .dots:
                var upper = Path()
                upper.move(to: CGPoint(x: lx + 2, y: 1))
                upper.addLine(to: CGPoint(x: lx + 2, y: mid - 4.5))
                var lower = Path()
                lower.move(to: CGPoint(x: lx + 2, y: mid + 4.5))
                lower.addLine(to: CGPoint(x: lx + 2, y: h - 1))
                context.stroke(upper, with: .color(tint.opacity(0.45)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                context.stroke(lower, with: .color(tint.opacity(0.45)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                context.stroke(Path(ellipseIn: CGRect(x: lx - 1.5, y: mid - 3.5, width: 7, height: 7)), with: .color(tint), lineWidth: 1.7)
                var tick = Path()
                tick.move(to: CGPoint(x: ex - 6, y: mid - 3))
                tick.addLine(to: CGPoint(x: ex - 2.5, y: mid))
                tick.addLine(to: CGPoint(x: ex - 6, y: mid + 3))
                context.stroke(tick, with: .color(tint.opacity(0.75)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

            case .rail:
                context.fill(Path(roundedRect: CGRect(x: lx - 1, y: 2, width: 2.4, height: h - 4), cornerRadius: 1.2), with: .color(tint.opacity(0.62)))
                var stem = Path()
                stem.move(to: CGPoint(x: lx + 6, y: mid - 4.5))
                stem.addLine(to: CGPoint(x: lx + 6, y: mid - 1.2))
                stem.addQuadCurve(to: CGPoint(x: lx + 8.5, y: mid + 1.2), control: CGPoint(x: lx + 6, y: mid + 1.2))
                stem.addLine(to: CGPoint(x: ex - 1, y: mid + 1.2))
                var head = Path()
                head.move(to: CGPoint(x: ex - 4.2, y: mid - 1.8))
                head.addLine(to: CGPoint(x: ex - 0.8, y: mid + 1.2))
                head.addLine(to: CGPoint(x: ex - 4.2, y: mid + 4.2))
                let stroke = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                context.stroke(stem, with: .color(tint), style: stroke)
                context.stroke(head, with: .color(tint), style: stroke)

            case .line:
                var p = Path()
                p.move(to: CGPoint(x: lx + 4, y: 2))
                p.addLine(to: CGPoint(x: lx + 4, y: h - 2))
                context.stroke(p, with: .color(tint.opacity(0.78)), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))

            case .dividers:
                var v = Path()
                v.move(to: CGPoint(x: lx, y: 2))
                v.addLine(to: CGPoint(x: lx, y: h - 2))
                context.stroke(v, with: .color(tint.opacity(0.72)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                var sep = Path()
                sep.move(to: CGPoint(x: lx + 5, y: mid))
                sep.addLine(to: CGPoint(x: ex, y: mid))
                context.stroke(sep, with: .color(Color.hqStroke), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }
        }
        .frame(width: 28, height: 20)
        .accessibilityHidden(true)
    }
}

/// One of the bot's chats, as the Sessions page draws it: its title, a dot when unread, its time.
struct BotChatRowView: View {
    var session: SessionSummary
    var first = false
    var last: Bool
    var showsPin = false
    /// The bot's own colour (its line in the tint style).
    var tint: Color = .hqStroke
    var style: BotChatsStyle = .saved
    @ScaledMetric(relativeTo: .callout) private var height: CGFloat = BotChatsMetrics.rowHeight

    var body: some View {
        let time = ListTime.string(session.lastActive)
        HStack(spacing: 8) {
            if showsPin {
                Image(systemName: "pin.fill").font(Font.hq(.caption2)).foregroundStyle(Color.hqLabel3).accessibilityHidden(true)
            }
            // [Mac AAA rest 2026-11-17] A chat with no title yet was a blank row with only its time: it is named as its
            // Sessions row (and the Mac sidebar) names it, the title, else its first words, else "Untitled Chat".
            Text(SessionRowView.title(session))
                .font(Font.hq(Density.compact && !Theme.isDesktop ? .subheadline : .callout).weight(session.unread ? .semibold : .regular))
                .foregroundStyle(Color.hqLabel)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            // A chat that waits for you is in the middle of its turn: the orange dot outranks the spinner.
            if session.isRunning, session.status != .needsInput {
                ProgressView().controlSize(.mini).accessibilityHidden(true)
            } else if session.unread || session.status == .needsInput {
                // Orange when it waits for an answer, as the Sessions page marks it.
                Circle().fill(session.status == .needsInput ? Color.hqOrange : Color.hqTint)
                    .frame(width: 8, height: 8).accessibilityHidden(true)
            }
            Text(time)
                .font(Font.hq(.footnote))
                .monospacedDigit()
                .foregroundStyle(Color.hqLabel2)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.leading, BotChatsMetrics.textX)
        .padding(.trailing, BotChatsMetrics.leading)
        .frame(minHeight: height)
        .overlay(alignment: .bottom) {
            if style == .dividers, !last {
                Rectangle().fill(Color.hqStroke).frame(height: HQShape.line(0.5))
                    .padding(.leading, BotChatsMetrics.textX).accessibilityHidden(true)
            }
        }
        .padding(.bottom, last ? BotChatsMetrics.tail : 0)
        .background(alignment: .leading) {
            BotChatsLine(first: first, last: last, tint: tint, lineX: BotChatsMetrics.lineX, style: style,
                         status: BotChatsLine.status(of: session))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BotChatRowView.label(session, time: time))
        .accessibilityAddTraits(.isButton)
    }

    static func label(_ session: SessionSummary, time: String) -> String {
        var words = [SessionRowView.title(session)]
        if session.pinned { words.append("Pinned") }
        if session.status == .needsInput { words.append("Waiting for you") }
        if session.isRunning { words.append("Working") } else if session.unread { words.append("Unread") }
        if !time.isEmpty { words.append(time) }
        return words.joined(separator: ", ")
    }
}

/// "N more ›": the rest of the bot's chats, in Sessions with its chip picked.
struct BotChatsMoreView: View {
    var count: Int
    var botName: String
    var first = false
    var tint: Color = .hqStroke
    var style: BotChatsStyle = .saved
    // [ui-sizing] The chat rows' height (Compact's too) as its own: a fixed 32 stood taller than Compact's 28 pt rows.
    @ScaledMetric(relativeTo: .subheadline) private var textHeight: CGFloat = 32
    private var height: CGFloat { textHeight / 32 * BotChatsMetrics.rowHeight }

    var body: some View {
        HStack(spacing: 4) {
            Text("\(count) more").font(Font.hq(.subheadline).weight(.medium))
            Image(systemName: "chevron.right").font(Font.hq(.caption).weight(.semibold))
        }
        .foregroundStyle(Color.hqTintText)
        .padding(.leading, BotChatsMetrics.textX)
        .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
        .padding(.bottom, BotChatsMetrics.tail)
        .background(alignment: .leading) {
            BotChatsLine(first: first, last: true, tint: tint, lineX: BotChatsMetrics.lineX, style: style, more: true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) more chats with \(botName)")
        .accessibilityHint("Opens Sessions with \(botName) picked")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Menus

extension BotChatsChoice {
    /// The choices as menu nodes: the three modes, then the recent count as a row of numbers. `follow`: a bot's own
    /// menu leads with "Same as All Bots" (checked when the bot has no choice of its own).
    @MainActor static func menuNodes(current: BotChatsChoice, own: Bool?, all: BotChatsChoice,
                                     pick: @escaping (BotChatsChoice?) -> Void) -> [BotMenuNode] {
        var modes: [BotMenuNode] = []
        if let own {
            var same = BotMenuNode.action("Same as All Bots", nil, checked: !own) { pick(nil) }
            same.subtitle = all.summary
            modes.append(same)
        }
        let checks = own ?? true
        for mode in BotChatsMode.allCases {
            var node = BotMenuNode.action(mode.title, nil, checked: checks && current.mode == mode) {
                pick(BotChatsChoice(mode: mode, count: current.count))
            }
            node.subtitle = mode.detail
            node.identifier = "chats-under.\(mode.rawValue)"
            modes.append(node)
        }
        let numbers = counts.map { count in
            var node = BotMenuNode.action("\(count)", "\(count).circle", checked: current.mode == .recent && current.count == count) {
                pick(BotChatsChoice(mode: .recent, count: count))
            }
            node.identifier = "chats-under.count.\(count)"
            return node
        }
        return [
            BotMenuNode(title: "", kind: .inline(modes)),
            BotMenuNode(title: own == nil ? "Recent Chats per Bot" : "Recent Chats", kind: .palette(numbers)),
        ]
    }
}

extension Bot {
    /// [chats-under] The bot's own colour: its head's accent.
    var chatsTint: Color {
        let color = Head.resolve(head, profile: id).color
        // Ink and paper faces are drawn black or white (as the page asks), not in their accent.
        if color == .ink { return .hqLabel }
        if color == .paper { return .hqLabel2 }
        let rgb = HeadTones.accent(color)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

extension Head {
    /// [bot-colour] The message colour a face gives its bot's chat: its accent, as the line beside its chats is
    /// (`Bot.chatsTint`). An ink face is drawn black, so its chat is black too, with white text (owner 2026-11-11: "A
    /// black bot face isn't showing a black chat bubble"; in dark it is deepened as any picked colour is). A paper
    /// face is drawn white, so its chat gets the quiet grey pill. [face-colour] Any other face gives its colour exactly,
    /// light and dark (owner 2026-11-17: "They should always match"); every one reads white (`HeadTones`).
    var messageColour: MessageColour {
        if color == .ink { return .custom(HeadTones.ink.hex) }
        if color == .paper { return .preset(.graphite) }
        return HeadTones.tones[color].map { .face($0.accent) } ?? .preset(.graphite)
    }
}

// MARK: - Settings › Appearance › Chats Under Bots

/// [chats-under] The style's page: a preview of a bot's chats drawn in it, then the five styles.
enum BotChatsStyleSettings {
    static let title = "Chats Under Bots"
    static func make() -> UIViewController {
        let page = SettingsPageController(title: title, BotChatsStyleSettingsView())
        page.view.accessibilityIdentifier = "settings.chats-under"
        page.view.backgroundColor = HQPalette.page
        return page
    }
}

struct BotChatsStyleSettingsView: View {
    @AppStorage(BotChatsStyle.key) private var raw = BotChatsStyle.branch.rawValue
    private var style: BotChatsStyle { BotChatsStyle(rawValue: raw) ?? .branch }

    #if targetEnvironment(macCatalyst)
    // [mac] The Mac's bots are in the sidebar, whose right click has the choice (the Bots list's Filter never shows there).
    static let note = "How the line beside each bot's chats looks in the sidebar. To show chats under your bots, Control-click a bot or the sidebar's empty space, then choose Chats Under Bots."
    #else
    static let note = "How the line beside each bot's chats looks on the Bots page. To show chats under your bots, open Bots, tap Filter, then Chats Under Bots."
    #endif

    private static func sample(_ id: String, _ title: String, hoursAgo: Double, unread: Bool = false,
                               status: SessionStatus = .idle) -> SessionSummary {
        var row = SessionSummary(id: id, profile: "preview", title: title, preview: nil,
                                 lastActive: Date().addingTimeInterval(-hoursAgo * 3600),
                                 source: "desktop", unread: unread, isRunning: false)
        row.status = status
        return row
    }

    var body: some View {
        List { Group {
            Section {
                VStack(spacing: 0) {
                    BotChatRowView(session: Self.sample("p1", "Draft the weekly newsletter", hoursAgo: 1, unread: true),
                                   first: true, last: false, tint: .hqTint, style: style)
                    BotChatRowView(session: Self.sample("p2", "Review release notes", hoursAgo: 4, status: .needsInput),
                                   last: false, tint: .hqTint, style: style)
                    BotChatRowView(session: Self.sample("p3", "Plan next week", hoursAgo: 26),
                                   last: false, tint: .hqTint, style: style)
                    BotChatsMoreView(count: 3, botName: "your bot", tint: .hqTint, style: style)
                }
                .padding(.vertical, 6)
                .listRowInsets(EdgeInsets())
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            } header: { HQSectionLabel { Text("Preview") } }
            Section {
                ForEach(BotChatsStyle.allCases, id: \.self) { option in
                    Button {
                        guard option != style else { return }
                        Haptics.play(.selection)
                        BotChatsStyle.saved = option
                        raw = option.rawValue
                        AppLog.trace("settings", "chats under bots style \(option.rawValue)")
                    } label: {
                        HStack(spacing: 12) {
                            BotChatsStyleGlyph(style: option, tint: .hqTintText)
                            Text(option.title).foregroundStyle(Color.hqLabel)
                            Spacer(minLength: 8)
                            if option.rawValue == raw { Image(systemName: "checkmark").foregroundStyle(Color.hqTintText).fontWeight(.semibold) }
                        }
                    }
                    .accessibilityAddTraits(option.rawValue == raw ? .isSelected : [])
                    .accessibilityIdentifier("chats-under.style.\(option.rawValue)")
                }
            } header: { HQSectionLabel { Text("Style") } } footer: { HQSectionFooter { Text(Self.note) } }
            .id(raw)   // the rows redraw with their tick when the pick changes (a List kept the old one)
        }.hqMacSettingsRowInsets() }
        .hqMacForm(settings: true)
        .hqGroupedPage()
        .listStyle(.insetGrouped)
    }
}

/// [chats-under] Settings › Appearance's row for the page, with the style it's set to.
struct BotChatsStyleRow: View {
    var open: () -> Void
    @AppStorage(BotChatsStyle.key) private var raw = BotChatsStyle.branch.rawValue
    var body: some View {
        if DeviceWord.isMac {
            // [mac] Owner 2026-11-09 (Settings "too iOS-like"): one choice is a pop-up in its row, not a page of its
            // own; the sidebar beside it shows the line as it changes.
            HStack(spacing: 12) {
                SettingsRowLabel(title: BotChatsStyleSettings.title, systemImage: "arrow.turn.down.right")
                Spacer(minLength: 16)
                MacPopUp(label: BotChatsStyleSettings.title, selection: Binding(get: { BotChatsStyle(rawValue: raw) ?? .branch }, set: { option in
                    BotChatsStyle.saved = option
                    raw = option.rawValue
                    AppLog.trace("settings", "chats under bots style \(option.rawValue)")
                }), options: BotChatsStyle.allCases) { $0.title }
                    .accessibilityIdentifier("settings.chats-under-row")
                    .hqMacSettingsControl()
            }
            .help("The line beside each bot's chats in the sidebar")
        } else {
        NavRow(title: BotChatsStyleSettings.title, systemImage: "arrow.turn.down.right",
               value: (BotChatsStyle(rawValue: raw) ?? .branch).title, action: open)
            .accessibilityIdentifier("settings.chats-under-row")
        }
    }
}
