// [tasks-first] The Tasks page's views as one row of pills under its bar (owner 2026-11-12, mockup 1-list-today:
// "Views, not bots, across the top"): Today, Upcoming, Inbox, each of your lists, Bots (once a bot has a task of its
// own), then + for a new list. It takes the place of the bot pills and of To Do | Ideas. A fixed band, as Sessions'
// header is: the list starts under it (the page's safe area grows by its height). Hold a list's pill to rename, move
// or delete it.

import SwiftUI
import UIKit

struct TaskViewPill: Identifiable, Equatable {
    var view: TodoView
    var title: String
    /// Its open tasks; nil shows none.
    var count: Int?
    /// [task-lists] A list's colour and icon: a small mark before its name.
    var color: TodoListColor?
    var icon: String?
    var id: String { view.key }
    var marked: Bool { color != nil || icon != nil }

    /// "tasks.view.today", and a list by its name ("tasks.view.list.Work").
    var identifier: String {
        if case .list = view { return "tasks.view.list.\(title)" }
        return "tasks.view.\(view.key)"
    }
}

/// What a hold on a list's pill offers.
struct TaskListActions {
    /// [task-lists] The Edit List sheet: name, colour, icon, the bot that keeps it.
    var edit: (String) -> Void
    var rename: (String) -> Void
    var move: (String, Int) -> Void
    var delete: (String) -> Void
    var newList: () -> Void
}

@MainActor @Observable
final class TaskViewsModel {
    /// Empty: no row (the list isn't read yet, or the add-on has no Tasks).
    var pills: [TaskViewPill] = []
    var picked: TodoView = .today
    /// Lists can be made and changed (not on a read-only gateway, or an add-on too old to keep them).
    var editsLists = true
    /// [Mac UI check 2026-11-13] A sheet is up over the page (UIKit has dimmed its tint).
    var dimmed = false
}

private struct TaskViewsBand: View {
    var model: TaskViewsModel
    var onPick: (TodoView) -> Void
    var actions: TaskListActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if !model.pills.isEmpty { rail }
        }
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: DesktopPillBand.color))   // [desktop-hard-edge] the hard band shows through on the iPhone
    }

    private var lists: [String] {
        model.pills.compactMap { if case .list(let id) = $0.view { return id } else { return nil } }
    }

    @ViewBuilder private var pills: some View {
        ForEach(model.pills) { pill in pillView(pill) }
        if model.editsLists { newListPill }
    }

    @ViewBuilder private func pillView(_ pill: TaskViewPill) -> some View {
        let picked = model.picked == pill.view
        // [Mac UI check 2026-11-13] Under a sheet the system greys the picked pill's tinted glass and
        // its white words read faintly on the grey: the pick is then drawn as a plain pill in the
        // label's ink with a ring, readable on the dimmed fill, and tinted again when the sheet goes.
        let quiet = picked && model.dimmed && !Theme.isDesktop
        SessionPill(caption: pill.title, name: spoken(pill), picked: picked && !quiet,
                    identifier: pill.identifier, hasFace: pill.marked, lead: pill.marked ? 11 : nil,
                    detail: pill.count.flatMap { $0 > 0 ? "\($0)" : nil }) {
            onPick(pill.view)
        } face: {
            // [task-lists] The list's icon, grey ([tasks-colour]).
            TaskListPillMark(color: pill.color, icon: pill.icon, picked: picked && !quiet)
        }
        .overlay {
            if quiet {
                Capsule().strokeBorder(Color.hqLabel2, lineWidth: 1.5)
                    .frame(height: HQFont.scaled(34))   // the pill's own height (`SessionPill`), not its 44 pt touch
                    .allowsHitTesting(false)
            }
        }
        .accessibilityAddTraits(quiet ? .isSelected : [])
        .contextMenu { menu(for: pill) }
        .id(pill.id)
    }

    @ViewBuilder private var newListPill: some View {
        SessionPill(caption: "", name: "New List", picked: false, identifier: "tasks.view.new-list", hasFace: true, lead: 10) {
            actions.newList()
        } face: {
            Image(systemName: "plus")
                .font(Font.hq(Theme.isDesktop ? .caption : .footnote).weight(.semibold))
                .foregroundStyle(Color.hqLabel2)
                .padding(.trailing, -8)
        }
    }

    @ViewBuilder private var rail: some View {
        if DeviceWord.isMac {
            // [mac-tasks-row] Owner 2026-11-22: the pills wrapped to a second line in a narrow pane ("You can't just
            // stack the pills like that"), and a pop-up for every view hid an easy one-click move. One row: every
            // pill that fits, in order, and the rest under a last "More" pill (the picked view always stays out).
            // A full window fits them all and has no More.
            macRow
        } else {
            scrollingRail
        }
    }

    /// Each pill's width (by its key; "+" for New List, "more" for More), and the row's.
    @State private var widths: [String: CGFloat] = [:]
    @State private var rowWidth: CGFloat = 0

    private var macRow: some View {
        let keys = model.pills.map(\.id)
        let available = rowWidth - 2 * gutter
        let whole = TaskViewsFit.fit(keys: keys, picked: model.picked.key, widths: widths,
                                     newList: model.editsLists ? "+" : nil, available: available, spacing: 8)
        // Owner 2026-11-22 ("What's a better way to do it?"): too narrow for them all, the other views become their
        // icons (the name under the pointer), still one click each; the picked view keeps its name and count. Only a
        // row too narrow even for the icons puts the last of them under "N More".
        var icons = widths
        for key in keys where key != model.picked.key { icons[key] = widths["icon." + key] }
        let iconFit = TaskViewsFit.fit(keys: keys, picked: model.picked.key, widths: icons,
                                       newList: model.editsLists ? "+" : nil, available: available, spacing: 8)
        let fit = !whole.more ? whole : !iconFit.more ? iconFit
            : TaskViewsFit.fit(keys: keys, picked: model.picked.key, widths: icons, newList: nil, available: available,
                               spacing: 8, forceMore: true)
        let shown = model.pills.filter { fit.shown.contains($0.id) }
        let rest = model.pills.filter { !fit.shown.contains($0.id) }
        let compact = whole.more
        return HStack(spacing: 8) {
            ForEach(shown) { pill in
                if compact && pill.view != model.picked { iconPill(pill) } else { pillView(pill) }
            }
            if fit.more {
                morePill(rest)
            } else if model.editsLists {
                newListPill
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, gutter)
        .padding(.top, DesktopRows.underBar)
        .padding(.bottom, Theme.isDesktop ? 2 : 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hqPickGlassRow()
        .hqFlatPicks()   // [Mac UI check 2026-11-13] no glass to carry the picked pill's blue onto its neighbours
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
        // Every pill measured off screen, at its own size, so the row knows what fits before it draws.
        .background(alignment: .topLeading) {
            HStack(spacing: 8) {
                ForEach(model.pills) { pill in
                    pillView(pill).fixedSize().measured(pill.id, into: $widths)
                    iconPill(pill).fixedSize().measured("icon." + pill.id, into: $widths)
                }
                newListPill.fixedSize().measured("+", into: $widths)
                morePill([]).fixedSize().measured("more", into: $widths)
            }
            .fixedSize()
            .hidden()
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Views")
        .accessibilityIdentifier("tasks.views")
    }

    private var gutter: CGFloat { Theme.isDesktop ? DesktopRows.gutter : 16 }

    /// [mac-tasks-row] A view as its icon alone, in a narrow row: its name under the pointer and for VoiceOver.
    private func iconPill(_ pill: TaskViewPill) -> some View {
        SessionPill(caption: "", name: spoken(pill), picked: false, identifier: pill.identifier, hasFace: true, lead: 10) {
            onPick(pill.view)
        } face: {
            Image(systemName: Self.symbol(pill))
                .font(Font.hq(Theme.isDesktop ? .caption : .footnote).weight(.medium))
                .foregroundStyle(Color.hqLabel2)
                .frame(minWidth: 14)
                .padding(.trailing, -8)
        }
        .help(pill.count.flatMap { $0 > 0 ? "\(pill.title) (\($0))" : nil } ?? pill.title)
        .contextMenu { menu(for: pill) }
    }

    static func symbol(_ pill: TaskViewPill) -> String {
        switch pill.view {
        case .goals: return "smallcircle.filled.circle"
        case .today: return "sun.max"
        case .upcoming: return "calendar"
        case .inbox: return "tray"
        case .suggested: return "sparkle"
        case .bots: return "person.2"
        case .list: return pill.icon ?? TodoListIcons.fallback
        }
    }

    /// "3 More ⌄": the views that didn't fit (with their counts), then New List. Measured as "9 More" (`rest` empty).
    private func morePill(_ rest: [TaskViewPill]) -> some View {
        Menu {
            ForEach(rest) { pill in
                Button { onPick(pill.view) } label: {
                    Text(pill.count.flatMap { $0 > 0 ? "\(pill.title)   \($0)" : nil } ?? pill.title)
                }
                .accessibilityIdentifier(pill.identifier)
            }
            if model.editsLists {
                Divider()
                Button { actions.newList() } label: { Label("New List…", systemImage: "plus") }
                    .accessibilityIdentifier("tasks.view.new-list")
            }
        } label: {
            // Owner 2026-11-22 ("Is the … the best way to make someone think they should click for the rest?"): "…" is
            // the bar's own actions button; "3 More ⌄" says views are hidden, how many, and that it opens a menu.
            HStack(spacing: 4) {
                Text(rest.isEmpty ? "9 More" : "\(rest.count) More")
                    .font(Font.hq(Theme.isDesktop ? .footnote : .subheadline).weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.hqLabel)
                Image(systemName: "chevron.down")
                    .font(Font.hq(.caption2).weight(.semibold))
                    .foregroundStyle(Color.hqLabel2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(minHeight: SessionPill<EmptyView>.height)
            .background {
                if Theme.isDesktop {
                    RoundedRectangle(cornerRadius: DesktopRows.radius, style: .continuous).fill(Color.hqFill3)
                }
            }
            .hqPickGlass(false, in: Capsule(), prominent: true, still: false)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More views")
        .accessibilityLabel(rest.isEmpty ? "More Views" : "\(rest.count) More Views")
        .accessibilityIdentifier("tasks.views.more")
    }

    private var scrollingRail: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) { pills }
                .padding(.horizontal, Theme.isDesktop ? DesktopRows.gutter : 16)
                .padding(.top, DesktopRows.underBar)
                .padding(.bottom, Theme.isDesktop ? 2 : 4)
                .hqPickGlassRow()
            }
            // [rail-scroller] Owner 2026-11-18 (Mac screenshot): `.hidden` still shows the scroller with a mouse
            // attached, a grey bar over the pills. `.never` hides it there too; a trackpad swipe still scrolls.
            .scrollIndicators(.never)
            .hqScrollEdgeFade(width: 20)
            // Only as far as it takes to show the picked pill whole (no anchor): centring it slid the whole row
            // sideways on every tap, even with every pill already in view (owner 2026-11-12: "it's glitching").
            .onAppear { proxy.scrollTo(model.picked.key) }
            .onChange(of: model.picked) { _, picked in
                if reduceMotion {
                    proxy.scrollTo(picked.key)
                } else {
                    withAnimation(.easeInOut(duration: HQMotion.pane)) { proxy.scrollTo(picked.key) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Views")
        .accessibilityIdentifier("tasks.views")
    }

    private func spoken(_ pill: TaskViewPill) -> String {
        guard let count = pill.count, count > 0 else { return pill.title }
        return "\(pill.title), \(count) \(count == 1 ? "task" : "tasks")"
    }

    @ViewBuilder private func menu(for pill: TaskViewPill) -> some View {
        if case .list(let id) = pill.view, model.editsLists {
            let at = lists.firstIndex(of: id) ?? 0
            Button { actions.edit(id) } label: { Label("Edit List…", systemImage: "slider.horizontal.3") }
            Button { actions.rename(id) } label: { Label("Rename…", systemImage: "pencil") }
            if at > 0 { Button { actions.move(id, -1) } label: { Label("Move Left", systemImage: "arrow.left") } }
            if at < lists.count - 1 { Button { actions.move(id, 1) } label: { Label("Move Right", systemImage: "arrow.right") } }
            Divider()
            Button(role: .destructive) { actions.delete(id) } label: { Label("Delete List…", systemImage: "trash") }
        }
    }
}

/// An empty view that says when its tint is dimmed (a sheet over the page) and when it isn't again.
final class TintDimProbe: UIView {
    var changed: ((Bool) -> Void)?
    override func tintColorDidChange() {
        super.tintColorDidChange()
        changed?(tintAdjustmentMode == .dimmed)
    }
}

/// The row as the page's fixed band under its bar. In the iOS look it is clear over the list's soft edge; the Desktop
/// Look keeps a band in the page colour.
@MainActor
final class TaskViewsHeader {
    let model = TaskViewsModel()
    private let onPick: (TodoView) -> Void
    private let actions: TaskListActions
    private weak var controller: UIViewController?
    private var host: UIHostingController<TaskViewsBand>?
    private var height: NSLayoutConstraint?
    private var laidOut = false

    var shows: Bool { !model.pills.isEmpty }

    init(actions: TaskListActions, onPick: @escaping (TodoView) -> Void) {
        self.actions = actions
        self.onPick = onPick
    }

    /// Under the bar of `controller`; `list` is the page's list (in its soft-edge host when it has one).
    func install(in controller: UIViewController, list: UIScrollView, backdrop: PageBackdrop?) {
        guard host == nil else { return }
        self.controller = controller
        let host = UIHostingController(rootView: TaskViewsBand(model: model, onPick: { [weak self] in self?.pick($0) }, actions: actions))
        host.safeAreaRegions = []                // it sits above the safe area it makes room in
        host.view.backgroundColor = DesktopPillBand.color
        backdrop?.clear(host.view)               // [backdrop] the picture's band is behind it then
        host.view.translatesAutoresizingMaskIntoConstraints = false
        controller.addChild(host)
        controller.view.addSubview(host.view)
        // [top-edge] The pills are part of the top edge, as Sessions' chips: the hard band reaches under them.
        if let edgeHost = list.superview as? UIScrollView {
            let edge = UIScrollEdgeElementContainerInteraction()
            edge.scrollView = edgeHost
            edge.edge = .top
            host.view.addInteraction(edge)
        }
        let height = host.view.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor),
            height,
        ])
        host.didMove(toParent: controller)
        host.view.clipsToBounds = true
        // [Mac UI check 2026-11-13] Told when a sheet dims the page's tint (the band itself keeps `.normal`).
        let probe = TintDimProbe()
        probe.isUserInteractionEnabled = false
        probe.changed = { [weak self] dimmed in
            guard let self, self.model.dimmed != dimmed else { return }
            self.model.dimmed = dimmed
        }
        controller.view.addSubview(probe)
        self.host = host
        self.height = height
    }

    /// The pills and the pick; the band is measured again only when what it draws changed.
    func update(pills: [TaskViewPill], picked: TodoView, editsLists: Bool) {
        guard host != nil else { return }
        var changed = false
        if model.pills != pills { model.pills = pills; changed = true }
        if model.picked != picked { model.picked = picked; changed = true }
        if model.editsLists != editsLists { model.editsLists = editsLists; changed = true }
        if changed { controller?.view.setNeedsLayout() }
    }

    private func pick(_ view: TodoView) {
        PagesHaptics.selection()
        onPick(view)
    }

    /// From the page's `viewDidLayoutSubviews`: the band's height, and the list's room under it.
    func layout() {
        guard let host, let height, let controller, controller.view.bounds.width > 0 else { return }
        let view = controller.view!
        let fitted = model.pills.isEmpty ? 0 : host.sizeThatFits(in: CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude)).height
        // To the pixel, not the point: a band a fraction taller than its content left a line of the list above it.
        let scale = max(view.window?.screen.scale ?? controller.traitCollection.displayScale, 1)
        let target = fitted.isFinite ? max(0, (fitted * scale).rounded(.up) / scale) : 0
        let band = DesktopPillBand.color
        if host.view.backgroundColor != band { host.view.backgroundColor = band }
        guard abs(controller.additionalSafeAreaInsets.top - target) > 0.5 else { return }
        let animated = view.window != nil && !HQMotion.reduced && laidOut
        laidOut = true
        let change = {
            height.constant = target
            controller.additionalSafeAreaInsets.top = target
        }
        if animated {
            UIView.animate(withDuration: HQMotion.fade) {   // motion-ok: `animated` above is false under Reduce Motion
                change()
                view.layoutIfNeeded()
            }
        } else {
            change()
        }
    }
}

private extension View {
    /// [mac-tasks-row] Writes the view's width into `widths` under `key`.
    func measured(_ key: String, into widths: Binding<[String: CGFloat]>) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if widths.wrappedValue[key] != width { widths.wrappedValue[key] = width }
        }
    }
}

/// [mac-tasks-row] Which of the Mac's view pills fit in one row.
enum TaskViewsFit {
    struct Result: Equatable {
        var shown: Set<String>
        var more: Bool
    }

    /// All of them (and New List's "+") when they fit. Otherwise as many as fit in order beside the More pill, the
    /// picked one always among them (in its own place, the last that fit giving way). Unmeasured: all, no More.
    /// `forceMore`: the row already overflowed with the counts on; fit the bare pills beside More regardless.
    static func fit(keys: [String], picked: String, widths: [String: CGFloat], newList: String?, available: CGFloat,
                    spacing: CGFloat, forceMore: Bool = false) -> Result {
        let all = Set(keys)
        guard available > 0, keys.allSatisfy({ widths[$0] != nil }), let more = widths["more"] else { return Result(shown: all, more: false) }
        func total(_ ks: [String]) -> CGFloat { ks.reduce(0) { $0 + widths[$1]! } + spacing * CGFloat(max(0, ks.count - 1)) }
        let whole = keys + (newList.flatMap { widths[$0] != nil ? [$0] : nil } ?? [])
        if !forceMore, total(whole) <= available { return Result(shown: all, more: false) }
        let room = available - more - spacing
        var shown: [String] = []
        for key in keys {
            if total(shown + [key]) <= room { shown.append(key) } else { break }
        }
        if keys.contains(picked), !shown.contains(picked) {
            while !shown.isEmpty, total(shown + [picked]) > room { shown.removeLast() }
            shown.append(picked)
        }
        return Result(shown: Set(shown), more: true)
    }
}
