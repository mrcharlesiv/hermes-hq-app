// Sealed alerts (port of the web app's ios/App/Shared/DispatchSeal.swift, build 240). Compiled into the app and the
// notification extension. The hermes-hq-push plugin seals each alert with a key this phone made and gave only to its
// own gateway (AES-256-GCM), so Apple and the push relay carry a box they can't open: the visible alert says only
// "Hermes HQ: New notification". Byte for byte as gateway-plugin/hermes-hq-push/push.py seals them (seal-vectors.json).
// Nothing here logs: alert words, keys and tokens never reach AppLog.

import CryptoKit
import Foundation
import Security

nonisolated enum PushSeal {
    static let aad = Data("dispatch-push seal v1".utf8)

    static func makeKey() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

    /// Which key a box names: the first 8 bytes of the key's SHA-256, in hex.
    static func kid(_ key: Data) -> String { SHA256.hash(data: key).prefix(8).map { String(format: "%02x", $0) }.joined() }

    /// The payload inside a pushed seal, or nil: not sealed, sealed with a key this phone doesn't hold, or tampered with.
    static func open(_ userInfo: [AnyHashable: Any], keys: [Data]) -> [String: Any]? {
        guard let seal = userInfo["seal"] as? [String: Any], (seal["v"] as? NSNumber)?.intValue == 1,
              let kid = seal["kid"] as? String, let box = (seal["box"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let key = keys.first(where: { self.kid($0) == kid }),
              let sealed = try? AES.GCM.SealedBox(combined: box),
              let plain = try? AES.GCM.open(sealed, using: SymmetricKey(data: key), authenticating: aad) else { return nil }
        return (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any]
    }

    /// A push as the app reads it: an opened seal's `aps` and `dispatch` in place of the seal, else as it came.
    static func opened(_ userInfo: [AnyHashable: Any], keys: [Data]) -> [AnyHashable: Any] {
        guard let inner = open(userInfo, keys: keys) else { return userInfo }
        var info = userInfo
        info["seal"] = nil
        for (key, value) in inner { info[key] = value }
        return info
    }

    /// What the extension shows from an opened alert.
    struct Alert: Equatable {
        var title = "", subtitle = "", body = "", thread = "", category = ""
        var relevance: Double?
    }

    /// Why a sealed push couldn't be opened: "noKey" when no key here names it, else "unreadable".
    static func failure(_ userInfo: [AnyHashable: Any], keys: [Data]) -> String {
        guard let kid = (userInfo["seal"] as? [String: Any])?["kid"] as? String, keys.contains(where: { self.kid($0) == kid }) else { return "noKey" }
        return "unreadable"
    }

    static func alert(_ inner: [String: Any]) -> Alert? {
        guard let aps = inner["aps"] as? [String: Any], let alert = aps["alert"] as? [String: Any] else { return nil }
        return Alert(title: alert["title"] as? String ?? "", subtitle: alert["subtitle"] as? String ?? "", body: alert["body"] as? String ?? "",
                     thread: aps["thread-id"] as? String ?? "", category: aps["category"] as? String ?? "",
                     relevance: (aps["relevance-score"] as? NSNumber)?.doubleValue)
    }
}

/// The seal keys, one per gateway account this phone registered (PushPolicy.owner). Same Keychain service as the web app
/// (an update keeps registrations working), the app's own access group which the extension lists in its
/// keychain-access-groups; readable after first unlock (alerts arrive on a locked phone), never synced.
nonisolated enum PushSealKeys {
    static let service = "ai.hermes.ios.push-seal"

    /// This account's key, made on first use. Nil only if Keychain refuses (the registration then goes without one).
    static func key(for account: String) -> Data? {
        if let existing = read(account) { return existing }
        let key = PushSeal.makeKey()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: account, kSecValueData as String: key,
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem { return read(account) }
        return status == errSecSuccess ? key : nil
    }

    static func all() -> [Data] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return [] }
        return (result as? [Data]) ?? []
    }

    /// Keychain can't be read yet (the phone hasn't been unlocked since it started).
    static func locked() -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecInteractionNotAllowed
    }

    static func remove(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }

    private static func read(_ account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data, data.count == 32 else { return nil }
        return data
    }
}

/// What the notification extension did with each push, as counts (Settings › Notifications shows them): opened; no key
/// here; Keychain still locked after a restart; unreadable; not sealed; out of time; opened without a saved face. Counts
/// and the last time only, never a payload. Same Keychain item as the web app (`ai.hermes.ios.push-diagnostics`).
nonisolated enum PushAlertDiagnostics {
    static let service = "ai.hermes.ios.push-diagnostics"
    private static var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "counts"]
    }

    /// Pure: `counts` with one more `outcome` at `at` (ms since 1970).
    static func adding(_ outcome: String, at: Double, to counts: [String: Double]) -> [String: Double] {
        var next = counts
        next[outcome, default: 0] += 1
        next[outcome + "LastAt"] = at
        return next
    }

    static func merged(_ a: [String: Double], _ b: [String: Double]) -> [String: Double] {
        a.merging(b) { old, new in old > 1_000_000_000 || new > 1_000_000_000 ? max(old, new) : old + new }
    }

    static func counts() -> [String: Double] {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let counts = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return counts
    }

    private static var pending: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("dispatch-alert-diagnostics.json")
    }

    static func record(_ outcome: String) {
        let now = Date().timeIntervalSince1970 * 1000
        var waiting: [String: Double] = [:]
        if let pending, let data = try? Data(contentsOf: pending) { waiting = (try? JSONDecoder().decode([String: Double].self, from: data)) ?? [:] }
        let next = merged(counts(), adding(outcome, at: now, to: waiting))
        guard let data = try? JSONEncoder().encode(next) else { return }
        var status = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = item
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status == errSecSuccess { if let pending { try? FileManager.default.removeItem(at: pending) }; return }
        // Locked: kept for later in a file readable before the first unlock (it holds only counts).
        if let pending, let saved = try? JSONEncoder().encode(adding(outcome, at: now, to: waiting)) {
            try? saved.write(to: pending, options: [.atomic, .noFileProtection])
        }
    }
}
