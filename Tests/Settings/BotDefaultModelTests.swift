// Tester batch 3, item 1 ("I can't find a way to change the default model for a profile other than default"): each
// bot's own Default Model. The model routes carry the bot's `?profile=`, the write goes to that bot alone (an expensive
// model asks first and writes nothing), the roster row takes the new model at once and keeps it over a read sent before
// the save, and Settings says whose model it changes.

import Foundation
import Testing
@testable import HermesHQNative

/// A scripted gateway that keeps each profile's model, as `profiles.list` and `POST /api/model/set?profile=` see it.
nonisolated final class ModelGateway: @unchecked Sendable {
    let client = BotsFakeGatewayClient()
    private let lock = NSLock()
    var models: [String: (model: String, provider: String)]
    /// How long a roster read takes to answer (its rows are the ones of when it was sent).
    var listDelay: Duration = .zero
    /// The next model-set answers, in order, before the real handling.
    var scripted: [@Sendable (JSONValue) throws -> JSONValue] = []

    init(_ models: [String: (model: String, provider: String)]) {
        self.models = models
        client.on("profiles.list") { [unowned self] _ in
            let (rows, delay) = self.withLock { (self.rows(), self.listDelay) }
            if delay > .zero { try await Task.sleep(for: delay) }
            return BotsTest.profilesResult(rows)
        }
        client.onREST { [unowned self] method, path, query, body in
            guard method == "POST", path == "/api/model/set" else { throw HTTPError(status: 404, body: nil) }
            let profile = query.first { $0.name == "profile" }?.value ?? "default"
            return try self.set(profile: profile, try JSONValue.parse(body ?? Data("{}".utf8))).encoded()
        }
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }

    private func rows() -> [JSONValue] {
        models.keys.sorted().map { name in
            ["name": .string(name), "is_default": .bool(name == "default"), "model": .string(models[name]!.model),
             "provider": .string(models[name]!.provider), "canonical_session": BotsTest.session("s-\(name)", lastActive: 100)]
        }
    }

    private func set(profile: String, _ params: JSONValue) throws -> JSONValue {
        if let next = withLock({ scripted.isEmpty ? nil : scripted.removeFirst() }) { return try next(params) }
        return try withLock {
            guard models[profile] != nil else {
                throw HTTPError(status: 404, body: #"{"detail":"Profile '\#(profile)' does not exist."}"#)
            }
            // Hermes answers the names it saved: an alias comes back as its provider.
            let provider = params["provider"]?.string == "claude" ? "anthropic" : params["provider"]?.string ?? ""
            let model = params["model"]?.string ?? ""
            models[profile] = (model, provider)
            return ["ok": true, "scope": "main", "provider": .string(provider), "model": .string(model)]
        }
    }
}

@MainActor
private func makeStore(_ gateway: ModelGateway) async -> BotStore {
    let store = BotStore(client: gateway.client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: .fast)
    await BotsTest.waitUntil { store.phase == .full }
    return store
}

/// The model-set calls the store made: their query and body.
private func modelSets(_ gateway: ModelGateway) -> [(query: [URLQueryItem], body: JSONValue)] {
    gateway.client.restCalls.filter { $0.path == "/api/model/set" }.map { call in
        (call.query, (try? JSONValue.parse(call.body ?? Data())) ?? .null)
    }
}

@MainActor @Suite(.serialized) struct BotDefaultModelTests {
    // MARK: The routes

    @Test func modelRoutesCarryTheBotsProfileAndSettingsKeepsItsOwn() async throws {
        let client = BotsFakeGatewayClient()
        client.onREST { _, path, _, _ in
            let answer: JSONValue = switch path {
            case "/api/model/options": ["providers": [["slug": "anthropic", "name": "Anthropic", "models": ["claude-opus-5.5"]]]]
            case "/api/model/auxiliary": ["tasks": .array([])]
            default: ["ok": true, "provider": "anthropic", "model": "claude-opus-5.5"]
            }
            return try answer.encoded()
        }
        let ivy = GatewaySettingsAPI(client: client, profile: "ivy")
        _ = try await ivy.modelInfo()
        #expect(try await ivy.modelOptions().map(\.slug) == ["anthropic"])
        _ = try await ivy.auxiliary()
        try await ivy.setModel(scope: "main", provider: "anthropic", model: "claude-opus-5.5")
        _ = try await ivy.moa()
        _ = try await ivy.saveMoa(["presets": .object([:])])
        let scoped = client.restCalls
        #expect(scoped.map(\.path) == ["/api/model/info", "/api/model/options", "/api/model/auxiliary", "/api/model/set",
                                       "/api/model/moa", "/api/model/moa"])
        for call in scoped {
            #expect(call.query.contains(URLQueryItem(name: "profile", value: "ivy")), "\(call.method) \(call.path) is Ivy's")
        }
        #expect(scoped[1].query.contains(URLQueryItem(name: "explicit_only", value: "1")), "the picker still asks for explicit models")

        // Settings › Model (no profile): the gateway's own, exactly as before.
        let own = GatewaySettingsAPI(client: client)
        _ = try await own.modelInfo()
        _ = try await own.modelOptions()
        try await own.setModel(scope: "main", provider: "anthropic", model: "claude-opus-5.5")
        for call in client.restCalls.dropFirst(scoped.count) {
            #expect(!call.query.contains { $0.name == "profile" }, "\(call.path) carries no profile")
        }
    }

    // MARK: The write

    @Test func savingWritesThatBotAloneAndItsRowShowsItAtOnce() async throws {
        let gateway = ModelGateway(["default": ("claude-opus-5.5", "anthropic"), "ivy": ("hermes-4", "nous")])
        let store = await makeStore(gateway)
        #expect(store.profile(named: "ivy")?.model == "hermes-4")
        try await store.setDefaultModel(name: "ivy", display: "Ivy", provider: "openrouter", model: "x-ai/grok-5")
        let sets = modelSets(gateway)
        #expect(sets.count == 1)
        #expect(sets.first?.query == [URLQueryItem(name: "profile", value: "ivy")])
        #expect(sets.first?.body == ["scope": "main", "provider": "openrouter", "model": "x-ai/grok-5"], "no confirm until asked")
        #expect(store.profile(named: "ivy")?.model == "x-ai/grok-5" && store.profile(named: "ivy")?.provider == "openrouter")
        #expect(store.profile(named: "default")?.model == "claude-opus-5.5", "the default bot keeps its own")
        #expect(gateway.withLock { gateway.models["default"]?.model } == "claude-opus-5.5")
        #expect(gateway.withLock { gateway.models["ivy"]?.model } == "x-ai/grok-5")
    }

    @Test func theRowTakesTheNamesHermesSaved() async throws {
        let gateway = ModelGateway(["default": ("hermes-4", "nous"), "ivy": ("hermes-4", "nous")])
        let store = await makeStore(gateway)
        try await store.setDefaultModel(name: "ivy", display: "Ivy", provider: "claude", model: "claude-opus-5.5")
        #expect(store.profile(named: "ivy")?.provider == "anthropic", "the alias came back as its provider")
    }

    @Test func anExpensiveModelAsksFirstAndWritesNothingUntilConfirmed() async throws {
        let gateway = ModelGateway(["default": ("hermes-4", "nous"), "ivy": ("hermes-4", "nous")])
        let store = await makeStore(gateway)
        gateway.withLock {
            gateway.scripted = [{ _ in ["ok": false, "confirm_required": true, "confirm_message": "About 5× the price of your current model."] }]
        }
        do {
            try await store.setDefaultModel(name: "ivy", display: "Ivy", provider: "anthropic", model: "claude-opus-ultra")
            Issue.record("the gateway asked first")
        } catch ModelSetError.confirm(let message) {
            #expect(message == "About 5× the price of your current model.")
        }
        #expect(store.profile(named: "ivy")?.model == "hermes-4", "nothing changed while asking")
        try await store.setDefaultModel(name: "ivy", display: "Ivy", provider: "anthropic", model: "claude-opus-ultra", confirm: true)
        #expect(modelSets(gateway).last?.body["confirm_expensive_model"] == true)
        #expect(modelSets(gateway).last?.query == [URLQueryItem(name: "profile", value: "ivy")])
        #expect(store.profile(named: "ivy")?.model == "claude-opus-ultra")
    }

    @Test func aReadOnlyGatewayRefusesWithoutSending() async throws {
        let gateway = ModelGateway(["default": ("hermes-4", "nous"), "ivy": ("hermes-4", "nous")])
        let store = await makeStore(gateway)
        store.readOnlyGateway = true
        do {
            try await store.setDefaultModel(name: "ivy", display: "Ivy", provider: "anthropic", model: "claude-opus-5.5")
            Issue.record("refused")
        } catch let error as BotWriteError {
            #expect(error.title == "Couldn’t Change Ivy’s Model" && error.reason == BotWriteError.readOnlyReason)
        }
        #expect(modelSets(gateway).isEmpty)
    }

    @Test func failuresSayWhyAndLeaveTheRowAlone() async throws {
        let gateway = ModelGateway(["default": ("hermes-4", "nous"), "ivy": ("hermes-4", "nous")])
        let store = await makeStore(gateway)
        // The bot is gone from the gateway (renamed or deleted on the computer): Hermes' 404, in its words.
        gateway.withLock { gateway.models["ivy"] = nil }
        do {
            try await store.setDefaultModel(name: "ivy", display: "Ivy", provider: "anthropic", model: "claude-opus-5.5")
            Issue.record("404")
        } catch let error as BotWriteError {
            #expect(error.title == "Couldn’t Change Ivy’s Model" && error.reason == "Profile 'ivy' does not exist.")
        }
        #expect(store.profile(named: "ivy")?.model == "hermes-4")
        // A refusal without a reason, and a dropped link.
        gateway.withLock {
            gateway.models["ivy"] = ("hermes-4", "nous")
            gateway.scripted = [{ _ in ["ok": false] }, { _ in throw RPCError(code: -33002, message: "not connected", data: nil) }]
        }
        do { try await store.setDefaultModel(name: "ivy", display: "Ivy", provider: "a", model: "b"); Issue.record("refused") } catch let error as BotWriteError {
            #expect(error.reason == "Your gateway didn’t accept the change.")
        }
        do { try await store.setDefaultModel(name: "ivy", display: "Ivy", provider: "a", model: "b"); Issue.record("offline") } catch let error as BotWriteError {
            #expect(error.reason == "Hermes HQ can’t reach your gateway right now. Try again when it’s back.")
        }
        #expect(store.profile(named: "ivy")?.model == "hermes-4")
        #expect(store.editing.modelWrites.isEmpty)
    }

    // MARK: The fence

    @Test func aReadSentBeforeTheSaveCantPutTheOldModelBack() async throws {
        let gateway = ModelGateway(["default": ("hermes-4", "nous"), "ivy": ("hermes-4", "nous")])
        let store = await makeStore(gateway)
        gateway.withLock { gateway.listDelay = .milliseconds(400) }
        let before = gateway.client.calls("profiles.list").count
        let stale = Task { await store.refresh() }          // its rows still say hermes-4
        #expect(await BotsTest.waitUntil { gateway.client.calls("profiles.list").count > before }, "the stale read went out")
        try await store.setDefaultModel(name: "ivy", display: "Ivy", provider: "openrouter", model: "x-ai/grok-5")
        await stale.value
        #expect(store.profile(named: "ivy")?.model == "x-ai/grok-5", "the read sent before the save didn't put hermes-4 back")
        #expect(store.profile(named: "ivy")?.provider == "openrouter")
        #expect(store.editing.modelWrites["ivy"] != nil)
        // A read sent after the save carries the new model: the fence goes.
        gateway.withLock { gateway.listDelay = .zero }
        await store.refresh()
        #expect(store.editing.modelWrites["ivy"] == nil)
        #expect(store.profile(named: "ivy")?.model == "x-ai/grok-5")
        // And the gateway changing it again (on the computer) shows.
        gateway.withLock { gateway.models["ivy"] = ("hermes-4", "nous") }
        await store.refresh()
        #expect(store.profile(named: "ivy")?.model == "hermes-4")
    }

    // MARK: The words

    @Test func settingsSaysWhoseModelItChanges() {
        #expect(SettingsWords.mainModelHeader(defaultBot: "Hermes") == "Hermes’s Default Model")
        #expect(SettingsWords.mainModelHeader(defaultBot: "  ") == "Default Profile’s Model", "an honest label without a name")
        #expect(SettingsWords.mainModelHeader(defaultBot: nil) == "Default Profile’s Model")
        // [model-scope] Owner 2026-11-03: "Applies to <Bot> only", and where the other bots' are.
        #expect(SettingsWords.mainModelFooter(defaultBot: "Hermes", otherBots: true)
                == "Applies to Hermes only. Other bots keep their own in Bot Info › Brain. A chat can still switch its own model.")
        #expect(SettingsWords.mainModelFooter(defaultBot: "Hermes", otherBots: false)
                == "Applies to Hermes only. A chat can still switch its own model.", "no other bots, no hint")
        #expect(SettingsWords.mainModelFooter(defaultBot: nil, otherBots: true).hasPrefix("Applies to the default bot only."))
        let section = SettingsWords.modelSectionFooter(defaultBot: "Hermes", otherBots: true)
        #expect(section.hasPrefix("Hermes’s models. They’re kept on the computer running Hermes, so every device uses them.")
                && section.hasSuffix("change them in each bot’s Bot Info › Brain."))
        #expect(section.components(separatedBy: "Hermes").count - 1 == 2, "Mac polish #134: not Hermes three times")
        #expect(!section.contains("your bots"), "it said “The models your bots use”, which read as every bot's")
        #expect(SettingsWords.modelSectionFooter(defaultBot: nil, otherBots: false).hasPrefix("The default profile’s models"))
        #expect(ConfigSectionView.footer("model", defaultBot: "Hermes", otherBots: true) == section, "Settings › Model shows it")
        #expect(ConfigSectionView.footer("chat").hasSuffix("Saved on the computer running Hermes."), "the other sections keep theirs")
    }

    /// [model-scope] Reasoning Effort and Fast Mode on Main Model are the default bot's too; a chat changes its own.
    @Test func mainModelDefaultsSayWhoseTheyAre() {
        let footer = SettingsWords.mainDefaultsFooter(defaultBot: "Hermes")
        #expect(footer.hasPrefix("How hard the model thinks before answering"))
        #expect(footer.hasSuffix("Applies to Hermes only. A chat can still change its own."))
        #expect(SettingsWords.mainDefaultsFooter(defaultBot: nil).contains("Applies to the default bot only."))
    }

    /// Tester 2026-10-30: a bot's own Fallback Models and Auxiliary Models say whose they are; [model-scope] Settings' own
    /// (the default bot's) say so too, and where the other bots' are.
    @Test func aBotsFallbackAndAuxiliaryPagesSayWhoseTheyAre() {
        #expect(SettingsWords.botScoped("Tried in order.", bot: "Ivy") == "Tried in order. Applies to Ivy only.")
        #expect(SettingsWords.botScoped("Tried in order.", bot: "Ivy", defaultBot: "Hermes", otherBots: true) == "Tried in order. Applies to Ivy only.",
                "a bot's own page names that bot, not the default")
        #expect(SettingsWords.botScoped("Tried in order.", bot: nil, defaultBot: "Hermes", otherBots: true)
                == "Tried in order. Applies to Hermes only. Other bots keep their own in Bot Info › Brain.")
        #expect(SettingsWords.botScoped("Tried in order.", bot: nil, defaultBot: "Hermes", otherBots: false) == "Tried in order. Applies to Hermes only.")
        #expect(SettingsWords.botScoped("Tried in order.", bot: "  ") == "Tried in order. Applies to the default bot only.",
                "a blank name is Settings' own page")
        #expect(BotModelPages.isDefault("default") && BotModelPages.isDefault("") && !BotModelPages.isDefault("ivy"),
                "the default bot edits Settings' own store")
    }

    @Test func aBotsChooserSaysWhoseModelItIs() {
        #expect(SettingsWords.botModelScope(bot: "Ivy", isDefault: false) == "Applies to Ivy only. A chat can still switch its own model.")
        // The default bot's Default Model is Settings › Model › Main Model (menu review #2: only a code comment said so).
        #expect(SettingsWords.botModelScope(bot: "Hermes", isDefault: true)
                == "Applies to Hermes only, the same as Settings › Model. A chat can still switch its own model.")
        #expect(SettingsWords.botModelFailureTitle("Ivy") == "Couldn’t Change Ivy’s Model")
    }

    /// [model-scope] The other places a model is picked: a custom provider made the default, a tool's model.
    @Test func otherModelPickersSayWhatTheyApplyTo() {
        #expect(SettingsWords.appliesOnly(to: "Hermes") == "Applies to Hermes only.")
        #expect(SettingsWords.appliesOnly(to: nil) == "Applies to the default bot only.")
        #expect(SettingsWords.customProviderDefaultFooter(model: "Llama 4", provider: "Studio", defaultBot: "Hermes")
                == "Makes Llama 4 from Studio the default model. Applies to Hermes only. A chat can still switch its own model.")
        #expect(SettingsWords.customProviderDefaultFooter(model: nil, provider: "Studio", defaultBot: nil)
                == "Makes Studio the default provider. Applies to the default bot only. A chat can still switch its own model.")
        #expect(SettingsWords.customProviderDefaultFooter(model: " ", provider: "Studio", defaultBot: "Hermes").hasPrefix("Makes Studio the default provider."))
        #expect(SettingsWords.customProviderIsDefault(defaultBot: "Hermes") == "New chats with Hermes use this provider’s default model.")
        #expect(SettingsWords.customProviderIsDefault(defaultBot: nil) == "New chats with the default bot use this provider’s default model.")
        #expect(SettingsWords.moaFooter(defaultBot: "Hermes")
                == "Several models answer each turn, and an aggregator model writes the reply from their answers. Applies to Hermes only.")
        #expect(SettingsWords.toolModelScope(bot: "Ivy") == "Applies to Ivy only.")
        #expect(SettingsWords.toolModelScope(bot: "") == "Applies to this bot only.")
        #expect(JobWords.modelScope(bot: "Ivy") == "Applies to this job only. Default uses Ivy’s own model.")
        #expect(JobWords.modelScope(bot: nil) == "Applies to this job only. Default uses the bot’s own model.")
    }
}
