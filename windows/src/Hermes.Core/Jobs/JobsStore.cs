using System.Text.Json.Nodes;
using Hermes.Core.Net;

namespace Hermes.Core.Jobs;

public sealed record JobsStoreTiming
{
    public TimeSpan ChangeGap { get; init; } = TimeSpan.FromSeconds(2);
    public TimeSpan Backstop { get; init; } = TimeSpan.FromSeconds(300);
    public TimeSpan BackstopWithoutEvents { get; init; } = TimeSpan.FromSeconds(30);
    public TimeSpan BackstopWorkOutOffScreen { get; init; } = TimeSpan.FromSeconds(90);
    public TimeSpan RunTimeout { get; init; } = TimeSpan.FromSeconds(120);
    public TimeSpan StillRunningRecheck { get; init; } = TimeSpan.FromSeconds(5);
    public TimeSpan StillRunningGiveUp { get; init; } = TimeSpan.FromSeconds(1800);
    public double DueLead { get; init; } = 3;
    public double DueRecheck { get; init; } = 10;
    public double DueWindow { get; init; } = 120;
    public double DueRecheckOffScreen { get; init; } = 40;
    public static JobsStoreTiming Standard { get; } = new();
}

/// Where the list and the blueprints are kept between launches (one folder per gateway account).
public interface IJobsCache
{
    string? Read(string name);
    void Write(string name, string text);
    void Delete(string name);
}

public sealed class JobsDiskCache(string directory) : IJobsCache
{
    private static string Safe(string name) => string.Concat(name.Select(c => char.IsLetterOrDigit(c) || c is '-' or '_' or '.' ? c : '_'));
    private string PathOf(string name) => Path.Combine(directory, Safe(name) + ".json");

    public string? Read(string name)
    {
        try { return File.Exists(PathOf(name)) ? File.ReadAllText(PathOf(name)) : null; } catch (IOException) { return null; }
    }

    public void Write(string name, string text)
    {
        try
        {
            Directory.CreateDirectory(directory);
            var tmp = PathOf(name) + ".tmp";
            File.WriteAllText(tmp, text);
            File.Move(tmp, PathOf(name), overwrite: true);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    public void Delete(string name)
    {
        try { File.Delete(PathOf(name)); } catch (IOException) { }
    }
}

public enum WriteKind { Done, Refused, Failed }
public sealed record WriteResult(WriteKind Kind, string? Reason = null);

public enum RunKind { Started, StillRunning, Refused, AlreadyRunning, RestorePauseFailed, Failed }
public sealed record RunResult(RunKind Kind, string? Reason = null);

public enum EditKind { Done, Refused, Failed }
/// How an editor write ended.
public sealed record JobEditResult(EditKind Kind, CronJob? Job = null, string? Reason = null, int? Status = null, bool Slow = false);

/// The Jobs page's data (HermesKit/Pages/JobsStore.swift, docs/spec/1x-pages.md §3): the scope's list painted from its
/// disk cache, then read (`GET /api/cron/jobs?profile=`); refreshed on `cron.changed` through a 2 s throttle, a backstop
/// (5 min, 30 s without change events or while work is out on screen), just after each job's start time, on reconnects
/// and on request. Each read also asks the Hermes HQ add-on which jobs a bot is still working on. Writes: Run Now,
/// Pause / Resume, Delete, and the editor's create / edit / create from a blueprint; each refused while read-only.
/// Events come on any thread.
public sealed class JobsStore : IDisposable
{
    public const string ReadOnlyNotice = "Changes are off for this gateway.";
    public static readonly TimeSpan WriteTimeout = TimeSpan.FromSeconds(15);
    /// At most this many jobs are kept on disk per scope, fewer when the JSON is over `CacheLimit` characters.
    public static readonly int[] JobPrefixes = [500, 250, 125, 62, 31];
    public const int CacheLimit = 300_000;

    private readonly object _lock = new();
    private readonly IJobsCache? _cache;
    private readonly SemaphoreSlim _readGate = new(1, 1);
    private readonly CancellationTokenSource _life = new();
    private long _asked, _served;
    private int _readGeneration;
    private int _nextToken;
    private readonly Dictionary<string, int> _busy = [];
    private readonly HashSet<string> _runInFlight = [];
    private readonly Dictionary<string, string?> _stillRunning = [];
    private readonly Dictionary<string, DateTimeOffset> _stillRunningSince = [];
    private readonly HashSet<string> _stillRunningSeenOut = [];
    private Dictionary<string, string> _botWorking = [];
    private bool _botWorkingMissing, _botWorkingFailed;
    private bool _runOut;
    private int _showing;
    private DateTimeOffset? _lastRead, _lastStart;
    private CancellationTokenSource? _backstop, _due, _throttle;
    /// When the add-on's working map was last read (BUG-3: it was asked with every list read — a second request on
    /// every tick where the list itself says whether anything could have changed).
    private DateTimeOffset? _botWorkingAt;
    /// A stale working map is never trusted longer than this even when the list is quiet (a killed run writes no
    /// jobs.json, so no change event would clear a Running that lied).
    public static readonly TimeSpan BotWorkingKeep = TimeSpan.FromMinutes(10);
    private readonly Dictionary<string, DateTimeOffset> _blueprintsReadAt = [];
    private readonly Dictionary<string, (DateTimeOffset Started, Task<List<CronRun>> Task)> _runReads = [];

    public JobsStore(JobsApi api, IJobsCache? cache = null, string scope = "all", JobsStoreTiming? timing = null)
    {
        Api = api;
        _cache = cache;
        Scope = scope;
        Timing = timing ?? JobsStoreTiming.Standard;
        PaintFromCache();
    }

    public JobsApi Api { get; }
    public JobsStoreTiming Timing { get; }
    public bool ReadOnlyGateway { get; set; }
    public bool ChangeEvents { get; private set; } = true;

    /// "all" or a profile name.
    public string Scope { get; private set; }
    /// The scope's jobs, by human title (a snapshot; replaced, never changed in place).
    public IReadOnlyList<CronJob> Jobs { get; private set; } = [];
    public bool HasList { get; private set; }
    public bool Loading { get; private set; }
    /// The last read failed (null after a read that worked).
    public string? LoadError { get; private set; }
    /// Spelling of words other jobs' names use ("GBrain").
    public IReadOnlyDictionary<string, string> Casing { get; private set; } = new Dictionary<string, string>();
    /// Counts `cron.changed` events: a job page re-reads its runs on each.
    public int ChangeTick { get; private set; }
    /// Bumped by every list read that landed.
    public int ListReads { get; private set; }
    /// Jobs this app deleted (their page closes itself).
    public HashSet<string> DeletedHere { get; } = [];
    /// Job templates by profile.
    public Dictionary<string, List<Blueprint>> BlueprintsByProfile { get; } = [];

    /// Anything shown changed.
    public event Action? Changed;
    /// A refresh failed while a cached list shows.
    public event Action<string>? RefreshFailed;
    /// A job vanished (404): its page closes with "Job Removed".
    public event Action<string>? JobRemoved;

    private void Notify() => Changed?.Invoke();

    // ------------------------------------------------------------------ cache

    private static string CacheName(string scope) => "jobs-" + scope;
    private static string BlueprintsName(string profile) => "blueprints-" + profile;

    private void PaintFromCache()
    {
        PaintBlueprintsFromCache();
        var text = _cache?.Read(CacheName(Scope));
        if (text != null && J.Parse(text) is { } node)
        {
            SetJobs(CronJob.List(node.Get("value") ?? node));
            HasList = true;
        }
        else
        {
            Jobs = [];
            HasList = false;
        }
    }

    /// The longest of the first 500 / 250 / 125 / 62 / 31 jobs whose saved JSON is at most `maxBytes`; null when none fits.
    public static string? FittingJobs(IReadOnlyList<CronJob> list, double at, int maxBytes)
    {
        var tried = new HashSet<int>();
        foreach (var count in JobPrefixes)
        {
            var kept = Math.Min(count, list.Count);
            if (!tried.Add(kept)) continue;
            var arr = new JsonArray([.. list.Take(kept).Select(j => (JsonNode)j.ToJson())]);
            var text = new JsonObject { ["at"] = at, ["value"] = arr }.ToJsonString();
            if (text.Length <= maxBytes) return text;
        }
        return null;
    }

    private void PaintBlueprintsFromCache()
    {
        var profile = ListProfile;
        if (BlueprintsByProfile.ContainsKey(profile) || _cache?.Read(BlueprintsName(profile)) is not { } text) return;
        if (J.Parse(text) is { } node) BlueprintsByProfile[profile] = Blueprint.List(node);
    }

    private void SetJobs(IEnumerable<CronJob> list)
    {
        var withWork = list.Select(j => j with { BotWorking = _botWorking.GetValueOrDefault(j.Key) }).ToList();
        var casing = JobWords.KnownWordCasing(withWork.Select(JobWords.JobTitle));
        Casing = casing;
        Jobs = [.. withWork.Select(j => (Job: j, Title: JobWords.HumanJobTitle(JobWords.JobTitle(j), casing)))
            .OrderBy(x => x.Title, NaturalComparer.Instance).Select(x => x.Job)];
    }

    public string Title(CronJob job) => JobWords.HumanJobTitle(JobWords.JobTitle(job), Casing);

    public CronJob? Job(string key) => Jobs.FirstOrDefault(j => j.Key == key);

    // ------------------------------------------------------------------ scope and visibility

    /// The profile the page's blueprints are read for: the scope's bot, the default bot under All.
    public string ListProfile => Scope == "all" ? "default" : Scope;

    public List<Blueprint> Blueprints => BlueprintsByProfile.GetValueOrDefault(ListProfile) ?? [];

    public void SetScope(string next)
    {
        if (next == Scope) return;
        Scope = next;
        Interlocked.Increment(ref _readGeneration);
        LoadError = null;
        PaintFromCache();
        Notify();
        _ = RefreshAsync();
    }

    /// Jobs (list or detail) on screen, counted: read now when the list is over 30 s old (or never read).
    public void NoteAppear()
    {
        if (Interlocked.Increment(ref _showing) != 1) return;
        Notify();
        if (_lastRead is not { } at || DateTimeOffset.Now - at > TimeSpan.FromSeconds(30)) _ = RefreshAsync();
        StartBackstop();
        ArmDueRead();
    }

    public void NoteDisappear()
    {
        if (Interlocked.Decrement(ref _showing) > 0) return;
        _showing = 0;
        Notify();
        StartBackstop();
        ArmDueRead();
    }

    public bool IsShowing => Volatile.Read(ref _showing) > 0;

    /// `cron.changed`: read soon (2 s apart).
    public void CronChanged()
    {
        ChangeTick++;
        CancellationToken token;
        lock (_lock)
        {
            if (_throttle != null || _life.IsCancellationRequested) return;
            _throttle = CancellationTokenSource.CreateLinkedTokenSource(_life.Token);
            token = _throttle.Token;
        }
        var since = _lastRead is { } r ? DateTimeOffset.Now - r : Timing.ChangeGap;
        var wait = since >= Timing.ChangeGap ? TimeSpan.Zero : Timing.ChangeGap - since;
        _ = Task.Run(async () =>
        {
            try { await Task.Delay(wait, token).ConfigureAwait(false); } catch (OperationCanceledException) { return; }
            lock (_lock) _throttle = null;
            await RefreshAsync().ConfigureAwait(false);
        });
        Notify();
    }

    /// `gateway.ready` after a (re)connect.
    public void GatewayReady(bool changeEvents)
    {
        ChangeEvents = changeEvents;
        _botWorkingMissing = false;
        StartBackstop();
        if (_lastStart is { } s && DateTimeOffset.Now - s < TimeSpan.FromSeconds(5)) return;
        _ = RefreshAsync();
    }

    /// How often the whole list is read with nothing else asking.
    public static TimeSpan BackstopGap(bool changeEvents, bool runOut, bool onScreen, JobsStoreTiming? timing = null)
    {
        var t = timing ?? JobsStoreTiming.Standard;
        if (!changeEvents) return t.BackstopWithoutEvents;
        if (!runOut) return t.Backstop;
        return onScreen ? t.BackstopWithoutEvents : t.BackstopWorkOutOffScreen;
    }

    public void StartBackstop()
    {
        CancellationTokenSource cts;
        lock (_lock)
        {
            _backstop?.Cancel();
            if (_life.IsCancellationRequested) return;
            cts = _backstop = CancellationTokenSource.CreateLinkedTokenSource(_life.Token);
        }
        var gap = BackstopGap(ChangeEvents, _runOut, _showing > 0, Timing);
        _ = Task.Run(async () =>
        {
            while (!cts.IsCancellationRequested)
            {
                try { await Task.Delay(gap, cts.Token).ConfigureAwait(false); } catch (OperationCanceledException) { return; }
                await RefreshAsync().ConfigureAwait(false);
            }
        });
    }

    /// Seconds until the read for the soonest job start: `DueLead` after a start ahead (or just passed), backing off
    /// while one passed less than `DueWindow` ago and its run isn't out yet; null with none.
    public static double? NextDueRead(IEnumerable<CronJob> jobs, DateTimeOffset now, JobsStoreTiming? timing = null, bool onScreen = true)
    {
        var t = timing ?? JobsStoreTiming.Standard;
        var recheck = onScreen ? t.DueRecheck : Math.Max(t.DueRecheck, t.DueRecheckOffScreen);
        double? soonest = null;
        foreach (var job in jobs)
        {
            if (job.Enabled == false || JobWords.WorkIsOut(job) || JobWords.JobState(job) is "paused" or "completed" or "disabled"
                || PagesDate.Parse(job.NextRunAt) is not { } next) continue;
            var ahead = (next - now).TotalSeconds;
            double delay;
            if (ahead > -t.DueLead) delay = ahead + t.DueLead;
            else
            {
                var passed = -ahead;
                var wait = Math.Max(recheck, passed);
                if (passed + wait > t.DueWindow) continue;
                delay = wait;
            }
            soonest = Math.Min(soonest ?? delay, delay);
        }
        return soonest;
    }

    private void ArmDueRead()
    {
        CancellationTokenSource cts;
        lock (_lock)
        {
            _due?.Cancel();
            _due = null;
            if (_life.IsCancellationRequested) return;
            if (NextDueRead(Jobs, DateTimeOffset.Now, Timing, _showing > 0) is not { } delay) return;
            cts = _due = CancellationTokenSource.CreateLinkedTokenSource(_life.Token);
            _ = Task.Run(async () =>
            {
                try { await Task.Delay(TimeSpan.FromSeconds(Math.Min(delay, 86400)), cts.Token).ConfigureAwait(false); }
                catch (OperationCanceledException) { return; }
                await RefreshAsync().ConfigureAwait(false);
            });
        }
    }

    public void Stop()
    {
        lock (_lock)
        {
            _backstop?.Cancel();
            _due?.Cancel();
            _throttle?.Cancel();
            _throttle = null;
        }
    }

    public void Dispose()
    {
        Stop();
        _life.Cancel();
    }

    // ------------------------------------------------------------------ reads

    /// Reads the scope's list. One read at a time; callers during a read share the one that follows it.
    public async Task RefreshAsync()
    {
        var asked = Interlocked.Increment(ref _asked);
        try { await _readGate.WaitAsync(_life.Token).ConfigureAwait(false); } catch (OperationCanceledException) { return; }
        try
        {
            if (Interlocked.Read(ref _served) >= asked) return;
            var covers = Interlocked.Read(ref _asked);
            await PerformRefreshAsync().ConfigureAwait(false);
            Interlocked.Exchange(ref _served, covers);
        }
        finally { _readGate.Release(); }
    }

    private async Task PerformRefreshAsync()
    {
        var generation = Interlocked.Increment(ref _readGeneration);
        _lastStart = DateTimeOffset.Now;
        var scope = Scope;
        _ = LoadBlueprintsIfStaleAsync(ListProfile);
        // No Notify at the start: a read whose answer changes nothing renders nothing (BUG-3's twitchy tile — two
        // state updates a tick even when the gateway said nothing new).
        Loading = true;
        var changed = true;   // an early exit (a superseded read) always renders
        try
        {
            var list = await ReadWithRetryAsync(() => Api.ListAsync(scope)).ConfigureAwait(false);
            if (generation != _readGeneration || scope != Scope) return;
            changed = Differs(list);
            // The add-on is asked only when it could have news: the list moved (at most once a minute even then —
            // each run changes the list long before the map can matter again), or what we know is old (a killed run
            // writes no jobs.json, so no change event would clear a Running that lied). A quiet list isn't asked:
            // BUG-3's second request on every tick where one data source would do.
            var sinceAsk = _botWorkingAt is { } a ? DateTimeOffset.UtcNow - a : TimeSpan.MaxValue;
            var askWorking = !_botWorkingMissing &&
                (changed ? sinceAsk >= TimeSpan.FromSeconds(60) : sinceAsk >= BotWorkingKeep);
            var (answerOk, answerMap) = askWorking ? await BotWorkingAnswer().ConfigureAwait(false) : (true, _botWorking);
            lock (_lock)
            {
                if (_botWorkingMissing) { _botWorking = []; }
                else if (askWorking && answerOk && answerMap == null) { _botWorkingMissing = true; _botWorking = []; _botWorkingAt = null; }
                else if (askWorking && answerOk) { _botWorking = answerMap!; _botWorkingFailed = false; _botWorkingAt = DateTimeOffset.UtcNow; }
                else if (askWorking)
                {
                    if (_botWorkingFailed) _botWorking = [];
                    _botWorkingFailed = true;
                    _botWorkingAt = null;
                }
                SetJobs(list);
            }
            var hadError = LoadError != null;
            var out_ = Jobs.Any(JobWords.WorkIsOut);
            if (out_ != _runOut) { _runOut = out_; changed = true; StartBackstop(); }
            HasList = true;
            LoadError = null;
            _lastRead = DateTimeOffset.Now;
            if (SettleStillRunning()) changed = true;
            ListReads++;
            ArmDueRead();
            if (_cache != null)
            {
                if (FittingJobs(list, DateTimeOffset.Now.ToUnixTimeMilliseconds(), CacheLimit) is { } text) _cache.Write(CacheName(scope), text);
                else _cache.Delete(CacheName(scope));
            }
            if (hadError || askWorking) changed = true;   // an error clearing, or a fresh working map, is news too
        }
        catch (GatewayException e)
        {
            if (generation != _readGeneration || scope != Scope) { changed = true; return; }
            var reason = JobErrors.Reason(e);
            changed = reason != LoadError;
            LoadError = reason;
            if (HasList) RefreshFailed?.Invoke(reason);
        }
        finally
        {
            if (generation == _readGeneration) Loading = false;
            if (changed) Notify();   // render only when what shows actually changed
        }
    }

    /// Whether the freshly read list differs from what shows, in anything a row or a tile renders.
    private bool Differs(List<CronJob> list)
    {
        var old = Jobs;
        if (old.Count != list.Count) return true;
        for (var i = 0; i < list.Count; i++)
        {
            var a = old[i];
            var b = list[i];
            if (a.Id != b.Id || a.Name != b.Name || a.State != b.State || a.Enabled != b.Enabled
                || a.LastRunAt != b.LastRunAt || a.NextRunAt != b.NextRunAt
                || a.LatestRunStatus != b.LatestRunStatus || a.LatestRunClaimedAt != b.LatestRunClaimedAt) return true;
        }
        return false;
    }

    /// One quick retry, none after a timeout or while the gateway can't be reached.
    private static async Task<T> ReadWithRetryAsync<T>(Func<Task<T>> read)
    {
        try { return await read().ConfigureAwait(false); }
        catch (GatewayException e) when (e.Code == "http" && e.Status >= 500 && !JobErrors.IsSlowAnswer(e))
        {
            await Task.Delay(500).ConfigureAwait(false);
            return await read().ConfigureAwait(false);
        }
    }

    private async Task<(bool Ok, Dictionary<string, string>? Map)> BotWorkingAnswer()
    {
        try { return (true, await Api.BotWorkingAsync().ConfigureAwait(false)); }
        catch (GatewayException) { return (false, null); }
    }

    /// One job, fresh. (true, job) found; (true, null) gone (404: the caller closes with "Job Removed"); (false, null)
    /// when the read failed.
    public async Task<(bool Read, CronJob? Job)> ReloadAsync(CronJob job)
    {
        try
        {
            var fresh = CronJob.Parse(await Api.JobAsync(job.Id, job.Owner).ConfigureAwait(false));
            if (fresh == null) return (true, null);
            Replace(fresh);
            return (true, fresh);
        }
        catch (GatewayException e)
        {
            if (JobErrors.Status(e) == 404)
            {
                Remove(job.Key);
                JobRemoved?.Invoke(job.Key);
                return (true, null);
            }
            return (false, null);
        }
    }

    /// A job's runs, newest first (`?limit=20`); callers within 250 ms of a read share it.
    public Task<List<CronRun>> LoadRunsAsync(CronJob job)
    {
        lock (_lock)
        {
            if (_runReads.TryGetValue(job.Key, out var e) && !e.Task.IsCompleted && DateTimeOffset.Now - e.Started <= TimeSpan.FromMilliseconds(250))
                return e.Task;
            var task = Api.RunsAsync(job.Id, job.Owner);
            _runReads[job.Key] = (DateTimeOffset.Now, task);
            return task;
        }
    }

    // ------------------------------------------------------------------ writes

    private int Mark(string key)
    {
        lock (_lock) { _busy[key] = ++_nextToken; }
        Notify();
        return _nextToken;
    }

    private void Clear(string key, int token)
    {
        lock (_lock) { if (_busy.TryGetValue(key, out var t) && t == token) _busy.Remove(key); else return; }
        Notify();
    }

    public bool IsBusy(CronJob job) { lock (_lock) return _busy.ContainsKey(job.Key); }
    public bool IsStillRunning(CronJob job) { lock (_lock) return _stillRunning.ContainsKey(job.Key); }
    /// The row says Running: a Run Now in flight, or one that outlived the wait.
    public bool ShowsRunning(CronJob job) { lock (_lock) return _runInFlight.Contains(job.Key) || _stillRunning.ContainsKey(job.Key); }
    /// How many of the scope's jobs show Running.
    public int WorkingCount => Jobs.Count(j => ShowsRunning(j) || JobWords.IsRunning(j));

    /// A write's own answer is newer than a list read that began before it: that read's answer is dropped.
    public void SupersedeListRead()
    {
        if (!Loading) return;
        Interlocked.Increment(ref _readGeneration);
        Loading = false;
    }

    public void Replace(CronJob job)
    {
        lock (_lock)
        {
            var list = Jobs.ToList();
            var i = list.FindIndex(j => j.Key == job.Key);
            if (i < 0) return;
            list[i] = job;
            SetJobs(list);
        }
        Notify();
    }

    public void Remove(string key)
    {
        lock (_lock) Jobs = [.. Jobs.Where(j => j.Key != key)];
        Notify();
    }

    /// Pause or Resume (no confirmation).
    public async Task<WriteResult> SetPausedAsync(CronJob job, bool pause)
    {
        if (ReadOnlyGateway) return new(WriteKind.Refused);
        var token = Mark(job.Key);
        ForgetList();
        try
        {
            var fresh = CronJob.Parse(await Api.PauseAsync(job.Id, job.Owner, pause).ConfigureAwait(false));
            if (fresh != null)
            {
                if (fresh.Profile == null) fresh.Profile = job.Profile;
                SupersedeListRead();
                Replace(fresh);
            }
            _ = RefreshAsync();
            return new(WriteKind.Done);
        }
        catch (GatewayException e) { return new(WriteKind.Failed, JobErrors.Reason(e)); }
        finally { Clear(job.Key, token); }
    }

    public async Task<WriteResult> DeleteAsync(CronJob job)
    {
        if (ReadOnlyGateway) return new(WriteKind.Refused);
        var token = Mark(job.Key);
        ForgetList();
        try
        {
            await Api.DeleteAsync(job.Id, job.Owner).ConfigureAwait(false);
            lock (_lock) DeletedHere.Add(job.Key);
            SupersedeListRead();
            Remove(job.Key);
            _ = RefreshAsync();
            return new(WriteKind.Done);
        }
        catch (GatewayException e)
        {
            if (JobErrors.Status(e) == 404) { Remove(job.Key); return new(WriteKind.Done); }
            return new(WriteKind.Failed, JobErrors.Reason(e));
        }
        finally { Clear(job.Key, token); }
    }

    /// Run Now (after the caller asked). One run at a time per job.
    public async Task<RunResult> RunNowAsync(CronJob job)
    {
        if (ReadOnlyGateway) return new(RunKind.Refused);
        if (IsBusy(job)) return new(RunKind.AlreadyRunning, "Job is already running or was claimed by another scheduler");
        var token = Mark(job.Key);
        ForgetList();
        lock (_lock) _runInFlight.Add(job.Key);
        try
        {
            var fresh = await Api.RunOnceAsync(job.Id, job.Owner, Timing.RunTimeout).ConfigureAwait(false);
            if (fresh != null)
            {
                if (fresh.Profile == null) fresh.Profile = job.Profile;
                SupersedeListRead();
                Replace(fresh);
            }
            _ = RefreshAsync();
            return new(RunKind.Started);
        }
        catch (RestorePauseException)
        {
            _ = RefreshAsync();
            return new(RunKind.RestorePauseFailed);
        }
        catch (GatewayException e)
        {
            if (JobErrors.IsSlowAnswer(e))
            {
                lock (_lock)
                {
                    _stillRunning[job.Key] = job.LastRunAt;
                    _stillRunningSince[job.Key] = DateTimeOffset.Now;
                    _stillRunningSeenOut.Remove(job.Key);
                }
                Notify();
                _ = Task.Run(async () =>
                {
                    await Task.Delay(Timing.StillRunningRecheck).ConfigureAwait(false);
                    await ReloadAsync(job).ConfigureAwait(false);
                    await RefreshAsync().ConfigureAwait(false);
                });
                return new(RunKind.StillRunning);
            }
            if (JobErrors.Status(e) == 409) return new(RunKind.AlreadyRunning, JobErrors.Reason(e));
            return new(RunKind.Failed, JobErrors.Reason(e));
        }
        finally
        {
            lock (_lock) _runInFlight.Remove(job.Key);
            Clear(job.Key, token);
        }
    }

    /// A run that outlived the wait ends when a read shows a newer last run; or, with no new run time, when a read that
    /// had shown it out shows it out no more, or `StillRunningGiveUp` after the wait.
    /// True when something stopped showing Running (the caller renders then, not before).
    public bool SettleStillRunning(DateTimeOffset? now = null)
    {
        var n = now ?? DateTimeOffset.Now;
        var any = false;
        lock (_lock)
        {
            foreach (var (key, before) in _stillRunning.ToList())
            {
                var job = Job(key);
                bool ended;
                if (job != null && job.LastRunAt == before)
                {
                    if (JobWords.IsRunning(job)) { _stillRunningSeenOut.Add(key); ended = false; }
                    else ended = _stillRunningSeenOut.Contains(key)
                        || n - _stillRunningSince.GetValueOrDefault(key, n) >= Timing.StillRunningGiveUp;
                }
                else ended = true;
                if (!ended) continue;
                _stillRunning.Remove(key);
                _stillRunningSince.Remove(key);
                _stillRunningSeenOut.Remove(key);
                any = true;
            }
        }
        return any;
    }

    // ------------------------------------------------------------------ the editor's writes and reads

    private JobEditResult EditFailure(GatewayException e) =>
        new(EditKind.Failed, Reason: JobErrors.EditReason(e), Status: JobErrors.Status(e), Slow: JobErrors.IsSlowAnswer(e));

    /// `POST /api/cron/jobs?profile=`.
    public async Task<JobEditResult> CreateAsync(JsonNode body, string profile)
    {
        if (ReadOnlyGateway) return new(EditKind.Refused);
        ForgetList();
        try
        {
            var made = CronJob.Parse(await Api.CreateAsync(body, profile).ConfigureAwait(false));
            if (made != null && made.Profile == null) made.Profile = profile;
            await RefreshAsync().ConfigureAwait(false);
            return new(EditKind.Done, made);
        }
        catch (GatewayException e)
        {
            if (JobErrors.IsSlowAnswer(e)) _ = RefreshAsync();
            return EditFailure(e);
        }
    }

    /// `PUT /api/cron/jobs/<id>?profile=<owner>` with `{"updates": …}` (only the changed keys).
    public async Task<JobEditResult> UpdateAsync(CronJob job, JsonNode updates)
    {
        if (ReadOnlyGateway) return new(EditKind.Refused);
        ForgetList();
        try
        {
            var fresh = CronJob.Parse(await Api.UpdateAsync(job.Id, job.Owner, updates).ConfigureAwait(false));
            if (fresh != null && fresh.Profile == null) fresh.Profile = job.Profile;
            SupersedeListRead();
            if (fresh != null) Replace(fresh);
            _ = RefreshAsync();
            return new(EditKind.Done, fresh);
        }
        catch (GatewayException e)
        {
            if (JobErrors.Status(e) == 404)
            {
                SupersedeListRead();
                Remove(job.Key);
                JobRemoved?.Invoke(job.Key);
                _ = RefreshAsync();
                return new(EditKind.Failed, Reason: "This job no longer exists.", Status: 404);
            }
            if (JobErrors.IsSlowAnswer(e)) _ = RefreshAsync();
            return EditFailure(e);
        }
    }

    /// `POST /api/cron/blueprints/instantiate?profile=`.
    public async Task<JobEditResult> InstantiateAsync(string key, IReadOnlyDictionary<string, string> values, string profile)
    {
        if (ReadOnlyGateway) return new(EditKind.Refused);
        ForgetList();
        try
        {
            var made = CronJob.Parse(await Api.InstantiateAsync(key, values, profile).ConfigureAwait(false));
            if (made != null && made.Profile == null) made.Profile = profile;
            await RefreshAsync().ConfigureAwait(false);
            return new(EditKind.Done, made);
        }
        catch (GatewayException e)
        {
            if (JobErrors.Status(e) == 404)
            {
                _ = LoadBlueprintsAsync(profile);
                return new(EditKind.Failed, Reason: "This blueprint is no longer available.", Status: 404);
            }
            if (JobErrors.IsSlowAnswer(e)) _ = RefreshAsync();
            return EditFailure(e);
        }
    }

    public Task<List<DeliveryTarget>> DeliveryTargetsAsync(string profile) => Api.DeliveryTargetsAsync(profile);
    public Task<List<JobModelProvider>> ModelProvidersAsync(string profile) => Api.ModelProvidersAsync(profile);

    /// With the list's reads: at most one catalog read a minute per profile.
    public async Task LoadBlueprintsIfStaleAsync(string profile)
    {
        lock (_lock)
            if (_blueprintsReadAt.TryGetValue(profile, out var at) && DateTimeOffset.Now - at < TimeSpan.FromSeconds(60)) return;
        await LoadBlueprintsAsync(profile).ConfigureAwait(false);
    }

    /// `GET /api/cron/blueprints?profile=`. A failed read keeps what was known.
    public async Task<bool> LoadBlueprintsAsync(string profile)
    {
        lock (_lock) _blueprintsReadAt[profile] = DateTimeOffset.Now;
        try
        {
            var list = await Api.BlueprintsAsync(profile).ConfigureAwait(false);
            bool changed;
            lock (_lock)
            {
                changed = !BlueprintsByProfile.TryGetValue(profile, out var old) || !old.SequenceEqual(list);
                if (changed) BlueprintsByProfile[profile] = list;
            }
            if (changed) Notify();
            _cache?.Write(BlueprintsName(profile), new JsonObject { ["blueprints"] = BlueprintsJson(list) }.ToJsonString());
            return true;
        }
        catch (GatewayException) { return false; }
    }

    private static JsonArray BlueprintsJson(IEnumerable<Blueprint> list) => new([.. list.Select(b => (JsonNode)new JsonObject
    {
        ["key"] = b.Key, ["title"] = b.Title, ["description"] = b.Description, ["category"] = b.Category,
        ["fields"] = new JsonArray([.. b.Fields.Select(f => (JsonNode)new JsonObject
        {
            ["name"] = f.Name, ["type"] = f.Type, ["label"] = f.Label, ["default"] = f.DefaultValue,
            ["options"] = new JsonArray([.. f.Choices.Select(o => (JsonNode)JsonValue.Create(o)!)]),
            ["optional"] = f.Optional, ["strict"] = f.Strict, ["help"] = f.Help,
        })]),
    })]);

    /// A write is about to change what the list says: its scope's cached answer goes, so the write's follow-up
    /// refresh is a real read (JobsListCache would otherwise serve the answer read before the write).
    private void ForgetList() { Api.ForgetList(Scope); }

    /// Sign-out: forget what this store holds in memory.
    public void Reset()
    {
        Stop();
        Interlocked.Increment(ref _readGeneration);
        Jobs = [];
        lock (_lock) { _botWorking = []; _botWorkingAt = null; }
        HasList = false;
    }
}

/// `localizedStandardCompare`: case-insensitive, numbers compared as numbers ("Job 2" before "Job 10").
public sealed class NaturalComparer : IComparer<string>
{
    public static NaturalComparer Instance { get; } = new();

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
            }
            else
            {
                var c = string.Compare(a[i].ToString(), b[j].ToString(), System.Globalization.CultureInfo.InvariantCulture,
                    System.Globalization.CompareOptions.IgnoreCase);
                if (c != 0) return c;
                i++; j++;
            }
        }
        return (a.Length - i).CompareTo(b.Length - j);
    }
}
