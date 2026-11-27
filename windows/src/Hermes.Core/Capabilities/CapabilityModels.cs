using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;

namespace Hermes.Core.Capabilities;

// Wire types of Capabilities (docs/spec/3x-capabilities.md §12; HermesKit/Contracts+capabilities.swift,
// Contracts+settings.swift). Decoding is lenient: an unknown key is ignored, a missing optional field never fails a page.

/// The four lists, each its own page (App/Capabilities/CapabilitiesModel.swift `CapabilitiesTab`).
public enum CapabilitiesTab { Skills, Tools, Connectors, Plugins }

public static class CapabilitiesTabs
{
    public static readonly CapabilitiesTab[] All = [CapabilitiesTab.Skills, CapabilitiesTab.Tools, CapabilitiesTab.Connectors, CapabilitiesTab.Plugins];

    public static string Title(this CapabilitiesTab tab) => tab switch
    {
        CapabilitiesTab.Skills => "Skills",
        CapabilitiesTab.Tools => "Tools",
        CapabilitiesTab.Connectors => "Connectors",
        _ => "Plugins",
    };

    public static string Prompt(this CapabilitiesTab tab) => $"Search {tab.Title()}";

    public static string Id(this CapabilitiesTab tab) => tab.Title().ToLowerInvariant();
}

/// A skill's use count as the gateway sent it: null when absent or not a number, never below zero (§3.2).
public static class SkillUsage
{
    public static int? Read(JsonNode? v)
    {
        if (v is not JsonValue jv || jv.GetValueKind() != System.Text.Json.JsonValueKind.Number) return null;
        if (!double.TryParse(jv.ToJsonString(), System.Globalization.NumberStyles.Float, CultureInfo.InvariantCulture, out var d)) return null;
        if (double.IsNaN(d) || double.IsInfinity(d)) return null;
        var t = Math.Truncate(d);
        return t > int.MaxValue ? int.MaxValue : Math.Max(0, (int)t);
    }
}

public sealed record SkillInfo(string Name, string Description, string? Category, bool Enabled, int? Usage, string? Provenance)
{
    public static SkillInfo? Read(JsonNode? row)
    {
        if (row.Text("name") is not { } name) return null;
        return new(name, row.Str("description") ?? "", row.Text("category"), row.Bool("enabled") ?? true,
            SkillUsage.Read(row.Get("usage")), row.Text("provenance"));
    }
}

public sealed record OfficialSkill(string Name, string Description, string Identifier, string? Category, bool Installed);

/// One Skills Hub result (`GET /api/skills/hub/search`): where it comes from and how far Hermes trusts that source.
public sealed record HubSkill(string Name, string Description, string Identifier, string Source, string Trust, string? Repo)
{
    public bool IsCommunity => Trust != "builtin" && Trust != "trusted";

    public string TrustWord => Trust switch { "builtin" => "Built-in", "trusted" => "Trusted", _ => "Community" };

    public string SourceWord => Source switch
    {
        "official" => "Official (Nous)",
        "hermes-index" => "Hermes Index",
        "skills-sh" => "skills.sh",
        "well-known" => "Well-Known",
        "url" => "Direct URL",
        "github" => "GitHub",
        "clawhub" => "ClawHub",
        "lobehub" => "LobeHub",
        "browse-sh" => "browse.sh",
        _ => Source,
    };

    /// "Community · GitHub · owner/repo"
    public string Provenance => string.Join(" · ", new[] { TrustWord, SourceWord, Repo ?? "" }.Where(s => s.Length > 0));
}

public sealed record HubSearchResult(IReadOnlyList<HubSkill> Results, IReadOnlySet<string> Installed);

/// A background action's status (`GET /api/actions/<name>/status`).
public sealed record ActionStatus(string Name, bool Running, int? ExitCode, IReadOnlyList<string> Lines)
{
    public static ActionStatus Read(JsonNode? v, string name) => new(
        v.Text("name") ?? name, v.Bool("running") ?? false, v.Int("exit_code") is { } c ? (int)c : null,
        [.. (v.Arr("lines") ?? []).Select(l => J.AsString(l) ?? "")]);
}

/// An MCP server ("connector") of one bot: `mcp.servers.list`, with `mcp.servers.status` folded in.
public sealed record McpServer(string Name, string Transport, bool Enabled, string Source, string? Plugin)
{
    public string? Status { get; init; }
    public int? Tools { get; init; }
    public string? Auth { get; init; }
    public bool? OauthTokensPresent { get; init; }
    public string? Url { get; init; }
    public string? Command { get; init; }
    public bool HasHeaders { get; init; }

    public static McpServer? Read(JsonNode? row)
    {
        if (row.Text("name") is not { } name) return null;
        return new(name, row.Str("transport") ?? "", row.Bool("enabled") ?? true, row.Text("source") ?? "config", row.Text("plugin"))
        {
            Auth = row.Text("auth"),
            OauthTokensPresent = row.Bool("oauth_tokens_present"),
            Url = row.Text("url"),
            Command = row.Text("command"),
            HasHeaders = (row.Obj("headers")?.Count ?? 0) > 0 || row.Text("auth") == "header",
        };
    }
}

public sealed record McpTool(string Name, string Description);

public sealed record McpProbe(bool Ok, IReadOnlyList<McpTool> Tools, string? Error, bool OauthNeeded)
{
    public static McpProbe Read(JsonNode? v) => new(
        v.Bool("ok") ?? false,
        [.. (v.Arr("tools") ?? []).Select(r => r.Text("name") is { } n ? new McpTool(n, r.Str("description") ?? "") : null).OfType<McpTool>()],
        v.Text("error"), v.Bool("oauth_needed") ?? false);
}

public sealed record McpOAuthStart(string SessionId, string AuthUrl);
public sealed record McpOAuthPoll(string Status, string ErrorMessage, int Tools);

/// What saving a connector's tool rules ended as (§5.5-b: remove-then-add with one rollback).
public abstract record ToolRulesOutcome
{
    public sealed record Saved : ToolRulesOutcome;
    public sealed record Unchanged : ToolRulesOutcome;
    /// The entry is no longer in the gateway's configuration.
    public sealed record Gone : ToolRulesOutcome;
    /// The add failed and the old entry was put back.
    public sealed record RolledBack(string Reason) : ToolRulesOutcome;
    /// The add and the rollback both failed: the connector is off this bot.
    public sealed record Lost(string Reason) : ToolRulesOutcome;
}

// ---------------------------------------------------------------- Tools (§4)

public sealed record Toolset(string Name, string Label, string Description, bool Enabled, bool Configured, IReadOnlyList<string> Tools)
{
    /// `isDesktopToolsetVisible`: toolsets the desktop never lists.
    public static readonly IReadOnlySet<string> Hidden = new HashSet<string> { "discord", "discord_admin", "yuanbao", "context_engine", "moa" };

    public static Toolset? Read(JsonNode? row)
    {
        if (row.Text("name") is not { } name) return null;
        return new(name, StripLabel(row.Text("label") ?? name), row.Str("description") ?? "", row.Bool("enabled") ?? false,
            row.Bool("configured") ?? true, [.. (row.Arr("tools") ?? []).Select(t => t is JsonValue jv && jv.TryGetValue(out string? s) ? s : null).OfType<string>()]);
    }

    /// `stripToolsetLabel`: leading emoji and spaces removed; if that leaves nothing the label stays as sent.
    public static string StripLabel(string label)
    {
        var e = StringInfo.GetTextElementEnumerator(label);
        var cut = 0;
        while (e.MoveNext())
        {
            var el = (string)e.Current;
            if (!IsEmojiOrSpace(el)) break;
            cut = e.ElementIndex + el.Length;
        }
        var rest = label[cut..];
        return rest.Length == 0 ? label : rest;
    }

    private static bool IsEmojiOrSpace(string element)
    {
        foreach (var r in element.EnumerateRunes())
        {
            var v = r.Value;
            if (Rune.IsWhiteSpace(r) || v == 0xFE0F || v == 0x200D) continue;
            // Digits, # and * are \p{Emoji} in JS too.
            if (v is >= '0' and <= '9' || v == '#' || v == '*') continue;
            if (v >= 0x1F000 || v is >= 0x2600 and <= 0x27BF || v is >= 0x2190 and <= 0x21FF || v is >= 0x2B00 and <= 0x2BFF
                || v is >= 0x2300 and <= 0x23FF || v == 0x00A9 || v == 0x00AE || v is >= 0x1F1E6 and <= 0x1F1FF || v is 0x203C or 0x2049)
                continue;
            return false;
        }
        return true;
    }

    /// The web's `compact`: 999 → "999", 1 200 → "1.2K", 12 400 → "12K", 1 500 000 → "1.5M". Never "NaN".
    public static string Compact(long count)
    {
        var n = Math.Max(0, count);
        static string Short(double value, string unit)
        {
            var rounded = Math.Round(value * 10, MidpointRounding.AwayFromZero) / 10;
            return (value < 10 && rounded != Math.Round(rounded)
                ? rounded.ToString("0.0", CultureInfo.InvariantCulture)
                : ((long)Math.Round(value, MidpointRounding.AwayFromZero)).ToString(CultureInfo.InvariantCulture)) + unit;
        }
        if (n < 1000) return n.ToString(CultureInfo.InvariantCulture);
        if (n < 1_000_000) return Short(n / 1000.0, "K");
        if (n < 1_000_000_000) return Short(n / 1_000_000.0, "M");
        return Short(n / 1_000_000_000.0, "B");
    }
}

public sealed record ToolEnvVar(string Key, string Prompt, string? Url, string? Placeholder, bool IsSet);

public sealed record ToolProvider(string Name, string Badge, string Tag, bool IsActive, string? Status, string? PostSetup,
    IReadOnlyList<ToolEnvVar> EnvVars, string? WebBackend, IReadOnlyList<string> Capabilities)
{
    /// "Ready" / "Needs keys" / "Setup required" / "Needs sign-in"; null for an older gateway that sends no status.
    public string? StatusWord => Status switch
    {
        "ready" => "Ready",
        "needs_keys" => "Needs keys",
        "needs_setup" => "Setup required",
        "needs_auth" => "Needs sign-in",
        _ => null,
    };
}

public sealed record ToolsetConfig(bool HasCategory, IReadOnlyList<ToolProvider> Providers, string? SearchBackend, string? ExtractBackend)
{
    public static ToolsetConfig Read(JsonNode? v)
    {
        var providers = new List<ToolProvider>();
        foreach (var row in v.Arr("providers") ?? [])
        {
            if (row.Text("name") is not { } name) continue;
            var vars = new List<ToolEnvVar>();
            foreach (var item in row.Arr("env_vars") ?? [])
            {
                if (item.Text("key") is not { } key) continue;
                var url = item.Text("url") is { } u && u.StartsWith("https://", StringComparison.OrdinalIgnoreCase) ? u : null;
                // A default that looks like a credential is never shown, even as a placeholder.
                var hint = item.Text("default") is { } d && McpEntryMask.Phone.Text(d) == d ? d : null;
                vars.Add(new(key, item.Text("prompt") ?? key, url, hint, item.Bool("is_set") ?? false));
            }
            providers.Add(new(name, row.Str("badge") ?? "", row.Str("tag") ?? "", row.Bool("is_active") ?? false, row.Text("status"),
                row.Text("post_setup"), vars, row.Text("web_backend"),
                [.. (row.Arr("capabilities") ?? []).Select(J.AsString).OfType<string>()]));
        }
        return new(v.Bool("has_category") ?? false, providers, v.Text("active_search_backend"), v.Text("active_extract_backend"));
    }
}

public sealed record ToolModel(string Id, string Display, string Caption);

public sealed record ToolModels(string Provider, string? Current, string? Fallback, IReadOnlyList<ToolModel> Models)
{
    public static ToolModels? Read(JsonNode? v)
    {
        if (v.Bool("has_models") != true) return null;
        var models = new List<ToolModel>();
        foreach (var row in v.Arr("models") ?? [])
        {
            if (row.Text("id") is not { } id) continue;
            var parts = new[] { "speed", "strengths", "price" }.Select(k => row.Text(k)).OfType<string>();
            models.Add(new(id, row.Text("display") ?? id, string.Join(" · ", parts)));
        }
        return models.Count == 0 ? null : new(v.Str("provider") ?? "", v.Text("current"), v.Text("default"), models);
    }
}

public sealed record TerminalBackend(string Name, string Label, string Description, bool Active, string Status, string Detail)
{
    public bool IsReady => Status == "ready";
}

// ---------------------------------------------------------------- Plugins (§9)

public sealed record PluginServerState(string Name, string State, string Sentence)
{
    /// The gateway's own sentence when it sent one, else the state in words.
    public string? Words
    {
        get
        {
            if (State == "connected") return null;
            if (Sentence.Length > 0) return Sentence;
            return State switch
            {
                "app_not_running" => "App not running",
                "hermes_not_connected" => "Connection missing",
                "endpoint_unavailable" => "Not reachable",
                "no_interactive_session" => "No session",
                "version_too_old" => "Version too old",
                "missing_app" => "App missing",
                "unsupported_gpu" => "This computer’s graphics can’t run it",
                _ => "Status unknown",
            };
        }
    }
}

public sealed record PluginField(string Key, string Type, string Label, string Description, bool Required, JsonNode? Value,
    JsonNode? Fallback, IReadOnlyList<string> Choices, string? Env, bool HasValue)
{
    public static readonly IReadOnlySet<string> Known = new HashSet<string> { "string", "number", "boolean", "enum", "secret", "json" };
}

public sealed record PluginInfo(string Name, string? Key, string Version, string Description, string Source, bool Enabled,
    bool HasDesktopHalf, IReadOnlyList<PluginServerState> Servers, bool UpdateAvailable, string? CatalogVersion, string? CatalogSha,
    IReadOnlyList<PluginField> Schema)
{
    /// The Hermes catalog entry it was installed from (`catalog_name`); null for every other source.
    public string? CatalogName { get; init; }
    /// What a Git install's update moves to (`update_target`: a commit, or a feed's version).
    public string? UpdateTarget { get; init; }

    /// The version an update brings, as words: the catalog's version, else a short commit.
    public string? NewVersion
    {
        get
        {
            if (CatalogVersion != null) return CatalogVersion;
            if ((CatalogSha ?? UpdateTarget) is not { } target) return null;
            var hex = target.Length >= 12 && target.All(Uri.IsHexDigit);
            return hex ? target[..7] : target;
        }
    }

    public bool IsKanban => Name == "kanban";
    public bool CanUninstall => Source is "user" or "git";
    /// The name as Marketplace shows it ("Weather Now" for weather-now).
    public string Title => DisplayName.Title(Name);

    public string? SourceWords => Source switch
    {
        "bundled" => "Comes with Hermes",
        "catalog" => "From the Hermes catalog",
        "git" => "Installed from Git",
        "user" => "Installed by hand",
        _ => null,
    };

    public static PluginInfo? Read(JsonNode? row)
    {
        if (row.Text("name") is not { } name) return null;
        var schema = new List<PluginField>();
        foreach (var f in row.Arr("settings_schema") ?? [])
        {
            if (f.Text("key") is not { } key) continue;
            schema.Add(new(key, f.Text("type") ?? "string", f.Text("label") ?? key, f.Str("description") ?? "", f.Bool("required") ?? false,
                f.Get("value")?.DeepClone(), f.Get("default")?.DeepClone(),
                [.. (f.Arr("choices") ?? []).Select(J.AsString).OfType<string>()], f.Text("env"), f.Bool("has_value") ?? false));
        }
        var servers = (row.Arr("servers") ?? []).Select(s => s.Text("name") is { } n
            ? new PluginServerState(n, s.Text("state") ?? "unknown", s.Str("sentence") ?? "") : null).OfType<PluginServerState>().ToList();
        return new(name, row.Text("key"), row.Str("version") ?? "", row.Str("description") ?? "", row.Text("source") ?? "",
            row.Text("status") == "enabled", row.Bool("has_desktop_half") ?? false, servers, row.Bool("update_available") ?? false,
            row.Text("catalog_version"), row.Text("catalog_sha"), schema)
        {
            CatalogName = row.Text("catalog_name"),
            UpdateTarget = row.Text("update_target"),
        };
    }
}

/// One `plugins.manage` call. Which params each action takes is fixed here so a wrong combination cannot be built.
public abstract record PluginAction
{
    public sealed record Toggle(string Key, bool Enable) : PluginAction;
    /// `Force`: apply it though Hermes's security scan said "caution".
    public sealed record Update(string Name, bool Accept, bool Force = false) : PluginAction;
    public sealed record Remove(string Name) : PluginAction;
    public sealed record Install(string Identifier, bool Force, bool Enable, string? Ref) : PluginAction;
    /// A Hermes catalog plugin by its catalog name: Hermes installs the commit Nous reviewed.
    public sealed record InstallCatalog(string Name, bool Enable) : PluginAction;
    public sealed record Settings(string Key, JsonObject Values) : PluginAction;

    public JsonObject Params(string profile)
    {
        var o = new JsonObject { ["profile"] = profile };
        switch (this)
        {
            case Toggle t: o["action"] = "toggle"; o["key"] = t.Key; o["enable"] = t.Enable; break;
            case Update u:
                o["action"] = "update"; o["name"] = u.Name;
                if (u.Accept) o["accept_capabilities"] = true;
                if (u.Force) o["force"] = true;
                break;
            case Remove r: o["action"] = "remove"; o["name"] = r.Name; break;
            case Install i:
                o["action"] = "install"; o["identifier"] = i.Identifier; o["force"] = i.Force; o["enable"] = i.Enable;
                if (!string.IsNullOrEmpty(i.Ref)) o["ref"] = i.Ref;
                break;
            case InstallCatalog c: o["action"] = "install"; o["catalog_name"] = c.Name; o["enable"] = c.Enable; break;
            case Settings s: o["action"] = "settings"; o["key"] = s.Key; o["values"] = s.Values.DeepClone(); break;
        }
        return o;
    }

    public TimeSpan Timeout => this is Install or InstallCatalog ? TimeSpan.FromSeconds(120) : TimeSpan.FromSeconds(60);
}

public sealed record PluginResult(bool Ok, string? Name, bool RestartRequired, bool GatewayReloaded, IReadOnlyList<string> MissingEnv,
    IReadOnlyList<string> Warnings, bool ConsentRequired, IReadOnlyList<string> DeltaLines, bool ScanBlocked, bool Unchanged,
    string? ScanVerdict, IReadOnlyList<string> ScanFindings)
{
    public bool NeedsRestart => RestartRequired && !GatewayReloaded;

    private static List<string> Strings(JsonNode? v, string key) => [.. (v.Arr(key) ?? []).Select(J.AsString).OfType<string>()];

    public static PluginResult Read(JsonNode? v) => new(
        v.Bool("ok") ?? false, v.Text("plugin_name") ?? v.Text("name"), v.Bool("restart_required") ?? false,
        v.Bool("gateway_reloaded") ?? false, Strings(v, "missing_env"), Strings(v, "warnings"), v.Bool("consent_required") ?? false,
        Strings(v, "delta_lines"), v.Bool("scan_blocked") ?? false, v.Bool("unchanged") ?? false, v.Text("scan_verdict"),
        [.. (v.Arr("scan_findings") ?? []).Select(f =>
        {
            var what = f.Text("description") ?? f.Text("category");
            if (what == null) return null;
            return f.Text("file") is { } file ? $"{what} ({file})" : what;
        }).OfType<string>()]);
}

/// Names as titles (HermesKit/Settings/DisplayName.swift). Text that already has capitals or spaces is kept.
public static class DisplayName
{
    public static readonly IReadOnlyDictionary<string, string> Words = new Dictionary<string, string>
    {
        ["ai"] = "AI", ["api"] = "API", ["aws"] = "AWS", ["cli"] = "CLI", ["css"] = "CSS", ["csv"] = "CSV", ["db"] = "DB", ["gcp"] = "GCP",
        ["hq"] = "HQ", ["html"] = "HTML", ["http"] = "HTTP", ["id"] = "ID", ["ios"] = "iOS", ["js"] = "JS", ["json"] = "JSON", ["llm"] = "LLM",
        ["macos"] = "macOS", ["mcp"] = "MCP", ["ocr"] = "OCR", ["pdf"] = "PDF", ["pr"] = "PR", ["prs"] = "PRs", ["rss"] = "RSS", ["sdk"] = "SDK",
        ["seo"] = "SEO", ["sms"] = "SMS", ["sql"] = "SQL", ["ssh"] = "SSH", ["stt"] = "STT", ["svg"] = "SVG", ["tts"] = "TTS", ["ts"] = "TS",
        ["ui"] = "UI", ["url"] = "URL", ["ux"] = "UX", ["xml"] = "XML", ["yaml"] = "YAML",
        ["github"] = "GitHub", ["gitlab"] = "GitLab", ["openai"] = "OpenAI", ["openrouter"] = "OpenRouter", ["youtube"] = "YouTube",
        ["linkedin"] = "LinkedIn", ["imessage"] = "iMessage", ["iphone"] = "iPhone", ["ipad"] = "iPad", ["whatsapp"] = "WhatsApp",
        ["elevenlabs"] = "ElevenLabs", ["deepseek"] = "DeepSeek", ["hubspot"] = "HubSpot", ["clickup"] = "ClickUp", ["posthog"] = "PostHog",
        ["pagerduty"] = "PagerDuty", ["tiktok"] = "TikTok", ["wordpress"] = "WordPress", ["xai"] = "xAI", ["arxiv"] = "arXiv",
        ["duckduckgo"] = "DuckDuckGo", ["searxng"] = "SearXNG", ["chatgpt"] = "ChatGPT", ["gpt"] = "GPT", ["mysql"] = "MySQL",
        ["postgresql"] = "PostgreSQL", ["sqlite"] = "SQLite", ["graphql"] = "GraphQL", ["javascript"] = "JavaScript",
        ["typescript"] = "TypeScript", ["icloud"] = "iCloud", ["applescript"] = "AppleScript", ["mongodb"] = "MongoDB",
        ["huggingface"] = "Hugging Face", ["lmstudio"] = "LM Studio", ["pypi"] = "PyPI", ["npm"] = "npm", ["fal"] = "FAL",
        ["macbook"] = "MacBook", ["imap"] = "IMAP", ["smtp"] = "SMTP", ["oauth"] = "OAuth", ["jira"] = "Jira", ["nous"] = "Nous",
    };

    public static string Title(string id)
    {
        var text = id.Trim();
        if (text.Length == 0 || text != text.ToLowerInvariant() || text.Contains(' ')) return text;
        var parts = text.Split(['-', '_'], StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0) return text;
        return string.Join(" ", parts.Select(p => Words.TryGetValue(p, out var w) ? w : char.ToUpperInvariant(p[0]) + p[1..]));
    }
}

/// Install from Git's address and pin rules (PluginsSections.swift `PluginRepo`).
public static class PluginRepo
{
    public enum Check { Empty, Ok, Insecure, Invalid }

    public static Check CheckRepo(string raw)
    {
        var value = raw.Trim();
        if (value.Length == 0) return Check.Empty;
        if (value.Length > 500 || value.StartsWith('-') || value.Any(c => char.IsWhiteSpace(c) || c < 0x20 || c == 0x7F)) return Check.Invalid;
        if (value.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            return Uri.TryCreate(value, UriKind.Absolute, out var u) && u.Host.Length > 0 ? Check.Ok : Check.Invalid;
        if (System.Text.RegularExpressions.Regex.IsMatch(value, @"^git@[A-Za-z0-9.-]+:[\w.~/-]+$", System.Text.RegularExpressions.RegexOptions.ECMAScript)) return Check.Ok;
        if (System.Text.RegularExpressions.Regex.IsMatch(value, "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")) return Check.Ok;
        if (System.Text.RegularExpressions.Regex.IsMatch(value, "^[a-z][a-z0-9+.-]*:", System.Text.RegularExpressions.RegexOptions.IgnoreCase)) return Check.Insecure;
        return Check.Invalid;
    }

    public static bool RefValid(string raw)
    {
        var v = raw.Trim();
        return v.Length == 0 || System.Text.RegularExpressions.Regex.IsMatch(v, "^[0-9a-fA-F]{40}$");
    }
}
