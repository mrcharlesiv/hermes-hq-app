// [offline] The open chat's part of the reconnect rules (docs/spec/3x-offline.md §6.3, §6.5): the reconnect owns the
// tail read (a `sessions.changed` tick during it schedules nothing; a "reopen" and a "gateway.ready" reconnect within
// 400 ms of each other are one reconnect), and a resume that settles on a reply the gateway has not saved starts the
// tail recheck. The state lives beside the chat (a weak table), so the chat class itself gains no stored property.

import UIKit

@MainActor final class ChatReconnectState {
    /// A reconnect that starts within this long of one still running is the same reconnect.
    nonisolated static let joinWindow: TimeInterval = 0.4

    var running = false
    var startedAt: TimeInterval = -.infinity
    var runtimeAtStart: String?
    /// A later call joined the running reconnect: if that one ends without having caught up, one more follows.
    var joined = false
    var recheck: TailRecheckSeries?
    /// Re-tries of a `session.activate` that timed out on a socket that stayed up (`reconnectEnded`).
    var activateTimeoutRetries = 0
    nonisolated static let activateTimeoutRetryLimit = 2
    /// Counters for tests: reconnects joined, and changed passes a running reconnect stood down.
    var joins = 0
    var stoodDown = 0

    private static let table = NSMapTable<LiveChatSession, ChatReconnectState>.weakToStrongObjects()

    static func of(_ chat: LiveChatSession) -> ChatReconnectState {
        if let state = table.object(forKey: chat) { return state }
        let state = ChatReconnectState()
        table.setObject(state, forKey: chat)
        return state
    }

    static func existing(_ chat: LiveChatSession) -> ChatReconnectState? { table.object(forKey: chat) }

    /// The pure join rule (§6.5), for tests.
    nonisolated static func joins(running: Bool, startedAt: TimeInterval, now: TimeInterval, runtimeAtStart: String?, runtime: String?) -> Bool {
        running && now - startedAt < joinWindow && runtimeAtStart == runtime
    }
}

extension LiveChatSession {
    /// §6.5: a reconnect is running, so a `sessions.changed` tick schedules nothing (the reconnect's own read is the one).
    var reconnectOwnsTail: Bool {
        guard let state = ChatReconnectState.existing(self), state.running else { return false }
        state.stoodDown += 1
        return true
    }

    /// §6.5: true when the reconnect about to start is the one already running (same runtime id, begun under 400 ms ago).
    func joinsRunningReconnect() -> Bool {
        let state = ChatReconnectState.of(self)
        guard ChatReconnectState.joins(running: state.running, startedAt: state.startedAt, now: ProcessInfo.processInfo.systemUptime,
                                       runtimeAtStart: state.runtimeAtStart, runtime: runtimeSessionId) else { return false }
        state.joined = true
        state.joins += 1
        return true
    }

    func reconnectBegan() {
        let state = ChatReconnectState.of(self)
        if observing { MainTrail.set("catchUp", "running") }      // [diagnostics] build 292: HangWatch's context
        state.running = true
        state.joined = false
        state.startedAt = ProcessInfo.processInfo.systemUptime
        state.runtimeAtStart = runtimeSessionId
    }

    /// The newest reconnect ended. `caughtUp`: it ran to its end (replay, `session.events.since` or its REST tail read).
    /// `activateTimedOut`: its `session.activate` got no answer on a socket that stayed up.
    func reconnectEnded(caughtUp: Bool, snapshot: JSONValue?, activateTimedOut: Bool = false) {
        let state = ChatReconnectState.of(self)
        state.running = false
        if observing { MainTrail.set("catchUp", caughtUp ? "done" : "gave up") }   // [diagnostics] build 292
        let joined = state.joined
        state.joined = false
        if caughtUp {
            state.activateTimeoutRetries = 0
            // A `sessions.changed` within the pass gap becomes the one trailing pass (a limit-1 probe), not a second read.
            lastChangedPassAt = Date()
            tailSettled(snapshot)
        } else if joined, observing, isLive {
            // The reconnect a later call joined gave up (its socket went away): that call's own reconnect runs now.
            AppLog.trace("chat", "reconnect \(logIds) gave up with a joined call waiting: running it again")
            reconnectTask = Task { [weak self] in await self?.reconnect(reason: "gateway.ready") }
        } else if activateTimedOut, observing, isLive, state.activateTimeoutRetries < ChatReconnectState.activateTimeoutRetryLimit {
            // The socket stayed up, so no gateway.ready retries it: nothing would catch up (frames missed while paused,
            // a turn's end) until the silence watchdog. Two more tries, 1 s then 3 s on; a newer reconnect cancels them.
            state.activateTimeoutRetries += 1
            let attempt = state.activateTimeoutRetries
            if observing { MainTrail.set("catchUp", "activate timeout, retry \(attempt)") }   // [diagnostics]
            AppLog.note("chat", "reconnect: session.activate timed out, retry \(attempt)")
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(for: attempt == 1 ? .seconds(1) : .seconds(3))
                guard let self, !Task.isCancelled, self.observing, self.isLive else { return }
                await self.reconnect(reason: "activate-timeout")
            }
        }
    }

    /// A gateway.ready reconnect starts afresh: the activate-timeout retries count from zero again.
    func resetActivateTimeoutRetries() {
        ChatReconnectState.existing(self)?.activateTimeoutRetries = 0
    }

    /// §6.3: a resume (a reconnect or an open) settled: start, restart or end the tail recheck.
    func tailSettled(_ snapshot: JSONValue?) {
        let state = ChatReconnectState.of(self)
        let running = turn.busy || snapshot?["running"]?.bool == true
        let journaled = snapshot?["running"]?.bool == false && !(snapshot?["inflight"]?["assistant"]?.string ?? "").isEmpty
        var local = false
        if !running, let at = messages.lastIndex(where: { $0.role == .user }),
           let reply = messages[(at + 1)...].last(where: { $0.role == .assistant }) {
            local = reply.rowId == nil && !reply.plainText.isEmpty
        }
        if state.recheck == nil {
            guard journaled || local, !running else { return }
            AppLog.trace("chat", "tail recheck \(logIds): series made (journaled partial=\(journaled), unsaved live reply=\(local))")
            state.recheck = TailRecheckSeries(
                owed: { [weak self] in
                    guard let self else { return false }
                    return self.observing && UIApplication.shared.applicationState == .active
                },
                read: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.tailRecheckRows()
                },
                resume: { [weak self] in self?.startRefresh(force: true) })
        }
        state.recheck?.logName = logIds
        state.recheck?.settled(partial: journaled || local, running: running, shown: TailRecheck.shown(messages))
    }

    /// §6.3 step: the chat's newest saved rows, read without merging. A tool-heavy turn (a dozen steps or so) puts its
    /// prompt beyond the newest 24 rows, so every step said "nothing saved" and the partial stayed: with no prompt among
    /// them the read reaches back a full page.
    func tailRecheckRows() async throws -> [JSONValue] {
        guard let stored = readSessionId else { throw CancellationError() }
        let request = HistoryRequest(storedSessionId: stored, profile: profileParam, limit: 24)
        let page = try await HistoryAPI.fetch(client: client, request: request, features: perfFeatures).0
        guard page.possiblyTruncated, !page.rows.contains(where: { $0["role"]?.string == "user" }) else { return page.rows }
        let full = HistoryRequest(storedSessionId: stored, profile: profileParam, limit: LiveChatSession.fullPageRows)
        return try await HistoryAPI.fetch(client: client, request: full, features: perfFeatures).0.rows
    }

    /// The chat left the screen: its series ends.
    func tailRecheckStopped() {
        ChatReconnectState.existing(self)?.recheck?.cancel()
    }
}
