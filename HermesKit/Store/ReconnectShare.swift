// [offline] The reconnect refresh share (docs/spec/3x-offline.md §6.4), a port of the web app's
// `src/reconnect-refresh.ts`: a socket that opens twice within a few seconds (a blip, a gateway restart, a return to the
// app) refreshes the Sessions list once. A run that failed is not shared, so the next open reads again.

import Foundation

nonisolated struct ReconnectShare: Sendable {
    static let window: TimeInterval = 3

    private var startedAt: TimeInterval?
    private var didFail = false
    private let now: @Sendable () -> TimeInterval

    init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.now = now }

    /// A socket opened: true when this open starts a refresh, false when it shares the last one.
    mutating func begin() -> Bool {
        let now = now()
        if let startedAt, !didFail, now - startedAt < Self.window { return false }
        startedAt = now
        didFail = false
        return true
    }

    /// The refresh this share started failed: the next open reads again.
    mutating func failed() { didFail = true }
}
