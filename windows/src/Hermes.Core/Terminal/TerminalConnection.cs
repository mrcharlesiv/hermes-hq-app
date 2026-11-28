namespace Hermes.Core.Terminal;

/// One open Terminal tab's link to its shell (docs/spec/terminal.md, HermesKit/Terminal/TerminalConnection.swift):
/// dials the add-on's socket, shows what the shell prints, sends what is typed, and dials again when the link drops,
/// asking only for what the tab missed (`since`). Keys typed while the link is down wait (up to 64 KB) and go once it
/// is back. The page leaving closes the socket but not the shell: the computer keeps it 15 minutes. Only `EndShell()`
/// ends it. Events are raised on the connection's own thread; the page marshals them to its UI thread.
public sealed class TerminalConnection
{
    public abstract record Phase
    {
        /// The first dial (or the first after New Shell).
        public sealed record Connecting : Phase;
        public sealed record Live : Phase;
        /// The link dropped: dialling again; what is typed waits.
        public sealed record Reconnecting : Phase;
        /// The shell ended, with its exit code when the computer knew it.
        public sealed record Ended(int? Code) : Phase;
        /// No more dialling: opened again elsewhere, turned off, unsupported, full or refused.
        public sealed record Stopped(TerminalWire.Ending Ending) : Phase;
    }

    public delegate Task<ITerminalSocket> Dial(IReadOnlyList<KeyValuePair<string, string>> query, CancellationToken ct);

    public string Session { get; }
    private readonly Dial _dial;
    private readonly object _lock = new();
    private Phase _phase = new Phase.Connecting();
    private ITerminalSocket? _socket;
    private CancellationTokenSource? _runner;
    private (int Cols, int Rows) _size = (80, 24), _sentSize = (0, 0);
    private readonly List<byte> _waiting = [];
    private DateTime _heard = DateTime.UtcNow;
    private volatile bool _dialNow;
    private volatile bool _closed;

    public const int MaxWaiting = 64 * 1024;
    /// The add-on pings after 20 s of quiet; a socket silent this long is gone.
    public static TimeSpan QuietLimit { get; set; } = TimeSpan.FromSeconds(45);
    /// Failed dials before a tab that never went live stops (about 30 s with the waits below).
    public static int GiveUpAfter { get; set; } = 8;
    /// Waits between failed dials: 0.5, 1, 2, 4, then 8 s.
    public static Func<int, TimeSpan> Backoff { get; set; } = failures => TimeSpan.FromMilliseconds(500 * (1 << Math.Min(Math.Max(failures - 1, 0), 4)));

    public TerminalConnection(string session, Dial dial)
    {
        Session = session;
        _dial = dial;
    }

    public Phase CurrentPhase { get { lock (_lock) return _phase; } }
    /// The shell's name ("zsh"), once the computer has said.
    public string Shell { get; private set; } = "";
    /// Bytes of this shell's output shown so far: where a new socket asks to start.
    public long Shown { get; private set; }
    /// Dials in a row that failed (0 once a socket is live).
    public int Failures { get; private set; }

    public event Action<Phase>? PhaseChanged;
    public event Action<byte[]>? Output;
    /// What follows starts at the beginning of what the computer kept, not where the tab is: clear the screen first.
    public event Action? Reset;
    /// For the log (never the shell's words).
    public event Action<string>? Trace;

    private void SetPhase(Phase next)
    {
        lock (_lock)
        {
            if (_phase == next) return;
            _phase = next;
        }
        PhaseChanged?.Invoke(next);
    }

    /// Dials, once; later calls only update the size.
    public void Start(int cols, int rows)
    {
        Resize(cols, rows);
        lock (_lock)
        {
            if (_runner != null || _closed) return;
            _runner = new CancellationTokenSource();
        }
        var token = _runner.Token;
        _ = Task.Run(() => RunAsync(token));
    }

    /// The page left: the socket closes, the shell stays on the computer.
    public void Stop()
    {
        _closed = true;
        ITerminalSocket? socket;
        lock (_lock)
        {
            _runner?.Cancel();
            _runner = null;
            socket = _socket;
            _socket = null;
        }
        socket?.Close();
    }

    /// Keys, or a paste already encoded for the terminal.
    public void Send(byte[] data)
    {
        if (data.Length == 0) return;
        lock (_lock)
        {
            switch (_phase)
            {
                case Phase.Live when _socket != null: _socket.Send(new TerminalFrame.Binary(data)); break;
                case Phase.Live or Phase.Connecting or Phase.Reconnecting: Hold(data); break;
            }
        }
    }

    public void Resize(int cols, int rows)
    {
        if (cols <= 0 || rows <= 0) return;
        lock (_lock)
        {
            _size = (cols, rows);
            SendSize();
        }
    }

    /// Hang up the shell (End Shell). Its `exit` arrives as the phase Ended.
    public void EndShell()
    {
        lock (_lock) if (_phase is Phase.Live && _socket != null) _socket.Send(new TerminalFrame.Text(TerminalWire.End));
    }

    /// The app is back in front after `away`: a socket left hanging is dialled again now rather than after the 45 s
    /// silence (the computer replays only what was missed).
    public void CameBack(TimeSpan away)
    {
        if (_closed || away <= TimeSpan.FromSeconds(5)) return;
        ITerminalSocket? socket;
        lock (_lock)
        {
            if (_phase is Phase.Ended or Phase.Stopped) return;
            _dialNow = true;
            socket = _socket;
        }
        socket?.Close();
    }

    // MARK: The loop

    private void Hold(byte[] data)
    {
        if (_waiting.Count + data.Length <= MaxWaiting) _waiting.AddRange(data);
    }

    /// Under the lock.
    private void SendSize()
    {
        if (_phase is not Phase.Live || _socket == null || _size == _sentSize) return;
        _sentSize = _size;
        _socket.Send(new TerminalFrame.Text(TerminalWire.Resize(_size.Cols, _size.Rows)));
    }

    private async Task RunAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && !_closed)
        {
            ITerminalSocket? opened = null;
            try
            {
                (int Cols, int Rows) size;
                lock (_lock) size = _size;
                var socket = await _dial(TerminalWire.Query(Session, size.Cols, size.Rows, Shown), ct);
                opened = socket;
                if (ct.IsCancellationRequested || _closed) { socket.Close(); return; }
                lock (_lock)
                {
                    _socket = socket;
                    // H27: record the size actually sent during dial so any Resize() during handshake triggers a follow-up resize.
                    _sentSize = size;
                }
                _heard = DateTime.UtcNow;
                using var watch = CancellationTokenSource.CreateLinkedTokenSource(ct);
                _ = WatchAsync(socket, watch.Token);
                try { await ReadAsync(socket, ct); }
                finally { watch.Cancel(); }
            }
            catch (Net.GatewayException e) when (e.Code == "session-ended")
            {
                _closed = true;   // signed out: the page is going
                return;
            }
            catch (Exception) { }
            lock (_lock) if (ReferenceEquals(_socket, opened)) _socket = null;
            if (ct.IsCancellationRequested || _closed) return;
            var ending = TerminalWire.EndingFor(opened?.CloseCode, opened?.CloseReason, opened?.RefusedStatus);
            Trace?.Invoke("socket ended: " + TerminalWire.Describe(opened?.CloseCode, opened?.RefusedStatus, ending));
            opened?.Close();
            switch (ending.Kind)
            {
                case TerminalWire.EndingKind.Ended:
                    if (CurrentPhase is not Phase.Ended) SetPhase(new Phase.Ended(null));
                    return;
                case TerminalWire.EndingKind.Retry:
                    if (CurrentPhase is Phase.Ended) return;
                    Failures++;
                    if (CurrentPhase is Phase.Live) SetPhase(new Phase.Reconnecting());
                    if (CurrentPhase is Phase.Connecting && Failures >= GiveUpAfter)
                    {
                        SetPhase(new Phase.Stopped(new TerminalWire.Ending(TerminalWire.EndingKind.Unreachable)));
                        return;
                    }
                    await PauseAsync(Backoff(Failures), ct);
                    break;
                default:
                    SetPhase(new Phase.Stopped(ending));
                    return;
            }
        }
    }

    /// Waits `delay`, cut short by `CameBack`.
    private async Task PauseAsync(TimeSpan delay, CancellationToken ct)
    {
        var until = DateTime.UtcNow + delay;
        while (DateTime.UtcNow < until && !_dialNow && !ct.IsCancellationRequested)
        {
            try { await Task.Delay(TimeSpan.FromMilliseconds(Math.Min(250, Math.Max(1, (until - DateTime.UtcNow).TotalMilliseconds))), ct); }
            catch (OperationCanceledException) { return; }
        }
        _dialNow = false;
    }

    private async Task ReadAsync(ITerminalSocket socket, CancellationToken ct)
    {
        while (true)
        {
            var frame = await socket.ReceiveAsync(ct);
            if (_closed) return;
            _heard = DateTime.UtcNow;
            switch (frame)
            {
                case TerminalFrame.Binary b:
                    Shown += b.Data.Length;
                    Output?.Invoke(b.Data);
                    break;
                case TerminalFrame.Text t:
                    switch (TerminalWire.Parse(t.Value))
                    {
                        case TerminalWire.Message.Ready r:
                            if (r.Offset != Shown) Reset?.Invoke();
                            Shown = r.Offset;
                            Shell = r.Shell;
                            Failures = 0;
                            SetPhase(new Phase.Live());
                            lock (_lock)
                            {
                                if (_waiting.Count > 0)
                                {
                                    socket.Send(new TerminalFrame.Binary([.. _waiting]));
                                    _waiting.Clear();
                                }
                                SendSize();
                            }
                            break;
                        case TerminalWire.Message.Exit x:
                            SetPhase(new Phase.Ended(x.Code));
                            break;
                    }
                    break;
            }
        }
    }

    private async Task WatchAsync(ITerminalSocket socket, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try { await Task.Delay(TimeSpan.FromSeconds(Math.Min(5, QuietLimit.TotalSeconds / 3)), ct); }
            catch (OperationCanceledException) { return; }
            if (DateTime.UtcNow - _heard > QuietLimit)
            {
                Trace?.Invoke($"no word from the computer in {QuietLimit.TotalSeconds:0} s; dialling again");
                socket.Close();
                return;
            }
        }
    }
}
