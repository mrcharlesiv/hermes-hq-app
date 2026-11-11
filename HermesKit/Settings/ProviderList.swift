// [provider-manager] Settings › Providers as one list of the providers you actually have (owner 2026-11-05: "I just
// need to be able to like add and remove providers and then edit their names and then edit the list of models"). The
// page used to show every provider Hermes knows (about 50 cards, 110 rows), most never set up, with nothing to remove,
// so it looked as if nothing could be. Now one row per provider you have, from three places:
//   - your own endpoints (`/api/providers/custom-endpoints`);
//   - Hermes' built-in providers with a key saved (the provider keys of `/api/env` whose group has one set);
//   - accounts you are signed in to (`/api/providers/oauth`).
// Each is keyed by its id in the model catalog, which is what the app's names and short lists (`ProviderPrefs`) use.
// Built-ins you don't use are only in Add Provider's "Built Into Hermes".

import Foundation

nonisolated struct ManagedProvider: Sendable, Equatable, Identifiable {
    /// The catalog id (`anthropic`, `custom:home-server`, `nous`), lowercased.
    var id: String
    /// The name Hermes gives it (the endpoint's own name, the key card's, the account's).
    var originalName: String
    var endpoint: CustomProvider?
    /// The built-in provider's keys (every key of its card, set or not).
    var keys: [EnvVarInfo] = []
    var account: OAuthProviderRow?

    var hasKey: Bool { keys.contains(where: \.isSet) }

    /// What it is, in a few words, under its name.
    var sourceLine: String {
        if let endpoint { return "Your own · \(endpoint.shortAddress)" }
        if let account, account.connected {
            let who = account.detail.map { " · \($0)" } ?? ""
            return hasKey ? "Signed in and key saved\(who)" : "Signed in\(who)"
        }
        return "Built into Hermes · Key saved"
    }

    /// The name shown: the owner's own for a built-in or an account, the endpoint's (renamed on the gateway) for one of
    /// your own.
    func name(_ prefs: ProviderPrefs) -> String {
        if endpoint != nil { return originalName }
        return prefs.providerName(id) ?? originalName
    }

    /// What Remove does for it, or why there's nothing to remove.
    enum Removal: Sendable, Equatable {
        case deleteEndpoint
        case removeKeys([String])
        case signOut
        /// Both: a built-in with a key and a sign-in Hermes can end.
        case removeKeysAndSignOut([String])
        case cannot(String)
    }

    var removal: Removal {
        if let endpoint {
            return endpoint.canDelete ? .deleteEndpoint
                : .cannot("This is the default model’s own address, not a saved provider. Change the default model to remove it.")
        }
        let setKeys = keys.filter(\.isSet).map(\.key)
        let canSignOut = account?.canSignOut == true
        switch (setKeys.isEmpty, canSignOut) {
        case (false, true): return .removeKeysAndSignOut(setKeys)
        case (false, false): return .removeKeys(setKeys)
        case (true, true): return .signOut
        case (true, false):
            return .cannot("This sign-in belongs to another app on \(HostWord.phrase). Sign out of it there.")
        }
    }
}

nonisolated enum ProviderList {
    /// The catalog id a built-in provider's keys stand for: the gateway's own (`provider` on each key), else the catalog
    /// row whose key is one of them, else the key's prefix (`ANTHROPIC_API_KEY` → `anthropic`).
    static func slug(forKeys keys: [EnvVarInfo], catalog: [ModelProviderOption]) -> String {
        if let own = keys.lazy.compactMap({ $0.provider?.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) {
            return ProviderPrefs.providerKey(own)
        }
        let names = Set(keys.map(\.key))
        if let row = catalog.first(where: { $0.keyEnv.map(names.contains) ?? false }) { return ProviderPrefs.providerKey(row.slug) }
        let key = ProviderAdding.primaryKey(keys)?.key ?? keys.first?.key ?? ""
        let group = EnvKeys.providerGroups.filter { key.hasPrefix($0.prefix) }.max { $0.prefix.count < $1.prefix.count }
        let prefix = group?.prefix ?? String(key.prefix { $0 != "_" }) + "_"
        return ProviderPrefs.providerKey(String(prefix.dropLast()).replacingOccurrences(of: "_", with: "-"))
    }

    /// The account's catalog id: its own, or the catalog row of the same name.
    static func slug(forAccount account: OAuthProviderRow, catalog: [ModelProviderOption]) -> String {
        let id = ProviderPrefs.providerKey(account.id)
        if catalog.contains(where: { ProviderPrefs.providerKey($0.slug) == id }) { return id }
        if let row = catalog.first(where: { $0.name.caseInsensitiveCompare(account.name) == .orderedSame }) {
            return ProviderPrefs.providerKey(row.slug)
        }
        return id
    }

    /// Every provider you have, one row each, by the name shown (A to Z).
    static func merge(custom: [CustomProvider], vars: [EnvVarInfo], accounts: [OAuthProviderRow], catalog: [ModelProviderOption],
                      prefs: ProviderPrefs = ProviderPrefs()) -> [ManagedProvider] {
        var rows: [ManagedProvider] = []
        var index: [String: Int] = [:]
        func add(_ row: ManagedProvider) {
            if let at = index[row.id] {
                // The same provider twice (a key and a sign-in for Nous): one row with both.
                if rows[at].keys.isEmpty { rows[at].keys = row.keys }
                if rows[at].account == nil { rows[at].account = row.account }
                if rows[at].endpoint == nil, let endpoint = row.endpoint { rows[at].endpoint = endpoint; rows[at].originalName = row.originalName }
            } else {
                index[row.id] = rows.count
                rows.append(row)
            }
        }
        for endpoint in custom {
            add(ManagedProvider(id: ProviderPrefs.endpointSlug(endpoint.id), originalName: endpoint.name, endpoint: endpoint))
        }
        for group in EnvKeys.groupedProviders(vars) where group.keys.contains(where: \.isSet) {
            add(ManagedProvider(id: slug(forKeys: group.keys, catalog: catalog), originalName: group.name, keys: group.keys))
        }
        for account in accounts where account.connected {
            add(ManagedProvider(id: slug(forAccount: account, catalog: catalog), originalName: account.name, account: account))
        }
        return rows.sorted {
            let a = $0.name(prefs), b = $1.name(prefs)
            let order = a.localizedCaseInsensitiveCompare(b)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    /// Every model a provider offers, for its page: the catalog's, then your endpoint's saved ones and what Test
    /// Connection found, then the ones added by hand. Hidden ones are listed too (each with its switch off).
    static func allModels(_ provider: ManagedProvider, catalog: [ModelProviderOption], found: [String] = [], prefs: ProviderPrefs) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        let row = catalog.first { ProviderPrefs.providerKey($0.slug) == provider.id }
        for model in (row?.models ?? []) + (provider.endpoint?.models ?? []) + found + prefs.extraModels(provider.id)
        where !model.isEmpty && seen.insert(model).inserted {
            out.append(model)
        }
        return out
    }

    /// [provider-rows] The row's trailing edge (owner 2026-11-10, design pick 4): "12 models", "1 model",
    /// "2 of 3 models", or "No models" with `none` set (the row draws that in orange: nothing to pick from it).
    static func shownEdge(_ provider: ManagedProvider, catalog: [ModelProviderOption], prefs: ProviderPrefs) -> (text: String, none: Bool) {
        let all = allModels(provider, catalog: catalog, prefs: prefs)
        guard !all.isEmpty else { return ("No models", true) }
        let shown = all.filter { !prefs.isHidden(provider: provider.id, model: $0) }.count
        if shown == all.count { return (shown == 1 ? "1 model" : "\(shown) models", false) }
        return ("\(shown) of \(all.count) models", false)
    }

    /// "12 models shown", "1 model shown", "No models listed".
    static func shownLine(_ provider: ManagedProvider, catalog: [ModelProviderOption], prefs: ProviderPrefs) -> String {
        let all = allModels(provider, catalog: catalog, prefs: prefs)
        guard !all.isEmpty else { return "No models listed" }
        let shown = all.filter { !prefs.isHidden(provider: provider.id, model: $0) }.count
        if shown == all.count { return shown == 1 ? "1 model shown" : "\(shown) models shown" }
        return "\(shown) of \(all.count) models shown"
    }
}
