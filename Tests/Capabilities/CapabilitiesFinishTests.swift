// Capabilities, review fixes: a refused replacement key leaves the saved key alone; a tool-list save cut off between
// remove and add is repaired on the next Connectors read; the All Bots pass forgets bots that left the roster.

import Foundation
import Testing
@testable import HermesHQNative

nonisolated final class MemoryToolRuleVault: ToolRuleVault, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [ToolRuleMarker] = []
    func all() -> [ToolRuleMarker] { lock.withLock { rows } }
    func put(_ marker: ToolRuleMarker) { lock.withLock { rows.removeAll { $0.profile == marker.profile && $0.name == marker.name }; rows.append(marker) } }
    func remove(profile: String, name: String) { lock.withLock { rows.removeAll { $0.profile == profile && $0.name == name } } }
}

/// A scripted gateway holding one bot's connectors: `/api/config`, add (4090 on a duplicate), remove, reload.
nonisolated final class ConnectorScript: @unchecked Sendable {
    let client = BotsFakeGatewayClient()
    private let lock = NSLock()
    private var servers: [String: JSONValue]
    var failAdds = 0
    var dropAfterRemove = false

    var names: [String] { lock.withLock { servers.keys.sorted() } }
    func entry(_ name: String) -> JSONValue? { lock.withLock { servers[name] } }

    init(_ servers: [String: JSONValue]) {
        self.servers = servers
        client.onREST { [unowned self] _, path, _, _ in
            guard path == "/api/config" else { throw HTTPError(status: 404, body: nil) }
            return try JSONValue.object(["mcp_servers": .object(self.lock.withLock { self.servers })]).encoded()
        }
        client.on("mcp.servers.remove") { [unowned self] params in
            self.lock.withLock { self.servers[params["name"]?.string ?? ""] = nil }
            if self.dropAfterRemove { throw URLError(.networkConnectionLost) }
            return ["ok": true]
        }
        client.on("mcp.servers.add") { [unowned self] params in
            try self.lock.withLock {
                let name = params["name"]?.string ?? ""
                if self.failAdds > 0 { self.failAdds -= 1; throw URLError(.timedOut) }
                if self.servers[name] != nil { throw RPCError(code: 4090, message: "server '\(name)' already exists", data: nil) }
                self.servers[name] = params["config"]
            }
            return ["ok": true]
        }
        client.on("mcp.servers.list") { [unowned self] _ in
            ["servers": .array(self.names.map { ["name": .string($0), "transport": "http"] })]
        }
        client.on("reload.mcp") { _ in ["ok": true] }
    }
}

@Suite(.serialized) @MainActor struct CapabilitiesFinishTests {
    // MARK: Tool-list save, cut off half way

    let old: JSONValue = ["url": "https://e.example/mcp", "headers": ["x-api-key": "${E_KEY}"]]

    func store(_ script: ConnectorScript) -> (CapabilitiesStore, MemoryToolRuleVault) {
        let store = CapabilitiesStore(client: script.client)
        let vault = MemoryToolRuleVault()
        store.toolRuleVault = vault
        return (store, vault)
    }

    @Test func aCleanSaveLeavesNoMarker() async throws {
        let script = ConnectorScript(["files": old])
        let (store, vault) = store(script)
        let outcome = try await store.saveToolRules("files", disabled: ["b"], discovered: ["a", "b"], profile: "ivy")
        guard case .saved = outcome else { Issue.record("expected saved, got \(outcome)"); return }
        #expect(script.entry("files")?["tools"]?["exclude"] == ["b"])
        #expect(vault.all().isEmpty)
        // An unchanged list writes nothing and keeps nothing.
        let removes = script.client.calls("mcp.servers.remove").count
        _ = try await store.saveToolRules("files", disabled: ["b"], discovered: ["a", "b"], profile: "ivy")
        #expect(script.client.calls("mcp.servers.remove").count == removes && vault.all().isEmpty)
    }

    @Test func aRolledBackSaveLeavesNoMarker() async throws {
        let script = ConnectorScript(["files": old])
        script.failAdds = 1
        let (store, vault) = store(script)
        let outcome = try await store.saveToolRules("files", disabled: ["b"], discovered: ["a", "b"], profile: "ivy")
        guard case .rolledBack = outcome else { Issue.record("expected rolledBack, got \(outcome)"); return }
        #expect(script.entry("files") == old && vault.all().isEmpty)
    }

    @Test func aConnectorLostInASaveComesBackOnTheNextRead() async throws {
        let script = ConnectorScript(["files": old, "other": ["command": "npx"]])
        script.failAdds = 2                                   // the add and the rollback both fail
        let (store, vault) = store(script)
        let outcome = try await store.saveToolRules("files", disabled: ["b"], discovered: ["a", "b"], profile: "ivy")
        guard case .lost = outcome else { Issue.record("expected lost, got \(outcome)"); return }
        #expect(script.names == ["other"] && vault.all().map(\.name) == ["files"])
        // Another bot's read does not touch it.
        _ = try await store.mcpServers("kim")
        #expect(script.names == ["other"])
        // The next Connectors read for this bot puts the old entry back, exactly as it was.
        let listed = try await store.mcpServers("ivy")
        #expect(listed.map(\.name) == ["files", "other"])
        #expect(script.entry("files") == old && vault.all().isEmpty)
        #expect(script.client.calls("mcp.servers.add").last?.params == ["profile": "ivy", "name": "files", "config": old])
        // And only once.
        let adds = script.client.calls("mcp.servers.add").count
        _ = try await store.mcpServers("ivy")
        #expect(script.client.calls("mcp.servers.add").count == adds)
    }

    @Test func aSaveCutOffAfterTheRemoveIsRepairedByANewStore() async throws {
        // The app is closed (or the link drops) right after the remove: a new store, as after a relaunch, repairs it.
        let script = ConnectorScript(["files": old])
        script.dropAfterRemove = true
        let (first, vault) = store(script)
        await #expect(throws: (any Error).self) {
            _ = try await first.saveToolRules("files", disabled: ["b"], discovered: ["a", "b"], profile: "ivy")
        }
        #expect(script.names.isEmpty && vault.all().count == 1)
        let relaunched = CapabilitiesStore(client: script.client)
        relaunched.toolRuleVault = vault
        #expect(await relaunched.recoverConnectors("ivy") == ["files"])
        #expect(script.entry("files") == old && vault.all().isEmpty)
    }

    @Test func recoveryNeverOverwritesOrResurrects() async throws {
        let script = ConnectorScript(["files": ["url": "https://new.example/mcp"]])
        let (store, vault) = store(script)
        // The connector is there (somebody added it again): the marker is dropped, nothing is written.
        vault.put(ToolRuleMarker(profile: "ivy", name: "files", entry: old, at: Date()))
        #expect(await store.recoverConnectors("ivy").isEmpty)
        #expect(script.entry("files")?["url"] == "https://new.example/mcp" && vault.all().isEmpty)
        #expect(script.client.calls("mcp.servers.add").isEmpty)
        // A marker older than 30 days is dropped unread.
        vault.put(ToolRuleMarker(profile: "ivy", name: "gone", entry: old, at: Date().addingTimeInterval(-31 * 24 * 3600)))
        #expect(await store.recoverConnectors("ivy").isEmpty && vault.all().isEmpty && script.entry("gone") == nil)
        // A read-only gateway is never written to.
        vault.put(ToolRuleMarker(profile: "ivy", name: "gone", entry: old, at: Date()))
        store.readOnlyGateway = true
        #expect(await store.recoverConnectors("ivy").isEmpty && script.entry("gone") == nil && vault.all().count == 1)
    }

    @Test func theKeychainVaultKeepsMarkersPerAccount() {
        let service = "tests.toolrules.\(UUID().uuidString)"
        let a = KeychainToolRuleVault(service: service, account: "a"), b = KeychainToolRuleVault(service: service, account: "b")
        defer { a.remove(profile: "ivy", name: "files"); a.remove(profile: "ivy", name: "web") }
        a.put(ToolRuleMarker(profile: "ivy", name: "files", entry: old, at: Date(timeIntervalSince1970: 1_800_000_000)))
        a.put(ToolRuleMarker(profile: "ivy", name: "web", entry: ["command": "npx"], at: Date(timeIntervalSince1970: 1_800_000_001)))
        #expect(a.all().map(\.name) == ["files", "web"] && a.all().first?.entry == old && b.all().isEmpty)
        a.remove(profile: "ivy", name: "files")
        #expect(a.all().map(\.name) == ["web"])
    }

    // [13-13] Sign-out takes the account's markers (they may hold header values); another account's stay.
    @Test func signingOutRemovesTheAccountsMarkers() {
        let service = "tests.toolrules.\(UUID().uuidString)"
        let a = KeychainToolRuleVault(service: service, account: "a"), b = KeychainToolRuleVault(service: service, account: "b")
        defer { a.removeAll(); b.removeAll() }
        a.put(ToolRuleMarker(profile: "ivy", name: "files", entry: old, at: Date()))
        b.put(ToolRuleMarker(profile: "ivy", name: "web", entry: old, at: Date()))
        a.removeAll()
        #expect(a.all().isEmpty)
        #expect(b.all().map(\.name) == ["web"])
    }

    // MARK: The All Bots pass

    @Test func theAllBotsPassForgetsBotsThatLeft() {
        #expect(ComposioVerified.pruned(["a", "b", "c"], roster: ["a", "c", "d"]) == ["a", "c"])
        #expect(ComposioVerified.pruned(["a", "b"], roster: []) == ["a", "b"], "a roster still loading forgets nobody")
        let account = "tests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: ComposioVerified.key(account)) }
        ComposioVerified.settle("ivy", account: account)
        ComposioVerified.settle("kim", account: account)
        #expect(ComposioVerified.read(account) == ["ivy", "kim"])
        // ivy is deleted, then made again under the same id: it is checked afresh.
        ComposioVerified.write(ComposioVerified.pruned(ComposioVerified.read(account), roster: ["kim"]), account: account)
        #expect(ComposioVerified.read(account) == ["kim"])
    }
}

/// In `ComposioTests` (serialized) because the Composio stub is process-wide.
extension ComposioTests {
    // MARK: A refused replacement key

    @Test func aRefusedReplacementKeyLeavesTheSavedKeyAlone() async throws {
        let keys = keychain()
        defer { keys.clear() }
        try keys.save("ak_good_key_AAAA")
        ComposioStub.reset { _ in (401, #"{"error":{"message":"Invalid API key"}}"#) }
        let client = client(keys)
        let model = ComposioModel(services: TabRecordingServices(), keys: keys, client: client)
        await model.runSetUp(typed: "ak_typo_key_BBBB")
        #expect(model.setupNotice?.title == "Key Not Accepted")
        #expect(keys.read() == "ak_good_key_AAAA", "a typo must not sign the owner out of Connect Apps")
        #expect(model.settingUp == false)
        // A 403 is the same story.
        ComposioStub.reset { _ in (403, #"{"error":{"message":"Forbidden"}}"#) }
        await model.runSetUp(typed: "ak_typo_key_CCCC")
        #expect(keys.read() == "ak_good_key_AAAA")
    }
}
