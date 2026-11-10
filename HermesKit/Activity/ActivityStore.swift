// One app-wide activity store per signed-in account (docs/spec/1x-activity.md §3.2): it listens to every gateway event
// once, keeps each bound chat's subagents, task lists and goal by runtime id, and makes the few reads that keep them
// honest (§4.4, §6.1): `subagent.list`, `subagent.tail`, `delegation.status`, `session.control.read`. Chats bind the
// runtime id their resume returned; a binding lives for the app run (leaving a chat keeps its children, its claim on
// the bot row and its events — only the polls stop with the screen). Nothing here is written to disk.

import Foundation

/// A registration for a chat's changes; dropped with `cancel()` or deinit.
final class ActivityObservation {
    fileprivate var cancelAction: (() -> Void)?
    fileprivate init(_ cancel: @escaping () -> Void) { cancelAction = cancel }
    func cancel() { cancelAction?(); cancelAction = nil }
    isolated deinit { cancelAction?() }
}

@MainActor final class ActivityStore {
    let client: any GatewayClient
    let display: DisplayConfigCache
    /// Seconds since 1970 (tests inject a clock).
    var now: () -> Double = { Date().timeIntervalSince1970 }

    // MARK: Tunables (tests shorten them)

    var listBase: Double = 5
    var listMax: Double = 30
    var tailBase: Double = 2
    var tailMax: Double = 16
    var staleSettle: Double = 1.5
    var stalePoll: Double = 30
    var readTimeout: Duration = .seconds(15)

    /// A bot gained or lost live work (its row says Working… while a chat of it has a running child, §8.4).
    var onLiveWorkChange: ((_ profile: String) -> Void)?

    // MARK: State

    private struct ChatState {
        /// The bot ("" for a nameless launch home); sent as `profile` when non-empty.
        var profile: String
        var storedId: String?
        var roster = SubagentRoster()
        var todos = TodoState()
        var control = ControlEntry()
        var nativeSubagentEvents = false
        var interrupted = false
        var tails: [String: SubagentTail] = [:]
        /// Bumped by every applied event or read: a read answered after a newer change is discarded.
        var version = 0
        var controlVersion = 0
        /// `subagent.list` answered 4001 (not bound on this socket) or failed 3 times: no list reads until a rebind,
        /// a reconnect or the app's return.
        var listStopped = false
        var listFailures = 0
    }

    private var chats: [String: ChatState] = [:]
    private var observers: [String: [UUID: () -> Void]] = [:]
    private var dirty: Set<String> = []
    private var ticker: FrameTicker!
    private var eventsTask: Task<Void, Never>?
    private var started = false
    private var appActive = true
    private var visibleRid: String?
    private var openSubagent: String?
    private var listTask: Task<Void, Never>?
    private var listLoopRid: String?
    private var tailTask: Task<Void, Never>?
    private var staleTask: Task<Void, Never>?
    private var stalePollTask: Task<Void, Never>?
    private var lingerTask: Task<Void, Never>?
    private var liveProfiles: Set<String> = []
    /// "<profile>\u{1F}<stored id>" of the chats holding a live child.
    private var liveSessions: Set<String> = []
    /// `-32601` on this connection: never asked again until the next `gateway.ready`.
    private var listUnsupported = false
    private var controlUnsupported = false

    // [offline] Background-process claims (docs/spec/3x-offline.md §6.6): a chat says a process runs; the stale check
    // asks `agents.list` and drops the ones the gateway no longer has. Fed by the background-task capsule (composer
    // row L461) through `setProcessClaims`; DEBUG builds can seed one (`-HQDebugProcessClaim`).
    private struct ProcessState {
        var profile: String
        var storedId: String?
        var claims: [ProcessClaim]
        var version = 0
    }
    private var processes: [String: ProcessState] = [:]
    /// `agents.list` answered -32601 on this connection: not asked again until the next `gateway.ready`.
    private var agentsListUnsupported = false
    /// A chat's process claims changed (the capsule redraws).
    var onProcessClaimsChange: ((_ runtimeId: String) -> Void)?
    /// §6.7: the stale check runs one at a time (the settle timer and the poll can never run two at once).
    private lazy var staleFlight = ReadFlight(isActive: { [weak self] in self?.appActive ?? false }, label: "activity stale") { [weak self] in
        await self?.performStaleCheck()
    }
    /// How many `agents.list` reads went out (tests and the performance log).
    private(set) var agentsListReads = 0

    init(client: any GatewayClient, frameMode: FrameTicker.Mode = .displayLink) {
        self.client = client
        display = DisplayConfigCache(client: client)
        ticker = FrameTicker(mode: frameMode) { [weak self] in self?.deliver() }
    }

    isolated deinit {
        eventsTask?.cancel()
        for task in [listTask, tailTask, staleTask, stalePollTask, lingerTask] { task?.cancel() }
        ticker?.invalidate()
    }

    /// Subscribes to the client's events (once).
    func start() {
        guard !started else { return }
        started = true
        let events = client.events()
        eventsTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    /// Sign-out / account switch: everything goes.
    func shutdown() {
        eventsTask?.cancel(); eventsTask = nil
        for task in [listTask, tailTask, staleTask, stalePollTask, lingerTask] { task?.cancel() }
        listTask = nil; tailTask = nil; staleTask = nil; stalePollTask = nil; lingerTask = nil
        chats = [:]
        processes = [:]                  // [offline]
        observers = [:]
        liveProfiles = []
        liveSessions = []
        display.forget()
        ticker.invalidate()
    }

    /// Delivers pending changes now (tests).
    func flush() { ticker.isScheduled ? ticker.fire() : deliver() }

    // MARK: Reading

    func activity(_ runtimeId: String?) -> ChatActivity {
        guard let runtimeId, let chat = chats[runtimeId] else { return ChatActivity() }
        return ChatActivity(subagents: chat.roster.items, liveTodos: chat.todos.live, retainedTodos: chat.todos.retained,
                            control: chat.control, nativeSubagentEvents: chat.nativeSubagentEvents, tails: chat.tails)
    }

    /// A chat not bound yet on this screen (its resume hasn't answered): what the store kept for it from an earlier
    /// open in this app run, found by its stored id (verify round 2: a reopened chat drew its shelf only once its resume
    /// bound, and the transcript slid up under it after the push).
    func activity(storedIds: [String], profile: String) -> ChatActivity {
        guard !storedIds.isEmpty,
              let rid = chats.first(where: { $0.value.profile == profile && $0.value.storedId.map(storedIds.contains) == true })?.key
        else { return ChatActivity() }
        return activity(rid)
    }

    func isBound(_ runtimeId: String) -> Bool { chats[runtimeId] != nil }

    /// [presence] The bot whose chat is bound as `runtimeId` this run (spec 3x-presence §3.1).
    func owner(ofRuntime runtimeId: String) -> (profile: String, storedId: String?)? {
        chats[runtimeId].map { ($0.profile, $0.storedId) }
    }

    /// A bot's chat holds a running (or queued) child.
    func hasLiveWork(profile: String) -> Bool {
        chats.values.contains { $0.profile == profile && $0.roster.liveCount > 0 }
            || processes.values.contains { $0.profile == profile && StaleWork.claimsRunning($0.claims) }   // [offline]
    }

    /// The stored ids of a bot's chats holding a running (or queued) child ("" = a chat not stored yet).
    func liveWorkStoredIds(profile: String) -> Set<String> {
        Set(chats.values.filter { $0.profile == profile && $0.roster.liveCount > 0 }.map { $0.storedId ?? "" })
            .union(processes.values.filter { $0.profile == profile && StaleWork.claimsRunning($0.claims) }
                .map { $0.storedId ?? "" })                                                                  // [offline]
    }

    /// The chat with this stored id holds a running (or queued) child (its Sessions row says Working…, §8.4).
    func hasLiveWork(storedId: String) -> Bool {
        chats.values.contains { $0.storedId == storedId && $0.roster.liveCount > 0 }
            || processes.values.contains { $0.storedId == storedId && StaleWork.claimsRunning($0.claims) }   // [offline]
    }

    /// The stored ids of every chat holding a live child.
    var liveWorkStoredIds: Set<String> {
        Set(chats.values.filter { $0.roster.liveCount > 0 }.compactMap(\.storedId))
            .union(processes.values.filter { StaleWork.claimsRunning($0.claims) }.compactMap(\.storedId))          // [offline]
    }

    // MARK: Background-process claims [offline] (§6.6)

    /// A chat's background processes as its capsule knows them (running or just finished). An empty list forgets the chat.
    func setProcessClaims(runtimeId: String, profile: String, storedId: String?, _ claims: [ProcessClaim]) {
        if claims.isEmpty {
            guard processes.removeValue(forKey: runtimeId) != nil else { return }
        } else {
            guard processes[runtimeId]?.claims != claims else { return }
            let version = (processes[runtimeId]?.version ?? 0) + 1
            processes[runtimeId] = ProcessState(profile: profile, storedId: storedId, claims: claims, version: version)
        }
        onProcessClaimsChange?(runtimeId)
        refreshLiveWork()
    }

    func processClaims(runtimeId: String) -> [ProcessClaim] { processes[runtimeId]?.claims ?? [] }

    /// The chat on screen (its polls run), nil when none.
    var visibleRuntimeId: String? { visibleRid }

    /// Runs on the main actor after a chat's activity changed, at most once per display frame.
    func observe(_ runtimeId: String, _ handler: @escaping () -> Void) -> ActivityObservation {
        let id = UUID()
        observers[runtimeId, default: [:]][id] = handler
        return ActivityObservation { [weak self] in _ = self?.observers[runtimeId]?.removeValue(forKey: id) }
    }

    private func markDirty(_ rid: String) {
        dirty.insert(rid)
        ticker.revive()
        ticker.schedule()
    }

    private func deliver() {
        let ids = dirty
        dirty = []
        for rid in ids {
            for handler in observers[rid]?.values.map({ $0 }) ?? [] { handler() }
        }
    }

    // MARK: Binding (§3.2)

    /// A chat's resume bound `runtimeId` (again after a reconnect or a re-mint). A new runtime id for a stored id
    /// already bound moves that chat's state across, then re-reads.
    func bind(runtimeId: String, profile: String, storedId: String?) {
        let tag = AppLog.tag(runtimeId)
        if var existing = chats[runtimeId] {
            // The same runtime id again (a reconnect re-activated it): the reads that keep it honest run again.
            AppLog.trace("jobs", "bind \(tag): re-activated (already bound)")
            existing.listStopped = false
            existing.listFailures = 0
            if let storedId { existing.storedId = storedId }
            chats[runtimeId] = existing
        } else if let storedId, let old = chats.first(where: { $0.value.storedId == storedId && $0.value.profile == profile })?.key {
            AppLog.trace("jobs", "bind \(tag): rebound from \(AppLog.tag(old))")
            var moved = chats.removeValue(forKey: old)!
            moved.listStopped = false
            moved.listFailures = 0
            chats[runtimeId] = moved
            if visibleRid == old {
                // The screen follows the chat to its new id, and so do its polls: the list loop and an open child's
                // detail asked about the old id (gone from `chats`) and stood still until the detail was reopened.
                visibleRid = runtimeId
                listTask?.cancel(); listTask = nil; listLoopRid = nil
                updateListLoop()
                restartTail()
            }
            // Observers stay under the old id: each chat observes its new id itself after a rebind
            // (`LiveChatSession.activityBound`), and releasing the old observation removes the old handler.
        } else {
            AppLog.trace("jobs", "bind \(tag): new chat state")
            chats[runtimeId] = ChatState(profile: profile, storedId: storedId)
        }
        markDirty(runtimeId)
        if visibleRid == runtimeId { hydrateList(runtimeId) }
        readControl(runtimeId)
        refreshLiveWork()
    }

    func unbind(runtimeId: String) {
        guard chats.removeValue(forKey: runtimeId) != nil else { return }
        AppLog.trace("jobs", "unbind \(AppLog.tag(runtimeId))")
        if visibleRid == runtimeId { visibleRid = nil; listTask?.cancel(); listTask = nil; tailTask?.cancel(); tailTask = nil }
        refreshLiveWork()
    }

    /// The resume (or activate) answer: its `todo_state` (§2.4).
    func applyResume(_ result: JSONValue, runtimeId: String) {
        guard var chat = chats[runtimeId], let state = result["todo_state"], state != .null else { return }
        let running = result["running"]?.bool == true
        if chat.todos.restore(state, running: running, now: now()) {
            chat.version += 1
            chats[runtimeId] = chat
            markDirty(runtimeId)
            scheduleLinger()
        }
    }

    // MARK: Screen state (gates the polls, §4.4)

    /// The chat on screen (nil when none) and the child whose detail is open in its card.
    func setVisible(runtimeId: String?, openSubagent: String?) {
        let changedChat = runtimeId != visibleRid
        let changedChild = openSubagent != self.openSubagent
        visibleRid = runtimeId
        self.openSubagent = openSubagent
        if changedChat {
            listTask?.cancel(); listTask = nil; listLoopRid = nil
            if let runtimeId, chats[runtimeId] != nil { hydrateList(runtimeId) }
            updateListLoop()
        }
        if changedChat || changedChild { restartTail() }
    }

    func setAppActive(_ active: Bool) {
        guard active != appActive else { return }
        appActive = active
        if active {
            display.markStale()            // the bot's display flags are read again on the next open
            for rid in chats.keys { chats[rid]?.listStopped = false; chats[rid]?.listFailures = 0 }
            if let rid = visibleRid { hydrateList(rid) }
            scheduleStaleCheck(after: staleSettle)
        } else {
            listTask?.cancel(); listTask = nil; listLoopRid = nil
            stalePollTask?.cancel(); stalePollTask = nil
        }
        updateListLoop()
        restartTail()
    }

    /// Stop was pressed (true) until the next send clears it (false): late subagent and task events of the stopped
    /// turn are dropped meanwhile.
    func setInterrupted(runtimeId: String, _ value: Bool) {
        chats[runtimeId]?.interrupted = value
    }

    /// Stop: the chat's children and task lists go (V:app/session/hooks/use-prompt-actions/index.ts:719-720).
    func stopped(runtimeId: String) {
        guard var chat = chats[runtimeId] else { return }
        chat.interrupted = true
        let a = chat.roster.clear(), b = chat.todos.clear()
        if a || b {
            chat.version += 1
            chats[runtimeId] = chat
            markDirty(runtimeId)
            refreshLiveWork()
        } else {
            chats[runtimeId] = chat
        }
    }

    // MARK: Events

    private static let subagentEvents: Set<String> = ["subagent.spawn_requested", "subagent.start", "subagent.progress",
                                                      "subagent.thinking", "subagent.tool", "subagent.complete"]

    func handle(_ event: GatewayEvent) {
        if event.type == "gateway.ready" { connectionReady(); return }
        let rid = event.sessionId
        guard var chat = chats[rid] else { return }
        let p = event.payload
        let t = now()
        var changed = false
        var readControlAfter = false

        switch event.type {
        case "message.start":
            changed = chat.roster.pruneFinished()
            if chat.nativeSubagentEvents { chat.nativeSubagentEvents = false; changed = true }
        case let type where Self.subagentEvents.contains(type):
            guard !chat.interrupted, case .object(let payload) = p else { break }
            if !chat.nativeSubagentEvents {
                chat.nativeSubagentEvents = true
                _ = chat.roster.pruneDelegateStandIns()
                changed = true
            }
            let create = type == "subagent.spawn_requested" || type == "subagent.start"
            if chat.roster.upsert(payload, createIfMissing: create, eventType: type, now: t) { changed = true }
        case "todo.updated":
            guard !chat.interrupted else { break }
            let todos = TodoRules.parseTodos(p) ?? []
            if chat.todos.set(todos, revision: TodoRules.parseRevision(p), now: t) { changed = true }
        case "tool.start", "tool.complete":
            guard !chat.interrupted else { break }
            let complete = event.type == "tool.complete"
            let name = p["name"]?.string
            let anonymousTodos = name == nil && p["todos"] != nil
            if TodoRules.isTodoTool(name) || anonymousTodos {
                if let todos = TodoRules.nextTodos(current: chat.todos.live ?? [], payload: p),
                   chat.todos.set(todos, revision: TodoRules.parseRevision(p), now: t) { changed = true }
            }
            if name == "delegate_task", !chat.nativeSubagentEvents {
                for payload in SubagentRules.delegatePayloads(p, complete: complete, sourceEventType: event.type) {
                    if chat.roster.upsert(payload, createIfMissing: true, eventType: complete ? "delegate.complete" : "delegate.running", now: t) {
                        changed = true
                    }
                }
            }
        case "session.control.update":
            if let snapshot = ControlRules.parseSnapshot(p["control"]) {
                if chat.control.snapshot != snapshot || chat.control.capability != .supported {
                    chat.control.snapshot = snapshot
                    chat.control.capability = .supported
                    changed = true
                }
                chat.controlVersion += 1
            }
        case "message.complete", "error":
            if chat.todos.dropActive() { changed = true }
            if event.type == "message.complete", chat.roster.pruneLiveDelegateStandIns() { changed = true }
            readControlAfter = true
        default:
            break
        }
        if changed { chat.version += 1 }
        chats[rid] = chat
        if changed {
            markDirty(rid)
            refreshLiveWork()
            scheduleLinger()
        }
        if readControlAfter, chat.control.capability == .supported { readControl(rid) }
    }

    private func connectionReady() {
        listUnsupported = false
        controlUnsupported = false
        agentsListUnsupported = false      // [offline]
        for rid in chats.keys { chats[rid]?.listStopped = false; chats[rid]?.listFailures = 0 }
        scheduleStaleCheck(after: staleSettle)
    }

    // MARK: Live work (§8.4)

    private func refreshLiveWork() {
        let live = chats.values.filter { $0.roster.liveCount > 0 }
        // [offline] §6.6: a running background process is live work too.
        let working = processes.values.filter { StaleWork.claimsRunning($0.claims) }
        let now = Set(live.map(\.profile)).union(working.map(\.profile))
        let stored = Set(live.compactMap { chat in chat.storedId.map { "\(chat.profile)\u{1F}\($0)" } })
            .union(working.compactMap { entry in entry.storedId.map { "\(entry.profile)\u{1F}\($0)" } })
        // A bot's claim, or a session's (a second chat of a bot that already works), came or went.
        var changed = now.symmetricDifference(liveProfiles)
        for key in stored.symmetricDifference(liveSessions) { changed.insert(String(key.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)[0])) }
        liveProfiles = now
        liveSessions = stored
        if !changed.isEmpty {
            AppLog.trace("jobs", "live work changed: \(changed.count) bot(s), \(now.count) now working (\(working.count) background)")
        }
        for profile in changed { onLiveWorkChange?(profile) }
        updateListLoop()
        updateStalePoll()
    }

    // MARK: `subagent.list` (§4.4)

    private func params(_ rid: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        var p: [String: JSONValue] = ["session_id": .string(rid)]
        if let profile = chats[rid]?.profile, !profile.isEmpty { p["profile"] = .string(profile) }
        for (k, v) in extra { p[k] = v }
        return .object(p)
    }

    /// One read now unless the visible loop is about to make one.
    private func hydrateList(_ rid: String) {
        guard listLoopRid != rid else { return }
        Task { [weak self] in await self?.readList(rid) }
    }

    /// The visible chat polls while it has a live child: at once, then 5 s, doubled while nothing changes (≤ 30 s),
    /// back to 5 s on a change.
    private func updateListLoop() {
        let target: String? = {
            guard appActive, let rid = visibleRid, let chat = chats[rid], chat.roster.liveCount > 0, !listUnsupported else { return nil }
            return rid
        }()
        guard target != listLoopRid else { return }
        listTask?.cancel()
        listTask = nil
        listLoopRid = target
        guard let rid = target else { return }
        listTask = Task { [weak self] in
            guard let self else { return }
            await self.readList(rid)
            var delay = self.listBase
            while !Task.isCancelled {
                await PowerPolls.wait(.seconds(delay), floor: .zero)      // [offline] §6.9
                guard !Task.isCancelled, self.listLoopRid == rid else { return }
                let before = self.chats[rid]?.version ?? 0
                await self.readList(rid)
                let after = self.chats[rid]?.version ?? 0
                delay = after != before ? self.listBase : min(delay * 2, self.listMax)
            }
        }
    }

    private func readList(_ rid: String) async {
        guard let chat = chats[rid], !chat.listStopped, !listUnsupported else { return }
        let before = chat.version
        do {
            let result = try await client.call("subagent.list", params(rid), timeout: readTimeout)
            guard var current = chats[rid] else { return }
            current.listFailures = 0
            if current.version == before, case .array(let rows)? = result["subagents"] {
                let children = rows.compactMap(\.object)
                let failed = (result["delegations"]?.array ?? []).compactMap(\.object)
                if current.roster.reconcile(children: children, failedDelegations: failed, now: now()) {
                    current.version += 1
                    chats[rid] = current
                    markDirty(rid)
                    refreshLiveWork()
                    return
                }
            }
            chats[rid] = current
        } catch let error as RPCError {
            if error.code == -32601 || error.message.localizedCaseInsensitiveContains("method not found") {
                listUnsupported = true
            } else if error.code == 4001 {
                chats[rid]?.listStopped = true
            } else if !(error.isNotConnected) {
                chats[rid]?.listFailures += 1
                if (chats[rid]?.listFailures ?? 0) >= 3 { chats[rid]?.listStopped = true }
            }
            if listUnsupported || chats[rid]?.listStopped == true { updateListLoopIfStopped(rid) }
        } catch {}
    }

    private func updateListLoopIfStopped(_ rid: String) {
        guard listLoopRid == rid else { return }
        listTask?.cancel(); listTask = nil; listLoopRid = nil
    }

    // MARK: `subagent.tail` (§4.4)

    /// While a child's detail is open on screen: at once, then 2 s, doubled while the text stands (≤ 16 s).
    private func restartTail() {
        tailTask?.cancel()
        tailTask = nil
        guard appActive, let rid = visibleRid, let child = openSubagent, chats[rid] != nil else { return }
        tailTask = Task { [weak self] in
            guard let self else { return }
            var delay = self.tailBase
            var last: String?
            while !Task.isCancelled {
                if let text = await self.readTail(rid, child) {
                    delay = text == last ? min(delay * 2, self.tailMax) : self.tailBase
                    last = text
                }
                await PowerPolls.wait(.seconds(delay), floor: .zero)      // [offline] §6.9
            }
        }
    }

    private func readTail(_ rid: String, _ child: String) async -> String? {
        guard chats[rid] != nil else { return nil }
        guard let result = try? await client.call("subagent.tail", params(rid, ["subagent_id": .string(child)]), timeout: readTimeout),
              !Task.isCancelled, var chat = chats[rid] else { return nil }
        let tail = SubagentTail(available: result["available"]?.bool == true, text: result["text"]?.string ?? "",
                                truncated: result["truncated"]?.bool == true)
        if chat.tails[child] != tail {
            chat.tails[child] = tail
            chats[rid] = chat
            markDirty(rid)
        }
        return tail.text
    }

    // MARK: `delegation.status` stale check (§4.4, R:src/stale-work-check.ts)

    /// Chats that claim a live child with a gateway id (and no live stand-in, which has no id to look up).
    private var staleClaims: [String] {
        chats.compactMap { rid, chat in
            let live = chat.roster.items.filter(\.isLive)
            guard !live.isEmpty, !live.contains(where: \.isDelegateStandIn) else { return nil }
            return rid
        }
    }

    private func scheduleStaleCheck(after delay: Double) {
        staleTask?.cancel()
        staleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            await self.staleCheck()
        }
    }

    /// [offline] Chats that claim a running background process.
    private var processClaimants: [String] {
        processes.compactMap { rid, entry in StaleWork.claimsRunning(entry.claims) ? rid : nil }
    }

    private func updateStalePoll() {
        let wanted = appActive && (!staleClaims.isEmpty || !processClaimants.isEmpty)
        if !wanted { stalePollTask?.cancel(); stalePollTask = nil; return }
        guard stalePollTask == nil else { return }
        stalePollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // [offline] §6.9: stretched in Low Power Mode or when the phone is hot (no floor: 30 s is over it).
                await PowerPolls.wait(.seconds(self.stalePoll), floor: .zero)
                guard !Task.isCancelled else { return }
                await self.staleCheck()
            }
        }
    }

    /// One pass: every live child the gateway no longer lists is dropped (one read per profile).
    /// [offline] §6.7: one pass at a time; callers during a pass share the one that follows it.
    func staleCheck() async {
        await staleFlight.request()
    }

    private func performStaleCheck() async {
        guard appActive else { return }
        await staleProcessCheck()          // [offline] §6.6
        let claims = staleClaims
        guard !claims.isEmpty else { return }
        var answers: [String: JSONValue?] = [:]
        for rid in claims {
            guard let chat = chats[rid] else { continue }
            let before = chat.version
            let profile = chat.profile
            if answers[profile] == nil {
                let p: JSONValue = profile.isEmpty ? .object([:]) : .object(["profile": .string(profile)])
                answers[profile] = .some(try? await client.call("delegation.status", p, timeout: readTimeout))
            }
            guard case .some(.some(let answer)) = answers[profile], case .array(let active)? = answer["active"],
                  var current = chats[rid], current.version == before else { continue }
            let known = Set(current.roster.items.map(\.id))
            let children = active.compactMap(\.object).filter { known.contains(ActivityJSON.str($0["subagent_id"])) }
            let listed = Set(children.map { ActivityJSON.str($0["subagent_id"]) })
            let stale = current.roster.items.filter { $0.isLive && !listed.contains($0.id) }
            guard !stale.isEmpty else { continue }
            AppLog.trace("jobs", "stale check \(AppLog.tag(rid)): \(stale.count) live claim(s) not in delegation.status, dropping")
            if current.roster.reconcile(children: children, now: now()) {
                current.version += 1
                chats[rid] = current
                markDirty(rid)
            }
        }
        refreshLiveWork()
    }

    /// [offline] §6.6: one `agents.list` per profile with a running process claim (`{}` on the default route), 15 s;
    /// a claim that changed while the read was out is left alone; -32601 stops the asking until the next ready.
    private func staleProcessCheck() async {
        guard !agentsListUnsupported else { return }
        let claimants = processClaimants
        guard !claimants.isEmpty else { return }
        var answers: [String: Set<String>?] = [:]
        for rid in claimants {
            guard let entry = processes[rid] else { continue }
            let profile = entry.profile
            if answers[profile] == nil {
                let p: JSONValue = profile.isEmpty || profile == "default" ? .object([:]) : .object(["profile": .string(profile)])
                agentsListReads += 1
                do {
                    answers[profile] = .some(StaleWork.runningProcesses(try await client.call("agents.list", p, timeout: readTimeout)))
                } catch let error as RPCError where error.code == -32601 {
                    agentsListUnsupported = true
                    AppLog.note("jobs", "stale process check: gateway lacks agents.list, stopped asking")
                    return
                } catch {
                    answers[profile] = .some(nil)
                }
            }
            guard case .some(.some(let running)) = answers[profile], let current = processes[rid], current.version == entry.version,
                  let kept = StaleWork.dropProcesses(claims: current.claims, running: running) else { continue }
            AppLog.trace("jobs", "stale process check \(AppLog.tag(rid)): \(current.claims.count) -> \(kept.count) claims")
            if kept.isEmpty { processes[rid] = nil } else {
                processes[rid]?.claims = kept
                processes[rid]?.version += 1
            }
            onProcessClaimsChange?(rid)
        }
        refreshLiveWork()
    }

    // MARK: Task-list linger (4 s after a list finishes)

    private func scheduleLinger() {
        lingerTask?.cancel()
        let deadlines = chats.values.compactMap(\.todos.dropAt)
        guard let next = deadlines.min() else { lingerTask = nil; return }
        let wait = max(0, next - now())
        lingerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait + 0.01))
            guard let self, !Task.isCancelled else { return }
            self.expireTodos()
        }
    }

    /// Drops the finished lists whose linger is over (tests call it with an advanced clock).
    func expireTodos() {
        let t = now()
        for rid in chats.keys {
            guard var chat = chats[rid], chat.todos.expire(now: t) else { continue }
            chat.version += 1
            chats[rid] = chat
            markDirty(rid)
        }
        scheduleLinger()
    }

    // MARK: Goal (§6)

    private func readControl(_ rid: String) {
        guard !controlUnsupported, chats[rid]?.control.capability != .unsupported else { return }
        Task { [weak self] in await self?.readControlNow(rid) }
    }

    func readControlNow(_ rid: String) async {
        guard let chat = chats[rid], !controlUnsupported else { return }
        let before = chat.controlVersion
        do {
            let result = try await client.call("session.control.read", params(rid), timeout: readTimeout)
            guard var current = chats[rid], current.controlVersion == before else { return }
            guard let snapshot = ControlRules.parseSnapshot(result["control"]) else { return }
            if current.control.snapshot != snapshot || current.control.capability != .supported {
                current.control.snapshot = snapshot
                current.control.capability = .supported
                chats[rid] = current
                markDirty(rid)
            }
        } catch let error as RPCError {
            if error.code == -32601 || error.message.localizedCaseInsensitiveContains("method not found") {
                controlUnsupported = true
                for key in chats.keys where chats[key]?.control.capability != .unsupported {
                    chats[key]?.control.capability = .unsupported
                    chats[key]?.control.snapshot = nil
                    markDirty(key)
                }
            }
            // Any other failure keeps the old snapshot; the phone shows nothing for a read failure (§6.1).
        } catch {}
    }

    /// Runs one goal action; the returned `control` applies at once (§6.4).
    func runControl(runtimeId: String, action: String, args: [String: JSONValue]) async throws -> ControlDispatch {
        guard chats[runtimeId] != nil else { throw RPCError(code: 4001, message: "This chat isn't connected.", data: nil) }
        let tag = AppLog.tag(runtimeId)
        let started = ContinuousClock.now
        AppLog.trace("jobs", "control \(action) \(tag): started")
        chats[runtimeId]?.control.pendingAction = action
        chats[runtimeId]?.control.actionError = nil
        markDirty(runtimeId)
        do {
            let result = try await client.call("session.control", params(runtimeId, ["action": .string(action), "args": .object(args)]),
                                               timeout: readTimeout)
            if var chat = chats[runtimeId] {
                chat.control.pendingAction = nil
                if let snapshot = ControlRules.parseSnapshot(result["control"]) {
                    chat.control.snapshot = snapshot
                    chat.control.capability = .supported
                }
                chat.controlVersion += 1
                chats[runtimeId] = chat
                markDirty(runtimeId)
            }
            AppLog.trace("jobs", "control \(action) \(tag): succeeded in \(AppLog.ms(since: started)) ms")
            return ControlRules.parseDispatch(result["dispatch"])
        } catch {
            let message = ControlRules.actionFailure((error as? RPCError)?.message ?? error.localizedDescription)
            AppLog.note("jobs", "control \(action) \(tag): failed, \(message)")
            chats[runtimeId]?.control.pendingAction = nil
            chats[runtimeId]?.control.actionError = message
            markDirty(runtimeId)
            throw error
        }
    }

    /// The card's red failure row (its ✕), or a busy-goal message.
    func setControlError(runtimeId: String, _ message: String?) {
        guard chats[runtimeId] != nil, chats[runtimeId]?.control.actionError != message else { return }
        chats[runtimeId]?.control.actionError = message
        markDirty(runtimeId)
    }

    // MARK: Steer and Stop a child (§4.3)

    func steer(runtimeId: String, subagentId: String, text: String) async -> SteerOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, chats[runtimeId] != nil else { return .rejected }
        guard let result = try? await client.call("subagent.steer",
                                                  params(runtimeId, ["subagent_id": .string(subagentId), "text": .string(trimmed)]),
                                                  timeout: readTimeout) else { return .rejected }
        return result["status"]?.string == "queued" ? .queued : .rejected
    }

    /// true: the stop reached it (its row ends with its `subagent.complete`); false: already finished, or refused.
    func interrupt(runtimeId: String, subagentId: String) async -> Bool {
        guard chats[runtimeId] != nil,
              let result = try? await client.call("subagent.interrupt", params(runtimeId, ["subagent_id": .string(subagentId)]),
                                                  timeout: readTimeout) else { return false }
        return result["found"]?.bool == true
    }
}
