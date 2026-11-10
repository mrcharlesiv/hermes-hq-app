// [offline] The header's words for the gateway link, in one place (docs/spec/3x-offline.md §5.1, §5.2), so the Bots
// subtitle, the page tabs' subtitle, the gateway switcher and the reconnect notice can never disagree about "Offline".
// The link reads "Offline" while the connection is offline, and once it has been reconnecting for 120 s (the web app's
// retry cycle turning offline); "Signed Out" once the gateway ended this phone's session and the user put signing in
// off.

import Foundation

nonisolated enum HeaderLink {
    /// Reconnecting this long reads "Offline".
    static let offlineAfter: TimeInterval = 120
    static let reconnecting = "Reconnecting…"
    static let offline = "Offline"
    static let signedOut = "Signed Out"

    static func isOffline(_ state: ConnectionState, reconnectingFor: TimeInterval?) -> Bool {
        switch state {
        case .offline: true
        case .reconnecting: (reconnectingFor ?? 0) >= offlineAfter
        default: false
        }
    }

    /// The line under a title, nil when the link is fine (or still making its first connection).
    static func words(_ state: ConnectionState, reconnectingFor: TimeInterval?) -> String? {
        switch state {
        case .signedOut: signedOut
        case .offline: offline
        case .reconnecting: isOffline(state, reconnectingFor: reconnectingFor) ? offline : reconnecting
        case .connecting, .ready: nil
        }
    }
}

/// How long the active gateway's link has been reconnecting (one per app: there is one active gateway).
@MainActor final class OutageClock {
    static let shared = OutageClock()

    private(set) var reconnectingSince: Date?
    private let now: () -> Date

    init(now: @escaping () -> Date = { Date() }) { self.now = now }

    /// The connection's new state. Returns true when a run of reconnecting just began (the caller arms the 120 s turn).
    @discardableResult func note(_ state: ConnectionState) -> Bool {
        if case .reconnecting = state {
            guard reconnectingSince == nil else { return false }
            reconnectingSince = now()
            return true
        }
        reconnectingSince = nil
        return false
    }

    func reset() { reconnectingSince = nil }

    private var reconnectingFor: TimeInterval? { reconnectingSince.map { now().timeIntervalSince($0) } }

    func isOffline(_ state: ConnectionState) -> Bool { HeaderLink.isOffline(state, reconnectingFor: reconnectingFor) }
    func words(_ state: ConnectionState) -> String? { HeaderLink.words(state, reconnectingFor: reconnectingFor) }
}

/// [connect-fast] The chat's "Reconnecting…" (its composer and its status line) waits as the headers' subtitle does
/// (spec 02 §6.5, 2 s): a reconnect that finishes inside the wait shows nothing at all. The desktop does the same
/// (apps/desktop gateway-liveness-policy: a quiet reconnect is not announced).
nonisolated struct ReconnectWordsGate: Sendable {
    static let delay: TimeInterval = 2
    private(set) var since: Date?

    /// Whether to show the reconnecting words now, and when to ask again if they are being held.
    mutating func note(reconnecting: Bool, now: Date = Date()) -> (show: Bool, recheckIn: TimeInterval?) {
        guard reconnecting else { since = nil; return (false, nil) }
        let started = since ?? now
        since = started
        let left = Self.delay - now.timeIntervalSince(started)
        return left <= 0 ? (true, nil) : (false, left)
    }
}
