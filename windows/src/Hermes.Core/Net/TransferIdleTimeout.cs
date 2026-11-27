using System.Net;

namespace Hermes.Core.Net;

// LiveGatewayClient.transfer gives URLRequest an *inactivity* interval, not a limit on the whole recording.
// The timer wakes a stuck transfer. The monotonic check also rejects a late answer if I/O runs before an overdue timer.
internal sealed class TransferIdleTimeout : IDisposable
{
    private readonly TimeProvider _clock;
    private readonly TimeSpan _interval;
    private readonly CancellationTokenSource _timer;
    private readonly CancellationTokenSource _linked;
    private readonly object _gate = new();
    private long _last;

    public TransferIdleTimeout(TimeSpan interval, TimeProvider clock, CancellationToken caller)
    {
        _clock = clock;
        _interval = interval;
        _last = clock.GetTimestamp();
        _timer = new CancellationTokenSource(interval, clock);
        _linked = CancellationTokenSource.CreateLinkedTokenSource(caller, _timer.Token);
    }

    private CancellationToken Token => _linked.Token;
    public bool TimedOut => _timer.IsCancellationRequested;

    private void Progress()
    {
        lock (_gate)
        {
            Token.ThrowIfCancellationRequested();
            var now = _clock.GetTimestamp();
            if (_clock.GetElapsedTime(_last, now) >= _interval) throw new OperationCanceledException(Token);
            _last = now;
            _timer.CancelAfter(_interval);
        }
    }

    private const int Chunk = 16 * 1024;
    public HttpContent Content(byte[] bytes) => bytes.Length == 0 ? new ByteArrayContent(bytes) : new Upload(bytes, this);

    private sealed class Upload(byte[] bytes, TransferIdleTimeout owner) : HttpContent
    {
        protected override bool TryComputeLength(out long length) { length = bytes.LongLength; return true; }
        protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) => WriteTo(stream, owner.Token);
        protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context, CancellationToken ct) => WriteTo(stream, ct);
        private async Task WriteTo(Stream stream, CancellationToken ct)
        {
            for (var at = 0; at < bytes.Length;)
            {
                int count = Math.Min(Chunk, bytes.Length - at);
                await stream.WriteAsync(bytes.AsMemory(at, count), ct).ConfigureAwait(false);
                owner.Progress();
                at += count;
            }
        }
    }

    public async Task<ByteAnswer> ReadAsync(HttpClient http, HttpRequestMessage request)
    {
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, Token).ConfigureAwait(false);
        Progress();
        // ResponseHeadersRead no longer applies HttpClient's built-in buffering ceiling: keep the same bound.
        long limit = http.MaxResponseContentBufferSize;
        if (response.Content.Headers.ContentLength > limit) throw TooLarge();
        using var input = await response.Content.ReadAsStreamAsync(Token).ConfigureAwait(false);
        using var body = new MemoryStream();
        var buffer = new byte[Chunk];
        while (true)
        {
            int count = await input.ReadAsync(buffer.AsMemory(), Token).ConfigureAwait(false);
            Progress();
            if (count == 0) break;
            if (body.Length + count > limit) throw TooLarge();
            body.Write(buffer, 0, count);
        }
        return new((int)response.StatusCode, body.ToArray(), response.Headers);
    }

    private static HttpRequestException TooLarge() => new(HttpRequestError.ConfigurationLimitExceeded, "The response exceeds the buffer limit.");
    public void Dispose() { _linked.Dispose(); _timer.Dispose(); }
}
