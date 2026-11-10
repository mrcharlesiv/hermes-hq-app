// [provider-add] Add Provider: the presets' addresses, where each pick goes (Hermes' own key when the gateway lists one
// for that service, else a new Your Providers entry), the Built Into Hermes list, "Added", and Sign Out's call.

import Foundation
import Testing
@testable import HermesHQNative

nonisolated private func key(_ name: String, category: String = "provider", isSet: Bool = false, password: Bool = true,
                             label: String? = nil, primary: Bool = false) -> EnvVarInfo {
    EnvVarInfo(key: name, category: category, isPassword: password, isSet: isSet, providerLabel: label, providerPrimary: primary)
}

/// What today's Hermes lists (a few of its 87 provider keys), with Mistral's key as the tool key it is.
nonisolated private let gatewayKeys: [EnvVarInfo] = [
    key("OPENROUTER_API_KEY", isSet: true),
    key("DEEPSEEK_API_KEY"), key("DEEPSEEK_BASE_URL", password: false),
    key("FIREWORKS_API_KEY"),
    key("ANTHROPIC_API_KEY", isSet: true), key("ANTHROPIC_TOKEN"),
    key("XAI_API_KEY"), key("XAI_BASE_URL", password: false),
    key("GOOGLE_API_KEY"), key("GEMINI_API_KEY"), key("GEMINI_BASE_URL", password: false),
    key("OPENAI_API_KEY", label: "OpenAI API", primary: true), key("OPENAI_BASE_URL", password: false, label: "OpenAI API"),
    key("AWS_PROFILE", password: false), key("AWS_REGION", password: false),
    key("MISTRAL_API_KEY", category: "tool"),
]

@Suite struct ProviderPresetTests {
    @Test func everyPresetIsAWholeOpenAICompatibleAddress() throws {
        #expect(ProviderPreset.all.map(\.id) == ["openrouter", "together", "groq", "deepseek", "fireworks", "mistral", "ollama", "lmstudio"])
        for preset in ProviderPreset.all {
            let draft = preset.draft
            #expect(draft.addressProblem == nil, "\(preset.name): \(preset.baseURL)")
            #expect(draft.isNew && draft.name == preset.name && draft.key.isEmpty && draft.model.isEmpty)
            #expect(!draft.canSave, "the model is still to pick (Test Connection finds them)")
        }
        let addresses = Dictionary(uniqueKeysWithValues: ProviderPreset.all.map { ($0.id, $0.baseURL) })
        #expect(addresses["together"] == "https://api.together.xyz/v1")
        #expect(addresses["groq"] == "https://api.groq.com/openai/v1")
        #expect(addresses["mistral"] == "https://api.mistral.ai/v1")
        #expect(addresses["ollama"] == "http://127.0.0.1:11434/v1")
        #expect(addresses["lmstudio"] == "http://127.0.0.1:1234/v1")
        #expect(ProviderPreset.local.map(\.id) == ["ollama", "lmstudio"])
    }

    @Test func aServiceHermesHasBuiltInOpensItsKey() {
        let byID = Dictionary(uniqueKeysWithValues: ProviderPreset.all.map { ($0.id, $0) })
        #expect(ProviderAdding.route(byID["openrouter"]!, vars: gatewayKeys) == .key(gatewayKeys[0]))
        guard case .key(let deepseek) = ProviderAdding.route(byID["deepseek"]!, vars: gatewayKeys) else {
            Issue.record("DeepSeek opens Hermes' own key"); return
        }
        #expect(deepseek.key == "DEEPSEEK_API_KEY")
        guard case .key(let fireworks) = ProviderAdding.route(byID["fireworks"]!, vars: gatewayKeys) else {
            Issue.record("Fireworks opens Hermes' own key"); return
        }
        #expect(fireworks.key == "FIREWORKS_API_KEY")
    }

    @Test func otherServicesBecomeAnEntry() {
        let byID = Dictionary(uniqueKeysWithValues: ProviderPreset.all.map { ($0.id, $0) })
        for id in ["together", "groq", "mistral", "ollama", "lmstudio"] {
            #expect(ProviderAdding.route(byID[id]!, vars: gatewayKeys) == .custom(byID[id]!.draft), "\(id)")
        }
        // Mistral's key is a tool key (voice), not a way to its chat models.
        #expect(ProviderAdding.route(byID["mistral"]!, vars: gatewayKeys) != .key(gatewayKeys.last!))
        // An older Hermes without DeepSeek's key: an entry at DeepSeek's address instead.
        #expect(ProviderAdding.route(byID["deepseek"]!, vars: []) == .custom(byID["deepseek"]!.draft))
    }

    @Test func listsHermesBuiltInsOnceWithTheKeyToPaste() {
        let builtIns = ProviderAdding.builtIns(gatewayKeys)
        let names = builtIns.map(\.name)
        #expect(!names.contains("OpenRouter") && !names.contains("DeepSeek") && !names.contains("Fireworks AI"), "with the presets")
        #expect(!names.contains("AWS Bedrock"), "no key to paste")
        #expect(!names.contains("Other") && !names.contains { $0.contains("Mistral") }, "tool keys aren't providers")
        let keys = Dictionary(uniqueKeysWithValues: builtIns.map { ($0.name, $0.key.key) })
        #expect(keys["Anthropic"] == "ANTHROPIC_API_KEY")
        #expect(keys["xAI"] == "XAI_API_KEY", "never the address")
        #expect(keys["Gemini"] == "GOOGLE_API_KEY" || keys["Gemini"] == "GEMINI_API_KEY")
        #expect(keys["OpenAI API"] == "OPENAI_API_KEY", "the gateway's main key")
        #expect(builtIns.first { $0.name == "Anthropic" }?.detail == "Claude API access (Sonnet, Opus, Haiku)")
        #expect(names.firstIndex(of: "Anthropic")! < names.firstIndex(of: "xAI")!, "the API Keys cards' order")
    }

    @Test func primaryKeyPrefersTheGatewaysMark() {
        #expect(ProviderAdding.primaryKey([key("X_TOKEN"), key("X_API_KEY")])?.key == "X_API_KEY")
        #expect(ProviderAdding.primaryKey([key("X_TOKEN", primary: true), key("X_API_KEY")])?.key == "X_TOKEN")
        #expect(ProviderAdding.primaryKey([key("X_BASE_URL", password: true)]) == nil)
    }

    @Test func saysWhatIsAddedAlready() {
        let byID = Dictionary(uniqueKeysWithValues: ProviderPreset.all.map { ($0.id, $0) })
        let mine = [CustomProvider(id: "together", name: "Together", baseURL: "https://API.together.xyz/v1", model: "m"),
                    CustomProvider(id: "lab", name: "Lab", baseURL: "http://127.0.0.1:1234/v1", model: "m")]
        #expect(ProviderAdding.isAdded(byID["openrouter"]!, vars: gatewayKeys, custom: []), "its key is set")
        #expect(!ProviderAdding.isAdded(byID["deepseek"]!, vars: gatewayKeys, custom: []))
        #expect(ProviderAdding.isAdded(byID["together"]!, vars: gatewayKeys, custom: mine), "one of Your Providers is there")
        #expect(!ProviderAdding.isAdded(byID["groq"]!, vars: gatewayKeys, custom: mine))
        #expect(ProviderAdding.isAdded(byID["lmstudio"]!, vars: gatewayKeys, custom: mine))
        #expect(!ProviderAdding.isAdded(byID["ollama"]!, vars: gatewayKeys, custom: mine), "same computer, another port")
    }

    @Test func readsTheGatewaysMainKeyMark() {
        let rows = EnvVarInfo.list(["OPENAI_API_KEY": ["category": "provider", "is_password": true, "provider_primary": true],
                                    "OPENAI_BASE_URL": ["category": "provider"]])
        #expect(rows.map(\.providerPrimary) == [true, false])
    }
}

@Suite struct ProviderSignOutTests {
    @Test func offersSignOutOnlyWhereHermesCan() throws {
        let nous = try #require(OAuthProviderRow(["id": "nous", "name": "Nous Portal", "disconnectable": true,
                                                  "status": ["logged_in": true]]))
        #expect(nous.connected && nous.canSignOut)
        let claude = try #require(OAuthProviderRow(["id": "claude-code", "name": "Claude Code", "disconnectable": false,
                                                    "status": ["logged_in": true]]))
        #expect(!claude.canSignOut, "another app owns it")
        let out = try #require(OAuthProviderRow(["id": "xai-oauth", "disconnectable": true, "status": ["logged_in": false]]))
        #expect(!out.canSignOut, "nothing to sign out of")
        let older = try #require(OAuthProviderRow(["id": "nous", "logged_in": true]))
        #expect(!older.canSignOut, "an older Hermes doesn't say")
    }

    @MainActor @Test func signOutMakesTheDesktopAppsCall() async throws {
        let client = PagesFakeClient { _ in ["ok": true, "provider": "openai-codex"] }
        try await GatewaySettingsAPI(client: client).signOutOAuthProvider("openai-codex")
        #expect(client.logLines == ["DELETE /api/providers/oauth/openai-codex"])
        let refused = GatewaySettingsAPI(client: PagesFakeClient { _ in ["ok": false] })
        await #expect(throws: SettingsSaveError.refused) { try await refused.signOutOAuthProvider("nous") }
    }
}
