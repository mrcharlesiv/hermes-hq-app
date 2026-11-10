// [custom-providers] Your Providers: the rows Hermes' `GET /api/providers/custom-endpoints` answers, the body Save sends
// (`CustomEndpointUpdate` in hermes_cli/web_models.py: a key only when typed, "" to remove it, the id kept on a rename),
// Test Connection's answer, the calls' paths, and the chat menus asking again after a change.

import Foundation
import Testing
@testable import HermesHQNative

nonisolated private let together: JSONValue = [
    "id": "together", "name": "Together AI", "base_url": "https://api.together.ai/v1", "model": "deepseek-ai/DeepSeek-V4.1-Flash",
    "models": ["meta-llama/Llama-3.3-70B-Instruct-Turbo", "deepseek-ai/DeepSeek-V4.1-Flash"], "api_mode": "chat_completions",
    "context_length": 1048576, "discover_models": true, "has_api_key": true, "api_key_preview": "${CUSTOM_TOGETHER_API_KEY}",
    "is_current": false, "source": "providers",
]

@Suite struct CustomProviderRowTests {
    @Test func readsARow() throws {
        let row = try #require(CustomProvider(together))
        #expect(row.id == "together")
        #expect(row.name == "Together AI")
        #expect(row.model == "deepseek-ai/DeepSeek-V4.1-Flash")
        #expect(row.models == ["meta-llama/Llama-3.3-70B-Instruct-Turbo", "deepseek-ai/DeepSeek-V4.1-Flash"])
        #expect(row.mode == .chatCompletions)
        #expect(row.contextLength == 1048576)
        #expect(row.hasKey && row.discoverModels && !row.isCurrent && row.canDelete)
        #expect(row.shortAddress == "api.together.ai")
    }

    @Test func fillsWhatALeanRowLeavesOut() throws {
        let row = try #require(CustomProvider(["id": "local-127.0.0.1:8283", "base_url": "http://127.0.0.1:8283/v1", "model": "qwen3",
                                               "models": [], "api_mode": "", "context_length": nil, "source": "direct-config"]))
        #expect(row.name == "local-127.0.0.1:8283", "no name: its id")
        #expect(row.models == ["qwen3"], "the default is always a choice")
        #expect(row.mode == .automatic && row.contextLength == nil && row.discoverModels && !row.hasKey)
        #expect(!row.canDelete, "the default model's own address has no entry to delete")
        #expect(row.shortAddress == "127.0.0.1:8283")
        #expect(CustomProvider(["name": "No address", "id": "x"]) == nil)
        #expect(CustomProvider.list(["endpoints": [together, ["id": "bad"]]]).map(\.id) == ["together"])
    }
}

@Suite struct CustomProviderDraftTests {
    private func draft() throws -> CustomProviderDraft { CustomProviderDraft(try #require(CustomProvider(together))) }

    @Test func anEditKeepsItsIdAndLeavesTheKeyAlone() throws {
        var edit = try draft()
        edit.name = "  Together  "
        let body = edit.body
        #expect(body["id"] == "together", "a rename keeps the entry (and the chats using it)")
        #expect(body["name"] == "Together")
        #expect(body["api_mode"] == "chat_completions")
        #expect(body["context_length"]?.int == 1048576)
        #expect(body["make_default"] == false)
        #expect(body["api_key"] == nil, "no key typed: none sent, so the saved one stays")
        #expect(body["models"] == nil, "the found catalogue is never written into config.yaml")
    }

    @Test func aTypedKeyIsSentAndRemoveSendsEmpty() throws {
        var edit = try draft()
        edit.key = " sk-new "
        #expect(edit.body["api_key"] == "sk-new")
        edit.key = ""
        edit.removeKey = true
        #expect(edit.body["api_key"] == "")
        edit.key = "sk-again"
        #expect(edit.body["api_key"] == "sk-again", "a typed key wins over Remove")
    }

    @Test func aNewOneHasNoIdAndATidyAddress() {
        var new = CustomProviderDraft()
        new.name = "Home Server"
        new.baseURL = "http://192.168.1.20:8080/v1//"
        new.model = "llama-3.3-70b"
        let body = new.body
        #expect(body["id"] == nil)
        #expect(body["base_url"] == "http://192.168.1.20:8080/v1")
        #expect(body["api_mode"] == "")
        #expect(body["context_length"] == nil)
        #expect(new.isNew && new.canSave)
    }

    @Test func checksTheAddressAndContextWindow() {
        var new = CustomProviderDraft()
        new.name = "X"; new.model = "m"
        #expect(!new.canSave, "an address is needed")
        new.baseURL = "192.168.1.20:8080"
        #expect(new.addressProblem != nil && !new.canSave)
        new.baseURL = "ftp://host/v1"
        #expect(new.addressProblem != nil)
        new.baseURL = "https://host/v1"
        #expect(new.addressProblem == nil && new.canSave)
        new.contextLength = "lots"
        #expect(new.contextProblem != nil && !new.canSave)
        new.contextLength = " 131072 "
        #expect(new.contextProblem == nil && new.contextValue == 131072 && new.canSave)
    }

    @Test func savesOnlyWhatChanged() throws {
        let saved = try draft()
        var edit = saved
        #expect(!edit.differs(from: saved))
        edit.name = "Together AI "
        #expect(!edit.differs(from: saved), "spaces alone change nothing")
        edit.models.append("another")
        #expect(!edit.differs(from: saved), "choices alone change nothing")
        edit.choose("another")
        #expect(edit.differs(from: saved) && edit.model == "another")
        edit = saved
        edit.removeKey = true
        #expect(edit.differs(from: saved))
    }

    @Test func takesWhatTestConnectionFound() {
        var new = CustomProviderDraft()
        new.name = "Lab"
        new.baseURL = "http://10.0.0.5:8000"
        let test = CustomProviderTest(["ok": true, "reachable": true, "models": ["qwen3", "gpt-oss-sol-high"],
                                       "model_details": [["id": "qwen3"], ["id": "gpt-oss-sol-high", "canonical_model": "gpt-oss-sol",
                                                                            "reasoning_effort": "high"]],
                                       "transport_checked": "chat_completions", "resolved_base_url": "http://10.0.0.5:8000/v1"])
        new.apply(test)
        #expect(new.baseURL == "http://10.0.0.5:8000/v1", "the address that answered, as the desktop app saves it")
        #expect(new.model == "qwen3", "the first model when none was chosen")
        #expect(new.models == ["qwen3", "gpt-oss-sol-high"])
        #expect(new.body["model_details"] == nil, "qwen3 is no alias with routing")
        new.choose("gpt-oss-sol-high")
        #expect(new.body["model_details"]?.array?.count == 1, "only the chosen alias's routing goes")
        #expect(test.summary == "Connected using Chat Completions. Found 2 models.")
        var failed = CustomProviderDraft()
        failed.baseURL = "http://x/v1"
        failed.apply(CustomProviderTest(["ok": false, "reachable": false, "message": "Could not reach http://x/v1/models."]))
        #expect(failed.models.isEmpty && failed.model.isEmpty)
    }

    @Test func saysWhatATestFound() {
        #expect(CustomProviderTest(ok: true).summary == "Connected.")
        #expect(CustomProviderTest(ok: true, models: ["a"], transport: .automatic).summary == "Connected. Found 1 model.")
        #expect(CustomProviderTest(ok: false, reachable: true, message: "The endpoint rejected the API key.").summary
                == "The endpoint rejected the API key.")
        #expect(CustomProviderTest(ok: false, reachable: false).summary == "Couldn’t reach this address.")
    }
}

@MainActor @Suite(.serialized) struct CustomProviderCallTests {
    @Test func makesTheDesktopAppsCalls() async throws {
        let client = PagesFakeClient { request in
            switch (request.method, request.path) {
            case ("GET", "/api/providers/custom-endpoints"): ["endpoints": [together], "current": ["provider": "anthropic"]]
            case ("POST", "/api/providers/custom-endpoints/validate"): ["ok": true, "reachable": true, "models": ["m"]]
            case ("POST", "/api/providers/custom-endpoints/local-127.0.0.1:8283/activate"): ["ok": true]
            default: ["ok": true, "endpoints": []]
            }
        }
        let api = GatewaySettingsAPI(client: client)
        #expect(try await api.customProviders().map(\.name) == ["Together AI"])
        var draft = CustomProviderDraft(try #require(CustomProvider(together)))
        draft.name = "Together"
        #expect(try await api.saveCustomProvider(draft).isEmpty)
        #expect(try await api.testCustomProvider(draft).ok)
        try await api.activateCustomProvider("local-127.0.0.1:8283")
        _ = try await api.deleteCustomProvider("my provider")
        #expect(client.logLines == [
            "GET /api/providers/custom-endpoints",
            "POST /api/providers/custom-endpoints",
            "POST /api/providers/custom-endpoints/validate",
            "POST /api/providers/custom-endpoints/local-127.0.0.1:8283/activate",
            "DELETE /api/providers/custom-endpoints/my%20provider",
        ])
        #expect(client.log[1].body?["name"] == "Together" && client.log[1].body?["id"] == "together")
    }

    @Test func aRefusalThrows() async {
        let api = GatewaySettingsAPI(client: PagesFakeClient { _ in ["ok": false] })
        await #expect(throws: SettingsSaveError.refused) { _ = try await api.saveCustomProvider(CustomProviderDraft()) }
    }

    @Test func aChangeSendsTheMenusBackToTheGateway() {
        let cache = ModelCatalogCache.shared
        cache.reset()
        defer { cache.reset() }
        let mine = ModelCatalogCache.Key(account: "a", profile: "default", scope: "global")
        let other = ModelCatalogCache.Key(account: "b", profile: "default", scope: "global")
        cache.store(ModelOptions(providers: []), for: mine)
        cache.store(ModelOptions(providers: []), for: other)
        cache.markStale(account: "a")
        #expect(cache.fresh(mine) == nil && cache.cached(mine) != nil, "asked again, the old copy shown meanwhile")
        #expect(cache.fresh(other) != nil)
    }
}
