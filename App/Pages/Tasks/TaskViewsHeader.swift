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
    var id: String { view.key }

    /// "tasks.view.today", and a list by its name ("tasks.view.list.Work").
    var identifier: String {
        if case .list = view { return "tasks.view.list.\(title)" }
        return "tasks.view.\(view.key)"
    }
}

/// What a hold on a list's pill offers.
struct TaskListActions {
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
        .background(Theme.isDesktop ? Color.hqPage : Color.clear)
    }

    private var lists: [String] {
        model.pills.compactMap { if case .list(let id) = $0.view { return id } else { return nil } }
    }

    private var rail: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(model.pills) { pill in
                        SessionPill(caption: pill.title, name: spoken(pill), picked: model.picked == pill.view,
                                    identifier: pill.identifier, detail: pill.count.flatMap { $0 > 0 ? "\($0)" : nil }) {
                            onPick(pill.view)
                        } face: {
                            EmptyView()
                        }
                        .contextMenu { menu(for: pill) }
                        .id(pill.id)
                    }
                    if model.editsLists {
                        SessionPill(caption: "", name: "New List", picked: false, identifier: "tasks.view.new-list", hasFace: true, lead: 10) {
                            actions.newList()
                        } face: {
                            Image(systemName: "plus")
                                .font(Font.hq(Theme.isDesktop ? .caption : .footnote).weight(.semibold))
                                .foregroundStyle(Color.hqLabel2)
                                .padding(.trailing, -8)
                        }
                    }
                }
                .padding(.horizontal, Theme.isDesktop ? DesktopRows.gutter : 16)
                .padding(.top, DesktopRows.underBar)
                .padding(.bottom, Theme.isDesktop ? 2 : 4)
                .hqPickGlassRow()
            }
            .scrollIndicators(.hidden)
            .hqScrollEdgeFade(width: 20)
            // Only as far as it takes to show the picked pill whole (no anchor): centring it slid the whole row
            // sideways on every tap, even with every pill already in view (owner 2026-11-12: "it's glitching").
            .onAppear { proxy.scrollTo(model.picked.key) }
            .onChange(of: model.picked) { _, picked in
                if reduceMotion {
                    proxy.scrollTo(picked.key)
                } else {
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(picked.key) }
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
            Button { actions.rename(id) } label: { Label("Rename…", systemImage: "pencil") }
            if at > 0 { Button { actions.move(id, -1) } label: { Label("Move Left", systemImage: "arrow.left") } }
            if at < lists.count - 1 { Button { actions.move(id, 1) } label: { Label("Move Right", systemImage: "arrow.right") } }
            Divider()
            Button(role: .destructive) { actions.delete(id) } label: { Label("Delete List…", systemImage: "trash") }
        }
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
        host.view.backgroundColor = Theme.isDesktop ? HQPalette.page : .clear
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
        let band = Theme.isDesktop ? HQPalette.page : UIColor.clear
        if host.view.backgroundColor != band { host.view.backgroundColor = band }
        guard abs(controller.additionalSafeAreaInsets.top - target) > 0.5 else { return }
        let animated = view.window != nil && !HQMotion.reduced && laidOut
        laidOut = true
        let change = {
            height.constant = target
            controller.additionalSafeAreaInsets.top = target
        }
        if animated {
            UIView.animate(withDuration: 0.2) {   // motion-ok: `animated` above is false under Reduce Motion
                change()
                view.layoutIfNeeded()
            }
        } else {
            change()
        }
    }
}
