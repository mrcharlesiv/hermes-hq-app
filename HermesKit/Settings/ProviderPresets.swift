// [provider-add] Owner 2026-11-04: "i need to be able to more easily add them adn i need to remove them" (Settings ›
// Providers). The Add Provider chooser (+ on the Providers page, Your Providers' Add Provider…, the model list's Add
// Provider…) offers well-known OpenAI-compatible services as presets that fill in the name and address, the providers
// Hermes has built in (their API key's page), and an empty form for any other service.
//
// A preset whose service Hermes already has built in, with a key the gateway lists (`GET /api/env`, category "provider":
// OpenRouter, DeepSeek, Fireworks on today's Hermes), opens that key instead of adding a second, hand-made entry: the
// built-in one knows the service's models and prices. The rest (Together, Groq, Mistral, a local model server) become
// Your Providers entries. LM Studio stays one too: Hermes' built-in LM Studio needs no key (LM_API_KEY is only a token
// for a server with sign-in turned on), so there is nothing for its key page to add, while an entry can Test the address
// and pick a model. Mistral's MISTRAL_API_KEY is a tool key (voice), not a provider, so it is not used here.

import Foundation

nonisolated struct ProviderPreset: Sendable, Hashable, Identifiable {
    enum Place: Sendable, Hashable {
        /// A service on the internet, paid with a key.
        case online
        /// A model server on the computer Hermes runs on (127.0.0.1 is that computer, not this device).
        case local
    }

    var id: String
    var name: String
    /// The service's OpenAI-compatible address (it ends in /v1 or the service's own equivalent).
    var baseURL: String
    /// One line under the name.
    var detail: String
    var place: Place
    /// Hermes' own key for this service, used instead of an entry when the gateway lists it as a provider key.
    var envKey: String?

    /// Checked 2026-11-04 against each service's own docs for its OpenAI-compatible base URL.
    static let all: [ProviderPreset] = [
        .init(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1",
              detail: "Hundreds of models with one key", place: .online, envKey: "OPENROUTER_API_KEY"),
        .init(id: "together", name: "Together AI", baseURL: "https://api.together.xyz/v1",
              detail: "Open models, hosted", place: .online),
        .init(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1",
              detail: "Very fast open models", place: .online),
        .init(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1",
              detail: "DeepSeek’s own models", place: .online, envKey: "DEEPSEEK_API_KEY"),
        .init(id: "fireworks", name: "Fireworks AI", baseURL: "https://api.fireworks.ai/inference/v1",
              detail: "Open models, hosted", place: .online, envKey: "FIREWORKS_API_KEY"),
        .init(id: "mistral", name: "Mistral", baseURL: "https://api.mistral.ai/v1",
              detail: "Mistral’s own models", place: .online),
        .init(id: "ollama", name: "Ollama", baseURL: "http://127.0.0.1:11434/v1",
              detail: "Models you run with Ollama", place: .local),
        .init(id: "lmstudio", name: "LM Studio", baseURL: "http://127.0.0.1:1234/v1",
              detail: "Models you run with LM Studio", place: .local),
    ]

    static var online: [ProviderPreset] { all.filter { $0.place == .online } }
    static var local: [ProviderPreset] { all.filter { $0.place == .local } }

    /// A new Your Providers entry with the name and address filled in (the key, Test and the model are left to you).
    var draft: CustomProviderDraft {
        var draft = CustomProviderDraft()
        draft.name = name
        draft.baseURL = baseURL
        return draft
    }

    /// The host the address points at, to tell whether one of Your Providers is this service already.
    var host: String? { URL(string: baseURL)?.host(percentEncoded: false)?.lowercased() }
}

/// What picking a choice opens.
nonisolated enum ProviderAddRoute: Sendable, Equatable {
    /// The page of one of Hermes' own keys (`EnvKeyEditor`).
    case key(EnvVarInfo)
    /// A new Your Providers entry (`CustomProviderEditor`).
    case custom(CustomProviderDraft)
}

/// One of the providers Hermes has built in, listed by the chooser: its name (the API Keys card's) and the key its
/// row opens.
nonisolated struct BuiltInProviderChoice: Sendable, Equatable, Identifiable {
    var name: String
    var detail: String?
    var key: EnvVarInfo
    var id: String { name }
}

nonisolated enum ProviderAdding {
    /// The gateway's provider key a preset opens, or an entry with its name and address.
    static func route(_ preset: ProviderPreset, vars: [EnvVarInfo]) -> ProviderAddRoute {
        if let name = preset.envKey, let info = EnvKeys.providerKeys(vars).first(where: { $0.key == name }) {
            return .key(info)
        }
        return .custom(preset.draft)
    }

    /// The key a provider's row opens: the one the gateway marks as its main key, else its API key, else its first
    /// secret that isn't an address. nil: no key to paste (AWS's profile and region).
    static func primaryKey(_ keys: [EnvVarInfo]) -> EnvVarInfo? {
        if let primary = keys.first(where: \.providerPrimary) { return primary }
        let secrets = keys.filter { $0.isPassword && !$0.key.hasSuffix("_URL") }
        return secrets.first { $0.key.hasSuffix("_API_KEY") } ?? secrets.first
    }

    /// Hermes' built-in providers with a key to paste, in the API Keys cards' order, without those a preset already
    /// opens (OpenRouter is listed once, with the presets).
    static func builtIns(_ vars: [EnvVarInfo]) -> [BuiltInProviderChoice] {
        let presetKeys = Set(ProviderPreset.all.compactMap(\.envKey))
        return EnvKeys.groupedProviders(vars).compactMap { group in
            guard !group.keys.contains(where: { presetKeys.contains($0.key) }), let key = primaryKey(group.keys) else { return nil }
            let detail = EnvKeys.providerGroups.first { $0.name == group.name && $0.detail != nil }?.detail
            return BuiltInProviderChoice(name: group.name, detail: detail, key: key)
        }
    }

    /// Is the preset's service added already: its key set, or one of Your Providers at its address?
    static func isAdded(_ preset: ProviderPreset, vars: [EnvVarInfo], custom: [CustomProvider]) -> Bool {
        if case .key(let info) = route(preset, vars: vars) { return info.isSet }
        guard let host = preset.host else { return false }
        return custom.contains { provider in
            guard let url = URL(string: provider.baseURL), url.host(percentEncoded: false)?.lowercased() == host else { return false }
            // A local server is told apart by its port (Ollama 11434, LM Studio 1234 on the same computer).
            return preset.place == .online || url.port == URL(string: preset.baseURL)?.port
        }
    }
}
