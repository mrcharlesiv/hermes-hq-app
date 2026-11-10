// Small pieces of the connection engine, kept pure so they can be tested on their own: reconnect back-off, the
// one-at-a-time ticket lane, the ticket timeout ladder, and the multicast hubs behind events() / connectionStates().

import Foundation
import Synchronization

/// Full-jitter exponential back-off (spec 01 §13.1): `random() * min(cap, base * 2^attempt)`.
nonisolated struct ReconnectBackoff: Sendable {
    var base: Double
    var cap: Double

    /// After the first successful boot: 300 ms base, 15 s cap.
    static let afterReady = ReconnectBackoff(base: 0.3, cap: 15)
    /// Before the first boot: 2 s base, 15 s cap (spec 01 §13.2).
    static let beforeReady = ReconnectBackoff(base: 2, cap: 15)

    /// The upper bound of the delay before attempt number `attempt` (0-based).
    func ceiling(attempt: Int) -> Double { min(cap, base * pow(2, Double(min(max(attempt, 0), 30)))) }

    /// `random` in [0, 1).
    func delay(attempt: Int, random: Double = Double.random(in: 0..<1)) -> Double {
        min(max(random, 0), 1) * ceiling(attempt: attempt)
    }

    /// The ladder restarts only after a socket stayed open at least this long (an accept-then-die keeps backing off).
    static let stableOpenSeconds: Double = 5
    /// After a dial fails before opening, the next dial waits until this long has passed (spec 01 §13.4).
    static let minRedialSeconds: Double = 1
}

/// [net-ready] The one quick redial after a dial that ran before the phone's network was usable (spec 01 §13.4,
/// build 295). Opened from a notification, the first ticket request can fail "unreachable" within 45–90 ms (the path
/// already reads satisfied, the radio is not carrying yet), and the 1 s floor then cost ~0.9 s before the dial that
/// works. A dial that began within `window` of the app coming forward, the connection starting or the network path
/// moving, and failed `.unreachable` within `failedWithin`, is dialed again after `floor` instead: once per such
/// moment. Anything else (a second failure, a timeout, a 5xx, a 429, a refusal, a slow failure) keeps the 1 s floor
/// and the ladder. Pure, so it can be tested on its own; the connection keeps one and tells it what happened.
nonisolated struct NetSettle: Sendable {
    /// A dial counts as "while the network settles" when it began this soon after the moment.
    static let window: Duration = .seconds(3)
    /// …and failed this fast (a dead gateway's refusal is fast too: the once-per-moment rule keeps that to one extra ask).
    static let failedWithin: Duration = .seconds(1)
    /// The quick redial's floor, in place of `ReconnectBackoff.minRedialSeconds`.
    static let floor: Duration = .milliseconds(200)

    /// The last moment the network may have been settling (activation, start, path change), and whether its one quick
    /// redial is spent.
    private(set) var since: ContinuousClock.Instant?
    private(set) var spent = false

    /// The app came forward, the connection started, or the path changed: one quick redial is available again.
    mutating func settling(at now: ContinuousClock.Instant) {
        since = now
        spent = false
    }

    /// A dial that began at `began` failed with `failure` at `now`: the floor before the next dial when it gets the
    /// quick redial (spending it), nil for the normal floor and ladder.
    mutating func quickRedial(after failure: GatewayFailure, began: ContinuousClock.Instant,
                              now: ContinuousClock.Instant) -> Duration? {
        guard failure == .unreachable, !spent, let since, since <= began, since.duration(to: began) < Self.window,
              began.duration(to: now) < Self.failedWithin else { return nil }
        spent = true
        return Self.floor
    }
}

/// The ws-ticket timeout after `count` timeouts in a row: 8 s, 15 s, then 20 s (spec 01 §9.2).
nonisolated func ticketTimeout(afterTimeouts count: Int) -> Duration {
    [Duration.seconds(8), .seconds(15), .seconds(20)][min(max(count, 0), 2)]
}

/// [connect-fast] Tailscale reads as off for a moment when the app returns (the tunnel's interface comes back a beat
/// after the app does): ask `up` again every `every` for at most `within` before calling it off. True as soon as it
/// is up; false when it stayed off (or the task was cancelled).
nonisolated func tunnelComesUp(within: Duration = .seconds(3), every: Duration = .milliseconds(300),
                               _ up: () -> Bool) async -> Bool {
    if up() { return true }
    let end = ContinuousClock.now + within
    while ContinuousClock.now < end {
        do { try await Task.sleep(for: min(every, ContinuousClock.now.duration(to: end))) } catch { return false }
        if up() { return true }
    }
    return false
}

/// A FIFO lane: one holder at a time, later callers wait their turn in order (the `/api/ws` ticket rule, §9.2).
nonisolated final class AsyncLane: Sendable {
    private struct State { var busy = false; var waiters: [CheckedContinuation<Void, Never>] = [] }
    private let state = Mutex(State())

    init() {}

    func enter() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = state.withLock { state -> Bool in
                if !state.busy { state.busy = true; return true }
                state.waiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func leave() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            if state.waiters.isEmpty { state.busy = false; return nil }
            return state.waiters.removeFirst()
        }
        next?.resume()
    }

    var isBusy: Bool { state.withLock { $0.busy } }
}

/// Multicast to any number of AsyncStream subscribers; each gets every element from when it subscribed.
nonisolated final class Broadcast<Element: Sendable>: Sendable {
    private struct Subscriber {
        var continuation: AsyncStream<Element>.Continuation
        var wants: (@Sendable (Element) -> Bool)?
    }
    private struct State {
        var next = 0
        var subscribers: [Int: Subscriber] = [:]
        var finished = false
    }
    private let state = Mutex(State())

    init() {}

    /// A new subscriber stream. `first` (if any) is delivered before anything yielded later. `wants` (if any) picks
    /// what this subscriber gets, checked under the lock before the element is queued: keep it a cheap compare.
    func subscribe(first: Element? = nil, where wants: (@Sendable (Element) -> Bool)? = nil) -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: .unbounded)
        let id: Int? = state.withLock { state in
            if let first { continuation.yield(first) }
            guard !state.finished else { return nil }
            let id = state.next
            state.next += 1
            state.subscribers[id] = Subscriber(continuation: continuation, wants: wants)
            return id
        }
        guard let id else { continuation.finish(); return stream }
        continuation.onTermination = { [weak self] _ in self?.drop(id) }
        return stream
    }

    func yield(_ element: Element) {
        state.withLock { state in
            for subscriber in state.subscribers.values where subscriber.wants?(element) ?? true {
                subscriber.continuation.yield(element)
            }
        }
    }

    func finish() {
        let all = state.withLock { state -> [AsyncStream<Element>.Continuation] in
            state.finished = true
            defer { state.subscribers.removeAll() }
            return state.subscribers.values.map(\.continuation)
        }
        all.forEach { $0.finish() }
    }

    var subscriberCount: Int { state.withLock { $0.subscribers.count } }

    private func drop(_ id: Int) { _ = state.withLock { $0.subscribers.removeValue(forKey: id) } }
}

/// The current connection state plus its subscribers (each new subscriber gets the current state first).
nonisolated final class StateHub: Sendable {
    private let hub = Broadcast<ConnectionState>()
    private let current: Mutex<ConnectionState>

    init(_ initial: ConnectionState) { current = Mutex(initial) }

    var value: ConnectionState { current.withLock { $0 } }

    func subscribe() -> AsyncStream<ConnectionState> {
        // Read and subscribe under one lock so no change can slip between them.
        current.withLock { state in hub.subscribe(first: state) }
    }

    /// Publishes a change (no-op when unchanged). Returns whether it changed.
    @discardableResult func set(_ new: ConnectionState) -> Bool {
        current.withLock { state -> Bool in
            guard state != new else { return false }
            state = new
            hub.yield(new)
            return true
        }
    }

    func finish() { hub.finish() }
}

/// A value a few threads read and one writes.
nonisolated final class Locked<Value: Sendable>: Sendable {
    private let state: Mutex<Value>
    init(_ value: Value) { state = Mutex(value) }
    var value: Value {
        get { state.withLock { $0 } }
    }
    func set(_ value: Value) { state.withLock { $0 = value } }
    @discardableResult func mutate<R: Sendable>(_ change: (inout Value) -> R) -> R { state.withLock { change(&$0) } }
}

/// What a network path change means for open sockets (spec 01 §13.7, HermesTransportPolicy.pathChange).
nonisolated enum PathChange: Equatable, Sendable {
    case none, lost, restored, verify, replaced

    /// Reachability plus the SET of interface types in use (several VPN utuns all report `other`).
    static func signature(satisfied: Bool, interfaces: [String]) -> String {
        (satisfied ? "up:" : "down:") + Set(interfaces).sorted().joined(separator: ",")
    }

    /// lost → close everything; restored → redial; replaced (no interface in common, e.g. Wi-Fi → cellular without a
    /// VPN) → close and redial now; verify (some interface kept, e.g. a VPN tunnel) → ping and keep what answers.
    static func between(_ old: String?, _ new: String) -> PathChange {
        guard let old, old != new else { return .none }
        if new.hasPrefix("down:") { return old.hasPrefix("down:") ? .none : .lost }
        if old.hasPrefix("down:") { return .restored }
        let before = interfaces(old), after = interfaces(new)
        return !before.isEmpty && !after.isEmpty && before.isDisjoint(with: after) ? .replaced : .verify
    }

    private static func interfaces(_ signature: String) -> Set<Substring> {
        Set((signature.split(separator: ":", maxSplits: 1).dropFirst().first ?? "").split(separator: ","))
    }

    /// A changed path must stay put this long before it is acted on.
    static let settleSeconds = 2.0
}

/// Lossless replay bookkeeping (spec 01 §13.3): the highest `seq` delivered per session (at most 8 cursors, least
/// recently active dropped), frames parked while a session's replay runs, and the duplicate filter. Pure value type;
/// the connection drives it.
nonisolated struct ReplayBook: Sendable {
    private(set) var epoch: String?
    private(set) var cursors: [String: Int] = [:]
    private var order: [String] = []                 // least recently active first
    private var parked: [String: [GatewayEvent]] = [:]
    /// The bytes each parked session holds, so releasing one session lowers `parkedBytes` by its own share (the
    /// budget counts what is still held, not everything parked since the reconnect).
    private var parkedSizes: [String: Int] = [:]
    private(set) var parkedCount = 0
    private(set) var parkedBytes = 0

    static let cursorBudget = 8
    static let parkedFrameBudget = 2048
    static let parkedByteBudget = 4 << 20

    init() {}

    var isParking: Bool { !parked.isEmpty }
    func isParked(_ session: String) -> Bool { parked[session] != nil }

    /// A new socket said `gateway.ready`. A changed epoch means the gateway restarted (nothing can be replayed); a
    /// missing one gives no continuity guarantee, so cursors are dropped too. Returns the sessions to replay, most
    /// recently active first, and starts parking their live frames.
    mutating func ready(epoch newEpoch: String?) -> [String] {
        parked.removeAll(); parkedSizes.removeAll(); parkedCount = 0; parkedBytes = 0
        if newEpoch == nil || (epoch != nil && epoch != newEpoch) { cursors.removeAll(); order.removeAll() }
        epoch = newEpoch
        let sessions = Array(order.reversed())
        for session in sessions { parked[session] = [] }
        return sessions
    }

    /// A live frame skipped past its session's cursor (`seq` > cursor + 1) while nothing is held for it: frames went
    /// to another socket meanwhile (e.g. between a reconnect's replay and the chat re-binding the session).
    func hasGap(_ event: GatewayEvent) -> Bool {
        guard let seq = event.seq, !event.sessionId.isEmpty, parked[event.sessionId] == nil,
              let last = cursors[event.sessionId] else { return false }
        return seq > last + 1
    }

    /// Starts holding one session's live frames (a gap repair replays it like a reconnect does).
    mutating func park(_ session: String) {
        if parked[session] == nil { parked[session] = [] }
    }

    /// A live frame. Returns what to deliver now (nothing while its session is parked or when it is a duplicate).
    /// `overBudget` means the hold grew too large: drop the socket and replay again from the untouched cursors.
    mutating func live(_ event: GatewayEvent, size: Int) -> (deliver: GatewayEvent?, overBudget: Bool) {
        guard event.seq != nil, !event.sessionId.isEmpty else { return (event, false) }
        if parked[event.sessionId] != nil {
            parked[event.sessionId]?.append(event)
            parkedCount += 1
            parkedBytes += size
            parkedSizes[event.sessionId, default: 0] += size
            return (nil, parkedCount > Self.parkedFrameBudget || parkedBytes > Self.parkedByteBudget)
        }
        return (accept(event), false)
    }

    /// A replayed (or released) event: delivered once, only past the session's cursor.
    mutating func accept(_ event: GatewayEvent) -> GatewayEvent? {
        guard let seq = event.seq, !event.sessionId.isEmpty else { return event }
        if let last = cursors[event.sessionId], seq <= last { return nil }
        cursors[event.sessionId] = seq
        order.removeAll { $0 == event.sessionId }
        order.append(event.sessionId)
        if order.count > Self.cursorBudget { cursors[order.removeFirst()] = nil }
        return event
    }

    /// The replay for `session` is over: its parked frames, deduplicated, in arrival order.
    /// [presence] They are part of the catch-up, so they carry `replayed` (spec 3x-presence §3.4), as on the web.
    mutating func release(_ session: String) -> [GatewayEvent] {
        guard let frames = parked.removeValue(forKey: session) else { return [] }
        parkedCount -= frames.count
        parkedBytes -= parkedSizes.removeValue(forKey: session) ?? 0
        if parked.isEmpty { parkedSizes.removeAll(); parkedCount = 0; parkedBytes = 0 }
        return frames.compactMap { accept($0) }.map { var event = $0; event.replayed = true; return event }
    }

    /// [presence] An event from `session.events.since`: delivered once, only past the cursor, marked `replayed`.
    mutating func acceptReplayed(_ event: GatewayEvent) -> GatewayEvent? {
        var marked = event
        marked.replayed = true
        return accept(marked)
    }

    /// Every session still parked, released.
    mutating func releaseAll() -> [GatewayEvent] {
        parked.keys.sorted().flatMap { release($0) }
    }

    /// `session.events.since` answered with another epoch: the gateway restarted under us.
    mutating func epochChanged(to newEpoch: String) {
        epoch = newEpoch
        cursors.removeAll(); order.removeAll()
    }

    /// The gap could not be replayed (`truncated: true`): forget this session's cursor.
    mutating func truncated(_ session: String) {
        cursors[session] = nil
        order.removeAll { $0 == session }
    }

    /// Every cursor dropped (a frame too large to ever receive would come back with the replay). Returns the sessions
    /// that had one, so their chats can re-read their transcripts.
    mutating func forgetCursors() -> [String] {
        let sessions = Array(order.reversed())
        cursors.removeAll(); order.removeAll()
        return sessions
    }

    /// The socket closed: parked frames go (their seqs stay above the cursors, so the next replay brings them back).
    mutating func socketClosed() {
        parked.removeAll(); parkedSizes.removeAll(); parkedCount = 0; parkedBytes = 0
    }
}

/// Settles one continuation exactly once, whoever gets there first (a worker, a deadline, the caller's cancel), and
/// cancels the tasks it tracks when it does.
nonisolated final class SettleOnce<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, Error>?
        var result: Result<T, Error>?
        var tasks: [Task<Void, Never>] = []
    }
    private let state = Mutex(State())

    init() {}

    /// The continuation to settle (settled at once if a result came first).
    func arm(_ continuation: CheckedContinuation<T, Error>) {
        let early = state.withLock { state -> Result<T, Error>? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let early { continuation.resume(with: early) }
    }

    /// Cancelled when the result is in (at once if it already is).
    func track(_ task: Task<Void, Never>) {
        let settled = state.withLock { state -> Bool in
            if state.result != nil { return true }
            state.tasks.append(task)
            return false
        }
        if settled { task.cancel() }
    }

    /// The first result wins; true for that one.
    @discardableResult func settle(_ result: Result<T, Error>) -> Bool {
        let taken = state.withLock { state -> (CheckedContinuation<T, Error>?, [Task<Void, Never>])? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.continuation = nil; state.tasks = [] }
            return (state.continuation, state.tasks)
        }
        guard let taken else { return false }
        taken.0?.resume(with: result)
        taken.1.forEach { $0.cancel() }
        return true
    }
}

/// Runs `work` in its own task and waits for it until `deadline` at most. Past the deadline `late` is thrown at once:
/// the work is cancelled but never awaited (so a step that ignores cancellation, such as a shared Nous rotation that
/// must finish and persist, cannot hold the caller past its budget). The caller's own cancellation also returns at once.
nonisolated func untilDeadline<T: Sendable>(_ deadline: ContinuousClock.Instant, late: @escaping @Sendable () -> any Error,
                                            _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    let gate = SettleOnce<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            gate.arm(continuation)
            gate.track(Task {
                do { gate.settle(.success(try await work())) } catch { gate.settle(.failure(error)) }
            })
            gate.track(Task {
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                gate.settle(.failure(late()))
            })
        }
    } onCancel: {
        gate.settle(.failure(CancellationError()))
    }
}

/// A 429 that named how long to wait (spec 01 §15): honoured where the client retries on its own.
nonisolated struct RetryLater: Error, Sendable {
    let failure: GatewayFailure
    /// Seconds to wait before trying again.
    let after: TimeInterval

    /// `Retry-After` as delta-seconds or an HTTP-date; nil when absent, unreadable or not in the future.
    static func parse(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let text = header?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let seconds = Double(text) { return seconds > 0 ? seconds : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: text) else { return nil }
        let wait = date.timeIntervalSince(now)
        return wait > 0 ? wait : nil
    }

    /// The longest a `Retry-After` may hold a reconnect (a misconfigured edge must not park the app for hours).
    /// **DECISION** (offline stream, stress round 1): 120 s, the same as before the first ready (`RetryLadder.ceiling`).
    /// At 300 s the app sat on "Reconnecting…" for minutes after a gateway that had sent `Retry-After: 300` was back.
    static let ceiling: TimeInterval = 120
}
