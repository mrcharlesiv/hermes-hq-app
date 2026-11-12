// [share] The signed-in account, read from the app's own Keychain item (docs/spec/3x-share.md §5.2, §7.4, §7.9).
// Port of build 240's DispatchShareKit.swift:184-328.
//
// Where the app's sign-in lives: `AccountVault`'s item (service ai.hermes.ios.gateway, account primary) in the app's
// default access group, which the extension lists in keychain-access-groups. Reads search every group the process may
// use. The extension only ever UPDATES that one item's value: it never adds one (so it never creates a second
// sign-in) and never deletes one. The JSON is edited as a dictionary, so every field the app keeps (provider, label,
// other accounts, fields a later build adds) survives an extension write untouched.

import Foundation
import Security

nonisolated protocol ShareKeychainStore: Sendable {
    func read() throws -> Data?
    func update(_ data: Data) throws
}

nonisolated struct SystemShareKeychain: ShareKeychainStore {
    var service: String = ShareIdentity.keychainService
    var account: String = ShareIdentity.keychainAccount

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read() throws -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if status == errSecInteractionNotAllowed { throw ShareFailure.locked }
        guard status == errSecSuccess, let data = result as? Data else { throw ShareFailure.keychain(Int(status)) }
        return data
    }

    func update(_ data: Data) throws {
        // The item keeps its access group and protection class; only its value changes.
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecInteractionNotAllowed { throw ShareFailure.locked }
        guard status == errSecSuccess else { throw ShareFailure.keychain(Int(status)) }
    }
}

/// The current account as the extension uses it: its gateway and its session cookies (raw, as the app wrote them), or
/// its Nous token pair for a Sign in with Nous account (which never holds cookies).
nonisolated struct ShareAccount: @unchecked Sendable {
    let key: String
    let url: String
    let username: String
    /// `SavedCookie` JSON entries, untouched (immutable once read, which is what makes this type safe to send).
    let cookies: [[String: Any]]
    var nous: ShareNous? = nil
}

/// Sign in with Nous: `NousTokens` as the Keychain item stores it, the same JSON keys. Portal rotates the refresh token
/// on every use and treats a replayed one as theft (it revokes the whole session).
nonisolated struct ShareNous: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    /// Seconds since 1970 (the access token's `exp`).
    var expiresAt: Double
    var userId: String
    /// When this pair was issued or last rotated, by this phone's clock (absent on a pair saved by an older build).
    var obtainedAt: Double?
    /// [own-login] The gateway's name for the login this pair came from when it isn't Nous (`NousTokens.provider`).
    var provider: String? = nil

    /// The provider name a renewal sends, and the only one whose pair it takes back.
    var providerName: String { provider ?? "nous" }

    init(accessToken: String, refreshToken: String, expiresAt: Double, userId: String, obtainedAt: Double? = nil,
         provider: String? = nil) {
        self.accessToken = accessToken; self.refreshToken = refreshToken
        self.expiresAt = expiresAt; self.userId = userId; self.obtainedAt = obtainedAt; self.provider = provider
    }

    init?(_ value: Any?) {
        guard let entry = value as? [String: Any], let access = entry["accessToken"] as? String, !access.isEmpty,
              let refresh = entry["refreshToken"] as? String,
              let user = entry["userId"] as? String, !user.isEmpty else { return nil }
        // [own-login] Only a self-hosted login's pair may have no refresh token (`NousTokens.canRenew`).
        guard !refresh.isEmpty || (entry["provider"] as? String)?.isEmpty == false else { return nil }
        self.init(accessToken: access, refreshToken: refresh, expiresAt: (entry["expiresAt"] as? NSNumber)?.doubleValue ?? 0,
                  userId: user, obtainedAt: (entry["obtainedAt"] as? NSNumber)?.doubleValue,
                  provider: (entry["provider"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    var json: [String: Any] {
        var entry: [String: Any] = ["accessToken": accessToken, "refreshToken": refreshToken, "expiresAt": expiresAt, "userId": userId]
        if let obtainedAt { entry["obtainedAt"] = obtainedAt }
        if let provider { entry["provider"] = provider }
        return entry
    }

    /// The same session pair: access token, refresh token and user (spec D12; the app's `NousTokens.samePair`).
    func samePair(_ other: ShareNous) -> Bool {
        accessToken == other.accessToken && refreshToken == other.refreshToken && userId == other.userId
    }

    /// The app's own rule (`NousTokens.needsRenewal`, spec D12): with a known issue time, once max(lifetime − 60 s,
    /// lifetime / 2) has passed since the pair arrived, and never ahead of time when the gateway sent no expiry (a
    /// refusal renews it then). A pair without an issue time keeps the older rule: within a minute of its end (and,
    /// with no expiry either, never ahead of time).
    func needsRenewal(now: Double = Date().timeIntervalSince1970) -> Bool {
        guard !refreshToken.isEmpty else { return false }
        guard let obtainedAt else { return expiresAt > 0 && expiresAt - now < 60 }
        let lifetime = expiresAt - obtainedAt
        guard expiresAt > 0, lifetime > 0 else { return false }
        return now >= obtainedAt + max(lifetime - 60, lifetime / 2)
    }

    /// The `/auth/native/refresh` answer: the rotated pair, for this same account and login provider only.
    static func renewed(status: Int, body: Data, userId: String, provider: String? = nil,
                        now: Double = Date().timeIntervalSince1970) -> ShareNous? {
        guard status == 200, let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              object["provider"] as? String == provider ?? "nous",
              let access = object["access_token"] as? String, !access.isEmpty,
              let refresh = object["refresh_token"] as? String, !refresh.isEmpty,
              let user = (object["user_id"] as? String) ?? (object["user_id"] as? NSNumber)?.stringValue, user == userId else { return nil }
        return ShareNous(accessToken: access, refreshToken: refresh, expiresAt: (object["expires_at"] as? NSNumber)?.doubleValue ?? 0,
                         userId: user, obtainedAt: now, provider: provider)
    }
}

/// The Keychain item's JSON. Shapes: this app's list `{"current": key, "accounts": [{url, username, cookies?, provider?,
/// label?, nous?}]}`, or a build-89 single account `{url, username, password?, cookies?}` (it holds a password, which the
/// extension never reads or sends).
nonisolated enum ShareAccounts {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func current(in data: Data) -> ShareAccount? {
        guard let object = object(data) else { return nil }
        let entry: [String: Any]?
        if let accounts = object["accounts"] as? [[String: Any]] {
            guard let current = object["current"] as? String else { return nil }
            entry = accounts.first { key($0) == current }
        } else if object["accounts"] != nil {
            entry = nil        // `accounts` of the wrong type: nobody
        } else {
            entry = object
        }
        guard let entry, let url = entry["url"] as? String, let username = entry["username"] as? String else { return nil }
        let cookies = (entry["cookies"] as? [[String: Any]]) ?? []
        return ShareAccount(key: ShareRules.accountKey(url: url, username: username), url: url, username: username,
                            cookies: cookies, nous: ShareNous(entry["nous"]))
    }

    /// A build-89 item: one account with a password and no list. The app migrates it; the extension never touches it.
    static func isLegacyPasswordItem(_ data: Data) -> Bool {
        guard let object = object(data) else { return false }
        return object["accounts"] == nil && object["password"] != nil
    }

    private static func key(_ entry: [String: Any]) -> String? {
        guard let url = entry["url"] as? String, let username = entry["username"] as? String else { return nil }
        return ShareRules.accountKey(url: url, username: username)
    }

    /// The item with `account`'s cookies replaced by `renewed`, only while that account is still saved (and still the
    /// current one) and still holds the cookies this share started from (`expected`): an app that renewed or signed out
    /// meanwhile wins. Nil means "write nothing".
    static func replacingCookies(in data: Data, account: String, expected: [[String: Any]], renewed: [[String: Any]]) -> Data? {
        guard !renewed.isEmpty, var object = object(data) else { return nil }
        func swap(_ entry: inout [String: Any]) -> Bool {
            let held = (entry["cookies"] as? [[String: Any]]) ?? []
            guard key(entry) == account, sameCookies(held, expected), !sameCookies(held, renewed) else { return false }
            entry["cookies"] = renewed
            return true
        }
        if var accounts = object["accounts"] as? [[String: Any]] {
            guard object["current"] as? String == account, let index = accounts.firstIndex(where: { key($0) == account }),
                  swap(&accounts[index]) else { return nil }
            object["accounts"] = accounts
        } else {
            guard object["accounts"] == nil, object["password"] == nil, swap(&object) else { return nil }
        }
        return try? JSONSerialization.data(withJSONObject: object)
    }

    /// The item with `account`'s Nous pair replaced by `renewed`, only while that account still holds `expected` (the
    /// pair the share spent). Nil means "write nothing".
    static func replacingNous(in data: Data, account: String, expected: ShareNous, renewed: ShareNous) -> Data? {
        guard var object = object(data), var accounts = object["accounts"] as? [[String: Any]],
              let index = accounts.firstIndex(where: { key($0) == account }),
              let held = ShareNous(accounts[index]["nous"]), held.samePair(expected) else { return nil }
        var entry = (accounts[index]["nous"] as? [String: Any]) ?? [:]
        for (name, value) in renewed.json { entry[name] = value }      // a field a later build adds survives
        if renewed.obtainedAt == nil { entry["obtainedAt"] = nil }
        accounts[index]["nous"] = entry
        object["accounts"] = accounts
        return try? JSONSerialization.data(withJSONObject: object)
    }

    /// Same session: the same cookie names and values (the gateway renews by issuing new values).
    static func sameCookies(_ a: [[String: Any]], _ b: [[String: Any]]) -> Bool {
        func pairs(_ list: [[String: Any]]) -> Set<String> {
            Set(list.map { "\($0["name"] as? String ?? "")=\($0["value"] as? String ?? "")" })
        }
        return pairs(a) == pairs(b)
    }

    /// `SavedCookie`'s JSON: the same keys, so the app decodes what the extension writes.
    static func encode(_ cookie: HTTPCookie) -> [String: Any] {
        var entry: [String: Any] = ["name": cookie.name, "value": cookie.value, "domain": cookie.domain, "path": cookie.path,
                                    "secure": cookie.isSecure, "httpOnly": cookie.isHTTPOnly]
        if let expires = cookie.expiresDate { entry["expires"] = expires.timeIntervalSince1970 }
        if let sameSite = cookie.sameSitePolicy { entry["sameSite"] = sameSite.rawValue }
        return entry
    }

    static func decode(_ entry: [String: Any]) -> HTTPCookie? {
        guard let name = entry["name"] as? String, let value = entry["value"] as? String,
              let domain = entry["domain"] as? String, let path = entry["path"] as? String else { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if let expires = (entry["expires"] as? NSNumber)?.doubleValue { properties[.expires] = Date(timeIntervalSince1970: expires) }
        if (entry["secure"] as? Bool) == true { properties[.secure] = "TRUE" }
        if (entry["httpOnly"] as? Bool) == true { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let sameSite = entry["sameSite"] as? String { properties[.sameSitePolicy] = HTTPCookieStringPolicy(rawValue: sameSite) }
        return HTTPCookie(properties: properties)
    }
}
