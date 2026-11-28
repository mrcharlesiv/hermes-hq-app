using System.Text.Json.Nodes;
using Hermes.Core.Attachments;
using Hermes.Core.Composer;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Transcripts;
using Hermes.Core.Voice;

namespace Hermes.Core.Chat;

// [WIN-MEMO-SEND-HOST] Voice memos in the live chat (HermesKit/Chat/LiveChatSession+Memo.swift at 6e2cec67f; spec
// 1x-voice §4.2–§4.5, #521): the optimistic bubble playing the local recording (plus any photos/files staged beside it
// during review), the staging pipeline (`MemoUploader` + `AttachForSendAsync`), the rewrite to the final text, then
// `prompt.submit` with the branches the chat's text send has (4001/4007 resume once, 4009 busy window, the wait for
// another Hermes process holding the chat (ChatSession+OwnerWait.cs), a locked chat, a refusal, "Delivery unconfirmed").
// Stop while a memo stages cancels the staging at once and hands the memo (and any staged attachments) back as the
// chat's draft (nothing reached the gateway). A refused memo comes back as the draft chip with the words typed beside
// it and any staged attachments, and the chat says why in the "Couldn’t Send" card; a retry into the same chat reuses
// what the first attempt staged (no second upload, attach or paid transcription).

/// A memo send in flight (by its optimistic bubble's id).
public sealed class MemoSendContext(
    MemoFile memo,
    string typed,
    int epoch,
    string accountId,
    bool steer,
    IReadOnlyList<DraftAttachment>? attachments = null,
    AttachmentCenter? center = null)
{
    public MemoFile Memo { get; } = memo;
    /// Typed beside the memo: the next bubble in the same turn; back into the empty field on a refusal.
    public string Typed { get; } = typed;
    /// Photos/files attached beside the memo (e.g., during review, #521): uploaded and submitted in the same turn.
    public IReadOnlyList<DraftAttachment> Attachments { get; } = attachments ?? [];
    /// The attachment center owning `Attachments`, when sent from the chat's attachment tray.
    public AttachmentCenter? Center { get; } = center;
    /// The Stop epoch the send began in.
    public int Epoch { get; } = epoch;
    /// The account the send belongs to: the memo stores are written only while it is still the one signed in.
    public string AccountId { get; } = accountId;
    /// It went into the running reply (`session.redirect`), not a turn of its own.
    public bool Steer { get; } = steer;
    /// Stop cancels the staging while it stages.
    public CancellationTokenSource Staging { get; } = new();
    /// The chat's stored id when staging began: what an earlier attempt's staging is kept under (and forgotten by).
    public string? StoredId { get; set; }
    /// The gateway's copy, once staged.
    public string? GatewayPath { get; set; }
    /// `prompt.submit` (or the steer) went out.
    public bool Submitted { get; set; }
}

/// How a memo send ended (the Swift's `MemoSendOutcome`).
public enum MemoSendOutcome { Acknowledged, Unconfirmed, Refused, Withdrawn }

public sealed partial class ChatSession : IMemoChatSession
{
    /// What a send overtaken by Stop says as it hands the memo back.
    public const string StoppedBeforeSending = "Stopped before sending";
    /// What a refusal with no words of its own says.
    public const string NotSentWords = "Your message wasn’t sent.";
    /// The mark on a memo whose `prompt.submit` may or may not have reached the gateway (04 §2.5).
    public const string UnconfirmedMark = "Delivery unconfirmed";

    private readonly Dictionary<string, MemoSendContext> _memoSends = [];
    private readonly Dictionary<string, AttachedSend> _memoAttached = [];

    /// The signed-in account's memo stores (drafts, shapes, playback cache). Null: memos aren't offered.
    public MemoAccountStores? MemoStores { get; set; }
    /// The gateway REST the memo pipeline uses (`IMemoTransfers` for the upload and the transcription).
    public IMemoGateway? MemoGateway { get; set; }
    /// The uploader's kept state (null: the app's shared one).
    public MemoUploadState? MemoUploads { get; set; }
    /// "Ivy", for the memo notices (the chat's bot; its title when unset).
    public string? MemoBotName { get; set; }
    private string BotName => MemoBotName is { Length: > 0 } n ? n : Title;

    /// The memo's typed words go back to the field, with why (`onDraftReturned`): "Stopped before sending", or the
    /// refusal's reason.
    public event Action<string, string>? MemoDraftReturned;

    // MARK: ChatVoiceMemos

    /// The chat's layout scope (the draft store's key): "<account id>|<profile>|<stored session id>".
    public string? MemoScope => DraftScope;

    public MemoFile? MemoDraft => MemoStoresAreMine ? MemoStores!.Drafts?.Draft(DraftScope) : null;

    public void SetMemoDraft(MemoFile? memo)
    {
        if (!MemoStoresAreMine) return;
        MemoStores!.Drafts?.Set(memo, DraftScope);
    }

    /// The memo stores signed in are this chat's account's (an account switch mid-send must not write into another's).
    public bool MemoStoresAreMine => MemoStores is { } s && s.AccountId == _client.AccountId;

    /// The memo sends still in flight, by bubble id.
    public IReadOnlyCollection<string> MemoSendIds { get { lock (_memoSends) return [.. _memoSends.Keys]; } }

    /// A memo of this Stop epoch is staging (`prompt.submit` hasn't gone out yet).
    public bool MemoStaging
    {
        get
        {
            var epoch = Volatile.Read(ref _stopEpoch);
            lock (_memoSends) return _memoSends.Values.Any(c => !c.Submitted && c.Epoch == epoch);
        }
    }

    private MemoSendContext? Memo(string localId) { lock (_memoSends) return _memoSends.GetValueOrDefault(localId); }

    private MemoUploader Uploader() => new(MemoGateway ?? throw new MemoSendException("Couldn’t reach this chat."), MemoUploads);

    // MARK: Send

    /// A memo (and any words and staged photos/files beside it) as this chat's next turn: the bubble shows at once
    /// playing the local file (with any staged attachments), it stages, the bubble switches to the transcript, then
    /// `prompt.submit` (`queued` for a queue drain). Keeping optional `attachments`/`center` compatible with 2- and
    /// 3-argument callers (#521).
    public Task<SendOutcome> SendMemoAsync(
        MemoFile memo,
        string typed,
        bool queued = false,
        IReadOnlyList<DraftAttachment>? attachments = null,
        AttachmentCenter? center = null)
    {
        IReadOnlyList<DraftAttachment> extra = attachments is { Count: > 0 } ? [.. attachments] : [];
        if (center != null) _sendingCenter = center;
        ChatMessage local;
        lock (_lock)
        {
            if (extra.Count > 0)
            {
                var parts = extra
                    .OrderBy(a => a.Kind == DraftKind.Image ? 0 : 1)
                    .Select(a => (ChatPart)new AttachmentPart(LocalAttachment(a)))
                    .ToList();
                local = _t.AddLocalUser(MemoText.Optimistic(memo.Path, typed), parts);
                _t.BeginPreparing(local.Id);
            }
            else
            {
                local = _t.AddLocalUser(MemoText.Optimistic(memo.Path, typed));
            }
        }
        if (extra.Count > 0)
        {
            lock (_inFlightAttachments) _inFlightAttachments[local.Id] = [.. extra.Select(a => a.Id)];
        }
        _stopPending = false;
        TurnInterrupted = false;   // the Couldn't Send card stays: only a typed send or its ✕ clears it (as the Mac)
        _turnStarted = DateTimeOffset.Now;
        var context = new MemoSendContext(memo, typed, Volatile.Read(ref _stopEpoch), _client.AccountId, steer: false, extra, center);
        lock (_memoSends) _memoSends[local.Id] = context;
        Changed?.Invoke();
        return RunMemoSendAsync(local.Id, context, queued);
    }

    private async Task<SendOutcome> RunMemoSendAsync(string localId, MemoSendContext context, bool queued)
    {
        var staged = await StageAsync(localId, context);
        if (staged.Failure is { } reason)
        {
            RefuseMemo(localId, reason);
            return SendOutcome.Refused;
        }
        if (staged.Prompt is not { } prompt) return SendOutcome.Refused;   // Stop withdrew it while it staged
        AttachedSend? attached;
        lock (_memoAttached) _memoAttached.TryGetValue(localId, out attached);
        JsonObject? submitExtra = attached is { SubmitAttachments.Count: > 0 }
            ? new JsonObject { ["attachments"] = attached.SubmitAttachments.DeepClone() }
            : null;
        // A memo goes through the same submit loop as a typed send (runMemoSend → submit): a refusal because another
        // Hermes process holds the chat waits for it ([WIN-MEMO-OWNER-WAIT], ChatSession+OwnerWait.cs), and each
        // ending hands the memo to MemoSendFinished: refused or withdrawn, the draft chip; unconfirmed, the cache.
        // Refused after a Stop: it never went out, so it comes back as stopped (the Swift's `refuse`).
        SendOutcome Refuse(string reason)
        {
            if (Volatile.Read(ref _stopEpoch) != context.Epoch) WithdrawStoppedMemo(localId);
            else RefuseMemo(localId, reason);
            return SendOutcome.Refused;
        }
        var wait = BeginOwnerWaitRun(localId);
        var submitted = false;   // past this point a timeout or drop means "maybe delivered": never resend
        var resumed = false;
        GatewayException? firstStale = null;
        try
        {
            while (true)
            {
                var runtime = _runtimeId ?? await ResumeAsync(CancellationToken.None);
                if (Volatile.Read(ref _stopEpoch) != context.Epoch)
                {
                    EndOwnerWait(wait);
                    WithdrawStoppedMemo(localId);
                    return SendOutcome.Refused;
                }
                JsonNode res;
                try
                {
                    submitted = true;
                    try { res = await Submit(runtime, prompt, CancellationToken.None, queued, extra: submitExtra, localId: localId); }
                    catch (GatewayException e) when (e.RpcCode == 4009 && !IsChatLocked(e))
                    {
                        res = await RetryMemoBusyAsync(runtime, prompt, CancellationToken.None, queued, submitExtra, localId);
                    }
                }
                catch (GatewayException e) when (e.Code == "rpc")
                {
                    submitted = false;   // refused: nothing ran
                    var (step, why) = await OwnerRefusalAsync(wait, e, photos: attached?.Photos.Count > 0);
                    switch (step)
                    {
                        case OwnerStep.Retry:
                            resumed = false;   // the chat answered on the runtime in hand: a later reap may resume again
                            firstStale = null;
                            if (_runtimeId == null && attached != null)
                            {
                                var again = await ResumeAsync(CancellationToken.None);
                                if (await ReattachPhotosAsync(attached, again) is { } lost)
                                    return Refuse(lost);
                            }
                            continue;
                        case OwnerStep.Stopped:
                            WithdrawStoppedMemo(localId);
                            return SendOutcome.Refused;
                        case OwnerStep.Locked:
                            Refuse(why);
                            ShowChatLocked(why);   // one card: the problem card names the way on
                            return SendOutcome.Refused;
                        case OwnerStep.Unconfirmed:
                            return MarkMemoUnconfirmed(localId);
                        case OwnerStep.Refuse:
                            return Refuse(why);
                    }
                    // 4001 and 4007: a stale runtime resumes once and the memo goes once more (the same staging).
                    if (e.RpcCode is 4001 or 4007 && !resumed)
                    {
                        resumed = true;
                        firstStale = e;
                        _runtimeId = null;
                        if (attached != null)
                        {
                            var fresh = await ResumeAsync(CancellationToken.None);
                            if (await ReattachPhotosAsync(attached, fresh) is { } lost)
                                return Refuse(lost);
                        }
                        continue;
                    }
                    return Refuse(e.RpcCode is 4001 or 4007 ? (firstStale ?? e).Message : e.Message);
                }
                catch (GatewayException e) when (e.IsNotConnected && wait.Waiting)
                {
                    submitted = false;   // [WIN-SEND-NOTSENT-REFUSE] never went out: the owner wait goes on while the link is away
                    switch (await OwnerLinkAwayAsync(wait, e))
                    {
                        case OwnerStep.Retry:
                            continue;
                        case OwnerStep.Stopped:
                            WithdrawStoppedMemo(localId);
                            return SendOutcome.Refused;
                    }
                    return Refuse(e.Message);
                }
                EndOwnerWait(wait);
                lock (_lock) _t.MarkSent(localId, res.Int("user_row_id"));
                MemoSendFinished(localId, MemoSendOutcome.Acknowledged);
                Changed?.Invoke();
                return SendOutcome.Accepted;
            }
        }
        catch (GatewayException e)
        {
            EndOwnerWait(wait);
            if (submitted && MayHaveGoneOut(e)) return MarkMemoUnconfirmed(localId);   // [WIN-SEND-NOTSENT-REFUSE]
            return Refuse(e.Message);
        }
    }

    private async Task<JsonNode> RetryMemoBusyAsync(string runtime, string text, CancellationToken ct, bool queued,
        JsonObject? extra, string localId)
    {
        var until = DateTimeOffset.UtcNow.AddSeconds(6);
        while (true)
        {
            await Task.Delay(150, ct);
            try { return await Submit(runtime, text, ct, queued, extra: extra, localId: localId); }
            catch (GatewayException e) when (e.RpcCode == 4009 && DateTimeOffset.UtcNow < until) { }
        }
    }

    /// Maybe delivered (no answer in time, the link lost under it, or the gateway's queue may hold it): never resent;
    /// the recording goes to the playback cache under its gateway path (`markUnconfirmed` → memoSendFinished).
    private SendOutcome MarkMemoUnconfirmed(string localId)
    {
        MemoSendFinished(localId, MemoSendOutcome.Unconfirmed);
        lock (_lock) _t.MarkFailed(localId, UnconfirmedMark);
        NoteLostSend(localId, memo: true);   // [WIN-LOST-SEND-MARKER] as markUnconfirmed: a memo is not kept
        Changed?.Invoke();
        return SendOutcome.Unconfirmed;
    }

    /// Steps (a)–(f) and the rewrite: the bubble shows the transcript at once and keeps playing the same file. When
    /// staged photos/files accompany the memo (#521), attaches them in tray order so audio + photos submit together in
    /// one turn. Returns the prompt; or a refusal's words (nothing was submitted); or neither when Stop withdrew the send.
    private async Task<(string? Prompt, string? Failure)> StageAsync(string localId, MemoSendContext context)
    {
        var storedId = StoredId;
        context.StoredId = storedId;
        StagedMemo staged;
        try
        {
            staged = await Uploader().StageAsync(context.Memo, Profile, storedId, MemoAttachAsync, context.Staging.Token);
        }
        catch (OperationCanceledException)
        {
            if (Memo(localId) != null) WithdrawStoppedMemo(localId);
            return (null, null);
        }
        catch (Exception e) when (e is MemoSendException or GatewayException)
        {
            if (Memo(localId) == null) return (null, null);   // Stop withdrew it while it staged
            if (Volatile.Read(ref _stopEpoch) != context.Epoch) { WithdrawStoppedMemo(localId); return (null, null); }
            return (null, (e as MemoSendException)?.Reason ?? MemoUploader.Words(e, "send the voice memo"));
        }
        if (Memo(localId) == null) return (null, null);
        // Stop pressed while it staged: it never goes out; the memo comes back as the chat's draft.
        if (Volatile.Read(ref _stopEpoch) != context.Epoch) { WithdrawStoppedMemo(localId); return (null, null); }

        AttachedSend? attached = null;
        if (context.Attachments.Count > 0)
        {
            string? refusal;
            if (context.Center is { } center)
                (attached, refusal) = await AttachForSendAsync(context.Attachments, localId, context.Epoch, center, context.Staging.Token);
            else
                (attached, refusal) = await AttachStandaloneForMemoAsync(context.Attachments, localId, context.Epoch, context.Staging.Token);

            if (Memo(localId) == null)
            {
                if (attached != null) await DetachPhotosAsync(attached);
                return (null, null);
            }
            if (attached == null)
            {
                if (Volatile.Read(ref _stopEpoch) != context.Epoch || refusal == null)
                {
                    WithdrawStoppedMemo(localId);
                    return (null, null);
                }
                return (null, refusal);
            }
            lock (_memoAttached) _memoAttached[localId] = attached;
        }

        var memoPrompt = MemoText.Prompt(staged.Reference, context.Typed);
        var prompt = attached is { FileRefs.Count: > 0 }
            ? AttachmentSender.PromptText(memoPrompt, attached.FileRefs, hasImages: false)
            : memoPrompt;
        lock (_lock)
        {
            _t.Revise(localId, m =>
            {
                var nonText = m.Parts.Where(p => p is not TextPart).ToList();
                nonText.Add(new TextPart(prompt));
                return m with { Parts = nonText };
            });
            _t.EndPreparing(localId);
        }
        if (!context.Steer) _turnPrompt = prompt;
        if (staged.GatewayPath is { } gatewayPath && MemoStoresAreMine)
        {
            MemoStores!.Cache?.Alias(gatewayPath, context.Memo.Path);
            MemoStores.Shapes?.Link(context.Memo.Path, gatewayPath);
        }
        context.GatewayPath = staged.GatewayPath;
        context.Submitted = true;
        if (staged.TranscriptFailure is { } failure && MemoStoresAreMine)
            MemoSessionNotice.Post(new MemoSessionNoticeInfo(MemoSessionNoticeKind.NoTranscript, DraftScope, failure, BotName));
        Changed?.Invoke();
        return (prompt, null);
    }

    /// Attaches pre-uploaded `DraftAttachment`s when `SendMemoAsync` is called without an `AttachmentCenter`.
    private async Task<(AttachedSend? Sent, string? Refusal)> AttachStandaloneForMemoAsync(
        IReadOnlyList<DraftAttachment> attachments, string localId, int epoch, CancellationToken ct)
    {
        bool Stopped() => Volatile.Read(ref _stopEpoch) != epoch || ct.IsCancellationRequested;
        var resumed = false;
        while (true)
        {
            string rid;
            try { rid = _runtimeId ?? await ResumeAsync(ct); }
            catch (OperationCanceledException) { return (null, null); }
            catch (GatewayException e) { return (null, Stopped() ? null : e.Message); }

            var sent = new AttachedSend { ViaAuthority = AttachmentSender.IsAuthority(_client.Rpc) };
            var stale = false;
            foreach (var a in attachments)
            {
                if (Stopped()) { await DetachPhotosAsync(sent); return (null, null); }
                if (a.Kind == DraftKind.Link)
                {
                    if (a.RefText is { Length: > 0 } r) sent.FileRefs.Add(r);
                    continue;
                }
                AttachmentSender.Attached? ok;
                AttachmentSender.AttachFailure? failed;
                if (a.Kind == DraftKind.Image && sent.ViaAuthority)
                {
                    byte[]? data = null;
                    try { if (!string.IsNullOrEmpty(a.LocalFile)) data = await File.ReadAllBytesAsync(a.LocalFile, ct); }
                    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
                    if (data is not { Length: > 0 })
                        return (null, "This attachment is no longer on this PC.");
                    (ok, var mime, failed) = await AttachmentSender.AttachImageBytesAsync(_client.Rpc, rid, data, a.Name, Profile, ct);
                    if (ok != null) sent.SubmitAttachments.Add(new JsonObject { ["path"] = ok.StoredPath, ["mime"] = mime });
                }
                else
                {
                    var path = a.GatewayPath ?? a.LocalFile;
                    if (string.IsNullOrEmpty(path))
                    {
                        await DetachPhotosAsync(sent);
                        return (null, $"“{a.Name}” wasn’t uploaded yet.");
                    }
                    if (a.Kind == DraftKind.Image)
                        (ok, failed) = await AttachmentSender.AttachImageAsync(_client.Rpc, rid, path, a.Name, Profile, ct);
                    else
                        (ok, failed) = await AttachmentSender.AttachFileAsync(_client.Rpc, rid, path, a.Name, Profile, ct);
                }

                if (ok != null)
                {
                    if (a.Kind == DraftKind.Image)
                    {
                        sent.Photos.Add((a.Id, ok.StoredPath));
                        sent.StoredPaths[a.Id] = ok.StoredPath;
                        SetUploadedPath(localId, a.Id, ok.StoredPath);
                    }
                    else
                    {
                        if (ok.RefText != null) sent.FileRefs.Add(ok.RefText);
                        sent.StoredPaths[a.Id] = (ok.RefText != null ? AttachmentSender.RefPath(ok.RefText) : null) ?? ok.StoredPath;
                    }
                    continue;
                }
                if (failed!.Stale && !resumed) { stale = true; break; }
                await DetachPhotosAsync(sent);
                return (null, Stopped() ? null : failed.Reason);
            }
            if (stale)
            {
                resumed = true;
                _runtimeId = null;
                continue;
            }
            if (Stopped()) { await DetachPhotosAsync(sent); return (null, null); }
            return (sent, null);
        }
    }

    /// (c) `file.attach {session_id, profile, name, path}`; a stale runtime id (4001) resumes once and attaches again
    /// with the same uploaded path (no second upload).
    public async Task<JsonNode?> MemoAttachAsync(JsonObject parameters, CancellationToken ct)
    {
        if (_runtimeId == null) await ResumeAsync(ct);
        var resumed = false;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var rid = _runtimeId ?? throw new MemoSendException("Couldn’t reach this chat.");
            var p = new JsonObject { ["session_id"] = rid };
            foreach (var (key, value) in parameters) p[key] = value?.DeepClone();
            try { return await _client.Rpc.RequestAsync("file.attach", p, TimeSpan.FromSeconds(30), ct); }
            catch (GatewayException e) when (e.RpcCode == 4001 && !resumed)
            {
                resumed = true;
                _runtimeId = null;
                await ResumeAsync(ct);
            }
        }
    }

    // MARK: Steer (a memo into the running reply)

    /// A memo sent now can go into the running reply: a reply runs, no Stop unwinds, the gateway can redirect, the words
    /// beside it aren't a slash command, and the running turn isn't a memo of its own still staging (nothing to steer).
    public bool MemoSteers(string typed, bool redirectUnsupported)
    {
        ChatMessage? anchor;
        lock (_lock) anchor = _t.Messages.LastOrDefault(m => m.Role == Role.User && m.IsPending);
        var ownStaging = anchor != null && Memo(anchor.Id) is { Submitted: false, Steer: false };
        return CanSteerNow && !ownStaging && !redirectUnsupported && !SteerRule.IsSlashCommand(typed.Trim());
    }

    /// The memo's bubble shows at once under the running reply (playing the local file); returns its local id.
    public string BeginMemoSteer(MemoFile memo, string typed)
    {
        var localId = BeginSteer(MemoText.Optimistic(memo.Path, typed));
        lock (_memoSends) _memoSends[localId] = new MemoSendContext(memo, typed, Volatile.Read(ref _stopEpoch), _client.AccountId, steer: true);
        return localId;
    }

    /// Stages a steered memo. `Prompt`: what the steer carries. `Withdrawn`: Stop handed it back as the draft meanwhile.
    /// Neither: staging failed, and the memo joins the queue (its staging, if any, stays kept for the drain).
    public async Task<(string? Prompt, bool Withdrawn)> StageMemoSteerAsync(string localId)
    {
        if (Memo(localId) is not { } context) return (null, true);
        var (prompt, failure) = await StageAsync(localId, context);
        if (prompt != null) return (prompt, false);
        return (null, failure == null);
    }

    /// The steer was taken: the recording moves to the playback cache under its gateway path.
    public void MemoSteerTaken(string localId) => MemoSendFinished(localId, MemoSendOutcome.Acknowledged);

    /// The steer went nowhere: its bubble goes (the queue card holds the memo now); nothing goes back to the drafts.
    public void MemoSteerNotTaken(string localId)
    {
        lock (_memoSends) _memoSends.Remove(localId);
        lock (_lock) _t.SteerFailed(localId);
        Changed?.Invoke();
    }

    // MARK: Endings

    /// A refusal: the bubble goes, the memo is the chat's draft chip again, the typed words go back to the field, and
    /// the "Couldn’t Send" card says why.
    private void RefuseMemo(string localId, string reason)
    {
        var typed = MemoSendFinished(localId, MemoSendOutcome.Refused) ?? "";
        lock (_lock) _t.Withdraw(localId);
        SetSendFailure(reason);   // the one card (ChatSession.SendFailure), the latest refusal wins
        Changed?.Invoke();
        MemoDraftReturned?.Invoke(typed, reason.Length == 0 ? NotSentWords : reason);
    }

    /// A memo send overtaken by Stop before it went out: its bubble goes, the memo is the draft chip again.
    private void WithdrawStoppedMemo(string localId)
    {
        var context = Memo(localId);
        // Once only: Stop's hook and the cancelled staging both check `Memo(localId) != null` and then withdraw, and the
        // cancellation can run its continuation on another thread between them. Whoever takes the send's context hands
        // the memo back; the other does nothing (else a second ("", "Stopped before sending") reached the field).
        if (MemoSendFinished(localId, MemoSendOutcome.Withdrawn) is not { } typed) return;
        lock (_lock)
        {
            if (context?.Steer == true) _t.SteerFailed(localId);   // the running reply runs on
            else _t.Withdraw(localId);
        }
        Changed?.Invoke();
        MemoDraftReturned?.Invoke(typed, StoppedBeforeSending);
    }

    /// The hook at the top of Stop: memos still staging stop at once (their staging is cancelled: nothing more is
    /// uploaded, attached or transcribed) and come back as this chat's draft, their bubble gone. When the running turn
    /// was such a memo's own, it never reached the gateway: the turn settles here with no interrupt and no Stopped marker,
    /// and `true` tells Stop it is done.
    public bool MemoStopWhileStaging()
    {
        List<KeyValuePair<string, MemoSendContext>> staging;
        lock (_memoSends) staging = [.. _memoSends.Where(p => !p.Value.Submitted).OrderBy(p => p.Key, StringComparer.Ordinal)];
        if (staging.Count == 0) return false;
        string? anchor;
        lock (_lock) anchor = _t.Messages.LastOrDefault(m => m.Role == Role.User)?.Id;
        var ownTurn = anchor != null && staging.Any(p => p.Key == anchor && !p.Value.Steer);
        Interlocked.Increment(ref _stopEpoch);
        foreach (var (localId, context) in staging)
        {
            context.Staging.Cancel();
            if (context.Attachments.Count > 0)
                context.Center?.InterruptWaits(context.Attachments.Select(a => a.Id));
            WithdrawStoppedMemo(localId);
        }
        if (!ownTurn) return false;
        Stopped?.Invoke();   // the queue parks, as after any Stop
        return true;
    }

    /// Called by each ending: nil for a text send. For a memo it returns the typed words and puts the memo where it
    /// belongs: the playback cache under its gateway path (accepted, or unconfirmed: never resent), or back in the
    /// composer as this chat's draft chip (refused, withdrawn). With another account signed in meanwhile, nothing is
    /// written into its stores: the recording is deleted.
    public string? MemoSendFinished(string localId, MemoSendOutcome outcome)
    {
        MemoSendContext? context;
        AttachedSend? attached;
        lock (_memoSends)
        {
            if (!_memoSends.Remove(localId, out context)) return null;
        }
        lock (_memoAttached) _memoAttached.Remove(localId, out attached);
        lock (_inFlightAttachments) _inFlightAttachments.Remove(localId);
        lock (_lock) _t.EndPreparing(localId);

        if (context.Attachments.Count > 0)
        {
            if (outcome is MemoSendOutcome.Acknowledged or MemoSendOutcome.Unconfirmed)
            {
                if (attached != null && context.Center is { } center)
                {
                    FinishAttachmentSend(attached, context.Attachments, localId, center);
                }
                else if (attached != null)
                {
                    lock (_lock)
                        _t.Revise(localId, m => m with
                        {
                            Parts = [.. m.Parts.Select(p => p is AttachmentPart { Attachment.Source: AttachmentSource.Local l } ap
                                && attached.StoredPaths.TryGetValue(l.DraftId, out var stored)
                                ? new AttachmentPart(ap.Attachment with { Source = new AttachmentSource.Gateway(stored), UploadedPath = null }) : p)],
                        });
                }
            }
            else
            {
                if (attached != null) _ = DetachPhotosAsync(attached);
                if (context.Center is { } center)
                {
                    var ids = context.Attachments.Select(a => a.Id).ToList();
                    var current = context.Attachments.Select(a => center.Item(a.Id) ?? a).ToList();
                    center.SendEnded(ids);
                    center.ReturnToDraft(DraftScope, Profile, context.Typed, current, setTextIfEmpty: true);
                }
            }
        }

        var stores = MemoStores;
        if (stores == null || stores.AccountId != context.AccountId)
        {
            stores?.Paths.Remove(context.Memo.Path);
            return context.Typed;
        }
        switch (outcome)
        {
            case MemoSendOutcome.Acknowledged or MemoSendOutcome.Unconfirmed:
                if (outcome == MemoSendOutcome.Acknowledged && MemoGateway != null)
                    Uploader().ForgetStage(context.Memo.Path, context.StoredId);
                if (context.GatewayPath is { } gatewayPath) stores.Cache?.Adopt(context.Memo.Path, gatewayPath);
                break;
            default:
                SetMemoDraft(context.Memo);
                break;
        }
        return context.Typed;
    }

    /// Remove on a queued memo: the memo returns as the draft chip (its words go back to the field as for text).
    public void MemoQueueItemRemoved(MemoFile memo) => SetMemoDraft(memo);

    /// Delete on a queued memo: nothing comes back; the recording leaves this PC.
    public void MemoQueueItemDiscarded(MemoFile memo) => MemoStores?.Paths.Remove(memo.Path);

    /// A chat that keeps no queue beyond its screen is left with memos still queued behind a reply: each comes back as
    /// this chat's draft (oldest first, with the words typed beside it), and the chat says so when it opens next.
    public void MemoQueueLeaving(IReadOnlyList<MemoDraft> memos)
    {
        if (memos.Count == 0) return;
        if (!MemoStoresAreMine || MemoStores!.Drafts is not { } drafts)
        {
            foreach (var draft in memos) MemoStores?.Paths.Remove(draft.Memo.Path);
            return;
        }
        drafts.Restore(memos, DraftScope);
        MemoSessionNotice.Post(new MemoSessionNoticeInfo(MemoSessionNoticeKind.SavedAsDraft, DraftScope, Bot: BotName));
    }
}
