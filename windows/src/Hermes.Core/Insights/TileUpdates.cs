using System.Text.Json.Nodes;
using Hermes.Core.Jobs;
using Hermes.Core.Net;

namespace Hermes.Core.Insights;

/// The tiles' jobs (App/Pages/Artifacts/TileUpdates.swift): each page tile's job looked up from its bot's jobs
/// (read again after 30 s), its health kept, a tile whose job has just run named so its picture is drawn again;
/// bounded concurrent prefetch across bots, active 4 s polling on Update Now (cancelling any prior poll per pin),
/// and the Updates menu's writes (How Often, Model, Update Now, Pause / Resume).
public sealed class TileUpdates
{
    public static readonly TimeSpan Fresh = TimeSpan.FromSeconds(30);
    public const int MaxPollChecks = 45;
    public static readonly TimeSpan DefaultPollInterval = TimeSpan.FromSeconds(4);

    private readonly GatewaySession? _session;
    private readonly Func<string, CancellationToken, Task<List<TileCronJob>>>? _readListOverride;
    private readonly Func<TileCronJob, JsonObject, CancellationToken, Task>? _updateJobOverride;
    private readonly Func<TileCronJob, bool, CancellationToken, Task>? _setPausedOverride;
    private readonly Func<TileCronJob, CancellationToken, Task>? _runNowOverride;

    private readonly Dictionary<string, (List<TileCronJob> Jobs, DateTimeOffset At)> _lists = [];
    /// The shared list cache keyed by the session; a session-less instance (tests) keeps its own.
    private JobsListCache? _ownCache;
    private JobsListCache Cache => _session is { } s ? JobsListCache.For(s) : (_ownCache ??= new JobsListCache());
    private readonly Dictionary<string, TileJobs.Health> _healths = [];
    private readonly Dictionary<string, string> _lastRuns = [];
    private readonly HashSet<string> _updating = [];
    private readonly Dictionary<string, (Guid Token, CancellationTokenSource Cts)> _activePolls = new(StringComparer.Ordinal);
    private readonly object _lock = new();

    /// Delay between active Update Now job polls (defaults to 4 s; tests may shorten it).
    public TimeSpan PollInterval { get; set; } = DefaultPollInterval;

    public TileUpdates(GatewaySession session) => _session = session;

    /// Testable constructor without a live `GatewaySession`.
    public TileUpdates(
        Func<string, CancellationToken, Task<List<TileCronJob>>> readList,
        Func<TileCronJob, JsonObject, CancellationToken, Task>? updateJob = null,
        Func<TileCronJob, bool, CancellationToken, Task>? setPaused = null,
        Func<TileCronJob, CancellationToken, Task>? runNow = null)
    {
        _readListOverride = readList;
        _updateJobOverride = updateJob;
        _setPausedOverride = setPaused;
        _runNowOverride = runNow;
    }

    public static string JobPath(string id) => "/api/cron/jobs/" + Uri.EscapeDataString(id);

    private static List<KeyValuePair<string, string>> ProfileQuery(string profile) => [new("profile", profile)];

    /// `GET /api/cron/jobs?profile=` — through the session's shared cache so the Tiles page and Jobs store share one read per 15 s.
    public async Task<List<TileCronJob>> ReadListAsync(string profile, CancellationToken ct = default)
    {
        if (_readListOverride != null) return await _readListOverride(profile, ct).ConfigureAwait(false);
        return TileCronJob.List(await Cache.ReadAsync(JobsApi.ListKey(profile),
            async () => (JsonNode?)await _session!.GetJsonAsync("/api/cron/jobs", ProfileQuery(profile), TimeSpan.FromSeconds(60)).ConfigureAwait(false), ct).ConfigureAwait(false));
    }

    /// [tiles-v2] Reads the jobs for `profiles` concurrently (bounded) so multi-bot accounts don't wait serially.
    public async Task PrefetchAsync(IEnumerable<string> profiles, int maxConcurrency = 4, CancellationToken ct = default)
    {
        var unique = profiles.Where(p => !string.IsNullOrWhiteSpace(p)).Distinct(StringComparer.Ordinal).ToList();
        if (unique.Count == 0) return;
        using var gate = new SemaphoreSlim(Math.Max(1, maxConcurrency));
        var tasks = unique.Select(async profile =>
        {
            await gate.WaitAsync(ct).ConfigureAwait(false);
            try
            {
                var jobs = await ReadListAsync(profile, ct).ConfigureAwait(false);
                lock (_lock) _lists[profile] = (jobs, DateTimeOffset.UtcNow);
            }
            catch (GatewayException) { }
            finally
            {
                gate.Release();
            }
        });
        await Task.WhenAll(tasks).ConfigureAwait(false);
    }

    /// [tiles-v2] All matched tile jobs for `pins` (one per unique job key), fetched concurrently per bot.
    public async Task<List<TileCronJob>> AllJobsAsync(IEnumerable<TilePin> pins, CancellationToken ct = default)
    {
        var pages = pins.Where(p => p.IsPage).ToList();
        if (pages.Count == 0) return [];
        await PrefetchAsync(pages.Select(p => p.Profile), ct: ct).ConfigureAwait(false);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var list = new List<TileCronJob>();
        foreach (var pin in pages)
        {
            var (job, _) = await LookupAsync(pin, Fresh, ct).ConfigureAwait(false);
            if (job != null && seen.Add(job.Key)) list.Add(job);
        }
        return list;
    }

    /// The job keeping `pin` up to date; `Known` false when the jobs couldn't be read.
    public async Task<(TileCronJob? Job, bool Known)> LookupAsync(TilePin pin, TimeSpan? fresh = null, CancellationToken ct = default)
    {
        if (!pin.IsPage || pin.GatewayPath is not { } path) return (null, true);
        List<TileCronJob> jobs;
        var read = true;
        (List<TileCronJob> Jobs, DateTimeOffset At) kept;
        bool have;
        lock (_lock) have = _lists.TryGetValue(pin.Profile, out kept);
        var window = fresh ?? Fresh;
        if (have && window > TimeSpan.Zero && DateTimeOffset.UtcNow - kept.At < window) jobs = kept.Jobs;
        else
        {
            try
            {
                if (window <= TimeSpan.Zero) Cache.Forget(JobsApi.ListKey(pin.Profile));
                jobs = await ReadListAsync(pin.Profile, ct).ConfigureAwait(false);
                lock (_lock) _lists[pin.Profile] = (jobs, DateTimeOffset.UtcNow);
            }
            catch (GatewayException)
            {
                jobs = have ? kept.Jobs : [];
                read = false;
            }
        }
        var job = TileJobs.Match(path, pin.Profile, pin.JobId, jobs);
        return (job, read || job != null);
    }

    public TileJobs.Health Health(string id) { lock (_lock) return _healths.GetValueOrDefault(id, TileJobs.Health.None); }

    /// Marks a tile whose page is gone from the gateway (`TileHealthMark.goneWords`).
    public void MarkGone(string id) { lock (_lock) _healths[id] = new(TileJobs.HealthKind.Failed, TileWords.GoneWords); }

    /// Reads every page tile's job again (concurrently per bot): which marks changed, and which tiles' jobs ran since
    /// the last read.
    public async Task<(List<string> Marks, List<string> Ran)> RefreshAsync(IReadOnlyList<TilePin> pins, DateTimeOffset now,
        CancellationToken ct = default)
    {
        var marks = new List<string>();
        var ran = new List<string>();
        var pages = pins.Where(p => p.IsPage).ToList();
        var profiles = pages.Select(p => p.Profile).Distinct(StringComparer.Ordinal).ToList();
        lock (_lock) foreach (var profile in profiles) _lists.Remove(profile);
        await PrefetchAsync(profiles, ct: ct).ConfigureAwait(false);
        foreach (var pin in pages)
        {
            var (job, known) = await LookupAsync(pin, TimeSpan.FromSeconds(15), ct).ConfigureAwait(false);
            if (!known) continue;
            var health = TileJobs.HealthOf(job, now);
            lock (_lock)
            {
                if (_healths.GetValueOrDefault(pin.Id, TileJobs.Health.None) != health) marks.Add(pin.Id);
                _healths[pin.Id] = health;
                var last = job?.LastRunAt ?? "";
                var wasUpdating = _updating.Contains(pin.Id);
                if (health.Kind == TileJobs.HealthKind.Updating) _updating.Add(pin.Id); else _updating.Remove(pin.Id);
                if (_lastRuns.TryGetValue(pin.Id, out var seen) && (seen != last || (wasUpdating && health.Kind != TileJobs.HealthKind.Updating)))
                    ran.Add(pin.Id);
                _lastRuns[pin.Id] = last;
            }
        }
        return (marks, ran);
    }

    public bool AnyUpdating { get { lock (_lock) return _updating.Count > 0; } }

    public void Forget(string profile)
    {
        lock (_lock) _lists.Remove(profile);
        Cache.Forget(JobsApi.ListKey(profile));
    }

    /// Writes `{"updates": updates}` to `PUT /api/cron/jobs/<id>?profile=<owner>` (schedule, model/provider/fallback_providers).
    public async Task UpdateJobAsync(TileCronJob job, JsonObject updates, CancellationToken ct = default)
    {
        if (_updateJobOverride != null)
        {
            await _updateJobOverride(job, updates, ct).ConfigureAwait(false);
            Forget(job.Owner);
            return;
        }
        var a = await _session!.SendAsync(HttpMethod.Put, JobPath(job.Id), ProfileQuery(job.Owner),
            new JsonObject { ["updates"] = updates.DeepClone() }, TimeSpan.FromSeconds(30), ct: ct).ConfigureAwait(false);
        if (!a.Ok) throw new GatewayException("http", $"The gateway answered {a.Status}.", a.Status, a.Body);
        Forget(job.Owner);
    }

    /// How Often: `PUT /api/cron/jobs/<id>?profile=<owner>` with `{"updates": {"schedule": cron}}`.
    public Task SetFrequencyAsync(TileCronJob job, TileJobs.Frequency f, CancellationToken ct = default) =>
        UpdateJobAsync(job, new JsonObject { ["schedule"] = f.Cron }, ct);

    /// Pause / Resume: `POST /api/cron/jobs/<id>/pause|resume?profile=<owner>`.
    public async Task SetPausedAsync(TileCronJob job, bool pause, CancellationToken ct = default)
    {
        if (_setPausedOverride != null)
        {
            await _setPausedOverride(job, pause, ct).ConfigureAwait(false);
            Forget(job.Owner);
            return;
        }
        var a = await _session!.SendAsync(HttpMethod.Post, JobPath(job.Id) + (pause ? "/pause" : "/resume"), ProfileQuery(job.Owner),
            new JsonObject(), ct: ct).ConfigureAwait(false);
        if (!a.Ok) throw new GatewayException("http", $"The gateway answered {a.Status}.", a.Status, a.Body);
        Forget(job.Owner);
    }

    /// Update Now: `POST /api/cron/jobs/<id>/trigger?profile=<owner>` (a paused job is not un-paused here).
    public async Task RunNowAsync(TileCronJob job, CancellationToken ct = default)
    {
        if (_runNowOverride != null)
        {
            await _runNowOverride(job, ct).ConfigureAwait(false);
            Forget(job.Owner);
            return;
        }
        var a = await _session!.SendAsync(HttpMethod.Post, JobPath(job.Id) + "/trigger", ProfileQuery(job.Owner), new JsonObject(),
            TimeSpan.FromSeconds(120), ct: ct).ConfigureAwait(false);
        if (!a.Ok) throw new GatewayException("http", $"The gateway answered {a.Status}.", a.Status, a.Body);
        Forget(job.Owner);
    }

    /// Cancels any active Update Now poll running for `pinId`.
    public void CancelPoll(string pinId)
    {
        CancellationTokenSource? prior = null;
        lock (_lock)
        {
            if (_activePolls.Remove(pinId, out var entry)) prior = entry.Cts;
        }
        if (prior != null)
        {
            try { prior.Cancel(); } catch (ObjectDisposedException) { }
            prior.Dispose();
        }
    }

    public void CancelAllPolls()
    {
        List<CancellationTokenSource> all;
        lock (_lock)
        {
            all = _activePolls.Values.Select(v => v.Cts).ToList();
            _activePolls.Clear();
        }
        foreach (var cts in all)
        {
            try { cts.Cancel(); } catch (ObjectDisposedException) { }
            cts.Dispose();
        }
    }

    /// [tiles-v2] Triggers `job` now and actively polls every `PollInterval` (4 s by default, up to `maxChecks` = 45)
    /// until the run completes, cancelling any prior active poll for `pin.Id`. Returns true when completion was observed
    /// (false if timed out or cancelled before completion).
    public async Task<bool> UpdateNowAndPollAsync(
        TileCronJob job,
        TilePin pin,
        Action<TileCronJob?>? onFinished = null,
        int maxChecks = MaxPollChecks,
        CancellationToken ct = default)
    {
        var token = Guid.NewGuid();
        var linked = CancellationTokenSource.CreateLinkedTokenSource(ct);
        CancellationTokenSource? prior = null;
        lock (_lock)
        {
            if (_activePolls.TryGetValue(pin.Id, out var prev)) prior = prev.Cts;
            _activePolls[pin.Id] = (token, linked);
        }
        if (prior != null)
        {
            try { prior.Cancel(); } catch (ObjectDisposedException) { }
            prior.Dispose();
        }

        var pollCt = linked.Token;
        var priorRun = job.LastRunAt ?? "";
        try
        {
            await RunNowAsync(job, pollCt).ConfigureAwait(false);
            var sawRunning = false;
            var checks = Math.Max(0, maxChecks);
            for (var i = 0; i < checks; i++)
            {
                if (PollInterval > TimeSpan.Zero)
                    await Task.Delay(PollInterval, pollCt).ConfigureAwait(false);
                else if (pollCt.IsCancellationRequested)
                    return false;

                var (latest, known) = await LookupAsync(pin, TimeSpan.Zero, pollCt).ConfigureAwait(false);
                if (!known || latest == null) continue;
                var running = TileJobs.WorkIsOut(latest);
                if (running) sawRunning = true;
                var finished = (latest.LastRunAt ?? "") != priorRun || (sawRunning && !running);
                if (finished)
                {
                    onFinished?.Invoke(latest);
                    return true;
                }
            }
            if (!pollCt.IsCancellationRequested) onFinished?.Invoke(null);
            return false;
        }
        catch (OperationCanceledException) when (pollCt.IsCancellationRequested)
        {
            return false;
        }
        finally
        {
            lock (_lock)
            {
                if (_activePolls.TryGetValue(pin.Id, out var current) && current.Token == token)
                    _activePolls.Remove(pin.Id);
            }
            linked.Dispose();
        }
    }
}
