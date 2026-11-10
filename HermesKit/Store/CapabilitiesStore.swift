// Skills and Connectors for one bot (spec 1x-settings §9): the gateway's REST routes and MCP RPCs, scoped with
// `?profile=<bot>` (the web shim's rule). Writes are one at a time per bot. No hosted connectors, no MCP config edits.

import Foundation

@MainActor final class CapabilitiesStore: CapabilitiesService {
    let client: any GatewayClient
    /// The read-only testing switch: every write here refuses.
    var readOnlyGateway = false
    /// Install/uninstall polling cadence (`POLL_MS`).
    var pollInterval: Duration = .milliseconds(1200)
    /// Toggles queued per bot (the gateway saves one disabled list per profile).
    private var tails: [String: Task<Void, Never>] = [:]
    /// [capabilities] Where a connector's entry is kept while its tool list is being saved (ToolRuleRecovery.swift).
    /// nil = no recovery (tests that don't ask for it).
    var toolRuleVault: (any ToolRuleVault)?
    /// [load-cache] Where each bot's add-on list is kept between launches (tests pass their own).
    var pluginLists: PluginListCache = .shared

    init(client: any GatewayClient) { self.client = client }

    func query(_ profile: String, _ extra: [URLQueryItem] = []) -> [URLQueryItem] {
        extra + [URLQueryItem(name: "profile", value: profile)]
    }

    func json(_ data: Data) throws -> JSONValue { try JSONValue.parseFast(data) }

    private func body(_ value: JSONValue) -> Data? { try? value.encoded() }

    func serial<T: Sendable>(_ profile: String, _ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tails[profile]
        let task = Task { @MainActor () async throws -> T in
            await previous?.value
            return try await work()
        }
        tails[profile] = Task { @MainActor in _ = try? await task.value }
        return try await task.value
    }

    // MARK: Skills

    func skills(_ profile: String) async throws -> [SkillInfo] {
        let data = try await client.rest("GET", "/api/skills", query: query(profile), body: nil)
        return try await Self.decodeSkills(data)
    }

    /// [perf] Parsed and mapped off the main thread: the answer lands while the page is being pushed.
    @concurrent nonisolated static func decodeSkills(_ data: Data) async throws -> [SkillInfo] {
        (try JSONValue.parseFast(data).array ?? []).compactMap(skill)
    }

    nonisolated static func skill(_ row: JSONValue) -> SkillInfo? {
        guard let name = RosterText.trimmed(row["name"]) else { return nil }
        return SkillInfo(name: name, description: RosterText.text(row["description"]), category: RosterText.trimmed(row["category"]),
                         enabled: row["enabled"]?.bool ?? true, usage: SkillUsage.read(row["usage"]),
                         provenance: RosterText.trimmed(row["provenance"]))
    }

    func officialSkills(_ profile: String) async throws -> [OfficialSkill] {
        let data = try await client.rest("GET", "/api/skills/hub/official", query: query(profile), body: nil)
        return try await Self.decodeOfficial(data)
    }

    /// [perf] The whole hub catalog, parsed and mapped off the main thread.
    @concurrent nonisolated static func decodeOfficial(_ data: Data) async throws -> [OfficialSkill] {
        (try JSONValue.parseFast(data)["skills"]?.array ?? []).compactMap { row in
            guard let name = RosterText.trimmed(row["name"]), let identifier = RosterText.trimmed(row["identifier"]) else { return nil }
            return OfficialSkill(name: name, description: RosterText.text(row["description"]), identifier: identifier,
                                 category: RosterText.trimmed(row["category"]), installed: row["installed"]?.bool ?? false)
        }
    }

    /// [hub] `GET /api/skills/hub/search?q=`: every configured hub source, deduped by identifier (network-bound; the
    /// gateway gives up on a slow source after 30 s, so the read waits a little longer than that).
    func searchHub(_ query: String, profile: String) async throws -> HubSearchResult {
        let items = self.query(profile, [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "20")])
        let data: Data
        if let live = client as? LiveGatewayClient {
            data = try await live.rest("GET", "/api/skills/hub/search", query: items, body: nil, timeout: 45)
        } else {
            data = try await client.rest("GET", "/api/skills/hub/search", query: items, body: nil)
        }
        return try Self.decodeHub(data)
    }

    nonisolated static func decodeHub(_ data: Data) throws -> HubSearchResult {
        let value = try JSONValue.parseFast(data)
        var seen = Set<String>()
        let results = (value["results"]?.array ?? []).compactMap { row -> HubSkill? in
            guard let name = RosterText.trimmed(row["name"]), let identifier = RosterText.trimmed(row["identifier"]),
                  seen.insert(identifier).inserted else { return nil }
            return HubSkill(name: name, description: RosterText.text(row["description"]), identifier: identifier,
                            source: RosterText.trimmed(row["source"]) ?? "", trust: RosterText.trimmed(row["trust_level"]) ?? "community",
                            repo: RosterText.trimmed(row["repo"]))
        }
        let installed: Set<String> = Set((value["installed"]?.object ?? [:]).keys)
        return HubSearchResult(results: results, installed: installed)
    }

    func skillContent(_ name: String, profile: String) async throws -> String {
        let value = try json(try await client.rest("GET", "/api/skills/content",
                                                   query: query(profile, [URLQueryItem(name: "name", value: name)]), body: nil))
        return RosterText.text(value["content"])
    }

    func setSkill(_ name: String, enabled: Bool, profile: String) async throws {
        if readOnlyGateway { throw BotWriteError(title: "Couldn’t Change \(name)", reason: BotWriteError.readOnlyReason) }
        try await serial(profile) { [client] in
            _ = try await client.rest("PUT", "/api/skills/toggle", query: [URLQueryItem(name: "profile", value: profile)],
                                      body: try? JSONValue.object(["name": .string(name), "enabled": .bool(enabled)]).encoded())
        }
    }

    /// `POST /api/skills/hub/install {identifier}` then the action's status every 1.2 s until it ends.
    func install(_ identifier: String, profile: String) -> AsyncThrowingStream<ActionStatus, Error> {
        action(profile, path: "/api/skills/hub/install", body: ["identifier": .string(identifier)])
    }

    func uninstall(_ name: String, profile: String) -> AsyncThrowingStream<ActionStatus, Error> {
        action(profile, path: "/api/skills/hub/uninstall", body: ["name": .string(name)])
    }

    private func action(_ profile: String, path: String, body: JSONValue) -> AsyncThrowingStream<ActionStatus, Error> {
        let client = self.client, interval = pollInterval, readOnly = readOnlyGateway
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    if readOnly { throw BotWriteError(title: "", reason: BotWriteError.readOnlyReason) }
                    let started = try JSONValue.parse(try await client.rest("POST", path, query: [URLQueryItem(name: "profile", value: profile)],
                                                                            body: try? body.encoded()))
                    guard let name = RosterText.trimmed(started["name"]) else { throw HTTPError(status: 500, body: "no action name") }
                    while !Task.isCancelled {
                        let raw = try await client.rest("GET", "/api/actions/\(name)/status",
                                                        query: [URLQueryItem(name: "lines", value: "200"), URLQueryItem(name: "profile", value: profile)],
                                                        body: nil)
                        let status = Self.status(try JSONValue.parse(raw), name: name)
                        continuation.yield(status)
                        if !status.running { break }
                        try await Task.sleep(for: interval)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated static func status(_ value: JSONValue, name: String) -> ActionStatus {
        ActionStatus(name: RosterText.trimmed(value["name"]) ?? name, running: value["running"]?.bool ?? false,
                     exitCode: value["exit_code"]?.int, lines: (value["lines"]?.array ?? []).map { RosterText.text($0) })
    }

    /// The security scan refused the install (`parseInstallBlocked`, `V/store/hub-actions.ts:201-222`).
    nonisolated static func installBlocked(_ lines: [String]) -> (findings: Int, unverified: Bool)? {
        let text = lines.joined(separator: "\n")
        let current = JSRegex(#"Not installed:\s+the security scan found\s+(?:(\d+)\s+)?high-risk\s+pattern"#, "i")
        if let match = current.exec(text) {
            let unverified = JSRegex(#"never installs\s+unverified"#, "i").test(text)
            return (Int(match.groups[1]) ?? 0, unverified)
        }
        let legacy = JSRegex(#"Installation blocked:.*?\(([a-z_-]+) source \+ ([a-z_]+) verdict, (\d+) findings?\)"#, "i")
        guard let match = legacy.exec(text) else { return nil }
        return (Int(match.groups[3]) ?? 0, match.groups[1] != "official")
    }

    /// "The security scan flagged 2 items to review and the skill comes from an unverified source. Read the scan…"
    nonisolated static func blockedMessage(findings: Int, unverified: Bool) -> String {
        let what = findings > 0 ? "\(findings) item\(findings == 1 ? "" : "s")" : "risky patterns"
        return "The security scan flagged \(what) to review\(unverified ? " and the skill comes from an unverified source" : ""). "
            + "Read the scan before deciding whether to trust the author."
    }

    // MARK: Connectors

    func mcpServers(_ profile: String) async throws -> [McpServer] {
        await recoverConnectors(profile)   // a tool-list save cut off half way: put the connector back first
        let value = try await client.call("mcp.servers.list", ["profile": .string(profile)], timeout: .seconds(30))
        return (value["servers"]?.array ?? []).compactMap { row in
            guard let name = RosterText.trimmed(row["name"]) else { return nil }
            return McpServer(name: name, transport: RosterText.text(row["transport"]), enabled: row["enabled"]?.bool ?? true,
                             source: RosterText.trimmed(row["source"]) ?? "config", plugin: RosterText.trimmed(row["plugin"]),
                             status: nil, tools: nil, auth: RosterText.trimmed(row["auth"]), oauthTokensPresent: row["oauth_tokens_present"]?.bool,
                             url: RosterText.trimmed(row["url"]), command: RosterText.trimmed(row["command"]),
                             hasHeaders: !(row["headers"]?.object ?? [:]).isEmpty || RosterText.trimmed(row["auth"]) == "header")
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func mcpStatus(_ profile: String) async throws -> [String: (status: String, tools: Int)] {
        let value = try await client.call("mcp.servers.status", ["profile": .string(profile)], timeout: .seconds(30))
        var out: [String: (status: String, tools: Int)] = [:]
        for row in value["servers"]?.array ?? [] {
            guard let name = RosterText.trimmed(row["name"]) else { continue }
            out[name] = (RosterText.trimmed(row["status"]) ?? "configured", RosterText.count(row["tools"]) ?? 0)
        }
        return out
    }

    /// The one-key route, then `reload.mcp {"confirm": true}` (no `profile`: `ReloadMcpParams` has none).
    func setMcp(_ name: String, enabled: Bool, profile: String) async throws {
        if readOnlyGateway { throw BotWriteError(title: "Couldn’t Change \(name)", reason: BotWriteError.readOnlyReason) }
        try await serial(profile) { [client] in
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? name
            _ = try await client.rest("PUT", "/api/mcp/servers/\(encoded)/enabled", query: [URLQueryItem(name: "profile", value: profile)],
                                      body: try? JSONValue.object(["enabled": .bool(enabled)]).encoded())
            _ = try? await client.call("reload.mcp", ["confirm": true], timeout: .seconds(30))
        }
    }

    /// The gateway's `detail` from an HTTP error body, else plain words.
    nonisolated static func detail(_ error: Error) -> String {
        if let http = error as? HTTPError {
            if let body = http.body, let data = body.data(using: .utf8), let value = try? JSONValue.parse(data),
               let detail = RosterText.trimmed(value["detail"]) { return detail }
            return http.status == 404 ? "Your gateway doesn’t know this one." : http.plainWords
        }
        if let rpc = error as? RPCError { return rpc.plainReason }
        if let transport = PagesREST.transportReason(error) { return transport }   // can't reach the gateway (verify round 2)
        return (error as? LocalizedError)?.errorDescription ?? "Something went wrong. Try again."
    }
}
