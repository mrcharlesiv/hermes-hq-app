// [offline] Background reads one at a time (docs/spec/3x-offline.md §6.7), a port of the web app's `singleFlight`
// (`src/rpc-flight.ts:1-98`). The gateway serves reads from a small worker pool that opening a chat shares, and a read
// the phone gave up on keeps its worker until it finishes. So a flight runs one request at a time: callers meanwhile
// share one trailing run, nothing is sent while the app is not active (one catch-up run when it is back), and
// background callers wait out `gap` since the last start, and `quietFor` after a slow request.

import Foundation

@MainActor protocol FlightTimer: AnyObject {
    func cancel()
}

/// Time for a flight: seconds on a steady clock, and a one-shot timer. Tests inject a hand-driven one.
@MainActor protocol FlightClock: AnyObject {
    func now() -> TimeInterval
    func schedule(after seconds: TimeInterval, _ run: @escaping @MainActor () -> Void) -> any FlightTimer
}

@MainActor final class LiveFlightClock: FlightClock {
    static let shared = LiveFlightClock()

    private final class Timer: FlightTimer {
        var task: Task<Void, Never>?
        func cancel() { task?.cancel() }
    }

    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    func schedule(after seconds: TimeInterval, _ run: @escaping @MainActor () -> Void) -> any FlightTimer {
        let timer = Timer()
        timer.task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0, seconds)))
            guard !Task.isCancelled else { return }
            run()
        }
        return timer
    }
}

@MainActor final class ReadFlight {
    struct State: Equatable {
        var running: Bool
        var trailing: Bool
        var scheduled: Bool
        var owed: Bool
    }

    /// Opens once; whoever waits on it then goes on (a run that covers their call has finished).
    private final class Gate {
        private var opened = false
        private var callbacks: [@MainActor () -> Void] = []
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func whenOpen(_ run: @escaping @MainActor () -> Void) {
            if opened { run() } else { callbacks.append(run) }
        }

        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            guard !opened else { return }
            opened = true
            let runs = callbacks, held = waiters
            callbacks = []; waiters = []
            for run in runs { run() }
            for waiter in held { waiter.resume() }
        }
    }

    private let gap: @MainActor () -> Duration
    private let slowAfter: Duration?
    private let quietFor: Duration
    private let isActive: @MainActor () -> Bool
    private let clock: any FlightClock
    private let work: @MainActor () async -> Void
    /// What this flight is for, in the diagnostic log only (never shown, never affects behavior). "" for a caller
    /// that didn't name one; the line still says a flight made a decision, just not which.
    private let label: String
    private var tag: String { label.isEmpty ? "read flight" : "read flight (\(label))" }

    private var running: Gate?
    private var trailing: Gate?
    private var trailingForeground = false
    private var lastStart = -Double.infinity
    private var quietUntil = -Double.infinity
    private var timer: (any FlightTimer)?
    private var timed: Gate?
    private var owed = false
    /// Runs started, for tests and the performance log.
    private(set) var runs = 0

    /// - gap: least time between the starts of two background runs.
    /// - slowAfter / quietFor: a run that took `slowAfter` or longer timed out on the gateway's side too; background
    ///   runs then wait `quietFor`.
    /// - isActive: false while the app is not in front: nothing is sent, one run is owed.
    init(gap: @escaping @MainActor () -> Duration = { .zero }, slowAfter: Duration? = nil, quietFor: Duration = .zero,
         isActive: @escaping @MainActor () -> Bool, clock: (any FlightClock)? = nil, label: String = "",
         _ work: @escaping @MainActor () async -> Void) {
        self.gap = gap
        self.slowAfter = slowAfter
        self.quietFor = quietFor
        self.isActive = isActive
        self.clock = clock ?? LiveFlightClock.shared
        self.label = label
        self.work = work
    }

    var state: State { State(running: running != nil, trailing: trailing != nil, scheduled: timer != nil, owed: owed) }

    /// Run now (or after the run in flight); `background` also waits out the gap. Returns when a run that covers this
    /// call has finished (at once while the app is not active: the run is owed).
    func request(background: Bool = false) async {
        await gate(background: background)?.wait()
    }

    /// The same without waiting for the run.
    func ask(background: Bool = false) { gate(background: background) }

    /// Back in front: the one owed catch-up run.
    func becameActive() {
        guard owed else { return }
        owed = false
        gate(background: true)
    }

    /// Forget what is scheduled or owed (the owner stopped). A run in flight ends by itself.
    func cancel() {
        _ = takeTimed()?.open()
        owed = false
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    @discardableResult
    private func gate(background: Bool) -> Gate? {
        guard isActive() else {
            if !owed { AppLog.trace("net", "\(tag): owed (app not active)") }
            owed = true
            return nil
        }
        if let running {
            trailingForeground = trailingForeground || !background
            if let trailing { return trailing }     // another caller already joined; same decision, not logged again
            AppLog.trace("net", "\(tag): merged into a trailing run")
            let gate = Gate()
            trailing = gate
            running.whenOpen { [weak self] in
                guard let self else { gate.open(); return }
                let foreground = self.trailingForeground
                self.trailing = nil
                self.trailingForeground = false
                AppLog.trace("net", "\(self.tag): trailing run starting")
                if let next = self.gate(background: !foreground) { next.whenOpen { gate.open() } } else { gate.open() }
            }
            return gate
        }
        if background {
            let now = clock.now()
            let wait = max(Self.seconds(gap()) - (now - lastStart), quietUntil - now)
            if wait > 0 {
                if let timed { return timed }     // already waiting; same decision, not logged again
                AppLog.trace("net", "\(tag): deferred \(Int(wait * 1000))ms (gap or quiet-after-slow)")
                let gate = Gate()
                timed = gate
                timer = clock.schedule(after: wait) { [weak self] in
                    guard let self else { gate.open(); return }
                    let settle = self.takeTimed()
                    if let next = self.gate(background: false) { next.whenOpen { settle?.open() } } else { settle?.open() }
                }
                return gate
            }
        }
        return start()
    }

    private func takeTimed() -> Gate? {
        timer?.cancel()
        timer = nil
        defer { timed = nil }
        return timed
    }

    private func start() -> Gate {
        // A scheduled run is overtaken by this one: whoever waited on it is covered by this run.
        let settle = takeTimed()
        let began = clock.now()
        lastStart = began
        owed = false          // any run covers the one owed from the time away
        runs += 1
        let gate = Gate()
        running = gate
        let work = self.work
        Task { @MainActor [weak self] in
            await work()
            if let self {
                if let slowAfter = self.slowAfter, self.clock.now() - began >= Self.seconds(slowAfter) {
                    self.quietUntil = self.clock.now() + Self.seconds(self.quietFor)
                    AppLog.trace("net", "\(self.tag): slow run; background reads quiet for \(Int(Self.seconds(self.quietFor) * 1000))ms")
                }
                if self.running === gate { self.running = nil }
            }
            gate.open()
            settle?.open()
        }
        return gate
    }
}
