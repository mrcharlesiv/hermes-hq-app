// Unit checks for the menus stream (spec docs/spec/1x-menus.md §14.1, checks 1–5, 7, 8, 10, 11). No network.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

// MARK: 1 · Model names

@Suite("Menus · model names (spec 1x §2.2)")
struct MenusModelNameTests {
    @Test(arguments: [
        ("claude-opus-4-5-20251101", "Opus 4.5", "Opus 4.5"),
        ("claude-sonnet-5[1m]", "Sonnet 5 1M", "Sonnet 5"),
        ("gpt-5.5-fast", "GPT-5.5 Fast", "GPT-5.5 · Fast"),
        ("gemini-2.5-pro", "Gemini 2.5 Pro", "Gemini 2.5 Pro"),
        ("glm-5.2", "GLM 5.2", "GLM 5.2"),
        ("deepseek-v4.1-flash", "DeepSeek V4.1 Flash", "DeepSeek V4.1 · Flash"),
        ("anthropic/claude-opus-4.5", "Opus 4.5", "Opus 4.5"),
        ("qwen2.5-coder:14b", "Qwen2.5 Coder:14B", "Qwen2.5 Coder:14B"),
        ("Qwen3-30B-A3B-Instruct-2507-UD-Q4_K_XL", "Qwen3 30B A3B Q4", "Qwen3 30B A3B"),
        ("moonshotai/kimi-k2-thinking", "Kimi K2 Thinking", "Kimi K2 · Thinking"),
        ("hermes-4", "Hermes 4", "Hermes 4"),
        ("", "No model", "No model"),
    ])
    func vectors(id: String, display: String, pill: String) {
        #expect(ModelNames.displayModelName(id) == display)
        #expect(ModelNames.formatModelPillLabel(id) == pill)
    }

    @Test func providerNames() {
        #expect(ModelNames.plainProviderName("Claude Subscription DirectSDK (Experimental)") == "Claude Subscription")
        #expect(ModelNames.plainProviderName("Custom [local]") == "Custom")
        #expect(ModelNames.plainProviderName("(x)") == "(x)")
        #expect(ModelNames.providerDisplayName("openai-codex") == "ChatGPT or Codex Subscription")
        #expect(ModelNames.providerDisplayName("openrouter") == "openrouter")
        #expect(ModelNames.effortLabel("extra_deep") == "Extra Deep")
        #expect(ModelNames.effortLabel("very_high") == "Very High")
        #expect(ModelNames.effortLabel("xhigh") == "Extra High")
        #expect(ModelNames.effortLabel("none") == "Off")
    }

    @Test func currentPick() {
        #expect(ModelNames.currentPickerSelection(store: ("a", "p"), options: ("b", "q")) == ("a", "p"))
        #expect(ModelNames.currentPickerSelection(store: ("a", ""), options: ("b", "q")) == ("b", "q"))
        #expect(ModelNames.currentPickerSelection(store: ("a", ""), options: ("", "q")) == ("a", "q"))
    }
}

// MARK: 2 · Quick list (port of S:ui-chat/title-menu.test.ts:34-90)

@Suite("Menus · Model submenu (spec 1x §4.6)")
struct MenusQuickListTests {
    static let current = ModelChoice(id: "sonnet", name: "Sonnet", provider: "anthropic", providerName: "Anthropic")
    static let recent = [
        ModelChoice(id: "opus", name: "Opus", provider: "anthropic", providerName: "Anthropic"),
        ModelChoice(id: "gpt", name: "GPT", provider: "openai", providerName: "OpenAI"),
        ModelChoice(id: "gemini", name: "Gemini", provider: "google", providerName: "Google"),
    ]

    static func input(_ patch: (inout ModelMenuInput) -> Void = { _ in }) -> ModelMenuInput {
        var i = ModelMenuInput(current: current, recents: recent, favorites: [], reasoningLevels: ["low", "medium", "high", "xhigh", "max"],
                               reasoningCurrent: "medium", canTurnOff: true, fastSupported: true, fastOn: true, offline: false)
        patch(&i)
        return i
    }

    private func ids(_ items: [ModelMenuItem]) -> [String] {
        items.map { item in
            switch item.action {
            case .model(let m): return "model:\(m.id)"
            case .moreModels: return "more-models"
            case .reasoning(let l): return "reasoning:\(l)"
            case .fast: return "fast"
            }
        }
    }

    @Test func order() {
        let node = ModelMenuModel.build(Self.input())
        #expect(ids(node.quick) == ["model:sonnet", "model:opus", "model:gpt", "more-models"])
        #expect(node.quickTitle == "Model for Next Reply")
        #expect(node.quick[0].on)
        #expect(node.reasoning != nil)
        #expect(node.fast?.on == true)
        #expect(node.subtitle == "Sonnet · Medium")
    }

    @Test func recentsCappedDedupedSubtitles() {
        let node = ModelMenuModel.build(Self.input { $0.recents = [Self.current, Self.recent[0], Self.recent[0], Self.recent[1], Self.recent[2]] })
        #expect(ids(node.quick) == ["model:sonnet", "model:opus", "model:gpt", "more-models"])
        #expect(node.quick[0].subtitle == nil)
        #expect(node.quick[1].subtitle == nil)
        #expect(node.quick[2].subtitle == "OpenAI")
    }

    @Test func favouritesLeadAtMostFive() {
        let favs = (1...7).map { ModelChoice(id: "f\($0)", name: "F\($0)", provider: "anthropic", providerName: "Anthropic") }
        let node = ModelMenuModel.build(Self.input { $0.favorites = [Self.current] + favs })
        #expect(ids(node.quick) == ["model:sonnet", "model:f1", "model:f2", "model:f3", "model:f4", "model:f5", "model:opus", "model:gpt", "more-models"])
    }

    @Test func reasoningOffFirst() {
        let node = ModelMenuModel.build(Self.input {
            $0.reasoningLevels = ModelNames.reasoningEfforts
            $0.reasoningCurrent = "none"
        })
        let reasoning = try! #require(node.reasoning)
        #expect(reasoning.subtitle == "Off")
        #expect(ids(reasoning.items) == ["reasoning:none", "reasoning:minimal", "reasoning:low", "reasoning:medium", "reasoning:high",
                                         "reasoning:xhigh", "reasoning:max", "reasoning:ultra"])
        #expect(reasoning.items.map(\.title) == ["Off", "Minimal", "Low", "Medium", "High", "Extra High", "Max", "Ultra"])
        #expect(reasoning.items.filter(\.on).count == 1 && reasoning.items[0].on)
    }

    @Test func mandatoryThinkingAndNoReasoning() {
        let node = ModelMenuModel.build(Self.input {
            $0.reasoningLevels = ["low", "none", "high"]
            $0.reasoningCurrent = "high"
            $0.canTurnOff = false
        })
        #expect(ids(node.reasoning!.items) == ["reasoning:low", "reasoning:high"])
        #expect(ModelMenuModel.build(Self.input { $0.reasoningLevels = [] }).reasoning == nil)
        #expect(ModelMenuModel.build(Self.input { $0.reasoningLevels = [] }).subtitle == "Sonnet")
    }

    @Test func fastOnlyWhenSupported() {
        #expect(ModelMenuModel.build(Self.input()).fast?.on == true)
        #expect(ModelMenuModel.build(Self.input { $0.fastOn = false }).fast?.on == false)
        #expect(ModelMenuModel.build(Self.input { $0.fastSupported = false }).fast == nil)
    }

    @Test func offlineDisablesEveryRow() {
        let node = ModelMenuModel.build(Self.input { $0.offline = true })
        #expect(node.subtitle == "Offline")
        #expect(node.reasoning?.subtitle == "Offline")
        for item in node.quick + (node.reasoning?.items ?? []) + [node.fast!] {
            #expect(item.disabled && item.subtitle == "Offline")
        }
    }
}

// MARK: 3–5 · Favourites from keys, stores, sections

@MainActor @Suite("Menus · favourites, recents, presets, sections (spec 1x §2.3, §6)")
struct MenusStoreTests {
    private func freshDefaults() -> UserDefaults {
        let name = "menus-tests-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @Test func favouritesBeforeCatalog() {
        let rows = ModelSheetModel.favoritesFromKeys(["openrouter::moonshotai/kimi-k2-thinking"])
        #expect(rows.count == 1)
        #expect(rows[0].name == "Kimi K2 Thinking")
        #expect(rows[0].providerName == "openrouter")
        // Recents show only once a catalog holds them.
        let input = ModelMenuInput(current: ModelChoice(id: "x", name: "X", provider: "anthropic"), recents: [], favorites: rows,
                                   reasoningLevels: [], reasoningCurrent: "medium", canTurnOff: true, fastSupported: false,
                                   fastOn: false, offline: false)
        let node = ModelMenuModel.build(input)
        #expect(node.quick[1].title == "Kimi K2 Thinking")
        #expect(node.quick[1].subtitle == "openrouter")
    }

    @Test func favouritesToggleInOrder() {
        let prefs = ModelPrefs(accountId: "a", defaults: freshDefaults())
        prefs.toggleFavorite(provider: "anthropic", model: "opus")
        prefs.toggleFavorite(provider: "openai-codex", model: "gpt-5.5")
        prefs.toggleFavorite(provider: "anthropic", model: "haiku")
        #expect(prefs.favorites == ["anthropic::opus", "openai-codex::gpt-5.5", "anthropic::haiku"])
        prefs.toggleFavorite(provider: "openai-codex", model: "gpt-5.5")
        #expect(prefs.favorites == ["anthropic::opus", "anthropic::haiku"])
        prefs.setFavorites([])
        #expect(prefs.favorites.isEmpty)
    }

    @Test func recentsNewestFirstMaxThree() {
        let prefs = ModelPrefs(accountId: "a", defaults: freshDefaults())
        let a = ModelChoice(id: "a", name: "A", provider: "p"), b = ModelChoice(id: "b", name: "B", provider: "p")
        let c = ModelChoice(id: "c", name: "C", provider: "p"), d = ModelChoice(id: "d", name: "D", provider: "p", providerName: "P")
        for m in [a, b, c, d] { prefs.remember(m) }
        #expect(prefs.recents.map(\.id) == ["d", "c", "b"])
        prefs.remember(b)
        #expect(prefs.recents.map(\.id) == ["b", "d", "c"])
        prefs.remember(ModelChoice(id: "b", name: "B", provider: "q"))
        #expect(prefs.recents.map { "\($0.provider)/\($0.id)" } == ["q/b", "p/b", "p/d"])
    }

    @Test func perAccountIsolation() {
        let defaults = freshDefaults()
        let one = ModelPrefs(accountId: "http://a|x", defaults: defaults)
        let two = ModelPrefs(accountId: "http://b|y", defaults: defaults)
        one.toggleFavorite(provider: "anthropic", model: "opus")
        one.remember(ModelChoice(id: "a", name: "A", provider: "p"))
        one.setPreset(provider: "anthropic", model: "opus", ModelPreset(effort: "high"))
        #expect(two.favorites.isEmpty && two.recents.isEmpty && two.preset(provider: "anthropic", model: "opus") == ModelPreset())
        #expect(one.favorites == ["anthropic::opus"])
        ModelPrefs.forget(accountId: "http://a|x", defaults: defaults)
        #expect(one.favorites.isEmpty && one.recents.isEmpty)
    }

    /// [model-fold] Folded providers are kept per account and forgotten with its other stores.
    @Test func foldedProvidersPerAccount() {
        let defaults = freshDefaults()
        let one = ModelPrefs(accountId: "http://a|x", defaults: defaults)
        let two = ModelPrefs(accountId: "http://b|y", defaults: defaults)
        #expect(one.foldedProviders.isEmpty)
        one.setFoldedProviders(["nous", "openrouter"])
        #expect(one.foldedProviders == ["nous", "openrouter"])
        #expect(two.foldedProviders.isEmpty)
        one.setFoldedProviders(["nous"])
        #expect(one.foldedProviders == ["nous"])
        ModelPrefs.forget(accountId: "http://a|x", defaults: defaults)
        #expect(one.foldedProviders.isEmpty)
    }

    /// [stale-stars] Tester 2026-11-09: a removed provider's stars stayed in a new chat's Switch Model until
    /// its catalog loaded, and could only be cleared all at once.
    @Test func staleStarsStayOutBeforeTheCatalogLoads() {
        let keys = ["commandcode::deepseek-v4.1-flash", "nous::gpt-6.1-sol", "clinepass::glm-5.3"]
        // No catalog and none read before: every star, as before.
        #expect(ModelMenuContext.favorites(keys: keys, catalog: nil, knownProviders: nil).map(\.provider)
                == ["commandcode", "nous", "clinepass"])
        // The bot's last catalog listed only Nous.
        #expect(ModelMenuContext.favorites(keys: keys, catalog: nil, knownProviders: ["nous"]).map(\.key) == ["nous::gpt-6.1-sol"])
        // A catalog (this chat's or another chat's of the bot) wins.
        let catalog = [ModelChoice(id: "gpt-6.1-sol", name: "GPT-6.1-sol", provider: "nous", providerName: "Nous Portal")]
        #expect(ModelMenuContext.favorites(keys: keys, catalog: catalog, knownProviders: nil) == catalog)
    }

    /// [ghost-stars] Tester 2026-11-10: "the ghost favorites are still there". A kept provider's dropped model
    /// stayed (only providers were remembered), and a catalog read before a provider was removed still listed its stars.
    @Test func ghostStarsStayOut() {
        let keys = ["commandcode::deepseek-v4.1-flash", "clinepass::deepseek-v4-pro", "clinepass::glm-5.3"]
        // Clinepass is still there, but the last catalog didn't list its DeepSeek V4 Pro.
        #expect(ModelMenuContext.favorites(keys: keys, catalog: nil, knownProviders: ["clinepass"], missing: ["clinepass::deepseek-v4-pro"])
                    .map(\.key) == ["clinepass::glm-5.3"])
        #expect(ModelMenuContext.favorites(keys: keys, catalog: nil, knownProviders: nil, missing: [keys[0]]).map(\.key) == Array(keys[1...]))
        // An older catalog still lists Commandcode, removed in Settings since.
        let catalog = ModelSheetModel.favoritesFromKeys(keys)
        #expect(ModelMenuContext.favorites(keys: keys, catalog: catalog, knownProviders: ["clinepass"]).map(\.provider)
                == ["clinepass", "clinepass"])
    }

    @Test func missingStarsAndRemovedProviders() {
        let defaults = freshDefaults()
        let prefs = ModelPrefs(accountId: "http://a|x", defaults: defaults)
        #expect(prefs.missingStars(profile: "").isEmpty)
        prefs.setMissingStars(["a::m", "b::n"], profile: "")
        prefs.setMissingStars(["c::o"], profile: "coder")
        #expect(prefs.missingStars(profile: "") == ["a::m", "b::n"])
        prefs.setMissingStars([], profile: "")
        #expect(prefs.missingStars(profile: "").isEmpty && prefs.missingStars(profile: "coder") == ["c::o"])
        prefs.clearFavoritesAndRecents()
        #expect(prefs.missingStars(profile: "coder").isEmpty)

        prefs.removeKnownProvider("nous")   // nothing read yet: nothing to do
        #expect(prefs.knownProviders(profile: "") == nil)
        prefs.setKnownProviders(["nous", "clinepass"], profile: "")
        prefs.setKnownProviders(["clinepass"], profile: "coder")
        prefs.removeKnownProvider("clinepass")
        #expect(prefs.knownProviders(profile: "") == ["nous"])
        #expect(prefs.knownProviders(profile: "coder") == [])
    }

    @Test func knownProvidersPerProfileAndClear() {
        let defaults = freshDefaults()
        let prefs = ModelPrefs(accountId: "http://a|x", defaults: defaults)
        #expect(prefs.knownProviders(profile: "") == nil)
        prefs.setKnownProviders(["nous", "xai-oauth"], profile: "")
        prefs.setKnownProviders([], profile: "coder")
        #expect(prefs.knownProviders(profile: "") == ["nous", "xai-oauth"])
        #expect(prefs.knownProviders(profile: "coder") == [])
        prefs.toggleFavorite(provider: "nous", model: "m")
        prefs.remember(ModelChoice(id: "m", name: "M", provider: "nous"))
        prefs.clearFavoritesAndRecents()
        #expect(prefs.favorites.isEmpty && prefs.recents.isEmpty)
        #expect(prefs.knownProviders(profile: "") == ["nous", "xai-oauth"])
        ModelPrefs.forget(accountId: "http://a|x", defaults: defaults)
        #expect(prefs.knownProviders(profile: "") == nil)
    }

    @MainActor @Test func siblingCatalogIsTheBotsNewest() {
        let cache = ModelCatalogCache()
        let row = { (slug: String) in ModelOptions(providers: [ModelProviderRow(slug: slug, name: slug, models: ["m"], aliases: [], capabilities: [:])]) }
        cache.store(row("old"), for: .init(account: "a", profile: "", scope: "s1"))
        cache.store(row("new"), for: .init(account: "a", profile: "", scope: "s2"))
        cache.store(row("other-bot"), for: .init(account: "a", profile: "coder", scope: "s3"))
        #expect(cache.sibling(.init(account: "a", profile: "", scope: "fresh"))?.providers.map(\.slug) == ["new"])
        #expect(cache.sibling(.init(account: "b", profile: "", scope: "fresh")) == nil)
    }

    @Test func clearModelsWords() {
        #expect(SettingsWords.clearModelsMessage(favorites: 3, recents: 1)
                == "Unstars 3 models and forgets 1 recent model. Bots, chats and each bot’s default model stay.")
        #expect(SettingsWords.clearModelsMessage(favorites: 0, recents: 0).hasPrefix("No models are starred"))
    }

    @Test func presetsMergePatch() {
        let prefs = ModelPrefs(accountId: "a", defaults: freshDefaults())
        prefs.setPreset(provider: "p", model: "m", ModelPreset(effort: "low"))
        prefs.setPreset(provider: "p", model: "m", ModelPreset(fast: true))
        #expect(prefs.preset(provider: "p", model: "m") == ModelPreset(effort: "low", fast: true))
    }

    static func catalog() -> ModelOptions {
        ModelOptions(providers: [
            ModelProviderRow(slug: "anthropic", name: "Anthropic", models: ["claude-sonnet-5", "claude-opus-4-5-20251101"], aliases: [], capabilities: [:]),
            ModelProviderRow(slug: "openai-codex", name: "ChatGPT or Codex Subscription (Experimental)",
                             models: ["gpt-5.5", "gpt-5.5-mini", "openai/gpt-5.5-mini"], aliases: ["codex"], capabilities: [:]),
            ModelProviderRow(slug: "openrouter", name: "OpenRouter", models: ["moonshotai/kimi-k2-thinking", "qwen/qwen2.5-coder:14b"],
                             aliases: [], capabilities: [:]),
        ])
    }

    @Test func sectionsTwinsAndSearch() {
        let models = Self.catalog().choices
        let sections = ModelSheetModel.sections(models, query: "", current: ("claude-sonnet-5", "anthropic"))
        #expect(sections.map(\.title) == ["Anthropic", "ChatGPT or Codex Subscription", "OpenRouter"])
        #expect(sections[1].models.map(\.id) == ["gpt-5.5", "gpt-5.5-mini"])
        let current = ModelSheetModel.sections(models, query: "", current: ("openai/gpt-5.5-mini", "openai-codex"))
        #expect(current[1].models.map(\.id) == ["gpt-5.5", "openai/gpt-5.5-mini"])
        let kimi = ModelSheetModel.sections(models, query: "kimi think", current: nil)
        #expect(kimi.count == 1 && kimi[0].models.map(\.id) == ["moonshotai/kimi-k2-thinking"])
        #expect(ModelSheetModel.sections(models, query: "zzz", current: nil).isEmpty)
        // The alias matches the provider.
        #expect(Self.catalog().row(matching: "codex")?.slug == "openai-codex")
    }

    @Test func favouriteRowsInStarredOrderMissingDropped() {
        let models = Self.catalog().choices
        let rows = ModelSheetModel.favoriteRows(models, keys: ["openrouter::moonshotai/kimi-k2-thinking", "x::gone", "anthropic::claude-sonnet-5"])
        #expect(rows.map(\.id) == ["moonshotai/kimi-k2-thinking", "claude-sonnet-5"])
    }
}

// MARK: 7 · Commands

@Suite("Menus · commands sheet (spec 1x §7, §12.5)")
struct MenusCommandsTests {
    /// The menus fixture's catalog (spec 1x §12.5), as Hermes builds it.
    static func fixtureCatalog() -> CommandsCatalog {
        func usage(_ desc: String, _ name: String, _ hint: String?) -> String { hint.map { "\(desc) (usage: /\(name) \($0))" } ?? desc }
        let session: [(String, String)] = [
            ("/new", usage("Start a new session", "new", "[name]")), ("/retry", "Retry the last message (resend to agent)"),
            ("/title", usage("Set a title for the current session", "title", "[name]")),
            ("/compress", usage("Manually compress conversation context", "compress", "[focus topic]")),
            ("/stop", "Kill all running background processes"), ("/status", "Show session info"),
            ("/plan", usage("Write an implementation plan", "plan", "[request]")),
            ("/goal", usage("Set a standing goal", "goal", "[text | pause | resume | clear | status]")),
            ("/undo", usage("Back up N user turns", "undo", "[N]")),
            ("/queue", usage("Queue a prompt for the next turn", "queue", "<prompt>")),
            ("/agents", "Show active agents and running tasks"),
            ("/resume", usage("Resume a previously-named session", "resume", "[name]")),
        ]
        let config: [(String, String)] = [
            ("/model", usage("Switch model for this session", "model", "[model] [--global]")),
            ("/reasoning", usage("Manage reasoning effort and display", "reasoning", "[level|show|hide]")),
            ("/yolo", "Toggle YOLO mode (skip all dangerous command approvals)"),
            ("/personality", usage("Set a predefined personality", "personality", "[name]")),
            ("/fast", usage("Toggle fast mode", "fast", "[normal|fast|status]")),
            ("/voice", usage("Toggle voice mode", "voice", "[on|off|tts|status]")),
            ("/config", "Show current configuration"),
        ]
        let info: [(String, String)] = [
            ("/usage", usage("Show token usage and rate limits", "usage", "[reset [--force]]")),
            ("/help", usage("Show available commands", "help", "[command]")), ("/version", "Show Hermes Agent version"),
            ("/whoami", "Show your slash command access"), ("/debug", usage("Upload debug report", "debug", "[note]")),
        ]
        let tools: [(String, String)] = [
            ("/tools", usage("Manage tools", "tools", "[list|disable|enable] [name...]")), ("/bundles", "List skill bundles"),
        ]
        let skills: [(String, String)] = [
            ("/release-notes", "Draft release notes from the changelog"), ("/gif-search", "Find a GIF for anything"),
            ("/changelog", "Summarise recent commits"),
        ]
        var commands: [String: CommandCatalogMeta] = [:]
        let modes: [String: (String?, String?)] = [
            "/new": ("text", nil), "/retry": (nil, nil), "/title": ("text", nil), "/compress": ("text", nil), "/stop": (nil, nil),
            "/status": (nil, nil), "/plan": ("text", nil), "/goal": ("mixed", nil), "/undo": ("text", nil), "/queue": ("mixed", nil),
            "/agents": (nil, nil), "/resume": ("mixed", nil), "/model": (nil, "hidden"), "/reasoning": ("options", nil),
            "/yolo": (nil, nil), "/personality": ("options", nil), "/fast": ("options", "advanced"), "/voice": ("options", "composer-voice"),
            "/config": (nil, "terminal"), "/usage": ("text", nil), "/help": ("text", nil), "/version": (nil, nil), "/whoami": (nil, nil),
            "/debug": ("text", nil), "/tools": ("options", nil), "/bundles": (nil, nil), "/reset": ("text", nil), "/q": ("mixed", nil),
        ]
        for (name, m) in modes { commands[name] = CommandCatalogMeta(argumentMode: m.0, desktop: m.1) }
        var canon: [String: String] = [:]
        for name in modes.keys { canon[name] = name }
        canon["/reset"] = "/new"
        canon["/q"] = "/queue"
        return CommandsCatalog(categories: [("Session", session), ("Configuration", config), ("Info", info), ("Tools & Skills", tools)],
                               pairs: session + config + info + tools + skills, commands: commands, canon: canon,
                               skills: ["/release-notes": SkillCatalogEntry(usage: 5, origin: "local"),
                                        "/gif-search": SkillCatalogEntry(usage: 2, origin: "hub"),
                                        "/changelog": SkillCatalogEntry(usage: 0, origin: "bundled")])
    }

    @Test func expectedSheet() {
        let catalog = Self.fixtureCatalog()
        let sections = SlashCatalog.sections(catalog)
        #expect(sections.map(\.title) == ["Session", "Configuration", "Info", "Tools & Skills", "Skills"])
        func rows(_ i: Int) -> [String] {
            sections[i].rows.map { "\($0.command) \(SlashCatalog.pickAction($0, catalog: catalog) == .send ? "S" : "I")" }
        }
        #expect(rows(0) == ["/new I", "/retry S", "/title I", "/compress I", "/stop S", "/status S", "/plan I", "/goal I", "/undo I", "/queue I",
                            "/agents S"])
        #expect(rows(1) == ["/reasoning I", "/yolo S", "/personality I"])
        // /help only reopens this sheet: not listed (typed, it still opens it).
        #expect(rows(2) == ["/usage I", "/version S", "/whoami S"])
        #expect(rows(3) == ["/tools I", "/bundles S"])
        #expect(rows(4) == ["/release-notes I", "/gif-search I"])
        let descriptions = Dictionary(sections.flatMap(\.rows).map { ($0.command, $0.description) }, uniquingKeysWith: { a, _ in a })
        let expected = [
            "/retry": "Retry the last message (resend to agent)", "/title": "Rename the current session",
            "/stop": "Stop the active turn and background processes", "/status": "Show current session status",
            "/plan": "Write a markdown implementation plan to .hermes/plans/ without executing anything",
            "/goal": "Set a standing goal Hermes works on across turns until achieved", "/undo": "Go back and re-prompt",
            "/queue": "Queue a prompt for the next turn", "/agents": "Show active agents and running tasks",
            "/reasoning": "Reasoning effort, or show or hide the reasoning", "/yolo": "Toggle YOLO — auto-approve dangerous commands",
            "/personality": "Set a predefined personality", "/usage": "Token usage and rate limits",
            "/version": "Show Hermes Agent version", "/whoami": "Show your slash command access (admin / user)",
            "/tools": "Turn tools on or off", "/bundles": "List skill bundles",
            "/release-notes": "Draft release notes from the changelog", "/gif-search": "Find a GIF for anything",
        ]
        for (command, text) in expected { #expect(descriptions[command] == text, "\(command)") }
    }

    @Test func botChatDropsTitle() {
        let rows = SlashCatalog.sections(Self.fixtureCatalog(), isBotChat: true).flatMap(\.rows).map(\.command)
        #expect(!rows.contains("/title") && !rows.contains("/help"))
        #expect(rows.contains("/plan") && rows.contains("/status"))
        #expect(SlashCatalog.sections(Self.fixtureCatalog()).flatMap(\.rows).map(\.command).contains("/title"))
        #expect(SlashCatalog.plainDescription("/help", nil) == "Show the commands list")
    }

    /// UX #214: a pick still sends, but /yolo (turning it on), /pause and /undo ask first.
    @Test func riskyPicksAskFirst() {
        #expect(SlashCatalog.confirmation("/yolo", yoloOn: false)?.title == "Turn On YOLO?")
        #expect(SlashCatalog.confirmation("/yolo", yoloOn: true) == nil)
        #expect(SlashCatalog.confirmation("/pause", yoloOn: false) != nil)
        #expect(SlashCatalog.confirmation("/UNDO", yoloOn: false)?.button == "Undo")
        #expect(SlashCatalog.confirmation("/status", yoloOn: false) == nil)
    }

    @Test func modelPickOpensModels() {
        #expect(SlashCatalog.pickAction(.init(command: "/model", description: "", skill: false), catalog: Self.fixtureCatalog()) == .models)
    }

    @Test func catalogWithoutMetadataStillListsAndSends() {
        let catalog = CommandsCatalog(json: ["pairs": [["/usage", "Show usage"], ["/frob", "Frob things"]], "commands": []])
        #expect(catalog.commands == nil)
        let sections = SlashCatalog.sections(catalog)
        #expect(sections.flatMap(\.rows).map(\.command) == ["/usage", "/frob"])
        #expect(SlashCatalog.pickAction(sections[0].rows[0], catalog: catalog) == .send)
    }

    @Test func descriptionVectors() {
        #expect(SlashCatalog.plainDescription("/usage", "anything") == "Token usage and rate limits")
        #expect(SlashCatalog.plainDescription("/frob", "Frob things: /frob [a|b] [--force]") == "Frob things")
        #expect(SlashCatalog.plainDescription("/frob", "Frob the `widget` [--all]") == "Frob the widget")
        #expect(SlashCatalog.plainDescription("/frob", "Toggle a thing (/frob, /frob list, /frob x)") == "Toggle a thing")
        #expect(SlashCatalog.plainDescription("/frob", "start a new thing") == "Start a new thing")
        #expect(SlashCatalog.plainDescription("/frob", "Pause new work; '/frob off' resumes") == "Pause new work")
    }

    @Test func search() {
        let sections = SlashCatalog.sections(Self.fixtureCatalog())
        #expect(SlashCatalog.filter(sections, query: "usage").flatMap(\.rows).map(\.command) == ["/usage"])
        #expect(SlashCatalog.filter(sections, query: "/new").flatMap(\.rows).map(\.command) == ["/new"])
        #expect(SlashCatalog.filter(sections, query: "/branch").isEmpty)
        #expect(SlashCatalog.filter(sections, query: "nothing like it").isEmpty)
        #expect(SlashCatalog.filter(sections, query: "/STATUS").flatMap(\.rows).map(\.command) == ["/status"])
    }
}

// MARK: 8 · Slash text

@Suite("Menus · slash regex and parse (spec 1x §8.1)")
struct MenusSlashParseTests {
    @Test func detection() {
        #expect(SlashCommand.matches("/usage"))
        #expect(SlashCommand.matches("/plan a\n b"))
        #expect(!SlashCommand.matches("/usr/local"))
        #expect(!SlashCommand.matches("run /x"))
        #expect(SlashCommand.matches("/"))
        #expect(SlashCommand.matches("/ words"))
        #expect(SlashCommand.matches("  /status  "))
    }

    @Test func parse() {
        #expect(SlashCommand.parse("/usage") == ("usage", ""))
        #expect(SlashCommand.parse("/Plan a\n b ") == ("plan", "a\n b"))
        #expect(SlashCommand.parse("/") == ("", ""))
        #expect(SlashCommand.parse("/ words") == ("", ""))
        #expect(SlashCommand.parse("//title  Trip   to Lisbon") == ("title", "Trip   to Lisbon"))
    }

    @Test func rpcResults() {
        #expect(SlashResults.render(["killed": 0]) == "No background processes to stop.")
        #expect(SlashResults.render(["killed": 1]) == "Stopped 1 background process.")
        #expect(SlashResults.render(["killed": 3]) == "Stopped 3 background processes.")
        #expect(SlashResults.render(["file": "/x"]) == "Saved transcript to /x")
        #expect(SlashResults.render(["output": "Session 5cc537d1 · idle"]) == "Session 5cc537d1 · idle")
        #expect(SlashResults.reasoningParams("high --global")! == ("high", "global"))
        #expect(SlashResults.reasoningParams("-s") == nil)
    }

    @Test func outputRowText() {
        #expect(SlashOutputRow.text(command: "/status", output: "ok\n") == "slash:/status\nok")
        #expect(SlashOutputRow.parse("slash:/status\nline 1\nline 2")! == ("/status", "line 1\nline 2"))
        #expect(SlashOutputRow.parse("plain") == nil)
    }
}

// MARK: 10–11 · Transcript and readable text

@Suite("Menus · transcript and hold-menu text (spec 1x §4.4, §9.2)")
struct MenusTranscriptTests {
    private let tool = ToolCall(id: "t", name: "terminal", title: "Ran ls", argsText: nil, summary: nil, state: .done, durationSeconds: nil)

    private func messages() -> [ChatMessage] {
        [
            ChatMessage(id: "u", role: .user, parts: [.text("Hi there")], timestamp: nil, rowId: 1),
            ChatMessage(id: "a", role: .assistant, parts: [.text("Checking."), .tool(tool), .text("Done.")], timestamp: nil, rowId: 2),
            ChatMessage(id: "s", role: .system, parts: [.text("note")], timestamp: nil, rowId: 3),
            ChatMessage(id: "local-slash-1", role: .system, parts: [.text("slash:/status\nidle")], timestamp: nil, rowId: nil),
        ]
    }

    @Test func webVector() {
        #expect(ChatTranscript.text(title: "Hey", botName: "Hermes", messages: messages()) == "Hey\n\nYou:\nHi there\n\nHermes:\nChecking.\n\nDone.\n")
    }

    @Test func botNamedAndBlankName() {
        #expect(ChatTranscript.text(title: "Hey", botName: "Ivy", messages: messages()) == "Hey\n\nYou:\nHi there\n\nIvy:\nChecking.\n\nDone.\n")
        #expect(ChatTranscript.text(title: nil, botName: " ", messages: messages()).hasPrefix("You:\nHi there\n\nHermes:"))
    }

    @Test func copyKeepsMarkdown() {
        let m = ChatMessage(id: "a", role: .assistant, parts: [.text("**Bold**"), .reasoning("x"), .tool(tool), .text("`code`")], timestamp: nil, rowId: nil)
        #expect(ChatTranscript.messageText(m) == "**Bold**\n`code`")
    }

    @Test func readableVector() {
        let md = "- **Dana:** you told her\n## Next\nSee [the doc](https://x.test) and `npm i`\n```\nconst a = **b**\n```"
        #expect(ChatTranscript.readableText(md) == "• Dana: you told her\nNext\nSee the doc (https://x.test) and npm i\nconst a = **b**")
        #expect(ChatTranscript.readableText("[https://a.b](https://a.b) *em* _un_ ~~gone~~") == "https://a.b em un gone")
    }

    @Test func menuTitle() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago")!
        let locale = Locale(identifier: "en_US")
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 12))!
        let morning = cal.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 9, minute: 14))!
        let yesterday = cal.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 21, minute: 14))!
        let older = cal.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 21, minute: 14))!
        let lastYear = cal.date(from: DateComponents(year: 2025, month: 9, day: 26, hour: 21, minute: 14))!
        func title(_ s: String, _ d: Date?) -> String {
            ChatTranscript.menuTitle(sender: s, date: d, now: now, calendar: cal, locale: locale).replacingOccurrences(of: "\u{202F}", with: " ")
        }
        #expect(title("Hermes", morning) == "Hermes · 9:14 AM")
        #expect(title("You", yesterday) == "You · Yesterday 9:14 PM")
        #expect(title("Scout", older) == "Scout · Sep 26, 9:14 PM")
        #expect(title("Scout", lastYear) == "Scout · Sep 26, 2025, 9:14 PM")
        #expect(title("Scout", nil) == "Scout")
    }
}

// MARK: Slash output rows in the transcript (spec 1x §8.4)

@MainActor @Suite("Menus · slash output rows")
struct MenusSlashRowTests {
    @Test func builderAndLayout() {
        let messages = [
            ChatMessage(id: "stored-row-1-assistant", role: .assistant, parts: [.text("Hi")], timestamp: Date(), rowId: 1),
            ChatMessage(id: "local-slash-1", role: .system, parts: [.text("slash:/status\nSession · idle")], timestamp: Date(), rowId: nil),
            ChatMessage(id: "local-slash-2", role: .system, parts: [.text("slash:/usage\nline one\nline two")], timestamp: Date(), rowId: nil),
            ChatMessage(id: "local-slash-3", role: .system, parts: [.text("empty slash command")], timestamp: Date(), rowId: nil),
        ]
        let rows = ChatRowBuilder.build(ChatRowBuilder.Input(messages: messages, isRunning: false, botName: "Hermes", expanded: []))
        let slash = rows.compactMap { row -> (String, String)? in
            if case .slashOutput(let c, let o) = row.kind { return (c, o) } else { return nil }
        }
        #expect(slash.map(\.0) == ["/status", "/usage"])
        #expect(slash.map(\.1) == ["Session · idle", "line one\nline two"])
        #expect(rows.contains { if case .notice("empty slash command") = $0.kind { true } else { false } })
        // No Copy action row under a reply that a slash row follows; heights are exact layouts.
        let style = ChatStyleCache.shared.style(for: .large)
        let one = TextLayout.slashOutput(command: "/status", output: "Session · idle", gap: 6, width: 402, style: style)
        let two = TextLayout.slashOutput(command: "/usage", output: "line one\nline two", gap: 6, width: 402, style: style)
        #expect(two.height > one.height)
        guard case .line(let l) = one.content else { Issue.record("a line layout"); return }
        #expect(abs(l.frame.midX - 201) < 1, "centred")
        #expect(l.frame.width <= (402 - 32) * 0.85 + 0.5, "at most 85 % of the content width")
        // Several lines: the output is monospaced as the command is, so padded columns line up.
        guard case .line(let multi) = two.content else { Issue.record("a line layout"); return }
        let text = multi.text.text
        let commandFont = text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        let bodyFont = text.attribute(.font, at: text.length - 1, effectiveRange: nil) as? UIFont
        #expect(bodyFont != nil && bodyFont == commandFont, "the output is set in the command's monospaced face")
    }
}

// MARK: Review round 2: links in slash output, a voice memo's Copy

@MainActor @Suite("Menus · slash links and memo copy (spec 1x §8.4, §9.2)")
struct MenusReviewRoundTwoTests {
    @Test func slashOutputLinksExplicitURLsOnly() {
        let style = ChatStyleCache.shared.style(for: .large)
        let output = "Top up at https://portal.example.com/topup?x=1 or see example.org\nftp://files.example.com"
        let row = TextLayout.slashOutput(command: "/topup", output: output, gap: 6, width: 402, style: style)
        guard case .line(let l) = row.content else { Issue.record("a line layout"); return }
        var links: [URL] = []
        let text = l.text.text
        text.enumerateAttribute(.chatLink, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        #expect(links.map(\.absoluteString) == ["https://portal.example.com/topup?x=1"])
        // The command itself is never a link.
        let one = TextLayout.slashOutput(command: "/status", output: "Session · idle", gap: 6, width: 402, style: style)
        guard case .line(let plain) = one.content else { Issue.record("a line layout"); return }
        var any = false
        plain.text.text.enumerateAttribute(.chatLink, in: NSRange(location: 0, length: plain.text.text.length)) { v, _, _ in any = any || v != nil }
        #expect(!any)
    }

    @Test func memoCopyIsTheWordsNotTheDirective() {
        let stored = "MEDIA:\"/Users/me/.hermes/uploads/voice-memo.m4a\"\n\nVoice memo transcript: Remind me to review the pump quote."
        let memo = ChatMessage(id: "u", role: .user, parts: [.text(stored)], timestamp: nil, rowId: 1)
        #expect(ChatMenus.copyText(memo) == "Remind me to review the pump quote.")
        let typed = ChatMessage(id: "u2", role: .user, parts: [.text("MEDIA:\"/tmp/voice-memo-2.m4a\"\nVoice memo transcript: Call Ivy\n\nand Dana")],
                                timestamp: nil, rowId: 2)
        #expect(ChatMenus.copyText(typed) == "Call Ivy\n\nand Dana")
        let silent = ChatMessage(id: "u3", role: .user, parts: [.text("MEDIA:\"/tmp/voice-memo.wav\"\nVoice memo transcript: (unavailable)")],
                                 timestamp: nil, rowId: 3)
        #expect(ChatMenus.copyText(silent) == "Voice Memo: (no transcript)")
        #expect(!ChatMenus.copyText(memo).contains("MEDIA:"))
        // Anything else copies its Markdown as before.
        let reply = ChatMessage(id: "a", role: .assistant, parts: [.text("**Bold** MEDIA:\"/x/voice-memo.m4a\"")], timestamp: nil, rowId: 4)
        #expect(ChatMenus.copyText(reply) == "**Bold** MEDIA:\"/x/voice-memo.m4a\"")
    }
}

// MARK: Swipe to Reply

@Suite("Menus · Swipe to Reply's quote")
struct ReplyQuoteTests {
    @Test func firstTwoLinesQuoted() throws {
        let quote = try #require(ChatMenus.replyQuote("Sure, here's the plan.\n\nStep one: back up.\nStep two: upgrade."))
        #expect(quote.markdown == "> Sure, here's the plan.\n> Step one: back up. …")
        #expect(quote.excerpt == "Sure, here's the plan. Step one: back up. …")
    }

    @Test func shortMessageWhole() throws {
        let quote = try #require(ChatMenus.replyQuote("  Done.  "))
        #expect(quote.markdown == "> Done.")
        #expect(quote.excerpt == "Done.")
    }

    @Test func longLineCut() throws {
        let quote = try #require(ChatMenus.replyQuote(String(repeating: "a", count: 400)))
        #expect(quote.markdown == "> " + String(repeating: "a", count: 160) + "…")
    }

    @Test func noWordsNoQuote() {
        #expect(ChatMenus.replyQuote(" \n\n ") == nil)
    }
}

// MARK: Name Chat (the empty chat's shortcut, 2026-10-30)

@Suite("Menus · Name Chat")
struct MenusNameChatTests {
    @Test func unnamedTitles() {
        #expect(ChatMenus.isUnnamed("New Chat"))
        #expect(ChatMenus.isUnnamed(" untitled chat "))
        #expect(ChatMenus.isUnnamed(""))
        #expect(!ChatMenus.isUnnamed("Trip planning"))
        #expect(!ChatMenus.isUnnamed("New Chat ideas"))
    }

    @Test func theIntroCarriesNameChat() {
        var intro = ChatPlaceholderView.Intro(talk: true, info: true)
        let before = ChatPlaceholderView.Mode.empty(name: "Ivy", head: nil, profile: "ivy", intro: intro)
        intro.name = true
        // A changed flag is a changed mode, so the placeholder redraws when the chat gets its name.
        #expect(before != .empty(name: "Ivy", head: nil, profile: "ivy", intro: intro))
    }
}
