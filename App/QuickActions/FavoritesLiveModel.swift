// [quick-actions] Live data hub for the Favorites page: lazily observes Bots, Group Chats, Sessions, Tasks, Goals,
// Jobs, Kanban, Gateway Status, Usage, and Spawn Tree only for the tiles actually on screen, and tracks inline
// background action feedback and live page badges.

import Foundation
import Observation
import UIKit

@MainActor @Observable
final class FavoritesLiveModel {
    /// A single attention item surfaced by the "Needs You" card.
    struct AttentionItem: Identifiable, Hashable {
        enum Kind: Hashable {
            case botInput(profile: String)
            case botAttention(profile: String)
            case taskWaiting(id: String)
            case jobAttention(key: String)
            case botWorking(profile: String)
        }
        var id: String
        var kind: Kind
        var title: String
        var detail: String
        var symbol: String
        var urgent: Bool
        var profile: String? = nil
        var head: JSONValue? = nil
    }

    /// Badge shown on a `page` action tile (e.g., unread chats, overdue tasks, running jobs, gateway issue).
    struct PageBadge: Equatable {
        enum Tone { case tint, orange, red, spinner }
        var text: String?
        var tone: Tone
    }

    /// Brief feedback drawn directly inside a background action tile (Run Job, background Send/Prompt, Routine).
    struct ActionFeedback: Equatable {
        var ok: Bool
        var text: String
    }

    /// Incremented whenever any observed store notifies, so SwiftUI cards stay current without redundant work.
    private(set) var tick = 0
    /// Tasks currently being ticked off inline (optimistic strikethrough while saving).
    private(set) var tickingTasks: Set<String> = []
    /// Background action tiles currently running (draws inline spinner).
    private(set) var runningTiles: Set<String> = []
    /// Recent background action result per tile id (cleared automatically after a few seconds).
    private(set) var feedbackByTile: [String: ActionFeedback] = [:]

    // Lazy remote snapshots (only loaded when a visible tile asks for them)
    private(set) var gatewayStatus: GatewayStatusReport?
    private(set) var statusLoading = false
    private(set) var usageByDays: [Int: UsageReport] = [:]
    private(set) var usageLoadingDays: Set<Int> = []
    private(set) var activeSubagents: Int?

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var observedTiles: [QuickTile] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private weak var watchedTasks: TasksStore?
    @ObservationIgnored private weak var watchedJobs: JobsStore?
    @ObservationIgnored private weak var watchedKanban: KanbanStore?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var feedbackClearTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastAccountId = ""
    @ObservationIgnored private var lastStatusAt: Date?
    @ObservationIgnored private var lastUsageAt: [Int: Date] = [:]
    @ObservationIgnored private var lastSpawnAt: Date?

    // MARK: Lifecycle

    func setVisible(_ shown: Bool, tiles: [QuickTile]) {
        visible = shown
        observedTiles = tiles
        resetIfAccountChanged()
        if shown {
            installObservers()
            attachStoresIfNeeded()
            refreshNeeded(force: false)
            startPolling()
        } else {
            stopPolling()
            removeObservers()
        }
    }

    func updateTiles(_ tiles: [QuickTile]) {
        observedTiles = tiles
        resetIfAccountChanged()
        guard visible else { return }
        attachStoresIfNeeded()
        refreshNeeded(force: false)
    }

    func refreshAll() async {
        resetIfAccountChanged()
        attachStoresIfNeeded()
        let kinds = Set(observedTiles.compactMap(\.known))
        if kinds.contains(.tasks) || kinds.contains(.goal) || kinds.contains(.needsYou) || hasPage("tasks") {
            await TasksHub.current?.refresh(force: true)
        }
        if kinds.contains(.jobCard) || kinds.contains(.needsYou) || hasPage("jobs") {
            await MainTabController.current?.pages?.jobsStore?.refresh(background: false)
        }
        if kinds.contains(.kanban) || hasPage("kanban") {
            MainTabController.current?.pages?.kanbanStore?.refreshAll(force: true)
        }
        if kinds.contains(.gatewayStatus) || kinds.contains(.needsYou) {
            await loadStatus(force: true)
            await loadSubagents(force: true)
        }
        for tile in observedTiles where tile.known == .usage {
            await loadUsage(days: tile.days ?? 7, force: true)
        }
        bump()
    }

    private func resetIfAccountChanged() {
        let accountId = MorePages.context?.account.id ?? ""
        guard accountId != lastAccountId else { return }
        lastAccountId = accountId
        gatewayStatus = nil
        usageByDays = [:]
        activeSubagents = nil
        lastStatusAt = nil
        lastUsageAt = [:]
        lastSpawnAt = nil
        watchedTasks = nil
        watchedJobs = nil
        watchedKanban = nil
    }

    private func hasPage(_ id: String) -> Bool {
        observedTiles.contains { $0.known == .page && $0.page == id }
    }

    private func bump() {
        tick += 1
        onChange?()
    }

    // MARK: Inline feedback for background tiles

    func setRunning(_ tileId: String, _ running: Bool) {
        if running {
            runningTiles.insert(tileId)
            feedbackClearTasks[tileId]?.cancel()
            feedbackByTile[tileId] = nil
        } else {
            runningTiles.remove(tileId)
        }
        bump()
    }

    func recordFeedback(_ tileId: String, ok: Bool, text: String) {
        runningTiles.remove(tileId)
        feedbackByTile[tileId] = ActionFeedback(ok: ok, text: text)
        feedbackClearTasks[tileId]?.cancel()
        feedbackClearTasks[tileId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, let self else { return }
            self.feedbackByTile[tileId] = nil
            self.feedbackClearTasks[tileId] = nil
            self.bump()
        }
        bump()
    }

    // MARK: Inline Task & Goal Check-off

    func toggleTaskDone(_ taskId: String) {
        guard let store = TasksHub.current, let task = store.task(taskId), !tickingTasks.contains(taskId) else { return }
        PagesHaptics.selection()
        let nextDone = !task.isDone
        tickingTasks.insert(taskId)
        bump()
        Task { [weak self] in
            let ok = await store.setDone(taskId, nextDone)
            if ok { PagesHaptics.success() } else { PagesHaptics.error() }
            try? await Task.sleep(for: .milliseconds(350))
            guard let self else { return }
            self.tickingTasks.remove(taskId)
            self.bump()
        }
    }

    // MARK: Store accessors & snapshots

    var bots: [Bot] {
        _ = tick
        return MainTabController.current?.services.bots ?? []
    }

    var rooms: [GroupRowModel] {
        _ = tick
        return (MainTabController.current?.services as? GroupServices)?.groupStore?.rows() ?? []
    }

    var sessions: [SessionSummary] {
        _ = tick
        return MainTabController.current?.services.sessions ?? []
    }

    func bot(_ profile: String?) -> Bot? {
        guard let profile, !profile.isEmpty else { return nil }
        return bots.first { $0.id == profile }
    }

    func room(_ key: String?) -> GroupRowModel? {
        guard let key, !key.isEmpty else { return nil }
        return rooms.first { $0.id == key }
    }

    func session(id: String?, profile: String?) -> SessionSummary? {
        guard let id, !id.isEmpty else { return nil }
        return sessions.first { $0.id == id && (profile == nil || profile?.isEmpty == true || $0.profile == profile) }
            ?? sessions.first { $0.id == id }
    }

    func botName(_ profile: String?) -> String {
        PagesNames.botName(profile, bots: bots)
    }

    /// Live Tasks frame matching Tasks page & Tasks widget rules.
    func tasksFrame(viewKey: String) -> (name: String, view: TodoView, frame: TasksWidgetFrame)? {
        _ = tick
        guard let store = TasksHub.current, !TasksHub.isOff(store.account) else { return nil }
        store.prepare()
        let view = TodoView(key: viewKey) ?? .today
        let roster = bots
        let tasks = store.tasks.map { task -> TodoTask in
            guard tickingTasks.contains(task.id) else { return task }
            var copy = task
            copy.status = task.isDone ? "open" : "done"
            return copy
        }
        let name = TasksNavigationLayout.title(for: view, sections: store.sections)
        let input = TasksWidgetWriter.Input(
            tasks: tasks,
            sections: store.sections,
            bots: roster.map(\.id),
            sort: store.settings.sort,
            paused: GoalViews.paused(store.goals),
            goals: store.goals,
            ticking: tickingTasks
        )
        let frame = TasksWidgetWriter.frame(view, input: input, botName: { [weak self] profile in
            self?.botName(profile) ?? (profile ?? "Hermes")
        }, at: Date())
        return (name, view, frame)
    }

    /// Live GoalCardModel for a goal id.
    func goalModel(_ id: String?) -> GoalCardModel? {
        _ = tick
        guard let id, !id.isEmpty, let store = TasksHub.current, !TasksHub.isOff(store.account) else { return nil }
        store.prepare()
        guard let goal = store.goal(id) else { return nil }
        let look = GoalTeamLook(bots: bots)
        let kept = GoalKeptHere.all[goal.id]
        return GoalCardModel.make(goal, tasks: store.tasks, now: Date(), ticking: tickingTasks,
                                  bots: store.goalBotsSupported, offers: store.offers, look: look, keptHere: kept)
    }

    /// Live Job snapshot for a single job key.
    func job(_ key: String?) -> (job: CronJob, title: String, running: Bool)? {
        _ = tick
        guard let key, !key.isEmpty, let store = MainTabController.current?.pages?.jobsStore,
              let job = store.job(key: key) else { return nil }
        let running = store.runInFlight.contains(key) || store.stillRunning[key] != nil || JobWords.isRunning(job)
        return (job, store.title(job), running)
    }

    /// Upcoming / running jobs overview when `.jobCard` has no specific job chosen.
    func upcomingJobs(limit: Int = 5) -> [(job: CronJob, title: String, running: Bool, failed: Bool)] {
        _ = tick
        guard let store = MainTabController.current?.pages?.jobsStore else { return [] }
        let now = Date()
        let active = store.jobs.filter { !JobActions.isPaused($0) && JobWords.jobState($0) != "completed" }
        let sorted = active.sorted { a, b in
            let ra = store.runInFlight.contains(a.key) || JobWords.isRunning(a)
            let rb = store.runInFlight.contains(b.key) || JobWords.isRunning(b)
            if ra != rb { return ra }
            let fa = JobWords.lastRunFailed(a)
            let fb = JobWords.lastRunFailed(b)
            if fa != fb { return fa }
            let da = PagesDate.parse(a.nextRunAt) ?? .distantFuture
            let db = PagesDate.parse(b.nextRunAt) ?? .distantFuture
            return da < db
        }
        return sorted.prefix(limit).map { job in
            let running = store.runInFlight.contains(job.key) || store.stillRunning[job.key] != nil || JobWords.isRunning(job)
            let failed = JobWords.lastRunFailed(job) || JobWords.nextRunOverdue(job, now: now) != nil
            return (job, store.title(job), running, failed)
        }
    }

    /// Live Kanban snapshot for a board slug and optional column status filter.
    func kanbanSnapshot(boardSlug: String?, columnStatus: String?) -> (title: String, counts: [String: Int], order: [String], tasks: [KanbanTask])? {
        _ = tick
        guard let store = MainTabController.current?.pages?.kanbanStore else { return nil }
        store.prepare()
        guard let board = store.board else { return nil }
        let order = KanbanModel.chipOrder(board.columns.map(\.name))
        let counts = KanbanModel.statusCounts(board)
        let title: String = {
            if let slug = boardSlug, !slug.isEmpty, let meta = store.boards?.boards.first(where: { $0.slug == slug }) {
                return KanbanModel.boardTitle(slug: meta.slug, name: meta.name)
            }
            return store.boardTitle
        }()
        let tasks: [KanbanTask] = {
            if let col = columnStatus, !col.isEmpty {
                return board.columns.first { $0.name == col }?.tasks ?? []
            }
            // Prioritize blocked, running, review, ready, todo
            let priorityOrder = ["blocked", "running", "review", "ready", "todo", "triage"]
            var out: [KanbanTask] = []
            for name in priorityOrder {
                if let col = board.columns.first(where: { $0.name == name }) { out.append(contentsOf: col.tasks) }
            }
            return out
        }()
        return (title, counts, order, tasks)
    }

    /// Dynamic "Needs You / Active Now" prioritized attention list.
    func attentionItems() -> [AttentionItem] {
        _ = tick
        var items: [AttentionItem] = []

        // 1. Bots needing input or attention
        for bot in bots where !bot.hidden {
            if let input = bot.needsInput {
                items.append(AttentionItem(
                    id: "bot-input:\(bot.id)",
                    kind: .botInput(profile: bot.id),
                    title: bot.name,
                    detail: input.statusText,
                    symbol: "exclamationmark.bubble.fill",
                    urgent: true,
                    profile: bot.id,
                    head: bot.head
                ))
            } else if let attention = bot.attention, !attention.isEmpty {
                items.append(AttentionItem(
                    id: "bot-attn:\(bot.id)",
                    kind: .botAttention(profile: bot.id),
                    title: bot.name,
                    detail: attention,
                    symbol: "exclamationmark.triangle.fill",
                    urgent: true,
                    profile: bot.id,
                    head: bot.head
                ))
            }
        }

        // 2. Tasks waiting on you (ready / needs_you)
        if let store = TasksHub.current, !TasksHub.isOff(store.account) {
            store.prepare()
            for task in store.tasks where !task.isDone && TodoViews.waitsOnYou(task) {
                let note = task.statusNote.trimmingCharacters(in: .whitespacesAndNewlines)
                items.append(AttentionItem(
                    id: "task:\(task.id)",
                    kind: .taskWaiting(id: task.id),
                    title: task.title.isEmpty ? "Untitled Task" : task.title,
                    detail: note.isEmpty ? (task.status == "needs_you" ? "Needs your reply" : "Ready for you") : note,
                    symbol: "checklist",
                    urgent: true,
                    profile: task.helper
                ))
            }
        }

        // 3. Jobs needing attention
        if let store = MainTabController.current?.pages?.jobsStore {
            let now = Date()
            for job in store.jobs where JobWords.section(job, now: now) == .needsAttention {
                let reason = JobWords.lastRunFailed(job) ? "Last run failed" : "Overdue"
                items.append(AttentionItem(
                    id: "job:\(job.key)",
                    kind: .jobAttention(key: job.key),
                    title: store.title(job),
                    detail: reason,
                    symbol: "calendar.badge.exclamationmark",
                    urgent: true
                ))
            }
        }

        // 4. Bots actively working right now (informational, non-urgent)
        for bot in bots where !bot.hidden && bot.isWorking && bot.needsInput == nil && bot.attention == nil {
            let detail = bot.step.map(LiveSteps.line) ?? "Working…"
            items.append(AttentionItem(
                id: "bot-work:\(bot.id)",
                kind: .botWorking(profile: bot.id),
                title: bot.name,
                detail: detail,
                symbol: "sparkles",
                urgent: false,
                profile: bot.id,
                head: bot.head
            ))
        }

        return items
    }

    /// Live badge for a `page` action tile (unread chats, overdue/waiting tasks, running jobs, gateway issues).
    func pageBadge(for pageId: String?) -> PageBadge? {
        _ = tick
        guard let pageId, !pageId.isEmpty else { return nil }
        switch pageId {
        case "tasks":
            guard let store = TasksHub.current, !TasksHub.isOff(store.account) else { return nil }
            store.prepare()
            let waiting = store.tasks.count { !$0.isDone && TodoViews.waitsOnYou($0) }
            if waiting > 0 { return PageBadge(text: "\(waiting)", tone: .orange) }
            let today = TodoViews.openCount(store.tasks, view: .today, sections: store.sections, now: Date())
            return today > 0 ? PageBadge(text: "\(today)", tone: .tint) : nil
        case "bots":
            let needs = bots.count { !$0.hidden && ($0.needsInput != nil || $0.attention != nil) }
            if needs > 0 { return PageBadge(text: "\(needs)", tone: .orange) }
            let unread = bots.count { !$0.hidden && $0.unread } + rooms.count { !$0.hidden && $0.unread }
            return unread > 0 ? PageBadge(text: "\(unread)", tone: .tint) : nil
        case "jobs":
            guard let store = MainTabController.current?.pages?.jobsStore else { return nil }
            let now = Date()
            let failed = store.jobs.count { JobWords.section($0, now: now) == .needsAttention }
            if failed > 0 { return PageBadge(text: "\(failed)", tone: .red) }
            let running = store.jobs.count { store.runInFlight.contains($0.key) || JobWords.isRunning($0) }
            if running > 0 { return PageBadge(text: nil, tone: .spinner) }
            return nil
        case "kanban":
            guard let board = MainTabController.current?.pages?.kanbanStore?.board else { return nil }
            let blocked = board.columns.first { $0.name == "blocked" }?.tasks.count ?? 0
            if blocked > 0 { return PageBadge(text: "\(blocked)", tone: .orange) }
            let running = board.columns.first { $0.name == "running" }?.tasks.count ?? 0
            return running > 0 ? PageBadge(text: "\(running)", tone: .tint) : nil
        case "command-center":
            if gatewayStatus?.gatewayRunning == false { return PageBadge(text: "!", tone: .red) }
            if let platforms = gatewayStatus?.platforms, platforms.contains(where: \.isDown) {
                return PageBadge(text: "!", tone: .orange)
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: Store & notification observation

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            SessionStrip.listChanged,
            ServerIssues.didChange,
            UIApplication.didBecomeActiveNotification,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.visible else { return }
                    self.attachStoresIfNeeded()
                    self.refreshNeeded(force: false)
                    self.bump()
                }
            }
        }
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        watchedTasks = nil
        watchedJobs = nil
        watchedKanban = nil
    }

    private func attachStoresIfNeeded() {
        let kinds = Set(observedTiles.compactMap(\.known))
        if kinds.contains(.tasks) || kinds.contains(.goal) || kinds.contains(.needsYou) || hasPage("tasks") {
            if let store = TasksHub.current, watchedTasks !== store {
                store.prepare()
                watchedTasks = store
                trackTasks(store)
            }
        }
        if kinds.contains(.jobCard) || kinds.contains(.needsYou) || hasPage("jobs") {
            if let store = MainTabController.current?.pages?.jobsStore, watchedJobs !== store {
                watchedJobs = store
                trackJobs(store)
            }
        }
        if kinds.contains(.kanban) || hasPage("kanban") {
            if let store = MainTabController.current?.pages?.kanbanStore, watchedKanban !== store {
                store.prepare()
                watchedKanban = store
                trackKanban(store)
            }
        }
    }

    private func trackTasks(_ store: TasksStore) {
        withObservationTracking {
            _ = store.tasks
            _ = store.sections
            _ = store.goals
            _ = store.offers
            _ = store.settings
        } onChange: { [weak self, weak store] in
            Task { @MainActor in
                guard let self, let store, self.visible, self.watchedTasks === store else { return }
                self.trackTasks(store)
                self.bump()
            }
        }
    }

    private func trackJobs(_ store: JobsStore) {
        withObservationTracking {
            _ = store.jobs
            _ = store.runInFlight
            _ = store.stillRunning
            _ = store.listReads
        } onChange: { [weak self, weak store] in
            Task { @MainActor in
                guard let self, let store, self.visible, self.watchedJobs === store else { return }
                self.trackJobs(store)
                self.bump()
            }
        }
    }

    private func trackKanban(_ store: KanbanStore) {
        withObservationTracking {
            _ = store.board
            _ = store.boards
        } onChange: { [weak self, weak store] in
            Task { @MainActor in
                guard let self, let store, self.visible, self.watchedKanban === store else { return }
                self.trackKanban(store)
                self.bump()
            }
        }
    }

    // MARK: Lazy remote fetches

    private func refreshNeeded(force: Bool) {
        let kinds = Set(observedTiles.compactMap(\.known))
        if kinds.contains(.tasks) || kinds.contains(.goal) || kinds.contains(.needsYou) {
            if let store = TasksHub.current, !TasksHub.isOff(store.account) {
                store.prepare()
                if !store.hasList || force {
                    Task { await store.refresh(force: force) }
                }
            }
        }
        if kinds.contains(.jobCard) || kinds.contains(.needsYou) {
            if let store = MainTabController.current?.pages?.jobsStore, !store.hasList || force {
                Task { await store.refresh(background: true) }
            }
        }
        if kinds.contains(.kanban) {
            if let store = MainTabController.current?.pages?.kanbanStore {
                store.prepare()
                if store.board == nil || force { store.refreshAll(force: force) }
            }
        }
        if kinds.contains(.gatewayStatus) || kinds.contains(.needsYou) {
            Task {
                await loadStatus(force: force)
                await loadSubagents(force: force)
            }
        }
        let usageDays = Set(observedTiles.filter { $0.known == .usage }.map { $0.days ?? 7 })
        for days in usageDays {
            Task { await loadUsage(days: days, force: force) }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await PowerPolls.wait(.seconds(20), floor: .zero)
                guard !Task.isCancelled, let self, self.visible else { return }
                let kinds = Set(self.observedTiles.compactMap(\.known))
                if kinds.contains(.gatewayStatus) || kinds.contains(.needsYou) {
                    await self.loadStatus(force: false)
                    await self.loadSubagents(force: false)
                }
                if kinds.contains(.botCard) || kinds.contains(.groupChat) || kinds.contains(.chatSession) || kinds.contains(.needsYou) {
                    self.bump()
                }
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func loadStatus(force: Bool) async {
        guard let context = MorePages.context else { return }
        if !force, let last = lastStatusAt, Date().timeIntervalSince(last) < 25 { return }
        statusLoading = true
        defer { statusLoading = false }
        let api = CommandCenterAPI(client: context.client)
        if let report = try? await api.status() {
            gatewayStatus = report
            lastStatusAt = Date()
            bump()
        }
    }

    private func loadUsage(days: Int, force: Bool) async {
        guard let context = MorePages.context else { return }
        if !force, let last = lastUsageAt[days], Date().timeIntervalSince(last) < 240 { return }
        guard !usageLoadingDays.contains(days) else { return }
        usageLoadingDays.insert(days)
        defer { usageLoadingDays.remove(days) }
        let api = CommandCenterAPI(client: context.client)
        if let report = try? await api.usage(days: days) {
            usageByDays[days] = report
            lastUsageAt[days] = Date()
            bump()
        }
    }

    private func loadSubagents(force: Bool) async {
        guard let context = MorePages.context else { return }
        if !force, let last = lastSpawnAt, Date().timeIntervalSince(last) < 15 { return }
        let api = SpawnTreeAPI(client: context.client)
        var profiles = context.botChoices.map(\.id)
        if profiles.isEmpty { profiles = ["default"] }
        var total = 0
        await withChildTasks(of: Int.self) { group in
            for profile in profiles {
                group.addTask {
                    let result = try? await api.status(profile: profile)
                    return result?.active.count { $0.status == .running } ?? 0
                }
            }
            while let count = await group.next() { total += count }
        }
        activeSubagents = total
        lastSpawnAt = Date()
        bump()
    }
}
