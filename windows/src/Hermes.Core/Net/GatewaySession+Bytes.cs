using System.Net.Http.Headers;
using System.Text;

namespace Hermes.Core.Net;

// [WIN-MEMO-SEND-WIRE] Byte bodies with their own Content-Type, answered as bytes (HermesKit/Net/LiveGatewayClient.swift
// at 93f984bb1: `send(_:_:query:body:contentType:timeout:)` under `rest` and `transfer`). The JSON `SendAsync` reads
// every answer as text and only sends a JsonNode; a multipart upload, a DELETE whose body is JSON bytes, the
// transcription's data URL and a recording's download need the bytes as they are. The same account handling as every
// REST call: proactive Nous renewal, the bearer or the jar's cookies, a 401 on an /api/ route refreshes once and sends
// the same bytes again, rotated cookies saved. A write (anything but GET/HEAD) drops the shared config reads before it
// is sent and once it is answered.

/// A REST answer as bytes.
public sealed record ByteAnswer(int Status, byte[] Body, HttpResponseHeaders Headers)
{
    public bool Ok => Status is >= 200 and < 300;
}

public sealed partial class GatewaySession
{
    /// `GET /api/config` shared by the readers that only read it (the Mac's `LiveGatewayClient.configReads`).
    public SharedConfigReads ConfigReads { get; } = new();

    private static bool IsRead(HttpMethod method) => method == HttpMethod.Get || method == HttpMethod.Head;

    /// Sends `body` (null: none) as `contentType` within `timeout` and returns the answer, any status. Transport
    /// failures throw GatewayException "timeout" / "offline" (the caller's own cancellation throws
    /// OperationCanceledException).
    public Task<ByteAnswer> SendBytesAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query,
        byte[]? body, string contentType, TimeSpan timeout, CancellationToken ct = default) =>
        SendBytesAsync(method, path, query, body, contentType, timeout, ct, null);

    internal async Task<ByteAnswer> SendBytesAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query,
        byte[]? body, string contentType, TimeSpan timeout, CancellationToken ct, TimeProvider? transferClock)
    {
        var read = IsRead(method) || IsControlPath(path);
        if (!read) ConfigReads.Invalidate();
        try
        {
            await RenewIfDueAsync(ct);
            var answer = await RawBytesAsync(method, path, query, body, contentType, timeout, ct, transferClock);
            if (answer.Status == 401 && path.Contains("/api/") && await RefreshAfter401Async(ct))
                answer = await RawBytesAsync(method, path, query, body, contentType, timeout, ct, transferClock);
            SaveCookiesIfChanged();
            return answer;
        }
        finally
        {
            if (!read) ConfigReads.Invalidate();
        }
    }

    private async Task<ByteAnswer> RawBytesAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query,
        byte[]? body, string contentType, TimeSpan timeout, CancellationToken ct, TimeProvider? transferClock)
    {
        using var idle = transferClock == null ? null : new TransferIdleTimeout(timeout, transferClock, ct);
        using var req = new HttpRequestMessage(method, Address.Endpoint(path, query));
        // HermesKit sets Content-Type on every request (`decorate`), a body or none.
        req.Content = idle?.Content(body ?? []) ?? new ByteArrayContent(body ?? []);
        req.Content.Headers.ContentType = MediaTypeHeaderValue.Parse(contentType);
        req.Content.Headers.ContentLength = body?.LongLength ?? 0;
        if (IsControlPath(path)) req.Headers.Accept.ParseAdd("application/json");
        Decorate(req);
        using var cts = idle == null ? CancellationTokenSource.CreateLinkedTokenSource(ct) : null;
        cts?.CancelAfter(timeout);
        var traced = Settings.DetailedLogging.Enabled;
        var began = traced ? System.Diagnostics.Stopwatch.GetTimestamp() : 0;
        var url = req.RequestUri!;
        var control = IsControlPath(path);
        long Ms() => (long)System.Diagnostics.Stopwatch.GetElapsedTime(began).TotalMilliseconds;
        try
        {
            ByteAnswer answer;
            if (idle != null) answer = await idle.ReadAsync(_http, req).ConfigureAwait(false);
            else
            {
                using var res = await _http.SendAsync(req, HttpCompletionOption.ResponseContentRead, cts!.Token);
                answer = new((int)res.StatusCode, await res.Content.ReadAsByteArrayAsync(cts.Token), res.Headers);
            }
            var bytes = answer.Body;
            if (traced)
                Settings.DetailedLogging.Trace("http", () => Settings.DetailedLogging.RequestLine(method.Method, url, control,
                    answer.Status, bytes.LongLength, Ms(), answer.Ok ? null : Encoding.UTF8.GetString(bytes, 0, Math.Min(bytes.Length, 4096))));
            return answer;
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            if (traced) Settings.DetailedLogging.Trace("http", () => Settings.DetailedLogging.FailureLine(method.Method, url, control, Ms(), "timed out"));
            throw new GatewayException("timeout", "The gateway took too long to answer.");
        }
        catch (Exception e) when (e is HttpRequestException || (idle != null && e is IOException))
        {
            // A response-stream disconnect can be an IOException after headers (formerly wrapped by HttpClient buffering).
            if (idle != null)
            {
                ct.ThrowIfCancellationRequested();
                if (idle.TimedOut)
                {
                    if (traced) Settings.DetailedLogging.Trace("http", () => Settings.DetailedLogging.FailureLine(method.Method, url, control, Ms(), "timed out"));
                    throw new GatewayException("timeout", "The gateway took too long to answer.");
                }
            }
            if (traced) Settings.DetailedLogging.Trace("http", () => Settings.DetailedLogging.FailureLine(method.Method, url, control, Ms(), e.Message));
            throw new GatewayException("offline", "Can't reach the gateway. " + e.Message);
        }
    }
}
