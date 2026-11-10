// Port of the web's V:lib/mcp-tool-filter.ts (docs/spec/3x-capabilities.md §5.5): a server's optional `tools.include`
// (whitelist) / `tools.exclude` (denylist) decide which discovered tools the agent registers. `include` wins, no
// filter means all.

import Foundation

nonisolated enum McpToolFilter {
    private static func names(_ value: JSONValue?) -> [String]? { value?.array.map { $0.compactMap(\.string) } }
    private static func toolsObject(_ server: JSONValue?) -> [String: JSONValue] { server?["tools"]?.object ?? [:] }

    static func read(_ server: JSONValue?) -> (include: [String]?, exclude: [String]?) {
        let tools = toolsObject(server)
        return (names(tools["include"]), names(tools["exclude"]))
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
        "paypal": "PayPal", "bigquery": "BigQuery", "wordpress": "WordPress", "airtable": "Airtable", "composio": "Connect Apps",
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
