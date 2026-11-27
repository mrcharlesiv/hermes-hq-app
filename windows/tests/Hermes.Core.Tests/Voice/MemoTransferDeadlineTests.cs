using System.Net;
using Hermes.Core.Auth;
using Hermes.Core.Net;
using Hermes.Core.Voice;

namespace Hermes.Core.Tests.Voice;

public sealed class MemoTransferDeadlineTests
{
    // Advance I/O time even when the scheduler has not dispatched a due timer. No sleeps or load generation.
    private sealed class Clock : TimeProvider
    {
        private readonly ManualTime _callbacks = new();
        private long _now;
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;
        public override long GetTimestamp() => Interlocked.Read(ref _now);
        public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan due, TimeSpan period) =>
            _callbacks.CreateTimer(callback, state, due, period);
        public void Advance(int ms, bool fire = true)
        {
            var d = TimeSpan.FromMilliseconds(ms);
            Interlocked.Add(ref _now, d.Ticks);
            if (fire) _callbacks.Advance(d);
        }
    }

    private sealed class Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage req, CancellationToken ct) => send(req, ct);
    }
    private const string Url = "http://127.0.0.1:9"; // no socket: every request is answered by the supplied handler
    private static GatewaySession Session(HttpMessageHandler handler) => new(GatewayAddress.Validated(Url), new StoredAccount(Url, "fixture"), new MemoryTokenStore(), handler);
    private static Task<byte[]> Transfer(GatewaySession session, Clock clock, double limit, byte[]? body = null, CancellationToken ct = default) =>
        new HermesMemoGateway(session, () => "fixture", clock).TransferAsync("POST", "/api/audio/transcribe", [], body, "application/octet-stream", limit, ct);

    [Theory]
    [InlineData(.01, 300, true)]
    [InlineData(.01, 999, true)]
    [InlineData(.01, 1000, false)]
    [InlineData(.01, 1600, false)]
    [InlineData(2.5, 2499, true)]
    [InlineData(2.5, 2500, false)]
    [InlineData(900, 599999, true)]
    [InlineData(900, 600000, false)]
    public async Task ASilentResponseUsesTheClampedDeadlineEvenBeforeTimerDispatch(double requested, int milliseconds, bool accepted)
    {
        var clock = new Clock();
        using var session = Session(new Handler((_, ct) =>
        {
            clock.Advance(milliseconds, fire: false);
            Assert.False(ct.IsCancellationRequested); // this is specifically I/O ahead of a timer callback
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([42]) });
        }));
        var call = Transfer(session, clock, requested);
        if (accepted) Assert.Equal(new byte[] { 42 }, await call);
        else Assert.Equal("timeout", (await Assert.ThrowsAsync<GatewayException>(() => call)).Code);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task TheTimerWakesATransferWithoutAnyResponseAndCallerCancellationStaysDistinct(bool callerCancels)
    {
        var clock = new Clock();
        using var caller = new CancellationTokenSource();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var session = Session(new Handler(async (_, ct) =>
        {
            entered.SetResult();
            await Task.Delay(Timeout.InfiniteTimeSpan, ct);
            throw new InvalidOperationException("must not complete normally");
        }));
        var call = Transfer(session, clock, .01, ct: caller.Token);
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(10));
        clock.Advance(999);
        Assert.False(call.IsCompleted);
        if (callerCancels) caller.Cancel();
        else clock.Advance(1);
        var bounded = call.WaitAsync(TimeSpan.FromSeconds(10));
        if (callerCancels) await Assert.ThrowsAnyAsync<OperationCanceledException>(() => bounded);
        else Assert.Equal("timeout", (await Assert.ThrowsAsync<GatewayException>(() => bounded)).Code);
    }

    private sealed class Body(Clock clock, int secondGap) : MemoryStream(new byte[] { 0, 127, 255 })
    {
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default)
        {
            clock.Advance(Position == 1 ? secondGap : 700, fire: true);
            return base.ReadAsync(buffer[..1], ct);
        }
    }
    [Theory]
    [InlineData(700, true)]
    [InlineData(1200, false)]
    public async Task TheResponseMayLastLongerThanTheIntervalButEachGapMustFit(int gap, bool accepted)
    {
        var clock = new Clock();
        using var session = Session(new Handler((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(new Body(clock, gap)) })));
        var call = Transfer(session, clock, 1);
        if (accepted) Assert.Equal(new byte[] { 0, 127, 255 }, await call);
        else Assert.Equal("timeout", (await Assert.ThrowsAsync<GatewayException>(() => call)).Code);
    }

    private sealed class Drop(Action beforeDrop) : MemoryStream
    {
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default)
        {
            beforeDrop();
            throw new IOException("synthetic disconnect");
        }
    }
    [Theory]
    [InlineData("offline")]
    [InlineData("timeout")]
    [InlineData("caller")]
    public async Task ADisconnectDuringTheBodyPreservesItsCause(string expected)
    {
        var clock = new Clock();
        using var stop = new CancellationTokenSource();
        using var session = Session(new Handler((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StreamContent(new Drop(() =>
            {
                if (expected == "caller") stop.Cancel();
                if (expected == "timeout") clock.Advance(1000);
            }))
        })));
        var call = Transfer(session, clock, 1, ct: stop.Token);
        if (expected == "caller") await Assert.ThrowsAnyAsync<OperationCanceledException>(() => call);
        else Assert.Equal(expected, (await Assert.ThrowsAsync<GatewayException>(() => call)).Code);
    }

    [Theory]
    [InlineData(3L)]
    [InlineData(null)]
    public async Task TheStreamingReaderStillEnforcesTheHttpClientsBufferLimit(long? declared)
    {
        using var client = new HttpClient(new Handler((_, _) =>
        {
            var content = new ByteArrayContent([1, 2, 3]);
            content.Headers.ContentLength = declared;
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = content });
        })) { MaxResponseContentBufferSize = 2 };
        using var req = new HttpRequestMessage(HttpMethod.Get, Url);
        using var idle = new TransferIdleTimeout(TimeSpan.FromSeconds(1), new Clock(), default);
        var error = await Assert.ThrowsAsync<HttpRequestException>(() => idle.ReadAsync(client, req));
        Assert.Equal(HttpRequestError.ConfigurationLimitExceeded, error.HttpRequestError);
    }

    private sealed class Sink(Clock clock, int stallAt) : MemoryStream
    {
        private int _writes;
        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken ct = default)
        {
            clock.Advance(++_writes == stallAt ? 1200 : 650);
            return base.WriteAsync(buffer, ct);
        }
    }
    [Theory]
    [InlineData(-1, true)]
    [InlineData(2, false)]
    public async Task WritesMakeProgressWithoutChangingTheUploadedBytes(int stallAt, bool accepted)
    {
        var clock = new Clock();
        var body = new byte[64 * 1024 + 3];
        new Random(42).NextBytes(body);
        using var session = Session(new Handler(async (req, ct) =>
        {
            using var sink = new Sink(clock, stallAt);
            await req.Content!.CopyToAsync(sink, ct);
            Assert.True(clock.GetTimestamp() > TimeSpan.TicksPerSecond);
            Assert.Equal(body, sink.ToArray());
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([7]) };
        }));
        var call = Transfer(session, clock, 1, body);
        if (accepted) Assert.Equal(new byte[] { 7 }, await call);
        else Assert.Equal("timeout", (await Assert.ThrowsAsync<GatewayException>(() => call)).Code);
    }
}
