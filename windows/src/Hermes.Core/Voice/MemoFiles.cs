using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Hermes.Core.Net;

namespace Hermes.Core.Voice;

// Where memos live on the device (spec 1x-voice §3.3 step 3, §3.6, §6.2, §6.3; HermesKit/Voice/MemoFiles.swift at
// 93f984bb1). The layout is the Mac's, under the two bases the app passes in (the Mac's Application Support and
// Library/Caches; on Windows the app's LocalApplicationData folder and its cache folder):
//   <support>/memos/<account key>/<UUID>/voice-memo.<ext>   your recordings (drafts, sends in flight)
//   <support>/memos/<account key>/drafts.json              drafts per chat, newest first: {"<scope>": [MemoDraft]}
//   <support>/memos/<account key>/shapes.json              waveforms by path, newest 64
//   <caches>/memos/<account key>/<sha256(path)>.<ext>      played gateway memos (LRU, 64 files / 128 MB)
// The account key is SHA-256(account id), hex, first 16 characters. Sign-out purges both folders. memos/ and
// memos/<account key>/ are protected on every sign-in (IMemoFolderGuard); recordings no draft refers to (a crash or a
// kill mid-send) are swept once a day old. Plain System.IO: no OS service is needed except the folder guard.

/// What the Mac does to a memo folder through the OS: `FileProtectionType.completeUntilFirstUserAuthentication` on
/// create, and `isExcludedFromBackup`. A Windows implementation would: keep the folders under LocalApplicationData
/// (never Roaming, which follows the user to other PCs, nor a OneDrive-redirected folder), mark them
/// FILE_ATTRIBUTE_NOT_CONTENT_INDEXED so Windows Search doesn't index chat ids and recordings, and leave the inherited
/// per-user ACL as it is (the profile folder is already the user's alone). Called on every sign-in and whenever a
/// folder is created; it must not throw.
public interface IMemoFolderGuard
{
    void Protect(string folder);
}

/// No OS calls (tests, and until the Windows guard exists).
public sealed class NoMemoFolderGuard : IMemoFolderGuard
{
    public static readonly NoMemoFolderGuard Instance = new();
    public void Protect(string folder) { }
}

public sealed class MemoPaths(string supportBase, string cachesBase, IMemoFolderGuard? guard = null)
{
    public string SupportBase { get; } = supportBase;
    public string CachesBase { get; } = cachesBase;
    public IMemoFolderGuard Guard { get; } = guard ?? NoMemoFolderGuard.Instance;

    /// The recording's name inside its UUID folder.
    public const string RecordingName = "voice-memo";
    public const string DraftsFile = "drafts.json";
    public const string ShapesFile = "shapes.json";
    /// Recordings nothing refers to go once this old (seconds).
    public const double SweepAge = 86_400;

    public static string AccountKey(string accountId) => Hex(accountId)[..16];

    public static string Hex(string text) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text))).ToLowerInvariant();

    public string MemosRoot => Path.Combine(SupportBase, "memos");
    public string Memos(string key) => Path.Combine(MemosRoot, key);
    public string Caches(string key) => Path.Combine(CachesBase, "memos", key);

    /// A new recording's final place: memos/<key>/<UUID>/voice-memo.<ext> (the UUID upper-case, as Foundation's).
    public string NewRecording(string key, string ext) =>
        Path.Combine(Memos(key), Guid.NewGuid().ToString().ToUpperInvariant(), $"{RecordingName}.{ext}");

    /// A path this device owns (under memos/): a local file, never a gateway path.
    public bool IsLocal(string path)
    {
        foreach (var root in new[] { MemosRoot, Real(MemosRoot) })
            if (path.StartsWith(root + "/", StringComparison.Ordinal) || path.StartsWith(root + "\\", StringComparison.Ordinal))
                return true;
        return false;
    }

    /// A recording's path in this install. The app's data folder can move (a reinstall, a moved profile on Windows; an
    /// update on iOS), so a path saved by an earlier launch is rebuilt under today's memos folder (everything after its
    /// last "/memos/").
    public string Rebase(string path)
    {
        if (File.Exists(path)) return path;
        var at = Math.Max(path.LastIndexOf("/memos/", StringComparison.Ordinal), path.LastIndexOf("\\memos\\", StringComparison.Ordinal));
        if (at < 0) return path;
        var tail = path[(at + "/memos/".Length)..].Split('/', '\\');
        var moved = Path.Combine([MemosRoot, .. tail]);
        return File.Exists(moved) ? moved : path;
    }

    /// Creates `folder` if needed and protects it (and so everything in it), every time.
    public void ExcludeFromBackup(string folder)
    {
        try { Directory.CreateDirectory(folder); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        Guard.Protect(folder);
    }

    /// Deletes the recording folders under memos/<key>/ that no draft refers to and that nothing touched for `age`
    /// seconds: what a crash or a kill mid-send left behind. Run off the UI thread.
    public void Sweep(string key, IEnumerable<string> keeping, double age = SweepAge)
    {
        string[] folders;
        try { folders = Directory.GetDirectories(Memos(key)); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return; }
        var kept = new HashSet<string>(keeping.SelectMany(p => new[] { p, Real(p) }), StringComparer.Ordinal);
        var cutoff = DateTime.UtcNow.AddSeconds(-age);
        foreach (var folder in folders)
        {
            string[] files;
            try { files = Directory.GetFiles(folder); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { files = []; }
            if (files.Any(f => kept.Contains(f) || kept.Contains(Real(f)))) continue;
            var touched = files.Select(File.GetLastWriteTimeUtc).Append(Directory.GetLastWriteTimeUtc(folder));
            if (touched.Max() < cutoff)
            {
                try { Directory.Delete(folder, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            }
        }
    }

    /// Creates the folder (protected) when it isn't there.
    public void Ensure(string folder)
    {
        if (Directory.Exists(folder)) return;
        try { Directory.CreateDirectory(folder); } catch (IOException) { return; } catch (UnauthorizedAccessException) { return; }
        Guard.Protect(folder);
    }

    /// Deletes a recording and its UUID folder (when that folder is under memos/).
    public void Remove(string path)
    {
        if (!IsLocal(path)) return;
        try { File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        var folder = Path.GetDirectoryName(path);
        var account = folder is null ? null : Path.GetDirectoryName(folder);
        var root = account is null ? null : Path.GetDirectoryName(account);
        if (folder is null || root is null || !SamePath(root, MemosRoot)) return;
        try
        {
            if (Directory.Exists(folder) && !Directory.EnumerateFileSystemEntries(folder).Any()) Directory.Delete(folder);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    /// Sign-out: this account's recordings, drafts, shapes and played memos.
    public void Purge(string accountId)
    {
        var key = AccountKey(accountId);
        DeleteTree(Memos(key));
        DeleteTree(Caches(key));
    }

    public void PurgeAll()
    {
        DeleteTree(MemosRoot);
        DeleteTree(Path.Combine(CachesBase, "memos"));
    }

    internal static void DeleteTree(string folder)
    {
        try { if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static bool SamePath(string a, string b) =>
        string.Equals(Path.TrimEndingDirectorySeparator(Path.GetFullPath(a)), Path.TrimEndingDirectorySeparator(Path.GetFullPath(b)),
            OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    /// `resolvingSymlinksInPath`: every symbolic link along the path followed (macOS's /var → /private/var). A path
    /// that doesn't exist resolves as far as it does.
    public static string Real(string path)
    {
        try
        {
            var full = Path.GetFullPath(path);
            var root = Path.GetPathRoot(full) ?? "";
            var current = root;
            foreach (var part in full[root.Length..].Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
            {
                var next = Path.Combine(current, part);
                FileSystemInfo info = Directory.Exists(next) ? new DirectoryInfo(next) : new FileInfo(next);
                if (info.Exists && info.LinkTarget is { } target)
                {
                    var resolved = info.ResolveLinkTarget(returnFinalTarget: true);
                    next = resolved?.FullName ?? Path.GetFullPath(Path.Combine(current, target));
                }
                current = next;
            }
            return current;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return path;
        }
    }
}

/// Small JSON files written off the UI thread (one serial queue, latest write wins). The value is serialised when the
/// write is asked for, so later changes to the caller's collections never leak into it.
public static class MemoDisk
{
    private static readonly object Gate = new();
    private static Task _tail = Task.CompletedTask;

    internal static readonly JsonSerializerOptions Json = new() { DefaultIgnoreCondition = JsonIgnoreCondition.Never };

    public static T? Read<T>(string file) where T : class
    {
        try { return File.Exists(file) ? JsonSerializer.Deserialize<T>(File.ReadAllBytes(file), Json) : null; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or NotSupportedException) { return null; }
    }

    public static void Write<T>(T value, string file, MemoPaths paths)
    {
        byte[] data;
        try { data = JsonSerializer.SerializeToUtf8Bytes(value, Json); }
        catch (Exception e) when (e is JsonException or NotSupportedException) { return; }
        lock (Gate)
        {
            _tail = _tail.ContinueWith(_ =>
            {
                try
                {
                    var folder = Path.GetDirectoryName(file)!;
                    paths.Ensure(folder);
                    // Atomic, as Data.write(options: .atomic): a temp file beside it, then a replace.
                    var temp = Path.Combine(folder, $".{Path.GetFileName(file)}.{Guid.NewGuid():N}.tmp");
                    File.WriteAllBytes(temp, data);
                    File.Move(temp, file, overwrite: true);
                }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }, CancellationToken.None, TaskContinuationOptions.None, TaskScheduler.Default);
        }
    }

    /// Waits for queued writes (tests, sign-out).
    public static void Flush()
    {
        Task tail;
        lock (Gate) tail = _tail;
        tail.Wait();
    }
}

// MARK: - Drafts

/// A memo waiting in its chat's composer, with any words that were typed beside it (a queued memo handed back when its
/// chat was left: they go back into the field with it).
public sealed record MemoDraft(
    [property: JsonPropertyName("memo")] MemoFile Memo,
    [property: JsonPropertyName("text"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Text = null);

/// Memo drafts per chat (spec §3.6), keyed by the chat's layout scope, newest first; the chip shows the first. A memo
/// handed back (a take left behind, a refused or withdrawn send, a queued memo removed or left behind) goes in front and
/// never deletes another: a recording only leaves the device when it is sent or its chip's Remove is clicked. Survives
/// relaunch (paths rebased if the data folder moved). Single-threaded: use it from the UI thread.
public sealed class MemoDraftStore
{
    /// Raised with the scope that changed (`MemoDraftStore.didChange` with its `scope` key).
    public event Action<string>? Changed;

    private readonly MemoPaths _paths;
    private readonly string _file;
    private readonly Dictionary<string, List<MemoDraft>> _drafts;

    public MemoDraftStore(MemoPaths paths, string accountKey)
    {
        _paths = paths;
        _file = Path.Combine(paths.Memos(accountKey), MemoPaths.DraftsFile);
        var loaded = Load(_file);
        var changed = false;
        foreach (var scope in loaded.Keys.ToList())
        {
            var list = loaded[scope];
            // A draft whose recording is gone (cleared, a crash mid-save) is no draft.
            var kept = list.Select(d => d with { Memo = d.Memo with { Path = paths.Rebase(d.Memo.Path) } })
                .Where(d => File.Exists(d.Memo.Path)).ToList();
            if (!kept.SequenceEqual(list))
            {
                changed = true;
                if (kept.Count == 0) loaded.Remove(scope); else loaded[scope] = kept;
            }
        }
        _drafts = loaded;
        if (changed) Save();
    }

    private static Dictionary<string, List<MemoDraft>> Load(string file)
    {
        if (MemoDisk.Read<Dictionary<string, List<MemoDraft>>>(file) is { } lists)
            return lists.Where(p => p.Value != null)
                .ToDictionary(p => p.Key, p => p.Value.Where(d => d?.Memo?.Path != null).ToList());
        // A drafts file written before drafts were lists.
        if (MemoDisk.Read<Dictionary<string, MemoFile>>(file) is { } single)
            return single.Where(p => p.Value?.Path != null).ToDictionary(p => p.Key, p => new List<MemoDraft> { new(p.Value) });
        return [];
    }

    /// The scope's draft (its newest). A bot chat opened before its id was known kept its drafts under
    /// "<account>|<profile>|": they are found (and moved) once the chat knows its id.
    public MemoFile? Draft(string scope) => Entries(scope).FirstOrDefault()?.Memo;

    /// Words kept with the scope's draft (null when none).
    public string? Text(string scope) => Entries(scope).FirstOrDefault()?.Text is { Length: > 0 } t ? t : null;

    /// Every recording a draft refers to (the sweep keeps them).
    public IReadOnlySet<string> Paths => _drafts.Values.SelectMany(l => l.Select(d => d.Memo.Path)).ToHashSet();

    /// `memo`: in front of the scope's drafts (moved there if it is already one). null: Remove — the newest draft goes
    /// and its recording is deleted.
    public void Set(MemoFile? memo, string scope)
    {
        var list = Entries(scope).ToList();
        if (memo != null)
        {
            if (list.Count > 0 && list[0].Memo == memo) return;
            var text = list.FirstOrDefault(d => d.Memo.Path == memo.Path)?.Text;
            list.RemoveAll(d => d.Memo.Path == memo.Path);
            list.Insert(0, new MemoDraft(memo, text));
        }
        else
        {
            if (list.Count == 0) return;
            var removed = list[0];
            list.RemoveAt(0);
            _paths.Remove(removed.Memo.Path);
        }
        Store(list, scope);
    }

    /// Memos handed back with their words (oldest first): in front of the scope's drafts, in that order. Nothing is
    /// deleted.
    public void Restore(IReadOnlyList<MemoDraft> items, string scope)
    {
        if (items.Count == 0) return;
        var paths = items.Select(i => i.Memo.Path).ToHashSet();
        Store([.. items, .. Entries(scope).Where(d => !paths.Contains(d.Memo.Path))], scope);
    }

    /// Takes the scope's newest draft out of the store to send it: its file stays (touched, so the sweep sees it as
    /// fresh while it is in flight).
    public MemoFile? Take(string scope)
    {
        var list = Entries(scope).ToList();
        if (list.Count == 0) return null;
        var memo = list[0].Memo;
        list.RemoveAt(0);
        try { File.SetLastWriteTimeUtc(memo.Path, DateTime.UtcNow); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        Store(list, scope);
        return memo;
    }

    /// The words kept with the scope's newest draft went back into the field: they're no longer kept.
    public void ClearText(string scope)
    {
        var list = Entries(scope).ToList();
        if (list.Count == 0 || list[0].Text == null) return;
        list[0] = list[0] with { Text = null };
        _drafts[scope] = list;
        Save();
    }

    /// The scope's drafts, moving a bare scope's ("<account>|<profile>|") to a full one that asks.
    private List<MemoDraft> Entries(string scope)
    {
        if (_drafts.TryGetValue(scope, out var hit) && hit.Count > 0) return hit;
        var bar = scope.LastIndexOf('|');
        if (bar < 0 || bar + 1 >= scope.Length) return [];
        var bare = scope[..(bar + 1)];
        if (!_drafts.TryGetValue(bare, out var early) || early.Count == 0) return [];
        _drafts.Remove(bare);
        _drafts[scope] = early;
        Save();
        return early;
    }

    private void Store(List<MemoDraft> list, string scope)
    {
        if (list.Count == 0) _drafts.Remove(scope); else _drafts[scope] = list;
        Save();
        Changed?.Invoke(scope);
    }

    public IReadOnlyDictionary<string, MemoFile> All =>
        _drafts.Where(p => p.Value.Count > 0).ToDictionary(p => p.Key, p => p.Value[0].Memo);

    /// How many memo drafts an account keeps on this device, read from its file without loading the store (Sign Out and
    /// Remove say how many recordings they delete). A draft whose recording is gone doesn't count.
    public static int SavedCount(MemoPaths paths, string accountId)
    {
        var file = Path.Combine(paths.Memos(MemoPaths.AccountKey(accountId)), MemoPaths.DraftsFile);
        return Load(file).Values.SelectMany(l => l).Count(d => File.Exists(paths.Rebase(d.Memo.Path)));
    }

    private void Save() => MemoDisk.Write(_drafts.ToDictionary(p => p.Key, p => p.Value.ToList()), _file, _paths);
}

// MARK: - Waveform shapes

public sealed record MemoShape(
    [property: JsonPropertyName("peaks")] IReadOnlyList<double> Peaks,
    [property: JsonPropertyName("seconds")] double Seconds,
    [property: JsonPropertyName("at")] double At);

/// Waveforms by path, newest 64 (W:src/ui-voice/memo-peaks.ts:4-37). Your own memos are stored at save by their local
/// path and linked to the gateway path when the send's text is rewritten. Single-threaded: use it from the UI thread.
public sealed class MemoShapeStore
{
    /// Raised with the path whose shape arrived (`MemoShapeStore.didChange` with its `path` key).
    public event Action<string>? Changed;
    public const int Limit = 64;
    /// A shape has this many peaks.
    public const int PeakCount = 48;

    private readonly MemoPaths _paths;
    private readonly string _file;
    private Dictionary<string, MemoShape> _shapes;
    private readonly HashSet<string> _failed = [];
    private double _lastAt;

    public MemoShapeStore(MemoPaths paths, string accountKey)
    {
        _paths = paths;
        _file = Path.Combine(paths.Memos(accountKey), MemoPaths.ShapesFile);
        _shapes = (MemoDisk.Read<Dictionary<string, MemoShape>>(_file) ?? [])
            .Where(p => p.Value?.Peaks != null).ToDictionary(p => p.Key, p => p.Value);
        _lastAt = _shapes.Count == 0 ? 0 : _shapes.Values.Max(s => s.At);
    }

    /// Paths whose computation failed this launch: never asked again.
    public IReadOnlySet<string> Failed => _failed;

    public MemoShape? Shape(string path) => _shapes.GetValueOrDefault(path);

    public void Remember(string path, IReadOnlyList<double> peaks, double seconds)
    {
        if (peaks.Count != PeakCount || !double.IsFinite(seconds) || seconds <= 0) return;
        // Date().timeIntervalSince1970 is finer than the clock's tick here: kept strictly rising so the newest wins.
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
        _lastAt = Math.Max(now, _lastAt + 1e-6);
        _shapes[path] = new MemoShape(peaks.ToArray(), seconds, _lastAt);
        Trim();
        Save();
        Changed?.Invoke(path);
    }

    /// The gateway's copy has the same shape as the recording it came from.
    public void Link(string local, string gateway)
    {
        if (!_shapes.TryGetValue(local, out var shape) || local == gateway) return;
        Remember(gateway, shape.Peaks, shape.Seconds);
    }

    public void MarkFailed(string path) => _failed.Add(path);
    public void UnmarkFailed(string path) => _failed.Remove(path);

    public int Count => _shapes.Count;

    private void Trim()
    {
        if (_shapes.Count <= Limit) return;
        _shapes = _shapes.OrderByDescending(p => p.Value.At).Take(Limit).ToDictionary(p => p.Key, p => p.Value);
    }

    private void Save() => MemoDisk.Write(new Dictionary<string, MemoShape>(_shapes), _file, _paths);
}

// MARK: - Playback cache

/// Played gateway memos as local files (spec §6.2): LRU by last use, 64 files or 128 MB. A gateway path resolves to
/// the local recording it came from (an alias, then the moved file), else to a cached download. Thread-safe.
public sealed class MemoPlaybackCache
{
    public const int DefaultMaxFiles = 64;
    public const int DefaultMaxBytes = 128 << 20;

    public string Folder { get; }
    public int MaxFiles { get; }
    public int MaxBytes { get; }
    private readonly MemoPaths _paths;
    private readonly object _gate = new();
    private readonly Dictionary<string, string> _aliases = [];
    private readonly Dictionary<string, Task<string>> _flights = [];

    public MemoPlaybackCache(MemoPaths paths, string accountKey, int maxFiles = DefaultMaxFiles, int maxBytes = DefaultMaxBytes)
    {
        _paths = paths;
        Folder = paths.Caches(accountKey);
        MaxFiles = maxFiles;
        MaxBytes = maxBytes;
    }

    /// The cache file for a gateway path: <sha256(path)>.<lower-case extension>.
    public string CacheUrl(string path)
    {
        var ext = PathExtension(path).ToLowerInvariant();
        return Path.Combine(Folder, MemoPaths.Hex(path) + (ext.Length == 0 ? "" : "." + ext));
    }

    /// NSString.pathExtension: after the last "." of the last "/" component (none for ".name" or "name.").
    internal static string PathExtension(string path)
    {
        var name = path.TrimEnd('/');
        name = name[(name.LastIndexOf('/') + 1)..];
        var dot = name.LastIndexOf('.');
        return dot <= 0 || dot == name.Length - 1 ? "" : name[(dot + 1)..];
    }

    /// A local file for `path` without the network: the file itself (local), an alias, or a cache hit (touched).
    public string? Local(string path)
    {
        if (_paths.IsLocal(path) || path.StartsWith(Path.GetTempPath(), StringComparison.Ordinal))
            return File.Exists(path) ? path : null;
        string? alias;
        lock (_gate) alias = _aliases.GetValueOrDefault(path);
        if (alias != null && File.Exists(alias)) return alias;
        var cached = CacheUrl(path);
        if (!File.Exists(cached)) return null;
        try { File.SetLastWriteTimeUtc(cached, DateTime.UtcNow); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        return cached;
    }

    /// While a send is in flight, the gateway path plays the local recording.
    public void Alias(string gatewayPath, string local)
    {
        lock (_gate) _aliases[gatewayPath] = local;
    }

    /// The gateway accepted the memo (V9): the recording moves into the cache under its gateway path, so your own memo
    /// never downloads again.
    public void Adopt(string local, string gatewayPath)
    {
        var target = CacheUrl(gatewayPath);
        _paths.Ensure(Folder);
        try { File.Delete(target); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        try { File.Move(local, target); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return; }
        _paths.Remove(local);   // its empty UUID folder
        lock (_gate) _aliases.Remove(gatewayPath);
        Evict();
    }

    /// Downloads `path` (`GET /api/fs/download?path=&profile=`), one flight per path, written off the UI thread.
    public Task<string> FetchAsync(string path, string? profile, IMemoGateway client)
    {
        if (Local(path) is { } hit) return Task.FromResult(hit);
        lock (_gate)
        {
            if (_flights.TryGetValue(path, out var running)) return running;
            var made = Task.Run(async () =>
            {
                try
                {
                    var query = new List<KeyValuePair<string, string>> { new("path", path) };
                    if (!string.IsNullOrEmpty(profile)) query.Add(new("profile", profile));
                    var data = await client.RestAsync("GET", "/api/fs/download", query, null, CancellationToken.None);
                    if (data.Length == 0) throw new GatewayException("http", "HTTP 204", 204, "empty");
                    _paths.Ensure(Folder);
                    var target = CacheUrl(path);
                    var temp = target + "." + Guid.NewGuid().ToString("N") + ".tmp";
                    await File.WriteAllBytesAsync(temp, data);
                    File.Move(temp, target, overwrite: true);
                    Evict();
                    return target;
                }
                finally
                {
                    lock (_gate) _flights.Remove(path);
                }
            });
            _flights[path] = made;
            return made;
        }
    }

    /// Keeps the newest `MaxFiles` / `MaxBytes` by last use.
    public void Evict()
    {
        FileInfo[] items;
        try { items = new DirectoryInfo(Folder).GetFiles(); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return; }
        long bytes = 0;
        var index = 0;
        foreach (var entry in items.OrderByDescending(f => f.LastWriteTimeUtc))
        {
            bytes += entry.Length;
            if (index >= MaxFiles || bytes > MaxBytes)
            {
                try { entry.Delete(); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            }
            index++;
        }
    }

    public void Purge()
    {
        lock (_gate) _aliases.Clear();
        MemoPaths.DeleteTree(Folder);
    }

    public int FileCount
    {
        get
        {
            try { return Directory.Exists(Folder) ? Directory.GetFileSystemEntries(Folder).Length : 0; }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return 0; }
        }
    }
}

// MARK: - The signed-in account's memo stores

/// The stores for the account that is signed in (one at a time). The app activates it on sign-in and purges it on
/// sign-out; screens read it. `queuedMemoPaths` names the recordings a chat's stashed queue still holds (the Mac's
/// `QueueStash.memoPaths(accountId:)`): the sweep keeps them. Activate and Deactivate from the UI thread.
public sealed class MemoAccountStores(MemoPaths paths, Func<string, IEnumerable<string>>? queuedMemoPaths = null)
{
    public MemoPaths Paths { get; } = paths;
    public string? AccountId { get; private set; }
    public string? Key { get; private set; }
    public MemoDraftStore? Drafts { get; private set; }
    public MemoShapeStore? Shapes { get; private set; }
    public MemoPlaybackCache? Cache { get; private set; }
    /// Bumped on every account change: in-flight work for the previous account is dropped.
    public int Generation { get; private set; }
    /// The sign-in's folder protection and sweep (tests wait for it).
    public Task? SweepTask { get; private set; }

    public void Activate(string accountId)
    {
        if (accountId == AccountId) return;
        Generation++;
        AccountId = accountId;
        var key = MemoPaths.AccountKey(accountId);
        Key = key;
        var drafts = new MemoDraftStore(Paths, key);
        Drafts = drafts;
        Shapes = new MemoShapeStore(Paths, key);
        Cache = new MemoPlaybackCache(Paths, key);
        // Off the UI thread: memos/ and memos/<key>/ are protected (drafts.json and shapes.json hold account and chat
        // ids), and recordings a crash or a kill left behind go once a day old (not a draft's, nor a queued memo's).
        var keep = drafts.Paths.ToHashSet();
        var queued = queuedMemoPaths;
        SweepTask = Task.Run(() =>
        {
            Paths.ExcludeFromBackup(Paths.MemosRoot);
            Paths.ExcludeFromBackup(Paths.Memos(key));
            if (queued != null) keep.UnionWith(queued(accountId));
            Paths.Sweep(key, keep);
        });
    }

    /// Sign-out or an account switch: forget the stores (and, on sign-out, the files).
    public void Deactivate(bool purge)
    {
        Generation++;
        if (purge && AccountId is { } accountId)
        {
            MemoDisk.Flush();
            Paths.Purge(accountId);
        }
        AccountId = null;
        Key = null;
        Drafts = null;
        Shapes = null;
        Cache = null;
    }
}
