// [WIN-EXTERNAL-TURN] Working… while another Hermes process runs a turn in this chat (93f984bb1
// HermesKit/Chat/LiveChatSession+External.swift `checkExternalWork`, `endExternalWork`, `externalWorkLoop`,
// `externalVerdict`, `askLedger`, `setExternalWork`; docs/spec/03-chat-history.md §4.8; the pure rules are
// ExternalTurn.cs): the chat reads its stored rows every few seconds meanwhile, so each step and the reply show as the
// gateway writes them, and the header says Working… until the ledger (or the rows) say it ended.
//
// When it is asked (as the Mac's): the open settling (OpenAsync), a history read that brought rows it hadn't seen
// (RefreshAsync, the Mac's "new rows"), and a send refused for the owner (OwnerRefusalAsync, "send waits for the owner").
// Never while a turn of ours runs; a turn of ours starting ends it (SendAsync, OnEvent: the Mac's `deliver`). The screen
// going away (DisposeAsync, the Mac's `stopObserving`) ends it. A send waiting for the owner wakes when it ends
// (`externalEnds`, SleepForOwnerAsync).
//
// Not ported: the probe-first tail read (Windows' history read is one 24-row page each round, not a 1-row probe
// first). The rows' live step line (ChatRow's `externalTail`) is ReplyContext.ExternalTail, and the Bots/Sessions
// rows' Working… (AppModel `setWorking`) is TurnRows, fed from ExternalWorkChanged and RunningChanged.

using Hermes.Core.Net;

namespace Hermes.Core.Chat;

public sealed partial class ChatSession
{
    private readonly object _externalGate = new();
    /// The stored id the chat opened with (StoredId may move to the resume's resolved id): the ledger may name either.
    private readonly string _openedId;
    private ExternalTurn.Source? _externalWork;
    private int _externalEnds;
    private Task? _externalTask;
    private CancellationTokenSource? _externalStop;
    private int _externalGeneration;
    private volatile bool _openSettled;
    private volatile bool _closed;
    /// The gateway's time of the newest stored row any history read of this chat returned (`newestStoredAt`): a folded
    /// turn carries its first row's time, so the messages alone understate how far the reader has seen.
    private DateTimeOffset? _newestStoredAt;
    private long? _newestRowId;

    /// How often the stored rows and the ledger are read while another process works (`ExternalTurn.pollInterval`).
    public TimeSpan ExternalPollInterval { get; set; } = ExternalTurn.DefaultPollInterval;

    /// What says another process runs a turn here now (null: nothing does).
    public ExternalTurn.Source? ExternalWork { get { lock (_externalGate) return _externalWork; } }

    /// Another process runs a turn here now (the header's Working…).
    public bool ExternalWorking => ExternalWork != null;

    /// Times the watch saw another run end (wakes a send waiting for the chat's owner).
    public int ExternalEnds => Volatile.Read(ref _externalEnds);

    /// The chat began (true) or stopped (false) showing another process's turn as Working… (`onExternalWorkChange`).
    /// Raised on a background thread; Changed fires as well.
    public event Action<bool>? ExternalWorkChanged;

    /// Checks run while no turn of ours does, and while our send waits behind theirs (`SESSION_OWNER_BUSY`).
    private bool ExternalChecksAllowed => !Busy || _waitingForOwner != null;

    /// Something suggests another process may run a turn here (the open settled, a read brought rows, our send was
    /// refused for the owner): ask, and keep reading while it runs. One loop at a time.
    public void CheckExternalWork(string why)
    {
        if (_closed || !_openSettled || !ExternalChecksAllowed) return;
        lock (_externalGate)
        {
            if (_externalTask != null || _closed) return;
            var generation = ++_externalGeneration;
            var stop = new CancellationTokenSource();
            _externalStop = stop;
            _externalTask = Task.Run(() => ExternalWorkLoopAsync(why, generation, stop.Token));
        }
    }

    /// The screen went away or our own turn started: the loop ends and Working… with it.
    public void EndExternalWork(string why)
    {
        lock (_externalGate)
        {
            _externalGeneration++;
            _externalStop?.Cancel();
            _externalStop = null;
            _externalTask = null;
        }
        SetExternalWork(null, why, readAfter: false);
    }

    /// A turn of ours started (`deliver`'s check): its own state says what runs from here.
    private void EndExternalIfOursRuns()
    {
        if (ExternalWork != null && Busy && _waitingForOwner == null) EndExternalWork("a turn of ours started");
    }

    private bool ExternalCurrent(int generation, CancellationToken stop) =>
        !_closed && !stop.IsCancellationRequested && generation == Volatile.Read(ref _externalGeneration);

    private async Task ExternalWorkLoopAsync(string why, int generation, CancellationToken stop)
    {
        var round = 0;
        try
        {
            while (ExternalCurrent(generation, stop) && ExternalChecksAllowed)
            {
                if (round > 0)
                {
                    // What the other process wrote since: each step as it lands.
                    await RefreshQuietly();
                    if (!ExternalCurrent(generation, stop) || !ExternalChecksAllowed) break;
                }
                round++;
                var verdict = await ExternalVerdictAsync(stop);
                if (!ExternalCurrent(generation, stop)) return;
                SetExternalWork(verdict, round == 1 ? why : $"read {round}", readAfter: true);
                if (verdict == null) return;
                await Task.Delay(ExternalPollInterval, stop);
            }
            // Our own turn started (or the screen left) with the loop still on: that turn's state takes over.
            if (ExternalCurrent(generation, stop) && ExternalWork != null)
                SetExternalWork(null, Busy ? "a turn of ours started" : "screen off", readAfter: false);
        }
        catch (OperationCanceledException) { }
        finally
        {
            lock (_externalGate) if (generation == _externalGeneration) _externalTask = null;
        }
    }

    /// The ledger's word when the add-on has it; otherwise the stored rows'.
    private async Task<ExternalTurn.Source?> ExternalVerdictAsync(CancellationToken stop)
    {
        switch (await AskLedgerAsync(stop))
        {
            case ExternalTurn.LedgerKind.Working: return ExternalTurn.Source.Ledger;
            case ExternalTurn.LedgerKind.Idle: return null;
        }
        DateTimeOffset? newest;
        lock (_externalGate) newest = _newestStoredAt;
        return ExternalTurn.HistoryUnfinished(Messages, newest, DateTimeOffset.UtcNow) ? ExternalTurn.Source.History : null;
    }

    private async Task<ExternalTurn.LedgerKind> AskLedgerAsync(CancellationToken stop)
    {
        var key = _client.AccountId;
        if (ExternalTurn.LedgerMissingSince.TryGetValue(key, out var since) && DateTimeOffset.UtcNow - since < ExternalTurn.MissingRecheck)
            return ExternalTurn.LedgerKind.Missing;
        var ids = new HashSet<string>(StringComparer.Ordinal) { StoredId, _openedId };
        var profile = Profile.Length == 0 ? "default" : Profile;
        try
        {
            var json = await _client.Session.GetJsonAsync(ExternalTurn.LedgerPath, [new("profile", profile)],
                TimeSpan.FromSeconds(10), stop);
            ExternalTurn.LedgerMissingSince.TryRemove(key, out _);
            return ExternalTurn.LedgerNames(json, ids, profile) ? ExternalTurn.LedgerKind.Working : ExternalTurn.LedgerKind.Idle;
        }
        catch (GatewayException e) when (e.Status == 404)
        {
            // No add-on, or one older than 0.9.6: the stored rows decide (asked again after MissingRecheck).
            ExternalTurn.LedgerMissingSince[key] = DateTimeOffset.UtcNow;
            return ExternalTurn.LedgerKind.Missing;
        }
        catch (GatewayException) { return ExternalTurn.LedgerKind.Failed; }
        catch (HttpRequestException) { return ExternalTurn.LedgerKind.Failed; }
    }

    /// `readAfter`: when the other process's turn ends, one read brings the reply it ended with.
    private void SetExternalWork(ExternalTurn.Source? source, string why, bool readAfter)
    {
        ExternalTurn.Source? was;
        lock (_externalGate)
        {
            if (source == _externalWork) return;
            was = _externalWork;
            _externalWork = source;
            if (source == null && was != null) Interlocked.Increment(ref _externalEnds);
        }
        _ = why;   // the Mac's log line: Windows' Core keeps no chat trace here
        Changed?.Invoke();
        if ((was == null) != (source == null)) ExternalWorkChanged?.Invoke(source != null);
        if (source == null && was != null && readAfter && !_closed) _ = RefreshQuietly();
    }

    /// A history read's rows: the newest stored time moves on; rows it hadn't seen may be another process's turn.
    private void NoteStoredRows(HistoryPage page)
    {
        bool moved = false;
        lock (_externalGate)
        {
            if (page.NewestStoredAt is { } t && (_newestStoredAt is not { } was || t > was)) { _newestStoredAt = t; moved = true; }
            if (page.NewestRowId is { } id && (_newestRowId is not { } seen || id > seen)) { _newestRowId = id; moved = true; }
        }
        if (moved) CheckExternalWork("new rows");
    }

    /// The open finished (`openSettled`): the watch may run from here.
    private void OpenSettled()
    {
        _openSettled = true;
        CheckExternalWork("open");
    }
}
