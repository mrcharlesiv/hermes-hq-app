// Hermes Cloud's agents through Nous Portal's MCP server (POST https://portal.nousresearch.com/mcp, the streamable
// HTTP transport): `agents` reads (list, status, cost estimate), `agent` acts (create, start, stop, …). The same two
// tools `hermes mcp add … hermes-cloud` gives a bot (hermes-agent website/docs/guides/manage-hermes-cloud-with-mcp.md).
// Tool arguments are read from the server's own schema (`tools/list`), so a renamed field or a new size shows up
// without an app update. Every call runs as the phone's Portal login (`PortalLogin`) and can only touch agents the
// person already controls on the Portal's /agents page.

import Foundation

/// One hosted agent. `dashboardUrl` is nil until it's provisioned; it's the gateway address HQ signs in to.
nonisolated struct CloudAgent: Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var status: String
    var dashboardURL: URL?
    /// "active" | "degraded" | "down" | "unknown" (Portal's dashboardGatewayState).
    var gatewayState: String
    var size: String = ""
    /// Memory and CPUs, when the row says (Portal's MCP rows carry `size` as {key, cpus, memoryMb, diskGb}).
    var memoryMB: Int?
    var cpus: Int?
    var region: String = ""
    /// Suspended while idle (Team Gateway agents); the next request wakes it, so it isn't started first.
    var isSleeping = false
    /// The data disk in GB, when the row says.
    var diskGB: Int?
    /// Disk sizes Nous offers this agent, when the row lists them (grow_disk takes one larger than `diskGB`).
    var diskChoices: [Int] = []
    /// Names of the environment variables set on it, when the row lists them (never their values).
    var envNames: [String] = []
    /// Team Gateway (Portal's "relay" feature) on or off, when the row says.
    var relay: Bool?
    /// The Hermes it runs ("v0.22.5", an image tag), when the row says.
    var version = ""
    /// Whether Nous has a newer Hermes image for it, when the row says.
    var updateAvailable: Bool?
    /// Portal's health words ("healthy", "degraded" …) and its sentence on them, when the row has them.
    var health = ""
    var healthDetail = ""
    /// The last thing that went wrong on Nous's side, when the row says.
    var lastError = ""
    /// Whether Nous allows a new size or a bigger disk right now (`changeSizeAvailable`, `diskExpansionAvailable`).
    var canResize: Bool?
    var canGrowDisk: Bool?
    /// When Nous will delete it (`scheduledDeletionAt`), as Portal wrote it.
    var deletesAt = ""
    /// The model it runs, as Nous set it at create.
    var model = ""

    var isRunning: Bool { ["running", "started", "active", "ready", "healthy"].contains(status.lowercased()) }
    var isStopped: Bool { ["stopped", "suspended", "paused", "sleeping"].contains(status.lowercased()) }
    var isFailed: Bool { ["failed", "error", "errored", "destroyed", "deleted"].contains(status.lowercased()) }
    /// On its way somewhere (starting, stopping, restarting, provisioning…): not settled as running, stopped or failed.
    var isChanging: Bool { !isRunning && !isStopped && !isFailed }
    /// Ready for a sign-in: an address and a gateway that answers, or one asleep that the sign-in wakes.
    var isReady: Bool {
        dashboardURL != nil && (isSleeping || gatewayState.lowercased() == "active" || (gatewayState.lowercased() == "unknown" && isRunning))
    }

    /// Reads an agent row in any of the shapes Portal uses (NAS /api/agents is camelCase, MCP text may be snake_case).
    static func read(_ value: JSONValue?) -> CloudAgent? {
        guard let value, case .object = value else { return nil }
        guard let id = RosterText.trimmed(value["id"]) ?? RosterText.trimmed(value["agentId"]) ?? RosterText.trimmed(value["agent_id"])
                ?? RosterText.trimmed(value["slug"]) else { return nil }
        let rawURL = RosterText.trimmed(value["dashboardUrl"]) ?? RosterText.trimmed(value["dashboard_url"])
            ?? RosterText.trimmed(value["url"]) ?? RosterText.trimmed(value["gatewayUrl"]) ?? RosterText.trimmed(value["gateway_url"])
        let url = rawURL.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" && $0.host != nil ? $0 : nil }
        let status = RosterText.trimmed(value["status"]) ?? RosterText.trimmed(value["state"]) ?? "unknown"
        // Portal's MCP rows (2026-10-31: capabilities, changeSizeAvailable, … health, healthDetail, lastError, volumeGb) carry
        // `health` where the web's rows carry dashboardGatewayState.
        let state = RosterText.trimmed(value["dashboardGatewayState"]) ?? RosterText.trimmed(value["dashboard_gateway_state"])
            ?? RosterText.trimmed(value["gatewayState"]) ?? RosterText.trimmed(value["health"]).map(Self.gatewayWord) ?? "unknown"
        // 2026-11-04: Portal's MCP rows carry `size` as an object ({key: "pro", cpus: 4, memoryMb: 4096, diskGb: 25}), so
        // its key is the size name; plain text is the web's shape.
        let sizeObject = value["size"]?.object != nil ? value["size"] : nil
        let size = RosterText.trimmed(sizeObject?["key"]) ?? RosterText.trimmed(sizeObject?["name"]) ?? RosterText.trimmed(value["size"])
            ?? RosterText.trimmed(value["tier"]) ?? RosterText.trimmed(value["plan"]) ?? ""
        let sleeping = (value["isSleeping"] ?? value["is_sleeping"] ?? value["sleeping"])?.bool ?? false
        var agent = CloudAgent(id: id, name: RosterText.trimmed(value["name"]) ?? id, status: status, dashboardURL: url,
                               gatewayState: state, size: size, region: RosterText.trimmed(value["region"]) ?? "", isSleeping: sleeping)
        // The row's other fields aren't documented (the app logs its keys once: "agents get keys"), so each is looked
        // for under the names Portal's other answers use.
        agent.diskGB = first(value, ["diskGb", "disk_gb", "diskSizeGb", "disk_size_gb", "volumeGb", "volume_gb", "volumeSizeGb"])?.int
            ?? sizeObject.flatMap { first($0, ["diskGb", "disk_gb"]) }?.int
        agent.memoryMB = (sizeObject.flatMap { first($0, ["memoryMb", "memory_mb"]) } ?? first(value, ["memoryMb", "memory_mb"]))?.int
        agent.cpus = (sizeObject.flatMap { first($0, ["cpus", "cpu", "vcpus"]) } ?? first(value, ["cpus", "vcpus"]))?.int
        agent.diskChoices = (first(value, ["diskOptions", "disk_options", "diskSizes", "disk_sizes", "offeredDiskGb", "offered_disk_gb"])?.array ?? [])
            .compactMap { $0.int ?? $0["gb"]?.int ?? $0["sizeGb"]?.int ?? $0["size_gb"]?.int }
        if let names = first(value, ["envKeys", "env_keys", "envNames", "env_names", "envVarNames", "env_var_names"])?.array {
            agent.envNames = names.compactMap(\.string)
        } else if let env = value["env"]?.object {
            agent.envNames = env.keys.sorted()
        }
        let features = value["features"]
        agent.relay = first(value, ["relay", "relayEnabled", "relay_enabled", "teamGateway", "team_gateway", "teamGatewayEnabled"])?.bool
            ?? features?["relay"]?.bool ?? (features?.array).map { list in list.contains { $0.string == "relay" } }
        agent.version = RosterText.trimmed(first(value, ["hermesVersion", "hermes_version", "imageVersion", "image_version", "version", "imageTag", "image_tag"])) ?? ""
        agent.updateAvailable = first(value, ["updateAvailable", "update_available", "imageOutdated", "image_outdated", "outdated"])?.bool
        agent.health = RosterText.trimmed(value["health"]) ?? ""
        agent.healthDetail = RosterText.trimmed(first(value, ["healthDetail", "health_detail"])) ?? ""
        agent.lastError = RosterText.trimmed(first(value, ["lastError", "last_error"])) ?? ""
        agent.canResize = first(value, ["changeSizeAvailable", "change_size_available"])?.bool
        agent.canGrowDisk = first(value, ["diskExpansionAvailable", "disk_expansion_available"])?.bool
        agent.deletesAt = RosterText.trimmed(first(value, ["scheduledDeletionAt", "scheduled_deletion_at"])) ?? ""
        agent.model = RosterText.trimmed(value["model"]) ?? ""
        return agent
    }

    /// Portal's health word as the gateway state the rest of the app reads ("active", "degraded", "down", "unknown").
    static func gatewayWord(_ health: String) -> String {
        switch health.lowercased() {
        case "healthy", "ok", "active", "up", "ready": "active"
        case "degraded", "warning", "slow": "degraded"
        case "unhealthy", "down", "error", "failed", "unreachable": "down"
        default: "unknown"
        }
    }

    private static func first(_ value: JSONValue, _ keys: [String]) -> JSONValue? {
        for key in keys { if let found = value[key], !found.isNull { return found } }
        return nil
    }

    /// Every agent row in a tool answer: a bare list, `{agents: […]}`, `{agent: {…}}`, `{data: …}` or one row.
    static func readAll(_ value: JSONValue) -> [CloudAgent] {
        if let rows = value.array { return rows.compactMap(read) }
        for key in ["agents", "items", "data", "results", "instances"] {
            if let rows = value[key]?.array { return rows.compactMap(read) }
        }
        for key in ["agent", "instance", "data", "result"] {
            if let one = read(value[key]) { return [one] }
        }
        return read(value).map { [$0] } ?? []
    }
}

/// One field the server's schema takes for an action (create's size, model, region …), for the form.
nonisolated struct CloudField: Sendable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var title: String
    var detail: String
    var choices: [String]
    /// Words for a choice when its key alone doesn't read well ("iad" → "Virginia, US"; "pro" → "Pro · 4 GB").
    var choiceTitles: [String: String] = [:]
    var defaultValue: String?
    var required: Bool
    var kind: Kind

    enum Kind: Sendable, Equatable { case text, choice, number, toggle }

    func title(of choice: String) -> String { choiceTitles[choice] ?? CloudToolSchema.title(choice) }
}

/// What a tool's `inputSchema` says about one action (e.g. `agent` + action "create").
nonisolated struct CloudToolSchema: Sendable, Equatable {
    /// The property naming the action ("action", "operation" …); nil when the tool takes none.
    var actionKey: String?
    var actions: [String]
    var properties: [String: JSONValue]
    var required: Set<String>
    /// Per-action branches (`oneOf`/`anyOf` with a const action) when the schema has them.
    var branches: [String: (properties: [String: JSONValue], required: Set<String>)] = [:]

    static func == (a: CloudToolSchema, b: CloudToolSchema) -> Bool {
        a.actionKey == b.actionKey && a.actions == b.actions && a.properties == b.properties && a.required == b.required
            && a.branches.keys.sorted() == b.branches.keys.sorted()
    }

    static func read(_ schema: JSONValue?) -> CloudToolSchema {
        let properties = schema?["properties"]?.object ?? [:]
        let required = Set(schema?["required"]?.array?.compactMap(\.string) ?? [])
        let actionKey = ["action", "operation", "op", "command"].first { properties[$0] != nil }
        var actions = actionKey.flatMap { properties[$0]?["enum"]?.array?.compactMap(\.string) } ?? []
        var out = CloudToolSchema(actionKey: actionKey, actions: actions, properties: properties, required: required)
        // Discriminated unions: each branch pins the action with const/enum and lists its own fields.
        for branch in (schema?["oneOf"]?.array ?? []) + (schema?["anyOf"]?.array ?? []) {
            let props = branch["properties"]?.object ?? [:]
            guard let key = actionKey ?? ["action", "operation", "op", "command"].first(where: { props[$0] != nil }),
                  let name = props[key]?["const"]?.string ?? props[key]?["enum"]?[0]?.string else { continue }
            out.actionKey = key
            if !actions.contains(name) { actions.append(name) }
            out.branches[name] = (props.merging(properties) { mine, _ in mine },
                                  required.union(branch["required"]?.array?.compactMap(\.string) ?? []))
        }
        out.actions = actions
        return out
    }

    /// Left out of create's form. compute_provider: production refuses every backend but DigitalOcean, which needs a
    /// flag on the account, so the default is the only safe choice. model: set in HQ once connected (per-bot Default
    /// Model), like any gateway.
    static let unasked: Set<String> = ["id", "agent_id", "agentId", "name", "compute_provider", "computeProvider", "model"]
    /// Form order: what changes the bill first.
    private static let order = ["size", "region"]

    /// The fields `action` takes, minus the action key and anything naming an existing agent. Fields whose description
    /// names other actions only ("(action='grow_disk')") are left out of create's form.
    func fields(for action: String, skipping skip: Set<String> = CloudToolSchema.unasked) -> [CloudField] {
        let (props, req) = branches[action] ?? (properties, required)
        let names = props.keys.sorted { a, b in
            let (ra, rb) = (Self.order.firstIndex(of: a) ?? Self.order.count, Self.order.firstIndex(of: b) ?? Self.order.count)
            return ra != rb ? ra < rb : a < b
        }
        return names.compactMap { name -> CloudField? in
            guard name != actionKey, !skip.contains(name), let prop = props[name] else { return nil }
            let detail = RosterText.text(prop["description"])
            if !branches.keys.contains(action), !Self.applies(detail, to: action, among: actions) { return nil }
            var choices = (prop["enum"]?.array ?? prop["items"]?["enum"]?.array ?? []).compactMap { $0.string ?? $0.double.map { String(Int($0)) } }
            var titles: [String: String] = [:]
            var fallback = prop["default"].flatMap { $0.string ?? $0.double.map { String(Int($0)) } ?? $0.bool.map { $0 ? "true" : "false" } }
            let type = prop["type"]?.string ?? (prop["type"]?.array?.compactMap(\.string).first { $0 != "null" } ?? "string")
            if choices.isEmpty, type == "string", let described = Self.describedChoices(detail) {
                // "e.g. 'standard' (default, 2 GB) or 'pro' (4 GB)": a free string the description lists the values of.
                choices = described.map(\.key)
                titles = Dictionary(uniqueKeysWithValues: described.map { ($0.key, $0.title) })
                fallback = fallback ?? described.first { $0.isDefault }?.key
                if name == "size" {
                    // Its sizes are examples ("e.g."): Portal also sells Max (8 GB), which the description leaves out.
                    let known = CloudPrices.sizes.sorted { $0.value.perDay < $1.value.perDay }.map(\.key)
                    choices += known.filter { key in !choices.contains { $0.lowercased() == key } }
                }
            }
            if name == "region" { titles.merge(Self.regionNames.filter { choices.contains($0.key) }) { mine, _ in mine } }
            if fallback == nil, let named = Self.statedDefault(detail), choices.contains(named) { fallback = named }
            let kind: CloudField.Kind = !choices.isEmpty ? .choice : type == "boolean" ? .toggle : (type == "integer" || type == "number") ? .number : .text
            // Objects and arrays without choices (env maps, image refs) aren't for a phone form.
            if kind == .text, type == "object" || type == "array" { return nil }
            return CloudField(name: name, title: RosterText.trimmed(prop["title"]) ?? Self.title(name), detail: detail,
                              choices: choices, choiceTitles: titles, defaultValue: fallback, required: req.contains(name), kind: kind)
        }
    }

    /// Values a description lists as `'key' (note)`, two or more of them; a note saying "default" marks the default.
    static func describedChoices(_ description: String) -> [(key: String, title: String, isDefault: Bool)]? {
        guard let pattern = try? NSRegularExpression(pattern: #"'([A-Za-z0-9_-]+)'\s*\(([^)]*)\)"#) else { return nil }
        let text = description as NSString
        var out: [(key: String, title: String, isDefault: Bool)] = []
        for match in pattern.matches(in: description, range: NSRange(location: 0, length: text.length)) {
            let key = text.substring(with: match.range(at: 1)), note = text.substring(with: match.range(at: 2))
            guard !out.contains(where: { $0.key == key }) else { continue }
            let isDefault = note.range(of: #"\bdefault\b"#, options: [.regularExpression, .caseInsensitive]) != nil
            let rest = note.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.lowercased() != "default" && !$0.isEmpty }.joined(separator: ", ")
            out.append((key, rest.isEmpty ? title(key) : "\(title(key)) · \(rest)", isDefault))
        }
        return out.count >= 2 ? out : nil
    }

    /// "Defaults to iad." → "iad".
    static func statedDefault(_ description: String) -> String? {
        guard let pattern = try? NSRegularExpression(pattern: #"[Dd]efaults? (?:to|is) '?([A-Za-z0-9_-]+)'?"#),
              let match = pattern.firstMatch(in: description, range: NSRange(location: 0, length: (description as NSString).length)) else { return nil }
        return (description as NSString).substring(with: match.range(at: 1))
    }

    /// Fly's region codes in the Portal's create schema.
    static let regionNames: [String: String] = [
        "iad": "Virginia, US", "sjc": "California, US", "ord": "Chicago, US", "dfw": "Dallas, US", "lhr": "London",
        "ams": "Amsterdam", "fra": "Frankfurt", "cdg": "Paris", "nrt": "Tokyo", "sin": "Singapore", "syd": "Sydney",
        "gru": "São Paulo", "yyz": "Toronto",
    ]

    /// Whether a shared field's description lets it apply to `action`: no actions named = applies to all.
    static func applies(_ description: String, to action: String, among actions: [String]) -> Bool {
        let lower = description.lowercased()
        let named = actions.filter { lower.range(of: "\\b\($0.lowercased())\\b", options: .regularExpression) != nil }
        return named.isEmpty || named.contains { $0.lowercased() == action.lowercased() }
    }

    /// "server_size" → "Server Size", "cpuKind" → "Cpu Kind".
    static func title(_ name: String) -> String {
        var words: [String] = [], current = ""
        for ch in name {
            if ch == "_" || ch == "-" || ch == " " { if !current.isEmpty { words.append(current) }; current = ""; continue }
            if ch.isUppercase, !current.isEmpty, !(current.last?.isUppercase ?? false) { words.append(current); current = "" }
            current.append(ch)
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

nonisolated struct CloudToolError: Error, Equatable, Sendable { var message: String }

/// What `agent` does to an agent that exists (create has its own call). Raw values are Portal's action names.
nonisolated enum CloudAction: String, Sendable, CaseIterable, Hashable {
    case start, stop, restart, destroy, rename, resize
    case updateImage = "update_image", updateEnv = "update_env", growDisk = "grow_disk", setFeature = "set_feature"

    /// How long the answer may take: these hold it while Nous stops and starts the machine.
    var timeout: TimeInterval {
        switch self {
        case .rename: 60
        case .start, .stop, .destroy, .setFeature: 150
        case .restart, .resize, .updateImage, .updateEnv, .growDisk: 300
        }
    }

    /// The agent restarts to apply it (a running one goes down and comes back).
    var restarts: Bool { [.restart, .resize, .updateImage, .updateEnv].contains(self) }
}

/// `team_gateway` status: Portal's connector that puts an agent on Discord, Telegram, Slack and WhatsApp.
nonisolated struct CloudTeamGateway: Sendable, Equatable {
    var enabled: Bool
    /// Chat apps with an account linked ("discord", "telegram" …).
    var platforms: [String] = []

    static func read(_ value: JSONValue) -> CloudTeamGateway? {
        let roots = [value["teamGateway"], value["team_gateway"], value["status"], value["data"], value].compactMap { $0 }.filter { $0.object != nil }
        for root in roots {
            guard let enabled = ["enabled", "isEnabled", "is_enabled", "relay", "relayEnabled", "relay_enabled", "on"]
                .lazy.compactMap({ root[$0]?.bool }).first else { continue }
            var platforms: [String] = []
            for key in ["platforms", "linkedPlatforms", "linked_platforms", "accounts", "identities", "links", "linked"] {
                for item in root[key]?.array ?? [] {
                    if let name = item.string ?? RosterText.trimmed(item["platform"]), !platforms.contains(name.lowercased()) { platforms.append(name.lowercased()) }
                }
            }
            return CloudTeamGateway(enabled: enabled, platforms: platforms)
        }
        return nil
    }
}

/// The Portal's MCP endpoint: initialize once, then `tools/list` and `tools/call`. One session per client.
actor HermesCloudClient {
    private var loggedShape = false
    static let endpoint = URL(string: Portal.resource)!
    static let protocolVersion = "2025-06-18"

    private let login: PortalLogin
    private let session: URLSession
    private let endpoint: URL
    private var sessionId: String?
    private var initialized = false
    /// The `initialize` in flight: calls made at once (opening Hermes Cloud reads the list and the create form
    /// together) wait for it instead of each starting a Portal session of its own.
    private var initializing: Task<Void, Error>?
    private var nextId = 1
    private var tools: [String: JSONValue] = [:]

    init(login: PortalLogin = .shared, session: URLSession = PortalAuth.makeSession(resourceTimeout: 330),
         endpoint: URL = HermesCloudClient.endpoint) {
        self.login = login; self.session = session; self.endpoint = endpoint
    }

    // MARK: Agents

    func listAgents() async throws -> [CloudAgent] {
        let value = try await call("agents", action: "list", arguments: [:])
        return CloudAgent.readAll(value)
    }

    /// One agent's current row: `agents` get/status by id, else the list. `live`: status first (Portal refreshes it from
    /// the machine; get may lag a stop or start by a poll or two).
    func agent(_ id: String, live: Bool = false) async throws -> CloudAgent? {
        let schema = try await schema("agents")
        for action in live ? ["status", "get"] : ["get", "status"] where schema.actions.contains(action) {
            let value = try await call("agents", action: action, arguments: [schema.idKey(for: action): .string(id)])
            if !loggedShape {
                // Portal's agent row is undocumented: its keys once per sign-in, for fitting CloudAgent.read.
                loggedShape = true
                let row = value["agent"] ?? value["data"] ?? value
                AppLog.trace("cloud", "agents \(action) keys: \(row.object?.keys.sorted().joined(separator: ",") ?? "-")")
            }
            let rows = CloudAgent.readAll(value)
            if let found = rows.first(where: { $0.id == id }) ?? (rows.count == 1 ? rows.first : nil) { return found }
        }
        return try await listAgents().first { $0.id == id }
    }

    /// Portal's cost estimate for one agent; nil when it has none or answers in a shape that names no amounts.
    func spend(_ id: String) async -> CloudSpend? {
        guard let schema = try? await schema("agents"), schema.actions.contains("cost_estimate"),
              let value = try? await call("agents", action: "cost_estimate", arguments: [schema.idKey(for: "cost_estimate"): .string(id)])
        else { return nil }
        let spend = CloudSpend.read(value)
        if spend == nil { AppLog.trace("cloud", "cost_estimate named no amounts: keys \(value.object?.keys.sorted().joined(separator: ",") ?? "-")") }
        return spend
    }

    /// The fields create takes beyond the name, from the server's schema.
    func createFields() async throws -> [CloudField] {
        try await schema("agent").fields(for: "create")
    }

    /// [update-flow] The fields an action takes beyond the agent's id, from the server's schema ([] when unread).
    func fields(for action: CloudAction) async -> [CloudField] {
        (try? await schema("agent").fields(for: action.rawValue)) ?? []
    }

    /// The longest name create takes (the schema's maxLength), else 64.
    func nameLimit() async -> Int {
        let schema = try? await schema("agent")
        let name = schema?.branches["create"]?.properties["name"] ?? schema?.properties["name"]
        return name?["maxLength"]?.int ?? 64
    }

    /// Provisioning can take minutes. If the wait runs out the create still carries on at Portal, so a caller looks
    /// for the name in the list instead of creating again (a second create makes, and bills, a second agent).
    func create(name: String, values: [String: JSONValue]) async throws -> CloudAgent? {
        var args = values
        args["name"] = .string(name)
        let value = try await call("agent", action: "create", arguments: args, timeout: 300)
        return CloudAgent.readAll(value).first
    }

    func start(_ id: String) async throws {
        try await act(.start, on: id)
    }

    /// The `agent` actions this Portal offers for an existing agent (an older or newer one may lack some).
    func offered() async -> Set<CloudAction> {
        guard let schema = try? await schema("agent") else { return [] }
        return Set(schema.actions.compactMap(CloudAction.init(rawValue:)))
    }

    /// One action on an agent that exists. `extra` carries the action's own fields (rename's name, resize's size,
    /// update_env's env and deleted_keys …). Returns the agent's row when the answer carries one. A restart, resize,
    /// new image or new variables can hold the answer while Nous stops and starts the machine.
    @discardableResult
    func act(_ action: CloudAction, on id: String, _ extra: [String: JSONValue] = [:]) async throws -> CloudAgent? {
        var args = extra
        args[try await schema("agent").idKey(for: action.rawValue)] = .string(id)
        let value = try await call("agent", action: action.rawValue, arguments: args, timeout: action.timeout)
        let rows = CloudAgent.readAll(value)
        return rows.first { $0.id == id }
    }

    /// The sizes resize takes: the schema's size field (its description lists them), else the price table's.
    func sizeChoices() async -> [String] {
        let field = try? await schema("agent").fields(for: "resize").first { $0.name == "size" }
        if let choices = field?.choices, !choices.isEmpty { return choices }
        return CloudPrices.sizes.sorted { $0.value.perDay < $1.value.perDay }.map(\.key)
    }

    /// Team Gateway for one agent: on or off and the chat apps linked. Nil when this Portal has no `team_gateway` tool
    /// or answers in a shape that doesn't say.
    func teamGateway(_ id: String) async -> CloudTeamGateway? {
        guard let schema = try? await schema("team_gateway"), schema.actions.contains("status"),
              let value = try? await call("team_gateway", action: "status", arguments: [schema.idKey(for: "status"): .string(id)])
        else { return nil }
        let found = CloudTeamGateway.read(value)
        if found == nil { AppLog.trace("cloud", "team_gateway status said no on/off: keys \(value.object?.keys.sorted().joined(separator: ",") ?? "-")") }
        return found
    }

    // MARK: Tools

    func schema(_ tool: String) async throws -> CloudToolSchema {
        if tools.isEmpty { try await loadTools() }
        guard let found = tools[tool] else { throw CloudToolError(message: "Nous Portal doesn’t offer \(tool) to this app.") }
        return CloudToolSchema.read(found["inputSchema"])
    }

    /// `tools/call`; the answer's JSON (structuredContent, else the text content parsed, else the text itself).
    func call(_ tool: String, action: String, arguments: [String: JSONValue], timeout: TimeInterval = 60) async throws -> JSONValue {
        let schema = try await schema(tool)
        var args = arguments
        if let key = schema.actionKey { args[key] = .string(action) }
        let result = try await rpc("tools/call", ["name": .string(tool), "arguments": .object(args)], timeout: timeout)
        let text = (result["content"]?.array ?? []).compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: "\n")
        if result["isError"]?.bool == true {
            throw CloudToolError(message: String(Self.errorText(text).prefix(400)))
        }
        if let structured = result["structuredContent"], !structured.isNull { return structured }
        if let data = text.data(using: .utf8), let parsed = try? JSONValue.parse(data) { return parsed }
        return .string(text)
    }

    private static func errorText(_ text: String) -> String {
        if let data = text.data(using: .utf8), let value = try? JSONValue.parse(data) {
            return RosterText.trimmed(value["error"]?["message"]) ?? RosterText.trimmed(value["message"]) ?? RosterText.trimmed(value["error"]) ?? text
        }
        return text.isEmpty ? "Nous Portal refused that." : text
    }

    private func loadTools() async throws {
        let result = try await rpc("tools/list", [:])
        var found: [String: JSONValue] = [:]
        for tool in result["tools"]?.array ?? [] { if let name = tool["name"]?.string { found[name] = tool } }
        tools = found
    }

    // MARK: Transport

    private func ensureInitialized() async throws {
        guard !initialized else { return }
        if let initializing { return try await initializing.value }
        let flight = Task { try await self.initialize() }
        initializing = flight
        defer { initializing = nil }
        try await flight.value
    }

    private func initialize() async throws {
        _ = try await post(["jsonrpc": "2.0", "id": .number(Double(takeId())), "method": "initialize",
                            "params": ["protocolVersion": .string(Self.protocolVersion), "capabilities": [:],
                                       "clientInfo": ["name": "hermes-hq", "version": .string(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0")]]])
        initialized = true
        _ = try? await post(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    private func rpc(_ method: String, _ params: JSONValue, timeout: TimeInterval = 60) async throws -> JSONValue {
        try await ensureInitialized()
        let answer: JSONValue
        do {
            answer = try await post(["jsonrpc": "2.0", "id": .number(Double(takeId())), "method": .string(method), "params": params], timeout: timeout)
        } catch let error as CloudSessionLost {
            _ = error
            // The server forgot this session (restart, idle) and ran nothing: start a new one, send once more.
            initialized = false; sessionId = nil
            try await ensureInitialized()
            answer = try await post(["jsonrpc": "2.0", "id": .number(Double(takeId())), "method": .string(method), "params": params], timeout: timeout)
        }
        if let error = answer["error"], !error.isNull {
            throw CloudToolError(message: RosterText.trimmed(error["message"]) ?? "Nous Portal refused that.")
        }
        return answer["result"] ?? .null
    }

    private struct CloudSessionLost: Error {}

    private func takeId() -> Int { defer { nextId += 1 }; return nextId }

    /// One POST; renews the Portal login once on 401 (nothing ran). Reads a JSON body or the last `data:` of an event
    /// stream.
    private func post(_ message: JSONValue, retried: Bool = false, refused: String? = nil, timeout: TimeInterval = 60) async throws -> JSONValue {
        let token = try await login.accessToken(force: retried, refused: refused)
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = try message.encoded()
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionId { request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id") }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw PortalAuth.mapped(error) }
        guard let http = response as? HTTPURLResponse else { throw PortalError.problem }
        if let id = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !id.isEmpty { sessionId = id }
        switch http.statusCode {
        case 200..<300: break
        case 401 where !retried: return try await post(message, retried: true, refused: token, timeout: timeout)
        case 401: await login.signOut(); throw PortalError.signedOut
        case 404 where sessionId != nil: throw CloudSessionLost()
        case 403: throw PortalError(kind: .refused, message: "Your Nous account can’t manage Hermes Cloud agents.")
        case 429: throw PortalError(kind: .server, message: "Nous Portal is busy. Try again in a minute.")
        default:
            AppLog.note("auth", "hermes cloud mcp HTTP \(http.statusCode)")
            throw PortalError.problem
        }
        if message["id"] == nil { return .null }   // a notification: 202, no body
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        return try Self.answer(data, eventStream: type.contains("text/event-stream"))
    }

    /// The JSON-RPC answer in a body: plain JSON, or the last `data:` event carrying a result or error.
    static func answer(_ data: Data, eventStream: Bool) throws -> JSONValue {
        guard eventStream else {
            guard let value = try? JSONValue.parse(data) else { throw PortalError.problem }
            return value
        }
        let text = String(decoding: data, as: UTF8.self)
        var events: [String] = [], current: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = line.hasSuffix("\r") ? line.dropLast() : line[...]
            if line.isEmpty { if !current.isEmpty { events.append(current.joined(separator: "\n")) }; current = []; continue }
            if line.hasPrefix("data:") { current.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
        }
        if !current.isEmpty { events.append(current.joined(separator: "\n")) }
        for event in events.reversed() {
            if let value = try? JSONValue.parse(Data(event.utf8)), value["result"] != nil || value["error"] != nil { return value }
        }
        throw PortalError.problem
    }
}

extension CloudToolSchema {
    /// The property that names an existing agent for `action` ("id", "agent_id", "agentId", "name").
    nonisolated func idKey(for action: String) -> String {
        let props = branches[action]?.properties ?? properties
        return ["id", "agent_id", "agentId", "agent", "name"].first { props[$0] != nil } ?? "id"
    }
}
