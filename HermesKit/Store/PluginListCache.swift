// [load-cache] Each bot's add-on list (`plugins.manage list`), kept on disk so the launch's add-on check
// (PushSetupOffer.botsWithout) doesn't ask every bot again on every cold launch. Hermes answers that list on its RPC
// pool (8 workers, shared with session.resume, profiles.list and projects.tree), at ~0.6-1 s of work each; eleven at
// once filled the pool for 6-10 s after each launch, and the chat being opened waited behind them (the owner's phone,
// 2026-10-30/31: session.resume 161 ms → 5.4 s median, profiles.list 451 ms → 6.9 s).
// Kept in Application Support/pages/<account key>/plugin-lists.json (PagesCache: removed on sign-out and gateway
// removal) for `keep`; a list the app changed (install, update, remove, toggle, settings) is forgotten at once.

import Foundation

@MainActor final class PluginListCache {
    static let shared = PluginListCache()
    /// How long a bot's list stands in for asking again.
    nonisolated static let keep: TimeInterval = 6 * 3600
    nonisolated static let fileName = "plugin-lists.json"

    /// What the add-on check needs from one row of a list.
    nonisolated struct Plugin: Codable, Sendable, Equatable {
        var name: String
        var version: String
        var enabled: Bool
    }

    nonisolated struct Entry: Codable, Sendable, Equatable {
        /// When the list was read (ms since the epoch).
        var at: Double
        var plugins: [Plugin]
    }

    private let root: URL
    private let now: () -> Date
    /// Account key → profile → entry, read from disk on the account's first use.
    private var accounts: [String: [String: Entry]] = [:]

    init(root: URL = PagesCache.root, now: @escaping () -> Date = { Date() }) {
        self.root = root
        self.now = now
    }

    private func url(_ account: GatewayAccount) -> URL {
        PagesCache.directory(for: account, root: root).appending(path: Self.fileName)
    }

    private func entries(_ account: GatewayAccount) -> [String: Entry] {
        let key = RosterDisk.accountKey(account)
        if let loaded = accounts[key] { return loaded }
        let read = PagesCache.read([String: Entry].self, url(account)) ?? [:]
        accounts[key] = read
        return read
    }

    private func save(_ entries: [String: Entry], _ account: GatewayAccount) {
        accounts[RosterDisk.accountKey(account)] = entries
        PagesCache.write(entries, to: url(account))
    }

    /// The bot's list if it was read within `keep` (a time ahead of the clock counts as stale).
    func entry(account: GatewayAccount, profile: String) -> Entry? {
        guard let entry = entries(account)[profile] else { return nil }
        let age = now().timeIntervalSince1970 - entry.at / 1000
        return age >= 0 && age < Self.keep ? entry : nil
    }

    func store(_ plugins: [PluginInfo], account: GatewayAccount, profile: String) {
        var all = entries(account)
        // [load-cache] Down, not to the nearest: rounded up, a list read back within half a millisecond was "ahead of the
        // clock", so stale (LoadCacheTests failed now and then).
        all[profile] = Entry(at: (now().timeIntervalSince1970 * 1000).rounded(.down),
                             plugins: plugins.map { Plugin(name: $0.name, version: $0.version, enabled: $0.enabled) })
        save(all, account)
    }

    /// The app changed this bot's add-ons: its next check asks again.
    func forget(account: GatewayAccount, profile: String) {
        var all = entries(account)
        guard all.removeValue(forKey: profile) != nil else { return }
        save(all, account)
    }

    /// Sign-out or gateway removal (PagesCache.purge removes the file).
    func forget(account: GatewayAccount) {
        accounts[RosterDisk.accountKey(account)] = nil
    }
}
