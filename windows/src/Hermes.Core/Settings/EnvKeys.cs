using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Bots;

namespace Hermes.Core.Settings;

// The gateway's environment keys (`GET /api/env`) as Settings › Providers and Settings › Keys show them
// (port of HermesKit/Settings/EnvKeys.swift). A set value comes back redacted only; the real value is read
// with Show (`POST /api/env/reveal`) and never kept or logged.

/// One `GET /api/env` row.
public sealed record EnvVarInfo(
    string Key,
    string Description = "",
    string Category = "",
    bool IsPassword = false,
    bool IsSet = false,
    bool Advanced = false,
    bool ChannelManaged = false,
    string? Provider = null,
    string? ProviderLabel = null,
    string? RedactedValue = null,
    string? Url = null,
    IReadOnlyList<string>? Tools = null,
    bool ProviderPrimary = false)
{
    public IReadOnlyList<string> ToolList => Tools ?? [];

    public static EnvVarInfo FromJson(string key, JsonNode? value)
    {
        var tools = (value.Arr("tools") ?? [])
            .Select(J.AsString)
            .Where(s => s != null)
            .Cast<string>()
            .ToList();
        return new EnvVarInfo(
            Key: key,
            Description: value.Str("description") ?? "",
            Category: value.Str("category") ?? "",
            IsPassword: value.Bool("is_password") ?? false,
            IsSet: value.Bool("is_set") ?? false,
            Advanced: value.Bool("advanced") ?? false,
            ChannelManaged: value.Bool("channel_managed") ?? false,
            Provider: RosterText.Trimmed(value.Get("provider")),
            ProviderLabel: RosterText.Trimmed(value.Get("provider_label")),
            RedactedValue: value.Str("redacted_value"),
            Url: RosterText.Trimmed(value.Get("url")),
            Tools: tools,
            ProviderPrimary: value.Bool("provider_primary") ?? false);
    }

    public static List<EnvVarInfo> List(JsonNode? response)
    {
        if (response is not JsonObject obj) return [];
        return [.. obj.Select(kv => FromJson(kv.Key, kv.Value)).OrderBy(v => v.Key, StringComparer.Ordinal)];
    }
}

public static class EnvKeys
{
    private static readonly Regex WakeRx = new(@"wake_?word|hey hermes|porcupine|picovoice", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex WakeWordRx = new(@"\bwake word\b", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex SwitchDescRx = new(@"true/false|default:?\s*(true|false)\b", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex SwitchDefaultTrueRx = new(@"default:?\s*true\b", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex NumberDescRx = new(@"\b(port|seconds|milliseconds|number of)\b", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex SwitchTfTrueRx = new(@"\s*\(true/false,\s*default:?\s*true\)", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex SwitchTfFalseRx = new(@"\s*\(true/false,\s*default:?\s*false\)", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex SwitchDefTrueRx = new(@"\(default:?\s*true\)", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex SwitchDefFalseRx = new(@"\(default:?\s*false\)", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex SwitchTfOnlyRx = new(@"\s*\(true/false\)", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    // MARK: Which page lists a key

    public static List<EnvVarInfo> ToolKeys(IEnumerable<EnvVarInfo> vars) =>
        [.. vars.Where(v => !v.ChannelManaged && v.Category == "tool" && !Hidden(v))];

    public static List<EnvVarInfo> OtherKeys(IEnumerable<EnvVarInfo> vars) =>
        [.. vars.Where(v => !v.ChannelManaged && v.Category is "setting" or "messaging" && !Hidden(v))];

    public static List<EnvVarInfo> ProviderKeys(IEnumerable<EnvVarInfo> vars) =>
        [.. vars.Where(v => v.Category == "provider" && !Hidden(v))];

    /// The removed wake word's key never shows (`hiddenEnvKey`).
    public static bool Hidden(EnvVarInfo info) =>
        WakeRx.IsMatch(info.Key) || WakeRx.IsMatch(info.Description) || WakeRx.IsMatch(info.Url ?? "");

    // MARK: Labels

    public static readonly IReadOnlyDictionary<string, string> Platforms = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["A2A"] = "A2A", ["BLUEBUBBLES"] = "BlueBubbles", ["BUZZ"] = "Buzz", ["DINGTALK"] = "DingTalk", ["DISCORD"] = "Discord",
        ["EMAIL"] = "Email", ["FEISHU"] = "Feishu", ["GATEWAY"] = "Gateway", ["GOOGLE_CHAT"] = "Google Chat", ["GROUPME"] = "GroupMe",
        ["IRC"] = "IRC", ["LINE"] = "LINE", ["MATRIX"] = "Matrix", ["MATTERMOST"] = "Mattermost", ["NTFY"] = "ntfy",
        ["PHOTON"] = "Photon", ["QQ"] = "QQ", ["QQBOT"] = "QQ Bot", ["SIGNAL"] = "Signal", ["SIMPLEX"] = "SimpleX",
        ["SLACK"] = "Slack", ["SMS"] = "SMS", ["TEAMS"] = "Teams", ["TELEGRAM"] = "Telegram", ["WECOM"] = "WeCom", ["WHATSAPP"] = "WhatsApp",
    };

    private static readonly (string Suffix, string Label)[] KeyLabels =
    [
        ("_ALLOW_ALL_USERS", "Allow All Users"), ("_HOME_CHANNEL_NAME", "Home Channel Name"), ("_HOME_CHANNEL", "Home Channel"),
        ("_HOME_ADDRESS", "Home Address"), ("_THREAD_REQUIRE_MENTION", "Require Mention in Threads"),
        ("_REQUIRE_MENTION", "Require Mention"), ("_DM_AUTO_THREAD", "Threads for Direct Messages"),
        ("_AUTO_THREAD", "Automatic Threads"), ("_FREE_RESPONSE_ROOMS", "Answer Without Mention In"),
        ("_FREE_RESPONSE_CHANNELS", "Answer Without Mention In"), ("_ALLOWED_CHANNELS", "Allowed Channels"),
        ("_REPLY_TO_MODE", "Reply Style"), ("_REPLY_MODE", "Reply Style"), ("_PROXY", "Proxy"),
    ];

    public static readonly IReadOnlyDictionary<string, string> ToolKeyLabels = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["BRV_API_KEY"] = "ByteRover", ["VOICE_TOOLS_OPENAI_KEY"] = "OpenAI for Voice",
        ["HERMES_LANGFUSE_PUBLIC_KEY"] = "Langfuse Public Key", ["HERMES_LANGFUSE_SECRET_KEY"] = "Langfuse Secret Key",
        ["HERMES_SIMPLEX_TEXT_BATCH_DELAY"] = "SimpleX: Message Batch Delay", ["TOOL_GATEWAY_SCHEME"] = "Tool Gateway Protocol",
        ["TOOL_GATEWAY_USER_TOKEN"] = "Tool Gateway User Token", ["AGENT_BROWSER_ENGINE"] = "Browser Engine",
        ["GATEWAY_PROXY_KEY"] = "Gateway Proxy Key", ["API_SERVER_ENABLED"] = "API Server",
    };

    private static readonly (string From, string To)[] PlainDescriptions =
    [
        ("Run the OpenAI-compatible API server", "Let other apps use your bots the way they use OpenAI’s API"),
    ];

    private static readonly Dictionary<string, string> BrandWords = new(StringComparer.Ordinal)
    {
        ["openviking"] = "OpenViking", ["retaindb"] = "RetainDB", ["searxng"] = "SearXNG", ["langfuse"] = "Langfuse",
        ["simplex"] = "SimpleX", ["url"] = "URL", ["api"] = "API", ["id"] = "ID",
        ["openrouter"] = "OpenRouter", ["openai"] = "OpenAI", ["xai"] = "xAI", ["deepseek"] = "DeepSeek",
        ["dashscope"] = "DashScope", ["minimax"] = "MiniMax", ["hf"] = "Hugging Face", ["huggingface"] = "Hugging Face",
        ["glm"] = "GLM", ["zai"] = "Z.AI", ["opencode"] = "OpenCode", ["elevenlabs"] = "ElevenLabs",
        ["github"] = "GitHub", ["cn"] = "China", ["fal"] = "FAL", ["llm"] = "LLM", ["tts"] = "TTS", ["stt"] = "STT",
    };

    private static readonly HashSet<string> BrandedMarkers = ["openviking", "retaindb", "searxng", "langfuse", "simplex"];

    public static string? KeyLabel(string key)
    {
        if (ToolKeyLabels.TryGetValue(key, out var label)) return label;
        foreach (var (suffix, suffixLabel) in KeyLabels)
        {
            if (!key.EndsWith(suffix, StringComparison.Ordinal)) continue;
            var platform = key[..^suffix.Length];
            if (Platforms.TryGetValue(platform, out var name)) return $"{name}: {suffixLabel}";
        }
        return BrandedLabel(key);
    }

    private static string? BrandedLabel(string key)
    {
        var own = key.StartsWith("HERMES_", StringComparison.Ordinal)
            && !(key.EndsWith("_API_KEY", StringComparison.Ordinal) || key.EndsWith("_TOKEN", StringComparison.Ordinal) || key.EndsWith("_KEY", StringComparison.Ordinal));
        var lowerWords = key.ToLowerInvariant().Split('_', StringSplitOptions.RemoveEmptyEntries);
        var branded = lowerWords.Any(BrandedMarkers.Contains);
        if (!own && !branded) return null;
        var name = key;
        if (name.StartsWith("HERMES_", StringComparison.Ordinal)) name = name["HERMES_".Length..];
        if (name.EndsWith("_API_KEY", StringComparison.Ordinal)) name = name[..^"_API_KEY".Length];
        return string.Join(" ", name.ToLowerInvariant().Split('_', StringSplitOptions.RemoveEmptyEntries)
            .Select(w => BrandWords.TryGetValue(w, out var b) ? b : char.ToUpperInvariant(w[0]) + w[1..]));
    }

    public static string Title(EnvVarInfo info)
    {
        if (KeyLabel(info.Key) is { } label) return label;
        return string.Join(" ", info.Key.Split('_', StringSplitOptions.RemoveEmptyEntries).Select(word =>
        {
            var lower = word.ToLowerInvariant();
            return BrandWords.TryGetValue(lower, out var brand) ? brand : char.ToUpperInvariant(lower[0]) + lower[1..];
        }));
    }

    public static string Description(string text)
    {
        var out_ = WakeWordRx.Replace(text, "keyword");
        foreach (var (from, to) in PlainDescriptions) out_ = out_.Replace(from, to, StringComparison.Ordinal);
        return out_;
    }

    /// Plain-English warning when a pasted value is clearly the wrong kind of credential for `key` (for example,
    /// pasting a one-time `code#state` OAuth callback code into `CLAUDE_CODE_OAUTH_TOKEN`, which overrides a valid
    /// `claude auth login` session and causes HTTP 401 Invalid bearer token — `9d40c4199`).
    public static string? ValueProblem(string key, string value)
    {
        var trimmed = (value ?? "").Trim();
        if (trimmed.Length == 0) return null;
        if (key == "CLAUDE_CODE_OAUTH_TOKEN")
        {
            if (!trimmed.StartsWith("sk-ant-", StringComparison.Ordinal) && trimmed.Contains('#'))
                return "That looks like a one-time login code (code#state), not an OAuth token. Paste it into the Terminal prompt during claude auth login instead — or leave this key unset if you already signed in.";
            if (!trimmed.StartsWith("sk-ant-", StringComparison.Ordinal))
                return "Claude Code OAuth tokens start with sk-ant- (from claude setup-token). If you signed in with claude auth login, leave this key unset so it doesn’t override your login.";
        }
        return null;
    }

    /// Fallback description shown in env key editors when the gateway doesn't supply one for a known key.
    public static string FallbackDescription(string key) =>
        key == "CLAUDE_CODE_OAUTH_TOKEN"
            ? "Only for a long-lived token from claude setup-token (starts with sk-ant-). Leave unset if you signed in with claude auth login — setting this key overrides that login."
            : "";

    // MARK: Switches

    private static readonly string[] SwitchSuffixes = ["_ALLOW_ALL_USERS", "_REQUIRE_MENTION", "_AUTO_THREAD"];

    public static bool IsSwitch(EnvVarInfo info)
    {
        if (info.IsPassword) return false;
        if (SwitchSuffixes.Any(s => info.Key.EndsWith(s, StringComparison.Ordinal))) return true;
        return SwitchDescRx.IsMatch(info.Description);
    }

    public static bool SwitchDefault(string description) => SwitchDefaultTrueRx.IsMatch(description);

    public static bool? Bool(string? text)
    {
        var t = text?.Trim().ToLowerInvariant();
        return t switch
        {
            "1" or "true" or "yes" or "on" => true,
            "0" or "false" or "no" or "off" => false,
            _ => null,
        };
    }

    public static bool DefersWhenUnset(string key) => key.EndsWith("_ALLOW_ALL_USERS", StringComparison.Ordinal);

    public static bool? SwitchState(EnvVarInfo info, bool? known)
    {
        if (known is { } k) return k;
        if (info.IsSet || DefersWhenUnset(info.Key)) return null;
        return SwitchDefault(info.Description);
    }

    public static bool SwitchRemoves(EnvVarInfo info, bool on) =>
        !DefersWhenUnset(info.Key) && on == SwitchDefault(info.Description);

    public static string SwitchDescription(string text)
    {
        var out_ = Description(text);
        out_ = SwitchTfTrueRx.Replace(out_, " (on by default)");
        out_ = SwitchTfFalseRx.Replace(out_, " (off by default)");
        out_ = SwitchDefTrueRx.Replace(out_, "(on by default)");
        out_ = SwitchDefFalseRx.Replace(out_, "(off by default)");
        out_ = SwitchTfOnlyRx.Replace(out_, "");
        return out_;
    }

    public static string UnknownNote(EnvVarInfo info, string? revealed)
    {
        if (!info.IsSet) return "Not set here, so the gateway’s own allow-all setting decides.";
        if (revealed != null && Bool(revealed) == null) return $"Set to “{revealed}”.";
        return "Set on your gateway. Choose Show Current Value to see whether it’s on.";
    }

    // MARK: Redacted previews

    public static string? Preview(string? value)
    {
        if (string.IsNullOrEmpty(value)) return null;
        if (!value.StartsWith("«redacted", StringComparison.Ordinal)) return value;
        if (value.StartsWith("«redacted:", StringComparison.Ordinal) && value.EndsWith('»'))
        {
            var inner = value["«redacted:".Length..^1].Trim();
            if (inner.Length > 0) return inner;
        }
        return "••••••••";
    }

    public static string? RowPreview(EnvVarInfo info) => info.IsPassword ? Preview(info.RedactedValue) : null;

    public static bool ReadsValueItself(EnvVarInfo info) => info.IsSet && !info.IsPassword && (IsSwitch(info) || IsNumber(info));

    private static readonly string[] NumberSuffixes =
        ["_PORT", "_TIMEOUT", "_DELAY", "_LIMIT", "_SECONDS", "_MS", "_INTERVAL", "_RETRIES", "_COUNT", "_SIZE", "_MAX"];

    public static bool IsNumber(EnvVarInfo info) =>
        NumberSuffixes.Any(s => info.Key.EndsWith(s, StringComparison.Ordinal)) || NumberDescRx.IsMatch(info.Description);

    public const int ReadsPerOpen = 3;

    // MARK: Provider groups (longest prefix wins)

    public sealed record ProviderGroup(string Prefix, string Name, string? Detail = null, string? Docs = null, int Priority = 99);

    public static readonly IReadOnlyList<ProviderGroup> ProviderGroups =
    [
        new("NOUS_", "Nous Portal", "Hosted Hermes and Nous-trained models", "https://portal.nousresearch.com", 0),
        new("FIREWORKS_", "Fireworks AI", "OpenAI-compatible direct model API", "https://app.fireworks.ai/settings/users/api-keys", 1),
        new("OPENROUTER_", "OpenRouter", "Aggregator for hundreds of frontier models", "https://openrouter.ai/keys", 1),
        new("ANTHROPIC_", "Anthropic", "Claude API access (Sonnet, Opus, Haiku)", "https://console.anthropic.com/settings/keys", 2),
        new("XAI_", "xAI", "Grok models", "https://console.x.ai/", 3),
        new("GOOGLE_", "Gemini", "Google AI Studio", "https://aistudio.google.com/app/apikey", 4),
        new("GEMINI_", "Gemini", Priority: 4),
        new("DEEPSEEK_", "DeepSeek", "Direct DeepSeek API", "https://platform.deepseek.com/api_keys", 5),
        new("DASHSCOPE_", "DashScope (Qwen)", "Alibaba Cloud DashScope", "https://modelstudio.console.alibabacloud.com/", 6),
        new("HERMES_QWEN_", "DashScope (Qwen)", Priority: 6),
        new("GLM_", "GLM / Z.AI", "Zhipu GLM and Z.AI endpoints", "https://z.ai/", 7),
        new("ZAI_", "GLM / Z.AI", Priority: 7),
        new("Z_AI_", "GLM / Z.AI", Priority: 7),
        new("KIMI_", "Kimi / Moonshot", "Moonshot Kimi endpoints", "https://platform.moonshot.cn/", 8),
        new("KIMI_CN_", "Kimi (China)", "Moonshot China endpoint", "https://platform.moonshot.cn/", 9),
        new("MINIMAX_", "MiniMax", "MiniMax international endpoints", "https://www.minimax.io/", 10),
        new("MINIMAX_CN_", "MiniMax (China)", "MiniMax mainland China endpoint", "https://www.minimaxi.com/", 11),
        new("HF_", "Hugging Face", "Inference Providers", "https://huggingface.co/settings/tokens", 12),
        new("OPENCODE_ZEN_", "OpenCode Zen", "Pay-as-you-go coding models", "https://opencode.ai/auth", 13),
        new("OPENCODE_GO_", "OpenCode Go", "Subscription for open coding models", "https://opencode.ai/auth", 14),
        new("NVIDIA_", "NVIDIA NIM", "build.nvidia.com or your own NIM endpoint", "https://build.nvidia.com/", 15),
        new("OLLAMA_", "Ollama Cloud", "Cloud-hosted open models", "https://ollama.com/settings", 16),
        new("LM_", "LM Studio", "Local LM Studio server", "https://lmstudio.ai/docs/local-server", 17),
        new("STEPFUN_", "StepFun", Priority: 18),
        new("XIAOMI_", "Xiaomi MiMo", Priority: 19),
        new("ARCEEAI_", "Arcee AI", Priority: 20),
        new("ARCEE_", "Arcee AI", Priority: 20),
        new("GMI_", "GMI Cloud", Priority: 21),
        new("AZURE_FOUNDRY_", "Azure Foundry", Priority: 22),
        new("AWS_", "AWS Bedrock", "AWS profile and region", Priority: 23),
    ];

    public static string ProviderName(EnvVarInfo info)
    {
        if (!string.IsNullOrEmpty(info.ProviderLabel)) return info.ProviderLabel;
        var best = ProviderGroups
            .Where(g => info.Key.StartsWith(g.Prefix, StringComparison.Ordinal))
            .OrderByDescending(g => g.Prefix.Length)
            .FirstOrDefault();
        return best?.Name ?? "Other";
    }

    public static int ProviderPriority(string name) =>
        ProviderGroups.FirstOrDefault(g => g.Name == name)?.Priority ?? 99;

    public static string ProviderDisplayName(string slug)
    {
        var trimmed = (slug ?? "").Trim();
        if (trimmed.Length == 0) return trimmed;
        var match = ProviderGroups.FirstOrDefault(g =>
            g.Prefix[..^1].Equals(trimmed, StringComparison.OrdinalIgnoreCase));
        if (match != null) return match.Name;
        return char.ToUpperInvariant(trimmed[0]) + trimmed[1..];
    }

    public static List<(string Name, List<EnvVarInfo> Keys)> GroupedProviders(IEnumerable<EnvVarInfo> vars) =>
        [.. ProviderKeys(vars)
            .GroupBy(ProviderName, StringComparer.Ordinal)
            .Select(g => (Name: g.Key, Keys: g.OrderBy(v => v.Key, StringComparer.Ordinal).ToList()))
            .OrderBy(g => ProviderPriority(g.Name))
            .ThenBy(g => g.Name, StringComparer.Ordinal)];
}
