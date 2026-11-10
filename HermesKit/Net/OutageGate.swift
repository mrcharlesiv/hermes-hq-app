// [offline] The outage gate (docs/spec/3x-offline.md §6.1), a port of the web app's `src/connection-reachability.ts`.
// Pollers kept asking a gateway that was down: each has its own timer, so they are bounded at the one place every
// gateway read passes (`LiveGatewayClient.send`). Once a read finds the gateway unreachable while the socket is down,
// or the socket's second dial in a row fails before opening, reads fail at once, as the gateway would have answered
// them, except one probe read per window (2 s doubling to 30 s). With the socket open, three reads in a row that ran
// out their time start a stall, held the same way. Any answered read, or the socket opening, ends it. Writes are never
// held. Nothing is queued, so no caller waits on the outage.

import Foundation
import Synchronization

nonisolated final class OutageGate: Sendable {
    static let probeBase: TimeInterval = 2
    static let probeCap: TimeInterval = 30
    /// Reads in a row that ran out their time, with the socket open, before reads are held as for an outage.
    static let stallTimeouts = 3
    /// Socket dials in a row that failed before they opened, before the gateway counts as down.
    static let failedDials = 2
    /// An HTTP answer that means nothing behind the address answered (proxy or tunnel up, gateway down).
    static let downStatuses: Set<Int> = [502, 503, 504, 520, 521, 522, 523, 524, 525, 526, 530]

    struct State: Equatable, Sendable {
        var down: Bool
        var stalled: Bool
        var probeIn: TimeInterval
        var socketOpen: Bool
    }

    private struct Box {
        var socketOpen = false
        var down = false
        var stalled = false
        var probeAt: TimeInterval = 0
        var delay = OutageGate.probeBase
        var timeouts = 0
        var failedDials = 0

        mutating func recover() {
            down = false; stalled = false; timeouts = 0; delay = OutageGate.probeBase; probeAt = 0
        }
        mutating func hold(_ now: TimeInterval) {
            probeAt = now + delay
            delay = min(OutageGate.probeCap, delay * 2)
        }
        mutating func unreachable(_ now: TimeInterval) {
            // The socket is the stronger signal: while it is open the gateway is up, whatever one read met.
            if socketOpen || down { return }
            down = true
            hold(now)
        }
    }

    private let box = Mutex(Box())
    private let now: @Sendable () -> TimeInterval

    /// `now`: seconds on any steady clock (tests inject one).
    init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    /// May a read go to the network now? False while an outage or a stall holds and no probe is due.
    func admit() -> Bool {
        let now = now()
        return box.withLock { box in
            if !box.down && !box.stalled { return true }
            if now < box.probeAt { return false }
            // This read is the probe; the next one waits out a longer window.
            box.hold(now)
            return true
        }
    }

    /// A read reached the gateway (any HTTP answer but a down status).
    func reached() { box.withLock { $0.recover() } }

    /// A read found the gateway unreachable.
    func unreachable() {
        let now = now()
        box.withLock { $0.unreachable(now) }
    }

    /// A read ran out its deadline: an outage while the socket is down as well, a stall after `stallTimeouts` in a row
    /// with it open (a reached but busy gateway is never an outage).
    func timeout() {
        let now = now()
        box.withLock { box in
            if !box.socketOpen { return box.unreachable(now) }
            if box.stalled { return }
            box.timeouts += 1
            if box.timeouts < OutageGate.stallTimeouts { return }
            box.stalled = true
            box.hold(now)
        }
    }

    /// The gateway socket opened or closed.
    func socket(open: Bool) {
        box.withLock { box in
            box.socketOpen = open
            if open {
                box.failedDials = 0
                box.recover()
            } else if box.stalled {
                // A closed socket is no longer a stalled one: a read's timeout now says whether the gateway is down.
                box.stalled = false; box.timeouts = 0; box.delay = OutageGate.probeBase; box.probeAt = 0
            }
        }
    }

    /// A gateway socket dial failed before it opened (count each dial once).
    func dialFailed() {
        let now = now()
        box.withLock { box in
            box.failedDials += 1
            if box.failedDials >= OutageGate.failedDials { box.unreachable(now) }
        }
    }

    /// Back in the app: the next read probes at once.
    func wake() { box.withLock { if $0.down || $0.stalled { $0.probeAt = 0 } } }

    var state: State {
        let now = now()
        return box.withLock { box in
            State(down: box.down, stalled: box.stalled,
                  probeIn: box.down || box.stalled ? max(0, box.probeAt - now) : 0, socketOpen: box.socketOpen)
        }
    }

    /// The failure for a read the gate holds back: the stall's or the outage's.
    var heldFailure: GatewayFailure { box.withLock { $0.stalled } ? .heldTimeout : .heldUnreachable }

    /// How a finished read reports: an HTTP answer (a down status or not), or the failure it met.
    func note(status: Int) {
        if Self.downStatuses.contains(status) { unreachable() } else { reached() }
    }

    func note(failure: GatewayFailure) {
        switch failure.code {
        case "unreachable": unreachable()
        case "timeout": timeout()
        default: break
        }
    }
}
