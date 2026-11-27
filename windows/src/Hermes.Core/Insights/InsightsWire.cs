using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Gateways;
using Hermes.Core.Net;

namespace Hermes.Core.Insights;

/// What the Insights pages share (HermesKit/Pages/More/MoreWire.swift, HermesKit/Pages/PagesWire.swift `PagesREST`,
/// App/Pages/PageKit.swift `PageStates`): the profile scope on REST and JSON-RPC, "this route is not on this gateway",
/// and a refused request in words.
public static partial class InsightsWire
{
    /// REST profile scope: `profile=<id>`, left out for the default bot.
    public static List<KeyValuePair<string, string>> ProfileQuery(string? profile)
    {
        var q = new List<KeyValuePair<string, string>>();
        if (!string.IsNullOrEmpty(profile) && profile != "default") q.Add(new("profile", profile));
        return q;
    }

    /// JSON-RPC `ProfileParams`: `{"profile": id}` for a named bot, nothing for the default one (Hermes answers 4000 for
    /// a key it does not know).
    public static JsonObject ProfileParams(string? profile)
    {
        var o = new JsonObject();
        if (!string.IsNullOrEmpty(profile) && profile != "default") o["profile"] = profile;
        return o;
    }

    /// The gateway has no such route or method (an older Hermes): HTTP 404 / 405, or JSON-RPC -32601.
    public static bool IsMissingRoute(Exception e) => e switch
    {
        GatewayException { Code: "http", Status: 404 or 405 } => true,
        GatewayException { Code: "rpc", RpcCode: -32601 } => true,
        _ => false,
    };

    /// What a page shows as "Not Available on This Hermes": a missing route, or an empty answer.
    public static bool IsNotAvailable(Exception e) =>
        (e is GatewayException { Code: "http" } h && IsUnknownRoute(h)) || (e is GatewayException { Code: "rpc", RpcCode: -32601 })
        || e is PagesMessageException { Message: OlderHermes };

    public const string OlderHermes = "Not available on this Hermes. Updating Hermes may add it.";
    public const string NotAvailableTitle = "Not Available on This Hermes";

    public static string NotAvailableBody(string? page) =>
        string.IsNullOrEmpty(page) ? OlderHermes : $"This Hermes doesn’t have {page}. Updating Hermes may add it.";

    /// The page a "Couldn't Load <Page>" title names ("Couldn't Load Star Map" → "Star Map").
    public static string? PageName(string failureTitle)
    {
        foreach (var prefix in new[] { "Couldn’t Load the ", "Couldn’t Load ", "Couldn't Load the ", "Couldn't Load " })
            if (failureTitle.StartsWith(prefix, StringComparison.Ordinal))
                return failureTitle.Length > prefix.Length ? failureTitle[prefix.Length..] : null;
        return null;
    }

    public static string FailureTitle(string title, string reason) => reason == OlderHermes ? NotAvailableTitle : title;

    /// The one sentence for a gateway that gave no answer, however it failed (GatewayFailure.unreachable).
    public static string CantReach => $"Can’t reach {HostWord.Phrase}. Check that it’s on, and that Tailscale is on here too if you use it.";

    public const string CouldntDoThat = "The gateway couldn’t do that.";

    /// The gateway's own reason for a refused request, in words (`PagesREST.reason`): FastAPI's `{"detail": "…"}`; an
    /// object `detail` shows its `message`; transport failures their own text.
    public static string Reason(Exception e)
    {
        switch (e)
        {
            case PagesMessageException m: return m.Message;
            case OperationCanceledException: return "Cancelled.";
            case GatewayException { Code: "http" } h:
                if (IsUnknownRoute(h)) return OlderHermes;
                return Detail(h.Body) ?? CouldntDoThat;
            case GatewayException { Code: "offline" or "timeout" }: return CantReach;
            case GatewayException { Code: "rpc" } r: return PlainRpc(r.Message);
            case GatewayException g when g.Message.Length > 0: return g.Message;
            default: return CouldntDoThat;
        }
    }

    /// An RPC error's message without the "error 4000:" style codes some gateways prefix.
    private static string PlainRpc(string message)
    {
        var t = message.Trim();
        return t.Length == 0 ? CouldntDoThat : t;
    }

    /// `detail` of an HTTP error body (a string, or an object's `message`); null when there is none.
    public static string? Detail(string? body)
    {
        var value = body == null ? null : J.Parse(body);
        if (value == null)
        {
            var text = body?.Trim() ?? "";
            return text.Length == 0 || text.StartsWith('<') || text.Length > 300 ? null : text;
        }
        if (value.Get("detail") is { } detail)
        {
            if (J.AsString(detail) is { Length: > 0 } s) return s;
            if (detail.Text("message") is { } m) return m;
            return null;
        }
        return value.Text("error");
    }

    /// A 404/405 for the route itself (a bare "Not Found" / "Method Not Allowed", or no reason), not a named thing that
    /// is gone ("Session not found" keeps its words).
    public static bool IsUnknownRoute(GatewayException h)
    {
        if (h.Status is not (404 or 405)) return false;
        var text = Detail(h.Body)?.Trim().ToLowerInvariant();
        return text is null or "not found" or "method not allowed";
    }

    /// An answer with nothing in it: `{}`, `[]`, `null` or no bytes.
    public static bool IsEmptyAnswer(JsonNode? value) => value switch
    {
        null => true,
        JsonObject o => o.Count == 0,
        JsonArray a => a.Count == 0,
        _ => false,
    };

    /// The error for an answer that isn't the expected shape (`PagesREST.unreadable`).
    public static PagesMessageException Unreadable(JsonNode? answer) =>
        new(IsEmptyAnswer(answer) ? OlderHermes : "The gateway’s answer couldn’t be read.");

    /// Copy Details never carries a token or cookie (`PageStates.scrubbed`).
    public static string Scrubbed(string text)
    {
        var pairs = PairRx().Replace(text, "$1=…");
        return BearerRx().Replace(pairs, "Bearer …");
    }

    [GeneratedRegex(@"(?i)\b(token|ticket|cookie|authorization|session_id|sessionid)\s*[=:]\s*(?:bearer\s+)?[^\s&;]+")]
    private static partial Regex PairRx();
    [GeneratedRegex(@"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{8,}")]
    private static partial Regex BearerRx();

    /// A first read still going after 15 s says the gateway is slow (RosterStateCopy).
    public static readonly TimeSpan SlowAfter = TimeSpan.FromSeconds(15);
    public const string SlowPage = "Still loading… Your gateway is taking longer than usual.";
    public const string TryAgain = "Try Again";
    public const string CopyDetails = "Copy Details";
    public const string OfflineFooter = "You can change this once your gateway is back.";
}

/// A reason in words, for failures the app finds itself (an unreadable answer).
public sealed class PagesMessageException(string message) : Exception(message);
