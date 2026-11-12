// Sign in with Nous, the parts that need no UI (spec 01 §6, §7): PKCE, the gateway's native authorize URL, the token
// answer, and the per-account renewal single flight with its successor map (refresh tokens rotate with reuse
// detection: sending a spent one revokes the whole session).

import CryptoKit
import Foundation
import os
import Security
import UIKit

nonisolated enum NousPKCE {
    static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "No system randomness")
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// RFC 7636 S256: base64url(sha256(ascii(verifier))), no padding.
    static func challenge(for verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    /// A 64-byte verifier (86 characters) and its S256 challenge; a new pair per attempt.
    static func pair() -> (verifier: String, challenge: String) {
        let verifier = randomURLSafe(bytes: 64)
        return (verifier, challenge(for: verifier))
    }

    /// 32 random bytes, base64url.
    static func state() -> String { randomURLSafe(bytes: 32) }

    /// Constant-time comparison of the echoed state with the one this sign-in sent.
    static func sameState(_ a: String?, _ b: String) -> Bool {
        guard let a, !a.isEmpty, !b.isEmpty else { return false }
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// [own-login] A browser login a gateway offers that isn't Nous: its provider name on the wire, and what the gateway
/// calls it.
nonisolated struct BrowserLogin: Sendable, Equatable {
    var provider: String
    var displayName: String

    /// The button's words. The gateway's stock name for a self-hosted OIDC login is jargon; anything else it named
    /// itself is shown as named.
    var buttonTitle: String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == "self-hosted" || name.isEmpty || name.count > 24 { return "Sign in with Single Sign-On" }
        return "Sign in with " + name
    }
}

nonisolated enum NousGatewayProtocol {
    /// `<gateway>/auth/native/authorize?provider=nous&code_challenge=…&code_challenge_method=S256&redirect_uri=…&state=…`
    /// `provider` is the gateway's name for the login it brokers: "nous", or its own (a self-hosted OIDC login).
    static func authorizeURL(gateway: URL, provider: String = nous, challenge: String, redirect: String, state: String) -> URL? {
        guard var parts = URLComponents(string: gateway.absoluteString + "/auth/native/authorize") else { return nil }
        parts.percentEncodedQuery = strictQuery([("provider", provider), ("code_challenge", challenge), ("code_challenge_method", "S256"),
                                                 ("redirect_uri", redirect), ("state", state)])
        return parts.url
    }

    /// A query whose names and values keep only letters, digits and "-._~"; everything else is percent-encoded.
    /// `URLQueryItem` leaves ":", "/" and "+" as they are, which is a valid URL but not a safe one to send: the
    /// gateway reads values form-encoded (a bare "+" is a space), and a reverse proxy's stock exploit filter refuses
    /// any query holding "=http://" (Nginx Proxy Manager's Block Common Exploits answered the loopback
    /// `redirect_uri` with 403 before the gateway saw it; a tester's report, 2026-11-12). The receiver decodes the
    /// same text either way.
    static func strictQuery(_ items: [(name: String, value: String)]) -> String {
        // Spelled out: `CharacterSet.alphanumerics` holds the letters and digits of every script.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func enc(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text }
        return items.map { enc($0.name) + "=" + enc($0.value) }.joined(separator: "&")
    }

    static let nous = "nous"

    /// `/api/status` offers Nous to native apps: providers ∋ "nous" and flows ∋ "native_pkce".
    static func offersNous(status: JSONValue) -> Bool {
        let providers = status["auth_providers"]?.array?.compactMap(\.string) ?? []
        return providers.contains(nous) && offersBrowserSignIn(status: status)
    }

    /// `/api/status` offers some browser sign-in to native apps (flows ∋ "native_pkce").
    static func offersBrowserSignIn(status: JSONValue) -> Bool {
        (status["auth_flows"]?.array?.compactMap(\.string) ?? []).contains("native_pkce")
    }

    /// [own-login] The gateway's own browser login when it has no Nous one (a self-hosted OIDC provider: Authentik,
    /// Keycloak, Authelia…; tester Papy 2026-11-12), from `GET /api/auth/providers`: the first provider that signs in
    /// in a browser rather than with a typed password. The gateway's native sign-in brokers any such provider.
    static func ownLogin(providers body: JSONValue) -> BrowserLogin? {
        for entry in body["providers"]?.array ?? [] {
            guard let name = entry["name"]?.string, !name.isEmpty, name != nous, entry["supports_password"]?.bool != true else { continue }
            return BrowserLogin(provider: name, displayName: entry["display_name"]?.string ?? "")
        }
        return nil
    }

    enum Answer: Equatable, Sendable { case tokens(NousTokens), refused(String), unavailable(Int) }

    /// The `/auth/native/token` or `/auth/native/refresh` answer (spec 01 §6.1 step 10).
    /// The pair must be for `provider`, the login this account signed in with.
    static func answer(status: Int, body: Data, provider: String = nous, now: Double = Date().timeIntervalSince1970) -> Answer {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        switch status {
        case 200:
            guard let object, let access = object["access_token"] as? String, !access.isEmpty,
                  // [own-login] A self-hosted login may hand out no refresh token (no offline_access scope): the
                  // session then lasts as long as its access token. Nous always sends one.
                  let refresh = object["refresh_token"] as? String, !refresh.isEmpty || provider != nous,
                  let user = (object["user_id"] as? String) ?? (object["user_id"] as? NSNumber)?.stringValue, !user.isEmpty,
                  object["provider"] as? String == provider else { return .unavailable(502) }
            let expires = (object["expires_at"] as? NSNumber)?.doubleValue ?? 0
            return .tokens(NousTokens(accessToken: access, refreshToken: refresh, expiresAt: expires, userId: user, obtainedAt: now,
                                      provider: provider == nous ? nil : provider))
        case 400, 401: return .refused((object?["error"] as? String) ?? "session_expired")
        case 403: return .refused((object?["error"] as? String) ?? "not_authorized")
        default: return .unavailable(status)
        }
    }
}

/// One renewal per account at a time, shared by every client in this process; a pair already rotated past is swapped
/// for its successor instead of being sent again (spec 01 §7.3 rules 1–3, 5).
actor NousRenewals {
    static let shared = NousRenewals()

    /// `unavailable`: the gateway's status, and the `Retry-After` it sent (Hermes's `refresh_pending` 503: Portal is
    /// still rotating; the same pair is asked again after it, log study 2026-10-28).
    enum Outcome: Sendable { case tokens(NousTokens), refused, unavailable(Int, retryAfter: TimeInterval?), failed(GatewayFailure) }

    private var flights: [String: Task<Outcome, Never>] = [:]
    /// Each spent refresh token's successor, for this run of the app.
    private var successors: [String: NousTokens] = [:]
    /// Rotations Keychain couldn't take yet (locked): written again by `retryUnsaved`, with the `keep` that failed.
    private var unsaved: [String: (sent: NousTokens, renewed: NousTokens, keep: Keep)] = [:]
    typealias Keep = @Sendable (_ sent: NousTokens, _ renewed: NousTokens) -> Bool
    private var watchingUnlock = false

    /// Keeps the app running while a rotation is out; answers the release. [n20 B1] Portal spends the refresh token the
    /// moment it answers: a suspension between its answer and the Keychain write would leave the saved copy spent.
    typealias Hold = @Sendable (String) async -> @Sendable () async -> Void
    private let hold: Hold

    /// iOS's background time (`BackgroundTime`), ended once the rotation is written or has failed.
    static let backgroundTime: Hold = { name in
        let time = await BackgroundTime.begin(name)
        return { await time.end() }
    }

    init(hold: @escaping Hold = NousRenewals.backgroundTime) { self.hold = hold }

    /// The newest pair this run has seen for `tokens` (chain up to 16).
    func latest(_ tokens: NousTokens) -> NousTokens {
        var tokens = tokens
        for _ in 0..<16 {
            guard let next = successors[tokens.refreshToken] else { break }
            tokens = next
        }
        return tokens
    }

    /// Whether this refresh token was already spent by a rotation in this run.
    func isSpent(_ tokens: NousTokens) -> Bool { successors[tokens.refreshToken] != nil }

    /// Renews `tokens` for `key`. Concurrent callers share one flight; a caller holding a spent pair gets the live one
    /// without a request. `keep` persists the rotated pair (Keychain compare-and-swap) the moment it lands; false means
    /// Keychain refused and the write is retried later.
    func renew(_ key: String, _ tokens: NousTokens,
               post: @escaping @Sendable (NousTokens) async -> Outcome,
               keep: @escaping @Sendable (_ sent: NousTokens, _ renewed: NousTokens) -> Bool) async -> Outcome {
        if let flight = flights[key] { return await flight.value }
        var tokens = tokens
        let live = latest(tokens)
        if !live.samePair(tokens) {
            // [phone-logs] The successor is handed over only while it is still good. A saved gateway's news check holds
            // the pair it read at launch: this run had rotated it 15+ minutes before, so the successor was itself
            // expired, and every news check after a break sent it, got a 401, and renewed again (53 in 3 days). A
            // successor that is due is renewed here instead: its refresh token is unspent, so that is no replay.
            guard live.needsRenewal() else { return .tokens(live) }
            tokens = live
        }
        let hold = self.hold
        let task = Task<Outcome, Never> {
            let release = await hold("Hermes HQ sign-in renewal")
            let outcome = await post(tokens)
            if case .tokens(let renewed) = outcome, renewed.userId == tokens.userId {
                self.landed(key, sent: tokens, renewed: renewed, keep: keep, saved: keep(tokens, renewed))
            }
            self.flightDone(key)
            await release()
            return outcome
        }
        flights[key] = task
        return await task.value
    }

    private func landed(_ key: String, sent: NousTokens, renewed: NousTokens, keep: @escaping Keep, saved: Bool) {
        successors[sent.refreshToken] = renewed
        if saved { unsaved[key] = nil; return }
        // A rotation while the device is locked (a Mac renewing in a dark wake) can't reach Keychain. The gateway
        // honours the spent token for only 5 minutes, so a relaunch after that (an update) read the spent pair back and
        // was signed out. Write it the moment the device unlocks, not only on the next trip to the background.
        unsaved[key] = (sent, renewed, keep)
        AppLog.note("auth", "rotated Nous pair not saved (Keychain locked); retrying when unlocked")
        watchUnlock()
    }

    private func flightDone(_ key: String) { flights[key] = nil }

    /// Retries Keychain writes that failed (the app going to the background, spec 01 §13.7).
    func retryUnsaved(_ keep: @Sendable (_ key: String, _ sent: NousTokens, _ renewed: NousTokens) -> Bool) {
        for (key, pair) in unsaved where keep(key, pair.sent, pair.renewed) { unsaved[key] = nil }
    }

    /// Retries them with the `keep` each rotation came with (unlock, becoming active).
    func retryUnsaved() {
        for (key, pair) in unsaved where pair.keep(pair.sent, pair.renewed) {
            unsaved[key] = nil
            AppLog.note("auth", "rotated Nous pair saved after unlock")
        }
    }

    private func watchUnlock() {
        guard !watchingUnlock else { return }
        watchingUnlock = true
        let names = [UIApplication.protectedDataDidBecomeAvailableNotification, UIApplication.didBecomeActiveNotification]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { await self?.retryUnsaved() }
            }
        }
    }

    #if DEBUG
    /// Tests: forget everything this run learned.
    func reset() { flights.removeAll(); successors.removeAll(); unsaved.removeAll() }
    #endif
}
