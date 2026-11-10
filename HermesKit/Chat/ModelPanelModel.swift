// [model-panel] What the composer's model panel shows (owner 2026-10-31: "shows all the available options for the model
// in terms of like it's available, the context window, effort"): the model with its tag and maker, its facts as a value
// over a caption each, side by side in one strip (the context window, how much of it the chat has used, the price,
// what is left on the plan, else whether it's available), the thinking levels with a line on each, Fast, and what its
// Switch Model menu offers: every favourite, the recents, then the whole catalog by provider (owner 2026-10-31 on three
// tiles: "I fear a limitation by only showing a few"). Built from the ⋯ › Model input plus the cached catalog; the
// panel (App/Chat/Menus/ModelPanel.swift) draws it.

import Foundation

nonisolated struct ModelPanelState: Sendable, Equatable {
    /// One column of the facts strip: `value` in bold over `caption` ("1M" over "Context"). `title` is what VoiceOver
    /// calls it, and `spoken` what it reads when the shown words are cut down ("$5 in · $25 out per 1M").
    struct Fact: Sendable, Equatable {
        var title: String
        var value: String
        var caption: String
        var spoken: String? = nil
        /// The context window's fact, which opens Context Window.
        static let contextTitle = "Context window"
    }

    struct Row: Sendable, Equatable {
        var model: ModelChoice
        var name: String
        var tag: String?
        var provider: String
        var current: Bool
    }

    var name: String
    var tag: String?
    var provider: String
    var facts: [Fact]
    /// The thinking scale's stops ("none" first when it can turn off); empty when the model doesn't think.
    var efforts: [String]
    var effort: String
    var fastSupported: Bool
    var fastOn: Bool
    /// The bot's approval mode ("manual" · "smart" · "off"; "" not known yet) and whether this chat skips approvals.
    var approvalMode: String
    var yolo: Bool
    /// Every favourite (the current model among them, checked), then recents that aren't favourites.
    var favorites: [Row]
    var recents: [Row]
    var offline: Bool
}

/// One provider's models in the Switch Model menu.
nonisolated struct ModelPanelGroup: Sendable, Equatable {
    var title: String
    var rows: [ModelPanelState.Row]
}

nonisolated enum ModelPanelModel {
    /// Recents the menu lists under the favourites (favourites are all listed).
    static let recentsShown = 5

    /// The approval modes in the order the menu lists them, each with its name and what it does
    /// (V:i18n/en.ts approvalMode).
    static let approvalModes: [(mode: String, name: String, line: String)] = [
        ("manual", "Manual", "Ask before actions that require approval"),
        ("smart", "Smart", "Automatically assess actions and ask when needed"),
        ("off", "Off", "Run without approval prompts"),
    ]

    /// What the Approvals row says: the bot's mode by name, nil when not known yet. This chat's skip is its own row.
    static func approvalValue(mode: String) -> String? {
        approvalModes.first { $0.mode == mode }?.name
    }

    /// [model-scope] Owner 2026-11-03: what a pick in the chat's Switch Model menu and Models sheet changes. It is
    /// `config.set model` on this chat's own session, which Hermes keeps to that chat (its config can say to save
    /// switches; this app never asks it to); the bot's default is changed in its Bot Info. `bot`: the chat's bot's name.
    static func switchScope(bot: String?) -> String {
        guard let bot = bot?.trimmingCharacters(in: .whitespacesAndNewlines), !bot.isEmpty else { return "Applies to this chat only." }
        return "Applies to this chat only. Change \(bot)’s default in Bot Info › Brain."
    }

    /// [model-scope] The Switch Model menu's title: the scope line, and none at the accessibility text sizes, where the
    /// menu scrolls and the line filled it ahead of every pick (AX3 run 2026-11-04). The Models sheet behind Search All
    /// Models still says it there.
    static func switchMenuTitle(bot: String?, largeText: Bool) -> String {
        largeText ? "" : switchScope(bot: bot)
    }

    /// [menu-stars] Tester 2026-11-06 (a tester: "have the starred models in that dropdown rather than having to find them
    /// or going through the providers"): Switch Model's Favorites ends in a row that stars or unstars the chat's model,
    /// so a model is starred where it is picked. With nothing starred yet it is the section's only row, and says where
    /// every other model is starred.
    static func starRow(name: String, favorite: Bool, noFavorites: Bool) -> (title: String, subtitle: String?, image: String) {
        favorite ? ("Remove \(name) from Favorites", nil, "star.slash")
            : ("Add \(name) to Favorites", noFavorites ? "Or star any model in Search All Models" : nil, "star")
    }

    /// What a thinking level means, under the ring.
    static func effortLine(_ level: String) -> String {
        switch level {
        case "none": "Answers straight away"
        case "minimal": "A moment's thought"
        case "low": "Thinks briefly"
        case "medium": "Thinks it through"
        case "high": "Thinks hard"
        case "xhigh": "Thinks very hard"
        case "max": "As hard as it can"
        case "ultra": "Goes all out"
        default: "Thinks at \(ModelNames.effortLabel(level))"
        }
    }

    /// - Parameters:
    ///   - contextMax: this chat's own window as the gateway last reported it.
    ///   - contextUsed: how much of it the chat has used.
    ///   - listedContext: models.dev's window for the model.
    ///   - price: "Included", "Free" or "$5 in · $25 out".
    ///   - limit: "Weekly · 60% left".
    static func build(_ input: ModelMenuInput, contextMax: Int? = nil, contextUsed: Int? = nil, listedContext: Int? = nil,
                      price: String? = nil, limit: String? = nil) -> ModelPanelState {
        let current = input.current
        let parts = ModelNames.modelDisplayParts(current.id.isEmpty ? current.name : current.id)
        let tags = parts.tag.split(separator: " ").map(String.init)
        // The id's own window tag ("[1m]") becomes the Context fact rather than a second pill.
        let windowTag = tags.last { $0.range(of: #"^\d+(\.\d+)?[KM]$"#, options: .regularExpression) != nil }
        let tag = tags.filter { $0 != windowTag }.joined(separator: " ")

        var facts: [ModelPanelState.Fact] = []
        let window = contextMax.flatMap { $0 > 0 ? SessionInfoRows.count($0) : nil } ?? windowTag
            ?? listedContext.flatMap { $0 > 0 ? SessionInfoRows.count($0) : nil }
        if let window { facts.append(ModelPanelState.Fact(title: ModelPanelState.Fact.contextTitle, value: window, caption: "Context")) }
        if let max = contextMax, max > 0, let used = contextUsed, used > 0 {
            let share = Int((Double(min(max, used)) / Double(max) * 100).rounded())
            facts.append(ModelPanelState.Fact(title: "Context used", value: "\(share)%", caption: "Used"))
        }
        if let price, !price.isEmpty { facts.append(priceFact(price)) }
        if let limit, !limit.isEmpty {
            facts.append(planFact(limit))
        } else {
            facts.append(ModelPanelState.Fact(title: "Status", value: input.offline ? "Offline" : "Available", caption: "Status"))
        }

        var efforts: [String] = []
        if !input.reasoningLevels.isEmpty {
            if input.canTurnOff { efforts.append("none") }
            for level in input.reasoningLevels where level != "none" && !efforts.contains(level) { efforts.append(level) }
        }

        var seen: Set<String> = []
        func rows(_ models: [ModelChoice], _ most: Int) -> [ModelPanelState.Row] {
            var out: [ModelPanelState.Row] = []
            for model in models where out.count < most && !seen.contains(model.key) {
                seen.insert(model.key)
                out.append(row(model, current: current))
            }
            return out
        }
        let favorites = rows(input.favorites, .max)
        let recents = rows(input.recents.filter { !($0.id == current.id && $0.provider == current.provider) }, recentsShown)

        return ModelPanelState(name: parts.name, tag: tag.isEmpty ? nil : tag,
                               provider: ModelNames.readableProviderName(slug: current.provider, catalogName: current.providerName), facts: facts,
                               efforts: efforts, effort: efforts.contains(input.reasoningCurrent) ? input.reasoningCurrent
                                   : (efforts.contains(ModelNames.defaultReasoningEffort) ? ModelNames.defaultReasoningEffort : efforts.first ?? ""),
                               fastSupported: input.fastSupported, fastOn: input.fastOn,
                               approvalMode: input.approvalMode, yolo: input.yolo,
                               favorites: favorites, recents: recents, offline: input.offline)
    }
}

nonisolated extension ModelPanelModel {
    /// A model as the panel lists it: its name and tag, its provider by name, checked when it is the chat's.
    static func row(_ model: ModelChoice, current: ModelChoice) -> ModelPanelState.Row {
        let parts = ModelNames.modelDisplayParts(model.id.isEmpty ? model.name : model.id)
        return ModelPanelState.Row(model: model, name: parts.name, tag: parts.tag.isEmpty ? nil : parts.tag,
                                   provider: ModelNames.readableProviderName(slug: model.provider, catalogName: model.providerName),
                                   current: model.id == current.id && model.provider == current.provider)
    }

    /// The whole catalog for the menu: one group per provider in the catalog's order, as the Models sheet has it.
    static func groups(_ catalog: [ModelChoice], current: ModelChoice) -> [ModelPanelGroup] {
        ModelSheetModel.sections(catalog, query: "", current: (current.id, current.provider)).compactMap { section in
            section.models.isEmpty ? nil : ModelPanelGroup(
                title: ModelNames.readableProviderName(slug: section.provider, catalogName: section.title),
                rows: section.models.map { row($0, current: current) })
        }
    }

    /// "$5 in · $25 out" reads "$5 · $25" over "In · out per 1M"; "Included" and "Free" over "Price".
    static func priceFact(_ price: String) -> ModelPanelState.Fact {
        let parts = price.components(separatedBy: " · ")
        let ins = parts.first { $0.hasSuffix(" in") }.map { String($0.dropLast(3)) }
        let outs = parts.first { $0.hasSuffix(" out") }.map { String($0.dropLast(4)) }
        guard ins != nil || outs != nil else { return ModelPanelState.Fact(title: "Price", value: price, caption: "Price") }
        let caption = ins != nil && outs != nil ? "In · out per 1M" : ins != nil ? "In per 1M" : "Out per 1M"
        return ModelPanelState.Fact(title: "Price", value: [ins, outs].compactMap { $0 }.joined(separator: " · "),
                                    caption: caption, spoken: price + " per 1M")
    }

    /// "Weekly · 62% left" reads "62% left" over "Weekly"; "Rate limited · back in 2 h" reads "Rate limited" over
    /// "Back in 2 h"; anything else whole over "Plan".
    static func planFact(_ limit: String) -> ModelPanelState.Fact {
        let parts = limit.components(separatedBy: " · ")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return ModelPanelState.Fact(title: "Plan", value: limit, caption: "Plan")
        }
        if parts[1].hasSuffix(" left") { return ModelPanelState.Fact(title: "Plan", value: parts[1], caption: parts[0], spoken: limit) }
        let caption = parts[1].prefix(1).uppercased() + parts[1].dropFirst()
        return ModelPanelState.Fact(title: "Plan", value: parts[0], caption: caption, spoken: limit)
    }
}

#if DEBUG
extension ModelPanelModel {
    /// Screenshots (`-HQDebugModelPanelSample YES`): a full panel the stand-in gateway can't give.
    static var debugSample: ModelPanelState {
        func choice(_ id: String, _ name: String, _ provider: String, _ providerName: String) -> ModelChoice {
            ModelChoice(id: id, name: name, provider: provider, providerName: providerName)
        }
        let opus = choice("claude-opus-5-5[1m]", "Opus 5.5", "anthropic", "Anthropic")
        let input = ModelMenuInput(current: opus, recents: [choice("gemini-3-pro", "Gemini 3 Pro", "gemini", "Google")],
                                   favorites: [opus, choice("gpt-5.5", "GPT-5.5", "openai-codex", "OpenAI Codex"),
                                               choice("grok-5", "Grok 5", "xai", "xAI"),
                                               choice("claude-sonnet-5", "Sonnet 5", "anthropic", "Anthropic")],
                                   reasoningLevels: ModelNames.reasoningEfforts, reasoningCurrent: "high", canTurnOff: true,
                                   fastSupported: true, fastOn: false, offline: false, approvalMode: "smart")
        return build(input, contextMax: 1_000_000, contextUsed: 184_000, price: "Included", limit: "Weekly · 62% left")
    }

    /// Screenshots of the Switch Model menu: a catalog of several providers, the sample's models among them.
    static var debugCatalog: [ModelChoice] {
        func choice(_ id: String, _ provider: String, _ providerName: String) -> ModelChoice {
            ModelChoice(id: id, name: ModelNames.displayModelName(id), provider: provider, providerName: providerName)
        }
        return [choice("claude-opus-5-5[1m]", "anthropic", "Anthropic"), choice("claude-sonnet-5", "anthropic", "Anthropic"),
                choice("claude-haiku-4-5", "anthropic", "Anthropic"),
                choice("gpt-5.5", "openai-codex", "OpenAI Codex"), choice("gpt-5.5-mini", "openai-codex", "OpenAI Codex"),
                choice("grok-5", "xai", "xAI"), choice("grok-5-fast", "xai", "xAI"),
                choice("gemini-3-pro", "gemini", "Google"), choice("gemini-3-flash", "gemini", "Google"),
                choice("deepseek/deepseek-chat", "openrouter", "OpenRouter"), choice("qwen/qwen3-coder", "openrouter", "OpenRouter"),
                choice("meta-llama/llama-3.3-70b-instruct:free", "openrouter", "OpenRouter"),
                choice("Hermes-4-405B", "nous", "Nous Portal"), choice("llama3.1:8b", "ollama", "Ollama")]
    }

    /// Screenshots of the hard cases (`-HQDebugModelPanelCase long|bare|onestop|offline|tag|yolo`): any model, any provider.
    static func debugCase(_ name: String) -> ModelPanelState? {
        func choice(_ id: String, _ provider: String, _ providerName: String? = nil) -> ModelChoice {
            ModelChoice(id: id, name: ModelNames.displayModelName(id), provider: provider, providerName: providerName)
        }
        func input(_ current: ModelChoice, favorites: [ModelChoice] = [], recents: [ModelChoice] = [], levels: [String] = ModelNames.reasoningEfforts,
                   effort: String = "high", canTurnOff: Bool = true, fast: Bool = false, offline: Bool = false) -> ModelMenuInput {
            ModelMenuInput(current: current, recents: recents, favorites: favorites, reasoningLevels: levels, reasoningCurrent: effort,
                           canTurnOff: canTurnOff, fastSupported: fast, fastOn: false, offline: offline, approvalMode: "manual")
        }
        switch name {
        case "long":
            let current = choice("meta-llama/Llama-3.1-405B-Instruct-Turbo:free", "claude-code",
                                 "Anthropic OAuth: Required Extra Usage Credits to Use Subscription")
            return build(input(current, favorites: [
                choice("us.anthropic.claude-3-7-sonnet-20250219-v1:0", "bedrock"),
                choice("unsloth/Qwen3-30B-A3B-GGUF:Q4_K_M", "custom", "Custom OpenAI-compatible endpoint (http://192.168.1.20:8080/v1)"),
                choice("ft:gpt-4o-mini-2024-07-18:acme::9abcDEF", "openai-codex", "ChatGPT or Codex Subscription"),
            ], levels: ["low", "high", "extra_deep_reasoning_budget"], effort: "extra_deep_reasoning_budget", fast: true), contextMax: 131_072, contextUsed: 9_000,
                         price: "$0.15 in · $0.60 out", limit: "Rate limited · back in 2h")
        case "bare":
            return build(input(choice("my_lab_model_v2_final_really_final", "my-lab-box"), levels: []))
        case "onestop":
            return build(input(choice("o3-mini", "openai-api", "OpenAI API"), favorites: [choice("gpt-5.5", "openai-codex", "ChatGPT or Codex Subscription")],
                               levels: ["high"], canTurnOff: false), listedContext: 200_000, price: "$1.10 in · $4.40 out")
        case "offline":
            var state = debugSample
            state.offline = true
            return state
        case "yolo":
            var state = debugSample
            state.fastOn = true
            state.yolo = true
            return state
        case "tag":
            return build(input(choice("google/gemini-3-pro-preview", "gemini", "Google AI Studio"),
                               favorites: [choice("x-ai/grok-4-fast", "openrouter", "OpenRouter"), choice("llama3.1:8b", "ollama")],
                               fast: true), listedContext: 1_048_576, price: "$2 in · $12 out", limit: "5-hour · 40% left")
        default:
            return nil
        }
    }
}
#endif
