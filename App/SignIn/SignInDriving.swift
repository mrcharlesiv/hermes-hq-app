// What the sign-in screen needs from the network layer. Integration adapts the real Net module (Probe, AuthSession,
// NousSignIn) to this protocol; the screen never sees a cookie, token or URLSession.

import Foundation

protocol SignInDriving: AnyObject {
    /// Unauthenticated `GET <address>/api/status` (spec 01 §4.1): which ways in the address offers.
    /// Never throws: an unreachable or unknown address answers `reachable: false`.
    func probe(_ address: String) async -> SignInOptions
    /// Typed sign-in (spec 01 §5.1). Throws `SignInError` (or a URLError/HTTPError, mapped by `SignInCopy`).
    func signInWithPassword(address: String, username: String, password: String) async throws
    /// Sign in with Nous (spec 01 §6.1): the system sheet, the loopback catch, the bearer pair.
    func signInWithNous(address: String) async throws

    // [onboarding] Added with defaults (below), so a driver written before them still conforms.
    /// The same sign-ins with the form's optional Name (docs/spec/3x-onboarding.md §5.13): kept on this phone as the
    /// account's label, never sent to the gateway.
    func signInWithPassword(address: String, username: String, password: String, label: String?) async throws
    func signInWithNous(address: String, label: String?) async throws
    /// After a sign-in succeeded: is this Hermes new enough (§5.14)? One read of its status; `.unknown` never blocks.
    func compatibility() async -> GatewayCompatibility
}

extension SignInDriving {
    func signInWithPassword(address: String, username: String, password: String, label: String?) async throws {
        try await signInWithPassword(address: address, username: username, password: password)
    }
    func signInWithNous(address: String, label: String?) async throws { try await signInWithNous(address: address) }
    func compatibility() async -> GatewayCompatibility { .compatible }
}

nonisolated struct SignInOptions: Sendable, Equatable {
    var reachable: Bool
    var offersNous: Bool
    var offersPassword: Bool
    /// Optional plain-language note about the address (shown calmly under the field, never as an error).
    var message: String?
    /// [own-login] The browser button's words when the gateway signs in with its own login provider rather than Nous
    /// ("Sign in with Single Sign-On"); nil for Nous. The browser way in is then this one.
    var ownLoginTitle: String?

    init(reachable: Bool, offersNous: Bool, offersPassword: Bool, message: String? = nil, ownLoginTitle: String? = nil) {
        self.reachable = reachable; self.offersNous = offersNous; self.offersPassword = offersPassword; self.message = message
        self.ownLoginTitle = ownLoginTitle
    }

    /// Some sign-in in the browser sheet: Nous, or the gateway's own login.
    var offersBrowser: Bool { offersNous || ownLoginTitle != nil }
}

/// A sign-in failure as one of spec 01 §18's stable codes ("auth-rejected", "unreachable", "nous-cancelled"…).
nonisolated struct SignInError: Error, Sendable, Equatable {
    var code: String
    var detail: String?
    init(_ code: String, detail: String? = nil) { self.code = code; self.detail = detail }
}

extension SignInWays {
    /// unknown → both; Nous only → nous; password only → password; both or neither → both.
    nonisolated init(_ options: SignInOptions?) {
        guard let options, options.reachable else { self = .both; return }
        if options.offersBrowser && !options.offersPassword { self = .nous }
        else if options.offersPassword && !options.offersBrowser { self = .password }
        else { self = .both }
    }
}

/// The form's words (`W:src/connection-startup.ts:44-71`, `W:src/connection-ways.ts:5-13,33-42`).
nonisolated enum SignInCopy {
    static var device: String { DeviceWord.name }   // [m9/ipad]

    static let messages: [String: String] = [
        "auth-rejected": "Hermes didn’t accept that username or password.",
        "no-password": "No password sign-in here: try Sign in with Nous, or add HERMES_DASHBOARD_BASIC_AUTH_USERNAME and HERMES_DASHBOARD_BASIC_AUTH_PASSWORD to ~/.hermes/.env on the computer running Hermes and restart the Hermes dashboard.",
        "signed-out": "Sign in to Hermes to continue.",
        "session-ended": "Your session on this Hermes ended. Enter your password to sign in again.",
        "insecure-url": "Use an https:// address. Plain http:// works only for private addresses: your local network, a VPN such as Tailscale or WireGuard, and .local names.",
        "tailscale-ip": "\(device) allows plain http:// to a Tailscale machine only by its name. Use the Tailscale name of the computer running Hermes (in the Tailscale app, like mac-mini.tailnet-name.ts.net) instead of its 100.x address, or use https://.",
        "invalid-url": "Enter the full address, like https://my-mac.tail1234.ts.net.",
        "missing-fields": "Enter the address, username and password.",
        "unreachable": "Can’t reach that address. Check that it’s typed right and that the computer running Hermes is on. If you use Tailscale, check that it’s on here too.",
        "timeout": "Hermes didn’t answer in time. Check that the computer running it is on and awake, and that Tailscale is on if you use it.",
        "tls": "\(device) doesn’t trust the HTTPS certificate at this address. Use a certificate from a public authority, such as Tailscale HTTPS.",
        "not-hermes": "That address answered, but it isn’t Hermes. Check the address, including any :port at the end.",
        "rate-limited": "Hermes is limiting sign-in attempts. Wait a minute, then try again.",
        "keychain-locked": "Unlock your \(device), then try again.",
        "keychain-unreadable": "Your saved sign-in couldn’t be read. Sign in again.",
        "keychain-unavailable": "\(device) couldn’t open your saved sign-in. Try again.",
        "gateway-error": "Couldn’t sign in. Check the Hermes address and try again.",
        "tailscale-off": "Turn on Tailscale to reach your Hermes, then try again.",
        "gateway-outdated": "\(HostWord.sentence) runs a version of Hermes that’s too old for Hermes HQ. Update Hermes on it, then try again.",
        "host-rejected": "Hermes doesn’t accept connections at this address yet. On the computer running Hermes, set HERMES_DASHBOARD_PUBLIC_URL in ~/.hermes/.env to this exact address, restart the Hermes dashboard, then try again.",
        "nous-unavailable": "This Hermes doesn’t offer Sign in with Nous yet. Sign in with its username and password, or finish the Mac setup: \(DeviceWord.tap) Need help connecting? below.",
        "nous-cancelled": "",
        "nous-failed": "Nous sign-in didn’t finish. Try again.",
        "not-owner": "This Nous account isn’t allowed in. \(DeviceWord.Tap) Use Another Nous Account and sign in with the one this Hermes was set up with.",
    ]

    /// Under the address when the probe couldn't reach it (UX study #130); the full form stays, as the probe can be wrong.
    static let unreachableNote = "Can’t reach this address right now. Check that it’s typed right, or sign in anyway."

    /// The stable code for any error a driver throws.
    static func code(for error: Error) -> String {
        if let error = error as? SignInError { return messages[error.code] != nil ? error.code : "gateway-error" }
        if error is CancellationError { return "nous-cancelled" }
        if let http = error as? HTTPError {
            switch http.status {
            case 401, 403: return "auth-rejected"
            case 429: return "rate-limited"
            default: return "gateway-error"
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .timedOut: return "timeout"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet, .networkConnectionLost,
                 .internationalRoamingOff, .dataNotAllowed:
                return "unreachable"
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot, .secureConnectionFailed, .clientCertificateRejected:
                return "tls"
            case .badURL, .unsupportedURL: return "invalid-url"
            case .cancelled, .userCancelledAuthentication: return "nous-cancelled"
            default: return "gateway-error"
            }
        }
        return "gateway-error"
    }

    /// What the form says for a failure ("" for a cancelled Nous sheet: nothing to say). A code the form has its own
    /// words for says those; any other `SignInError` says the Net module's plain words it carries (`detail`, from
    /// `GatewayFailure.message`: "You're offline…", "Hermes isn't answering right now…").
    static func message(for error: Error) -> String {
        if let error = error as? SignInError, messages[error.code] == nil, let detail = error.detail, !detail.isEmpty {
            return detail
        }
        return messages[code(for: error)] ?? messages["gateway-error"]!
    }

    /// Failures that mark the address field (`invalidField`, `connection-startup.ts:90-97`).
    static func marksAddress(_ code: String) -> Bool {
        ["insecure-url", "tailscale-ip", "invalid-url", "unreachable", "timeout", "tls", "not-hermes"].contains(code)
    }

    /// Failures that mark the password field: the gateway turned the password down.
    static func marksPassword(_ code: String) -> Bool { code == "auth-rejected" || code == "session-ended" }

    /// [own-login] The words for a gateway that signs in with its own login provider (self-hosted OIDC), not Nous.
    enum OwnLogin {
        static let subtitleOnly = "This Hermes uses its own sign-in page. Use the account it was set up with."
        static let subtitleBoth = "This Hermes has its own sign-in page, and a username and password."
        static let footnote = "You sign in on your own sign-in page, in a secure sheet; Hermes HQ never sees that password. Your session stays in \(DeviceWord.system) Keychain to reconnect."
        static let messages: [String: String] = [
            "nous-failed": "The sign-in didn’t finish. Try again.",
            "not-owner": "This account isn’t allowed in. Sign in with the one this Hermes was set up for.",
            "nous-unavailable": "This Hermes doesn’t offer a browser sign-in to apps. Sign in with its username and password.",
        ]
    }

    static func subtitle(_ ways: SignInWays?, ownLogin: Bool) -> String {
        guard ownLogin else { return subtitle(ways) }
        switch ways {
        case .nous: return OwnLogin.subtitleOnly
        case .both: return OwnLogin.subtitleBoth
        default: return subtitle(ways)
        }
    }

    static func footnote(_ ways: SignInWays?, ownLogin: Bool) -> String {
        ownLogin && ways == .nous ? OwnLogin.footnote : footnote(ways)
    }

    /// A failure's words; with the gateway's own login, the ones that would name Nous say what happened instead.
    static func message(for error: Error, ownLogin: Bool) -> String {
        if ownLogin, let words = OwnLogin.messages[code(for: error)] { return words }
        return message(for: error)
    }

    static func subtitle(_ ways: SignInWays?) -> String {
        switch ways {
        case .password: return "This Hermes uses a username and password. To sign in with your Nous account instead, it needs a one-time setup on its computer: \(DeviceWord.tap) Need help connecting? below."
        case .nous: return "This Hermes uses Nous sign-in. Use the Nous account it was set up with."
        default: return "Paste or type the address of your Hermes, then sign in."
        }
    }

    /// [nous-different-account] Under Sign in with Nous: a private sheet, so Safari's saved Nous login can't pick the
    /// account.
    static let otherNousAccount = "Use Another Nous Account"

    static func footnote(_ ways: SignInWays?) -> String {
        ways == .nous
            ? "Nous handles the sign-in in a secure sheet; Hermes HQ never sees your Nous password. Your session stays in \(DeviceWord.system) Keychain to reconnect."
            : "Hermes HQ keeps your session in \(DeviceWord.system) Keychain to reconnect. Your password is never stored."
    }
}

/// The address as typed → what is probed and signed in to (`W:src/connection-startup.ts:96-121`): a scheme typed in
/// any case is lowered; with none, `http://` for local and Tailscale hosts, else `https://`.
nonisolated enum SignInAddress {
    static func normalize(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return value }
        if let range = value.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) {
            return value[range].lowercased() + value[range.upperBound...]
        }
        let host: String
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            host = String(value[...close])
        } else {
            host = String(value.split(whereSeparator: { "/:?#".contains($0) }).first ?? "")
        }
        return (isLocalHost(host) ? "http://" : "https://") + value
    }

    /// The address in pasted text. People copy Hermes's whole reply ("Here it is: https://my-mac.tail1234.ts.net. Paste
    /// it into…"), so the first link in it is the address; a line with no link is taken as typed.
    static func pasted(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains(where: \.isWhitespace) else { return text }
        for pattern in ["[A-Za-z][A-Za-z0-9+.-]*://[^\\s<>\"“”]+", "[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*\\.ts\\.net(:[0-9]+)?"] {
            guard let range = text.range(of: pattern, options: .regularExpression) else { continue }
            var found = String(text[range])
            while let last = found.last, ".,;:!?)]}'’*_`".contains(last) { found.removeLast() }
            if !found.isEmpty { return found }
        }
        return text
    }

    /// Whether the probe should be asked at all: text that looks like `host.tld` (`connection-ways.ts:57`).
    static func looksLikeAddress(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: "^(https?://)?[^\\s/]+\\.[^\\s/]+", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isASCIIDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }

    /// Plain http:// is for networks the user controls (`localGatewayHost`, `connection-startup.ts:101-114`).
    static func isLocalHost(_ raw: String) -> Bool {
        var host = raw.lowercased()
        if host.hasPrefix("[") { host.removeFirst() }
        if host.hasSuffix("]") { host.removeLast() }
        if host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty { return false }
        if host.contains(":") {
            return host == "::1" || host.range(of: "^(fe[89ab][0-9a-f]|f[cd][0-9a-f]{2}):", options: .regularExpression) != nil
        }
        // ASCII digits only, as the web's `\d{1,3}`: `Character.isNumber` is also true for "١" or "²", which `Int`
        // can't read (an address typed in Arabic-Indic digits used to crash here).
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4, octets.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(Self.isASCIIDigit) }) {
            let n = octets.compactMap { Int($0) }
            guard n.count == 4, !n.contains(where: { $0 > 255 }) else { return false }
            let (a, b) = (n[0], n[1])
            return a == 127 || a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
                || (a == 169 && b == 254) || (a == 100 && (64...127).contains(b))
        }
        if host.allSatisfy({ Self.isASCIIDigit($0) || $0 == "." }) { return false }
        return host == "localhost" || !host.contains(".") || host.hasSuffix(".local") || host.hasSuffix(".ts.net")
            || GatewayAddress.privateNameSuffixes.contains(where: host.hasSuffix)   // [own-vpn]
    }
}
