// The gateway calls behind Settings' gateway pages, exactly as the web app makes them (`vendor/.../api/config.ts`,
// `api/models.ts`, `settings/vault-settings.tsx`, `settings/billing/api.ts`):
//   GET  /api/config            the record (defaults filled in)        GET /api/config/schema    the field schema
//   GET  /api/config/defaults   Hermes' defaults                        PUT /api/config {config}  a sparse patch (deep-merged)
//   GET  /api/env               keys, redacted                          PUT /api/env {key,value}  DELETE /api/env {key}
//   POST /api/env/reveal {key}  one key's value (rate limited, audited)
//   GET  /api/model/info, /api/model/options, /api/model/auxiliary, /api/model/moa;  POST /api/model/set;  PUT /api/model/moa
//        (each with `?profile=` for one bot's own, as the desktop app scopes them; every Hermes with `profiles.list` takes it)
//   GET  /api/providers/oauth   provider sign-ins          DELETE /api/providers/oauth/{id}   [provider-add] sign out of one
//   GET/POST /api/providers/custom-endpoints (+ /validate, /{id}/activate, DELETE /{id})   your own providers
//   RPC  vault.list / vault.add / vault.remove / vault.sources / vault.source.set / vault.unlock / vault.lock, billing.state
// Nothing here logs a value: only which call failed and its status.

import Foundation

nonisolated struct GatewaySettingsAPI: Sendable {
    let client: any GatewayClient
    /// [talk] One bot's own settings (`?profile=`, which Hermes' config and model routes take): the iPhone-voice notice's
    /// Fix… opens that bot's Text to Speech page (docs/spec/3x-talk.md §7.7), and a bot's Default Model is its own.
    /// nil: the gateway's own settings.
    var profile: String? = nil

    init(client: any GatewayClient, profile: String? = nil) {
        self.client = client
        self.profile = profile
    }

    private var profileQuery: [URLQueryItem] { VoiceWire.profileQuery(profile) }

    // MARK: REST plumbing

    private func json(_ method: String, _ path: String, query: [URLQueryItem] = [], body: JSONValue? = nil) async throws -> JSONValue {
        let data = try await client.rest(method, path, query: query, body: try body?.encoded())
        if data.isEmpty { return .object([:]) }
        return try JSONValue.parseFast(data)
    }

    // MARK: Config

    func config() async throws -> JSONValue { try await json("GET", "/api/config", query: profileQuery) }

    /// Is `path` a folder on the gateway computer (`GET /api/fs/list`: an `entries` array and no `error`)? [settings]
    func folderExists(_ path: String) async throws -> Bool {
        DefaultProjectFolder.isFolder(try await json("GET", "/api/fs/list", query: [URLQueryItem(name: "path", value: path)]))
    }
    func schema() async throws -> [String: ConfigFieldSchema] { ConfigFieldSchema.fields(try await json("GET", "/api/config/schema")) }
    func defaults() async throws -> JSONValue { try await json("GET", "/api/config/defaults") }

    /// `PUT /api/config` with `{config: patch}`. A gateway answer without `ok: true` is a refusal.
    func saveConfig(_ patch: JSONValue) async throws {
        let answer = try await json("PUT", "/api/config", query: profileQuery, body: ["config": patch])
        if answer["ok"]?.bool == false { throw SettingsSaveError.refused }
        // [talk] Live voice keeps the voice settings for a minute: a save is read again at once.
        VoiceGateway.forgetConfig()
    }

    // MARK: Keys

    func env() async throws -> [EnvVarInfo] { EnvVarInfo.list(try await json("GET", "/api/env")) }

    func setEnv(_ key: String, value: String, providerSetup: Bool = false) async throws {
        var body: [String: JSONValue] = ["key": .string(key), "value": .string(value)]
        if providerSetup { body["provider_setup"] = true }
        let answer = try await json("PUT", "/api/env", body: .object(body))
        if answer["ok"]?.bool == false { throw SettingsSaveError.refused }
    }

    func deleteEnv(_ key: String) async throws {
        let answer = try await json("DELETE", "/api/env", body: ["key": .string(key)])
        if answer["ok"]?.bool == false { throw SettingsSaveError.refused }
    }

    /// The real value: shown, never stored or logged.
    func revealEnv(_ key: String) async throws -> String {
        try await json("POST", "/api/env/reveal", body: ["key": .string(key)])["value"]?.string ?? ""
    }

    // MARK: Models

    func modelInfo() async throws -> JSONValue { try await json("GET", "/api/model/info", query: profileQuery) }

    func modelOptions() async throws -> [ModelProviderOption] {
        let answer = try await json("GET", "/api/model/options", query: [URLQueryItem(name: "explicit_only", value: "1")] + profileQuery)
        return (answer["providers"]?.array ?? []).compactMap(ModelProviderOption.init)
    }

    func auxiliary() async throws -> [AuxiliaryAssignment] {
        try await json("GET", "/api/model/auxiliary", query: profileQuery)["tasks"]?.array?.compactMap(AuxiliaryAssignment.init) ?? []
    }

    /// `POST /api/model/set`. A `confirm_required` answer throws `.confirm(message)`; send again with `confirm: true`.
    @discardableResult
    func setModel(scope: String, provider: String, model: String, task: String? = nil, baseURL: String? = nil,
                  confirm: Bool = false) async throws -> JSONValue {
        var body: [String: JSONValue] = ["scope": .string(scope), "provider": .string(provider), "model": .string(model)]
        if let task { body["task"] = .string(task) }
        if let baseURL, !baseURL.isEmpty { body["base_url"] = .string(baseURL) }
        if confirm { body["confirm_expensive_model"] = true }
        let answer = try await json("POST", "/api/model/set", query: profileQuery, body: .object(body))
        if answer["confirm_required"]?.bool == true {
            throw ModelSetError.confirm(ModelSwitchWording.plain(answer["confirm_message"]?.string ?? "This model costs more than most. Use it anyway?"))
        }
        if answer["ok"]?.bool == false { throw SettingsSaveError.refused }
        return answer
    }

    func moa() async throws -> JSONValue { try await json("GET", "/api/model/moa", query: profileQuery) }

    func saveMoa(_ body: JSONValue) async throws -> JSONValue {
        let answer = try await json("PUT", "/api/model/moa", query: profileQuery, body: body)
        if answer["ok"]?.bool == false { throw SettingsSaveError.refused }
        return answer
    }

    // MARK: Provider sign-ins

    func oauthProviders() async throws -> [OAuthProviderRow] {
        try await json("GET", "/api/providers/oauth")["providers"]?.array?.compactMap(OAuthProviderRow.init) ?? []
    }

    /// [provider-add] Signs the gateway out of a provider (`DELETE /api/providers/oauth/{id}`, the Hermes desktop app's
    /// Disconnect): Hermes forgets the sign-in it keeps. Offered only on a row the gateway marks `disconnectable`.
    func signOutOAuthProvider(_ id: String) async throws {
        let answer = try await json("DELETE", "/api/providers/oauth/\(HistoryRequest.encodePathSegment(id))")
        if answer["ok"]?.bool == false { throw SettingsSaveError.refused }
    }

    // MARK: Your own providers (`CustomProviders.swift`)

    func customProviders() async throws -> [CustomProvider] {
        CustomProvider.list(try await json("GET", "/api/providers/custom-endpoints", query: profileQuery))
    }

    /// Adds or edits one; answers the list as it now stands.
    func saveCustomProvider(_ draft: CustomProviderDraft) async throws -> [CustomProvider] {
        let answer = try await json("POST", "/api/providers/custom-endpoints", query: profileQuery, body: draft.body)
        if answer["ok"]?.bool == false { throw SettingsSaveError.refused }
        return CustomProvider.list(answer)
    }

    func testCustomProvider(_ draft: CustomProviderDraft) async throws -> CustomProviderTest {
        CustomProviderTest(try await json("POST", "/api/providers/custom-endpoints/validate", body: draft.body))
    }

    /// Makes it the gateway's default model (its own default model).
    func activateCustomProvider(_ id: String) async throws {
        let answer = try await json("POST", "/api/providers/custom-endpoints/\(HistoryRequest.encodePathSegment(id))/activate",
                                    query: profileQuery)
        if answer["ok"]?.bool == false { throw SettingsSaveError.refused }
    }

    func deleteCustomProvider(_ id: String) async throws -> [CustomProvider] {
        let answer = try await json("DELETE", "/api/providers/custom-endpoints/\(HistoryRequest.encodePathSegment(id))",
                                    query: profileQuery)
        if answer["ok"]?.bool == false { throw SettingsSaveError.refused }
        return CustomProvider.list(answer)
    }

    // MARK: RPC (vault, billing)

    func rpc(_ method: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
        try await client.call(method, params, timeout: .seconds(30))
    }
}

// MARK: - Answers

nonisolated enum SettingsSaveError: Error, LocalizedError, Equatable {
    case refused
    var errorDescription: String? { "Your gateway didn’t accept the change." }
}

nonisolated enum ModelSetError: Error, LocalizedError, Equatable {
    case confirm(String)
    var errorDescription: String? {
        if case .confirm(let message) = self { return message }
        return nil
    }
}

/// A provider row of `/api/model/options` (`ModelOptionProvider`).
nonisolated struct ModelProviderOption: Sendable, Hashable, Identifiable {
    var slug: String
    var name: String
    var models: [String]
    var authenticated: Bool?
    var authType: String?
    var keyEnv: String?
    var apiURL: String?
    var isCurrent: Bool
    var id: String { slug }

    init(slug: String, name: String, models: [String], authenticated: Bool? = nil, authType: String? = nil, keyEnv: String? = nil,
         apiURL: String? = nil, isCurrent: Bool = false) {
        self.slug = slug; self.name = name; self.models = models; self.authenticated = authenticated; self.authType = authType
        self.keyEnv = keyEnv; self.apiURL = apiURL; self.isCurrent = isCurrent
    }

    init?(_ value: JSONValue) {
        guard let slug = value["slug"]?.string else { return nil }
        self.init(slug: slug, name: RosterText.trimmed(value["name"]) ?? slug, models: value["models"]?.array?.compactMap(\.string) ?? [],
                  authenticated: value["authenticated"]?.bool, authType: value["auth_type"]?.string,
                  keyEnv: RosterText.trimmed(value["key_env"]), apiURL: RosterText.trimmed(value["api_url"]),
                  isCurrent: value["is_current"]?.bool ?? false)
    }

    /// Signed in or has models (`isProviderReady`).
    var isReady: Bool { authenticated != false || !models.isEmpty }
}

/// One auxiliary task's model (`AuxiliaryTaskAssignment`).
nonisolated struct AuxiliaryAssignment: Sendable, Hashable, Identifiable {
    var task: String
    var provider: String
    var model: String
    var baseURL: String
    var id: String { task }

    init(task: String, provider: String, model: String, baseURL: String = "") {
        self.task = task; self.provider = provider; self.model = model; self.baseURL = baseURL
    }

    init?(_ value: JSONValue) {
        guard let task = value["task"]?.string else { return nil }
        self.init(task: task, provider: value["provider"]?.string ?? "", model: value["model"]?.string ?? "",
                  baseURL: value["base_url"]?.string ?? "")
    }

    /// "auto" / "main" / empty: it follows the main model.
    var followsMain: Bool { ["", "auto", "main"].contains(provider.lowercased()) }

    static let titles: [String: String] = [
        "vision": "Vision", "compression": "Compression", "skills_hub": "Skills Hub", "approval": "Approvals", "mcp": "Connectors",   /* Stress test 2026-10-28 #59, round 2 (both) */
        "title_generation": "Chat Titles", "review": "Review", "triage_specifier": "Triage", "kanban_decomposer": "Kanban Planning",
        "profile_describer": "Bot Descriptions", "curator": "Curator",
    ]

    static func title(_ task: String) -> String { titles[task] ?? ConfigText.pretty(task) }
}

/// A provider sign-in row of `/api/providers/oauth`.
nonisolated struct OAuthProviderRow: Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var connected: Bool
    var detail: String?
    /// [provider-add] Hermes can sign it out itself (`disconnectable`; false for a sign-in another app owns, like Claude
    /// Code's, or one that is really an API key). An older Hermes without the field offers no Sign Out.
    var canSignOut: Bool

    init?(_ value: JSONValue) {
        guard let id = value["id"]?.string ?? value["provider"]?.string else { return nil }
        self.id = id
        name = RosterText.trimmed(value["name"]) ?? RosterText.trimmed(value["label"]) ?? ConfigText.pretty(id)
        let status = value["status"]
        connected = value["logged_in"]?.bool ?? value["connected"]?.bool ?? status?["logged_in"]?.bool ?? false
        detail = RosterText.trimmed(value["account"]) ?? RosterText.trimmed(status?["account_tier"]) ?? RosterText.trimmed(value["description"])
        canSignOut = connected && value["disconnectable"]?.bool == true
    }
}

// MARK: - Failure words (`loadErrorText` / `saveFailureText`)

nonisolated enum SettingsErrorText {
    private static func raw(_ error: Error) -> String {
        if let http = error as? HTTPError {
            if let body = http.body, let data = body.data(using: .utf8), let json = try? JSONValue.parse(data),
               let detail = json["detail"]?.string ?? json["error"]?.string ?? json["message"]?.string {
                return detail
            }
            return "HTTP \(http.status)"
        }
        if let rpc = error as? RPCError { return rpc.message }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private static func network(_ text: String) -> Bool {
        text.range(of: #"not connected|not open|offline|can.t reach|could not connect|network connection|internet connection|-100[3459]\b|socket"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func timeout(_ text: String) -> Bool {
        text.range(of: #"timed?\s*out|timeout|took too long|-1001\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Why a Settings list didn't load, in words (never the transport string).
    static func load(_ error: Error) -> String {
        if let failure = error as? GatewayFailure { return failure.localizedDescription }
        if let rpc = error as? RPCError, rpc.isNotConnected { return "Hermes HQ can’t reach your gateway right now. It tries again when the connection is back." }
        let text = raw(error)
        if timeout(text) { return "Your gateway didn’t answer in time. It may be busy; try again in a moment." }
        if network(text) { return "Hermes HQ can’t reach your gateway right now. It tries again when the connection is back." }
        if (error as? HTTPError)?.status == 404 { return MoreWire.olderHermes }   // Mac UX stress test #10
        return text.count <= 180 && text.range(of: "[{}<>]", options: .regularExpression) == nil && !text.hasPrefix("HTTP ")
            ? text : "Your gateway couldn’t send this list. Try again in a moment."
    }

    /// Why a save didn't reach the gateway, in words.
    static func save(_ error: Error) -> String {
        if let failure = error as? GatewayFailure { return failure.localizedDescription }
        let text = raw(error)
        if timeout(text) { return "Your gateway didn’t answer in time. Try again in a moment." }
        if network(text) || (error as? RPCError)?.isNotConnected == true { return "Hermes HQ can’t reach your gateway right now. Try again when it’s back." }
        return text.count <= 180 && text.range(of: "[{}<>]", options: .regularExpression) == nil && !text.hasPrefix("HTTP ")
            ? text : "Your gateway didn’t accept the change."
    }
}
