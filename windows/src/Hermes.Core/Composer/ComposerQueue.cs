using Hermes.Core.Chat;

namespace Hermes.Core.Composer;

/// A message waiting for the running reply to finish (spec 04 §6.2 M1: a local FIFO shown as a queue card, never as
/// transcript rows; drained with `queued:true` after the turn ends). HermesKit/Contracts.swift QueuedMessage.
/// `Display`: what the bubble shows (a skill's invocation); `Text`: what prompt.submit carries. `Hidden`: a goal
/// continuation (no bubble). `AttachmentCount`/`AttachedLabel`: what the attachments feature put beside the words.
public sealed record QueuedMessage(string Id, string Text, string? Display = null, bool Hidden = false,
    int AttachmentCount = 0, string? AttachedLabel = null, object? Payload = null);

/// What a steer into the running reply came to (HermesKit ReplySteerOutcome).
public enum SteerOutcome { Redirected, NextTurn, Failed }

/// What the queue needs from the open chat. ChatSession implements it through `ChatComposer`; tests use a fake.
public interface IQueueHost
{
    /// A reply is running (or a send is out).
    bool Busy { get; }
    /// Typed words may go into the running reply now (no Stop unwinding, nothing waiting on another process).
    bool CanSteerNow { get; }
    /// The optimistic bubble, busy at once, then prompt.submit (with `queued:true` for queue drains).
    Task<SendOutcome> SendAsync(QueuedMessage message, bool queued);
    /// Stop, locally first (the chat raises its own Stopped, which parks the queue).
    void Stop();
    /// The pending bubble under the running reply; returns its local id.
    string BeginSteer(string shown);
    /// `session.redirect` for that bubble; `unsupported` is set when the gateway can't (4010, -32601).
    Task<(SteerOutcome Outcome, bool Unsupported)> FinishSteerAsync(string localId, string text);
}

/// The chat's queue (HermesKit/Chat/LiveChatSession.swift "Queue", +QueueEdit.swift, Contracts+composer.swift):
/// sends while a reply runs wait here, Send Now steers or sends, Stop parks it, Resume un-parks, Edit holds a row.
/// Thread-safe; Changed fires on whatever thread changed it.
public sealed class ComposerQueue
{
    private readonly IQueueHost _host;
    private readonly object _lock = new();
    private readonly List<QueuedMessage> _items = [];
    private readonly HashSet<string> _steering = [];
    private CancellationTokenSource? _drain;
    private Task _typedSteers = Task.CompletedTask;
    private int _stopEpoch;
    private int _counter;

    /// After a turn's message.complete, how long the queue waits for `session.info running:false` before draining.
    public TimeSpan DrainFallback { get; set; } = TimeSpan.FromMilliseconds(1500);

    public ComposerQueue(IQueueHost host) => _host = host;

    public event Action? Changed;
    /// "Couldn’t add this to the running reply…" and the like: the screen shows it under the title.
    public event Action<string>? Notice;
    /// [WIN-MEMO-SEND-HOST] A row left the queue by the card's Remove (`discarded` false: its words go back to the field)
    /// or Delete (true: nothing comes back). A memo row's recording goes back to the draft chip, or leaves the PC.
    public event Action<QueuedMessage, bool>? Taken;

    public IReadOnlyList<QueuedMessage> Items { get { lock (_lock) return [.. _items]; } }
    public bool Parked { get; private set; }
    public string? EditingId { get; private set; }
    /// The gateway said it cannot redirect (4010, -32601): Send Now is not offered while busy from then on.
    public bool RedirectUnsupported { get; private set; }
    /// Ctrl+Enter: the next send waits in the queue instead of going into the running reply (read once by Send).
    public bool QueuesNextSend { get; set; }

    public bool IsSending(string id) { lock (_lock) return _steering.Contains(id); }

    private string NextId() => $"queued-{Interlocked.Increment(ref _counter)}-{Random.Shared.Next():x}";

    // ------------------------------------------------------------------ sending

    /// Typed words go into the running reply instead of waiting behind it (desktop parity, owner 2026-10-28).
    public bool SteersTyped(string text, string? display, int attachments)
    {
        var t = text.Trim();
        return _host.Busy && _host.CanSteerNow && !RedirectUnsupported && display == null && attachments == 0
            && t.Length > 0 && !SteerRule.IsSlashCommand(t);
    }

    /// A send from the composer (`sendAfterOpen`): steers into a running reply, waits in line, or goes now.
    /// `steer` false: the caller already decided it doesn't go into the running reply (a voice memo, its `payload`,
    /// which may carry no words).
    public void Send(string text, string? display = null, int attachments = 0, string? attachedLabel = null, object? payload = null,
        bool steer = true)
    {
        var toQueue = QueuesNextSend;
        QueuesNextSend = false;
        if (text.Trim().Length == 0 && attachments == 0 && payload == null) return;
        if (!toQueue && steer && SteersTyped(text, display, attachments))
        {
            SteerTyped(text);
            return;
        }
        bool waitInLine;
        QueuedMessage message;
        lock (_lock)
        {
            // A fresh message is fresh intent: a park left by an earlier Stop never holds it back.
            waitInLine = _host.Busy || (_items.Count > 0 && !Parked);
            Parked = false;
            message = new QueuedMessage(NextId(), text, display, false, attachments, attachedLabel, payload);
            if (waitInLine) _items.Add(message);
        }
        if (waitInLine)
        {
            Changed?.Invoke();
            if (!_host.Busy) DrainHead();
            return;
        }
        Changed?.Invoke();
        _ = Deliver(message, queued: false);
    }

    /// Queues a hidden goal continuation behind the running reply (1x-activity §6.4).
    public void EnqueueHidden(string text, string? display)
    {
        lock (_lock) _items.Add(new QueuedMessage(NextId(), text, display, Hidden: true));
        Changed?.Invoke();
        if (!_host.Busy) DrainHead();
    }

    private async Task Deliver(QueuedMessage message, bool queued)
    {
        SendOutcome outcome;
        try { outcome = await _host.SendAsync(message, queued); }
        catch (Exception) { outcome = SendOutcome.Refused; }
        // A queued drain that never left (offline / signed out) goes back to the head of the queue and parks.
        if (queued && outcome == SendOutcome.NotSent)
        {
            lock (_lock)
            {
                if (_items.All(m => m.Id != message.Id)) _items.Insert(0, message);
            }
            Park();
            Changed?.Invoke();
            return;
        }
        // A refused or unconfirmed send never cascades through the rest of the queue.
        if (outcome != SendOutcome.Accepted) Park();
    }

    // ------------------------------------------------------------------ the turn's end, Stop

    /// The reply ended. `confirmed`: the gateway said it is idle (session.info running:false); otherwise the queue
    /// waits a moment for that before draining anyway (`queued:true` keeps a still-running turn from being interrupted).
    public void TurnEnded(bool confirmed) => ScheduleDrain(confirmed ? TimeSpan.Zero : DrainFallback);

    /// Stop halts the queue too (the web parks it); Send Now, Resume or a fresh send un-parks it.
    public void Stopped()
    {
        Interlocked.Increment(ref _stopEpoch);
        Park();
    }

    public void Park()
    {
        lock (_lock)
        {
            if (_items.Count == 0 || Parked) return;
            Parked = true;
            _drain?.Cancel();
            _drain = null;
        }
        Changed?.Invoke();
    }

    public void ScheduleDrain(TimeSpan delay)
    {
        CancellationTokenSource cts;
        lock (_lock)
        {
            if (_items.Count == 0 || Parked) return;
            _drain?.Cancel();
            cts = _drain = new CancellationTokenSource();
        }
        _ = Task.Run(async () =>
        {
            try { if (delay > TimeSpan.Zero) await Task.Delay(delay, cts.Token); }
            catch (OperationCanceledException) { return; }
            if (cts.IsCancellationRequested) return;
            DrainHead();
        });
    }

    /// The head goes out with `queued:true`: not while parked, busy, or held for an edit.
    public void DrainHead()
    {
        QueuedMessage next;
        lock (_lock)
        {
            if (_items.Count == 0 || Parked || _host.Busy || _items[0].Id == EditingId) return;
            _drain?.Cancel();
            _drain = null;
            next = _items[0];
            _items.RemoveAt(0);
        }
        Changed?.Invoke();
        _ = Deliver(next, queued: true);
    }

    // ------------------------------------------------------------------ the card's actions

    /// Send Now on an idle chat (or Stop and Send on a busy one): it moves to the head; a running reply is stopped so it
    /// goes out when the turn unwinds.
    public void SendNow(string id)
    {
        bool busy;
        lock (_lock)
        {
            var at = _items.FindIndex(m => m.Id == id);
            if (at < 0) return;
            var item = _items[at];
            _items.RemoveAt(at);
            _items.Insert(0, item);
            busy = _host.Busy;
        }
        if (busy)
        {
            _host.Stop();
            lock (_lock) Parked = false;
            Changed?.Invoke();
            ScheduleDrain(TimeSpan.Zero);
        }
        else
        {
            lock (_lock) Parked = false;
            Changed?.Invoke();
            DrainHead();
        }
    }

    /// Whether Send Now may steer this row into the running reply.
    public bool CanSteer(string id)
    {
        lock (_lock)
        {
            if (!_host.Busy || RedirectUnsupported || _steering.Contains(id)) return false;
            var item = _items.Find(m => m.Id == id);
            return item != null && SteerRule.Steerable(item);
        }
    }

    /// Whether the card offers Send Now for a row: idle, or busy and steerable (busy otherwise: only Stop and Send).
    public bool CanSendNow(QueuedMessage item) => !_host.Busy || CanSteer(item.Id);

    /// The card's Send Now: steers while a reply runs, else sends now.
    public async Task SendNowFromCard(string id)
    {
        if (_host.Busy)
        {
            if (!CanSteer(id)) return; // a second press while the first is out must not become Stop and Send
            await SteerQueued(id);
        }
        else SendNow(id);
    }

    /// The row leaves the queue on `redirected`/`queued`; a refusal keeps the row and says so.
    public async Task<bool> SteerQueued(string id)
    {
        QueuedMessage? item;
        lock (_lock)
        {
            item = _items.Find(m => m.Id == id);
            if (!_host.Busy || _steering.Count > 0 || item == null || !SteerRule.Steerable(item)) item = null;
            else _steering.Add(id);
        }
        if (item == null)
        {
            if (!_host.Busy) SendNow(id);
            return false;
        }
        Changed?.Invoke();
        try
        {
            var local = _host.BeginSteer(item.Display ?? item.Text);
            var (outcome, unsupported) = await _host.FinishSteerAsync(local, item.Text);
            if (unsupported) RedirectUnsupported = true;
            if (outcome == SteerOutcome.Failed)
            {
                Notice?.Invoke(SteerRule.FailedNotice);
                return false;
            }
            lock (_lock)
            {
                _items.RemoveAll(m => m.Id == id);
                if (_items.Count == 0) Parked = false;
            }
            return true;
        }
        finally
        {
            lock (_lock) _steering.Remove(id);
            Changed?.Invoke();
        }
    }

    /// Typed words steered into the running reply, one after another in typing order. Turned down, they join the
    /// queue: idle by then → sent now; still busy → the notice; Stop meanwhile → a paused row.
    public void SteerTyped(string text)
    {
        var local = _host.BeginSteer(text);
        var epoch = Volatile.Read(ref _stopEpoch);
        lock (_lock)
        {
            var previous = _typedSteers;
            _typedSteers = Task.Run(async () =>
            {
                await previous;
                var (outcome, unsupported) = await _host.FinishSteerAsync(local, text);
                if (unsupported) RedirectUnsupported = true;
                if (outcome != SteerOutcome.Failed) return;
                NotTaken(new QueuedMessage(NextId(), text), epoch);
            });
        }
    }

    /// A steer turned down joins the queue: idle by then → sent now; still busy → the notice; Stop meanwhile → a paused row.
    private void NotTaken(QueuedMessage row, int epoch)
    {
        if (Volatile.Read(ref _stopEpoch) != epoch)
        {
            lock (_lock) _items.Add(row);
            Park();
            Changed?.Invoke();
            return;
        }
        lock (_lock)
        {
            _items.Add(row);
            Parked = false;
        }
        Changed?.Invoke();
        if (_host.Busy) Notice?.Invoke(SteerRule.FailedNotice);
        else DrainHead();
    }

    // ------------------------------------------------------------------ [WIN-MEMO-SEND-HOST] a memo into the running reply

    /// A voice memo steered into the running reply (LiveChatSession+Memo.swift `steerMemo`): its bubble is already up
    /// (`local`) and its staging started (`staged`, in parallel with any steer still out); it goes after those, in
    /// sending order. `Prompt` null and not `Withdrawn`: staging failed. Not taken, or staging failed: `notTaken` runs
    /// and `row` (the memo as a queue item) joins the queue as turned-down typed words do, so nothing recorded is lost.
    /// Withdrawn by Stop: nothing (the memo is the draft chip already). Returns the chain's step (tests await it).
    public Task SteerStaged(string local, Task<(string? Prompt, bool Withdrawn)> staged, string typed, object payload,
        Action<bool> taken)
    {
        var epoch = Volatile.Read(ref _stopEpoch);
        lock (_lock)
        {
            var previous = _typedSteers;
            _typedSteers = Task.Run(async () =>
            {
                var (prompt, withdrawn) = await staged;
                await previous;   // an earlier steer goes in first
                if (withdrawn) return;
                if (prompt != null)
                {
                    var (outcome, unsupported) = await _host.FinishSteerAsync(local, prompt);
                    if (unsupported) RedirectUnsupported = true;
                    if (outcome != SteerOutcome.Failed) { taken(true); return; }
                }
                taken(false);
                NotTaken(new QueuedMessage(NextId(), typed, Payload: payload), epoch);
            });
            return _typedSteers;
        }
    }

    /// Takes a message out of the queue and returns its words (a hidden goal continuation returns nil).
    public string? Remove(string id)
    {
        QueuedMessage? item;
        lock (_lock)
        {
            item = _items.Find(m => m.Id == id);
            if (item == null) return null;
            _items.Remove(item);
            if (_items.Count == 0) Parked = false;
        }
        Changed?.Invoke();
        Taken?.Invoke(item, false);
        return item.Hidden ? null : item.Display ?? item.Text;
    }

    /// Delete: the row is thrown away; nothing comes back to the field.
    public void Discard(string id)
    {
        bool wasHeld;
        QueuedMessage? item;
        lock (_lock)
        {
            item = _items.Find(m => m.Id == id);
            if (item == null) return;
            _items.Remove(item);
            wasHeld = EditingId == id;
            if (wasHeld) EditingId = null;
            if (_items.Count == 0) Parked = false;
        }
        Changed?.Invoke();
        Taken?.Invoke(item, true);
        if (wasHeld && !_host.Busy) DrainHead();
    }

    /// [WIN-MEMO-SEND-HOST] A row leaves with its chat (a queued memo handed back as a draft): no Taken, no drain.
    public void Drop(string id)
    {
        lock (_lock)
        {
            if (_items.RemoveAll(m => m.Id == id) == 0) return;
            if (_items.Count == 0) Parked = false;
        }
        Changed?.Invoke();
    }

    /// Resume on a paused queue: idle, the head goes now; a reply running, the turn's end drains it.
    public void Resume()
    {
        lock (_lock)
        {
            if (!Parked || _items.Count == 0) return;
            Parked = false;
        }
        Changed?.Invoke();
        if (!_host.Busy) DrainHead();
    }

    /// A Return in the empty field while idle: the head goes now. Returns whether a message went out.
    public bool SendNextQueued()
    {
        int count;
        lock (_lock) count = _items.Count;
        if (EmptyReturnRule.Decide(_host.Busy, count, Parked, canAct: true) != EmptyReturn.SendNext) return false;
        DrainHead();
        return true;
    }

    /// The empty-field Return as the Mac decides it (ChatViewController.hardwareReturnInEmptyField).
    public EmptyReturn EmptyReturnNow(bool canAct = true)
    {
        QueuedMessage? head;
        int count;
        lock (_lock)
        {
            if (EditingId != null) return EmptyReturn.Nothing;
            count = _items.Count;
            head = count > 0 ? _items[0] : null;
        }
        var rule = EmptyReturnRule.Decide(_host.Busy, count, Parked, canAct);
        switch (rule)
        {
            case EmptyReturn.SendNext: SendNextQueued(); break;
            case EmptyReturn.SendNowHead when head != null: SendNow(head.Id); break;
        }
        return rule;
    }

    // ------------------------------------------------------------------ Edit (spec §15.5)

    /// Whether Edit is offered for a row: its typed words; not a goal continuation, not going out now.
    public bool CanEdit(string id)
    {
        lock (_lock)
        {
            var item = _items.Find(m => m.Id == id);
            return item != null && !item.Hidden && item.Display == null && !_steering.Contains(id);
        }
    }

    /// Holds the row for an edit and returns its words; null when it can't be edited.
    public string? BeginEdit(string id)
    {
        string text;
        lock (_lock)
        {
            if (EditingId != null && EditingId != id) return null;
            var item = _items.Find(m => m.Id == id);
            if (item == null || item.Hidden || item.Display != null || _steering.Contains(id)) return null;
            EditingId = id;
            text = item.Text;
        }
        Changed?.Invoke();
        return text;
    }

    /// Save: the row's words become `text` in place (same id, same position) and the hold ends. False when it is gone.
    public bool SaveEdit(string id, string text)
    {
        bool saved;
        lock (_lock)
        {
            var at = _items.FindIndex(m => m.Id == id);
            saved = at >= 0;
            if (saved) _items[at] = _items[at] with { Text = text };
        }
        EndEdit();
        return saved;
    }

    /// Cancel (or Save done): the hold ends and the queue goes on.
    public void EndEdit()
    {
        lock (_lock)
        {
            if (EditingId == null) return;
            EditingId = null;
        }
        Changed?.Invoke();
        if (!_host.Busy) DrainHead();
    }
}
