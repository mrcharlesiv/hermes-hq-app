using System.Text.Json.Nodes;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Rpc;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Chat;

/// One open chat (HermesKit/Chat/LiveChatSession.swift, M1 scope): cached rows first, then the REST tail, a
/// session.resume to bind the socket, prompt.submit, the streamed reply, and Stop. Changed fires on a background
/// thread; the UI marshals it to its own.
public sealed partial class ChatSession : IAsyncDisposable
{
    private readonly HermesClient _client;
    private readonly Transcript _t = new();
    private readonly object _lock = new();
    private readonly SemaphoreSlim _resumeGate = new(1, 1);
    private string? _runtimeId;
    private long _nextOffset;
    private bool _hasOlder = true;
    private bool _stopPending;

    public string Profile { get; }
    public string StoredId { get; private set; }
    public string Title { get; private set; }

    public event Action? Changed;
    /// [questions] Raised (on a background thread) each time session.resume binds a runtime id.
    public event Action<string>? RuntimeBound;
    /// [questions] Stop was pressed and the turn hasn't started again: requests for it are refused (spec 1x §2.3).
    public bool TurnInterrupted { get; private set; }
    /// Every stream event of this chat, after the transcript took it (features fold their own state: the activity
    /// shelf, reasoning timing). Raised on a background thread.
    public event Action<RpcEvent>? EventApplied;
    /// The chat was renamed (Rename…).
    public event Action<string>? TitleChanged;
    /// The runtime session id on the gateway, once bound (steer, stop a helper, react).
    public string? RuntimeId => _runtimeId;
    /// The last read of earlier messages failed; Try Again calls LoadOlderAsync again (§4.2).
    public bool OlderFailed { get; private set; }
    /// [transcript] A send the gateway refused or that never left: the one "Couldn’t Send" card at the composer (§6.3;
    /// 93f984bb1 LiveChatSession `sendFailure`). Typed and memo refusals both set it, the latest wins. Cleared only where
    /// the Mac clears it: the card's ✕ (DismissSendFailure), and a fresh typed send (not a queue drain, not a memo send).
    public SendFailure? SendFailure { get; private set; }

    /// The card's ✕, or its Try Again with nothing to send again (`dismissSendFailure`).
    public void DismissSendFailure()
    {
        if (SendFailure == null) return;
        SendFailure = null;
        Changed?.Invoke();
    }

    /// The card's Try Again sends what is in the field now; with no words and no attachments there is nothing to send
    /// again and the card just goes (ChatViewController `sendFailureCard.onPrimary`; a memo draft chip doesn't count).
    public static bool TryAgainSends(string fieldText, bool hasAttachments) => fieldText.Trim().Length > 0 || hasAttachments;

    /// A refusal: the card says why (`refuseSend`'s `sendFailure = SendFailure.make(reason:)`).
    /// [WIN-PROBLEM-CARD-REST] One card: when the chat is locked (a resume or a submit refused it during this send),
    /// the problem card names the way on and no "Couldn’t Send" shows as well (`sendFailure = nil   // one card`).
    private void SetSendFailure(string reason) =>
        SendFailure = SessionProblem?.Primary == Transcripts.SessionProblemPrimary.NewChat ? null : Transcripts.SendFailure.Make(reason);

    /// [WIN-SEND-REFUSE-WITHDRAW] A refused typed send's words go back to the field, with why (93f984bb1
    /// LiveChatSession `onDraftReturned` from `refuseSend`): the gateway's reason, or "Your message wasn’t sent." when it
    /// gave none. The words are what the bubble showed (a skill's invocation, not its body). Raised on a background
    /// thread; the composer applies it with ReturnedDraft (typing done meanwhile is never overwritten).
    public event Action<string, string>? DraftReturned;

    /// The field after a send's words come back (AppModel's `onDraftReturned`, [transcript] §6.3): an empty field takes
    /// them; else they go before what was typed meanwhile, unless the field already holds them (or starts with them).
    public static string ReturnedDraft(string typed, string returned)
    {
        if (typed.Length == 0) return returned;
        if (returned.Length > 0 && typed != returned && !typed.StartsWith(returned + "\n", StringComparison.Ordinal))
            return returned + "\n" + typed;
        return typed;
    }

    /// `refuseSend`: the optimistic bubble goes (no bubble left behind and no error card: one failure, one place), the
    /// chat settles, the "Couldn’t Send" card says why, and the words go back to the field. The queue parks on the
    /// Refused outcome (ComposerQueue.Deliver), so a refusal never cascades through the rest of it.
    private void RefuseSend(string localId, string draft, string text, string reason)
    {
        lock (_lock)
        {
            _t.Withdraw(localId);
            if (_turnPrompt == text) { _turnPrompt = null; _turnStarted = null; }   // no turn ran: nothing to time
        }
        SetSendFailure(reason);
        Changed?.Invoke();
        DraftReturned?.Invoke(draft, reason.Length == 0 ? NotSentWords : reason);
    }

    // [transcript] How long each turn took (§6.6), by the prompt's row id (or local id) — kept for the app's run.
    private static readonly Dictionary<string, double> TurnMarks = [];
    private DateTimeOffset? _turnStarted;
    private string? _turnPrompt;
    // [transcript] "Waking up…" while a cold bot starts (§6.5), "Still waking up…" after 20 s.
    private DateTimeOffset? _resumeStarted;
    public static readonly TimeSpan StillWakingAfter = TimeSpan.FromSeconds(20);
    /// [composer] The chat's live info: `session.resume`'s `info` and each `session.info` payload (model, provider,
    /// reasoning_effort, fast, yolo, cwd, usage). On a background thread.
    public event Action<JsonNode>? InfoChanged;
    /// [composer] A reply ended. True when the gateway said it is idle (`session.info running:false`); false at
    /// `message.complete` or an error, when the queue waits a moment for that.
    public event Action<bool>? TurnEnded;
    /// [composer] Stop was pressed (the queue parks).
    public event Action? Stopped;
    /// [WIN-OWN-TURN-ROWS] A turn of ours began (true: the send's own bubble, a stream frame, a resume that found one
    /// running) or ended (false), as the Mac's `onRunningChange`: Busy as it stands after a Changed that moved it. Raised
    /// on the thread that changed it.
    public event Action<bool>? RunningChanged;
    /// [WIN-OWN-TURN-ROWS] The resume named the chat's stored id as another than it had (`onStoredIdResolved`): (from, to).
    public event Action<string, string>? StoredIdResolved;
    private int _reportedRunning;

    private void ReportRunning()
    {
        var now = Busy ? 1 : 0;
        if (Interlocked.Exchange(ref _reportedRunning, now) != now) RunningChanged?.Invoke(now == 1);
    }

    public ChatSession(HermesClient client, string profile, string storedId, string title)
    {
        _client = client;
        Profile = profile;
        StoredId = storedId;
        Title = title;
        _openedId = storedId;
        client.Rpc.Event += OnEvent;
        client.Rpc.Reconnected += OnReconnected;
        Changed += ReportRunning;   // [WIN-OWN-TURN-ROWS] first, so RunningChanged comes before the screen's redraw
    }

    public IReadOnlyList<ChatMessage> Messages { get { lock (_lock) return [.. _t.Messages]; } }
    public bool Busy { get { lock (_lock) return _t.Busy; } }
    public string? Status
    {
        get
        {
            lock (_lock)
            {
                if (_waitingForOwner is { } waiting) return waiting.Status;   // [WIN-OWNER-WAIT]
                if (_t.Status != null || _t.Busy) return _t.Status;
                if (_resumeStarted is { } since && _runtimeId == null)
                    return DateTimeOffset.Now - since >= StillWakingAfter ? "Still waking up…" : "Waking up…";
                // [WIN-EXTERNAL-TURN] Another process's turn (a bot's message, Telegram, a job's hand-off).
                if (ExternalWork != null) return ExternalTurn.StatusWords;
                return null;
            }
        }
    }

    /// How long the turn started by `prompt` (a user message) took, when this app saw it run (TurnMarks, §6.6).
    public double? TurnSeconds(ChatMessage prompt)
    {
        lock (TurnMarks) return TurnMarks.TryGetValue(MarkKey(prompt), out var s) ? s : null;
    }

    private string MarkKey(ChatMessage prompt) =>
        $"{_client.AccountId}\u0001{Profile}\u0001{StoredId}\u0001{(prompt.RowId is { } r ? r.ToString() : prompt.Text)}";
    public bool HasOlder => _hasOlder;

    /// Paints the cache, then reads the newest page and binds the socket. A chat this app just started
    /// (StartedChats, the Mac's `startsNew`) has no stored rows yet: only the resume runs.
    public async Task OpenAsync(CancellationToken ct = default)
    {
        var fresh = StartedChats.Take(Profile, StoredId);
        if (_client.Cache?.Read(_client.AccountId, Profile, StoredId) is { Count: > 0 } cached)
        {
            // [WIN-SENT-TITLES] a titled request shows its title from the first paint (the cache holds the stored prompt)
            lock (_lock) _t.ReplaceWithHistory(SentTitles.Applied(cached));
            RestoreLostSends();   // [WIN-LOST-SEND-RESTORE] the saved copy shows a lost send too (keepSavedCopy)
            Changed?.Invoke();
        }
        if (fresh && Messages.Count == 0)
        {
            _hasOlder = false;   // nothing stored above an empty new chat to page back to
            Changed?.Invoke();
            try { await ResumeAsync(ct); } catch (GatewayException) { /* the first send resumes again */ }
            OpenSettled();   // [WIN-EXTERNAL-TURN]
            return;
        }
        var history = RefreshAsync(ct);
        var bind = ResumeAsync(ct);
        try { await history; }
        catch (GatewayException) { OpenFailed = true; throw; }   // [WIN-PROBLEM-CARD-REST] the Mac's `openError`
        try { await bind; } catch (GatewayException) { /* the first send resumes again */ }
        OpenSettled();   // [WIN-EXTERNAL-TURN] another process's turn here? (`checkExternalWork("open")`)
    }

    /// Re-reads the newest page (REST is the transcript authority).
    public async Task RefreshAsync(CancellationToken ct = default)
    {
        var page = await _client.HistoryAsync(Profile, StoredId, 24, 0, ct);
        _nextOffset = page.NextOffset;
        _hasOlder = page.PossiblyTruncated;
        lock (_lock) _t.ReplaceWithHistory(SentTitles.Applied(page.Messages));   // [WIN-SENT-TITLES] keeps its title
        _client.Cache?.Write(_client.AccountId, Profile, StoredId, page.Messages);
        // [WIN-LOST-SEND-MARKER/RESTORE] a marked send the page now holds did arrive and goes (`settleLostSends`); every
        // other one this screen does not show comes back where it was said (`restoreLostSends`, as applyFirstPage)
        RestoreLostSends();
        Changed?.Invoke();
        NoteStoredRows(page);   // [WIN-EXTERNAL-TURN] rows written by another process? (`checkExternalWork("new rows")`)
    }

    public async Task LoadOlderAsync(CancellationToken ct = default)
    {
        if (!_hasOlder) return;
        HistoryPage page;
        try { page = await _client.HistoryAsync(Profile, StoredId, 60, _nextOffset, ct); OlderFailed = false; }
        catch (GatewayException) { OlderFailed = true; Changed?.Invoke(); throw; }
        _nextOffset = page.NextOffset;
        _hasOlder = page.PossiblyTruncated && page.Messages.Count > 0;
        lock (_lock) _t.PrependHistory(SentTitles.Applied(page.Messages));   // [WIN-SENT-TITLES] older rows too
        Changed?.Invoke();
    }

    private async Task<string> ResumeAsync(CancellationToken ct)
    {
        await _resumeGate.WaitAsync(ct);
        try
        {
            if (_runtimeId != null) return _runtimeId;
            _resumeStarted ??= DateTimeOffset.Now;
            using var still = new Timer(_ => Changed?.Invoke(), null, StillWakingAfter + TimeSpan.FromMilliseconds(50), Timeout.InfiniteTimeSpan);
            try {
            JsonNode res;
            try
            {
                try { res = await Resume(ct); }
                catch (GatewayException e) when (e.Code is "timeout" or "offline"
                    || (e.RpcCode == 4007 && e.Message.Contains("no longer live")))
                { res = await Resume(ct); }
            }
            catch (GatewayException e) { NoteResumeFailed(e); throw; }   // [WIN-COMPOSER-CARD-IDS] "Couldn’t reopen this chat"
            NoteResumed();   // [WIN-COMPOSER-CARD-IDS] the chat came back
            _runtimeId = res.Text("session_id") ?? throw new GatewayException("rpc", "The gateway didn't open the chat.");
            if ((res.Text("session_key") ?? res.Text("resumed")) is { } resolved && resolved != StoredId)
            {
                var from = StoredId;
                StoredId = resolved;
                StoredIdResolved?.Invoke(from, resolved);   // [WIN-OWN-TURN-ROWS]
            }
            // [WIN-INFLIGHT-GRAFT] running, the inflight and queued prompts, a lost send that arrived after all
            if (GraftInflight(res, resuming: res.Str("status") == "resuming")) _ = RefreshQuietly();
            Changed?.Invoke();
            RuntimeBound?.Invoke(_runtimeId);
            if (res.Obj("info") is { } info) { Cwd = info.Str("cwd") ?? Cwd; InfoChanged?.Invoke(info); }
            return _runtimeId;
            } finally { _resumeStarted = null; }
        }
        finally { _resumeGate.Release(); }
    }

    private Task<JsonNode> Resume(CancellationToken ct) => _client.Rpc.RequestAsync("session.resume", new JsonObject
    {
        ["session_id"] = StoredId, ["cols"] = 96, ["source"] = "desktop", ["defer_history"] = true,
        ["omit_messages"] = true, ["profile"] = Profile,
    }, ResumeTimeout, ct);

    /// How long one `session.resume` waits for its answer (the waking resume's two minutes; tests shorten it).
    public TimeSpan ResumeTimeout { get; set; } = TimeSpan.FromSeconds(120);

    /// [composer] Binds the socket to this chat if it isn't (session-scoped calls resume first).
    public Task<string> EnsureRuntimeAsync(CancellationToken ct = default) => ResumeAsync(ct);

    /// [composer] A session-scoped call refused 4001 (stale runtime): the next call resumes.
    public void ForgetRuntime() => _runtimeId = null;

    /// Sends one message. A timeout or socket loss after sending is never resent: the bubble says "Delivery unconfirmed".
    /// [composer] `queued`: a queue drain (`prompt.submit queued:true` waits behind a turn still unwinding).
    /// `display`: what the bubble shows when it isn't the text sent (a skill's invocation).
    public async Task<SendOutcome> SendAsync(string text, CancellationToken ct = default, bool queued = false,
        string? display = null)
    {
        text = text.Trim();
        if (text.Length == 0) return SendOutcome.Refused;
        // [WIN-SENT-TITLES] A titled request whose title came back to the field (a refused send, or its queue row taken
        // out to edit) and is sent again goes out as the request it stands for, in the main bot's chat only.
        if (display == null && Profile == "default" && SentTitles.Prompt(text) is { } prompt)
        {
            display = text;
            text = prompt.Trim();
        }
        // §6.2, §6.3: a fresh send answers the card about the last one (`sendAfterOpen`); a queue drain doesn't.
        if (!queued) { SendFailure = null; ClearProblemForSend(); }
        ChatMessage local;
        lock (_lock) local = _t.AddLocalUser(display?.Trim() is { Length: > 0 } shown ? shown : text);
        AnchorTurn(local.Id, text);   // [WIN-INFLIGHT-GRAFT] the turn's prompt, by the words that went out
        _stopPending = false;
        TurnInterrupted = false;
        _turnStarted = DateTimeOffset.Now;
        _turnPrompt = text;
        Changed?.Invoke();
        EndExternalIfOursRuns();   // [WIN-EXTERNAL-TURN] a turn of ours started
        var draft = display?.Trim() is { Length: > 0 } words ? words : text;
        // [WIN-OWNER-WAIT] A refusal because another Hermes process holds the chat waits for it, then sends
        // (ChatSession+OwnerWait.cs; the Mac's submit loop with its `ownerDeadline`).
        var wait = BeginOwnerWaitRun(local.Id);
        var submitted = false; // past this point a timeout or drop means "maybe delivered": never resend
        var resumed = false;
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
                    try { res = await Submit(runtime, text, ct, queued, localId: local.Id); }
                    catch (GatewayException e) when (e.RpcCode == 4009 && !IsChatLocked(e))
                    {
                        res = await RetryBusy(runtime, text, ct, queued, local.Id);
                    }
                }
                catch (GatewayException e) when (e.Code == "rpc")
                {
                    submitted = false;   // refused: nothing ran
                    var (step, why) = await OwnerRefusalAsync(wait, e, photos: false);
                    switch (step)
                    {
                        case OwnerStep.Retry:
                            resumed = false;   // the chat answered on the runtime in hand: a later reap may resume again
                            firstStale = null;
                            continue;
                        case OwnerStep.Stopped:
                            WithdrawStoppedSend(local.Id, draft, text);
                            return SendOutcome.Refused;
                        case OwnerStep.Locked:
                            RefuseSend(local.Id, draft, text, why);
                            ShowChatLocked(why);
                            return SendOutcome.Refused;
                        case OwnerStep.Unconfirmed:
                            return MarkUnconfirmed(local.Id);
                        case OwnerStep.Refuse:
                            RefuseSend(local.Id, draft, text, why);
                            return SendOutcome.Refused;
                    }
                    // 4001 and 4007: a stale runtime resumes once and the send goes once more.
                    if (e.RpcCode is 4001 or 4007 && !resumed)
                    {
                        resumed = true;
                        firstStale = e;
                        _runtimeId = null;
                        continue;
                    }
                    RefuseSend(local.Id, draft, text, e.RpcCode is 4001 or 4007 ? (firstStale ?? e).Message : e.Message);
                    return SendOutcome.Refused;
                }
                catch (GatewayException e) when (e.IsNotConnected && wait.Waiting)
                {
                    submitted = false;   // [WIN-SEND-NOTSENT-REFUSE] never went out: the owner wait goes on while the link is away
                    switch (await OwnerLinkAwayAsync(wait, e))
                    {
                        case OwnerStep.Retry:
                            continue;
                        case OwnerStep.Stopped:
                            WithdrawStoppedSend(local.Id, draft, text);
                            return SendOutcome.Refused;
                    }
                    RefuseSend(local.Id, draft, text, e.Message);
                    return SendOutcome.Refused;
                }
                EndOwnerWait(wait);
                lock (_lock) _t.MarkSent(local.Id, res.Int("user_row_id"));
                break;
            }
        }
        catch (GatewayException e)
        {
            EndOwnerWait(wait);
            // [WIN-SEND-NOTSENT-REFUSE] Only a call that may have gone out (no answer in time, or the socket closed before
            // the gateway answered: `isTimeout || isConnectionLost`) is "Delivery unconfirmed". One that never went out
            // (`isNotConnected`: no socket, the socket wait ran out) is refused and handed back: safe to send again.
            if (submitted && MayHaveGoneOut(e)) return MarkUnconfirmed(local.Id);
            if (queued && e.IsNotConnected)
            {
                lock (_lock)
                {
                    _t.Withdraw(local.Id);
                    if (_turnPrompt == text) { _turnPrompt = null; _turnStarted = null; }
                }
                Changed?.Invoke();
                return SendOutcome.NotSent;
            }
            RefuseSend(local.Id, draft, text, e.Message);
            return SendOutcome.Refused;
        }
        Changed?.Invoke();
        return SendOutcome.Accepted;
    }

    /// [WIN-SEND-NOTSENT-REFUSE] `error.isTimeout || error.isConnectionLost` (LiveChatSession.swift at 93f984bb1): the
    /// request may have reached the gateway. A not-sent one (`isNotConnected`) and any other "offline" never did.
    internal static bool MayHaveGoneOut(GatewayException e) => e.Code == "timeout" || e.IsConnectionLost;

    /// Maybe delivered: the bubble keeps its mark, never withdrawn, never the card, never resent (04 §2.5).
    private SendOutcome MarkUnconfirmed(string localId)
    {
        lock (_lock) _t.MarkFailed(localId, UnconfirmedMark);
        NoteLostSend(localId, memo: false);   // [WIN-LOST-SEND-MARKER] its Sessions row says "Not Delivered:"
        Changed?.Invoke();
        return SendOutcome.Unconfirmed;
    }

    /// [authority] `localId` is the send's own bubble: its `submission_id` ("hq-" + localId) stays the same through every
    /// retry of that send, so a session authority replays one admission rather than adding a turn (LiveChatSession.swift
    /// send). The plain sidecar never sees the key: RpcConnection strips it there (AuthorityWire).
    private Task<JsonNode> Submit(string runtime, string text, CancellationToken ct, bool queued = false, JsonObject? extra = null,
        string? localId = null)
    {
        var p = new JsonObject { ["session_id"] = runtime, ["text"] = text, ["profile"] = Profile };
        if (localId != null) p["submission_id"] = AuthorityWire.SubmissionId(localId);
        if (queued) p["queued"] = true;
        // [chat actions] A rewind's keys (RewindParams.Make): truncate before a stored user row.
        if (extra != null) foreach (var (k, v) in extra) p[k] = v?.DeepClone();
        return _client.Rpc.RequestAsync("prompt.submit", p, TimeSpan.FromSeconds(1800), ct);
    }

    /// 4009: retry every 150 ms for up to 6 s, then hand the text back.
    private async Task<JsonNode> RetryBusy(string runtime, string text, CancellationToken ct, bool queued = false, string? localId = null)
    {
        var until = DateTimeOffset.UtcNow.AddSeconds(6);
        while (true)
        {
            await Task.Delay(150, ct);
            try { return await Submit(runtime, text, ct, queued, localId: localId); }
            catch (GatewayException e) when (e.RpcCode == 4009 && DateTimeOffset.UtcNow < until) { }
        }
    }

    /// Stop: local first, then session.interrupt (40 s). If it doesn't land, interrupt again on the next message.start.
    public async Task StopAsync()
    {
        // [WIN-MEMO-SEND-HOST] A memo still staging comes back as the draft; nothing reached the gateway (ChatSession+Memo.cs).
        if (MemoStopWhileStaging()) return;
        StopAttachmentSends(); // a send still uploading or attaching withdraws (ChatSession+Attachments.cs)
        lock (_lock) _t.Stop();
        TurnInterrupted = true;
        Changed?.Invoke();
        Stopped?.Invoke();
        if (_runtimeId is not { } runtime) return;
        try
        {
            await _client.Rpc.RequestAsync("session.interrupt",
                new JsonObject { ["session_id"] = runtime, ["profile"] = Profile }, TimeSpan.FromSeconds(40));
        }
        catch (GatewayException e) when (e.RpcCode is 4001 or 4007) { _runtimeId = null; }
        catch (GatewayException) { _stopPending = true; }
    }

    private void OnEvent(RpcEvent e)
    {
        if (e.Type == "session.reclaimed" && e.Payload.Text("session_id") == _runtimeId) { _runtimeId = null; return; }
        if (e.SessionId.Length == 0 || e.SessionId != _runtimeId)
        {
            if (e.Type == "hq.replay_truncated" && e.SessionId == _runtimeId) _ = RefreshQuietly();
            return;
        }
        if (_stopPending && e.Type == "message.start" && _runtimeId is { } r)
        {
            _stopPending = false;
            _ = _client.Rpc.RequestAsync("session.interrupt",
                new JsonObject { ["session_id"] = r, ["profile"] = Profile }, TimeSpan.FromSeconds(40));
        }
        if (e.Type == "session.resume_progress" && e.Payload.Str("status") == "failed") { _runtimeId = null; return; }
        if (e.Type == "session.info" && e.Payload is JsonObject info) { Cwd = info.Str("cwd") ?? Cwd; InfoChanged?.Invoke(info); }
        Transcript.Outcome outcome;
        lock (_lock) outcome = _t.Apply(e);
        EventApplied?.Invoke(e);
        if (outcome == Transcript.Outcome.Problem)
        {
            string? words;
            lock (_lock) words = _t.ProblemText;
            RaiseProblem(words ?? "");
            return;
        }
        if (outcome == Transcript.Outcome.None)
        {
            if (e.Type == "session.info" && e.Payload.Bool("running") == false && !Busy) TurnEnded?.Invoke(true);
            return;
        }
        if (outcome == Transcript.Outcome.TurnEnded) MarkTurn();
        EndExternalIfOursRuns();   // [WIN-EXTERNAL-TURN] our own turn's frames say what runs from here
        Changed?.Invoke();
        if (outcome == Transcript.Outcome.TurnEnded)
        {
            TurnInterrupted = false; // the stopped turn's end arrived: later turns get their cards
            TurnEnded?.Invoke(e.Type == "session.info");
            _ = RefreshQuietly();
        }
    }

    private void OnReconnected(bool restarted)
    {
        // Re-bind the open chat after every reconnect; a still-live session comes back with the same runtime id.
        if (restarted) _runtimeId = null;
        _ = Task.Run(async () =>
        {
            var read = false;
            try
            {
                if (_runtimeId is { } r)
                {
                    try
                    {
                        var snapshot = await _client.Rpc.RequestAsync("session.activate", new JsonObject
                        { ["session_id"] = r, ["cols"] = 96, ["omit_messages"] = true, ["profile"] = Profile },
                            TimeSpan.FromSeconds(30));
                        // [WIN-INFLIGHT-GRAFT] another turn than ours runs now: ours is sealed and read afresh; then
                        // running, the inflight and queued prompts, a lost send that arrived after all
                        read |= EndOwnTurnIfAnotherRuns(snapshot);
                        read |= GraftInflight(snapshot);
                    }
                    catch (GatewayException e) when (e.RpcCode is 4001 or 4007) { _runtimeId = null; }
                }
                await ResumeAsync(CancellationToken.None);
                if (restarted || read) await RefreshAsync();
            }
            catch (GatewayException) { }
        });
    }

    /// The turn ended: its length goes on the prompt that started it (by row id once sent, else its words).
    private void MarkTurn()
    {
        if (_turnStarted is not { } started || _turnPrompt is not { } prompt) return;
        _turnStarted = null;
        ChatMessage? user;
        lock (_lock) user = _t.Messages.LastOrDefault(m => m.Role == Role.User && m.Text == prompt);
        if (user == null) return;
        var seconds = (DateTimeOffset.Now - started).TotalSeconds;
        lock (TurnMarks)
        {
            TurnMarks[MarkKey(user)] = seconds;
            TurnMarks[MarkKey(user with { RowId = null })] = seconds;
            if (TurnMarks.Count > 400) TurnMarks.Remove(TurnMarks.Keys.First());
        }
    }

    /// A call on this chat's runtime session (resumed first): `session_id` and `profile` are added to `params`.
    public async Task<JsonNode> CallAsync(string method, JsonObject parameters, TimeSpan timeout, CancellationToken ct = default)
    {
        var runtime = await ResumeAsync(ct);
        parameters["session_id"] = runtime;
        parameters["profile"] = Profile;
        return await _client.Rpc.RequestAsync(method, parameters, timeout, ct);
    }

    /// Renames the chat (`session.title` on its runtime, as SessionWrite's socket path); returns the stored title.
    public async Task<string> RenameAsync(string title, CancellationToken ct = default)
    {
        var typed = title.Trim();
        var answer = await CallAsync("session.title", new JsonObject { ["title"] = typed }, TimeSpan.FromSeconds(20), ct);
        Title = answer.Text("title") ?? typed;
        TitleChanged?.Invoke(Title);
        return Title;
    }

    /// Your Tapback (`message.react`): `emoji` replaces your previous one; your current one (or null) removes it.
    /// Drawn at once; the gateway's list wins when it answers; a refusal puts the old list back.
    public async Task ReactAsync(string messageId, string? emoji, CancellationToken ct = default)
    {
        ChatMessage? m;
        lock (_lock) m = _t.Messages.LastOrDefault(x => x.Id == messageId);
        if (m == null) return;
        var before = m.Reactions ?? [];
        var mine = before.FirstOrDefault(r => r.IsMine)?.Emoji;
        var sent = emoji == mine ? null : emoji;
        lock (_lock) _t.SetReactions(messageId, Hermes.Core.Transcripts.MessageReactions.Applying(before, sent));
        Changed?.Invoke();
        try
        {
            var p = new JsonObject { ["emoji"] = sent, ["author"] = "user" };
            if ((m.ReactionRow ?? m.RowId) is { } row) p["row_id"] = row;
            else p["newest_role"] = m.Role == Role.User ? "user" : "assistant";
            var answer = await CallAsync("message.react", p, TimeSpan.FromSeconds(10), ct);
            lock (_lock) _t.SetReactions(messageId, Hermes.Core.Transcripts.MessageReactions.Decode(answer.Get("reactions")));
        }
        catch (GatewayException)
        {
            lock (_lock) _t.SetReactions(messageId, before);
            Changed?.Invoke();
            throw;
        }
        Changed?.Invoke();
    }

    private async Task RefreshQuietly()
    {
        try { await RefreshAsync(); } catch (GatewayException) { }
    }

    // ------------------------------------------------------------------ [composer] steers, local rows, session calls

    /// Seals the live reply where it stands and adds the pending bubble under it (the desktop's
    /// `appendMidTurnUserMessage`). Returns the bubble's local id.
    public string BeginSteer(string shown)
    {
        string id;
        lock (_lock) id = _t.BeginSteer(shown);
        Changed?.Invoke();
        return id;
    }

    /// `session.redirect {session_id, text[, profile]}` for a steer begun with BeginSteer (resumes a stale runtime and
    /// retries once). `Unsupported`: the gateway can't redirect (4010, -32601).
    public async Task<(Composer.SteerOutcome Outcome, bool Unsupported)> RedirectAsync(string localId, string text)
    {
        GatewayException? failure = null;
        for (var attempt = 0; attempt < 2; attempt++)
        {
            string runtime;
            try { runtime = await ResumeAsync(CancellationToken.None); }
            catch (GatewayException) { break; }
            try
            {
                var res = await _client.Rpc.RequestAsync("session.redirect",
                    new JsonObject { ["session_id"] = runtime, ["text"] = text, ["profile"] = Profile }, TimeSpan.FromSeconds(20));
                var status = res.Str("status") ?? "";
                if (status == "redirected")
                {
                    lock (_lock) _t.SteerTaken(localId);
                    Changed?.Invoke();
                    return (Composer.SteerOutcome.Redirected, false);
                }
                if (status == "queued")
                {
                    lock (_lock) _t.SteerNextTurn(localId);
                    Changed?.Invoke();
                    return (Composer.SteerOutcome.NextTurn, false);
                }
                failure = null;
                break;
            }
            catch (GatewayException e)
            {
                failure = e;
                if (e.RpcCode == 4001) { _runtimeId = null; continue; }
                break;
            }
        }
        lock (_lock) _t.SteerFailed(localId);
        Changed?.Invoke();
        return (Composer.SteerOutcome.Failed, failure is { RpcCode: 4010 or -32601 });
    }

    /// Typed words may go into the running reply now: a reply runs and no Stop is unwinding.
    public bool CanSteerNow { get { lock (_lock) return _t.Busy && !_t.StopUnwinding; } }

    /// A local row (a slash command's output): never cached, kept across history reads.
    public string AddLocalRow(Role role, ChatPart part)
    {
        string id;
        lock (_lock) id = _t.AddLocal(role, part);
        Changed?.Invoke();
        return id;
    }

    /// Replaces a local row's part, or removes the row (null).
    public void UpdateLocalRow(string id, ChatPart? part)
    {
        lock (_lock) _t.ReplaceLocal(id, part);
        Changed?.Invoke();
    }

    /// A session-scoped call (spec 1x §0; LiveChatSession+Menus.swift `sessionCall`): `session_id` (when bound) and
    /// `profile` are added; a stale runtime (4001) resumes once and sends once more.
    public async Task<JsonNode> CallAsync(string method, JsonObject parameters, TimeSpan timeout, SessionNeed need,
        CancellationToken ct = default)
    {
        if (_runtimeId == null)
        {
            switch (need)
            {
                case SessionNeed.Required: throw new GatewayException("loading", "This chat is still loading. Try again when it is ready.");
                case SessionNeed.ResumeFirst: await ResumeAsync(ct); break;
            }
        }
        var resumed = false;
        while (true)
        {
            var runtime = _runtimeId;
            var p = (JsonObject)parameters.DeepClone();
            if (runtime != null) p["session_id"] = runtime;
            p["profile"] = Profile;
            try { return await _client.Rpc.RequestAsync(method, p, timeout, ct); }
            catch (GatewayException e) when (e.RpcCode == 4001 && !resumed && runtime != null)
            {
                resumed = true;
                _runtimeId = null;
                var stale = e;
                try { await ResumeAsync(ct); }
                catch (GatewayException) { System.Runtime.ExceptionServices.ExceptionDispatchInfo.Throw(stale); }
            }
        }
    }

    public ValueTask DisposeAsync()
    {
        _closed = true;
        EndExternalWork("screen off");   // [WIN-EXTERNAL-TURN] off screen nothing reads the rows
        _client.Rpc.Event -= OnEvent;
        _client.Rpc.Reconnected -= OnReconnected;
        return ValueTask.CompletedTask;
    }
}

/// [composer] How a send came out: accepted (it runs or waits in the gateway's queue), refused (nothing was sent), or
/// unconfirmed (it may have reached the gateway; never resent).
public enum SendOutcome { Accepted, Refused, Unconfirmed, NotSent }

/// [composer] What a session-scoped call does without a runtime id (HermesKit SessionCallRuntime).
public enum SessionNeed
{
    /// Resume the chat first (the slash dispatcher).
    ResumeFirst,
    /// Fail with "This chat is still loading." (model writes).
    Required,
    /// Send without `session_id` (`model.options`, `commands.catalog`).
    Optional,
}
