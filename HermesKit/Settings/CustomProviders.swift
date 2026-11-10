// [custom-providers] Your own providers (Settings › Providers › Your Providers): OpenAI-compatible services added by
// hand, kept in the gateway's config.yaml under `providers:`. The same calls the Hermes desktop app's Custom Endpoints
// page makes (`apps/desktop/src/app/settings/custom-endpoints-settings.tsx`), so a name set here is the name the desktop
// app, the chat menus and the terminal all show:
//   GET    /api/providers/custom-endpoints                {endpoints: [row], current: {provider, model, base_url}}
//   POST   /api/providers/custom-endpoints {draft}        add or edit; `id` keeps an edit on its own entry, so a rename
//                                                         keeps the id and the chats using it keep working
//   POST   /api/providers/custom-endpoints/validate       Test Connection: {ok, reachable, message, models, ...}
//   POST   /api/providers/custom-endpoints/{id}/activate  the gateway's default model
//   DELETE /api/providers/custom-endpoints/{id}
// A key is sent only when typed (left out: kept; "": removed). Hermes saves it in its .env, never in config.yaml.
// Nothing here logs a value.

import Foundation

/// How Hermes talks to the service (`api_mode`); automatic lets Hermes work it out from the address.
nonisolated enum CustomProviderMode: String, CaseIterable, Sendable, Hashable {
    case automatic = ""
    case chatCompletions = "chat_completions"
    case responses = "codex_responses"
    case anthropic = "anthropic_messages"

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .chatCompletions: "Chat Completions"
        case .responses: "Responses API"
        case .anthropic: "Anthropic Messages"
        }
    }
}

/// One row of `GET /api/providers/custom-endpoints`.
nonisolated struct CustomProvider: Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var baseURL: String
    var model: String
    var models: [String]
    var mode: CustomProviderMode
    var contextLength: Int?
    var discoverModels: Bool
    var hasKey: Bool
    var isCurrent: Bool
    /// "providers"; "custom_providers" (an older entry Hermes moves on its first save); "direct-config" (the default
    /// model's own address, with no entry to delete).
    var source: String

    init(id: String, name: String, baseURL: String, model: String, models: [String] = [], mode: CustomProviderMode = .automatic,
         contextLength: Int? = nil, discoverModels: Bool = true, hasKey: Bool = false, isCurrent: Bool = false,
         source: String = "providers") {
        self.id = id; self.name = name; self.baseURL = baseURL; self.model = model; self.models = models; self.mode = mode
        self.contextLength = contextLength; self.discoverModels = discoverModels; self.hasKey = hasKey
        self.isCurrent = isCurrent; self.source = source
    }

    init?(_ value: JSONValue) {
        guard let id = RosterText.trimmed(value["id"]), let baseURL = RosterText.trimmed(value["base_url"]) else { return nil }
        let model = RosterText.trimmed(value["model"]) ?? ""
        var models: [String] = []
        for name in (value["models"]?.array ?? []).compactMap({ RosterText.trimmed($0) }) where !models.contains(name) {
            models.append(name)
        }
        if !model.isEmpty, !models.contains(model) { models.insert(model, at: 0) }
        self.init(id: id, name: RosterText.trimmed(value["name"]) ?? id, baseURL: baseURL, model: model, models: models,
                  mode: CustomProviderMode(rawValue: value["api_mode"]?.string ?? "") ?? .automatic,
                  contextLength: value["context_length"]?.int.flatMap { $0 > 0 ? $0 : nil },
                  discoverModels: value["discover_models"]?.bool ?? true, hasKey: value["has_api_key"]?.bool ?? false,
                  isCurrent: value["is_current"]?.bool ?? false, source: value["source"]?.string ?? "providers")
    }

    static func list(_ value: JSONValue) -> [CustomProvider] {
        (value["endpoints"]?.array ?? []).compactMap(CustomProvider.init)
    }

    /// The default model's own address isn't an entry: there's nothing to delete.
    var canDelete: Bool { source != "direct-config" }

    /// The address as the row shows it: the host and port, or the whole address when it has none.
    var shortAddress: String {
        guard let url = URL(string: baseURL), let host = url.host(percentEncoded: false), !host.isEmpty else { return baseURL }
        return url.port.map { "\(host):\($0)" } ?? host
    }
}

/// The Test Connection answer (`POST …/validate`).
nonisolated struct CustomProviderTest: Sendable, Equatable {
    var ok: Bool
    var reachable: Bool
    var message: String
    var models: [String]
    /// `/v1/models` rows with their routing (`gpt-5.6-sol-high` → `gpt-5.6-sol` at high): sent back on Save so the
    /// gateway keeps what each stands for.
    var modelDetails: [JSONValue]
    /// The address that answered (`<root>/v1` when the root was typed): Save keeps it, as the desktop app does.
    var resolvedBaseURL: String?
    var transport: CustomProviderMode?

    init(ok: Bool, reachable: Bool = true, message: String = "", models: [String] = [], modelDetails: [JSONValue] = [],
         resolvedBaseURL: String? = nil, transport: CustomProviderMode? = nil) {
        self.ok = ok; self.reachable = reachable; self.message = message; self.models = models
        self.modelDetails = modelDetails; self.resolvedBaseURL = resolvedBaseURL; self.transport = transport
    }

    init(_ value: JSONValue) {
        self.init(ok: value["ok"]?.bool ?? false, reachable: value["reachable"]?.bool ?? false,
                  message: RosterText.trimmed(value["message"]) ?? "",
                  models: (value["models"]?.array ?? []).compactMap { RosterText.trimmed($0) },
                  modelDetails: value["model_details"]?.array ?? [],
                  resolvedBaseURL: RosterText.trimmed(value["resolved_base_url"]),
                  transport: value["transport_checked"]?.string.flatMap(CustomProviderMode.init(rawValue:)))
    }

    /// The result in words, under the Test Connection button.
    var summary: String {
        guard ok else {
            if !message.isEmpty { return message }
            return reachable ? "The service answered, but not as expected." : "Couldn’t reach this address."
        }
        let via = transport.map { $0 == .automatic ? "" : " using \($0.title)" } ?? ""
        switch models.count {
        case 0: return "Connected\(via)."
        case 1: return "Connected\(via). Found 1 model."
        default: return "Connected\(via). Found \(models.count) models."
        }
    }
}

/// The provider page's fields, and the body Save sends.
nonisolated struct CustomProviderDraft: Sendable, Equatable {
    /// The entry being edited; "" while new (Hermes makes one from the name).
    var id = ""
    var name = ""
    var baseURL = ""
    var model = ""
    /// Every model the page knows (saved, found by Test Connection, typed): the Default Model choices. Not sent.
    var models: [String] = []
    var modelDetails: [JSONValue] = []
    var mode: CustomProviderMode = .automatic
    /// Typed digits; "" keeps what is saved (Hermes has no way to clear it).
    var contextLength = ""
    var discoverModels = true
    /// A new key, typed; "" sends none (the saved one stays).
    var key = ""
    /// Remove Key: sends "" so the gateway deletes it.
    var removeKey = false
    /// [provider-manager] Model ids typed under Add Model…: sent as `models`, which Hermes adds to the endpoint's saved
    /// list (it keeps the ones already there; it can't take one away).
    var addModels: [String] = []

    init() {}

    init(_ provider: CustomProvider) {
        id = provider.id
        name = provider.name
        baseURL = provider.baseURL
        model = provider.model
        models = provider.models
        mode = provider.mode
        contextLength = provider.contextLength.map(String.init) ?? ""
        discoverModels = provider.discoverModels
    }

    private static func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isNew: Bool { id.isEmpty }

    /// Why the address can't be saved, or nil.
    var addressProblem: String? {
        let text = Self.trim(baseURL)
        guard !text.isEmpty else { return nil }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(percentEncoded: false), !host.isEmpty else {
            return "Enter the whole address, starting with http:// or https://."
        }
        return nil
    }

    /// The typed context window, nil when empty or not a number.
    var contextValue: Int? { Int(Self.trim(contextLength)).flatMap { $0 > 0 ? $0 : nil } }

    var contextProblem: String? {
        Self.trim(contextLength).isEmpty || contextValue != nil ? nil : "Enter a whole number of tokens, like 128000."
    }

    var canSave: Bool {
        !Self.trim(name).isEmpty && !Self.trim(baseURL).isEmpty && !Self.trim(model).isEmpty
            && addressProblem == nil && contextProblem == nil
    }

    /// The fields as Save compares them: trimmed, without the model choices.
    private var compared: CustomProviderDraft {
        var draft = self
        draft.name = Self.trim(name); draft.baseURL = Self.trim(baseURL).trimmingSuffix("/"); draft.model = Self.trim(model)
        draft.contextLength = Self.trim(contextLength); draft.key = Self.trim(key)
        draft.models = []; draft.modelDetails = []
        return draft
    }

    /// Something Save would change: a field, a typed key or Remove Key.
    func differs(from saved: CustomProviderDraft) -> Bool { compared != saved.compared }

    /// Makes `name` the default model, adding it to the choices when it is new (a name typed under Another Model).
    mutating func choose(_ name: String) {
        let name = Self.trim(name)
        guard !name.isEmpty else { return }
        if !models.contains(name) { models.append(name) }
        model = name
    }

    /// What Test Connection found: its models join the list, its address replaces a root that was typed, and the first
    /// model becomes the default when there is none.
    mutating func apply(_ test: CustomProviderTest) {
        guard test.ok else { return }
        for name in test.models where !models.contains(name) { models.append(name) }
        modelDetails = test.modelDetails
        if let resolved = test.resolvedBaseURL, resolved != Self.trim(baseURL).trimmingSuffix("/") { baseURL = resolved }
        if Self.trim(model).isEmpty, let first = test.models.first { model = first }
    }

    /// `POST /api/providers/custom-endpoints` (and `…/validate`, which reads the same fields).
    var body: JSONValue {
        var body: [String: JSONValue] = [
            "name": .string(Self.trim(name)),
            "base_url": .string(Self.trim(baseURL).trimmingSuffix("/")),
            "model": .string(Self.trim(model)),
            "api_mode": .string(mode.rawValue),
            "discover_models": .bool(discoverModels),
            "make_default": false,
        ]
        if !id.isEmpty { body["id"] = .string(id) }
        let typedKey = Self.trim(key)
        if !typedKey.isEmpty {
            body["api_key"] = .string(typedKey)
        } else if removeKey {
            body["api_key"] = ""
        }
        if let context = contextValue { body["context_length"] = .number(Double(context)) }
        // Not the models Test Connection found: Hermes keeps the saved list and adds the default itself, and a service's
        // whole catalogue (hundreds of ids) would be written into config.yaml. Only the default's routing goes, so an
        // alias (`gpt-5.6-sol-high`) is saved as what it stands for; a plain model (a row with only its id) sends none.
        let chosen = modelDetails.filter { row in
            row["id"]?.string.map(Self.trim) == Self.trim(model) && (row.object?.keys.contains { $0 != "id" } ?? false)
        }
        if !chosen.isEmpty { body["model_details"] = .array(chosen) }
        let added = addModels.map(Self.trim).filter { !$0.isEmpty }
        if !added.isEmpty { body["models"] = .array(added.map { .string($0) }) }
        return .object(body)
    }
}

private extension String {
    nonisolated func trimmingSuffix(_ suffix: String) -> String {
        var text = self
        while text.hasSuffix(suffix) { text.removeLast(suffix.count) }
        return text
    }
}
