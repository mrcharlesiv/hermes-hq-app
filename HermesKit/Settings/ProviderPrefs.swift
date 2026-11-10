// [provider-manager] Owner 2026-11-05: "I just need to be able to like add and remove providers and then edit their
// names and then edit the list of models on each provider so that I can like control which ones show in the app and the
// names and everything else." What Hermes can't keep for a provider is kept here, by the app: a provider's own name (a
// built-in one or a signed-in account; your own endpoints are renamed on the gateway), each model's name, the models
// left out of the menus, and model IDs added by hand to a built-in provider.
//
// Keyed by the provider's catalog id (`anthropic`, `custom:home-server`, lowercased) and, for a model, that id plus the
// model's own id (`anthropic::claude-opus-5.5`). Only what is shown changes: a pick still sends the real ids.
//
// The account's choices are one document of the cross-device sync (`GatewaySync`, "providers"), so the iPhone and the Mac
// show the same names and the same short lists. The account in use is `ProviderPrefs.active`, which the model menus and
// names read from any thread (`ModelNames.displayModelName`, `ModelOptions.applying`).

import CryptoKit
import Foundation

nonisolated struct ProviderPrefs: Sendable, Equatable, Codable {
    /// Provider id → the name to show.
    var providerNames: [String: String] = [:]
    /// `provider::model` → the name to show.
    var modelNames: [String: String] = [:]
    /// `provider::model` left out of every model list (still shown as the current model where it is in use).
    var hidden: Set<String> = []
    /// Provider id → model ids added by hand, in the order added (offered after the provider's own).
    var extras: [String: [String]] = [:]

    init() {}

    var isEmpty: Bool { providerNames.isEmpty && modelNames.isEmpty && hidden.isEmpty && extras.isEmpty }

    // MARK: Keys

    /// A provider's key: its catalog id, trimmed and lowercased.
    static func providerKey(_ provider: String) -> String { provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    static func modelKey(_ provider: String, _ model: String) -> String {
        "\(providerKey(provider))::\(model.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// The catalog id Hermes gives one of your own endpoints (`custom_provider_slug`: `custom:` and its config key,
    /// lowercased, spaces as hyphens).
    static func endpointSlug(_ id: String) -> String {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "-")
        return normalized.hasPrefix("custom:") ? normalized : "custom:\(normalized)"
    }

    // MARK: Reading

    func providerName(_ provider: String) -> String? { providerNames[Self.providerKey(provider)] }

    func modelName(provider: String, model: String) -> String? { modelNames[Self.modelKey(provider, model)] }

    /// A model's name when only its id is known (a transcript note, a fallback row): the one name given to it, if every
    /// provider that renamed it agrees.
    func modelName(anyProvider model: String) -> String? {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !modelNames.isEmpty else { return nil }
        let suffix = "::\(model)"
        let names = Set(modelNames.compactMap { $0.key.hasSuffix(suffix) ? $0.value : nil })
        return names.count == 1 ? names.first : nil
    }

    func isHidden(provider: String, model: String) -> Bool { hidden.contains(Self.modelKey(provider, model)) }

    func extraModels(_ provider: String) -> [String] { extras[Self.providerKey(provider)] ?? [] }

    /// A provider's models as the menus offer them: its own, then those added here, without the hidden ones. `keep`: a
    /// model in use stays even when hidden, so the current value never goes blank.
    func visibleModels(provider: String, models: [String], keep: String? = nil) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for model in models + extraModels(provider) where seen.insert(model).inserted {
            if isHidden(provider: provider, model: model), model != keep { continue }
            out.append(model)
        }
        return out
    }

    // MARK: Writing

    /// A name; empty or the original clears it.
    mutating func setProviderName(_ name: String?, provider: String, original: String? = nil) {
        let key = Self.providerKey(provider)
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        providerNames[key] = trimmed.isEmpty || trimmed == original ? nil : trimmed
    }

    mutating func setModelName(_ name: String?, provider: String, model: String, original: String? = nil) {
        let key = Self.modelKey(provider, model)
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        modelNames[key] = trimmed.isEmpty || trimmed == original ? nil : trimmed
    }

    mutating func setHidden(_ hide: Bool, provider: String, model: String) {
        let key = Self.modelKey(provider, model)
        if hide { hidden.insert(key) } else { hidden.remove(key) }
    }

    /// Hides (or shows) every one of `models` at once (Show All / Hide All).
    mutating func setHidden(_ hide: Bool, provider: String, models: [String]) {
        for model in models { setHidden(hide, provider: provider, model: model) }
    }

    mutating func addExtra(_ model: String, provider: String) {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        let key = Self.providerKey(provider)
        var list = extras[key] ?? []
        if !list.contains(model) { list.append(model) }
        extras[key] = list
        hidden.remove(Self.modelKey(provider, model))
    }

    mutating func removeExtra(_ model: String, provider: String) {
        let key = Self.providerKey(provider)
        var list = extras[key] ?? []
        list.removeAll { $0 == model }
        extras[key] = list.isEmpty ? nil : list
        modelNames[Self.modelKey(provider, model)] = nil
        hidden.remove(Self.modelKey(provider, model))
    }

    /// Everything kept for a provider goes (its row was removed from the list).
    mutating func forget(provider: String) {
        let key = Self.providerKey(provider)
        providerNames[key] = nil
        extras[key] = nil
        modelNames = modelNames.filter { !$0.key.hasPrefix("\(key)::") }
        hidden = hidden.filter { !$0.hasPrefix("\(key)::") }
    }

    // MARK: The active account's copy (read from any thread)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var activeValue = ProviderPrefs()
    nonisolated(unsafe) private static var activeVersion = 0

    /// The signed-in account's choices (empty before one is active).
    static var active: ProviderPrefs { lock.withLock { activeValue } }
    /// Rises with every change of `active` (the model catalog's applied copies are made again).
    static var version: Int { lock.withLock { activeVersion } }

    static func setActive(_ prefs: ProviderPrefs) {
        lock.withLock {
            guard activeValue != prefs else { return }
            activeValue = prefs
            activeVersion += 1
        }
    }
}

// MARK: - Sync encoding

extension ProviderPrefs {
    /// `{"providers": {id: name}, "models": {"id::model": name}, "hidden": ["id::model"], "extra": {id: [model]}}`.
    var json: JSONValue {
        .object([
            "providers": .object(providerNames.mapValues { .string($0) }),
            "models": .object(modelNames.mapValues { .string($0) }),
            "hidden": .array(hidden.sorted().map { .string($0) }),
            "extra": .object(extras.mapValues { .array($0.map { .string($0) }) }),
        ])
    }

    init(json: JSONValue?) {
        self.init()
        guard let json else { return }
        for (key, value) in json["providers"]?.object ?? [:] {
            if let name = value.string, !name.isEmpty { providerNames[key] = name }
        }
        for (key, value) in json["models"]?.object ?? [:] {
            if let name = value.string, !name.isEmpty { modelNames[key] = name }
        }
        hidden = Set((json["hidden"]?.array ?? []).compactMap(\.string))
        for (key, value) in json["extra"]?.object ?? [:] {
            let list = (value.array ?? []).compactMap(\.string).filter { !$0.isEmpty }
            if !list.isEmpty { extras[key] = list }
        }
    }

    /// One flat entry per choice, so two devices' changes merge choice by choice.
    private var flat: [String: String] {
        var out: [String: String] = [:]
        for (key, name) in providerNames { out["p\u{0}\(key)"] = name }
        for (key, name) in modelNames { out["m\u{0}\(key)"] = name }
        for key in hidden { out["h\u{0}\(key)"] = "1" }
        for (provider, list) in extras { for (index, model) in list.enumerated() { out["x\u{0}\(provider)\u{0}\(model)"] = String(index) } }
        return out
    }

    private init(flat: [String: String], order: [ProviderPrefs]) {
        self.init()
        var extraRows: [String: [(order: Int, model: String)]] = [:]
        for (key, value) in flat {
            let parts = key.components(separatedBy: "\u{0}")
            guard parts.count >= 2 else { continue }
            switch parts[0] {
            case "p": providerNames[parts[1]] = value
            case "m": modelNames[parts[1]] = value
            case "h": hidden.insert(parts[1])
            case "x" where parts.count == 3: extraRows[parts[1], default: []].append((Int(value) ?? 0, parts[2]))
            default: break
            }
        }
        for (provider, rows) in extraRows {
            // The order the first copy that has it gives, then the rest as numbered.
            let known = order.flatMap { $0.extraModels(provider) }
            extras[provider] = rows.sorted { a, b in
                let ia = known.firstIndex(of: a.model) ?? Int.max, ib = known.firstIndex(of: b.model) ?? Int.max
                return ia != ib ? ia < ib : (a.order, a.model) < (b.order, b.model)
            }.map(\.model)
        }
    }

    /// How another device's copy meets this one (`GatewaySyncMerge`): replaced; joined with this one winning where both
    /// set the same thing (first contact); or, over a newer copy, this device's own changes since `base` kept and the
    /// rest taken from `remote` (rebase).
    static func merged(local: ProviderPrefs, remote: ProviderPrefs, base: ProviderPrefs?, merge: GatewaySyncMerge) -> ProviderPrefs {
        switch merge {
        case .replace:
            return remote
        case .firstContact:
            return ProviderPrefs(flat: remote.flat.merging(local.flat) { _, mine in mine }, order: [local, remote])
        case .rebase:
            let mine = local.flat, theirs = remote.flat, before = (base ?? ProviderPrefs()).flat
            var out: [String: String] = [:]
            for key in Set(mine.keys).union(theirs.keys).union(before.keys) {
                let value = mine[key] != before[key] ? mine[key] : theirs[key]
                if let value { out[key] = value }
            }
            return ProviderPrefs(flat: out, order: [local, remote])
        }
    }
}

// MARK: - Applying to the model lists

extension ModelOptions {
    /// The catalog as the menus show it: renamed providers and models, hidden models left out (except the current one),
    /// and models added by hand. Ids are unchanged.
    func applying(_ prefs: ProviderPrefs) -> ModelOptions {
        guard !prefs.isEmpty else { return self }
        var out = self
        out.providers = providers.map { row in
            var row = row
            let key = ProviderPrefs.providerKey(row.slug)
            row.customName = prefs.providerNames[key]
            let keep = row.matches(provider) ? model : nil
            row.models = prefs.visibleModels(provider: row.slug, models: row.models, keep: keep)
            var names: [String: String] = [:]
            for (modelKey, name) in prefs.modelNames where modelKey.hasPrefix("\(key)::") {
                names[String(modelKey.dropFirst(key.count + 2))] = name
            }
            row.modelNames = names
            return row
        }
        return out
    }
}

extension ModelProviderOption {
    /// Settings' model lists, as the menus show them (`ModelOptions.applying`). `keep`: the model in use for this
    /// provider (kept even when hidden).
    func applying(_ prefs: ProviderPrefs, keep: String? = nil) -> ModelProviderOption {
        var out = self
        if let name = prefs.providerName(slug) { out.name = name }
        out.models = prefs.visibleModels(provider: slug, models: models, keep: keep)
        return out
    }
}

extension JobModelProvider {
    func applying(_ prefs: ProviderPrefs) -> JobModelProvider {
        var out = self
        if let name = prefs.providerName(slug) { out.name = name }
        out.models = prefs.visibleModels(provider: slug, models: models)
        return out
    }
}

// MARK: - The account's store

/// One account's choices, kept on this device (Application Support/provider-prefs/<account hash>.json) and synced.
@MainActor final class ProviderPrefsStore {
    /// Posted on the main actor after any change (here or from another device).
    static let didChange = Notification.Name("hq.providerPrefs.didChange")

    private static var stores: [String: ProviderPrefsStore] = [:]

    static func of(accountId: String) -> ProviderPrefsStore {
        if let store = stores[accountId] { return store }
        let store = ProviderPrefsStore(fileURL: fileURL(accountId: accountId))
        stores[accountId] = store
        return store
    }

    /// The account in use: its choices become `ProviderPrefs.active`.
    private(set) static var current: ProviderPrefsStore?

    static func activate(accountId: String?) {
        guard let accountId else { current = nil; ProviderPrefs.setActive(ProviderPrefs()); return }
        let store = of(accountId: accountId)
        current = store
        ProviderPrefs.setActive(store.prefs)
    }

    nonisolated static func fileURL(accountId: String, root: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first) -> URL? {
        guard let root else { return nil }
        let hash = SHA256.hash(data: Data(accountId.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        return root.appending(path: "provider-prefs", directoryHint: .isDirectory).appending(path: "\(hash).json")
    }

    #if DEBUG
    /// `-HQDebugResetProviderPrefs YES` (UI tests): nothing renamed or hidden on any account.
    static func debugReset() {
        if let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "provider-prefs", directoryHint: .isDirectory) {
            try? FileManager.default.removeItem(at: dir)
        }
        stores = [:]
        current = nil
        ProviderPrefs.setActive(ProviderPrefs())
    }
    #endif

    let fileURL: URL?
    private(set) var prefs: ProviderPrefs

    init(fileURL: URL?) {
        self.fileURL = fileURL
        prefs = fileURL.flatMap { PagesCache.read(ProviderPrefs.self, $0) } ?? ProviderPrefs()
    }

    /// [sync] Told after every change made here.
    var syncChanged: (() -> Void)?

    /// Changes the choices; saved, made active (when this is the account in use) and synced.
    func update(_ change: (inout ProviderPrefs) -> Void) {
        var next = prefs
        change(&next)
        guard next != prefs else { return }
        prefs = next
        saved()
        syncChanged?()
    }

    private func saved() {
        if let fileURL { PagesCache.write(prefs, to: fileURL) }
        if Self.current === self { ProviderPrefs.setActive(prefs) }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

// [sync] The names and short lists, as every device signed in to the gateway sees them.
extension ProviderPrefsStore: GatewaySynced {
    var syncName: String { "providers" }

    func syncValue() -> JSONValue { prefs.json }

    func adoptSynced(_ value: JSONValue, merge: GatewaySyncMerge, base: JSONValue?) {
        let next = ProviderPrefs.merged(local: prefs, remote: ProviderPrefs(json: value), base: base.map { ProviderPrefs(json: $0) }, merge: merge)
        guard next != prefs else { return }
        prefs = next
        saved()
    }
}
