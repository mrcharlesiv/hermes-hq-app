// [perf-returns] One dial's steps for the phone's performance log (DiagnosticLog, sent home by LogUploader), so a slow
// return can be pinned on the tunnel, the ticket or the socket's handshake. StartupTimings keeps the same steps in
// memory for Diagnostics; this is the one line that reaches the log. Content-free: durations and a failure code only.
//
//   connect: tunnel 3 ms, ticket 412 ms, handshake 690 ms, total 1105 ms (return after 312 s, active to ready 1180 ms)
//   connect failed (timeout): wait 1500 ms, tunnel 2 ms, ticket 15003 ms (auth refreshed), total 16505 ms (first)

import Foundation

nonisolated struct ConnectSteps: Sendable, Equatable {
    /// The redial floor waited out before the dial (`ReconnectBackoff.minRedialSeconds`).
    var waited: Duration = .zero
    var tunnel: Duration?
    /// Minting the socket ticket, its queue included.
    var ticket: Duration?
    /// The ticket waited for a credentials refresh (a 401 and its retry, or a Nous renewal in the token's last minute).
    /// A renewal alongside (`GatewayAuth.renewAlongside`) does not hold the ticket and is logged on its own line.
    var refreshed = false
    /// The socket's upgrade and the gateway's first frame (`gateway.ready`), together.
    var handshake: Duration?
    var total: Duration = .zero
    /// No socket was ever ready on this connection yet: the launch's (or a sign-in's) first dial.
    var first = false
    /// The app had been in the background this long before the return that led to this dial.
    var away: Duration?
    /// From the app becoming active to this dial's end.
    var sinceActive: Duration?

    static func ms(_ d: Duration) -> Int { Int((d / .milliseconds(1)).rounded()) }

    /// "connect: …" when the gateway said ready (`outcome == "ok"`), else "connect failed (<code>): …".
    func line(outcome: String) -> String {
        var parts: [String] = []
        if waited > .zero { parts.append("wait \(Self.ms(waited)) ms") }
        if let tunnel { parts.append("tunnel \(Self.ms(tunnel)) ms") }
        if let ticket { parts.append("ticket \(Self.ms(ticket)) ms" + (refreshed ? " (auth refreshed)" : "")) }
        if let handshake { parts.append("handshake \(Self.ms(handshake)) ms") }
        parts.append("total \(Self.ms(total)) ms")
        var context: [String] = []
        if first { context.append("first") }
        if let away { context.append("return after \(Int((away / .seconds(1)).rounded())) s") }
        if let sinceActive { context.append("active to \(outcome == "ok" ? "ready" : "failure") \(Self.ms(sinceActive)) ms") }
        let head = outcome == "ok" ? "connect" : "connect failed (\(outcome))"
        return head + ": " + parts.joined(separator: ", ") + (context.isEmpty ? "" : " (" + context.joined(separator: ", ") + ")")
    }
}
