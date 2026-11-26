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
    /// Maximum number of suggested tasks shown inline on the iPhone Grouped Overview before tapping "See all".
    static let overviewSuggestedLimit = 3

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
        case .suggested: return "Suggested"
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
        case .suggested: return "sparkle"
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

struct TasksOverviewSuggestedRowModel: Hashable {
    var count: Int
    var isOn: Bool
    var looking: Bool

    var identifier: String { "tasks.view.suggested" }

    var subtitle: String? {
        if looking { return "Looking for ideas…" }
        if !isOn { return "Off" }
        return nil
    }

    var spoken: String {
        if looking { return "Suggested, looking for ideas" }
        if !isOn { return "Suggested, off" }
        return "Suggested, \(count) \(count == 1 ? "idea" : "ideas")"
    }
}

struct TasksOverviewSuggestedModel: Hashable {
    var cards: [TaskIdeaCardModel]
    var totalCount: Int
}

struct TasksOverviewAgentsModel: Hashable {
    var suggested: TasksOverviewSuggestedRowModel?
    var botsCount: Int?

    var isEmpty: Bool { suggested == nil && botsCount == nil }
    var botsIdentifier: String { "tasks.view.bots" }
    var botsSpoken: String {
        let count = botsCount ?? 0
        return "Bots’ Tasks, \(count) \(count == 1 ? "task" : "tasks")"
    }
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
            shape.fill(Color(uiColor: ProjectPageHeader.fill))
                .overlay { if Theme.isDesktop { shape.strokeBorder(Color.hqStroke, lineWidth: HQShape.hairline) } }
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
                            .fill(Color(uiColor: HQPalette.separator))
                            .frame(height: HQShape.line(Theme.isDesktop ? 1 : 0.5))
                            .padding(.leading, 54)
                    }
                }
            }
        }
        .background {
            shape.fill(Color(uiColor: ProjectPageHeader.fill))
                .overlay { if Theme.isDesktop { shape.strokeBorder(Color.hqStroke, lineWidth: HQShape.hairline) } }
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

/// Section header for the inline Suggested Tasks preview on iPhone Overview.
struct TasksOverviewSuggestedHeader: View {
    var count: Int
    var onSeeAll: () -> Void

    var body: some View {
        let _ = Theme.touch()
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "sparkle")
                .font(Font.hq(.caption2).weight(.bold))
                .foregroundStyle(Color.hqOrange)
                .accessibilityHidden(true)
            Text("Suggested · \(count)")
                .font(Font.hq(.footnote).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color.hqLabel2)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button {
                PagesHaptics.selection()
                onSeeAll()
            } label: {
                HStack(spacing: 3) {
                    Text("See all")
                        .font(Font.hq(.footnote).weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(Font.hq(.caption2).weight(.bold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Color.hqTintText)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tasks.overview.suggested.see-all")
        }
        .padding(.horizontal, ListGutter.side + 2)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }
}

/// Inline card showing the top pending suggested tasks right on iPhone Overview, with 1-tap Add / × and tap-to-expand details.
struct TasksOverviewSuggestedCard: View {
    var model: TasksOverviewSuggestedModel
    var open: TaskIdeaOpen
    var enabled: Bool
    var onToggle: (String) -> Void
    var onAdd: (String, Bool) -> Void
    var onDismiss: (String) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .footnote) private var faceSize: CGFloat = 18

    var body: some View {
        let _ = Theme.touch()
        let radius: CGFloat = Theme.isDesktop ? DesktopRows.radius : 14
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        VStack(spacing: 0) {
            ForEach(Array(model.cards.enumerated()), id: \.element.idea.id) { idx, card in
                let isOpen = open.id == card.idea.id
                rowContent(card, expanded: isOpen)
                    .contentShape(Rectangle())
                    .onTapGesture { onToggle(card.idea.id) }
                    .contextMenu {
                        if enabled {
                            Button { onAdd(card.idea.id, false) } label: { Label("Add to Tasks", systemImage: "plus.circle") }
                            if card.idea.botHelps {
                                Button { onAdd(card.idea.id, true) } label: {
                                    Label("Add & Let \(card.botName) Start", systemImage: "play.circle")
                                }
                            }
                            Divider()
                            Button(role: .destructive) { onDismiss(card.idea.id) } label: { Label("Dismiss", systemImage: "xmark.circle") }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("tasks.overview.idea.\(card.idea.title)")

                if idx < model.cards.count - 1 {
                    Rectangle()
                        .fill(Color(uiColor: HQPalette.separator))
                        .frame(height: HQShape.line(Theme.isDesktop ? 1 : 0.5))
                        .padding(.leading, 14)
                }
            }
        }
        .background {
            shape.fill(Color(uiColor: ProjectPageHeader.fill))
                .overlay { if Theme.isDesktop { shape.strokeBorder(Color.hqOrange.opacity(0.28), lineWidth: HQShape.hairline) } }
        }
        .clipShape(shape)
        .padding(.horizontal, ListGutter.side)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tasks.overview.suggested")
    }

    private func subtitle(for card: TaskIdeaCardModel) -> String {
        let idea = card.idea
        if idea.botHelps {
            let can = idea.who == "bot" ? "can do this" : "can help"
            return idea.help.isEmpty ? "\(card.botName) \(can)" : "\(card.botName) \(can): \(idea.help)"
        }
        if !idea.why.isEmpty { return idea.why }
        return idea.source
    }

    private func helpLine(for card: TaskIdeaCardModel) -> Text {
        let idea = card.idea
        let name = Text(card.botName).fontWeight(.semibold).foregroundStyle(Color.hqLabel)
        let can = Text(idea.who == "bot" ? " can do this" : " can help").foregroundStyle(Color.hqLabel)
        guard !idea.help.isEmpty else { return Text("\(name)\(can)") }
        return Text("\(name)\(can)\(Text(" · \(idea.help)").foregroundStyle(Color.hqLabel2))")
    }

    @ViewBuilder
    private func rowContent(_ card: TaskIdeaCardModel, expanded: Bool) -> some View {
        let idea = card.idea
        let large = typeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: expanded ? 8 : 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(idea.title.isEmpty ? "Untitled Idea" : idea.title)
                    .font(Font.hq(.callout).weight(.semibold))
                    .foregroundStyle(Color.hqLabel)
                    .lineLimit(expanded ? nil : (large ? 4 : 2))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !expanded {
                    Button { onAdd(idea.id, false) } label: {
                        HStack(spacing: 4) {
                            if card.busy { ProgressView().controlSize(.mini) }
                            Text("Add")
                        }
                        .font(Font.hq(.footnote).weight(.semibold))
                        .foregroundStyle(Color.hqTintText)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.hqTint.opacity(0.14)))
                        .contentShape(Rectangle().inset(by: -8))
                        .padding(.vertical, -3)
                    }
                    .buttonStyle(.plain)
                    .disabled(!enabled || card.busy)
                    .accessibilityLabel("Add to Tasks")
                    .accessibilityIdentifier("tasks.overview.idea.add.\(idea.title)")
                }
                Button { onDismiss(idea.id) } label: {
                    Image(systemName: "xmark")
                        .font(Font.hq(.footnote).weight(.semibold))
                        .foregroundStyle(Color.hqLabel3)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle().inset(by: -10))
                }
                .buttonStyle(.plain)
                .disabled(!enabled || card.busy)
                .hqIconLabel("Dismiss")
                .accessibilityIdentifier("tasks.overview.idea.dismiss.\(idea.title)")
            }

            if expanded {
                if !idea.why.isEmpty {
                    Text(idea.why)
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if idea.botHelps {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        let size = min(26, faceSize).rounded()
                        HeadImage(raw: card.head, profile: idea.bot, size: size)
                            .frame(width: size, height: size)
                            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + HQFont.preferred(.footnote).capHeight / 2 }
                            .accessibilityHidden(true)
                        helpLine(for: card)
                            .font(Font.hq(.footnote))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !idea.source.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "text.bubble")
                            .accessibilityHidden(true)
                        Text(idea.source)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(Font.hq(.caption))
                    .foregroundStyle(Color.hqLabel3)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { expandedButtons(card) }
                    VStack(alignment: .leading, spacing: 8) { expandedButtons(card) }
                }
                .disabled(!enabled || card.busy)
                .padding(.top, 2)
            } else {
                let line = subtitle(for: card)
                if !line.isEmpty {
                    Text(line)
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                        .lineLimit(large ? 4 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func expandedButtons(_ card: TaskIdeaCardModel) -> some View {
        let idea = card.idea
        Button { onAdd(idea.id, false) } label: {
            HStack(spacing: 5) {
                if card.busy { ProgressView().controlSize(.mini) } else { Image(systemName: "plus") }
                Text("Add")
            }
            .font(Font.hq(.footnote).weight(.semibold))
            .foregroundStyle(Color.hqTintText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.hqTint.opacity(0.15)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add to Tasks")
        .accessibilityIdentifier("tasks.overview.idea.add.\(idea.title)")

        if idea.botHelps {
            Button { onAdd(idea.id, true) } label: {
                Text("Add & Let \(card.botName) Start")
                    .font(Font.hq(.footnote).weight(.semibold))
                    .foregroundStyle(Color.hqTintText)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.hqFill3))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tasks.overview.idea.start.\(idea.title)")
        }
    }
}

/// Agents card on iPhone Overview (Suggested tasks + Bots' own tasks, cleanly separated from user lists).
struct TasksOverviewAgentsCard: View {
    var agents: TasksOverviewAgentsModel
    var onPick: (TodoView) -> Void

    var body: some View {
        let _ = Theme.touch()
        let radius: CGFloat = Theme.isDesktop ? DesktopRows.radius : 14
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        VStack(spacing: 0) {
            if let suggested = agents.suggested {
                Button {
                    PagesHaptics.selection()
                    onPick(.suggested)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkle")
                            .font(Font.hq(.subheadline).weight(.semibold))
                            .foregroundStyle(Color.hqOrange)
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.hqOrange.opacity(0.14)))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Suggested")
                                .font(Font.hq(.body).weight(.medium))
                                .foregroundStyle(Color.hqLabel)
                                .lineLimit(1)
                            if let subtitle = suggested.subtitle {
                                Text(subtitle)
                                    .font(Font.hq(.footnote))
                                    .foregroundStyle(Color.hqLabel2)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        if suggested.isOn {
                            Text("\(suggested.count)")
                                .font(Font.hq(.subheadline))
                                .monospacedDigit()
                                .foregroundStyle(Color.hqLabel2)
                        }
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
                .accessibilityLabel(suggested.spoken)
                .accessibilityIdentifier(suggested.identifier)
            }

            if agents.suggested != nil && agents.botsCount != nil {
                Rectangle()
                    .fill(Color(uiColor: HQPalette.separator))
                    .frame(height: HQShape.line(Theme.isDesktop ? 1 : 0.5))
                    .padding(.leading, 54)
            }

            if let botsCount = agents.botsCount {
                Button {
                    PagesHaptics.selection()
                    onPick(.bots)
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
                        Text("\(botsCount)")
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
                .accessibilityLabel(agents.botsSpoken)
                .accessibilityIdentifier(agents.botsIdentifier)
            }
        }
        .background {
            shape.fill(Color(uiColor: ProjectPageHeader.fill))
                .overlay { if Theme.isDesktop { shape.strokeBorder(Color.hqStroke, lineWidth: HQShape.hairline) } }
        }
        .clipShape(shape)
        .padding(.horizontal, ListGutter.side)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tasks.overview.agents")
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

                if let agents = model.agents, !agents.isEmpty {
                    sectionHeading("Agents")
                        .padding(.top, 12)
                    if let suggested = agents.suggested {
                        let isPicked = model.picked == .suggested
                        sidebarRow(
                            title: "Suggested",
                            count: suggested.isOn ? suggested.count : nil,
                            picked: isPicked,
                            spoken: suggested.spoken,
                            identifier: suggested.identifier,
                            icon: {
                                Image(systemName: "sparkle")
                                    .font(Font.hq(.footnote).weight(.semibold))
                                    .foregroundStyle(isPicked ? Color.hqOnTint : Color.hqOrange)
                                    .frame(width: 18)
                            },
                            action: { onPick(.suggested) }
                        )
                    }
                    if let botsCount = agents.botsCount {
                        let isPicked = model.picked == .bots
                        sidebarRow(
                            title: "Bots’ Tasks",
                            count: botsCount,
                            picked: isPicked,
                            spoken: agents.botsSpoken,
                            identifier: agents.botsIdentifier,
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
