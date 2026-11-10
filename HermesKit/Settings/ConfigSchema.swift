// The gateway's config pages, driven at run time by the gateway's own schema (`GET /api/config/schema`) as the web app
// does (`vendor/.../app/settings/config-settings.tsx`, `config-field.tsx`, `helpers.ts`, `constants.ts`,
// `config-subpages.ts`): which keys each page lists, how each key is drawn (switch, picker, number, text, list…), its
// label and description, and the record edits a change makes. Pure data and functions, so the mapping and the save
// payloads are unit tested without a screen.

import Foundation

// MARK: - The schema

/// One field of `GET /api/config/schema` → `fields` (`types/hermes.ts` ConfigFieldSchema).
nonisolated struct ConfigFieldSchema: Sendable, Equatable {
    enum Kind: String, Sendable { case boolean, list, number, select, string, text }
    var kind: Kind?
    var description: String?
    var options: [String]?
    var category: String?
    var searchable: Bool
    var clearable: Bool

    init(kind: Kind? = nil, description: String? = nil, options: [String]? = nil, category: String? = nil,
         searchable: Bool = false, clearable: Bool = false) {
        self.kind = kind; self.description = description; self.options = options; self.category = category
        self.searchable = searchable; self.clearable = clearable
    }

    init(_ value: JSONValue) {
        kind = value["type"]?.string.flatMap(Kind.init(rawValue:))
        description = value["description"]?.string
        options = value["options"]?.array?.map { ConfigText.text($0) }
        category = value["category"]?.string
        searchable = value["searchable"]?.bool ?? false
        clearable = value["clearable"]?.bool ?? false
    }

    /// The schema's answer: `{fields: {key: schema}}` (a bare map is accepted too).
    static func fields(_ response: JSONValue) -> [String: ConfigFieldSchema] {
        let map = response["fields"]?.object ?? response.object ?? [:]
        return map.mapValues(ConfigFieldSchema.init)
    }

    /// What the web infers for a key the schema omits but the record has (`inferFieldSchema`).
    static func inferred(from value: JSONValue) -> ConfigFieldSchema {
        switch value {
        case .bool: ConfigFieldSchema(kind: .boolean)
        case .number: ConfigFieldSchema(kind: .number)
        case .array: ConfigFieldSchema(kind: .list)
        default: ConfigFieldSchema(kind: .string)
        }
    }
}

// MARK: - Record paths (`getNested` / `setNested` / `diffConfig`)

nonisolated enum ConfigPath {
    private static let unsafe: Set<String> = ["__proto__", "constructor", "prototype"]

    static func parts(_ path: String) -> [String]? {
        let parts = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        return parts.allSatisfy({ !$0.isEmpty && !unsafe.contains($0) }) ? parts : nil
    }

    /// The value at a dotted path (nil when any step is missing or not an object).
    static func get(_ record: JSONValue, _ path: String) -> JSONValue? {
        guard let parts = parts(path) else { return nil }
        var current: JSONValue? = record
        for part in parts {
            guard let object = current?.object else { return nil }
            current = object[part]
        }
        return current
    }

    /// A copy of `record` with `value` at `path` (missing or non-object steps become objects).
    static func set(_ record: JSONValue, _ path: String, _ value: JSONValue) -> JSONValue {
        guard let parts = parts(path) else { return record }
        return set(record.object ?? [:], parts[...], value)
    }

    private static func set(_ object: [String: JSONValue], _ parts: ArraySlice<String>, _ value: JSONValue) -> JSONValue {
        guard let first = parts.first else { return value }
        var copy = object
        if parts.count == 1 {
            copy[first] = value
        } else {
            copy[first] = set(object[first]?.object ?? [:], parts.dropFirst(), value)
        }
        return .object(copy)
    }

    /// Only the branches of `next` that differ from `base` (objects compared key by key, arrays and scalars whole).
    /// `PUT /api/config` deep-merges, so a key the user never touched is never sent back with a stale value.
    static func diff(_ base: JSONValue, _ next: JSONValue) -> JSONValue {
        let baseObject = base.object ?? [:]
        var patch: [String: JSONValue] = [:]
        for (key, nextValue) in next.object ?? [:] {
            let baseValue = baseObject[key]
            if let b = baseValue, b.object != nil, nextValue.object != nil {
                let nested = diff(b, nextValue)
                if !(nested.object ?? [:]).isEmpty { patch[key] = nested }
            } else if baseValue != nextValue || baseValue == nil {
                if baseValue == nil, nextValue.isNull { continue }
                patch[key] = nextValue
            }
        }
        return .object(patch)
    }

    /// Lays `patch` over `record` the way the gateway merges a PUT (objects merge, anything else replaces).
    static func merge(_ record: JSONValue, _ patch: JSONValue) -> JSONValue {
        guard var object = record.object, let changes = patch.object else { return patch }
        for (key, value) in changes {
            if let current = object[key], current.object != nil, value.object != nil {
                object[key] = merge(current, value)
            } else {
                object[key] = value
            }
        }
        return .object(object)
    }

    /// Clearing a non-empty Enabled Toolsets list (an explicit `[]`) turns off most tools: the page confirms it first.
    static func clearsEnabledToolsets(_ previous: JSONValue, _ next: JSONValue) -> Bool {
        let had = (get(previous, "toolsets")?.array?.isEmpty == false)
        let clears = get(next, "toolsets")?.array?.isEmpty == true
        return had && clears
    }
}

// MARK: - Text helpers

nonisolated enum ConfigText {
    /// A value as the web's `asText` shows it in a field.
    static func text(_ value: JSONValue?) -> String {
        switch value {
        case .string(let s)?: s
        case .number(let n)?: n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b)?: b ? "true" : "false"
        case .array(let a)?: a.map { text($0) }.joined(separator: ", ")
        case .object?: (try? String(decoding: JSONEncoder().encode(value!), as: UTF8.self)) ?? ""
        default: ""
        }
    }

    /// `prettyName`: "max_turns" → "Max Turns".
    static func pretty(_ text: String) -> String {
        // Stress test 2026-10-28 #59, round 2 (both): brand and acronym spellings as DisplayName keeps them
        // ("duckduckgo" → "DuckDuckGo", not "Duckduckgo").
        text.replacingOccurrences(of: "_", with: " ").split(separator: " ", omittingEmptySubsequences: false).map { word in
            DisplayName.words[String(word)] ?? (word.prefix(1).uppercased() + word.dropFirst())
        }.joined(separator: " ")
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
}

// MARK: - The pages

/// One page of a config section (e.g. Safety › Approvals): the keys it lists, by exact name or prefix.
nonisolated struct ConfigPage: Sendable, Hashable, Identifiable {
    var section: String
    var id: String
    var title: String
    var symbol: String
    var fields: [String] = []
    var prefixes: [String] = []
    var footer: String? = nil

    var key: String { "\(section).\(id)" }

    func contains(_ field: String) -> Bool { fields.contains(field) || prefixes.contains { field.hasPrefix($0) } }
}

/// A Settings group (Model, Chat, Workspace…) and its pages, in the web's order.
nonisolated struct ConfigSection: Sendable, Hashable, Identifiable {
    var id: String
    var title: String
    var symbol: String
    /// The curated keys (`SECTIONS[].keys`): only these appear, and only when the schema or the record has them.
    var keys: [String]
    var pages: [ConfigPage]
}

nonisolated enum ConfigCatalog {
    /// `constants.ts` SECTIONS (Voice and Appearance are other streams'), with the pages of `config-subpages.ts`.
    static let sections: [ConfigSection] = [
        ConfigSection(id: "model", title: "Model", symbol: "cube", keys: [
            "model_context_length", "fallback_providers", "agent.reasoning_effort", "agent.service_tier",
        ], pages: [
            ConfigPage(section: "model", id: "main", title: "Main Model", symbol: "cube",
                       fields: ["model", "agent.reasoning_effort", "agent.service_tier"], prefixes: ["model."]),
            // [context-window] Owner 2026-11-01: "If I have to ask you, then I'm sure others may not ever even find it"
            // (it was one field on Main Model). Hermes' desktop app names it Context Window too.
            ConfigPage(section: "model", id: "context", title: "Context Window", symbol: "viewfinder", fields: [ContextWindow.key]),
            // Stress test 2026-10-28 #103, round 2 (both): Fallback Models had Changes' branch, Agent Limits had Auxiliary
            // Models' chip, and MoA's and Subagents' people were wider than the icon column; each has its own, narrower one.
            ConfigPage(section: "model", id: "fallbacks", title: "Fallback Models", symbol: "arrow.turn.down.right", fields: ["fallback_providers"]),
            ConfigPage(section: "model", id: "auxiliary", title: "Auxiliary Models", symbol: "cpu", prefixes: ["auxiliary."]),
            ConfigPage(section: "model", id: "moa", title: "Mixture of Agents", symbol: "rectangle.3.group", prefixes: ["moa."]),
        ]),
        ConfigSection(id: "chat", title: "Chat Behavior", symbol: "bubble.left.and.text.bubble.right", keys: [
            "display.personality", "timezone", "display.show_reasoning", "agent.image_input_mode",
        ], pages: [
            ConfigPage(section: "chat", id: "behavior", title: "Behavior", symbol: "bubble.left",
                       fields: ["display.personality", "timezone", "display.show_reasoning"]),
            ConfigPage(section: "chat", id: "attachments", title: "Attachments", symbol: "photo", fields: ["agent.image_input_mode"]),
        ]),
        ConfigSection(id: "workspace", title: "Workspace", symbol: "folder", keys: [
            "terminal.cwd", "desktop.repo_scan_enabled", "desktop.repo_scan_roots", "desktop.repo_scan_exclude_paths",
            "code_execution.mode", "terminal.persistent_shell", "terminal.env_passthrough", "file_read_max_chars",
        ], pages: [
            ConfigPage(section: "workspace", id: "projects", title: "Projects", symbol: "folder",
                       fields: ["terminal.cwd"], prefixes: ["desktop.repo_scan_"]),
            ConfigPage(section: "workspace", id: "shell", title: "Shell", symbol: "terminal",
                       fields: ["terminal.persistent_shell", "terminal.env_passthrough"]),
            ConfigPage(section: "workspace", id: "files", title: "Files", symbol: "doc.text",
                       fields: ["code_execution.mode", "file_read_max_chars"]),
        ]),
        ConfigSection(id: "safety", title: "Safety", symbol: "lock.shield", keys: [
            "approvals.mode", "approvals.timeout", "approvals.mcp_reload_confirm", "command_allowlist",
            "security.redact_secrets", "security.allow_private_urls", "checkpoints.enabled",
        ], pages: [
            ConfigPage(section: "safety", id: "approvals", title: "Approvals", symbol: "checkmark.shield",
                       fields: ["command_allowlist"], prefixes: ["approvals."]),
            ConfigPage(section: "safety", id: "privacy", title: "Privacy & Network", symbol: "lock", prefixes: ["security."]),
            ConfigPage(section: "safety", id: "checkpoints", title: "Checkpoints", symbol: "archivebox", prefixes: ["checkpoints."]),
        ]),
        ConfigSection(id: "browser", title: "Browser", symbol: "globe", keys: [
            "browser.use_real_profile", "browser.allow_private_urls", "browser.auto_local_for_private_urls",
        ], pages: [
            ConfigPage(section: "browser", id: "profile", title: "Browser Profile", symbol: "globe", fields: ["browser.use_real_profile"]),
            ConfigPage(section: "browser", id: "network", title: "Local & Private URLs", symbol: "network",
                       fields: ["browser.allow_private_urls", "browser.auto_local_for_private_urls"]),
        ]),
        ConfigSection(id: "memory", title: "Memory", symbol: "brain", keys: [
            "memory.memory_enabled", "memory.user_profile_enabled", "memory.memory_char_limit", "memory.user_char_limit",
            "memory.provider", "context.engine", "compression.enabled", "compression.threshold",
            "compression.codex_gpt55_autoraise", "compression.target_ratio", "compression.protect_last_n",
            "auxiliary.compression.timeout",
        ], pages: [
            ConfigPage(section: "memory", id: "persistent", title: "Persistent Memory", symbol: "brain", prefixes: ["memory."]),
            ConfigPage(section: "memory", id: "context", title: "Context & Compression", symbol: "doc.text",
                       prefixes: ["context.", "compression.", "auxiliary.compression."]),
        ]),
        VoiceSettingsCatalog.section,   // [talk] Voice, between Memory and Advanced as on the web (docs/spec/3x-talk.md §9.1)
        ConfigSection(id: "advanced", title: "Advanced", symbol: "gearshape.2", keys: [   // UX #116: the wrench stays on Tool Calls
            "toolsets", "terminal.backend", "terminal.timeout", "terminal.docker_image", "terminal.singularity_image",
            "terminal.modal_image", "terminal.daytona_image", "tool_output.max_bytes", "tool_output.max_lines",
            "tool_output.max_line_length", "checkpoints.max_snapshots", "agent.max_turns", "agent.api_max_retries",
            "agent.service_tier", "agent.tool_use_enforcement", "delegation.model", "delegation.provider",
            "delegation.max_iterations", "delegation.max_concurrent_children", "delegation.child_timeout_seconds",
            "delegation.reasoning_effort",
        ], pages: [
            ConfigPage(section: "advanced", id: "runtime", title: "Agent Limits", symbol: "timer",
                       fields: ["agent.max_turns", "agent.api_max_retries", "agent.service_tier"]),
            ConfigPage(section: "advanced", id: "tools", title: "Tool Access", symbol: "wrench", fields: ["toolsets", "agent.tool_use_enforcement"]),
            ConfigPage(section: "advanced", id: "terminal", title: "Terminal Backend", symbol: "terminal", prefixes: ["terminal."]),
            ConfigPage(section: "advanced", id: "output", title: "Output Limits", symbol: "doc.plaintext", prefixes: ["tool_output.", "checkpoints."]),
            ConfigPage(section: "advanced", id: "delegation", title: "Subagents", symbol: "person.crop.rectangle.stack", prefixes: ["delegation."]),
        ]),
    ]

    static func section(_ id: String) -> ConfigSection? { sections.first { $0.id == id } }

    static func page(_ key: String) -> ConfigPage? {
        let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return section(parts[0])?.pages.first { $0.id == parts[1] }
    }

    /// The page a field lands on (`configSubpageForField`).
    static func page(forField field: String, in section: String) -> ConfigPage? {
        self.section(section)?.pages.first { $0.contains(field) }
    }

    /// Pages drawn by their own screens rather than the generic field list (they still show their schema fields below).
    static let customPages: Set<String> = Set(["model.main", "model.context", "model.fallbacks", "model.auxiliary", "model.moa"])
        .union(VoiceSettingsCatalog.customPages)   // [talk]

    /// Fields that mean nothing with the settings as they are: Terminal Backend's image rows for the backends not
    /// chosen (stress test 2026-10-28 #99: set to Local, the Docker, Singularity, Modal and Daytona images all showed at
    /// full strength). Only hidden; their saved values are untouched.
    static func hiddenNow(config: JSONValue?) -> Set<String> {
        let backend = ConfigText.text(ConfigPath.get(config ?? .null, "terminal.backend")).trimmingCharacters(in: .whitespaces).lowercased()
        return Set(["docker", "singularity", "modal", "daytona"].filter { $0 != backend }.map { "terminal.\($0)_image" })
    }

    /// Mac polish #98: settings that only matter while a switch is on, and that switch (Workspace's folders under
    /// Automatic Repository Discovery, Output Limits' Checkpoint Limit under File Checkpoints). While it is off they show
    /// dimmed and can't be changed, as Mixture of Agents' rows are; their saved values are untouched.
    static let parentSwitch: [String: String] = [
        "desktop.repo_scan_roots": "desktop.repo_scan_enabled",
        "desktop.repo_scan_exclude_paths": "desktop.repo_scan_enabled",
        "checkpoints.max_snapshots": "checkpoints.enabled",
    ]

    /// What a held field's help adds when its switch is on another page (Checkpoint Limit is on Advanced › Output
    /// Limits, File Checkpoints on Safety › Checkpoints), so a dimmed row says why. Workspace's folders sit under their
    /// switch, so they need none.
    static let heldHelp: [String: String] = [
        "checkpoints.max_snapshots": "Turn on File Checkpoints in Safety to change it.",
    ]

    /// The fields held now (`parentSwitch`): their switch is in the record and off. A record without it holds nothing.
    static func heldNow(config: JSONValue?) -> Set<String> {
        guard let config else { return [] }
        return Set(parentSwitch.filter { _, parent in ConfigPath.get(config, parent).map { $0.bool != true } ?? false }.keys)
    }
}

// MARK: - How a field is drawn

nonisolated enum ConfigControl: Sendable, Equatable {
    case toggle
    /// A closed list; `free` keeps typed values (voice and model names), `searchable` gets a search field.
    case choice(options: [String], free: Bool, searchable: Bool)
    case number
    case text
    /// A long string (a persona, a prompt): its own editor.
    case longText
    /// Comma-separated in one field.
    case list
    /// An object with no schema: JSON in an editor.
    case json
    /// `fallback_providers`: its own page.
    case fallbackModels
}

/// One row a config page draws.
nonisolated struct ConfigFieldModel: Sendable, Equatable, Identifiable {
    var key: String
    var label: String
    var description: String?
    var control: ConfigControl
    var value: JSONValue?
    /// The gateway's default (`GET /api/config/defaults`), nil when it has none.
    var defaultValue: JSONValue?
    var id: String { key }

    /// Reset to Default is offered when there is a default and the value differs from it.
    var canReset: Bool {
        guard let defaultValue else { return false }
        return !ConfigRenderer.same(value, defaultValue)
    }
}

nonisolated enum ConfigRenderer {
    /// The fields a page lists, in the section's curated order: a key shows when the schema describes it or the record
    /// has it (`sectionFieldEntries`), filtered to the page (`configSubpageForField`).
    static func fields(page: ConfigPage, schema: [String: ConfigFieldSchema], config: JSONValue,
                       defaults: JSONValue? = nil) -> [ConfigFieldModel] {
        guard let section = ConfigCatalog.section(page.section) else { return [] }
        return section.keys.compactMap { key -> ConfigFieldModel? in
            guard !VoiceSettingsCatalog.isHidden(key) else { return nil }   // [talk] row L546
            guard ConfigCatalog.page(forField: key, in: page.section)?.id == page.id else { return nil }
            let value = ConfigPath.get(config, key)
            guard let field = schema[key] ?? value.map(ConfigFieldSchema.inferred(from:)) else { return nil }
            return model(key: key, schema: field, value: value, config: config, defaults: defaults)
        }
    }

    static func model(key: String, schema: ConfigFieldSchema, value: JSONValue?, config: JSONValue, defaults: JSONValue?) -> ConfigFieldModel {
        let label = ConfigCopy.labels[key] ?? ConfigText.pretty(String(key.split(separator: ".").last ?? Substring(key)))
        return ConfigFieldModel(key: key, label: label, description: description(key: key, schema: schema, label: label),
                                control: control(key: key, schema: schema, value: value, config: config), value: value,
                                defaultValue: defaults.flatMap { ConfigPath.get($0, key) })
    }

    /// The copy's description, else the schema's, unless it only repeats the label or the key.
    static func description(key: String, schema: ConfigFieldSchema, label: String) -> String? {
        let raw = (ConfigCopy.descriptions[key] ?? schema.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let normal = ConfigText.normalized(raw)
        guard !raw.isEmpty, normal != ConfigText.normalized(label), normal != ConfigText.normalized(key) else { return nil }
        return raw
    }

    /// `ConfigField`'s choice of control.
    static func control(key: String, schema: ConfigFieldSchema, value: JSONValue?, config: JSONValue) -> ConfigControl {
        if key == "fallback_providers" { return .fallbackModels }
        if schema.kind == .boolean { return .toggle }
        if let options = options(key: key, schema: schema, value: value, config: config) {
            let free = ConfigCopy.freeInputKeys.contains(key)
            return .choice(options: free ? options.filter { !$0.isEmpty } : options, free: free, searchable: schema.searchable)
        }
        if schema.kind == .number { return .number }
        if schema.kind == .list { return .list }
        if value?.object != nil { return .json }
        if schema.kind == .text || ConfigText.text(value).count > 100 { return .longText }
        return .text
    }

    /// `enumOptionsFor`, then the schema's own options for a select. The current value is always kept as a choice.
    static func options(key: String, schema: ConfigFieldSchema, value: JSONValue?, config: JSONValue) -> [String]? {
        var options: [String]?
        if key == "display.personality" {
            options = personalityOptions(config)
        } else if let known = ConfigCopy.enumOptions[key] {
            options = known
            // [talk] The voice providers also list whatever the gateway's schema adds (DeepInfra, a plug-in).
            if VoiceSettingsCatalog.schemaExtendedKeys.contains(key), let listed = schema.options {
                options = known + listed.filter { !known.contains($0) }
            }
        } else if schema.kind == .select, let listed = schema.options {
            options = listed
        }
        if key == "agent.tool_use_enforcement", options == nil { options = ["auto", "true", "false"] }
        guard var list = options else { return nil }
        let current = ConfigText.text(value)
        if !current.isEmpty, !list.contains(current) { list.append(current) }
        return list
    }

    static let builtinPersonalities = ["helpful", "concise", "technical", "creative", "teacher", "kawaii", "catgirl", "pirate",
                                       "shakespeare", "surfer", "noir", "uwu", "philosopher", "hype"]

    static func personalityOptions(_ config: JSONValue) -> [String] {
        var names = [""] + builtinPersonalities
        for key in ["personalities", "agent.personalities"] {
            for name in (ConfigPath.get(config, key)?.object ?? [:]).keys.sorted() {
                let folded = name.trimmingCharacters(in: .whitespaces).lowercased()
                if !folded.isEmpty, !["none", "default", "neutral"].contains(folded), !names.contains(folded) { names.append(folded) }
            }
        }
        return names
    }

    /// A time zone id as words (Mac UX stress test #59): "America/New_York" → "New York (America)",
    /// "America/Argentina/Buenos_Aires" → "Buenos Aires (America)", "Etc/UTC" → "UTC". The value written stays the id.
    static func timeZoneLabel(_ id: String) -> String {
        let parts = id.split(separator: "/").map { $0.replacingOccurrences(of: "_", with: " ") }
        guard let city = parts.last, parts.count > 1 else { return id.replacingOccurrences(of: "_", with: " ") }
        return parts[0] == "Etc" ? city : "\(city) (\(parts[0]))"   // round 2 (both): "New York (America)", not a comma list
    }

    /// How a choice reads in its picker.
    static func optionLabel(key: String, _ option: String) -> String {
        if option.isEmpty {
            switch key {
            case "display.personality": return "None"
            case "memory.provider": return "Built-in Only"
            // Stress test 2026-10-28 #101 (both): named as the Model page names it (Settings › Model › Main Model).
            case "delegation.reasoning_effort": return "Same as Main Model"
            case "timezone": return "System Default"
            default: return VoiceSettingsCatalog.emptyLabels[key] ?? "None"   // [talk]
            }
        }
        if let label = ConfigCopy.optionLabels[key]?[option] { return label }
        if key == "timezone" { return timeZoneLabel(option) }
        if ConfigCopy.freeInputKeys.contains(key) { return option }
        return ConfigText.pretty(option)
    }

    /// The value a picked choice writes: `tool_use_enforcement`'s true/false are booleans; the rest strings.
    static func choiceValue(key: String, _ option: String, current: JSONValue?) -> JSONValue {
        if key == "agent.tool_use_enforcement", option == "true" || option == "false" { return .bool(option == "true") }
        if case .number? = current, let number = Double(option) { return .number(number) }
        return .string(option)
    }

    /// A typed number (empty means 0, as the web's field does); nil while it isn't a number.
    static func numberValue(_ text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .number(0) }
        guard let number = Double(trimmed.replacingOccurrences(of: ",", with: "")), number.isFinite else { return nil }
        return .number(number)
    }

    /// A comma-separated list.
    static func listValue(_ text: String) -> JSONValue {
        .array(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { .string($0) })
    }

    /// Values compared as the page shows them (1 and 1.0 alike; a missing value equals null).
    static func same(_ a: JSONValue?, _ b: JSONValue?) -> Bool {
        switch (a, b) {
        case (nil, nil), (nil, .null?), (.null?, nil): return true
        case (.number(let x)?, .number(let y)?): return x == y
        default: return a == b
        }
    }

    /// The summary a page row shows for a value (pickers' labels, On/Off, counts).
    static func summary(_ field: ConfigFieldModel) -> String {
        switch field.control {
        case .toggle: return field.value?.bool == true ? "On" : "Off"
        case .choice: return optionLabel(key: field.key, ConfigText.text(field.value))
        case .list, .fallbackModels:
            // Mac polish #132: lower case, with what the list holds ("3 toolsets"), not "3 Items".
            let count = field.value?.array?.count ?? 0
            let noun = ConfigCopy.listNouns[field.key] ?? ("item", "items")
            return count == 0 ? "None" : "\(count) \(count == 1 ? noun.one : noun.many)"
        default:
            let text = ConfigText.text(field.value)
            // [talk] An empty language is detected ("Automatic"); Max Dictation Length reads "120 s".
            if text.isEmpty { return VoiceSettingsCatalog.emptyLabels[field.key] ?? "Not Set" }
            // Mac UX stress test #59: a 0 that means "use what the model says" reads "Automatic", not "0".
            if ConfigCopy.zeroMeansAutomatic.contains(field.key), field.value?.double == 0 { return "Automatic" }
            if let unit = VoiceSettingsCatalog.units[field.key] { return "\(text) \(unit)" }
            return text
        }
    }
}

// MARK: - Fallback models (`fallback-models-field.tsx`)

/// One `fallback_providers` entry: `{provider, model}` (a bare "provider:model" string is read too).
nonisolated struct FallbackModel: Sendable, Hashable {
    var provider: String
    var model: String

    static func list(_ value: JSONValue?) -> [FallbackModel] {
        (value?.array ?? []).compactMap { item in
            if let text = item.string {
                let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
                return parts.count == 2 ? FallbackModel(provider: parts[0], model: parts[1]) : FallbackModel(provider: "", model: text)
            }
            guard let provider = item["provider"]?.string, let model = item["model"]?.string else { return nil }
            return FallbackModel(provider: provider, model: model)
        }
    }

    static func value(_ list: [FallbackModel]) -> JSONValue {
        .array(list.map { ["provider": .string($0.provider), "model": .string($0.model)] })
    }
}
