using System.Text.Json.Nodes;

namespace Hermes.Core.Artifacts;

/// One kept chat: its listing stamp, when it was last active, what it held, and (for a transcript over the safe-load
/// limit) the message count it failed at.
public sealed record ArtifactIndexEntry(string Stamp, double At, IReadOnlyList<ArtifactRecord> Artifacts, long? FailedAt = null);

public sealed record ArtifactIndexFailure(ArtifactSessionRow Session, Exception Error);

public sealed record ArtifactIndexResult(IReadOnlyList<ArtifactRecord> Artifacts, IReadOnlyList<ArtifactIndexFailure> Failures,
    IReadOnlyList<ArtifactSessionRow> Read);

/// What the page shows (`artifactsView`).
public enum ArtifactsView { Loading, Error, Empty, List }

/// The Artifacts index (docs/spec/1x-pages.md §5.3; HermesKit/Pages/ArtifactIndex.swift): one entry per [profile,
/// session] stamped with the row's message_count, last_active and title, so a visit reads only sessions that changed.
/// Kept across launches in a file (≤ 4 MB) for this collector version only. Reads newest first, 3 at a time (a session
/// with ≥ 1000 messages, or no count, takes all 3).
public sealed class ArtifactIndex
{
    /// Bump when the collector changes: a kept index from another collector is read again.
    public const string CollectorVersion = "native-7";
    public const int MaxFileBytes = 4 << 20;
    public const int Slots = 3;
    public const int LongSession = 1000;

    private Dictionary<string, ArtifactIndexEntry> _entries = [];
    private readonly object _gate = new();
    private bool _unsaved;
    private DateTime _lastSave = DateTime.MinValue;
    private Task _saving = Task.CompletedTask;
    private int _generation;

    public string? FilePath { get; }
    /// Progress at most once a second; saves at most every 5 s while reading (tests shorten them).
    public TimeSpan ProgressInterval { get; set; } = TimeSpan.FromSeconds(1);
    public TimeSpan SaveInterval { get; set; } = TimeSpan.FromSeconds(5);
    public bool IsLoaded { get; private set; }

    public IReadOnlyDictionary<string, ArtifactIndexEntry> Entries { get { lock (_gate) return new Dictionary<string, ArtifactIndexEntry>(_entries); } }

    /// Nothing is read here: `Prepare()` reads it when the page is about to draw.
    public ArtifactIndex(string? filePath) => FilePath = filePath;

    /// Reads the kept index once.
    public void Prepare()
    {
        if (IsLoaded) return;
        if (FilePath != null) lock (_gate) _entries = Read(FilePath) ?? [];
        IsLoaded = true;
    }

    public static Dictionary<string, ArtifactIndexEntry>? Read(string path)
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.Length > MaxFileBytes) return null;
            var json = J.Parse(File.ReadAllText(path));
            if (json.Str("collector") != CollectorVersion || json.Obj("entries") is not { } entries) return null;
            var out_ = new Dictionary<string, ArtifactIndexEntry>();
            foreach (var (key, value) in entries)
            {
                if (value.Str("stamp") is not { } stamp) continue;
                var records = (value.Arr("artifacts") ?? new JsonArray()).Select(ArtifactRecord.FromJson).OfType<ArtifactRecord>().ToList();
                out_[key] = new ArtifactIndexEntry(stamp, value.Num("at") ?? 0, records, value.Int("failedAt"));
            }
            return out_;
        }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }

    public static string Key(string? profile, string id)
    {
        var p = (profile ?? "").Trim();
        return (p.Length == 0 ? "default" : p) + "\u001F" + id;
    }

    public static string Key(ArtifactSessionRow session) => Key(session.Profile, session.Id);

    private static string ProfileOf(string key) => key.Split('\u001F', 2)[0];

    /// What changes when a session gains messages or a name; null when the row has no counts (never cached).
    public static string? Stamp(ArtifactSessionRow session)
    {
        if (session.MessageCount == null && session.LastActive == null) return null;
        static string Number(double? value)
        {
            if (value is not { } v) return "";
            return Math.Round(v) == v && Math.Abs(v) < 9e15 ? ((long)v).ToString(System.Globalization.CultureInfo.InvariantCulture)
                : v.ToString("R", System.Globalization.CultureInfo.InvariantCulture);
        }
        return $"{session.MessageCount?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? ""}|{Number(session.LastActive)}|{session.Title ?? ""}";
    }

    public static bool IsPermanentFailure(Exception error) =>
        error is ArtifactSafeLoadException || error.Message.Contains("safe-load limit", StringComparison.OrdinalIgnoreCase);

    /// One pass over the listed sessions (§5.3). `load` reads one session's artifacts (run off the calling thread);
    /// `onProgress` gets what there is to show as reads land (at most once a second); `onRead` each session read.
    /// `window`: the most chats a bot's listing returns (0: unknown); a shorter listing holds every chat it has.
    public async Task<ArtifactIndexResult> RunAsync(IReadOnlyList<ArtifactSessionRow> sessions,
        Func<ArtifactSessionRow, CancellationToken, Task<List<ArtifactRecord>>> load,
        IEnumerable<string>? listedProfiles = null, IEnumerable<string>? retainedProfiles = null, int retain = 0, int window = 0,
        Action<IReadOnlyList<ArtifactRecord>>? onProgress = null, Action<ArtifactSessionRow>? onRead = null,
        CancellationToken ct = default)
    {
        Prepare();
        var mine = Interlocked.Increment(ref _generation);
        static string Name(string p) => p.Length == 0 ? "default" : p;
        var listed = sessions.Select(Key).ToHashSet();
        var failedProfiles = (retainedProfiles ?? []).Select(Name).ToHashSet();
        var completedProfiles = (listedProfiles ?? []).Select(Name).Where(p => !failedProfiles.Contains(p)).ToHashSet();
        // [pins] A chat that only fell out of the window stays (the `retain` newest). One that is gone (deleted or
        // archived) still goes: it was newer than the oldest chat listed, or the listing was shorter than the window.
        var oldestListed = new Dictionary<string, double>();
        var listedCount = new Dictionary<string, int>();
        foreach (var session in sessions)
        {
            var profile = ProfileOf(Key(session));
            listedCount[profile] = listedCount.GetValueOrDefault(profile) + 1;
            if (session.LastActive is { } active) oldestListed[profile] = Math.Min(oldestListed.GetValueOrDefault(profile, active), active);
        }
        bool Gone(string key, ArtifactIndexEntry entry)
        {
            var profile = ProfileOf(key);
            if (!completedProfiles.Contains(profile)) return false;
            var count = listedCount.GetValueOrDefault(profile);
            if (count == 0 || (window > 0 && count < window)) return true;
            return oldestListed.TryGetValue(profile, out var oldest) && entry.At > oldest;
        }
        List<ArtifactRecord> kept;
        var stale = new List<ArtifactSessionRow>();
        List<IReadOnlyList<ArtifactRecord>> previous;
        HashSet<string> retainedKeys;
        lock (_gate)
        {
            foreach (var (key, entry) in _entries.ToList())
                if (!listed.Contains(key) && Gone(key, entry)) { _entries.Remove(key); _unsaved = true; }
            var covered = completedProfiles.Union(failedProfiles).ToHashSet();
            var retained = _entries.Where(e => !listed.Contains(e.Key) && e.Value.Artifacts.Count > 0 && covered.Contains(ProfileOf(e.Key)))
                .OrderByDescending(e => e.Value.At).Take(Math.Max(0, retain)).ToList();
            retainedKeys = retained.Select(e => e.Key).ToHashSet();
            kept = [.. retained.SelectMany(e => e.Value.Artifacts)];
            foreach (var session in sessions)
            {
                _entries.TryGetValue(Key(session), out var entry);
                var stamp = Stamp(session);
                var tooLarge = entry?.FailedAt is { } at && (session.MessageCount ?? -1) >= at;
                if (entry != null && stamp != null && (entry.Stamp == stamp || tooLarge)) { kept.AddRange(entry.Artifacts); continue; }
                stale.Add(session);
            }
            previous = [.. stale.Select(s => _entries.TryGetValue(Key(s), out var e) ? e.Artifacts : [])];
        }
        var results = new (List<ArtifactRecord>? Ok, Exception? Error)?[stale.Count];
        IEnumerable<ArtifactRecord> Found(int at) => results[at] is { Ok: { } ok } ? ok : previous[at];
        var shownAt = DateTime.MinValue;
        var shown = false;
        void Show(bool now)
        {
            if (onProgress == null || mine != Volatile.Read(ref _generation)) return;
            if (!now && DateTime.UtcNow - shownAt < ProgressInterval) return;
            var all = kept.Concat(Enumerable.Range(0, stale.Count).SelectMany(Found)).ToList();
            if (all.Count == 0) return;
            shownAt = DateTime.UtcNow;
            shown = true;
            onProgress(all);
        }
        if (stale.Count > 0) Show(true);

        var order = new Queue<int>(Enumerable.Range(0, stale.Count).OrderByDescending(i => stale[i].Recency));
        int Weight(int i) => (stale[i].MessageCount ?? LongSession) >= LongSession ? Slots : 1;
        async Task<(List<ArtifactRecord>?, Exception?)> Read(ArtifactSessionRow session)
        {
            try { return (await load(session, ct).ConfigureAwait(false), null); }
            catch (Exception e) { return (null, e); }
        }
        var running = new Dictionary<Task<(List<ArtifactRecord>?, Exception?)>, int>();
        var used = 0;
        while (true)
        {
            while (order.Count > 0 && used + Weight(order.Peek()) <= Slots)
            {
                var i = order.Dequeue();
                used += Weight(i);
                var session = stale[i];
                // Started in order, newest first (each read's own awaits leave this thread).
                running.Add(Read(session), i);
            }
            if (running.Count == 0) break;
            var done = await Task.WhenAny(running.Keys);
            var index = running[done];
            running.Remove(done);
            used -= Weight(index);
            var outcome = await done;
            results[index] = outcome;
            if (mine != Volatile.Read(ref _generation)) continue;
            Settle(stale[index], outcome.Item1, outcome.Item2);
            onRead?.Invoke(stale[index]);
            Show(!shown);
            if (DateTime.UtcNow - _lastSave >= SaveInterval) Save();
        }
        var failures = Enumerable.Range(0, stale.Count).Where(i => results[i] is { Error: not null })
            .Select(i => new ArtifactIndexFailure(stale[i], results[i]!.Value.Error!)).ToList();
        var loaded = Enumerable.Range(0, stale.Count).SelectMany(Found).ToList();
        if (mine != Volatile.Read(ref _generation)) return new ArtifactIndexResult([.. kept, .. loaded], failures, stale);
        lock (_gate)
        {
            // Sessions that left the window are forgotten beyond the `retain` kept.
            var outside = _entries.Keys.Count(k => !listed.Contains(k));
            foreach (var key in _entries.OrderBy(e => e.Value.At).Select(e => e.Key).ToList())
            {
                if (outside <= retain) break;
                if (listed.Contains(key) || retainedKeys.Contains(key)) continue;
                _entries.Remove(key);
                outside--;
                _unsaved = true;
            }
        }
        Save();
        return new ArtifactIndexResult([.. kept, .. loaded], failures, stale);
    }

    private void Settle(ArtifactSessionRow session, List<ArtifactRecord>? artifacts, Exception? error)
    {
        var stamp = Stamp(session);
        var key = Key(session);
        lock (_gate)
        {
            _unsaved = true;
            if (error != null)
            {
                if (stamp != null && session.MessageCount is { } count && IsPermanentFailure(error))
                    _entries[key] = new ArtifactIndexEntry(stamp, session.LastActive ?? 0,
                        _entries.TryGetValue(key, out var old) ? old.Artifacts : [], count);
                // Any other failure keeps the previous artifacts and the old stamp: the next pass retries.
                return;
            }
            if (stamp == null) { _entries.Remove(key); return; }
            _entries[key] = new ArtifactIndexEntry(stamp, session.LastActive ?? 0,
                [.. artifacts!.Where(a => Key(a.Profile, a.SessionId) == key)]);
        }
    }

    /// Writes the index off the calling thread (newest sessions first while they fit in 4 MB).
    public void Save()
    {
        Dictionary<string, ArtifactIndexEntry> snapshot;
        lock (_gate)
        {
            if (!_unsaved || FilePath == null) return;
            _unsaved = false;
            _lastSave = DateTime.UtcNow;
            snapshot = new Dictionary<string, ArtifactIndexEntry>(_entries);
        }
        var path = FilePath;
        _saving = _saving.ContinueWith(_ => Write(path, snapshot), TaskScheduler.Default);
    }

    /// Returns once every save asked for has been written.
    public Task FlushAsync() => _saving;

    private static JsonObject EntryJson(ArtifactIndexEntry e)
    {
        var o = new JsonObject { ["stamp"] = e.Stamp, ["at"] = e.At, ["artifacts"] = new JsonArray([.. e.Artifacts.Select(a => (JsonNode)a.ToJson())]) };
        if (e.FailedAt is { } f) o["failedAt"] = f;
        return o;
    }

    private static void Write(string path, Dictionary<string, ArtifactIndexEntry> snapshot)
    {
        try
        {
            var entries = new JsonObject();
            var total = 0;
            foreach (var (key, entry) in snapshot.OrderByDescending(e => e.Value.At))
            {
                var json = EntryJson(entry);
                var size = json.ToJsonString().Length;
                if (total + size > MaxFileBytes * 9 / 10) continue;
                entries[key] = json;
                total += size;
            }
            var file = new JsonObject { ["collector"] = CollectorVersion, ["entries"] = entries };
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var temp = path + ".tmp";
            File.WriteAllText(temp, file.ToJsonString());
            File.Move(temp, path, overwrite: true);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    /// Ends any pass in flight's claim on the index (sign-out; a new account starts from nothing).
    public void Cancel()
    {
        Interlocked.Increment(ref _generation);
        lock (_gate) _entries = [];
        IsLoaded = true;
    }

    /// What the page shows: found artifacts win; none loaded and a pass in flight is loading, a failed pass is the
    /// error, only a pass that worked and found nothing is empty.
    public static ArtifactsView View(int? loaded, int visible, bool refreshing, string? error)
    {
        if (visible > 0) return ArtifactsView.List;
        if (loaded is > 0) return ArtifactsView.Empty;
        if (refreshing || (loaded == null && error == null)) return ArtifactsView.Loading;
        return error != null ? ArtifactsView.Error : ArtifactsView.Empty;
    }
}
