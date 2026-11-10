// The gateway's environment keys (`GET /api/env`) as Settings › Providers and Settings › Keys show them
// (`src/settings-ios-list.tsx` EnvSwitchRow, envKeyLabel, `vendor/.../settings/keys-settings.tsx`, `helpers.ts`
// credentialPreview / providerGroup, `constants.ts` PROVIDER_GROUPS). A set value comes back redacted only; the real
// value is read with Show (`POST /api/env/reveal`, rate limited and audited by the gateway) and never kept or logged.

import Foundation

/// One `GET /api/env` row.
nonisolated struct EnvVarInfo: Sendable, Equatable {
    var key: String
    var description: String
    var category: String
    var isPassword: Bool
    var isSet: Bool
    var advanced: Bool
    var channelManaged: Bool
    var provider: String?
    var providerLabel: String?
    var redactedValue: String?
    var url: String?
    var tools: [String]
    /// [provider-add] The provider's main key (`provider_primary`): the one its Add Provider row opens.
    var providerPrimary: Bool

    init(key: String, description: String = "", category: String = "", isPassword: Bool = false, isSet: Bool = false,
         advanced: Bool = false, channelManaged: Bool = false, provider: String? = nil, providerLabel: String? = nil,
         redactedValue: String? = nil, url: String? = nil, tools: [String] = [], providerPrimary: Bool = false) {
        self.key = key; self.description = description; self.category = category; self.isPassword = isPassword
        self.isSet = isSet; self.advanced = advanced; self.channelManaged = channelManaged; self.provider = provider
        self.providerLabel = providerLabel; self.redactedValue = redactedValue; self.url = url; self.tools = tools
        self.providerPrimary = providerPrimary
    }

    init(key: String, _ value: JSONValue) {
        self.init(key: key, description: value["description"]?.string ?? "", category: value["category"]?.string ?? "",
                  isPassword: value["is_password"]?.bool ?? false, isSet: value["is_set"]?.bool ?? false,
                  advanced: value["advanced"]?.bool ?? false, channelManaged: value["channel_managed"]?.bool ?? false,
                  provider: RosterText.trimmed(value["provider"]), providerLabel: RosterText.trimmed(value["provider_label"]),
                  redactedValue: value["redacted_value"]?.string, url: RosterText.trimmed(value["url"]),
                  tools: value["tools"]?.array?.compactMap(\.string) ?? [],
                  providerPrimary: value["provider_primary"]?.bool ?? false)
    }

    static func list(_ response: JSONValue) -> [EnvVarInfo] {
        (response.object ?? [:]).map { EnvVarInfo(key: $0.key, $0.value) }.sorted { $0.key < $1.key }
    }
}

nonisolated enum EnvKeys {
    // MARK: Which page lists a key

    /// Settings › Keys › Tools and › Other Keys (`VIEW_CATEGORIES`); messaging credentials stay on their own page.
    static func toolKeys(_ vars: [EnvVarInfo]) -> [EnvVarInfo] {
        vars.filter { !$0.channelManaged && $0.category == "tool" && !hidden($0) }
    }

    static func otherKeys(_ vars: [EnvVarInfo]) -> [EnvVarInfo] {
        vars.filter { !$0.channelManaged && ["setting", "messaging"].contains($0.category) && !hidden($0) }
    }

    /// Settings › Providers › API Keys: provider credentials, grouped by provider.
    static func providerKeys(_ vars: [EnvVarInfo]) -> [EnvVarInfo] {
        vars.filter { $0.category == "provider" && !hidden($0) }
    }

    /// The removed wake word's key never shows (`hiddenEnvKey`).
    static func hidden(_ info: EnvVarInfo) -> Bool {
        let wake = try? NSRegularExpression(pattern: "wake_?word|hey hermes|porcupine|picovoice", options: [.caseInsensitive])
        return [info.key, info.description, info.url ?? ""].contains { text in
            wake?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    // MARK: Labels

    static let platforms: [String: String] = [
        "A2A": "A2A", "BLUEBUBBLES": "BlueBubbles", "BUZZ": "Buzz", "DINGTALK": "DingTalk", "DISCORD": "Discord", "EMAIL": "Email",
        "FEISHU": "Feishu", "GATEWAY": "Gateway", "GOOGLE_CHAT": "Google Chat", "GROUPME": "GroupMe", "IRC": "IRC", "LINE": "LINE",
        "MATRIX": "Matrix", "MATTERMOST": "Mattermost", "NTFY": "ntfy", "PHOTON": "Photon", "QQ": "QQ", "QQBOT": "QQ Bot",
        "SIGNAL": "Signal", "SIMPLEX": "SimpleX", "SLACK": "Slack", "SMS": "SMS", "TEAMS": "Teams", "TELEGRAM": "Telegram",
        "WECOM": "WeCom", "WHATSAPP": "WhatsApp",
    ]

    private static let keyLabels: [(suffix: String, label: String)] = [
        ("_ALLOW_ALL_USERS", "Allow All Users"), ("_HOME_CHANNEL_NAME", "Home Channel Name"), ("_HOME_CHANNEL", "Home Channel"),
        ("_HOME_ADDRESS", "Home Address"), ("_THREAD_REQUIRE_MENTION", "Require Mention in Threads"),
        ("_REQUIRE_MENTION", "Require Mention"), ("_DM_AUTO_THREAD", "Threads for Direct Messages"),
        ("_AUTO_THREAD", "Automatic Threads"), ("_FREE_RESPONSE_ROOMS", "Answer Without Mention In"),
        ("_FREE_RESPONSE_CHANNELS", "Answer Without Mention In"), ("_ALLOWED_CHANNELS", "Allowed Channels"),
        ("_REPLY_TO_MODE", "Reply Style"), ("_REPLY_MODE", "Reply Style"), ("_PROXY", "Proxy"),
    ]

    static let toolKeyLabels: [String: String] = [
        "BRV_API_KEY": "ByteRover", "VOICE_TOOLS_OPENAI_KEY": "OpenAI for Voice", "HERMES_LANGFUSE_PUBLIC_KEY": "Langfuse Public Key",
        "HERMES_LANGFUSE_SECRET_KEY": "Langfuse Secret Key", "HERMES_SIMPLEX_TEXT_BATCH_DELAY": "SimpleX: Message Batch Delay",
        "TOOL_GATEWAY_SCHEME": "Tool Gateway Protocol", "TOOL_GATEWAY_USER_TOKEN": "Tool Gateway User Token",
        "AGENT_BROWSER_ENGINE": "Browser Engine", "GATEWAY_PROXY_KEY": "Gateway Proxy Key",
        // Stress test 2026-10-28 #100, round 2 (both): "API Server Enabled" named a variable, not a setting.
        "API_SERVER_ENABLED": "API Server",
    ]

    /// Gateway descriptions reworded where they speak in developer terms (stress test 2026-10-28 #100, round 2).
    private static let plainDescriptions: [(String, String)] = [
        ("Run the OpenAI-compatible API server", "Let other apps use your bots the way they use OpenAI’s API"),
    ]

    private static let brandWords: [String: String] = [
        "openviking": "OpenViking", "retaindb": "RetainDB", "searxng": "SearXNG", "langfuse": "Langfuse", "simplex": "SimpleX",
        "url": "URL", "api": "API", "id": "ID",
        // Mac UX stress test #59: provider key titles read as the provider ("OPENROUTER_API_KEY" → "OpenRouter API Key").
        "openrouter": "OpenRouter", "openai": "OpenAI", "xai": "xAI", "deepseek": "DeepSeek", "dashscope": "DashScope",
        "minimax": "MiniMax", "hf": "Hugging Face", "huggingface": "Hugging Face", "glm": "GLM", "zai": "Z.AI", "opencode": "OpenCode",
        "elevenlabs": "ElevenLabs", "github": "GitHub", "cn": "China", "fal": "FAL", "llm": "LLM", "tts": "TTS", "stt": "STT",
    ]

    /// A messaging or tool key's name as words ("IRC: Allow All Users", "ByteRover"); nil for anything else.
    static func keyLabel(_ key: String) -> String? {
        if let label = toolKeyLabels[key] { return label }
        // Longest platform first so GOOGLE_CHAT wins over a shorter match.
        for (suffix, label) in keyLabels where key.hasSuffix(suffix) {
            let platform = String(key.dropLast(suffix.count))
            if let name = platforms[platform] { return "\(name): \(label)" }
        }
        return brandedLabel(key)
    }

    private static func brandedLabel(_ key: String) -> String? {
        let own = key.hasPrefix("HERMES_") && !(key.hasSuffix("_API_KEY") || key.hasSuffix("_TOKEN") || key.hasSuffix("_KEY"))
        let words = key.lowercased().split(separator: "_").map(String.init)
        let branded = words.contains { ["openviking", "retaindb", "searxng", "langfuse", "simplex"].contains($0) }
        guard own || branded else { return nil }
        var name = key
        if name.hasPrefix("HERMES_") { name.removeFirst("HERMES_".count) }
        if name.hasSuffix("_API_KEY") { name.removeLast("_API_KEY".count) }
        return name.lowercased().split(separator: "_").map { word in
            brandWords[String(word)] ?? (word.prefix(1).uppercased() + word.dropFirst())
        }.joined(separator: " ")
    }

    /// The row's title: the platform/tool label, else the key's words ("OPENAI_API_KEY" → "OpenAI API Key" stays the key's).
    static func title(_ info: EnvVarInfo) -> String {
        if let label = keyLabel(info.key) { return label }
        return info.key.split(separator: "_").map { word -> String in
            let lower = word.lowercased()
            if let brand = brandWords[lower] { return brand }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined(separator: " ")
    }

    /// Photon calls its group-chat mention keyword a "wake word", which reads like the removed feature.
    static func description(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"\bwake word\b"#, with: "keyword", options: [.regularExpression, .caseInsensitive])
        for (from, to) in plainDescriptions { out = out.replacingOccurrences(of: from, with: to) }
        return out
    }

    // MARK: Switches (`booleanEnvKey`, `envSwitchState`)

    /// On/off keys: the name or the "(true/false)" / "default: false" wording says so.
    static func isSwitch(_ info: EnvVarInfo) -> Bool {
        guard !info.isPassword else { return false }
        if ["_ALLOW_ALL_USERS", "_REQUIRE_MENTION", "_AUTO_THREAD"].contains(where: info.key.hasSuffix) { return true }
        return info.description.range(of: #"true/false|default:?\s*(true|false)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func switchDefault(_ description: String) -> Bool {
        description.range(of: #"default:?\s*true\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "true"/"1"/"yes"/"on" → true and their opposites → false; anything else isn't a switch value.
    static func bool(_ text: String?) -> Bool? {
        guard let text = text?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        if ["1", "true", "yes", "on"].contains(text) { return true }
        if ["0", "false", "no", "off"].contains(text) { return false }
        return nil
    }

    /// Allow All Users can also come from the gateway's config.yaml, so "not set here" never means off.
    static func defersWhenUnset(_ key: String) -> Bool { key.hasSuffix("_ALLOW_ALL_USERS") }

    /// What a switch can truthfully show: a value written here or revealed, else the default for a key that isn't set
    /// (and doesn't defer to another setting); nil when it isn't known.
    static func switchState(_ info: EnvVarInfo, known: Bool?) -> Bool? {
        if let known { return known }
        if info.isSet || defersWhenUnset(info.key) { return nil }
        return switchDefault(info.description)
    }

    /// Turning a switch back to its default removes the key (the gateway's default applies again); Allow All Users is
    /// always written, since removing it hands the decision back to config.yaml.
    static func switchRemoves(_ info: EnvVarInfo, to on: Bool) -> Bool {
        !defersWhenUnset(info.key) && on == switchDefault(info.description)
    }

    /// A switch's description without the "(true/false)" its text field needed.
    static func switchDescription(_ text: String) -> String {
        var out = description(text)
        out = out.replacingOccurrences(of: #"\s*\(true/false,\s*default:?\s*true\)"#, with: " (on by default)", options: [.regularExpression, .caseInsensitive])
        out = out.replacingOccurrences(of: #"\s*\(true/false,\s*default:?\s*false\)"#, with: " (off by default)", options: [.regularExpression, .caseInsensitive])
        out = out.replacingOccurrences(of: #"\(default:?\s*true\)"#, with: "(on by default)", options: [.regularExpression, .caseInsensitive])
        out = out.replacingOccurrences(of: #"\(default:?\s*false\)"#, with: "(off by default)", options: [.regularExpression, .caseInsensitive])
        out = out.replacingOccurrences(of: #"\s*\(true/false\)"#, with: "", options: [.regularExpression, .caseInsensitive])
        return out
    }

    /// The words under a switch whose state isn't known.
    static func unknownNote(_ info: EnvVarInfo, revealed: String?) -> String {
        guard info.isSet else { return "Not set here, so the gateway’s own allow-all setting decides." }
        if let revealed, bool(revealed) == nil { return "Set to “\(revealed)”." }
        return "Set on your gateway. Choose Show Current Value to see whether it’s on."
    }

    // MARK: Redacted previews

    /// The gateway wraps stored-key previews in «redacted:…»: the inner preview, or a plain mask.
    static func preview(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard value.hasPrefix("«redacted") else { return value }
        if value.hasPrefix("«redacted:"), value.hasSuffix("»") {
            let inner = value.dropFirst("«redacted:".count).dropLast().trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty { return inner }
        }
        return "••••••••"
    }

    /// The preview a key's row shows after "Set ·". Stress test 2026-10-28 #84 (both): the gateway clips every stored
    /// value, so a port read "86…", which looked like a masked number. A secret keeps its clipped preview (it tells two
    /// keys apart); a plain setting shows none until Show reads it.
    static func rowPreview(_ info: EnvVarInfo) -> String? {
        guard info.isPassword else { return nil }
        return preview(info.redactedValue)
    }

    /// Stress test 2026-10-28 #84, round 2 (both): a set key whose value isn't a secret and is a number or an on/off
    /// (a port, a timeout, Require Mention) is read once when the page opens, so its row shows the value itself ("8642",
    /// a switch) instead of "Set". The gateway clips every stored value, so a read (`/api/env/reveal`) is the only way.
    /// Text values (URLs, names) aren't read: a proxy address can carry a password.
    static func readsValueItself(_ info: EnvVarInfo) -> Bool {
        guard info.isSet, !info.isPassword else { return false }
        return isSwitch(info) || isNumber(info)
    }

    /// A key that holds a number: its name ends like one, or its description says so.
    static func isNumber(_ info: EnvVarInfo) -> Bool {
        let suffixes = ["_PORT", "_TIMEOUT", "_DELAY", "_LIMIT", "_SECONDS", "_MS", "_INTERVAL", "_RETRIES", "_COUNT", "_SIZE", "_MAX"]
        if suffixes.contains(where: info.key.hasSuffix) { return true }
        return info.description.range(of: #"\b(port|seconds|milliseconds|number of)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// At most this many keys are read when the page opens: the gateway allows five reads in 30 seconds, and Show
    /// must still have one left.
    static let readsPerOpen = 3

    // MARK: Provider groups (`PROVIDER_GROUPS`, longest prefix wins)

    struct ProviderGroup: Sendable, Equatable {
        var prefix: String
        var name: String
        var detail: String?
        var docs: String?
        var priority: Int
    }

    static let providerGroups: [ProviderGroup] = [
        .init(prefix: "NOUS_", name: "Nous Portal", detail: "Hosted Hermes and Nous-trained models", docs: "https://portal.nousresearch.com", priority: 0),
        .init(prefix: "FIREWORKS_", name: "Fireworks AI", detail: "OpenAI-compatible direct model API", docs: "https://app.fireworks.ai/settings/users/api-keys", priority: 1),
        .init(prefix: "OPENROUTER_", name: "OpenRouter", detail: "Aggregator for hundreds of frontier models", docs: "https://openrouter.ai/keys", priority: 1),
        .init(prefix: "ANTHROPIC_", name: "Anthropic", detail: "Claude API access (Sonnet, Opus, Haiku)", docs: "https://console.anthropic.com/settings/keys", priority: 2),
        .init(prefix: "XAI_", name: "xAI", detail: "Grok models", docs: "https://console.x.ai/", priority: 3),
        .init(prefix: "GOOGLE_", name: "Gemini", detail: "Google AI Studio", docs: "https://aistudio.google.com/app/apikey", priority: 4),
        .init(prefix: "GEMINI_", name: "Gemini", priority: 4),
        .init(prefix: "DEEPSEEK_", name: "DeepSeek", detail: "Direct DeepSeek API", docs: "https://platform.deepseek.com/api_keys", priority: 5),
        .init(prefix: "DASHSCOPE_", name: "DashScope (Qwen)", detail: "Alibaba Cloud DashScope", docs: "https://modelstudio.console.alibabacloud.com/", priority: 6),
        .init(prefix: "HERMES_QWEN_", name: "DashScope (Qwen)", priority: 6),
        .init(prefix: "GLM_", name: "GLM / Z.AI", detail: "Zhipu GLM and Z.AI endpoints", docs: "https://z.ai/", priority: 7),
        .init(prefix: "ZAI_", name: "GLM / Z.AI", priority: 7),
        .init(prefix: "Z_AI_", name: "GLM / Z.AI", priority: 7),
        .init(prefix: "KIMI_", name: "Kimi / Moonshot", detail: "Moonshot Kimi endpoints", docs: "https://platform.moonshot.cn/", priority: 8),
        .init(prefix: "KIMI_CN_", name: "Kimi (China)", detail: "Moonshot China endpoint", docs: "https://platform.moonshot.cn/", priority: 9),
        .init(prefix: "MINIMAX_", name: "MiniMax", detail: "MiniMax international endpoints", docs: "https://www.minimax.io/", priority: 10),
        .init(prefix: "MINIMAX_CN_", name: "MiniMax (China)", detail: "MiniMax mainland China endpoint", docs: "https://www.minimaxi.com/", priority: 11),
        .init(prefix: "HF_", name: "Hugging Face", detail: "Inference Providers", docs: "https://huggingface.co/settings/tokens", priority: 12),
        .init(prefix: "OPENCODE_ZEN_", name: "OpenCode Zen", detail: "Pay-as-you-go coding models", docs: "https://opencode.ai/auth", priority: 13),
        .init(prefix: "OPENCODE_GO_", name: "OpenCode Go", detail: "Subscription for open coding models", docs: "https://opencode.ai/auth", priority: 14),
        .init(prefix: "NVIDIA_", name: "NVIDIA NIM", detail: "build.nvidia.com or your own NIM endpoint", docs: "https://build.nvidia.com/", priority: 15),
        .init(prefix: "OLLAMA_", name: "Ollama Cloud", detail: "Cloud-hosted open models", docs: "https://ollama.com/settings", priority: 16),
        .init(prefix: "LM_", name: "LM Studio", detail: "Local LM Studio server", docs: "https://lmstudio.ai/docs/local-server", priority: 17),
        .init(prefix: "STEPFUN_", name: "StepFun", priority: 18),
        .init(prefix: "XIAOMI_", name: "Xiaomi MiMo", priority: 19),
        .init(prefix: "ARCEEAI_", name: "Arcee AI", priority: 20),
        .init(prefix: "ARCEE_", name: "Arcee AI", priority: 20),
        .init(prefix: "GMI_", name: "GMI Cloud", priority: 21),
        .init(prefix: "AZURE_FOUNDRY_", name: "Azure Foundry", priority: 22),
        .init(prefix: "AWS_", name: "AWS Bedrock", detail: "AWS profile and region", priority: 23),
    ]

    /// The provider a key belongs to: the gateway's own label first, then the longest prefix, else "Other".
    static func providerName(_ info: EnvVarInfo) -> String {
        if let label = info.providerLabel { return label }
        let best = providerGroups.filter { info.key.hasPrefix($0.prefix) }.max { $0.prefix.count < $1.prefix.count }
        return best?.name ?? "Other"
    }

    static func providerPriority(_ name: String) -> Int { providerGroups.first { $0.name == name }?.priority ?? 99 }

    /// Item 5: a model's provider slug ("anthropic", "openrouter") in the words these API key cards already use
    /// ("Anthropic", "OpenRouter"), matched against the group whose env var prefix is the slug plus "_". An unlisted
    /// slug just gets its first letter capitalized, so Bot Info never shows the internal id as typed.
    static func providerDisplayName(forSlug slug: String) -> String {
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if let own = ProviderPrefs.active.providerName(trimmed) { return own }   // [provider-manager] the owner's name
        if let match = providerGroups.first(where: { $0.prefix.dropLast().lowercased() == trimmed.lowercased() }) {
            return match.name
        }
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }

    /// Provider keys in cards: priority, then name.
    static func groupedProviders(_ vars: [EnvVarInfo]) -> [(name: String, keys: [EnvVarInfo])] {
        let groups = Dictionary(grouping: providerKeys(vars), by: providerName)
        return groups.map { (name: $0.key, keys: $0.value.sorted { $0.key < $1.key }) }
            .sorted { (providerPriority($0.name), $0.name) < (providerPriority($1.name), $1.name) }
    }
}
