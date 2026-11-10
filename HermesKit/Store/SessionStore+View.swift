// [sessions-m9] The Sessions list's view state and what follows from it (docs/spec/3x-sessions.md §3, §5.6, §9.4):
// the Filter & Sort choices (kept per account), the chip's bot (in memory), the groups the list draws, the deeper read
// while a filter is on, each bot's projects, the needs-input and pending inputs of a row's status, and Mark All as Read.

import Foundation

extension SessionStore {
    /// `recents_limit` of a full read: 50, and 300 while a filter narrows the list (`V/store/layout.ts:41,45`).
    static let recentsLimit = 50
    static let deepRecentsLimit = 300
    /// [perf-returns] The short top page a reconnect reads instead of the full list (docs/spec/3x-sessions.md §11.5):
    /// recents 20 (a phone screen shows ~10 rows, an iPad ~16; busy bots churn the top, not the folders), the Cron
    /// jobs and messaging folders 10 each (behind a tap, and slow to change). About a fifth of a full answer.
    static let topLimits = (recents: 20, cron: 10, messaging: 10)
    /// A bot's projects are asked for again at most this often.
    static let projectsMaxAge: Duration = .seconds(60)

    // MARK: - What the user chose

    /// Filter › Project's list (Home last; empty when no bot has a project). `order`: the bots in chip order. `bot`: the
    /// chip's bot; when set, only that bot's projects (a tester 2026-11-03: other bots' projects narrow nothing there).
    func projectEntries(order: [String] = [], bot: String? = nil) -> [SessionProjectEntry] {
        guard let bot else { return SessionProjects.menuEntries(projectsByProfile, order: order) }
        return SessionProjects.menuEntries(projectsByProfile[bot].map { [bot: $0] } ?? [:], order: order)
    }

    /// C-07: a project the list does not have narrows nothing.
    var effectiveProjects: Set<String> {
        view.projectFilter.isEmpty ? [] : view.projectFilter.intersection(projectEntries(bot: botFilter).map(\.key))
    }

    /// "A filter searches the loaded page, so switching one on has to deepen the page" (§3.6). Archived has its own read.
    var wantsDeepRead: Bool { !view.statusFilter.isEmpty || botFilter != nil || statusChip != nil || !effectiveProjects.isEmpty }

    /// Everything the menu, the button and the strip read.
    func filterState(order: [String], botCount: Int) -> SessionFilterState {
        SessionFilterState(prefs: view, showBackgroundRuns: showBackgroundRuns, showOutsideChats: showOutsideChats, botFilter: botFilter,
                           projects: projectEntries(order: order, bot: botFilter), botCount: botCount, anySpend: anySpend, hasUnread: anyUnread)
    }

    /// Takes the menu's (or the strip's, or a chip's) new choices: kept on the device, the list redrawn, and the page
    /// read deeper when the first filter came on.
    func apply(_ state: SessionFilterState) {
        let wasDeep = wantsDeepRead
        let archivedBefore = view.showArchived
        var changed = false
        if state.prefs != view {
            view = state.prefs
            device.view = state.prefs
            persistState()
            changed = true
        }
        if state.botFilter != botFilter {
            botFilter = state.botFilter
            changed = true
        }
        if state.showBackgroundRuns != showBackgroundRuns {
            showBackgroundRuns = state.showBackgroundRuns          // persists and rebuilds
            changed = true
        }
        if state.showOutsideChats != showOutsideChats {
            showOutsideChats = state.showOutsideChats              // persists and rebuilds
            changed = true
        }
        if changed {
            AppLog.trace("sessions", "filter changed: status=\(view.statusFilter.count), bot=\(botFilter != nil), " +
                         "projects=\(view.projectFilter.count), groupBy=\(view.groupBy.rawValue), showArchived=\(view.showArchived), " +
                         "showRuns=\(showBackgroundRuns), showOutside=\(showOutsideChats)")
            onChange?()
        }
        if view.showArchived, !archivedBefore { Task { await loadArchived() } }
        if view.groupBy == .project || !view.projectFilter.isEmpty { loadProjects() }
        if wantsDeepRead, !wasDeep, lastFullLimit < Self.deepRecentsLimit { readInFull() }
    }

    func setView(_ change: (inout SessionsViewPrefs) -> Void) {
        var state = filterState(order: [], botCount: 1)
        change(&state.prefs)
        apply(state)
    }

    /// A chip: one bot's chats, or nil for All. Never stored.
    func setBotFilter(_ profile: String?) {
        var state = filterState(order: [], botCount: 1)
        state.botFilter = profile
        apply(state)
    }

    /// [sessions-fresh] The New or Working chip, or nil (All). Never stored; the page is read deeper as for a filter.
    func setStatusChip(_ chip: SessionStatusChip?) {
        guard chip != statusChip else { return }
        let wasDeep = wantsDeepRead
        statusChip = chip
        AppLog.trace("sessions", "status chip: \(chip?.rawValue ?? "none")")
        onChange?()
        if wantsDeepRead, !wasDeep, lastFullLimit < Self.deepRecentsLimit { readInFull() }
    }

    /// [sessions-fresh] The chips' counts under the bot chip.
    var chipCounts: [SessionStatusChip: Int] {
        SessionListPipeline.chipCounts(SessionListInput(live: sessions, botFilter: botFilter))
    }

    // MARK: - The list

    /// The list as it is drawn: pool → filter → pinned → sort → group (`SessionListPipeline`). `botNames`: Group By
    /// Bot's headers.
    func listGroups(order: [String] = [], botNames: [String: String] = [:], now: Date = Date(),
                    calendar: Calendar = .current) -> [SessionGroup] {
        SessionListPipeline.groups(SessionListInput(live: sessions, archived: archivedSessions, prefs: view, botFilter: botFilter,
                                                    projectsByProfile: projectsByProfile, projects: projectEntries(order: order, bot: botFilter),
                                                    outside: outsideRows,
                                                    collapsedGroups: collapsedGroups, openGroups: openGroups, keepNew: keepNew,
                                                    expandedGroups: expandedGroups[groupScope] ?? [],
                                                    chatOrder: device.chatOrder, projectOrder: device.projectOrder,
                                                    botOrder: device.botGroupOrder, favoriteProjects: Set(device.favoriteProjects),
                                                    botNames: botNames, statusChip: statusChip, now: now, calendar: calendar))
    }

    // MARK: - Hand-picked orders [manual-order]

    /// Sort By Manual's order holds at most this many chats (the ones put there last are kept).
    static let chatOrderLimit = 1_000

    /// A drag on the list: `keys` are one group's chats as they now stand (row keys). Kept on the device, and the sort
    /// becomes Manual (as the desktop: dragging is how Manual is picked). `drawn`: every chat on the list in its order,
    /// where a drag under another sort starts Manual from (so nothing but the dragged chat moves; the order a Manual
    /// before it left is replaced).
    func reorderChats(_ keys: [String], drawn: [String] = []) {
        let base = view.sortBy == .manual ? device.chatOrder : drawn
        var order = SessionManualOrder.merged(base, with: keys)
        if order.count > Self.chatOrderLimit {
            let run = Set(keys)
            let keep = Set(keys + order.filter { !run.contains($0) }.prefix(Self.chatOrderLimit - min(keys.count, Self.chatOrderLimit)))
            order = order.filter(keep.contains)
        }
        device.chatOrder = order
        AppLog.trace("sessions", "manual order: \(keys.count) chats in a group rearranged (\(order.count) kept)")
        if view.sortBy != .manual {
            setView { $0.sortBy = .manual }        // persists and redraws
        } else {
            persistState()
            onChange?()
        }
    }

    /// The groups Group By Project (project keys) or Group By Bot (profiles) draws, as the user put them. Empty: the
    /// default order again (newest chat first, Home last).
    func setGroupOrder(_ ids: [String], bots: Bool) {
        if bots {
            guard device.botGroupOrder != ids else { return }
            device.botGroupOrder = ids
        } else {
            guard device.projectOrder != ids else { return }
            device.projectOrder = ids
        }
        AppLog.trace("sessions", "group order: \(ids.count) \(bots ? "bots" : "projects") (\(ids.isEmpty ? "default" : "hand-picked"))")
        persistState()
        onChange?()
    }

    /// The project order as drawn (`shown`: the project keys on the list) with one moved by `delta` places, among the
    /// favorites or among the rest (a favorite stays above the rest).
    func moveGroup(_ id: String, by delta: Int, shown: [String], bots: Bool) {
        let favorites = bots ? [] : Set(device.favoriteProjects)
        let lane = shown.filter { favorites.contains($0) == favorites.contains(id) }
        guard let from = lane.firstIndex(of: id) else { return }
        let to = from + delta
        guard lane.indices.contains(to) else { return }
        // The swap, written over the whole drawn order so the projects not in the lane keep their places.
        var all = shown
        guard let a = all.firstIndex(of: id), let b = all.firstIndex(of: lane[to]) else { return }
        all.swapAt(a, b)
        setGroupOrder(SessionManualOrder.merged(bots ? device.botGroupOrder : device.projectOrder, with: all), bots: bots)
    }

    /// No hand-picked order and no favorites (UI tests start from here).
    func resetOrders() {
        guard !device.chatOrder.isEmpty || !device.projectOrder.isEmpty || !device.botGroupOrder.isEmpty
                || !device.favoriteProjects.isEmpty else { return }
        device.chatOrder = []; device.projectOrder = []; device.botGroupOrder = []; device.favoriteProjects = []
        persistState()
        onChange?()
    }

    var favoriteProjects: Set<String> { Set(device.favoriteProjects) }

    /// A project's star: Favorite keeps it above every other project (owner, 2026-10-29).
    func setFavoriteProject(_ key: String, _ on: Bool) {
        var keys = device.favoriteProjects
        if on { guard !keys.contains(key) else { return }; keys.append(key) } else {
            guard keys.contains(key) else { return }
            keys.removeAll { $0 == key }
        }
        device.favoriteProjects = keys
        AppLog.trace("sessions", "favorite project \(on ? "added" : "removed") (\(keys.count) favorites)")
        persistState()
        onChange?()
    }

    // MARK: - Folding groups

    /// Whose folds the list shows: the chip's bot, or "*" for All (a project closed under one bot stays open under All).
    var groupScope: String { botFilter ?? "*" }

    /// The groups closed for the chip's bot (kept across launches, per gateway account).
    var collapsedGroups: Set<String> { Set(device.collapsedGroups[groupScope] ?? []) }

    /// [sessions-layout] The projects opened for the chip's bot (every other one is folded to its summary row).
    var openGroups: Set<String> { Set(device.openGroups[groupScope] ?? []) }

    /// [sessions-layout] Every chat New for You lifts right now joins the ones kept there until the page is left.
    func holdNew() {
        let now = Set(sessions.filter { SessionListPipeline.isNew($0) }.map(SessionListPipeline.key))
        if !now.isSubset(of: keepNew) { keepNew.formUnion(now) }
    }

    /// [sessions-layout] The page was left (another tab, the app in the background): chats read since go back to
    /// their own groups. True when one moves.
    @discardableResult
    func releaseNew() -> Bool {
        let unreadNow = Set(sessions.filter { SessionListPipeline.isNew($0) }.map(SessionListPipeline.key))
        let moves = !keepNew.isSubset(of: unreadNow)
        keepNew = []
        return moves
    }

    /// A header tapped: its group closes to the header, or opens again. Kept on the device.
    func setGroupCollapsed(_ id: String, _ collapsed: Bool) {
        if SessionListPipeline.isProject(id) {
            // [sessions-layout] A project is folded unless opened: its open state is the one kept.
            var ids = openGroups
            guard collapsed ? ids.remove(id) != nil : ids.insert(id).inserted else { return }
            device.openGroups[groupScope] = ids.isEmpty ? nil : ids.sorted()
            persistState()
            onChange?()
            return
        }
        var ids = collapsedGroups
        guard collapsed ? ids.insert(id).inserted : ids.remove(id) != nil else { return }
        device.collapsedGroups[groupScope] = ids.isEmpty ? nil : ids.sorted()
        persistState()
        onChange?()
    }

    #if DEBUG
    /// [sessions-layout] UI tests: the device's unread state from scratch (markers, watermarks, local reads); the
    /// next read seeds the watermarks again, so only the gateway's own unread flags count.
    func resetUnreadForTests() {
        guard device.unread != SessionUnreadState() else { return }
        device.unread = SessionUnreadState()
        persistState()
        rebuild()
    }
    #endif

    /// Every group open again, for every bot (UI tests start from here).
    func resetGroupFolds() {
        guard !device.collapsedGroups.isEmpty || !device.openGroups.isEmpty || !expandedGroups.isEmpty else { return }
        device.collapsedGroups = [:]
        device.openGroups = [:]
        expandedGroups = [:]
        persistState()
        onChange?()
    }

    /// Show More (`expanded`) or Show Less under a project. For this launch only.
    func setGroupExpanded(_ id: String, _ expanded: Bool) {
        var ids = expandedGroups[groupScope] ?? []
        guard expanded ? ids.insert(id).inserted : ids.remove(id) != nil else { return }
        expandedGroups[groupScope] = ids
        onChange?()
    }

    /// The live pool and the platform chats (Show › Outside Chats), for search.
    var liveRows: [SessionSummary] {
        guard !outsideRows.isEmpty else { return sessions }
        let ids = Set(sessions.map { Self.writeKey(id: $0.id, profile: $0.profile) })
        return sessions + outsideRows.filter { !ids.contains(Self.writeKey(id: $0.id, profile: $0.profile)) }
    }

    /// The Other Apps page's sections (the chip and status filter apply, as on the list).
    func appSections() -> [SessionGroup] {
        SessionListPipeline.appSections(SessionListInput(live: [], archived: archivedSessions, prefs: view, botFilter: botFilter,
                                                         outside: outsideRows))
    }

    /// The chats the Other Apps page holds: the messaging platforms' with Show › Outside Chats, the one-off runs with
    /// Show › Background Runs (`messagingSessions` keeps those only then), and the scheduled job runs with it too.
    var outsideRows: [SessionSummary] {
        let outside = messagingSessions.filter { ChatSource.isMessaging($0.source) ? showOutsideChats : ChatSource.hasFolder($0.source) }
        return showBackgroundRuns ? outside + cronSessions : outside
    }

    /// The chats Mark All as Read and its enabled state speak for: every recents row that is not a bot's own chat,
    /// background runs the list hides included.
    var listedRows: [SidebarSessionRow] { recents.filter { !SessionRules.isBotChat($0) } }

    /// Either unread source holds a Sessions chat (`anyUnread`, `filter-apply.ts:53`).
    var anyUnread: Bool { listedRows.contains(where: isUnreadNow) }

    /// Some listed chat reports spend ("a cost sort would rank a list of zeroes").
    var anySpend: Bool { listedRows.contains { $0.costUsd > 0 } }

    // MARK: - A row's status inputs

    /// Chats where an approval, a question, a sudo or a secret prompt waits (stored ids).
    func setNeedsInput(_ ids: Set<String>) {
        guard ids != needsInput else { return }
        needsInput = ids
        rebuild()
    }

    /// A draft or a lost send changed: the rows' pending lines are read again.
    func refreshPending() { rebuild() }

    // MARK: - Projects (§3.4)

    /// Asks for the projects of every bot that owns a listed chat (and the chip's bot): the first time the Filter menu
    /// opens or Group By Project is on, then at most once a minute per bot, and again (`force`) after one is created.
    /// `also`: bots to ask whether or not they own a listed chat (the bot a project was just created for).
    /// At most `projectsWindow` asks are in the air; the rest wait their turn.
    func loadProjects(force: Bool = false, also extra: [String] = []) {
        var owners = Set(listedRows.map(\.profile)).union(extra)
        if let botFilter { owners.insert(botFilter) }
        var queued = 0
        for profile in owners.sorted() where !projectReads.contains(profile) && !projectQueue.contains(profile) {
            if !force, let at = projectsReadAt[profile], ContinuousClock.now - at < Self.projectsMaxAge { continue }
            projectsReadAt[profile] = .now
            projectQueue.append(profile)
            queued += 1
        }
        if queued > 0 { AppLog.trace("sessions", "projects: \(queued) bots queued to read (force=\(force))") }
        pumpProjectReads()
    }

    private func pumpProjectReads() {
        while projectReads.count < Self.projectsWindow, !projectQueue.isEmpty {
            let profile = projectQueue.removeFirst()
            projectReads.insert(profile)
            Task { [weak self] in
                var failed = false
                do { _ = try await self?.projects(for: profile, refresh: true) } catch is BotWriteError {
                    // A gateway without projects: asked again no sooner than the next minute.
                } catch { failed = true }
                guard let self else { return }
                // An ask that failed (timed out, the link dropped) does not count as asked: the next need asks again.
                if failed { self.projectsReadAt[profile] = nil }
                self.projectReads.remove(profile)
                self.pumpProjectReads()
            }
        }
    }

    /// `projects.tree` asks in the air at once (as Mark All as Read's writes).
    static let projectsWindow = 4

    /// The projects as last read changed: kept for the next launch, and the list regroups.
    func projectsChanged() {
        guard device.projects != projectsByProfile else { return }
        device.projects = projectsByProfile
        persistState()
        onChange?()
    }

    // MARK: - Mark All as Read (§5.6)

    /// Clears both unread sources for every listed chat, as each row's Mark as Read does: the device's marks at once,
    /// then `PATCH {"unread": false}` for each chat whose server flag is set, at most four in the air. Returns the
    /// chats whose write failed (they keep their unread mark). `only`: Try Again, for just those chats.
    /// A read-only gateway gets no write: the dots clear on this device.
    @discardableResult
    func markAllRead(only failed: [SessionWriteFailure]? = nil) async -> [SessionWriteFailure] {
        var targets = listedRows
        if let failed {
            let keys = Set(failed.map { Self.writeKey(id: $0.id, profile: $0.profile) })
            targets = targets.filter { keys.contains(Self.writeKey(id: $0.id, profile: $0.profile)) }
        }
        guard !targets.isEmpty else { return [] }
        AppLog.trace("sessions", "mark all read: started, \(targets.count) rows (retry=\(failed != nil))")
        for row in targets { device.unread.opened(row, clearServerLocally: row.unread == true && readOnlyGateway) }
        persistState()
        let tickets = readOnlyGateway ? [] : targets.filter { $0.unread == true }.map { beginUnreadWrite(false, row: $0) }
        if !tickets.isEmpty { writeCache() }
        rebuild(force: true)
        guard !tickets.isEmpty else { return [] }

        let started = ContinuousClock.now
        let client = self.client
        var failures: [(index: Int, failure: SessionWriteFailure)] = []
        // Not `withTaskGroup`: optimized builds abort when a child finishes into a destroyed group (ChildTasks.swift).
        await withChildTasks(of: (Int, (any Error)?).self) { group in
            var next = 0
            while next < min(Self.markAllWindow, tickets.count) {
                let index = next
                group.addTask { (index, await Self.sendUnread(tickets[index], client: client)) }
                next += 1
            }
            while let (index, error) = await group.next() {
                settleUnreadWrite(tickets[index], error: error)
                if let error {
                    failures.append((index, SessionWriteFailure(id: tickets[index].id, profile: tickets[index].profile,
                                                                reason: SessionActionText.reason(error))))
                }
                if next < tickets.count {
                    let index = next
                    group.addTask { (index, await Self.sendUnread(tickets[index], client: client)) }
                    next += 1
                }
            }
        }
        let sorted = failures.sorted { $0.index < $1.index }.map(\.failure)
        AppLog.trace("sessions", "mark all read: \(tickets.count - sorted.count) succeeded, \(sorted.count) failed, in \(AppLog.ms(since: started)) ms")
        return sorted
    }

    /// Mark All as Read's writes in the air at once.
    static let markAllWindow = 4
}
