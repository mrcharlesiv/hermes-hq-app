using System.Text;
using Hermes.Core.Net;

namespace Hermes.Core.Voice;

// [WIN-MEMO-SEND-WIRE] The memo pipeline's REST over the signed-in account's session, as HermesKit's LiveGatewayClient
// sends it at 93f984bb1 (`rest`, `configData`, `transfer`, `send`):
//   RestAsync      `rest`: Content-Type application/json, the body as given (none for a GET), 30 s (clamped 1…120)
//   TransferAsync  `transfer`: the caller's Content-Type (a multipart boundary, JSON), timeout clamped 1…600 s
//   ConfigDataAsync `configData`: GET /api/config through the session's shared config reads
// Every answer comes back as its bytes (a recording's download stays binary). A non-2xx answer throws
// GatewayException("http", …, status, the first 64 KiB of the body as text): the Mac's HTTPError for every status,
// 429 included, so MemoUploader.Words reads all of them the same way. Transport failures are the session's own
// GatewayException ("timeout", "offline"); the caller's cancellation stays OperationCanceledException.

public sealed class HermesMemoGateway(GatewaySession session, Func<string> accountId) : IMemoTransfers
{
    /// `rest`'s ceiling, and its clamp (seconds).
    public const double RestTimeout = 30;
    public const double RestMax = 120;
    /// `transfer`'s clamp (seconds).
    public const double TransferMax = 600;
    /// How much of a refusal's body is kept (`data.prefix(64 << 10)`).
    public const int BodyLimit = 64 << 10;

    private readonly TimeProvider _transferClock = TimeProvider.System;
    internal HermesMemoGateway(GatewaySession session, Func<string> accountId, TimeProvider transferClock) : this(session, accountId) =>
        _transferClock = transferClock;

    public HermesMemoGateway(HermesClient client) : this(client.Session, () => client.AccountId) { }

    public GatewaySession Session { get; } = session;

    public string AccountId => accountId();

    public Task<byte[]> RestAsync(string method, string path, IReadOnlyList<KeyValuePair<string, string>> query, byte[]? body,
        CancellationToken ct) =>
        SendAsync(method, path, query, body, "application/json", Math.Min(Math.Max(RestTimeout, 1), RestMax), ct);

    public Task<byte[]> ConfigDataAsync(IReadOnlyList<KeyValuePair<string, string>> query, TimeSpan maxAge, CancellationToken ct) =>
        Session.ConfigReads.DataAsync(query, maxAge, () => RestAsync("GET", "/api/config", query, null, ct));

    public Task<byte[]> TransferAsync(string method, string path, IReadOnlyList<KeyValuePair<string, string>> query, byte[]? body,
        string contentType, double timeoutSeconds, CancellationToken ct) =>
        SendAsync(method, path, query, body, contentType, Math.Min(Math.Max(timeoutSeconds, 1), TransferMax), ct, _transferClock);

    private async Task<byte[]> SendAsync(string method, string path, IReadOnlyList<KeyValuePair<string, string>> query, byte[]? body,
        string contentType, double seconds, CancellationToken ct, TimeProvider? transferClock = null)
    {
        var answer = await Session.SendBytesAsync(new HttpMethod(method), path, query, body, contentType,
            TimeSpan.FromSeconds(seconds), ct, transferClock);
        if (!answer.Ok) throw HttpError(answer.Status, answer.Body);
        return answer.Body;
    }

    /// The Mac's `HTTPError(status:body:)`: the status and the body's first 64 KiB as text.
    public static GatewayException HttpError(int status, byte[] body)
    {
        var text = Encoding.UTF8.GetString(body, 0, Math.Min(body.Length, BodyLimit));
        return new GatewayException("http", $"The gateway answered {status}.", status, text);
    }
}
