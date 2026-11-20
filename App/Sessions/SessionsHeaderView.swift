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
    /// [project-pills] The pills are the bots or the projects (Filter › Pills); the project pills, in order, and the
    /// lit one(s) (Filter › Project's picks).
    var pills: SessionPills = .bots
    var projects: [SessionProjectPill] = []
    var pickedProjects: Set<String> = []
    /// [project-pills] A bot picked another way (Filter › All Bots off) keeps All from lighting.
    var botPicked = false
    /// [mac-top] The Mac shows a project's page: its header carries the counts, so the row under the bar leaves them out.
    var onPage = false
    /// [mac-scope-menu] Each bot's New and Working counts, for its row in the Mac's menu.
    var botCounts: [String: [SessionStatusChip: Int]] = [:]
    /// [mac-scope-menu] A bot's face (its photo as a circle, or its head): profile, side, dark, scale.
    @ObservationIgnored var face: (String, CGFloat, Bool, CGFloat) -> UIImage? = { _, _, _, _ in nil }
    @ObservationIgnored var onPick: (String?) -> Void = { _ in }
    @ObservationIgnored var onPickProject: (String?) -> Void = { _ in }
    /// [project-pills] A project pill's hold: Archive Project / Unarchive Project.
    @ObservationIgnored var onArchiveProject: (String, Bool) -> Void = { _, _ in }
    /// [pill-reorder] VoiceOver's Move Before / Move After: this project onto that one, among the pills shown.
    @ObservationIgnored var onMoveProject: (String, String, [String]) -> Void = { _, _, _ in }
    /// [pill-reorder] A dragged pill let go: the pills shown, in their new order.
    @ObservationIgnored var onOrderProjects: ([String]) -> Void = { _ in }

    /// [project-pills] The project pills drawn: a status pill (New, Working) keeps the projects it stands for (and the
    /// picked one, so it can be tapped off).
    var shownProjects: [SessionProjectPill] {
        guard let status else { return projects }
        return projects.filter { $0.matches(status) || pickedProjects.contains($0.key) }
    }
    @ObservationIgnored var onPickStatus: (SessionStatusChip?) -> Void = { _ in }
    /// All: every bot and no status chip.
    @ObservationIgnored var onPickAll: () -> Void = {}
    @ObservationIgnored var onClearStrip: () -> Void = {}

    /// The status chips drawn, in order.
    var shownStatus: [SessionStatusChip] {
        SessionStatusChip.allCases.filter { (statusChips[$0] ?? 0) > 0 || status == $0 }
    }

    var isEmpty: Bool { !hasRail && strip == nil }
    /// The rail shows with a second bot, a status chip, or the Bots | Projects switch. [mac-switch] Owner 2026-11-17
    /// (picked "B" of three drawings): on the Mac too, the iPhone's own row under the bar (it had an "All Bots ⌄" pop-up).
    var hasRail: Bool { hasPills || !shownStatus.isEmpty || showsSwitch }
    /// [projects-switch] Owner 2026-11-15: the project view was three taps into Filter. With projects to show, the rail
    /// starts with a Bots | Projects switch (one tap; Group By follows it).
    var showsSwitch = false
    @ObservationIgnored var onSwitch: (SessionPills) -> Void = { _ in }
    /// [project-pills] A bot pill or a project pill to draw.
    var hasPills: Bool { pills == .projects ? !projects.isEmpty : !bots.isEmpty }
    /// The lit project pill's scroll id (the first picked, in the pills' order).
    var pickedProjectId: String? {
        projects.first { pickedProjects.contains($0.key) }.map { SessionsHeaderModel.projectPillId($0.key) }
    }
    static func projectPillId(_ key: String) -> String { "project:" + key }
}

struct SessionsHeaderView: View {
    var model: SessionsHeaderModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var scopeHover = Self.debugHover
    /// `-HQDebugScopeHover YES` draws the menu button as under the pointer, for a picture.
    private static var debugHover: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "HQDebugScopeHover")
        #else
        false
        #endif
    }
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
    /// [pill-reorder] The project rail's scroll, for a dragged pill that reaches an end of it.
    @State private var pillScroll = PillRailScroll()
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
        .background(Color(uiColor: DesktopPillBand.color))   // [desktop-hard-edge] the hard band shows through on the iPhone
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.strip)
    }

    @ViewBuilder private var rail: some View {
        if DeviceWord.isMac { macRow } else { pillRail }
    }

    /// [mac-pane] Owner 2026-11-18: the Mac's list keeps the iPhone's order and words, but not its controls ("where we
    /// have the pills that you can scroll over that works very well on an iPhone I don't know if that's best practice on
    /// a Mac app"; he took the drawing with the menu). The row under the bar is the Bots | Projects switch, the view's
    /// "All Bots" / "All Projects" menu, and New and Working as counts at its end: nothing scrolls sideways or is cut at
    /// the pane's edge. It reverses his 2026-11-17 pick of the iPhone's pill row for the Mac ([mac-switch]).
    private var macRow: some View {
        // [mac-top] Owner 2026-11-19 (a screenshot of a project's page: "the top section feels so messy", then "I just
        // want to redo what we have to be better suited"): the same three things in the same places, drawn as one set of
        // Mac controls: one height, one corner, one type size, their left edge on the rows' text. In a narrow pane the
        // row had run past both edges (the switch cut at the left, the menu down to its arrows, "1 new" cut at the right);
        // the menu's name now gives way first and keeps its room ahead of the counts. On a project's page the counts are
        // the header's (that project's, and they narrow it), so the row doesn't say them a second time.
        // A pane too narrow for it all says the counts as a mark and a number ("● 5"), then the switch's words without
        // its glyphs, before the menu's name is cut. The switch always says its two views' names (owner 2026-11-19: "The
        // toggle should have Bots and Projects written in it just like it has on iOS"; Chats and Projects since
        // [chats-switch]).
        ViewThatFits(in: .horizontal) {
            macRowContent(switchIcons: true, countWords: true)
            macRowContent(switchIcons: true, countWords: false)
            macRowContent(switchIcons: false, countWords: false)
            macRowContent(switchIcons: false, countWords: false, menuPicture: false)   // [mac-scope-button] words over faces
        }
        .frame(height: SessionsMacControl.height)
        .padding(.leading, Theme.isDesktop ? DesktopRows.gutter : ProjectCard.lead)   // the project header's edge
        .padding(.trailing, (Theme.isDesktop ? DesktopRows.gutter : ProjectCard.lead) - 6)   // a count's text ends where the rows' times do (its 6 pt padding)
        .padding(.top, Theme.isDesktop ? 6 : 4)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func macRowContent(switchIcons: Bool, countWords: Bool, menuPicture: Bool = true) -> some View {
        HStack(spacing: countWords ? 8 : 6) {
            if model.showsSwitch { SessionsPillsSwitch(model: model, macIcons: switchIcons).fixedSize() }
            if model.hasPills { scopeMenu(picture: menuPicture).layoutPriority(1) }
            Spacer(minLength: 0)
            if !model.onPage {
                ForEach(model.shownStatus, id: \.self) { chip in macStatus(chip, words: countWords) }
            }
        }
    }

    /// New's or Working's count ("5 new"): a click narrows the list to those chats, another brings every chat back.
    private func macStatus(_ chip: SessionStatusChip, words: Bool = true) -> some View {
        let count = model.statusChips[chip] ?? 0
        let word = chip == .new ? "new" : "working"
        let picked = model.status == chip
        return Button { model.onPickStatus(picked ? nil : chip) } label: {
            HStack(spacing: 5) {
                StatusChipMark(chip: chip, picked: false)
                Text(words ? "\(count) \(word)" : "\(count)").lineLimit(1)
            }
            .font(Font.hq(.footnote).weight(picked ? .semibold : .regular))
            .foregroundStyle(picked ? Color.hqLabel : Color.hqLabel2)
            .padding(.horizontal, words ? 6 : 4)
            .frame(height: SessionsMacControl.height)
            .background(picked ? Color.hqFill3 : Color.clear, in: RoundedRectangle(cornerRadius: SessionsMacControl.radius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(chip == .new ? "Chats with a reply you haven’t read" : "Chats a bot is working in")
        .accessibilityLabel("\(chip == .new ? "New" : "Working"), \(count) \(count == 1 ? "chat" : "chats")")
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityIdentifier("sessions.chip.status.\(chip.rawValue)")
    }

    /// The view's choices: every bot or one, every project or one (a project opens its page).
    /// [mac-scope-menu] Owner 2026-11-19: "The all bots drop down needs to be better." The button shows the picked bot's
    /// face (a project's folder) before its name, and the menu is a UIKit menu (`SessionsHeaderModel.scopeMenuElements`)
    /// so each row can carry the bot's face and what is going on there ("2 working · 1 new"), archived projects
    /// folded into a submenu. It had been names alone in a SwiftUI picker.
    private func scopeMenu(picture: Bool) -> some View {
        let projects = model.pills == .projects
        let pickedProject = model.projects.first { model.pickedProjects.contains($0.key) }
        let title = projects ? (model.pickedProjects.count == 1 ? pickedProject?.label ?? "All Projects" : "All Projects")
            : model.picked.flatMap { id in model.bots.first { $0.id == id }?.name } ?? "All Bots"
        let side = HQFont.scaled(15)
        // [mac-scope-button] Owner 2026-11-19 ("And the button to open that drop down?"): it was a grey box like the
        // switch beside it, so it read as the switch's third side. It is a Mac pop-up button now: an outline on the page
        // (the switch is the filled control), a picture before the words (the first bots' faces overlapping for All
        // Bots, the picked bot's face, a folder for projects), a downward chevron, and a fill under the pointer.
        return HStack(spacing: 6) {
            if picture { scopePicture(projects: projects, side: side) }
            Text(title).lineLimit(1).truncationMode(.tail)
            Image(systemName: "chevron.down").font(Font.hqSystem(size: HQFont.scaled(9), weight: .bold))
                .foregroundStyle(Color.hqLabel2)
                .fixedSize()
        }
        .font(SessionsMacControl.font)
        .foregroundStyle(Color.hqLabel)
        .padding(.leading, picture ? 5 : 8).padding(.trailing, 8)
        .frame(minWidth: 64, maxHeight: SessionsMacControl.height)   // [mac-top] never just its arrows
        .background {
            let shape = RoundedRectangle(cornerRadius: SessionsMacControl.radius, style: .continuous)
            shape.fill(scopeHover ? Color.hqLabel.opacity(0.16) : Color.clear)
                .overlay { shape.strokeBorder(Color.hqStroke, lineWidth: 1) }
        }
        .fixedSize(horizontal: false, vertical: true)   // a long project's name is cut, not the counts after it
        .accessibilityHidden(true)
        .overlay {
            SessionsScopeMenuButton(model: model, title: title) { scopeHover = $0 }
        }
    }

    /// [mac-scope-button] The picture before the menu's words.
    @ViewBuilder private func scopePicture(projects: Bool, side: CGFloat) -> some View {
        let dark = colorScheme == .dark
        if projects {
            Image(systemName: model.pickedProjects.count == 1 ? "folder" : "square.stack")
                .font(Font.hqSystem(size: HQFont.scaled(11), weight: .medium))
                .foregroundStyle(Color.hqLabel2)
                .frame(width: side, height: side)
        } else if let id = model.picked, let face = model.face(id, side, dark, displayScale) {
            Image(uiImage: face).resizable().frame(width: side, height: side)
        } else {
            // All Bots: the first three faces, each overlapping the one before it by half, ringed in the page colour.
            let faces = model.bots.prefix(3).compactMap { model.face($0.id, side, dark, displayScale) }
            HStack(spacing: -side * 0.45) {
                ForEach(Array(faces.enumerated()), id: \.offset) { index, face in
                    Image(uiImage: face).resizable().frame(width: side, height: side)
                        .padding(1)
                        .background(Circle().fill(Color.hqPage))
                        .zIndex(Double(faces.count - index))
                }
            }
        }
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
    @ViewBuilder private var pillRail: some View {
        if model.pills == .projects { projectRail } else { botRail }
    }

    /// [projects-switch] The switch at the rail's start: the two views side by side in one capsule (owner 2026-11-15
    /// on 1039's single round button: "needs to be more clear that it's a toggle between two views"). The robot is
    /// the tab bar's Bots glyph and the folder the project pills' own (owner: "They need to match what we use in the
    /// menu"). The side of the view drawn is the tint while nothing is picked, a soft grey while a pill is.
    /// [switch-toggles] Owner 2026-11-17: "Why can't the toggle toggle when you click it anywhere?" A tap anywhere on it
    /// flips the view. The side drawn had also been All (a tap on it cleared a picked pill and otherwise did nothing,
    /// so the switch seemed to ignore the tap); the lit pill clears itself with a tap, as it always has.
    /// [switch-scrolls] Owner 2026-11-17: it scrolls with the pills, as the row's first item ("I want for this to scroll
    /// with everything else in this row"; on 2026-11-16 he had turned down a fixed switch with words). [switch-words]
    /// Then: each side carries its name beside its glyph (`switchSide`).
    @ViewBuilder private func pillsSwitch(allPicked: Bool) -> some View {
        if model.showsSwitch {
            SessionsPillsSwitch(model: model).id("sessions.chip.all")
        }
    }

    private var botRail: some View {
        BotPillRail(bots: model.bots, picked: model.picked, allPicked: model.picked == nil && model.status == nil,
                    identifier: "sessions.chip", leading: AnyView(pillsSwitch(allPicked: model.picked == nil && model.status == nil)),
                    showsAll: !model.showsSwitch, onPick: model.onPick, onPickAll: model.onPickAll) {
            // [sessions-fresh] New and Working, then a rule before the bots.
            statusPills
            // [projects-switch] With the switch the status pills are a mark and a count, told apart from the faces
            // after them without a rule (and the rail is no wider than it was before the switch).
            if !model.shownStatus.isEmpty, !model.bots.isEmpty, !model.showsSwitch { railRule }
        }
    }

    @ViewBuilder private var statusPills: some View {
        ForEach(model.shownStatus, id: \.self) { chip in
            let count = model.statusChips[chip] ?? 0
            let word = chip == .new ? "New" : "Working"
            // [projects-switch] Its mark and count alone ("3"), so more bots or projects fit; VoiceOver still says the
            // word. With the switch at the rail's start the worded pills pushed a third bot off an iPhone's screen; without
            // the switch (no projects yet) they keep their words.
            SessionPill(caption: model.showsSwitch ? "\(count)" : "\(word) \(count)",
                        name: "\(word), \(count) \(count == 1 ? "chat" : "chats")",
                        picked: model.status == chip, identifier: "sessions.chip.status.\(chip.rawValue)",
                        hasFace: true, lead: 12) {
                model.onPickStatus(model.status == chip ? nil : chip)
            } face: {
                StatusChipMark(chip: chip, picked: model.status == chip)
            }
            .id("status-\(chip.rawValue)")
        }
    }

    /// [project-pills] Owner 2026-11-15: the same row with the projects as its pills: All, New and Working, then each
    /// project (a folder before its name). A tap picks that project alone (Filter › Project); the lit pill goes back to
    /// All. New and Working count that project's chats.
    private var projectRail: some View {
        BotPillRail(bots: [], picked: model.pickedProjectId,
                    allPicked: model.pickedProjects.isEmpty && model.status == nil && !model.botPicked,
                    identifier: "sessions.chip", label: "Projects",
                    leading: AnyView(pillsSwitch(allPicked: model.pickedProjects.isEmpty && model.status == nil && !model.botPicked)),
                    showsAll: !model.showsSwitch, scroll: pillScroll, onPick: { _ in },
                    onPickAll: model.onPickAll) {
            statusPills
            if !model.shownStatus.isEmpty, !model.shownProjects.isEmpty { railRule }
            // [pill-reorder] The pills themselves, and the hold that rearranges them (`ProjectPillRun`).
            ProjectPillRun(model: model, scroll: pillScroll)
        }
    }

    private var railRule: some View {
        HQHairline(axis: .vertical, length: 22)
            .accessibilityHidden(true)
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
                    if reduceMotion { position.scrollTo(x: x) } else { withAnimation(.easeInOut(duration: HQMotion.pane)) { position.scrollTo(x: x) } }
                    return
                }
                if reduceMotion {
                    proxy.scrollTo(picked ?? Self.allId, anchor: .center)
                } else {
                    withAnimation(.easeInOut(duration: HQMotion.pane)) { proxy.scrollTo(picked ?? Self.allId, anchor: .center) }
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
            if reduceMotion { position.scrollTo(x: target) } else { withAnimation(.easeInOut(duration: HQMotion.pane)) { position.scrollTo(x: target) } }
        } label: {
            Image(systemName: forward ? "chevron.forward" : "chevron.backward")
                .font(Font.hq(.footnote).weight(.semibold))
                .foregroundStyle(Color.hqLabel2)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.hqPage))
                .overlay(Circle().strokeBorder(Color.hqStroke, lineWidth: HQShape.hairline))
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
                    .font(Font.hq(.caption2).weight(picked && !DeviceWord.isMac ? .semibold : .regular))   // [type] Mac: the ring shows the pick
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
    /// [pill-reorder] A pill that can be held and dragged (`ProjectPillRun`), and whether it is lifted now: its run
    /// draws the lift, so its glass stays still under the finger and its words keep their ink while it is carried.
    var lifted: Bool? = nil
    var action: () -> Void
    @ViewBuilder var face: () -> Face

    /// [density] UI Scale in the iOS look too, but not Compact: the pills are controls, kept easy to tap and read beside
    /// the bar's buttons, and shrinking their one row saved about 6 pt (owner 2026-11-09).
    static var faceSize: CGFloat { Theme.isDesktop ? HQFont.scaled(20) : HQFont.scaled(24) }
    /// The pill's own height (its touch reaches 44 pt).
    static var height: CGFloat { Theme.isDesktop ? HQFont.scaled(28) : HQFont.scaled(34) }
    private var height: CGFloat { Self.height }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if hasFace { face() }
                Text(caption)
                    .font(Font.hq(Theme.isDesktop ? .footnote : .subheadline).weight(.medium))
                    .foregroundStyle(picked ? Theme.pickedPillInk : Color.hqLabel)
                    .lineLimit(1)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                if let detail {
                    Text(detail)
                        .font(Font.hq(Theme.isDesktop ? .footnote : .subheadline)).monospacedDigit()
                        .foregroundStyle((picked ? Theme.pickedPillInk : Color.hqLabel).opacity(0.65))
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
            .hqPickGlass(picked, in: Capsule(), prominent: true, still: lifted != nil)
            // The touch reaches 44 pt tall around the 34 pt pill.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .modifier(PillPress(carried: lifted))
        .animation(HQMotion.reduced ? nil : .snappy(duration: 0.2), value: picked)
        .accessibilityLabel(name)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

/// A pill's press: the plain style, but a pill that can be carried keeps its words' ink while it is ([pill-reorder]).
private struct PillPress: ViewModifier {
    /// nil: a pill that is never carried.
    var carried: Bool?

    func body(content: Content) -> some View {
        if let carried { content.buttonStyle(Carried(carried: carried)) } else { content.buttonStyle(.plain) }
    }

    private struct Carried: ButtonStyle {
        var carried: Bool
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.opacity(configuration.isPressed && !carried ? 0.55 : 1)
        }
    }
}

/// [sessions-fresh] A status chip's mark: New's dot, Working's still quarter ring (still: the rail draws no motion).
struct StatusChipMark: View {
    var chip: SessionStatusChip
    var picked: Bool

    var body: some View {
        let ink = picked ? Theme.pickedPillInk : Color.hqLabel
        switch chip {
        case .new:
            Circle().fill(picked ? Theme.pickedPillInk : Color.hqTint).frame(width: 8, height: 8)
        case .working:
            ZStack {
                Circle().stroke(ink.opacity(0.25), lineWidth: 2)
                Circle().trim(from: 0, to: 0.25).stroke(ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .frame(width: 12, height: 12)
        }
    }
}

/// [project-pills] A project pill's mark: what its chats are doing. Needs You an orange dot, Ready the tint's dot,
/// Working the still quarter ring (the rail draws no motion), quiet a folder; archived an archive box.
struct ProjectPillMark: View {
    var state: SessionProjectState
    var archived: Bool
    var picked: Bool

    var body: some View {
        let ink = picked ? Color.hqOnTint : Color.hqLabel
        Group {
            if archived {
                Image(systemName: "archivebox").font(Font.hqSystem(size: HQFont.scaled(13), weight: .medium)).foregroundStyle(ink.opacity(0.7))
            } else {
                switch state {
                case .needsYou: Circle().fill(picked ? Color.hqOnTint : Color.hqOrange).frame(width: 8, height: 8)
                case .ready: Circle().fill(picked ? Color.hqOnTint : Color.hqTint).frame(width: 8, height: 8)
                case .working: StatusChipMark(chip: .working, picked: picked)
                case .quiet:
                    Image(systemName: picked ? "folder.fill" : "folder")
                        .font(Font.hqSystem(size: HQFont.scaled(14), weight: .medium))
                        .foregroundStyle(picked ? Color.hqOnTint : Color.hqLabel2)
                }
            }
        }
        .frame(minWidth: 14)
        .accessibilityHidden(true)
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

/// [projects-switch] The Bots | Projects switch: the pill rail's first item (iPhone, iPad and, since 2026-11-17, the Mac).
/// [mac-scope-menu] The Mac's "All Bots" / "All Projects" menu: a clear button over the drawn one, opening a UIKit
/// menu built when it opens (faces, subtitles and the submenu SwiftUI's picker could not draw).
struct SessionsScopeMenuButton: UIViewRepresentable {
    var model: SessionsHeaderModel
    var title: String
    /// The pointer came over the button, or left it.
    var onHover: (Bool) -> Void = { _ in }

    final class Coordinator: NSObject {
        var onHover: (Bool) -> Void = { _ in }
        @objc func hovered(_ hover: UIHoverGestureRecognizer) {
            switch hover.state {
            case .began, .changed: onHover(true)
            default: onHover(false)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityIdentifier = "pages.scope"
        button.addGestureRecognizer(UIHoverGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hovered)))
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.onHover = onHover
        let model = model
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak button] done in
            let traits = button?.traitCollection ?? .current
            done(model.scopeMenuElements(dark: traits.userInterfaceStyle == .dark, scale: traits.displayScale))
        }])
        button.accessibilityLabel = title
        button.accessibilityHint = model.pills == .projects ? "Picks a project" : "Picks a bot"
        #if targetEnvironment(macCatalyst)
        button.toolTip = title
        #endif
    }
}

extension SessionsHeaderModel {
    /// "2 working · 1 new"; nil when nothing is going on.
    nonisolated static func countWords(_ counts: [SessionStatusChip: Int]) -> String? {
        var parts: [String] = []
        if let working = counts[.working], working > 0 { parts.append("\(working) working") }
        if let new = counts[.new], new > 0 { parts.append("\(new) new") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A project's row: what its bots are doing there ("Needs you · Working"); nil when quiet.
    nonisolated static func projectWords(_ project: SessionProjectPill) -> String? {
        var parts: [String] = []
        if project.states.contains(.needsYou) { parts.append("Needs you") }
        if project.states.contains(.working) { parts.append("Working") }
        if project.states.contains(.ready) { parts.append("New") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The menu's rows: All, then each bot with its face and counts (or each project with its folder and states, the
    /// archived ones in a submenu). The picked one is checked.
    func scopeMenuElements(dark: Bool, scale: CGFloat) -> [UIMenuElement] {
        if pills == .projects {
            let one = pickedProjects.count == 1 ? pickedProjects.first : nil
            let all = UIAction(title: "All Projects", image: UIImage(systemName: "square.stack"), state: one == nil ? .on : .off) { [weak self] _ in self?.onPickProject(nil) }
            func row(_ project: SessionProjectPill) -> UIAction {
                let action = UIAction(title: project.label, image: UIImage(systemName: "folder"),
                                      state: one == project.key ? .on : .off) { [weak self] _ in self?.onPickProject(project.key) }
                action.subtitle = Self.projectWords(project)
                return action
            }
            let live = projects.filter { !$0.archived }.map(row)
            let archived = projects.filter(\.archived).map(row)
            var out: [UIMenuElement] = [all]
            if !live.isEmpty { out.append(UIMenu(options: .displayInline, children: live)) }
            if !archived.isEmpty {
                out.append(UIMenu(title: "Archived", image: UIImage(systemName: "archivebox"), children: archived))
            }
            return out
        }
        let all = UIAction(title: "All Bots", image: UIImage(systemName: "person.2"), state: picked == nil ? .on : .off) { [weak self] _ in
            self?.onPick(nil)
        }
        var total: [SessionStatusChip: Int] = [:]
        for counts in botCounts.values { for (chip, count) in counts { total[chip, default: 0] += count } }
        all.subtitle = Self.countWords(total)
        let rows: [UIMenuElement] = bots.map { bot in
            let image = face(bot.id, 18, dark, scale)?.withRenderingMode(.alwaysOriginal)
            let action = UIAction(title: bot.name, image: image, state: picked == bot.id ? .on : .off) { [weak self] _ in
                self?.onPick(bot.id)
            }
            action.subtitle = Self.countWords(botCounts[bot.id] ?? [:])
            return action
        }
        return [all, UIMenu(options: .displayInline, children: rows)]
    }

    /// A photo as a circle, as a face is drawn beside a name.
    static func circled(_ image: UIImage, side: CGFloat, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).addClip()
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
    }
}

/// [mac-top] The Mac row's controls share one height, corner and type size (the switch, the menu, the counts).
@MainActor enum SessionsMacControl {
    static var height: CGFloat { HQFont.scaled(24) }
    static let radius: CGFloat = 6
    static var font: Font { Font.hq(.footnote).weight(.medium) }
}

struct SessionsPillsSwitch: View {
    var model: SessionsHeaderModel
    /// [mac-top] The Mac's switch names its sides, with their glyphs; in a narrow pane, the names alone.
    var macIcons = true
    /// The side drawn is the tint while nothing is picked, a soft grey while a pill is.
    private var allPicked: Bool {
        model.pills == .projects ? model.pickedProjects.isEmpty && model.status == nil && !model.botPicked
            : model.picked == nil && model.status == nil
    }

    var body: some View {
        if DeviceWord.isMac { macBody } else { phoneBody }
    }

    /// [mac-top] Owner 2026-11-19: the Mac's switch is a segmented control of the menu's height and corner beside it (it
    /// was the iPhone's 44 pt glass capsule, a second style of control in one row). The view shown is a raised grey
    /// segment, never the tint; a click anywhere on it flips the view, as on the iPhone ([switch-toggles]).
    private var macBody: some View {
        let other: SessionPills = model.pills == .bots ? .projects : .bots
        let inner = SessionsMacControl.radius - 2
        return Button { model.onSwitch(other) } label: {
            HStack(spacing: 0) {
                ForEach([SessionPills.bots, .projects], id: \.self) { view in
                    let here = model.pills == view
                    HStack(spacing: 4) {
                        if macIcons {
                            Image(systemName: Self.symbol(view)).font(Font.hqSystem(size: HQFont.scaled(11), weight: .medium))
                        }
                        Text(Self.word(view)).lineLimit(1).fixedSize()
                    }
                    .font(SessionsMacControl.font)
                    .foregroundStyle(here ? Color.hqLabel : Color.hqLabel2)
                    .padding(.horizontal, macIcons ? 8 : 7)
                    .frame(maxHeight: .infinity)
                    .background {
                        if here { RoundedRectangle(cornerRadius: inner, style: .continuous).fill(Color.hqLabel.opacity(0.12)) }
                    }
                }
            }
            .padding(2)
            .frame(height: SessionsMacControl.height)
            .background(Color.hqFill3, in: RoundedRectangle(cornerRadius: SessionsMacControl.radius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show " + Self.word(other))
        .accessibilityLabel("Switch to " + Self.word(other))
        .accessibilityValue(Self.word(model.pills))
        .accessibilityIdentifier("sessions.pills.\(other.rawValue)")
    }

    private var phoneBody: some View {
        Group {
            let side: CGFloat = Theme.isDesktop ? HQFont.scaled(24) : HQFont.scaled(30)
            let half = side + 8
            // Each side's touch reaches this far past the capsule (into the rail's margin, and the gap before the
            // next pill), so it is 44 pt wide as every pill's is.
            let reach = max(0, 44 - half - 2)
            let touch: CGFloat = 44
            let views: [SessionPills] = [.bots, .projects]
            // The drawing: glyphs in the glass (the glass takes its content, as every pill's does).
            HStack(spacing: 0) {
                ForEach(views, id: \.self) { view in
                    let here = model.pills == view
                    switchSide(view, here: here, half: half, side: side)
                        // [switch-neutral] Owner 2026-11-18: "idk why the background to Projects is black?" With a
                        // pill lit, the view's side is a soft grey thumb (a segmented control's), not solid black.
                        .foregroundStyle(!here ? Color.hqLabel2 : allPicked ? Color.hqOnTint : Color.hqLabel)
                        // [switch-thumb] Owner 2026-11-19 (Desktop Look on the iPhone: "the pill showing which is
                        // selected doesn't look right"): the Desktop Look's track is a 4 pt-corner box, so the side shown
                        // is a box of its corner inset by the track's 2 pt, not a capsule rounding past the track's own corners.
                        .background {
                            if here {
                                thumbShape.fill(allPicked ? Color.hqTint : Color.hqLabel.opacity(0.12))
                            }
                        }
                }
            }
            .padding(2)
            .background {
                if Theme.isDesktop { RoundedRectangle(cornerRadius: DesktopRows.radius, style: .continuous).fill(Color.hqFill3) }
            }
            .hqPickGlass(false, in: Capsule(), prominent: true)
            .accessibilityHidden(true)
            .frame(height: touch)
            // The touch: one clear button over the whole switch, reaching past both ends of the capsule (its own drawing,
            // unseen, sizes it). VoiceOver: "Switch to Projects", and the view shown as its value.
            .overlay {
                let other: SessionPills = model.pills == .bots ? .projects : .bots
                Button {
                    model.onSwitch(other)
                } label: {
                    HStack(spacing: 0) {
                        ForEach(views, id: \.self) { view in
                            switchSide(view, here: model.pills == view, half: half, side: side).hidden()
                        }
                    }
                    .padding(2)
                    .padding(.horizontal, reach)
                    .frame(height: touch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Switch to " + Self.word(other))
                .accessibilityValue(Self.word(model.pills))
                .accessibilityIdentifier("sessions.pills.\(other.rawValue)")
                .fixedSize()
            }
        }
    }

    /// [chats-switch] A tester, 2026-11-20: the switch's left side is "Chats", told apart from the bots themselves (the
    /// Bots tab, a bot's own sessions), with the Sessions tab's chat bubbles for its glyph; it was "Bots" and the
    /// robot. The view's value is still `SessionPills.bots` and its button `sessions.pills.bots`; the rail of bot
    /// pills (and its All Bots) is still the bots'.
    static func word(_ view: SessionPills) -> String { view == .bots ? "Chats" : "Projects" }
    static func symbol(_ view: SessionPills) -> String { view == .bots ? "bubble.left.and.bubble.right" : "folder" }

    /// [switch-thumb] The side shown: concentric with the track (the Desktop Look's box, else the glass capsule).
    private var thumbShape: AnyShape {
        Theme.isDesktop ? AnyShape(RoundedRectangle(cornerRadius: max(2, DesktopRows.radius - 2), style: .continuous))
            : AnyShape(Capsule())
    }

    /// One side of the switch: its glyph and its name. [switch-words] Owner 2026-11-17: "I want the bots/projects
    /// toggle to show the words of each with the icons" (both sides named, now that the switch scrolls with the row).
    private func switchSide(_ view: SessionPills, here: Bool, half: CGFloat, side: CGFloat) -> some View {
        HStack(spacing: 5) {
            Image(systemName: Self.symbol(view)).font(Font.hqSystem(size: HQFont.scaled(13), weight: .medium))
            Text(Self.word(view))
                .font(Font.hq(Theme.isDesktop ? .footnote : .subheadline).weight(.medium))
                .lineLimit(1)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .fixedSize()
        }
        .padding(.horizontal, 11)
        .frame(minWidth: half, minHeight: side, maxHeight: side)
    }

}
