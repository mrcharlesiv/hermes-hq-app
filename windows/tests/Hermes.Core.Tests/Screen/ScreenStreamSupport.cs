// [WIN-SCREEN-SOCKET-STREAM] The socket-and-stream half of the Mac's Tests/Screen/ScreenTestSupport.swift at 93f984bb1:
// FakeScreenSocket (a display socket a test drives by hand), FakeUptime (a clock a test moves), screenWait, and the
// StreamProbe from ScreenStreamTests.swift. The Mac's main actor is a TestMainThread here: one dedicated thread every
// callback runs on, so "decoding never ran on the main thread" means the same thing it does on the Mac.

using System.Collections.Concurrent;
using Hermes.Core.Screen;

namespace Hermes.Core.Tests.Screen;

/// A display socket a test drives by hand: `Push` delivers a frame, `End` closes it as the gateway would.
internal sealed class FakeScreenSocket : IScreenSocket
{
    internal sealed class HeldWrite(byte[] bytes)
    {
        public byte[] Bytes { get; } = bytes;
        // The exact Task returned by SendAsync, not just entry into the fake or permission to finish.
        public TaskCompletionSource<Task> Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Allow { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public bool Written => Started.Task.IsCompletedSuccessfully && Started.Task.Result.IsCompletedSuccessfully;
    }

    private readonly object _gate = new();
    private readonly List<byte[]> _sent = [];
    private readonly List<bool> _closes = [];
    private int? _code;
    private string? _reason;
    private int _pings;
    private bool _answerPings = true;
    private TimeSpan? _sendDelay;
    private bool _failSends;
    private HeldWrite? _hold;
    // The Swift AsyncStream: frames queue until received; finishing ends every later receive.
    private readonly Queue<ScreenSocketFrame> _frames = new();
    private bool _finished;
    private TaskCompletionSource _arrived = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public List<byte[]> Sent { get { lock (_gate) return [.. _sent]; } }
    /// One entry per `Close` call: true = with a 1000 close frame (hand back).
    public List<bool> Closes { get { lock (_gate) return [.. _closes]; } }
    public int Pings { get { lock (_gate) return _pings; } }
    public List<byte[]> Requests => Sent.Where(d => d.Length > 0 && d[0] == 3).ToList();
    public List<byte[]> Inputs => Sent.Where(d => d.Length > 0 && d[0] is 4 or 5 or 6).ToList();
    public void AnswerPings(bool on) { lock (_gate) _answerPings = on; }
    public void SlowSends(TimeSpan? delay) { lock (_gate) _sendDelay = delay; }
    /// Every send from now fails while receiving goes on (a link that can't send).
    public void FailSends() { lock (_gate) _failSends = true; }
    public HeldWrite HoldWrite(byte[] bytes) { lock (_gate) return _hold = new(bytes); }

    public void Push(byte[] data) => Yield(new ScreenSocketFrame.Binary(data));
    public void PushText() => Yield(new ScreenSocketFrame.Text());

    /// The gateway ends the socket (`code` null: the link dropped, no close frame).
    public void End(int? code = null, string? reason = null)
    {
        lock (_gate) { _code = code; _reason = reason; }
        Finish();
    }

    private void Yield(ScreenSocketFrame frame)
    {
        TaskCompletionSource wake;
        lock (_gate)
        {
            if (_finished) return;
            _frames.Enqueue(frame);
            wake = _arrived;
        }
        wake.TrySetResult();
    }

    private void Finish()
    {
        TaskCompletionSource wake;
        lock (_gate) { _finished = true; wake = _arrived; }
        wake.TrySetResult();
    }

    public async Task<ScreenSocketFrame> ReceiveAsync(CancellationToken ct)
    {
        while (true)
        {
            Task wait;
            lock (_gate)
            {
                if (_frames.Count > 0) return _frames.Dequeue();
                if (_finished) throw new IOException("network connection lost");
                if (_arrived.Task.IsCompleted) _arrived = new(TaskCreationOptions.RunContinuationsAsynchronously);
                wait = _arrived.Task;
            }
            await wait.WaitAsync(ct);
        }
    }

    public Task SendAsync(byte[] data, CancellationToken ct)
    {
        lock (_gate)
        {
            var held = _hold;
            if (held == null || !data.AsSpan().SequenceEqual(held.Bytes)) return Write(data, _sendDelay, null, ct);
            _hold = null;
            var write = Write(data, _sendDelay, held.Allow.Task, ct);
            held.Started.SetResult(write);
            return write;
        }
    }

    private async Task Write(byte[] data, TimeSpan? delay, Task? permit, CancellationToken ct)
    {
        if (permit != null) await permit.WaitAsync(ct);
        if (delay is { } d) { try { await Task.Delay(d, ct); } catch (OperationCanceledException) { } }
        bool closed;
        lock (_gate)
        {
            closed = _closes.Count > 0 || _failSends;
            if (!closed) _sent.Add(data);
        }
        if (closed) throw new OperationCanceledException("cancelled");
    }

    public async Task<bool> PingAsync(TimeSpan timeout)
    {
        bool answer;
        lock (_gate) { _pings++; answer = _answerPings; }
        if (!answer) await Task.Delay(50);
        return answer;
    }

    /// Like the real socket, only the first close counts.
    public void Close(bool handBack)
    {
        lock (_gate) { if (_closes.Count == 0) _closes.Add(handBack); }
        Finish();
    }

    public int? CloseCode { get { lock (_gate) return _code; } }
    public string? CloseReason { get { lock (_gate) return _reason; } }
}

/// A clock a test moves by hand.
internal sealed class FakeUptime
{
    private readonly object _gate = new();
    private double _value = 1000.0;
    public double Now { get { lock (_gate) return _value; } }
    public void Advance(double seconds) { lock (_gate) _value += seconds; }
}

/// The Mac's main actor: one dedicated thread that runs every callback in order.
internal sealed class TestMainThread : IDisposable
{
    private readonly BlockingCollection<Action> _work = new();
    private readonly Thread _thread;

    public TestMainThread()
    {
        _thread = new Thread(() => { foreach (var action in _work.GetConsumingEnumerable()) action(); }) { IsBackground = true, Name = "test-main" };
        _thread.Start();
    }

    public bool IsCurrent => Thread.CurrentThread == _thread;

    public Task Run(Action action)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        try { _work.Add(() => { try { action(); done.SetResult(); } catch (Exception e) { done.SetException(e); } }); }
        catch (InvalidOperationException) { done.SetResult(); }
        return done.Task;
    }

    /// Runs `read` on the main thread and returns its value (so a test reads the probe where it is written).
    public T Read<T>(Func<T> read)
    {
        if (IsCurrent) return read();
        T value = default!;
        Run(() => value = read()).GetAwaiter().GetResult();
        return value;
    }

    public void Dispose() => _work.CompleteAdding();
}

internal sealed record ProbeFrame(int Width, int Height, int Serial, int RequestsSeen);

/// What a stream reported, written on the main thread only (as the Swift @MainActor StreamProbe).
internal sealed class StreamProbe
{
    public List<(int Width, int Height)> Ready { get; } = [];
    public List<ProbeFrame> Frames { get; } = [];
    public List<ScreenStreamEnd> Ends { get; } = [];
    public byte[]? LastImage { get; set; }
    public int LastImageWidth { get; set; }
}

internal static class ScreenWaits
{
    /// Polls `done` every 10 ms until it holds or `seconds` pass (never less than 10 s here, so a slow runner has room).
    public static async Task<bool> ScreenWait(Func<bool> done, double seconds = 10)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(Math.Max(10, seconds));
        while (DateTime.UtcNow < deadline)
        {
            if (done()) return true;
            await Task.Delay(10);
        }
        return done();
    }
}
