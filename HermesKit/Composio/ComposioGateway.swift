// Connect Apps' gateway side (docs/spec/3x-capabilities.md §10.6): one shared record on the default profile, and per
// bot an MCP server named `composio` plus the key in that bot's env. The record key and id prefix are the web app's
// own (DECISION 10.6-a) so either app recognises a gateway the other set up; neither string is shown to the user.

import Foundation

nonisolated struct ComposioRecord: Codable, Equatable, Sendable {
    var userId: String
    var sessionId: String
    var allBots: Bool

    static let key = "dispatch-composio"
    static let server = "composio"
    static let envKey = "COMPOSIO_API_KEY"

    static func newUserID() -> String {
        "dispatch-" + (0..<6).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    static func read(_ value: JSONValue?) -> ComposioRecord? {
        guard let value, let user = RosterText.trimmed(value["userId"]) else { return nil }
        return ComposioRecord(userId: user, sessionId: RosterText.text(value["sessionId"]), allBots: value["allBots"]?.bool ?? false)
    }

    var json: JSONValue { ["userId": .string(userId), "sessionId": .string(sessionId), "allBots": .bool(allBots)] }

    /// The entry a bot gets: the session's MCP URL and the literal `${COMPOSIO_API_KEY}` reference, never the key.
    static func entry(mcpURL: String) -> JSONValue { ["url": .string(mcpURL), "headers": ["x-api-key": "${COMPOSIO_API_KEY}"]] }
}

@MainActor final class ComposioGateway {
    let store: CapabilitiesStore
    var client: any GatewayClient { store.client }
    var readOnly: Bool { store.readOnlyGateway }

    init(store: CapabilitiesStore) { self.store = store }

    /// The shared record, read straight from the gateway (always before a write).
    func record() async throws -> ComposioRecord? {
        // [offline] §6.2 via 3x §17.4: a read gets one quick retry, none while the gateway cannot be reached.
        let value = try await QueryRetry.read { try await self.client.call("profiles.list", ["include_sessions": false], timeout: .seconds(30)) }
        let rows = value["profiles"]?.array ?? value.array ?? []
        let row = rows.first { RosterText.trimmed($0["name"]) == "default" }
        return ComposioRecord.read(row?["ui_meta"]?[ComposioRecord.key])
    }

    func write(_ record: ComposioRecord?) async throws {
        guard !readOnly else { throw BotWriteError(title: "", reason: BotWriteError.readOnlyReason) }
        let value = try await client.call("profiles.configure", ["name": "default", "ui_meta": [ComposioRecord.key: record?.json ?? .null]],
                                          timeout: .seconds(30))
        guard value["applied"]?["ui_meta"]?.bool == true else {
            throw BotWriteError(title: "", reason: "This gateway couldn’t save the Connect Apps setting.")
        }
    }

    /// The bot's `composio` server, when it has one.
    func server(_ profile: String) async throws -> McpServer? {
        try await QueryRetry.read { try await self.store.mcpServers(profile) }.first { $0.name == ComposioRecord.server }
    }

    /// Give a bot the apps: the key into its env, the server (replacing an old one), then a reload.
    func turnOn(_ profile: String, key: String, mcpURL: String) async throws {
        try await store.setEnv(ComposioRecord.envKey, value: key, profile: profile)
        try await store.mcpRemove(ComposioRecord.server, profile: profile)
        try await store.mcpAdd(ComposioRecord.server, config: ComposioRecord.entry(mcpURL: mcpURL), bearer: nil, profile: profile)
        await store.reloadMcp()
    }

    /// Take the apps away again: the server and the env key. Connected accounts stay with Composio.
    func turnOff(_ profile: String) async throws {
        try await store.mcpRemove(ComposioRecord.server, profile: profile)
        try await store.deleteEnv(ComposioRecord.envKey, profile: profile)
        await store.reloadMcp()
    }

    /// The key a bot on this gateway already holds (an explicit tap only; DECISION 10.4-a). Held in memory only.
    func revealKey(_ profile: String) async throws -> String? { try await store.revealEnv(ComposioRecord.envKey, profile: profile) }
}
