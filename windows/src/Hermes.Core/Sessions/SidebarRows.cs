using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Bots;

namespace Hermes.Core.Sessions;

// Sessions tab data (spec 02 §9): the sidebar answer, its rows, the client-side filters, row words and unread rules.
// Port of HermesKit/Model/RosterSessions.swift and the row words of SessionListPipeline.swift.

/// One session row of `GET /api/profiles/sessions/sidebar`. Times are unix seconds.
public sealed record SidebarSessionRow
{
    public required string Id { get; init; }
    public required string Profile { get; init; }
    public string? Title { get; init; }
    public string? Preview { get; init; }
    public string? Source { get; init; }
    public double? StartedAt { get; init; }
    public double? LastActive { get; init; }
    public long? MessageCount { get; init; }
    public long? ToolCallCount { get; init; }
    public string? Model { get; init; }
    public string? Cwd { get; init; }
    public bool? Archived { get; init; }
    public bool? Pinned { get; init; }
    /// Server read watermark (`last_active > last_read_at`).
    public bool? Unread { get; init; }
    public double? LastReadAt { get; init; }
    public bool? Hidden { get; init; }
    public long? InputTokens { get; init; }
    public long? OutputTokens { get; init; }
    public double? ActualCostUsd { get; init; }
    public double? EstimatedCostUsd { get; init; }
    public string? GitBranch { get; init; }
    public string? HandoffPlatform { get; init; }
    public string? UserId { get; init; }
    public string? ParentSessionId { get; init; }

    public static SidebarSessionRow? From(JsonNode? json)
    {
        if (json is not JsonObject o || RosterText.Trimmed(o["id"]) is not { } id) return null;
        static double? Amount(JsonNode? n) => RosterText.Number(n) is { } d && d >= 0 ? d : null;
        static long? Positive(JsonNode? n) => RosterText.Count(n) is { } c && c >= 0 ? c : null;
        return new SidebarSessionRow
        {
            Id = id,
            Title = o["title"] is null ? null : RosterText.Text(o["title"]),
            Preview = o["preview"] is null ? null : RosterText.Text(o["preview"]),
            Source = RosterText.Trimmed(o["source"]),
            StartedAt = RosterText.Number(o["started_at"]),
            LastActive = RosterText.Number(o["last_active"]),
            MessageCount = RosterText.Count(o["message_count"]),
            ToolCallCount = RosterText.Count(o["tool_call_count"]),
            Model = RosterText.Trimmed(o["model"]),
            Cwd = RosterText.Trimmed(o["cwd"]),
            Profile = RosterText.Trimmed(o["profile"]) ?? RosterText.Trimmed(o["profile_name"]) ?? "default",
            Archived = RosterText.Bool(o["archived"]),
            Pinned = RosterText.Bool(o["pinned"]),
            Unread = RosterText.Bool(o["unread"]),
            LastReadAt = Amount(o["last_read_at"]),
            Hidden = RosterText.Bool(o["hidden"]),
            InputTokens = Positive(o["input_tokens"]),
            OutputTokens = Positive(o["output_tokens"]),
            ActualCostUsd = Amount(o["actual_cost_usd"]),
            EstimatedCostUsd = Amount(o["estimated_cost_usd"]),
            GitBranch = RosterText.Trimmed(o["git_branch"]),
            HandoffPlatform = RosterText.Trimmed(o["handoff_platform"]),
            UserId = RosterText.Trimmed(o["user_id"]),
            ParentSessionId = RosterText.Trimmed(o["parent_session_id"]),
        };
    }

    public long TotalTokens => (InputTokens ?? 0) + (OutputTokens ?? 0);
    public double CostUsd => ActualCostUsd ?? EstimatedCostUsd ?? 0;
    /// `last_active || started_at`.
    public double Recency => (LastActive ?? 0) > 0 ? LastActive!.Value : StartedAt ?? 0;
    public string WriteKey => Profile + "\u0000" + Id;
}

/// A decoded sidebar answer. A slice whose scan failed comes back without `sessions`: Retry, never "No sessions".
public sealed record SidebarPayload(List<SidebarSessionRow>? Recents, List<SidebarSessionRow>? Cron,
    List<SidebarSessionRow>? Messaging, IReadOnlyList<string> FailedProfiles)
{
    public static SidebarPayload Decode(JsonNode? json)
    {
        if (json is not JsonObject root) throw new Net.GatewayException("not-hermes", "The gateway's sessions list was not readable.");
        List<SidebarSessionRow>? Slice(string key) => root[key] is JsonObject o && o["sessions"] is JsonArray rows
            ? rows.Select(SidebarSessionRow.From).OfType<SidebarSessionRow>().ToList() : null;
        var failed = (root["errors"] as JsonArray ?? []).Select(e => RosterText.Trimmed(e?["profile"])).OfType<string>().ToList();
        return new SidebarPayload(Slice("recents"), Slice("cron"), Slice("messaging"), failed);
    }
}

public static class ChatSource
{
    public static readonly HashSet<string> Messaging = ["telegram", "discord", "slack", "mattermost", "matrix", "signal", "whatsapp",
        "bluebubbles", "photon", "homeassistant", "email", "sms", "webhook", "api_server", "weixin", "wecom", "qqbot",
        "yuanbao", "dingtalk", "feishu"];

    public static string Id(string? source) => (source ?? "").Trim().ToLowerInvariant();
    public static bool IsMessaging(string? source) => Messaging.Contains(Id(source));
}

public static class SessionRules
{
    /// Sources a bot runs on its own; hidden from the list unless Show › Background Runs.
    public static readonly HashSet<string> RunSources = ["tool", "oneshot", "subagent", "kanban"];

    public static bool IsBackgroundRun(SidebarSessionRow row) => RunSources.Contains(row.Source ?? "") || IsProbe(row);

    private const string ProbeLead = @"^(?i:(?:do not|don't) (?:use|call) (?:any )?tools?[.,;:!]?\s+)?(?i:please\s+)?"
        + @"(?i:reply|respond|answer|say|return|output|print)(?i: with)?";
    private static readonly Regex ProbeToken = new(ProbeLead + @"(?i: exactly| only| just)?:?\s+[""'`]?[A-Z][A-Z0-9_]{1,40}[""'`]?[.!]?$");
    private static readonly Regex ProbeExactly = new(ProbeLead + @" (?i:exactly)\b.{0,60}$");

    /// A script's check that the gateway answers ("Reply with exactly ROUTE_OK."): hidden like a run.
    public static bool IsProbe(SidebarSessionRow row)
    {
        var source = ChatSource.Id(row.Source);
        if (source == "desktop" || ChatSource.IsMessaging(source) || (row.ToolCallCount ?? 0) != 0 || (row.MessageCount ?? 0) > 6) return false;
        if (row.Preview?.Trim() is not { Length: <= 160 } first) return false;
        return ProbeToken.IsMatch(first) || ProbeExactly.IsMatch(first);
    }

    /// Bot Chats never show on Sessions (§9.2): the gateway hides them; a row that still says so is dropped.
    public static bool IsBotChat(SidebarSessionRow row)
    {
        var title = row.Title?.Trim() ?? "";
        return row.Hidden == true || title == RosterRules.BotChatTitle || title.StartsWith("Group: ");
    }

    private static readonly Regex MarkupOnly = new(@"^<[\w:-]+>\s*[{\[<]");
    private static readonly Regex WhitespaceRun = new(@"\s+");
    private static readonly Regex ProfileSlug = new("^[a-z0-9][a-z0-9_-]*$");

    private static string Words(string? text)
    {
        var t = (text ?? "").Trim();
        return MarkupOnly.IsMatch(t) ? "" : t;
    }

    /// A row's title: title, else preview, else "Untitled Chat"; a model-switch note reworded.
    public static string Title(SidebarSessionRow row)
    {
        var b = Words(row.Title);
        if (b.Length == 0) b = Words(row.Preview);
        if (b.Length == 0) b = "Untitled Chat";
        var shown = RosterPreview.RowPreview(b);
        return shown.Length == 0 ? "Untitled Chat" : shown;
    }

    public static string? PreviewOf(SidebarSessionRow row)
    {
        var line = WhitespaceRun.Replace(RosterPreview.RowPreview(row.Preview), " ").Trim();
        return line.Length == 0 ? null : line;
    }

    public static string ReadableProfileName(string label)
    {
        var t = label.Trim();
        return ProfileSlug.IsMatch(t) ? RosterRules.TitleCase(t) : t;
    }

    /// The owner bot's name on a Sessions row.
    public static string OwnerName(string profile, IReadOnlyDictionary<string, string> displayNames)
    {
        var id = profile.Trim();
        if (displayNames.TryGetValue(id, out var shown) && RosterText.NonBlank(shown) is { } s) return s;
        if (id.Length == 0 || id == "default") return "Hermes";
        return ReadableProfileName(id);
    }

    /// "main · hermes-4 · 2 messages · 1 tool call".
    public static string Metadata(string? branch, string? model, long? messages, long? toolCalls)
    {
        var parts = new List<string>();
        if (branch?.Trim() is { Length: > 0 } b) parts.Add(b);
        if (model?.Trim() is { Length: > 0 } m && m.Split('/').Last() is { Length: > 0 } last) parts.Add(last);
        if (messages is > 0) parts.Add(messages == 1 ? "1 message" : $"{messages} messages");
        if (toolCalls is > 0) parts.Add(toolCalls == 1 ? "1 tool call" : $"{toolCalls} tool calls");
        return string.Join(" · ", parts);
    }
}

/// The row's words (SessionRowWords).
public static class SessionRowWords
{
    public static string ShowMoreLabel(int more) => more > 0 ? $"Show {more} more {(more == 1 ? "chat" : "chats")}" : "Show fewer chats";

    public static string? CompactTokens(long value)
    {
        if (value <= 0) return null;
        static string Scaled(double v, string suffix)
        {
            var text = v.ToString("0.0", CultureInfo.InvariantCulture);
            if (text.EndsWith(".0")) text = text[..^2];
            return text + suffix;
        }
        if (value >= 999_950) return Scaled(value / 1_000_000.0, "M");
        if (value >= 1000) return Scaled(value / 1_000.0, "k");
        return value.ToString(CultureInfo.InvariantCulture);
    }

    public static string? Cost(double value) =>
        double.IsFinite(value) && value >= 0.01 ? "$" + value.ToString("0.00", CultureInfo.InvariantCulture) : null;

    /// Tokens · Cost · time, as Row Detail asks.
    public static string? Trailing(SessionSummary s, IReadOnlySet<SessionRowDetail> detail, string time)
    {
        var parts = new List<string>();
        if (detail.Contains(SessionRowDetail.Tokens) && CompactTokens(s.Tokens) is { } t) parts.Add(t);
        if (detail.Contains(SessionRowDetail.Cost) && Cost(s.Cost) is { } c) parts.Add(c);
        if (detail.Contains(SessionRowDetail.Time) && time.Length > 0) parts.Add(time);
        return parts.Count == 0 ? null : string.Join(" · ", parts);
    }

    public static string? StatusWords(SessionStatus status, string? step = null) => status switch
    {
        SessionStatus.NeedsInput => "Needs your input",
        SessionStatus.Working => step ?? "Working…",
        _ => null,
    };

    /// The second line: live status, the pending line ("Not Delivered: …", "Draft: …"), the preview (Row Detail ›
    /// Preview), else the metadata (93f984bb1 SessionListPipeline.swift `detailText`).
    public static string? DetailText(SessionSummary s, IReadOnlySet<SessionRowDetail> detail)
    {
        if (StatusWords(s.Status, s.Step) is { } words) return words;
        if (s.Pending is { } pending) return pending.Prefix + " " + pending.Text;
        var titled = s.Title.Trim().Length > 0;
        if (detail.Contains(SessionRowDetail.Preview) && titled && RosterPreview.CleanPreviewText(s.Preview) is { Length: > 0 } p) return p;
        return s.Metadata.Length == 0 ? null : s.Metadata;
    }

    public static string AccessibilityLabel(string title, SessionSummary s, string ownerName, IReadOnlySet<SessionRowDetail> detail,
        string time, bool muted = false)
    {
        var parts = new List<string> { title };
        var status = StatusWords(s.Status, s.Step);
        if (status != null) parts.Add(status.Replace("…", ""));
        var body = status != null ? null : DetailText(s, detail);
        parts.Add(body is null ? ownerName : $"{ownerName}: {body}");
        if (detail.Contains(SessionRowDetail.Tokens) && CompactTokens(s.Tokens) is { } t) parts.Add($"{t} tokens");
        if (detail.Contains(SessionRowDetail.Cost) && Cost(s.Cost) is { } c) parts.Add(c);
        if (detail.Contains(SessionRowDetail.Time) && time.Length > 0) parts.Add(time);
        if (s.Unread) parts.Add("Unread");
        if (s.Pinned) parts.Add("Pinned"); else if (s.ProjectPinned) parts.Add("Pinned in project");
        if (s.Archived) parts.Add("Archived");
        if (muted) parts.Add("Muted");
        return string.Join(". ", parts);
    }
}

/// Device-local unread state for listed sessions (spec 02 §9.3): "seen" watermarks seeded on first sight, explicit
/// markers, and rows cleared locally without a server write.
public sealed class SessionUnreadState
{
    /// Profile → session id → the `message_count` this device has seen.
    public Dictionary<string, Dictionary<string, long>> Seen { get; set; } = [];
    /// Profile → explicitly unread ids.
    public Dictionary<string, List<string>> Markers { get; set; } = [];
    /// Session id → `last_active` when the dot was cleared here only.
    public Dictionary<string, double> LocalReads { get; set; } = [];

    public const int MaxSeenPerProfile = 2000;

    public void Observe(IReadOnlyList<SidebarSessionRow> rows)
    {
        foreach (var row in rows)
        {
            if (row.MessageCount is not { } count) continue;
            if (!Seen.TryGetValue(row.Profile, out var map)) Seen[row.Profile] = map = [];
            map.TryAdd(row.Id, count);
        }
        foreach (var (profile, map) in Seen.ToList())
        {
            if (map.Count <= MaxSeenPerProfile) continue;
            var live = rows.Where(r => r.Profile == profile).Select(r => r.Id).ToHashSet();
            Seen[profile] = map.Where(kv => live.Contains(kv.Key)).ToDictionary(kv => kv.Key, kv => kv.Value);
        }
    }

    private bool Marked(SidebarSessionRow row) => Markers.TryGetValue(row.Profile, out var b) && b.Contains(row.Id);

    /// Unread when the server says so, an explicit marker exists, or (non-messaging rows) the stored count passed the
    /// seen watermark. A running turn's stored steps don't make it unread; the chat on screen has nothing unread.
    public bool IsUnread(SidebarSessionRow row, bool messaging = false, bool selected = false, bool running = false, bool onScreen = false)
    {
        if (onScreen && row.LastReadAt != 0 && !Marked(row)) return false;
        if (!selected && Marked(row)) return true;
        if (messaging || running) return false;
        var server = row.Unread ?? false;
        if (server && LocalReads.TryGetValue(row.Id, out var cleared) && (row.LastActive ?? 0) <= cleared) server = false;
        if (server) return true;
        if (selected) return false;
        return row.MessageCount is { } count && Seen.TryGetValue(row.Profile, out var map)
            && map.TryGetValue(row.Id, out var watermark) && count > watermark;
    }

    /// Opening a row clears its local state.
    public void Opened(SidebarSessionRow row, bool clearServerLocally)
    {
        if (row.MessageCount is { } count)
        {
            if (!Seen.TryGetValue(row.Profile, out var map)) Seen[row.Profile] = map = [];
            map[row.Id] = count;
        }
        if (Markers.TryGetValue(row.Profile, out var bucket))
        {
            bucket.Remove(row.Id);
            if (bucket.Count == 0) Markers.Remove(row.Profile);
        }
        if (clearServerLocally) LocalReads[row.Id] = row.LastActive ?? 0;
    }

    public void Mark(SidebarSessionRow row)
    {
        if (!Markers.TryGetValue(row.Profile, out var bucket)) Markers[row.Profile] = bucket = [];
        if (!bucket.Contains(row.Id)) bucket.Add(row.Id);
    }
}

/// One row of Chat Info (was Session Info): label, value, the note under it, monospaced, the text Copy gives.
public sealed record ChatInfoRow(string Label, string Value, string? Note = null, bool Mono = false);

/// Chat Info's rows from what the list holds (docs/spec/3x-sessions.md §10.1, the stored row's half: Model, Tokens,
/// Cost, Messages, Folder, Bot, Source, Gateway, Chat ID; the live half, Answered By, Reasoning and Context, comes with
/// the chat's own state). Each row only when it has a value.
public static class ChatInfoRows
{
    public const string Title = "Chat Info";
    public const string CopyAll = "Copy Chat Info";

    /// Below 1,000 as is; then one decimal with a capital K ("15.4K", "200K"); from a million with M ("1.5M").
    public static string Count(long n)
    {
        static string One(double v) => v.ToString("0.#", System.Globalization.CultureInfo.InvariantCulture);
        if (n < 1000) return n.ToString(System.Globalization.CultureInfo.InvariantCulture);
        if (n < 1_000_000) return One(n / 1000.0) + "K";
        return One(n / 1_000_000.0) + "M";
    }

    /// "$0.34"; four decimals below a cent ("$0.0042"); null at zero.
    public static string? CostWords(double usd) => usd <= 0 || !double.IsFinite(usd) ? null
        : "$" + usd.ToString(usd < 0.01 ? "0.0000" : "0.00", System.Globalization.CultureInfo.InvariantCulture);

    private static readonly Dictionary<string, string> SourceNames = new()
    {
        ["telegram"] = "Telegram", ["discord"] = "Discord", ["slack"] = "Slack", ["whatsapp"] = "WhatsApp", ["signal"] = "Signal",
        ["imessage"] = "iMessage", ["sms"] = "SMS", ["email"] = "Email", ["matrix"] = "Matrix", ["mattermost"] = "Mattermost",
        ["teams"] = "Microsoft Teams", ["cron"] = "Scheduled job", ["cli"] = "Terminal", ["oneshot"] = "One-off run",
        ["subagent"] = "Subagent", ["webhook"] = "Webhook", ["api"] = "API", ["tool"] = "Tool",
    };
    private static readonly HashSet<string> Silent = ["", "desktop", "dispatch", "tui", "ios", "app"];

    public static string? SourceName(string? source)
    {
        var id = ChatSource.Id(source);
        if (Silent.Contains(id)) return null;
        if (SourceNames.TryGetValue(id, out var known)) return known;
        var spaced = id.Replace('-', ' ').Replace('_', ' ');
        return char.ToUpperInvariant(spaced[0]) + spaced[1..];
    }

    public static List<ChatInfoRow> Rows(SidebarSessionRow row, string botName, string gatewayHost, string gatewayState)
    {
        var o = new List<ChatInfoRow>();
        if (row.Model is { } model) o.Add(new("Model", model.Split('/').Last()));
        if (row.TotalTokens > 0)
            o.Add(new("Tokens", Count(row.TotalTokens), $"{Count(row.InputTokens ?? 0)} in · {Count(row.OutputTokens ?? 0)} out"));
        if (CostWords(row.CostUsd) is { } cost) o.Add(new("Cost", cost, row.ActualCostUsd == null ? "Estimated" : null));
        if (row.MessageCount is { } m) o.Add(new("Messages", m.ToString(System.Globalization.CultureInfo.InvariantCulture)));
        if (row.Cwd is { } cwd) o.Add(new("Folder", cwd, row.GitBranch, true));
        o.Add(new("Bot", botName));
        if (SourceName(row.HandoffPlatform ?? row.Source) is { } source) o.Add(new("Source", source));
        o.Add(new("Gateway", gatewayHost, gatewayState));
        if (!string.IsNullOrWhiteSpace(row.Id)) o.Add(new("Chat ID", row.Id, null, true));   // only with an id, as the Mac's
        return o;
    }

    /// Every row as `Label: value (note)`, with the raw ids: the Bot row as `Bot: Bike Shop (bike-shop)` when its name
    /// differs from the profile id (SessionInfoRows' `copy`).
    public static string CopyText(IEnumerable<ChatInfoRow> rows, string? profile = null) => string.Join("\n", rows.Select(r =>
        r.Label == "Bot" && profile != null && r.Value != profile ? $"Bot: {r.Value} ({profile})"
            : r.Note is { } n ? $"{r.Label}: {r.Value} ({n})" : $"{r.Label}: {r.Value}"));
}
