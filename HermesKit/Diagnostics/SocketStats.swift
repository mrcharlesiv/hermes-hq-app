// [diagnostics] The connection counts Settings › About › Diagnostics › Gateway shows (the web shell's
// `DispatchSocketStats`, `bridge/socket.ts`): how many sockets are open, how many ever were, how often the gateway's
// own socket had to be opened again. Counted where sockets open and close; read from any thread.

import Foundation
import Synchronization

nonisolated final class SocketStats: Sendable {
    static let shared = SocketStats()

    struct Counts: Sendable, Equatable {
        var live = 0, gateway = 0, peak = 0, opened = 0, reconnects = 0, attempts = 0, tooBig = 0
    }

    private struct State {
        var counts = Counts()
        var gatewayOpenedOnce = false
    }

    private let state = Mutex(State())

    var counts: Counts { state.withLock { $0.counts } }

    /// A connection was asked for (a ticket requested or a plugin socket dialled).
    func attempt() { state.withLock { $0.counts.attempts += 1 } }

    /// A socket's handshake completed. `gateway` is the main `/api/ws` socket.
    func opened(gateway: Bool) {
        state.withLock { s in
            s.counts.live += 1
            s.counts.opened += 1
            s.counts.peak = max(s.counts.peak, s.counts.live)
            if gateway {
                s.counts.gateway += 1
                if s.gatewayOpenedOnce { s.counts.reconnects += 1 }
                s.gatewayOpenedOnce = true
            }
        }
    }

    func closed(gateway: Bool) {
        state.withLock { s in
            s.counts.live = max(0, s.counts.live - 1)
            if gateway { s.counts.gateway = max(0, s.counts.gateway - 1) }
        }
    }

    /// A frame over the receive limit was refused.
    func tooBig() { state.withLock { $0.counts.tooBig += 1 } }

    /// A side socket (a plugin's stream, speech, a bot's screen) counts as open from the moment it is handed out
    /// until its task completes, however it ends. URLSession reports no separate moment for the upgrade.
    func track(_ task: URLSessionWebSocketTask) {
        attempt()
        opened(gateway: false)
        let id = ObjectIdentifier(task)
        let watch = task.observe(\.state, options: [.new]) { [weak self] task, _ in
            guard task.state == .completed, let self else { return }
            if self.watches.withLock({ $0.removeValue(forKey: id) }) != nil { self.closed(gateway: false) }
        }
        watches.withLock { $0[id] = Watch(observation: watch) }
        // Already over before the observer was in place.
        if task.state == .completed, watches.withLock({ $0.removeValue(forKey: id) }) != nil { closed(gateway: false) }
    }

    private struct Watch: @unchecked Sendable { let observation: NSKeyValueObservation }
    private let watches = Mutex<[ObjectIdentifier: Watch]>([:])

    func resetForTests() { state.withLock { $0 = State() } }
}
