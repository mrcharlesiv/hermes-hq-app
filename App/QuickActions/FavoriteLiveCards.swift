// [quick-actions] Native live widget cards, Mini action tiles, and collapsible Section Headers for Favorites.
// Reuses Hermes HQ's own card grammar (`GoalRing`, `GoalTeamFaces`, `HeadImage`, `GroupAvatar`, `TasksWidgetFrame`,
// `BotList.secondLine`, `KanbanModel`, Swift Charts) with theme-aware colors and Dynamic Type scaling.

import Charts
import SwiftUI
import UIKit

// MARK: - Section Header

struct FavoriteSectionHeaderView: View {
    var title: String
    var collapsed: Bool
    var itemCount: Int
    var editing: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title.isEmpty ? "Section" : title)
                .font(Font.hq(.footnote).weight(.semibold))
                .foregroundStyle(Color.hqLabel2)
                .textCase(.uppercase)
                .lineLimit(1)
            if collapsed && itemCount > 0 {
                Text("\(itemCount)")
                    .font(Font.hq(.caption2).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.hqLabel2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.hqFill3))
            }
            Spacer(minLength: 8)
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(Font.hq(.caption).weight(.semibold))
                .foregroundStyle(Color.hqLabel3)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Mini Action Tile (compact 4-across launcher strip)

struct QuickTileMiniFace: View {
    var name: String
    var symbol: String
    var color: UIColor
    var dimmed = false
    var botAvatar: (profile: String, head: JSONValue?)? = nil
    var badge: FavoritesLiveModel.PageBadge? = nil
    var running = false
    var feedback: FavoritesLiveModel.ActionFeedback? = nil

    var body: some View {
        let iconSide = HQFont.scaled(32)
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                if let botAvatar {
                    HeadImage(raw: botAvatar.head, profile: botAvatar.profile, size: iconSide)
                        .frame(width: iconSide, height: iconSide)
                } else {
                    QuickTileIcon(symbol: symbol, color: color, side: iconSide)
                }
                if running {
                    ProgressView().controlSize(.mini)
                        .padding(3)
                        .background(Circle().fill(Color(uiColor: HQPalette.card)))
                        .offset(x: 6, y: -4)
                } else if let feedback {
                    Image(systemName: feedback.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(Font.hq(.caption2).weight(.bold))
                        .foregroundStyle(feedback.ok ? Color.hqGreen : Color.hqRed)
                        .background(Circle().fill(Color(uiColor: HQPalette.card)))
                        .offset(x: 5, y: -4)
                } else if let badge {
                    TileBadgePill(badge: badge)
                        .offset(x: 6, y: -4)
                }
            }
            Text(name.isEmpty ? " " : name)
                .font(Font.hq(.caption).weight(.semibold))
                .foregroundStyle(Color.hqLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .opacity(dimmed ? 0.4 : 1)
    }
}

// MARK: - Shared Card Chrome Helpers

struct TileBadgePill: View {
    var badge: FavoritesLiveModel.PageBadge

    private var fill: Color {
        switch badge.tone {
        case .tint: Color.hqTint
        case .orange: Color.hqOrange
        case .red: Color.hqRed
        case .spinner: Color.hqFill3
        }
    }

    var body: some View {
        if badge.tone == .spinner {
            ProgressView().controlSize(.mini)
                .padding(4)
                .background(Circle().fill(Color.hqFill3))
        } else if let text = badge.text, !text.isEmpty {
            Text(text)
                .font(Font.hq(.caption2).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(fill))
                .accessibilityHidden(true)
        } else {
            Circle().fill(fill).frame(width: 8, height: 8)
                .accessibilityHidden(true)
        }
    }
}

private struct LiveCardHeader<Trailing: View>: View {
    var symbol: String
    var tint: Color
    var title: String
    var detail: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(Font.hq(.footnote).weight(.semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
                .font(Font.hq(.subheadline).weight(.semibold))
                .foregroundStyle(Color.hqLabel)
                .lineLimit(1)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(Font.hq(.caption))
                    .foregroundStyle(Color.hqLabel2)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            trailing()
        }
    }
}

private extension LiveCardHeader where Trailing == EmptyView {
    init(symbol: String, tint: Color, title: String, detail: String? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, detail: detail, trailing: { EmptyView() })
    }
}

// MARK: - 1. Live Tasks Card

struct FavoriteTasksCard: View {
    var tile: QuickTile
    var model: FavoritesLiveModel
    var size: QuickTileSize
    var dimmed: Bool
    var onOpenTask: (String) -> Void
    var onAddTask: () -> Void

    private var viewKey: String { tile.taskView?.nilIfEmpty ?? "today" }

    private var maxRows: Int {
        switch size {
        case .small: 2
        case .wide, .banner: 3
        case .tallCard: 6
        case .large, .extraLarge: 7
        case .mini: 1
        }
    }

    var body: some View {
        let _ = Theme.touch()
        let snapshot = model.tasksFrame(viewKey: viewKey)
        let title = tile.name.isEmpty ? (snapshot?.name ?? "Today") : tile.name
        let tint = Color(uiColor: QuickTileLook.color(tile.tint))
        let symbol = snapshot.map { TasksNavigationLayout.symbol(for: $0.view, sections: TasksHub.current?.sections ?? []) } ?? "checklist"

        VStack(alignment: .leading, spacing: 8) {
            LiveCardHeader(symbol: symbol, tint: tint, title: title) {
                if let frame = snapshot?.frame {
                    HStack(spacing: 6) {
                        if frame.waiting > 0 {
                            Text("\(frame.waiting)")
                                .font(Font.hq(.caption).weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.hqOrange))
                        } else if frame.count > 0 {
                            Text("\(frame.count)")
                                .font(Font.hq(.caption).weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(Color.hqLabel2)
                        }
                        if size != .small {
                            Button { onAddTask() } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(Font.hq(.body))
                                    .foregroundStyle(Color.hqTint)
                                    .contentShape(Rectangle().inset(by: -6))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Add Task")
                        }
                    }
                }
            }

            if let frame = snapshot?.frame {
                let rows = frame.sections.flatMap(\.rows)
                if rows.isEmpty {
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(Font.hq(.title3))
                            .foregroundStyle(Color.hqGreen)
                            .accessibilityHidden(true)
                        Text(frame.empty)
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqLabel2)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                } else if size == .small {
                    let headline = TasksWidgetLayout.headline(frame, view: title)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(headline.number)")
                            .font(Font.hq(.title2).weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(headline.waiting ? Color.hqOrange : Color.hqLabel)
                        Text(headline.waiting ? "waiting" : "open")
                            .font(Font.hq(.caption))
                            .foregroundStyle(headline.waiting ? Color.hqOrange : Color.hqLabel2)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(rows.prefix(maxRows))) { row in
                            taskRow(row, compact: true)
                        }
                    }
                    Spacer(minLength: 0)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(rows.prefix(maxRows))) { row in
                            taskRow(row, compact: false)
                        }
                    }
                    Spacer(minLength: 0)
                    let overflow = max(0, frame.total - min(rows.count, maxRows))
                    if overflow > 0 {
                        Text("+\(overflow) more")
                            .font(Font.hq(.caption))
                            .foregroundStyle(Color.hqLabel2)
                    }
                }
            } else {
                Spacer(minLength: 0)
                Text("Open Tasks to connect your list.")
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(dimmed ? 0.4 : 1)
    }

    @ViewBuilder
    private func taskRow(_ row: TasksWidgetRow, compact: Bool) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Button { model.toggleTaskDone(row.id) } label: {
                Image(systemName: row.done ? "checkmark.circle.fill" : "circle")
                    .font(Font.hq(compact ? .footnote : .callout))
                    .foregroundStyle(row.done ? Color.hqTint : (row.late ? Color.hqRed : Color.hqLabel3))
                    .contentShape(Rectangle().inset(by: -8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark \(row.title) Done")

            Button { onOpenTask(row.id) } label: {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title)
                            .font(Font.hq(compact ? .caption : .subheadline))
                            .foregroundStyle(row.done ? Color.hqLabel2 : Color.hqLabel)
                            .strikethrough(row.done, color: Color.hqLabel3)
                            .lineLimit(1)
                        if !compact, let note = row.note, !note.isEmpty {
                            Text(note)
                                .font(Font.hq(.caption2))
                                .foregroundStyle(row.tone == "needsYou" || row.tone == "ready" ? Color.hqOrange : Color.hqLabel2)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 2)
                    if !compact, let when = row.when, !when.isEmpty {
                        Text(when)
                            .font(Font.hq(.caption2))
                            .foregroundStyle(row.late ? Color.hqRed : Color.hqLabel2)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - 2. Live Goal Card

struct FavoriteGoalCard: View {
    var tile: QuickTile
    var model: FavoritesLiveModel
    var size: QuickTileSize
    var dimmed: Bool

    var body: some View {
        let _ = Theme.touch()
        let goal = model.goalModel(tile.goalId)
        VStack(alignment: .leading, spacing: 10) {
            if let goal {
                HStack(alignment: .center, spacing: 10) {
                    GoalRing(fraction: goal.fraction, color: goal.color, size: HQFont.scaled(size == .small ? 32 : 38), quiet: goal.greyRing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tile.name.isEmpty ? goal.title : tile.name)
                            .font(Font.hq(.subheadline).weight(.semibold))
                            .foregroundStyle(goal.quiet ? Color.hqLabel2 : Color.hqLabel)
                            .lineLimit(size == .small ? 2 : 1)
                        HStack(spacing: 4) {
                            Text(goal.line)
                                .font(Font.hq(.caption))
                                .foregroundStyle(Color.hqLabel2)
                                .lineLimit(1)
                            if let pace = goal.pace {
                                Text("· \(pace.words)")
                                    .font(Font.hq(.caption).weight(.medium))
                                    .foregroundStyle(pace.tone.ink)
                                    .lineLimit(1)
                            }
                        }
                        if let stall = goal.stall, size != .small {
                            Text(stall)
                                .font(Font.hq(.caption2))
                                .foregroundStyle(Color.hqOrange)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if size != .small, !goal.team.isEmpty {
                        GoalTeamFaces(team: goal.team, look: goal.look, waits: goal.waits, size: HQFont.scaled(22))
                    }
                }

                Spacer(minLength: 0)

                if let next = goal.next {
                    Divider().overlay(Color.hqStroke)
                    HStack(spacing: 8) {
                        Button { model.toggleTaskDone(next.id) } label: {
                            Image(systemName: goal.ticking ? "checkmark.circle.fill" : "circle")
                                .font(Font.hq(.callout))
                                .foregroundStyle(goal.ticking ? Color.hqTint : Color.hqLabel3)
                                .contentShape(Rectangle().inset(by: -8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Mark \(next.title) Done")
                        Text(next.title)
                            .font(Font.hq(.footnote))
                            .foregroundStyle(goal.ticking ? Color.hqLabel2 : Color.hqLabel)
                            .strikethrough(goal.ticking, color: Color.hqLabel3)
                            .lineLimit(size == .small ? 2 : 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if goal.planWaits {
                    Divider().overlay(Color.hqStroke)
                    Label(GoalShelfNext.planWords, systemImage: "list.bullet.rectangle")
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqOrange)
                        .lineLimit(1)
                }
            } else {
                LiveCardHeader(symbol: "target", tint: Color.hqGreen, title: tile.name.isEmpty ? "Goal" : tile.name)
                Spacer(minLength: 0)
                Text("Choose an active goal in Edit.")
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(dimmed ? 0.4 : 1)
    }
}

// MARK: - 3. Dynamic "Needs You / Active Now" Card

struct FavoriteNeedsYouCard: View {
    var tile: QuickTile
    var model: FavoritesLiveModel
    var size: QuickTileSize
    var onSelect: (FavoritesLiveModel.AttentionItem) -> Void

    private var maxItems: Int {
        switch size {
        case .small: 2
        case .wide, .banner: 3
        case .tallCard: 5
        case .large, .extraLarge: 6
        case .mini: 1
        }
    }

    var body: some View {
        let _ = Theme.touch()
        let items = model.attentionItems()
        let urgentCount = items.count(where: \.urgent)
        let title = tile.name.isEmpty ? "Needs You" : tile.name

        VStack(alignment: .leading, spacing: 8) {
            LiveCardHeader(
                symbol: urgentCount > 0 ? "bell.badge.fill" : "checkmark.seal.fill",
                tint: urgentCount > 0 ? Color.hqOrange : Color.hqGreen,
                title: title
            ) {
                if urgentCount > 0 {
                    Text("\(urgentCount)")
                        .font(Font.hq(.caption).weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.hqOrange))
                } else if let subs = model.activeSubagents, subs > 0 {
                    Text("\(subs) active")
                        .font(Font.hq(.caption2).weight(.semibold))
                        .foregroundStyle(Color.hqTintText)
                }
            }

            if items.isEmpty {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 3) {
                    Text("All caught up")
                        .font(Font.hq(.headline))
                        .foregroundStyle(Color.hqLabel)
                    Text("Approvals, waiting tasks, and running bots appear here.")
                        .font(Font.hq(.caption))
                        .foregroundStyle(Color.hqLabel2)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(items.prefix(maxItems))) { item in
                        Button { onSelect(item) } label: {
                            HStack(spacing: 8) {
                                if let profile = item.profile {
                                    HeadImage(raw: item.head, profile: profile, size: HQFont.scaled(22))
                                        .frame(width: HQFont.scaled(22), height: HQFont.scaled(22))
                                } else {
                                    Image(systemName: item.symbol)
                                        .font(Font.hq(.footnote).weight(.semibold))
                                        .foregroundStyle(item.urgent ? Color.hqOrange : Color.hqTint)
                                        .frame(width: HQFont.scaled(22), height: HQFont.scaled(22))
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title)
                                        .font(Font.hq(.footnote).weight(.semibold))
                                        .foregroundStyle(Color.hqLabel)
                                        .lineLimit(1)
                                    Text(item.detail)
                                        .font(Font.hq(.caption2))
                                        .foregroundStyle(item.urgent ? Color.hqOrange : Color.hqLabel2)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 2)
                                Image(systemName: "chevron.right")
                                    .font(Font.hq(.caption2).weight(.semibold))
                                    .foregroundStyle(Color.hqLabel3)
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
                if items.count > maxItems {
                    Text("+\(items.count - maxItems) more")
                        .font(Font.hq(.caption))
                        .foregroundStyle(Color.hqLabel2)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - 4. Live Bot Card (with Avatar, Live Status & Quick Actions)

struct FavoriteBotCard: View {
    var tile: QuickTile
    var model: FavoritesLiveModel
    var size: QuickTileSize
    var dimmed: Bool
    var onMemo: () -> Void
    var onTalk: () -> Void
    var onNewChat: () -> Void

    var body: some View {
        let _ = Theme.touch()
        let bot = model.bot(tile.bot)
        let name = tile.name.isEmpty ? (bot?.name ?? tile.botName ?? "Bot") : tile.name
        let fallbackTone: BotList.Tone = .secondary
        let line = bot.map(BotList.secondLine) ?? (text: dimmed ? "Not on this gateway" : "Tap to open chat", tone: fallbackTone)
        let lineColor: Color = switch line.tone {
        case .attention: Color.hqOrange
        case .tint: Color.hqTintText
        case .secondary: Color.hqLabel2
        }
        let faceSize = HQFont.scaled(size == .small ? 42 : 46)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    HeadImage(raw: bot?.head, profile: bot?.id ?? tile.bot ?? "default", size: faceSize)
                        .frame(width: faceSize, height: faceSize)
                    if bot?.needsInput != nil || bot?.attention != nil {
                        Circle().fill(Color.hqOrange).frame(width: 11, height: 11)
                            .overlay(Circle().stroke(Color(uiColor: HQPalette.card), lineWidth: 2))
                    } else if bot?.unread == true {
                        Circle().fill(Color.hqTint).frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Color(uiColor: HQPalette.card), lineWidth: 2))
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(Font.hq(.headline))
                            .foregroundStyle(Color.hqLabel)
                            .lineLimit(1)
                        if bot?.isWorking == true {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    Text(line.text)
                        .font(Font.hq(.footnote))
                        .foregroundStyle(lineColor)
                        .lineLimit(size == .small ? 3 : 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)

            if size != .small && !dimmed {
                HStack(spacing: 8) {
                    quickPill("Memo", symbol: "mic.fill", tint: Color.hqRed, action: onMemo)
                    quickPill("Talk", symbol: "waveform", tint: Color.hqGreen, action: onTalk)
                    quickPill("New", symbol: "square.and.pencil", tint: Color.hqTint, action: onNewChat)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(dimmed ? 0.4 : 1)
    }

    private func quickPill(_ title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(Font.hq(.caption2).weight(.semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(Font.hq(.caption).weight(.semibold))
                    .foregroundStyle(Color.hqLabel)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.hqFill3))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 5. Live Group Chat Card

struct FavoriteGroupChatCard: View {
    var tile: QuickTile
    var model: FavoritesLiveModel
    var size: QuickTileSize
    var dimmed: Bool

    var body: some View {
        let _ = Theme.touch()
        let room = model.room(tile.roomKey)
        let title = tile.name.isEmpty ? (room?.name ?? tile.roomName ?? "Group Chat") : tile.name
        let faceSize = HQFont.scaled(size == .small ? 40 : 44)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    GroupAvatar(image: room?.image, faces: room?.faces ?? [], size: faceSize)
                    if room?.unread == true {
                        Circle().fill(Color.hqTint).frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Color(uiColor: HQPalette.card), lineWidth: 2))
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(Font.hq(.headline))
                            .foregroundStyle(Color.hqLabel)
                            .lineLimit(size == .small ? 2 : 1)
                        if room?.running == true { ProgressView().controlSize(.mini) }
                    }
                    if let room {
                        Text("\(room.memberCount) \(room.memberCount == 1 ? "bot" : "bots")")
                            .font(Font.hq(.caption))
                            .foregroundStyle(Color.hqLabel2)
                    } else {
                        Text("Group chat")
                            .font(Font.hq(.caption))
                            .foregroundStyle(Color.hqLabel2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            if let line = room?.line, !line.isEmpty {
                Text(line)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .lineLimit(size == .small ? 2 : 3)
            } else {
                Text("Tap to open group chat")
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(dimmed ? 0.4 : 1)
    }
}

// MARK: - 6. Pinned Chat Session Card

struct FavoriteChatSessionCard: View {
    var tile: QuickTile
    var model: FavoritesLiveModel
    var size: QuickTileSize
    var dimmed: Bool

    var body: some View {
        let _ = Theme.touch()
        let session = model.session(id: tile.sessionId, profile: tile.bot)
        let bot = model.bot(session?.profile ?? tile.bot)
        let title = tile.name.isEmpty ? (session?.title ?? tile.sessionTitle ?? "Chat") : tile.name
        let botLabel = bot?.name ?? tile.botName ?? "Hermes"
        let snippet: String = {
            if let input = session?.inputDetail, !input.isEmpty { return input }
            if let step = session?.step, !step.isEmpty { return LiveSteps.line(step) }
            if let preview = session?.preview, !preview.isEmpty { return preview }
            if let meta = session?.metadata, !meta.isEmpty { return meta }
            return "Chat with \(botLabel)"
        }()

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HeadImage(raw: bot?.head, profile: bot?.id ?? tile.bot ?? "default", size: HQFont.scaled(28))
                    .frame(width: HQFont.scaled(28), height: HQFont.scaled(28))
                VStack(alignment: .leading, spacing: 1) {
                    Text(botLabel)
                        .font(Font.hq(.caption).weight(.semibold))
                        .foregroundStyle(Color.hqLabel2)
                        .lineLimit(1)
                    if let branch = session?.branch, !branch.isEmpty {
                        Text(branch)
                            .font(Font.hq(.caption2))
                            .foregroundStyle(Color.hqLabel3)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if session?.isRunning == true {
                    ProgressView().controlSize(.mini)
                } else if session?.unread == true {
                    Circle().fill(Color.hqTint).frame(width: 9, height: 9)
                }
            }
            Text(title)
                .font(Font.hq(.headline))
                .foregroundStyle(Color.hqLabel)
                .lineLimit(2)
            Spacer(minLength: 0)
            Text(snippet)
                .font(Font.hq(.footnote))
                .foregroundStyle(session?.inputDetail != nil ? Color.hqOrange : Color.hqLabel2)
                .lineLimit(size == .small ? 2 : 3)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(dimmed ? 0.4 : 1)
    }
}

// MARK: - 7. Live Job Status / Upcoming Jobs Card

struct FavoriteJobCard: View {
    var tile: QuickTile
    var model: FavoritesLiveModel
    var size: QuickTileSize
    var dimmed: Bool
    var onRunNow: (String, String) -> Void

    var body: some View {
        let _ = Theme.touch()
        if let jobKey = tile.job, !jobKey.isEmpty {
            singleJobBody(jobKey: jobKey)
        } else {
            upcomingBody
        }
    }

    private func singleJobBody(jobKey: String) -> some View {
        let info = model.job(jobKey)
        let title = tile.name.isEmpty ? (info?.title ?? tile.jobName ?? "Job") : tile.name
        let running = info?.running ?? model.runningTiles.contains(tile.id)
        let failed = info.map { JobWords.lastRunFailed($0.job) } ?? false
        let paused = info.map { JobActions.isPaused($0.job) } ?? false
        let dotColor: Color = running ? Color.hqTint : failed ? Color.hqRed : paused ? Color.hqLabel3 : Color.hqGreen
        let statusText: String = {
            if running { return "Running…" }
            if failed { return "Last run failed" }
            if paused { return "Paused" }
            if let job = info?.job, let note = JobWords.lastRunNote(job) { return note }
            return "Scheduled"
        }()
        let scheduleLine = info.map { JobWords.rowSubtitle($0.job, running: running) } ?? "Open Jobs to sync"

        return VStack(alignment: .leading, spacing: 8) {
            LiveCardHeader(symbol: "bolt.fill", tint: Color.hqOrange, title: title) {
                if running {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(dotColor).frame(width: 9, height: 9)
                }
            }
            Text(statusText)
                .font(Font.hq(.footnote).weight(.medium))
                .foregroundStyle(failed ? Color.hqRed : Color.hqLabel)
                .lineLimit(2)
            Text(scheduleLine)
                .font(Font.hq(.caption))
                .foregroundStyle(Color.hqLabel2)
                .lineLimit(2)
            Spacer(minLength: 0)
            if !dimmed {
                Button { onRunNow(jobKey, title) } label: {
                    Label(running ? "Running…" : "Run Now", systemImage: "play.fill")
                        .font(Font.hq(.caption).weight(.semibold))
                        .foregroundStyle(Color.hqTintText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.hqFill3))
                }
                .buttonStyle(.plain)
                .disabled(running)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(dimmed ? 0.4 : 1)
    }

    private var upcomingBody: some View {
        let limit = size == .small ? 2 : (size.rowSpan > 1 ? 5 : 3)
        let items = model.upcomingJobs(limit: limit)
        let title = tile.name.isEmpty ? "Upcoming Jobs" : tile.name

        return VStack(alignment: .leading, spacing: 8) {
            LiveCardHeader(symbol: "calendar.badge.clock", tint: Color.hqOrange, title: title) {
                let running = items.count(where: \.running)
                if running > 0 {
                    ProgressView().controlSize(.mini)
                }
            }
            if items.isEmpty {
                Spacer(minLength: 0)
                Text("No scheduled jobs yet.")
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                Spacer(minLength: 0)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(items, id: \.job.key) { entry in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(entry.running ? Color.hqTint : entry.failed ? Color.hqRed : Color.hqGreen)
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.title)
                                    .font(Font.hq(.footnote).weight(.semibold))
                                    .foregroundStyle(Color.hqLabel)
                                    .lineLimit(1)
                                Text(entry.running ? "Running…" : JobWords.rowSubtitle(entry.job, running: false))
                                    .font(Font.hq(.caption2))
                                    .foregroundStyle(entry.failed ? Color.hqRed : Color.hqLabel2)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 2)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(dimmed ? 0.4 : 1)
    }
}

// MARK: - 8. Live Kanban Board / Column Card

struct FavoriteKanbanCard: View {
    var tile: QuickTile
    var model: FavoritesLiveModel
    var size: QuickTileSize
    var dimmed: Bool

    var body: some View {
        let _ = Theme.touch()
        let snap = model.kanbanSnapshot(boardSlug: tile.boardSlug, columnStatus: tile.columnStatus)
        let title = tile.name.isEmpty ? (snap?.title ?? tile.boardName ?? "Kanban") : tile.name
        let maxCards = size == .small ? 2 : (size.rowSpan > 1 ? 6 : 3)

        VStack(alignment: .leading, spacing: 8) {
            LiveCardHeader(
                symbol: "rectangle.split.3x1.fill",
                tint: Color.hqOrange,
                title: title,
                detail: tile.columnStatus.map(KanbanModel.label)
            )

            if let snap {
                if size != .small, tile.columnStatus == nil {
                    HStack(spacing: 6) {
                        ForEach(["blocked", "running", "review", "ready"], id: \.self) { col in
                            let count = snap.counts[col] ?? 0
                            if count > 0 {
                                Text("\(KanbanModel.label(col)) \(count)")
                                    .font(Font.hq(.caption2).weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(col == "blocked" ? Color.hqOrange : Color.hqLabel2)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.hqFill3))
                            }
                        }
                    }
                }
                if snap.tasks.isEmpty {
                    Spacer(minLength: 0)
                    Text("No active cards.")
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                    Spacer(minLength: 0)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(snap.tasks.prefix(maxCards))) { task in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(task.status == "blocked" ? Color.hqOrange : task.status == "running" ? Color.hqTint : Color.hqLabel3)
                                    .frame(width: 6, height: 6)
                                Text(task.title)
                                    .font(Font.hq(.footnote))
                                    .foregroundStyle(Color.hqLabel)
                                    .lineLimit(1)
                                Spacer(minLength: 2)
                                if size != .small {
                                    Text(KanbanModel.label(task.status))
                                        .font(Font.hq(.caption2))
                                        .foregroundStyle(Color.hqLabel2)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                Spacer(minLength: 0)
                Text("Open Kanban to load your board.")
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(dimmed ? 0.4 : 1)
    }
}

// MARK: - 9. Live Gateway Status & Maintenance Glance Card

struct FavoriteGatewayStatusCard: View {
    var tile: QuickTile
    var model: FavoritesLiveModel
    var size: QuickTileSize

    var body: some View {
        let _ = Theme.touch()
        let status = model.gatewayStatus
        let up = status?.gatewayRunning ?? (MorePages.context?.isOnline == true)
        let title = tile.name.isEmpty ? "Gateway Status" : tile.name

        VStack(alignment: .leading, spacing: 8) {
            LiveCardHeader(symbol: "gauge.with.dots.needle.67percent", tint: up ? Color.hqGreen : Color.hqRed, title: title) {
                Circle().fill(up ? Color.hqGreen : Color.hqRed).frame(width: 9, height: 9)
            }

            if let status {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(status.gatewayWords)
                        .font(Font.hq(.title3).weight(.semibold))
                        .foregroundStyle(Color.hqLabel)
                        .lineLimit(1)
                    if size != .small {
                        Text(status.versionWords)
                            .font(Font.hq(.caption))
                            .foregroundStyle(Color.hqLabel2)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 12) {
                    statChip(label: "Sessions", value: status.sessionsWords)
                    if let subs = model.activeSubagents {
                        statChip(label: "Helpers", value: "\(subs)")
                    }
                }

                Spacer(minLength: 0)

                if !status.platforms.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(status.platforms.prefix(size == .small ? 2 : 4))) { platform in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(platform.isUp ? Color.hqGreen : platform.isDown ? Color.hqRed : Color.hqLabel3)
                                    .frame(width: 6, height: 6)
                                Text(platform.name)
                                    .font(Font.hq(.caption2))
                                    .foregroundStyle(Color.hqLabel2)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.hqFill3))
                        }
                    }
                }
            } else {
                Spacer(minLength: 0)
                if model.statusLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Text(up ? "Connected" : "Offline")
                        .font(Font.hq(.headline))
                        .foregroundStyle(Color.hqLabel2)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func statChip(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(Font.hq(.subheadline).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color.hqLabel)
            Text(label)
                .font(Font.hq(.caption2))
                .foregroundStyle(Color.hqLabel2)
        }
    }
}

// MARK: - 10. Live Usage Overview Card (with Swift Charts sparkline)

struct FavoriteUsageCard: View {
    var tile: QuickTile
    var model: FavoritesLiveModel
    var size: QuickTileSize

    private var days: Int { tile.days ?? 7 }

    var body: some View {
        let _ = Theme.touch()
        let report = model.usageByDays[days]
        let title = tile.name.isEmpty ? "Usage" : tile.name

        VStack(alignment: .leading, spacing: 8) {
            LiveCardHeader(symbol: "chart.bar.fill", tint: Color.hqTint, title: title) {
                Text("\(days)d")
                    .font(Font.hq(.caption2).weight(.semibold))
                    .foregroundStyle(Color.hqLabel2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.hqFill3))
            }

            if let report {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(UsageFormat.compact(report.tokens))
                            .font(Font.hq(.title3).weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Color.hqLabel)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text("tokens")
                            .font(Font.hq(.caption2))
                            .foregroundStyle(Color.hqLabel2)
                    }
                    if let cost = report.cost {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(UsageFormat.cost(cost))
                                .font(Font.hq(.subheadline).weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(Color.hqLabel)
                                .lineLimit(1)
                            Text("est. cost")
                                .font(Font.hq(.caption2))
                                .foregroundStyle(Color.hqLabel2)
                        }
                    }
                    if size != .small, let sessions = report.sessions {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(UsageFormat.compact(sessions))
                                .font(Font.hq(.subheadline).weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(Color.hqLabel)
                                .lineLimit(1)
                            Text("sessions")
                                .font(Font.hq(.caption2))
                                .foregroundStyle(Color.hqLabel2)
                        }
                    }
                }

                Spacer(minLength: 0)

                if !report.daily.isEmpty {
                    let bars = Array(report.daily.suffix(size == .small ? 7 : 14))
                    Chart(bars) { day in
                        BarMark(x: .value("Day", day.id), y: .value("Tokens", day.tokens))
                            .foregroundStyle(Color.hqTint.gradient)
                            .cornerRadius(3)
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(height: size.rowSpan > 1 ? 90 : 42)
                    .accessibilityHidden(true)
                }
            } else {
                Spacer(minLength: 0)
                if model.usageLoadingDays.contains(days) {
                    ProgressView().controlSize(.small)
                } else {
                    Text("No usage data yet.")
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
