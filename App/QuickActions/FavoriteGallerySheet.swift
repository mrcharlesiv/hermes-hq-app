// [quick-actions] Visual "Add to Favorites" gallery (iOS Widget Gallery style):
// 1. Hero: "Build a Custom Tile with Hermes" (launches `NewTileSheet` + auto-adds to Favorites).
// 2. Live Widget Carousel: real live-data previews of every native card, tap to configure size or one-tap Add.
// 3. Starter Layouts Strip: miniature Bento wireframe previews of all presets.
// 4. Dashboard Tiles Carousel: real rendered thumbnails of pinned Dashboard tiles.
// 5. Quick Actions, Smart Shortcuts, Pages, and Section Headers — all searchable in one view.

import SwiftUI
import UIKit

enum FavoriteGallerySheet {
    static func make(
        liveModel: FavoritesLiveModel,
        pageId: String,
        choices: @escaping () -> [MoreSection],
        tiles: [QuickActionChoice],
        source: FavoriteTiles?,
        onAddTile: @escaping (QuickTile) -> Void,
        onApplyPreset: @escaping ([QuickTile], Bool) -> Void,
        onCreateCustomTile: @escaping () -> Void
    ) -> UINavigationController {
        let pictures = source.map(FavoriteTilePictures.init)
        let host = FavoriteGalleryHost(
            liveModel: liveModel,
            pageId: pageId,
            choices: choices,
            tiles: tiles,
            pictures: pictures,
            onAddTile: onAddTile,
            onApplyPreset: onApplyPreset,
            onCreateCustomTile: onCreateCustomTile
        )
        let nav = ChatSheet.wrap(host, title: "Add to Favorites", detents: [.large()])
        nav.sheetPresentationController?.selectedDetentIdentifier = .large
        nav.view.accessibilityIdentifier = "favorites.gallery-sheet"
        return nav
    }
}

private final class FavoriteGalleryHost: UIHostingController<HQScaledRoot<FavoriteGalleryView>> {
    private let pictures: FavoriteTilePictures?
    private let onAddTile: (QuickTile) -> Void
    private let onApplyPreset: ([QuickTile], Bool) -> Void
    private let onCreateCustomTile: () -> Void
    private let pageId: String

    init(
        liveModel: FavoritesLiveModel,
        pageId: String,
        choices: @escaping () -> [MoreSection],
        tiles: [QuickActionChoice],
        pictures: FavoriteTilePictures?,
        onAddTile: @escaping (QuickTile) -> Void,
        onApplyPreset: @escaping ([QuickTile], Bool) -> Void,
        onCreateCustomTile: @escaping () -> Void
    ) {
        self.pictures = pictures
        self.onAddTile = onAddTile
        self.onApplyPreset = onApplyPreset
        self.onCreateCustomTile = onCreateCustomTile
        self.pageId = pageId
        weak var weakSelf: FavoriteGalleryHost?
        let view = FavoriteGalleryView(
            liveModel: liveModel,
            pageSections: choices(),
            dashboardTiles: tiles,
            pictures: pictures,
            onQuickAdd: { tile in
                PagesHaptics.success()
                weakSelf?.finishAdding(tile)
            },
            onConfigure: { choice in
                weakSelf?.openSetup(for: choice)
            },
            onApplyPreset: { preset in
                weakSelf?.applyPreset(preset)
            },
            onCreateCustomTile: {
                weakSelf?.dismiss(animated: true) {
                    onCreateCustomTile()
                }
            }
        )
        super.init(rootView: HQScaledRoot(view))
        weakSelf = self
        title = "Add to Favorites"
        navigationItem.largeTitleDisplayMode = .never
        let close = UIBarButtonItem.hqClose(.close, action: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        close.accessibilityIdentifier = "favorites.gallery.close"
        navigationItem.hqPlaceFormClose(close)
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func finishAdding(_ tile: QuickTile) {
        var stamped = tile
        if pageId != FavoritePage.mainId { stamped.pageId = pageId }
        dismiss(animated: true) { [onAddTile] in onAddTile(stamped) }
    }

    private func openSetup(for choice: QuickActionChoice) {
        PagesHaptics.selection()
        let setup = QuickActionSetup.page(
            tile: choice.newTile(),
            isNew: true,
            pictures: choice.kind == .dashboardTile ? pictures : nil
        ) { [weak self] saved in
            PagesHaptics.success()
            self?.finishAdding(saved)
        }
        navigationController?.pushViewController(setup, animated: true)
    }

    private func applyPreset(_ preset: FavoritePreset) {
        let bot = MainTabController.current?.services.bots.first.map { (profile: $0.id, name: $0.name) }
        let goal = TasksHub.current?.goals.first { $0.state == .active }.map { (id: $0.id, title: $0.title) }
        let tiles = preset.tiles(bot: bot, goal: goal, pageId: pageId)
        PagesHaptics.success()
        dismiss(animated: true) { [onApplyPreset] in onApplyPreset(tiles, false) }
    }
}

private struct FavoriteGalleryView: View {
    var liveModel: FavoritesLiveModel
    var pageSections: [MoreSection]
    var dashboardTiles: [QuickActionChoice]
    var pictures: FavoriteTilePictures?
    var onQuickAdd: (QuickTile) -> Void
    var onConfigure: (QuickActionChoice) -> Void
    var onApplyPreset: (FavoritePreset) -> Void
    var onCreateCustomTile: () -> Void

    @State private var query = ""

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private struct WidgetPreviewSpec: Identifiable {
        let id: String
        let kind: QuickTileKind
        let title: String
        let subtitle: String
        let defaultSize: QuickTileSize
        let choice: QuickActionChoice
    }

    private static func makeChoice(_ kind: QuickTileKind, _ title: String, _ detail: String) -> QuickActionChoice {
        QuickActionChoice(
            id: kind.rawValue,
            kind: kind,
            title: title,
            detail: detail,
            symbol: kind.defaultLook.symbol,
            color: QuickTileLook.color(kind.defaultLook.color)
        )
    }

    private var widgetSpecs: [WidgetPreviewSpec] {
        let all: [WidgetPreviewSpec] = [
            .init(id: "needs-you", kind: .needsYou, title: "Needs You", subtitle: "Approvals, tasks & failed jobs", defaultSize: .wide,
                  choice: Self.makeChoice(.needsYou, "Needs You", "Waiting bots, tasks & jobs")),
            .init(id: "tasks", kind: .tasks, title: "Today’s Tasks", subtitle: "Live checklist with check-off", defaultSize: .wide,
                  choice: Self.makeChoice(.tasks, "Tasks List", "Today, Upcoming, or any list")),
            .init(id: "approvals", kind: .approvals, title: "Approvals", subtitle: "One-tap Allow / Deny & questions", defaultSize: .wide,
                  choice: Self.makeChoice(.approvals, "Approvals & Questions", "Approve tools & answer bots inline")),
            .init(id: "inline-ask", kind: .inlineAsk, title: "Inline Ask", subtitle: "Ask a bot right on Favorites", defaultSize: .wide,
                  choice: Self.makeChoice(.inlineAsk, "Inline Ask", "Type and read replies in place")),
            .init(id: "active-runs", kind: .activeRuns, title: "Active Now", subtitle: "Live bots & running helpers", defaultSize: .wide,
                  choice: Self.makeChoice(.activeRuns, "Active Now", "Running bots & subagents")),
            .init(id: "bot-card", kind: .botCard, title: "Live Bot", subtitle: "Status + Memo / Talk / New pills", defaultSize: .wide,
                  choice: Self.makeChoice(.botCard, "Live Bot Card", "Bot status & quick actions")),
            .init(id: "goal", kind: .goal, title: "Goal Progress", subtitle: "Ring, pace & next task tick", defaultSize: .wide,
                  choice: Self.makeChoice(.goal, "Goal Progress", "Ring, pace & inline check-off")),
            .init(id: "gateway-status", kind: .gatewayStatus, title: "Gateway", subtitle: "Health, sessions & platforms", defaultSize: .small,
                  choice: Self.makeChoice(.gatewayStatus, "Gateway", "Health, sessions & platforms")),
            .init(id: "usage", kind: .usage, title: "Usage", subtitle: "Tokens, cost & sparkline", defaultSize: .small,
                  choice: Self.makeChoice(.usage, "Usage", "Tokens, cost & chart")),
            .init(id: "job-card", kind: .jobCard, title: "Jobs", subtitle: "Upcoming jobs or Run Now", defaultSize: .wide,
                  choice: Self.makeChoice(.jobCard, "Job Status", "Single job or upcoming overview")),
            .init(id: "kanban", kind: .kanban, title: "Kanban", subtitle: "Board counts & top cards", defaultSize: .wide,
                  choice: Self.makeChoice(.kanban, "Kanban Board", "Live board or column counts")),
            .init(id: "live-peek", kind: .livePeek, title: "Browser & Screen", subtitle: "Watch bots browse or use screen", defaultSize: .wide,
                  choice: Self.makeChoice(.livePeek, "Browser & Screen", "Live peek & one-tap Watch")),
            .init(id: "group-chat", kind: .groupChat, title: "Group Chat", subtitle: "Live room status & preview", defaultSize: .small,
                  choice: Self.makeChoice(.groupChat, "Group Chat", "Live group chat card")),
            .init(id: "chat-session", kind: .chatSession, title: "Pinned Chat", subtitle: "Pin any specific conversation", defaultSize: .small,
                  choice: Self.makeChoice(.chatSession, "Pinned Chat", "Jump straight to one session")),
        ]
        guard !trimmed.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed) || $0.subtitle.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var actionGroups: [(title: String, items: [QuickActionChoice])] {
        let base: [(String, [QuickActionChoice])] = [
            ("Quick Actions", QuickActionChoice.chats + QuickActionChoice.work),
            ("Smart Shortcuts & Organize", QuickActionChoice.shortcuts + QuickActionChoice.organize),
        ]
        let pages = QuickActionChoice.pages(pageSections)
        let combined = pages.isEmpty ? base : base + [("App Pages", pages)]
        guard !trimmed.isEmpty else { return combined }
        return combined.compactMap { title, items in
            let hit = items.filter { $0.matches(trimmed) }
            return hit.isEmpty ? nil : (title, hit)
        }
    }

    private var matchingDashboardTiles: [QuickActionChoice] {
        guard !trimmed.isEmpty else { return dashboardTiles }
        return dashboardTiles.filter { $0.matches(trimmed) }
    }

    var body: some View {
        let _ = Theme.touch()
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if trimmed.isEmpty {
                    customTileHero
                        .padding(.horizontal, 16)
                }

                if !widgetSpecs.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        galleryHeader("Live Cards", detail: "Tap a preview to customize, or + to add right away")
                            .padding(.horizontal, 16)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(widgetSpecs) { spec in
                                    widgetGalleryItem(spec)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }

                if trimmed.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        galleryHeader("Starter Layouts", detail: "Complete setups you can drop onto this page")
                            .padding(.horizontal, 16)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(FavoritePreset.allCases) { preset in
                                    presetGalleryCard(preset)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }

                if !matchingDashboardTiles.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        galleryHeader("Your Dashboard Tiles", detail: "Live HTML & bot-made tiles")
                            .padding(.horizontal, 16)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(matchingDashboardTiles) { choice in
                                    dashboardTileGalleryCard(choice)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }

                ForEach(actionGroups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        galleryHeader(group.title, detail: nil)
                            .padding(.horizontal, 16)
                        VStack(spacing: 0) {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { idx, item in
                                Button { onConfigure(item) } label: {
                                    HStack(spacing: 12) {
                                        QuickTileIcon(symbol: item.symbol, color: item.color, side: HQFont.scaled(30))
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.title)
                                                .font(Font.hq(.body).weight(.medium))
                                                .foregroundStyle(Color.hqLabel)
                                                .lineLimit(1)
                                            Text(item.detail)
                                                .font(Font.hq(.footnote))
                                                .foregroundStyle(Color.hqLabel2)
                                                .lineLimit(1)
                                        }
                                        Spacer(minLength: 4)
                                        Image(systemName: "chevron.right")
                                            .font(Font.hq(.caption).weight(.semibold))
                                            .foregroundStyle(Color.hqLabel3)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("favorites.gallery.\(item.id)")
                                if idx < group.items.count - 1 {
                                    Divider().overlay(Color.hqStroke).padding(.leading, 56)
                                }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: HQPalette.sheetCard)))
                        .padding(.horizontal, 16)
                    }
                }

                if widgetSpecs.isEmpty && matchingDashboardTiles.isEmpty && actionGroups.isEmpty {
                    Text("No widgets, actions, or pages match “\(trimmed)”.")
                        .font(Font.hq(.body))
                        .foregroundStyle(Color.hqLabel2)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }
            }
            .padding(.vertical, 12)
        }
        .background(Color(uiColor: HQPalette.sheetPage))
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search widgets, tiles, actions & pages")
    }

    private func galleryHeader(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Font.hq(.headline))
                .foregroundStyle(Color.hqLabel)
            if let detail {
                Text(detail)
                    .font(Font.hq(.caption))
                    .foregroundStyle(Color.hqLabel2)
            }
        }
    }

    private var customTileHero: some View {
        Button { onCreateCustomTile() } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.hqTint.gradient)
                        .frame(width: HQFont.scaled(46), height: HQFont.scaled(46))
                    Image(systemName: "sparkles")
                        .font(Font.hq(.title3).weight(.semibold))
                        .foregroundStyle(Color.hqOnTint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Build a Custom Tile")
                        .font(Font.hq(.subheadline).weight(.semibold))
                        .foregroundStyle(Color.hqLabel)
                    Text("Describe a tracker, PR list, or live chart and Hermes builds it right here.")
                        .font(Font.hq(.caption))
                        .foregroundStyle(Color.hqLabel2)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Text("Create")
                    .font(Font.hq(.caption).weight(.semibold))
                    .foregroundStyle(Color.hqOnTint)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.hqTint))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(uiColor: HQPalette.sheetCard))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.hqTint.opacity(0.28), lineWidth: 1))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("favorites.gallery.create-custom-tile")
    }

    private func widgetGalleryItem(_ spec: WidgetPreviewSpec) -> some View {
        let previewTile = sampleTile(for: spec)
        let canQuickAdd = (!spec.kind.needsBot && spec.kind != .goal && spec.kind != .groupChat && spec.kind != .chatSession)
            || (spec.kind.needsBot && liveModel.bots.first != nil)
        let cardWidth: CGFloat = spec.defaultSize == .small ? 176 : 258
        let cardHeight: CGFloat = 152

        return VStack(alignment: .leading, spacing: 8) {
            Button { onConfigure(spec.choice) } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(uiColor: HQPalette.sheetCard))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.hqStroke, lineWidth: 1))
                    livePreview(for: previewTile, size: spec.defaultSize)
                        .allowsHitTesting(false)
                }
                .frame(width: cardWidth, height: cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("favorites.gallery.widget.\(spec.id)")

            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(spec.title)
                        .font(Font.hq(.footnote).weight(.semibold))
                        .foregroundStyle(Color.hqLabel)
                        .lineLimit(1)
                    Text(spec.subtitle)
                        .font(Font.hq(.caption2))
                        .foregroundStyle(Color.hqLabel2)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if canQuickAdd {
                    Button { onQuickAdd(previewTile) } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(Font.hq(.title3))
                            .foregroundStyle(Color.hqTint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add \(spec.title)")
                }
            }
            .frame(width: cardWidth)
        }
    }

    private func sampleTile(for spec: WidgetPreviewSpec) -> QuickTile {
        let lead = liveModel.bots.first
        let goal = TasksHub.current?.goals.first { $0.state == .active }
        var tile = QuickTile(kind: spec.kind, name: spec.title, size: spec.defaultSize)
        if spec.kind.needsBot, let lead {
            tile.bot = lead.id
            tile.botName = lead.name
        }
        if spec.kind == .tasks { tile.taskView = "today"; tile.taskViewName = "Today" }
        if spec.kind == .goal, let goal { tile.goalId = goal.id; tile.goalName = goal.title; tile.name = goal.title }
        if spec.kind == .botCard, let lead { tile.name = lead.name }
        if spec.kind == .inlineAsk, let lead { tile.name = "Ask \(lead.name)" }
        if spec.kind == .usage { tile.days = 7 }
        return tile
    }

    @ViewBuilder
    private func livePreview(for tile: QuickTile, size: QuickTileSize) -> some View {
        switch tile.known {
        case .tasks:
            FavoriteTasksCard(tile: tile, model: liveModel, size: size, dimmed: false, onOpenTask: { _ in }, onAddTask: {})
        case .goal:
            FavoriteGoalCard(tile: tile, model: liveModel, size: size, dimmed: false)
        case .needsYou:
            FavoriteNeedsYouCard(tile: tile, model: liveModel, size: size, hasTodayTasksCard: false, onSelect: { _ in }, onRetryJob: { _, _ in })
        case .botCard:
            FavoriteBotCard(tile: tile, model: liveModel, size: size, dimmed: false, onMemo: {}, onTalk: {}, onNewChat: {})
        case .groupChat:
            FavoriteGroupChatCard(tile: tile, model: liveModel, size: size, dimmed: false)
        case .chatSession:
            FavoriteChatSessionCard(tile: tile, model: liveModel, size: size, dimmed: false)
        case .jobCard:
            FavoriteJobCard(tile: tile, model: liveModel, size: size, dimmed: false, onRunNow: { _, _ in })
        case .kanban:
            FavoriteKanbanCard(tile: tile, model: liveModel, size: size, dimmed: false)
        case .gatewayStatus:
            FavoriteGatewayStatusCard(tile: tile, model: liveModel, size: size)
        case .usage:
            FavoriteUsageCard(tile: tile, model: liveModel, size: size)
        case .approvals:
            FavoriteApprovalsCard(tile: tile, model: liveModel, size: size, onOpenBot: { _ in })
        case .activeRuns:
            FavoriteActiveRunsCard(tile: tile, model: liveModel, size: size, onOpenBot: { _ in })
        case .inlineAsk:
            FavoriteInlineAskCard(tile: tile, model: liveModel, size: size, dimmed: false, onOpenChat: { _ in })
        case .livePeek:
            FavoriteLivePeekCard(tile: tile, model: liveModel, size: size, onOpenBrowser: { _ in }, onOpenScreen: { _ in })
        default:
            EmptyView()
        }
    }

    private func presetGalleryCard(_ preset: FavoritePreset) -> some View {
        Button { onApplyPreset(preset) } label: {
            VStack(alignment: .leading, spacing: 8) {
                FavoritePresetThumbnail(preset: preset)
                    .frame(width: 132, height: 102)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.title)
                        .font(Font.hq(.footnote).weight(.semibold))
                        .foregroundStyle(Color.hqLabel)
                        .lineLimit(1)
                    Text(preset.subtitle)
                        .font(Font.hq(.caption2))
                        .foregroundStyle(Color.hqLabel2)
                        .lineLimit(2)
                }
                .frame(width: 132, alignment: .leading)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(uiColor: HQPalette.sheetCard))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.hqStroke, lineWidth: 1))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("favorites.gallery.preset.\(preset.rawValue)")
    }

    private func dashboardTileGalleryCard(_ choice: QuickActionChoice) -> some View {
        Button { onConfigure(choice) } label: {
            VStack(alignment: .leading, spacing: 6) {
                if let pin = choice.pin {
                    DashboardTileThumb(pin: pin, pictures: pictures, side: 120)
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.hqFill3)
                        .frame(width: 120, height: 120)
                        .overlay(Image(systemName: "chart.xyaxis.line").foregroundStyle(Color.hqTint))
                }
                Text(choice.title)
                    .font(Font.hq(.caption).weight(.semibold))
                    .foregroundStyle(Color.hqLabel)
                    .lineLimit(1)
                    .frame(width: 120, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("favorites.gallery.tile.\(choice.id)")
    }
}
