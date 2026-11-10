// [offline] What the offline stream reads from the app model (docs/spec/3x-offline.md): the Bots list's slow, stale and
// failed states (§4), the launch screen's blocker (§3.2), the gateway named on the offline screen (§3.5) and the
// reconnect notice's inputs (§5.1).

import UIKit

extension AppModel: RosterStateServices {
    var rosterFailure: RosterFailure? {
        if case .failed(let failure) = botStore?.loadState { return failure }
        return nil
    }

    var rosterFailureWords: String? { botStore?.failureWords }
    var rosterUpdated: Date? { botStore?.lastUpdated }
    var rosterRefreshing: Bool { botStore?.isRefreshing ?? false }

    func retryRoster() {
        // §5.2: signed out and put off: nothing can load; say again why instead of a silent failure.
        if offlineHub.sessionEnded { offlineHub.remindSessionEnded(); return }
        refreshBots()
        if connection != .ready { client?.reconnectNow() }
    }
}

extension AppModel: LaunchContentSource {
    /// §3.2: what still stands between the launch screen and an app worth showing. Rows from the cache count as
    /// content while still connecting; an honest empty list or an honest error state counts too.
    var launchBlocker: LaunchBlocker? {
        guard let botStore else { return .cover }
        if !botStore.bots.isEmpty { return nil }
        switch botStore.loadState {
        case .ready: return nil
        // A load that failed while the gateway was away says nothing about the gateway that has just answered: the
        // read after the reconnect is covered like a first load (at most the gate's content allowance, 5 s).
        case .failed: return connection == .ready && botStore.failurePredatesOpen ? .loading : nil
        case .idle, .loading: return connection == .ready ? .loading : .cover
        }
    }
}
