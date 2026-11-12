// The ⋯ › Model submenu as plain data (spec 1x §4.6; S:ui-chat/title-menu.ts:27-57,288-295), and the context that
// reads the open chat's model, the cached catalog and this account's favourites, recents and presets for it.

import Foundation

/// What the submenu is built from (`TitleMenuInput`).
nonisolated struct ModelMenuInput: Sendable {
    var current: ModelChoice
    var recents: [ModelChoice]
    var favorites: [ModelChoice]
    /// The Reasoning levels offered; empty = no Reasoning submenu.
    var reasoningLevels: [String]
    var reasoningCurrent: String
    var canTurnOff: Bool
    var fastSupported: Bool
    var fastOn: Bool
    var offline: Bool
    /// [model-panel] The bot's approval mode ("" not reported) and this chat's YOLO.
    var approvalMode = ""
    var yolo = false
}

nonisolated struct ModelMenuItem: Hashable, Sendable {
    enum Action: Hashable, Sendable {
        case model(ModelChoice)
        case moreModels
        case reasoning(String)
        case fast(on: Bool)
    }
    var action: Action
    var title: String
    var subtitle: String?
    var on = false
    var disabled = false
}

/// "Model ▸" with its inline "Model for Next Reply" section, Reasoning ▸ and Fast.
nonisolated struct ModelMenuNode: Sendable {
    var title = "Model"
    var subtitle: String
    var quickTitle = "Model for Next Reply"
    var quick: [ModelMenuItem]
    var reasoning: (subtitle: String, items: [ModelMenuItem])?
    var fast: ModelMenuItem?
}

nonisolated enum ModelMenuModel {
    static let favoritesShown = 5
    static let recentsShown = 2

    static func build(_ input: ModelMenuInput) -> ModelMenuNode {
        func write(_ item: ModelMenuItem) -> ModelMenuItem {
            guard input.offline else { return item }
            var disabled = item
            disabled.disabled = true
            disabled.subtitle = "Offline"
            return disabled
        }
        var seen: Set<String> = [input.current.id]
        func fresh(_ models: [ModelChoice], _ most: Int) -> [ModelChoice] {
            var left = most
            return models.filter { m in
                guard left > 0, !seen.contains(m.id) else { return false }
                seen.insert(m.id)
                left -= 1
                return true
            }
        }
        let favorites = fresh(input.favorites, favoritesShown)
        let recents = fresh(input.recents, recentsShown)
        var quick = [write(ModelMenuItem(action: .model(input.current), title: input.current.name, on: true))]
        for row in favorites + recents {
            let subtitle = row.provider != input.current.provider ? (row.providerName ?? row.provider) : nil
            quick.append(write(ModelMenuItem(action: .model(row), title: row.name, subtitle: subtitle)))
        }
        quick.append(write(ModelMenuItem(action: .moreModels, title: "More Models…")))

        var node = ModelMenuNode(subtitle: "", quick: quick)
        if !input.reasoningLevels.isEmpty {
            var levels: [String] = input.canTurnOff ? ["none"] : []
            for level in input.reasoningLevels where level != "none" && !levels.contains(level) { levels.append(level) }
            let items = levels.map { level in
                write(ModelMenuItem(action: .reasoning(level), title: ModelNames.effortLabel(level), on: level == input.reasoningCurrent))
            }
            node.reasoning = (input.offline ? "Offline" : ModelNames.effortLabel(input.reasoningCurrent), items)
        }
        if input.fastSupported {
            node.fast = write(ModelMenuItem(action: .fast(on: !input.fastOn), title: "Fast", on: input.fastOn))
        }
        let effort = input.reasoningLevels.isEmpty ? "" : ModelNames.effortLabel(input.reasoningCurrent)
        node.subtitle = input.offline ? "Offline" : [input.current.name, effort].filter { !$0.isEmpty }.joined(separator: " · ")
        return node
    }
}

/// An error whose message is shown as is ("You’re offline.", "This chat is still loading…").
nonisolated struct MenusError: LocalizedError, Sendable, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }

    /// A whole sentence: it reads as an alert's reason and as the line under "Couldn’t load the models." (Usage & Limits,
    /// Model Prices), as the Models sheet says it.
    static let offline = MenusError("You’re offline.")
    static let loading = MenusError("This chat is still loading. Try again when it is ready.")

    /// The words an alert or output row shows for any error: the gateway's own reason when it gave one in words, else
    /// plain words for what happened. Never an error page's HTML, a JSON body, a bare status number or a Swift error's
    /// dump (those are for Show Details: `details`).
    static func text(_ error: any Error) -> String {
        if SessionWrite.isBusy(error) { return SessionWrite.busyWords }
        if let rpc = error as? RPCError { return rpc.message }
        if let menus = error as? MenusError { return menus.message }
        if let http = error as? HTTPError {
            // FastAPI's {"detail": "…"} (or an object's message, or {"error": "…"}), or a short plain-text body.
            if let detail = PagesREST.detail(http) { return detail }
            switch GatewayFailure.from(status: http.status, body: http.body) {
            case .gatewayError: return "\(HostWord.sentence) couldn’t do that. Try again."
            case let failure: return failure.message
            }
        }
        if let failure = error as? GatewayFailure { return failure.message }
        if error is CancellationError { return "Cancelled." }
        if let transport = PagesREST.transportReason(error) { return transport }
        if error is DecodingError { return "\(HostWord.sentence) sent an answer Hermes HQ couldn’t read." }
        if let local = error as? LocalizedError, let text = local.errorDescription, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            return text
        }
        return "Something went wrong. Try again."
    }

    /// What Show Details shows: everything the error carries (the body as the gateway sent it, the status, the error).
    static func details(_ error: any Error) -> String {
        if let http = error as? HTTPError {
            let body = http.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return body.isEmpty ? "HTTP \(http.status)" : "HTTP \(http.status)\n\n\(String(body.prefix(4000)))"
        }
        if let rpc = error as? RPCError { return "\(rpc.message) (\(rpc.code))" }
        if let local = error as? LocalizedError, let text = local.errorDescription { return text }
        return String(describing: error)
    }
}

/// The open chat's model menu context (`titleMenuContext`, S:ui-chat/title-menu.ts:78-276): reads the chat's model
/// state, the cached catalog and this account's stores; loads the catalog.
final class ModelMenuContext {
    let chat: any ChatModelControlling
    let prefs: ModelPrefs
    let cache: ModelCatalogCache

    init(chat: any ChatModelControlling, prefs: ModelPrefs, cache: ModelCatalogCache = .shared) {
        self.chat = chat
        self.prefs = prefs
        self.cache = cache
    }

    var key: ModelCatalogCache.Key { Self.key(for: chat) }

    /// The catalog cache's key for a chat: its account, profile and runtime id ("global" before it has one).
    static func key(for chat: any ChatModelControlling) -> ModelCatalogCache.Key {
        ModelCatalogCache.Key(account: chat.account.id, profile: chat.profileParam ?? "", scope: chat.runtimeSessionId ?? "global")
    }

    /// A model's provider as the menus name it: the catalog row's name when the chat's catalog is cached (the Models
    /// sheet's header, the quick list's subtitle), else the slug's display name (spec 1x §4.3, Info's note).
    static func providerName(for chat: any ChatModelControlling, model: String, provider: String,
                             cache: ModelCatalogCache = .shared) -> String {
        let options = cache.cached(key(for: chat))
        let choice = options?.describe(id: model, provider: provider) ?? ModelOptions.describe(id: model, provider: provider, row: nil)
        return choice.providerName ?? ModelNames.plainProviderName(ModelNames.providerDisplayName(provider))
    }

    var profileKey: ModelCatalogCache.ProfileKey {
        ModelCatalogCache.ProfileKey(account: chat.account.id, profile: chat.profileParam ?? "")
    }

    /// The profile's own reasoning default once read (`config.get reasoning` without a session); nil until then.
    var profileDefaultEffort: String? { cache.profileEffort(profileKey) }

    var options: ModelOptions? { cache.cached(key) }
    var hasCatalog: Bool { options != nil }
    var offline: Bool { chat.connection != .ready }

    func describe(id: String, provider: String) -> ModelChoice {
        options?.describe(id: id, provider: provider) ?? ModelOptions.describe(id: id, provider: provider, row: nil)
    }

    func models() -> [ModelChoice] { options?.choices ?? [] }

    func current() -> ModelChoice {
        let state = chat.modelState
        let selection = ModelNames.currentPickerSelection(store: (state.model, state.provider),
                                                         options: options.map { ($0.model, $0.provider) })
        return describe(id: selection.model, provider: selection.provider)
    }

    func capabilities(_ model: ModelChoice) -> ModelCapabilities? {
        options?.capabilities(provider: model.provider, model: model.id)
    }

    /// How Fast works for the current model (`fast()`, title-menu.ts:163-170): the model's own tier, a `-fast` sibling
    /// id, or (neither) only while Fast is on, so it can be turned off.
    func fastControl() -> (supported: Bool, on: Bool, variant: (base: String, sibling: String)?) {
        let model = current()
        let fastOn = chat.modelState.fast
        if capabilities(model)?.fast == true { return (true, fastOn, nil) }
        let ids = options?.row(matching: model.provider)?.models ?? []
        let base = model.id.replacingOccurrences(of: "-fast$", with: "", options: [.regularExpression, .caseInsensitive])
        let sibling = "\(base)-fast"
        if ids.contains(base) && ids.contains(sibling) { return (true, model.id == sibling, (base, sibling)) }
        return (fastOn, fastOn, nil)
    }

    func input() -> ModelMenuInput {
        let model = current()
        let caps = capabilities(model)
        let catalog = models()
        // [custom-providers] The catalog's own row, not the one saved with the pick: a provider renamed since (Settings ›
        // Providers, or the desktop app) shows its new name here too, as the favourites do.
        let recents = prefs.recents.compactMap { row in catalog.first { $0.id == row.id && $0.provider == row.provider } }
        // [ghost-stars] The bot's newest catalog, this chat's or another's: this chat's own may be the older one (read
        // before a provider or a model went away).
        let favorites = Self.favorites(keys: prefs.favorites, catalog: cache.sibling(key)?.choices ?? options?.choices,
                                       knownProviders: prefs.knownProviders(profile: key.profile),
                                       missing: prefs.missingStars(profile: key.profile))
        let effort = chat.modelState.reasoningEffort
        let fast = fastControl()
        return ModelMenuInput(current: model, recents: recents, favorites: favorites,
                              reasoningLevels: caps?.reasoning == false || model.id.isEmpty ? [] : ModelNames.reasoningEfforts,
                              reasoningCurrent: effort.isEmpty ? (profileDefaultEffort ?? ModelNames.defaultReasoningEffort) : effort,
                              canTurnOff: caps?.canDisableReasoning != false,
                              fastSupported: fast.supported, fastOn: fast.on, offline: offline,
                              approvalMode: chat.modelState.approvalMode, yolo: chat.modelState.yolo)
    }

    /// [stale-stars] The starred models the menus list: the rows of the bot's newest catalog for them; with none in
    /// memory, each star read from its key, but none the bot's last catalog didn't list (`missing`) and none from a
    /// provider it didn't list (tester 2026-11-09: a removed provider's stars showed in every new chat until
    /// its catalog loaded). [ghost-stars] The known providers hold over a catalog too: one removed in Settings since
    /// that catalog was read is still in it (tester 2026-11-10: "the ghost favorites are still there").
    nonisolated static func favorites(keys: [String], catalog: [ModelChoice]?, knownProviders: Set<String>?,
                                      missing: Set<String> = []) -> [ModelChoice] {
        // [ghost-stars] No catalog and none read for this bot on this device (its first chat here, or after Sign Out):
        // no star is known to exist yet, so none shows until the read answers (a removed provider's stars did).
        if catalog == nil, knownProviders == nil { return [] }
        let rows = catalog.map { ModelSheetModel.favoriteRows($0, keys: keys) }
            ?? ModelSheetModel.favoritesFromKeys(keys).filter { !missing.contains($0.key) }
        guard let knownProviders else { return rows }
        return rows.filter { knownProviders.contains($0.provider) }
    }

    /// [ghost-stars] What a catalog read leaves for the next chat's menu, drawn before its own read answers: the
    /// providers it listed and the stars it didn't.
    func noteCatalog(_ shown: ModelOptions?, raw: ModelOptions) {
        prefs.setKnownProviders(Set(raw.providers.filter { !$0.models.isEmpty }.map(\.slug)), profile: key.profile)
        let listed = Set((shown ?? raw).choices.map(\.key))
        prefs.setMissingStars(Set(prefs.favorites.filter { !listed.contains($0) }), profile: key.profile)
    }

    // MARK: Loading (spec 1x §3.1)

    /// Each try's time limit. DEBUG: `-HQNModelTimeout <seconds>` shortens it for the UI tests.
    static var optionsTimeout: Duration {
        #if DEBUG
        let seconds = UserDefaults.standard.double(forKey: "HQNModelTimeout")
        if seconds > 0 { return .milliseconds(Int(seconds * 1000)) }
        #endif
        return .seconds(30)
    }

    /// [m9/composer] The last load of this chat's catalog failed and nothing is cached (the model panel's Switch Model
    /// menu then says so and offers Try Again, docs/spec/3x-composer.md §12.2 point 5).
    var loadFailed: Bool { options == nil && cache.loadFailed(key) }

    /// The catalog's models: the cached answer while fresh (30 s) unless `refresh`; offline, the cached one or "Offline".
    /// [m9/composer] A failed read is tried once more at once before the failure shows (web r2-60 `retry: 1`), except
    /// where a second try cannot help (`ModelLoad.secondTryHelps`). `reread`: ask even while the cached answer is fresh,
    /// without the gateway's heavy refresh (⋯ › Usage & Limits and Model Prices want the newest usage and prices).
    func load(refresh: Bool = false, reread: Bool = false) async throws -> [ModelChoice] {
        if offline {
            guard options != nil else { throw MenusError.offline }
            return models()
        }
        if !refresh, !reread, cache.fresh(key) != nil { return models() }
        var attempt = 0
        while true {
            attempt += 1
            do {
                let result = try await chat.sessionCall("model.options", timeout: Self.optionsTimeout, runtime: .optional) { _ in
                    var p: [String: JSONValue] = ["explicit_only": true]
                    if refresh { p["refresh"] = true }
                    return p
                }
                let loaded = ModelOptions(json: result)
                cache.store(loaded, for: key)
                noteCatalog(cache.cached(key), raw: loaded)
                cache.setLoadFailed(false, for: key)
                return models()
            } catch {
                if attempt < ModelLoad.tries, !Task.isCancelled, !offline, ModelLoad.secondTryHelps(error) {
                    AppLog.note("menus", "model list: first try failed (\(MenusError.text(error))), trying once more")
                    continue
                }
                if !(error is CancellationError) {
                    cache.setLoadFailed(true, for: key)
                    if options != nil { AppLog.note("menus", "Models didn’t refresh: \(MenusError.text(error))") }
                }
                throw error
            }
        }
    }

    /// The ⋯ menu's one background catalog read per key in an app run (spec 1x §3.1 ⚑ DECISION): no UI, errors
    /// swallowed; the next ⋯ open shows the full quick list. The profile's reasoning default is read with it.
    func warmUp() {
        guard !offline else { return }
        if cache.claimProfileEffortRead(profileKey) {
            Task { [weak self] in _ = await self?.loadProfileDefault() }
        }
        let key = self.key
        guard cache.cached(key) == nil, cache.claimWarmUp(key) else { return }
        Task { [weak self] in _ = try? await self?.load() }
    }

    // MARK: The profile's reasoning default

    static let profileDefaultTimeout: Duration = .seconds(10)
    private var profileDefaultLoad: Task<String?, Never>?

    /// `config.get {key: "reasoning", profile}` with **no** session id: the gateway then answers the profile's
    /// config.yaml `agent.reasoning_effort` (its built-in "medium" when unset; H:tui_gateway/methods_config.py:206-225).
    /// Cached per account and profile; nil when it couldn't be read (a switch then leaves the session's reasoning
    /// alone rather than guess). Concurrent callers share one read.
    func loadProfileDefault() async -> String? {
        if let running = profileDefaultLoad { return await running.value }
        if offline { return profileDefaultEffort }
        let key = profileKey
        let client = chat.client
        var params: [String: JSONValue] = ["key": "reasoning"]
        if let profile = chat.profileParam { params["profile"] = .string(profile) }
        let cache = self.cache
        let task = Task<String?, Never> {
            guard let answer = try? await client.call("config.get", .object(params), timeout: Self.profileDefaultTimeout),
                  let value = ModelNames.normalizeConfigEffort(answer["value"]) else { return cache.profileEffort(key) }
            cache.storeProfileEffort(value, for: key)
            return value
        }
        profileDefaultLoad = task
        defer { profileDefaultLoad = nil }
        return await task.value
    }
}
