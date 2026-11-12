// The stable failure vocabulary (spec 01 §18) with plain-language copy (web app: connection-startup.ts SIGN_IN_COPY,
// connection-ways.ts NOUS_SIGN_IN_COPY, main.ts OFFLINE_COPY). The UI shows `message`; `code` is for logic and logs.

import Foundation

nonisolated enum GatewayFailure: Error, Sendable, Hashable, CustomStringConvertible, LocalizedError {
    // Refusals: the gateway answered and said no. Never retried offline; they go to the sign-in form.
    case authRejected            // typed username/password refused
    case sessionEnded            // the saved session was refused (restore, refresh, ticket after refresh)
    case noPassword
    case signedOut
    // Address problems
    case invalidURL
    case insecureURL
    case invalidDestination
    case missingFields
    case notHermes
    case hostRejected
    case gatewayOutdated
    // Reachability
    case unreachable
    case timeout
    case tls
    case tailscaleOff
    case offline                 // this phone has no network path
    case rateLimited
    case unavailable             // 502/503/504 from the gateway or the edge: Hermes isn't answering right now
    case gatewayError(String?)   // anything else (detail is a short, secret-free hint for logs)
    // Keychain
    case keychainLocked
    case keychainUnreadable
    case keychainUnavailable
    case keychainClearFailed
    // Sign in with Nous
    case nousUnavailable
    case nousCancelled
    case nousFailed
    case notOwner
    // Socket / connection
    case paused
    case socketDead
    case responseTooLarge
    case connectionChanged       // sign-out or account switch while a request was in flight
    case accountMissing
    case accountCurrent
    // [offline] A read the outage gate held back (docs/spec/3x-offline.md §6.1): failed at once, as the gateway would
    // have answered it. They reuse the stable codes `unreachable` and `timeout`.
    case heldUnreachable
    case heldTimeout

    /// Stable code (spec 01 §18).
    var code: String {
        switch self {
        case .authRejected: "auth-rejected"
        case .sessionEnded: "session-ended"
        case .noPassword: "no-password"
        case .signedOut: "signed-out"
        case .invalidURL: "invalid-url"
        case .insecureURL: "insecure-url"
        case .invalidDestination: "invalid-url"
        case .missingFields: "missing-fields"
        case .notHermes: "not-hermes"
        case .hostRejected: "host-rejected"
        case .gatewayOutdated: "gateway-outdated"
        case .unreachable: "unreachable"
        case .timeout: "timeout"
        case .tls: "tls"
        case .tailscaleOff: "tailscale-off"
        case .offline: "network"
        case .rateLimited: "rate-limited"
        case .unavailable: "unavailable"
        case .gatewayError: "gateway-error"
        case .keychainLocked: "keychain-locked"
        case .keychainUnreadable: "keychain-unreadable"
        case .keychainUnavailable: "keychain-unavailable"
        case .keychainClearFailed: "keychain-clear-failed"
        case .nousUnavailable: "nous-unavailable"
        case .nousCancelled: "nous-cancelled"
        case .nousFailed: "nous-failed"
        case .notOwner: "not-owner"
        case .paused: "paused"
        case .socketDead: "socket-dead"
        case .responseTooLarge: "response-too-large"
        case .connectionChanged: "connection-changed"
        case .accountMissing: "account-missing"
        case .accountCurrent: "account-current"
        case .heldUnreachable: "unreachable"      // [offline]
        case .heldTimeout: "timeout"              // [offline]
        }
    }

    /// What the screen says. Never an address, a token or raw server text. Empty for a user cancel.
    var message: String {
        switch self {
        case .authRejected: "Your gateway didn’t accept that username or password."
        case .sessionEnded: "Your session on this gateway ended. Sign in again."
        case .noPassword: "This gateway has no password sign-in. Try Sign in with Nous, or turn on a username and password on \(HostWord.phrase)."
        case .signedOut: "Sign in to your gateway to continue."
        case .invalidURL, .invalidDestination: "Enter the full address, like https://my-mac.tail1234.ts.net."
        case .insecureURL: "Use an https:// address. Plain http:// works only for private addresses: your local network, a VPN such as Tailscale or WireGuard, and .local names."
        case .missingFields: "Enter the address, username and password."
        case .notHermes: "That address answered, but it isn’t Hermes. Check the address, including any :port at the end."
        case .hostRejected: "Your gateway doesn’t accept connections at this address yet. On \(HostWord.phrase), set HERMES_DASHBOARD_PUBLIC_URL in ~/.hermes/.env to this exact address, restart the Hermes dashboard, then try again."
        case .gatewayOutdated: "\(HostWord.sentence) has a version of Hermes that’s too old for Hermes HQ. Update Hermes there, then try again."
        case .unreachable: "Can’t reach \(HostWord.phrase). Check that it’s on, and that Tailscale is on here too if you use it."
        case .timeout: "Hermes didn’t answer in time. Check that the computer running it is on and awake."
        case .tls: "This \(DeviceWord.name) doesn’t trust your gateway’s HTTPS certificate. Use a certificate from a public authority, such as Tailscale HTTPS."
        case .tailscaleOff: "Turn on Tailscale to reach \(HostWord.phrase), then try again."   // UX study #24
        case .offline: "You’re offline. Hermes HQ reconnects when the network is back."
        case .rateLimited: "Your gateway is busy right now. Wait a minute, then try again."
        case .unavailable: "Hermes isn’t answering right now. It may be restarting — try again in a moment."
        case .gatewayError: "Your gateway couldn’t complete that. Try again."
        case .keychainLocked: "Unlock your \(DeviceWord.name), then try again."
        case .keychainUnreadable: "Your saved sign-in couldn’t be read. Sign in again."
        case .keychainUnavailable: "This \(DeviceWord.name) couldn’t open your saved sign-in. Try again."
        case .keychainClearFailed: "This \(DeviceWord.name) couldn’t remove your saved sign-in. Try again."
        case .nousUnavailable: "This Hermes doesn’t offer Sign in with Nous yet. Sign in with its username and password, or finish the Mac setup: \(DeviceWord.tap) Need help connecting? below."
        case .nousCancelled: ""
        case .nousFailed: "Nous sign-in didn’t finish. Try again."
        case .notOwner: "This Nous account isn’t allowed in. \(DeviceWord.Tap) Use Another Nous Account and sign in with the one this Hermes was set up with."
        case .paused: "Paused while Hermes HQ is in the background."
        case .socketDead: "Your gateway stopped answering. Reconnecting…"
        case .responseTooLarge: "That answer is too large to open on \(DeviceWord.name)."
        case .connectionChanged: "The connection changed before your gateway answered. Try again."
        case .accountMissing: "That gateway isn’t saved on this \(DeviceWord.name) any more."
        case .accountCurrent: "Sign out of this gateway instead."
        case .heldUnreachable: "Can’t reach \(HostWord.phrase) right now. Try again."                    // [offline]
        case .heldTimeout: "\(HostWord.sentence) isn’t answering right now. Try again in a moment."        // [offline]
        }
    }

    /// The gateway refused the sign-in: go to the (prefilled) sign-in form, never retry on our own.
    var isRejection: Bool {
        switch self {
        case .authRejected, .sessionEnded, .noPassword, .signedOut: true
        default: false
        }
    }

    /// [offline] Failed by the outage gate without asking the gateway (§6.1): never retried at once (§6.2).
    var isHeld: Bool { self == .heldUnreachable || self == .heldTimeout }

    var description: String {
        if case .gatewayError(let detail?) = self { return "\(code) (\(detail))" }
        return code
    }
    var errorDescription: String? { message }

    /// Copy for a stable code (connection-state reasons carry codes).
    static func forCode(_ code: String) -> GatewayFailure? { codeTable[code] }
    private static let codeTable: [String: GatewayFailure] = {
        let all: [GatewayFailure] = [.authRejected, .sessionEnded, .noPassword, .signedOut, .invalidURL, .insecureURL,
            .missingFields, .notHermes, .hostRejected, .gatewayOutdated, .unreachable, .timeout, .tls, .tailscaleOff,
            .offline, .rateLimited, .unavailable, .gatewayError(nil), .keychainLocked, .keychainUnreadable, .keychainUnavailable,
            .keychainClearFailed, .nousUnavailable, .nousCancelled, .nousFailed, .notOwner, .paused, .socketDead,
            .responseTooLarge, .connectionChanged, .accountMissing, .accountCurrent]
        return Dictionary(all.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
    }()

    // MARK: Mapping

    /// Any error from this module (URLError, HTTPError, RPCError, GatewayFailure) → the failure to show.
    static func from(_ error: any Error) -> GatewayFailure {
        switch error {
        case let failure as GatewayFailure: return failure
        case let later as RetryLater: return later.failure
        case let http as HTTPError: return from(status: http.status, body: http.body)
        case let rpc as RPCError:
            if rpc.isTimeout { return .timeout }
            if rpc.isConnectionLost { return .socketDead }
            if rpc.isNotConnected { return rpc.notSentBecause ?? .socketDead }
            return .gatewayError("rpc \(rpc.code)")
        case is CancellationError: return .connectionChanged
        default:
            let ns = error as NSError
            return transport(domain: ns.domain, code: ns.code)
        }
    }

    /// A non-2xx status (spec 01 §8.3).
    static func from(status: Int, body: String?) -> GatewayFailure {
        switch status {
        case 401, 403:
            if let body, body.contains("not_authorized") { return .notOwner }
            return .sessionEnded
        case 400 where body?.contains("Invalid Host header") == true: return .hostRejected
        case 429: return .rateLimited
        case 502, 503, 504, 520...526, 530: return .unavailable
        default: return .gatewayError("HTTP \(status)")
        }
    }

    /// NSURLErrorDomain → code (HermesTransportPolicy.failureCode).
    static func transport(domain: String, code: Int) -> GatewayFailure {
        guard domain == NSURLErrorDomain else { return .gatewayError("\(domain) \(code)") }
        switch code {
        case -1001: return .timeout
        case -1022: return .insecureURL
        case -1206 ... -1200: return .tls
        case -1000, -1002: return .invalidURL
        case -1003, -1004, -1005, -1006, -1009, -1018, -1020: return .unreachable
        case -999: return .connectionChanged
        default: return .gatewayError("URLError \(code)")
        }
    }
}

// MARK: - RPC error helpers (contract type RPCError)

nonisolated extension RPCError {
    /// Client-side codes for failures that never reached a gateway answer. Gateway codes are positive (4xxx, 5032) or
    /// the JSON-RPC range -32700…-32600; these sit outside both.
    static let timeoutCode = -33001
    static let connectionLostCode = -33002
    static let notConnectedCode = -33003

    var isTimeout: Bool { code == Self.timeoutCode }
    /// The socket closed before the answer came: the gateway may still have done it (delivery unconfirmed).
    var isConnectionLost: Bool { code == Self.connectionLostCode }
    var isNotConnected: Bool { code == Self.notConnectedCode }

    static func timedOut(_ method: String, after timeout: Duration) -> RPCError {
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        return RPCError(code: timeoutCode, message: "request timed out after \(Int(seconds.rounded()))s: \(method)", data: nil)
    }
    static func connectionLost(_ method: String) -> RPCError {
        RPCError(code: connectionLostCode, message: "connection closed before the gateway answered: \(method)", data: nil)
    }

    /// The call never reached a gateway (no socket while it waited: paused, offline, signed out, shut down…). Safe to
    /// send again; `message` is plain words for the screen, `data.reason` the stable code (`notSentBecause`).
    static func notSent(_ failure: GatewayFailure) -> RPCError {
        RPCError(code: notConnectedCode, message: failure.message, data: ["reason": .string(failure.code)])
    }

    /// Why a `notSent` call never went out (nil for any other error).
    var notSentBecause: GatewayFailure? {
        guard isNotConnected, let reason = data?["reason"]?.string else { return nil }
        return GatewayFailure.forCode(reason)
    }

    /// Words for a failure alert (audit 10-2): the gateway's own sentence ("That name is taken."), but never its
    /// protocol wording ("invalid params for prompt.submit: …", method not found) or a transport line
    /// ("request timed out after 30s: projects.create").
    var plainReason: String {
        if isTimeout { return GatewayFailure.timeout.message }
        if isConnectionLost { return "The connection dropped before your gateway answered. Check that it went through, then try again." }
        if isNotConnected { return message }
        if code == -32601 || code == -32602 || code == -32600
            || message.range(of: #"^\s*(invalid[ _]params|method not found|unknown method)"#,
                             options: [.regularExpression, .caseInsensitive]) != nil {
            return "Your gateway didn’t accept that request. Updating Hermes on \(HostWord.phrase) may help."
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if code == -32603 || code == -32700 || trimmed.isEmpty { return GatewayFailure.gatewayError(nil).message }
        return trimmed
    }
}

nonisolated extension HTTPError {
    /// A status that came without a readable reason, in plain words (audit 10-3): never a bare "answered 500".
    var plainWords: String {
        switch status {
        case 400, 422: "Your gateway didn’t accept that request."
        case 401, 403: "Your gateway didn’t allow that."
        case 404: "Your gateway doesn’t have that."
        case 408, 504, 524: "Your gateway took too long to answer. Try again in a moment."
        case 409: "Something changed on your gateway at the same time. Try again."
        case 413: "That’s too large for your gateway."
        case 429: GatewayFailure.rateLimited.message
        case 502, 503, 520...523, 525, 526, 530: GatewayFailure.unavailable.message
        default: "Your gateway ran into a problem (error \(status)). Try again."
        }
    }
}

// MARK: - Connection state copy

nonisolated extension ConnectionState {
    /// Plain words for a banner, or nil when nothing should be said (ready, or paused in the background).
    var userMessage: String? {
        switch self {
        case .ready: return nil
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .offline(let reason):
            if reason == "paused" { return nil }
            return GatewayFailure.forCode(reason)?.message ?? "Can’t reach \(HostWord.phrase) right now."
        case .signedOut(let reason):
            return GatewayFailure.forCode(reason)?.message ?? GatewayFailure.sessionEnded.message
        }
    }
}
