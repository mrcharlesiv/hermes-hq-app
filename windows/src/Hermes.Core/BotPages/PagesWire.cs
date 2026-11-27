using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Gateways;
using Hermes.Core.Net;

namespace Hermes.Core.BotPages;

/// What the Bot Profiles, Messaging, Webhooks and Import Sessions pages ask of the gateway: REST and JSON-RPC. The app
/// hands in `ClientPagesGateway`; the tests a fake. A refused REST call throws GatewayException("http", …) with the
/// status and body (as GatewaySession does); a refused RPC GatewayException("rpc", …) with its code.
public interface IPagesGateway
{
    Task<string> RestAsync(string method, string path, IEnumerable<KeyValuePair<string, string>>? query = null,
        JsonNode? body = null, TimeSpan? timeout = null, CancellationToken ct = default);

    Task<JsonNode> CallAsync(string method, JsonObject parameters, TimeSpan timeout, CancellationToken ct = default);
}

/// The gateway in use, as the pages read it.
public sealed class ClientPagesGateway(HermesClient client) : IPagesGateway
{
    public HermesClient Client { get; } = client;

    public async Task<string> RestAsync(string method, string path, IEnumerable<KeyValuePair<string, string>>? query = null,
        JsonNode? body = null, TimeSpan? timeout = null, CancellationToken ct = default)
    {
        var answer = await Client.Session.SendAsync(new HttpMethod(method), path, query, body, timeout, ct: ct);
        if (!answer.Ok) throw GatewaySession.HttpError(answer);
        return answer.Body;
    }

    public Task<JsonNode> CallAsync(string method, JsonObject parameters, TimeSpan timeout, CancellationToken ct = default) =>
        Client.Rpc.RequestAsync(method, parameters, timeout, ct);
}

/// A reason in words, for failures the app finds itself (an unreadable answer, a refused start)
/// (HermesKit/Pages/PagesWire.swift `PagesMessageError`).
public sealed class PagesMessageException(string message) : Exception(message);

/// The paths, scopes and error words the More pages share (HermesKit/Pages/PagesWire.swift `PagesREST`,
/// HermesKit/Pages/More/MoreWire.swift `MoreWire`).
public static partial class PagesRest
{
    /// A page or action the connected Hermes doesn't have: not a failure, so it never says "couldn't".
    public const string OlderHermes = "Not available on this Hermes. Updating Hermes may add it.";
    /// The title over `OlderHermes` where a page would otherwise say "Couldn't Load …".
    public const string NotAvailableTitle = "Not Available on This Hermes";
    public const string Unreadable = "The gateway’s answer couldn’t be read.";
    public const string CouldNotDo = "The gateway couldn’t do that.";

    /// One gateway that gave no answer, however it failed (GatewayFailure.unreachable).
    public static string CantReach => $"Can’t reach {HostWord.Phrase}. Check that it’s on, and that Tailscale is on here too if you use it.";

    /// "This Hermes doesn't have Messaging. Updating Hermes may add it."
    public static string NotAvailableBody(string? page) =>
        string.IsNullOrEmpty(page) ? OlderHermes : $"This Hermes doesn’t have {page}. Updating Hermes may add it.";

    /// The page a "Couldn't Load <Page>" title names ("Couldn't Load Star Map" → "Star Map").
    public static string? PageName(string title)
    {
        foreach (var prefix in new[] { "Couldn’t Load the ", "Couldn’t Load ", "Couldn't Load the ", "Couldn't Load " })
            if (title.StartsWith(prefix, StringComparison.Ordinal)) return title.Length > prefix.Length ? title[prefix.Length..] : null;
        return null;
    }

    /// One path segment, percent-encoded like `encodeURIComponent` ("job/1" → "job%2F1").
    public static string Segment(string raw) => Uri.EscapeDataString(raw)
        .Replace("%21", "!").Replace("%2A", "*").Replace("%27", "'").Replace("%28", "(").Replace("%29", ")");

    /// REST profile scope: `profile=<id>`, left out for the default bot.
    public static IEnumerable<KeyValuePair<string, string>> ProfileQuery(string? profile) =>
        string.IsNullOrEmpty(profile) || profile == "default" ? [] : [new("profile", profile)];

    /// JSON-RPC `ProfileParams`: `{"profile": id}` for a named bot, nothing for the default one. Hermes answers 4000 for a
    /// key it does not know, so callers add only the keys their method lists.
    public static JsonObject ProfileParams(string? profile, JsonObject? more = null)
    {
        var o = more ?? [];
        if (!string.IsNullOrEmpty(profile) && profile != "default") o["profile"] = profile;
        return o;
    }

    public static async Task<JsonNode?> JsonAsync(IPagesGateway gw, string method, string path,
        IEnumerable<KeyValuePair<string, string>>? query = null, JsonNode? body = null, TimeSpan? timeout = null,
        CancellationToken ct = default)
    {
        var text = await gw.RestAsync(method, path, query, body, timeout, ct);
        if (string.IsNullOrWhiteSpace(text)) return null;
        return J.Parse(text) ?? throw new PagesMessageException(Unreadable);
    }

    /// An HTTP status, when the error has one.
    public static int? Status(Exception e) => e is GatewayException { Code: "http" } g ? g.Status : null;

    /// The gateway has no such route or method (an older Hermes): HTTP 404 / 405, or JSON-RPC -32601.
    public static bool IsMissingRoute(Exception e) => e is GatewayException g &&
        (g.Code == "http" && g.Status is 404 or 405 || g.Code == "rpc" && g.RpcCode == -32601);

    /// What a page itself shows as "Not Available on This Hermes": a missing route, or an empty answer.
    public static bool IsNotAvailable(Exception e) => IsMissingRoute(e) || e is PagesMessageException { Message: OlderHermes };

    /// An answer with nothing in it: no bytes, `{}`, `[]` or `null`.
    public static bool IsEmptyAnswer(JsonNode? value) => value switch
    {
        null => true,
        JsonObject o => o.Count == 0,
        JsonArray a => a.Count == 0,
        _ => false,
    };

    /// The error for an answer that isn't the expected shape: an empty one is "Not available on this Hermes".
    public static PagesMessageException UnreadableAnswer(JsonNode? answer) =>
        new(IsEmptyAnswer(answer) ? OlderHermes : Unreadable);

    /// `detail` of an HTTP error body (a string, or an object's `message`); nil when there is none.
    public static string? Detail(string? body)
    {
        if (J.Parse(body ?? "") is not { } value)
        {
            var text = (body ?? "").Trim();
            return text.Length == 0 || text.StartsWith('<') || text.Length > 300 ? null : text;
        }
        if (value.Get("detail") is { } detail)
        {
            if (detail is JsonValue dv && dv.TryGetValue(out string? s) && s.Length > 0) return s;
            if (detail.Str("message") is { Length: > 0 } m) return m;
            return null;
        }
        return value.Str("error") is { Length: > 0 } e ? e : null;
    }

    /// A 404/405 for the route itself (a bare "Not Found" / "Method Not Allowed", or no reason at all), not a named
    /// thing that is gone ("Session not found" keeps its own words).
    public static bool IsUnknownRoute(int status, string? body)
    {
        if (status is not (404 or 405)) return false;
        if (Detail(body)?.Trim().ToLowerInvariant() is not { } text) return true;
        return text is "not found" or "method not allowed";
    }

    /// The gateway's own reason for a refused request, in words (the web's `errText`).
    public static string Reason(Exception e) => e switch
    {
        GatewayException { Code: "http" } h => IsUnknownRoute(h.Status, h.Body) ? OlderHermes : Detail(h.Body) ?? CouldNotDo,
        GatewayException { IsConnectionLost: true } g => g.PlainReason,
        GatewayException { Code: "timeout" or "offline" } => CantReach,
        GatewayException { Code: "rpc" } r => r.RpcCode == -32601 ? OlderHermes : r.PlainReason,
        GatewayException g => g.Message,
        OperationCanceledException => "Cancelled.",
        PagesMessageException m => m.Message,
        _ => string.IsNullOrEmpty(e.Message) ? CouldNotDo : e.Message,
    };

    /// Sent but not answered in time, or a gateway/edge timeout: the work may still be running server-side.
    public static bool IsSlowAnswer(Exception e) =>
        e is GatewayException { Code: "timeout" } || Status(e) is 502 or 504 or 524;

    /// A JSON value as text: a string, or a number written as one (100000001 → "100000001").
    public static string? PgString(JsonNode? v) => v switch
    {
        JsonValue jv when jv.TryGetValue(out string? s) => s,
        JsonValue jv when jv.TryGetValue(out double d) => Math.Round(d) == d && Math.Abs(d) < 9.007e15
            ? ((long)d).ToString(System.Globalization.CultureInfo.InvariantCulture)
            : d.ToString(System.Globalization.CultureInfo.InvariantCulture),
        JsonValue jv when jv.TryGetValue(out bool b) => b ? "true" : "false",
        _ => null,
    };

    /// An ISO 8601 time (with or without fractions or a zone: none reads as UTC) or epoch seconds
    /// (MessagingAPI.swift `MessagingDates.parse`).
    public static DateTimeOffset? ParseDate(JsonNode? value)
    {
        if (value is JsonValue jv && jv.TryGetValue(out double seconds))
            return double.IsFinite(seconds) && seconds > 0 ? DateTimeOffset.FromUnixTimeMilliseconds((long)(seconds * 1000)) : null;
        var text = J.AsString(value)?.Trim();
        if (string.IsNullOrEmpty(text)) return null;
        if (double.TryParse(text, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var s) && s > 0)
            return DateTimeOffset.FromUnixTimeMilliseconds((long)(s * 1000));
        if (!text.EndsWith('Z') && !ZoneSuffix().IsMatch(text)) text += "Z";
        return DateTimeOffset.TryParse(text, System.Globalization.CultureInfo.InvariantCulture,
            System.Globalization.DateTimeStyles.AdjustToUniversal, out var d) ? d : null;
    }

    [GeneratedRegex(@"[+-]\d{2}:?\d{2}$")]
    private static partial Regex ZoneSuffix();

    /// "While offline, write controls are disabled with this line" (MorePages.offlineFooter).
    public const string OfflineFooter = "You can change this once your gateway is back.";
}

/// `title` the bot a per-bot page reads, by account and page (`pages.more.bot.<page>.<account>`). Stored as one small
/// JSON file; a bot that left the roster reads as the first choice (MorePageKit.swift `MoreBotChoice`).
public sealed class BotChoiceStore(string path)
{
    private readonly object _gate = new();

    public static string Key(string page, string account) => $"pages.more.bot.{page}.{account}";

    public string Read(string page, string account, IReadOnlyList<string> choices)
    {
        lock (_gate)
        {
            var saved = Load().Str(Key(page, account));
            if (saved != null && choices.Contains(saved)) return saved;
        }
        return choices.FirstOrDefault() ?? "default";
    }

    public void Save(string page, string account, string profile)
    {
        lock (_gate)
        {
            var all = Load() as JsonObject ?? [];
            all[Key(page, account)] = profile;
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                File.WriteAllText(path, all.ToJsonString());
            }
            catch (IOException) { }
        }
    }

    private JsonNode? Load()
    {
        try { return File.Exists(path) ? J.Parse(File.ReadAllText(path)) : null; }
        catch (IOException) { return null; }
    }

    /// Default bot first, then roster order (the scope pill's order: `PagesNames.scopeChoices`).
    public static IReadOnlyList<Model.Bot> Choices(IEnumerable<Model.Bot> bots)
    {
        var list = bots.ToList();
        return [.. list.Where(b => b.IsDefault), .. list.Where(b => !b.IsDefault)];
    }
}
