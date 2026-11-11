// Favourite models, recent models and per-model presets (spec 1x §2.3): the web app's three localStorage stores with
// the same keys and JSON formats, kept per gateway account (the web snapshots its whole storage per account). Stored
// in UserDefaults under "<web key>|<account id>"; forgotten on Sign Out with the account's other caches. Main actor.

import Foundation

/// A model as the menus show it (`TitleModel`, S:ui-chat/title-menu.ts:5).
nonisolated struct ModelChoice: Hashable, Sendable, Codable {
    var id: String
    var name: String
    var provider: String
    var providerName: String?

    /// The `provider::model` key favourites and presets use.
    var key: String { ModelPrefs.key(provider: provider, model: id) }
}

/// Reasoning and Fast remembered per model and re-applied when it is picked again (V:store/model-presets.ts).
nonisolated struct ModelPreset: Hashable, Sendable, Codable {
    var effort: String?
    var fast: Bool?
}

final class ModelPrefs {
    static let favoritesKey = "hermes.desktop.favorite-models"
    static let recentsKey = "dispatch.chat.recentModels"
    static let presetsKey = "hermes.desktop.model-presets"
    /// Ours, not the web's: the provider sections folded in the Models sheet.
    static let foldedKey = "hq.models.folded-providers"
    /// Ours: per profile, the provider slugs the last catalog read listed (the menus' stand-in before a chat's catalog loads).
    static let knownProvidersKey = "hq.models.known-providers"
    /// Ours: per profile, the starred keys the last catalog read didn't list (their model or provider is gone there).
    static let missingStarsKey = "hq.models.missing-stars"
    static let recentsLimit = 3

    let accountId: String
    private let defaults: UserDefaults

    init(accountId: String, defaults: UserDefaults = .standard) {
        self.accountId = accountId
        self.defaults = defaults
    }

    nonisolated static func key(provider: String, model: String) -> String { "\(provider)::\(model)" }

    private func storageKey(_ web: String) -> String { "\(web)|\(accountId)" }

    // MARK: Favourites (S:favorite-models.ts)

    /// Starred `provider::model` keys, in starred order.
    var favorites: [String] {
        guard let data = defaults.data(forKey: storageKey(Self.favoritesKey)),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return rows.compactMap { ($0 as? String).flatMap { $0.isEmpty ? nil : $0 } }
    }

    func setFavorites(_ keys: [String]) {
        var seen = Set<String>()
        let next = keys.filter { seen.insert($0).inserted }
        if next.isEmpty {
            defaults.removeObject(forKey: storageKey(Self.favoritesKey))
        } else if let data = try? JSONSerialization.data(withJSONObject: next) {
            defaults.set(data, forKey: storageKey(Self.favoritesKey))
        }
    }

    /// Star (it joins the end) or unstar a model.
    func toggleFavorite(provider: String, model: String) {
        let key = Self.key(provider: provider, model: model)
        let current = favorites
        setFavorites(current.contains(key) ? current.filter { $0 != key } : current + [key])
    }

    func isFavorite(_ model: ModelChoice) -> Bool { favorites.contains(model.key) }

    // MARK: Folded providers (tester 2026-11-09)

    /// The provider slugs whose sections the Models sheet shows folded to their heading.
    var foldedProviders: Set<String> {
        Set((defaults.array(forKey: storageKey(Self.foldedKey)) as? [String] ?? []).filter { !$0.isEmpty })
    }

    func setFoldedProviders(_ providers: Set<String>) {
        if providers.isEmpty {
            defaults.removeObject(forKey: storageKey(Self.foldedKey))
        } else {
            defaults.set(providers.sorted(), forKey: storageKey(Self.foldedKey))
        }
    }

    // MARK: Known providers (tester 2026-11-09)

    /// [stale-stars] The providers `profile`'s last catalog listed; nil before one was read. A new chat's Switch Model
    /// menu is drawn before its own catalog loads, and listed every star then, a removed provider's too ("annoying to
    /// have to wait in every new session"); these keep those out until the catalog answers.
    func knownProviders(profile: String) -> Set<String>? {
        guard let all = defaults.dictionary(forKey: storageKey(Self.knownProvidersKey)),
              let slugs = all[profile] as? [String] else { return nil }
        return Set(slugs)
    }

    func setKnownProviders(_ slugs: Set<String>, profile: String) {
        var all = defaults.dictionary(forKey: storageKey(Self.knownProvidersKey)) ?? [:]
        let next = slugs.sorted()
        if all[profile] as? [String] == next { return }
        all[profile] = next
        defaults.set(all, forKey: storageKey(Self.knownProvidersKey))
    }

    /// [ghost-stars] A provider removed in Settings › Providers: no profile lists it from now, before any catalog is
    /// read again (the catalogs in memory still do until then).
    func removeKnownProvider(_ slug: String) {
        guard var all = defaults.dictionary(forKey: storageKey(Self.knownProvidersKey)) else { return }
        var changed = false
        for (profile, value) in all {
            guard let slugs = value as? [String], slugs.contains(slug) else { continue }
            all[profile] = slugs.filter { $0 != slug }
            changed = true
        }
        if changed { defaults.set(all, forKey: storageKey(Self.knownProvidersKey)) }
    }

    // MARK: Missing stars (tester 2026-11-10)

    /// [ghost-stars] The starred keys `profile`'s last catalog didn't list: a model its provider dropped, or a provider
    /// that is gone. The known providers alone left a kept provider's dropped models in every new chat's menu until
    /// the chat's own catalog answered.
    func missingStars(profile: String) -> Set<String> {
        Set((defaults.dictionary(forKey: storageKey(Self.missingStarsKey))?[profile] as? [String]) ?? [])
    }

    func setMissingStars(_ keys: Set<String>, profile: String) {
        var all = defaults.dictionary(forKey: storageKey(Self.missingStarsKey)) ?? [:]
        let next = keys.sorted()
        if (all[profile] as? [String] ?? []) == next { return }
        all[profile] = next.isEmpty ? nil : next
        if all.isEmpty {
            defaults.removeObject(forKey: storageKey(Self.missingStarsKey))
        } else {
            defaults.set(all, forKey: storageKey(Self.missingStarsKey))
        }
    }

    /// [stale-stars] Settings › Clear Favorite & Recent Models (tester 2026-11-09: a removed provider's stars
    /// can't be unstarred, since no list shows its models any more).
    func clearFavoritesAndRecents() {
        defaults.removeObject(forKey: storageKey(Self.favoritesKey))
        defaults.removeObject(forKey: storageKey(Self.recentsKey))
        defaults.removeObject(forKey: storageKey(Self.missingStarsKey))
    }

    // MARK: Recents (S:ui-chat/title-menu.ts:59-76)

    /// Newest first, at most three; malformed rows are dropped.
    var recents: [ModelChoice] {
        guard let data = defaults.data(forKey: storageKey(Self.recentsKey)),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        let valid: [ModelChoice] = rows.compactMap { row in
            guard let o = row as? [String: Any], let id = o["id"] as? String, let name = o["name"] as? String,
                  let provider = o["provider"] as? String else { return nil }
            if let pn = o["providerName"], !(pn is String) { return nil }
            return ModelChoice(id: id, name: name, provider: provider, providerName: o["providerName"] as? String)
        }
        return Array(valid.prefix(Self.recentsLimit))
    }

    /// `remember(m)`: newest first, the same id+provider once, three at most.
    func remember(_ model: ModelChoice) {
        let next = [model] + recents.filter { $0.id != model.id || $0.provider != model.provider }
        let rows: [[String: Any]] = next.prefix(Self.recentsLimit).map { m in
            var o: [String: Any] = ["id": m.id, "name": m.name, "provider": m.provider]
            if let pn = m.providerName { o["providerName"] = pn }
            return o
        }
        if let data = try? JSONSerialization.data(withJSONObject: rows) { defaults.set(data, forKey: storageKey(Self.recentsKey)) }
    }

    // MARK: Presets (V:store/model-presets.ts:9-53)

    private var allPresets: [String: ModelPreset] {
        guard let data = defaults.data(forKey: storageKey(Self.presetsKey)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: ModelPreset] = [:]
        for (key, value) in object {
            guard let o = value as? [String: Any] else { continue }
            out[key] = ModelPreset(effort: o["effort"] as? String, fast: o["fast"] as? Bool)
        }
        return out
    }

    func preset(provider: String, model: String) -> ModelPreset {
        allPresets[Self.key(provider: provider, model: model)] ?? ModelPreset()
    }

    /// Merge-patch one model's preset (`nil` fields leave the stored value).
    func setPreset(provider: String, model: String, _ patch: ModelPreset) {
        var all = allPresets
        let key = Self.key(provider: provider, model: model)
        var merged = all[key] ?? ModelPreset()
        if let effort = patch.effort { merged.effort = effort }
        if let fast = patch.fast { merged.fast = fast }
        all[key] = merged
        writePresets(all)
    }

    /// Replaces one model's preset as a whole (a rollback).
    func replacePreset(provider: String, model: String, _ preset: ModelPreset) {
        var all = allPresets
        all[Self.key(provider: provider, model: model)] = preset
        writePresets(all)
    }

    private func writePresets(_ all: [String: ModelPreset]) {
        var object: [String: Any] = [:]
        for (key, preset) in all {
            var o: [String: Any] = [:]
            if let effort = preset.effort { o["effort"] = effort }
            if let fast = preset.fast { o["fast"] = fast }
            object[key] = o
        }
        if let data = try? JSONSerialization.data(withJSONObject: object) { defaults.set(data, forKey: storageKey(Self.presetsKey)) }
    }

    // MARK: Sign Out

    /// Forgets every account's stores (a clean first run, DEBUG reset).
    static func forgetAll(defaults: UserDefaults = .standard) {
        let webKeys = [favoritesKey, recentsKey, presetsKey, foldedKey, knownProvidersKey, missingStarsKey]
        for key in defaults.dictionaryRepresentation().keys where webKeys.contains(where: { key.hasPrefix($0 + "|") }) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Forgets this account's stores (Sign Out).
    static func forget(accountId: String, defaults: UserDefaults = .standard) {
        for web in [favoritesKey, recentsKey, presetsKey, foldedKey, knownProvidersKey, missingStarsKey] { defaults.removeObject(forKey: "\(web)|\(accountId)") }
    }
}
