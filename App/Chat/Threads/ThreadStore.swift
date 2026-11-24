import UIKit

/// [threads] One account's threads (docs/spec/3x-threads.md §4): the chats started from inside a bot's chat, which
/// that chat draws in place.
///
/// A thread is known three ways:
/// - started here this run: a live chat with no screen (`LiveChatSession.listenOffScreen`), so its reply arrives while
///   the bot chat is the one on screen;
/// - listed by the gateway: a Sessions row whose parent is the bot chat (another device started it, or an earlier
///   run), read once over REST and again when its row changes;
/// - opened: the chat its screen uses, kept as the live one.
///
/// Only a few idle threads stay live; the rest keep the messages they last showed.
@MainActor
final class ThreadStore {
    private final class Entry {
        /// Stable for the run: the stored id for a listed thread, a local key for one started here.
        let key: String
        let profile: String
        /// The bot chat's id it was started under (nil when that chat had no stored id yet).
        var parentId: String?
        var storedId: String?
        var live: LiveChatSession?
        var startedAt: Date
        var anchorMessageId: String?
        var anchorRow: Int?
        var rowTitle: String?
        /// What it showed when last read or last live.
        var kept: [ChatMessage] = []
        /// The Sessions row state the last read was made for ("<last active>|<count>").
        var readStamp: String?
        var reading = false
        var problem: String?
        var lastChange = Date()
        /// What the bot chat last drew of it (a change in any of these redraws it).
        var drawn: Int = 0

        init(key: String, profile: String, parentId: String?, storedId: String?, startedAt: Date) {
            self.key = key; self.profile = profile; self.parentId = parentId; self.storedId = storedId; self.startedAt = startedAt
        }
    }

    private weak var model: AppModel?
    private var entries: [Entry] = []
    private var observers: [(owner: WeakBox<AnyObject>, profile: String, call: () -> Void)] = []
    private var owed: Set<String> = []
    private var notifyQueued = false
    /// Idle threads kept live (a running one always is).
    static let idleLive = 4

    init(model: AppModel) { self.model = model }

    // MARK: Observing

    /// `call` runs (once per run loop turn) when a thread of `profile` changed, for as long as `owner` lives.
    func observe(profile: String, owner: AnyObject, _ call: @escaping () -> Void) {
        observers.removeAll { $0.owner.value == nil }
        observers.append((WeakBox(owner), profile, call))
    }

    private func changed(_ profile: String) {
        owed.insert(profile)
        guard !notifyQueued else { return }
        notifyQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notifyQueued = false
            let profiles = self.owed
            self.owed = []
            self.observers.removeAll { $0.owner.value == nil }
            for observer in self.observers where profiles.contains(observer.profile) { observer.call() }
        }
    }

    // MARK: Reading

    /// The threads of the bot chat known by `parentIds`, oldest first.
    func threads(profile: String, parentIds: Set<String>) -> [ChatThread] {
        adoptListed(profile: profile, parentIds: parentIds)
        return entries.filter { $0.profile == profile && belongs($0, to: parentIds) }
            .sorted { $0.startedAt < $1.startedAt }
            .map(thread)
    }

    /// One started here before its bot chat had a stored id belongs to that profile's bot chat.
    private func belongs(_ entry: Entry, to parentIds: Set<String>) -> Bool {
        guard let parent = entry.parentId else { return true }
        return parentIds.contains(parent)
    }

    private func thread(_ entry: Entry) -> ChatThread {
        let live = entry.live
        let listed = entry.storedId.flatMap { model?.sessionStore?.row(for: $0) }
        let title = [live?.title, listed?.title ?? entry.rowTitle].compactMap { $0 }
            .first { !$0.isEmpty && $0 != ThreadRules.defaultTitle && !ThreadRules.isInheritedBotChatTitle($0) }
        let scope = live?.layoutScope ?? "\(model?.account?.id ?? "")|\(entry.profile)|\(entry.storedId ?? entry.key)"
        return ChatThread(id: entry.key, storedId: live?.storedSessionId ?? entry.storedId, title: title, startedAt: entry.startedAt,
                          anchorMessageId: entry.anchorMessageId, anchorRow: entry.anchorRow,
                          messages: live?.messages ?? entry.kept,
                          // Started a moment ago with nothing sent yet: it is on its way, not idle.
                          running: live.map { $0.isRunning || ($0.messages.isEmpty && $0.threadProblem == nil) }
                              ?? (entry.storedId.map { model?.isSessionWorking($0) ?? false } ?? false),
                          problem: live?.threadProblem ?? entry.problem, scope: scope)
    }

    /// Listed Sessions rows that belong to this bot chat (either via durable synced `BotThreadLink` or a gateway
    /// `parent_session_id` from older builds) become threads; a listed thread not live here is read again when moved.
    private func adoptListed(profile: String, parentIds: Set<String>) {
        guard let store = model?.sessionStore else { return }
        func adoptRow(_ row: SidebarSessionRow, parent: String, linkedAnchorRow: Int? = nil, linkedStartedAt: Double? = nil) {
            let entry: Entry
            if let known = entries.first(where: { $0.profile == profile && ($0.storedId == row.id || $0.live?.storedSessionId == row.id) }) {
                entry = known
                if entry.storedId == nil { entry.storedId = row.id }
            } else {
                let at = linkedStartedAt ?? row.startedAt ?? row.lastActive ?? Date().timeIntervalSince1970
                entry = Entry(key: row.id, profile: profile, parentId: parent, storedId: row.id,
                              startedAt: Date(timeIntervalSince1970: at))
                entries.append(entry)
            }
            if entry.anchorRow == nil, let linkedAnchorRow { entry.anchorRow = linkedAnchorRow }
            entry.rowTitle = row.title
            guard entry.live == nil else { return }
            let stamp = "\(row.lastActive ?? 0)|\(row.messageCount ?? 0)"
            if entry.readStamp != stamp { read(entry, stamp: stamp) }
        }
        for link in store.botThreads where link.profile == profile && parentIds.contains(link.parentId) {
            guard let row = store.rowsById[link.storedId], row.archived != true else { continue }
            adoptRow(row, parent: link.parentId, linkedAnchorRow: link.anchorRow, linkedStartedAt: link.startedAt)
        }
        for row in store.rowsById.values where row.profile == profile && row.archived != true {
            guard let parent = row.parentSessionId, parentIds.contains(parent) else { continue }
            adoptRow(row, parent: parent)
        }
    }

    private func read(_ entry: Entry, stamp: String) {
        guard !entry.reading, let client = model?.client, let stored = entry.storedId else { return }
        entry.reading = true
        let profile = entry.profile
        Task { [weak self, weak entry] in
            let result = try? await ThreadFetch.load(client: client, storedId: stored, profile: profile.isEmpty ? nil : profile)
            guard let self, let entry else { return }
            entry.reading = false
            guard let result else { return }      // the next change of its row tries again
            entry.readStamp = stamp
            guard entry.live == nil else { return }
            entry.kept = result.messages
            if let row = result.anchorRow { entry.anchorRow = row }
            entry.lastChange = Date()
            self.changed(profile)
        }
    }

    /// The Sessions list was read again: listed threads may have moved.
    func sessionsChanged() {
        for profile in Set(observers.map(\.profile)) { changed(profile) }
    }

    // MARK: Starting

    /// Starts a thread from `parent` (a bot's own chat) with `text` as its first message, under `anchor` (the message
    /// of the main chat it hangs under). The chat is made and the message sent with no screen; the reply runs beside
    /// whatever the main chat is doing.
    @discardableResult
    func start(text: String, display: String? = nil, attachments: [DraftAttachment] = [],
               in parent: LiveChatSession, bot: Bot, anchor: ChatMessage?,
               leavingOut localId: String? = nil, busyReason: String? = nil) -> String? {
        guard let model else { return nil }
        let parentId = parent.readSessionId
        // §9: `localId` is the bubble of the words this thread is taking over; they are its message, not its seed.
        let seed = ThreadSeed.rows(from: parent.messages.filter { $0.id != localId },
                                   running: parent.isRunning || parent.externalWorking,
                                   anchorRow: anchor?.rowId, busyReason: busyReason,
                                   isSeedable: { !SideTaskRow.isSideRow($0) })
        // Never pass `parent_session_id` alongside `messages` on `session.create`: real Hermes gateways route
        // `parent_session_id + messages` into `_seed_branch_row`, which names the thread `"Bot Chat #N"` (preventing
        // auto-titling) and persists seed rows with `copy_fields=()` (dropping `display_kind: "hidden"` so the whole
        // Bot Chat seed dumps visibly into the thread). Sending `messages` without `parent_session_id` takes `_seed_row`,
        // keeping every seed row hidden and letting Hermes auto-title the thread from its own first message; the
        // parent Bot Chat link rides in `SessionStore.botThreads` (persisted locally and synced via `GatewaySync`).
        var extra: [String: JSONValue] = [:]
        if !seed.isEmpty { extra["messages"] = .array(ThreadSeed.params(seed)) }
        let entry = Entry(key: "thread-\(UUID().uuidString)", profile: bot.id, parentId: parentId, storedId: nil, startedAt: Date())
        entry.anchorMessageId = anchor?.id
        entry.anchorRow = anchor?.rowId
        let folder = parent.menus.cwd.flatMap { $0.isEmpty ? nil : $0 }
        let chat = model.freshChat(for: bot, folder: folder, shownTitle: ThreadRules.defaultTitle, extra: extra) { [weak self, weak entry] stored in
            guard let self, let entry else { return }
            entry.storedId = stored
            if let parentId = entry.parentId {
                self.model?.sessionStore?.recordBotThread(BotThreadLink(
                    storedId: stored, profile: entry.profile, parentId: parentId,
                    startedAt: entry.startedAt.timeIntervalSince1970, anchorRow: entry.anchorRow))
            }
            if self.busyThreads[entry.profile]?.key == entry.key { self.busyThreads[entry.profile]?.storedId = stored }
            self.changed(entry.profile)
            self.model?.refreshSessions()       // it lists under Sessions too, as any chat with that bot
        }
        entries.append(entry)
        if let live = chat as? LiveChatSession {
            adopt(live, for: entry)
            live.listenOffScreen()
            live.send(text, display: display, attachments: attachments)
            AppLog.note("threads", "thread started in \(AppLog.tag(parentId)) (profile \(bot.id)): \(seed.count) seed rows, anchor row \(anchor?.rowId.map(String.init) ?? "-"), attachments \(attachments.count), main chat \(parent.isRunning || parent.externalWorking ? "working" : "idle")")
        } else {
            entry.problem = "Not connected to the gateway."
        }
        changed(bot.id)
        trim()
        return entry.key
    }

    // MARK: A busy chat's words (docs/spec/3x-threads.md §9)

    private struct BusyLatch {
        var key: String
        var storedId: String?
        var heldAt: Int
        var lastActivity: Date
        var reason: OwnerWait?
        var mainIdleSinceHold = false
        weak var parent: LiveChatSession?
    }

    /// By profile: the thread that last took its bot chat's words while busy.
    private var busyThreads: [String: BusyLatch] = [:]
    /// Profiles where the user tapped "Use Main" for the current busy stretch.
    private var optedOutProfiles: Set<String> = []
    /// Per-profile background probe watching for the main chat to become free when the ledger isn't tracking it.
    private var availabilityProbes: [String: Task<Void, Never>] = [:]
    /// Auto-thread keys per profile whose settled exchange should be bridged onto the next main-chat prompt.
    private var pendingReconciliation: [String: [String]] = [:]
    /// A reconciliation note restored after a main-chat send failed or fell back to a thread.
    private var restoredReconciliation: [String: String] = [:]

    /// True when the app already knows `parent` is unavailable and sends should route straight into a thread (0 ms wait).
    func shouldRouteToBusyThread(for parent: LiveChatSession, botId: String, now: Date = Date()) -> Bool {
        guard !optedOutProfiles.contains(botId) else { return false }
        if parent.externalWorking { return true }
        return activeBusyEntry(for: parent, botId: botId, now: now) != nil
    }

    /// Calm banner shown above the composer whenever the next send will proactively route into a thread.
    func busyBanner(for parent: LiveChatSession, botId: String, botName: String, now: Date = Date()) -> ThreadBusyBanner? {
        guard shouldRouteToBusyThread(for: parent, botId: botId, now: now) else { return nil }
        if let active = activeBusyEntry(for: parent, botId: botId, now: now) {
            let title = ThreadRules.name(thread(active.entry))
            return ThreadRules.proactiveBanner(botName: botName, activeTitle: title, threadKey: active.entry.key,
                                               reason: active.latch.reason ?? (parent.externalWorking ? .backgroundTask : nil))
        }
        return ThreadRules.proactiveBanner(botName: botName, activeTitle: nil, threadKey: nil,
                                           reason: parent.externalWorking ? .backgroundTask : nil)
    }

    /// User tapped "Use Main" on the proactive busy-thread strip: switch sends back to the main chat immediately.
    func optOutBusyRouting(profile: String) {
        optedOutProfiles.insert(profile)
        busyThreads[profile] = nil
        availabilityProbes.removeValue(forKey: profile)?.cancel()
        changed(profile)
    }

    /// Releases a busy-thread latch automatically when the main chat frees up, notifying the visible chat quietly.
    private func autoUnlatch(profile: String, parent: LiveChatSession?, why: String) {
        optedOutProfiles.remove(profile)
        availabilityProbes.removeValue(forKey: profile)?.cancel()
        guard let latch = busyThreads.removeValue(forKey: profile) else {
            changed(profile)
            return
        }
        AppLog.note("threads", "auto-thread unlatched for profile \(profile): \(why)")
        changed(profile)
        let chat = parent ?? latch.parent
        if let chat, chat.observing {
            chat.onNotice?(ThreadRules.backInMainNotice(botName: chat.botName))
        }
    }

    /// External work in the main bot chat started or ended: ending unlatches any busy thread and clears an opt-out.
    func noteMainExternalWork(profile: String, working: Bool, parent: LiveChatSession? = nil) {
        if !working {
            autoUnlatch(profile: profile, parent: parent, why: "external work finished")
        } else {
            changed(profile)
        }
    }

    /// A newer finished assistant reply landed in the main chat (e.g. a background job or CLI turn finished writing):
    /// unlatch any busy thread so the next message goes back into the main chat even on gateways without the ledger.
    func noteMainReplyLanded(profile: String, parent: LiveChatSession) {
        guard busyThreads[profile] != nil || optedOutProfiles.contains(profile) else { return }
        autoUnlatch(profile: profile, parent: parent, why: "main reply landed")
    }

    /// Gentle 5 s watch while a busy thread is latched on screen without an active ledger watch.
    private func startAvailabilityProbe(profile: String, parent: LiveChatSession, reason: OwnerWait?) {
        availabilityProbes.removeValue(forKey: profile)?.cancel()
        availabilityProbes[profile] = Task { [weak self, weak parent] in
            let checkServer = reason == .runningReply
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, let parent, !Task.isCancelled, self.busyThreads[profile] != nil else { break }
                guard parent.observing else { continue }
                if !parent.externalWorking { parent.checkExternalWork("busy thread watch") }
                let idle = await parent.probeMainAvailability(checkServerRunning: checkServer)
                guard !Task.isCancelled, self.busyThreads[profile] != nil else { break }
                if idle {
                    self.autoUnlatch(profile: profile, parent: parent, why: "main session idle")
                    break
                }
            }
            self?.availabilityProbes[profile] = nil
        }
    }

    /// Compact summary of auto-threads that settled while the main chat was busy, consumed once on the next main send.
    func consumeReconciliationNote(profile: String) -> String? {
        if let restored = restoredReconciliation.removeValue(forKey: profile) { return restored }
        guard let keys = pendingReconciliation[profile], !keys.isEmpty else { return nil }
        var settled: [(title: String?, messages: [ChatMessage])] = []
        var stillRunning: [String] = []
        for key in keys {
            guard let entry = entries.first(where: { $0.key == key }) else { continue }
            let view = thread(entry)
            if view.running { stillRunning.append(key); continue }
            if !view.spoken.isEmpty { settled.append((ThreadRules.name(view), view.spoken)) }
        }
        pendingReconciliation[profile] = stillRunning.isEmpty ? nil : stillRunning
        return ThreadContextNote.format(threads: settled)
    }

    func restoreReconciliationNote(profile: String, note: String) {
        guard !note.isEmpty else { return }
        restoredReconciliation[profile] = note
    }

    private func activeBusyEntry(for parent: LiveChatSession, botId: String, now: Date) -> (latch: BusyLatch, entry: Entry)? {
        guard let latch = busyThreads[botId],
              let entry = entries.first(where: { $0.key == latch.key || (latch.storedId != nil && $0.storedId == latch.storedId) })
        else { return nil }
        let reachable = entry.live != nil || entry.storedId != nil
        let problem = (entry.live?.threadProblem ?? entry.problem) != nil
        guard ThreadRules.takesNextBusySend(heldAt: latch.heldAt, accepted: parent.acceptedSends, reachable: reachable,
                                            problem: problem, mainIdleSinceHold: latch.mainIdleSinceHold,
                                            lastActivity: latch.lastActivity, now: now) else {
            busyThreads[botId] = nil
            return nil
        }
        return (latch, entry)
    }

    private static func seedBusyReason(_ reason: OwnerWait?, externalWorking: Bool) -> String {
        switch reason {
        case .backgroundTask: return "a background task"
        case .messagingTurn(let app?): return "a \(app) message"
        case .messagingTurn(nil): return "a messaging turn"
        case .otherWindow: return "another Hermes window"
        case .runningReply: return "another reply"
        case nil: return externalWorking ? "a background task" : "another turn"
        }
    }

    /// Legacy text-only entry point (kept for source compatibility).
    func takeBusySend(_ text: String, from parent: LiveChatSession, bot: Bot, leavingOut localId: String) -> Bool {
        takeBusySend(BusyThreadPayload(text: text, localId: localId), from: parent, bot: bot)
    }

    /// `parent` (a bot's own chat) cannot take `payload` now: a thread takes it as its message. The same thread takes
    /// follow-ups until the chat takes a send itself, external work finishes, or the thread goes stale. Reopens an
    /// evicted idle thread by `storedId` rather than spawning a duplicate. False when no thread could be started.
    func takeBusySend(_ payload: BusyThreadPayload, from parent: LiveChatSession, bot: Bot) -> Bool {
        let now = Date()
        if let active = activeBusyEntry(for: parent, botId: bot.id, now: now) {
            let live: LiveChatSession?
            if let existing = active.entry.live {
                live = existing
            } else {
                live = chatModel(for: active.entry.key) as? LiveChatSession
                live?.listenOffScreen()
            }
            if let live {
                live.send(payload.text, display: payload.display, attachments: payload.attachments)
                busyThreads[bot.id]?.lastActivity = now
                if let reason = payload.reason { busyThreads[bot.id]?.reason = reason }
                trackReconciliation(key: active.entry.key, profile: bot.id)
                AppLog.note("threads", "busy chat's send went on in its thread (profile \(bot.id), proactive=\(payload.proactive))")
                changed(bot.id)
                return true
            }
        }
        // Release oldest idle live thread before spawning a new busy thread so we stay well below gateway session caps.
        releaseOldestIdleIfCrowded()
        let anchor = ThreadRules.busyAnchor(in: parent.messages, leavingOut: payload.localId)
        let busyReason = Self.seedBusyReason(payload.reason, externalWorking: parent.externalWorking)
        guard let key = start(text: payload.text, display: payload.display, attachments: payload.attachments,
                              in: parent, bot: bot, anchor: anchor, leavingOut: payload.localId, busyReason: busyReason),
              let entry = entries.first(where: { $0.key == key }) else { return false }
        guard let live = entry.live else {
            entries.removeAll { $0.key == key }     // it never began: no thread line for it
            changed(bot.id)
            return false
        }
        let latchReason = payload.reason ?? (parent.externalWorking ? .backgroundTask : nil)
        busyThreads[bot.id] = BusyLatch(key: key, storedId: entry.storedId, heldAt: parent.acceptedSends,
                                        lastActivity: now, reason: latchReason, parent: parent)
        optedOutProfiles.remove(bot.id)
        trackReconciliation(key: key, profile: bot.id)
        startAvailabilityProbe(profile: bot.id, parent: parent, reason: latchReason)
        // Only hand back the initial unconfirmed auto-thread send if the thread fails off-screen; never clobber the
        // main chat's draft after the user opens the thread or after the thread has already accepted sends.
        live.onDraftReturned = { [weak self, weak parent, weak live, weak entry] text, reason in
            guard let live, !live.observing, live.acceptedSends == 0 else { return }
            if let entry, entry.storedId == nil {
                self?.entries.removeAll { $0.key == entry.key }
                if self?.busyThreads[entry.profile]?.key == entry.key { self?.busyThreads[entry.profile] = nil }
                self?.changed(entry.profile)
            }
            parent?.threadSendCameBack(text, reason: reason)
        }
        return true
    }

    private func trackReconciliation(key: String, profile: String) {
        var list = pendingReconciliation[profile] ?? []
        if !list.contains(key) { list.append(key) }
        if list.count > 4 { list.removeFirst(list.count - 4) }
        pendingReconciliation[profile] = list
    }

    /// Keeps idle thread runtimes lean when spinning up a new auto-thread.
    private func releaseOldestIdleIfCrowded() {
        let idle = entries.filter { entry in
            guard let live = entry.live else { return false }
            return !live.isRunning && !live.observing
        }.sorted { $0.lastChange < $1.lastChange }
        if idle.count >= Self.idleLive, let oldest = idle.first { release(oldest) }
    }

    private func adopt(_ live: LiveChatSession, for entry: Entry) {
        entry.live = live
        live.menus.isThread = true
        live.threadHold = true
        live.onThreadChange = { [weak self, weak entry, weak live] in
            guard let self, let entry, let live, entry.live === live else { return }
            var hasher = Hasher()
            hasher.combine(live.messages.count)
            if let last = live.messages.last { hasher.combine(last.id); hasher.combine(last.revision); hasher.combine(last.isStreaming) }
            hasher.combine(live.isRunning); hasher.combine(live.title); hasher.combine(live.storedSessionId)
            hasher.combine(live.threadProblem)
            let now = hasher.finalize()
            guard now != entry.drawn else { return }
            entry.drawn = now
            entry.lastChange = Date()
            if entry.storedId == nil { entry.storedId = live.storedSessionId }
            self.changed(entry.profile)
            if !live.isRunning { self.trim() }
        }
    }

    // MARK: Opening

    /// The chat for the thread's own screen: the live one, or the listed chat opened (and kept live from here on).
    func chatModel(for key: String) -> (any ChatSessionModel)? {
        guard let entry = entries.first(where: { $0.key == key }), let model else { return nil }
        if let live = entry.live { return live }
        guard let stored = entry.storedId else { return nil }
        let summary = SessionSummary(id: stored, profile: entry.profile, title: ThreadRules.name(thread(entry)), preview: nil,
                                     lastActive: entry.lastChange, source: nil, unread: false, isRunning: false)
        let chat = model.chat(for: summary)
        if let live = chat as? LiveChatSession { adopt(live, for: entry) }
        trim()
        return chat
    }

    /// "Thread", or its own short title; nil for a key not known.
    func name(for key: String) -> String? {
        entries.first(where: { $0.key == key }).map { ThreadRules.name(thread($0)) }
    }

    /// The thread whose stored chat is `storedId`, when the bot chat showing it is the one on screen: its reply is read
    /// there, so it raises no alert.
    func isDrawn(storedId: String?, profile: String, in focused: LiveChatSession?) -> Bool {
        guard let storedId, let focused, focused.menus.isBotChat, focused.profile == profile else { return false }
        return entries.contains { $0.profile == profile && ($0.storedId == storedId || $0.live?.storedSessionId == storedId) }
    }

    /// These threads stand open in the bot chat on screen: a finished reply in them is read there.
    func markSeen(_ keys: [String]) {
        guard let store = model?.sessionStore else { return }
        for entry in entries where keys.contains(entry.key) {
            guard let stored = entry.live?.storedSessionId ?? entry.storedId, entry.live?.isRunning != true else { continue }
            store.markReadInPlace(id: stored, profile: entry.profile)
        }
    }

    // MARK: Letting go

    /// Idle threads beyond the newest few stop listening; what they showed stays.
    private func trim() {
        let idle = entries.filter { entry in
            guard let live = entry.live else { return false }
            return !live.isRunning && !live.observing
        }.sorted { $0.lastChange > $1.lastChange }
        for entry in idle.dropFirst(Self.idleLive) { release(entry) }
    }

    private func release(_ entry: Entry) {
        guard let live = entry.live else { return }
        entry.kept = live.messages
        if entry.storedId == nil { entry.storedId = live.storedSessionId }
        entry.problem = live.threadProblem
        live.onThreadChange = nil
        live.endThreadHold()
        entry.live = nil
    }

    /// Sign-out or a gateway switch: nothing of this account's threads stays.
    func reset() {
        for entry in entries { entry.live?.onThreadChange = nil; entry.live?.threadHold = false }
        entries = []
        busyThreads = [:]
        optedOutProfiles = []
        for task in availabilityProbes.values { task.cancel() }
        availabilityProbes = [:]
        pendingReconciliation = [:]
        restoredReconciliation = [:]
        observers = []
        owed = []
    }
}
