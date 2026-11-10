// [groups] One member's turn in a room (docs/spec/3x-groups.md §6.6–§6.7): its hidden session, the baseline, the
// submit, the wait and the pick. A port of `HB/group-turns.ts:278-445, 859-1286` over `GatewayClient.call` (§4.4).

import Foundation

nonisolated struct GroupTiming: Sendable {
    /// Base time limit of a turn, extended while the session is busy or waits for your answer.
    var base: TimeInterval = 180
    var hardCap: TimeInterval = 180 * 60
    /// The read after a silent stretch, and between reads of a busy session.
    var poll: TimeInterval = 5
    var settle: TimeInterval = 0.25
    var settleChecks = 8
    var harvestEvery: TimeInterval = 5
    var call: Duration = .seconds(30)

    static var standard: GroupTiming {
        var timing = GroupTiming()
        #if DEBUG
        // UI tests shorten the limits so a `late:` turn strands in seconds (`-HQGroupsTurnLimit 6`): a turn that stays
        // busy is given up at the hard cap (twice the limit here), and its reply is collected when it lands.
        let limit = UserDefaults.standard.double(forKey: "HQGroupsTurnLimit")
        if limit > 0 {
            timing.base = limit
            timing.hardCap = limit * 2
            timing.poll = min(timing.poll, max(1, limit / 3))
            timing.harvestEvery = 2
        }
        #endif
        return timing
    }
}

/// A member's hidden session as one `session.resume` answered it.
nonisolated struct GroupSessionState: Sendable {
    struct Row: Sendable, Equatable {
        var role: String
        var text: String
    }
    var runtime: String
    var stored: String?
    var rows: [Row] = []
    var running = false
    var hasInflight = false
    /// A kept `{status: "error"}`: the turn failed, the session is not busy.
    var retainedError: String?
    var retainedKey: String?
    var waitingOnUser = false
    /// `ensureSession` made this session just now (`fresh` in `ensureGroupChatSession`): it has no transcript yet.
    var fresh = false
    /// The answer said whether the session is busy (`running` or `inflight` present). A light read
    /// (`omit_messages`) from a gateway that dropped them says nothing, so its "not busy" can't be trusted.
    var busyKnown = true

    /// `groupSessionBusy`.
    var busy: Bool { running || (hasInflight && retainedError == nil) }

    init?(_ result: JSONValue) {
        guard let runtime = result["session_id"]?.string?.trimmingCharacters(in: .whitespaces), !runtime.isEmpty else { return nil }
        self.runtime = runtime
        stored = result["session_key"]?.string ?? result["stored_session_id"]?.string ?? result["resumed"]?.string
        running = result["running"]?.bool == true
        busyKnown = result["running"] != nil || result["inflight"] != nil
        if let inflight = result["inflight"], !inflight.isNull {
            hasInflight = true
            if inflight["status"]?.string == "error" {
                retainedError = inflight["error"]?.string ?? "turn failed"
                retainedKey = "\(result["turn_started_at"]?.double ?? 0)|\(retainedError ?? "")"
            }
        }
        let open = result["open_requests"]?.array ?? []
        let approval = result["pending_approval"]
        waitingOnUser = open.contains { ($0["method"]?.string ?? $0["kind"]?.string ?? "").hasPrefix("clarify") }
            || (approval != nil && approval?.isNull == false)
        rows = (result["messages"]?.array ?? []).map { message in
            let text: String
            if let content = message["content"]?.string { text = content }
            else if let parts = message["content"]?.array { text = parts.map { $0.string ?? $0["text"]?.string ?? "" }.joined() }
            else { text = message["text"]?.string ?? "" }
            return Row(role: message["role"]?.string ?? "", text: text)
        }
    }
}

nonisolated enum GroupTurnError: Error, Sendable, Equatable {
    /// The session check failed with something other than "does not exist": never start a second session.
    case check(String)
    /// The prompt never went out (the member did not take the message).
    case notSent(String)
    /// The prompt went out and the turn failed.
    case failed(String)
    /// The prompt went out and no reply came in time: it may still land (§6.7).
    case timedOut(before: Int, stored: String?)
    case cancelled

    var reason: String {
        switch self {
        case .check(let text), .notSent(let text), .failed(let text): return text
        case .timedOut: return "took too long"
        case .cancelled: return "cancelled"
        }
    }
}

/// `message.complete` / `error` events by runtime id, for the turn's wait.
@MainActor final class GroupSignals {
    private var task: Task<Void, Never>?
    private var waiters: [UUID: (runtime: String, continuation: CheckedContinuation<Bool, Never>)] = [:]
    /// When each runtime last ended a turn: a signal that lands between two waits (during a read) is not lost.
    private(set) var fired: [String: Date] = [:]
    static let firedLimit = 64

    func start(_ client: any GatewayClient) {
        guard task == nil else { return }
        // [perf] Filtered off the main actor: only the two event types it wants hop over, not every streamed delta.
        task = Task.detached { [weak self] in
            for await event in client.events() where event.type == "message.complete" || event.type == "error" {
                await self?.fire(event.sessionId)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        fired = [:]
        wakeAll()
    }

    func fire(_ runtime: String) {
        fired[runtime] = Date()
        if fired.count > Self.firedLimit, let oldest = fired.min(by: { $0.value < $1.value })?.key { fired[oldest] = nil }
        for (id, waiter) in waiters where waiter.runtime == runtime {
            waiters[id] = nil
            waiter.continuation.resume(returning: true)
        }
    }

    /// Stop and delete wake every wait at once (the turn then sees it is no longer current).
    func wakeAll() {
        let all = waiters
        waiters = [:]
        for waiter in all.values { waiter.continuation.resume(returning: false) }
    }

    /// true when the session's turn ended within `seconds`, or already ended after `since`.
    func wait(runtime: String, seconds: TimeInterval, since: Date) async -> Bool {
        if let at = fired[runtime], at > since { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters[id] = (runtime, continuation)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0.05, seconds) * 1_000_000_000))
                guard let self, let waiter = self.waiters.removeValue(forKey: id) else { return }
                waiter.continuation.resume(returning: false)
            }
        }
    }
}

@MainActor final class GroupTurn {
    let client: any GatewayClient
    let signals: GroupSignals
    var timing: GroupTiming

    init(client: any GatewayClient, signals: GroupSignals, timing: GroupTiming = .standard) {
        self.client = client
        self.signals = signals
        self.timing = timing
    }

    static func reason(_ error: Error) -> String {
        if let rpc = error as? RPCError { return rpc.plainReason }
        if let turn = error as? GroupTurnError { return turn.reason }
        return (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    /// `isSessionGoneError`: the runtime id is not live any more (resume by the stored id, then go on).
    static func isGone(_ error: Error) -> Bool {
        guard let rpc = error as? RPCError else { return false }
        let message = rpc.message.lowercased()
        return rpc.code == 4001 || message.contains("not in memory") || message.contains("session not found")
    }

    func read(_ target: String, profile: String, messages: Bool) async throws -> GroupSessionState {
        var params: [String: JSONValue] = ["session_id": .string(target), "profile": .string(profile)]
        if !messages { params["omit_messages"] = true }
        let result = try await client.call("session.resume", .object(params), timeout: timing.call)
        guard let state = GroupSessionState(result) else { throw RPCError(code: -1, message: "Missing group runtime", data: nil) }
        return state
    }

    /// The newest assistant message after `before` with real text; a `(pass)` only when nothing else is there.
    static func pick(_ rows: [GroupSessionState.Row], before: Int) -> String? {
        var pass: String?
        var index = rows.count - 1
        while index >= max(0, before) {
            let row = rows[index]
            index -= 1
            guard row.role == "assistant" else { continue }
            let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if GroupPrompt.isPass(text) { if pass == nil { pass = text }; continue }
            return text
        }
        return pass
    }

    /// `ensureGroupChatSession`: the member's hidden session for this thread, found or made once.
    func ensureSession(room: GroupRoom, thread: String, seat: GroupSeat, idempotencyKey: String,
                       save: (String) -> Void) async throws -> GroupSessionState {
        let roomTitle = "Group: \(room.roomId ?? room.name)"
        let title = "\(roomTitle) · \(thread)"
        let known = room.sessions[GroupKeys.sessionKey(thread: thread, memberKey: seat.key)]
        let scoped = room.sessions.keys.contains { $0.hasPrefix("thread:") && $0.hasSuffix("::\(seat.key)") }
        let legacy = scoped ? nil : room.sessions[seat.key]
        var targets: [String] = [known, title].compactMap { $0 }
        if let legacy { targets += [legacy, roomTitle] }
        for target in targets where !target.isEmpty {
            var attempt = 0
            while true {
                attempt += 1
                do {
                    let state = try await read(target, profile: seat.name, messages: false)
                    let stored = state.stored ?? ((target == title || target == roomTitle) ? known : target)
                    if let stored { save(stored) }
                    var out = state
                    out.stored = stored
                    return out
                } catch let error as RPCError where error.code == 4007 {
                    // Does not exist: the next target. A 4007 that says "no longer live" is asked once more.
                    if attempt == 1, error.message.lowercased().contains("no longer live") { continue }
                    break
                } catch is CancellationError {
                    throw GroupTurnError.cancelled
                } catch {
                    throw GroupTurnError.check("Couldn’t check \(seat.display)'s group session (\(Self.reason(error))) — not starting a new one")
                }
            }
        }
        let params: JSONValue = ["profile": .string(seat.name), "title": .string(title), "hidden": true, "room_plumbing": true,
                                 "follow_profile_config": true, "idempotency_key": .string(idempotencyKey)]
        var created: JSONValue
        do {
            created = try await client.call("session.create", params, timeout: timing.call)
        } catch let error as RPCError where error.isConnectionLost || error.isTimeout {
            // A lost answer: the same key answers the same session, never a second one.
            created = try await client.call("session.create", params, timeout: timing.call)
        }
        guard var state = GroupSessionState(created) else { throw GroupTurnError.notSent("The gateway did not start a session for \(seat.display).") }
        state.stored = created["stored_session_id"]?.string ?? state.stored
        state.fresh = true
        if let stored = state.stored { save(stored) }
        return state
    }

    /// Runs the turn. Returns the member's reply text (nil = nothing to post). `onRuntime` gets the live runtime id
    /// as soon as it is known (and again when it changes); `onWaiting` follows "waits for your answer". `freshContext`:
    /// the room's other threads, added to the prompt only when this turn makes the member's session.
    func run(room: GroupRoom, thread: String, seat: GroupSeat, prompt basePrompt: String, freshContext: [String] = [],
             isCurrent: @escaping () -> Bool,
             save: (String) -> Void, onRuntime: (_ runtime: String, _ stored: String?) -> Void,
             onAccepted: (_ before: Int, _ stored: String?) -> Void, onWaiting: (Bool) -> Void) async throws -> String? {
        let session: GroupSessionState
        do {
            session = try await ensureSession(room: room, thread: thread, seat: seat, idempotencyKey: UUID().uuidString.lowercased(), save: save)
        } catch let error as GroupTurnError { throw error
        } catch { throw GroupTurnError.notSent(Self.reason(error)) }
        guard isCurrent() else { throw GroupTurnError.cancelled }
        let prompt = session.fresh ? GroupPrompt.addFreshThreadContext(basePrompt, lines: freshContext) : basePrompt
        let stored = session.stored ?? session.runtime
        var runtime = session.runtime
        // Baseline: how long the transcript is now, and a failure left over from an earlier turn.
        var before = 0
        var staleError: String?
        do {
            let baseline = try await read(stored, profile: seat.name, messages: true)
            runtime = baseline.runtime
            before = baseline.rows.count
            staleError = baseline.retainedKey
        } catch {
            throw GroupTurnError.notSent(Self.reason(error))
        }
        guard isCurrent() else { throw GroupTurnError.cancelled }
        onRuntime(runtime, session.stored)
        func submit(_ runtime: String) async throws {
            _ = try await client.call("prompt.submit", ["session_id": .string(runtime), "profile": .string(seat.name), "text": .string(prompt)],
                                      timeout: timing.call)
        }
        let submitted = Date()
        do {
            do { try await submit(runtime) }
            catch where Self.isGone(error) {
                let again = try await read(stored, profile: seat.name, messages: false)
                runtime = again.runtime
                onRuntime(runtime, session.stored)
                try await submit(runtime)
            }
        } catch {
            throw GroupTurnError.notSent(Self.reason(error))
        }
        onAccepted(before, session.stored)
        // Signals count from the submit on (an earlier turn's end on this runtime never does). Moved on after each
        // wait, so a signal that lands during a read wakes the next wait at once, and each one counts only once.
        var since = submitted
        let started = Date()
        var deadline = started.addingTimeInterval(timing.base)
        let hardStop = started.addingTimeInterval(timing.hardCap)
        var waiting = false
        defer { if waiting { onWaiting(false) } }
        while true {
            guard isCurrent() else { throw GroupTurnError.cancelled }
            let signalled = await signals.wait(runtime: runtime, seconds: timing.poll, since: since)
            since = Date()
            guard isCurrent() else { throw GroupTurnError.cancelled }
            // [perf] Light reads while it works (the busy fields come without the transcript, which can be hundreds
            // of KB); the full read only once it says it's done, or didn't say. A light "not busy" never picks.
            var state = try? await read(stored, profile: seat.name, messages: false)
            if signalled {
                var checks = 0
                while let now = state, now.busy, checks < timing.settleChecks {
                    checks += 1
                    try? await Task.sleep(nanoseconds: UInt64(timing.settle * 1_000_000_000))
                    state = try? await read(stored, profile: seat.name, messages: false)
                }
            }
            if let light = state, !light.busy || !light.busyKnown {
                state = try? await read(stored, profile: seat.name, messages: true)
            }
            guard isCurrent() else { throw GroupTurnError.cancelled }
            if let state {
                if state.runtime != runtime { runtime = state.runtime; onRuntime(runtime, session.stored) }
                if state.waitingOnUser != waiting { waiting = state.waitingOnUser; onWaiting(waiting) }
                if !state.busy {
                    if let reply = Self.pick(state.rows, before: before) { return reply }
                    if let error = state.retainedError, state.retainedKey != staleError { throw GroupTurnError.failed(error) }
                    if signalled { return nil }       // the turn ended and left nothing to post
                } else {
                    deadline = min(hardStop, Date().addingTimeInterval(timing.base))
                }
                if state.waitingOnUser { deadline = min(hardStop, Date().addingTimeInterval(timing.base)) }
            }
            if Date() >= deadline { throw GroupTurnError.timedOut(before: before, stored: session.stored) }
        }
    }

    enum Harvest: Equatable, Sendable { case busy, reply(String), nothing }

    /// `harvestStrandedGroupReply`: a timed-out turn's session read again.
    func harvest(_ marker: GroupStranded, profile: String) async -> Harvest {
        // Light first: a member still at work costs no transcript download.
        guard let stored = marker.stored, let light = try? await read(stored, profile: profile, messages: false) else { return .busy }
        if light.busy { return .busy }
        guard let state = try? await read(stored, profile: profile, messages: true) else { return .busy }
        if state.busy { return .busy }
        if let reply = Self.pick(state.rows, before: marker.before), !GroupPrompt.isPass(reply) { return .reply(reply) }
        return .nothing
    }
}

/// A room's Stop (row L467, `S/group-interrupt.ts`): the interrupt goes to the session's **live** runtime id, asked
/// for first by its stored id. Any failure answers false ("could not confirm").
nonisolated enum GroupInterrupt {
    static let timeout: Duration = .seconds(15)

    static func interrupt(client: any GatewayClient, profile: String, storedId: String) async -> Bool {
        do {
            let resumed = try await client.call("session.resume", ["session_id": .string(storedId), "omit_messages": true,
                                                                   "profile": .string(profile)], timeout: timeout)
            let runtime = (resumed["session_id"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !runtime.isEmpty else { return false }
            let result = try await client.call("session.interrupt", ["session_id": .string(runtime), "profile": .string(profile)],
                                               timeout: timeout)
            let status = result["status"]?.string
            return status == "interrupted" || status == "not_interrupted"
        } catch {
            return false
        }
    }
}
