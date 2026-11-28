using System.Text.Json.Nodes;
using Hermes.Core.Net;
using Hermes.Core.Rpc;

namespace Hermes.Core.Activity;

/// Waiting on teammates (Hermes 0.23.3+, `bot_delivery.list`, `apps/desktop/src/plugins/hermes-bots/teammate-waits.tsx`):
/// read-only list of unsettled `message_agent` deliveries sent by a bot. Never resends automatically.
public enum BotDeliveryState { Queued, Claimed, Working, WaitingOnYou, Failed }

public sealed record BotDeliveryRow(
    string DeliveryId,
    string Target,
    string TargetHandle,
    BotDeliveryState State,
    double Since,
    string Preview,
    string? WaitingOn = null,
    string? Reason = null,
    string? Error = null)
{
    public const string NeverResentNotice =
        "Items here are never resent automatically. Outcome unknown means the teammate may already have acted — open its chat before asking again.";

    public static readonly IReadOnlyDictionary<string, string> ReasonWords = new Dictionary<string, string>
    {
        ["provider_auth_or_access"] = "Model provider rejected the key",
        ["provider_quota_limit"] = "Provider is out of credits",
        ["provider_rate_limit"] = "Provider rate limit",
        ["provider_server_error"] = "Provider couldn’t be reached",
        ["missing_config"] = "No model configured",
        ["model_unavailable"] = "Model unavailable",
        ["context_overflow"] = "Context limit reached",
        ["runtime_offline"] = "Teammate offline",
        ["queued_expired"] = "Never picked up",
        ["delivery_timeout"] = "Timed out",
        ["agent_blocked"] = "Blocked",
        ["cancelled"] = "Cancelled",
        ["unknown_outcome"] = "Outcome unknown",
    };

    public bool IsUnknownOutcome => State == BotDeliveryState.Failed && Reason == "unknown_outcome";
    public bool NeedsAttention => State is BotDeliveryState.WaitingOnYou or BotDeliveryState.Failed;
    public bool IsActive => State is BotDeliveryState.Queued or BotDeliveryState.Claimed or BotDeliveryState.Working;

    public string FailureReasonText
    {
        get
        {
            if (Reason is { Length: > 0 } r && r != "unknown" && ReasonWords.TryGetValue(r, out var words))
                return words;
            var trimmed = Error?.Trim() ?? "";
            return trimmed.Length > 0 ? trimmed : "Unknown error";
        }
    }

    public string StatusLine => State switch
    {
        BotDeliveryState.Queued => "Queued",
        BotDeliveryState.Claimed => "Picked up",
        BotDeliveryState.Working => "Working",
        BotDeliveryState.WaitingOnYou => WaitingOn == "clarify"
            ? "Waiting on you — answer question"
            : "Waiting on you — approve or deny",
        BotDeliveryState.Failed => IsUnknownOutcome ? "Outcome unknown" : $"Failed: {FailureReasonText}",
        _ => "",
    };

    public static BotDeliveryState? ParseState(string? raw) => raw switch
    {
        "queued" => BotDeliveryState.Queued,
        "claimed" => BotDeliveryState.Claimed,
        "working" => BotDeliveryState.Working,
        "waiting_on_you" => BotDeliveryState.WaitingOnYou,
        "failed" => BotDeliveryState.Failed,
        _ => null,
    };

    public static BotDeliveryRow? From(JsonNode? json)
    {
        var deliveryId = json.Str("delivery_id")?.Trim();
        var target = json.Str("target")?.Trim();
        var state = ParseState(json.Str("state"));
        if (string.IsNullOrEmpty(deliveryId) || string.IsNullOrEmpty(target) || state is null) return null;
        var handle = json.Str("target_handle")?.Trim() ?? "";
        var since = json.Num("since") is { } s && double.IsFinite(s) ? s : 0;
        return new BotDeliveryRow(
            deliveryId,
            target,
            handle.Length > 0 ? handle : target,
            state.Value,
            since,
            json.Str("preview") ?? "",
            json.Str("waiting_on"),
            json.Str("reason"),
            json.Str("error"));
    }

    public static string CompactAge(double since, double now)
    {
        if (since <= 0 || now < since) return "<1m";
        var seconds = (int)(now - since);
        if (seconds < 60) return "<1m";
        var minutes = seconds / 60;
        if (minutes < 60) return $"{minutes}m";
        var hours = minutes / 60;
        if (hours < 48) return $"{hours}h";
        return $"{hours / 24}d";
    }

    /// Only failed rows can be dismissed; active or waiting rows stay visible.
    public static IReadOnlyList<BotDeliveryRow> Visible(IEnumerable<BotDeliveryRow> rows, IReadOnlySet<string> dismissed) =>
        [.. rows.Where(r => r.State != BotDeliveryState.Failed || !dismissed.Contains(r.DeliveryId))];
}

public sealed record TeammateWaitsResult(IReadOnlyList<BotDeliveryRow> Rows, bool Unsupported = false);

public static class TeammateWaitsApi
{
    public static async Task<TeammateWaitsResult> ListAsync(
        Func<string, JsonObject, TimeSpan, CancellationToken, Task<JsonNode>> call,
        string? profile,
        CancellationToken ct = default)
    {
        var p = new JsonObject();
        var trimmed = profile?.Trim() ?? "";
        if (trimmed.Length > 0) p["profile"] = trimmed;
        try
        {
            var res = await call("bot_delivery.list", p, TimeSpan.FromSeconds(10), ct);
            var rows = (res.Arr("deliveries") ?? []).Select(BotDeliveryRow.From).OfType<BotDeliveryRow>().ToList();
            return new TeammateWaitsResult(rows, Unsupported: false);
        }
        catch (GatewayException e) when (e.Code == "rpc" && e.RpcCode == -32601)
        {
            return new TeammateWaitsResult([], Unsupported: true);
        }
    }

    public static Task<TeammateWaitsResult> ListAsync(RpcConnection rpc, string? profile, CancellationToken ct = default) =>
        ListAsync((m, p, t, c) => rpc.RequestAsync(m, p, t, c), profile, ct);
}
