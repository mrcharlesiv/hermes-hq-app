// The /api/ws JSON-RPC connection for one account (spec 01 §9–§13): single-use tickets (one request in flight),
// the socket, request/response matching with per-call timeouts, the multicast event stream, `gateway.ready`
// (heartbeat + replay epoch; `client.capabilities` first on every socket, spec 1x §2.1), answers to server→client
// requests (spec 1x §2.3), `open_requests` re-delivery (spec 1x §2.4), lossless
// replay of missed seq'd events, liveness pings, full-jitter reconnect, background grace and network changes.
// Runs on its own actor: frames are parsed and dispatched off the main thread.

import Foundation
import os

actor GatewayConnection {
    /// Where the connection reports to (owned by LiveGatewayClient; all thread-safe).
    struct Outlets: Sendable {
        let events: Broadcast<GatewayEvent>
        let states: StateHub
        let ready: Locked<JSONValue?>
        let failure: Locked<GatewayFailure?>
        /// Ends the UIKit background task (hops to the main actor itself).
        let endBackgroundTask: @Sendable () -> Void
        /// [offline] The outage gate's socket signals and the next dial's due time (GatewayConnection+Offline.swift).
        var offline = OfflineOutlets()
    }

    /// Every interval the connection keeps (spec 01 §12–13); tests shorten them.
    struct Timing: Sendable {
        var heartbeatInterval: Duration = .seconds(15)
        var heartbeatSilence: Duration = .seconds(45)
        var streamPingAfter: Duration = .seconds(5)
        var streamPongTimeout: Duration = .seconds(7)
        /// [connect-fast] 25 s (was 20): a return within it finds the socket open. With the 1 s close flush it stays
        /// inside the ~30 s the system gives a background task; an earlier expiry closes at once (`.backgroundExpired`).
        var backgroundGrace: TimeInterval = 25
        var connectTimeout: Duration = .seconds(15)
        var maxReadyWait: Duration = .seconds(60)
        /// [connect-fast] How long a dial waits for a Tailscale tunnel that reads as off, asking every 300 ms.
        var tunnelWait: Duration = .seconds(3)
        /// [frozen-dial] A dial still running this long when the app comes forward was frozen with the app (no step
        /// takes it: tunnel 3 s, ticket at most 21 s with any renewal it waits on): it is dropped and dialed again.
        var frozenDial: Duration = .seconds(40)
        static let standard = Timing()
    }

    enum Command: Sendable {
        case becameActive
        case enteredBackground(granted: Bool)
        case backgroundExpired
        /// [talk-background] A conversation runs on with the app away (the audio background mode keeps the app alive):
        /// the socket is kept through the background while held. Releasing it away starts the usual grace; `granted`
        /// says whether a fresh UIKit background task covers that grace.
        case holdOpen
        case releaseHold(granted: Bool)
        case path(PathChange)
        case reconnectNow
        case shutdown
    }

    private struct Pending {
        let method: String
        /// [questions] The call's `session_id` param (the `open_requests` interception's fallback, spec 1x §2.4).
        var sessionParam: String? = nil
        let timeout: Duration
        let continuation: CheckedContinuation<JSONValue, Error>
        var timer: Task<Void, Never>?
        /// [diagnostics] When it was written, for the call's time in the detailed log.
        var began = ContinuousClock.now
    }

    /// A call waiting for the socket, and the timer that gives up on it (cancelled when it is woken first).
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Never>
        var timer: Task<Void, Never>?
    }

    nonisolated let base: URL
    nonisolated let socketProfile: String
    private let auth: GatewayAuth
    private let transport: HTTPTransport
    private let out: Outlets
    private let timing: Timing
    private let lane = AsyncLane()

    // Socket
    private var socket: URLSessionWebSocketTask?
    /// Bumped on every close: answers, dials and timers from an older socket are ignored.
    private var socketEpoch = 0
    private var socketReady = false          // gateway.ready arrived on this socket
    private var published = false            // gateway.ready announced: callers may use the socket
    private var openedAt: ContinuousClock.Instant?
    /// [diagnostics] When the socket now dialing was started (the handshake's timing, Diagnostics › Gateway).
    private var dialedAt: Date?
    /// [perf-returns] The dial now in its handshake: its steps so far, when it began and when the socket was dialed.
    private var dialSteps: (steps: ConnectSteps, began: ContinuousClock.Instant, handshakeBegan: ContinuousClock.Instant)?
    /// [perf-returns] When the app went to the background, and the return that came after (cleared once a dial is ready).
    private var leftAt: ContinuousClock.Instant?
    private var returned: (at: ContinuousClock.Instant, away: Duration)?
    private var everReady = false
    private var heartbeat = false
    private var sessionAuthority = false   // [authority] this socket's `gateway.ready` named the session authority
    private var generations: [String: Int] = [:]   // [authority] session → its latest turn (`execution_generation`)
    private var lastInbound = ContinuousClock.now
    private var lastHeartbeatSent: ContinuousClock.Instant?
    private var heartbeatSeq = 0
    private var heartbeatsOutstanding: Set<String> = []
    private var livenessTask: Task<Void, Never>?
    private var replayTask: Task<Void, Never>?
    private var connectTimer: Task<Void, Never>?
    private var pingSeq = 0
    private var pingInFlight: Int?
    private var pingMisses = 0
    private var streaming: [String: ContinuousClock.Instant] = [:]
    private var wakeFailures = 0
    /// The path check in flight (`PathChange.verify`): only the newest one's answer counts.
    private var verifySeq = 0
    private var verifyTimer: Task<Void, Never>?
    /// Sockets in a row closed for an inbound frame over 64 MiB (spec 01 §10.3: say so once, never loop).
    private var tooLargeStreak = 0
    // [questions] The current socket's `client.capabilities` call and its `declines_not_shown` (spec 1x §2.1): readable
    // from any thread, reset when the socket closes.
    private var capabilitiesCallId: Int?
    nonisolated let declinesNotShown = Locked(false)

    // Requests
    private var nextId = 1
    private var pending: [Int: Pending] = [:]
    private var waiters: [Int: Waiter] = [:]
    private var nextWaiter = 0
    /// Callers waiting for one session's replay to finish (spec 01 §13.3 "a history read for a held session waits on
    /// that session's barrier").
    private var replayBarriers: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// Sessions this socket's replay answered in full (same epoch, not truncated): session → the `last_seen` it asked
    /// from. A chat whose own cursor is at or past it needs no `session.events.since` of its own, even when the replay
    /// found nothing to deliver (verification round 2: an empty replay made every chat ask a second time).
    private var replayedFrom: [String: Int] = [:]

    // Dialing
    private var dialTask: Task<Void, Never>?
    /// [frozen-dial] When the running dial began, and the epoch of a dial dropped as frozen (its failure is not one).
    private var dialBegan: ContinuousClock.Instant?
    /// The socket epoch the dial in flight was started for (`abandonDial`, `dropFrozenDial`).
    private var dialEpoch: Int?
    private var droppedDialEpoch: Int?
    private var retryTask: Task<Void, Never>?
    /// Failed attempts since the last stable socket (drives back-off; `.reconnecting(attempt:)` reports it).
    private var attempt = 0
    private var lastDialFailure: ContinuousClock.Instant?
    /// [net-ready] The quick redial after a dial that ran before the network was usable (NetSettle), and the floor the
    /// next dial waits out when it got one (nil: `ReconnectBackoff.minRedialSeconds`).
    private var settle = NetSettle()
    private var quickFloor: Duration?
    private var lastForcedReconnect: ContinuousClock.Instant?
    private var lastCallerDial: ContinuousClock.Instant?
    private var ticketTimeouts = 0
    /// A 429's `Retry-After`: dials the app starts on its own wait until then (spec 01 §15).
    private var retryNotBefore: ContinuousClock.Instant?
    /// [offline] The dial running was asked for with Try Again before the first ready: its failure does not climb the
    /// retry ladder.
    private var extraDial = false

    // Lifecycle
    private var started = false
    private var backgrounded = false
    private var backgroundClosed = false
    /// [talk-background] A conversation holds the socket open through the background (`Command.holdOpen`).
    private var held = false
    private var lastActivation: ContinuousClock.Instant?
    private var backgroundEpoch = 0
    private var graceTimer: DispatchSourceTimer?
    private var networkUp = true
    private var shutDown = false
    private var signedOut: GatewayFailure?

    // Replay (spec 01 §13.3)
    private var book = ReplayBook()
    /// [diagnostics] Detailed Logging: the stream's many small frames per session, counted and written as one line when
    /// the turn ends (message.complete / error) instead of one line each.
    private var tally: [String: [String: Int]] = [:]
    /// The profile each session id was last named with on a call (and the runtime id a call answered with), so the
    /// replay's `session.events.since` names it too (spec 04 §1.4: `profile` on every session RPC). Bounded.
    private var sessionProfiles: [String: String] = [:]

    init(base: URL, socketProfile: String, auth: GatewayAuth, transport: HTTPTransport, outlets: Outlets,
         timing: Timing = .standard) {
        self.base = base
        self.socketProfile = socketProfile
        self.auth = auth
        self.transport = transport
        self.out = outlets
        self.timing = timing
    }

    // MARK: Commands

    func start() {
        guard !started else { return }
        started = true
        settle.settling(at: .now)                         // [net-ready] a launch's first dial may beat the network too
        setState(.connecting)
        connect()
    }

    func handle(_ command: Command) async {
        switch command {
        case .becameActive: becameActive()
        case .enteredBackground(let granted): await enteredBackground(granted: granted)
        case .backgroundExpired: closeForBackground(epoch: backgroundEpoch, flush: false)
        case .holdOpen: holdOpen()
        case .releaseHold(let granted): releaseHold(granted: granted)
        case .path(let change): pathChanged(change)
        case .reconnectNow: manualRetry()
        case .shutdown: shutdown()
        }
    }

    /// Auth refused the session somewhere (REST, ticket, restore): stop for good and say so.
    func authRejected(_ failure: GatewayFailure) { becomeSignedOut(failure) }

    // MARK: Calls

    /// A JSON-RPC call. Waits for the socket (at most min(timeout, 60 s)), then gives the gateway `timeout` to answer.
    func call(_ method: String, _ params: JSONValue, timeout: Duration) async throws -> JSONValue {
        try await waitPublished(until: .now + min(timeout, timing.maxReadyWait))
        let profile = params["profile"]?.string
        if let profile, let session = params["session_id"]?.string { noteProfile(profile, for: session) }
        let result = try await send(method, params, timeout: timeout, epoch: socketEpoch)
        // `session.resume` / `session.create` name the stored id (or nothing) and answer with the runtime id.
        if let profile, let runtime = result["session_id"]?.string { noteProfile(profile, for: runtime) }
        if let runtime = result["session_id"]?.string, let generation = result["execution_generation"]?.int {   // [authority] a snapshot
            noteGeneration(generation, for: runtime, snapshot: true)
        }
        return result
    }

    /// A snapshot states the session's turn as it is now (a restarted gateway counts afresh); a frame only moves it on.
    private func noteGeneration(_ generation: Int, for session: String, snapshot: Bool = false) {   // [authority]
        guard !session.isEmpty, snapshot || generation >= (generations[session] ?? 0) else { return }
        if generations.count > 256 { generations.removeAll() }
        generations[session] = generation
    }

    private func noteProfile(_ profile: String, for session: String) {
        guard !session.isEmpty else { return }
        if sessionProfiles.count > 256 { sessionProfiles.removeAll() }
        sessionProfiles[session] = profile
    }

    /// Sends on the current socket (published or, for the replay, merely ready).
    private func send(_ method: String, _ params: JSONValue, timeout: Duration, epoch: Int) async throws -> JSONValue {
        guard let socket, socketReady, epoch == socketEpoch else { throw RPCError.notSent(.socketDead) }
        let id = nextId
        nextId += 1
        // [authority] The frame as this socket's server takes it; the caller (and `pending`) keep the app's own verb.
        let wire = AuthorityWire.adapt(method, params, authority: sessionAuthority,
                                       generation: params["session_id"]?.string.flatMap { generations[$0] })
        let text = RPCFrame.request(id: id, method: wire.method, params: wire.params)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.expire(id)
                }
                pending[id] = Pending(method: method, sessionParam: params["session_id"]?.string, timeout: timeout,
                                      continuation: continuation, timer: timer)
                socket.send(.string(text)) { [weak self] error in
                    guard error != nil else { return }
                    Task { await self?.sendFailed(id, epoch: epoch) }
                }
            }
        } onCancel: {
            Task { await self.settle(id, .failure(CancellationError())) }
        }
    }

    private func expire(_ id: Int) {
        guard let entry = pending[id] else { return }
        settle(id, .failure(RPCError.timedOut(entry.method, after: entry.timeout)))
    }

    private func sendFailed(_ id: Int, epoch: Int) {
        guard let entry = pending[id] else { return }
        settle(id, .failure(RPCError.connectionLost(entry.method)))
        if epoch == socketEpoch { invalidate(.socketDead) }
    }

    private func settle(_ id: Int, _ result: Result<JSONValue, Error>) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timer?.cancel()
        if AppLog.detailed {   // [diagnostics]
            let session = entry.sessionParam.map { " " + AppLog.tag($0) } ?? ""
            switch result {
            case .success: AppLog.trace("rpc", "\(entry.method)\(session) ok, \(AppLog.ms(since: entry.began)) ms")
            case .failure(let error):
                AppLog.trace("rpc", "\(entry.method)\(session) failed after \(AppLog.ms(since: entry.began)) ms: \(AppLog.scrub(String(describing: error)))")
            }
        }
        // Hermes reaped this runtime (a chat left a couple of minutes): its cursor goes, so every later reconnect stops
        // replaying a chat that can't have new frames (log study 2026-10-28: 482 of 512 replays in a day were empty).
        if case .failure(let error as RPCError) = result, error.code == 4001, entry.method == "session.activate",
           let session = entry.sessionParam, book.cursors[session] != nil {
            book.truncated(session)
            AppLog.trace("stream", "\(AppLog.tag(session)) is gone (4001): no more replays for it")
        }
        // [questions] A resume/activate/events.since result's still-open requests reach the event stream before its
        // caller sees the result (spec 1x §2.4).
        if case .success(let value) = result, ServerRequestsSwitch.enabled {
            let params: JSONValue = entry.sessionParam.map { ["session_id": .string($0)] } ?? [:]
            OpenRequestsIntercept.events(method: entry.method, params: params, result: value, epoch: socketEpoch)
                .forEach(out.events.yield)
        }
        entry.continuation.resume(with: result)
    }

    private func failAllPending() {
        let all = pending
        pending.removeAll()
        if !all.isEmpty { AppLog.trace("rpc", "connection lost under \(all.count) calls: \(all.values.map(\.method).sorted().joined(separator: ", "))") }
        for entry in all.values {
            entry.timer?.cancel()
            entry.continuation.resume(throwing: RPCError.connectionLost(entry.method))
        }
    }

    // MARK: Waiting for the socket

    /// Throws `GatewayFailure` (LiveGatewayClient turns it into `RPCError.notSent`). Known-down cases fail at once
    /// instead of waiting (spec 01 §13.6): no network path, Tailscale off, paused in the background, signed out.
    private func waitPublished(until deadline: ContinuousClock.Instant) async throws {
        while true {
            try Task.checkCancellation()
            if let signedOut { throw signedOut }
            if shutDown { throw GatewayFailure.connectionChanged }
            if published, socket != nil { return }
            if backgroundClosed { throw GatewayFailure.paused }
            if !networkUp { throw GatewayFailure.offline }
            if !GatewayAddress.reachable(base) { throw GatewayFailure.tailscaleOff }
            if ContinuousClock.now >= deadline { throw out.failure.value ?? GatewayFailure.timeout }
            callerWantsSocket()
            let id = nextWaiter
            nextWaiter += 1
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let timer = Task { [weak self] in
                        do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                        await self?.wake(id)
                    }
                    waiters[id] = Waiter(continuation: continuation, timer: timer)
                }
            } onCancel: {
                Task { await self.wake(id) }
            }
        }
    }

    private func wake(_ id: Int) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timer?.cancel()
        waiter.continuation.resume()
    }

    private func wakeAll() {
        let all = waiters
        waiters.removeAll()
        for waiter in all.values {
            waiter.timer?.cancel()
            waiter.continuation.resume()
        }
    }

    // MARK: Replay barriers

    /// Returns once `session`'s missed events have been replayed after a reconnect (at once when it isn't held). A
    /// history read of that session waits on this, so it never races the replayed frames (spec 01 §13.3). Bounded by
    /// the replay's 10 s deadline and by the socket closing.
    func replayDone(session: String) async {
        guard book.isParked(session) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            replayBarriers[session, default: []].append(continuation)
        }
    }

    /// The `last_seen` this socket's replay of `session` answered from (its missed frames are then delivered), nil when
    /// it did not replay that session in full.
    func replayedCursor(session: String) -> Int? { replayedFrom[session] }

    private func openBarrier(_ session: String) {
        replayBarriers.removeValue(forKey: session)?.forEach { $0.resume() }
    }

    private func openAllBarriers() {
        let all = replayBarriers
        replayBarriers.removeAll()
        all.values.joined().forEach { $0.resume() }
    }

    // MARK: Dialing

    private var mayDial: Bool { !shutDown && signedOut == nil && !backgroundClosed && networkUp }

    private func alive(_ epoch: Int) -> Bool { mayDial && epoch == socketEpoch }

    private func connect() {
        guard started, mayDial, socket == nil, dialTask == nil else { return }
        retryTask?.cancel()
        retryTask = nil
        out.offline.retry(due: nil)          // [offline] a dial runs: no countdown
        let epoch = socketEpoch
        dialBegan = .now
        dialEpoch = epoch
        dialTask = Task { await self.dial(epoch: epoch) }
    }

    /// A call is waiting for the socket: dial if idle; cut a back-off short at most once per 5 s (a busy screen must
    /// not turn a gateway outage into a ticket request a second).
    private func callerWantsSocket() {
        guard socket == nil, dialTask == nil else { return }
        if let notBefore = retryNotBefore, ContinuousClock.now < notBefore { return }
        if retryTask != nil {
            let now = ContinuousClock.now
            if let last = lastCallerDial, last.duration(to: now) < .seconds(5) { return }
            lastCallerDial = now
        }
        connect()
    }

    /// Dial now if idle or waiting out a back-off (a wake signal). `forced` resets the ladder.
    private func reconnectNow(forced: Bool) {
        // [offline] §3.7: before the first ready the wait keeps its place on the ladder (the offline screen's Try Again,
        // a return to the app and a restored network dial at once, but a gateway still down is not asked faster).
        if forced, everReady { attempt = 0 }
        if socket == nil, dialTask == nil { connect() }
    }

    /// [offline] "Try Again" (§3.1, §3.7). Before the first ready a socket that was dialed but never said ready is
    /// dropped and dialed again; a ticket request in flight is left to finish (tickets go one at a time, so a second
    /// could only wait behind it).
    private func manualRetry() {
        // [offline] review: the gateway said when to come back (429 Retry-After) and the offline screen is counting
        // that wait down: Try Again does not dial inside it.
        if let notBefore = retryNotBefore, ContinuousClock.now < notBefore { return }
        if !everReady, socket != nil, !socketReady {
            closeSocket(code: .goingAway)
        }
        // [offline] review: a Try Again dial is an extra one. If it fails, the automatic wait that follows is the rung
        // the ladder was on, not the next one up (three impatient taps must not turn 3 s into 30 s). **DECISION:**
        // only Try Again is exempt. A return to the app and a restored network still climb, so opening the app again
        // and again against a gateway that is down never asks it faster (UI `testS29`).
        if !everReady, socket == nil, dialTask == nil { extraDial = true }
        reconnectNow(forced: true)
    }

    private func dial(epoch: Int) async {
        defer {
            dialTask = nil
            dialBegan = nil
            dialEpoch = nil
            // Abandoned because a wake signal or path change arrived meanwhile (and no retry is waiting): dial again
            // now, or nobody would.
            if socket == nil, retryTask == nil, mayDial, epoch != socketEpoch { connect() }
        }
        let began = ContinuousClock.now                // [perf-returns]
        var steps = ConnectSteps()
        if let last = lastDialFailure {
            // [net-ready] A quick redial (NetSettle) waits its short floor once; every other dial the 1 s.
            let floor = quickFloor ?? .seconds(ReconnectBackoff.minRedialSeconds)
            quickFloor = nil
            let wait = floor - last.duration(to: .now)
            if wait > .zero { try? await Task.sleep(for: wait) }
        }
        guard alive(epoch) else { return }
        steps.waited = began.duration(to: .now)
        do {
            // [connect-fast] The desktop's way (apps/desktop use-gateway-boot.ts): minting the ticket is the session
            // check. No separate `/api/auth/me` first: a restored session that is refused fails the ticket (401 →
            // one refresh → 401/403 = signed out), and an address that isn't Hermes fails it too (GatewayAuth.mintTicket).
            var stepBegan = ContinuousClock.now
            try await tunnelUp()
            steps.tunnel = stepBegan.duration(to: .now)
            guard alive(epoch) else { return }
            stepBegan = .now
            let refreshesBefore = await auth.refreshesRun
            let ticket: String
            do {
                ticket = try await self.ticket(epoch: epoch)
                steps.ticket = stepBegan.duration(to: .now)
                steps.refreshed = await auth.refreshesRun != refreshesBefore
            } catch {
                steps.ticket = stepBegan.duration(to: .now)
                steps.refreshed = await auth.refreshesRun != refreshesBefore
                throw error
            }
            guard alive(epoch), socket == nil else { return }
            let url = try GatewayAddress.socketURL(base: base, profile: socketProfile, ticket: ticket)
            let task = try transport.webSocketTask(with: URLRequest(url: url, timeoutInterval: 15))
            task.maximumMessageSize = 64 << 20
            socket = task
            socketReady = false
            published = false
            lastInbound = .now
            dialedAt = Date()
            dialSteps = (steps, began, .now)              // [perf-returns]
            Signposts.begin(.socket, "Handshake")
            task.resume()
            receive(task, epoch: epoch)
            let timing = self.timing
            connectTimer = Task { [weak self] in
                do { try await Task.sleep(for: timing.connectTimeout) } catch { return }
                await self?.connectTimedOut(epoch: epoch)
            }
            AppLog.note("socket", "socket dialed")
        } catch {
            let failure = GatewayFailure.from(error)
            // [frozen-dial] Dropped on coming forward: the defer above dials again; this end says nothing.
            if droppedDialEpoch == epoch, !failure.isRejection { return }
            // [frozen-dial] Failed after running longer than any of its steps allows: it was frozen with the app, and
            // its deadline fired on the thaw before the return could drop it. End it as `dropFrozenDial` would.
            if !failure.isRejection, !(error is CancellationError), began.duration(to: .now) > timing.frozenDial {
                AppLog.note("net", "connect dropped: frozen \(ConnectSteps.ms(began.duration(to: .now))) ms, dialing again")
                socketEpoch += 1        // the defer above dials again at once (not a failure: no floor)
                return
            }
            if failure != .connectionChanged, !(error is CancellationError) {     // [perf-returns]
                noteConnect(steps, began: began, outcome: failure.code)
            }
            // [net-ready] Failed fast "unreachable" just after the app came forward or the path moved: once, dial again
            // after the short floor instead of the 1 s one and the ladder.
            let quick = error is CancellationError ? nil : settle.quickRedial(after: failure, began: began, now: .now)
            dialFailed(failure, epoch: epoch, retryAfter: (error as? RetryLater)?.after, quick: quick)
        }
    }

    /// [perf-returns] One line per dial that reached ready or failed, for the phone's performance log (ConnectSteps).
    private func noteConnect(_ steps: ConnectSteps, began: ContinuousClock.Instant, outcome: String) {
        var steps = steps
        let now = ContinuousClock.now
        steps.total = began.duration(to: now)
        steps.first = !everReady                          // ready() notes the dial before it sets everReady
        // The return led to this dial when the dial began soon after it (a socket that outlived the return and died
        // later is another story).
        if let returned, returned.at <= began, returned.at.duration(to: began) < .seconds(30) {
            steps.away = returned.away
            steps.sinceActive = returned.at.duration(to: now)
            if outcome == "ok" { self.returned = nil }
        }
        AppLog.note("net", steps.line(outcome: outcome))
    }

    /// [connect-fast] Throws `tailscaleOff` only once the tunnel has stayed off for `timing.tunnelWait` (a phone back
    /// from the background sees the tunnel's interface a beat late). Not an outage: no wait when it is up.
    private func tunnelUp() async throws {
        let base = self.base
        guard await tunnelComesUp(within: timing.tunnelWait, { GatewayAddress.reachable(base) }) else { throw GatewayFailure.tailscaleOff }
    }

    /// A fresh single-use ticket, minted right before the dial, one request in flight at a time (FIFO).
    private func ticket(epoch: Int) async throws -> String {
        await lane.enter()
        defer { lane.leave() }
        guard alive(epoch) else { throw GatewayFailure.connectionChanged }
        let timeout = ticketTimeout(afterTimeouts: ticketTimeouts)
        let asked = Date()                        // [diagnostics] §2.2: every ticket is a timed, named step
        let deadline = ContinuousClock.now + timeout + .seconds(1)
        SocketStats.shared.attempt()
        Signposts.begin(.socket, "Ticket")
        do {
            // [ticket-deadline] The rung is the whole step's budget, a renewal it waits on included: the request's own
            // timeout only counts idle time, and a Nous renewal before it added up to 15 s more. The 1 s of slack lets
            // URLSession's timeout normally answer first. A renewal still running past the deadline runs on and
            // persists its rotation (its own task); the next dial joins it or finds the new pair.
            let auth = self.auth
            let ticket = try await untilDeadline(deadline, late: { GatewayFailure.timeout }) {
                try await auth.mintTicket(timeout: timeout)
            }
            ticketTimeouts = 0
            StartupTimings.shared.record("socket.ticket", from: asked)
            Signposts.end(.socket, "Ticket", outcome: "ok")
            return ticket
        } catch {
            let outcome = error is CancellationError ? "cancelled" : GatewayFailure.from(error).code
            StartupTimings.shared.record("socket.ticket", from: asked, outcome: outcome)
            Signposts.end(.socket, "Ticket", outcome: outcome)
            // [frozen-dial] A deadline that fired well after it was due means the app was frozen meanwhile (the
            // continuous clock kept counting): not the gateway being slow, so the ladder stays on its rung.
            let failure = GatewayFailure.from(error)
            let frozen = failure == .timeout && deadline.duration(to: .now) > .seconds(2)
            ticketTimeouts = failure == .timeout ? (frozen ? ticketTimeouts : ticketTimeouts + 1) : 0
            throw error // a RetryLater keeps its wait
        }
    }

    private func dialFailed(_ failure: GatewayFailure, epoch: Int, retryAfter: TimeInterval? = nil, quick: Duration? = nil) {
        if failure == .connectionChanged, shutDown || signedOut != nil { return }
        lastDialFailure = .now
        out.failure.set(failure)
        AppLog.note("socket", "dial failed: \(failure.code)")
        if failure.isRejection { return becomeSignedOut(failure) }
        guard epoch == socketEpoch else { return }
        out.offline.gate?.dialFailed()       // [offline] §6.1
        if let quick, retryAfter == nil { return quickRedial(floor: quick) }
        scheduleReconnect(after: failure, retryAfter: retryAfter)
    }

    /// [net-ready] The dial ran before the network was usable (NetSettle): dial again once its short floor has passed.
    /// No rung is climbed and the state stays as it is (connecting / reconnecting): nothing failed worth showing yet. A
    /// second failure takes the normal path (1 s floor, the ladder, the offline screen's countdown).
    private func quickRedial(floor: Duration) {
        guard started, !shutDown, signedOut == nil, !backgroundClosed else { return }
        guard networkUp else { return setState(.offline(reason: GatewayFailure.offline.code)) }
        quickFloor = floor
        retryTask?.cancel()
        retryTask = Task { [weak self] in await self?.retryFired() }   // dial() waits the floor once this one has ended
    }

    private func connectTimedOut(epoch: Int) {
        guard epoch == socketEpoch, socket != nil, !socketReady else { return }
        lastDialFailure = .now
        handshakeEnded("timeout")                 // [diagnostics]
        out.failure.set(.timeout)
        closeSocket(code: .goingAway)
        out.offline.gate?.dialFailed()       // [offline] §6.1
        scheduleReconnect(after: .timeout)
    }

    /// [diagnostics] The dial that began at `dialedAt` ended: "ok" when the gateway said it is ready (the socket's
    /// upgrade and the gateway's first frame together: URLSession reports no separate moment for the upgrade), else
    /// the short failure code. Recorded once per dial.
    private func handshakeEnded(_ outcome: String) {
        guard let dialedAt else { return }
        self.dialedAt = nil
        StartupTimings.shared.record("socket.handshake", from: dialedAt, outcome: outcome)
        Signposts.end(.socket, "Handshake", outcome: outcome)
        if let dial = dialSteps {                         // [perf-returns]
            dialSteps = nil
            var steps = dial.steps
            steps.handshake = dial.handshakeBegan.duration(to: .now)
            noteConnect(steps, began: dial.began, outcome: outcome)
        }
        if outcome == "ok" {
            SocketStats.shared.opened(gateway: true)
            StartupTimings.shared.mark("socket.open")
        } else {
            StartupTimings.shared.mark("socket.error")
        }
    }

    private func scheduleReconnect(after failure: GatewayFailure?, retryAfter: TimeInterval? = nil) {
        guard started, !shutDown, signedOut == nil, !backgroundClosed else { return }
        guard networkUp else { return setState(.offline(reason: GatewayFailure.offline.code)) }
        let extra = extraDial && !everReady && attempt > 0
        extraDial = false
        if !extra { attempt += 1 }
        let backoff = everReady ? ReconnectBackoff.afterReady : ReconnectBackoff.beforeReady
        // [offline] §3.6: before the first ready the wait is the offline screen's ladder (3, 6, 12, 24, 30 s, no jitter),
        // so the countdown shown is this timer and not a second clock.
        var delay = everReady ? backoff.delay(attempt: attempt - 1) : RetryLadder.wait(attempt: attempt - 1)
        // The same oversized frame again right away: wait the full cap so it can never loop tightly.
        if failure == .responseTooLarge, tooLargeStreak >= 2 { delay = max(delay, backoff.cap) }
        if let retryAfter {
            // [offline] §3.6: before the first ready the wait is on show as a countdown, capped at the ladder's 120 s.
            let wait = min(retryAfter, everReady ? RetryLater.ceiling : RetryLadder.ceiling)
            delay = max(delay, wait)
            retryNotBefore = .now + .seconds(wait)
        }
        // Before the first ready a failed attempt is "offline, because…" (the launch's offline screen); after it the
        // socket is "reconnecting" (the UI waits a few seconds before saying more; `lastFailure` has the cause).
        if failure == .tailscaleOff { setState(.offline(reason: GatewayFailure.tailscaleOff.code)) }
        else if everReady { setState(.reconnecting(attempt: attempt)) }
        else { setState(.offline(reason: (failure ?? .unreachable).code)) }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.retryFired()
        }
        if !everReady { out.offline.retry(due: Date().addingTimeInterval(delay)) }      // [offline] §3.6
    }

    private func retryFired() {
        retryTask = nil
        connect()
    }

    // MARK: Receiving

    private func receive(_ task: URLSessionWebSocketTask, epoch: Int) {
        Task.detached { [weak self] in
            while true {
                let message: URLSessionWebSocketTask.Message
                do { message = try await task.receive() } catch {
                    await self?.socketFailed(task, error: error, epoch: epoch)
                    return
                }
                let frame: RPCFrame
                let size: Int
                switch message {
                case .string(let text):
                    size = text.utf8.count
                    frame = RPCFrame.parse(text)
                case .data(let data):
                    size = data.count
                    frame = RPCFrame.parse(data)
                @unknown default:
                    size = 0
                    frame = .ignored
                }
                guard let self else { return }
                await self.handle(frame, size: size, epoch: epoch)
            }
        }
    }

    private func handle(_ frame: RPCFrame, size: Int, epoch: Int) {
        guard epoch == socketEpoch, socket != nil else { return }
        lastInbound = .now
        switch frame {
        case .event(let event):
            if event.type == "gateway.ready" { return ready(event.payload, epoch: epoch) }
            if AppLog.detailed { traceEvent(event, size: size) }
            if let generation = event.generation { noteGeneration(generation, for: event.sessionId) }   // [authority]
            noteStreaming(event)
            deliverLive(event, size: size)
        case .result(let id, let value):
            if id == capabilitiesCallId { capabilitiesAnswered(value); return }   // [questions]
            settle(id, .success(value))
        case .failure(let id, let error):
            if id == capabilitiesCallId { capabilitiesCallId = nil; return }     // [questions] old backend: -32601
            settle(id, .failure(error))
        case .stringAnswer(let id):
            heartbeatsOutstanding.remove(id)
        case .serverRequest(let id, let method, let params):
            // [questions] Answered by the account's ServerRequestCenter (spec 1x §3.2), exactly once.
            out.events.yield(GatewayEvent(type: LocalEvent.serverRequest, sessionId: params["session_id"]?.string ?? "",
                                          seq: nil, payload: ["id": .string(id), "method": .string(method), "params": params,
                                                              "replayed": false, "epoch": .number(Double(epoch))]))
        case .orphanError(let error):
            AppLog.note("socket", "gateway refused a frame: \(error.code)")
        case .ignored:
            break
        }
    }

    private func socketFailed(_ task: URLSessionWebSocketTask, error: Error, epoch: Int) {
        guard epoch == socketEpoch, socket === task else { return }
        let ns = error as NSError
        var failure = GatewayFailure.socketDead
        var retryAfter: TimeInterval?
        if !socketReady {
            // Refused upgrade (HTTP 403 from Hermes, 401 from the edge) or a dead link while dialing: back off and
            // mint a new ticket next time; never a sign-out.
            if let response = task.response as? HTTPURLResponse, response.statusCode != 101 {
                failure = response.statusCode == 429 ? .rateLimited : (response.statusCode >= 500 ? .unavailable : .socketDead)
                if response.statusCode == 429 { retryAfter = RetryLater.parse(response.value(forHTTPHeaderField: "Retry-After")) }
            } else {
                failure = GatewayFailure.transport(domain: ns.domain, code: ns.code)
            }
            handshakeEnded((task.response as? HTTPURLResponse).flatMap { $0.statusCode != 101 ? "\($0.statusCode)" : nil } ?? failure.code)   // [diagnostics]
            lastDialFailure = .now
            out.offline.gate?.dialFailed()   // [offline] §6.1
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == 40 {
            AppLog.note("socket", "inbound frame over 64 MiB; closing with 1009")
            closeSocket(code: .messageTooBig)
            SocketStats.shared.tooBig()           // [diagnostics]
            tooLargeStreak += 1
            failure = .responseTooLarge
            // Replaying would bring the same frame back: forget the cursors, and have open chats re-read instead.
            for session in book.forgetCursors() {
                out.events.yield(GatewayEvent(type: LocalEvent.replayTruncated, sessionId: session, seq: nil, payload: .null))
            }
            if tooLargeStreak == 1 {
                out.events.yield(GatewayEvent(type: LocalEvent.messageTooLarge, sessionId: "", seq: nil,
                                              payload: ["message": .string(GatewayFailure.responseTooLarge.message)]))
            }
        } else {
            let code = task.closeCode
            AppLog.note("socket", "socket ended (close \(code.rawValue))")
            closeSocket(code: .goingAway)
        }
        out.failure.set(failure)
        scheduleReconnect(after: failure, retryAfter: retryAfter)
    }

    /// Drops the current socket (reconnect follows separately).
    private func invalidate(_ failure: GatewayFailure) {
        guard socket != nil else { return }
        out.failure.set(failure)
        closeSocket(code: .goingAway)
        scheduleReconnect(after: failure)
    }

    /// Closes the socket and forgets everything bound to it. Pending calls fail as "connection lost".
    private func closeSocket(code: URLSessionWebSocketTask.CloseCode?) {
        if let openedAt, openedAt.duration(to: .now) >= .seconds(ReconnectBackoff.stableOpenSeconds) {
            attempt = 0
            tooLargeStreak = 0
        }
        if let socket, let code { socket.cancel(with: code, reason: nil) }
        if published { out.offline.gate?.socket(open: false) }     // [offline] §6.1
        if socketReady {                                           // [diagnostics] §2.2
            SocketStats.shared.closed(gateway: true)
            StartupTimings.shared.mark("socket.close")
        }
        dialedAt = nil
        socket = nil
        socketEpoch += 1
        socketReady = false
        published = false
        openedAt = nil
        connectTimer?.cancel(); connectTimer = nil
        livenessTask?.cancel(); livenessTask = nil
        replayTask?.cancel(); replayTask = nil
        book.socketClosed()
        openAllBarriers()
        verifyTimer?.cancel(); verifyTimer = nil
        streaming.removeAll()
        capabilitiesCallId = nil            // [questions]
        declinesNotShown.set(false)
        heartbeatsOutstanding.removeAll()
        lastHeartbeatSent = nil
        pingInFlight = nil
        pingMisses = 0
        wakeFailures = 0
        failAllPending()
    }

    // MARK: gateway.ready

    private func ready(_ payload: JSONValue, epoch: Int) {
        guard !socketReady else { return }
        handshakeEnded("ok")                      // [diagnostics]
        socketReady = true
        everReady = true
        extraDial = false
        openedAt = .now
        connectTimer?.cancel(); connectTimer = nil
        out.ready.set(payload)
        heartbeat = payload["heartbeat"]?.bool == true
        sessionAuthority = payload["session_authority"]?.bool == true   // [authority]
        if sessionAuthority { AppLog.note("socket", "served by the gateway's session authority") }
        startLiveness(epoch: epoch)
        // [questions] `client.capabilities` is the first frame on every socket (spec 1x §2.1, replaces D1), written
        // before the replay and before any caller may use the socket. Callers may use the socket at once; only the
        // sessions being replayed hold their live seq'd frames (and history reads that wait on `replayDone(session:)`)
        // until their replay is in.
        sendCapabilities()
        let heldEpoch = book.epoch
        let sessions = book.ready(epoch: payload["replay_epoch"]?.string)
        replayedFrom = [:]
        tally = [:]
        AppLog.trace("stream", "ready: epoch \(heldEpoch == nil ? "new" : heldEpoch == book.epoch ? "same" : "changed (gateway restarted)"), replaying \(sessions.map(AppLog.tag).joined(separator: " "))")
        publish(payload)
        if !sessions.isEmpty { replayTask = Task { await self.replay(sessions, epoch: epoch) } }
    }

    private func publish(_ payload: JSONValue) {
        published = true
        retryNotBefore = nil
        out.offline.gate?.socket(open: true)     // [offline] §6.1
        out.offline.retry(due: nil)
        out.failure.set(nil)
        setState(.ready)
        AppLog.note("socket", "gateway ready")
        out.events.yield(GatewayEvent(type: "gateway.ready", sessionId: "", seq: nil, payload: payload))
        wakeAll()
    }

    // MARK: Replay (spec 01 §13.3)

    private func replay(_ sessions: [String], epoch: Int) async {
        let deadline = ContinuousClock.now + .seconds(10)
        var index = 0
        while index < sessions.count, epoch == socketEpoch, ContinuousClock.now < deadline {
            let batch = sessions[index..<min(index + 2, sessions.count)]
            index += 2
            await withChildTasks(of: Void.self) { group in
                for session in batch { group.addTask { await self.replayOne(session, epoch: epoch) } }
            }
        }
        guard epoch == socketEpoch, socketReady else { return }
        book.releaseAll().forEach(out.events.yield)
        openAllBarriers()
    }

    private func replayOne(_ session: String, epoch: Int) async {
        defer {
            if epoch == socketEpoch {
                book.release(session).forEach(out.events.yield)
                openBarrier(session)
            }
        }
        guard let last = book.cursors[session] else {
            AppLog.trace("stream", "replay \(AppLog.tag(session)): no cursor, nothing to replay")
            return
        }
        let began = ContinuousClock.now
        do {
            var params: [String: JSONValue] = ["session_id": .string(session), "last_seen": .number(Double(last))]
            if let profile = sessionProfiles[session] { params["profile"] = .string(profile) }
            let result = try await send("session.events.since", .object(params), timeout: .seconds(10), epoch: epoch)
            guard epoch == socketEpoch else { return }
            if let answered = result["epoch"]?.string, let held = book.epoch, answered != held {
                AppLog.trace("stream", "replay \(AppLog.tag(session)) from seq \(last): epoch changed, cursors dropped")
                book.epochChanged(to: answered)
                return
            }
            let items = result["events"]?.array ?? []
            var delivered = 0
            for item in items {
                guard var event = RPCFrame.event(from: item) else { continue }
                if event.sessionId.isEmpty { event.sessionId = session }
                if let generation = event.generation { noteGeneration(generation, for: event.sessionId) }   // [authority]
                if let fresh = book.acceptReplayed(event) { out.events.yield(fresh); delivered += 1 }   // [presence] marked replayed
            }
            if AppLog.detailed {
                let seqs = items.compactMap { RPCFrame.event(from: $0)?.seq }
                AppLog.trace("stream", "replay \(AppLog.tag(session)) from seq \(last): \(items.count) events (seq \(seqs.min().map(String.init) ?? "-")…\(seqs.max().map(String.init) ?? "-")), \(delivered) new, \(result["truncated"]?.bool == true ? "TRUNCATED" : "complete"), \(AppLog.ms(since: began)) ms")
            }
            if result["truncated"]?.bool == true {
                book.truncated(session)
                out.events.yield(GatewayEvent(type: LocalEvent.replayTruncated, sessionId: session, seq: nil, payload: .null))
            } else {
                replayedFrom[session] = last
            }
        } catch {
            // Best effort: the chat's own re-read covers a gap.
            AppLog.swallowed("stream", "replay \(AppLog.tag(session)) from seq \(last)", error)
        }
    }

    private func deliverLive(_ event: GatewayEvent, size: Int) {
        if published, book.hasGap(event) {
            // Lossless: hold this session and fetch what it missed from the gateway's ring, as on a reconnect.
            AppLog.trace("stream", "gap \(AppLog.tag(event.sessionId)): seq \(event.seq ?? -1) after \(book.cursors[event.sessionId] ?? -1), replaying")
            book.park(event.sessionId)
            let session = event.sessionId, epoch = socketEpoch
            Task { await self.replayOne(session, epoch: epoch) }
        }
        let parked = book.isParked(event.sessionId)
        let (deliver, overBudget) = book.live(event, size: size)
        if let deliver { out.events.yield(deliver) }
        else if !parked, let seq = event.seq { AppLog.trace("stream", "duplicate dropped \(AppLog.tag(event.sessionId)) seq \(seq) \(event.type)") }
        if overBudget {
            AppLog.note("stream", "held frames over budget (\(book.parkedCount) frames, \(book.parkedBytes) B): dropping the socket to replay")
            invalidate(.socketDead)
        }
    }

    // MARK: Detailed log of the stream [diagnostics]

    /// Frames that come many to a turn: counted, not written one by one.
    private static let countedTypes: Set<String> = ["message.delta", "thinking.delta", "reasoning.delta", "message.interim",
                                                    "tool.progress", "tool.output", "subagent.progress", "subagent.delta"]

    private func traceEvent(_ event: GatewayEvent, size: Int) {
        let session = event.sessionId
        let seq = event.seq.map { " seq \($0)" } ?? ""
        if Self.countedTypes.contains(event.type) || event.type.hasSuffix(".delta") {
            tally[session, default: [:]][event.type, default: 0] += 1
            tally[session, default: [:]]["bytes", default: 0] += size
            return
        }
        var line = "\(event.type) \(AppLog.tag(session))\(seq), \(size) B"
        if let counted = tally[session], event.type == "message.complete" || event.type == "error" || event.type.hasPrefix("tool.") {
            let parts = counted.filter { $0.key != "bytes" }.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }
            if !parts.isEmpty { line += " — since last: " + parts.joined(separator: ", ") + ", \(counted["bytes"] ?? 0) B" }
            tally[session] = nil
        }
        if let id = event.payload["message_id"]?.string ?? event.payload["id"]?.string { line += ", msg \(AppLog.tag(id))" }
        if let tool = event.payload["tool_name"]?.string ?? event.payload["name"]?.string, event.type.hasPrefix("tool.") { line += ", tool \(tool)" }
        if event.type == "error", let code = event.payload["code"]?.string ?? event.payload["type"]?.string { line += ", code \(code)" }
        AppLog.trace("event", line)
    }

    // MARK: Liveness (spec 01 §12.2–12.4)

    private func noteStreaming(_ event: GatewayEvent) {
        let type = event.type, session = event.sessionId
        guard !session.isEmpty || type == "session.reclaimed" else { return }
        if type.hasPrefix("message.start") || type == "message.delta" || type == "message.interim" || type == "thinking.delta"
            || type == "reasoning.delta" || type == "reasoning.available" || type.hasPrefix("tool.") {
            streaming[session] = .now
        } else if type.hasPrefix("subagent."), streaming[session] != nil {
            streaming[session] = .now
        } else if type == "message.complete" || type == "error" {
            streaming[session] = nil
        } else if type == "session.reclaimed" {
            streaming[event.payload["session_id"]?.string ?? session] = nil
        }
    }

    private func startLiveness(epoch: Int) {
        livenessTask?.cancel()
        livenessTask = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, await self.livenessTick(epoch: epoch) else { return }
            }
        }
    }

    private func livenessTick(epoch: Int) -> Bool {
        guard epoch == socketEpoch, let socket, socketReady else { return false }
        let now = ContinuousClock.now
        let silence = lastInbound.duration(to: now)
        if heartbeat {
            if silence >= timing.heartbeatSilence {
                AppLog.note("socket", "heartbeat: nothing heard for too long")
                invalidate(.socketDead)
                return false
            }
            if lastHeartbeatSent.map({ $0.duration(to: now) >= timing.heartbeatInterval }) ?? true {
                if heartbeatsOutstanding.count >= 8 { heartbeatsOutstanding.removeAll() }
                heartbeatSeq += 1
                let id = "heartbeat-\(heartbeatSeq)"
                heartbeatsOutstanding.insert(id)
                lastHeartbeatSent = now
                socket.send(.string(RPCFrame.request(id: id, method: "gateway.ping"))) { _ in }
            }
        }
        streaming = streaming.filter { $0.value.duration(to: now) < .seconds(180) }
        if !streaming.isEmpty, silence >= timing.streamPingAfter, pingInFlight == nil {
            pingSeq += 1
            let ping = pingSeq
            pingInFlight = ping
            socket.sendPing { [weak self] error in
                Task { await self?.pongArrived(ping, epoch: epoch, ok: error == nil) }
            }
            let wait = timing.streamPongTimeout
            Task { [weak self] in
                do { try await Task.sleep(for: wait) } catch { return }
                await self?.pongMissed(ping, epoch: epoch, sentAt: now)
            }
        }
        return true
    }

    private func pongArrived(_ ping: Int, epoch: Int, ok: Bool) {
        guard epoch == socketEpoch, pingInFlight == ping, ok else { return }
        pingInFlight = nil
        pingMisses = 0
    }

    private func pongMissed(_ ping: Int, epoch: Int, sentAt: ContinuousClock.Instant) {
        guard epoch == socketEpoch, pingInFlight == ping else { return }
        pingInFlight = nil
        if lastInbound > sentAt { pingMisses = 0; return } // A frame arrived meanwhile: that counts as an answer.
        pingMisses += 1
        if pingMisses >= 3 {
            AppLog.note("socket", "stream liveness: 3 pings unanswered")
            invalidate(.socketDead)
        }
    }

    /// Back in the app with the socket still open: prove it with `ping` (5 s). -32601 is an old, healthy backend.
    private func wakeProbe() {
        guard socket != nil, published else { return }
        let epoch = socketEpoch
        Task {
            do {
                _ = try await self.send("ping", [:], timeout: .seconds(5), epoch: epoch)
                self.wakeAnswered(epoch: epoch)
            } catch let error as RPCError where !error.isTimeout && !error.isConnectionLost && !error.isNotConnected {
                self.wakeAnswered(epoch: epoch)
            } catch {
                self.wakeFailed(epoch: epoch)
            }
        }
    }

    private func wakeAnswered(epoch: Int) { if epoch == socketEpoch { wakeFailures = 0 } }

    private func wakeFailed(epoch: Int) {
        guard epoch == socketEpoch, socket != nil else { return }
        wakeFailures += 1
        if !streaming.isEmpty, wakeFailures < 2 {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                await self?.wakeProbe()
            }
            return
        }
        invalidate(.socketDead)
    }

    // MARK: Lifecycle (spec 01 §13.2, §13.7)

    private func becameActive() {
        let wasBackgrounded = backgrounded
        backgrounded = false
        graceTimer?.cancel(); graceTimer = nil
        out.endBackgroundTask()
        // [connect-fast] The app tells us on coming forward and again once active: the second, within 2 s and with no
        // background between, is the same return (it must not re-dial behind a dial that just failed fast).
        let now = ContinuousClock.now
        if !wasBackgrounded, let last = lastActivation, last.duration(to: now) < .seconds(2) { return }
        lastActivation = now
        settle.settling(at: now)                          // [net-ready] the radio may not carry yet
        if wasBackgrounded, let left = leftAt { returned = (now, left.duration(to: now)) }   // [perf-returns]
        leftAt = nil
        dropFrozenDial(now: now)
        if backgroundClosed {
            backgroundClosed = false
            if !networkUp {
                // The network went away while paused: say so instead of the (silent) "paused".
                if !shutDown, signedOut == nil { setState(.offline(reason: GatewayFailure.offline.code)) }
            } else if mayDial {
                // [connect-fast] We closed this socket ourselves (the background grace): the dial back is quiet, as on
                // the desktop. `.connecting`, not "Reconnecting…"; a failure still climbs to `.reconnecting(attempt:)`.
                setState(.connecting)
            }
            reconnectNow(forced: true)
            return
        }
        if socket != nil {
            if wasBackgrounded { wakeProbe() }
        } else {
            reconnectNow(forced: true)
        }
    }

    /// [frozen-dial] Owner's phone, 2026-10-17 (build 312): iOS launched the app in the background and froze it with the
    /// ticket request out; the tap on a reply's alert 4 minutes later found that dial still waiting, and the chat sat on
    /// its cached rows for 17 s (the request failed 7 s after the return, then a fresh dial). A dial older than any of
    /// its steps allows is dropped and dialed again at once. A renewal it started runs on (its rotation must land).
    private func dropFrozenDial(now: ContinuousClock.Instant) {
        guard socket == nil, let task = dialTask, let began = dialBegan, began.duration(to: now) > timing.frozenDial else { return }
        AppLog.note("net", "connect dropped: frozen \(ConnectSteps.ms(began.duration(to: now))) ms, dialing again")
        droppedDialEpoch = dialEpoch ?? socketEpoch
        socketEpoch += 1                 // the dial's `alive` checks fail; its defer dials again
        task.cancel()
    }

    /// [stale-dial] The socket a dial in flight is for will not be used (the background close, a lost or replaced
    /// path, a sign-out): stop it now, quietly, as `dropFrozenDial` does. Left running it held the next dial back
    /// (`connect` waits for it) until its ticket request timed out on the old path, then logged a failure and climbed
    /// the ticket ladder. The caller's `closeSocket` moves the epoch on.
    private func abandonDial() {
        guard socket == nil, let task = dialTask, let epoch = dialEpoch else { return }
        droppedDialEpoch = epoch
        task.cancel()
    }

    private func enteredBackground(granted: Bool) async {
        guard !backgrounded else { return }
        backgrounded = true
        backgroundClosed = false
        leftAt = .now                                     // [perf-returns]
        returned = nil
        backgroundEpoch += 1
        let epoch = backgroundEpoch
        await auth.persistForBackground()
        guard backgrounded, backgroundEpoch == epoch else { return }
        // [talk-background] A conversation keeps the app running: no grace, and no background task to hold.
        if held { return out.endBackgroundTask() }
        startGrace(epoch: epoch, granted: granted)
    }

    /// The grace before the background close: a timer inside the UIKit background task, or at once without one.
    private func startGrace(epoch: Int, granted: Bool) {
        guard granted else { return closeForBackground(epoch: epoch, flush: false) }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timing.backgroundGrace, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            Task { await self?.closeForBackground(epoch: epoch, flush: true) }
        }
        graceTimer?.cancel()
        graceTimer = timer
        timer.resume()
    }

    /// The grace is over (or the system wants the background task back): close with 1001; no socket opens until the
    /// app is back. With `flush` the background task outlives the close by 1 s so the close frame goes out.
    private func closeForBackground(epoch: Int, flush: Bool) {
        guard backgrounded, backgroundEpoch == epoch, !backgroundClosed, !held else {
            if !flush { out.endBackgroundTask() }
            return
        }
        graceTimer?.cancel(); graceTimer = nil
        backgroundClosed = true
        retryTask?.cancel(); retryTask = nil; out.offline.retry(due: nil)
        abandonDial()                                     // [stale-dial]
        closeSocket(code: .goingAway)
        if !shutDown, signedOut == nil {
            // [stale-pool] The return dials on fresh HTTP connections, as the socket does (none left idle to go stale).
            transport.flushConnections()
            setState(.offline(reason: GatewayFailure.paused.code))
        }
        wakeAll()
        AppLog.note("socket", "background grace over: socket closed")
        if flush {
            let end = out.endBackgroundTask
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                // Back and away again within that second: the background task now running is the new trip's (its own
                // grace ends it); ending it here would leave that grace's socket to be frozen with the app.
                if let self, await !self.stillAway(since: epoch) { return }
                end()
            }
        } else {
            out.endBackgroundTask()
        }
    }

    /// Still in the background trip `epoch` began (not back, not away again since).
    private func stillAway(since epoch: Int) -> Bool { backgrounded && backgroundEpoch == epoch }

    /// [talk-background] Held: a grace already running is called off (the app stays alive for the conversation).
    private func holdOpen() {
        held = true
        guard backgrounded, !backgroundClosed else { return }
        graceTimer?.cancel(); graceTimer = nil
        out.endBackgroundTask()
    }

    /// [talk-background] Let go: away, the socket gets the grace it would have had on leaving the app.
    private func releaseHold(granted: Bool) {
        guard held else { return granted ? out.endBackgroundTask() : () }
        held = false
        guard backgrounded, !backgroundClosed else { return granted ? out.endBackgroundTask() : () }
        startGrace(epoch: backgroundEpoch, granted: granted)
    }

    private func pathChanged(_ change: PathChange) {
        switch change {
        case .none:
            return
        case .lost:
            networkUp = false
            retryTask?.cancel(); retryTask = nil; out.offline.retry(due: nil)
            abandonDial()                                 // [stale-dial]
            closeSocket(code: .goingAway)
            if !shutDown, signedOut == nil, !backgroundClosed { setState(.offline(reason: GatewayFailure.offline.code)) }
            wakeAll()
        case .restored:
            networkUp = true
            settle.settling(at: .now)                     // [net-ready]
            if !backgroundClosed, signedOut == nil, !shutDown, socket == nil { setState(everReady ? .reconnecting(attempt: 0) : .connecting) }
            forcedReconnect()
        case .replaced:
            networkUp = true
            settle.settling(at: .now)                     // [net-ready]
            abandonDial()                                 // [stale-dial]
            closeSocket(code: .goingAway)
            if !backgroundClosed, signedOut == nil, !shutDown { setState(everReady ? .reconnecting(attempt: 0) : .connecting) }
            forcedReconnect()
        case .verify:
            networkUp = true
            settle.settling(at: .now)                     // [net-ready]
            guard let socket else { return forcedReconnect() }
            // Some interface was kept (a VPN tunnel): ping and keep the socket only if it answers within 10 s. Each
            // path change gets its own check; only the newest one's answer counts.
            verifySeq += 1
            let token = verifySeq, epoch = socketEpoch
            socket.sendPing { [weak self] error in
                Task { await self?.verifyAnswered(token: token, epoch: epoch, ok: error == nil) }
            }
            verifyTimer?.cancel()
            verifyTimer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                await self?.verifyAnswered(token: token, epoch: epoch, ok: false)
            }
        }
    }

    private func verifyAnswered(token: Int, epoch: Int, ok: Bool) {
        guard token == verifySeq else { return }
        verifySeq += 1 // settled: the other callback of this check is ignored
        verifyTimer?.cancel(); verifyTimer = nil
        guard epoch == socketEpoch else { return }
        if !ok { invalidate(.socketDead) }
    }

    /// Network back: at most one forced reconnect per 15 s (spec 01 §13.2).
    private func forcedReconnect() {
        let now = ContinuousClock.now
        if let last = lastForcedReconnect, last.duration(to: now) < .seconds(15), socket != nil || dialTask != nil { return }
        lastForcedReconnect = now
        reconnectNow(forced: true)
    }

    private func becomeSignedOut(_ failure: GatewayFailure) {
        guard signedOut == nil, !shutDown else { return }
        signedOut = failure
        retryTask?.cancel(); retryTask = nil; out.offline.retry(due: nil)
        abandonDial()                                     // [stale-dial]
        closeSocket(code: .normalClosure)
        out.failure.set(failure)
        setState(.signedOut(reason: failure.code))
        wakeAll()
        out.endBackgroundTask()
    }

    private func shutdown() {
        guard !shutDown else { return }
        shutDown = true
        retryTask?.cancel(); retryTask = nil; out.offline.retry(due: nil)
        dialTask?.cancel()
        graceTimer?.cancel(); graceTimer = nil
        closeSocket(code: .normalClosure)
        wakeAll()
        out.endBackgroundTask()
    }

    private func setState(_ state: ConnectionState) { out.states.set(state) }

    // MARK: Server requests [questions] (spec 1x §2.1, §2.3)

    /// Fire and forget, synchronously: nothing else can be written on this socket before it.
    private func sendCapabilities() {
        guard ServerRequestsSwitch.enabled, let socket else { return }
        let id = nextId
        nextId += 1
        capabilitiesCallId = id
        socket.send(.string(RPCFrame.request(id: id, method: "client.capabilities", params: ["server_requests": true]))) { _ in }
    }

    private func capabilitiesAnswered(_ value: JSONValue) {
        capabilitiesCallId = nil
        declinesNotShown.set(value["declines_not_shown"]?.bool == true)
    }

    /// Writes one answer frame on the current socket and returns once it went out, with that socket's epoch. Throws
    /// `RPCError.notSent` when no socket is up (nothing is queued), `connectionLost` when the send failed.
    @discardableResult func sendAnswer(_ text: String) async throws -> Int {
        guard let socket, socketReady, published else {
            let reason: GatewayFailure = signedOut ?? (shutDown ? .connectionChanged : !networkUp ? .offline
                : backgroundClosed ? .paused : .socketDead)
            throw RPCError.notSent(reason)
        }
        let epoch = socketEpoch
        let failed: Bool = await withCheckedContinuation { continuation in
            socket.send(.string(text)) { error in continuation.resume(returning: error != nil) }
        }
        if failed {
            if epoch == socketEpoch { invalidate(.socketDead) }
            throw RPCError.connectionLost("server request answer")
        }
        return epoch
    }

    // MARK: Test hooks

    #if DEBUG
    var debugCursors: [String: Int] { book.cursors }
    var debugSocketEpoch: Int { socketEpoch }
    var debugWaiting: (calls: Int, barriers: Int) { (waiters.count, replayBarriers.values.reduce(0) { $0 + $1.count }) }
    func debugDropSocket() { invalidate(.socketDead) }
    /// Feeds a frame as if it came from the current socket (tests drive the replay without a seq'd fixture).
    func debugReceive(_ text: String) { handle(RPCFrame.parse(text), size: text.utf8.count, epoch: socketEpoch) }
    #endif
}

/// Events this module makes up (never sent by a gateway).
nonisolated enum LocalEvent {
    /// A server→client request (approval, clarify, …) arrived, live or re-delivered from `open_requests` (spec 1x §2.2,
    /// §2.4). payload `{id, method, params, replayed, epoch}`; `sessionId` from its params.
    static let serverRequest = "hq.server_request"
    /// A reconnect could not replay everything this session missed: re-read its transcript (spec 01 §13.3).
    static let replayTruncated = "session.replay.truncated"
    /// The gateway sent a frame over 64 MiB; the socket closed with 1009 (spec 01 §10.3). Said once per streak;
    /// payload `{message}` is the plain-words notice ("That answer is too large to open on iPhone.").
    static let messageTooLarge = "hq.message_too_large"
}
