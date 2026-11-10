// The bots and chats a Home Screen quick action may open, most recent first, and the bots the system's pickers list
// (docs/spec/3x-intents.md §4, §9.2; a port of the web's sync in W:src/ui-voice/shortcuts.ts:25-46 and
// W:src/action-voice-runtime.ts:40-45). Pure: lists in, lists out.

import Foundation

nonisolated enum ShortcutCatalogBuilder {
    /// A bot's name as the pickers and the quick actions show it. Never empty: a name with nothing in it reads as
    /// "Hermes" for the default profile, else as the profile's own name.
    static func displayName(_ bot: Bot) -> String {
        let name = VoiceBotCatalog.clean(bot.name)
        if !name.isEmpty { return name }
        if bot.id == "default" { return "Hermes" }
        let profile = VoiceBotCatalog.clean(bot.id)
        return profile.isEmpty ? "Hermes" : profile
    }

    /// The pickers' bots, in roster order, hidden ones included (DECISION I4).
    static func botRecords(bots: [Bot], account: String) -> [VoiceBotRecord] {
        var seen = Set<String>()
        var records: [VoiceBotRecord] = []
        for bot in bots where !bot.id.isEmpty && seen.insert(bot.id).inserted {
            let key = VoiceBotCatalog.key(profile: bot.id)
            records.append(VoiceBotRecord(id: VoiceBotCatalog.id(account: account, key: key), name: displayName(bot), key: key, account: account))
            if records.count == VoiceBotCatalog.maxBots { break }
        }
        return records
    }

    /// Quick-action targets before the sign-in epoch is put in front of their ids: every bot, every listed chat that
    /// is not some bot's own chat, and `extra` (DECISION I7: rooms, when they exist), by last activity or visit, newest
    /// first, at most 128. `visits` and `extraActivity` are seconds since 1970 by target id.
    static func targets(bots: [Bot], sessions: [SessionSummary], visits: [String: Double], extra: [ShortcutTarget] = [],
                        extraActivity: [String: Double] = [:]) -> [ShortcutTarget] {
        var items: [(target: ShortcutTarget, at: Double, order: Int)] = []
        var canonical = Set<String>()
        var seen = Set<String>()
        func add(_ target: ShortcutTarget, _ at: Double) {
            guard seen.insert(target.id).inserted else { return }
            items.append((target, at.isFinite ? at : 0, items.count))
        }
        for bot in bots where !bot.id.isEmpty {
            let key = VoiceBotCatalog.key(profile: bot.id), id = "bot:" + key
            if let own = bot.canonicalSessionId, !own.isEmpty { canonical.insert(own) }
            add(ShortcutTarget(id: id, name: displayName(bot), kind: "bot", botKey: key),
                max(visits[id] ?? 0, bot.lastActive?.timeIntervalSince1970 ?? 0))
        }
        for row in sessions where !row.id.isEmpty && !canonical.contains(row.id) && !row.archived {
            let id = "session:" + row.id
            let title = VoiceBotCatalog.clean(row.title)
            add(ShortcutTarget(id: id, name: title.isEmpty ? IntentsText.untitledChat : title, kind: "session", sessionId: row.id),
                max(visits[id] ?? 0, row.lastActive?.timeIntervalSince1970 ?? 0))
        }
        for target in extra { add(target, max(visits[target.id] ?? 0, extraActivity[target.id] ?? 0)) }
        // Newest first; rows equally recent keep the order they came in.
        items.sort { $0.at != $1.at ? $0.at > $1.at : $0.order < $1.order }
        return items.prefix(ShortcutPolicy.maxTargets).map(\.target)
    }
}
