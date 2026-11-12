// [sessions-m9] The Sessions page's fixed header (docs/spec/3x-sessions.md §6.2, §7.2): the bot chips rail, then the
// strip that names the Filter menu's filters. It sits under the navigation bar and never scrolls with the list (the
// owner rejected chips that scroll away). It draws no blur or tint of its own. Owner 2026-11-01: in the iOS look it is
// clear, with no rule, and sits over the list's soft edge as the bar's title does (`pinTitle(softEdgeAround:)` reaches
// under it); the Desktop Look keeps a band in the page colour under its bar.

import SwiftUI
import UIKit

/// [perf] What a chip draws, and nothing else: a bot's preview, time or unread changing (every stream event) leaves
/// the rail's array equal, so the rail is not drawn and measured again. The head is resolved once here, not per body.
struct SessionChipBot: Identifiable, Equatable {
    let id: String
    let name: String
    let head: Head
    let isWorking: Bool

    /// The chips for a roster: none with fewer than two bots (no rail).
    static func chips(from bots: [Bot]) -> [SessionChipBot] {
        guard bots.count > 1 else { return [] }
        return bots.map { SessionChipBot(id: $0.id, name: $0.name, head: Head.resolve($0.head, profile: $0.id), isWorking: $0.isWorking) }
    }
}

@MainActor @Observable
final class SessionsHeaderModel {
    /// The chips, in order (Hermes first); empty with fewer than two bots: no rail.
    var bots: [SessionChipBot] = []
    /// The chip's bot; nil: All.
    var picked: String?
    /// The strip's words; nil: no strip.
    var strip: String?
    /// [sessions-fresh] The New and Working chips after All (iPhone and iPad, Group By Recent): their counts under the
    /// bot chip, and the one picked. A chip shows while it has a chat or is picked.
    var statusChips: [SessionStatusChip: Int] = [:]
    var status: SessionStatusChip?
    @ObservationIgnored var onPick: (String?) -> Void = { _ in }
    @ObservationIgnored var onPickStatus: (SessionStatusChip?) -> Void = { _ in }
    /// All: every bot and no status chip.
    @ObservationIgnored var onPickAll: () -> Void = {}
    @ObservationIgnored var onClearStrip: () -> Void = {}

    /// The status chips drawn, in order.
    var shownStatus: [SessionStatusChip] {
        SessionStatusChip.allCases.filter { (statusChips[$0] ?? 0) > 0 || status == $0 }
    }

    var isEmpty: Bool { !hasRail && strip == nil }
    /// The rail shows with a second bot, or (not on the Mac, which keeps its bot menu) a status chip.
    var hasRail: Bool { !bots.isEmpty || (!DeviceWord.isMac && !shownStatus.isEmpty) }
}

struct SessionsHeaderView: View {
    var model: SessionsHeaderModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// [mac] Stress test 2026-10-28 #11: chips cut off at either end of the rail; that end fades as a hint to scroll.
    /// Round 2: the ends were read only from `onScrollGeometryChange`, which runs when
    /// the rail scrolls, not when it first lays out, so a rail cut at the pane's edge showed no fade until it was
    /// scrolled. The widths are now measured as laid out (`onGeometryChange` runs with the first value too).
    @State private var railOffset: CGFloat = 0
    @State private var railWidth: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var position = ScrollPosition()
    /// [mac] Stress test 2026-10-28 round 7: the width the rail has in the pane.
    @State private var available: CGFloat = 0
    private var moreBefore: Bool { DeviceWord.isMac && railOffset > 1 }
    private var moreAfter: Bool { DeviceWord.isMac && railWidth > 0 && railOffset + railWidth < contentWidth - 1 }
    /// [mac] The rail scrolls (its scroller can show): owner 2026-10-29, the scroller sat on the names under the faces.
    /// Then the names keep the scroller's lane under them, and the arrows rise with the faces.
    private var barLane: CGFloat {
        guard DeviceWord.isMac, railWidth > 0, contentWidth > railWidth + 0.5 else { return 0 }
        return max(0, ScrollBarLane.height - 8)
    }

    // [mac] Stress test 2026-10-28 round 7: the last chip was cut under the fade and the "›" button ("Res", "Researc",
    // the arrow over its face). On the Mac a rail that doesn't fit is now as wide as the whole chips that fit, it
    // stops on a chip (`ChipPaging`), and its two arrows stand in the room after it, so nothing is half shown or covered.
    /// The rail's side room inside its scroll view.
    private var side: CGFloat { Theme.isDesktop ? DesktopRows.gutter - 4 : 16 }
    private static let chipGap: CGFloat = 14
    /// [mac] Stress test 2026-10-28 round 8: the least gap a clamped rail closes to so one more whole chip fits. The
    /// Desktop Look's chips are 83 pt (UI Scale x 1.3), so at 14 pt gaps a 440 pt pane held three with 84 pt empty
    /// after the arrows, where the iOS look's 74 pt chips held four.
    private static let leastGap: CGFloat = 4
    /// The gap between chips: 14, or on a clamped rail what fills the pane (never under `leastGap`).
    /// [mac] Stress test 2026-10-28 round 10: a clamped rail's gaps were capped at 14, so the room the whole chips left
    /// all stood between the last chip and the arrows (about 67 pt at laptop width). Now that room is shared out: the
    /// gaps between the chips and the one before the arrows are equal, and the arrows still end on the rows' edge.
    private var gap: CGFloat {
        guard clamped, shown > 1 else { return Self.chipGap }
        let room = available - side - CGFloat(shown) * macPitch - Self.pagersWidth - DesktopRows.gutter
        return max(Self.leastGap, (room / CGFloat(shown)).rounded(.down))
    }
    /// [mac] Stress test 2026-10-28 round 10: the two arrows' width on a clamped rail (two 26 pt frames 2 pt apart).
    private static var pagersWidth: CGFloat { 2 * (24 + 2 * pagerSlack) + 2 }
    private var macPitch: CGFloat { SessionChip<EmptyView>.macPitch }
    /// One chip and the gap after it.
    private var chipStep: CGFloat { macPitch + gap }
    /// The room the two arrows take after a clamped rail.
    private static let arrowRoom: CGFloat = 64
    /// [mac] Stress test 2026-10-28 round 9: a clamped rail's arrow frame is 26 pt round its 24 pt circle, so the circle
    /// stands 1 pt inside the frame's trailing edge. The frame ends `DesktopRows.gutter` in from the pane's edge, where
    /// the rows' text ends (both looks), so the circle's ink ends where the time's does (its glyphs keep 1 pt of side
    /// bearing): measured 646 and 646 in a 440 pt pane, 526 and 526 at laptop width.
    private static let pagerSlack: CGFloat = 1
    /// [mac] Stress test 2026-10-28 round 8: every chip (All and each bot) at the full gap, counted rather than measured, so closing the gaps
    /// can't unclamp the rail.
    private var fullWidth: CGFloat {
        let count = CGFloat(model.bots.count + 1)
        return 2 * side + count * macPitch + (count - 1) * Self.chipGap
    }
    /// The rail doesn't fit its pane (the Mac only).
    private var clamped: Bool { DeviceWord.isMac && available > 0 && fullWidth > available + 0.5 }
    /// How many whole chips a clamped rail shows, at the least gap.
    private var shown: Int {
        max(1, Int(((available - Self.arrowRoom - 2 * side + Self.leastGap) / (macPitch + Self.leastGap)).rounded(.down)))
    }
    /// A clamped rail's width: its leading side room and `shown` whole chips. [mac] Stress test 2026-10-28 round 8: it ends at the last whole
    /// chip (the side room after it goes before the arrows instead); with the gaps closed to 4 pt the next chip began
    /// inside a trailing 16 pt and its name's first letter showed.
    private var clampedWidth: CGFloat { side + CGFloat(shown) * chipStep - gap }

    static let allId = "sessions.chip.all"

    var body: some View {
        VStack(spacing: 0) {
            if model.hasRail { rail }
            if let strip = model.strip {
                PageFilterToken(text: strip, identifier: "sessions.filter-strip", clearWords: "Clear Filters", clear: model.onClearStrip)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Theme.isDesktop ? Color.hqPage : Color.clear)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.strip)
    }

    @ViewBuilder private var rail: some View {
        if DeviceWord.isMac {
            botMenu
        } else {
            pillRail
        }
    }

    /// [mac-audit] Owner 2026-11-02 (#20): on the Mac the bots are an "All Bots ⌄" pop-up, the words-and-chevron control
    /// Jobs and Artifacts have (`ScopeBarItem`), not a rail of faces paged by small ‹ › arrows. It sits here, under the
    /// bar where the rail was, not in the bar: a fourth item beside Filter, New and Search left no room in the 320 pt
    /// list pane, and UIKit dropped the "Sessions" title (with one gateway; two kept it by its subtitle).
    private var botMenu: some View {
        let ink = DeviceWord.isMac && !Theme.isDesktop ? Color.hqLabel : Color.hqLabel2
        let title = model.picked.flatMap { id in model.bots.first { $0.id == id }?.name } ?? "All Bots"
        return Menu {
            Picker("Bot", selection: Binding(get: { model.picked }, set: { model.onPick($0) })) {
                Text("All Bots").tag(String?.none)
                Section {
                    ForEach(model.bots) { bot in Text(bot.name).tag(Optional(bot.id)) }
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Text(title).font(Font.hq(.subheadline))
                Image(systemName: "chevron.down").font(Font.hq(.caption2).weight(.semibold)).imageScale(.small)
            }
            .foregroundStyle(ink)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Showing \(title). Change")
        .accessibilityIdentifier("sessions.bots")
        .padding(.leading, DesktopRows.gutter)   // the rows' and the bar title's leading edge
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The Mac's faces rail with ‹ › arrows, unused since the pop-up took its place (#20); kept until the owner has seen it.
    @ViewBuilder private var macRail: some View {
        if DeviceWord.isMac {
            HStack(spacing: 0) {
                railScroll
                    .frame(width: clamped ? clampedWidth : nil)
                    .scrollTargetBehavior(ChipPaging(step: clamped ? chipStep : 0))
                if clamped {
                    // [mac] Stress test 2026-10-28 round 9: the arrows end on the rows' trailing edge (the time's), at
                    // every pane width; the room the whole chips leave goes between the last chip and the arrows. They
                    // stood a side room after the rail, so they ran 17 pt past the rows in a wide pane and stopped 27 pt
                    // short of them at laptop width.
                    Spacer(minLength: 0)
                    HStack(spacing: 2) {
                        pager(forward: false).disabled(!moreBefore)
                        pager(forward: true).disabled(!moreAfter)
                    }
                    .padding(.trailing, DesktopRows.gutter)
                }
            }
            // [mac] Stress test 2026-10-28 round 8: the pane's width whatever the rail inside asks. Without a least width
            // the frame grew to a wider rail, so a rail sized in a wider pane (the window at its narrowest, 512) kept
            // reading that width back at 440 and stood 28 pt wider than the pane, its ends cut.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
        } else {
            pillRail
        }
    }

    /// [sessions-layout] iPhone and iPad: the bots as slim pills (a small face before the name) in one row, so the
    /// rail is about 50 pt tall rather than 80 and shows more of the roster. The Mac keeps its faces rail.
    /// [bot-pills] The rail is `BotPillRail`, which Tasks draws too; Sessions adds New and Working after All.
    private var pillRail: some View {
        BotPillRail(bots: model.bots, picked: model.picked, allPicked: model.picked == nil && model.status == nil,
                    identifier: "sessions.chip", onPick: model.onPick, onPickAll: model.onPickAll) {
            // [sessions-fresh] New and Working, then a rule before the bots.
            ForEach(model.shownStatus, id: \.self) { chip in
                let count = model.statusChips[chip] ?? 0
                let word = chip == .new ? "New" : "Working"
                SessionPill(caption: "\(word) \(count)", name: "\(word), \(count) \(count == 1 ? "chat" : "chats")",
                            picked: model.status == chip, identifier: "sessions.chip.status.\(chip.rawValue)",
                            hasFace: true, lead: 12) {
                    model.onPickStatus(model.status == chip ? nil : chip)
                } face: {
                    StatusChipMark(chip: chip, picked: model.status == chip)
                }
                .id("status-\(chip.rawValue)")
            }
            if !model.shownStatus.isEmpty, !model.bots.isEmpty {
                Rectangle().fill(Color(uiColor: HQPalette.separator)).frame(width: 1, height: 22)
                    .accessibilityHidden(true)
            }
        }
    }

    private var railScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: gap) {   // [mac] Stress test 2026-10-28 round 8: closes on a clamped rail
                    SessionChip(caption: "All", name: "All Bots", picked: model.picked == nil, identifier: Self.allId) {
                        model.onPick(nil)
                    } face: {
                        Image(systemName: "square.stack.3d.up")
                            .font(Font.hqSystem(size: 19, weight: .medium))
                            .foregroundStyle(Color.hqLabel2)
                            .frame(width: chipFace, height: chipFace)
                            .background {
                                // [mac] Stress test 2026-10-28 #68: a circle in the look too, like the heads beside it.
                                if Theme.isDesktop && !DeviceWord.isMac { RoundedRectangle(cornerRadius: DesktopRows.radius).fill(Color.hqFill3) }
                                else { Circle().fill(Color.hqFill3) }
                            }
                    }
                    .id(Self.allId)
                    ForEach(model.bots) { bot in
                        let head = bot.head
                        // [photoheads] A photo is an app-icon tile, so its ring is the rounded square. Reading
                        // `version` redraws the ring when a photo arrives or goes.
                        let _ = BotFaces.shared.version
                        let photo = BotFaces.shared.showsPhoto(bot.id)
                        SessionChip(caption: bot.name, name: bot.name, picked: model.picked == bot.id,
                                    identifier: "sessions.chip.\(bot.id)", round: Self.isRound(head) && !photo) {
                            // The lit chip goes back to every bot.
                            model.onPick(model.picked == bot.id ? nil : bot.id)
                        } face: {
                            HeadImage(head: head, profile: bot.id, size: chipFace, working: bot.isWorking,
                                      phase: HeadView.phase(for: bot.id), moods: true)
                        }
                        .id(bot.id)
                    }
                }
                .padding(.horizontal, side)
                // [mac] Stress test 2026-10-28 round 7: the Desktop Look's 4 pt put the ring about 2 pt under the bar on
                // the Mac; there it has the iOS look's room in both looks.
                .padding(.vertical, Theme.isDesktop && !DeviceWord.isMac ? 4 : 8)
                .padding(.bottom, barLane)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }   // [mac] #11
            }
            // [mac] The Mac shows the scroller while it scrolls (a mouse has no swipe to discover the rail with), fades a
            // cut-off end and puts a scroll button on it (stress test 2026-10-28 #11).
            .scrollIndicators(DeviceWord.isMac ? .automatic : .hidden)
            .scrollPosition($position)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { railWidth = $0 }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in
                if DeviceWord.isMac { railOffset = x }
            }
            .mask {
                // [mac] Round 7: a clamped rail shows whole chips only, so neither end fades.
                let moreBefore = moreBefore && !clamped, moreAfter = moreAfter && !clamped
                HStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(moreBefore ? 0 : 1), .black], startPoint: .leading, endPoint: .trailing).frame(width: Self.fade)
                    Rectangle()
                    LinearGradient(colors: [.black, .black.opacity(moreAfter ? 0 : 1)], startPoint: .leading, endPoint: .trailing).frame(width: Self.fade)
                }
            }
            .overlay(alignment: .leading) { if moreBefore && !clamped { pager(forward: false) } }
            .overlay(alignment: .trailing) { if moreAfter && !clamped { pager(forward: true) } }
            // item 20: the trailing chip read as clipped, not more to scroll to; the picked chip starts in view. The Mac
            // has its own fade and scroll buttons (above), so this is the iPhone's only.
            .hqScrollEdgeFade(width: DeviceWord.isMac ? 0 : 20)
            .onAppear { if !DeviceWord.isMac { proxy.scrollTo(model.picked ?? Self.allId, anchor: .center) } }
            .onChange(of: model.picked) { _, picked in
                // [mac] Round 7: a clamped rail centres the picked chip on a whole-chip stop.
                if clamped {
                    let index = picked.flatMap { id in model.bots.firstIndex { $0.id == id }.map { $0 + 1 } } ?? 0
                    let most = max(0, contentWidth - clampedWidth)
                    let x = min(most, max(0, (CGFloat(index) - CGFloat(shown - 1) / 2).rounded(.down) * chipStep))
                    if reduceMotion { position.scrollTo(x: x) } else { withAnimation(.easeInOut(duration: 0.25)) { position.scrollTo(x: x) } }
                    return
                }
                if reduceMotion {
                    proxy.scrollTo(picked ?? Self.allId, anchor: .center)
                } else {
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(picked ?? Self.allId, anchor: .center) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bots")
        .accessibilityIdentifier("sessions.chips")
    }

    /// [mac] Stress test 2026-10-28 #11: the width a cut-off end fades over.
    private static let fade: CGFloat = 44

    /// [mac] Stress test 2026-10-28 #11: a small round arrow on a cut-off end, as a Mac's carousels have: the rail
    /// scrolls (a mouse wheel turns it only with Shift), and a click moves it most of the pane's width.
    private func pager(forward: Bool) -> some View {
        Button {
            // [mac] Round 7: a clamped rail moves a page of whole chips.
            let step = clamped ? CGFloat(shown) * chipStep : max(80, railWidth - 120)
            let target = forward ? min(railOffset + step, max(0, contentWidth - railWidth)) : max(0, railOffset - step)
            if reduceMotion { position.scrollTo(x: target) } else { withAnimation(.easeInOut(duration: 0.25)) { position.scrollTo(x: target) } }
        } label: {
            Image(systemName: forward ? "chevron.forward" : "chevron.backward")
                .font(Font.hq(.footnote).weight(.semibold))
                .foregroundStyle(Color.hqLabel2)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.hqPage))
                .overlay(Circle().strokeBorder(Color.hqStroke, lineWidth: 1))
                .frame(width: clamped ? 24 + 2 * Self.pagerSlack : 32, height: 44)   // [mac] Stress test 2026-10-28 round 9: was 28 clamped
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(clamped && !(forward ? moreAfter : moreBefore) ? 0.35 : 1)   // [mac] Round 7: an end reached
        .padding(.bottom, (Theme.isDesktop ? 14 : 18) + barLane)   // on the faces, not the names under them
        .padding(forward ? .trailing : .leading, clamped ? 0 : 2)   // [mac] Stress test 2026-10-28 round 9: the pair ends on the rows' edge
        .accessibilityLabel(forward ? "Show More Bots" : "Show Earlier Bots")
        .accessibilityIdentifier(forward ? "sessions.chips.next" : "sessions.chips.previous")
    }

    /// A head that is a plain circle (a round Shapes head with no backdrop, or any dot-matrix head: its LEDs sit in a
    /// round glow): its ring is a circle too. Every other head (a square, a pill, a star, a head on a tile) is ringed
    /// by a rounded square that clears its corners.
    /// [desktoplook2] 32 pt faces in the look (the roster's), 44 pt otherwise.
    /// [density] UI Scale only: Compact tightens the list's rows, not the controls above it (owner 2026-11-09).
    private var chipFace: CGFloat { Theme.isDesktop ? DesktopRows.face : HQFont.scaled(44) }

    static func isRound(_ head: Head) -> Bool {
        (head.theme == .shape && head.form == .round && head.tile == .none) || head.theme == .matrix
    }
}

/// One chip: a 44 pt face with its name under it; picked, a 2 pt tint ring 2 pt outside the face. The ring follows
/// the face's frame, as the web's does ("the selection ring follows the bot icon's rounded frame",
/// phone-ui-bots.css): a circle around a round face, else a rounded square with the web's 22.37% corner, so it never
/// crosses a square head's corners.
private struct SessionChip<Face: View>: View {
    var caption: String
    var name: String
    var picked: Bool
    var identifier: String
    var round = true
    var action: () -> Void
    @ViewBuilder var face: () -> Face
    /// The caption's room: 64 pt, widening with larger text (to 96 pt, where the caption stops growing) so a name is
    /// not cut to four letters; the web's pitch widens with the names under it the same way.
    @ScaledMetric(relativeTo: .caption2) private var scaledPitch: CGFloat = 64

    /// [mac] Stress test 2026-10-28 round 7: a chip's width on the Mac, where Dynamic Type doesn't move (`scaledPitch`
    /// stays 64), so the rail can size itself to whole chips.
    static var macPitch: CGFloat { min(max(64 * HQFont.scale, 64), 96 * HQFont.scale).rounded() }

    /// [mac] Stress test 2026-10-28 #11: Dynamic Type doesn't move on the Mac but UI Scale grows the caption, so the
    /// pitch grows with UI Scale there ("Not…", "Her…", "Rese…" were cut at 64).
    private var pitch: CGFloat {
        if DeviceWord.isMac { return Self.macPitch }   // [mac] Round 7: the width the rail counts on
        let scale: CGFloat = 1
        return min(max(64 * scale, scaledPitch.rounded()), 96 * scale).rounded()
    }

    /// 52 pt across: the 44 pt face and 4 pt around it.
    private static var ringCorner: CGFloat { 52 * 0.2237 }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                face()
                    .padding(4)
                    .overlay {
                        if picked {
                            // [mac] Stress test 2026-10-28 #68: on the Mac the look's ring follows a round face too (the
                            // All chip read as a blue-outlined square among round heads).
                            if Theme.isDesktop && DeviceWord.isMac && round {
                                Circle().strokeBorder(Color.hqTintText, lineWidth: 1.5)
                            } else if Theme.isDesktop {   // [desktoplook2] the desktop's square ring in the accent
                                RoundedRectangle(cornerRadius: DesktopRows.radius).strokeBorder(Color.hqTintText, lineWidth: 1.5)
                            } else if round {
                                Circle().strokeBorder(Color.hqTint, lineWidth: 2)
                            } else {
                                RoundedRectangle(cornerRadius: Self.ringCorner, style: .continuous).strokeBorder(Color.hqTint, lineWidth: 2)
                            }
                        }
                    }
                Text(caption)
                    .font(Font.hq(.caption2).weight(picked ? .semibold : .regular))
                    .foregroundStyle(picked ? Color.hqLabel : Color.hqLabel2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .frame(width: pitch)
            }
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // One element a chip: the button itself carries the name, the picked state and the identifier (a wrapping
        // element left the button inside it in the tree, so each chip was there twice).
        .accessibilityLabel(name)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

/// [sessions-layout] One pill on the iPhone's and iPad's bot rail: a 24 pt face and the bot's name in a 34 pt capsule
/// on Liquid Glass (the look's flat square corners in Desktop Look); picked, the tint with its words in the tint's ink. "All"
/// has no face. [bot-pills] Tasks' rail draws the same pill (`BotPillRail`).
struct SessionPill<Face: View>: View {
    var caption: String
    var name: String
    var picked: Bool
    var identifier: String
    var hasFace = false
    /// [sessions-fresh] The room before a small mark (a status chip's), in place of the face's.
    var lead: CGFloat? = nil
    /// [tasks-first] A quiet count after the caption ("Today 6"), in the caption's ink at two-thirds strength.
    var detail: String? = nil
    var action: () -> Void
    @ViewBuilder var face: () -> Face

    /// [density] UI Scale in the iOS look too, but not Compact: the pills are controls, kept easy to tap and read beside
    /// the bar's buttons, and shrinking their one row saved about 6 pt (owner 2026-11-09).
    static var faceSize: CGFloat { Theme.isDesktop ? HQFont.scaled(20) : HQFont.scaled(24) }
    private var height: CGFloat { Theme.isDesktop ? HQFont.scaled(28) : HQFont.scaled(34) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if hasFace { face() }
                Text(caption)
                    .font(Font.hq(Theme.isDesktop ? .footnote : .subheadline).weight(.medium))
                    .foregroundStyle(picked ? Color.hqOnTint : Color.hqLabel)
                    .lineLimit(1)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                if let detail {
                    Text(detail)
                        .font(Font.hq(Theme.isDesktop ? .footnote : .subheadline)).monospacedDigit()
                        .foregroundStyle((picked ? Color.hqOnTint : Color.hqLabel).opacity(0.65))
                        .lineLimit(1)
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                        .padding(.leading, -1)
                }
            }
            .padding(.leading, lead ?? (hasFace ? (height - Self.faceSize) / 2 : 14))
            .padding(.trailing, hasFace ? 12 : 14)
            .padding(.vertical, 4)                      // large text grows the pill, never touching its edge
            .frame(minHeight: height)
            .background {
                if Theme.isDesktop {
                    RoundedRectangle(cornerRadius: DesktopRows.radius, style: .continuous).fill(picked ? Color.hqTint : Color.hqFill3)
                }
            }
            // Owner 2026-11-01: the rows scroll under the rail (the bar is clear), so in the iOS look each pill is glass,
            // as the bar's buttons beside it are: a row passing under it is blurred, never read through a grey fill.
            .hqPickGlass(picked, in: Capsule(), prominent: true)
            // The touch reaches 44 pt tall around the 34 pt pill.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(HQMotion.reduced ? nil : .snappy(duration: 0.2), value: picked)
        .accessibilityLabel(name)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

/// [sessions-fresh] A status chip's mark: New's dot, Working's still quarter ring (still: the rail draws no motion).
private struct StatusChipMark: View {
    var chip: SessionStatusChip
    var picked: Bool

    var body: some View {
        let ink = picked ? Color.hqOnTint : Color.hqLabel
        switch chip {
        case .new:
            Circle().fill(picked ? Color.hqOnTint : Color.hqTint).frame(width: 8, height: 8)
        case .working:
            ZStack {
                Circle().stroke(ink.opacity(0.25), lineWidth: 2)
                Circle().trim(from: 0, to: 0.25).stroke(ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .frame(width: 12, height: 12)
        }
    }
}

/// The list's empty state when the filters (or a chip) leave nothing (§6.3).
/// A chip alone (`bot`, its name) says the bot has no chats yet and offers New Chat with it; Clear Filters still clears
/// the chip.
struct SessionsNoMatchView: View {
    var bot: String? = nil
    var compose: (() -> Void)? = nil
    var clear: () -> Void

    var body: some View {
        ContentUnavailableView {
            if let bot {
                Label("\(bot) Has No Chats Yet", systemImage: "bubble.left.and.bubble.right")
            } else {
                Label("No Matching Chats", systemImage: "line.3.horizontal.decrease.circle")
            }
        } description: {
            if let bot {
                Text("New chats you start with \(bot) appear here.")
            } else {
                Text("No chats match these filters.")
            }
        } actions: {
            if bot != nil, let compose {
                Button("New Chat", action: compose)
                    .hqGlassButtonStyle()
                    .accessibilityIdentifier("sessions.empty.compose")
            }
            Button("Clear Filters", action: clear)
                .hqGlassButtonStyle()
                .accessibilityIdentifier("sessions.empty.clear")
        }
    }
}

// MARK: - Item 20: a short fade where a horizontally scrolling chip row has more past the edge

/// Which edges currently have more content past them (so the fade only shows there).
private struct ScrollEdgeFadeState: Equatable {
    var leading = false
    var trailing = false
}

private struct ScrollEdgeFade: ViewModifier {
    var width: CGFloat = 20
    @State private var state = ScrollEdgeFadeState()

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: ScrollEdgeFadeState.self) { geometry in
                ScrollEdgeFadeState(
                    leading: geometry.contentOffset.x > geometry.contentInsets.leading + 0.5,
                    trailing: geometry.contentOffset.x < geometry.contentSize.width - geometry.containerSize.width - geometry.contentInsets.trailing - 0.5)
            } action: { _, next in state = next }
            .mask(alignment: .leading) {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: state.leading ? width : 0)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: state.trailing ? width : 0)
                }
            }
    }
}

extension View {
    /// A chip row cut off flat at the screen edge read as clipping, not more to scroll to (item 20): a short fade on
    /// the trailing edge while more chips lie off screen, and on the leading edge once scrolled.
    func hqScrollEdgeFade(width: CGFloat = 20) -> some View { modifier(ScrollEdgeFade(width: width)) }
}

/// [mac] Stress test 2026-10-28 round 7: a clamped chip rail comes to rest on a chip, so its leading chip sits at the
/// rail's side room and its last shown chip is whole. `step` 0: free scrolling, as before.
struct ChipPaging: ScrollTargetBehavior {
    var step: CGFloat

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard step > 0 else { return }
        let most = max(0, context.contentSize.width - context.containerSize.width)
        target.rect.origin.x = min(most, max(0, (target.rect.origin.x / step).rounded() * step))
    }
}
