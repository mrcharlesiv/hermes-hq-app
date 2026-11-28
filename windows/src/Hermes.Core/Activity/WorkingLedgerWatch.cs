using System.Text.Json.Nodes;
using Hermes.Core.Chat;
using Hermes.Core.Net;

namespace Hermes.Core.Activity;

// Port of HermesKit/Activity/WorkingLedgerWatch.swift:
// Polls `GET /api/plugins/hermes-hq-push/sessions/working` (gateway durable ledger),
// `GET /api/plugins/hermes-hq-push/serve/working` (in-memory turns in `hermes serve`), and per-bot
// `subagent.roster` (background commands & helpers that outlive a turn). Exposes active-turn and
// background-process working session IDs globally and per bot.

public sealed class WorkingLedgerWatch : IDisposable
{
    public const string LedgerPath = ExternalTurn.LedgerPath;
    public const string ServePath = "/api/plugins/hermes-hq-push/serve/working";

    private readonly Func<string, CancellationToken, Task<JsonNode>> _restGet;
    private readonly Func<string, JsonObject, CancellationToken, Task<JsonNode>> _rpcCall;
    private readonly object _gate = new();

    private HashSet<string> _storedIds = new(StringComparer.Ordinal);
    private Dictionary<string, HashSet<string>> _storedByProfile = new(StringComparer.Ordinal);
    private HashSet<string> _backgroundIds = new(StringComparer.Ordinal);
    private Dictionary<string, HashSet<string>> _backgroundByProfile = new(StringComparer.Ordinal);
    private readonly Dictionary<string, DateTimeOffset> _missingSince = new(StringComparer.Ordinal);
    private readonly Dictionary<string, WorkingLedgerSnapshot> _lastByRoute = new(StringComparer.Ordinal);
    private readonly Dictionary<string, DateTimeOffset> _endedAt = new(StringComparer.Ordinal);
    private DateTimeOffset? _rosterMissingSince;
    private bool _wanted;
    private CancellationTokenSource? _loopCts;

    public WorkingLedgerWatch(HermesClient client)
        : this(
            (path, ct) => client.Session.GetJsonAsync(path, timeout: BackgroundProcessesApi.LedgerTimeout, ct: ct),
            (method, p, ct) => client.Rpc.RequestAsync(method, p, BackgroundProcessesApi.RosterTimeout, ct))
    {
    }

    public WorkingLedgerWatch(
        Func<string, CancellationToken, Task<JsonNode>> restGet,
        Func<string, JsonObject, CancellationToken, Task<JsonNode>> rpcCall)
    {
        _restGet = restGet;
        _rpcCall = rpcCall;
    }

    /// How often the routes are read while wanted (tests shorten it).
    public TimeSpan Interval { get; set; } = TimeSpan.FromSeconds(5);

    /// A route that answered 404 (older add-on) or 503 (`serve/working` outside serving process) or `-32601`
    /// (`subagent.roster`) is asked again after this long.
    public TimeSpan MissingRecheck { get; set; } = TimeSpan.FromSeconds(600);

    /// Clock provider (tests inject a clock).
    public Func<DateTimeOffset> Now { get; set; } = () => DateTimeOffset.UtcNow;

    /// The bots whose chats `subagent.roster` is asked about (`""` or `"default"` = the default bot).
    public Func<IEnumerable<string>> Profiles { get; set; } = static () => [];

    /// Raised when `StoredIds` or `BackgroundIds` changed.
    public event Action? Changed;

    /// Stored session IDs the gateway runs a turn in right now, as last read.
    public IReadOnlySet<string> StoredIds { get { lock (_gate) return new HashSet<string>(_storedIds, StringComparer.Ordinal); } }

    /// Stored session IDs holding a running background command or helper, by `subagent.roster`.
    /// Not cut by `TurnEnded`: a turn's end doesn't end its background work.
    public IReadOnlySet<string> BackgroundIds { get { lock (_gate) return new HashSet<string>(_backgroundIds, StringComparer.Ordinal); } }

    /// Union of active-turn (`StoredIds`) and background-work (`BackgroundIds`) session IDs.
    public IReadOnlySet<string> WorkingIds
    {
        get
        {
            lock (_gate)
            {
                var set = new HashSet<string>(_storedIds, StringComparer.Ordinal);
                set.UnionWith(_backgroundIds);
                return set;
            }
        }
    }

    /// Active-turn working session IDs grouped by normalized bot profile (`""` → `"default"`).
    public IReadOnlyDictionary<string, IReadOnlySet<string>> StoredIdsByProfile
    {
        get
        {
            lock (_gate)
            {
                return _storedByProfile.ToDictionary(
                    kv => kv.Key,
                    kv => (IReadOnlySet<string>)new HashSet<string>(kv.Value, StringComparer.Ordinal),
                    StringComparer.Ordinal);
            }
        }
    }

    /// Background-process / helper working session IDs grouped by normalized bot profile (`""` → `"default"`).
    public IReadOnlyDictionary<string, IReadOnlySet<string>> BackgroundIdsByProfile
    {
        get
        {
            lock (_gate)
            {
                return _backgroundByProfile.ToDictionary(
                    kv => kv.Key,
                    kv => (IReadOnlySet<string>)new HashSet<string>(kv.Value, StringComparer.Ordinal),
                    StringComparer.Ordinal);
            }
        }
    }

    /// All working session IDs (active turns + background work) for one bot profile.
    public IReadOnlySet<string> WorkingIdsForProfile(string? profile)
    {
        var key = NormalizeProfile(profile);
        lock (_gate)
        {
            var set = new HashSet<string>(StringComparer.Ordinal);
            if (_storedByProfile.TryGetValue(key, out var turns)) set.UnionWith(turns);
            if (_backgroundByProfile.TryGetValue(key, out var bg)) set.UnionWith(bg);
            return set;
        }
    }

    /// Starts reading immediately and every `Interval` while `on`, or stops reading while keeping the last known sets.
    public void SetWanted(bool on)
    {
        CancellationTokenSource? toCancel = null;
        CancellationTokenSource? nextCts = null;
        lock (_gate)
        {
            if (_wanted == on) return;
            _wanted = on;
            toCancel = _loopCts;
            _loopCts = null;
            if (on)
            {
                nextCts = new CancellationTokenSource();
                _loopCts = nextCts;
            }
        }
        CancelQuietly(toCancel);
        if (nextCts is not null)
        {
            var token = nextCts.Token;
            _ = Task.Run(() => LoopAsync(token), CancellationToken.None);
        }
    }

    /// A turn this app observed ended in `storedId`: drop it from `StoredIds` immediately and reject in-flight reads
    /// started before this moment. `BackgroundIds` is untouched because background jobs outlive the turn.
    public void TurnEnded(string storedId)
    {
        var changed = false;
        lock (_gate)
        {
            _endedAt[storedId] = Now();
            if (_storedIds.Remove(storedId)) changed = true;
            foreach (var set in _storedByProfile.Values) set.Remove(storedId);
        }
        if (changed) Changed?.Invoke();
    }

    /// Stops polling and forgets all cached working IDs.
    public void Stop()
    {
        CancellationTokenSource? toCancel;
        bool changed;
        lock (_gate)
        {
            _wanted = false;
            toCancel = _loopCts;
            _loopCts = null;
            changed = _storedIds.Count > 0 || _backgroundIds.Count > 0;
            _storedIds.Clear();
            _storedByProfile.Clear();
            _backgroundIds.Clear();
            _backgroundByProfile.Clear();
            _lastByRoute.Clear();
        }
        CancelQuietly(toCancel);
        if (changed) Changed?.Invoke();
    }

    public void Dispose() => Stop();

    /// One pass across `sessions/working`, `serve/working`, and per-bot `subagent.roster`.
    public async Task ReadOnceAsync(CancellationToken ct = default)
    {
        var started = Now();
        var ledgerTask = ReadRouteAsync(LedgerPath, fromServe: false, ct);
        var serveTask = ReadRouteAsync(ServePath, fromServe: true, ct);
        var rosterTask = ReadRosterAsync(ct);

        await Task.WhenAll(ledgerTask, serveTask, rosterTask).ConfigureAwait(false);
        if (ct.IsCancellationRequested) return;

        var fromLedger = ledgerTask.Result;
        var fromServe = serveTask.Result;
        if (fromLedger is null && fromServe is null) return;

        bool changed;
        lock (_gate)
        {
            if (fromLedger is not null) _lastByRoute[LedgerPath] = fromLedger;
            if (fromServe is not null) _lastByRoute[ServePath] = fromServe;

            var ledgerSnap = fromLedger ?? (_lastByRoute.TryGetValue(LedgerPath, out var l) ? l : WorkingLedgerSnapshot.Empty);
            var serveSnap = fromServe ?? (_lastByRoute.TryGetValue(ServePath, out var s) ? s : WorkingLedgerSnapshot.Empty);

            var now = Now();
            var expired = _endedAt.Where(kv => (now - kv.Value).TotalSeconds >= 60).Select(kv => kv.Key).ToList();
            foreach (var key in expired) _endedAt.Remove(key);

            var nextIds = new HashSet<string>(StringComparer.Ordinal);
            var nextByProfile = new Dictionary<string, HashSet<string>>(StringComparer.Ordinal);

            void Collect(WorkingLedgerSnapshot snap)
            {
                foreach (var entry in snap.Entries)
                {
                    if (_endedAt.TryGetValue(entry.SessionId, out var ended) && ended >= started) continue;
                    nextIds.Add(entry.SessionId);
                    var prof = NormalizeProfile(entry.Profile);
                    if (!nextByProfile.TryGetValue(prof, out var set))
                    {
                        set = new HashSet<string>(StringComparer.Ordinal);
                        nextByProfile[prof] = set;
                    }
                    set.Add(entry.SessionId);
                }
            }

            Collect(ledgerSnap);
            Collect(serveSnap);

            changed = !nextIds.SetEquals(_storedIds);
            _storedIds = nextIds;
            _storedByProfile = nextByProfile;
        }
        if (changed) Changed?.Invoke();
    }

    private async Task LoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            bool wanted;
            lock (_gate) wanted = _wanted;
            if (!wanted) return;
            try
            {
                await ReadOnceAsync(ct).ConfigureAwait(false);
                if (ct.IsCancellationRequested) return;
                await Task.Delay(Interval, ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    private async Task<WorkingLedgerSnapshot?> ReadRouteAsync(string path, bool fromServe, CancellationToken ct)
    {
        lock (_gate)
        {
            if (_missingSince.TryGetValue(path, out var since) && Now() - since < MissingRecheck)
                return null;
        }
        try
        {
            var json = await _restGet(path, ct).ConfigureAwait(false);
            lock (_gate) _missingSince.Remove(path);
            return WorkingLedgerSnapshot.Parse(json, fromServe);
        }
        catch (GatewayException e) when (e.Status is 404 or 503)
        {
            lock (_gate)
            {
                _missingSince[path] = Now();
                _lastByRoute.Remove(path);
            }
            return new WorkingLedgerSnapshot(fromServe, new HashSet<string>(StringComparer.Ordinal), Array.Empty<WorkingLedgerEntry>());
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            return null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private async Task ReadRosterAsync(CancellationToken ct)
    {
        lock (_gate)
        {
            if (_rosterMissingSince is { } since && Now() - since < MissingRecheck)
                return;
        }

        var names = Profiles()
            .Select(NormalizeProfile)
            .Distinct(StringComparer.Ordinal)
            .OrderBy(p => p, StringComparer.Ordinal)
            .ToList();
        if (names.Count == 0) return;

        Dictionary<string, HashSet<string>> next;
        lock (_gate)
        {
            next = new Dictionary<string, HashSet<string>>(StringComparer.Ordinal);
            foreach (var name in names)
            {
                if (_backgroundByProfile.TryGetValue(name, out var existing))
                    next[name] = new HashSet<string>(existing, StringComparer.Ordinal);
            }
        }

        foreach (var name in names)
        {
            if (ct.IsCancellationRequested) return;
            var parameters = BackgroundProcessesApi.ProfileParams(name);
            try
            {
                var answer = await _rpcCall("subagent.roster", parameters, ct).ConfigureAwait(false);
                lock (_gate) _rosterMissingSince = null;
                next[name] = ParseRosterIds(answer);
            }
            catch (GatewayException e) when (BackgroundProcessesApi.IsMethodNotFound(e))
            {
                lock (_gate) _rosterMissingSince = Now();
                next.Clear();
                break;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                return;
            }
            catch (Exception)
            {
                // Transient failure keeps that bot's last word.
                continue;
            }
        }

        if (ct.IsCancellationRequested) return;

        var union = new HashSet<string>(StringComparer.Ordinal);
        foreach (var set in next.Values) union.UnionWith(set);

        bool changed;
        lock (_gate)
        {
            _backgroundByProfile = next;
            changed = !union.SetEquals(_backgroundIds);
            if (changed) _backgroundIds = union;
        }
        if (changed) Changed?.Invoke();
    }

    /// The stored IDs a `{"sessions": [{"id": …}]}` answer names.
    public static HashSet<string> ParseIds(JsonNode? json)
    {
        var outSet = new HashSet<string>(StringComparer.Ordinal);
        if (json.Get("sessions") is not JsonArray rows) return outSet;
        foreach (var row in rows)
        {
            if (row?.Text("id") is { } id) outSet.Add(id);
        }
        return outSet;
    }

    /// `{"sessions": [{"session_id", "subagents", "background"}]}` → stored IDs with either count > 0.
    public static HashSet<string> ParseRosterIds(JsonNode? json)
    {
        var outSet = new HashSet<string>(StringComparer.Ordinal);
        if (json.Get("sessions") is not JsonArray rows) return outSet;
        foreach (var row in rows)
        {
            if (row is null) continue;
            var id = row.Text("session_id");
            if (id is null) continue;
            var bg = ActivityJson.Num(row.Get("background")) ?? 0;
            var subs = ActivityJson.Num(row.Get("subagents")) ?? 0;
            if (bg > 0 || subs > 0) outSet.Add(id);
        }
        return outSet;
    }

    private static string NormalizeProfile(string? profile) =>
        string.IsNullOrWhiteSpace(profile) ? "default" : profile.Trim();

    private static void CancelQuietly(CancellationTokenSource? cts)
    {
        if (cts is null) return;
        try { cts.Cancel(); } catch (ObjectDisposedException) { }
        try { cts.Dispose(); } catch (ObjectDisposedException) { }
    }
}
