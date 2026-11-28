using System.Text.Json.Nodes;
using Hermes.Core.Capabilities;
using Hermes.Core.Net;

namespace Hermes.Core.Settings;

/// [proactivity-beta] Wire contract and constants for the optional `hermes-hq-proactive` Beta plugin
/// (HermesKit/Plugins/ProactivityBeta.swift, commits b446e2abf & 6bedd2ea3).
/// Off by default on the gateway; toggling it calls `PATCH /api/plugins/hermes-hq-proactive/settings`.
public static class ProactivityBeta
{
    public const string PluginName = "hermes-hq-proactive";
    public const string PluginSource = "mrcharlesiv/hermes-hq-plugins/hermes-hq-proactive";
    public const string PageLabel = "Proactivity (Beta)";
    public const string Route = "/api/plugins/hermes-hq-proactive";
}

/// Autonomy tier for Proactivity (Beta) (`ProactivityBeta.AutonomyMode`).
public enum AutonomyMode
{
    Observe,
    Prep,
    Full,
}

public static class AutonomyModes
{
    public static readonly AutonomyMode[] All = [AutonomyMode.Observe, AutonomyMode.Prep, AutonomyMode.Full];

    public static string Raw(this AutonomyMode mode) => mode switch
    {
        AutonomyMode.Observe => "observe",
        AutonomyMode.Full => "full",
        _ => "prep",
    };

    public static string Title(this AutonomyMode mode) => mode switch
    {
        AutonomyMode.Observe => "Observe & Brief",
        AutonomyMode.Full => "Prep + Urgent",
        _ => "Prep & Offer",
    };

    public static string Detail(this AutonomyMode mode) => mode switch
    {
        AutonomyMode.Observe => "Quiet open-loop tracking and a daily brief only (Tier 0).",
        AutonomyMode.Full => "Prep & offers plus budgeted urgent alerts outside quiet hours (Tier 0–2).",
        _ => "Read-only checks, drafts, and structured offers within your daily budget (Tier 0–1).",
    };

    public static AutonomyMode Parse(string? raw) => (raw ?? "").Trim().ToLowerInvariant() switch
    {
        "observe" => AutonomyMode.Observe,
        "full" => AutonomyMode.Full,
        _ => AutonomyMode.Prep,
    };
}

/// Live status payload from `GET /api/plugins/hermes-hq-proactive/status` (`ProactivityBeta.Status`).
public sealed record ProactivityStatus(
    string Version,
    bool Beta,
    bool Enabled,
    AutonomyMode AutonomyMode,
    bool QuietHoursActive,
    string QuietStart,
    string QuietEnd,
    int OffersUsed24h,
    int OffersLimit24h,
    int InterruptsUsed24h,
    int InterruptsLimit24h,
    int PendingOffers,
    int OpenLoops,
    int SnoozedLoops,
    int ActiveWatches,
    bool InTurnEnabled,
    bool LoopRadarEnabled,
    bool IdleSweepEnabled,
    bool DailyBriefEnabled,
    bool PatternDetectionEnabled,
    bool AllowLlmInSweep)
{
    public static ProactivityStatus Parse(string json) => Parse(J.Parse(json));

    public static ProactivityStatus Parse(JsonNode? root)
    {
        var budgets = root.Get("budgets");
        var counts = root.Get("counts");
        var settings = root.Get("settings");
        var rawMode = root.Text("autonomy_mode") ?? settings.Text("autonomy_mode") ?? "prep";
        return new ProactivityStatus(
            Version: root.Text("version") ?? "0.1.0-beta.1",
            Beta: root.Bool("beta") ?? true,
            Enabled: root.Bool("enabled") ?? settings.Bool("enabled") ?? false,
            AutonomyMode: AutonomyModes.Parse(rawMode),
            QuietHoursActive: root.Bool("quiet_hours_active") ?? false,
            QuietStart: settings.Text("quiet_start") ?? "22:00",
            QuietEnd: settings.Text("quiet_end") ?? "08:00",
            OffersUsed24h: (int)(budgets.Int("offers_used_24h") ?? 0),
            OffersLimit24h: (int)(budgets.Int("offers_limit_24h") ?? 6),
            InterruptsUsed24h: (int)(budgets.Int("interrupts_used_24h") ?? 0),
            InterruptsLimit24h: (int)(budgets.Int("interrupts_limit_24h") ?? 2),
            PendingOffers: (int)(counts.Int("pending_offers") ?? 0),
            OpenLoops: (int)(counts.Int("open_loops") ?? 0),
            SnoozedLoops: (int)(counts.Int("snoozed_loops") ?? 0),
            ActiveWatches: (int)(counts.Int("active_watches") ?? 0),
            InTurnEnabled: settings.Bool("in_turn_enabled") ?? true,
            LoopRadarEnabled: settings.Bool("loop_radar_enabled") ?? true,
            IdleSweepEnabled: settings.Bool("idle_sweep_enabled") ?? true,
            DailyBriefEnabled: settings.Bool("daily_brief_enabled") ?? true,
            PatternDetectionEnabled: settings.Bool("pattern_detection_enabled") ?? true,
            AllowLlmInSweep: settings.Bool("allow_llm_in_sweep") ?? true);
    }
}

/// Result of `POST /api/plugins/hermes-hq-proactive/sweep` (`ProactivityBeta.SweepOutcome`).
public sealed record SweepOutcome(bool Quiet, int SignalsDetected, int CreatedOffers, int TokensUsed)
{
    public static SweepOutcome Parse(string json) => Parse(J.Parse(json));

    public static SweepOutcome Parse(JsonNode? root) => new(
        Quiet: root.Bool("quiet") ?? false,
        SignalsDetected: (int)(root.Int("signals_detected") ?? 0),
        CreatedOffers: (int)(root.Int("created_offers") ?? 0),
        TokensUsed: (int)(root.Int("tokens_used") ?? 0));
}

/// Classification after a 404 on `/api/plugins/hermes-hq-proactive/status` (commit `6bedd2ea3`).
public enum ProactivityMissingState
{
    NotInstalled,
    NeedsRestart,
}

/// REST client for `hermes-hq-proactive` (HermesKit/Plugins/ProactivityBeta.swift `ProactivityBetaAPI`).
public sealed class ProactivityBetaApi(GatewaySession session)
{
    /// Omits `default` or empty profiles, includes `?profile=<bot>` for named bot profiles.
    public static IReadOnlyList<KeyValuePair<string, string>> ProfileQuery(string? profile)
    {
        var trimmed = profile?.Trim() ?? "";
        return trimmed.Length == 0 || trimmed == "default" ? [] : [new("profile", trimmed)];
    }

    public async Task<ProactivityStatus> StatusAsync(string profile = "default", CancellationToken ct = default)
    {
        var answer = await session.SendAsync(HttpMethod.Get, $"{ProactivityBeta.Route}/status", ProfileQuery(profile), ct: ct);
        return ProactivityStatus.Parse(GatewaySession.Require(answer));
    }

    public async Task<ProactivityStatus> UpdateSettingsAsync(JsonObject fields, string profile = "default", CancellationToken ct = default)
    {
        var answer = await session.SendAsync(HttpMethod.Patch, $"{ProactivityBeta.Route}/settings", ProfileQuery(profile), fields.DeepClone(), ct: ct);
        var root = GatewaySession.Require(answer);
        if (root.Obj("status") is { } statusObj) return ProactivityStatus.Parse(statusObj);
        return await StatusAsync(profile, ct);
    }

    public async Task<SweepOutcome> SweepAsync(bool forceBrief = false, string profile = "default", CancellationToken ct = default)
    {
        var body = new JsonObject { ["force_brief"] = forceBrief };
        var answer = await session.SendAsync(HttpMethod.Post, $"{ProactivityBeta.Route}/sweep", ProfileQuery(profile), body, ct: ct);
        return SweepOutcome.Parse(GatewaySession.Require(answer));
    }

    /// True when the gateway answered 404 on `/status` (plugin not installed, disabled, or routes not mounted yet).
    /// Hermes's runtime gate answers `404 {"detail":"Plugin not found"}` and FastAPI's fallback answers
    /// `404 {"detail":"Not Found"}`; `/status` itself never returns a domain 404 (commit `6bedd2ea3`).
    public static bool IsRouteMissing(Exception error) =>
        error is GatewayException { Code: "http", Status: 404 };

    /// Distinguishes an already-installed plugin whose routes haven't mounted yet (`NeedsRestart`) from an absent one.
    public static ProactivityMissingState ClassifyMissingRoute(IReadOnlyList<PluginInfo>? installedPlugins)
    {
        if (installedPlugins != null && installedPlugins.Any(IsProactivityPlugin))
            return ProactivityMissingState.NeedsRestart;
        return ProactivityMissingState.NotInstalled;
    }

    public static bool IsProactivityPlugin(PluginInfo plugin) =>
        plugin.Name == ProactivityBeta.PluginName || plugin.CatalogName == ProactivityBeta.PluginName;

    public static string ErrorWords(Exception error, string fallback = "Couldn’t reach Hermes.")
    {
        if (error is GatewayException { Code: "http" } http)
        {
            if (http.Body is { Length: > 0 } body && J.Parse(body) is JsonObject parsed)
            {
                var detail = parsed.Text("detail") ?? parsed.Text("error") ?? parsed.Text("message");
                if (!string.IsNullOrEmpty(detail)) return detail;
            }
            return $"Hermes answered HTTP {http.Status}.";
        }
        return string.IsNullOrWhiteSpace(error.Message) ? fallback : error.Message;
    }

    public static string SweepSummary(SweepOutcome outcome) => outcome.Quiet
        ? "Signal check quiet — nothing crossed threshold (0 tokens)."
        : $"Checked {outcome.SignalsDetected} signal(s), staged {outcome.CreatedOffers} offer(s).";

    public static string RestartPrompt(string botName) =>
        $"Please restart Hermes so the {ProactivityBeta.PageLabel} ({ProactivityBeta.PluginName}) plugin web routes finish loading for {botName}.";
}
