using System.Text.Json;
using System.Text.Json.Nodes;
using Hermes.Core.Net;

namespace Hermes.Core.Kanban;

/// The REST calls the Kanban and Tasks pages make, with the account's auth. `GatewaySessionRest` is the live one; the
/// tests give a fake. A non-2xx answer throws GatewayException "http" with its Status and Body.
public interface IPagesRest
{
    Task<JsonNode?> JsonAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query = null,
        JsonNode? body = null, TimeSpan? timeout = null, CancellationToken ct = default);

    /// POSTs a multipart body built on disk; returns the answer's text.
    Task<string> UploadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string contentType, string bodyFile,
        TimeSpan timeout, Action<long, long>? progress = null, CancellationToken ct = default);

    /// GETs into `file` (never into memory), up to `ceiling` bytes.
    Task DownloadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string file, long ceiling,
        CancellationToken ct = default);
}

/// The live gateway.
public sealed class GatewaySessionRest(GatewaySession session) : IPagesRest
{
    public async Task<JsonNode?> JsonAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query = null,
        JsonNode? body = null, TimeSpan? timeout = null, CancellationToken ct = default)
    {
        var a = await session.SendAsync(method, path, query, body, timeout, ct: ct);
        if (!a.Ok) throw new GatewayException("http", $"The gateway answered {a.Status}.", a.Status, a.Body.Length > 65536 ? a.Body[..65536] : a.Body);
        return a.Json;
    }

    public Task<string> UploadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string contentType, string bodyFile,
        TimeSpan timeout, Action<long, long>? progress = null, CancellationToken ct = default) =>
        session.UploadFileAsync(path, query, contentType, bodyFile, timeout, progress, ct);

    public Task DownloadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string file, long ceiling,
        CancellationToken ct = default) => session.DownloadToFileAsync(path, query, file, ceiling, ct: ct);
}

/// A message the page shows as it is.
public sealed class PagesMessageException(string message) : Exception(message);

/// Paths, values and failure words the pages share (HermesKit PagesREST).
public static class KanbanRest
{
    public const string OlderHermes = "Not available on this Hermes. Updating Hermes may add it.";
    public const string CantReach = "Couldn’t reach your gateway. Check that it’s running, then try again.";
    public const string ReadOnlyNotice = "Changes are off for this gateway.";

    /// One path segment, percent-encoded like `encodeURIComponent` ("job/1" → "job%2F1").
    public static string Segment(string raw)
    {
        var sb = new System.Text.StringBuilder();
        foreach (var b in System.Text.Encoding.UTF8.GetBytes(raw))
        {
            var c = (char)b;
            if (b < 128 && (char.IsAsciiLetterOrDigit(c) || "-_.!~*'()".Contains(c))) sb.Append(c);
            else sb.Append('%').Append(b.ToString("X2"));
        }
        return sb.ToString();
    }

    /// A string, or a number written as one; null when absent or empty.
    public static string? Id(JsonNode? n, string key) => J.AsString(n.Get(key)) is { Length: > 0 } s
        ? (n.Get(key) is JsonValue v && v.GetValueKind() == JsonValueKind.Number && v.TryGetValue(out double d) ? KanbanNumbers.Plain(d) : s)
        : null;

    /// Seconds since the epoch from a number or numeric string; null when absent or not positive.
    public static double? Seconds(JsonNode? n, string key) => n.Num(key) is { } s && double.IsFinite(s) && s > 0 ? s : null;

    public static int? Status(Exception e) => e is GatewayException { Code: "http" } g ? g.Status : null;

    /// The gateway's own reason in an error's body: `detail` (a string, or `{message}`), else `error`, else a short plain
    /// body.
    public static string? Detail(string? body)
    {
        var json = body == null ? null : J.Parse(body);
        if (json == null)
        {
            var text = body?.Trim() ?? "";
            return text.Length == 0 || text.StartsWith('<') || text.Length > 300 ? null : text;
        }
        if (json.Get("detail") is { } detail)
        {
            if (J.AsString(detail) is { Length: > 0 } s && detail is JsonValue) return s;
            if (detail.Str("message") is { Length: > 0 } m) return m;
            return null;
        }
        return json.Str("error") is { Length: > 0 } err ? err : null;
    }

    /// A 404/405 for the route itself (a bare "Not Found" or no reason), not a named thing that is gone.
    public static bool IsUnknownRoute(Exception e)
    {
        if (e is not GatewayException { Code: "http", Status: 404 or 405 } g) return false;
        var text = Detail(g.Body)?.Trim().ToLowerInvariant();
        return text == null || text == "not found" || text == "method not allowed";
    }

    /// The words for a failure (PagesREST.reason).
    public static string Reason(Exception e) => e switch
    {
        PagesMessageException m => m.Message,
        GatewayException { Code: "http" } g => IsUnknownRoute(g) ? OlderHermes : Detail(g.Body) ?? "The gateway couldn’t do that.",
        GatewayException { Code: "offline" or "timeout" } => CantReach,
        GatewayException g => g.Message,
        OperationCanceledException => "Cancelled.",
        HttpRequestException => CantReach,
        _ => string.IsNullOrEmpty(e.Message) ? "The gateway couldn’t do that." : e.Message,
    };

    public static List<KeyValuePair<string, string>> Query(string board, params (string Key, string Value)[] extra)
    {
        var q = extra.Select(x => new KeyValuePair<string, string>(x.Key, x.Value)).ToList();
        if (board.Length > 0) q.Add(new("board", board));
        return q;
    }
}
