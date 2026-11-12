// What the Keychain item holds (spec 01 §2.1, §2.4, §2.4.1): every gateway account signed in on this phone, the
// current one, each with its own session (password: the gateway's cookies; Nous: the bearer pair). Never a password.
// Pure value types and list rules; the Keychain I/O is in Keychain.swift.

import Foundation

/// A gateway session cookie as saved (never leaves native code).
nonisolated struct SavedCookie: Codable, Sendable, Hashable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expires: Double?
    var secure: Bool
    var httpOnly: Bool?
    var sameSite: String?

    init(name: String, value: String, domain: String, path: String = "/", expires: Double? = nil, secure: Bool = false,
         httpOnly: Bool? = true, sameSite: String? = nil) {
        self.name = name; self.value = value; self.domain = domain; self.path = path
        self.expires = expires; self.secure = secure; self.httpOnly = httpOnly; self.sameSite = sameSite
    }

    init(_ cookie: HTTPCookie) {
        name = cookie.name; value = cookie.value; domain = cookie.domain; path = cookie.path
        expires = cookie.expiresDate?.timeIntervalSince1970; secure = cookie.isSecure
        httpOnly = cookie.isHTTPOnly; sameSite = cookie.sameSitePolicy?.rawValue
    }

    var cookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if let expires { properties[.expires] = Date(timeIntervalSince1970: expires) }
        if secure { properties[.secure] = "TRUE" }
        if httpOnly == true { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let sameSite { properties[.sameSitePolicy] = HTTPCookieStringPolicy(rawValue: sameSite) }
        return HTTPCookie(properties: properties)
    }

    /// The same session: the same cookies by name and value (the gateway renews by issuing new values).
    static func same(_ a: [SavedCookie], _ b: [SavedCookie]) -> Bool {
        Set(a.map { $0.name + "=" + $0.value }) == Set(b.map { $0.name + "=" + $0.value })
    }
}

/// Sign in with Nous: Portal's short-lived bearer and its rotating refresh token (spec 01 §6, §7).
nonisolated struct NousTokens: Codable, Sendable, Hashable {
    var accessToken: String
    var refreshToken: String
    /// Seconds since 1970 (the access token's `exp`), 0 when the gateway sent none.
    var expiresAt: Double
    /// The Nous account's id (Portal `sub`): public; keeps two Nous accounts on one gateway apart.
    var userId: String
    /// Phone clock (s since 1970) when this pair arrived (D6). nil for a pair this app did not mint.
    var obtainedAt: Double?
    /// [own-login] The gateway's name for the login this pair came from when it isn't Nous (a self-hosted OIDC
    /// provider); nil for Nous. Renewals name it, and take only that provider's pair back.
    var provider: String? = nil

    static let renewBefore: Double = 60

    /// [own-login] False for a login that handed out no refresh token: nothing to renew with, so the session ends
    /// when its access token does (the gateway's 401), and the form asks to sign in again.
    var canRenew: Bool { !refreshToken.isEmpty }

    /// The provider name renewals send: "nous" unless the pair says otherwise.
    var providerName: String { provider ?? NousGatewayProtocol.nous }

    /// Seconds the access token lives, measured on this phone (nil without `obtainedAt`).
    var lifetime: Double? { obtainedAt.map { expiresAt - $0 } }

    /// D6 (spec 01 §7.1): renew once max(lifetime − 60 s, lifetime / 2) has passed since the pair arrived. No proactive
    /// renewal when `expires_at` is missing or the lifetime is not positive (the 401 → renew → retry path covers it).
    /// Without `obtainedAt`, the web rule: renew within 60 s of expiry (and, as above, never ahead of time without one).
    func needsRenewal(now: Double = Date().timeIntervalSince1970) -> Bool {
        guard canRenew else { return false }
        guard let obtainedAt else { return expiresAt > 0 && expiresAt - now < Self.renewBefore }
        let lifetime = expiresAt - obtainedAt
        guard expiresAt > 0, lifetime > 0 else { return false }
        return now >= obtainedAt + max(lifetime - Self.renewBefore, lifetime / 2)
    }

    /// [renew-alongside] Half the lifetime has passed (spec 01 §7.1): renew, but alongside the request rather than
    /// before it, which still goes out with this token. Callers test `needsRenewal` first (that one blocks). False
    /// without a known issue time or a positive lifetime (then only `needsRenewal` and the 401 path renew).
    func renewsAlongside(now: Double = Date().timeIntervalSince1970) -> Bool {
        guard canRenew, let obtainedAt, expiresAt > 0 else { return false }
        let lifetime = expiresAt - obtainedAt
        guard lifetime > 0 else { return false }
        return now >= obtainedAt + lifetime / 2
    }

    /// The same pair (what compare-and-swap compares; `obtainedAt` is bookkeeping).
    func samePair(_ other: NousTokens) -> Bool {
        accessToken == other.accessToken && refreshToken == other.refreshToken && userId == other.userId
    }

    /// [n20 B1] How old this pair is and what it needs, for the log: "47 s old of 899 s, fresh", "2 h old of 899 s,
    /// expired". A launch that reads a pair already due right after the last run renewed has read a stale copy (two
    /// copies of the app sharing one Keychain item: the Mac sign-out after updating). Never a token.
    func ageNote(now: Double = Date().timeIntervalSince1970) -> String {
        guard let obtainedAt else { return expiresAt > 0 ? (now >= expiresAt ? "no issue time, expired" : "no issue time") : "no expiry" }
        let state = expiresAt > 0 && now >= expiresAt ? "expired" : needsRenewal(now: now) ? "renewal due"
            : renewsAlongside(now: now) ? "renews alongside" : "fresh"
        let life = lifetime.map { " of \(Int($0.rounded())) s" } ?? ""
        return "\(Self.age(now - obtainedAt)) old\(life), \(state)"
    }

    /// "47 s", "12 min", "3 h", "2 d" (a clock that ran back reads as 0 s).
    static func age(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 120 { return "\(s) s" }
        if s < 7200 { return "\(s / 60) min" }
        if s < 172_800 { return "\(s / 3600) h" }
        return "\(s / 86_400) d"
    }
}

/// One saved account (the web app's `Credentials`, minus the password, which is never persisted).
nonisolated struct StoredAccount: Codable, Sendable, Hashable {
    var url: String
    /// Password accounts: the typed username. Nous accounts: "nous:" + user id.
    var username: String
    var cookies: [SavedCookie]? = nil
    var provider: String? = nil
    var label: String? = nil
    var nous: NousTokens? = nil

    init(url: String, username: String, cookies: [SavedCookie]? = nil, provider: String? = nil, label: String? = nil,
         nous: NousTokens? = nil) {
        self.url = url; self.username = username; self.cookies = cookies; self.provider = provider
        self.label = label; self.nous = nous
    }

    var key: String { GatewayAddress.accountKey(url: url, username: username) }
    /// A browser sign-in (a bearer pair): Nous, or [own-login] the gateway's own login provider.
    var isNous: Bool { nous != nil || username.hasPrefix("nous:") }
    /// Holds a session a launch can resume (cookies or a bearer pair).
    var hasSession: Bool { !(cookies ?? []).isEmpty || nous != nil }

    /// The contract's account value. `id` is `<url>|<username>` (filesystem-safe after hashing; never a secret).
    var gatewayAccount: GatewayAccount? {
        guard let base = URL(string: url) else { return nil }
        let host = base.host(percentEncoded: false) ?? url
        let name = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        return GatewayAccount(id: url + "|" + username, baseURL: base, kind: isNous ? .nous : .password,
                              username: isNous ? nil : username, label: name?.isEmpty == false ? name! : host,
                              provider: isNous ? (nous?.provider ?? provider) : nil)
    }

    /// What a refused session leaves behind: the prefilled sign-in form's address and username.
    var withoutSession: StoredAccount {
        StoredAccount(url: url, username: username, provider: provider, label: label)
    }

    static func nousUsername(userId: String) -> String { "nous:" + userId }
}

/// The Keychain item's JSON: `{current, accounts}`, most recently used first (spec 01 §2.4).
nonisolated struct SavedAccounts: Codable, Sendable, Hashable {
    var current: String?
    var accounts: [StoredAccount]

    init(current: String? = nil, accounts: [StoredAccount] = []) { self.current = current; self.accounts = accounts }

    var active: StoredAccount? { accounts.first { $0.key == current } }
    func account(_ key: String) -> StoredAccount? { accounts.first { $0.key == key } }

    /// Saved (or updated) and made current, first in the list. A save that names no label keeps the old one.
    mutating func save(_ account: StoredAccount) {
        var account = account
        let key = account.key
        if account.label == nil { account.label = accounts.first { $0.key == key }?.label }
        accounts.removeAll { $0.key == key }
        accounts.insert(account, at: 0)
        current = key
    }

    /// Changed in place (order and `current` untouched); false when not saved.
    @discardableResult mutating func update(_ key: String, _ change: (inout StoredAccount) -> Void) -> Bool {
        guard let index = accounts.firstIndex(where: { $0.key == key }) else { return false }
        change(&accounts[index])
        return true
    }

    /// Made current (a switch); false for an account that isn't saved.
    mutating func select(_ key: String) -> Bool {
        guard let index = accounts.firstIndex(where: { $0.key == key }) else { return false }
        accounts.insert(accounts.remove(at: index), at: 0)
        current = key
        return true
    }

    /// Compare-and-swap (spec 01 §7.3 rule 4): the rotated pair replaces `sent` only in an account that still holds it.
    mutating func renewNous(_ key: String, sent: NousTokens, renewed: NousTokens) -> Bool {
        guard let index = accounts.firstIndex(where: { $0.key == key }), let held = accounts[index].nous,
              held.samePair(sent) else { return false }
        accounts[index].nous = renewed
        return true
    }

    /// Removed; removing the current account makes the most recently used other one current (none when it was last).
    @discardableResult mutating func remove(_ key: String) -> StoredAccount? {
        guard let index = accounts.firstIndex(where: { $0.key == key }) else { return nil }
        let removed = accounts.remove(at: index)
        if current == key { current = accounts.first?.key }
        return removed
    }

    func encoded() throws -> Data { try JSONEncoder().encode(self) }
    /// The list, or (the web app's item from build ≤ 89) one bare account made current. A web item's extra keys (an old
    /// `password` field) are ignored, never written back.
    static func decode(_ data: Data) -> SavedAccounts? {
        if let list = try? JSONDecoder().decode(SavedAccounts.self, from: data) { return list }
        guard let single = try? JSONDecoder().decode(StoredAccount.self, from: data) else { return nil }
        return SavedAccounts(current: single.key, accounts: [single])
    }
}
