// Wire types of the capabilities stream (docs/spec/3x-capabilities.md §12): tools and their setup, connector probes,
// plugins. Decoding is lenient everywhere: an unknown key is ignored, a missing optional field never fails a page.

import Foundation

/// A skill's use count as the gateway sent it: nil when absent or not a number, never below zero (§3.2, STRESS D11).
nonisolated enum SkillUsage {
    static func read(_ value: JSONValue?) -> Int? {
        guard case .number(let n)? = value, n.isFinite else { return nil }
        return max(0, Int(exactly: n.rounded(.towardZero)) ?? Int.max)
    }
}

// MARK: - Tools (§4)

nonisolated struct Toolset: Identifiable, Sendable, Hashable {
    var name: String
    var label: String
    var description: String
    var enabled: Bool
    var configured: Bool
    var tools: [String]
    var id: String { name }

    /// `isDesktopToolsetVisible` (V:lib/desktop-toolsets.ts:11-24).
    static let hidden: Set<String> = ["discord", "discord_admin", "yuanbao", "context_engine", "moa"]

    static func read(_ row: JSONValue) -> Toolset? {
        guard let name = RosterText.trimmed(row["name"]) else { return nil }
        return Toolset(name: name, label: stripLabel(RosterText.trimmed(row["label"]) ?? name), description: RosterText.text(row["description"]),
                       enabled: row["enabled"]?.bool ?? false, configured: row["configured"]?.bool ?? true,
                       tools: (row["tools"]?.array ?? []).compactMap(\.string))
    }

    /// `stripToolsetLabel` (V:app/settings/helpers.ts:12-16): /^[\p{Emoji}\p{Extended_Pictographic}\s]+/u removed; if that
    /// leaves nothing the label stays as sent. (Digits are \p{Emoji} in JS too, so a label starting with one loses it.)
    static func stripLabel(_ label: String) -> String {
        var scalars = Substring(label).unicodeScalars
        while let first = scalars.first, first.properties.isEmoji || first.properties.isWhitespace || first.value == 0xFE0F || first.value == 0x200D {
            scalars.removeFirst()
        }
        let out = String(String.UnicodeScalarView(scalars))
        return out.isEmpty ? label : out
    }

    /// The web's `compact`: 999 → "999", 1 200 → "1.2K", 12 400 → "12K", 1 500 000 → "1.5M". Never "NaN".
    static func compact(_ count: Int) -> String {
        let n = max(0, count)
        func short(_ value: Double, _ unit: String) -> String {
            let rounded = (value * 10).rounded() / 10
            return (value < 10 && rounded != rounded.rounded() ? String(format: "%.1f", rounded) : String(Int(value.rounded()))) + unit
        }
        if n < 1000 { return String(n) }
        if n < 1_000_000 { return short(Double(n) / 1000, "K") }
        if n < 1_000_000_000 { return short(Double(n) / 1_000_000, "M") }
        return short(Double(n) / 1_000_000_000, "B")
    }
}

nonisolated struct ToolEnvVar: Sendable, Hashable, Identifiable {
    var key: String
    var prompt: String
    var url: String?
    var placeholder: String?
    var isSet: Bool
    var id: String { key }
}

nonisolated struct ToolProvider: Sendable, Hashable, Identifiable {
    var name: String
    var badge: String
    var tag: String
    var isActive: Bool
    var status: String?
    var postSetup: String?
    var envVars: [ToolEnvVar]
    var webBackend: String?
    var capabilities: [String]
    var id: String { name }

    /// "Ready" / "Needs keys" / "Setup required" / "Needs sign-in"; nil for an older gateway that sends no status.
    var statusWord: String? {
        switch status {
        case "ready": "Ready"
        case "needs_keys": "Needs keys"
        case "needs_setup": "Setup required"
        case "needs_auth": "Needs sign-in"
        default: nil
        }
    }
}

nonisolated struct ToolsetConfig: Sendable, Hashable {
    var hasCategory: Bool
    var providers: [ToolProvider]
    var searchBackend: String?
    var extractBackend: String?

    static func read(_ value: JSONValue) -> ToolsetConfig {
        let providers: [ToolProvider] = (value["providers"]?.array ?? []).compactMap { row in
            guard let name = RosterText.trimmed(row["name"]) else { return nil }
            let vars: [ToolEnvVar] = (row["env_vars"]?.array ?? []).compactMap { item in
                guard let key = RosterText.trimmed(item["key"]) else { return nil }
                let url = RosterText.trimmed(item["url"]).flatMap { $0.lowercased().hasPrefix("https://") ? $0 : nil }
                // A default that looks like a credential is never shown, even as a placeholder.
                let hint = RosterText.trimmed(item["default"]).flatMap { McpEntryMask.phone.text($0) == $0 ? $0 : nil }
                return ToolEnvVar(key: key, prompt: RosterText.trimmed(item["prompt"]) ?? key, url: url, placeholder: hint,
                                  isSet: item["is_set"]?.bool ?? false)
            }
            return ToolProvider(name: name, badge: RosterText.text(row["badge"]), tag: RosterText.text(row["tag"]),
                                isActive: row["is_active"]?.bool ?? false, status: RosterText.trimmed(row["status"]),
                                postSetup: RosterText.trimmed(row["post_setup"]), envVars: vars,
                                webBackend: RosterText.trimmed(row["web_backend"]), capabilities: (row["capabilities"]?.array ?? []).compactMap(\.string))
        }
        return ToolsetConfig(hasCategory: value["has_category"]?.bool ?? false, providers: providers,
                             searchBackend: RosterText.trimmed(value["active_search_backend"]),
                             extractBackend: RosterText.trimmed(value["active_extract_backend"]))
    }
}

nonisolated struct ToolModel: Sendable, Hashable, Identifiable {
    var id: String
    var display: String
    var caption: String
}

nonisolated struct ToolModels: Sendable, Hashable {
    var provider: String
    var current: String?
    var fallback: String?
    var models: [ToolModel]

    static func read(_ value: JSONValue) -> ToolModels? {
        guard value["has_models"]?.bool == true else { return nil }
        let models: [ToolModel] = (value["models"]?.array ?? []).compactMap { row in
            guard let id = RosterText.trimmed(row["id"]) else { return nil }
            let parts = ["speed", "strengths", "price"].compactMap { RosterText.trimmed(row[$0]) }
            return ToolModel(id: id, display: RosterText.trimmed(row["display"]) ?? id, caption: parts.joined(separator: " · "))
        }
        guard !models.isEmpty else { return nil }
        return ToolModels(provider: RosterText.text(value["provider"]), current: RosterText.trimmed(value["current"]),
                          fallback: RosterText.trimmed(value["default"]), models: models)
    }
}

nonisolated struct TerminalBackend: Sendable, Hashable, Identifiable {
    var name: String
    var label: String
    var description: String
    var active: Bool
    var status: String
    var detail: String
    var id: String { name }
    var isReady: Bool { status == "ready" }
}

// MARK: - Connectors (§5)

nonisolated struct McpTool: Sendable, Hashable, Identifiable {
    var name: String
    var description: String
    var id: String { name }
}

nonisolated struct McpProbe: Sendable, Hashable {
    var ok: Bool
    var tools: [McpTool]
    var error: String?
    var oauthNeeded: Bool

    static func read(_ value: JSONValue) -> McpProbe {
        McpProbe(ok: value["ok"]?.bool ?? false,
                 tools: (value["tools"]?.array ?? []).compactMap { row in
                     RosterText.trimmed(row["name"]).map { McpTool(name: $0, description: RosterText.text(row["description"])) }
                 },
                 error: RosterText.trimmed(value["error"]), oauthNeeded: value["oauth_needed"]?.bool ?? false)
    }
}

nonisolated struct McpOAuthStart: Sendable, Hashable {
    var sessionId: String
    var authURL: String
}

nonisolated struct McpOAuthPoll: Sendable, Hashable {
    var status: String
    var errorMessage: String
    var tools: Int
}

/// What saving a connector's tool rules ended as (§5.5-b: remove-then-add with one rollback).
nonisolated enum ToolRulesOutcome: Sendable, Equatable {
    case saved, unchanged
    /// The entry is no longer in the gateway's configuration.
    case gone
    /// The add failed and the old entry was put back.
    case rolledBack(String)
    /// The add and the rollback both failed: the connector is off this bot.
    case lost(String)
}

// MARK: - Plugins (§9, §12.4)

nonisolated struct PluginServerState: Sendable, Hashable {
    var name: String
    var state: String
    var sentence: String

    /// The gateway's own sentence when it sent one, else the state in words (§9).
    var words: String? {
        if state == "connected" { return nil }
        if !sentence.isEmpty { return sentence }
        switch state {
        case "app_not_running": return "App not running"
        case "hermes_not_connected": return "Connection missing"
        case "endpoint_unavailable": return "Not reachable"
        case "no_interactive_session": return "No session"
        case "version_too_old": return "Version too old"
        case "missing_app": return "App missing"
        case "unsupported_gpu": return "This computer’s graphics can’t run it"
        default: return "Status unknown"
        }
    }
}

nonisolated struct PluginField: Sendable, Hashable, Identifiable {
    var key: String
    var type: String
    var label: String
    var description: String
    var required: Bool
    var value: JSONValue?
    var fallback: JSONValue?
    var choices: [String]
    var env: String?
    var hasValue: Bool
    var id: String { key }

    static let known: Set<String> = ["string", "number", "boolean", "enum", "secret", "json"]
}

nonisolated struct PluginInfo: Sendable, Hashable, Identifiable {
    var name: String
    var key: String?
    var version: String
    var description: String
    var source: String
    var enabled: Bool
    var hasDesktopHalf: Bool
    var servers: [PluginServerState]
    var updateAvailable: Bool
    var catalogVersion: String?
    var catalogSha: String?
    var schema: [PluginField]
    /// [find-plugins] The Hermes catalog entry it was installed from (`catalog_name`); nil for every other source.
    var catalogName: String? = nil
    /// [plugin-updates] What a Git install's update moves to (`update_target`: a commit, or a feed's version).
    var updateTarget: String? = nil
    var id: String { name }

    /// [plugin-updates] The version an update brings, as words: the catalog's version, else a short commit.
    var newVersion: String? {
        if let catalogVersion { return catalogVersion }
        guard let target = catalogSha ?? updateTarget else { return nil }
        let hex = target.count >= 12 && target.allSatisfy(\.isHexDigit)
        return hex ? String(target.prefix(7)) : target
    }

    var isKanban: Bool { name == "kanban" }
    var canUninstall: Bool { source == "user" || source == "git" }
    var sourceWords: String? {
        switch source {
        case "bundled": "Comes with Hermes"
        case "catalog": "From the Hermes catalog"
        case "git": "Installed from Git"
        case "user": "Installed by hand"
        default: nil
        }
    }

    static func read(_ row: JSONValue) -> PluginInfo? {
        guard let name = RosterText.trimmed(row["name"]) else { return nil }
        let schema: [PluginField] = (row["settings_schema"]?.array ?? []).compactMap { field in
            guard let key = RosterText.trimmed(field["key"]) else { return nil }
            return PluginField(key: key, type: RosterText.trimmed(field["type"]) ?? "string", label: RosterText.trimmed(field["label"]) ?? key,
                               description: RosterText.text(field["description"]), required: field["required"]?.bool ?? false,
                               value: field["value"].flatMap { $0.isNull ? nil : $0 }, fallback: field["default"].flatMap { $0.isNull ? nil : $0 },
                               choices: (field["choices"]?.array ?? []).compactMap(\.string), env: RosterText.trimmed(field["env"]),
                               hasValue: field["has_value"]?.bool ?? false)
        }
        var info = PluginInfo(name: name, key: RosterText.trimmed(row["key"]), version: RosterText.text(row["version"]),
                          description: RosterText.text(row["description"]), source: RosterText.trimmed(row["source"]) ?? "",
                          enabled: RosterText.trimmed(row["status"]) == "enabled", hasDesktopHalf: row["has_desktop_half"]?.bool ?? false,
                          servers: (row["servers"]?.array ?? []).compactMap { server in
                              RosterText.trimmed(server["name"]).map {
                                  PluginServerState(name: $0, state: RosterText.trimmed(server["state"]) ?? "unknown", sentence: RosterText.text(server["sentence"]))
                              }
                          },
                          updateAvailable: row["update_available"]?.bool ?? false, catalogVersion: RosterText.trimmed(row["catalog_version"]),
                          catalogSha: RosterText.trimmed(row["catalog_sha"]), schema: schema, catalogName: RosterText.trimmed(row["catalog_name"]))
        info.updateTarget = RosterText.trimmed(row["update_target"])
        return info
    }
}

/// One `plugins.manage` call. Which params each action takes is fixed here so a wrong combination cannot be built
/// (V:store/agent-plugins.ts:158, 207, 306, 376, 412, 466).
nonisolated enum PluginAction: Sendable, Equatable {
    case toggle(key: String, enable: Bool)
    case update(name: String, accept: Bool)
    case remove(name: String)
    case install(identifier: String, force: Bool, enable: Bool, ref: String?)
    /// [find-plugins] A Hermes catalog plugin by its catalog name: Hermes installs the commit Nous reviewed.
    case installCatalog(name: String, enable: Bool)
    case settings(key: String, values: [String: JSONValue])

    func params(profile: String) -> JSONValue {
        var out: [String: JSONValue] = ["profile": .string(profile)]
        switch self {
        case .toggle(let key, let enable):
            out["action"] = "toggle"; out["key"] = .string(key); out["enable"] = .bool(enable)
        case .update(let name, let accept):
            out["action"] = "update"; out["name"] = .string(name)
            if accept { out["accept_capabilities"] = true }
        case .remove(let name):
            out["action"] = "remove"; out["name"] = .string(name)
        case .install(let identifier, let force, let enable, let ref):
            out["action"] = "install"; out["identifier"] = .string(identifier); out["force"] = .bool(force); out["enable"] = .bool(enable)
            if let ref, !ref.isEmpty { out["ref"] = .string(ref) }
        case .installCatalog(let name, let enable):
            out["action"] = "install"; out["catalog_name"] = .string(name); out["enable"] = .bool(enable)
        case .settings(let key, let values):
            out["action"] = "settings"; out["key"] = .string(key); out["values"] = .object(values)
        }
        return .object(out)
    }

    var timeout: Duration {
        switch self {
        case .install, .installCatalog: .seconds(120)
        default: .seconds(60)
        }
    }
}

nonisolated struct PluginResult: Sendable, Hashable {
    var ok: Bool
    var name: String?
    var restartRequired: Bool
    var gatewayReloaded: Bool
    var missingEnv: [String]
    var warnings: [String]
    var consentRequired: Bool
    var deltaLines: [String]
    /// [plugin-updates] Hermes's security scan stopped an update (nothing changed).
    var scanBlocked = false
    /// [plugin-updates] An update that found nothing newer.
    var unchanged = false

    var needsRestart: Bool { restartRequired && !gatewayReloaded }

    static func read(_ value: JSONValue) -> PluginResult {
        PluginResult(ok: value["ok"]?.bool ?? false, name: RosterText.trimmed(value["plugin_name"]) ?? RosterText.trimmed(value["name"]),
                     restartRequired: value["restart_required"]?.bool ?? false, gatewayReloaded: value["gateway_reloaded"]?.bool ?? false,
                     missingEnv: (value["missing_env"]?.array ?? []).compactMap(\.string), warnings: (value["warnings"]?.array ?? []).compactMap(\.string),
                     consentRequired: value["consent_required"]?.bool ?? false, deltaLines: (value["delta_lines"]?.array ?? []).compactMap(\.string),
                     scanBlocked: value["scan_blocked"]?.bool ?? false, unchanged: value["unchanged"]?.bool ?? false)
    }
}
