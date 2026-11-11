// [provider-manager] Settings › Providers as one list of the providers you have, and the app's own provider and model
// names, hidden models and added model ids (`ProviderPrefs`): the merge of the three sources, the names and short lists
// as every model menu shows them (ids unchanged, the model in use never lost), the sync document and its merges, and a
// rename and a hidden model travelling from the iPhone to the Mac.

import Foundation
import Testing
@testable import HermesHQNative

nonisolated private func key(_ name: String, set: Bool, provider: String? = nil, primary: Bool = false, password: Bool = true) -> EnvVarInfo {
    EnvVarInfo(key: name, category: "provider", isPassword: password, isSet: set, provider: provider, providerPrimary: primary)
}

nonisolated private let catalog: [ModelProviderOption] = [
    ModelProviderOption(slug: "anthropic", name: "Anthropic", models: ["claude-opus-5.5", "claude-sonnet-5"], authenticated: true,
                        keyEnv: "ANTHROPIC_API_KEY"),
    ModelProviderOption(slug: "openrouter", name: "OpenRouter", models: ["deepseek/deepseek-v3.2", "x-ai/grok-5"], keyEnv: "OPENROUTER_API_KEY"),
    ModelProviderOption(slug: "nous", name: "Nous Portal", models: ["Hermes-4-405B"]),
    ModelProviderOption(slug: "custom:home-server", name: "Home Server", models: ["llama-3.3-70b"]),
]

nonisolated private let home = CustomProvider(id: "home-server", name: "Home Server", baseURL: "http://192.168.1.20:8080/v1",
                                              model: "llama-3.3-70b", models: ["llama-3.3-70b", "qwen3-coder-30b"])

nonisolated private func account(_ id: String, _ name: String, connected: Bool, disconnectable: Bool) -> OAuthProviderRow {
    OAuthProviderRow(["id": .string(id), "name": .string(name), "logged_in": .bool(connected), "disconnectable": .bool(disconnectable)])!
}

@Suite struct ProviderListMergeTests {
    private var vars: [EnvVarInfo] {
        [key("ANTHROPIC_API_KEY", set: true), key("ANTHROPIC_BASE_URL", set: false, password: false),
         key("OPENROUTER_API_KEY", set: false), key("DEEPSEEK_API_KEY", set: false),
         key("NOUS_API_KEY", set: true, provider: "nous")]
    }

    @Test func listsOnlyWhatYouHave() {
        let accounts = [account("nous", "Nous Portal", connected: true, disconnectable: true),
                        account("openai-codex", "ChatGPT (Codex)", connected: false, disconnectable: true),
                        account("claude-code", "Claude Code", connected: true, disconnectable: false)]
        let rows = ProviderList.merge(custom: [home], vars: vars, accounts: accounts, catalog: catalog)
        #expect(rows.map(\.id) == ["anthropic", "claude-code", "custom:home-server", "nous"], "A to Z by name, unset keys and signed-out accounts left out")
        let anthropic = rows[0]
        #expect(anthropic.keys.map(\.key) == ["ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL"], "every key of its card, for its page")
        #expect(anthropic.sourceLine == "Built into Hermes · Key saved")
        #expect(anthropic.removal == .removeKeys(["ANTHROPIC_API_KEY"]))
        let nous = rows[3]
        #expect(nous.account != nil && nous.hasKey, "a key and a sign-in for the same provider are one row")
        #expect(nous.removal == .removeKeysAndSignOut(["NOUS_API_KEY"]))
        #expect(rows[2].endpoint?.id == "home-server")
        #expect(rows[2].sourceLine == "Your own · 192.168.1.20:8080")
        #expect(rows[2].removal == .deleteEndpoint)
        if case .cannot(let why) = rows[1].removal { #expect(why.contains("another app")) } else { Issue.record("Claude Code can't be signed out here") }
    }

    @Test func aKeysCatalogIdComesFromTheGatewayThenTheCatalogThenThePrefix() {
        #expect(ProviderList.slug(forKeys: [key("NOUS_API_KEY", set: true, provider: "Nous")], catalog: []) == "nous")
        #expect(ProviderList.slug(forKeys: [key("OPENROUTER_API_KEY", set: true)], catalog: catalog) == "openrouter")
        #expect(ProviderList.slug(forKeys: [key("DEEPSEEK_API_KEY", set: true)], catalog: []) == "deepseek")
        #expect(ProviderList.slug(forKeys: [key("KIMI_CN_API_KEY", set: true)], catalog: []) == "kimi-cn", "the longest prefix")
        #expect(ProviderPrefs.endpointSlug("Home Server") == "custom:home-server")
        #expect(ProviderPrefs.endpointSlug("custom:lab") == "custom:lab")
    }

    @Test func anEndpointWithNoEntryCantBeRemoved() {
        var direct = home
        direct.source = "direct-config"
        let rows = ProviderList.merge(custom: [direct], vars: [], accounts: [], catalog: [])
        guard case .cannot = rows[0].removal else { Issue.record("the default model's own address has no entry"); return }
    }

    @Test func sortsByTheNameShownAndCountsShownModels() {
        var prefs = ProviderPrefs()
        prefs.setProviderName("Zed's Claude", provider: "anthropic")
        prefs.setHidden(true, provider: "custom:home-server", model: "qwen3-coder-30b")
        prefs.addExtra("my-tune", provider: "custom:home-server")
        let rows = ProviderList.merge(custom: [home], vars: vars, accounts: [], catalog: catalog, prefs: prefs)
        #expect(rows.map { $0.name(prefs) } == ["Home Server", "Nous Portal", "Zed's Claude"])
        #expect(ProviderList.allModels(rows[0], catalog: catalog, prefs: prefs) == ["llama-3.3-70b", "qwen3-coder-30b", "my-tune"],
                "the catalog's, the endpoint's saved ones, then those added")
        #expect(ProviderList.shownLine(rows[0], catalog: catalog, prefs: prefs) == "2 of 3 models shown")
        #expect(ProviderList.shownLine(rows[2], catalog: catalog, prefs: prefs) == "2 models shown")
        #expect(ProviderList.shownLine(rows[1], catalog: catalog, prefs: prefs) == "1 model shown")
        // [provider-rows] Owner 2026-11-10: the same counts at the row's trailing edge, without "shown".
        #expect(ProviderList.shownEdge(rows[0], catalog: catalog, prefs: prefs).text == "2 of 3 models")
        #expect(ProviderList.shownEdge(rows[2], catalog: catalog, prefs: prefs).text == "2 models")
        #expect(ProviderList.shownEdge(rows[1], catalog: catalog, prefs: prefs) == ("1 model", false))
        #expect(ProviderList.shownEdge(rows[0], catalog: [], prefs: ProviderPrefs()).none == ProviderList.allModels(rows[0], catalog: [], prefs: ProviderPrefs()).isEmpty,
                "orange only when there is nothing to pick")
        var renamedEndpoint = prefs
        renamedEndpoint.setProviderName("Ignored", provider: "custom:home-server")
        #expect(rows[0].name(renamedEndpoint) == "Home Server", "your own endpoint's name is the gateway's")
    }
}

@Suite struct ProviderPrefsTests {
    @Test func namesAndHiddenModelsApplyToTheChatCatalog() {
        var prefs = ProviderPrefs()
        prefs.setProviderName("Work Claude", provider: "Anthropic")
        prefs.setModelName("Big Brain", provider: "anthropic", model: "claude-opus-5.5")
        prefs.setHidden(true, provider: "anthropic", model: "claude-sonnet-5")
        prefs.setHidden(true, provider: "anthropic", model: "claude-haiku-5")
        prefs.addExtra("claude-opus-5.5-preview", provider: "anthropic")
        let options = ModelOptions(providers: [
            ModelProviderRow(slug: "anthropic", name: "Anthropic", models: ["claude-opus-5.5", "claude-sonnet-5", "claude-haiku-5"],
                             aliases: [], capabilities: [:]),
            ModelProviderRow(slug: "openrouter", name: "OpenRouter", models: ["x-ai/grok-5"], aliases: [], capabilities: [:]),
        ], model: "claude-haiku-5", provider: "anthropic")
        let shown = options.applying(prefs)
        #expect(shown.providers[0].models == ["claude-opus-5.5", "claude-haiku-5", "claude-opus-5.5-preview"],
                "hidden left out, the model in use kept, added ones after")
        #expect(shown.providers[1].models == ["x-ai/grok-5"])
        let opus = shown.describe(id: "claude-opus-5.5", provider: "anthropic")
        #expect(opus.name == "Big Brain" && opus.providerName == "Work Claude")
        #expect(opus.id == "claude-opus-5.5" && opus.provider == "anthropic", "the real ids are what a pick sends")
        let hidden = shown.describe(id: "claude-sonnet-5", provider: "anthropic")
        #expect(hidden.name == "Sonnet 5", "a hidden model in use still has its name")
        #expect(!shown.choices.contains { $0.id == "claude-sonnet-5" })
        #expect(options.applying(ProviderPrefs()) == options, "nothing set: the catalog as it came")
    }

    @Test func settingsAndJobListsHideAndRenameToo() {
        var prefs = ProviderPrefs()
        prefs.setProviderName("Router", provider: "openrouter")
        prefs.setHidden(true, provider: "openrouter", model: "x-ai/grok-5")
        let row = catalog[1].applying(prefs)
        #expect(row.name == "Router" && row.models == ["deepseek/deepseek-v3.2"] && row.slug == "openrouter")
        #expect(catalog[1].applying(prefs, keep: "x-ai/grok-5").models == ["deepseek/deepseek-v3.2", "x-ai/grok-5"])
        let job = JobModelProvider(slug: "openrouter", name: "OpenRouter", models: ["deepseek/deepseek-v3.2", "x-ai/grok-5"]).applying(prefs)
        #expect(job.name == "Router" && job.models == ["deepseek/deepseek-v3.2"])
    }

    @Test func renamesClearWhenEmptyOrOriginal() {
        var prefs = ProviderPrefs()
        prefs.setModelName("  ", provider: "a", model: "m")
        #expect(prefs.modelNames.isEmpty)
        prefs.setModelName("Claude Opus 5.5", provider: "a", model: "claude-opus-5.5", original: "Claude Opus 5.5")
        #expect(prefs.modelNames.isEmpty, "the original name is no rename")
        prefs.setModelName("Mine", provider: "a", model: "m")
        prefs.setModelName(nil, provider: "a", model: "m")
        #expect(prefs.isEmpty)
        prefs.addExtra("x", provider: "A")
        prefs.setModelName("X", provider: "a", model: "x")
        prefs.setHidden(true, provider: "a", model: "x")
        prefs.removeExtra("x", provider: "a")
        #expect(prefs.isEmpty, "removing an added model forgets its name and switch")
    }

    @Test func aModelNameWithoutItsProviderIsUsedOnlyWhenItIsTheOnlyOne() {
        var prefs = ProviderPrefs()
        prefs.setModelName("Opus", provider: "anthropic", model: "claude-opus-5.5")
        #expect(prefs.modelName(anyProvider: "claude-opus-5.5") == "Opus")
        prefs.setModelName("Opus via Router", provider: "openrouter", model: "claude-opus-5.5")
        #expect(prefs.modelName(anyProvider: "claude-opus-5.5") == nil, "two names: neither guessed")
        #expect(prefs.modelName(provider: "openrouter", model: "claude-opus-5.5") == "Opus via Router")
    }

    @Test func theActiveCopyNamesModelsEverywhere() {
        // A model id no other test uses: the active copy is shared by every test running at once.
        let id = "zz-provider-manager-test-model"
        let before = ProviderPrefs.active
        defer { ProviderPrefs.setActive(before) }
        var prefs = before
        prefs.setModelName("Test Brain", provider: "zz-test", model: id)
        prefs.setProviderName("Test Provider", provider: "zz-test")
        ProviderPrefs.setActive(prefs)
        #expect(ModelNames.displayModelName(id) == "Test Brain")
        #expect(ModelNames.displayModelName(id, provider: "zz-test") == "Test Brain")
        #expect(ModelNames.builtInModelName(id) != "Test Brain", "the original name is still known")
        #expect(ModelNames.providerDisplayName("zz-test") == "Test Provider")
        #expect(ModelOptions.describe(id: id, provider: "zz-test", row: nil).providerName == "Test Provider", "before the catalog is read")
    }
}

@MainActor @Suite struct ProviderRemovalForgetsTests {
    @Test func forgetClearsOneProviderOnly() {
        var prefs = ProviderPrefs()
        prefs.setProviderName("Work", provider: "custom:home")
        prefs.setModelName("Llama", provider: "custom:home", model: "llama-3.3-70b")
        prefs.setHidden(true, provider: "custom:home", model: "qwen3")
        prefs.addExtra("mine", provider: "custom:home")
        prefs.setProviderName("Server", provider: "custom:home-server")
        prefs.setHidden(true, provider: "custom:home-server", model: "qwen3")
        prefs.forget(provider: "Custom:Home")
        #expect(prefs.providerName("custom:home") == nil && prefs.extraModels("custom:home").isEmpty)
        #expect(prefs.modelName(provider: "custom:home", model: "llama-3.3-70b") == nil)
        #expect(!prefs.isHidden(provider: "custom:home", model: "qwen3"))
        #expect(prefs.providerName("custom:home-server") == "Server", "a provider whose id starts the same is kept")
        #expect(prefs.isHidden(provider: "custom:home-server", model: "qwen3"))
    }

    @Test func deletingYourOwnProviderForgetsItsNamesAndHiddenModels() async throws {
        let client = PagesFakeClient { _ in ["ok": true, "endpoints": []] }
        let model = CustomProvidersModel(api: GatewaySettingsAPI(client: client), readOnly: false, account: nil)
        let store = ProviderPrefsStore(fileURL: nil)
        model.prefsStore = store
        model.providers = [home]
        store.update {
            $0.setModelName("Llama", provider: "custom:home-server", model: "llama-3.3-70b")
            $0.setHidden(true, provider: "custom:home-server", model: "qwen3-coder-30b")
            $0.setProviderName("Router", provider: "openrouter")
        }
        try await model.delete("home-server")
        #expect(store.prefs.modelName(provider: "custom:home-server", model: "llama-3.3-70b") == nil)
        #expect(!store.prefs.isHidden(provider: "custom:home-server", model: "qwen3-coder-30b"), "adding it again starts fresh")
        #expect(store.prefs.providerName("openrouter") == "Router", "other providers keep theirs")
    }
}

@MainActor @Suite struct ProviderSearchTests {
    @Test func searchFindsProvidersByWhatItsPagesDo() {
        let index = SettingsSearch.index()
        for words in ["rename model", "hide model", "show models", "model names", "custom provider"] {
            #expect(SettingsSearch.results(words, in: index).contains { $0.target == .root("providers") }, "\(words)")
        }
    }

    @Test func appIconIsSearchableWhereverItsRowIs() {
        // The Mac's App Icon page sets the Dock's icon: the search no longer drops it there.
        let index = SettingsSearch.index()
        #expect(index.contains { $0.id == "app:app-icon" })
        #expect(SettingsSearch.results("dock icon", in: index).contains { $0.target == .root("app-icon") })
    }
}

@Suite struct ProviderPrefsSyncTests {
    private var sample: ProviderPrefs {
        var prefs = ProviderPrefs()
        prefs.setProviderName("Work", provider: "anthropic")
        prefs.setModelName("Big", provider: "anthropic", model: "claude-opus-5.5")
        prefs.setHidden(true, provider: "openrouter", model: "x-ai/grok-5")
        prefs.addExtra("b-model", provider: "nous")
        prefs.addExtra("a-model", provider: "nous")
        return prefs
    }

    @Test func roundTripsThroughTheSyncDocument() throws {
        let json = sample.json
        #expect(json["providers"]?["anthropic"]?.string == "Work")
        #expect(json["models"]?["anthropic::claude-opus-5.5"]?.string == "Big")
        #expect(json["hidden"]?.array == ["openrouter::x-ai/grok-5"])
        #expect(json["extra"]?["nous"]?.array == ["b-model", "a-model"], "added models keep their order")
        #expect(ProviderPrefs(json: json) == sample)
        let data = try json.encoded()
        #expect(ProviderPrefs(json: try JSONValue.parse(data)) == sample)
        #expect(ProviderPrefs(json: nil).isEmpty && ProviderPrefs(json: ["hidden": "nope"]).isEmpty, "junk reads as nothing")
    }

    @Test func mergesChoiceByChoice() {
        let base = sample
        var mine = base
        mine.setHidden(true, provider: "anthropic", model: "claude-sonnet-5")   // hidden here
        mine.setModelName(nil, provider: "anthropic", model: "claude-opus-5.5")  // name reset here
        var theirs = base
        theirs.setProviderName("Router", provider: "openrouter")                 // renamed on the other device
        theirs.setHidden(false, provider: "openrouter", model: "x-ai/grok-5")    // shown again there
        theirs.setProviderName("Their Work", provider: "anthropic")
        let rebased = ProviderPrefs.merged(local: mine, remote: theirs, base: base, merge: .rebase)
        #expect(rebased.isHidden(provider: "anthropic", model: "claude-sonnet-5"))
        #expect(rebased.modelName(provider: "anthropic", model: "claude-opus-5.5") == nil, "this device's reset stays")
        #expect(rebased.providerName("openrouter") == "Router")
        #expect(!rebased.isHidden(provider: "openrouter", model: "x-ai/grok-5"))
        #expect(rebased.providerName("anthropic") == "Their Work", "unchanged here: the other device's")
        #expect(rebased.extraModels("nous") == ["b-model", "a-model"])

        #expect(ProviderPrefs.merged(local: mine, remote: theirs, base: base, merge: .replace) == theirs)
        let joined = ProviderPrefs.merged(local: mine, remote: theirs, base: nil, merge: .firstContact)
        #expect(joined.providerName("anthropic") == "Work" && joined.providerName("openrouter") == "Router", "both kept, this device first")
    }

    @MainActor @Test func aRenameAndAHiddenModelTravelFromThePhoneToTheMac() async {
        let server = SyncFakeServer()
        func device(_ name: String) -> (GatewaySync, ProviderPrefsStore) {
            let client = FakeGatewayClient()
            client.onCall { method, params in server.handle(method, params) }
            let sync = GatewaySync(client: client, accountId: "http://gw|me", deviceName: name,
                                   defaults: UserDefaults(suiteName: "hq.providers.test.\(name).\(UUID().uuidString)")!,
                                   knownDirectory: FileManager.default.temporaryDirectory.appending(path: "providers-sync-\(UUID().uuidString)"),
                                   defaultRow: { RosterProfile(json: server.row) })
            sync.debounceNanoseconds = 1_000_000_000_000
            sync.backoffUnit = 0.001
            let store = ProviderPrefsStore(fileURL: nil)
            store.syncChanged = { [weak sync] in sync?.changed("providers") }
            sync.register(store)
            return (sync, store)
        }
        func round(_ sync: GatewaySync) async { sync.pulled(); await sync.flushNow(); sync.pulled() }
        let (phoneSync, phone) = device("iPhone"), (macSync, mac) = device("Mac")
        await round(phoneSync); await round(macSync)
        phone.update {
            $0.setProviderName("Work Claude", provider: "anthropic")
            $0.setHidden(true, provider: "anthropic", model: "claude-sonnet-5")
        }
        await round(phoneSync); await round(macSync)
        #expect(mac.prefs.providerName("anthropic") == "Work Claude")
        #expect(mac.prefs.isHidden(provider: "anthropic", model: "claude-sonnet-5"))
        #expect(server.value("hermes-hq-sync.providers") != nil, "kept on the gateway")
        mac.update { $0.setHidden(false, provider: "anthropic", model: "claude-sonnet-5") }
        await round(macSync); await round(phoneSync)
        #expect(!phone.prefs.isHidden(provider: "anthropic", model: "claude-sonnet-5"), "shown again on the Mac, shown on the phone")
        #expect(phone.prefs.providerName("anthropic") == "Work Claude")
    }
}

@Suite struct EndpointAddModelTests {
    @Test func addModelSendsItAsTheEndpointsModels() {
        var draft = CustomProviderDraft(home)
        #expect(draft.body["models"] == nil, "a plain save sends no models")
        draft.addModels = [" my-tune "]
        #expect(draft.body["models"] == ["my-tune"])
        #expect(draft.body["id"] == "home-server" && draft.body["model"] == "llama-3.3-70b", "the entry and its default kept")
        #expect(draft.body["api_key"] == nil, "no key sent")
    }
}
