// [pill-reorder] Owner 2026-11-18, on build 1103's system drag and drop (the Archive menu came up first, the pill became
// a floating copy, nothing moved until it was dropped exactly on another pill): "this sucks". The project pills now
// rearrange as home-screen icons do. A hold lifts the pill where it is; moved, it follows the finger and the other
// pills slide out of its way as it passes them, the rail scrolling when the finger reaches an end; let go, it settles
// and the order is saved once. Held still (or let go without moving), Archive Project shows on that pill; a finger that
// then moves takes the pill along and the choice goes.

import SwiftUI
import UIKit

/// The rail's scroll, for a drag that reaches an end of it (`BotPillRail` fills it in).
@MainActor @Observable
final class PillRailScroll {
    var position = ScrollPosition()
    @ObservationIgnored var x: CGFloat = 0
    /// The furthest the rail scrolls.
    @ObservationIgnored var most: CGFloat = 0
    /// The rail on the screen.
    @ObservationIgnored var frame: CGRect = .zero
}

/// The hold that lifts a pill. A recognised hold takes the touch from the rail's scroll and from the pill's own tap.
private struct ProjectPillHold: UIGestureRecognizerRepresentable {
    /// The state, and the finger's x on the screen.
    var onChange: (UIGestureRecognizer.State, CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let hold = UILongPressGestureRecognizer()
        hold.minimumPressDuration = DeviceWord.isMac ? 0.2 : 0.3
        hold.allowableMovement = 10
        hold.delegate = context.coordinator
        return hold
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    /// The hold runs beside the pills' own taps (their gesture would otherwise keep it from starting), never beside
    /// the rail's scroll: once it is recognised the scroll gives way.
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            return !(other.view is UIScrollView)
        }
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        onChange(recognizer.state, context.converter.location(in: .global).x)
    }
}

/// The project pills, in one run inside the rail.
struct ProjectPillRun: View {
    var model: SessionsHeaderModel
    var scroll: PillRailScroll
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Drag: Equatable {
        var key: String
        /// The pills' keys as they stand while it is dragged.
        var order: [String]
        /// The finger on the screen, where it went down, and how far into the pill it took hold.
        var fingerX: CGFloat
        var startX: CGFloat
        var grab: CGFloat
        var moved = false
    }

    @State private var drag: Drag?
    /// The order just dropped, drawn until the list's own order says the same.
    @State private var settled: [String]?
    @State private var widths: [String: CGFloat] = [:]
    /// The run's start on the screen (it moves as the rail scrolls).
    @State private var originX: CGFloat = 0
    /// The pill whose Archive choice is up.
    @State private var menuFor: String?
    @State private var stillHold: Task<Void, Never>?
    @State private var front: String?
    /// The pill's own tap is recognised beside the hold: it does nothing from a hold's start until just after its end.
    @State private var noTapUntil = Date.distantPast

    /// The rail's own room between pills (`BotPillRail`).
    private static let gap: CGFloat = 8
    private static let spring = Animation.spring(response: 0.3, dampingFraction: 0.82)

    private var shown: [SessionProjectPill] {
        let base = model.shownProjects
        guard let order = drag?.order ?? settled, order.count == base.count else { return base }
        var byKey: [String: SessionProjectPill] = [:]
        for project in base { byKey[project.key] = project }
        let drawn = order.compactMap { byKey[$0] }
        return drawn.count == base.count ? drawn : base
    }

    var body: some View {
        let shown = shown
        HStack(spacing: Self.gap) {
            ForEach(Array(shown.enumerated()), id: \.element.key) { index, project in
                pill(index, project, among: shown)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: {
            originX = $0
            reorder()   // the rail scrolled under a still finger
        }
        .gesture(ProjectPillHold { state, x in hold(state, x) })
        .task(id: drag?.key) { await scrollAtTheEnds() }
        .onChange(of: model.projects) { settled = nil }
    }

    @ViewBuilder private func pill(_ index: Int, _ project: SessionProjectPill, among shown: [SessionProjectPill]) -> some View {
        let picked = model.pickedProjects.contains(project.key)
        let lifted = drag?.key == project.key
        let spoken = [project.label + " project", project.state.spoken, project.archived ? "Archived" : nil]
            .compactMap { $0 }.joined(separator: ", ")
        let archive = project.archived ? "Unarchive Project" : "Archive Project"
        SessionPill(caption: project.label, name: spoken, picked: picked,
                    identifier: "sessions.chip.project.\(index)", hasFace: true, lead: 12, lifted: lifted) {
            if Date() >= noTapUntil { model.onPickProject(picked ? nil : project.key) }
        } face: {
            ProjectPillMark(state: project.state, archived: project.archived, picked: picked,
                            look: model.projectLooks[project.key] ?? ProjectLook())   // [project-look]
        }
        .opacity(project.archived && !picked ? 0.6 : 1)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths[project.key] = $0 }
        .accessibilityAction(named: "Icon & Color…") { model.onLookProject(project.key, project.label) }
        .accessibilityAction(named: "Project Settings…") { model.onSettingsProject(project.key, project.label) }
        .accessibilityAction(named: archive) { model.onArchiveProject(project.key, !project.archived) }
        .accessibilityActions {
            if index > 0 {
                Button("Move Before") { model.onMoveProject(project.key, shown[index - 1].key, shown.map(\.key)) }
            }
            if index < shown.count - 1 {
                Button("Move After") { model.onMoveProject(project.key, shown[index + 1].key, shown.map(\.key)) }
            }
        }
        .modifier(MacProjectPillMenu(
            archiveTitle: archive, archived: project.archived,
            onLook: { model.onLookProject(project.key, project.label) },
            onSettings: { model.onSettingsProject(project.key, project.label) },
            onArchive: { model.onArchiveProject(project.key, !project.archived) }))
        .popover(isPresented: Binding(get: { menuFor == project.key },
                                      set: { if !$0, menuFor == project.key { menuFor = nil } }),
                 attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                popoverItem("Icon & Color…", symbol: "paintbrush", id: "sessions.chip.project.look") {
                    menuFor = nil
                    model.onLookProject(project.key, project.label)
                }
                Divider()
                popoverItem("Project Settings…", symbol: "gearshape", id: "sessions.chip.project.settings") {
                    menuFor = nil
                    model.onSettingsProject(project.key, project.label)
                }
                Divider()
                popoverItem(archive, symbol: project.archived ? "tray.and.arrow.up" : "archivebox", id: "sessions.chip.project.archive") {
                    menuFor = nil
                    model.onArchiveProject(project.key, !project.archived)
                }
            }
            .fixedSize(horizontal: true, vertical: true)
            .presentationCompactAdaptation(.popover)
        }
        // Carried, the pill is not read through: the pills it passes over don't show in its glass.
        .background {
            Capsule().fill(Color(uiColor: HQPalette.card)).frame(height: SessionPill<EmptyView>.height)
                .opacity(lifted && !Theme.isDesktop ? 1 : 0)
        }
        .scaleEffect(lifted && !reduceMotion ? 1.08 : 1)
        .shadow(color: .black.opacity(lifted ? 0.22 : 0), radius: 10, y: 4)
        .animation(reduceMotion ? nil : Self.spring, value: lifted)
        .offset(x: lift(project.key))
        // The pill last carried stays in front: put back behind as it was let go, its glass was drawn afresh (it folded
        // up and came back).
        .zIndex(front == project.key ? 1 : 0)
        // The lifted pill stays under the finger: its place in the row and its offset change together, unanimated.
        .transaction { if lifted { $0.animation = nil } }
        .id(SessionsHeaderModel.projectPillId(project.key))
    }

    private func popoverItem(_ title: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(Font.hq(.body))
                .foregroundStyle(Color.hqLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    // MARK: Places

    private func start(of key: String, in order: [String]) -> CGFloat {
        var x: CGFloat = 0
        for other in order {
            if other == key { return x }
            x += (widths[other] ?? 0) + Self.gap
        }
        return x
    }

    private func length(_ order: [String]) -> CGFloat {
        order.reduce(-Self.gap) { $0 + (widths[$1] ?? 0) + Self.gap }
    }

    /// Where the lifted pill's leading edge is wanted, in the run: under the finger, never past the run's ends.
    private func wanted(_ drag: Drag) -> CGFloat {
        let most = max(0, length(drag.order) - (widths[drag.key] ?? 0))
        return min(most, max(0, drag.fingerX - originX - drag.grab))
    }

    /// How far the lifted pill is drawn from its place in the row.
    private func lift(_ key: String) -> CGFloat {
        guard let drag, drag.key == key else { return 0 }
        return wanted(drag) - start(of: key, in: drag.order)
    }

    private func key(at x: CGFloat, in order: [String]) -> String? {
        var from: CGFloat = 0
        for key in order {
            let width = widths[key] ?? 0
            if x >= from - Self.gap / 2, x <= from + width + Self.gap / 2 { return key }
            from += width + Self.gap
        }
        return nil
    }

    // MARK: The hold

    private func hold(_ state: UIGestureRecognizer.State, _ x: CGFloat) {
        switch state {
        case .began:
            let order = shown.map(\.key)
            guard let key = key(at: x - originX, in: order) else { return }
            stillHold?.cancel()
            noTapUntil = .distantFuture
            front = key
            menuFor = nil
            settled = nil
            drag = Drag(key: key, order: order, fingerX: x, startX: x, grab: x - originX - start(of: key, in: order))
            Haptics.play(.medium)
            Haptics.prepare(.selection)
            // Still held, still in place: the pill's choice.
            stillHold = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, let drag, drag.key == key, !drag.moved else { return }
                menuFor = key
            }
        case .changed:
            guard var now = drag else { return }
            now.fingerX = x
            if !now.moved, abs(x - now.startX) > 8 {
                now.moved = true
                stillHold?.cancel()
                menuFor = nil
            }
            drag = now
            reorder()
        case .ended:
            noTapUntil = Date().addingTimeInterval(0.35)
            guard let now = drag else { return }
            stillHold?.cancel()
            if now.moved {
                drop(now)
            } else {
                menuFor = now.key
                settle { drag = nil }
            }
        default:
            noTapUntil = Date().addingTimeInterval(0.35)
            stillHold?.cancel()
            settle { drag = nil }
        }
    }

    /// The other pills step aside as the lifted one's edge passes their middle.
    private func reorder() {
        guard var now = drag, now.moved else { return }
        let leading = wanted(now), trailing = leading + (widths[now.key] ?? 0)
        var order = now.order
        for _ in order {
            guard let index = order.firstIndex(of: now.key) else { break }
            if index + 1 < order.count {
                let next = order[index + 1]
                if trailing > start(of: next, in: order) + (widths[next] ?? 0) / 2 { order.swapAt(index, index + 1); continue }
            }
            if index > 0 {
                let before = order[index - 1]
                if leading < start(of: before, in: order) + (widths[before] ?? 0) / 2 { order.swapAt(index, index - 1); continue }
            }
            break
        }
        guard order != now.order else { return }
        now.order = order
        Haptics.play(.selection)
        settle { drag = now }
    }

    private func drop(_ now: Drag) {
        let changed = now.order != model.shownProjects.map(\.key)
        settle {
            settled = changed ? now.order : nil
            drag = nil
        }
        guard changed else { return }
        Haptics.play(.light)
        model.onOrderProjects(now.order)
        let order = now.order
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            if settled == order { settled = nil }
        }
    }

    private func settle(_ change: () -> Void) {
        if reduceMotion { change() } else { withAnimation(Self.spring, change) }
    }

    /// The rail scrolls while the finger is near one of its ends, faster the nearer.
    private func scrollAtTheEnds() async {
        let edge: CGFloat = 48
        while !Task.isCancelled, drag != nil {
            try? await Task.sleep(for: .milliseconds(16))
            guard let now = drag, now.moved, scroll.frame.width > 0 else { continue }
            var step: CGFloat = 0
            if now.fingerX > scroll.frame.maxX - edge {
                step = min(1, (now.fingerX - (scroll.frame.maxX - edge)) / edge) * 9
            } else if now.fingerX < scroll.frame.minX + edge {
                step = -min(1, (scroll.frame.minX + edge - now.fingerX) / edge) * 9
            }
            let x = min(scroll.most, max(0, scroll.x + step))
            guard step != 0, abs(x - scroll.x) > 0.5 else { continue }
            scroll.x = x
            scroll.position.scrollTo(x: x)
        }
    }
}

/// The Mac's secondary click keeps the choices a hold gives.
private struct MacProjectPillMenu: ViewModifier {
    var archiveTitle: String
    var archived: Bool
    var onLook: () -> Void
    var onSettings: () -> Void
    var onArchive: () -> Void

    func body(content: Content) -> some View {
        if DeviceWord.isMac {
            content.contextMenu {
                Button(action: onLook) { Label("Icon & Color…", systemImage: "paintbrush") }
                Button(action: onSettings) { Label("Project Settings…", systemImage: "gearshape") }
                Divider()
                Button(action: onArchive) { Label(archiveTitle, systemImage: archived ? "tray.and.arrow.up" : "archivebox") }
            }
        } else {
            content
        }
    }
}

/// `BotPillRail` with a `PillRailScroll`: the rail's place is kept and can be set.
struct PillRailScrolls: ViewModifier {
    var scroll: PillRailScroll?

    func body(content: Content) -> some View {
        if let scroll {
            content
                .scrollPosition(Bindable(scroll).position)
                .onScrollGeometryChange(for: [CGFloat].self) {
                    [$0.contentOffset.x, max(0, $0.contentSize.width - $0.containerSize.width)]
                } action: { _, now in
                    scroll.x = now[0]
                    scroll.most = now[1]
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { scroll.frame = $0 }
        } else {
            content
        }
    }
}
