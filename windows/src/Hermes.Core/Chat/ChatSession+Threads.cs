using System.Text.Json.Nodes;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Chat;

/// A burst message queued behind a send that was just routed into a side thread.
public sealed record QueuedBusySend(
    string Id,
    string Text,
    string? Display = null,
    IReadOnlyList<ChatPart>? Attachments = null,
    bool Hidden = false);

// [threads] Session threads runtime on ChatSession (port of HermesKit/Chat/Threads/LiveChatSession+Threads.swift
// and §9 busy-chat auto-routing): off-screen listening, busy-chat handoff on RPC 4009/4090, proactive routing,
// burst-queue draining, ThreadContextNote reconciliation, and main-chat availability probing.
public sealed partial class ChatSession
{
    private bool _threadChangeHooked;

    /// True when this session itself is a side thread (threads never host nested threads).
    public bool IsThread { get; set; }

    /// True when this session is a bot's canonical Bot Chat (shares one thread scope per profile).
    public bool IsBotChat { get; set; }

    /// Held open off-screen by `ThreadStore` while its parent chat renders it inline.
    public bool ThreadHold { get; set; }

    /// True while a chat screen is actively observing this session.
    public bool Observing { get; set; }

    /// True while listening off-screen without a visible chat screen.
    public bool DrainingAway { get; private set; }

    /// Number of sends accepted by the gateway in this session (used by `ThreadRules.TakesNextBusySend`).
    public int AcceptedSends { get; private set; }

    /// Brief grace window on a first `4090` refusal from a known external holder before routing to a thread.
    public TimeSpan BusyOwnerGrace { get; set; } = ThreadRules.BusyOwnerGrace;

    /// Display name for thread notices (`ThreadRules.BackInMainNotice`).
    public string EffectiveBotName => BotName;

    /// Rich busy-send router (preferred over legacy `OnBusyThread`).
    public Func<BusyThreadPayload, bool>? OnBusyThreadSend { get; set; }

    /// Legacy text-only busy-send router `(text, localId) -> handled`.
    public Func<string, string, bool>? OnBusyThread { get; set; }

    /// Proactive check before `prompt.submit`: true routes straight into a thread with 0 ms wait.
    public Func<bool>? ShouldRouteToBusyThread { get; set; }

    /// Consumes a pending `ThreadContextNote` from settled auto-threads to bridge onto the next main prompt.
    public Func<string?>? ConsumeThreadContextNote { get; set; }

    /// Restores a consumed `ThreadContextNote` if the main send was refused or routed into a thread.
    public Action<string>? RestoreThreadContextNote { get; set; }

    /// Fired when a refresh detects a newer finished assistant reply in the main chat.
    public Action? OnMainReplyLanded { get; set; }

    /// Quiet transient notice displayed above the composer (`ThreadRules.BusyNotice`, `ThreadRules.BackInMainNotice`).
    public Action<string>? OnNotice { get; set; }

    /// Fired when the thread's messages, running state, title, or problem change (subscribed by `ThreadStore`).
    public Action? OnThreadChange { get; set; }

    /// Fired when off-screen listening begins or ends.
    public event Action<bool>? DrainingAwayChanged;

    /// Whether this chat can host side threads (bot chats and regular sessions; never threads themselves).
    public bool SupportsThreads => !IsThread && (OnBusyThreadSend != null || OnBusyThread != null);

    /// Opts this chat out of hosting threads (called for threads themselves and hidden task/goal/tile chats).
    public void DisableThreads()
    {
        OnBusyThread = null;
        OnBusyThreadSend = null;
        ShouldRouteToBusyThread = null;
        ConsumeThreadContextNote = null;
        RestoreThreadContextNote = null;
        OnMainReplyLanded = null;
    }

    /// Opens the chat (or keeps it open) and hears the gateway without a screen (`LiveChatSession.listenOffScreen`).
    public void ListenOffScreen()
    {
        ThreadHold = true;
        if (!_threadChangeHooked)
        {
            _threadChangeHooked = true;
            Changed += NotifyThreadChange;
            TitleChanged += _ => NotifyThreadChange();
        }
        if (Observing) return;
        if (!DrainingAway)
        {
            DrainingAway = true;
            DrainingAwayChanged?.Invoke(true);
        }
        if (!_openSettled && _runtimeId == null && Messages.Count == 0 && !string.IsNullOrEmpty(StoredId))
        {
            _ = Task.Run(async () =>
            {
                try { await OpenAsync(); }
                catch (Exception) { }
            });
        }
    }

    private void NotifyThreadChange() => OnThreadChange?.Invoke();

    /// Ends the off-screen thread hold; once idle off-screen, draining ends.
    public void EndThreadHold()
    {
        ThreadHold = false;
        if (!Observing && !Busy && DrainingAway)
        {
            DrainingAway = false;
            DrainingAwayChanged?.Invoke(false);
        }
    }

    /// §9: routes a send to the app's thread handler (rich `OnBusyThreadSend` first, legacy `OnBusyThread` fallback).
    public bool DeliverToBusyThread(BusyThreadPayload payload)
    {
        if (OnBusyThreadSend != null) return OnBusyThreadSend(payload);
        if ((payload.Attachments == null || payload.Attachments.Count == 0) && payload.Display == null && OnBusyThread != null)
            return OnBusyThread(payload.Text, payload.LocalId ?? "");
        return false;
    }

    /// §9: a send this chat could not take went on in a thread. Its bubble leaves this chat (the thread draws it),
    /// with no "Couldn’t Send" card and nothing handed back. Burst messages queued behind it drain into the same
    /// thread in order; hidden continuations and voice chat transcripts stay parked.
    public void SendWentToThread(string localId, OwnerWait? reason = null, IList<QueuedBusySend>? queued = null)
    {
        lock (_lock)
        {
            _t.Withdraw(localId);
            if (_turnPrompt != null) { _turnPrompt = null; _turnStarted = null; }
        }
        if (queued is { Count: > 0 })
        {
            var remaining = new List<QueuedBusySend>();
            foreach (var item in queued)
            {
                var canDrain = !item.Hidden && !UpdateGroups.IsVoiceTranscript(item.Text);
                if (canDrain && DeliverToBusyThread(new BusyThreadPayload(
                        item.Text, item.Display, item.Attachments, LocalId: null, Reason: reason, Proactive: true)))
                    continue;
                remaining.Add(item);
            }
            queued.Clear();
            foreach (var item in remaining) queued.Add(item);
        }
        Changed?.Invoke();
        OnNotice?.Invoke(ThreadRules.BusyNotice);
    }

    /// §9: the thread could not send those words either — hand them back to the main chat's composer with the reason.
    public void ThreadSendCameBack(string text, string reason)
    {
        SetSendFailure(reason);
        Changed?.Invoke();
        DraftReturned?.Invoke(text, string.IsNullOrEmpty(reason) ? NotSentWords : reason);
    }

    /// §9: lightweight probe while an auto-thread is latched on screen and `ExternalWorking` is false.
    /// Refreshes stored rows (firing `OnMainReplyLanded` if a newer finished reply landed), and when
    /// `checkServerRunning` is true checks `session.resume(omit_messages: true)` and `session.active_list`.
    public async Task<bool> ProbeMainAvailabilityAsync(bool checkServerRunning, CancellationToken ct = default)
    {
        if (_closed || Busy) return false;
        var before = Messages;
        await RefreshQuietly();
        var after = Messages;
        if (ThreadRules.HasNewFinishedReply(before, after))
            OnMainReplyLanded?.Invoke();
        if (!checkServerRunning || _closed || Busy || string.IsNullOrEmpty(StoredId)) return false;

        var resumeParams = new JsonObject
        {
            ["session_id"] = StoredId,
            ["omit_messages"] = true,
            ["profile"] = Profile,
        };
        JsonNode resumed;
        try { resumed = await _client.Rpc.RequestAsync("session.resume", resumeParams, TimeSpan.FromSeconds(10), ct); }
        catch (Exception) { return false; }

        if (resumed.Bool("running") == true) return false;
        if (resumed.Obj("inflight") is { } inflight && inflight.Str("status") != "error") return false;

        try
        {
            var active = await _client.Rpc.RequestAsync("session.active_list", new JsonObject(), TimeSpan.FromSeconds(10), ct);
            var ids = new HashSet<string>(StringComparer.Ordinal) { StoredId, _openedId };
            if (!string.IsNullOrEmpty(_runtimeId)) ids.Add(_runtimeId);
            foreach (var row in active.Arr("sessions") ?? [])
            {
                var matches = new[] { row.Str("id"), row.Str("session_id"), row.Str("session_key") }
                    .Any(id => id != null && ids.Contains(id));
                if (!matches) continue;
                var status = (row.Str("status") ?? "").ToLowerInvariant();
                if (status is "running" or "waiting" || row.Bool("running") == true) return false;
            }
        }
        catch (Exception) { /* if active_list isn't supported, rely on session.resume */ }

        return true;
    }

    /// §9: busy-chat aware send. Routes proactively when `ShouldRouteToBusyThread` is true, bridges any pending
    /// `ThreadContextNote` onto the main prompt (restoring it on refusal/handoff), and automatically hands off on
    /// RPC `4009` (server busy) or `4090` (after `BusyOwnerGrace`).
    public async Task<SendOutcome> SendWithThreadRoutingAsync(
        string text,
        CancellationToken ct = default,
        bool queued = false,
        string? display = null,
        IReadOnlyList<ChatPart>? attachments = null,
        IList<QueuedBusySend>? burstQueue = null)
    {
        var rawText = text.Trim();
        if (rawText.Length == 0) return SendOutcome.Refused;

        var supports = SupportsThreads;
        if (supports && ShouldRouteToBusyThread?.Invoke() == true)
        {
            var proactive = new BusyThreadPayload(rawText, display, attachments, LocalId: null,
                Reason: ExternalWorking ? OwnerWait.BackgroundTask : null, Proactive: true);
            if (DeliverToBusyThread(proactive)) return SendOutcome.Accepted;
        }

        string? contextNote = null;
        var wireText = rawText;
        var visibleText = display?.Trim() is { Length: > 0 } shown ? shown : rawText;
        if (supports && ConsumeThreadContextNote?.Invoke() is { Length: > 0 } note)
        {
            contextNote = note;
            wireText = ThreadContextNote.Appended(rawText, note);
        }

        void RestoreNoteIfHeld()
        {
            if (contextNote is { Length: > 0 } n)
            {
                contextNote = null;
                RestoreThreadContextNote?.Invoke(n);
            }
        }

        if (!queued) { SendFailure = null; ClearProblemForSend(); }
        var draftScopeBefore = DraftScope;
        ChatMessage local;
        lock (_lock)
        {
            _turnGeneration++;
            local = attachments is { Count: > 0 }
                ? _t.AddLocalUser(visibleText, attachments)
                : _t.AddLocalUser(visibleText);
            _stopPending = false;
        }
        MigrateDraftScope(draftScopeBefore);
        StopTerminalReached();
        AnchorTurn(local.Id, wireText);
        TurnInterrupted = false;
        _turnStarted = DateTimeOffset.Now;
        _turnPrompt = wireText;
        Changed?.Invoke();
        EndExternalIfOursRuns();

        var wait = BeginOwnerWaitRun(local.Id);
        var submitted = false;
        var resumed = false;
        var ownerGraceTried = false;
        GatewayException? firstStale = null;

        try
        {
            while (true)
            {
                var runtime = _runtimeId ?? await ResumeAsync(ct);
                JsonNode res;
                try
                {
                    submitted = true;
                    res = await Submit(runtime, wireText, ct, queued, localId: local.Id);
                }
                catch (GatewayException e) when (e.RpcCode == 4009 && !IsChatLocked(e))
                {
                    submitted = false;
                    if (supports)
                    {
                        RestoreNoteIfHeld();
                        var payload = new BusyThreadPayload(rawText, display, attachments, local.Id, OwnerWait.RunningReply, Proactive: false);
                        if (DeliverToBusyThread(payload))
                        {
                            EndOwnerWait(wait);
                            SendWentToThread(local.Id, OwnerWait.RunningReply, burstQueue);
                            return SendOutcome.Accepted;
                        }
                    }
                    submitted = true;
                    res = await RetryBusy(runtime, wireText, ct, queued, local.Id);
                }
                catch (GatewayException e) when (e.Code == "rpc")
                {
                    submitted = false;
                    if (supports && e.RpcCode == 4090 && WaitsForOwner(e) && !IsChatLocked(e) && !IsOwnerUnconfirmed(e))
                    {
                        var reason = OwnerWaitOf(e);
                        if (!ownerGraceTried && BusyOwnerGrace > TimeSpan.Zero)
                        {
                            ownerGraceTried = true;
                            await Task.Delay(BusyOwnerGrace, ct);
                            continue;
                        }
                        RestoreNoteIfHeld();
                        var payload = new BusyThreadPayload(rawText, display, attachments, local.Id, reason, Proactive: false);
                        if (DeliverToBusyThread(payload))
                        {
                            EndOwnerWait(wait);
                            SendWentToThread(local.Id, reason, burstQueue);
                            return SendOutcome.Accepted;
                        }
                    }

                    var (step, why) = await OwnerRefusalAsync(wait, e, photos: attachments is { Count: > 0 });
                    switch (step)
                    {
                        case OwnerStep.Retry:
                            resumed = false;
                            firstStale = null;
                            continue;
                        case OwnerStep.Stopped:
                            RestoreNoteIfHeld();
                            WithdrawStoppedSend(local.Id, visibleText, wireText);
                            return SendOutcome.Refused;
                        case OwnerStep.Locked:
                            RestoreNoteIfHeld();
                            RefuseSend(local.Id, visibleText, wireText, why);
                            ShowChatLocked(why);
                            return SendOutcome.Refused;
                        case OwnerStep.Unconfirmed:
                            return MarkUnconfirmed(local.Id);
                        case OwnerStep.Refuse:
                            RestoreNoteIfHeld();
                            RefuseSend(local.Id, visibleText, wireText, why);
                            return SendOutcome.Refused;
                    }
                    if (e.RpcCode is 4001 or 4007 && !resumed)
                    {
                        resumed = true;
                        firstStale = e;
                        _runtimeId = null;
                        continue;
                    }
                    RestoreNoteIfHeld();
                    RefuseSend(local.Id, visibleText, wireText, e.RpcCode is 4001 or 4007 ? (firstStale ?? e).Message : e.Message);
                    return SendOutcome.Refused;
                }
                catch (GatewayException e) when (e.IsNotConnected && wait.Waiting)
                {
                    submitted = false;
                    switch (await OwnerLinkAwayAsync(wait, e))
                    {
                        case OwnerStep.Retry:
                            continue;
                        case OwnerStep.Stopped:
                            RestoreNoteIfHeld();
                            WithdrawStoppedSend(local.Id, visibleText, wireText);
                            return SendOutcome.Refused;
                    }
                    RestoreNoteIfHeld();
                    RefuseSend(local.Id, visibleText, wireText, e.Message);
                    return SendOutcome.Refused;
                }

                EndOwnerWait(wait);
                contextNote = null; // delivered to main chat
                AcceptedSends++;
                lock (_lock) _t.MarkSent(local.Id, res.Int("user_row_id"));
                break;
            }
        }
        catch (GatewayException e)
        {
            EndOwnerWait(wait);
            if (submitted && MayHaveGoneOut(e)) return MarkUnconfirmed(local.Id);
            RestoreNoteIfHeld();
            if (queued && e.IsNotConnected)
            {
                lock (_lock)
                {
                    _t.Withdraw(local.Id);
                    if (_turnPrompt == wireText) { _turnPrompt = null; _turnStarted = null; }
                }
                Changed?.Invoke();
                return SendOutcome.NotSent;
            }
            RefuseSend(local.Id, visibleText, wireText, e.Message);
            return SendOutcome.Refused;
        }
        Changed?.Invoke();
        return SendOutcome.Accepted;
    }

    /// Why the thread could not open or send, in words for the thread's line; nil while all is well.
    public string? ThreadProblem =>
        OpenFailed ? "Couldn’t load this chat." : Messages.LastOrDefault(m => m.Role == Role.User)?.Error;
}
