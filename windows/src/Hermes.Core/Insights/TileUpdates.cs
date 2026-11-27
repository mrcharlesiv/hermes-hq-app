using System.Text.Json.Nodes;
using Hermes.Core.Net;

namespace Hermes.Core.Insights;

/// The tiles' jobs (App/Pages/Artifacts/TileUpdates.swift): each page tile's job looked up from its bot's jobs
/// (read again after 30 s), its health kept, a tile whose job has just run named so its picture is drawn again; and
/// the Updates menu's writes (How Often, Update Now, Pause / Resume).
public sealed class TileUpdates(GatewaySession session)
{
    public static readonly TimeSpan Fresh = TimeSpan.FromSeconds(30);

    private readonly Dictionary<string, (List<TileCronJob> Jobs, DateTimeOffset At)> _lists = [];
    private readonly Dictionary<string, TileJobs.Health> _healths = [];
    private readonly Dictionary<string, string> _lastRuns = [];
    private readonly HashSet<string> _updating = [];
    private readonly object _lock = new();

    public static string JobPath(string id) => "/api/cron/jobs/" + Uri.EscapeDataString(id);

    private static List<KeyValuePair<string, string>> ProfileQuery(string profile) => [new("profile", profile)];

    /// `GET /api/cron/jobs?profile=`.
    public async Task<List<TileCronJob>> ReadListAsync(string profile, CancellationToken ct = default) =>
        TileCronJob.List(await session.GetJsonAsync("/api/cron/jobs", ProfileQuery(profile), TimeSpan.FromSeconds(60), ct));

    /// The job keeping `pin` up to date; `Known` false when the jobs couldn't be read.
    public async Task<(TileCronJob? Job, bool Known)> LookupAsync(TilePin pin, TimeSpan? fresh = null, CancellationToken ct = default)
    {
        if (!pin.IsPage || pin.GatewayPath is not { } path) return (null, true);
        List<TileCronJob> jobs;
        var read = true;
        (List<TileCronJob> Jobs, DateTimeOffset At) kept;
        bool have;
        lock (_lock) have = _lists.TryGetValue(pin.Profile, out kept);
        if (have && DateTimeOffset.UtcNow - kept.At < (fresh ?? Fresh)) jobs = kept.Jobs;
        else
        {
            try
            {
                jobs = await ReadListAsync(pin.Profile, ct);
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

    /// Reads every page tile's job again: which marks changed, and which tiles' jobs ran since the last read.
    public async Task<(List<string> Marks, List<string> Ran)> RefreshAsync(IReadOnlyList<TilePin> pins, DateTimeOffset now,
        CancellationToken ct = default)
    {
        var marks = new List<string>();
        var ran = new List<string>();
        var pages = pins.Where(p => p.IsPage).ToList();
        lock (_lock) foreach (var profile in pages.Select(p => p.Profile).Distinct()) _lists.Remove(profile);
        foreach (var pin in pages)
        {
            var (job, known) = await LookupAsync(pin, TimeSpan.FromSeconds(5), ct);
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

    public void Forget(string profile) { lock (_lock) _lists.Remove(profile); }

    /// How Often: `PUT /api/cron/jobs/<id>?profile=<owner>` with `{"updates": {"schedule": cron}}`.
    public async Task SetFrequencyAsync(TileCronJob job, TileJobs.Frequency f, CancellationToken ct = default)
    {
        var a = await session.SendAsync(HttpMethod.Put, JobPath(job.Id), ProfileQuery(job.Owner),
            new JsonObject { ["updates"] = new JsonObject { ["schedule"] = f.Cron } }, TimeSpan.FromSeconds(30), ct: ct);
        if (!a.Ok) throw new GatewayException("http", $"The gateway answered {a.Status}.", a.Status, a.Body);
        Forget(job.Owner);
    }

    /// Pause / Resume: `POST /api/cron/jobs/<id>/pause|resume?profile=<owner>`.
    public async Task SetPausedAsync(TileCronJob job, bool pause, CancellationToken ct = default)
    {
        var a = await session.SendAsync(HttpMethod.Post, JobPath(job.Id) + (pause ? "/pause" : "/resume"), ProfileQuery(job.Owner),
            new JsonObject(), ct: ct);
        if (!a.Ok) throw new GatewayException("http", $"The gateway answered {a.Status}.", a.Status, a.Body);
        Forget(job.Owner);
    }

    /// Update Now: `POST /api/cron/jobs/<id>/trigger?profile=<owner>` (a paused job is not un-paused here).
    public async Task RunNowAsync(TileCronJob job, CancellationToken ct = default)
    {
        var a = await session.SendAsync(HttpMethod.Post, JobPath(job.Id) + "/trigger", ProfileQuery(job.Owner), new JsonObject(),
            TimeSpan.FromSeconds(120), ct: ct);
        if (!a.Ok) throw new GatewayException("http", $"The gateway answered {a.Status}.", a.Status, a.Body);
        Forget(job.Owner);
    }
}
