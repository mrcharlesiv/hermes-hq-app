using Hermes.Core.Net;

namespace Hermes.Core.Artifacts;

/// The Artifacts page's data (docs/spec/1x-pages.md §5; HermesKit/Pages/ArtifactsStore.swift): the index's kept
/// artifacts painted at once, then a pass over each profile's 50 most recent sessions (3 profiles at a time when the
/// scope is All Bots and there are ≥ 2 bots), reading only sessions that changed; older chats read before keep their
/// artifacts (up to 300 chats). Never off screen: on the page's first show, on later shows when the last pass is
/// > 60 s old, and on Refresh. Files the gateway can't find collect under Unavailable.
///
/// Use it from one thread (the UI's): its callbacks come back on the caller's synchronization context.
public sealed class ArtifactsStore
{
    public const int WindowSize = 50;
    public const int Retain = 300;
    public static readonly TimeSpan StaleAfter = TimeSpan.FromSeconds(60);
    public const string All = "all";

    private readonly IArtifactSource _source;
    private int _passGeneration;
    private CancellationTokenSource? _pass;
    private bool _prepared;

    public ArtifactIndex Index { get; }
    /// What the owner removed: never listed.
    public ArtifactHidden Hidden { get; }
    /// "all" or a profile name.
    public string Scope { get; private set; }
    /// Every profile name the roster knows (for the per-profile listing), read when a pass starts.
    public Func<IReadOnlyList<string>> ProfilesProvider { get; set; } = () => [];
    /// A profile's display name ("default" → "Hermes").
    public Func<string, string> DisplayName { get; set; } = p => p == "default" ? "Hermes" : p;
    /// What the page lists, newest first, one per [profile, session, kind, value, href].
    public IReadOnlyList<ArtifactRecord> Artifacts { get; private set; } = [];
    /// Artifacts in hand (null before the first pass when nothing was kept).
    public int? Loaded { get; private set; }
    public bool Refreshing { get; private set; }
    public string? LoadError { get; private set; }
    public DateTime? LastPass { get; private set; }
    /// Files and images the gateway couldn't find or place this run (in memory; Refresh clears it).
    public HashSet<string> Unavailable { get; } = [];
    /// The wait before a failed listing is asked once more (tests shorten it).
    public TimeSpan RetryDelay { get; set; } = TimeSpan.FromSeconds(1);

    public event Action? Changed;
    /// A notice for some seconds ("Skipped 2 of 30 recent sessions…", "Couldn’t list Ivy’s chats…").
    public event Action<string, TimeSpan>? Notice;
    /// Sessions read again in a pass: their image previews kept from before are read again.
    public event Action<IReadOnlyList<ArtifactSessionRow>>? SessionsRead;

    public ArtifactsStore(IArtifactSource source, string? indexFile, ArtifactHidden hidden, string scope = All)
    {
        _source = source;
        Hidden = hidden;
        Scope = scope;
        Index = new ArtifactIndex(indexFile);
        // A Remove anywhere leaves every list at once.
        Hidden.Changed += HiddenChanged;
    }

    private void HiddenChanged()
    {
        var before = Artifacts.Count;
        Artifacts = Hidden.Visible(Artifacts);
        if (Artifacts.Count != before) Changed?.Invoke();
    }

    public IArtifactSource Source => _source;

    /// The page is about to draw: paint from the kept index. Nothing is read before.
    public void Prepare()
    {
        if (_prepared) return;
        _prepared = true;
        Index.Prepare();
        PaintFromIndex();
    }

    private bool InScope(ArtifactRecord record) => Scope == All || (record.Profile ?? "default") == Scope;

    private void PaintFromIndex()
    {
        if (!Index.IsLoaded) { Artifacts = []; Loaded = null; return; }
        var entries = Index.Entries;
        var kept = entries.Values.SelectMany(e => e.Artifacts).Where(InScope);
        Artifacts = Hidden.Visible(ArtifactCollector.Unique(kept));
        Loaded = entries.Count == 0 ? null : Artifacts.Count;
    }

    /// A scope change repaints from the index; a pass for the new scope starts only from `PageShown()` or a Refresh.
    public void SetScope(string next)
    {
        if (next == Scope) return;
        Scope = next;
        _passGeneration++;
        _pass?.Cancel();
        Refreshing = false;
        LoadError = null;
        LastPass = null;
        PaintFromIndex();
        Changed?.Invoke();
    }

    /// The page came on screen: a pass on its first show, then when the last one is over a minute old.
    public void PageShown()
    {
        Prepare();
        if (Refreshing) return;
        if (LastPass is { } last && DateTime.UtcNow - last < StaleAfter) return;
        _ = RefreshAsync(explicit_: false);
    }

    /// `explicit_`: a Refresh (clears Unavailable, so missing files get another try).
    public Task RefreshAsync(bool explicit_)
    {
        if (explicit_) Unavailable.Clear();
        if (Refreshing && !explicit_) return Task.CompletedTask;
        _pass?.Cancel();
        _pass = new CancellationTokenSource();
        var generation = ++_passGeneration;
        Refreshing = true;
        Changed?.Invoke();
        return RunPassAsync(generation, _pass.Token);
    }

    private async Task RunPassAsync(int generation, CancellationToken ct)
    {
        var scope = Scope;
        try
        {
            Listing listing;
            try { listing = await ListSessionsAsync(scope, ct); }
            catch (Exception e) when (ShouldRetry(e))
            {
                await Task.Delay(RetryDelay, ct);
                listing = await ListSessionsAsync(scope, ct);
            }
            if (generation != _passGeneration) return;
            if (listing.FailedNames.Count > 0) Notice?.Invoke(ArtifactPageWords.ListingFailed(listing.FailedNames), TimeSpan.FromSeconds(10));
            var source = _source;
            var result = await Index.RunAsync(listing.Sessions, (s, c) => ArtifactReads.SessionAsync(source, s, c),
                listing.Listed, listing.Failed, Retain, listing.PerProfile ? WindowSize : 0,
                onProgress: found => { if (generation == _passGeneration) Show(found); }, ct: ct);
            if (generation != _passGeneration) return;
            Show(result.Artifacts);
            Loaded = Artifacts.Count;
            LoadError = null;
            if (result.Read.Count > 0) SessionsRead?.Invoke(result.Read);
            if (result.Failures.Count > 0)
                Notice?.Invoke(ArtifactPageWords.Skipped(result.Failures.Count, listing.Sessions.Count), TimeSpan.FromSeconds(10));
        }
        catch (Exception e)
        {
            if (generation != _passGeneration || e is OperationCanceledException && ct.IsCancellationRequested) return;
            LoadError = ArtifactFiles.Reason(e);
            if (Artifacts.Count > 0) Notice?.Invoke(ArtifactPageWords.RefreshFailed, TimeSpan.FromSeconds(3));
        }
        if (generation != _passGeneration) return;
        Refreshing = false;
        LastPass = DateTime.UtcNow;
        Changed?.Invoke();
    }

    /// [offline] §6.2: one quick retry, none after a timeout or while the gateway cannot be reached.
    private static bool ShouldRetry(Exception e) =>
        e is not OperationCanceledException && e is not GatewayException { Code: "timeout" or "offline" }
        && e is not GatewayException { Code: "http", Status: 502 or 503 or 504 };

    private void Show(IEnumerable<ArtifactRecord> found)
    {
        Artifacts = Hidden.Visible(ArtifactCollector.Unique(found.Where(InScope)));
        if (Loaded == null && Artifacts.Count > 0) Loaded = Artifacts.Count;
        Changed?.Invoke();
    }

    public sealed record Listing(IReadOnlyList<ArtifactSessionRow> Sessions, IReadOnlyList<string> Listed, IReadOnlyList<string> Failed,
        IReadOnlyList<string> FailedNames, bool PerProfile);

    /// Each profile's recent window (scope All with ≥ 2 bots), merged newest first; otherwise the scope's one listing.
    public async Task<Listing> ListSessionsAsync(string scope, CancellationToken ct = default)
    {
        var names = ProfilesProvider().Select(p => p.Length == 0 ? "default" : p).Distinct().OrderBy(p => p, StringComparer.Ordinal).ToList();
        async Task<List<ArtifactSessionRow>> List(string profile)
        {
            var json = await _source.ListSessionsAsync(profile, WindowSize, ct).ConfigureAwait(false);
            var listed = profile == All ? null : profile;
            return [.. (json.Arr("sessions") ?? json as System.Text.Json.Nodes.JsonArray ?? new System.Text.Json.Nodes.JsonArray())
                .Select(r => ArtifactSessionRow.FromJson(r, listed)).OfType<ArtifactSessionRow>()];
        }
        if (scope != All || names.Count < 2)
        {
            var rows = await List(scope);
            return new Listing(rows, scope == All ? names : [scope], [], [], scope != All);
        }
        var pages = new Dictionary<string, List<ArtifactSessionRow>>();
        var errors = new List<Exception>();
        using var gate = new SemaphoreSlim(3);
        var tasks = names.Select(async name =>
        {
            await gate.WaitAsync(ct).ConfigureAwait(false);
            try { return (name, rows: (List<ArtifactSessionRow>?)await List(name).ConfigureAwait(false), error: (Exception?)null); }
            catch (Exception e) { return (name, rows: null, error: e); }
            finally { gate.Release(); }
        }).ToList();
        foreach (var (name, rows, error) in await Task.WhenAll(tasks))
        {
            if (rows != null) pages[name] = rows;
            else errors.Add(error!);
        }
        if (pages.Count == 0) throw errors.FirstOrDefault() ?? new ArtifactReadException("No bot’s chats could be listed.");
        var seen = new HashSet<string>();
        var all = new List<ArtifactSessionRow>();
        foreach (var name in names)
        {
            foreach (var row in pages.GetValueOrDefault(name) ?? [])
            {
                var r = string.IsNullOrWhiteSpace(row.Profile) ? row with { Profile = name } : row;
                if (seen.Add(ArtifactIndex.Key(r))) all.Add(r);
            }
        }
        var sorted = all.Select((r, i) => (r, i)).OrderByDescending(x => x.r.Recency).ThenBy(x => x.i).Select(x => x.r).ToList();
        var failed = names.Where(n => !pages.ContainsKey(n)).ToList();
        return new Listing(sorted, [.. names.Where(pages.ContainsKey)], failed, [.. failed.Select(DisplayName)], true);
    }

    // ---- unavailable

    public void MarkUnavailable(string id)
    {
        if (Unavailable.Add(id)) Changed?.Invoke();
    }

    public void MarkAvailable(string id)
    {
        if (Unavailable.Remove(id)) Changed?.Invoke();
    }

    public void Reset()
    {
        _passGeneration++;
        _pass?.Cancel();
        Index.Cancel();
        Hidden.Changed -= HiddenChanged;
        Artifacts = [];
    }
}
