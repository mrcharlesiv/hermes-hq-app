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

    /// Live state of an Inline Ask card (user types directly on Favorites and reads the answer in place).
    struct InlineAskState: Equatable {
        var prompt: String
        var reply: String? = nil
        var sending: Bool = false
        var error: String? = nil
    }

    /// Live running bot, session, or subagent surfaced by the "Active Now" card.
    struct ActiveRunItem: Identifiable, Hashable {
        var id: String
        var profile: String
        var head: JSONValue?
        var title: String
        var detail: String
        var isSubagent: Bool
    }

    /// Open tool approval or clarify question surfaced by the "Approvals" card.
    struct ApprovalItem: Identifiable {
        var id: String
        var profile: String?
        var botName: String
        var head: JSONValue?
        var title: String
        var detail: String
        var isApproval: Bool
        var allowSession: Bool
        var answering: Bool
    }

    /// Bot currently using its Browser or Screen surfaced by the "Browser & Screen" card.
    struct LivePeekItem: Identifiable {
        var id: String
        var profile: String
        var botName: String
        var head: JSONValue?
        var browserLine: String?
        var usingComputer: Bool
    }

    /// Incremented whenever any observed store notifies, so SwiftUI cards stay current without redundant work.
    private(set) var tick = 0
    /// Tasks currently being ticked off inline (optimistic strikethrough while saving).
    private(set) var tickingTasks: Set<String> = []
    /// Background action tiles currently running (draws inline spinner).
    private(set) var runningTiles: Set<String> = []
    /// Recent background action result per tile id (cleared automatically after a few seconds).
    private(set) var feedbackByTile: [String: ActionFeedback] = [:]
    /// Live reply state per Inline Ask card.
    private(set) var inlineAskByTile: [String: InlineAskState] = [:]
    /// Approvals currently being answered inline.
    private(set) var answeringApprovals: Set<String> = []

    // Lazy remote snapshots (only loaded when a visible tile asks for them)
    private(set) var gatewayStatus: GatewayStatusReport?
    private(set) var statusLoading = false
    private(set) var usageByDays: [Int: UsageReport] = [:]
    private(set) var usageLoadingDays: Set<Int> = []
    private(set) var activeSubagents: Int?
    private(set) var activeSubagentItems: [ActiveRunItem] = []

    var isGatewayOnline: Bool {
        _ = tick
        return MorePages.context?.isOnline ?? false
    }

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

    // MARK: Inline Ask & Approvals

    func sendInlineAsk(tileId: String, profile: String, botName: String, prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, inlineAskByTile[tileId]?.sending != true else { return }
        PagesHaptics.selection()
        inlineAskByTile[tileId] = InlineAskState(prompt: trimmed, reply: nil, sending: true, error: nil)
        bump()
        let time = BackgroundTime.begin("hq.quick-actions.inline-ask")
        Task { [weak self] in
            let sent = await Result.of { try await AskBotIntent.send(profile: profile, name: botName, message: trimmed, wait: true) }
            time.end()
            guard let self else { return }
            switch sent {
            case .success(let (_, result)):
                PagesHaptics.success()
                switch result.reply {
                case .text(let text):
                    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.inlineAskByTile[tileId] = InlineAskState(
                        prompt: trimmed,
                        reply: cleaned.isEmpty ? "Finished without a written reply." : cleaned,
                        sending: false,
                        error: nil
                    )
                case .asking:
                    self.inlineAskByTile[tileId] = InlineAskState(prompt: trimmed, reply: "Waiting on your answer in chat.", sending: false, error: nil)
                case .stillWorking:
                    self.inlineAskByTile[tileId] = InlineAskState(prompt: trimmed, reply: "Still working — open chat to watch live.", sending: false, error: nil)
                case .failed(let msg):
                    self.inlineAskByTile[tileId] = InlineAskState(prompt: trimmed, reply: nil, sending: false, error: msg.isEmpty ? "Couldn’t finish replying." : msg)
                case nil:
                    self.inlineAskByTile[tileId] = InlineAskState(prompt: trimmed, reply: "Sent to \(botName).", sending: false, error: nil)
                }
            case .failure(let error):
                PagesHaptics.error()
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.inlineAskByTile[tileId] = InlineAskState(prompt: trimmed, reply: nil, sending: false, error: msg)
            }
            self.bump()
        }
    }

    func clearInlineAsk(tileId: String) {
        inlineAskByTile[tileId] = nil
        bump()
    }

    func openApprovals() -> [ApprovalItem] {
        _ = tick
        guard let center = (MainTabController.current?.services as? AppModel)?.serverRequests else { return [] }
        return center.allOpenPrompts().compactMap { summary in
            let b = summary.profile.flatMap { bot($0) }
            let name = b?.name ?? summary.profile.map { botName($0) } ?? "Hermes"
            if let approval = summary.approval {
                let text = approval.showsDescription && !approval.description.isEmpty ? approval.description : approval.command
                return ApprovalItem(
                    id: approval.id,
                    profile: summary.profile,
                    botName: name,
                    head: b?.head,
                    title: text.isEmpty ? "Approval needed" : text,
                    detail: name,
                    isApproval: true,
                    allowSession: approval.allowSession,
                    answering: answeringApprovals.contains(approval.id) || approval.answering != nil
                )
            }
            if let clarify = summary.clarify {
                let firstQ = clarify.questions.first?.question ?? "Waiting for your answer"
                return ApprovalItem(
                    id: clarify.id,
                    profile: summary.profile,
                    botName: name,
                    head: b?.head,
                    title: firstQ,
                    detail: clarify.questions.count > 1 ? "\(name) · \(clarify.questions.count) questions" : name,
                    isApproval: false,
                    allowSession: false,
                    answering: clarify.sending
                )
            }
            return nil
        }
    }

    func answerApproval(_ id: String, choice: ApprovalChoice) {
        guard let center = (MainTabController.current?.services as? AppModel)?.serverRequests,
              !answeringApprovals.contains(id) else { return }
        PagesHaptics.selection()
        answeringApprovals.insert(id)
        bump()
        Task { [weak self] in
            let res = await Result.of { try await center.answerApproval(id, choice) }
            if case .success = res { PagesHaptics.success() } else { PagesHaptics.error() }
            guard let self else { return }
            self.answeringApprovals.remove(id)
            self.bump()
        }
    }

    func activeRunItems() -> [ActiveRunItem] {
        _ = tick
        var out: [ActiveRunItem] = []
        var seenProfiles: Set<String> = []
        for bot in bots where !bot.hidden && bot.isWorking {
            seenProfiles.insert(bot.id)
            let detail = bot.step.map(LiveSteps.line) ?? "Working…"
            out.append(ActiveRunItem(id: "bot:\(bot.id)", profile: bot.id, head: bot.head,
                                     title: bot.name, detail: detail, isSubagent: false))
        }
        for session in sessions where session.isRunning && !seenProfiles.contains(session.profile) {
            let b = bot(session.profile)
            let detail = session.step.map(LiveSteps.line) ?? "Running…"
            out.append(ActiveRunItem(id: "sess:\(session.id)", profile: session.profile, head: b?.head,
                                     title: SessionRowView.title(session), detail: detail, isSubagent: false))
        }
        out.append(contentsOf: activeSubagentItems)
        return out
    }

    func livePeekItems() -> [LivePeekItem] {
        _ = tick
        return bots.compactMap { bot in
            guard !bot.hidden, let presence = bot.presence, !presence.isEmpty else { return nil }
            return LivePeekItem(
                id: bot.id,
                profile: bot.id,
                botName: bot.name,
                head: bot.head,
                browserLine: presence.browserLine,
                usingComputer: presence.usingComputer
            )
        }
    }

    func activeTileMakers() -> [TileMaker] {
        _ = tick
        guard let accountId = MorePages.context?.account.id, !accountId.isEmpty else { return [] }
        return TileMaker.makers(accountId: accountId)
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
    func upcomingJobs(limit: Int = 5) -> [(job: CronJob, title: String, running: Bool, failed: Bool, overdue: Bool, reason: String?)] {
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
            let oa = JobWords.nextRunOverdue(a, now: now) != nil
            let ob = JobWords.nextRunOverdue(b, now: now) != nil
            if oa != ob { return oa }
            let da = PagesDate.parse(a.nextRunAt) ?? .distantFuture
            let db = PagesDate.parse(b.nextRunAt) ?? .distantFuture
            return da < db
        }
        return sorted.prefix(limit).map { job in
            let running = store.runInFlight.contains(job.key) || store.stillRunning[job.key] != nil || JobWords.isRunning(job)
            let failed = JobWords.lastRunFailed(job)
            let overdueNote = JobWords.nextRunOverdue(job, now: now)
            let overdue = !failed && overdueNote != nil
            let reason: String? = failed ? "Last run failed" : (overdueNote != nil ? "Overdue" : nil)
            return (job, store.title(job), running, failed, overdue, reason)
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
    /// When a `Today` Tasks card is also visible on the same page, non-input ready tasks are deprioritized below
    /// approvals, questions, and failed jobs so both cards don't repeat the same top 3 rows.
    func attentionItems(hasTodayTasksCard: Bool = false) -> [AttentionItem] {
        _ = tick
        var items: [AttentionItem] = []

        // 1. Live server approvals & clarify questions
        for prompt in openApprovals() {
            items.append(AttentionItem(
                id: "prompt:\(prompt.id)",
                kind: .botInput(profile: prompt.profile ?? "default"),
                title: prompt.isApproval ? "Approve: \(prompt.title)" : prompt.title,
                detail: prompt.isApproval ? "\(prompt.botName) needs approval" : "\(prompt.botName) is asking",
                symbol: prompt.isApproval ? "checkmark.shield.fill" : "questionmark.bubble.fill",
                urgent: true,
                profile: prompt.profile,
                head: prompt.head
            ))
        }

        // 2. Bots needing input or attention
        for bot in bots where !bot.hidden {
            if let input = bot.needsInput, !items.contains(where: { $0.profile == bot.id }) {
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

        // 3. Jobs needing attention (failed or overdue)
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

        // 4. Tasks waiting on you (if a Today card is also shown on this page, avoid duplicating tasks already due today
        // unless they explicitly need your reply or there are no other attention items).
        if let store = TasksHub.current, !TasksHub.isOff(store.account) {
            store.prepare()
            let todayIds: Set<String> = hasTodayTasksCard
                ? Set(TodoViews.groups(store.tasks, view: .today, sections: store.sections, bots: bots.map(\.id),
                                       now: Date(), sort: store.settings.sort, paused: GoalViews.paused(store.goals))
                    .flatMap(\.tasks).map(\.id))
                : []
            for task in store.tasks where !task.isDone && TodoViews.waitsOnYou(task) {
                if hasTodayTasksCard && todayIds.contains(task.id) && task.status != "needs_you" { continue }
                let note = task.statusNote.trimmingCharacters(in: .whitespacesAndNewlines)
                let helperBot = task.helper.flatMap { bot($0) }
                items.append(AttentionItem(
                    id: "task:\(task.id)",
                    kind: .taskWaiting(id: task.id),
                    title: task.title.isEmpty ? "Untitled Task" : task.title,
                    detail: note.isEmpty ? (task.status == "needs_you" ? "Needs your reply" : "Ready for you") : note,
                    symbol: "checklist",
                    urgent: task.status == "needs_you",
                    profile: task.helper,
                    head: helperBot?.head
                ))
            }
        }

        // 5. Bots actively working right now (informational, non-urgent)
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
            TileMaker.changed,
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
        if kinds.contains(.gatewayStatus) {
            Task { await loadStatus(force: force) }
        }
        if kinds.contains(.gatewayStatus) || kinds.contains(.activeRuns) {
            Task { await loadSubagents(force: force) }
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
                await PowerPolls.wait(.seconds(30), floor: .zero)
                guard !Task.isCancelled, let self, self.visible else { return }
                let kinds = Set(self.observedTiles.compactMap(\.known))
                if kinds.contains(.gatewayStatus) {
                    await self.loadStatus(force: false)
                }
                if kinds.contains(.gatewayStatus) || kinds.contains(.activeRuns) {
                    await self.loadSubagents(force: false)
                }
                if kinds.contains(.botCard) || kinds.contains(.groupChat) || kinds.contains(.chatSession)
                    || kinds.contains(.needsYou) || kinds.contains(.approvals) || kinds.contains(.activeRuns) || kinds.contains(.livePeek) {
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
        if !force, let last = lastSpawnAt, Date().timeIntervalSince(last) < 30 { return }
        let api = SpawnTreeAPI(client: context.client)
        var profiles = context.botChoices.map(\.id)
        if profiles.isEmpty { profiles = ["default"] }
        var total = 0
        var rows: [ActiveRunItem] = []
        await withChildTasks(of: (String, [SpawnRecord]).self) { group in
            for profile in profiles {
                group.addTask {
                    let result = try? await api.status(profile: profile)
                    let active = result?.active.filter { $0.status == .running } ?? []
                    return (profile, active)
                }
            }
            while let (profile, active) = await group.next() {
                total += active.count
                let b = bot(profile)
                for run in active {
                    let goal = (run.goal ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let title = goal.isEmpty ? "Helper (\(botName(profile)))" : goal
                    let detail: String = {
                        if let count = run.toolCount, count > 0 { return "\(botName(profile)) · \(count) \(count == 1 ? "step" : "steps")" }
                        return "\(botName(profile)) helper"
                    }()
                    rows.append(ActiveRunItem(
                        id: "sub:\(profile):\(run.id)",
                        profile: profile,
                        head: b?.head,
                        title: title,
                        detail: detail,
                        isSubagent: true
                    ))
                }
            }
        }
        activeSubagents = total
        activeSubagentItems = rows
        lastSpawnAt = Date()
        bump()
    }
}
