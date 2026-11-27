// Port of the web's V:lib/mcp-tool-filter.ts (docs/spec/3x-capabilities.md §5.5): a server's optional `tools.include`
// (whitelist) / `tools.exclude` (denylist) decide which discovered tools the agent registers. `include` wins, no
// filter means all.

import Foundation

/// How far a bot may go with one tool of an MCP connector (`tools.permissions[tool]` in the connector's entry).
/// Hermes itself only knows on and off (`tools.include` / `tools.exclude`, which `.blocked` is written as); the
/// two asking levels are enforced by the Hermes HQ add-on (its `toolPermissions` status flag, 0.9.86), which puts
/// Hermes's own approval in front of the call. A tool with nothing stored runs without asking, as it always has.
nonisolated enum McpToolPermission: String, CaseIterable, Hashable, Sendable {
    case alwaysAllow = "always_allow"
    case autoReview = "auto_review"
    case needsApproval = "needs_approval"
    case blocked = "blocked"

    var title: String {
        switch self {
        case .alwaysAllow: "Always allow"
        case .autoReview: "Auto-review"
        case .needsApproval: "Needs approval"
        case .blocked: "Blocked"
        }
    }

    var shortTitle: String {
        switch self {
        case .alwaysAllow: "Always"
        case .autoReview: "Auto"
        case .needsApproval: "Approve"
        case .blocked: "Blocked"
        }
    }

    var subtitle: String {
        switch self {
        case .alwaysAllow: "Runs without asking"
        case .autoReview: "Asks before a call that changes something"
        case .needsApproval: "Asks you every time"
        case .blocked: "Hidden from this bot"
        }
    }

    var symbol: String {
        switch self {
        case .alwaysAllow: "checkmark.shield.fill"
        case .autoReview: "sparkles"
        case .needsApproval: "hand.raised.fill"
        case .blocked: "nosign"
        }
    }
}

nonisolated enum McpToolFilter {
    private static func names(_ value: JSONValue?) -> [String]? { value?.array.map { $0.compactMap(\.string) } }
    private static func toolsObject(_ server: JSONValue?) -> [String: JSONValue] { server?["tools"]?.object ?? [:] }

    static func read(_ server: JSONValue?) -> (include: [String]?, exclude: [String]?) {
        let tools = toolsObject(server)
        return (names(tools["include"]), names(tools["exclude"]))
    }

    /// Reads the stored `tools.permissions` map (tool name → permission).
    static func readPermissions(_ server: JSONValue?) -> [String: McpToolPermission] {
        guard let map = toolsObject(server)["permissions"]?.object else { return [:] }
        var out: [String: McpToolPermission] = [:]
        for (k, v) in map {
            if let raw = v.string, let perm = McpToolPermission(rawValue: raw) {
                out[k] = perm
            }
        }
        return out
    }

    /// The level stored for `name`, whether or not the tool is on: what it comes back as when it is unblocked.
    /// Nothing stored is `.alwaysAllow` (the tool runs without asking, as every tool did before levels).
    static func storedLevel(_ server: JSONValue?, _ name: String) -> McpToolPermission {
        let level = readPermissions(server)[name] ?? .alwaysAllow
        return level == .blocked ? .alwaysAllow : level
    }

    /// Effective permission for `name` on `server`: a tool that is off is `.blocked`, whatever is stored for it.
    static func permission(_ server: JSONValue?, _ name: String) -> McpToolPermission {
        guard isEnabled(server, name) else { return .blocked }
        return storedLevel(server, name)
    }

    /// Effective permissions for all `discovered` tools.
    static func permissions(_ server: JSONValue?, discovered: [String]) -> [String: McpToolPermission] {
        var out: [String: McpToolPermission] = [:]
        for name in discovered { out[name] = permission(server, name) }
        return out
    }

    /// Writes the levels: blocked tools through `tools.include` / `tools.exclude` (`setDisabled`), the two asking
    /// levels into `tools.permissions`. Kept as they are: entries for tools not in `discovered`, and a blocked
    /// tool's own stored level, so unblocking a tool that needed approval never leaves it running unasked.
    static func setPermissions(_ server: JSONValue, permissions: [String: McpToolPermission], discovered: [String]) -> JSONValue {
        let blocked = discovered.filter { permissions[$0] == .blocked }
        let updated = setDisabled(server, disabled: blocked, discovered: discovered)
        guard var next = updated.object else { return updated }
        var tools = toolsObject(updated)
        var permMap: [String: JSONValue] = [:]
        // Only well-formed levels are written back; a value some other hand left there in the wrong shape goes.
        for (name, level) in readPermissions(updated) where level == .autoReview || level == .needsApproval {
            permMap[name] = .string(level.rawValue)
        }
        for name in discovered {
            switch permissions[name] {
            case .autoReview?: permMap[name] = .string(McpToolPermission.autoReview.rawValue)
            case .needsApproval?: permMap[name] = .string(McpToolPermission.needsApproval.rawValue)
            case .alwaysAllow?: permMap[name] = nil
            case .blocked?, nil: break   // keeps what was stored
            }
        }
        if permMap.isEmpty { tools["permissions"] = nil } else { tools["permissions"] = .object(permMap) }
        if tools.isEmpty { next["tools"] = nil } else { next["tools"] = .object(tools) }
        return .object(next)
    }

    /// An explicit `include` (even []) is a whitelist: the runtime registers nothing for `[]`.
    static func isEnabled(_ server: JSONValue?, _ name: String) -> Bool {
        let filter = read(server)
        if let include = filter.include { return include.contains(name) }
        return !(filter.exclude?.contains(name) ?? false)
    }

    /// `setDisabledTools`: keeps the entry's mode and every stored name that was not discovered this time.
    static func setDisabled(_ server: JSONValue, disabled: [String], discovered: [String]) -> JSONValue {
        guard var next = server.object else { return server }
        let filter = read(server)
        let off = Set(disabled), seen = Set(discovered)
        var tools = toolsObject(server)
        func kept(_ stored: [String]?) -> [String] { (stored ?? []).filter { !seen.contains($0) } }
        if let include = filter.include {
            tools["include"] = .array((discovered.filter { !off.contains($0) } + kept(include)).map(JSONValue.string))
        } else {
            let names = discovered.filter { off.contains($0) } + kept(filter.exclude)
            if names.isEmpty { tools["exclude"] = nil } else { tools["exclude"] = .array(names.map(JSONValue.string)) }
        }
        if tools.isEmpty { next["tools"] = nil } else { next["tools"] = .object(tools) }
        return .object(next)
    }

    static func countEnabled(_ server: JSONValue?, _ names: [String]) -> Int { names.filter { isEnabled(server, $0) }.count }

    /// A future Hermes that redacts `/api/config` must never have a redacted secret written back (§5.5): any string
    /// in the entry that carries a redaction mark makes the tool editor read only.
    static func looksRedacted(_ value: JSONValue) -> Bool {
        switch value {
        case .string(let s): return s.contains("•") || s.contains("***") || s == McpEntryMask.MASK
        case .array(let items): return items.contains(where: looksRedacted)
        case .object(let map): return map.values.contains(where: looksRedacted)
        default: return false
        }
    }
}

/// Readable connector names and the app's own words for a failed check (port of ref:src/connector-failure.ts).
nonisolated enum ConnectorTitle {
    /// DECISION: names whose usual spelling is not "each word capitalised".
    static let known: [String: String] = [
        "github": "GitHub", "gitlab": "GitLab", "linkedin": "LinkedIn", "youtube": "YouTube", "hubspot": "HubSpot",
        "clickup": "ClickUp", "openai": "OpenAI", "postgresql": "PostgreSQL", "mongodb": "MongoDB", "icloud": "iCloud",
        "paypal": "PayPal", "bigquery": "BigQuery", "wordpress": "WordPress", "airtable": "Airtable", "composio": "Composio",
    ]

    static func title(for name: String) -> String {
        if let known = known[name.lowercased()] { return known }
        let words = name.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " }).map { word -> String in
            let lower = word.lowercased()
            if lower == "mcp" { return "MCP" }
            if lower == "api" { return "API" }
            if let known = known[lower] { return known }
            return word.prefix(1).uppercased() + word.dropFirst()
        }
        return words.isEmpty ? name : words.joined(separator: " ")
    }

    static let busyCheck = "The gateway was too busy to check this connector. Try again."
    private static let clientTimeout = JSRegex(#"took too long to answer|didn.t answer in time|may be busy|too busy|gateway (?:is |was )?busy|request timed out after \d+"#, "i")

    static func isBusy(_ error: String) -> Bool { clientTimeout.test(error) }

    /// Safe, actionable guidance: never shows raw provider URLs, headers or tokens.
    static func failureDetail(_ error: String, hasCommand: Bool, hasURL: Bool) -> String {
        if isBusy(error) { return busyCheck }
        if !hasCommand && !hasURL { return "This connector has no server address or launch command. Correct its gateway configuration, then try again." }
        let text = error.lowercased()
        if JSRegex(#"no such file|enoent|cannot find module|module not found"#).test(text) {
            return "A required program or file is missing on the gateway. Install it or correct the launch path there, then try again."
        }
        if JSRegex(#"401|403|unauthori[sz]ed|token|oauth|api.?key|authentication"#).test(text) {
            return "The connector needs valid credentials on the gateway. Update its sign-in or API key there, then try again."
        }
        if JSRegex(#"timeout|timed out"#).test(text) {
            return "The gateway could not reach this connector in time. Check the server address and network, then try again."
        }
        if JSRegex(#"reset|refused|closed|connect"#).test(text) {
            return "The connector ended or refused the connection. Check that its server is running and its address is correct, then try again."
        }
        return "The gateway could not start this connector. Check its launch command, server address and gateway logs, then try again."
    }
}
