// The bots the system's pickers offer (Shortcuts, Siri, the Action Button), and the voice note an older build left
// behind (docs/spec/3x-intents.md §3.2, §4, §8.1). Same UserDefaults keys and JSON as build 240
// (W:ios/App/App/VoiceNoteIntent.swift:7-15,42-46,95-98), so a shortcut saved under the web app still finds its bot
// after the update. Read off the main thread by the entity queries: nothing here touches app state.

import Foundation

/// One bot as the pickers know it (build 240's `VoiceNoteBot`, stored).
nonisolated struct VoiceBotRecord: Codable, Equatable, Sendable {
    /// `base64(account + "\n" + key)`.
    let id: String
    let name: String
    /// `"ios-direct::" + profile`.
    let key: String
    /// `url + "\n" + username`.
    let account: String
}

/// A recording builds 26–28 made in their own sheet and never attached. Native only reads and clears it.
nonisolated struct PendingVoiceNote: Codable, Equatable, Sendable {
    let id: String
    let bot: VoiceBotRecord
    let path: String
}

nonisolated enum VoiceBotCatalog {
    static let botsKey = "dispatch.voice.bots"
    static let pendingKey = "dispatch.voice.pending"
    static let keyPrefix = "ios-direct::"
    /// DECISION I4.
    static let maxBots = 512
    static let maxName = 160
    /// An id longer than this is nobody's (a url, a username and a key fit many times over).
    static let maxId = 4096

    // MARK: Formulas (§3.2: do not change one character)

    static func account(url: String, username: String) -> String { url + "\n" + username }
    static func key(profile: String) -> String { keyPrefix + profile }
    /// The profile a key names, nil for a key of another kind.
    static func profile(key: String) -> String? {
        guard key.hasPrefix(keyPrefix), key.count > keyPrefix.count else { return nil }
        return String(key.dropFirst(keyPrefix.count))
    }
    static func id(account: String, key: String) -> String { Data((account + "\n" + key).utf8).base64EncodedString() }

    /// Whether two `url\nusername` values name one account, however the address was written (a trailing "/", the
    /// host's case).
    static func sameAccount(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard let left = normalized(a), let right = normalized(b) else { return false }
        return left == right
    }

    private static func normalized(_ account: String) -> String? {
        guard let split = account.firstIndex(of: "\n") else { return nil }
        return GatewayAddress.accountKey(url: String(account[..<split]), username: String(account[account.index(after: split)...]))
    }

    /// A name as it is stored and shown: one line, no run of spaces, at most 160 characters; empty when nothing is left.
    static func clean(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return String(words.joined(separator: " ").prefix(maxName))
    }

    // MARK: The stored catalog

    static func bots(_ defaults: UserDefaults = .standard) -> [VoiceBotRecord] {
        guard let data = defaults.data(forKey: botsKey), data.count <= 1024 * 1024,
              let records = try? JSONDecoder().decode([VoiceBotRecord].self, from: data) else { return [] }
        return Array(records.prefix(maxBots))
    }

    /// Writes only when the bytes differ from what is stored. Returns whether it wrote.
    @discardableResult static func store(_ records: [VoiceBotRecord], _ defaults: UserDefaults = .standard) -> Bool {
        let encoder = JSONEncoder()
        // The same roster always gives the same bytes.
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Array(records.prefix(maxBots))) else { return false }
        if defaults.data(forKey: botsKey) == data { return false }
        defaults.set(data, forKey: botsKey)
        return true
    }

    /// The catalog's bot an entity id names: the stored id, or (carry-over from the web app, §3.2) the same account
    /// and key with the address written another way. The record handed back keeps the id that was asked for, which is
    /// what the system matches on, with the bot's current name.
    static func resolve(id: String, _ defaults: UserDefaults = .standard) -> VoiceBotRecord? {
        guard !id.isEmpty, id.utf8.count <= maxId else { return nil }
        let all = bots(defaults)
        if let exact = all.first(where: { $0.id == id }) { return exact }
        guard let data = Data(base64Encoded: id), let text = String(data: data, encoding: .utf8),
              let first = text.firstIndex(of: "\n") else { return nil }
        let rest = text[text.index(after: first)...]
        guard let second = rest.firstIndex(of: "\n") else { return nil }
        let url = String(text[..<first]), username = String(rest[..<second]), key = String(rest[rest.index(after: second)...])
        guard !url.isEmpty, !key.isEmpty else { return nil }
        let wanted = GatewayAddress.accountKey(url: url, username: username)
        guard let hit = all.first(where: { $0.key == key && normalized($0.account) == wanted }) else { return nil }
        return VoiceBotRecord(id: id, name: hit.name, key: hit.key, account: hit.account)
    }

    // MARK: The older build's saved note

    /// The saved note, nil when there is none. A value that is not one (edited storage) is cleared.
    static func pendingNote(_ defaults: UserDefaults = .standard) -> PendingVoiceNote? {
        guard let data = defaults.data(forKey: pendingKey) else {
            if defaults.object(forKey: pendingKey) != nil { clearPendingNote(defaults) }
            return nil
        }
        guard data.count <= 64 * 1024, let note = try? JSONDecoder().decode(PendingVoiceNote.self, from: data),
              !note.id.isEmpty, !note.bot.key.isEmpty else { clearPendingNote(defaults); return nil }
        return note
    }

    static func clearPendingNote(_ defaults: UserDefaults = .standard) { defaults.removeObject(forKey: pendingKey) }

    static func clear(_ defaults: UserDefaults = .standard) { defaults.removeObject(forKey: botsKey) }
}
