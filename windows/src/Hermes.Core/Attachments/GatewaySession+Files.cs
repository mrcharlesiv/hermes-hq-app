using System.Net.Http.Headers;
using Hermes.Core.Net;

namespace Hermes.Core.Net;

/// File-streamed uploads and downloads with the account's auth (HermesKit/Contracts+attachments.swift
/// GatewayFileTransfers; spec 1x-attachments §3, §8.2): never the whole body in memory, the same bearer or cookies as
/// every REST call, and a 401 on an /api/ route refreshes once and sends the same file again.
public sealed partial class GatewaySession
{
    /// POSTs `bodyFile` (a multipart body built on disk). `timeout` is an idle timeout: it restarts with every block
    /// sent. Returns the answer body (≤ 1 MiB). A non-2xx answer throws GatewayException "http" with its Status and Body.
    public async Task<string> UploadFileAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string contentType,
        string bodyFile, TimeSpan timeout, Action<long, long>? progress = null, CancellationToken ct = default)
    {
        await RenewIfDueAsync(ct);
        var answer = await RawUploadAsync(path, query, contentType, bodyFile, timeout, progress, ct);
        if (answer.Status == 401 && await RefreshAfter401Async(ct))
            answer = await RawUploadAsync(path, query, contentType, bodyFile, timeout, progress, ct);
        SaveCookiesIfChanged();
        if (!answer.Ok) throw HttpError(answer);
        return answer.Body;
    }

    /// GETs into `file` (never into memory). Past `ceiling` bytes → GatewayException "too-large" and no file is left.
    /// Returns the answer's content type. A non-2xx answer throws GatewayException "http".
    public async Task<string?> DownloadToFileAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string file,
        long ceiling, Action<long, long>? progress = null, CancellationToken ct = default)
    {
        await RenewIfDueAsync(ct);
        var (status, type, body, headers) = await RawDownloadAsync(path, query, file, ceiling, progress, ct);
        if (status == 401 && await RefreshAfter401Async(ct))
            (status, type, body, headers) = await RawDownloadAsync(path, query, file, ceiling, progress, ct);
        SaveCookiesIfChanged();
        if (status is < 200 or >= 300) throw HttpError(new HttpAnswer(status, body, headers!));
        return type;
    }

    private async Task RenewIfDueAsync(CancellationToken ct)
    {
        if (Account.Nous is { } n && n.NeedsRenewal(DateTimeOffset.UtcNow)) await RefreshAsync(n, ct);
        else if (Account.Nous is { } m && m.RenewsAlongside(DateTimeOffset.UtcNow)) _ = RenewQuietly(m);
    }

    private void Decorate(HttpRequestMessage req)
    {
        if (Account.Nous is { } n) req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", n.AccessToken);
    }

    private async Task<HttpAnswer> RawUploadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query,
        string contentType, string bodyFile, TimeSpan timeout, Action<long, long>? progress, CancellationToken ct)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout);
        await using var file = new FileStream(bodyFile, FileMode.Open, FileAccess.Read, FileShare.Read, 64 * 1024, useAsync: true);
        var total = file.Length;
        var content = new StreamContent(new ProgressStream(file, sent =>
        {
            cts.CancelAfter(timeout); // idle timeout: each block sent restarts it
            progress?.Invoke(sent, total);
        }), 64 * 1024);
        content.Headers.ContentType = MediaTypeHeaderValue.Parse(contentType);
        content.Headers.ContentLength = total;
        using var req = new HttpRequestMessage(HttpMethod.Post, Address.Endpoint(path, query)) { Content = content };
        Decorate(req);
        try
        {
            using var res = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cts.Token);
            var body = await ReadCapped(res.Content, 1 << 20, cts.Token);
            return new HttpAnswer((int)res.StatusCode, body, res.Headers);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new GatewayException("timeout", "The gateway took too long to answer.");
        }
        catch (HttpRequestException e)
        {
            throw new GatewayException("offline", "Can't reach the gateway. " + e.Message);
        }
    }

    private async Task<(int Status, string? Type, string Body, HttpResponseHeaders? Headers)> RawDownloadAsync(string path,
        IEnumerable<KeyValuePair<string, string>>? query, string file, long ceiling, Action<long, long>? progress,
        CancellationToken ct)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var idle = TimeSpan.FromSeconds(60);
        cts.CancelAfter(idle);
        using var req = new HttpRequestMessage(HttpMethod.Get, Address.Endpoint(path, query));
        Decorate(req);
        var partial = file + ".partial";
        try
        {
            using var res = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cts.Token);
            var status = (int)res.StatusCode;
            if (status is < 200 or >= 300)
                return (status, null, await ReadCapped(res.Content, 64 * 1024, cts.Token), res.Headers);
            var expected = res.Content.Headers.ContentLength ?? -1;
            if (expected > ceiling) throw new GatewayException("too-large", "The file is too large.", status);
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            await using (var input = await res.Content.ReadAsStreamAsync(cts.Token))
            await using (var output = new FileStream(partial, FileMode.Create, FileAccess.Write, FileShare.None, 64 * 1024, useAsync: true))
            {
                var buffer = new byte[64 * 1024];
                long received = 0;
                int n;
                while ((n = await input.ReadAsync(buffer, cts.Token)) > 0)
                {
                    received += n;
                    if (received > ceiling) throw new GatewayException("too-large", "The file is too large.", status);
                    await output.WriteAsync(buffer.AsMemory(0, n), cts.Token);
                    cts.CancelAfter(idle);
                    progress?.Invoke(received, expected);
                }
            }
            File.Move(partial, file, overwrite: true);
            return (status, res.Content.Headers.ContentType?.MediaType, "", res.Headers);
        }
        catch (Exception e)
        {
            TryDelete(partial);
            if (e is OperationCanceledException && !ct.IsCancellationRequested)
                throw new GatewayException("timeout", "The gateway took too long to answer.");
            if (e is HttpRequestException h) throw new GatewayException("offline", "Can't reach the gateway. " + h.Message);
            throw;
        }
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    private static async Task<string> ReadCapped(HttpContent content, int max, CancellationToken ct)
    {
        await using var s = await content.ReadAsStreamAsync(ct);
        var buffer = new byte[max];
        var total = 0;
        int n;
        while (total < max && (n = await s.ReadAsync(buffer.AsMemory(total, max - total), ct)) > 0) total += n;
        return System.Text.Encoding.UTF8.GetString(buffer, 0, total);
    }

    /// Reports the bytes read so far (what has gone out on an upload).
    private sealed class ProgressStream(Stream inner, Action<long> report) : Stream
    {
        private long _done;
        public override bool CanRead => true;
        public override bool CanSeek => inner.CanSeek;
        public override bool CanWrite => false;
        public override long Length => inner.Length;
        public override long Position { get => inner.Position; set { inner.Position = value; _done = value; } }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) => Note(inner.Read(buffer, offset, count));
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default) =>
            Note(await inner.ReadAsync(buffer, ct));
        public override async Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken ct) =>
            Note(await inner.ReadAsync(buffer.AsMemory(offset, count), ct));
        public override long Seek(long offset, SeekOrigin origin) { var p = inner.Seek(offset, origin); _done = p; return p; }
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

        private int Note(int n)
        {
            if (n > 0) { _done += n; report(_done); }
            return n;
        }
    }
}
