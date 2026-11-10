// What a Home Screen quick action or a legacy shortcut may open (docs/spec/3x-intents.md §6, §9). `accountDigest`,
// `legacyMemoBotKey`, `catalog` and `permits` are build 240's `DispatchShortcutPolicy`, line for line
// (W:ios/App/App/HermesUIPages.swift:186-217); the storage half is its `DispatchShortcuts`, minus UIKit. Same
// UserDefaults keys as the web app: items and legacy entity ids embed the sign-in epoch, and they must survive the
// update.

import CryptoKit
import Foundation

nonisolated struct ShortcutTarget: Codable, Equatable, Sendable {
    let id: String
    let name: String
    /// "bot", "session" or "room".
    let kind: String
    let sessionId: String?
    let botKey: String?
    let group: String?

    init(id: String, name: String, kind: String, sessionId: String? = nil, botKey: String? = nil, group: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.sessionId = sessionId; self.botKey = botKey; self.group = group
    }
}

nonisolated enum ShortcutPolicy {
    static let catalogKey = "dispatch.shortcut.catalog"
    static let accountKey = "dispatch.shortcut.account"
    static let epochKey = "dispatch.shortcut.epoch"
    static let maxTargets = 128
    static let maxBytes = 128 * 1024

    // MARK: Build 240's policy (do not reword)

    static func accountDigest(url: String, username: String) -> String {
        SHA256.hash(data: Data((url + "\u{0}" + username).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Build 26's memo action saved `epoch:bot:<roster key>` identities. They resolve against the current voice
    /// catalog, never by display name, and only within the same signed-in epoch and account.
    static func legacyMemoBotKey(id: String, epoch: String?, botAccount: String, currentAccountDigest: String?) -> String? {
        guard let epoch, !epoch.isEmpty, id.hasPrefix(epoch + ":bot:"),
              let split = botAccount.firstIndex(of: "\n"), let currentAccountDigest,
              accountDigest(url: String(botAccount[..<split]), username: String(botAccount[botAccount.index(after: split)...])) == currentAccountDigest
        else { return nil }
        let key = String(id.dropFirst((epoch + ":bot:").count))
        return !key.isEmpty && key.count <= 512 ? key : nil
    }

    static func catalog(_ rows: [ShortcutTarget], epoch: String, validSession: (String) -> Bool) -> [ShortcutTarget] {
        guard !epoch.isEmpty else { return [] }
        var ids = Set<String>()
        return Array(rows.filter { row in
            guard !row.id.isEmpty, row.id.count <= 512, !row.name.isEmpty, row.name.count <= 160,
                  ["bot", "session", "room"].contains(row.kind), ids.insert(row.id).inserted else { return false }
            if row.kind == "session" { return row.sessionId.map(validSession) ?? false }
            if row.kind == "bot" { return !(row.botKey ?? "").isEmpty && (row.botKey?.count ?? 0) <= 512 }
            return !(row.group ?? "").isEmpty && (row.group?.count ?? 0) <= 160
        }.prefix(maxTargets)).map { row in
            ShortcutTarget(id: epoch + ":" + row.id, name: row.name, kind: row.kind, sessionId: row.sessionId, botKey: row.botKey, group: row.group)
        }
    }

    static func permits(_ action: String, id: String, epoch: String?, current: String?, targets: [ShortcutTarget]) -> Bool {
        guard let current, !current.isEmpty, epoch == nil || epoch == current,
              ["open", "memo", "search"].contains(action) else { return false }
        if action == "search" { return true }
        guard let target = targets.first(where: { $0.id == id && $0.id.hasPrefix(current + ":") }) else { return false }
        return action != "memo" || target.kind == "bot"
    }

    // MARK: Stored values

    static func targets(_ defaults: UserDefaults = .standard) -> [ShortcutTarget] {
        guard let data = defaults.data(forKey: catalogKey), data.count <= maxBytes,
              let rows = try? JSONDecoder().decode([ShortcutTarget].self, from: data) else { return [] }
        return Array(rows.prefix(maxTargets))
    }

    /// The sign-in epoch: a UUID made when the signed-in account's digest changes. Items and legacy ids from an
    /// earlier sign-in carry another and are refused.
    static func epoch(_ defaults: UserDefaults = .standard) -> String? {
        // (`string(forKey:)` would turn a number into text: only a stored string is an epoch.)
        guard let value = defaults.object(forKey: epochKey) as? String, !value.isEmpty, value.count <= 128 else { return nil }
        return value
    }

    static func digest(_ defaults: UserDefaults = .standard) -> String? {
        guard let value = defaults.object(forKey: accountKey) as? String, !value.isEmpty, value.count <= 128 else { return nil }
        return value
    }

    /// The ways one address may have been written by the build that stored the digest (§3.2, carry-over from the web
    /// app): as stored, with and without a trailing "/", and with the scheme and host lower-cased.
    static func addressForms(_ url: String) -> [String] {
        var forms: [String] = []
        func add(_ value: String) { if !forms.contains(value) { forms.append(value) } }
        var bare = url
        while bare.hasSuffix("/") { bare.removeLast() }
        var lowered = bare
        if var parts = URLComponents(string: bare) {
            parts.scheme = parts.scheme?.lowercased()
            if let host = parts.percentEncodedHost { parts.percentEncodedHost = host.lowercased() }
            lowered = parts.string ?? bare
        }
        while lowered.hasSuffix("/") { lowered.removeLast() }
        for form in [url, bare, bare + "/", lowered, lowered + "/"] { add(form) }
        return forms
    }

    enum Activation: Sendable, Equatable {
        /// The account on record, however its address was written: its digest and its epoch are kept.
        case same
        /// Nothing was on record.
        case first
        /// Another account was on record: the catalog, digest and epoch were replaced. The caller clears what else
        /// belonged to the old account.
        case changed
    }

    /// The signed-in account (called on every activation).
    @discardableResult static func activate(url: String, username: String, _ defaults: UserDefaults = .standard) -> Activation {
        let stored = digest(defaults)
        if let stored, epoch(defaults) != nil,
           addressForms(url).contains(where: { accountDigest(url: $0, username: username) == stored }) { return .same }
        clear(defaults)
        defaults.set(accountDigest(url: url, username: username), forKey: accountKey)
        defaults.set(UUID().uuidString, forKey: epochKey)
        return stored == nil ? .first : .changed
    }

    static func clear(_ defaults: UserDefaults = .standard) {
        for key in [catalogKey, accountKey, epochKey] { defaults.removeObject(forKey: key) }
    }

    /// The encoded catalog when it should be written: nil when it is over the size limit or already what is stored.
    static func encoded(_ safe: [ShortcutTarget], _ defaults: UserDefaults = .standard) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(safe), data.count <= maxBytes, data != defaults.data(forKey: catalogKey) else { return nil }
        return data
    }

    // MARK: Legacy shortcut ids (§6)

    /// The catalog bot a legacy entity id (`epoch + ":bot:" + key`) names, in this sign-in only.
    static func legacyBot(id: String, _ defaults: UserDefaults = .standard) -> VoiceBotRecord? {
        guard !id.isEmpty, id.utf8.count <= VoiceBotCatalog.maxId, let epoch = epoch(defaults), let stored = digest(defaults) else { return nil }
        return VoiceBotCatalog.bots(defaults).first { bot in
            guard let split = bot.account.firstIndex(of: "\n") else { return false }
            let username = String(bot.account[bot.account.index(after: split)...])
            // The stored digest may be of the address as the web app wrote it.
            return addressForms(String(bot.account[..<split])).contains { form in
                legacyMemoBotKey(id: id, epoch: epoch, botAccount: form + "\n" + username, currentAccountDigest: stored) == bot.key
            }
        }
    }

    /// What the legacy intents' picker lists: one id per catalog bot that resolves in this sign-in.
    static func legacyEntities(_ defaults: UserDefaults = .standard) -> [(id: String, name: String)] {
        guard let epoch = epoch(defaults) else { return [] }
        return VoiceBotCatalog.bots(defaults).compactMap { bot in
            let id = epoch + ":bot:" + bot.key
            return legacyBot(id: id, defaults) != nil ? (id, bot.name) : nil
        }
    }
}
