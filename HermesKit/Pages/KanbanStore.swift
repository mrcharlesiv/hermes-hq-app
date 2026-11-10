// The Kanban tab's data (docs/spec/1x-pages.md §4): the chosen board's snapshot painted from disk, then read; boards,
// bots and the fallback assignee; optimistic writes that undo only the failed task (R21, §4.5); polling every 30 s while
// the tab shows and the app is active (D-P7), a read after each write, on foreground and on a board switch.

import Foundation
import Observation

nonisolated struct KanbanStoreTiming: Sendable {
    var poll: Duration = .seconds(30)
    var boardsStale: TimeInterval = 30
    var profilesStale: TimeInterval = 60
    /// [perf] gateway.ready skips its board read when one landed this recently (the return's own read).
    var boardFresh: TimeInterval = 5
    /// [offline] §6.2: the wait before a failed board read is asked once more.
    var retryDelay: Duration = QueryRetry.delay
    static let standard = KanbanStoreTiming()
}

@MainActor @Observable
final class KanbanStore {
    let api: KanbanAPI
    let account: GatewayAccount
    let directory: URL?
    let timing: KanbanStoreTiming
    var readOnlyGateway = false

    /// The board the user picked ('' = the server's current board).
    private(set) var slug: String
    private(set) var boards: KanbanBoards?
    /// The shown board's snapshot (optimistic edits applied).
    private(set) var board: KanbanBoard?
    private(set) var boardError: String?
    private(set) var loadingBoard = false
    private(set) var profiles: [KanbanProfile] = []
    /// `default_assignee` ('' when unset: an unassigned Ready task never runs).
    private(set) var fallback = ""
    /// `resolved_default_assignee` (New Task's preselection).
    private(set) var resolvedDefault = "default"
    /// The chip the user picked, per board (memory only; survives tab switches).
    private var pickedStatus: [String: String] = [:]

    @ObservationIgnored var onChange: (() -> Void)?
    /// A write failed: the gateway's detail (the board puts back only that task).
    @ObservationIgnored var onWriteFailed: ((String) -> Void)?
    /// A write was refused before sending (read-only gateway, a locked status).
    @ObservationIgnored var onNotice: ((String) -> Void)?
    @ObservationIgnored var onWriteSucceeded: (() -> Void)?

    @ObservationIgnored private var visible = false
    @ObservationIgnored private var appActive = true
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var boardGeneration = 0
    @ObservationIgnored private var boardsReadAt: Date?
    @ObservationIgnored private var profilesReadAt: Date?
    /// The last board read that landed (gateway.ready right after a return's read skips its own).
    @ObservationIgnored private var boardReadOKAt: Date?
    @ObservationIgnored private var boardsInFlight = false
    @ObservationIgnored private var profilesInFlight = false
    @ObservationIgnored private var nextToken = 1

    nonisolated static func slugKey(_ account: GatewayAccount) -> String { "pages.kanbanBoard.\(account.id)" }

    init(api: KanbanAPI, account: GatewayAccount, directory: URL?, timing: KanbanStoreTiming = .standard) {
        self.api = api
        self.account = account
        self.directory = directory
        self.timing = timing
        slug = UserDefaults.standard.string(forKey: Self.slugKey(account)) ?? ""
    }

    @ObservationIgnored private var prepared = false

    /// The board page is about to draw: paint the boards list and the chosen board from disk (read here, not at
    /// launch: P-NAV-6).
    func prepare() {
        guard !prepared else { return }
        prepared = true
        if boards == nil, let url = boardsURL, let cached = PagesCache.read(PagesCached<KanbanBoards>.self, url) { boards = cached.value }
        if board == nil { paintBoardFromCache() }
    }

    // MARK: Cache

    private var boardsURL: URL? { directory?.appending(path: "kanban-boards.json") }
    private func boardURL(_ slug: String) -> URL? {
        directory?.appending(path: "kanban-board-\(slug.isEmpty ? "_current" : PagesCache.safeName(slug)).json")
    }

    private func paintBoardFromCache() {
        if let url = boardURL(slug), let cached = PagesCache.read(PagesCached<KanbanBoard>.self, url) { board = cached.value }
        else { board = nil }
    }

    // MARK: Derived

    /// The board key a chip pick is remembered under ('' resolves to the server's current slug when known).
    var boardKey: String { slug.isEmpty ? (boards?.current ?? "") : slug }

    var currentMeta: KanbanBoardMeta? { boards?.boards.first { $0.slug == boardKey } }

    var boardTitle: String {
        let meta = currentMeta
        return KanbanModel.boardTitle(slug: meta?.slug ?? boardKey, name: meta?.name)
    }

    func picked(_ status: String?) { pickedStatus[boardKey] = status; onChange?() }
    var pickedChip: String? { pickedStatus[boardKey] }

    /// The board name for a profile ("default" → "Hermes", via `name`), "No One" for none.
    func botName(_ name: String?, display: (String) -> String) -> String {
        guard let name, !name.isEmpty else { return "No One" }
        return display(name)
    }

    // MARK: Visibility and polling

    func setVisible(_ shown: Bool) {
        visible = shown
        if shown {
            prepare()
            refreshAll(force: false)
            startPolling()
        } else {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    func appDidBecomeActive() {
        appActive = true
        if visible { refreshAll(force: false); startPolling() }
    }

    func appDidEnterBackground() {
        appActive = false
        pollTask?.cancel()
        pollTask = nil
    }

    /// [perf] A return reads on becoming active and gateway.ready follows a redial: one board read, not two. The
    /// board is read again unless the return's read already landed (one sent before the network was up failed, or is
    /// still waiting, and this read supersedes it).
    func gatewayReady() {
        guard visible else { return }
        if boardReadOKAt.map({ Date().timeIntervalSince($0) >= timing.boardFresh }) ?? true { Task { await readBoard() } }
        refreshLists(force: false)
    }

    private func startPolling() {
        pollTask?.cancel()
        let gap = timing.poll
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await PowerPolls.wait(gap, floor: .zero)                  // [offline] §6.9
                guard !Task.isCancelled, let self else { return }
                if self.visible && self.appActive { await self.readBoard() }
            }
        }
    }

    func stop() { pollTask?.cancel(); pollTask = nil }

    // MARK: Reads

    /// Board now; boards if > 30 s old; bots and fallback if > 60 s old (`force`: all of them).
    func refreshAll(force: Bool) {
        Task { await readBoard() }
        refreshLists(force: force)
    }

    /// Pull to refresh: every list again, and the board read awaited. The reason when that read failed while a board
    /// is still shown (it stays as saved), else nil.
    func pullToRefresh() async -> String? {
        refreshLists(force: true)
        let failure = await readBoard()
        return board != nil ? failure : nil
    }

    /// Boards if > 30 s old, bots and fallback if > 60 s old; a list already being read is not asked again.
    private func refreshLists(force: Bool) {
        if force || (!boardsInFlight && boardsReadAt.map({ Date().timeIntervalSince($0) > timing.boardsStale }) ?? true) {
            Task { await readBoards() }
        }
        if force || (!profilesInFlight && profilesReadAt.map({ Date().timeIntervalSince($0) > timing.profilesStale }) ?? true) {
            Task { await readProfiles() }
        }
    }

    /// The reason when this read failed; nil when it landed or a newer read superseded it (that read reports its own).
    @discardableResult
    func readBoard() async -> String? {
        boardGeneration += 1
        let generation = boardGeneration, slug = self.slug
        loadingBoard = true
        onChange?()
        let start = ContinuousClock.now
        do {
            // [offline] §6.2: one quick retry, none after a timeout or while the gateway cannot be reached.
            let api = self.api
            let fresh = try await QueryRetry.read(delay: timing.retryDelay) { try await api.board(slug) }
            guard generation == boardGeneration, slug == self.slug else { return nil }
            board = fresh
            boardReadOKAt = Date()
            boardError = nil
            loadingBoard = false
            if let url = boardURL(slug) { PagesCache.write(PagesCached(at: Date().timeIntervalSince1970 * 1000, value: fresh), to: url) }
            onChange?()
            AppLog.trace("pages", "kanban board \(slug.isEmpty ? "(current)" : slug) read in \(AppLog.ms(since: start)) ms: \(fresh.columns.count) columns, \(fresh.allTasks.count) tasks")
            return nil
        } catch {
            guard generation == boardGeneration, slug == self.slug, !(error is CancellationError) else { return nil }
            boardReadOKAt = nil   // gateway.ready reads again: the last word on this board is a failure
            boardError = PagesREST.reason(error)
            loadingBoard = false
            onChange?()
            AppLog.note("pages", "kanban board \(slug.isEmpty ? "(current)" : slug) read failed after \(AppLog.ms(since: start)) ms: \(boardError ?? "")")
            return boardError
        }
    }

    func readBoards() async {
        boardsInFlight = true
        defer { boardsInFlight = false }
        do {
            let fresh = try await api.boards()
            boards = fresh
            boardsReadAt = Date()
            if let url = boardsURL { PagesCache.write(PagesCached(at: Date().timeIntervalSince1970 * 1000, value: fresh), to: url) }
            // A picked board that no longer exists falls back to the current one.
            if !slug.isEmpty, !fresh.boards.contains(where: { $0.slug == slug }) { select(board: "") }
            onChange?()
        } catch {}
    }

    func readProfiles() async {
        profilesInFlight = true
        defer { profilesInFlight = false }
        async let people = try? api.profiles()
        async let orchestration = try? api.orchestration()
        if let list = await people { profiles = list; profilesReadAt = Date() }
        if let o = await orchestration { fallback = o.fallback; resolvedDefault = o.resolved }
        onChange?()
    }

    /// A board pick: the server's current board stores ''.
    func select(board next: String) {
        let stored = next == boards?.current ? "" : next
        guard stored != slug else { return }
        AppLog.trace("pages", "kanban board switch \(slug.isEmpty ? "(current)" : slug) -> \(stored.isEmpty ? "(current)" : stored)")
        slug = stored
        boardReadOKAt = nil   // an earlier board's read says nothing about this one
        UserDefaults.standard.set(stored, forKey: Self.slugKey(account))
        boardGeneration += 1
        boardError = nil
        paintBoardFromCache()
        onChange?()
        Task { await readBoard() }
    }

    // MARK: Writes (optimistic, §4.5)

    private func refused() -> Bool {
        if readOnlyGateway {
            AppLog.note("config", "kanban write refused: gateway is read-only")
            onNotice?(JobsStore.readOnlyNotice)
            return true
        }
        return false
    }

    /// Optimistic writes on their way.
    @ObservationIgnored private var writesInFlight = 0

    /// Cancel the board's in-flight read, apply `edit`, send `write` on the board it started on, then read the board
    /// and the boards list again whatever happens. A failure puts back only this task (R21). `silent`: no success
    /// haptic (archive: its Undo pill is the feedback, §2.6). `failed`: the caller tells the failure itself (an alert
    /// with Try Again, UX study #134) in place of `onWriteFailed`'s short notice.
    @discardableResult
    private func optimistic(_ id: String, action: String, silent: Bool = false, edit: (KanbanBoard, Int) -> KanbanBoard,
                            failed: ((String) -> Void)? = nil,
                            write: @escaping (String) async throws -> Void) async -> Bool {
        let started = slug
        boardGeneration += 1
        nextToken += 1
        let token = nextToken
        let before = board
        let after = before.map { edit($0, token) }
        if let after { board = after; onChange?() }
        let start = ContinuousClock.now
        writesInFlight += 1
        defer {
            // Audit 863 (08c-6): the board is read again once the last of quick writes has landed; a read after the
            // first put the second card back where it was until its own read moved it again.
            writesInFlight -= 1
            if writesInFlight == 0 { Task { await self.readBoard() } }
            Task { await self.readBoards() }
        }
        do {
            try await write(started)
            AppLog.trace("config", "kanban \(action) \(AppLog.tag(id)) ok in \(AppLog.ms(since: start)) ms")
            if !silent { onWriteSucceeded?() }
            return true
        } catch {
            if let before, let after, let now = board, slug == started {
                board = KanbanModel.restoreTask(now: now, before: before, after: after, id: id)
                onChange?()
            }
            let reason = PagesREST.reason(error)
            AppLog.note("config", "kanban \(action) \(AppLog.tag(id)) failed after \(AppLog.ms(since: start)) ms: \(reason)")
            (failed ?? onWriteFailed)?(reason)
            return false
        }
    }

    func move(_ task: KanbanTask, to: String) async {
        guard task.status != to else { return }
        if KanbanModel.isLocked(to) { onNotice?(KanbanModel.lockedReason(to)); return }
        if refused() { return }
        let api = self.api
        await optimistic(task.id, action: "move to \(to)", edit: { KanbanModel.moveCard($0, task.id, to: to, token: $1) }) { board in
            try await api.patch(task.id, ["status": .string(to)], board: board)
        }
    }

    /// "" unassigns (the gateway's reassign takes an empty profile as none).
    func assign(_ task: KanbanTask, to profile: String) async {
        let next = profile.isEmpty ? nil : profile
        guard task.assignee != next else { return }
        if refused() { return }
        let api = self.api
        await optimistic(task.id, action: "reassign", edit: { KanbanModel.editCard($0, task.id, token: $1) { $0.assignee = next } }) { board in
            try await api.reassign(task.id, profile: profile, board: board)
        }
    }

    /// Archive: removed at once; on success the caller shows the Undo pill. Returns the board it left (for Undo).
    func archive(_ task: KanbanTask) async -> String? {
        if refused() { return nil }
        let api = self.api, started = slug
        let ok = await optimistic(task.id, action: "archive", silent: true, edit: { board, _ in KanbanModel.removeCard(board, task.id) }) { board in
            try await api.patch(task.id, ["status": "archived"], board: board)
        }
        return ok ? started : nil
    }

    /// Undo an archive on the board it left. Returns the gateway's reason when it failed (the caller offers Try Again).
    @discardableResult
    func unarchive(_ task: KanbanTask, to status: String, board: String) async -> String? {
        var failure: String?
        let start = ContinuousClock.now
        do {
            try await api.patch(task.id, ["status": .string(status)], board: board)
            AppLog.trace("config", "kanban unarchive \(AppLog.tag(task.id)) ok in \(AppLog.ms(since: start)) ms")
        } catch {
            failure = PagesREST.reason(error)
            AppLog.note("config", "kanban unarchive \(AppLog.tag(task.id)) failed after \(AppLog.ms(since: start)) ms: \(failure ?? "")")
        }
        await readBoard()
        await readBoards()
        return failure
    }

    /// `failed`: the reason goes to the caller (an alert with Try Again) in place of the board's notice.
    func delete(_ task: KanbanTask, failed: ((String) -> Void)? = nil) async -> Bool {
        if refused() { return false }
        let api = self.api
        return await optimistic(task.id, action: "delete", edit: { board, _ in KanbanModel.removeCard(board, task.id) }, failed: failed) { board in
            try await api.delete(task.id, board: board)
        }
    }

    /// New Task (§4.7). Throws the gateway's reason; returns a warning to show, if any.
    func create(title: String, body: String, assignee: String?, priority: Int, skills: [String], start: String,
                goalMode: Bool) async throws -> String? {
        if readOnlyGateway {
            AppLog.note("config", "kanban create task refused: gateway is read-only")
            throw PagesMessageError(JobsStore.readOnlyNotice)
        }
        var fields: [String: JSONValue] = ["title": .string(title.pgTrim), "priority": .number(Double(priority)),
                                           "triage": .bool(start == "triage"), "goal_mode": .bool(goalMode)]
        let details = body.pgTrim
        if !details.isEmpty { fields["body"] = .string(details) }
        if let assignee, !assignee.isEmpty { fields["assignee"] = .string(assignee) }
        if !skills.isEmpty { fields["skills"] = .array(skills.map { .string($0) }) }
        let started = slug
        let startTime = ContinuousClock.now
        do {
            let created = try await api.create(.object(fields), board: started)
            if let task = created.task, task.status != start {
                _ = try? await api.patch(task.id, ["status": .string(start)], board: started)
            }
            pickedStatus[boardKey] = start
            Task { await readBoard() }
            Task { await readBoards() }
            AppLog.trace("config", "kanban create task \(AppLog.tag(created.task?.id)) ok in \(AppLog.ms(since: startTime)) ms, warning \(created.warning != nil)")
            return created.warning
        } catch {
            AppLog.note("config", "kanban create task failed after \(AppLog.ms(since: startTime)) ms: \(PagesREST.reason(error))")
            throw error
        }
    }

    func reset() { stop(); board = nil; boards = nil }
}
