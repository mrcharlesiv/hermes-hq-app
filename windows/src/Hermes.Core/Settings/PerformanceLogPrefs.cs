using System.Text.Json.Nodes;
using Hermes.Core.Net;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Settings;

/// Settings › About › Send Performance Logs to Hermes & Mark a Slow Moment (App/Settings/AboutView.swift).
public static class PerformanceLogPrefs
{
    public const string EnabledKey = "hqn.perfLog.enabled";
    public const string Title = "Send Performance Logs to Hermes";
    public const string MarkLabel = "Mark a Slow Moment";
    public const string MarkNote = "Flags this moment in the log on the computer running Hermes.";

    public static bool IsEnabled(IPreferences prefs) => prefs.Get(EnabledKey) != "false";

    public static void SetEnabled(IPreferences prefs, bool on, Action<string, string>? log = null)
    {
        prefs.Set(EnabledKey, on ? null : "false");
        log?.Invoke("settings", $"performance logs {(on ? "on" : "off")}");
    }

    /// Best-effort marker upload to the gateway's perf log endpoint when enabled.
    public static async Task<bool> MarkSlowMomentAsync(GatewaySession? session, string appVersion, CancellationToken ct = default)
    {
        if (session == null) return false;
        try
        {
            var body = new JsonObject
            {
                ["kind"] = "slow_moment",
                ["platform"] = "windows",
                ["version"] = appVersion,
                ["timestamp"] = DateTimeOffset.UtcNow.ToString("O"),
            };
            await session.SendAsync(HttpMethod.Post, "/api/perf-logs/mark", body: body, timeout: TimeSpan.FromSeconds(5), ct: ct);
            return true;
        }
        catch (Exception ex) when (ex is GatewayException or HttpRequestException or OperationCanceledException)
        {
            return false;
        }
    }
}
