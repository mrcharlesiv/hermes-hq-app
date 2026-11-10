// The capabilities stream's calls (docs/spec/3x-capabilities.md §12): tools and their setup, connector add / remove /
// test / sign-in / tool rules / entry / logs, plugins, per-bot env. REST is scoped with `?profile=`, RPC with a
// `profile` param, writes go through the per-bot serial queue, and only the params each method lists are ever sent
// (an unknown param is refused with 4000).

import Foundation

extension CapabilitiesStore {
    private func refuse(_ title: String) throws {
        if readOnlyGateway { throw BotWriteError(title: title, reason: BotWriteError.readOnlyReason) }
    }

    nonisolated static func encode(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) ?? segment
    }

    private func rest(_ method: String, _ path: String, _ profile: String, extra: [URLQueryItem] = [], body: JSONValue? = nil) async throws -> JSONValue {
        let data = try await client.rest(method, path, query: query(profile, extra), body: body.flatMap { try? $0.encoded() })
        return data.isEmpty ? .null : try JSONValue.parseFast(data)
    }

    nonisolated static func isNotFound(_ error: Error) -> Bool { (error as? HTTPError)?.status == 404 }
    /// JSON-RPC "method not found": an older Hermes without this method.
    nonisolated static func isUnknownMethod(_ error: Error) -> Bool {
        guard let rpc = error as? RPCError else { return false }
        return rpc.code == -32601 || rpc.message.lowercased().contains("method not found") || rpc.message.lowercased().contains("unknown method")
    }

    // MARK: Tools (§4)

    func toolsets(_ profile: String) async throws -> [Toolset] {
        (try await rest("GET", "/api/tools/toolsets", profile).array ?? []).compactMap(Toolset.read)
    }

    func setToolset(_ name: String, enabled: Bool, profile: String) async throws {
        try refuse("Couldn’t Update \(name)")
        try await serial(profile) { [self] in
            _ = try await rest("PUT", "/api/tools/toolsets/\(Self.encode(name))", profile, body: ["enabled": .bool(enabled)])
        }
    }

    /// Calls per tool name over the last year. Best effort: the caller ignores a failure.
    func toolUsage(_ profile: String) async throws -> [String: Int] {
        let value = try await rest("GET", "/api/analytics/usage", profile, extra: [URLQueryItem(name: "days", value: "365")])
        var out: [String: Int] = [:]
        for row in value["tools"]?.array ?? [] {
            guard let tool = RosterText.trimmed(row["tool"]), let count = SkillUsage.read(row["count"]) else { continue }
            out[tool] = count
        }
        return out
    }

    /// nil: this gateway's Hermes has no tool setup routes (404).
    func toolsetConfig(_ name: String, profile: String) async throws -> ToolsetConfig? {
        do { return ToolsetConfig.read(try await rest("GET", "/api/tools/toolsets/\(Self.encode(name))/config", profile)) }
        catch where Self.isNotFound(error) { return nil }
    }

    /// True when the gateway says the provider needs a Nous sign-in before it works.
    func selectProvider(_ toolset: String, provider: String, capability: String?, profile: String) async throws -> Bool {
        try refuse("Couldn’t Select \(provider)")
        return try await serial(profile) { [self] in
            var body: [String: JSONValue] = ["provider": .string(provider)]
            if let capability { body["capability"] = .string(capability) }
            return try await rest("PUT", "/api/tools/toolsets/\(Self.encode(toolset))/provider", profile, body: .object(body))["needs_nous_auth"]?.bool ?? false
        }
    }

    func toolModels(_ toolset: String, provider: String, profile: String) async throws -> ToolModels? {
        do {
            return ToolModels.read(try await rest("GET", "/api/tools/toolsets/\(Self.encode(toolset))/models", profile,
                                                  extra: [URLQueryItem(name: "provider", value: provider)]))
        } catch where Self.isNotFound(error) { return nil }
    }

    func setToolModel(_ toolset: String, model: String, provider: String, profile: String) async throws {
        try refuse("Couldn’t Select \(model)")
        try await serial(profile) { [self] in
            _ = try await rest("PUT", "/api/tools/toolsets/\(Self.encode(toolset))/model", profile, body: ["model": .string(model), "provider": .string(provider)])
        }
    }

    func terminalBackends(_ profile: String) async throws -> [TerminalBackend] {
        let value = try await rest("GET", "/api/tools/terminal/backends", profile)
        let active = RosterText.trimmed(value["active"])
        return (value["backends"]?.array ?? []).compactMap { row in
            guard let name = RosterText.trimmed(row["name"]) else { return nil }
            return TerminalBackend(name: name, label: RosterText.trimmed(row["label"]) ?? name, description: RosterText.text(row["description"]),
                                   active: row["active"]?.bool ?? (name == active), status: RosterText.trimmed(row["status"]) ?? "ready",
                                   detail: RosterText.text(row["detail"]))
        }
    }

    func setTerminalBackend(_ name: String, profile: String) async throws {
        try refuse("Couldn’t Select \(name)")
        try await serial(profile) { [self] in
            _ = try await rest("PUT", "/api/tools/terminal/backend", profile, body: ["backend": .string(name)])
        }
    }

    /// `POST …/post-setup {key}` then the action's status every 1.2 s until it ends, or for `ceiling` (STRESS D14).
    func postSetup(_ toolset: String, key: String, profile: String, ceiling: Duration = .seconds(600)) -> AsyncThrowingStream<ActionStatus, Error> {
        let client = self.client, interval = pollInterval, readOnly = readOnlyGateway
        let scope = [URLQueryItem(name: "profile", value: profile)]
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    if readOnly { throw BotWriteError(title: "", reason: BotWriteError.readOnlyReason) }
                    let started = try JSONValue.parse(try await client.rest("POST", "/api/tools/toolsets/\(Self.encode(toolset))/post-setup", query: scope,
                                                                            body: try? JSONValue.object(["key": .string(key)]).encoded()))
                    let name = RosterText.trimmed(started["name"]) ?? "tools-post-setup"
                    let deadline = ContinuousClock.now + ceiling
                    while !Task.isCancelled {
                        let raw = try await client.rest("GET", "/api/actions/\(Self.encode(name))/status",
                                                        query: [URLQueryItem(name: "lines", value: "300")] + scope, body: nil)
                        let status = Self.status(try JSONValue.parse(raw), name: name)
                        continuation.yield(status)
                        if !status.running { break }
                        if ContinuousClock.now >= deadline { throw BotWriteError(title: "", reason: "The setup is taking too long. Check \(HostWord.phrase).") }
                        try await Task.sleep(for: interval)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Per-bot env (tool keys, plugin secrets, the Composio key)

    func setEnv(_ key: String, value: String, profile: String) async throws {
        try refuse("Couldn’t Save \(key)")
        try await serial(profile) { [self] in
            _ = try await rest("PUT", "/api/env", profile, body: ["key": .string(key), "value": .string(value)])
        }
    }

    /// A key that is already gone (404) counts as removed.
    func deleteEnv(_ key: String, profile: String) async throws {
        try refuse("Couldn’t Remove \(key)")
        try await serial(profile) { [self] in
            do { _ = try await rest("DELETE", "/api/env", profile, body: ["key": .string(key)]) }
            catch where Self.isNotFound(error) {}
        }
    }

    /// The stored value, or nil when this bot has none. Hermes allows 5 of these per 30 s (429).
    func revealEnv(_ key: String, profile: String) async throws -> String? {
        do { return RosterText.trimmed(try await rest("POST", "/api/env/reveal", profile, body: ["key": .string(key)])["value"]) }
        catch where Self.isNotFound(error) { return nil }
    }

    // MARK: Connectors (§5)

    func reloadMcp() async {
        _ = try? await client.call("reload.mcp", ["confirm": true], timeout: .seconds(30))
    }

    /// `mcp.servers.add`. `bearer` goes in `bearer_token`, never inside `config`.
    func mcpAdd(_ name: String, config: JSONValue, bearer: String?, profile: String) async throws {
        try refuse("Couldn’t Add \(name)")
        try await serial(profile) { [client] in
            var params: [String: JSONValue] = ["profile": .string(profile), "name": .string(name), "config": config]
            if let bearer, !bearer.isEmpty { params["bearer_token"] = .string(bearer) }
            _ = try await client.call("mcp.servers.add", .object(params), timeout: .seconds(30))
        }
    }

    /// `mcp.servers.remove`; a server that is already gone (4064) counts as removed.
    func mcpRemove(_ name: String, profile: String) async throws {
        try refuse("Couldn’t Remove \(name)")
        try await serial(profile) { [client] in
            do { _ = try await client.call("mcp.servers.remove", ["profile": .string(profile), "name": .string(name)], timeout: .seconds(30)) }
            catch let error as RPCError where error.code == 4064 {}
        }
    }

    func mcpTest(_ name: String, profile: String) async throws -> McpProbe {
        McpProbe.read(try await client.call("mcp.servers.test", ["profile": .string(profile), "name": .string(name)], timeout: .seconds(60)))
    }

    /// The server's own entry from `GET /api/config` (`mcp_servers[name]`); the rest of the body is dropped at once.
    /// nil: not in the gateway's configuration. Throws when the answer is not a configuration.
    func mcpEntry(_ name: String, profile: String) async throws -> JSONValue? {
        let data = try await client.rest("GET", "/api/config", query: query(profile), body: nil)
        guard data.count <= 4 * 1024 * 1024, let value = try? JSONValue.parse(data), value.object != nil else {
            throw BotWriteError(title: "", reason: "Your gateway’s answer wasn’t a configuration.")
        }
        guard let servers = value["mcp_servers"] else { return nil }
        guard let map = servers.object else { throw BotWriteError(title: "", reason: "Your gateway’s answer wasn’t a configuration.") }
        guard let entry = map[name], entry.object != nil else { return nil }
        return entry
    }

    /// §5.5-b: read the entry fresh, apply the rules, remove, add; one rollback when the add fails. All inside the
    /// bot's serial queue so no other write of this app lands in between.
    func saveToolRules(_ name: String, disabled: [String], discovered: [String], profile: String) async throws -> ToolRulesOutcome {
        try refuse("Couldn’t Save")
        return try await serial(profile) { [self, client] in
            guard let old = try await mcpEntry(name, profile: profile) else { return .gone }
            guard !McpToolFilter.looksRedacted(old) else {
                throw BotWriteError(title: "Couldn’t Save", reason: "This connector’s tool list can be changed on \(HostWord.phrase).")
            }
            let new = McpToolFilter.setDisabled(old, disabled: disabled, discovered: discovered)
            if new == old { return .unchanged }
            // Kept until the connector is known to be back, so a save cut off between the two calls is repaired on
            // the next Connectors read (`recoverConnectors`).
            toolRuleVault?.put(ToolRuleMarker(profile: profile, name: name, entry: old, at: Date()))
            do {
                _ = try await client.call("mcp.servers.remove", ["profile": .string(profile), "name": .string(name)], timeout: .seconds(30))
            } catch let error as RPCError {
                toolRuleVault?.remove(profile: profile, name: name)   // the gateway answered no: nothing was removed
                throw error
            }
            do {
                _ = try await client.call("mcp.servers.add", ["profile": .string(profile), "name": .string(name), "config": new], timeout: .seconds(30))
            } catch {
                let reason = Self.detail(error)
                do {
                    _ = try await client.call("mcp.servers.add", ["profile": .string(profile), "name": .string(name), "config": old], timeout: .seconds(30))
                } catch { return .lost(reason) }   // the marker stays: the next read tries again
                toolRuleVault?.remove(profile: profile, name: name)
                await reloadMcp()
                return .rolledBack(reason)
            }
            toolRuleVault?.remove(profile: profile, name: name)
            await reloadMcp()
            return .saved
        }
    }

    /// Lines of a gateway log file. Throws `HTTPError` 400/404 when the gateway keeps no such file.
    func logs(file: String, lines: Int, search: String?, profile: String) async throws -> [String] {
        var extra = [URLQueryItem(name: "file", value: file), URLQueryItem(name: "lines", value: String(lines))]
        if let search, !search.isEmpty { extra.append(URLQueryItem(name: "search", value: search)) }
        return (try await rest("GET", "/api/logs", profile, extra: extra)["lines"]?.array ?? []).map { RosterText.text($0) }
    }

    func oauthStart(_ name: String, redirect: String, profile: String) async throws -> McpOAuthStart {
        let value = try await client.call("mcp.servers.oauth.start", ["profile": .string(profile), "name": .string(name),
                                                                       "client_redirect_uri": .string(redirect)], timeout: .seconds(30))
        return McpOAuthStart(sessionId: RosterText.text(value["session_id"]), authURL: RosterText.text(value["auth_url"]))
    }

    /// Sends `code`/`state` or `error`; `iss` only when present.
    func oauthCallback(_ name: String, session: String, callback: LoopbackRelay.Callback, profile: String) async throws {
        var params: [String: JSONValue] = ["profile": .string(profile), "name": .string(name), "session_id": .string(session)]
        if let error = callback.error, !error.isEmpty { params["error"] = .string(error) } else if let code = callback.code { params["code"] = .string(code) }
        if let state = callback.state { params["state"] = .string(state) }
        if let iss = callback.iss, !iss.isEmpty { params["iss"] = .string(iss) }
        _ = try await client.call("mcp.servers.oauth.callback", .object(params), timeout: .seconds(30))
    }

    func oauthPoll(_ name: String, session: String, profile: String) async throws -> McpOAuthPoll {
        let value = try await client.call("mcp.servers.oauth.poll", ["profile": .string(profile), "name": .string(name),
                                                                      "session_id": .string(session)], timeout: .seconds(10))
        return McpOAuthPoll(status: RosterText.trimmed(value["status"]) ?? "pending", errorMessage: RosterText.text(value["error_message"]),
                            tools: value["tools"]?.array?.count ?? 0)
    }

    func oauthCancel(_ name: String, session: String, profile: String) async {
        _ = try? await client.call("mcp.servers.oauth.cancel", ["profile": .string(profile), "name": .string(name),
                                                                "session_id": .string(session)], timeout: .seconds(10))
    }

    // MARK: Plugins (§9)

    /// Every list read here is kept for the launch's add-on check ([load-cache] PluginListCache).
    func plugins(_ profile: String) async throws -> [PluginInfo] {
        let value = try await client.call("plugins.manage", ["action": "list", "profile": .string(profile)], timeout: .seconds(30))
        let list = (value["plugins"]?.array ?? []).compactMap(PluginInfo.read)
        if value["plugins"]?.array != nil { pluginLists.store(list, account: client.account, profile: profile) }
        return list
    }

    func plugin(_ action: PluginAction, profile: String) async throws -> PluginResult {
        try refuse("")
        // [load-cache] Whatever the answer, the kept list may be wrong now.
        defer { pluginLists.forget(account: client.account, profile: profile) }
        return try await serial(profile) { [client] in
            PluginResult.read(try await client.call("plugins.manage", action.params(profile: profile), timeout: action.timeout))
        }
    }
}
