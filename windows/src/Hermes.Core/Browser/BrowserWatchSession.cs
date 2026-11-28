// One live view of a bot's browser (the plugin's `WS /sessions/{id}/watch`, stream.py): hello, the view size, state and
// frames in, acks out once a frame is drawn, the person's input while they hold it, and reconnects.
// C# twin of HermesKit/Browser/BrowserWatchSession.swift. Frames are parsed and decoded off the main thread;
// the main thread only puts the decoded image on screen. No page content, typed text or address is ever logged.

using System.Globalization;
using Hermes.Core.Screen;

namespace Hermes.Core.Browser;

/// A decoded browser frame: BGRA8 pixels ready for WinUI WriteableBitmap, plus dimensions.
public sealed record BrowserDecodedImage(int Width, int Height, byte[] Bgra);

/// Decodes JPEG bytes off the UI thread. Headless tests use ManagedBrowserImageDecoder (ScreenJpeg);
/// WinUI may plug in a WIC BitmapDecoder implementation for full baseline + progressive JPEG hardware speed.
public interface IBrowserImageDecoder
{
    BrowserDecodedImage? Decode(byte[] jpeg);
}

/// Zero-dependency baseline JPEG decoder backed by Hermes.Core.Screen.ScreenJpeg.
public sealed class ManagedBrowserImageDecoder : IBrowserImageDecoder
{
    public static readonly ManagedBrowserImageDecoder Instance = new();

    public BrowserDecodedImage? Decode(byte[] jpeg)
    {
        if (jpeg.Length < 4) return null;
        try
        {
            var decoded = ScreenJpeg.Decoder.Decode(jpeg);
            if (decoded == null) return null;
            var pixels = decoded.Width * decoded.Height;
            var bgra = new byte[pixels * 4];
            var rgb = decoded.Rgb;
            for (var i = 0; i < pixels; i++)
            {
                var src = i * 3;
                var dst = i * 4;
                bgra[dst] = rgb[src + 2];     // B
                bgra[dst + 1] = rgb[src + 1]; // G
                bgra[dst + 2] = rgb[src];     // R
                bgra[dst + 3] = 0xFF;         // A
            }
            return new BrowserDecodedImage(decoded.Width, decoded.Height, bgra);
        }
        catch (Exception) { return null; }
    }
}

/// One decoding frame and one waiting: a newer frame replaces the one waiting (which is acknowledged unseen so the
/// plugin's window moves on); stale pixels are never shown. Decodes off the caller's thread on the thread pool.
public sealed class BrowserFrameDecoder
{
    public readonly record struct DecoderStats(int Decoded, int MainThreadDecodes, int Skipped, int Failed);

    private readonly object _gate = new();
    private readonly IBrowserImageDecoder _imageDecoder;
    private readonly int _mainThreadId;
    private readonly Action<BrowserFrame, BrowserDecodedImage> _decoded;
    private readonly Action<int> _skipped;
    private readonly Action _failed;
    private bool _busy;
    private BrowserFrame? _waiting;
    private int _lastSeq;
    private bool _closed;
    private DecoderStats _stats;

    public BrowserFrameDecoder(
        Action<BrowserFrame, BrowserDecodedImage> decoded,
        Action<int> skipped,
        Action failed,
        IBrowserImageDecoder? imageDecoder = null,
        int? mainThreadId = null)
    {
        _decoded = decoded;
        _skipped = skipped;
        _failed = failed;
        _imageDecoder = imageDecoder ?? ManagedBrowserImageDecoder.Instance;
        _mainThreadId = mainThreadId ?? Environment.CurrentManagedThreadId;
    }

    public DecoderStats Stats { get { lock (_gate) return _stats; } }

    public bool Push(BrowserFrame frame)
    {
        int? replaced = null;
        var start = false;
        lock (_gate)
        {
            if (_closed || frame.Seq <= _lastSeq) return false;
            _lastSeq = frame.Seq;
            if (_busy)
            {
                if (_waiting is { } w)
                {
                    replaced = w.Seq;
                    _stats = _stats with { Skipped = _stats.Skipped + 1 };
                }
                _waiting = frame;
            }
            else
            {
                _busy = true;
                start = true;
            }
        }
        if (replaced is { } r) _skipped(r);
        if (start) _ = Task.Run(() => Run(frame));
        return true;
    }

    public void Close()
    {
        lock (_gate)
        {
            _closed = true;
            _waiting = null;
        }
    }

    private void Run(BrowserFrame first)
    {
        BrowserFrame? current = first;
        while (current != null)
        {
            var image = _imageDecoder.Decode(current.Jpeg);
            bool closed;
            lock (_gate)
            {
                _stats = image != null
                    ? _stats with { Decoded = _stats.Decoded + 1 }
                    : _stats with { Failed = _stats.Failed + 1 };
                if (Environment.CurrentManagedThreadId == _mainThreadId)
                    _stats = _stats with { MainThreadDecodes = _stats.MainThreadDecodes + 1 };
                closed = _closed;
            }
            if (closed) break;
            if (image == null)
            {
                Close();
                _failed();
                break;
            }
            _decoded(current, image);
            lock (_gate)
            {
                current = _closed ? null : _waiting;
                _waiting = null;
                if (current == null) _busy = false;
            }
        }
        lock (_gate) _busy = false;
    }
}

/// The frame pacing the viewer measured.
public readonly record struct BrowserPacing(int Frames = 0, double MedianMs = 0, double P95Ms = 0, int MainThreadDecodes = 0)
{
    public static BrowserPacing From(IReadOnlyList<double> intervals, int frames, int mainThreadDecodes)
    {
        var sorted = intervals.OrderBy(x => x).ToArray();
        double At(double q) => sorted.Length == 0 ? 0 : sorted[Math.Min(sorted.Length - 1, (int)((sorted.Length - 1) * q))] * 1000.0;
        return new BrowserPacing(frames, At(0.5), At(0.95), mainThreadDecodes);
    }

    public string Summary => string.Create(
        CultureInfo.InvariantCulture,
        $"frames={Frames} p50={MedianMs:0} p95={P95Ms:0} mainDecodes={MainThreadDecodes}");
}

public enum BrowserWatchLink { Idle, Connecting, Live, Reconnecting, Stalled }

public sealed class BrowserWatchSession
{
    public static TimeSpan WatchdogEvery { get; set; } = TimeSpan.FromSeconds(5);
    public static TimeSpan WatchdogSilence { get; set; } = TimeSpan.FromSeconds(25);

    private readonly object _gate = new();
    private readonly PendingTyping _pending = new();
    private readonly List<double> _intervals = [];
    private readonly string _viewer;

    private BrowserWatchLink _link = BrowserWatchLink.Idle;
    private BrowserViewState? _view;
    private IBrowserSocket? _socket;
    private CancellationTokenSource? _workCts;
    private CancellationTokenSource? _retryCts;
    private CancellationTokenSource? _watchdogCts;
    private BrowserFrameDecoder? _decoder;
    private int _dials;
    private int _attempt;
    private bool _stalled;
    private bool _shown;
    private bool _stopped;
    private long _nextAckTicks = System.Diagnostics.Stopwatch.GetTimestamp();
    private long _lastInbound = System.Diagnostics.Stopwatch.GetTimestamp();
    private double? _lastShown;
    private int _shownFrames;
    private (int Width, int Height, double Scale)? _wantedView;

    public BrowserService Service { get; }
    public string RowId { get; }
    public string Base { get; }
    public string Profile { get; }
    public string Name { get; }

    public BrowserWatchLink Link
    {
        get { lock (_gate) return _link; }
        private set
        {
            var changed = false;
            lock (_gate)
            {
                if (_link != value) { _link = value; changed = true; }
            }
            if (changed)
            {
                Service.Note?.Invoke($"watch link {value.ToString().ToLowerInvariant()}");
                OnChange?.Invoke();
            }
        }
    }

    public BrowserViewState? View
    {
        get { lock (_gate) return _view; }
        private set
        {
            var changed = false;
            lock (_gate)
            {
                if (_view != value) { _view = value; changed = true; }
            }
            if (changed) OnChange?.Invoke();
        }
    }

    /// The page's CSS size and tab of the frame on screen (null before the first).
    public (BrowserSize Size, string? Tab)? Page { get; private set; }
    public bool Ended { get; private set; }
    public BrowserPacing Pacing { get; private set; }

    public Action? OnChange { get; set; }
    /// A decoded frame to put on screen (UI thread). Return after it is on screen: the ack follows.
    public Action<BrowserDecodedImage, BrowserFrame>? OnFrame { get; set; }
    /// A short notice (`warning`: with the warning cue).
    public Action<string, bool>? OnNotice { get; set; }
    /// The page's selected text, answering Copy.
    public Action<string>? OnCopied { get; set; }
    /// The account went away (sign-out, another gateway): hand a held browser back, end, and tell the viewer.
    public Action? OnShutDown { get; set; }

    public BrowserWatchSession(BrowserService service, string rowId, string @base, string profile, string name)
    {
        Service = service;
        RowId = rowId;
        Base = @base;
        Profile = profile;
        Name = name;
        _viewer = BrowserWire.ViewerId(service.Prefs);
        service.Register(this);
    }

    public BrowserControlState? Control => View?.Control;
    /// This device holds the browser.
    public bool Mine => Control is { Mine: true, State: BrowserControl.Person };
    public bool Waiting => Control is { Mine: true, State: BrowserControl.Waiting };
    public bool SomeoneElse => Control is { Mine: false } c && c.State != BrowserControl.Bot;

    public void ShutDown()
    {
        Stop();
        OnShutDown?.Invoke();
    }

    public void SetShown(bool on)
    {
        lock (_gate)
        {
            if (on == _shown || _stopped) return;
            _shown = on;
            if (on) _attempt = 0;
        }
        if (on) Connect();
        else Disconnect();
    }

    public void LinkRestored()
    {
        bool dial;
        lock (_gate)
        {
            dial = BrowserLinkRule.WatchDialsNow(_shown, _stopped, Ended, _socket != null, _retryCts != null);
            if (dial)
            {
                CancelCts(ref _retryCts);
                _attempt = 0;
            }
        }
        if (!dial) return;
        Service.Note?.Invoke("watch link restored: dialing now");
        Connect();
    }

    /// The viewer closed: hand the browser back if this device held it, then end.
    public void Stop()
    {
        IBrowserSocket? giveSocket = null;
        lock (_gate)
        {
            if (_stopped) return;
            _stopped = true;
            if ((Mine || Waiting) && _socket != null)
            {
                giveSocket = _socket;
                _socket = null;
            }
        }
        giveSocket?.CloseAfter(BrowserClientMessage.Give.Instance.ToJson());
        Disconnect();
        Service.Note?.Invoke("watch stopped");
    }

    private void Disconnect()
    {
        IBrowserSocket? socket;
        BrowserFrameDecoder? decoder;
        lock (_gate)
        {
            _dials++;
            CancelCts(ref _retryCts);
            CancelCts(ref _watchdogCts);
            CancelCts(ref _workCts);
            decoder = _decoder; _decoder = null;
            socket = _socket; _socket = null;
        }
        decoder?.Close();
        socket?.Close();
        if (Link != BrowserWatchLink.Idle) Link = BrowserWatchLink.Idle;
    }

    public bool Send(BrowserClientMessage message, int? epoch = null)
    {
        IBrowserSocket? socket;
        lock (_gate)
        {
            socket = _socket;
            if (socket == null || (_link != BrowserWatchLink.Live && message is not (BrowserClientMessage.Give or BrowserClientMessage.Take)))
                return false;
        }
        _ = socket.SendTextAsync(message.ToJson(epoch));
        return true;
    }

    /// The stage changed size or zoom: frames are sized to match (the plugin caps them).
    public void SetViewSize(double width, double height, double scale)
    {
        var wanted = BrowserWire.ViewSize(width, height, scale);
        lock (_gate)
        {
            if (_wantedView == wanted) return;
            _wantedView = wanted;
        }
        SendView();
    }

    private void SendView()
    {
        IBrowserSocket? socket;
        (int Width, int Height, double Scale)? wanted;
        lock (_gate) { socket = _socket; wanted = _wantedView; }
        if (socket == null || wanted is not { } w) return;
        _ = socket.SendTextAsync(new BrowserClientMessage.View(w.Width, w.Height, w.Scale).ToJson());
    }

    // ------------------------------------------------------------------ Control and input

    public void Take() { OnNotice?.Invoke("", false); Send(BrowserClientMessage.Take.Instance); }
    public void Give() => Send(BrowserClientMessage.Give.Instance);
    public void Follow() => Send(BrowserClientMessage.Follow.Instance);
    public void ShowTab(string id) => Send(new BrowserClientMessage.Tab(id));

    /// Input while holding the browser. Typing during a socket blip waits for the socket (in order); taps/scrolls drop.
    public void Input(BrowserInput input)
    {
        if (!Mine || Control?.Epoch is not { } epoch) return;
        bool queueIt;
        lock (_gate) queueIt = !_pending.IsEmpty || _link != BrowserWatchLink.Live || _socket == null;
        if (queueIt)
        {
            PendingTypingOutcome outcome;
            lock (_gate) outcome = _pending.Add(input);
            switch (outcome)
            {
                case PendingTypingOutcome.First:
                    OnNotice?.Invoke("Reconnecting… What you type is sent when it’s back.", false);
                    break;
                case PendingTypingOutcome.Full:
                    OnNotice?.Invoke("That’s too much to keep while reconnecting. Type the rest once it’s back.", true);
                    break;
            }
            return;
        }
        Send(new BrowserClientMessage.Input(input), epoch);
    }

    private void SendTyped(BrowserViewState state)
    {
        if (state.Control is { Mine: true, State: BrowserControl.Waiting }) return;
        List<BrowserInput> typed;
        lock (_gate) typed = _pending.Take();
        if (typed.Count == 0) return;
        if (state.Control is not { Mine: true, State: BrowserControl.Person, Epoch: { } epoch })
        {
            OnNotice?.Invoke($"What you typed while reconnecting wasn’t sent: {Name} has its browser back.", true);
            return;
        }
        foreach (var input in typed) Send(new BrowserClientMessage.Input(input), epoch);
    }

    // ------------------------------------------------------------------ The socket

    private void Connect()
    {
        int dial;
        CancellationTokenSource cts;
        BrowserWatchLink nextLink;
        var shutDown = false;
        lock (_gate)
        {
            if (!_shown || _stopped) return;
            if (Service.IsShutDown)
            {
                shutDown = true;
                dial = 0;
                cts = null!;
                nextLink = BrowserWatchLink.Idle;
            }
            else
            {
                _dials++;
                dial = _dials;
                nextLink = _stalled ? BrowserWatchLink.Stalled
                    : (_attempt > 0 || Page != null) ? BrowserWatchLink.Reconnecting
                    : BrowserWatchLink.Connecting;
                CancelCts(ref _workCts);
                cts = _workCts = new CancellationTokenSource();
            }
        }
        if (shutDown) { Finish(); return; }
        Link = nextLink;
        var path = BrowserWire.WatchPath(RowId, Base) ?? "";
        _ = RunSocketAsync(dial, path, cts);
    }

    private async Task RunSocketAsync(int dial, string path, CancellationTokenSource cts)
    {
        try
        {
            // Never pass `?profile=` on `/sessions/{id}/watch`: the watch stream routes through the launch
            // profile's in-process browser plugin (just like `/activity`), whereas a secondary `?profile=` triggers
            // Hermes's plugin host socket refusal (HTTP 501). (HermesKit/Browser/BrowserWatchSession.swift)
            var socket = await Service.Gateway.PluginSocketAsync(
                path,
                [],
                BrowserWire.MaxMessage,
                cts.Token).ConfigureAwait(false);
            if (!IsDial(dial)) { socket.Close(); return; }
            var decoder = MakeDecoder(dial);
            lock (_gate)
            {
                if (_dials != dial || _stopped) { socket.Close(); decoder.Close(); return; }
                _socket = socket;
                _decoder = decoder;
                _nextAckTicks = System.Diagnostics.Stopwatch.GetTimestamp();
                _lastInbound = _nextAckTicks;
            }
            _ = socket.SendTextAsync(new BrowserClientMessage.Hello(_viewer).ToJson());
            SendView();
            StartWatchdog(dial, socket);
            var closeCode = 1006;
            while (!cts.IsCancellationRequested)
            {
                var text = await socket.ReceiveTextAsync(cts.Token).ConfigureAwait(false);
                if (!IsDial(dial)) return;
                if (text == null) { closeCode = socket.CloseCode; break; }
                Volatile.Write(ref _lastInbound, System.Diagnostics.Stopwatch.GetTimestamp());
                var parsed = BrowserServerMessage.Parse(text);
                if (parsed == null) continue;
                var over = false;
                var done = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                Service.Post(() =>
                {
                    try { over = IsDial(dial) && Handle(parsed, socket, decoder); }
                    finally { done.TrySetResult(over); }
                });
                if (await done.Task.ConfigureAwait(false)) return;
            }
            if (IsDial(dial)) Service.Post(() => { if (IsDial(dial)) Closed(closeCode); });
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            if (!IsDial(dial)) return;
            if (BrowserService.IsMissing(e))
            {
                Service.Note?.Invoke("watch ended: plugin missing");
                Service.Post(() => { if (IsDial(dial)) Finish(); });
                return;
            }
            Service.Note?.Invoke($"watch socket failed ({e.GetType().Name})");
            var msg = e is Hermes.Core.Net.GatewayException ge && ge.Message.Length > 0 ? ge.Message : "Check your connection, then try again.";
            Service.Post(() =>
            {
                if (!IsDial(dial)) return;
                OnNotice?.Invoke(msg, false);
                ScheduleRetry();
            });
        }
    }

    private BrowserFrameDecoder MakeDecoder(int dial) => new(
        decoded: (frame, image) => Service.Post(() => Show(frame, image, dial)),
        skipped: seq => Service.Post(() =>
        {
            if (!IsDial(dial)) return;
            IBrowserSocket? socket;
            lock (_gate) socket = _socket;
            if (socket != null) _ = socket.SendTextAsync(new BrowserClientMessage.Ack(seq).ToJson());
        }),
        failed: () => Service.Post(() =>
        {
            if (!IsDial(dial)) return;
            IBrowserSocket? socket;
            lock (_gate) socket = _socket;
            socket?.Close(4000);
        }),
        imageDecoder: Service.ImageDecoder);

    /// true: the stream is over for this dial.
    private bool Handle(BrowserServerMessage message, IBrowserSocket socket, BrowserFrameDecoder decoder)
    {
        switch (message)
        {
            case BrowserServerMessage.State s:
                lock (_gate) { _attempt = 0; _stalled = false; }
                View = s.View;
                Link = BrowserWatchLink.Live;
                SendTyped(s.View);
                return false;
            case BrowserServerMessage.Frame f:
                decoder.Push(f.Data);
                return false;
            case BrowserServerMessage.Ping:
                _ = socket.SendTextAsync(BrowserClientMessage.Pong.Instance.ToJson());
                return false;
            case BrowserServerMessage.Error err:
                OnNotice?.Invoke(err.Message, true);
                return false;
            case BrowserServerMessage.Copied c:
                OnCopied?.Invoke(c.Text);
                return false;
            case BrowserServerMessage.Ended ended:
                if (ended.Reason == "unresponsive")
                {
                    lock (_gate) _stalled = true;
                    Service.Note?.Invoke("watch stalled: unresponsive");
                    socket.Close();
                    return false;
                }
                if (ended.Reason == "error")
                {
                    Service.Note?.Invoke("watch reconnecting: gateway stream error");
                    socket.Close();
                    return false;
                }
                Finish();
                return true;
            default:
                return false;
        }
    }

    private void Show(BrowserFrame frame, BrowserDecodedImage image, int dial)
    {
        IBrowserSocket? socket;
        BrowserFrameDecoder? decoder;
        lock (_gate)
        {
            if (_dials != dial || _socket == null) return;
            socket = _socket;
            decoder = _decoder;
        }
        OnFrame?.Invoke(image, frame);
        var size = new BrowserSize(frame.Width, frame.Height);
        var changed = Page is not { } prev || prev.Size != size || prev.Tab != frame.Tab;
        Page = (size, frame.Tab);

        var nowSec = System.Diagnostics.Stopwatch.GetTimestamp() / (double)System.Diagnostics.Stopwatch.Frequency;
        if (_lastShown is { } last)
        {
            _intervals.Add(nowSec - last);
            if (_intervals.Count > 240) _intervals.RemoveRange(0, _intervals.Count - 240);
        }
        _lastShown = nowSec;
        _shownFrames++;
        if (_shownFrames % 15 == 0)
            Pacing = BrowserPacing.From(_intervals, _shownFrames, decoder?.Stats.MainThreadDecodes ?? 0);
        if (changed) OnChange?.Invoke();

        // Acks paced at FrameInterval (33 ms): the plugin sends a frame per ack, capping at 30 fps.
        var nowTicks = System.Diagnostics.Stopwatch.GetTimestamp();
        var intervalTicks = (long)(BrowserWire.FrameInterval.TotalSeconds * System.Diagnostics.Stopwatch.Frequency);
        var at = Math.Max(nowTicks, _nextAckTicks);
        _nextAckTicks = at + intervalTicks;
        var ack = new BrowserClientMessage.Ack(frame.Seq).ToJson();
        if (at > nowTicks)
        {
            var delayMs = (at - nowTicks) * 1000.0 / System.Diagnostics.Stopwatch.Frequency;
            _ = Task.Run(async () =>
            {
                await Task.Delay(TimeSpan.FromMilliseconds(delayMs)).ConfigureAwait(false);
                if (IsDial(dial)) await socket.SendTextAsync(ack).ConfigureAwait(false);
            });
        }
        else _ = socket.SendTextAsync(ack);
    }

    private void StartWatchdog(int dial, IBrowserSocket socket)
    {
        CancellationTokenSource wd;
        lock (_gate)
        {
            CancelCts(ref _watchdogCts);
            wd = _watchdogCts = new CancellationTokenSource();
        }
        _ = Task.Run(async () =>
        {
            while (!wd.IsCancellationRequested)
            {
                try { await Task.Delay(WatchdogEvery, wd.Token).ConfigureAwait(false); }
                catch (OperationCanceledException) { return; }
                if (!IsDial(dial)) return;
                if (System.Diagnostics.Stopwatch.GetElapsedTime(Volatile.Read(ref _lastInbound)) > WatchdogSilence)
                {
                    Service.Note?.Invoke("watch socket silent; reconnecting");
                    socket.Close();
                    return;
                }
            }
        });
    }

    private void Closed(int code)
    {
        BrowserFrameDecoder? decoder;
        lock (_gate)
        {
            _socket = null;
            decoder = _decoder; _decoder = null;
            CancelCts(ref _watchdogCts);
        }
        decoder?.Close();
        if (code == 4404) { Finish(); return; }
        ScheduleRetry();
    }

    private void ScheduleRetry()
    {
        int dial;
        double wait;
        BrowserWatchLink nextLink;
        CancellationTokenSource retry;
        lock (_gate)
        {
            if (_stopped || Ended) return;
            _attempt++;
            nextLink = _stalled ? BrowserWatchLink.Stalled : BrowserWatchLink.Reconnecting;
            wait = BrowserReconnect.Delay(_attempt);
            dial = _dials;
            CancelCts(ref _retryCts);
            retry = _retryCts = new CancellationTokenSource();
        }
        Link = nextLink;
        _ = Task.Run(async () =>
        {
            try { await Task.Delay(TimeSpan.FromSeconds(wait), retry.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
            var shouldReconnect = false;
            lock (_gate)
            {
                if (_dials == dial && !_stopped && !Ended && ReferenceEquals(_retryCts, retry))
                {
                    _retryCts = null;
                    shouldReconnect = true;
                }
            }
            if (shouldReconnect) Service.Post(Connect);
        });
    }

    private void Finish()
    {
        lock (_gate)
        {
            Ended = true;
            _pending.Clear();
        }
        View = null;
        Page = null;
        Disconnect();
        Service.Note?.Invoke("watch ended");
        OnChange?.Invoke();
    }

    private bool IsDial(int dial) { lock (_gate) return _dials == dial && !_stopped; }

    private static void CancelCts(ref CancellationTokenSource? cts)
    {
        if (cts == null) return;
        try { cts.Cancel(); } catch (ObjectDisposedException) { }
        try { cts.Dispose(); } catch (ObjectDisposedException) { }
        cts = null;
    }

    // Internal test seams
    internal void DebugReceive(BrowserServerMessage message)
    {
        if (message is BrowserServerMessage.State s)
        {
            View = s.View;
            Link = BrowserWatchLink.Live;
            SendTyped(s.View);
        }
        else if (message is BrowserServerMessage.Copied c) OnCopied?.Invoke(c.Text);
        else if (message is BrowserServerMessage.Error e) OnNotice?.Invoke(e.Message, true);
        else if (message is BrowserServerMessage.Ended ended)
        {
            if (ended.Reason is not ("unresponsive" or "error")) Finish();
        }
    }

    internal IReadOnlyList<BrowserInput> DebugPending { get { lock (_gate) return [.. _pending.Items]; } }
    internal int DebugDials { get { lock (_gate) return _dials; } }
    internal int DebugAttempt { get { lock (_gate) return _attempt; } }
    internal bool DebugRetrying { get { lock (_gate) return _retryCts != null; } }
    internal bool IsStopped { get { lock (_gate) return _stopped; } }
}
