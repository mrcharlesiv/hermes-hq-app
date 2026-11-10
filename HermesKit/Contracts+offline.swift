// [offline] Additions to the contracts for the offline stream (docs/spec/3x-offline.md), kept out of Contracts.swift.

import Foundation

/// A client that knows its gateway is down (the outage gate, §6.1). Test doubles need not conform.
nonisolated protocol GatewayOutageReporting {
    var gatewayDown: Bool { get }
}

extension GatewayClient {
    /// True while the outage gate holds reads; false for any client without one.
    nonisolated var isGatewayDown: Bool { (self as? any GatewayOutageReporting)?.gatewayDown ?? false }
}

/// What the Bots list needs beyond `AppServices` for its slow, stale and failed states (§4), and the one Try Again
/// they share. `AppModel` conforms; a stand-in without it shows the plain states.
protocol RosterStateServices: AnyObject {
    /// Why the last roster read failed; nil when it did not.
    var rosterFailure: RosterFailure? { get }
    /// That failure's reason in plain words, when it has any worth showing (never a code).
    var rosterFailureWords: String? { get }
    /// When the list on show was last read from a good answer (or the saved copy's own time).
    var rosterUpdated: Date? { get }
    /// A roster read is out.
    var rosterRefreshing: Bool { get }
    /// Try Again: read the roster again and, when the gateway is not connected, dial it now.
    func retryRoster()
}
