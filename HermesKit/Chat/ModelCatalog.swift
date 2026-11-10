// The gateway's model catalog (`model.options`, spec 1x §3.1): decoding, provider matching, capabilities, the 30 s
// in-memory cache, and the Models sheet's sections (S:ui-chat/model-sheet.tsx:18-35).

import Foundation

nonisolated struct ModelCapabilities: Hashable, Sendable {
    var fast: Bool?
    var reasoning: Bool?
    var canDisableReasoning: Bool?
}

nonisolated struct ModelProviderRow: Hashable, Sendable {
    var slug: String
    var name: String
    var models: [String]
    var aliases: [String]
    var capabilities: [String: ModelCapabilities]
    /// False for a provider listed but not signed in (only with `include_unconfigured`); nil when the gateway says nothing.
    var authenticated: Bool? = nil
    /// ⋯ › Model Prices: the gateway's $/Mtok per model (`ModelPricing`); empty when it knows none.
    var pricing: [String: ModelPrice] = [:]
    /// Nous before its prices are cached (`pricing_pending`): asked again, they come.
    var pricingPending = false
    /// ⋯ › Usage & Limits: subscription windows (`ProviderUsage`), a usage-window plan (`PlanUsage`), a rate limit.
    var usage: ProviderUsage? = nil
    var plan: PlanUsage? = nil
    var limit: ProviderLimit? = nil
    /// [provider-manager] The owner's own name for this provider and its models (`ProviderPrefs`, set by
    /// `ModelOptions.applying`): the menus show them; the ids stay as they are.
    var customName: String? = nil
    var modelNames: [String: String] = [:]

    /// A row matches a slug by slug, display name, or alias (V:lib/model-options.ts:10-20).
    func matches(_ provider: String) -> Bool {
        guard !provider.isEmpty else { return false }
        return slug == provider || name == provider || aliases.contains(provider)
    }
}

/// `ModelOptionsResult` (only the fields the menus read).
nonisolated struct ModelOptions: Hashable, Sendable {
    var providers: [ModelProviderRow]
    var model: String
    var provider: String

    init(providers: [ModelProviderRow], model: String = "", provider: String = "") {
        self.providers = providers; self.model = model; self.provider = provider
    }

    init(json: JSONValue) {
        model = json["model"]?.string ?? ""
        provider = json["provider"]?.string ?? ""
        providers = (json["providers"]?.array ?? []).compactMap { row in
            guard let slug = row["slug"]?.string else { return nil }
            var caps: [String: ModelCapabilities] = [:]
            for (id, value) in row["capabilities"]?.object ?? [:] {
                caps[id] = ModelCapabilities(fast: value["fast"]?.bool, reasoning: value["reasoning"]?.bool,
                                             canDisableReasoning: value["can_disable_reasoning"]?.bool)
            }
            var out = ModelProviderRow(slug: slug, name: row["name"]?.string ?? "",
                                       models: (row["models"]?.array ?? []).compactMap(\.string),
                                       aliases: (row["aliases"]?.array ?? []).compactMap(\.string), capabilities: caps)
            out.authenticated = row["authenticated"]?.bool
            for (id, value) in row["pricing"]?.object ?? [:] {
                if let price = ModelPrice(json: value) { out.pricing[id] = price }
            }
            out.pricingPending = row["pricing_pending"]?.bool ?? false
            out.usage = ProviderUsage(json: row["usage"])
            out.plan = PlanUsage(json: row["plan_usage"])
            out.limit = ProviderLimit(json: row["limit"])
            return out
        }
    }

    func row(matching provider: String) -> ModelProviderRow? { providers.first { $0.matches(provider) } }

    /// The catalog's capabilities for a pick, nil while it doesn't say (callers then assume reasoning).
    func capabilities(provider: String, model: String) -> ModelCapabilities? {
        row(matching: provider)?.capabilities[model]
    }

    /// A model as the menus show it (`describe`, S:ui-chat/title-menu.ts:152-156).
    func describe(id: String, provider: String) -> ModelChoice {
        ModelOptions.describe(id: id, provider: provider, row: row(matching: provider))
    }

    static func describe(id: String, provider: String, row: ModelProviderRow?) -> ModelChoice {
        // [provider-manager] The owner's names first (the row's, set by `applying`, else the account's own copy when the
        // catalog isn't cached yet), typed as they were (no bracket trimming).
        let prefs = row == nil ? ProviderPrefs.active : nil
        let slug = row?.slug ?? provider
        let display = row?.modelNames[id] ?? prefs?.modelName(provider: slug, model: id) ?? ModelNames.displayModelName(id)
        let rowName = row?.name ?? ""
        let fallback = ModelNames.providerDisplayName(provider)
        let source = !rowName.isEmpty ? rowName : (!fallback.isEmpty ? fallback : provider)
        let own = row?.customName ?? prefs?.providerName(slug)
        return ModelChoice(id: id, name: display.isEmpty ? "Model" : display, provider: slug,
                           providerName: own ?? ModelNames.plainProviderName(source))
    }

    /// Every catalog model, in catalog order.
    var choices: [ModelChoice] {
        providers.flatMap { row in row.models.map { ModelOptions.describe(id: $0, provider: row.slug, row: row) } }
    }
}

/// One provider's rows in the Models sheet.
nonisolated struct ModelSection: Hashable, Sendable {
    var provider: String        // "" for Favorites
    var title: String
    var models: [ModelChoice]
}

nonisolated enum ModelSheetModel {
    /// The catalog by provider, filtered by `query` (`modelSections`): one row per id or display name within a
    /// provider; the chat's current model wins its name's place.
    static func sections(_ models: [ModelChoice], query: String, current: (id: String, provider: String)?) -> [ModelSection] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        func isCurrent(_ m: ModelChoice) -> Bool { current.map { m.id == $0.id && m.provider == $0.provider } ?? false }
        var order: [String] = []
        var sections: [String: (title: String, models: [ModelChoice], twins: [String: Int])] = [:]
        for model in models {
            if !words.isEmpty {
                let text = "\(model.id) \(model.name) \(model.provider) \(model.providerName ?? "")".lowercased()
                if !words.allSatisfy({ text.contains($0) }) { continue }
            }
            if sections[model.provider] == nil {
                order.append(model.provider)
                let title = (model.providerName ?? "").isEmpty ? model.provider : (model.providerName ?? "")
                sections[model.provider] = (title, [], [:])
            }
            guard var section = sections[model.provider] else { continue }
            let nameKey = "name:" + model.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let twin = section.twins["id:" + model.id] ?? section.twins[nameKey] {
                if isCurrent(model) && !isCurrent(section.models[twin]) { section.models[twin] = model }
            } else {
                section.twins["id:" + model.id] = section.models.count
                section.twins[nameKey] = section.models.count
                section.models.append(model)
            }
            sections[model.provider] = section
        }
        return order.compactMap { key in sections[key].map { ModelSection(provider: key, title: $0.title, models: $0.models) } }
    }

    /// The catalog's rows for the starred keys, in starred order; a star the catalog lacks shows nothing.
    static func favoriteRows(_ models: [ModelChoice], keys: [String]) -> [ModelChoice] {
        var byKey: [String: ModelChoice] = [:]
        for m in models where byKey[m.key] == nil { byKey[m.key] = m }
        return keys.compactMap { byKey[$0] }
    }

    /// Favourites before a catalog is cached: each `provider::model` key described from the key alone.
    static func favoritesFromKeys(_ keys: [String]) -> [ModelChoice] {
        keys.compactMap { key in
            guard let at = key.range(of: "::"), at.lowerBound > key.startIndex else { return nil }
            return ModelOptions.describe(id: String(key[at.upperBound...]), provider: String(key[..<at.lowerBound]), row: nil)
        }
    }
}

// MARK: - Cache (spec 1x §3.1: memory only, fresh for 30 s)

@MainActor final class ModelCatalogCache {
    static let shared = ModelCatalogCache()

    struct Key: Hashable {
        var account: String
        var profile: String
        /// The runtime id, or "global".
        var scope: String
    }

    private struct Entry {
        var options: ModelOptions
        var at: ContinuousClock.Instant
        var stale = false
    }

    private var entries: [Key: Entry] = [:]
    /// Keys whose one ⋯ warm-up already ran in this app run (spec 1x §3.1 ⚑ DECISION).
    private var warmed: Set<Key> = []
    static let freshFor: Duration = .seconds(30)

    /// A profile's own reasoning default (`agent.reasoning_effort` in its config.yaml, the web's
    /// `$defaultReasoningEffort`), per account and profile: a pick with no saved preset applies it, never Hermes' built-in
    /// medium over the user's config (V:app/session/hooks/use-hermes-config.ts:105-114).
    struct ProfileKey: Hashable {
        var account: String
        var profile: String
    }

    private var profileEfforts: [ProfileKey: (value: String, at: ContinuousClock.Instant)] = [:]
    /// Read again after this long (the owner may edit config.yaml); the old value still answers meanwhile.
    static let profileEffortFreshFor: Duration = .seconds(300)

    /// [m9/composer] Keys whose last catalog read failed (both tries): the ⋯ › Model submenu says so.
    private var failedKeys: Set<Key> = []
    func loadFailed(_ key: Key) -> Bool { failedKeys.contains(key) }
    func setLoadFailed(_ failed: Bool, for key: Key) { if failed { failedKeys.insert(key) } else { failedKeys.remove(key) } }

    /// [provider-manager] The catalog as the menus show it (`ModelOptions.applying` the account's `ProviderPrefs`): the
    /// gateway's answer is kept as it came, and the shown copy is made again when the names or short lists change.
    func cached(_ key: Key) -> ModelOptions? { entries[key].map { shown($0, key) } }

    /// [stale-stars] The newest catalog cached for another chat of the same account and profile (a new chat has none of
    /// its own until its read answers): the same bot lists the same providers.
    func sibling(_ key: Key) -> ModelOptions? {
        entries.filter { $0.key.account == key.account && $0.key.profile == key.profile }
            .max { $0.value.at < $1.value.at }
            .map { shown($0.value, $0.key) }
    }

    /// The gateway's own answer, without the owner's names or hidden models (Settings › Providers lists every model).
    func raw(_ key: Key) -> ModelOptions? { entries[key]?.options }

    func fresh(_ key: Key, now: ContinuousClock.Instant = .now) -> ModelOptions? {
        guard let e = entries[key], !e.stale, now - e.at < Self.freshFor else { return nil }
        return shown(e, key)
    }

    func store(_ options: ModelOptions, for key: Key) { entries[key] = Entry(options: options, at: .now); applied[key] = nil }

    private var applied: [Key: (version: Int, model: String, provider: String, options: ModelOptions)] = [:]

    private func shown(_ entry: Entry, _ key: Key) -> ModelOptions {
        let version = ProviderPrefs.version
        if let hit = applied[key], hit.version == version, hit.model == entry.options.model, hit.provider == entry.options.provider {
            return hit.options
        }
        let options = entry.options.applying(ProviderPrefs.active)
        applied[key] = (version, entry.options.model, entry.options.provider, options)
        return options
    }

    /// A live switch's answer: the next load asks again.
    func markStale(_ key: Key) { entries[key]?.stale = true }

    /// [custom-providers] A provider added, renamed or removed in Settings: every menu of the account asks again on its
    /// next open (and shows the copy it has until then).
    func markStale(account: String) {
        for key in entries.keys where key.account == account { entries[key]?.stale = true }
    }

    /// Paints a pick into the cached answer (the web's `setQueryData`), so `current()` reads it at once.
    func paint(_ key: Key, model: String, provider: String) {
        guard var e = entries[key] else { return }
        e.options.model = model
        e.options.provider = provider
        entries[key] = e
    }

    /// True the first time it is asked for a key (and remembers it).
    func claimWarmUp(_ key: Key) -> Bool { warmed.insert(key).inserted }

    func profileEffort(_ key: ProfileKey) -> String? { profileEfforts[key]?.value }

    func profileEffortIsFresh(_ key: ProfileKey, now: ContinuousClock.Instant = .now) -> Bool {
        guard let e = profileEfforts[key] else { return false }
        return now - e.at < Self.profileEffortFreshFor
    }

    func storeProfileEffort(_ value: String, for key: ProfileKey) { profileEfforts[key] = (value, .now) }

    private var profileEffortReads: [ProfileKey: ContinuousClock.Instant] = [:]

    /// True when the ⋯ warm-up may read the profile's default now: not fresh, and not tried in the last 5 minutes (a
    /// gateway that can't answer isn't asked on every ⋯ open).
    func claimProfileEffortRead(_ key: ProfileKey, now: ContinuousClock.Instant = .now) -> Bool {
        if profileEffortIsFresh(key, now: now) { return false }
        if let last = profileEffortReads[key], now - last < Self.profileEffortFreshFor { return false }
        profileEffortReads[key] = now
        return true
    }

    func forget(account: String) {
        entries = entries.filter { $0.key.account != account }
        applied = applied.filter { $0.key.account != account }
        failedKeys = failedKeys.filter { $0.account != account }
        warmed = warmed.filter { $0.account != account }
        profileEfforts = profileEfforts.filter { $0.key.account != account }
        profileEffortReads = profileEffortReads.filter { $0.key.account != account }
    }

    #if DEBUG
    func reset() { entries = [:]; applied = [:]; failedKeys = []; warmed = []; profileEfforts = [:]; profileEffortReads = [:] }
    #endif
}
