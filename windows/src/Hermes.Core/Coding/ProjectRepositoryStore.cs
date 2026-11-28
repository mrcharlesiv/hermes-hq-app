using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Composer;
using Hermes.Core.Kanban;
using Hermes.Core.Net;
using Hermes.Core.Sessions;

namespace Hermes.Core.Coding;

/// Linked repository record kept by the gateway add-on (`SessionPRRepo` in `HermesKit/Contracts.swift`).
public sealed record SessionPRRepo(
    string Project,
    string Path,
    string Main = "main",
    string? PublicRepo = null,
    bool Mirror = false)
{
    public static SessionPRRepo? From(JsonNode? node)
    {
        if (node is not JsonObject) return null;
        var project = node.Text("project");
        var path = node.Text("path");
        if (project == null || path == null) return null;
        return new SessionPRRepo(
            Project: project,
            Path: path,
            Main: node.Text("main") ?? "main",
            PublicRepo: node.Text("public_repo"),
            Mirror: node.Bool("mirror") ?? false);
    }

    public JsonObject Wire()
    {
        var o = new JsonObject
        {
            ["project"] = Project,
            ["path"] = Path,
            ["main"] = string.IsNullOrWhiteSpace(Main) ? "main" : Main.Trim(),
            ["mirror"] = Mirror,
        };
        if (!string.IsNullOrWhiteSpace(PublicRepo)) o["public_repo"] = PublicRepo.Trim();
        return o;
    }
}

public enum SessionPRReposState
{
    Idle,
    Loading,
    Ready,
    Unsupported,
    Failed,
}

/// Folder choices offered by ProjectRepositoryPage (`SessionStore+PRManage.swift` `repositoryFolderChoices`).
public sealed record RepositoryFolderChoiceSet(
    IReadOnlyList<string> Here,
    IReadOnlyList<string> Elsewhere);

public enum SessionPRRepoErrorKind
{
    NotARepository,
    InvalidPublicRepo,
    Offline,
    OlderAddOn,
    Other,
}

public sealed class SessionPRRepoException(SessionPRRepoErrorKind kind, string message) : Exception(message)
{
    public SessionPRRepoErrorKind Kind { get; } = kind;
}

/// Notification rule for a project (`ProjectSettingsPage.swift`).
public enum ProjectNotifyMode
{
    All,
    NeedsMe,
    Mute,
}

/// Auto-archive rule for quiet or merged chats in a project.
public sealed record ProjectAutoDone(int? Days = null, bool OnMerge = false);

/// Visual appearance of a project (`ProjectIconGuide.swift` + `ProjectSettingsPage.swift`).
public sealed record ProjectLook(string? Emoji = null, string? Color = null, bool ShowBranchOnRows = true);

/// Default model/reasoning overrides for new chats in a project.
public sealed record ProjectNewChatDefaults(string? Model = null, string? Reasoning = null);

/// Per-project settings persisted locally (`ProjectSettingsPage.swift`).
public sealed record ProjectSettings(string ProjectKey)
{
    public bool KeepChatsInProject { get; init; } = true;
    public bool PinsStayInProject { get; init; } = true;
    public ProjectAutoDone AutoDone { get; init; } = new();
    public bool CodingProject { get; init; }
    public ProjectNotifyMode Notify { get; init; } = ProjectNotifyMode.All;
    public ProjectNewChatDefaults NewChat { get; init; } = new();
    public ProjectLook Look { get; init; } = new();

    public JsonObject ToJson() => new()
    {
        ["project_key"] = ProjectKey,
        ["keep_chats"] = KeepChatsInProject,
        ["pins_stay"] = PinsStayInProject,
        ["auto_done_days"] = AutoDone.Days,
        ["auto_done_merge"] = AutoDone.OnMerge,
        ["coding"] = CodingProject,
        ["notify"] = Notify.ToString().ToLowerInvariant(),
        ["model"] = NewChat.Model,
        ["reasoning"] = NewChat.Reasoning,
        ["emoji"] = Look.Emoji,
        ["color"] = Look.Color,
        ["show_branch"] = Look.ShowBranchOnRows,
    };

    public static ProjectSettings FromJson(string projectKey, JsonNode? node)
    {
        if (node is not JsonObject) return new ProjectSettings(projectKey);
        var notify = (node.Str("notify")?.ToLowerInvariant()) switch
        {
            "needsme" => ProjectNotifyMode.NeedsMe,
            "mute" => ProjectNotifyMode.Mute,
            _ => ProjectNotifyMode.All,
        };
        return new ProjectSettings(projectKey)
        {
            KeepChatsInProject = node.Bool("keep_chats") ?? true,
            PinsStayInProject = node.Bool("pins_stay") ?? true,
            AutoDone = new ProjectAutoDone(
                Days: node.Int("auto_done_days") is { } d and > 0 ? (int)d : null,
                OnMerge: node.Bool("auto_done_merge") ?? false),
            CodingProject = node.Bool("coding") ?? false,
            Notify = notify,
            NewChat = new ProjectNewChatDefaults(node.Text("model"), node.Text("reasoning")),
            Look = new ProjectLook(node.Text("emoji"), node.Text("color"), node.Bool("show_branch") ?? true),
        };
    }
}

/// Pure helpers for normalizing repository paths, `owner/repo` slugs, and project icon swatches.
public static partial class RepoPathHelpers
{
    [GeneratedRegex(@"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")]
    private static partial Regex OwnerRepoRegex();

    /// Available project accent swatches (`ProjectIconGuide.swift`).
    public static readonly IReadOnlyList<(string Key, string Label, byte R, byte G, byte B)> Swatches =
    [
        ("blue", "Blue", 0x0A, 0x84, 0xFF),
        ("green", "Green", 0x30, 0xB9, 0x4D),
        ("orange", "Orange", 0xFF, 0x9F, 0x0A),
        ("purple", "Purple", 0xAF, 0x52, 0xDE),
        ("pink", "Pink", 0xFF, 0x2D, 0x55),
        ("teal", "Teal", 0x30, 0xB0, 0xC7),
        ("red", "Red", 0xFF, 0x3B, 0x30),
        ("gray", "Graphite", 0x8E, 0x8E, 0x93),
    ];

    /// Suggested icon presets (`ProjectIconGuide.swift`).
    public static readonly IReadOnlyList<(string Emoji, string Label)> IconPresets =
    [
        ("🚀", "Shipping"),
        ("🛠️", "Tools"),
        ("📦", "Package"),
        ("🧪", "Tests"),
        ("🌐", "Web"),
        ("📱", "App"),
        ("⚡", "Runtime"),
        ("🔒", "Security"),
    ];

    /// Normalizes `https://github.com/owner/repo.git`, `git@github.com:owner/repo.git`, or `owner/repo` into `owner/repo`.
    /// Returns null if blank or invalid.
    public static string? NormalizePublicRepo(string? input)
    {
        if (string.IsNullOrWhiteSpace(input)) return null;
        var s = input.Trim();

        if (s.StartsWith("ssh://git@github.com/", StringComparison.OrdinalIgnoreCase))
            s = s["ssh://git@github.com/".Length..];
        else if (s.StartsWith("git@github.com:", StringComparison.OrdinalIgnoreCase))
            s = s["git@github.com:".Length..];
        else if (s.StartsWith("https://github.com/", StringComparison.OrdinalIgnoreCase))
            s = s["https://github.com/".Length..];
        else if (s.StartsWith("http://github.com/", StringComparison.OrdinalIgnoreCase))
            s = s["http://github.com/".Length..];
        else if (s.StartsWith("github.com/", StringComparison.OrdinalIgnoreCase))
            s = s["github.com/".Length..];

        s = s.Trim('/');
        if (s.EndsWith(".git", StringComparison.OrdinalIgnoreCase))
            s = s[..^4];

        // Drop trailing path segments like /pulls or /tree/main if pasted from a browser URL.
        var parts = s.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2) return null;
        var slug = $"{parts[0]}/{parts[1]}";
        return OwnerRepoRegex().IsMatch(slug) ? slug : null;
    }

    public static bool IsValidPublicRepo(string? input) => NormalizePublicRepo(input) != null;

    public static string NormalizeFolderPath(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return "";
        var clean = path.Trim();
        while (clean.Length > 1 && (clean.EndsWith('/') || clean.EndsWith('\\')))
            clean = clean[..^1];
        return clean;
    }

    /// True for Unix (`/Users/...`) or Windows (`C:\...`, `C:/...`) absolute folder paths.
    public static bool IsAbsoluteFolderPath(string? path)
    {
        var clean = NormalizeFolderPath(path);
        if (clean.Length == 0) return false;
        if (clean.StartsWith('/')) return true;
        return clean.Length >= 3 && char.IsLetter(clean[0]) && clean[1] == ':' && (clean[2] == '\\' || clean[2] == '/');
    }

    /// A folder's own leaf name (`"app"` for `/Users/me/Projects/app`, matching `SessionStore.folderName`).
    public static string FolderName(string path)
    {
        var clean = NormalizeFolderPath(path);
        if (clean.Length == 0) return path;
        var sep = Math.Max(clean.LastIndexOf('/'), clean.LastIndexOf('\\'));
        if (sep < 0 || sep == clean.Length - 1) return clean;
        return clean[(sep + 1)..];
    }

    /// The parent folder of `path`, or empty string when at root.
    public static string ParentFolder(string path)
    {
        var clean = NormalizeFolderPath(path);
        var sep = Math.Max(clean.LastIndexOf('/'), clean.LastIndexOf('\\'));
        return sep > 0 ? clean[..sep] : "";
    }

    /// Shortens `/Users/<name>/...` and `/home/<name>/...` to `~/...` (`ProjectPageHeader.shortFolder`).
    public static string ShortFolder(string? path)
    {
        if (string.IsNullOrWhiteSpace(path) || path.StartsWith("id:", StringComparison.Ordinal)) return "";
        var clean = NormalizeFolderPath(path);
        if (clean.StartsWith("/Users/", StringComparison.Ordinal) || clean.StartsWith("/home/", StringComparison.Ordinal))
        {
            var parts = clean.Split('/', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length >= 2)
                return parts.Length == 2 ? "~" : "~/" + string.Join('/', parts.Skip(2));
        }
        return clean;
    }
}

/// REST client for the gateway add-on's PR status and repository endpoints (`hermes-hq-push`).
public sealed class CodingApi(IPagesRest rest)
{
    public const string Base = "/api/plugins/hermes-hq-push/sessions";
    public IPagesRest Rest { get; } = rest;

    /// `POST /api/plugins/hermes-hq-push/sessions/pr-status`
    public async Task<Dictionary<string, SessionPRStatus>> FetchPRStatusAsync(
        IReadOnlyList<(string Profile, string SessionId)> sessions,
        bool fresh = false,
        bool detail = false,
        CancellationToken ct = default)
    {
        var result = new Dictionary<string, SessionPRStatus>(StringComparer.Ordinal);
        if (sessions.Count == 0) return result;

        var body = new JsonObject
        {
            ["sessions"] = new JsonArray([.. sessions.Select(s => (JsonNode)new JsonObject
            {
                ["profile"] = s.Profile,
                ["id"] = s.SessionId,
            })]),
        };
        if (fresh) body["fresh"] = true;
        if (detail && sessions.Count <= 4) body["detail"] = true;

        var json = await Rest.JsonAsync(HttpMethod.Post, Base + "/pr-status", body: body, ct: ct);
        if (json.Obj("statuses") is { } map)
        {
            foreach (var (key, value) in map)
                result[key] = PRFacts.ParseStatus(value);
        }
        else if (json.Arr("items") is { } list)
        {
            foreach (var item in list)
            {
                var profile = item.Text("profile");
                var id = item.Text("id");
                if (profile != null && id != null)
                    result[$"{profile}:{id}"] = PRFacts.ParseStatus(item.Get("status") ?? item);
            }
        }
        return result;
    }

    /// `GET /api/plugins/hermes-hq-push/sessions/pr-repos`
    public async Task<IReadOnlyList<SessionPRRepo>> ListReposAsync(CancellationToken ct = default)
    {
        var json = await Rest.JsonAsync(HttpMethod.Get, Base + "/pr-repos", ct: ct);
        var arr = json.Arr("repos") ?? json as JsonArray ?? [];
        return [.. arr.Select(SessionPRRepo.From).OfType<SessionPRRepo>()];
    }

    /// `PUT /api/plugins/hermes-hq-push/sessions/pr-repos`
    public async Task<SessionPRRepo> SaveRepoAsync(SessionPRRepo repo, CancellationToken ct = default)
    {
        try
        {
            var json = await Rest.JsonAsync(HttpMethod.Put, Base + "/pr-repos", body: repo.Wire(), ct: ct);
            return SessionPRRepo.From(json.Get("repo") ?? json) ?? repo;
        }
        catch (Exception e)
        {
            throw ClassifyRepoError(e);
        }
    }

    /// `DELETE /api/plugins/hermes-hq-push/sessions/pr-repos?project=...`
    public async Task DeleteRepoAsync(string project, CancellationToken ct = default)
    {
        try
        {
            await Rest.JsonAsync(HttpMethod.Delete, Base + "/pr-repos",
                query: [new("project", project)], ct: ct);
        }
        catch (Exception e)
        {
            throw ClassifyRepoError(e);
        }
    }

    /// `PUT /api/plugins/hermes-hq-push/sessions/pr-mark` (`{profile, id, closed}`)
    public async Task<SessionPRStatus?> MarkClosedAsync(string profile, string sessionId, bool closed, CancellationToken ct = default)
    {
        var body = new JsonObject
        {
            ["profile"] = profile,
            ["id"] = sessionId,
            ["closed"] = closed,
        };
        var json = await Rest.JsonAsync(HttpMethod.Put, Base + "/pr-mark", body: body, ct: ct);
        return json != null ? PRFacts.ParseStatus(json.Get("status") ?? json) : null;
    }

    private static SessionPRRepoException ClassifyRepoError(Exception e)
    {
        if (KanbanRest.IsUnknownRoute(e))
            return new SessionPRRepoException(SessionPRRepoErrorKind.OlderAddOn, KanbanRest.OlderHermes);
        if (e is GatewayException { Code: "http" } g)
        {
            var code = J.Parse(g.Body ?? "").Str("error") ?? J.Parse(g.Body ?? "").Str("code") ?? "";
            if (code == "not_a_repository")
                return new SessionPRRepoException(SessionPRRepoErrorKind.NotARepository, "That folder isn’t a Git repository.");
            if (code == "invalid_public_repo")
                return new SessionPRRepoException(SessionPRRepoErrorKind.InvalidPublicRepo, "Enter the repository as owner/repo (for example, acme/widget).");
            return new SessionPRRepoException(SessionPRRepoErrorKind.Other, KanbanRest.Reason(e));
        }
        if (e is GatewayException { Code: "offline" or "timeout" } or HttpRequestException)
            return new SessionPRRepoException(SessionPRRepoErrorKind.Offline, KanbanRest.CantReach);
        return new SessionPRRepoException(SessionPRRepoErrorKind.Other, KanbanRest.Reason(e));
    }
}

/// Stateful cache for PR statuses, linked project repositories, and per-project coding settings.
public sealed class CodingStore(CodingApi? api, IKeyValueStore? prefs = null)
{
    private readonly Dictionary<string, SessionPRStatus> _statuses = new(StringComparer.Ordinal);
    private readonly Dictionary<string, DateTimeOffset> _refreshedAt = new(StringComparer.Ordinal);
    private readonly Dictionary<string, SessionPRRepo> _repos = new(StringComparer.Ordinal);
    private readonly Dictionary<string, ProjectSettings> _settings = new(StringComparer.Ordinal);
    private readonly HashSet<string> _prAutoLinkFailed = new(StringComparer.Ordinal);

    public CodingApi? Api { get; } = api;
    public SessionPRReposState ReposState { get; private set; } = SessionPRReposState.Idle;
    public string? ReposError { get; private set; }
    public bool IsManageAvailable => ReposState is SessionPRReposState.Ready or SessionPRReposState.Failed || _repos.Count > 0;
    public bool IsPRRouteUnsupported => ReposState == SessionPRReposState.Unsupported;

    public event Action? Changed;

    public IReadOnlyDictionary<string, SessionPRStatus> Statuses => _statuses;
    public IReadOnlyDictionary<string, SessionPRRepo> Repos => _repos;
    /// Projects whose automatic own-folder link returned `not_a_repository` (`SessionStore.prAutoLinkFailed`).
    public IReadOnlySet<string> PrAutoLinkFailed => _prAutoLinkFailed;

    public bool HasAutoLinkFailed(string projectKey) => _prAutoLinkFailed.Contains(projectKey);

    public SessionPRStatus? StatusFor(string sessionKey)
    {
        if (_statuses.TryGetValue(sessionKey, out var status)) return status;
        var alt = AlternateSessionKey(sessionKey);
        return alt != null && _statuses.TryGetValue(alt, out status) ? status : null;
    }

    public SessionPRStatus? StatusFor(string profile, string sessionId) =>
        StatusFor($"{profile}:{sessionId}") ?? StatusFor($"{profile}\u001F{sessionId}");

    public DateTimeOffset? RefreshedAt(string sessionKey)
    {
        if (_refreshedAt.TryGetValue(sessionKey, out var at)) return at;
        var alt = AlternateSessionKey(sessionKey);
        return alt != null && _refreshedAt.TryGetValue(alt, out at) ? at : null;
    }

    private static string? AlternateSessionKey(string sessionKey)
    {
        if (sessionKey.Contains('\u001F')) return sessionKey.Replace('\u001F', ':');
        var idx = sessionKey.IndexOf(':');
        return idx > 0 ? string.Concat(sessionKey.AsSpan(0, idx), "\u001F", sessionKey.AsSpan(idx + 1)) : null;
    }

    public SessionPRRepo? RepoFor(string projectKey) =>
        _repos.TryGetValue(projectKey, out var repo) ? repo : null;

    public void PutStatus(string sessionKey, SessionPRStatus status, DateTimeOffset? at = null)
    {
        _statuses[sessionKey] = status;
        _refreshedAt[sessionKey] = at ?? DateTimeOffset.UtcNow;
        Changed?.Invoke();
    }

    public ProjectSettings SettingsFor(string projectKey)
    {
        if (_settings.TryGetValue(projectKey, out var cached)) return cached;
        ProjectSettings loaded = new(projectKey);
        if (prefs?.Get(SettingsStorageKey(projectKey)) is { Length: > 0 } raw && J.Parse(raw) is { } node)
            loaded = ProjectSettings.FromJson(projectKey, node);
        if (_repos.ContainsKey(projectKey) && !loaded.CodingProject)
            loaded = loaded with { CodingProject = true };
        _settings[projectKey] = loaded;
        return loaded;
    }

    public void SaveSettings(ProjectSettings settings)
    {
        _settings[settings.ProjectKey] = settings;
        prefs?.Set(SettingsStorageKey(settings.ProjectKey), settings.ToJson().ToJsonString());
        Changed?.Invoke();
    }

    public async Task RefreshPRStatusAsync(
        IReadOnlyList<(string Profile, string SessionId)> sessions,
        bool fresh = false,
        bool detail = false,
        CancellationToken ct = default)
    {
        if (Api == null || sessions.Count == 0) return;
        try
        {
            var fetched = await Api.FetchPRStatusAsync(sessions, fresh, detail, ct);
            var now = DateTimeOffset.UtcNow;
            foreach (var (key, status) in fetched)
            {
                _statuses[key] = status;
                _refreshedAt[key] = now;
            }
            Changed?.Invoke();
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            var reason = KanbanRest.IsUnknownRoute(e) ? SessionPRUnknownReason.Unsupported : SessionPRUnknownReason.Unavailable;
            foreach (var (profile, id) in sessions)
            {
                var key = $"{profile}:{id}";
                if (!_statuses.ContainsKey(key))
                    _statuses[key] = new SessionPRStatus(SessionPRState.Unknown, reason);
            }
            Changed?.Invoke();
        }
    }

    public async Task RefreshReposAsync(CancellationToken ct = default)
    {
        if (Api == null) return;
        ReposState = SessionPRReposState.Loading;
        ReposError = null;
        Changed?.Invoke();
        try
        {
            var list = await Api.ListReposAsync(ct);
            _repos.Clear();
            foreach (var r in list) _repos[r.Project] = r;
            ReposState = SessionPRReposState.Ready;
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            ReposState = KanbanRest.IsUnknownRoute(e) ? SessionPRReposState.Unsupported : SessionPRReposState.Failed;
            ReposError = KanbanRest.Reason(e);
        }
        Changed?.Invoke();
    }

    public async Task<SessionPRRepo> LinkRepoAsync(SessionPRRepo repo, CancellationToken ct = default)
    {
        var saved = Api != null ? await Api.SaveRepoAsync(repo, ct) : repo;
        _repos[saved.Project] = saved;
        ReposState = SessionPRReposState.Ready;
        _prAutoLinkFailed.Remove(saved.Project);
        var current = SettingsFor(saved.Project);
        if (!current.CodingProject) SaveSettings(current with { CodingProject = true });
        else Changed?.Invoke();
        return saved;
    }

    public async Task UnlinkRepoAsync(string projectKey, CancellationToken ct = default)
    {
        if (Api != null) await Api.DeleteRepoAsync(projectKey, ct);
        _repos.Remove(projectKey);
        _prAutoLinkFailed.Remove(projectKey);
        Changed?.Invoke();
    }

    /// Offers repository folder choices for `projectKey` (`SessionStore+PRManage.swift` `repositoryFolderChoices`):
    /// `Here` holds repositories discovered in this project (starting with any linked folder, or the project's own
    /// folder if none); `Elsewhere` holds every other known repository across projects and linked gateway repos,
    /// sorted by folder name.
    public RepositoryFolderChoiceSet RepositoryFolderChoices(
        string projectKey,
        IReadOnlyDictionary<string, List<SessionProject>>? projectsByProfile = null,
        string? fallbackRootFolder = null)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        string? Fresh(string? path)
        {
            var tidy = RepoPathHelpers.NormalizeFolderPath(path);
            return RepoPathHelpers.IsAbsoluteFolderPath(tidy) && seen.Add(tidy) ? tidy : null;
        }

        var here = new List<string>();
        var elsewhere = new List<string>();

        if (projectsByProfile != null)
        {
            foreach (var (profile, projects) in projectsByProfile.OrderBy(kv => kv.Key, StringComparer.Ordinal))
            {
                foreach (var project in projects)
                {
                    if (!string.Equals(SessionProjects.KeyOf(project, profile), projectKey, StringComparison.Ordinal))
                        continue;
                    foreach (var p in project.Paths)
                        if (Fresh(p) is { } hit) here.Add(hit);
                    if (Fresh(project.Root) is { } rootHit) here.Add(rootHit);
                }
            }
        }

        if (RepoFor(projectKey)?.Path is { } linked && Fresh(linked) is { } linkedPath)
            here.Insert(0, linkedPath);
        if (here.Count == 0 && Fresh(projectKey) is { } own)
            here.Add(own);
        if (here.Count == 0 && Fresh(fallbackRootFolder) is { } fallback)
            here.Add(fallback);

        if (projectsByProfile != null)
        {
            foreach (var (_, projects) in projectsByProfile.OrderBy(kv => kv.Key, StringComparer.Ordinal))
            {
                foreach (var project in projects)
                {
                    foreach (var p in project.Paths)
                        if (Fresh(p) is { } hit) elsewhere.Add(hit);
                    if (Fresh(project.Root) is { } rootHit) elsewhere.Add(rootHit);
                }
            }
        }

        foreach (var repo in _repos.Values)
            if (Fresh(repo.Path) is { } hit) elsewhere.Add(hit);

        elsewhere.Sort((a, b) =>
        {
            var cmp = NumericComparer.Instance.Compare(RepoPathHelpers.FolderName(a), RepoPathHelpers.FolderName(b));
            return cmp != 0 ? cmp : StringComparer.Ordinal.Compare(a, b);
        });

        return new RepositoryFolderChoiceSet(here, elsewhere);
    }

    /// Suggested `owner/repo` choices from already linked repos and observed PR statuses (`SessionStore+PRManage.swift`).
    public IReadOnlyList<string> PublicRepoChoices()
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var outList = new List<string>();
        void Collect(string? raw)
        {
            if (RepoPathHelpers.NormalizePublicRepo(raw) is { } slug && seen.Add(slug))
                outList.Add(slug);
        }

        foreach (var repo in _repos.Values) Collect(repo.PublicRepo);
        foreach (var status in _statuses.Values)
        {
            Collect(status.Repo);
            foreach (var item in status.AllItems) Collect(item.Repo);
        }

        outList.Sort(NumericComparer.Instance);
        return outList;
    }

    /// Turning Coding Project on for a folder-backed project (`SessionStore+PRManage.swift` `linkOwnFolderIfUnlinked`):
    /// awaits `RefreshReposAsync` when needed, then tries linking the project's own folder. Records `PrAutoLinkFailed`
    /// only when the gateway answers `not_a_repository`, leaving transient failures unflagged.
    public async Task<bool> LinkOwnFolderIfUnlinkedAsync(string projectKey, string? folderPath = null, CancellationToken ct = default)
    {
        var candidate = RepoPathHelpers.NormalizeFolderPath(folderPath ?? projectKey);
        if (!RepoPathHelpers.IsAbsoluteFolderPath(candidate) || ReposState == SessionPRReposState.Unsupported || Api == null)
            return false;

        if (ReposState is SessionPRReposState.Idle or SessionPRReposState.Failed)
            await RefreshReposAsync(ct);

        if (ReposState != SessionPRReposState.Ready) return false;
        if (!SettingsFor(projectKey).CodingProject || RepoFor(projectKey) != null) return false;

        try
        {
            await LinkRepoAsync(new SessionPRRepo(projectKey, candidate), ct);
            return true;
        }
        catch (SessionPRRepoException ex) when (ex.Kind == SessionPRRepoErrorKind.NotARepository)
        {
            if (_prAutoLinkFailed.Add(projectKey)) Changed?.Invoke();
            return false;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return false;
        }
    }

    public async Task<bool> MarkClosedAsync(string profile, string sessionId, bool closed, CancellationToken ct = default)
    {
        var key = $"{profile}:{sessionId}";
        if (Api == null)
        {
            var existing = StatusFor(key) ?? new SessionPRStatus(SessionPRState.Open);
            PutStatus(key, existing with { State = closed ? SessionPRState.Closed : SessionPRState.Open, Manual = closed });
            return true;
        }
        var updated = await Api.MarkClosedAsync(profile, sessionId, closed, ct);
        if (updated != null) PutStatus(key, updated);
        return updated != null;
    }

    private static string SettingsStorageKey(string projectKey) => "project.settings." + projectKey;
}
