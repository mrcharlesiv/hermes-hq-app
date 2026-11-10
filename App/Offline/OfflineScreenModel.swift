// [offline] What the offline screen shows (docs/spec/3x-offline.md §3.5, §3.6): the words for the reason, the card
// naming the gateway, and the status line — a countdown to the next automatic retry drawn from the due date (never a
// decrementing counter), or "Connecting…" while an attempt runs. VoiceOver hears "Trying again automatically" once
// per countdown and never the number.

import Foundation
import Observation

@Observable
final class OfflineScreenModel {
    struct OtherGateway: Identifiable, Equatable {
        var id: String
        var title: String
    }

    /// The connection's reason (`GatewayFailure.code`), or a Keychain reason.
    var reason: String?
    var url: URL?
    /// The name given to the gateway on this phone.
    var label: String?
    /// The username, or "Nous account".
    var accountName: String?
    /// Keychain reads that have failed in a row while the saved sign-in can't be opened.
    var keychainReads = 0
    /// The other saved gateways, offered under the buttons as "Switch to <name>" (UX study #125).
    var otherGateways: [OtherGateway] = []
    /// The next automatic retry; nil while an attempt runs or when nothing will retry.
    private(set) var due: Date?
    /// An attempt is running: the status line says so and Try Again is off (the ways to another sign-in stay on:
    /// a dial into a silent host runs for 15 s, and nobody should be kept from leaving that long).
    private(set) var connecting = false
    /// A sentence that replaces the status line (the storage sentence of §3.4).
    var problem: String?
    /// Bumped when Try Again is pressed: VoiceOver's focus moves to the status line (§3.7).
    private(set) var focusRequests = 0

    /// VoiceOver's announcements go through here (tests record them).
    @ObservationIgnored var announce: (String) -> Void = { _ in }
    @ObservationIgnored private(set) var announced: [String] = []

    var screen: OfflineCopy.Screen { OfflineCopy.screen(reason: reason, hasAddress: url != nil, nous: OfflineCopy.nousHosted(url)) }
    /// No network on this phone: nothing dials, so the line says what it waits for instead of standing empty.
    private var waitsForNetwork: Bool { reason == GatewayFailure.offline.code && due == nil && !connecting }
    var card: OfflineCopy.Card? { OfflineCopy.card(reason: reason, url: url, label: label, accountName: accountName) }
    var showsDifferentGateway: Bool { OfflineCopy.showsDifferentGateway(hasAddress: url != nil) }
    var showsSignInAgain: Bool { OfflineCopy.showsSignInAgain(reason: reason, failedReads: keychainReads) }
    var tryAgainEnabled: Bool { !connecting }

    /// The visible status line at `now`.
    func statusText(now: Date = Date()) -> String {
        if let problem, !problem.isEmpty { return problem }
        if connecting { return OfflineCopy.connecting }
        if waitsForNetwork { return OfflineCopy.waitingForNetwork }
        guard let due else { return "" }
        return OfflineCopy.countdown(RetryLadder.remaining(until: due, now: now))
    }

    /// What VoiceOver reads for the status line: never the number.
    var spokenStatus: String {
        if let problem, !problem.isEmpty { return problem }
        if connecting { return OfflineCopy.connecting }
        if waitsForNetwork { return OfflineCopy.waitingForNetwork }
        return due == nil ? "" : OfflineCopy.retryingSpoken
    }

    /// The retry clock changed. One announcement when a countdown starts, one when an attempt starts.
    func setStatus(due next: Date?, connecting attempt: Bool) {
        let countdownBegan = next != nil && !attempt && (due == nil || connecting)
        let attemptBegan = attempt && !connecting
        due = attempt ? nil : next
        connecting = attempt
        if attemptBegan { say(OfflineCopy.connecting) } else if countdownBegan { say(OfflineCopy.retryingSpoken) }
    }

    func focusStatus() { focusRequests += 1 }

    private func say(_ words: String) {
        announced.append(words)
        announce(words)
    }
}
