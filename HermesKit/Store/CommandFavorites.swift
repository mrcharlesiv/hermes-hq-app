// Favourite commands (docs/spec/3x-composer.md §9.7): the ones starred in the Commands sheet lead it and the slash
// drawer, in starred order. Kept on this phone per gateway account, as favourite models are (ModelPrefs), under
// "<key>|<account id>"; forgotten on Sign Out with the account's other caches. Main actor.

import Foundation

final class CommandFavorites {
    static let storageKey = "hq.favorite-commands"
    /// The most kept; starring past it lets the oldest go.
    static let limit = 50

    let accountId: String
    private let defaults: UserDefaults

    init(accountId: String, defaults: UserDefaults = .standard) {
        self.accountId = accountId
        self.defaults = defaults
    }

    private var key: String { "\(Self.storageKey)|\(accountId)" }

    /// Starred commands as "/name" (lower case), in starred order.
    var commands: [String] {
        (defaults.stringArray(forKey: key) ?? []).filter { !$0.isEmpty }
    }

    func contains(_ command: String) -> Bool { commands.contains(SlashCatalog.normalize(command)) }

    /// Star (it joins the end) or unstar a command.
    func toggle(_ command: String) {
        let name = SlashCatalog.normalize(command)
        guard name.count > 1 else { return }
        let current = commands
        set(current.contains(name) ? current.filter { $0 != name } : current + [name])
    }

    private func set(_ commands: [String]) {
        var seen = Set<String>()
        let next = Array(commands.filter { seen.insert($0).inserted }.suffix(Self.limit))
        if next.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(next, forKey: key) }
    }

    /// Forgets this account's (Sign Out).
    static func forget(accountId: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: "\(storageKey)|\(accountId)")
    }

    /// Forgets every account's (a clean first run, DEBUG reset).
    static func forgetAll(defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(storageKey + "|") {
            defaults.removeObject(forKey: key)
        }
    }
}
