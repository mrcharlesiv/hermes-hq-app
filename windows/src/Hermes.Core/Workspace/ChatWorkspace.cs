using System.Text.Json.Nodes;
using Hermes.Core.Net;

namespace Hermes.Core.Workspace;

/// A folder's row.
public sealed record WorkspaceEntry(string Name, string Path, bool IsDirectory);

/// A file read as text; `ByteSize` is the whole file's size ("Showing the first 512 KB of 2.5 MB.").
public sealed record WorkspaceFileText(string Path, string Text, bool Binary, bool Truncated, long? ByteSize = null);

/// An uncommitted change. `Status` is "M", "A", "D", "R", "C", "U" or "?".
public sealed record WorkspaceChange(string Path, long Added, long Removed, string Status, bool Staged)
{
    /// The status in plain words (UX study #116).
    public string StatusName => Status.ToUpperInvariant() switch
    {
        "A" => "Added",
        "D" => "Deleted",
        "R" => "Renamed",
        "C" => "Copied",
        "U" => "Conflict",
        "?" => "New file",
        _ => "Changed",
    };
}

/// A read the gateway answered with its own error words (`{"error": "ENOENT"}`): the Mac's MenusError.
public sealed class WorkspaceReadException(string message) : Exception(message);

/// What the pages read through (the gateway in the app, a stand-in in tests).
public interface IWorkspaceRest
{
    /// GET `path` with `query`; the answer's status and text. Throws GatewayException when the gateway can't be reached.
    Task<(int Status, string Body)> GetAsync(string path, IReadOnlyList<KeyValuePair<string, string>> query, CancellationToken ct);

    /// GET `path` into `file`, streamed, up to `ceiling` bytes. Throws GatewayException ("http", "too-large") on failure.
    Task DownloadToFileAsync(string path, IReadOnlyList<KeyValuePair<string, string>> query, string file, long ceiling,
        CancellationToken ct);
}

/// The gateway's REST lane for the pages.
public sealed class SessionWorkspaceRest(GatewaySession session) : IWorkspaceRest
{
    public async Task<(int Status, string Body)> GetAsync(string path, IReadOnlyList<KeyValuePair<string, string>> query,
        CancellationToken ct)
    {
        var a = await session.SendAsync(HttpMethod.Get, path, query, null, null, ct: ct);
        return (a.Status, a.Body);
    }

    public Task DownloadToFileAsync(string path, IReadOnlyList<KeyValuePair<string, string>> query, string file, long ceiling,
        CancellationToken ct) => session.DownloadToFileAsync(path, query, file, ceiling, null, ct);
}

/// The chat's folder reads, over REST with the bot's profile (HermesKit/Chat/ChatWorkspace.swift, plus the More pages'
/// own reads in App/Pages/More/Workspace/MoreWorkspacePages.swift). Nothing here writes: every request is a GET.
///   Files    GET /api/fs/list?path=<dir>              → {entries:[{name, path, isDirectory}], error?}
///            GET /api/fs/read-text?path=<file>        → {path, text, binary?, truncated?, byteSize?}
///   Changes  GET /api/git/review/list?path=&scope=uncommitted → {files:[{path, added, removed, status, staged}]}
///            GET /api/git/review/diff?path=&file=&scope=uncommitted&staged= → {diff}
///   Root     GET /api/fs/default-cwd, /api/fs/git-root?path=, /api/profiles
public sealed class ChatWorkspace(IWorkspaceRest rest, string? profile)
{
    public string? Profile { get; } = profile is null or "" or "default" ? null : profile;

    /// Paths the web leaves out of Changes (dependency, build and cache folders, OS noise).
    public static readonly HashSet<string> ExcludedChangeParts =
    [
        "node_modules", ".git", "dist", "build", ".next", ".cache", "__pycache__", ".venv", "venv", ".DS_Store", "Pods",
        "DerivedData", ".turbo", "coverage",
    ];

    /// A file Hermes's text read refuses as too large (413), or a download past the limit.
    public sealed class TooLargeException() : Exception("This file is too large to open here.");

    private List<KeyValuePair<string, string>> Query(params (string, string)[] items)
    {
        var o = items.Select(i => new KeyValuePair<string, string>(i.Item1, i.Item2)).ToList();
        if (Profile != null) o.Add(new("profile", Profile));
        return o;
    }

    private async Task<JsonNode> ReadAsync(string path, (string, string)[] items, CancellationToken ct)
    {
        var (status, text) = await rest.GetAsync(path, Query(items), ct);
        if (status == 413) throw new TooLargeException();
        if (status is < 200 or >= 300)
            throw new GatewayException("http", Detail(text) ?? "The gateway couldn’t do that.", status, text);
        return J.Parse(text) ?? throw new GatewayException("not-hermes", "The gateway sent something that isn't JSON.", status);
    }

    /// The `detail` of an error answer, as the Mac's PagesREST.detail.
    public static string? Detail(string body)
    {
        var json = J.Parse(body);
        return json.Text("detail") ?? json.Text("error") ?? json.Text("message");
    }

    /// A folder's entries, folders first, then by name.
    public async Task<List<WorkspaceEntry>> ListAsync(string directory, CancellationToken ct = default)
    {
        var json = await ReadAsync("/api/fs/list", [("path", directory)], ct);
        if (json.Text("error") is { } error) throw new WorkspaceReadException(error);
        var entries = (json.Arr("entries") ?? []).OfType<JsonNode>().Select(e =>
        {
            if (e.Text("name") is not { } name) return null;
            var path = e.Text("path") ?? (directory.EndsWith('/') ? directory : directory + "/") + name;
            return new WorkspaceEntry(name, path, e.Bool("isDirectory") ?? e.Bool("is_directory") ?? false);
        }).OfType<WorkspaceEntry>();
        return Sorted(entries);
    }

    /// Folders first, then by name as the Finder sorts ("file2" before "file10").
    public static List<WorkspaceEntry> Sorted(IEnumerable<WorkspaceEntry> entries) =>
        [.. entries.OrderBy(e => e.IsDirectory ? 0 : 1).ThenBy(e => e.Name, NaturalComparer.Instance)];

    public async Task<WorkspaceFileText> ReadTextAsync(string path, CancellationToken ct = default)
    {
        var json = await ReadAsync("/api/fs/read-text", [("path", path)], ct);
        return new WorkspaceFileText(json.Text("path") ?? path, json.Str("text") ?? "", json.Bool("binary") ?? false,
            json.Bool("truncated") ?? false, json.Int("byteSize") ?? json.Int("byte_size"));
    }

    /// Uncommitted changes in a folder.
    public async Task<List<WorkspaceChange>> ChangesAsync(string directory, CancellationToken ct = default)
    {
        var json = await ReadAsync("/api/git/review/list", [("path", directory), ("scope", "uncommitted")], ct);
        if (json.Text("error") is { } error) throw new WorkspaceReadException(error);
        return [.. (json.Arr("files") ?? []).OfType<JsonNode>().Select(f => f.Text("path") is { } p
                ? new WorkspaceChange(p, f.Int("added") ?? 0, f.Int("removed") ?? 0, f.Str("status") ?? "M", f.Bool("staged") ?? false)
                : null)
            .OfType<WorkspaceChange>().Where(c => !Excluded(c.Path))];
    }

    public static bool Excluded(string path) => path.Split('/').Any(ExcludedChangeParts.Contains);

    public async Task<string> DiffAsync(string directory, WorkspaceChange file, CancellationToken ct = default)
    {
        var json = await ReadAsync("/api/git/review/diff",
            [("path", directory), ("file", file.Path), ("scope", "uncommitted"), ("staged", file.Staged ? "true" : "false")], ct);
        return json.Str("diff") ?? "";
    }

    /// The gateway's own default folder (`GET /api/fs/default-cwd`), the root's last choice.
    public async Task<string?> DefaultCwdAsync(CancellationToken ct = default) =>
        (await ReadAsync("/api/fs/default-cwd", [], ct)).Str("cwd");

    /// The repository `path` is in; null when it isn't in one or the gateway can't say.
    public async Task<string?> GitRootAsync(string path, CancellationToken ct = default)
    {
        try { return (await ReadAsync("/api/fs/git-root", [("path", path)], ct)).Text("root"); }
        catch (Exception e) when (e is not OperationCanceledException) { return null; }
    }

    /// Whether `path` is inside a repository: null when the gateway cannot say.
    public async Task<bool?> IsRepositoryAsync(string path, CancellationToken ct = default)
    {
        try
        {
            var json = await ReadAsync("/api/fs/git-root", [("path", path)], ct);
            if (json is not JsonObject o || !o.ContainsKey("root")) return null;
            return json.Text("root") != null;
        }
        catch (Exception e) when (e is not OperationCanceledException) { return null; }
    }

    /// The gateway user's home ("~" in paths), from `GET /api/profiles`; null when unknown.
    public async Task<string?> HomeAsync(CancellationToken ct = default)
    {
        try
        {
            var (status, body) = await rest.GetAsync("/api/profiles", [], ct);
            return status is >= 200 and < 300 ? WorkspaceRoot.GatewayHome(J.Parse(body)) : null;
        }
        catch (Exception e) when (e is not OperationCanceledException) { return null; }
    }

    /// The most a file is fetched whole (the Mac's chat file card limit, `MediaLoader.fileCeiling`).
    public const long FileCeiling = 512L << 20;

    /// A file fetched into `file`, streamed (Save As…, opening a file that isn't text, a text file shown only in part).
    public async Task DownloadAsync(string path, string file, CancellationToken ct = default)
    {
        try { await rest.DownloadToFileAsync("/api/fs/download", Query(("path", path)), file, FileCeiling, ct); }
        catch (GatewayException e) when (e.Code == "too-large" || e.Status == 413) { throw new TooLargeException(); }
        catch (GatewayException e) when (e.Code == "http" && e.Body is { } body && Detail(body) is { } detail)
        {
            throw new GatewayException("http", detail, e.Status, body);
        }
    }

    /// The words for a read that failed (the Mac's PagesREST.reason, the too-large words for a 413).
    public static string Reason(Exception e) => e switch
    {
        TooLargeException => "This file is too large to open here.",
        WorkspaceReadException r => r.Message,
        GatewayException { Status: 404 or 405 } => "Not available on this Hermes. Updating Hermes may add it.",
        GatewayException g => g.Message,
        OperationCanceledException => "Cancelled.",
        _ => "The gateway couldn’t do that.",
    };
}

/// Names compared as the Finder (localizedStandardCompare): case-insensitive, runs of digits by value.
public sealed class NaturalComparer : IComparer<string>
{
    public static readonly NaturalComparer Instance = new();

    public int Compare(string? a, string? b)
    {
        a ??= ""; b ??= "";
        int i = 0, j = 0;
        while (i < a.Length && j < b.Length)
        {
            if (char.IsDigit(a[i]) && char.IsDigit(b[j]))
            {
                int si = i, sj = j;
                while (i < a.Length && char.IsDigit(a[i])) i++;
                while (j < b.Length && char.IsDigit(b[j])) j++;
                var na = a[si..i].TrimStart('0'); var nb = b[sj..j].TrimStart('0');
                if (na.Length != nb.Length) return na.Length.CompareTo(nb.Length);
                var c = string.CompareOrdinal(na, nb);
                if (c != 0) return c;
                continue;
            }
            var x = string.Compare(a[i].ToString(), b[j].ToString(), StringComparison.CurrentCultureIgnoreCase);
            if (x != 0) return x;
            i++; j++;
        }
        var rest = (a.Length - i).CompareTo(b.Length - j);
        return rest != 0 ? rest : string.CompareOrdinal(a, b);
    }
}
