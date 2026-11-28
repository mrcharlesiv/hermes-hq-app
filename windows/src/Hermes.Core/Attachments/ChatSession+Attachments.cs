using System.Text.Json.Nodes;
using Hermes.Core.Attachments;
using Hermes.Core.Model;
using Hermes.Core.Net;

namespace Hermes.Core.Chat;

/// Sending photos and files from the live chat (HermesKit/Chat/LiveChatSession+Attachments.swift; spec 1x-attachments
/// §6.4, §6.5, §7.8): the optimistic bubble's attachments, then await uploads → attach in tray order → prompt.submit →
/// re-attach photos after a stale-runtime submit → detach on a withdrawn send; after the ack the media store is seeded
/// and the bubble switches to the gateway copies; a refusal or Stop hands the draft back. The pipeline belongs to the
/// chat's session, never to its screen: leaving the chat doesn't cancel it.
public sealed partial class ChatSession
{
    private int _stopEpoch;
    private readonly Dictionary<string, List<string>> _inFlightAttachments = [];
    private AttachmentCenter? _sendingCenter;

    public HermesClient Client => _client;

    /// The layout cache key for this chat: "<account id>|<profile>|<stored session id or pending scope>".
    public string LayoutScope => AttachmentCenter.Scope(_client.AccountId, Profile,
        StoredId.Length > 0 ? StoredId : (PendingScope ?? ""));

    /// The drafts store's key for this chat: a newly started listed chat keeps its deterministic `PendingScope`
    /// (`"new"` or `"new|<cleanFolder>"`) while empty and idle, so switching bots before sending preserves its unsent
    /// draft across ephemeral session id changes (HermesKit/Chat/LiveChatSession.swift, #613 / 363ae6c33).
    public string DraftScope
    {
        get
        {
            if (StartsNew && ListsWhenStarted && !string.IsNullOrEmpty(PendingScope) && !HasQueuedMessages)
            {
                lock (_lock)
                {
                    if (_t.Messages.Count == 0 && !_t.Busy)
                        return AttachmentCenter.Scope(_client.AccountId, Profile, PendingScope);
                }
            }
            return LayoutScope;
        }
    }

    /// Migrates any draft from `draftScopeBefore` to the current `DraftScope` when the scope changes (363ae6c33).
    private void MigrateDraftScope(string draftScopeBefore, AttachmentCenter? center = null)
    {
        var draftScopeAfter = DraftScope;
        if (draftScopeBefore == draftScopeAfter) return;
        (center ?? _sendingCenter ?? AttachmentCenter.Existing(_client.AccountId))
            ?.MoveDraft(draftScopeBefore, draftScopeAfter);
    }

    /// The session id a relative media path is read against (spec §8.2).
    public string MediaSessionId => StoredId;

    /// A send didn't go out (refused, or stopped before prompt.submit): its words and attachments are back in the draft.
    /// The text is the refusal's reason, or null for Stop.
    public event Action<string?>? SendReturned;

    private void StopAttachmentSends()
    {
        Interlocked.Increment(ref _stopEpoch);
        List<string> ids;
        lock (_inFlightAttachments) ids = [.. _inFlightAttachments.Values.SelectMany(x => x)];
        if (ids.Count > 0) _sendingCenter?.InterruptWaits(ids);
    }

    private sealed class AttachedSend
    {
        public List<(string Id, string Path)> Photos = [];
        public List<string> FileRefs = [];
        public List<string> ReleasedFolders = [];
        public Dictionary<string, string> StoredPaths = [];
        public JsonArray SubmitAttachments = [];
        public bool ViaAuthority;
    }

    private static MessageAttachment LocalAttachment(DraftAttachment a) => new(
        a.Kind switch { DraftKind.Image => AttachmentKind.Image, DraftKind.Link => AttachmentKind.Link, _ => AttachmentKind.File },
        new AttachmentSource.Local(a.Id, a.LocalFile), a.Name, a.PixelWidth, a.PixelHeight, a.ByteSize > 0 ? a.ByteSize : null,
        a.Kind == DraftKind.Image ? a.GatewayPath : null);

    /// Sends `text` with `attachments` (tray order), taken from `center`'s draft for this chat.
    public async Task SendAsync(string text, IReadOnlyList<DraftAttachment> attachments, AttachmentCenter center,
        CancellationToken ct = default)
    {
        _sendingCenter = center;
        if (attachments.Count == 0) { await SendAsync(text, ct); return; }
        // §6.2, §6.3: a fresh send answers the card about the last one, with attachments as without (`send`'s
        // `sendFailure = nil`), and the chat's problem card ([WIN-COMPOSER-CARD-IDS] `sessionProblem = nil`).
        SendFailure = null;
        ClearProblemForSend();
        var epoch = Volatile.Read(ref _stopEpoch);
        var ids = attachments.Select(a => a.Id).ToList();
        var draftScopeBefore = DraftScope;
        ChatMessage local;
        lock (_lock)
        {
            _turnGeneration++;
            local = _t.AddLocalUser(AttachmentSender.BubbleText(text, attachments),
                [.. attachments.OrderBy(a => a.Kind == DraftKind.Image ? 0 : 1).Select(a => (ChatPart)new AttachmentPart(LocalAttachment(a)))]);
            _t.BeginPreparing(local.Id);   // [WIN-PROBLEM-CARD-REST] `turn.preparingSendId = localId`
            _stopPending = false;
        }
        MigrateDraftScope(draftScopeBefore, center);
        StopTerminalReached();
        TurnInterrupted = false;
        Changed?.Invoke();
        lock (_inFlightAttachments) _inFlightAttachments[local.Id] = ids;
        try
        {
            var (sent, refusal) = await AttachForSendAsync(attachments, local.Id, epoch, center, ct);
            if (sent == null)
            {
                Withdraw(local.Id, center, text, attachments, refusal);
                return;
            }
            var prompt = AttachmentSender.PromptText(text, sent.FileRefs, attachments.Any(a => a.Kind == DraftKind.Image));
            lock (_lock) _t.EndPreparing(local.Id);   // [WIN-PROBLEM-CARD-REST] `endPreparing(localId)`: prompt.submit goes
            var submitted = false;
            // [WIN-OWNER-WAIT] The attachment loop's owner wait (the Mac's one submit loop has it for both).
            var wait = BeginOwnerWaitRun(local.Id);
            try
            {
                var runtime = _runtimeId ?? await ResumeAsync(ct);
                var resumed = false;
                JsonNode res;
                while (true)
                {
                    try
                    {
                        submitted = true;
                        res = await SubmitWithAsync(runtime, prompt, sent, local.Id, ct);
                        break;
                    }
                    catch (GatewayException e) when (e.Code == "rpc")
                    {
                        submitted = false;
                        var (step, why) = await OwnerRefusalAsync(wait, e, photos: sent.Photos.Count > 0);
                        switch (step)
                        {
                            case OwnerStep.Retry:
                                resumed = false;
                                if (_runtimeId == null)
                                {
                                    // Reaped while it waited: resume and attach the photos to the new runtime (A5).
                                    var again = await ResumeAsync(ct);
                                    if (await ReattachPhotosAsync(sent, again) is { } lost)
                                    {
                                        Withdraw(local.Id, center, text, attachments, lost);
                                        return;
                                    }
                                }
                                runtime = _runtimeId ?? await ResumeAsync(ct);
                                continue;
                            case OwnerStep.Stopped:
                                await DetachPhotosAsync(sent);
                                Withdraw(local.Id, center, text, attachments, null);
                                return;
                            case OwnerStep.Locked:
                                await DetachPhotosAsync(sent);
                                Withdraw(local.Id, center, text, attachments, why);
                                ShowChatLocked(why);
                                return;
                            case OwnerStep.Unconfirmed:
                                // The gateway's queue may hold it: the attaches were done, never resent (§2.5).
                                FinishAttachmentSend(sent, attachments, local.Id, center);
                                lock (_lock) _t.MarkFailed(local.Id, UnconfirmedMark);
                                Changed?.Invoke();
                                return;
                            case OwnerStep.Refuse:
                                await DetachPhotosAsync(sent);
                                Withdraw(local.Id, center, text, attachments, why);
                                return;
                        }
                        if (e.RpcCode is not (4001 or 4007) || resumed) throw;
                        // A5: resume once, the photos again on the new runtime, submit once more.
                        resumed = true;
                        _runtimeId = null;
                        var fresh = await ResumeAsync(ct);
                        if (await ReattachPhotosAsync(sent, fresh) is { } why2)
                        {
                            Withdraw(local.Id, center, text, attachments, why2);
                            return;
                        }
                        runtime = fresh;
                    }
                }
                EndOwnerWait(wait);
                lock (_lock) _t.MarkSent(local.Id, res.Int("user_row_id"));
                Changed?.Invoke();
                FinishAttachmentSend(sent, attachments, local.Id, center);
            }
            catch (GatewayException e)
            {
                EndOwnerWait(wait);
                center.SendEnded(ids);
                if (submitted && e.Code is "timeout" or "offline")
                {
                    // Maybe delivered: never resend, never hand back (spec 04 §2.5).
                    lock (_lock) _t.MarkFailed(local.Id, "Delivery unconfirmed");
                    Changed?.Invoke();
                }
                else
                {
                    await DetachPhotosAsync(sent);
                    Withdraw(local.Id, center, text, attachments, e.Message);
                }
            }
        }
        finally
        {
            lock (_lock) _t.EndPreparing(local.Id);
            lock (_inFlightAttachments) _inFlightAttachments.Remove(local.Id);
        }
    }

    /// Refused or stopped: the bubble goes, and the words and attachments go back to the draft in front of whatever it
    /// holds now (spec §6.4 step 8). A refusal is said once, in the "Couldn’t Send" card at the composer, never as an
    /// error line in the transcript as well (93f984bb1 LiveChatSession `refuseSend`: `sendFailure = SendFailure.make(reason:)`,
    /// §6.3 "one failure, one place"); a Stop (null reason) is `withdrawStoppedSend`: no card.
    private void Withdraw(string localId, AttachmentCenter center, string text, IReadOnlyList<DraftAttachment> attachments, string? reason)
    {
        lock (_lock) _t.Withdraw(localId);
        if (reason != null) SetSendFailure(reason);
        var current = attachments.Select(a => center.Item(a.Id) ?? a).ToList();
        center.SendEnded(attachments.Select(a => a.Id));
        center.ReturnToDraft(DraftScope, Profile, text, current, setTextIfEmpty: true);
        Changed?.Invoke();
        SendReturned?.Invoke(reason);
    }

    /// Waits for every upload (a failed retryable one is retried once), then attaches in tray order: photos
    /// image.attach (or image.attach_bytes on a session authority), files file.attach, links ride as their @url: line.
    /// A stale runtime resumes once and restarts the attaches; any other failure detaches the photos already attached
    /// and refuses. Stop → detach → stopped (a null reason).
    private async Task<(AttachedSend? Sent, string? Refusal)> AttachForSendAsync(IReadOnlyList<DraftAttachment> attachments,
        string localId, int epoch, AttachmentCenter center, CancellationToken ct)
    {
        var ids = attachments.Select(a => a.Id).ToList();
        bool Stopped() => Volatile.Read(ref _stopEpoch) != epoch;
        var staged = new Dictionary<string, StagedFile>();
        foreach (var a in attachments)
        {
            StagedFile file;
            try { file = await center.AwaitUploadedAsync(a.Id, retryFailed: true); }
            catch (AttachmentUploadException e)
            {
                center.SendEnded(ids);
                return (null, Stopped() ? null : e.Reason);
            }
            if (Stopped()) { center.SendEnded(ids); return (null, null); }
            staged[a.Id] = file;
            if (a.Kind == DraftKind.Image) SetUploadedPath(localId, a.Id, file.Path);
        }
        var resumed = false;
        while (true)
        {
            string rid;
            try { rid = _runtimeId ?? await ResumeAsync(ct); }
            catch (GatewayException e)
            {
                center.SendEnded(ids);
                return (null, Stopped() ? null : e.Message);
            }
            var sent = new AttachedSend { ViaAuthority = AttachmentSender.IsAuthority(_client.Rpc) };
            var stale = false;
            foreach (var a in attachments)
            {
                if (Stopped()) { await DetachPhotosAsync(sent); center.SendEnded(ids); return (null, null); }
                if (!staged.TryGetValue(a.Id, out var file)) continue;
                if (a.Kind == DraftKind.Link)
                {
                    if (a.RefText is { } r) sent.FileRefs.Add(r);
                    continue;
                }
                AttachmentSender.Attached? ok;
                AttachmentSender.AttachFailure? failed;
                if (a.Kind == DraftKind.Image && sent.ViaAuthority)
                {
                    byte[]? data = null;
                    try { data = await File.ReadAllBytesAsync((center.Item(a.Id) ?? a).LocalFile, ct); }
                    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
                    if (data is not { Length: > 0 })
                    {
                        center.SendEnded(ids);
                        return (null, "This attachment is no longer on this PC.");
                    }
                    (ok, var mime, failed) = await AttachmentSender.AttachImageBytesAsync(_client.Rpc, rid, data, a.Name, Profile, ct);
                    if (ok != null) sent.SubmitAttachments.Add(new JsonObject { ["path"] = ok.StoredPath, ["mime"] = mime });
                }
                else if (a.Kind == DraftKind.Image)
                    (ok, failed) = await AttachmentSender.AttachImageAsync(_client.Rpc, rid, file.Path, a.Name, Profile, ct);
                else
                    (ok, failed) = await AttachmentSender.AttachFileAsync(_client.Rpc, rid, file.Path, a.Name, Profile, ct);

                if (ok != null)
                {
                    if (a.Kind == DraftKind.Image)
                    {
                        // The path Hermes keeps: the stored @image: row, image.detach and the media store all use it.
                        sent.Photos.Add((a.Id, ok.StoredPath));
                        sent.StoredPaths[a.Id] = ok.StoredPath;
                        if (ok.StoredPath != file.Path) SetUploadedPath(localId, a.Id, ok.StoredPath);
                    }
                    else
                    {
                        if (ok.RefText != null) sent.FileRefs.Add(ok.RefText);
                        sent.StoredPaths[a.Id] = (ok.RefText != null ? AttachmentSender.RefPath(ok.RefText) : null) ?? ok.StoredPath;
                        if (AttachmentStager.StagedCopyReleased(ok.Uploaded, ok.StoredPath, file.Folder)) sent.ReleasedFolders.Add(file.Folder);
                    }
                    continue;
                }
                if (failed!.Stale && !resumed) { stale = true; break; }
                await DetachPhotosAsync(sent);
                center.SendEnded(ids);
                return (null, Stopped() ? null : failed.Reason);
            }
            if (stale)
            {
                // The runtime went away under the attaches: resume once and start again from the first (spec §6.4 step 5).
                resumed = true;
                _runtimeId = null;
                continue;
            }
            if (Stopped()) { await DetachPhotosAsync(sent); center.SendEnded(ids); return (null, null); }
            return (sent, null);
        }
    }

    /// [authority] The send's own `submission_id` ("hq-" + its bubble's id), the same through every retry, as the typed
    /// send's (LiveChatSession.swift send: one submit for both); RpcConnection strips it on the plain sidecar.
    private Task<JsonNode> SubmitOnceAsync(string runtime, string text, AttachedSend sent, string localId, CancellationToken ct)
    {
        var p = new JsonObject { ["session_id"] = runtime, ["text"] = text, ["profile"] = Profile,
            ["submission_id"] = AuthorityWire.SubmissionId(localId) };
        if (sent.SubmitAttachments.Count > 0) p["attachments"] = sent.SubmitAttachments.DeepClone();
        return _client.Rpc.RequestAsync("prompt.submit", p, TimeSpan.FromSeconds(1800), ct);
    }

    /// prompt.submit; 4009 (busy) retries every 150 ms for up to 6 s, as M1's.
    private async Task<JsonNode> SubmitWithAsync(string runtime, string text, AttachedSend sent, string localId, CancellationToken ct)
    {
        var until = DateTimeOffset.UtcNow.AddSeconds(6);
        while (true)
        {
            try { return await SubmitOnceAsync(runtime, text, sent, localId, ct); }
            catch (GatewayException e) when (e.RpcCode == 4009 && DateTimeOffset.UtcNow < until) { await Task.Delay(150, ct); }
        }
    }

    /// After a 4001/4007 on prompt.submit and its resume: the photos again, on the new runtime (A5). Files' refs stay
    /// valid. Returns a refusal reason, or null when all attached.
    private async Task<string?> ReattachPhotosAsync(AttachedSend sent, string runtime)
    {
        if (sent.ViaAuthority) return null; // the photos ride on the submit itself
        var attached = new List<(string Id, string Path)>();
        foreach (var photo in sent.Photos)
        {
            var (ok, failed) = await AttachmentSender.AttachImageAsync(_client.Rpc, runtime, photo.Path,
                MediaKinds.NameOfPath(photo.Path, image: true), Profile);
            if (ok != null)
            {
                attached.Add((photo.Id, ok.StoredPath));
                sent.StoredPaths[photo.Id] = ok.StoredPath;
                continue;
            }
            sent.Photos = attached;
            await DetachPhotosAsync(sent);
            return failed!.Reason;
        }
        sent.Photos = attached;
        return null;
    }

    /// image.detach for each photo attached in a send that won't be submitted (A6), errors ignored.
    private async Task DetachPhotosAsync(AttachedSend sent)
    {
        if (sent.Photos.Count == 0 || sent.ViaAuthority || _runtimeId is not { } rid) return;
        foreach (var photo in sent.Photos) await AttachmentSender.DetachImageAsync(_client.Rpc, rid, photo.Path, Profile);
    }

    private void SetUploadedPath(string localId, string draftId, string path)
    {
        lock (_lock)
            _t.Revise(localId, m => m with
            {
                Parts = [.. m.Parts.Select(p => p is AttachmentPart { Attachment.Source: AttachmentSource.Local l } ap && l.DraftId == draftId
                    ? new AttachmentPart(ap.Attachment with { UploadedPath = path }) : p)],
            });
    }

    /// Step 7: seeds the media store with your photos and files under their gateway paths (so the stored row shows the
    /// same pictures with no download), switches the bubble to them, lets this PC's copies go, and deletes the staging
    /// folders of files the gateway copied out.
    private void FinishAttachmentSend(AttachedSend sent, IReadOnlyList<DraftAttachment> attachments, string localId, AttachmentCenter center)
    {
        foreach (var a in attachments)
        {
            if (!sent.StoredPaths.TryGetValue(a.Id, out var path) || a.Kind == DraftKind.Link) continue;
            var item = center.Item(a.Id) ?? a;
            if (File.Exists(item.LocalFile)) center.Media.Seed(Profile, path, item.LocalFile, a.Name, a.Kind == DraftKind.Image);
        }
        lock (_lock)
            _t.Revise(localId, m => m with
            {
                Parts = [.. m.Parts.Select(p => p is AttachmentPart { Attachment.Source: AttachmentSource.Local l } ap
                    && sent.StoredPaths.TryGetValue(l.DraftId, out var stored)
                    ? new AttachmentPart(ap.Attachment with { Source = new AttachmentSource.Gateway(stored), UploadedPath = null }) : p)],
            });
        Changed?.Invoke();
        var ids = attachments.Select(a => a.Id).ToList();
        center.SendEnded(ids);
        center.Release(ids);
        foreach (var folder in sent.ReleasedFolders) _ = center.Stager.ReleaseAsync(folder, Profile);
    }
}
