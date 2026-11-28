using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Rpc;

namespace Hermes.Core.Attachments;

/// What a pick hands over: a file on this PC and how it came (AttachmentImporter.Source).
public sealed record PickedItem(string Path, string Name, PickSource Source);

public enum PickSource
{
    /// From the Photos picker (pictures and videos): a picture goes through the normaliser, a video is a file.
    Photo,
    /// From Files, drag and drop or a pasted file: a picture the normaliser can read goes the photo way, the rest is a file.
    File,
    /// A camera capture: normalised, named camera.jpg.
    Camera,
    /// A pasted image: normalised, named clipboard.jpg / clipboard.png.
    Clipboard,
}

/// A prepared photo (PhotoNormalizer.Output): at most 3072 px on the long side, orientation applied, no metadata, JPEG
/// 0.85 (PNG with real transparency; an animated GIF passes through).
public sealed record NormalizedPhoto(string Path, string Name, long ByteSize, int? PixelWidth, int? PixelHeight);

/// The app's photo normaliser (Windows.Graphics.Imaging). Throws when it can't read the picture.
public interface IPhotoNormalizer
{
    Task<NormalizedPhoto> NormalizeAsync(string source, string stem, string folder, CancellationToken ct);
}

/// One signed-in account's photos and files (HermesKit/Attachments/AttachmentCenter.swift; spec 1x-attachments §6):
/// every chat's draft (text and tray), each attachment's state from pick to send, the upload queue (one at a time,
/// oldest first, eager; spec §6.3), and the hand-over to a send (AwaitUploadedAsync) and back (ReturnToDraft). Its files
/// live under `root`: staging/<id>/<name> (this PC's copies), uploads/ (multipart bodies), media/ (the media store),
/// drafts.json. Thread-safe; events fire on a background thread.
public sealed class AttachmentCenter : IDisposable
{
    /// Per message (Hermes expands at most 16 @-references).
    public const int MaxPerMessage = 16;
    /// Per pick (the first Files picks).
    public const int MaxPerPick = 8;

    private static readonly Dictionary<string, AttachmentCenter> Centers = [];

    /// The center for `client`'s account, made on first use (a new client for the same account replaces the old one's).
    public static AttachmentCenter For(HermesClient client, string accountsRoot)
    {
        lock (Centers)
        {
            if (Centers.TryGetValue(client.AccountId, out var known) && ReferenceEquals(known.Client, client)) return known;
            known?.Dispose();
            var made = new AttachmentCenter(client, Path.Combine(accountsRoot, AccountKey(client.AccountId)));
            Centers[client.AccountId] = made;
            return made;
        }
    }

    public static AttachmentCenter? Existing(string accountId)
    {
        lock (Centers) return Centers.GetValueOrDefault(accountId);
    }

    internal static void RegisterForTests(AttachmentCenter center)
    {
        lock (Centers) Centers[center.Client.AccountId] = center;
    }

    internal static void UnregisterForTests(string accountId, AttachmentCenter? expected = null)
    {
        lock (Centers)
        {
            if (expected is null || (Centers.TryGetValue(accountId, out var current) && ReferenceEquals(current, expected)))
                Centers.Remove(accountId);
        }
    }

    /// Sign-out (spec §6.6): uploads stop; the account's copies, drafts and media cache go.
    public static void SignedOut(string accountId)
    {
        AttachmentCenter? center;
        lock (Centers) { Centers.Remove(accountId, out center); }
        if (center == null) return;
        center.Dispose();
        center.Media.Purge();
        try { Directory.Delete(center._root, recursive: true); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    /// A short stable folder name for an account id (never the id itself: it holds the gateway's address).
    public static string AccountKey(string id) => Convert.ToHexString(
        System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(id)))[..24].ToLowerInvariant();

    public static IPhotoNormalizer? Normalizer { get; set; }

    private readonly string _root;
    private readonly object _gate = new();
    private readonly Dictionary<string, DraftAttachment> _items = [];
    private readonly Dictionary<string, string> _profiles = [];
    private readonly Dictionary<string, Draft> _drafts = [];
    private readonly List<string> _queue = [];
    private readonly Dictionary<string, List<TaskCompletionSource>> _waiters = [];
    private readonly Dictionary<string, CancellationTokenSource> _preparations = [];
    private readonly HashSet<string> _autoRetried = [], _sendRetried = [], _stopRequested = [];
    private (string Id, CancellationTokenSource Cancel)? _current;
    private bool _connectionReady, _socketReady, _shutDown;
    private int _waitingTries;
    private CancellationTokenSource? _waitingRetry;
    /// The waits before each retry while the socket stays ready (tests shorten it).
    public TimeSpan[] WaitingBackoff { get; set; } = [TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(10), TimeSpan.FromSeconds(30)];
    public TimeSpan AutoRetryDelay { get; set; } = TimeSpan.FromSeconds(2);

    private sealed class Draft
    {
        public string Text = "";
        public List<string> Ids = [];
        public string Profile = "";
        public double UpdatedAt;
    }

    public HermesClient Client { get; }
    public AttachmentStager Stager { get; }
    public MediaStore Media { get; }
    public string StagingRoot => Path.Combine(_root, "staging");

    /// An attachment's state changed (its id).
    public event Action<string>? ItemChanged;
    /// A chat's draft changed outside typing (its scope): attachments added, removed or returned, a send took it.
    public event Action<string>? DraftChanged;

    public AttachmentCenter(HermesClient client, string root)
    {
        Client = client;
        _root = root;
        Stager = new AttachmentStager(client.Session, Path.Combine(root, "uploads"));
        Media = new MediaStore(client.Session, Path.Combine(root, "media"));
        Load();
        _socketReady = _connectionReady = client.Rpc.State == ConnectionState.Open;
        client.Rpc.StateChanged += OnConnection;
        Pump();
        _ = Task.Run(async () => { await Task.Delay(3000); Sweep(); });
    }

    private void OnConnection(ConnectionState state)
    {
        var ready = state == ConnectionState.Open;
        bool pump;
        lock (_gate)
        {
            _socketReady = ready;
            pump = ready && !_connectionReady;
            _connectionReady = ready;
            if (pump) { _waitingRetry?.Cancel(); _waitingTries = 0; }
        }
        if (pump) Pump();
    }

    // ------------------------------------------------------------------ drafts

    /// The chat's draft key: "<account id>|<profile>|<stored session id>".
    public static string Scope(string accountId, string profile, string storedId) => $"{accountId}|{profile}|{storedId}";

    public (string Text, IReadOnlyList<DraftAttachment> Attachments) GetDraft(string scope)
    {
        lock (_gate)
            return _drafts.TryGetValue(scope, out var d) ? (d.Text, d.Ids.Where(_items.ContainsKey).Select(i => _items[i]).ToList()) : ("", []);
    }

    public DraftAttachment? Item(string id) { lock (_gate) return _items.GetValueOrDefault(id); }

    public int Count(string scope) { lock (_gate) return _drafts.TryGetValue(scope, out var d) ? d.Ids.Count : 0; }

    /// Typed text (the composer saves it as it changes).
    public void SetText(string scope, string profile, string text)
    {
        lock (_gate)
        {
            var d = DraftFor(scope);
            if (d.Text == text) return;
            d.Text = text;
            d.Profile = profile;
            d.UpdatedAt = Now();
        }
        Save();
    }

    private Draft DraftFor(string scope)
    {
        if (!_drafts.TryGetValue(scope, out var d)) _drafts[scope] = d = new Draft();
        return d;
    }

    private static double Now() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;

    /// Adds an attachment to the end of the tray (a link, or an already prepared item).
    public void Add(DraftAttachment a, string scope, string profile)
    {
        lock (_gate)
        {
            var d = DraftFor(scope);
            d.Ids.Add(a.Id);
            d.Profile = profile;
            d.UpdatedAt = Now();
            _items[a.Id] = a;
            _profiles[a.Id] = profile;
            if (a.Upload is UploadState.Waiting && !a.DefersUpload) _queue.Add(a.Id);
        }
        DraftChanged?.Invoke(scope);
        ItemChanged?.Invoke(a.Id);
        Save();
        Pump();
    }

    /// Picks into the tray: a preparing tile at once for each (pick order), then each is copied and prepared off the
    /// UI thread. Answers the reasons of the items that couldn't attach (the "Couldn't Attach" alert), after all are done.
    public async Task<IReadOnlyList<string>> AddPicksAsync(string scope, string profile, IReadOnlyList<PickedItem> picks)
    {
        var problems = new List<string>();
        var accepted = new List<(PickedItem Pick, DraftAttachment Placeholder, CancellationTokenSource Cancel)>();
        lock (_gate)
        {
            var d = DraftFor(scope);
            foreach (var pick in picks)
            {
                if (d.Ids.Count >= MaxPerMessage)
                {
                    problems.Add(new AttachmentPrepareException(AttachmentPrepareException.Reason.LimitReached).Message);
                    break;
                }
                var id = Guid.NewGuid().ToString().ToUpperInvariant();
                var kind = pick.Source is PickSource.Camera or PickSource.Clipboard || CanNormalize(pick.Name) ? DraftKind.Image : DraftKind.File;
                var placeholder = new DraftAttachment(id, kind, SafeName(pick.Name), "", 0, null, null, new UploadState.Preparing(null));
                var cancel = new CancellationTokenSource();
                _items[id] = placeholder;
                _profiles[id] = profile;
                _preparations[id] = cancel;
                d.Ids.Add(id);
                d.Profile = profile;
                d.UpdatedAt = Now();
                accepted.Add((pick, placeholder, cancel));
            }
        }
        DraftChanged?.Invoke(scope);
        var results = await Task.WhenAll(accepted.Select(x => Task.Run(async () =>
        {
            try
            {
                var prepared = await PrepareAsync(x.Pick, x.Placeholder.Id, x.Cancel.Token);
                FinishPreparing(prepared);
                return null;
            }
            catch (AttachmentPrepareException e)
            {
                FailPreparing(x.Placeholder.Id);
                return e.Why == AttachmentPrepareException.Reason.Cancelled ? null : e.Message;
            }
            catch (OperationCanceledException)
            {
                FailPreparing(x.Placeholder.Id);
                return null;
            }
        })));
        problems.InsertRange(0, results.Where(r => r != null).Select(r => r!));
        return problems;
    }

    /// Picture extensions the normaliser takes (everything else attaches as a file).
    public static bool CanNormalize(string name) => MediaKinds.ImageExtensions.Contains(MediaKinds.Ext(name));

    /// Picks → prepared attachments (AttachmentImporter.prepare): photos through the normaliser, other files copied
    /// under their safe names, each in its own folder; a failed item's partial copy is deleted at once.
    private async Task<DraftAttachment> PrepareAsync(PickedItem pick, string id, CancellationToken ct)
    {
        var folder = Path.Combine(StagingRoot, id);
        try
        {
            ct.ThrowIfCancellationRequested();
            var info = new FileInfo(pick.Path);
            if (!info.Exists) throw new AttachmentPrepareException(pick.Source == PickSource.File
                ? AttachmentPrepareException.Reason.UnreadableFile : AttachmentPrepareException.Reason.UnreadablePhoto);
            var safe = SafeName(pick.Name);
            var photo = pick.Source is PickSource.Camera or PickSource.Clipboard || CanNormalize(safe);
            if (photo)
            {
                var stem = pick.Source switch
                {
                    PickSource.Camera => "camera",
                    PickSource.Clipboard => "clipboard",
                    _ => Stem(safe),
                };
                // A source over the limit is still fine when the normalised copy fits; only absurd inputs are refused.
                if (info.Length > 512L << 20) throw new AttachmentPrepareException(AttachmentPrepareException.Reason.TooLarge, stem + ".jpg");
                Directory.CreateDirectory(folder);
                try
                {
                    var made = await NormalizeAsync(pick.Path, stem, safe, folder, ct);
                    if (made.ByteSize > AttachmentLimit.Bytes) throw new AttachmentPrepareException(AttachmentPrepareException.Reason.TooLarge, made.Name);
                    return new DraftAttachment(id, DraftKind.Image, made.Name, made.Path, made.ByteSize, made.PixelWidth, made.PixelHeight,
                        UploadState.Ready);
                }
                catch (Exception e) when (e is not AttachmentPrepareException and not OperationCanceledException && pick.Source == PickSource.File)
                {
                    // A picture the normaliser can't read (a HEIC without its codec) still attaches, as a file.
                    TryDeleteFolder(folder);
                }
                catch (Exception e) when (e is not AttachmentPrepareException and not OperationCanceledException)
                {
                    throw new AttachmentPrepareException(pick.Source == PickSource.Camera
                        ? AttachmentPrepareException.Reason.CameraNotSaved : AttachmentPrepareException.Reason.UnreadablePhoto);
                }
            }
            if (info.Length > AttachmentLimit.Bytes) throw new AttachmentPrepareException(AttachmentPrepareException.Reason.TooLarge, safe);
            Directory.CreateDirectory(folder);
            var target = Path.Combine(folder, safe);
            try { await Task.Run(() => File.Copy(pick.Path, target, overwrite: true), ct); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            { throw new AttachmentPrepareException(AttachmentPrepareException.Reason.UnreadableFile); }
            return new DraftAttachment(id, DraftKind.File, safe, target, new FileInfo(target).Length, null, null, UploadState.Ready);
        }
        catch
        {
            TryDeleteFolder(folder);
            throw;
        }
    }

    private static async Task<NormalizedPhoto> NormalizeAsync(string source, string stem, string safe, string folder, CancellationToken ct)
    {
        if (Normalizer is { } n) return await n.NormalizeAsync(source, stem, folder, ct);
        // No normaliser (tests, a Core-only host): the picture as it is, under the stem's name.
        var ext = MediaKinds.Ext(safe);
        var name = stem + "." + (ext.Length > 0 ? ext : "jpg");
        var target = Path.Combine(folder, name);
        await Task.Run(() => File.Copy(source, target, overwrite: true), ct);
        var size = ImageHeader.PixelSizeOfFile(target);
        return new NormalizedPhoto(target, name, new FileInfo(target).Length, size?.Width, size?.Height);
    }

    private void FinishPreparing(DraftAttachment prepared)
    {
        lock (_gate)
        {
            _preparations.Remove(prepared.Id);
            if (!_items.ContainsKey(prepared.Id))
            {
                // Removed while it was being prepared: its copy goes.
                TryDeleteFolder(Path.Combine(StagingRoot, prepared.Id));
                return;
            }
            _items[prepared.Id] = prepared;
            if (!prepared.DefersUpload && !_queue.Contains(prepared.Id)) _queue.Add(prepared.Id);
        }
        ItemChanged?.Invoke(prepared.Id);
        Save();
        Pump();
    }

    private void FailPreparing(string id)
    {
        var scopes = new List<string>();
        lock (_gate)
        {
            _preparations.Remove(id);
            if (!_items.Remove(id)) return;
            foreach (var (scope, d) in _drafts)
                if (d.Ids.Remove(id)) scopes.Add(scope);
        }
        TryDeleteFolder(Path.Combine(StagingRoot, id));
        ResumeWaiters(id); // a send waiting on it hears it is gone (and refuses) instead of hanging
        foreach (var s in scopes) DraftChanged?.Invoke(s);
        Save();
    }

    /// The tile's ✕ (spec §6.2): stops its preparation or upload, deletes this PC's copy, and deletes the gateway
    /// staging folder when it was already uploaded.
    public void Remove(string id, string scope)
    {
        DraftAttachment? removed;
        string profile;
        lock (_gate)
        {
            if (_preparations.Remove(id, out var prep)) prep.Cancel();
            if (_current?.Id == id) _current.Value.Cancel.Cancel();
            _queue.Remove(id);
            _items.Remove(id, out removed);
            profile = _profiles.Remove(id, out var p) ? p : _drafts.GetValueOrDefault(scope)?.Profile ?? "";
            if (_drafts.TryGetValue(scope, out var d)) { d.Ids.Remove(id); d.UpdatedAt = Now(); }
        }
        ResumeWaiters(id);
        TryDeleteFolder(Path.Combine(StagingRoot, id));
        if (removed?.StagingFolder is { Length: > 0 } folder) _ = Stager.ReleaseAsync(folder, profile);
        DraftChanged?.Invoke(scope);
        Save();
    }

    /// Try Again on a failed tile: it gets its automatic retry back. A send's own retry (resetAutoRetry false) is the
    /// one more try before refusing.
    public void Retry(string id, bool resetAutoRetry = true)
    {
        lock (_gate)
        {
            if (!_items.TryGetValue(id, out var a) || a.Failure == null) return;
            _items[id] = a with { Upload = UploadState.Ready };
            if (resetAutoRetry) _autoRetried.Remove(id); else _autoRetried.Add(id);
            if (!_queue.Contains(id)) _queue.Add(id);
        }
        ItemChanged?.Invoke(id);
        Save();
        Pump();
    }

    /// Send takes the draft (spec §6.4 step 1): text and attachments leave it together; the attachments stay known (in
    /// flight) until the send ends or returns them.
    public (string Text, IReadOnlyList<DraftAttachment> Attachments) TakeForSend(string scope)
    {
        (string, IReadOnlyList<DraftAttachment>) taken;
        lock (_gate)
        {
            if (!_drafts.TryGetValue(scope, out var d)) return ("", []);
            taken = (d.Text, d.Ids.Where(_items.ContainsKey).Select(i => _items[i]).ToList());
            _drafts[scope] = new Draft { Profile = d.Profile, UpdatedAt = Now() };
        }
        DraftChanged?.Invoke(scope);
        Save();
        return taken;
    }

    /// Moves a draft's text and attachments from `fromScope` to `toScope`, merging ahead of any items already at
    /// `toScope` (HermesKit/Attachments/AttachmentCenter.swift `moveDraft`, 363ae6c33).
    public void MoveDraft(string fromScope, string toScope, bool keepTargetText = false)
    {
        if (fromScope == toScope) return;
        lock (_gate)
        {
            if (!_drafts.Remove(fromScope, out var moving)) return;
            var target = DraftFor(toScope);
            target.Ids = [.. moving.Ids, .. target.Ids.Where(id => !moving.Ids.Contains(id))];
            if (moving.Text.Length > 0 && !(keepTargetText && target.Text.Length > 0)) target.Text = moving.Text;
            if (moving.Profile.Length > 0) target.Profile = moving.Profile;
            target.UpdatedAt = Math.Max(target.UpdatedAt, moving.UpdatedAt);
        }
        DraftChanged?.Invoke(fromScope);
        DraftChanged?.Invoke(toScope);
        Save();
    }

    /// A refused or stopped send hands its attachments back (spec §6.4 step 8): in front of whatever the tray holds now
    /// (deduplicated), with their upload state (an uploaded one stays uploaded). `text` goes in only when the draft has
    /// none and setTextIfEmpty.
    public void ReturnToDraft(string scope, string profile, string? text, IReadOnlyList<DraftAttachment> attachments, bool setTextIfEmpty)
    {
        lock (_gate)
        {
            var d = DraftFor(scope);
            d.Profile = profile;
            var incoming = attachments.Select(a => a.Id).ToList();
            d.Ids = [.. incoming, .. d.Ids.Where(i => !incoming.Contains(i))];
            foreach (var a in attachments)
            {
                var b = _items.GetValueOrDefault(a.Id) ?? a;
                // L6: do not reset an item that is actively being uploaded right now (`_current`).
                if (b.Upload is UploadState.Uploading && _current?.Id != a.Id) b = b with { Upload = UploadState.Ready };
                _items[a.Id] = b;
                _profiles[a.Id] = profile;
                if (b.Upload is UploadState.Waiting && !b.DefersUpload && !_queue.Contains(b.Id)) _queue.Add(b.Id);
            }
            if (setTextIfEmpty && !string.IsNullOrEmpty(text) && d.Text.Length == 0) d.Text = text;
            d.UpdatedAt = Now();
        }
        DraftChanged?.Invoke(scope);
        Save();
        Pump();
    }

    /// A sent message's attachments are done with: their copies go (after a second, as the Mac's 1 s removeLater).
    public void Release(IEnumerable<string> ids)
    {
        var list = ids.ToList();
        lock (_gate)
            foreach (var id in list)
            {
                _items.Remove(id);
                _profiles.Remove(id);
                _sendRetried.Remove(id);
                _autoRetried.Remove(id);
            }
        _ = Task.Run(async () =>
        {
            await Task.Delay(1000);
            foreach (var id in list) { lock (_gate) if (_items.ContainsKey(id)) continue; TryDeleteFolder(Path.Combine(StagingRoot, id)); }
        });
        Save();
    }

    // ------------------------------------------------------------------ uploads (spec §6.3)

    /// A send waits for this one: it goes first.
    public void Prioritize(string id)
    {
        lock (_gate)
        {
            if (_queue.Remove(id)) _queue.Insert(0, id);
            else if (_items.TryGetValue(id, out var a) && a.DefersUpload && a.Upload is UploadState.Waiting && _current?.Id != id)
                _queue.Insert(0, id);
        }
        Pump();
    }

    private void Pump()
    {
        DraftAttachment item;
        string profile;
        CancellationTokenSource cancel;
        lock (_gate)
        {
            if (_shutDown || _current != null || !_connectionReady) return;
            _queue.RemoveAll(i => !_items.ContainsKey(i));
            var index = _queue.FindIndex(i => _items[i].Upload is UploadState.Waiting);
            if (index < 0) return;
            var id = _queue[index];
            _queue.RemoveAt(index);
            item = _items[id];
            if (item.IsLink || item.LocalFile.Length == 0) return;
            profile = _profiles.GetValueOrDefault(id) ?? "";
            _items[id] = item with { Upload = new UploadState.Uploading(0, item.ByteSize) };
            cancel = new CancellationTokenSource();
            _current = (id, cancel);
        }
        ItemChanged?.Invoke(item.Id);
        _ = Task.Run(async () =>
        {
            StagedFile? staged = null;
            Exception? failure = null;
            try
            {
                staged = await Stager.StageAsync(item.LocalFile, item.Name, profile, (sent, total) => Progress(item.Id, sent, total),
                    cancel.Token);
            }
            catch (Exception e) { failure = e; }
            UploadFinished(item.Id, staged, failure, cancel.IsCancellationRequested, profile);
        });
    }

    private long _lastProgressTicks;

    private void Progress(string id, long sent, long total)
    {
        var now = Environment.TickCount64;
        if (now - Interlocked.Read(ref _lastProgressTicks) < 100 && sent < total) return; // ten updates a second at most
        Interlocked.Exchange(ref _lastProgressTicks, now);
        lock (_gate)
        {
            if (!_items.TryGetValue(id, out var a) || a.Upload is not UploadState.Uploading) return;
            _items[id] = a with { Upload = new UploadState.Uploading(sent, total) };
        }
        ItemChanged?.Invoke(id);
    }

    private void UploadFinished(string id, StagedFile? staged, Exception? failure, bool cancelled, string profile)
    {
        bool waitAgain = false, autoRetry = false;
        lock (_gate)
        {
            if (_current?.Id == id) _current = null;
            if (!_items.TryGetValue(id, out var a))
            {
                // Removed while uploading: its gateway copy goes too.
                if (staged != null) _ = Stager.ReleaseAsync(staged.Folder, profile);
            }
            else if (staged != null)
            {
                _items[id] = a with { Upload = new UploadState.Uploaded(staged.Path, staged.Folder) };
                _waitingTries = 0;
            }
            else if (cancelled || failure is OperationCanceledException)
            {
                _items[id] = a with { Upload = UploadState.Ready };
                _queue.Insert(0, id);
            }
            else if (failure is AttachmentUploadException u)
            {
                switch (u.Kind)
                {
                    case AttachmentUploadException.Kinds.Waiting:
                        _items[id] = a with { Upload = UploadState.Ready };
                        _queue.Insert(0, id);
                        _connectionReady = false; // starts again with the next Open…
                        waitAgain = _socketReady; // …which never comes if the socket never left
                        break;
                    case AttachmentUploadException.Kinds.Retryable when !_autoRetried.Contains(id):
                        _autoRetried.Add(id);
                        _items[id] = a with { Upload = UploadState.Ready };
                        autoRetry = true;
                        break;
                    case AttachmentUploadException.Kinds.Retryable or AttachmentUploadException.Kinds.SessionEnded:
                        _items[id] = a with { Upload = new UploadState.Failed(u.Reason, true) };
                        break;
                    default:
                        _items[id] = a with { Upload = new UploadState.Failed(u.Reason, false) };
                        break;
                }
            }
            else
            {
                _items[id] = a with { Upload = new UploadState.Failed(AttachmentUploadException.Connection(a.Name).Reason, true) };
            }
        }
        var settled = Item(id)?.Upload is UploadState.Uploaded or UploadState.Failed || Item(id) == null;
        if (settled) ResumeWaiters(id);
        ItemChanged?.Invoke(id);
        Save();
        if (waitAgain) RetryWhileSocketReady();
        if (autoRetry)
            _ = Task.Run(async () =>
            {
                await Task.Delay(AutoRetryDelay);
                lock (_gate) { if (_items.GetValueOrDefault(id)?.Upload is UploadState.Waiting && !_queue.Contains(id)) _queue.Add(id); }
                Pump();
            });
        Pump();
    }

    /// The upload failed "offline" but the socket is still open: try again after a growing wait (2, 5, 10, 30 s).
    private void RetryWhileSocketReady()
    {
        CancellationTokenSource cts;
        TimeSpan delay;
        lock (_gate)
        {
            _waitingRetry?.Cancel();
            delay = WaitingBackoff[Math.Min(_waitingTries, WaitingBackoff.Length - 1)];
            _waitingTries++;
            _waitingRetry = cts = new CancellationTokenSource();
        }
        _ = Task.Run(async () =>
        {
            try { await Task.Delay(delay, cts.Token); } catch (OperationCanceledException) { return; }
            lock (_gate)
            {
                if (_shutDown || !_socketReady || _connectionReady) return;
                _connectionReady = true;
            }
            Pump();
        });
    }

    private void ResumeWaiters(string id)
    {
        List<TaskCompletionSource>? list;
        lock (_gate) _waiters.Remove(id, out list);
        foreach (var w in list ?? []) w.TrySetResult();
    }

    /// Waits until `id` is uploaded (spec §6.4 step 3). A failed retryable upload is retried once per send; still
    /// failing (or gone) → the failure.
    public async Task<StagedFile> AwaitUploadedAsync(string id, bool retryFailed)
    {
        while (true)
        {
            Task wait;
            lock (_gate)
            {
                if (_stopRequested.Contains(id)) throw AttachmentUploadException.Stopped();
                if (_shutDown || !_items.TryGetValue(id, out var a))
                    throw new AttachmentUploadException(AttachmentUploadException.Kinds.Final, "This attachment is no longer on this PC.");
                switch (a.Upload)
                {
                    case UploadState.Uploaded u:
                        return new StagedFile(u.Path, u.Folder);
                    case UploadState.Failed f when retryFailed && f.Retryable && !_sendRetried.Contains(id):
                        _sendRetried.Add(id);
                        wait = Task.CompletedTask;
                        break;
                    case UploadState.Failed f:
                        throw new AttachmentUploadException(f.Retryable ? AttachmentUploadException.Kinds.Retryable
                            : AttachmentUploadException.Kinds.Final, f.Reason);
                    default:
                        var tcs = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                        if (!_waiters.TryGetValue(id, out var list)) _waiters[id] = list = [];
                        list.Add(tcs);
                        wait = tcs.Task;
                        break;
                }
            }
            if (wait.IsCompleted) { Retry(id, resetAutoRetry: false); Prioritize(id); continue; }
            Prioritize(id);
            await wait;
        }
    }

    /// Stop (spec §6.4 step 9): sends waiting on `ids` stop waiting at once; the uploads themselves keep going.
    public void InterruptWaits(IEnumerable<string> ids)
    {
        var list = ids.ToList();
        lock (_gate) _stopRequested.UnionWith(list);
        foreach (var id in list) ResumeWaiters(id);
    }

    /// The send ended (refused, stopped or delivered): its per-send retry allowance and any Stop mark reset.
    public void SendEnded(IEnumerable<string> ids)
    {
        lock (_gate)
            foreach (var id in ids) { _sendRetried.Remove(id); _stopRequested.Remove(id); }
    }

    // ------------------------------------------------------------------ names and files

    /// Last path component; control characters and " \ / : dropped; empty, . or .. → "attachment"; at most 180 UTF-8
    /// bytes, keeping an extension of ≤ 32 bytes (PickedFiles.safeName, spec §5.5).
    public static string SafeName(string raw)
    {
        var name = raw.Replace('\\', '/');
        name = name[(name.LastIndexOf('/') + 1)..];
        var filtered = string.Concat(name.EnumerateRunes().Where(r => !Rune.IsControl(r) && r.Value is not ('"' or '\\' or '/' or ':'))
            .Select(r => r.ToString()));
        if (filtered.Length == 0 || filtered is "." or "..") return "attachment";
        var enc = Encoding.UTF8;
        if (enc.GetByteCount(filtered) <= 180) return filtered;
        var ext = MediaKinds.Ext(filtered);
        var suffix = ext.Length > 0 && enc.GetByteCount(ext) <= 32 ? filtered[filtered.LastIndexOf('.')..] : "";
        var stem = suffix.Length == 0 ? filtered : filtered[..^suffix.Length];
        var cleaned = new StringBuilder();
        var budget = 180 - enc.GetByteCount(suffix);
        foreach (var r in stem.EnumerateRunes())
        {
            if (enc.GetByteCount(cleaned.ToString()) + r.Utf8SequenceLength > budget) break;
            cleaned.Append(r.ToString());
        }
        return cleaned + suffix;
    }

    /// A name's stem, for "<stem>.jpg".
    public static string Stem(string name)
    {
        var dot = name.LastIndexOf('.');
        var s = dot > 0 ? name[..dot] : name;
        return s.Length == 0 ? "photo" : s;
    }

    private static void TryDeleteFolder(string folder)
    {
        try { if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    /// Launch sweep (spec §6.6): staging folders nothing references and older than 600 s, and multipart bodies an
    /// earlier run left behind.
    private void Sweep()
    {
        HashSet<string> referenced;
        lock (_gate) referenced = [.. _items.Keys];
        try
        {
            var cutoff = DateTime.UtcNow.AddSeconds(-600);
            if (Directory.Exists(StagingRoot))
                foreach (var dir in new DirectoryInfo(StagingRoot).EnumerateDirectories())
                    if (!referenced.Contains(dir.Name) && dir.LastWriteTimeUtc < cutoff) TryDeleteFolder(dir.FullName);
            var uploads = Path.Combine(_root, "uploads");
            if (Directory.Exists(uploads))
                foreach (var f in new DirectoryInfo(uploads).EnumerateFiles())
                    if (f.LastWriteTimeUtc < cutoff) f.Delete();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    // ------------------------------------------------------------------ persistence (spec §6.6)

    private string DraftsFile => Path.Combine(_root, "drafts.json");

    private void Save()
    {
        JsonObject chats;
        lock (_gate)
        {
            if (_shutDown) return;
            chats = [];
            foreach (var (scope, d) in _drafts.Where(x => x.Value.Text.Length > 0 || x.Value.Ids.Count > 0)
                         .OrderByDescending(x => x.Value.UpdatedAt).Take(50))
            {
                var list = new JsonArray();
                foreach (var id in d.Ids) if (_items.TryGetValue(id, out var a)) list.Add(ToJson(a));
                chats[scope] = new JsonObject
                { ["text"] = d.Text, ["profile"] = d.Profile, ["updatedAt"] = d.UpdatedAt, ["attachments"] = list };
            }
        }
        try
        {
            Directory.CreateDirectory(_root);
            var tmp = DraftsFile + "." + Guid.NewGuid().ToString("N") + ".tmp";
            File.WriteAllText(tmp, new JsonObject { ["v"] = 1, ["chats"] = chats }.ToJsonString());
            File.Move(tmp, DraftsFile, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    /// On restore: preparing / uploading → waiting; uploaded kept; an attachment whose copy is gone is dropped.
    private void Load()
    {
        JsonNode? json = null;
        try { if (File.Exists(DraftsFile)) json = J.Parse(File.ReadAllText(DraftsFile)); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        if (json.Obj("chats") is not { } chats) return;
        foreach (var (scope, node) in chats)
        {
            var d = new Draft { Text = node.Str("text") ?? "", Profile = node.Str("profile") ?? "", UpdatedAt = node.Num("updatedAt") ?? 0 };
            foreach (var item in node.Arr("attachments") ?? [])
            {
                if (FromJson(item) is not { } a) continue;
                if (!a.IsLink && !File.Exists(a.LocalFile)) continue;
                if (a.Upload is UploadState.Preparing or UploadState.Uploading) a = a with { Upload = UploadState.Ready };
                _items[a.Id] = a;
                _profiles[a.Id] = d.Profile;
                d.Ids.Add(a.Id);
                if (a.Upload is UploadState.Waiting && !a.DefersUpload) _queue.Add(a.Id);
            }
            _drafts[scope] = d;
        }
    }

    internal static JsonObject ToJson(DraftAttachment a)
    {
        var o = new JsonObject
        {
            ["id"] = a.Id, ["kind"] = a.Kind.ToString(), ["name"] = a.Name, ["localFile"] = a.LocalFile, ["byteSize"] = a.ByteSize,
        };
        if (a.PixelWidth is { } w) o["w"] = w;
        if (a.PixelHeight is { } h) o["h"] = h;
        if (a.RefText is { } r) o["refText"] = r;
        o["upload"] = a.Upload switch
        {
            UploadState.Uploaded u => new JsonObject { ["state"] = "uploaded", ["path"] = u.Path, ["folder"] = u.Folder },
            UploadState.Failed f => new JsonObject { ["state"] = "failed", ["reason"] = f.Reason, ["retryable"] = f.Retryable },
            _ => new JsonObject { ["state"] = "waiting" },
        };
        return o;
    }

    internal static DraftAttachment? FromJson(JsonNode? n)
    {
        if (n.Str("id") is not { } id || !Enum.TryParse<DraftKind>(n.Str("kind"), out var kind)) return null;
        var u = n.Obj("upload");
        UploadState upload = u.Str("state") switch
        {
            "uploaded" when u.Str("path") is { } p => new UploadState.Uploaded(p, u.Str("folder") ?? ""),
            "failed" => new UploadState.Failed(u.Str("reason") ?? "", u.Bool("retryable") == true),
            _ => UploadState.Ready,
        };
        return new DraftAttachment(id, kind, n.Str("name") ?? "attachment", n.Str("localFile") ?? "", n.Int("byteSize") ?? 0,
            (int?)n.Int("w"), (int?)n.Int("h"), upload, n.Str("refText"));
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_shutDown) return;
            _shutDown = true;
            _current?.Cancel.Cancel();
            _current = null;
            foreach (var p in _preparations.Values) p.Cancel();
            _preparations.Clear();
            _waitingRetry?.Cancel();
        }
        Client.Rpc.StateChanged -= OnConnection;
        List<string> waiting;
        lock (_gate) waiting = [.. _waiters.Keys];
        foreach (var id in waiting) ResumeWaiters(id);
    }
}
