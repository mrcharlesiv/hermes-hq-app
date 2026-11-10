// More › Spawn Tree (docs/spec/3x-morepages.md §16, D-M13): the subagents running on the gateway right now, grouped by
// bot and by the chat that owns them, indented by depth. Read-only: a tap opens the chat. Read on appear and every
// 3 s while the page is on screen and the app is active (10 s after a failed read), and on `subagent.*` events.

import SwiftUI
import UIKit

extension MorePages {
    static func installSpawnTree() {
        factories["spawn-tree"] = { context in SpawnTreePage.make(context: context) }
    }
}

@MainActor
enum SpawnTreePage {
    static func make(context: MorePages.Context) -> UIViewController {
        let model = SpawnTreeModel(context: context)
        let page = MorePageController(title: "Spawn Tree", identifier: "spawn-tree.page", SpawnTreeView(model: model))
        model.host = page
        page.retained = [model]
        page.onAppear = { [weak model] in model?.appear() }
        page.onDisappear = { [weak model] in model?.disappear() }
        return page
    }
}

@MainActor @Observable
final class SpawnTreeModel {
    enum Load: Equatable {
        case loading
        case ready
        case failed(String)
        /// The gateway has no `delegation.status` (an older Hermes).
        case older
    }

    @ObservationIgnored let context: MorePages.Context
    @ObservationIgnored let api: SpawnTreeAPI
    @ObservationIgnored weak var host: UIViewController?

    private(set) var tree = SpawnTree()
    private(set) var load: Load = .loading
    private(set) var refreshFailed = false
    /// When the tree was read (durations are counted from it).
    private(set) var now = Date().timeIntervalSince1970

    @ObservationIgnored var interval: Duration = .seconds(3)
    @ObservationIgnored var errorInterval: Duration = .seconds(10)
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var events: Task<Void, Never>?
    @ObservationIgnored private var reading = false
    /// An event came in while a read was on its way: one more read follows it (never more than one).
    @ObservationIgnored private var again = false
    @ObservationIgnored private var lastFailed = false
    @ObservationIgnored private var noted = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(context: MorePages.Context) {
        self.context = context
        api = SpawnTreeAPI(client: context.client)
    }

    func botName(_ profile: String) -> String { context.botName(profile) }
    func head(_ profile: String) -> JSONValue? { context.bots.first { $0.id == profile }?.head }

    // MARK: Refresh

    func appear() {
        start()
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        #if targetEnvironment(macCatalyst)
        // [mac] Mac polish #84: in view beside another app it keeps refreshing; hidden or minimized it stops.
        let (resumes, pauses) = (UIApplication.willEnterForegroundNotification, UIApplication.didEnterBackgroundNotification)
        #else
        let (resumes, pauses) = (UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification)
        #endif
        observers = [
            center.addObserver(forName: resumes, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.start() }
            },
            center.addObserver(forName: pauses, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            },
        ]
    }

    func disappear() {
        stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func start() {
        guard loop == nil, UIApplication.shared.applicationState != .background else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.read()
                // [perf] Stretched in Low Power Mode or when the phone is hot, like every other page poll.
                await PowerPolls.wait(self.lastFailed ? self.errorInterval : self.interval, floor: .zero)
            }
        }
        let client = context.client
        events = Task { [weak self] in
            for await event in client.events() where event.type.hasPrefix("subagent.") {
                guard !Task.isCancelled else { return }
                await self?.read()
            }
        }
    }

    private func stop() {
        loop?.cancel(); loop = nil
        events?.cancel(); events = nil
        again = false
    }

    func retry() {
        load = .loading
        stop()
        start()
    }

    func read() async {
        // [perf] A `subagent.*` event during a read used to be dropped, leaving the tree stale until the next tick.
        guard !reading else { again = true; return }
        reading = true
        defer { reading = false }
        repeat {
            again = false
            await readOnce()
        } while again && !Task.isCancelled
    }

    private func readOnce() async {
        var profiles = context.botChoices.map(\.id)
        if profiles.isEmpty { profiles = ["default"] }
        let api = api
        var answers: [String: Result<DelegationStatus, Error>] = [:]
        // Not `withTaskGroup`: build 278 aborted here ("pure virtual function called", HermesKit/Net/ChildTasks.swift).
        await withChildTasks(of: (String, Result<DelegationStatus, Error>).self) { group in
            for profile in profiles {
                group.addTask {
                    let outcome = await Result.of { try await api.status(profile: profile) }
                    return (profile, outcome)
                }
            }
            while let (profile, result) = await group.next() { answers[profile] = result }
        }
        guard !Task.isCancelled else { return }
        let good = profiles.compactMap { profile -> (profile: String, status: DelegationStatus)? in
            if case .success(let status) = answers[profile] { return (profile, status) } else { return nil }
        }
        if good.isEmpty {
            let error = profiles.lazy.compactMap { profile -> Error? in
                if case .failure(let error) = answers[profile] { return error } else { return nil }
            }.first
            lastFailed = true
            if let error, MoreWire.isMissingRoute(error) {
                MorePages.noteRead("spawn-tree", error: error)
                load = .older
                tree = SpawnTree()
            } else if load == .ready {
                refreshFailed = true
                AppLog.note("pages", "spawn tree refresh failed, keeping last tree: \(error.map(PagesREST.reason) ?? "?")")
            } else {
                let reason = error.map(PagesREST.reason) ?? "The gateway couldn’t do that."
                AppLog.note("pages", "spawn tree load failed for all \(profiles.count) bots: \(reason)")
                load = .failed(reason)
            }
            return
        }
        if !noted { noted = true; MorePages.noteRead("spawn-tree", error: nil) }
        lastFailed = false
        refreshFailed = false
        var sessions: [String: SpawnTree.Session] = [:]
        for session in context.services.sessions { sessions[session.id] = SpawnTree.Session(profile: session.profile, title: session.title) }
        let built = SpawnTree.build(answers: good, sessions: sessions)
        now = Date().timeIntervalSince1970
        if built != tree {
            AppLog.trace("pages", "spawn tree read: \(good.count) of \(profiles.count) bots, \(built.total) subagents, \(built.active) active")
            tree = built
        }
        load = .ready
    }

    // MARK: Opening a chat

    func open(_ chat: SpawnTree.Chat, profile: String) {
        guard let id = chat.sessionId else { return }
        let navigation = host?.navigationController
        if let session = context.services.sessions.first(where: { $0.id == id }) {
            MorePages.openChat(session, on: navigation)
        } else {
            MorePages.openChat(sessionId: id, profile: profile, title: chat.title, on: navigation)
        }
    }
}

struct SpawnTreeView: View {
    var model: SpawnTreeModel
    /// [mac-tools] The page's width: wide enough on the Mac, the tree is the dashboard (SpawnDashboard.swift).
    @State private var width: CGFloat = 0

    /// [mac] Stress test 2026-10-28 round 7: the dotted tree glyph is thin dots in a wide box, so at the shared empty-state
    /// size it drew about 20 pt and faint beside the other pages' 30 pt symbols. The Mac uses the solid branch glyph.
    private static var emptySymbol: String {
        DeviceWord.isMac ? "arrow.triangle.branch" : "point.3.connected.trianglepath.dotted"
    }

    var body: some View {
        Group { page }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { width = $0 })
    }

    @ViewBuilder private var page: some View {
        switch model.load {
        case .loading:
            MoreSkeleton(label: "Loading subagents…") { model.retry() }
        case .failed(let reason):
            MoreErrorState(title: "Couldn’t Load Spawn Tree", reason: reason) { model.retry() }
        case .older:
            MoreEmptyState(symbol: Self.emptySymbol, title: MoreWire.notAvailableTitle,
                           text: MoreWire.notAvailableBody("Spawn Tree"))   // [mac] Stress test 2026-10-28 #10
        case .ready:
            if model.tree.isEmpty, !model.tree.paused, !model.refreshFailed {
                MoreEmptyState(symbol: Self.emptySymbol, title: "No Subagents Running",
                               text: "When a bot hands work to subagents (helper bots it starts), they show up here while they run.")
            } else if DeviceWord.isMac, width >= SpawnDashboard.wideAt {
                SpawnDashboard(model: model)
            } else {
                list
            }
        }
    }

    private var list: some View {
        List { Group {
            Section {
                if model.refreshFailed {
                    Text("Couldn’t refresh. Showing the last list.").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                        .padding(.vertical, 3)
                        .accessibilityIdentifier("spawn-tree.refresh-failed")
                }
                Text(model.tree.header)
                    .font(Font.hq(.subheadline).weight(.semibold)).foregroundStyle(Color.hqLabel)
                    .accessibilityIdentifier("spawn-tree.header")
                if model.tree.paused {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "pause.circle.fill").foregroundStyle(Color.hqOrange).accessibilityHidden(true)
                        Text("New subagents are paused on this gateway.").foregroundStyle(Color.hqLabel)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("spawn-tree.paused")
                }
            }
            if model.tree.isEmpty {
                Section {
                    Text("No live subagents.").foregroundStyle(Color.hqLabel2).padding(.vertical, 6)
                }
            }
            ForEach(model.tree.bots) { bot in
                Section {
                    ForEach(bot.chats) { chat in
                        // The chat's own row opens it too, as its subagents' rows do (UX study #101).
                        if chat.sessionId != nil {
                            Button { model.open(chat, profile: bot.id) } label: { chatTitle(chat, opens: true) }
                                .buttonStyle(.plain)
                                .accessibilityHint("Opens the chat")
                                .accessibilityIdentifier("spawn-tree.chat.\(chat.sessionId ?? "none")")
                        } else {
                            chatTitle(chat, opens: false)
                                .accessibilityIdentifier("spawn-tree.chat.none")
                        }
                        ForEach(chat.rows) { row in
                            SpawnRow(row: row, now: model.now, opens: chat.sessionId != nil) { model.open(chat, profile: bot.id) }
                        }
                    }
                } header: { HQSectionLabel {
                    HStack(spacing: 8) {
                        HeadImage(raw: model.head(bot.id), profile: bot.id, size: 22)
                        Text(model.botName(bot.id))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("spawn-tree.bot.\(bot.id)")
                } }
            }
        }.hqMacSettingsRowInsets() }
        .hqMacForm()   // [mac] Stress test 2026-10-28 #8, #53: the readable width, one inset, small switches
        .hqGroupedPage()
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("spawn-tree.list")
    }

    /// The chat a group of subagents belongs to, with the chevron its subagents' rows draw when it can be opened.
    private func chatTitle(_ chat: SpawnTree.Chat, opens: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "bubble.left").accessibilityHidden(true)
            Text(chat.title).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            if opens {
                SettingsChevron()
                    .accessibilityHidden(true)
            }
        }
        .font(Font.hq(.footnote).weight(.semibold)).foregroundStyle(Color.hqLabel2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One subagent: its goal (two lines), then "<model> · N tools · running 2m 10s", indented 16 pt a level (four at most).
struct SpawnRow: View {
    var row: SpawnTree.Row
    var now: Double
    var opens: Bool
    var open: () -> Void
    /// The glyph's column grows with the text size, so a large checkmark never runs into the goal.
    @ScaledMetric(relativeTo: .body) private var glyphWidth: CGFloat = 20

    var body: some View {
        if opens {
            Button(action: open) { content }
                .padding(.leading, CGFloat(row.indent) * SpawnTree.indentWidth)
                .accessibilityLabel(SpawnTree.spoken(row, now: now))
                .accessibilityHint("Opens the chat")
                .accessibilityIdentifier("spawn-tree.row.\(row.record.id)")
        } else {
            content
                .padding(.leading, CGFloat(row.indent) * SpawnTree.indentWidth)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(SpawnTree.spoken(row, now: now))
                .accessibilityIdentifier("spawn-tree.row.\(row.record.id)")
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 10) {
            glyph.frame(width: glyphWidth, height: glyphWidth).padding(.top, 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.record.goal ?? "Subagent").foregroundStyle(Color.hqLabel).lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(SpawnTree.detail(row.record, now: now))
                    .font(Font.hq(.footnote)).foregroundStyle(row.record.status == .failed ? Color.hqRed : Color.hqLabel2)
                    .lineLimit(2).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if opens {
                SettingsChevron()
                    .padding(.top, 3).accessibilityHidden(true)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var glyph: some View {
        switch row.record.status {
        case .running: ProgressView().controlSize(.small)
        case .queued: Image(systemName: "clock").foregroundStyle(Color.hqLabel3)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.hqRed)
        }
    }
}
