// [WIN-SCREEN-SOCKET-STREAM] One attach's picture stream (docs/spec/3x-screen.md §2.3, §3.2, §5.11), ported from the
// Mac's HermesKit/Screen/ScreenStream.swift at 93f984bb1: socket → parser → decoders → a finished picture on the UI
// thread. Everything up to the picture runs on the stream's own tasks; the UI thread only shows it. Pull model: the next
// FramebufferUpdateRequest goes out only after the frame was handed to the UI thread, so there is never more than one
// request outstanding and a slow link gets fewer frames, not a queue.
//
// The Mac's main actor is `onMain` (runs a callback on the UI thread and completes when it has run; default: inline)
// and `isMain` (default: never). The CGImage is the framebuffer's BGRX snapshot (`Width * 4` a row).

using System.Diagnostics;
using System.Globalization;
using System.Threading.Channels;

namespace Hermes.Core.Screen;

public enum ScreenStuckVerdict { Stuck, NoPicture }

/// The stuck rule (DECISION D12): the stream is waiting for bytes it was promised (the handshake, or an update that
/// has begun) and none came for `Limit`, or one decode has run for `Limit`. A slow link that keeps delivering is not
/// stuck, however long the frame takes; silence between updates is normal (nothing on the desktop changed).
///
/// The first picture is its own wait (review finding 3): once the handshake is done the server owes a picture but may
/// not have one yet (the Mac helper writes a frame only when it has captured one: sharing paused from its menu, the
/// display asleep, capture slow to start). That wait gets `FirstLimit` (20 s, the same patience as the status), and
/// ends as `NoPicture`, not as a stuck stream. A first picture that has begun and then stalls is stuck at `Limit`.
public record struct ScreenStuckRule
{
    public ScreenStuckRule(double lastByte, double limit = 8, double firstLimit = 20, bool waiting = true, bool awaitingFirst = false,
        double? decodingSince = null)
    {
        LastByte = lastByte;
        Limit = limit;
        FirstLimit = firstLimit;
        Waiting = waiting;
        AwaitingFirst = awaitingFirst;
        DecodingSince = decodingSince;
    }

    public double Limit { get; set; }
    public double FirstLimit { get; set; }
    /// Handshake not finished, first picture owed, or mid-update.
    public bool Waiting { get; set; }
    /// The handshake is done and no byte of the first picture has come yet.
    public bool AwaitingFirst { get; set; }
    public double LastByte { get; set; }
    public double? DecodingSince { get; set; }

    public readonly ScreenStuckVerdict? Verdict(double now)
    {
        if (DecodingSince is { } since && now - since >= Limit) return ScreenStuckVerdict.Stuck;
        if (!Waiting) return null;
        if (AwaitingFirst) return now - LastByte >= Math.Max(Limit, FirstLimit) ? ScreenStuckVerdict.NoPicture : null;
        return now - LastByte >= Limit ? ScreenStuckVerdict.Stuck : null;
    }

    public readonly bool IsStuck(double now) => Verdict(now) != null;
}

public record struct ScreenPacing
{
    public int Frames { get; set; }
    public int Rects { get; set; }
    public int MainThreadDecodes { get; set; }
    public double P50Ms { get; set; }
    public double P95Ms { get; set; }
    public int Serial { get; set; }
    public int Width { get; set; }
    public int Height { get; set; }
    public string Probe { get; set; }
    public int FailedJpegs { get; set; }

    public ScreenPacing() => Probe = "";

    /// The stage's debug value (UI tests and the stress tester read it).
    public readonly string Summary => string.Create(CultureInfo.InvariantCulture,
        $"frames={Frames} rects={Rects} size={Width}x{Height} mainDecodes={MainThreadDecodes} p50={P50Ms:F1} p95={P95Ms:F1} serial={Serial} probe={Probe}");
}

/// How a stream ended (the Swift `ScreenStream.End`).
public abstract record ScreenStreamEnd
{
    /// The socket ended: the gateway's close code and reason when it sent a close frame.
    public sealed record Closed(int? Code, string? Reason) : ScreenStreamEnd;
    /// Bad data (the parser's typed error) or a text frame.
    public sealed record Failed(string Name) : ScreenStreamEnd;
    /// The stuck rule fired, or a ping went unanswered.
    public sealed record Stuck : ScreenStreamEnd;
    /// The handshake finished and no picture came for the first-picture limit (the socket itself was fine).
    public sealed record NoPicture : ScreenStreamEnd;
}

public sealed class ScreenStream
{
    /// The log's category, and what it writes (content-free).
    public const string LogCategory = "screen";

    private sealed class Shared
    {
        public ScreenStuckRule Rule;
        public ScreenPacing Pacing = new();
        public readonly List<double> Samples = [];
        public bool Ended;
        public bool? StopHandBack;
        public bool Stopped => StopHandBack.HasValue;
        public bool Live;
        /// Local close issued: true by the FIFO sender, false by a failure or the cutoff. Not a peer acknowledgment.
        public readonly TaskCompletionSource<bool> CloseIssued = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private int _closing;

        public void Close(IScreenSocket socket, bool handBack, bool flushed)
        {
            if (Interlocked.Exchange(ref _closing, 1) != 0) return;
            socket.Close(handBack);
            CloseIssued.TrySetResult(flushed);
        }
    }

    private abstract record Out
    {
        public sealed record Data(byte[] Bytes) : Out;
        public sealed record Drain(TaskCompletionSource Done) : Out;
        public sealed record Close(bool HandBack) : Out;
    }

    private readonly IScreenSocket _socket;
    private readonly Shared _shared;
    private readonly object _gate = new();
    private readonly Channel<Out> _outbox = Channel.CreateUnbounded<Out>(new UnboundedChannelOptions { SingleReader = true });
    private readonly CancellationTokenSource _tasks = new();
    private readonly Func<double> _now;
    private readonly TimeSpan _pingEvery;
    private readonly Action<int, int> _onReady;
    private readonly Action<byte[], int, int, int> _onFrame;
    private readonly Action<ScreenStreamEnd> _onEnd;
    private readonly Func<Action, Task> _onMain;
    private readonly Func<bool> _isMain;
    private readonly Action<string>? _note;

    /// The ping's own limit (the Mac's `ping(timeout: .seconds(10))`).
    public static readonly TimeSpan PingTimeout = TimeSpan.FromSeconds(10);
    /// How long `Stop` lets the flush and the close go out before the socket is cut.
    public static readonly TimeSpan StopCut = TimeSpan.FromMilliseconds(250);
    internal TimeProvider FlushClock { get; init; } = TimeProvider.System;
    internal Task WritesEnded => _shared.CloseIssued.Task;
    /// The watchdog's tick.
    public static readonly TimeSpan WatchdogTick = TimeSpan.FromMilliseconds(250);
    /// The update-time samples the percentiles are taken over.
    public const int SampleCount = 120;

    private static readonly long Uptime0 = Stopwatch.GetTimestamp();
    private static double Uptime() => Stopwatch.GetElapsedTime(Uptime0).TotalSeconds;

    /// `onFrame(picture, width, height, serial)` runs through `onMain`; the next request is sent after it has run.
    /// `onEnd` is called once, and never after `Stop`. `note` gets the log lines (category `LogCategory`).
    public ScreenStream(IScreenSocket socket, Action<int, int> onReady, Action<byte[], int, int, int> onFrame, Action<ScreenStreamEnd> onEnd,
        double stuckAfter = 8, double firstPictureWait = 20, TimeSpan? pingEvery = null, Func<double>? now = null,
        Func<Action, Task>? onMain = null, Func<bool>? isMain = null, Action<string>? note = null)
    {
        _socket = socket;
        _now = now ?? Uptime;
        _pingEvery = pingEvery ?? TimeSpan.FromSeconds(20);
        _onReady = onReady;
        _onFrame = onFrame;
        _onEnd = onEnd;
        _onMain = onMain ?? (action => { action(); return Task.CompletedTask; });
        _isMain = isMain ?? (() => false);
        _note = note;
        _shared = new Shared { Rule = new ScreenStuckRule(lastByte: _now(), limit: stuckAfter, firstLimit: firstPictureWait) };
    }

    ~ScreenStream()
    {
        // After `Stop` the close is already arranged (the flush, then the close frame asked for): cutting the socket
        // here would lose a button-up, or turn a hand-back into a dropped link.
        bool stopped;
        lock (_gate) stopped = _shared.Stopped;
        if (stopped) return;
        _outbox.Writer.TryComplete();
        try { _tasks.Cancel(); } catch (ObjectDisposedException) { }
        _socket.Close(handBack: false);
    }

    public ScreenPacing Pacing { get { lock (_gate) return _shared.Pacing; } }
    public bool IsLive { get { lock (_gate) return _shared.Live; } }

    private void Note(string line) => _note?.Invoke(line);

    public void Start()
    {
        var owner = new WeakReference<ScreenStream>(this);
        IScreenSocket socket = _socket;
        var reader = _outbox.Reader;
        var shared = _shared;
        var ct = _tasks.Token;
        _ = Task.Run(() => SendLoop(owner, socket, reader, shared, ct));
        _ = Task.Run(() => ReceiveLoop(owner, socket, ct));
        _ = Task.Run(() => Watchdog(owner, ct));
    }

    private static ScreenStream? Owner(WeakReference<ScreenStream> owner) => owner.TryGetTarget(out var stream) ? stream : null;

    private static async Task SendLoop(WeakReference<ScreenStream> owner, IScreenSocket socket, ChannelReader<Out> reader, Shared shared,
        CancellationToken ct)
    {
        try
        {
            while (await reader.WaitToReadAsync(ct))
            {
                while (reader.TryRead(out var item))
                {
                    switch (item)
                    {
                        case Out.Data data:
                            try { await socket.SendAsync(data.Bytes, ct); }
                            catch (Exception)
                            {
                                // Audit 14-14: a send that fails ends the stream now, as a dropped link (it reconnects),
                                // rather than the picture freezing until the receive loop or the next ping notices.
                                if (ct.IsCancellationRequested) return;
                                SendFailed(owner, socket);
                                return;
                            }
                            break;
                        case Out.Drain drain:
                            drain.Done.TrySetResult(); // every preceding SendAsync returned successfully
                            break;
                        case Out.Close close:
                            shared.Close(socket, close.HandBack, flushed: true);
                            return;
                    }
                }
            }
        }
        catch (OperationCanceledException) { }
    }

    private static void SendFailed(WeakReference<ScreenStream> owner, IScreenSocket socket)
    {
        var stream = Owner(owner);
        stream?.Note("send failed");
        stream?.Finish(new ScreenStreamEnd.Closed(socket.CloseCode, socket.CloseReason));
    }

    private static async Task Watchdog(WeakReference<ScreenStream> owner, CancellationToken ct)
    {
        var sincePing = Stopwatch.StartNew();
        while (!ct.IsCancellationRequested)
        {
            try { await Task.Delay(WatchdogTick, ct); } catch (OperationCanceledException) { return; }
            if (ct.IsCancellationRequested) return;
            if (!await Tick(owner, sincePing)) return;
        }
    }

    /// One watchdog tick; false: the watchdog is done. The stream is held only for the tick.
    private static async Task<bool> Tick(WeakReference<ScreenStream> owner, Stopwatch sincePing)
    {
        if (!owner.TryGetTarget(out var self)) return false;
        bool live;
        ScreenStuckVerdict? verdict;
        lock (self._gate)
        {
            if (self._shared.Ended || self._shared.Stopped) return false;
            verdict = self._shared.Rule.Verdict(self._now());
            live = self._shared.Live;
        }
        if (verdict is { } v)
        {
            self.Note(v == ScreenStuckVerdict.NoPicture ? "no first picture" : "stream stuck");
            self.Finish(v == ScreenStuckVerdict.NoPicture ? new ScreenStreamEnd.NoPicture() : new ScreenStreamEnd.Stuck());
            return false;
        }
        if (live && sincePing.Elapsed >= self._pingEvery)
        {
            sincePing.Restart();
            if (!await self._socket.PingAsync(PingTimeout))
            {
                lock (self._gate) { if (self._shared.Ended || self._shared.Stopped) return false; }
                self.Note("ping unanswered");
                self.Finish(new ScreenStreamEnd.Stuck());
                return false;
            }
        }
        return true;
    }

    /// An input or request message, sent in order after everything queued before it.
    public void Send(byte[] data)
    {
        lock (_gate) { if (_shared.Stopped) return; }
        _outbox.Writer.TryWrite(new Out.Data(data));
    }

    /// A local FIFO fence for an ordinary hand-back. No bytes are added to the wire. If the sender is stuck,
    /// cut this transport before relinquishing control: queued input must not drain later against the next lease.
    internal async Task DrainBeforeHandBack()
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_gate)
        {
            if (!_shared.Stopped && !_shared.Ended) _outbox.Writer.TryWrite(new Out.Drain(done));
        }
        try { await Task.WhenAny(done.Task, WritesEnded).WaitAsync(StopCut, FlushClock).ConfigureAwait(false); }
        catch (TimeoutException)
        {
            // Do not start a second budget if a pause/leave also requested a close during the drain.
            Finish(new ScreenStreamEnd.Closed(null, null), cutEvenIfStopping: true);
            await WritesEnded.ConfigureAwait(false);
        }
    }

    /// Ends the stream on purpose: `flush` (button-up, key-up) goes out first, then the socket closes — with a 1000
    /// close frame when `handBack`, else with none. Bounded: after 250 ms the socket is cut whatever is still queued.
    /// `onEnd` is not called.
    public void Stop(bool handBack, IReadOnlyList<byte[]>? flush = null)
    {
        lock (_gate)
        {
            if (_shared.Stopped || _shared.Ended) return;
            _shared.StopHandBack = handBack;
        }
        var writer = _outbox.Writer;
        foreach (var data in flush ?? []) writer.TryWrite(new Out.Data(data));
        writer.TryWrite(new Out.Close(handBack));
        IScreenSocket socket = _socket;
        var tasks = _tasks;
        var shared = _shared;
        var clock = FlushClock;
        _ = CutAfterLimit();
        async Task CutAfterLimit()
        {
            await Task.Delay(StopCut, clock).ConfigureAwait(false);
            shared.Close(socket, handBack, flushed: false);
            writer.TryComplete();
            try { tasks.Cancel(); } catch (ObjectDisposedException) { }
        }
    }

    /// `Stop`, then waits (at most `limit`, default 400 ms) until the sender has written the flush and closed the socket
    /// as asked. true: the close the caller asked for went out in order. false: the socket was cut by the clock, or the
    /// stream had already been stopped or had ended, so nothing can be said about a hand-back.
    public async Task<bool> StopAndWait(bool handBack, IReadOnlyList<byte[]>? flush = null, TimeSpan? limit = null)
    {
        bool already;
        lock (_gate) already = _shared.Stopped || _shared.Ended;
        if (already)
        {
            Stop(handBack, flush);
            return false;
        }
        Stop(handBack, flush);
        try { return await _shared.CloseIssued.Task.WaitAsync(limit ?? TimeSpan.FromMilliseconds(400)); }
        catch (TimeoutException) { return false; }
    }

    private void Finish(ScreenStreamEnd end, bool cutEvenIfStopping = false)
    {
        bool? stop;
        lock (_gate)
        {
            stop = _shared.StopHandBack;
            if (_shared.Ended || (stop.HasValue && !cutEvenIfStopping)) return;
            _shared.Ended = true;
            _shared.Live = false;
        }
        _shared.Close(_socket, handBack: stop ?? false, flushed: false);
        _outbox.Writer.TryComplete();
        var onEnd = _onEnd;
        if (!stop.HasValue) _ = _onMain(() => onEnd(end));
        try { _tasks.Cancel(); } catch (ObjectDisposedException) { }
    }

    // The receive loop (off the UI thread)

    /// What the loop keeps between frames (the Swift loop's locals).
    private sealed class Loop
    {
        public readonly RfbParser Parser = new();
        public int Serial;
        public double DecodeTime;
        public bool Handshaken;
        /// H25: latches `out_.Resized` across frames with 0 updates so the next request asks `incremental: false`.
        public bool PendingResized;
    }

    /// `owner` is asked for the stream each time something arrives, so a stream nobody holds any more is not kept
    /// alive by its own loop.
    private static async Task ReceiveLoop(WeakReference<ScreenStream> owner, IScreenSocket socket, CancellationToken ct)
    {
        var loop = new Loop();
        while (!ct.IsCancellationRequested)
        {
            ScreenSocketFrame frame;
            try { frame = await socket.ReceiveAsync(ct); }
            catch (Exception)
            {
                Owner(owner)?.Finish(new ScreenStreamEnd.Closed(socket.CloseCode, socket.CloseReason));
                return;
            }
            if (!await Handle(owner, frame, loop, ct)) return;
        }
    }

    private readonly record struct Decoded(RfbParser.Output Out, byte[]? Image, int Width, int Height, string Probe, double Began, double Ended);

    /// One frame; false: the loop is done. The stream is held only while the frame is handled.
    private static async Task<bool> Handle(WeakReference<ScreenStream> owner, ScreenSocketFrame frame, Loop loop, CancellationToken ct)
    {
        if (!owner.TryGetTarget(out var stream) || ct.IsCancellationRequested) return false;
        if (frame is not ScreenSocketFrame.Binary binary)
        {
            stream.Note("text frame");
            stream.Finish(new ScreenStreamEnd.Failed("text-frame"));
            return false;
        }
        Decoded decoded;
        try { decoded = stream.Decode(binary.Data, loop); }
        catch (RfbException error)
        {
            stream.Note($"bad data {error.Error.LogName}");
            stream.Finish(new ScreenStreamEnd.Failed(error.Error.LogName));
            return false;
        }
        var out_ = decoded.Out;
        foreach (var reply in out_.Send) stream._outbox.Writer.TryWrite(new Out.Data(reply));
        var parser = loop.Parser;
        loop.DecodeTime += decoded.Ended - decoded.Began;
        var spent = loop.DecodeTime;
        var pictured = loop.Serial > 0 || out_.Updates > 0;
        if (out_.Ready) loop.Handshaken = true;
        var awaitingFirst = loop.Handshaken && !pictured && !parser.MidUpdate;
        lock (stream._gate)
        {
            var state = stream._shared;
            state.Rule.DecodingSince = null;
            state.Rule.Waiting = !pictured || parser.MidUpdate;
            state.Rule.AwaitingFirst = awaitingFirst;
            state.Rule.LastByte = decoded.Ended;
            state.Pacing.Rects += out_.Rects;
            state.Pacing.FailedJpegs = parser.FailedJpegs;
            if (out_.Updates > 0)
            {
                state.Samples.Add(spent);
                if (state.Samples.Count > SampleCount) state.Samples.RemoveRange(0, state.Samples.Count - SampleCount);
                var sorted = state.Samples.Order().ToList();
                state.Pacing.P50Ms = sorted[(sorted.Count - 1) / 2] * 1000;
                state.Pacing.P95Ms = sorted[Math.Min(sorted.Count - 1, (int)((sorted.Count - 1) * 0.95))] * 1000;
                state.Pacing.Width = decoded.Width;
                state.Pacing.Height = decoded.Height;
                state.Pacing.Probe = decoded.Probe;
            }
        }
        if (out_.Ready)
        {
            stream.Note($"live {decoded.Width}x{decoded.Height}");
            var onReady = stream._onReady;
            int w = decoded.Width, h = decoded.Height;
            await stream._onMain(() => onReady(w, h));
        }
        loop.PendingResized = loop.PendingResized || out_.Resized;
        if (out_.Updates == 0) return true;
        var resized = loop.PendingResized;
        loop.PendingResized = false;
        loop.DecodeTime = 0;
        loop.Serial += 1;
        if (decoded.Image is { } image)
        {
            var onFrame = stream._onFrame;
            int w = decoded.Width, h = decoded.Height, number = loop.Serial;
            await stream._onMain(() => onFrame(image, w, h, number));
        }
        lock (stream._gate)
        {
            stream._shared.Pacing.Frames += 1;
            stream._shared.Pacing.Serial = loop.Serial;
            stream._shared.Live = true;
        }
        // Only now that the frame is on the UI thread: ask for the next one (the whole picture after a resize).
        stream.Send(RfbMessage.UpdateRequest(incremental: !resized, width: decoded.Width, height: decoded.Height));
        return true;
    }

    /// Feeds the parser one frame and takes what the UI needs from it (no awaits: the span never crosses one).
    private Decoded Decode(byte[] data, Loop loop)
    {
        var began = _now();
        var onMain = _isMain();
        lock (_gate)
        {
            _shared.Rule.LastByte = began;
            _shared.Rule.DecodingSince = began;
            if (onMain) _shared.Pacing.MainThreadDecodes += 1;
        }
        var parser = loop.Parser;
        var out_ = parser.Feed(data);
        var framebuffer = parser.Framebuffer;
        var image = out_.Updates > 0 ? framebuffer?.Snapshot() : null;
        var probe = out_.Updates > 0 ? framebuffer?.Probe() ?? "" : "";
        return new Decoded(out_, image, framebuffer?.Width ?? 0, framebuffer?.Height ?? 0, probe, began, _now());
    }
}
