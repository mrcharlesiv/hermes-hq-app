// Grouped Overview (iPhone / compact) and collapsible Tasks Sidebar (Mac) for Tasks navigation.
// Separates Smart Views (Today, Upcoming, Inbox, Goals), My Lists, and Agents (Bots) into three distinct groups
// instead of flattening custom lists and Bots into one horizontal pill bar.

import SwiftUI
import UIKit

/// Pure layout and title rules for Tasks' Grouped Overview and Mac Sidebar (unit-tested in Tests/Pages/TasksNavigationTests).
nonisolated enum TasksNavigationLayout {
    /// Mac internal Tasks sidebar width in points.
    static let sidebarWidth: CGFloat = 216
    /// Minimum Tasks pane width on Mac to display the internal sidebar beside the list; narrower panes (such as when a
    /// task detail pane opens beside Tasks) auto-collapse the sidebar into the nav bar's view switcher.
    static let sidebarMinPaneWidth: CGFloat = 640
    /// Minimum collection view width on Mac to render the multi-column table layout (`TodoTable`).
    static let tableMinContentWidth: CGFloat = 760

    static func shouldShowMacSidebar(isMac: Bool, paneWidth: CGFloat, userCollapsed: Bool, hasList: Bool, needsAddOn: Bool) -> Bool {
        isMac && hasList && !needsAddOn && !userCollapsed && paneWidth >= sidebarMinPaneWidth
    }

    static func shouldUseMacTable(isMac: Bool, contentWidth: CGFloat) -> Bool {
        isMac && contentWidth >= tableMinContentWidth
    }

    static func title(for view: TodoView, sections: [TodoUserSection]) -> String {
        switch view {
        case .today: return "Today"
        case .upcoming: return "Upcoming"
        case .inbox: return "Inbox"
        case .goals: return "Goals"
        case .bots: return "Bots’ Tasks"
        case .list(let id): return sections.first { $0.id == id }?.name ?? "List"
        }
    }

    static func symbol(for view: TodoView, sections: [TodoUserSection]) -> String {
        switch view {
        case .today: return "sun.max"
        case .upcoming: return "calendar"
        case .inbox: return "tray"
        case .goals: return "smallcircle.filled.circle"
        case .bots: return "person.2"
        case .list(let id): return sections.first { $0.id == id }?.icon ?? TodoListIcons.fallback
        }
    }
}

// MARK: - Models

struct TasksSmartTileModel: Identifiable, Hashable {
    var view: TodoView
    var title: String
    var symbol: String
    var count: Int?
    var id: String { view.key }
    var identifier: String { "tasks.view.\(view.key)" }

    var spoken: String {
        guard let count else { return title }
        if view == .goals { return "\(title), \(count) \(count == 1 ? "goal" : "goals")" }
        return "\(title), \(count) \(count == 1 ? "task" : "tasks")"
    }

    var tint: Color {
        switch view {
        case .today: return Color.hqTint
        case .upcoming: return Color.hqRed
        case .inbox: return Color.hqLabel2
        case .goals: return Color.hqGreen
        default: return Color.hqTint
        }
    }
}

struct TasksOverviewListModel: Identifiable, Hashable {
    var id: String
    var name: String
    var icon: String
    var color: TodoListColor?
    var subtitle: String?
    var count: Int
    var index: Int
    var total: Int

    var identifier: String { "tasks.view.list.\(name)" }

    var spoken: String {
        var parts = [name, "\(count) \(count == 1 ? "task" : "tasks")"]
        if let subtitle, !subtitle.isEmpty { parts.append(subtitle) }
        return parts.joined(separator: ", ")
    }
}

struct TasksOverviewAgentsModel: Hashable {
    var count: Int
    var identifier: String { "tasks.view.bots" }
    var spoken: String { "Bots’ Tasks, \(count) \(count == 1 ? "task" : "tasks")" }
}

// MARK: - iPhone Grouped Overview Views

/// The 2×2 Smart Views grid at the top of the Grouped Overview (Today, Upcoming, Inbox, Goals).
struct TasksSmartGridView: View {
    var tiles: [TasksSmartTileModel]
    var onPick: (TodoView) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    private var columns: [GridItem] {
        let count = typeSize.isAccessibilitySize ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 10), count: count)
    }

    var body: some View {
        let _ = Theme.touch()
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(tiles) { tile in
                Button {
                    PagesHaptics.selection()
                    onPick(tile.view)
                } label: {
                    tileBody(tile)
                }
                .buttonStyle(TasksOverviewTileButtonStyle())
                .accessibilityLabel(tile.spoken)
                .accessibilityIdentifier(tile.identifier)
            }
        }
        .padding(.horizontal, ListGutter.side)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tasks.overview.smart")
    }

    private func tileBody(_ tile: TasksSmartTileModel) -> some View {
        let radius: CGFloat = Theme.isDesktop ? DesktopRows.radius : 14
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Image(systemName: tile.symbol)
                    .font(Font.hq(.body).weight(.semibold))
                    .foregroundStyle(tile.tint)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(tile.tint.opacity(0.14)))
                    .accessibilityHidden(true)
                Spacer(minLength: 6)
                if let count = tile.count {
                    Text("\(count)")
                        .font(Font.hq(.title3).weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.hqLabel)
                }
            }
            Text(tile.title)
                .font(Font.hq(.subheadline).weight(.semibold))
                .foregroundStyle(Color.hqLabel2)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(Color.hqGroupedCard)
                .overlay { shape.strokeBorder(Color.hqStroke, lineWidth: HQShape.hairline) }
        }
        .contentShape(shape)
    }
}

private struct TasksOverviewTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !HQMotion.reduced ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Section header for "My Lists" (with an inline "+ New List" action) and "Agents".
struct TasksOverviewSectionHeader: View {
    var title: String
    var actionTitle: String?
    var actionIdentifier: String?
    var action: (() -> Void)?

    var body: some View {
        let _ = Theme.touch()
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(Font.hq(.footnote).weight(.semibold))
                .foregroundStyle(Color.hqLabel2)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button {
                    PagesHaptics.selection()
                    action()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                            .font(Font.hq(.caption2).weight(.bold))
                            .accessibilityHidden(true)
                        Text(actionTitle)
                            .font(Font.hq(.footnote).weight(.semibold))
                    }
                    .foregroundStyle(Color.hqTintText)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(actionIdentifier ?? "tasks.overview.header-action")
            }
        }
        .padding(.horizontal, ListGutter.side + 2)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }
}

/// Grouped card container for My Lists on iPhone Overview (supports context menus per list and an empty state).
struct TasksOverviewListsCard: View {
    var lists: [TasksOverviewListModel]
    var editsLists: Bool
    var onPick: (String) -> Void
    var actions: TaskListActions

    var body: some View {
        let _ = Theme.touch()
        let radius: CGFloat = Theme.isDesktop ? DesktopRows.radius : 14
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        VStack(spacing: 0) {
            if lists.isEmpty {
                if editsLists {
                    Button {
                        PagesHaptics.selection()
                        actions.newList()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus")
                                .font(Font.hq(.subheadline).weight(.semibold))
                                .foregroundStyle(Color.hqTintText)
                                .frame(width: 30, height: 30)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.hqTint.opacity(0.14)))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("New List")
                                    .font(Font.hq(.body).weight(.medium))
                                    .foregroundStyle(Color.hqTintText)
                                Text("Group tasks your way, like Home, Work or Errands.")
                                    .font(Font.hq(.footnote))
                                    .foregroundStyle(Color.hqLabel2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(TasksOverviewRowButtonStyle())
                    .accessibilityIdentifier("tasks.view.new-list")
                } else {
                    Text("No lists yet.")
                        .font(Font.hq(.subheadline))
                        .foregroundStyle(Color.hqLabel2)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ForEach(Array(lists.enumerated()), id: \.element.id) { idx, list in
                    Button {
                        PagesHaptics.selection()
                        onPick(list.id)
                    } label: {
                        listRowBody(list)
                    }
                    .buttonStyle(TasksOverviewRowButtonStyle())
                    .contextMenu {
                        if editsLists {
                            Button { actions.edit(list.id) } label: { Label("Edit List…", systemImage: "slider.horizontal.3") }
                            Button { actions.rename(list.id) } label: { Label("Rename…", systemImage: "pencil") }
                            if list.index > 0 {
                                Button { actions.move(list.id, -1) } label: { Label("Move Up", systemImage: "arrow.up") }
                            }
                            if list.index < list.total - 1 {
                                Button { actions.move(list.id, 1) } label: { Label("Move Down", systemImage: "arrow.down") }
                            }
                            Divider()
                            Button(role: .destructive) { actions.delete(list.id) } label: { Label("Delete List…", systemImage: "trash") }
                        }
                    }
                    .accessibilityLabel(list.spoken)
                    .accessibilityIdentifier(list.identifier)

                    if idx < lists.count - 1 {
                        Rectangle()
                            .fill(Color.hqStroke)
                            .frame(height: HQShape.hairline)
                            .padding(.leading, 54)
                    }
                }
            }
        }
        .background {
            shape.fill(Color.hqGroupedCard)
                .overlay { shape.strokeBorder(Color.hqStroke, lineWidth: HQShape.hairline) }
        }
        .clipShape(shape)
        .padding(.horizontal, ListGutter.side)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tasks.overview.lists")
    }

    private func listRowBody(_ list: TasksOverviewListModel) -> some View {
        let tint = list.color?.ink ?? Color.hqTint
        return HStack(spacing: 12) {
            Image(systemName: list.icon)
                .font(Font.hq(.subheadline).weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(list.name)
                    .font(Font.hq(.body).weight(.medium))
                    .foregroundStyle(Color.hqLabel)
                    .lineLimit(1)
                if let subtitle = list.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text("\(list.count)")
                .font(Font.hq(.subheadline))
                .monospacedDigit()
                .foregroundStyle(Color.hqLabel2)
            Image(systemName: "chevron.right")
                .font(Font.hq(.caption).weight(.semibold))
                .foregroundStyle(Color.hqLabel3)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }
}

/// Agents card on iPhone Overview (Bots' own tasks, cleanly separated from user lists).
struct TasksOverviewAgentsCard: View {
    var agents: TasksOverviewAgentsModel
    var onPick: () -> Void

    var body: some View {
        let _ = Theme.touch()
        let radius: CGFloat = Theme.isDesktop ? DesktopRows.radius : 14
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Button {
            PagesHaptics.selection()
            onPick()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.2")
                    .font(Font.hq(.subheadline).weight(.semibold))
                    .foregroundStyle(Color.hqLabel2)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.hqFill3))
                    .accessibilityHidden(true)
                Text("Bots’ Tasks")
                    .font(Font.hq(.body).weight(.medium))
                    .foregroundStyle(Color.hqLabel)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(agents.count)")
                    .font(Font.hq(.subheadline))
                    .monospacedDigit()
                    .foregroundStyle(Color.hqLabel2)
                Image(systemName: "chevron.right")
                    .font(Font.hq(.caption).weight(.semibold))
                    .foregroundStyle(Color.hqLabel3)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(TasksOverviewRowButtonStyle())
        .background {
            shape.fill(Color.hqGroupedCard)
                .overlay { shape.strokeBorder(Color.hqStroke, lineWidth: HQShape.hairline) }
        }
        .clipShape(shape)
        .padding(.horizontal, ListGutter.side)
        .accessibilityLabel(agents.spoken)
        .accessibilityIdentifier(agents.identifier)
    }
}

private struct TasksOverviewRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(uiColor: HQPalette.cellPressed) : Color.clear)
    }
}

// MARK: - Mac Internal Tasks Sidebar

@MainActor @Observable
final class TasksSidebarModel {
    var smart: [TasksSmartTileModel] = []
    var lists: [TasksOverviewListModel] = []
    var agents: TasksOverviewAgentsModel?
    var picked: TodoView = .today
    var editsLists = true
}

struct TasksSidebarView: View {
    var model: TasksSidebarModel
    var onPick: (TodoView) -> Void
    var actions: TaskListActions

    var body: some View {
        let _ = Theme.touch()
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                sectionHeading("Views")
                ForEach(model.smart) { tile in
                    sidebarRow(
                        title: tile.title,
                        count: tile.count,
                        picked: model.picked == tile.view,
                        spoken: tile.spoken,
                        identifier: tile.identifier,
                        icon: {
                            Image(systemName: tile.symbol)
                                .font(Font.hq(.footnote).weight(.semibold))
                                .foregroundStyle(model.picked == tile.view ? Color.hqOnTint : tile.tint)
                                .frame(width: 18)
                        },
                        action: { onPick(tile.view) }
                    )
                }

                sectionHeading("My Lists")
                    .padding(.top, 12)
                ForEach(model.lists) { list in
                    let isPicked = model.picked == .list(list.id)
                    sidebarRow(
                        title: list.name,
                        count: list.count,
                        picked: isPicked,
                        spoken: list.spoken,
                        identifier: list.identifier,
                        icon: {
                            Image(systemName: list.icon)
                                .font(Font.hq(.footnote).weight(.medium))
                                .foregroundStyle(isPicked ? Color.hqOnTint : (list.color?.ink ?? Color.hqLabel2))
                                .frame(width: 18)
                        },
                        action: { onPick(.list(list.id)) }
                    )
                    .contextMenu {
                        if model.editsLists {
                            Button { actions.edit(list.id) } label: { Label("Edit List…", systemImage: "slider.horizontal.3") }
                            Button { actions.rename(list.id) } label: { Label("Rename…", systemImage: "pencil") }
                            if list.index > 0 {
                                Button { actions.move(list.id, -1) } label: { Label("Move Up", systemImage: "arrow.up") }
                            }
                            if list.index < list.total - 1 {
                                Button { actions.move(list.id, 1) } label: { Label("Move Down", systemImage: "arrow.down") }
                            }
                            Divider()
                            Button(role: .destructive) { actions.delete(list.id) } label: { Label("Delete List…", systemImage: "trash") }
                        }
                    }
                }

                if model.editsLists {
                    Button {
                        PagesHaptics.selection()
                        actions.newList()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(Font.hq(.caption).weight(.semibold))
                                .frame(width: 18)
                            Text("New List")
                                .font(Font.hq(.footnote).weight(.medium))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(Color.hqTintText)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(TasksSidebarRowButtonStyle(picked: false))
                    .accessibilityIdentifier("tasks.view.new-list")
                    .padding(.top, 2)
                }

                if let agents = model.agents {
                    sectionHeading("Agents")
                        .padding(.top, 12)
                    let isPicked = model.picked == .bots
                    sidebarRow(
                        title: "Bots’ Tasks",
                        count: agents.count,
                        picked: isPicked,
                        spoken: agents.spoken,
                        identifier: agents.identifier,
                        icon: {
                            Image(systemName: "person.2")
                                .font(Font.hq(.footnote).weight(.medium))
                                .foregroundStyle(isPicked ? Color.hqOnTint : Color.hqLabel2)
                                .frame(width: 18)
                        },
                        action: { onPick(.bots) }
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: HQPalette.groupedPage))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Views")
        .accessibilityIdentifier("tasks.views")
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(Font.hq(.caption2).weight(.semibold))
            .foregroundStyle(Color.hqLabel3)
            .textCase(.uppercase)
            .padding(.horizontal, 9)
            .padding(.top, 4)
            .padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }

    private func sidebarRow<Icon: View>(
        title: String,
        count: Int?,
        picked: Bool,
        spoken: String,
        identifier: String,
        @ViewBuilder icon: () -> Icon,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            PagesHaptics.selection()
            action()
        } label: {
            HStack(spacing: 8) {
                icon().accessibilityHidden(true)
                Text(title)
                    .font(Font.hq(.footnote).weight(picked ? .semibold : .medium))
                    .foregroundStyle(picked ? Color.hqOnTint : Color.hqLabel)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(Font.hq(.caption))
                        .monospacedDigit()
                        .foregroundStyle(picked ? Color.hqOnTint.opacity(0.9) : Color.hqLabel2)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(TasksSidebarRowButtonStyle(picked: picked))
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

private struct TasksSidebarRowButtonStyle: ButtonStyle {
    var picked: Bool
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        configuration.label
            .background {
                if picked {
                    shape.fill(Color.hqTint)
                } else if configuration.isPressed {
                    shape.fill(Color(uiColor: HQPalette.cellPressed))
                } else if hovered {
                    shape.fill(Color.hqFill3.opacity(0.65))
                }
            }
            .onHover { hovered = $0 }
    }
}

/// Hosts `TasksSidebarView` inside `TasksViewController` on Mac beside `collectionView`.
@MainActor
final class TasksSidebarHost {
    let model = TasksSidebarModel()
    private let onPick: (TodoView) -> Void
    private let actions: TaskListActions
    private(set) var host: UIHostingController<TasksSidebarView>?
    private(set) var separator: UIView?

    init(actions: TaskListActions, onPick: @escaping (TodoView) -> Void) {
        self.actions = actions
        self.onPick = onPick
    }

    func install(in controller: UIViewController) {
        guard host == nil else { return }
        let hosting = UIHostingController(rootView: TasksSidebarView(model: model, onPick: { [weak self] in self?.onPick($0) }, actions: actions))
        hosting.view.backgroundColor = .clear
        controller.addChild(hosting)
        controller.view.addSubview(hosting.view)
        hosting.didMove(toParent: controller)
        let line = UIView()
        #if targetEnvironment(macCatalyst)
        line.backgroundColor = HQPalette.paneLine
        #else
        line.backgroundColor = HQPalette.separator
        #endif
        line.isUserInteractionEnabled = false
        controller.view.addSubview(line)
        host = hosting
        separator = line
    }

    func update(smart: [TasksSmartTileModel], lists: [TasksOverviewListModel], agents: TasksOverviewAgentsModel?,
                picked: TodoView, editsLists: Bool) {
        if model.smart != smart { model.smart = smart }
        if model.lists != lists { model.lists = lists }
        if model.agents != agents { model.agents = agents }
        if model.picked != picked { model.picked = picked }
        if model.editsLists != editsLists { model.editsLists = editsLists }
    }

    func layout(in bounds: CGRect, visible: Bool, scale: CGFloat) {
        guard let view = host?.view, let separator else { return }
        view.isHidden = !visible
        separator.isHidden = !visible
        guard visible else { return }
        let width = TasksNavigationLayout.sidebarWidth
        let pixel = 1 / max(scale, 1)
        view.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        separator.frame = CGRect(x: width, y: 0, width: pixel, height: bounds.height)
    }
}
