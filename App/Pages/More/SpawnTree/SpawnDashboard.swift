// [mac-tools] Spawn Tree on the Mac, as a dashboard across the window (owner 2026-11-09, the Tools sketch: "a dashboard
// across the window, not Settings cards in a strip"). A headline says how many subagents are working; four tiles count
// them by state; each bot is a card holding a table (Task, Model, Tools, Status, Time), its chats as bands with
// Open Chat, its subagents indented under the one that started them. Narrower than `SpawnDashboard.wideAt` the page
// is the list it was. iPhone and iPad keep the list.

import SwiftUI
import UIKit

struct SpawnDashboard: View {
    var model: SpawnTreeModel

    /// The page is drawn at 77 % on the Mac: about 740 pt of window.
    static let wideAt: CGFloat = 960

    private enum Column {
        static let model: CGFloat = 190, tools: CGFloat = 90, status: CGFloat = 130, time: CGFloat = 110
    }

    private var records: [SpawnRecord] { model.tree.bots.flatMap { $0.chats.flatMap { $0.rows.map(\.record) } } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headline
                tiles
                if model.tree.isEmpty {
                    MacDashCard(title: "Subagents") {
                        Text("No live subagents.").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                    }
                }
                ForEach(model.tree.bots) { bot in botCard(bot) }
            }
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 28)
        }
        .background(Color.hqGroupedPage)
        .accessibilityIdentifier("spawn-tree.dashboard")
    }

    // MARK: The headline

    private var headline: some View {
        let tree = model.tree
        let chats = tree.bots.reduce(0) { $0 + $1.chats.count }
        let words = tree.active == 0 ? "No Subagents Working" : tree.active == 1 ? "1 Subagent Working" : "\(tree.active) Subagents Working"
        let detail = tree.isEmpty ? "Helpers a bot starts show up here while they run."
            : "\(tree.total) listed, for \(tree.bots.count) \(tree.bots.count == 1 ? "bot" : "bots") in \(chats) \(chats == 1 ? "chat" : "chats")."
        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: "arrow.triangle.branch").font(Font.hq(.largeTitle))
                .foregroundStyle(tree.active > 0 ? Color.hqTint : Color.hqLabel2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(words).font(Font.hq(.title2).weight(.bold)).foregroundStyle(Color.hqLabel)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("spawn-tree.header")
                Text(detail).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                if model.refreshFailed {
                    Text("Couldn’t refresh. Showing the last list.").font(Font.hq(.footnote)).foregroundStyle(Color.hqOrange)
                        .accessibilityIdentifier("spawn-tree.refresh-failed")
                }
            }
            Spacer(minLength: 12)
            if tree.paused {
                HStack(spacing: 8) {
                    Image(systemName: "pause.circle.fill").foregroundStyle(Color.hqOrange).accessibilityHidden(true)
                    Text("New subagents are paused on this gateway.").foregroundStyle(Color.hqLabel)
                }
                .font(Font.hq(.subheadline))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color.hqOrange.opacity(0.16), in: Capsule())
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("spawn-tree.paused")
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: The tiles

    private var tiles: some View {
        let records = records
        func count(_ status: SpawnStatus) -> Int { records.count { $0.status == status } }
        let longest = records.filter { $0.status == .running }.compactMap(\.startedAt).min()
            .flatMap { SpawnTree.duration(model.now - $0) }
        let failed = count(.failed)
        return HStack(spacing: 16) {
            MacDashTile(title: "Running", value: "\(count(.running))", note: longest.map { "longest \($0)" } ?? "working now")
            MacDashTile(title: "Queued", value: "\(count(.queued))", note: "waiting to start")
            MacDashTile(title: "Done", value: "\(count(.done))", note: "finished, still listed")
            MacDashTile(title: "Failed", value: "\(failed)", note: failed > 0 ? "stopped with an error" : "none",
                        noteColor: failed > 0 ? .hqRed : .hqLabel2)
        }
    }

    // MARK: A bot's table

    private func botCard(_ bot: SpawnTree.BotGroup) -> some View {
        let running = bot.chats.reduce(0) { $0 + $1.rows.count { $0.record.status == .running } }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                HeadImage(raw: model.head(bot.id), profile: bot.id, size: 30)
                Text(model.botName(bot.id)).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
                Spacer(minLength: 8)
                Text("\(bot.count) \(bot.count == 1 ? "subagent" : "subagents") · \(running) running")
                    .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("spawn-tree.bot.\(bot.id)")
            headings
            ForEach(bot.chats) { chat in
                line
                chatBand(chat, profile: bot.id)
                ForEach(chat.rows) { row in
                    line.padding(.leading, 18)
                    taskRow(row, chat: chat, profile: bot.id)
                }
            }
        }
        .padding(.bottom, 6)
        .background(Color(uiColor: HQPalette.card), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(uiColor: MacDash.edge)) }
    }

    private var line: some View { Rectangle().fill(Color(uiColor: HQPalette.separator)).frame(height: 1) }

    private var headings: some View {
        HStack(spacing: 12) {
            Text("TASK").frame(maxWidth: .infinity, alignment: .leading)
            Text("MODEL").frame(width: Column.model, alignment: .leading)
            Text("TOOLS").frame(width: Column.tools, alignment: .trailing)
            Text("STATUS").frame(width: Column.status, alignment: .leading)
            Text("TIME").frame(width: Column.time, alignment: .trailing)
        }
        .font(Font.hq(.caption).weight(.semibold)).foregroundStyle(Color.hqLabel2)
        .padding(.horizontal, 18).padding(.bottom, 8)
        .accessibilityHidden(true)
    }

    /// The chat a group of subagents works for, with the button that opens it.
    private func chatBand(_ chat: SpawnTree.Chat, profile: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left").foregroundStyle(Color.hqLabel2).accessibilityHidden(true)
            Text(chat.title).font(Font.hq(.subheadline).weight(.semibold)).foregroundStyle(Color.hqLabel).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Text("\(chat.rows.count)").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).monospacedDigit()
                .accessibilityLabel("\(chat.rows.count) \(chat.rows.count == 1 ? "subagent" : "subagents")")
            Spacer(minLength: 8)
            if chat.sessionId != nil {
                Button("Open Chat") { model.open(chat, profile: profile) }
                    .hqMacBordered().fixedSize()
                    .accessibilityIdentifier("spawn-tree.chat.\(chat.sessionId ?? "none")")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
        .frame(minHeight: 44)
        .background(Color(uiColor: HQPalette.groupedPage).opacity(0.55))
    }

    private func taskRow(_ row: SpawnTree.Row, chat: SpawnTree.Chat, profile: String) -> some View {
        let record = row.record
        let time = record.status == .running ? SpawnTree.duration(record.startedAt.map { model.now - $0 }) : nil
        return HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if row.indent > 0 {
                    Image(systemName: "arrow.turn.down.right").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel3)
                        .padding(.leading, CGFloat(row.indent - 1) * 22)
                        .accessibilityHidden(true)
                }
                Text(record.goal ?? "Subagent").font(Font.hq(.body)).foregroundStyle(Color.hqLabel).lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(record.model.map { ModelNames.displayModelName($0) } ?? "—").lineLimit(1)
                .frame(width: Column.model, alignment: .leading)
            Text(record.toolCount.map { "\($0)" } ?? "—").monospacedDigit()
                .frame(width: Column.tools, alignment: .trailing)
            statusPill(record.status).frame(width: Column.status, alignment: .leading)
            Text(time ?? "—").monospacedDigit()
                .frame(width: Column.time, alignment: .trailing)
        }
        .font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
        .padding(.horizontal, 18).padding(.vertical, 10)
        .frame(minHeight: 46)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SpawnTree.spoken(row, now: model.now))
        .accessibilityIdentifier("spawn-tree.row.\(record.id)")
    }

    private func statusPill(_ status: SpawnStatus) -> some View {
        let color: Color = switch status {
        case .running: .hqTint
        case .queued: .hqLabel2
        case .done: .green
        case .failed: .hqRed
        }
        return HStack(spacing: 6) {
            switch status {
            case .running: ProgressView().controlSize(.mini)
            case .queued: Image(systemName: "clock")
            case .done: Image(systemName: "checkmark")
            case .failed: Image(systemName: "exclamationmark")
            }
            Text(status.word)
        }
        .font(Font.hq(.footnote).weight(.medium)).foregroundStyle(color)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(color.opacity(0.15), in: Capsule())
    }
}
