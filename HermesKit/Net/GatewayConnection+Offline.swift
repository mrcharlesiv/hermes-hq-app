// [offline] What the connection reports for the offline stream (docs/spec/3x-offline.md §3.6, §6.1): the outage gate's
// socket signals, and when the next dial before the first ready is due (the offline screen's countdown draws that
// date; it owns no clock of its own).

import Foundation

nonisolated struct OfflineOutlets: Sendable {
    var gate: OutageGate?
    var retryDue: Locked<Date?>?
    var retryHub: Broadcast<Date?>?

    init(gate: OutageGate? = nil, retryDue: Locked<Date?>? = nil, retryHub: Broadcast<Date?>? = nil) {
        self.gate = gate
        self.retryDue = retryDue
        self.retryHub = retryHub
    }

    /// A retry was scheduled for `due`, or (nil) a dial runs, the socket is ready, or nothing will dial.
    func retry(due: Date?) {
        guard let retryDue else { return }
        let changed = retryDue.mutate { current -> Bool in
            guard current != due else { return false }
            current = due
            return true
        }
        if changed { retryHub?.yield(due) }
    }
}

extension LiveGatewayClient: GatewayOutageReporting {
    /// §6.1: the outage gate holds reads (the gateway was found unreachable and no read has answered since).
    var gatewayDown: Bool { outage.state.down }

    /// §3.6: when the next dial is due while the gateway has not been reached since launch; nil while a dial runs, once
    /// ready, or when nothing will dial (paused, no network, signed out).
    var nextRetry: Date? { retryDue.value }

    /// The current `nextRetry`, then every change.
    func retryChanges() -> AsyncStream<Date?> { retryHub.subscribe(first: retryDue.value) }

    /// §6.1, §6.8: back in the app after the background: the next read may probe at once.
    func wakeReads() { outage.wake() }
}
