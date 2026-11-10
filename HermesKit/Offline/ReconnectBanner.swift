// [offline] The reconnect notice (docs/spec/3x-offline.md §5.1), a port of the web app's `reconnectNotice` and
// `reconnectBanner` (`src/connection-startup.ts`). A socket error holds the notice for 4 s, so a socket that drops and
// comes straight back shows nothing but the header's subtitle; a lost network shows it at once. It says only
// "Reconnecting to the computer running Hermes…" until a reconnect attempt has actually failed, then why. A reconnect tried while the
// app was in the background ("paused") says nothing.

import Foundation

nonisolated enum ReconnectNotice {
    static let networkDown = "Network unavailable. Check your network or VPN connection."
    // UX study #24: the computer running Hermes (HostWord), never "gateway". The VPN, dash and casing wording stays
    // the web's (#132, docs/spec/3x-offline.md §2 DECISION).
    static let reconnecting = "Reconnecting to \(HostWord.phrase)…"

    /// The sentence for the state. `failed == false`: no reconnect attempt has failed yet in this outage (no cause is
    /// named). `offline`: the header reads "Offline" (the notice then says "Hermes HQ keeps trying.").
    static func text(networkDown: Bool, reason: String? = nil, failed: Bool? = nil, offline: Bool = false) -> String {
        if networkDown { return Self.networkDown }
        if offline { return "\(offlineCause(reason: reason, failed: failed)) Hermes HQ keeps trying." }
        if failed == false { return reconnecting }
        switch reason {
        case "tailscale-off": return "Turn on Tailscale to reach \(HostWord.phrase). Reconnecting…"
        case "timeout": return "\(HostWord.sentence) is slow to answer — still trying…"
        case "rate-limited": return "\(HostWord.sentence) is busy — still trying…"
        case nil, "", "unreachable": return "Can’t reach \(HostWord.phrase). Check your network or VPN connection. Reconnecting…"
        default: return "Can’t connect to \(HostWord.phrase) right now. Reconnecting…"
        }
    }

    private static func offlineCause(reason: String?, failed: Bool?) -> String {
        if failed == false { return "\(HostWord.sentence) is out of reach." }
        switch reason {
        case "tailscale-off": return "Turn on Tailscale to reach \(HostWord.phrase)."
        case "timeout": return "\(HostWord.sentence) is slow to answer."
        case "rate-limited": return "\(HostWord.sentence) is busy."
        case nil, "", "unreachable": return "Can’t reach \(HostWord.phrase). Check your network or VPN connection."
        default: return "Can’t connect to \(HostWord.phrase) right now."
        }
    }

    /// The network sentence wears the Wi-Fi symbol, the others the reconnecting arrows.
    static func symbol(for text: String) -> String {
        text == networkDown ? "wifi.exclamationmark" : "arrow.triangle.2.circlepath"
    }
}

@MainActor final class ReconnectBanner {
    /// A dropped socket that is back within this long raises no notice.
    nonisolated static let hold: TimeInterval = 4

    private let hold: TimeInterval
    private let clock: any FlightClock
    private let offline: @MainActor () -> Bool
    private let show: @MainActor (String) -> Void
    private let clearView: @MainActor () -> Void

    private var networkDown = false
    private var failed = false
    private var reason: String?
    private var openAttempt = 0
    private var holdTimer: (any FlightTimer)?
    private var stopped = false
    /// The sentence on show ("" = none).
    private(set) var shown = ""

    init(hold: TimeInterval = ReconnectBanner.hold, clock: (any FlightClock)? = nil, offline: @escaping @MainActor () -> Bool = { false },
         show: @escaping @MainActor (String) -> Void, clear: @escaping @MainActor () -> Void) {
        self.hold = hold
        self.clock = clock ?? LiveFlightClock.shared
        self.offline = offline
        self.show = show
        self.clearView = clear
    }

    private func cancelHold() { holdTimer?.cancel(); holdTimer = nil }

    private func render() {
        guard !stopped, reason != "paused" else { return }
        let next = ReconnectNotice.text(networkDown: networkDown, reason: reason, failed: failed, offline: offline())
        guard next != shown else { return }
        shown = next
        show(next)
    }

    private func clear() {
        cancelHold()
        guard !shown.isEmpty else { return }
        shown = ""
        clearView()
    }

    /// A gateway socket failed: the open one dropping (its own attempt number), or a reconnect attempt (a later one).
    func socketError(attempt: Int? = nil) {
        if (attempt ?? openAttempt) > openAttempt { failed = true }
        if !shown.isEmpty { return render() }
        guard holdTimer == nil, !stopped else { return }
        holdTimer = clock.schedule(after: hold) { [weak self] in
            guard let self else { return }
            self.holdTimer = nil
            self.render()
        }
    }

    /// The connection could not open a socket and says why; "paused" is the app in the background.
    func failure(reason why: String?) {
        reason = why
        if why == "paused" { return }
        failed = true
        if !shown.isEmpty { render() }
    }

    func foreground() { if reason == "paused" { reason = nil } }

    func network(reachable: Bool) {
        networkDown = !reachable
        if reachable { return clear() }
        cancelHold()
        render()
    }

    func open(attempt: Int? = nil) {
        if let attempt { openAttempt = attempt }
        networkDown = false; failed = false; reason = nil
        clear()
    }

    /// The header's reading changed (a retry cycle turned offline): a notice on show says so too.
    func refresh() { if !shown.isEmpty { render() } }

    /// Signed out: the notice goes for good ("Sign in again" replaces it).
    func stop() { clear(); stopped = true }

    var isStopped: Bool { stopped }
}
